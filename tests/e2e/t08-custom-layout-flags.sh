#!/bin/bash
# t08 — --worktrees-dir and --branch-prefix flags (Singularity compat path).
# Verifies that sandbox-init and sandbox-lifecycle honour non-default layout
# so host projects with their own conventions (e.g. Singularity's
# .claude/worktrees/ + worktree-session-* naming) can delegate to the core
# without migrating existing worktrees.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t08")
SESSION="t08-custom"
CUSTOM_DIR=".claude/worktrees"
CUSTOM_PREFIX="worktree-session"

echo "== init honours --worktrees-dir and --branch-prefix =="
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" \
  --repo "$REPO" --session "$SESSION" \
  --worktrees-dir "$CUSTOM_DIR" \
  --branch-prefix "$CUSTOM_PREFIX")
ec=$?
assert_exit "init exits 0" 0 "$ec"
assert_dir_exists "sandbox in custom layout" "$REPO/$CUSTOM_DIR/$CUSTOM_PREFIX-$SESSION"
# Full path equality is skipped: on MSYS, git cygpaths /tmp/... to C:/Users/.../Temp/...
# The dir-exists check above already proves the custom layout is honoured.
assert_contains "returned path has custom prefix" "$CUSTOM_PREFIX-$SESSION" "$SB"
assert_contains "returned path has custom dir" "$CUSTOM_DIR" "$SB"
assert_file_exists "TASK.md seeded in custom layout" "$SB/TASK.md"

echo "== default layout is not used when flags given =="
assert_dir_absent "no .sandbox dir" "$REPO/.sandbox"

echo "== lifecycle with matching flags cleans the custom layout =="
printf 'feature\n' > "$SB/feature.txt"
(cd "$SB" && git add feature.txt && git commit -q -m "feat: add feature")
(cd "$REPO" && git merge -q "$CUSTOM_PREFIX-$SESSION")
rm -f "$REPO/.git/sandbox-markers/$SESSION"
rm -f "$SB/TASK.md"

out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" \
  --repo "$REPO" \
  --worktrees-dir "$CUSTOM_DIR" \
  --branch-prefix "$CUSTOM_PREFIX-*")
assert_contains "lifecycle reports removal" "REMOVED" "$out"
assert_dir_absent "custom sandbox swept" "$SB"

test_summary
