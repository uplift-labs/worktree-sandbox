#!/bin/bash
# t02 — unchecked TASK.md boxes block merge-gate.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t02")
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t02")

cat > "$SB/TASK.md" << 'T'
---
created: 2026-04-05
purpose: Test blocked merge
---
## Tasks
- [x] Done
- [ ] Still pending
T

echo "== merge-gate blocks on unchecked =="
out=$(bash "$ROOT/core/cmd/sandbox-merge-gate.sh" --worktree "$SB") && ec=0 || ec=$?
assert_exit "gate returns 1" 1 "$ec"
assert_contains "reports unchecked" "1/2 unchecked" "$out"
assert_contains "reports purpose" "Test blocked merge" "$out"

test_summary
