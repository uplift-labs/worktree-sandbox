#!/bin/bash
# t09 — SessionEnd graduation hook.
# Covers the Stop/SessionEnd split (plan: virtual-finding-hopcroft):
#   - Multiple Stop turns with a fully-checked TASK.md keep the sandbox alive.
#   - SessionEnd with a failing gate leaves the sandbox alive (can't block exit).
#   - SessionEnd with reason=other completes the graduate.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t09")
SESSION="t09-graduation"
STOP_HOOK="$ROOT/adapters/claude-code/hooks/stop.sh"
END_HOOK="$ROOT/adapters/claude-code/hooks/session-end.sh"

# Bootstrap: start a session.
START_IN=$(printf '{"session_id":"%s","source":"startup"}' "$SESSION")
printf '%s' "$START_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" >/dev/null 2>&1
SB_PATH="$REPO/.sandbox/worktrees/sandbox-session-$SESSION"
MARKER="$REPO/.git/sandbox-markers/$SESSION"
assert_dir_exists "sandbox created" "$SB_PATH"

echo "== multi-turn: Stop with passing gate keeps sandbox alive across turns =="
# Commit real work so scan-uncommitted is happy.
echo "payload" > "$SB_PATH/feature.txt"
(cd "$SB_PATH" && git add feature.txt && git commit -q -m "feat: payload")
cat > "$SB_PATH/TASK.md" << 'TM'
---
created: 2026-04-05
purpose: t09 multi-turn test
---
## Tasks
- [x] Ship payload
TM

STOP_IN=$(printf '{"session_id":"%s"}' "$SESSION")
for turn in 1 2 3; do
  OUT=$(printf '%s' "$STOP_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$STOP_HOOK" 2>&1)
  ec=$?
  assert_exit "Stop turn $turn exits 0" 0 "$ec"
  assert_not_contains "Stop turn $turn no block" "\"decision\":\"block\"" "$OUT"
  assert_dir_exists "sandbox alive after turn $turn" "$SB_PATH"
  assert_file_exists "marker alive after turn $turn" "$MARKER"
  assert_file_absent "main untouched after turn $turn" "$REPO/feature.txt"
done

echo "== SessionEnd: gate failure leaves sandbox alive =="
# Introduce an untracked file — gate blocks on ??.
echo "scratch" > "$SB_PATH/scratch.tmp"
END_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$SESSION")
OUT=$(printf '%s' "$END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" 2>&1)
ec=$?
assert_exit "SessionEnd exits 0 on gate fail" 0 "$ec"
assert_dir_exists "sandbox preserved when gate fails" "$SB_PATH"
assert_file_exists "marker preserved when gate fails" "$MARKER"
assert_file_absent "main untouched when gate fails" "$REPO/feature.txt"

echo "== SessionEnd reason=clear is no-op even with passing gate =="
rm -f "$SB_PATH/scratch.tmp"
CLEAR_IN=$(printf '{"session_id":"%s","reason":"clear"}' "$SESSION")
OUT=$(printf '%s' "$CLEAR_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" 2>&1)
ec=$?
assert_exit "SessionEnd clear exits 0" 0 "$ec"
assert_dir_exists "sandbox preserved on clear" "$SB_PATH"
assert_file_exists "marker preserved on clear" "$MARKER"
assert_file_absent "main untouched on clear" "$REPO/feature.txt"

echo "== SessionEnd reason=prompt_input_exit graduates cleanly =="
OUT=$(printf '%s' "$END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" 2>&1)
ec=$?
assert_exit "SessionEnd graduate exits 0" 0 "$ec"
assert_file_exists "work reached main" "$REPO/feature.txt"
assert_dir_absent "sandbox reaped" "$SB_PATH"
assert_file_absent "marker reaped" "$MARKER"

test_summary
