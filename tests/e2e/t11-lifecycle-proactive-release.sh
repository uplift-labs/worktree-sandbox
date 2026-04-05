#!/bin/bash
# t11 — lifecycle's proactive marker release reaps a merged+clean sandbox
# whose marker is still fresh (not TTL-expired). Covers the crashed /
# `/clear` / `/compact` session gap where SessionEnd never self-released.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t11")
SESSION="t11-crashed-but-fresh"
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
BRANCH=$(basename "$SB")

# Make the branch mergeable and merge it into main.
echo "done" > "$SB/done.txt"
(cd "$SB" && git add done.txt && git commit -q -m "feat: done")
(cd "$REPO" && git merge -q "$BRANCH")

MARKER="$REPO/.git/sandbox-markers/$SESSION"
assert_file_exists "marker exists (fresh)" "$MARKER"

# Run lifecycle with the default generous TTL. The marker is fresh, so
# Phase 2 TTL reclaim must NOT touch it — only Phase 3 proactive release
# should drop it, proving the new behavior.
echo "== lifecycle with default TTL reaps merged+clean sandbox =="
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_file_absent "fresh marker proactively released" "$MARKER"
assert_contains "reports removal" "REMOVED" "$out"
assert_dir_absent "sandbox reaped" "$SB"

# Negative control: a fresh marker whose branch is NOT merged must survive.
SESSION2="t11-live-unmerged"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
BRANCH2=$(basename "$SB2")
echo "wip" > "$SB2/wip.txt"
(cd "$SB2" && git add wip.txt && git commit -q -m "wip")
MARKER2="$REPO/.git/sandbox-markers/$SESSION2"

echo "== unmerged branch's marker must survive proactive release =="
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null
assert_file_exists "unmerged marker preserved" "$MARKER2"
assert_dir_exists "unmerged sandbox preserved" "$SB2"

# Negative control: merged branch but dirty worktree must survive.
SESSION3="t11-merged-but-dirty"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
BRANCH3=$(basename "$SB3")
echo "a" > "$SB3/a.txt"
(cd "$SB3" && git add a.txt && git commit -q -m "a")
(cd "$REPO" && git merge -q "$BRANCH3")
# Leave an untracked file behind → sb_scan_uncommitted reports dirty.
echo "uncommitted" > "$SB3/dirty.txt"
MARKER3="$REPO/.git/sandbox-markers/$SESSION3"

echo "== merged+dirty sandbox must survive proactive release =="
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null
assert_file_exists "dirty marker preserved" "$MARKER3"
assert_dir_exists "dirty sandbox preserved" "$SB3"

test_summary
