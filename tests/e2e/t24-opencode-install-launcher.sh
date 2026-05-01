#!/bin/bash
# t24 — OpenCode install path and launcher smoke test.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t24")

echo "== install --with-opencode populates adapter and project plugin =="
OUT=$(bash "$ROOT/install.sh" --target "$REPO" --with-opencode 2>&1)
ec=$?
assert_exit "install exits 0" 0 "$ec"
assert_file_exists "opencode launcher copied" "$REPO/.uplift/sandbox/adapters/opencode/bin/opencode-sandbox.sh"
assert_file_exists "opencode layout copied" "$REPO/.uplift/sandbox/adapters/opencode/lib/layout.sh"
assert_file_exists "opencode adapter plugin copied" "$REPO/.uplift/sandbox/adapters/opencode/plugins/worktree-sandbox.js"
assert_file_exists "project opencode plugin written" "$REPO/.opencode/plugins/worktree-sandbox.js"
assert_contains "install output mentions opencode" "opencode adapter" "$OUT"

echo "== re-install updates managed plugin but preserves unrelated project plugins =="
printf 'user plugin\n' > "$REPO/.opencode/plugins/user-plugin.js"
printf 'stale\n' > "$REPO/.uplift/sandbox/adapters/opencode/plugins/stale.js"
OUT=$(bash "$ROOT/install.sh" --target "$REPO" --with-opencode 2>&1)
ec=$?
assert_exit "re-install exits 0" 0 "$ec"
assert_file_absent "stale adapter plugin removed" "$REPO/.uplift/sandbox/adapters/opencode/plugins/stale.js"
assert_file_exists "unrelated project plugin preserved" "$REPO/.opencode/plugins/user-plugin.js"
assert_file_exists "managed project plugin still present" "$REPO/.opencode/plugins/worktree-sandbox.js"

echo "== post-merge hook preserves --with-opencode flag =="
GIT_COMMON=$(git -C "$REPO" rev-parse --git-common-dir)
assert_contains "post-merge detects opencode" "--with-opencode" "$(cat "$REPO/$GIT_COMMON/hooks/post-merge")"

echo "== installed launcher runs fake OpenCode inside .uplift sandbox =="
FAKE_BIN="$FIXTURE_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/opencode" <<'SH'
#!/bin/bash
printf '%s' "$PWD" > "$OPENCODE_FAKE_CWD"
printf '%s' "$OPENCODE_SANDBOX_WORKTREE" > "$OPENCODE_FAKE_WORKTREE"
printf '%s' "${OPENCODE_CONFIG_DIR:-}" > "$OPENCODE_FAKE_CONFIG_DIR"
exit 0
SH
chmod +x "$FAKE_BIN/opencode"

SESSION="t24-installed"
FAKE_CWD="$FIXTURE_ROOT/fake-cwd.txt"
FAKE_WORKTREE="$FIXTURE_ROOT/fake-worktree.txt"
FAKE_CONFIG="$FIXTURE_ROOT/fake-config.txt"
OUT=$(PATH="$FAKE_BIN:$PATH" \
  OPENCODE_FAKE_CWD="$FAKE_CWD" \
  OPENCODE_FAKE_WORKTREE="$FAKE_WORKTREE" \
  OPENCODE_FAKE_CONFIG_DIR="$FAKE_CONFIG" \
  bash "$REPO/.uplift/sandbox/adapters/opencode/bin/opencode-sandbox.sh" \
    --repo "$REPO" --session "$SESSION" -- run "hello" 2>&1)
ec=$?
assert_exit "installed launcher exits 0" 0 "$ec"
assert_file_exists "fake opencode received cwd" "$FAKE_CWD"
assert_contains "fake cwd is installed sandbox" ".uplift/sandbox/worktrees/wt-$SESSION" "$(cat "$FAKE_CWD")"
assert_contains "worktree env is installed sandbox" ".uplift/sandbox/worktrees/wt-$SESSION" "$(cat "$FAKE_WORKTREE")"
assert_contains "config dir is installed adapter" ".uplift/sandbox/adapters/opencode" "$(cat "$FAKE_CONFIG")"
assert_dir_absent "empty installed sandbox reaped" "$REPO/.uplift/sandbox/worktrees/wt-$SESSION"
assert_file_absent "empty installed marker reaped" "$REPO/.git/sandbox-markers/$SESSION"
assert_dir_absent "legacy .sandbox not used" "$REPO/.sandbox"

test_summary
