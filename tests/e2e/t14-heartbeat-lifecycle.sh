#!/bin/bash
# t14 — heartbeat-based lifecycle: heartbeat keeps marker alive, PID death
# freezes mtime, lifecycle reclaims the stale marker and worktree.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

HB="$ROOT/core/lib/heartbeat.sh"
REPO=$(fixture_repo "t14")
SESSION="t14-heartbeat"

SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
BRANCH=$(basename "$SB")
MARKER="$REPO/.git/sandbox-markers/$SESSION"
assert_file_exists "marker created" "$MARKER"

# Merge the sandbox branch so it's eligible for removal
echo "work" > "$SB/work.txt"
(cd "$SB" && git add work.txt && git commit -q -m "feat: work")
(cd "$REPO" && git merge -q "$BRANCH")

# ── 1. Heartbeat keeps marker alive against short TTL ────────────────
echo "== heartbeat protects marker from TTL reclaim =="

# Backdate the marker's created_epoch to pass grace period
# (rewrite content with old epoch, but mtime will be refreshed by heartbeat)
_branch_val=$(sb_marker_read_value "$MARKER")
_init_head=$(sb_marker_read_initial_head "$MARKER")
printf '%s %s %s' "$_branch_val" "1000000000" "$_init_head" > "$MARKER"

sleep 300 &
MOCK_PID=$!

bash "$HB" --pid "$MOCK_PID" --marker "$MARKER" --interval 1 &
HB_PID=$!
sleep 2

# Marker should be fresh despite old created_epoch
sb_marker_is_fresh "$MARKER" 5; assert_exit "marker fresh while heartbeat active" 0 $?

# Lifecycle should NOT reclaim (heartbeat sidecar PID is alive)
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "marker survives lifecycle (heartbeat alive)" "$MARKER"
assert_dir_exists "worktree survives lifecycle" "$SB"

# ── 2. Kill PID → heartbeat stops → marker ages → lifecycle reclaims ─
echo "== PID death → marker stales → lifecycle reclaims =="

kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true
# Wait for heartbeat to detect PID death and exit
sleep 3

# Heartbeat should have exited
if kill -0 "$HB_PID" 2>/dev/null; then
  kill "$HB_PID" 2>/dev/null; wait "$HB_PID" 2>/dev/null || true
fi
assert_file_exists "sidecar left behind after PID death (dead-PID signal)" "${MARKER}.hb"

# Backdate marker mtime to simulate time passing after heartbeat stopped
touch -t "$(date -d '-1 minute' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-1M '+%Y%m%d%H%M.%S')" "$MARKER"

# Now lifecycle should reclaim it
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5)
assert_file_absent "marker pruned after PID death + TTL" "$MARKER"
assert_contains "reports removal" "REMOVED" "$out"
assert_dir_absent "worktree swept" "$SB"

# ── 3. Grace period protects freshly-created markers ─────────────────
echo "== grace period protects fresh markers =="

SESSION2="t14-fresh"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
MARKER2="$REPO/.git/sandbox-markers/$SESSION2"
assert_file_exists "fresh marker created" "$MARKER2"

# No heartbeat, no sidecar — but marker just created (within grace period)
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "fresh marker survives (grace period)" "$MARKER2"

# Cleanup
rm -f "$MARKER2" 2>/dev/null || true

test_summary
