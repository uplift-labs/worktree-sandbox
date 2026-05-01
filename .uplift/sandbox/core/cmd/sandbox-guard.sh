#!/bin/bash
# sandbox-guard.sh — path gate: is an edit allowed?
#
# Usage:
#   sandbox-guard.sh --session <id> --file <path> [--repo <dir>] [--worktrees-dir <rel>]
#
# Contract:
#   --session  session id (used to locate marker)
#   --file     absolute path the caller wants to edit
#   --repo     main repo path (default: current git common-dir parent)
#
# Behaviour:
#   1. If the session has no marker → exit 0 (no sandbox active → no restriction).
#   2. If the file is INSIDE the session's sandbox dir → exit 0 (allow).
#   3. If the file is anywhere in the main repo but outside sandbox → exit 1
#      (deny, print reason on stdout).
#   4. If the file is outside both the main repo and the sandbox → exit 0
#      (it is not this guard's business to gate foreign files).
#
# This command is deliberately path-only. It does not touch git history, branches,
# or make any decisions about protected branch state. The Claude Code adapter or
# git hook caller is responsible for wrapping this into their native deny format.
#
# Exit:
#   0 = allow
#   1 = deny (reason on stdout)
#   2 = bad usage

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/ttl-marker.sh"

usage() { printf 'usage: sandbox-guard.sh --session <id> --file <path> [--repo <dir>] [--worktrees-dir <rel>]\n' >&2; exit 2; }

SESSION=""; FILE=""; REPO=""; WT_DIR=".sandbox/worktrees"
while [ $# -gt 0 ]; do
  case "$1" in
    --session)       SESSION="$2"; shift 2 ;;
    --file)          FILE="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --worktrees-dir) WT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$SESSION" ] && usage
[ -z "$FILE" ]    && usage

# Normalize paths to forward slashes + lowercase for case-insensitive compare
# (Windows filesystems are case-insensitive; Linux/macOS are case-sensitive but
# lowercase compare still works for genuine matches).
_norm() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -am "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]'
  else
    printf '%s' "$1" | sed 's|\\|/|g' | tr -s '/' | tr '[:upper:]' '[:lower:]'
  fi
}

# Resolve repo root
if [ -z "$REPO" ]; then
  REPO=$(sb_git_root ".") || exit 0  # no git context → no restriction
fi
REPO_ROOT=$(sb_git_root "$REPO") || exit 0

GIT_COMMON=$(sb_git_common_dir "$REPO_ROOT") || exit 0

MARKER="$GIT_COMMON/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0  # no active sandbox → no restriction

WT_BRANCH=$(sb_marker_read_value "$MARKER")
[ -z "$WT_BRANCH" ] && exit 0

SB_PATH="$REPO_ROOT/$WT_DIR/$WT_BRANCH"

nf=$(_norm "$FILE")
nr=$(_norm "$REPO_ROOT")
ns=$(_norm "$SB_PATH")

case "$nf" in
  "$ns"/*) exit 0 ;;  # inside sandbox — allow
  "$ns")   exit 0 ;;  # exact sandbox root
  "$nr"/*|"$nr")
    printf 'sandbox-guard: edit blocked — session %s has sandbox at %s, but target is in main repo (%s). Edit the sandbox copy and merge via git.\n' \
      "$SESSION" "$SB_PATH" "$FILE"
    exit 1
    ;;
  *) exit 0 ;;  # outside both main repo and sandbox — not our business
esac
