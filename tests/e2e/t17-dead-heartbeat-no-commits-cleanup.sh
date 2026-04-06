#!/bin/bash
# t17 — a session with a dead heartbeat and no commits (HEAD == init_head)
# must be cleaned up by lifecycle Phase 3, even though cur_head == init_head.
#
# Regression test for the bug where Phase 3 unconditionally skipped sessions
# with HEAD == init_head, preventing cleanup of dead sessions that never
# committed any work (common after /clear + terminal close).
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t17")
SESSION="t17-dead-no-commits"
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
BRANCH=$(basename "$SB")
MARKER="$REPO/.git/sandbox-markers/$SESSION"

assert_file_exists "marker created" "$MARKER"
assert_dir_exists "sandbox created" "$SB"

# Simulate a dead heartbeat: write a .hb sidecar with a PID that does not
# exist. PID 99999 is unlikely to be alive; use a subshell PID that already
# exited as a safer choice.
(exit 0) &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s 0 0' "$DEAD_PID" > "${MARKER}.hb"
assert_file_exists "heartbeat sidecar planted" "${MARKER}.hb"

# Verify precondition: branch HEAD equals init_head (no commits made).
init_head=$(awk '{print $3}' "$MARKER")
cur_head=$(git -C "$SB" rev-parse HEAD 2>/dev/null)
assert_eq "HEAD == init_head (no work done)" "$init_head" "$cur_head"

# Branch is trivially an ancestor of main (created from main HEAD).
git -C "$REPO" merge-base --is-ancestor "$BRANCH" main 2>/dev/null; ec=$?
assert_exit "branch is ancestor of main" 0 "$ec"

echo "== lifecycle must reap dead session with no commits =="
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_file_absent "marker released" "$MARKER"
assert_file_absent "heartbeat sidecar cleaned" "${MARKER}.hb"
assert_dir_absent "sandbox removed" "$SB"
assert_contains "lifecycle reports removal" "REMOVED" "$out"

echo "== negative control: dead heartbeat + no commits + NOT merged =="
SESSION2="t17-dead-unmerged"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
BRANCH2=$(basename "$SB2")
MARKER2="$REPO/.git/sandbox-markers/$SESSION2"

# Make branch diverge from main so it's NOT an ancestor.
echo "wip" > "$SB2/diverge.txt"
(cd "$SB2" && git add diverge.txt && git commit -q -m "wip: diverge")

# Plant dead heartbeat.
(exit 0) &
DEAD_PID2=$!
wait "$DEAD_PID2" 2>/dev/null || true
printf '%s 0 0' "$DEAD_PID2" > "${MARKER2}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null
assert_file_exists "unmerged marker preserved" "$MARKER2"
assert_dir_exists "unmerged sandbox preserved" "$SB2"

echo "== negative control: no heartbeat sidecar + no commits =="
SESSION3="t17-no-hb-fresh"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
MARKER3="$REPO/.git/sandbox-markers/$SESSION3"

# No .hb file — can't confirm session is dead. Must preserve (fresh session).
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null
assert_file_exists "no-heartbeat marker preserved" "$MARKER3"
assert_dir_exists "no-heartbeat sandbox preserved" "$SB3"

test_summary
