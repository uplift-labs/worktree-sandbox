#!/bin/bash
# t03 — worktree with untracked files is preserved by lifecycle even when branch merged.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t03")
SESSION="t03"
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
BRANCH=$(basename "$SB")

# Commit something and merge to main
echo "done" > "$SB/work.txt"
(cd "$SB" && git add work.txt && git commit -q -m "feat: add work")
(cd "$REPO" && git merge -q "$BRANCH")

# Leave an untracked file behind
echo "not yet committed" > "$SB/untracked-scratch.txt"
assert_file_exists "untracked file exists" "$SB/untracked-scratch.txt"

# Remove marker so lifecycle is allowed to sweep it
rm -f "$REPO/.git/sandbox-markers/$SESSION"

out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_contains "reports PRESERVED" "PRESERVED" "$out"
assert_contains "mentions unsaved" "unsaved work" "$out"
assert_dir_exists "sandbox still present" "$SB"
assert_file_exists "untracked file still there" "$SB/untracked-scratch.txt"

test_summary
