#!/bin/bash
# t22 — Codex install path and launcher smoke test.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t22")

echo "== install --with-codex populates adapter and config =="
OUT=$(bash "$ROOT/install.sh" --target "$REPO" --with-codex 2>&1)
ec=$?
assert_exit "install exits 0" 0 "$ec"
assert_file_exists "codex hook copied" "$REPO/.uplift/sandbox/adapters/codex/hooks/session-start.sh"
assert_file_exists "codex launcher copied" "$REPO/.uplift/sandbox/adapters/codex/bin/codex-sandbox.sh"
assert_file_exists "codex hooks.json written" "$REPO/.codex/hooks.json"
assert_file_exists "codex config written" "$REPO/.codex/config.toml"
assert_contains "hooks point at prefix layout" ".uplift/sandbox/adapters/codex" "$(cat "$REPO/.codex/hooks.json")"
assert_contains "codex_hooks enabled" "codex_hooks = true" "$(cat "$REPO/.codex/config.toml")"

echo "== installed session-start uses .uplift/sandbox/worktrees =="
SESSION="t22-installed"
INPUT=$(printf '{"session_id":"%s","source":"startup","cwd":"%s"}' "$SESSION" "$REPO")
OUT=$(printf '%s' "$INPUT" | bash "$REPO/.uplift/sandbox/adapters/codex/hooks/session-start.sh" 2>&1)
ec=$?
assert_exit "installed session-start exits 0" 0 "$ec"
assert_dir_exists "installed layout sandbox dir exists" "$REPO/.uplift/sandbox/worktrees/wt-$SESSION"
assert_dir_absent "legacy .sandbox not used" "$REPO/.sandbox"

DENY_IN=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"apply_patch"}' "$SESSION" "$REPO")
OUT=$(printf '%s' "$DENY_IN" | bash "$REPO/.uplift/sandbox/adapters/codex/hooks/pre-tool-use.sh" 2>&1)
ec=$?
assert_exit "installed deny hook exits 0" 0 "$ec"
assert_contains "installed deny is JSON" "\"permissionDecision\":\"deny\"" "$OUT"

echo "== codex-sandbox launcher runs Codex inside installed worktree =="
FAKE_BIN="$FIXTURE_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codex" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -C)
      printf '%s' "$2" > "$CODEX_FAKE_CWD"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
exit 0
SH
chmod +x "$FAKE_BIN/codex"

RUN_SESSION="t22-launcher"
FAKE_CWD="$FIXTURE_ROOT/fake-cwd.txt"
OUT=$(PATH="$FAKE_BIN:$PATH" CODEX_FAKE_CWD="$FAKE_CWD" \
  bash "$REPO/.uplift/sandbox/adapters/codex/bin/codex-sandbox.sh" \
    --repo "$REPO" --session "$RUN_SESSION" -- --fake-prompt 2>&1)
ec=$?
assert_exit "launcher exits with codex status" 0 "$ec"
assert_file_exists "fake codex received cwd" "$FAKE_CWD"
assert_contains "fake codex cwd is sandbox" ".uplift/sandbox/worktrees/wt-$RUN_SESSION" "$(cat "$FAKE_CWD")"
assert_dir_absent "empty launcher sandbox reaped" "$REPO/.uplift/sandbox/worktrees/wt-$RUN_SESSION"
assert_file_absent "empty launcher marker reaped" "$REPO/.git/sandbox-markers/$RUN_SESSION"

test_summary
