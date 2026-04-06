#!/bin/bash
# t16 — lifecycle cleans sessions whose heartbeat PID is dead.
# Covers:
#   - Session with dead heartbeat PID + expired TTL is cleaned
#   - Session with dead heartbeat PID but within grace period survives
#   - Heartbeat sidecar (.hb) files are cleaned along with markers
#   - Worktree directories are removed after marker cleanup
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t16")
MARKERS="$REPO/.git/sandbox-markers"
mkdir -p "$MARKERS"

# ── 1. Dead heartbeat + stale mtime → lifecycle reclaims ─────────────
echo "== dead heartbeat + stale mtime → reclaimed =="

SESSION1="t16-dead-hb"
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION1")
BRANCH1=$(basename "$SB1")
MARKER1="$MARKERS/$SESSION1"
assert_file_exists "marker created" "$MARKER1"

# Merge so branch is ancestor of main
echo "work" > "$SB1/work.txt"
(cd "$SB1" && git add work.txt && git commit -q -m "feat: work")
(cd "$REPO" && git merge -q "$BRANCH1")

# Write a fake dead PID into sidecar
printf '99999' > "${MARKER1}.hb"

# Backdate created_epoch past grace period and mtime past TTL
_val=$(sb_marker_read_value "$MARKER1")
_head=$(sb_marker_read_initial_head "$MARKER1")
printf '%s %s %s' "$_val" "1000000000" "$_head" > "$MARKER1"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER1"

# Lifecycle should reclaim
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (dead heartbeat)" "$MARKER1"
assert_file_absent "sidecar cleaned" "${MARKER1}.hb"
assert_dir_absent "worktree removed" "$SB1"

# ── 2. Dead heartbeat but within grace period → survives ─────────────
echo "== dead heartbeat within grace period → survives =="

SESSION2="t16-grace"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
MARKER2="$MARKERS/$SESSION2"
assert_file_exists "fresh marker created" "$MARKER2"

# Write a fake dead PID but do NOT backdate the epoch — marker is fresh
printf '99998' > "${MARKER2}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "marker survives (grace period)" "$MARKER2"
assert_dir_exists "worktree survives (grace period)" "$SB2"

# ── 3. No sidecar at all + stale → TTL reclaim works ─────────────────
echo "== no sidecar + stale → TTL reclaims =="

SESSION3="t16-no-hb"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
BRANCH3=$(basename "$SB3")
MARKER3="$MARKERS/$SESSION3"

# Merge
echo "work3" > "$SB3/work3.txt"
(cd "$SB3" && git add work3.txt && git commit -q -m "feat: work3")
(cd "$REPO" && git merge -q "$BRANCH3")

# Backdate epoch + mtime, no sidecar
_val3=$(sb_marker_read_value "$MARKER3")
_head3=$(sb_marker_read_initial_head "$MARKER3")
printf '%s %s %s' "$_val3" "1000000000" "$_head3" > "$MARKER3"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER3"

out3=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (no sidecar + stale)" "$MARKER3"
assert_dir_absent "worktree removed (no sidecar)" "$SB3"

# Cleanup remaining
rm -f "$MARKER2" "${MARKER2}.hb" 2>/dev/null || true

test_summary
