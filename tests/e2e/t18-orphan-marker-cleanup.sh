#!/bin/bash
# t18 — lifecycle cleans orphan markers whose worktree directory is missing,
# and correctly handles legacy single-field heartbeat sidecar format.
#
# Covers:
#   Case 1: marker + live heartbeat, but worktree dir deleted → marker cleaned
#   Case 2: marker + dead heartbeat, but worktree dir deleted → marker cleaned
#   Case 3: legacy single-field .hb (old format) → treated as dead session
#   Case 4: negative control — marker + live heartbeat + worktree exists → preserved
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t18")
MARKERS="$REPO/.git/sandbox-markers"
mkdir -p "$MARKERS"

# ── 1. Live heartbeat + missing worktree dir → marker cleaned ───────────
echo "== live heartbeat + missing worktree dir → cleaned =="

SESSION1="t18-orphan-live-hb"
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION1")
BRANCH1=$(basename "$SB1")
MARKER1="$MARKERS/$SESSION1"
assert_file_exists "marker created" "$MARKER1"
assert_dir_exists "sandbox created" "$SB1"

# Launch a real background process to act as the heartbeat
sleep 9999 &
_fake_hb1=$!

# Write a proper sidecar with live PID
printf '%s 0 0' "$_fake_hb1" > "${MARKER1}.hb"

# Manually remove the worktree dir (simulates external cleanup / corruption)
rm -rf "$SB1"
git -C "$REPO" worktree prune 2>/dev/null || true
assert_dir_absent "worktree dir removed (precondition)" "$SB1"

out1=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (live hb, no worktree)" "$MARKER1"
assert_file_absent "sidecar cleaned" "${MARKER1}.hb"

# Heartbeat process should have been killed
if kill -0 "$_fake_hb1" 2>/dev/null; then
  echo "FAIL: fake heartbeat still alive after lifecycle (case 1)"
  kill "$_fake_hb1" 2>/dev/null
  T_FAIL=$((T_FAIL + 1)); T_TOTAL=$((T_TOTAL + 1))
else
  echo "PASS: fake heartbeat killed by lifecycle (case 1)"
  T_PASS=$((T_PASS + 1)); T_TOTAL=$((T_TOTAL + 1))
fi
wait "$_fake_hb1" 2>/dev/null || true

# ── 2. Dead heartbeat + missing worktree dir → marker cleaned ───────────
echo "== dead heartbeat + missing worktree dir → cleaned =="

SESSION2="t18-orphan-dead-hb"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
MARKER2="$MARKERS/$SESSION2"
assert_file_exists "marker created" "$MARKER2"

# Write dead PID sidecar
(exit 0) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s 0 0' "$DEAD_PID" > "${MARKER2}.hb"

# Remove worktree dir
rm -rf "$SB2"
git -C "$REPO" worktree prune 2>/dev/null || true

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_absent "marker cleaned (dead hb, no worktree)" "$MARKER2"
assert_file_absent "sidecar cleaned (dead hb)" "${MARKER2}.hb"

# ── 3. Legacy single-field .hb format → treated as dead ─────────────────
echo "== legacy single-field .hb format → treated as dead =="

SESSION3="t18-legacy-hb"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
BRANCH3=$(basename "$SB3")
MARKER3="$MARKERS/$SESSION3"
assert_file_exists "marker created" "$MARKER3"

# Merge branch into main so it's an ancestor
echo "work3" > "$SB3/work3.txt"
(cd "$SB3" && git add work3.txt && git commit -q -m "feat: work3")
(cd "$REPO" && git merge -q "$BRANCH3")

# Launch a real background process to simulate legacy heartbeat
sleep 9999 &
_fake_hb3=$!

# Write legacy single-field sidecar (old format: just the PID)
printf '%s' "$_fake_hb3" > "${MARKER3}.hb"

# Backdate marker past grace period so TTL applies after heartbeat is dismissed
_val3=$(sb_marker_read_value "$MARKER3")
_head3=$(sb_marker_read_initial_head "$MARKER3")
printf '%s %s %s' "$_val3" "1000000000" "$_head3" > "$MARKER3"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER3"

out3=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (legacy hb format)" "$MARKER3"
assert_file_absent "sidecar cleaned (legacy hb format)" "${MARKER3}.hb"
assert_dir_absent "worktree removed (legacy hb format)" "$SB3"

# Heartbeat should have been killed
if kill -0 "$_fake_hb3" 2>/dev/null; then
  echo "FAIL: legacy heartbeat still alive after lifecycle (case 3)"
  kill "$_fake_hb3" 2>/dev/null
  T_FAIL=$((T_FAIL + 1)); T_TOTAL=$((T_TOTAL + 1))
else
  echo "PASS: legacy heartbeat killed by lifecycle (case 3)"
  T_PASS=$((T_PASS + 1)); T_TOTAL=$((T_TOTAL + 1))
fi
wait "$_fake_hb3" 2>/dev/null || true

# ── 4. Negative: live heartbeat + worktree exists → preserved ───────────
echo "== negative: live heartbeat + worktree exists → preserved =="

SESSION4="t18-alive"
SB4=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION4")
MARKER4="$MARKERS/$SESSION4"
assert_file_exists "marker created" "$MARKER4"
assert_dir_exists "sandbox created" "$SB4"

# Launch heartbeat and write proper 3-field sidecar
sleep 9999 &
_fake_hb4=$!
printf '%s 0 0' "$_fake_hb4" > "${MARKER4}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "marker preserved (live hb, worktree exists)" "$MARKER4"
assert_dir_exists "sandbox preserved (live hb, worktree exists)" "$SB4"

# Cleanup
kill "$_fake_hb4" 2>/dev/null; wait "$_fake_hb4" 2>/dev/null || true

# ── 5. Marker without worktree, no .hb at all → cleaned after grace ─────
echo "== no .hb + missing worktree → cleaned =="

SESSION5="t18-no-hb-no-wt"
SB5=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION5")
MARKER5="$MARKERS/$SESSION5"

# Remove worktree dir
rm -rf "$SB5"
git -C "$REPO" worktree prune 2>/dev/null || true

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_absent "marker cleaned (no hb, no worktree)" "$MARKER5"

test_summary
