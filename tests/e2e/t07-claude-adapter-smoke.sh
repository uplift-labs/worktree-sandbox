#!/bin/bash
# t07 — Claude Code adapter smoke test.
# Feeds native Claude JSON into each hook and asserts the output shape.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t07")
SESSION="t07-adapter"

echo "== session-start creates sandbox and prints banner =="
INPUT=$(printf '{"session_id":"%s","source":"startup"}' "$SESSION")
OUT=$(printf '%s' "$INPUT" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" 2>&1)
ec=$?
assert_exit "session-start exits 0" 0 "$ec"
assert_contains "banner has sandbox prefix" "\[sandbox\]" "$OUT"
assert_contains "banner shows path" "sandbox-session" "$OUT"
assert_dir_exists "sandbox dir exists" "$REPO/.sandbox/worktrees/sandbox-session-$SESSION"
assert_file_exists "marker written" "$REPO/.git/sandbox-markers/$SESSION"

echo "== pre-edit: file in sandbox is allowed (silent exit 0) =="
SB_PATH=$(ls -d "$REPO/.sandbox/worktrees/sandbox-session-$SESSION")
ALLOW_IN=$(printf '{"session_id":"%s","file_path":"%s/x.txt"}' "$SESSION" "$SB_PATH")
OUT=$(printf '%s' "$ALLOW_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/pre-edit.sh" 2>&1)
ec=$?
assert_exit "allow exits 0" 0 "$ec"
assert_eq "no stdout on allow" "" "$OUT"

echo "== pre-edit: file in main repo is denied with JSON =="
DENY_IN=$(printf '{"session_id":"%s","file_path":"%s/README.md"}' "$SESSION" "$REPO")
OUT=$(printf '%s' "$DENY_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/pre-edit.sh" 2>&1)
ec=$?
assert_exit "deny exits 0 (hook success)" 0 "$ec"
assert_contains "output is Claude hookSpecificOutput JSON" "hookSpecificOutput" "$OUT"
assert_contains "decision is deny" "\"permissionDecision\":\"deny\"" "$OUT"
assert_contains "reason present" "permissionDecisionReason" "$OUT"

echo "== stop: TASK.md placeholder blocks merge via decision:block JSON =="
# sandbox-init seeded a TODO TASK.md → merge-gate should fire
STOP_IN=$(printf '{"session_id":"%s"}' "$SESSION")
OUT=$(printf '%s' "$STOP_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/stop.sh" 2>&1)
ec=$?
assert_exit "stop exits 0" 0 "$ec"
assert_contains "decision block emitted" "\"decision\":\"block\"" "$OUT"
assert_contains "reason mentions TASK.md" "TASK.md" "$OUT"
# Sandbox must still exist after block
assert_dir_exists "sandbox preserved on block" "$SB_PATH"

echo "== stop: after filling TASK.md and committing real work, gate passes but sandbox stays alive =="
echo "work content" > "$SB_PATH/work.txt"
(cd "$SB_PATH" && git add work.txt && git commit -q -m "feat: add work")
cat > "$SB_PATH/TASK.md" << 'TM'
---
created: 2026-04-05
purpose: Smoke-test adapter
---
## Tasks
- [x] Add work file
TM
OUT=$(printf '%s' "$STOP_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/stop.sh" 2>&1)
ec=$?
assert_exit "stop exits 0 after fix" 0 "$ec"
assert_not_contains "no block on passing gate" "\"decision\":\"block\"" "$OUT"
# New invariant: Stop must NOT graduate. Sandbox, marker, and untouched main stay put.
assert_dir_exists "sandbox preserved on Stop" "$SB_PATH"
assert_file_exists "marker preserved on Stop" "$REPO/.git/sandbox-markers/$SESSION"
assert_file_absent "main untouched on Stop" "$REPO/work.txt"

echo "== session-end: reason=clear is a no-op (only heartbeat) =="
CLEAR_IN=$(printf '{"session_id":"%s","reason":"clear"}' "$SESSION")
OUT=$(printf '%s' "$CLEAR_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-end.sh" 2>&1)
ec=$?
assert_exit "session-end clear exits 0" 0 "$ec"
assert_dir_exists "sandbox preserved on clear" "$SB_PATH"
assert_file_exists "marker preserved on clear" "$REPO/.git/sandbox-markers/$SESSION"
assert_file_absent "main untouched on clear" "$REPO/work.txt"

echo "== session-end: reason=prompt_input_exit captures pending work WITHOUT merging =="
# Add an uncommitted file so SessionEnd has something to capture-commit.
echo "pending" > "$SB_PATH/pending.txt"
EXIT_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$SESSION")
OUT=$(printf '%s' "$EXIT_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-end.sh" 2>&1)
ec=$?
assert_exit "session-end exit exits 0" 0 "$ec"
# Durability: pending work is committed on the sandbox branch.
assert_file_exists "pending captured inside sandbox" "$SB_PATH/pending.txt"
BRANCH=$(awk '{print $1}' "$REPO/.git/sandbox-markers/$SESSION")
LAST_SUBJ=$(git -C "$SB_PATH" log -1 --format=%s "$BRANCH")
assert_contains "capture-commit subject" "capture pending work" "$LAST_SUBJ"
# No merge: main must still NOT have the files from the sandbox branch.
assert_file_absent "main still lacks work.txt" "$REPO/work.txt"
assert_file_absent "main still lacks pending.txt" "$REPO/pending.txt"
# Sandbox stays alive for the user to review + merge manually.
assert_dir_exists "sandbox preserved after SessionEnd" "$SB_PATH"
assert_file_exists "marker preserved after SessionEnd" "$REPO/.git/sandbox-markers/$SESSION"

echo "== after manual merge + lifecycle pass, the now-merged sandbox is reaped =="
# User merges manually.
(cd "$REPO" && git merge "$BRANCH" --no-edit >/dev/null 2>&1)
assert_file_exists "work landed in main after manual merge" "$REPO/work.txt"
# Remove this session's marker to simulate "session is gone" (in reality a
# second SessionEnd or a TTL-prune from a parallel session would do this).
rm -f "$REPO/.git/sandbox-markers/$SESSION"
# Now lifecycle Phase 3 has nothing protecting the merged+clean branch.
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1
assert_dir_absent "merged sandbox reaped by lifecycle" "$SB_PATH"

test_summary
