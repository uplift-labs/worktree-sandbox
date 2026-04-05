#!/bin/bash
# t13 — a fresh sandbox session (marker exists, zero commits on branch) must
# survive lifecycle cleanup triggered by a second session. Regression test for
# the bug where Phase 3 proactive marker release treated "never-worked" as
# "merged+clean" and reaped a live session's worktree.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t13")

# --- Session 1: create sandbox but do NO work (no commits, no dirty files) ---
SESSION1="t13-fresh-session"
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION1")
BRANCH1=$(basename "$SB1")
MARKER1="$REPO/.git/sandbox-markers/$SESSION1"
assert_dir_exists "session1 sandbox created" "$SB1"
assert_file_exists "session1 marker created" "$MARKER1"

# Verify marker has initial_head field
init_head=$(awk '{print $3}' "$MARKER1")
assert_contains "marker has initial_head" "^[0-9a-f]" "$init_head"

echo "== lifecycle must NOT reap fresh session with no commits =="
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_file_exists "marker survives lifecycle" "$MARKER1"
assert_dir_exists "sandbox survives lifecycle" "$SB1"

# --- Session 2: create another sandbox, also fresh ---
SESSION2="t13-second-session"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
MARKER2="$REPO/.git/sandbox-markers/$SESSION2"

echo "== both fresh sessions survive lifecycle =="
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null
assert_file_exists "session1 marker still alive" "$MARKER1"
assert_dir_exists "session1 sandbox still alive" "$SB1"
assert_file_exists "session2 marker alive" "$MARKER2"
assert_dir_exists "session2 sandbox alive" "$SB2"

# --- Positive control: session1 does work, merges, then lifecycle reaps it ---
echo "== after commit+merge, lifecycle reaps the completed session =="
echo "done" > "$SB1/done.txt"
(cd "$SB1" && git add done.txt && git commit -q -m "feat: work done")
(cd "$REPO" && git merge -q "$BRANCH1")

out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_file_absent "worked+merged marker released" "$MARKER1"
assert_dir_absent "worked+merged sandbox reaped" "$SB1"
# Session 2 (still fresh) must survive
assert_file_exists "session2 still alive after session1 reaped" "$MARKER2"
assert_dir_exists "session2 sandbox still alive" "$SB2"

test_summary
