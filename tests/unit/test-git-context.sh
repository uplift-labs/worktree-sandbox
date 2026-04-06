#!/bin/bash
# Unit tests for core/lib/git-context.sh
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/git-context.sh"

fixture_init
trap fixture_cleanup EXIT

echo "== sb_git_root in main repo =="
REPO=$(fixture_repo "a")
got=$(sb_git_root "$REPO"); ec=$?
assert_exit "exits 0" 0 "$ec"
assert_contains "returns repo path" "a" "$got"

echo "== sb_is_worktree main =="
sb_is_worktree "$REPO"; ec=$?
assert_exit "main tree returns 1" 1 "$ec"

echo "== sb_is_worktree linked =="
WT=$(fixture_worktree "$REPO" "feature" "x.txt" "hello")
sb_is_worktree "$WT"; ec=$?
assert_exit "linked wt returns 0" 0 "$ec"

echo "== sb_main_branch detects main =="
got=$(sb_main_branch "$REPO")
assert_eq "main branch" "main" "$got"

echo "== sb_list_worktrees lists all =="
got=$(sb_list_worktrees "$REPO")
assert_contains "main listed" "main" "$got"
assert_contains "feature listed" "feature" "$got"

echo "== sb_git_root in non-repo returns error =="
NOREPO="$FIXTURE_ROOT/no-repo"
mkdir -p "$NOREPO"
sb_git_root "$NOREPO" >/dev/null 2>&1; ec=$?
assert_exit "non-repo returns 1" 1 "$ec"

echo "== sb_git_common_dir in main repo =="
got=$(sb_git_common_dir "$REPO"); ec=$?
assert_exit "exits 0" 0 "$ec"
assert_contains "ends with .git" ".git" "$got"

echo "== sb_git_common_dir from linked worktree =="
got=$(sb_git_common_dir "$WT"); ec=$?
assert_exit "exits 0 from linked wt" 0 "$ec"
assert_contains "points to main .git" ".git" "$got"

echo "== sb_git_common_dir in non-repo returns error =="
sb_git_common_dir "$NOREPO" >/dev/null 2>&1; ec=$?
assert_exit "non-repo returns 1" 1 "$ec"

echo "== sb_has_in_progress_operation on clean repo =="
sb_has_in_progress_operation "$REPO" 2>/dev/null; ec=$?
assert_exit "clean repo returns 1 (no operation)" 1 "$ec"

test_summary
