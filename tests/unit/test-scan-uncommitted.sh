#!/bin/bash
# Unit tests for core/lib/scan-uncommitted.sh
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "r")

echo "== clean merged worktree scans clean =="
WT=$(fixture_worktree "$REPO" "clean-branch" "f.txt" "one")
(cd "$REPO" && git merge -q clean-branch)
out=$(sb_scan_uncommitted "$WT") && ec=0 || ec=$?
assert_exit "clean scan returns 0" 0 "$ec"

echo "== untracked file blocks =="
echo "scratch" > "$WT/untracked.txt"
out=$(sb_scan_uncommitted "$WT") && ec=0 || ec=$?
assert_exit "untracked returns 1" 1 "$ec"
assert_contains "mentions untracked" "untracked" "$out"
rm -f "$WT/untracked.txt"

echo "== tracked modification blocks =="
(cd "$WT" && echo "modified" > f.txt)
out=$(sb_scan_uncommitted "$WT") && ec=0 || ec=$?
assert_exit "modified returns 1" 1 "$ec"
assert_contains "mentions modified" "modified" "$out"
(cd "$WT" && git checkout -- f.txt)

echo "== nonexistent wt-path returns 0 =="
sb_scan_uncommitted "$FIXTURE_ROOT/nowhere" && ec=0 || ec=$?
assert_exit "nowhere returns 0" 0 "$ec"

test_summary
