#!/bin/bash
# t21 — Codex adapter smoke test.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t21")
SESSION="t21-codex"

echo "== session-start creates sandbox and returns Codex context =="
INPUT=$(printf '{"session_id":"%s","source":"startup","cwd":"%s"}' "$SESSION" "$REPO")
OUT=$(printf '%s' "$INPUT" | bash "$ROOT/adapters/codex/hooks/session-start.sh" 2>&1)
ec=$?
assert_exit "session-start exits 0" 0 "$ec"
assert_contains "context mentions sandbox" "worktree-sandbox active" "$OUT"
assert_contains "context has SessionStart shape" "hookSpecificOutput" "$OUT"
assert_dir_exists "sandbox dir exists" "$REPO/.sandbox/worktrees/wt-$SESSION"
assert_file_exists "marker written" "$REPO/.git/sandbox-markers/$SESSION"

SB_PATH="$REPO/.sandbox/worktrees/wt-$SESSION"

echo "== pre-tool-use: apply_patch from sandbox cwd is allowed =="
ALLOW_IN=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"apply_patch"}' "$SESSION" "$SB_PATH")
OUT=$(printf '%s' "$ALLOW_IN" | bash "$ROOT/adapters/codex/hooks/pre-tool-use.sh" 2>&1)
ec=$?
assert_exit "allow exits 0" 0 "$ec"
assert_eq "allow produces no output" "" "$OUT"

echo "== pre-tool-use: apply_patch from main cwd is denied =="
DENY_IN=$(printf '{"session_id":"%s","cwd":"%s","tool_name":"apply_patch"}' "$SESSION" "$REPO")
OUT=$(printf '%s' "$DENY_IN" | bash "$ROOT/adapters/codex/hooks/pre-tool-use.sh" 2>&1)
ec=$?
assert_exit "deny hook exits 0" 0 "$ec"
assert_contains "deny output is hook JSON" "hookSpecificOutput" "$OUT"
assert_contains "permission denied" "\"permissionDecision\":\"deny\"" "$OUT"

echo "== stop: heartbeat JSON only =="
STOP_IN=$(printf '{"session_id":"%s","cwd":"%s","turn_id":"turn-1"}' "$SESSION" "$SB_PATH")
OUT=$(printf '%s' "$STOP_IN" | bash "$ROOT/adapters/codex/hooks/stop.sh" 2>&1)
ec=$?
assert_exit "stop exits 0" 0 "$ec"
assert_eq "stop returns continue JSON" '{"continue":true}' "$OUT"
assert_file_exists "marker preserved on Stop" "$REPO/.git/sandbox-markers/$SESSION"

test_summary
