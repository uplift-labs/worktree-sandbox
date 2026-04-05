#!/bin/bash
# t01 — full happy path: init → edit → commit → check → gate ok → merge → cleanup.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "happy")
SESSION="t01-happy"

echo "== step 1: init creates sandbox with seeded TASK.md =="
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
ec=$?
assert_exit "init exits 0" 0 "$ec"
assert_dir_exists "sandbox dir exists" "$SB"
assert_file_exists "TASK.md seeded" "$SB/TASK.md"
assert_contains "TASK.md has TODO" "TODO" "$(cat "$SB/TASK.md")"

echo "== step 2: edit file in sandbox =="
printf 'feature content\n' > "$SB/feature.txt"
(cd "$SB" && git add feature.txt && git commit -q -m "feat: add feature")
assert_file_exists "feature.txt committed" "$SB/feature.txt"

echo "== step 3: fill TASK.md =="
cat > "$SB/TASK.md" << 'T'
---
created: 2026-04-05
purpose: Ship the feature
---
## Tasks
- [x] Add feature file
T

echo "== step 4: merge-gate passes =="
bash "$ROOT/core/cmd/sandbox-merge-gate.sh" --worktree "$SB"; ec=$?
assert_exit "gate allows" 0 "$ec"

echo "== step 5: merge into main =="
(cd "$REPO" && git merge -q "$(basename "$SB")")
assert_file_exists "feature in main" "$REPO/feature.txt"

echo "== step 6: lifecycle removes merged sandbox =="
# Remove the session marker so lifecycle is allowed to sweep its worktree
MARKERS_DIR="$REPO/.git/sandbox-markers"
rm -f "$MARKERS_DIR/$SESSION"
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO")
assert_contains "lifecycle reports removal" "REMOVED" "$out"
assert_dir_absent "sandbox dir gone" "$SB"

test_summary
