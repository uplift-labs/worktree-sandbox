#!/bin/bash
# Unit tests for core/lib/wt-cleanup.sh
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"
. "$ROOT/core/lib/wt-cleanup.sh"

fixture_init
trap fixture_cleanup EXIT

echo "== remove_if_merged happy path =="
REPO=$(fixture_repo "a")
WT=$(fixture_worktree "$REPO" "fa" "x.txt" "hi")
(cd "$REPO" && git merge -q fa)
out=$(sb_wt_remove_if_merged "$REPO" "$WT" "fa" "main") && ec=0 || ec=$?
assert_exit "removed returns 0" 0 "$ec"
assert_contains "output says REMOVED" "REMOVED fa" "$out"
assert_dir_absent "wt dir gone" "$WT"

echo "== remove_if_merged preserves unmerged =="
REPO=$(fixture_repo "b")
WT=$(fixture_worktree "$REPO" "fb" "y.txt" "hi")
out=$(sb_wt_remove_if_merged "$REPO" "$WT" "fb" "main") && ec=0 || ec=$?
assert_exit "unmerged returns 1" 1 "$ec"
assert_contains "output says PRESERVED" "PRESERVED fb" "$out"
assert_dir_exists "wt dir still there" "$WT"

echo "== remove_if_merged preserves dirty (untracked) =="
REPO=$(fixture_repo "c")
WT=$(fixture_worktree "$REPO" "fc" "z.txt" "hi")
(cd "$REPO" && git merge -q fc)
echo "scratch" > "$WT/scratch.txt"
out=$(sb_wt_remove_if_merged "$REPO" "$WT" "fc" "main") && ec=0 || ec=$?
assert_exit "dirty returns 2" 2 "$ec"
assert_contains "output mentions unsaved" "unsaved work" "$out"
assert_dir_exists "wt dir preserved" "$WT"

echo "== remove_if_merged preserves locked worktree =="
REPO=$(fixture_repo "locked")
WT=$(fixture_worktree "$REPO" "flocked" "locked.txt" "hi")
(cd "$REPO" && git merge -q flocked)
git -C "$REPO" worktree lock "$WT" >/dev/null 2>&1
out=$(sb_wt_remove_if_merged "$REPO" "$WT" "flocked" "main") && ec=0 || ec=$?
assert_exit "locked returns 3" 3 "$ec"
assert_contains "locked output says PRESERVED" "PRESERVED flocked" "$out"
assert_dir_exists "locked wt dir preserved" "$WT"
assert_contains "locked branch still exists" "flocked" "$(git -C "$REPO" branch --list flocked)"

echo "== prune_metadata no-op safe =="
sb_wt_prune_metadata "$REPO"; assert_exit "prune exits 0" 0 $?

echo "== sweep_orphan_branches respects skip list =="
REPO=$(fixture_repo "skip")
WT=$(fixture_worktree "$REPO" "fskip" "skip.txt" "hi")
(cd "$REPO" && git merge -q fskip)
git -C "$REPO" worktree remove "$WT" >/dev/null 2>&1
out=$(sb_wt_sweep_orphan_branches "$REPO" "f*" "main" " fskip ")
assert_eq "skip list suppresses branch removal output" "" "$out"
assert_contains "skipped branch still exists" "fskip" "$(git -C "$REPO" branch --list fskip)"
out=$(sb_wt_sweep_orphan_branches "$REPO" "f*" "main")
assert_contains "unskipped branch removed" "REMOVED branch fskip" "$out"
assert_eq "branch absent after unskipped sweep" "" "$(git -C "$REPO" branch --list fskip)"

echo "== sweep_residual_dirs =="
REPO=$(fixture_repo "d")
RES="$REPO/.claude/worktrees"
mkdir -p "$RES/empty-shell" "$RES/with-files"
echo "x" > "$RES/with-files/data.txt"
out=$(sb_wt_sweep_residual_dirs "$RES")
assert_contains "removes empty" "REMOVED residual empty-shell" "$out"
assert_contains "preserves non-empty" "PRESERVED residual with-files" "$out"
assert_dir_absent "empty shell gone" "$RES/empty-shell"
assert_dir_exists "with-files kept" "$RES/with-files"

test_summary
