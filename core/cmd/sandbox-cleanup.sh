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
. "$ROOT/core/lib/ttl-marker.sh"
. "$ROOT/core/lib/cleanup-log.sh"

usage() { printf 'usage: sandbox-cleanup.sh --repo <dir> --session <id>\n' >&2; exit 2; }

REPO=""; SESSION=""; TRUST_DEAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)       REPO="$2"; shift 2 ;;
    --session)    SESSION="$2"; shift 2 ;;
    --trust-dead) TRUST_DEAD=1; shift ;;
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
_init_head=$(sb_marker_read_initial_head "$MARKER")
_cur_head=$(git -C "$SB" rev-parse HEAD 2>/dev/null || true)

# Critical guard (mirrors sandbox-lifecycle.sh Phase 3): a fresh session whose
# branch has never diverged from main (HEAD == initial_head) looks structurally
# identical to a completed+merged session at the branch level — merge-base says
# "ancestor", scan-uncommitted says "clean". Without the initial_head check,
# Phase 2 releases the marker of a live session that simply hasn't committed
# yet, and lifecycle's Phase 3 reap destroys the worktree while the user is
# still working in it. Legacy markers (empty initial_head) also fall through
# to TTL safety net.
# When --trust-dead is passed (session-end.sh), the session has already
# ended � skip the initial_head guard. An empty session that terminated
# should self-reap (no live process to destroy). Without --trust-dead
# (heartbeat parent-death cleanup), keep the guard: parent-death detection
# can false-positive and destroying a live worktree is much worse than a
# bounded orphan.
_fresh_guard_ok=1
if [ "$TRUST_DEAD" != "1" ]; then
  if [ -z "$_init_head" ] || [ -z "$_cur_head" ] || [ "$_cur_head" = "$_init_head" ]; then
    _fresh_guard_ok=0
  fi
fi

if [ "$_can_commit" = 1 ] \
   && [ -n "$_main" ] \
   && [ "$_fresh_guard_ok" = 1 ] \
   && git -C "$SB" merge-base --is-ancestor "$BRANCH" "$_main" 2>/dev/null \
   && sb_scan_uncommitted "$SB" --ignore-deletions >/dev/null 2>&1; then
  rm -f "$MARKER" "${MARKER}.hb" 2>/dev/null || true
  sb_cleanup_log "$ROOT" "RELEASE" "$SESSION" "$BRANCH" "cleanup-phase2-self-release"
fi

# --- Phase 3: lifecycle reap -----------------------------------------------
#
# Runs after self-release so that, when the marker has just been dropped,
# lifecycle actually removes the worktree in this pass. For sessions that
# kept their marker, lifecycle's live-marker protection skips them.
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1 || true

exit 0
