#!/bin/bash
# t06 — running sandbox-init inside an already-linked worktree must be refused.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t06")
# Create a linked worktree manually
WT=$(fixture_worktree "$REPO" "manual-branch" "f.txt" "content")

echo "== init inside linked worktree is refused =="
out=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$WT" --session "t06-nest" 2>&1) && ec=0 || ec=$?
assert_exit "init returns 1" 1 "$ec"
assert_contains "message mentions nesting" "nest" "$out"

test_summary
