#!/bin/bash
# session-end.sh — Claude Code SessionEnd hook wrapper.
# Fires on real session termination (/exit, Ctrl+D/C, SIGHUP, logout, idle).
#
# Responsibility: durability, not graduation.
#   1. Capture-commit any pending work in the current sandbox so nothing is
#      lost when the process exits. TASK.md is excluded from the commit
#      (scratchpad, must not pollute main on any future manual merge).
#   2. Invoke sandbox-lifecycle to reap *other* sandboxes whose branches
#      have already been merged into main and whose worktrees are clean.
#
# This hook does NOT merge the current session's branch into main. Merging
# is always a deliberate user action (`git merge <branch>` or the
# pre-merge-commit hook). Auto-merging on exit is too aggressive — the user
# may want to review, rebase, or discard.
#
# SessionEnd CANNOT block termination, so this script must be fast and
# idempotent. Any failure leaves the sandbox alive for the TTL safety-net
# in sandbox-lifecycle.sh (next SessionStart) to reclaim later.
#
# Reason branching:
#   clear   — /clear, context reset; session continues. Heartbeat only.
#   compact — compact restart; session continues. Heartbeat only.
#   other   — real termination. Capture-commit + lifecycle.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
REASON=$(json_field "reason" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

MARKER="$REPO/.git/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

BRANCH=$(awk '{print $1}' "$MARKER")
SB="$REPO/.sandbox/worktrees/$BRANCH"

# Non-terminating reasons: session is not actually ending — just heartbeat
# the marker and bail. No commit, no scan.
case "$REASON" in
  clear|compact)
    touch "$MARKER" 2>/dev/null
    exit 0
    ;;
esac

# Real termination path.
[ -d "$SB" ] || exit 0

# --- Phase 1: capture-commit pending work in the current sandbox ---------
#
# Guard against in-progress states where `git commit` would do something
# unexpected. Skip the commit phase in any of them; lifecycle still runs.
_can_commit=1
# Use git rev-parse --git-path so this works for linked worktrees (where
# .git is a file pointing into the main repo's worktrees/<name> dir, and
# MERGE_HEAD etc. live in that pointed-to dir, not in $SB/.git/).
_merge_head=$(git -C "$SB" rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
_rebase_head=$(git -C "$SB" rev-parse --git-path REBASE_HEAD 2>/dev/null || true)
_rebase_apply=$(git -C "$SB" rev-parse --git-path rebase-apply 2>/dev/null || true)
_rebase_merge=$(git -C "$SB" rev-parse --git-path rebase-merge 2>/dev/null || true)
if { [ -n "$_merge_head" ] && [ -f "$_merge_head" ]; } \
   || { [ -n "$_rebase_head" ] && [ -f "$_rebase_head" ]; } \
   || { [ -n "$_rebase_apply" ] && [ -d "$_rebase_apply" ]; } \
   || { [ -n "$_rebase_merge" ] && [ -d "$_rebase_merge" ]; }; then
  _can_commit=0
  printf '[sandbox] SessionEnd: in-progress merge/rebase in %s — skipping capture-commit.\n' "$BRANCH" >&2
fi
if [ "$_can_commit" = 1 ] && ! git -C "$SB" symbolic-ref -q HEAD >/dev/null 2>&1; then
  _can_commit=0
  printf '[sandbox] SessionEnd: detached HEAD in %s — skipping capture-commit.\n' "$BRANCH" >&2
fi

if [ "$_can_commit" = 1 ]; then
  # Stage everything, then unstage TASK.md. TASK.md is a per-session
  # scratchpad and must never enter the branch history.
  git -C "$SB" add -A >/dev/null 2>&1 || true
  git -C "$SB" reset -q -- TASK.md >/dev/null 2>&1 || true

  # Commit iff something is actually staged after the TASK.md unstage.
  if ! git -C "$SB" diff --cached --quiet >/dev/null 2>&1; then
    if ! git -C "$SB" commit -q -m "chore(session-end): capture pending work on exit" >/dev/null 2>&1; then
      printf '[sandbox] SessionEnd: capture-commit failed on %s — sandbox left as-is.\n' "$BRANCH" >&2
    fi
  fi
fi

# --- Phase 2: fast-path self-release for the current session -------------
#
# If our own branch is already merged into main AND the worktree is clean
# (scan-uncommitted excludes TASK.md) AND there is no in-progress
# merge/rebase/detached-HEAD state (_can_commit=1), drop our marker NOW
# so the lifecycle pass below treats our worktree as unprotected and
# reaps it in the same invocation — otherwise the empty/merged sandbox
# lingers on disk until the next SessionStart.
#
# The _can_commit gate protects against a rare-but-catastrophic case: a
# branch already merged into main via a different clone while the sandbox
# has a stuck rebase/merge. Without the gate we could reap a worktree
# mid-conflict-resolution.
#
# Any uncertainty (detached HEAD, missing main, dirty tree, unmerged
# branch, in-progress merge/rebase) falls through: the marker stays, and
# lifecycle's live-marker protection skips our branch so the TTL
# safety-net handles cleanup later.
_main=$(sb_main_branch "$REPO" 2>/dev/null || true)
if [ "$_can_commit" = 1 ] \
   && [ -n "$_main" ] \
   && git -C "$SB" merge-base --is-ancestor "$BRANCH" "$_main" 2>/dev/null \
   && sb_scan_uncommitted "$SB" >/dev/null 2>&1; then
  rm -f "$MARKER" 2>/dev/null || true
fi

# --- Phase 3: lifecycle reap of merged+clean sandboxes -------------------
#
# Runs after the fast-path so that, when our marker has just been dropped,
# Phase 3 of lifecycle actually removes our own worktree in this pass.
# For sessions that kept their marker, lifecycle's live-marker protection
# skips our branch as before.
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1 || true

exit 0
