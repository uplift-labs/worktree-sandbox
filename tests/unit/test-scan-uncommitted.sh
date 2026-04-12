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

# --- --ignore-deletions flag tests ---

echo "== phantom ' D' filtered with --ignore-deletions =="
REPO2=$(fixture_repo "r2")
(cd "$REPO2" && mkdir -p data && echo "x" > data/a.md && echo "y" > data/b.md && git add -A && git commit -q -m "add files")
rm "$REPO2/data/a.md" "$REPO2/data/b.md"
# Without flag: dirty
out=$(sb_scan_uncommitted "$REPO2") && ec=0 || ec=$?
assert_exit "deletions dirty without flag" 1 "$ec"
assert_contains "reports modified" "modified" "$out"
# With flag: clean
out=$(sb_scan_uncommitted "$REPO2" --ignore-deletions) && ec=0 || ec=$?
assert_exit "deletions clean with flag" 0 "$ec"

echo "== real modifications NOT filtered by --ignore-deletions =="
REPO3=$(fixture_repo "r3")
echo "changed" >> "$REPO3/README.md"
out=$(sb_scan_uncommitted "$REPO3" --ignore-deletions) && ec=0 || ec=$?
assert_exit "real mod still dirty" 1 "$ec"
assert_contains "still reports modified" "modified" "$out"

echo "== mixed phantom deletions + real modifications =="
REPO4=$(fixture_repo "r4")
(cd "$REPO4" && mkdir -p data && echo "x" > data/del.md && git add -A && git commit -q -m "add file")
rm "$REPO4/data/del.md"
echo "changed" >> "$REPO4/README.md"
out=$(sb_scan_uncommitted "$REPO4" --ignore-deletions) && ec=0 || ec=$?
assert_exit "mixed still dirty" 1 "$ec"
assert_contains "reports 1 modified" "1 modified" "$out"

test_summary
