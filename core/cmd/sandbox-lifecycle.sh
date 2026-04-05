#!/bin/bash
# sandbox-lifecycle.sh — periodic cleanup of sandbox worktrees.
#
# Usage:
#   sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>]
#
# Contract:
#   --repo           main repo path
#   --ttl            marker TTL for stale-reclaim (default 3600)
#   --branch-prefix  glob for orphan branch sweep (default 'sandbox-session-*')
#
# Phases:
#   1. git worktree prune (stale metadata)
#   2. Prune expired markers (TTL — reclaims crashed sessions)
#   3. For each linked worktree, try sb_wt_remove_if_merged with marker protection
#   4. Sweep orphan branches matching --branch-prefix
#   5. Sweep empty residual dirs under .sandbox/worktrees/
#
# Always exits 0. Prints a multi-line report to stdout summarizing actions.
# No-op silently if there is nothing to do.

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"
. "$ROOT/core/lib/ttl-marker.sh"
. "$ROOT/core/lib/wt-cleanup.sh"

usage() { printf 'usage: sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>]\n' >&2; exit 2; }

REPO=""; TTL=3600; PREFIX="sandbox-session-*"; WT_DIR=".sandbox/worktrees"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --ttl)           TTL="$2"; shift 2 ;;
    --branch-prefix) PREFIX="$2"; shift 2 ;;
    --worktrees-dir) WT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$REPO" ] && usage

GIT_ROOT=$(sb_git_root "$REPO") || exit 0
GIT_COMMON=$(git -C "$GIT_ROOT" rev-parse --git-common-dir 2>/dev/null)
case "$GIT_COMMON" in
  /*|[A-Za-z]:*) ;;
  *) GIT_COMMON="$GIT_ROOT/$GIT_COMMON" ;;
esac
MAIN_BRANCH=$(sb_main_branch "$GIT_ROOT")
MARKERS_DIR="$GIT_COMMON/sandbox-markers"

REMOVED=0
LINES=""

# Phase 1: prune stale git worktree metadata
sb_wt_prune_metadata "$GIT_ROOT"

# Phase 2: TTL reclaim — drop markers older than $TTL (crashed sessions)
if [ -d "$MARKERS_DIR" ]; then
  sb_marker_prune_stale "$MARKERS_DIR/*" "$TTL"
fi

# Phase 3: try to clean each linked worktree
# Collect marker-protected branches (still-alive sessions)
PROTECTED=""
if [ -d "$MARKERS_DIR" ]; then
  for mf in "$MARKERS_DIR"/*; do
    [ -f "$mf" ] || continue
    v=$(sb_marker_read_value "$mf")
    [ -n "$v" ] && PROTECTED="$PROTECTED $v "
  done
fi

while IFS="	" read -r WT_PATH WT_BRANCH; do
  [ -z "$WT_PATH" ] && continue
  [ "$WT_PATH" = "$GIT_ROOT" ] && continue
  [ "$WT_BRANCH" = "$MAIN_BRANCH" ] && continue

  # Respect marker protection
  case "$PROTECTED" in
    *" $WT_BRANCH "*) continue ;;
  esac

  status=$(sb_wt_remove_if_merged "$GIT_ROOT" "$WT_PATH" "$WT_BRANCH" "$MAIN_BRANCH" "stale") || true
  case "$status" in
    "REMOVED "*) REMOVED=$((REMOVED + 1)); LINES="${LINES}${status}\n" ;;
    "PRESERVED "*) LINES="${LINES}${status}\n" ;;
  esac
done <<SBL
$(sb_list_worktrees "$GIT_ROOT")
SBL

# Phase 4: orphan branches matching prefix
ORPHAN_OUT=$(sb_wt_sweep_orphan_branches "$GIT_ROOT" "$PREFIX" "$MAIN_BRANCH")
[ -n "$ORPHAN_OUT" ] && LINES="${LINES}${ORPHAN_OUT}\n"

# Phase 5: residual directory sweep
SB_WT_DIR="$GIT_ROOT/$WT_DIR"
if [ -d "$SB_WT_DIR" ]; then
  RESIDUAL=$(sb_wt_sweep_residual_dirs "$SB_WT_DIR")
  [ -n "$RESIDUAL" ] && LINES="${LINES}${RESIDUAL}\n"
fi

if [ -n "$LINES" ]; then
  printf 'sandbox-lifecycle: cleaned=%d\n' "$REMOVED"
  printf '%b' "$LINES"
fi
exit 0
