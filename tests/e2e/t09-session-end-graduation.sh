#!/bin/bash
# t09 — SessionEnd durability + housekeeping (commit-only, no auto-merge).
# Covers:
#   - Multiple Stop turns with a clean sandbox keep the sandbox alive.
#   - SessionEnd reason=clear / compact are heartbeat-only.
#   - SessionEnd reason=prompt_input_exit captures pending work as a commit
#     on the sandbox branch, WITHOUT merging into main.
#   - SessionEnd skips commit when the tree is already clean.
#   - In-progress merge state blocks the capture-commit (graceful skip).
#   - After a manual merge, lifecycle reaps the now merged+clean sandbox
#     (Phase 3) on its next pass (guarded by live-marker protection, so the
#     marker must be absent / stale first).
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
LIFECYCLE="$ROOT/core/cmd/sandbox-lifecycle.sh"

# Bootstrap: start a session.
START_IN=$(printf '{"session_id":"%s","source":"startup"}' "$SESSION")
printf '%s' "$START_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" >/dev/null 2>&1
SB_PATH="$REPO/.sandbox/worktrees/sandbox-session-$SESSION"
MARKER="$REPO/.git/sandbox-markers/$SESSION"
BRANCH="sandbox-session-$SESSION"
assert_dir_exists "sandbox created" "$SB_PATH"

echo "== multi-turn: Stop heartbeat keeps sandbox alive across turns =="
echo "payload" > "$SB_PATH/feature.txt"
(cd "$SB_PATH" && git add feature.txt && git commit -q -m "feat: payload")

STOP_IN=$(printf '{"session_id":"%s"}' "$SESSION")
for turn in 1 2 3; do
  OUT=$(printf '%s' "$STOP_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$STOP_HOOK" 2>&1)
  ec=$?
  assert_exit "Stop turn $turn exits 0" 0 "$ec"
  assert_eq "Stop turn $turn no output" "" "$OUT"
  assert_dir_exists "sandbox alive after turn $turn" "$SB_PATH"
  assert_file_exists "marker alive after turn $turn" "$MARKER"
  assert_file_absent "main untouched after turn $turn" "$REPO/feature.txt"
done

echo "== SessionEnd reason=clear is heartbeat-only =="
CLEAR_IN=$(printf '{"session_id":"%s","reason":"clear"}' "$SESSION")
TIP_BEFORE=$(git -C "$SB_PATH" rev-parse HEAD)
printf '%s' "$CLEAR_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
assert_eq "no commit created on clear" "$TIP_BEFORE" "$(git -C "$SB_PATH" rev-parse HEAD)"
assert_dir_exists "sandbox preserved on clear" "$SB_PATH"
assert_file_absent "main untouched on clear" "$REPO/feature.txt"

echo "== SessionEnd reason=compact is heartbeat-only =="
COMPACT_IN=$(printf '{"session_id":"%s","reason":"compact"}' "$SESSION")
printf '%s' "$COMPACT_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
assert_eq "no commit created on compact" "$TIP_BEFORE" "$(git -C "$SB_PATH" rev-parse HEAD)"
assert_dir_exists "sandbox preserved on compact" "$SB_PATH"

echo "== SessionEnd real termination: clean tree → no commit, no merge, sandbox alive =="
END_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$SESSION")
printf '%s' "$END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
assert_eq "clean tree → no new commit" "$TIP_BEFORE" "$(git -C "$SB_PATH" rev-parse HEAD)"
assert_dir_exists "sandbox alive after clean SessionEnd" "$SB_PATH"
assert_file_exists "marker alive after clean SessionEnd" "$MARKER"
assert_file_absent "main still untouched" "$REPO/feature.txt"

echo "== SessionEnd real termination: pending work is captured as commit, main untouched =="
echo "new work" > "$SB_PATH/new.txt"
echo "modify" >> "$SB_PATH/feature.txt"
printf '%s' "$END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
TIP_AFTER=$(git -C "$SB_PATH" rev-parse HEAD)
assert_contains "new commit created" "$TIP_AFTER" "$(git -C "$SB_PATH" rev-parse HEAD)"
# Capture-commit subject.
LAST_SUBJ=$(git -C "$SB_PATH" log -1 --format=%s)
assert_contains "commit subject mentions capture" "capture pending work" "$LAST_SUBJ"
# Commit contains new.txt and feature.txt.
CHANGED=$(git -C "$SB_PATH" show --name-only --format='' HEAD)
assert_contains "new.txt in capture commit" "new.txt" "$CHANGED"
assert_contains "feature.txt in capture commit" "feature.txt" "$CHANGED"
# Main branch is still untouched — the whole point of the refactor.
assert_file_absent "main never got feature.txt" "$REPO/feature.txt"
assert_file_absent "main never got new.txt" "$REPO/new.txt"
# Sandbox is alive.
assert_dir_exists "sandbox alive after capture SessionEnd" "$SB_PATH"
assert_file_exists "marker alive after capture SessionEnd" "$MARKER"

echo "== in-progress merge blocks capture-commit gracefully =="
# Set up a second branch to merge into the sandbox branch, producing conflict.
(cd "$SB_PATH" && git checkout -q -b conflict-branch "$BRANCH"^)
echo "conflict-a" > "$SB_PATH/feature.txt"
(cd "$SB_PATH" && git add feature.txt && git commit -q -m "conflicting change")
(cd "$SB_PATH" && git checkout -q "$BRANCH")
# Intentionally start a merge that will conflict, leaving MERGE_HEAD.
git -C "$SB_PATH" merge --no-commit conflict-branch >/dev/null 2>&1 || true
MERGE_HEAD_PATH=$(git -C "$SB_PATH" rev-parse --git-path MERGE_HEAD)
assert_file_exists "MERGE_HEAD exists" "$MERGE_HEAD_PATH"
TIP_MERGE_BEFORE=$(git -C "$SB_PATH" rev-parse HEAD)
OUT=$(printf '%s' "$END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" 2>&1)
ec=$?
assert_exit "SessionEnd exits 0 on in-progress merge" 0 "$ec"
assert_eq "HEAD unchanged — no commit attempted" "$TIP_MERGE_BEFORE" "$(git -C "$SB_PATH" rev-parse HEAD)"
assert_dir_exists "sandbox still alive" "$SB_PATH"
# Clean up the merge state for the next phase.
git -C "$SB_PATH" merge --abort >/dev/null 2>&1 || true

echo "== manual merge + lifecycle reaps the merged+clean sandbox =="
# User merges the branch manually.
(cd "$REPO" && git merge "$BRANCH" --no-edit >/dev/null 2>&1)
assert_file_exists "work landed in main after manual merge" "$REPO/feature.txt"
# Drop the marker so lifecycle's live-marker protection does not skip.
rm -f "$MARKER"
bash "$LIFECYCLE" --repo "$REPO" >/dev/null 2>&1
assert_dir_absent "merged sandbox reaped by lifecycle" "$SB_PATH"

echo "== SessionEnd fast-path: merged+clean branch self-reaps within the same hook =="
# Fresh session. The fast-path in session-end.sh should release the marker
# if (a) branch is an ancestor of main and (b) scan-uncommitted is clean
# and (c) no in-progress merge/rebase, and lifecycle (called right after)
# must then remove the worktree in the same invocation — the user
# should NOT see a lingering empty sandbox after closing the host tool.
FP_SESSION="t09-fp1"
FP_START_IN=$(printf '{"session_id":"%s","source":"startup"}' "$FP_SESSION")
printf '%s' "$FP_START_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" >/dev/null 2>&1
FP_SB="$REPO/.sandbox/worktrees/sandbox-session-$FP_SESSION"
FP_MARKER="$REPO/.git/sandbox-markers/$FP_SESSION"
FP_BRANCH="sandbox-session-$FP_SESSION"
assert_dir_exists "fast-path sandbox created" "$FP_SB"
assert_file_exists "fast-path marker created" "$FP_MARKER"
# Real work + merge it into main, so branch becomes an ancestor of main.
echo "fp-payload" > "$FP_SB/fp.txt"
(cd "$FP_SB" && git add fp.txt && git commit -q -m "feat: fp payload")
(cd "$REPO" && git merge "$FP_BRANCH" --no-edit >/dev/null 2>&1)
assert_file_exists "fp work landed in main" "$REPO/fp.txt"
# Real SessionEnd termination on clean+merged sandbox:
FP_END_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$FP_SESSION")
printf '%s' "$FP_END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
# Fast-path should have removed the marker...
assert_file_absent "fast-path dropped own marker" "$FP_MARKER"
# ...and lifecycle (invoked right after in the same hook) should have
# removed the worktree itself — no second lifecycle pass required.
assert_dir_absent "fast-path self-reaped worktree in the same hook" "$FP_SB"

echo "== SessionEnd fast-path: empty session (no commits) self-reaps its worktree =="
# Regression: user-reported bug. Open session, do nothing, close. The branch
# tip equals main tip (trivially an ancestor) and the worktree is clean.
# Fast-path must fire AND lifecycle must immediately reap the worktree.
EMPTY_SESSION="t09-empty"
EMPTY_START_IN=$(printf '{"session_id":"%s","source":"startup"}' "$EMPTY_SESSION")
printf '%s' "$EMPTY_START_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" >/dev/null 2>&1
EMPTY_SB="$REPO/.sandbox/worktrees/sandbox-session-$EMPTY_SESSION"
EMPTY_MARKER="$REPO/.git/sandbox-markers/$EMPTY_SESSION"
assert_dir_exists "empty sandbox created" "$EMPTY_SB"
assert_file_exists "empty sandbox marker created" "$EMPTY_MARKER"
# Sanity: branch tip == main tip (no commits made in the session).
EMPTY_TIP=$(git -C "$EMPTY_SB" rev-parse HEAD)
MAIN_TIP=$(git -C "$REPO" rev-parse HEAD)
assert_eq "branch tip equals main tip" "$MAIN_TIP" "$EMPTY_TIP"
# User closes the session without doing anything.
EMPTY_END_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$EMPTY_SESSION")
printf '%s' "$EMPTY_END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
# Fast-path must have released the marker...
assert_file_absent "empty-session fast-path dropped marker" "$EMPTY_MARKER"
# ...and lifecycle in the same hook must have removed the worktree.
assert_dir_absent "empty sandbox self-reaped in the same hook" "$EMPTY_SB"

echo "== SessionEnd fast-path: unmerged branch keeps marker (safety-net) =="
# Same setup but do NOT merge the branch. Fast-path must NOT fire.
FP2_SESSION="t09-fp2"
FP2_START_IN=$(printf '{"session_id":"%s","source":"startup"}' "$FP2_SESSION")
printf '%s' "$FP2_START_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$ROOT/adapters/claude-code/hooks/session-start.sh" >/dev/null 2>&1
FP2_SB="$REPO/.sandbox/worktrees/sandbox-session-$FP2_SESSION"
FP2_MARKER="$REPO/.git/sandbox-markers/$FP2_SESSION"
echo "fp2-payload" > "$FP2_SB/fp2.txt"
(cd "$FP2_SB" && git add fp2.txt && git commit -q -m "feat: fp2 payload")
# Branch is ahead of main, NOT an ancestor → fast-path skipped.
FP2_END_IN=$(printf '{"session_id":"%s","reason":"prompt_input_exit"}' "$FP2_SESSION")
printf '%s' "$FP2_END_IN" | CLAUDE_PROJECT_DIR="$REPO" bash "$END_HOOK" >/dev/null 2>&1
assert_file_exists "unmerged fast-path keeps marker" "$FP2_MARKER"
assert_dir_exists "unmerged fast-path keeps sandbox" "$FP2_SB"

test_summary
