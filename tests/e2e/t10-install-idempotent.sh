#!/bin/bash
# t10 — install.sh is idempotent and updating.
# Covers:
#   - Fresh install populates core + adapter hook dirs.
#   - Re-running install.sh overwrites existing *.sh (latest source wins).
#   - Stale *.sh files in the install target that no longer exist in source
#     are removed on re-run (protects against silent drift after a rename
#     or deletion upstream).
#   - Runtime state under .sandbox/ (worktrees/, markers) is untouched.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t10")

echo "== first install populates core + adapter =="
OUT=$(bash "$ROOT/install.sh" --target "$REPO" --with-claude-code 2>&1)
ec=$?
assert_exit "install exits 0" 0 "$ec"
assert_file_exists "core lib copied"    "$REPO/.sandbox/core/lib/git-context.sh"
assert_file_exists "core cmd copied"    "$REPO/.sandbox/core/cmd/sandbox-init.sh"
assert_file_exists "adapter lib copied" "$REPO/.sandbox/adapter/lib/json-field.sh"
assert_file_exists "adapter hook copied" "$REPO/.sandbox/adapter/hooks/session-end.sh"

echo "== seed stale files + runtime state, then re-run install =="
# Pretend an older version had these files that are no longer in source.
echo "# stale core lib" > "$REPO/.sandbox/core/lib/ghost-lib.sh"
echo "# stale core cmd" > "$REPO/.sandbox/core/cmd/ghost-cmd.sh"
echo "# stale adapter hook" > "$REPO/.sandbox/adapter/hooks/ghost-hook.sh"
echo "# stale adapter lib"  > "$REPO/.sandbox/adapter/lib/ghost.sh"
# Runtime state that install MUST NOT touch.
mkdir -p "$REPO/.sandbox/worktrees/bogus-session"
echo "runtime" > "$REPO/.sandbox/worktrees/bogus-session/marker.txt"
mkdir -p "$REPO/.git/sandbox-markers"
echo "branch 123" > "$REPO/.git/sandbox-markers/sess-abc"

# Also mutate an installed file to confirm re-run actually overwrites.
echo "TAMPERED" > "$REPO/.sandbox/core/cmd/sandbox-init.sh"

OUT=$(bash "$ROOT/install.sh" --target "$REPO" --with-claude-code 2>&1)
ec=$?
assert_exit "re-install exits 0" 0 "$ec"

echo "== stale files in managed dirs are gone =="
assert_file_absent "stale core lib removed"     "$REPO/.sandbox/core/lib/ghost-lib.sh"
assert_file_absent "stale core cmd removed"     "$REPO/.sandbox/core/cmd/ghost-cmd.sh"
assert_file_absent "stale adapter hook removed" "$REPO/.sandbox/adapter/hooks/ghost-hook.sh"
assert_file_absent "stale adapter lib removed"  "$REPO/.sandbox/adapter/lib/ghost.sh"

echo "== tampered file is restored to source content =="
REINSTALLED=$(head -1 "$REPO/.sandbox/core/cmd/sandbox-init.sh")
assert_not_contains "tampered file overwritten" "TAMPERED" "$REINSTALLED"
assert_contains "restored file has expected shebang" "#!/bin/bash" "$REINSTALLED"

echo "== runtime state is untouched =="
assert_dir_exists  "bogus worktree dir preserved" "$REPO/.sandbox/worktrees/bogus-session"
assert_file_exists "bogus worktree file preserved" "$REPO/.sandbox/worktrees/bogus-session/marker.txt"
assert_file_exists "marker preserved"              "$REPO/.git/sandbox-markers/sess-abc"

echo "== missing source dir is a fatal error (abort, no partial wipe) =="
# Build a minimal broken source tree with no core/lib/*.sh.
BROKEN_SRC=$(mktemp -d 2>/dev/null || mktemp -d -t sbx-broken)
mkdir -p "$BROKEN_SRC/core/lib" "$BROKEN_SRC/core/cmd" "$BROKEN_SRC/adapters/claude-code/lib" "$BROKEN_SRC/adapters/claude-code/hooks"
cp "$ROOT/install.sh" "$BROKEN_SRC/install.sh"
# No .sh files in core/lib — should abort before wiping.
OUT=$(bash "$BROKEN_SRC/install.sh" --target "$REPO" 2>&1)
ec=$?
assert_exit "broken source install fails" 1 "$ec"
assert_contains "error mentions missing source" "no \*.sh files" "$OUT"
# After the failed install, original files must still be present.
assert_file_exists "core lib survived failed install" "$REPO/.sandbox/core/lib/git-context.sh"
rm -rf "$BROKEN_SRC"

test_summary
