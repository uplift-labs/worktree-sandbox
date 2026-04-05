#!/bin/bash
# sandbox-init.sh — create a session sandbox worktree with a seeded TASK.md.
#
# Usage:
#   sandbox-init.sh --repo <dir> --session <id> [--base <branch>]
#
# Contract:
#   --repo    path to the main repo (must be a git repo, on main/master)
#   --session unique session identifier; used for branch name + marker file
#   --base    base branch to fork from (default: detected via sb_main_branch)
#
# Behaviour:
#   - If the current dir is already inside a linked worktree, no-op (exit 0).
#   - If the session already has a fresh marker (TTL 24h), no-op.
#   - Otherwise: create <repo>/.sandbox/worktrees/<session>, a branch
#     sandbox-session-<short-id>, seed TASK.md template, write marker.
#   - Echoes the absolute sandbox path to stdout on success.
#
# Exit:
#   0 = success (path on stdout) OR benign no-op (no output)
#   1 = hard failure (detection, git error — message on stdout)
#   2 = bad usage

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/ttl-marker.sh"
. "$ROOT/core/lib/task-md.sh"

MARKER_TTL=86400  # 24h

usage() { printf 'usage: sandbox-init.sh --repo <dir> --session <id> [--base <branch>] [--worktrees-dir <rel>] [--branch-prefix <prefix>]\n' >&2; exit 2; }

REPO=""; SESSION=""; BASE=""
WT_DIR=".sandbox/worktrees"
BR_PREFIX="sandbox-session"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)           REPO="$2"; shift 2 ;;
    --session)        SESSION="$2"; shift 2 ;;
    --base)           BASE="$2"; shift 2 ;;
    --worktrees-dir)  WT_DIR="$2"; shift 2 ;;
    --branch-prefix)  BR_PREFIX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$REPO" ] && usage
[ -z "$SESSION" ] && usage

# Resolve repo root, guard against running inside a linked worktree
if ! sb_is_worktree "$REPO" >/dev/null 2>&1; then
  # Return code 2 = not a repo; 1 = main working tree (ok to create here)
  case "$?" in
    2) printf 'not a git repository: %s\n' "$REPO"; exit 1 ;;
  esac
fi
# sb_is_worktree returns 0 for linked, 1 for main, 2 for non-repo
if sb_is_worktree "$REPO" >/dev/null 2>&1; then
  # Already inside a linked worktree — refuse nesting
  printf 'refusing to nest: %s is already a linked worktree\n' "$REPO"
  exit 1
fi

GIT_ROOT=$(sb_git_root "$REPO") || { printf 'cannot resolve git root: %s\n' "$REPO"; exit 1; }
GIT_COMMON=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)
case "$GIT_COMMON" in
  /*|[A-Za-z]:*) ;;
  *) GIT_COMMON="$GIT_ROOT/$GIT_COMMON" ;;
esac

# Only run on protected branches (main/master). Other branches are already
# feature-ish and do not need sandboxing.
CURRENT=$(git -C "$GIT_ROOT" branch --show-current 2>/dev/null)
case "$CURRENT" in main|master) ;; *) exit 0 ;; esac

[ -z "$BASE" ] && BASE=$(sb_main_branch "$GIT_ROOT")

SHORT=$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9-' '-' | cut -c1-16)
WT_BRANCH="$BR_PREFIX-$SHORT"
WT_PATH="$GIT_ROOT/$WT_DIR/$WT_BRANCH"

MARKER="$GIT_COMMON/sandbox-markers/$SESSION"

# TTL check — fresh marker means this session already owns a sandbox
if sb_marker_is_fresh "$MARKER" "$MARKER_TTL"; then
  existing=$(sb_marker_read_value "$MARKER")
  if [ -n "$existing" ] && [ -d "$GIT_ROOT/$WT_DIR/$existing" ]; then
    printf '%s\n' "$GIT_ROOT/$WT_DIR/$existing"
    exit 0
  fi
fi

mkdir -p "$(dirname "$WT_PATH")" 2>/dev/null

# Create worktree — retry once without -b in case branch survives from crashed session
if ! git -C "$GIT_ROOT" worktree add "$WT_PATH" -b "$WT_BRANCH" "$BASE" >/dev/null 2>&1; then
  if ! git -C "$GIT_ROOT" worktree add "$WT_PATH" "$WT_BRANCH" >/dev/null 2>&1; then
    printf 'worktree creation failed\n'
    exit 1
  fi
fi

sb_marker_write "$MARKER" "$WT_BRANCH"

# Seed TASK.md template (delegated to task-md.sh — single source of truth)
sb_task_seed_placeholder "$WT_PATH"

printf '%s\n' "$WT_PATH"
exit 0
