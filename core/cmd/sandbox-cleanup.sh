#!/bin/bash
# sandbox-cleanup.sh — session cleanup: capture-commit + self-release + lifecycle.
#
# Usage:
#   sandbox-cleanup.sh --repo <dir> --session <id>
#
# Contract:
#   --repo     main repo path
#   --session  session identifier (marker filename under sandbox-markers/)
#
# Phases:
#   1. Capture-commit pending work in the session's sandbox worktree
#      (git add -A && git commit). Skipped when a merge/rebase is in progress
#      or HEAD is detached.
#   2. Self-release the session marker if the branch is already merged into
#      main AND the worktree is clean. This lets the lifecycle pass (Phase 3)
#      reap the worktree in the same invocation.
#   3. Invoke sandbox-lifecycle for a full cleanup pass (reaps this session's
#      worktree if marker was dropped, plus any other stale sandboxes).
#
# Callers:
#   - adapters/claude-code/hooks/session-end.sh (graceful exit)
#   - core/lib/heartbeat.sh (parent-death cleanup)
#
# Exit: always 0 (fail-open). Diagnostic output on stderr.

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"

usage() { printf 'usage: sandbox-cleanup.sh --repo <dir> --session <id>\n' >&2; exit 2; }

REPO=""; SESSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$REPO" ] && usage
[ -z "$SESSION" ] && usage

GIT_COMMON=$(sb_git_common_dir "$REPO") || exit 0
MARKER="$GIT_COMMON/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

BRANCH=$(awk '{print $1}' "$MARKER")
SB="$REPO/.sandbox/worktrees/$BRANCH"

[ -d "$SB" ] || exit 0

# --- Phase 1: capture-commit pending work in the session's sandbox ----------
#
# Guard against in-progress states where `git commit` would do something
# unexpected. Skip the commit phase in any of them; lifecycle still runs.
_can_commit=1
if sb_has_in_progress_operation "$SB"; then
  _can_commit=0
  printf '[sandbox] cleanup: in-progress merge/rebase in %s — skipping capture-commit.\n' "$BRANCH" >&2
fi
if [ "$_can_commit" = 1 ] && ! git -C "$SB" symbolic-ref -q HEAD >/dev/null 2>&1; then
  _can_commit=0
  printf '[sandbox] cleanup: detached HEAD in %s — skipping capture-commit.\n' "$BRANCH" >&2
fi

if [ "$_can_commit" = 1 ]; then
  git -C "$SB" add -A >/dev/null 2>&1 || true

  # Commit iff something is actually staged.
  if ! git -C "$SB" diff --cached --quiet >/dev/null 2>&1; then
    if ! git -C "$SB" commit -q -m "chore(sandbox-cleanup): capture pending work" >/dev/null 2>&1; then
      printf '[sandbox] cleanup: capture-commit failed on %s — sandbox left as-is.\n' "$BRANCH" >&2
    fi
  fi
fi

# --- Phase 2: self-release marker if merged+clean --------------------------
#
# If the branch is already an ancestor of main AND the worktree is clean
# AND there is no in-progress state, drop the marker so lifecycle (Phase 3)
# treats the worktree as unprotected and reaps it in the same pass.
#
# Any uncertainty falls through: marker stays, lifecycle's TTL safety-net
# handles cleanup later.
_main=$(sb_main_branch "$REPO" 2>/dev/null || true)
if [ "$_can_commit" = 1 ] \
   && [ -n "$_main" ] \
   && git -C "$SB" merge-base --is-ancestor "$BRANCH" "$_main" 2>/dev/null \
   && sb_scan_uncommitted "$SB" >/dev/null 2>&1; then
  rm -f "$MARKER" "${MARKER}.hb" 2>/dev/null || true
fi

# --- Phase 3: lifecycle reap -----------------------------------------------
#
# Runs after self-release so that, when the marker has just been dropped,
# lifecycle actually removes the worktree in this pass. For sessions that
# kept their marker, lifecycle's live-marker protection skips them.
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1 || true

exit 0
