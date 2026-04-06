#!/bin/bash
# git-context.sh — git repo and worktree introspection primitives.
#
# Public functions (all take optional <dir> defaulting to '.'):
#   sb_git_root        echo main repo root; exit 1 if not a repo
#   sb_git_common_dir  echo absolute git common dir; exit 1 if not a repo
#   sb_is_worktree     exit 0 linked wt / 1 main / 2 not a repo
#   sb_has_in_progress_operation  exit 0 if merge/rebase in progress, 1 if clean
#   sb_main_branch     echo origin/HEAD target or fallback "main"
#   sb_list_worktrees  echo "path<TAB>branch" lines, one per worktree

sb_git_root() {
  local dir="${1:-.}"
  local common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  if [ "$common" = ".git" ]; then
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null || return 1
  else
    local abs
    if [ -d "$common" ]; then
      abs=$(cd "$dir" && cd "$common" && pwd 2>/dev/null)
    else
      abs=$(cd "$dir" && pwd 2>/dev/null)
    fi
    (cd "$abs/.." 2>/dev/null && pwd) || return 1
  fi
}

sb_git_common_dir() {
  local dir="${1:-.}"
  local root common
  root=$(sb_git_root "$dir") || return 1
  common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) printf '%s' "$common" ;;
    *) printf '%s' "$root/$common" ;;
  esac
}

sb_is_worktree() {
  local dir="${1:-.}"
  local common
  common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 2
  [ "$common" = ".git" ] && return 1
  return 0
}

sb_has_in_progress_operation() {
  local dir="${1:-.}"
  local _mh _rh _ra _rm
  _mh=$(git -C "$dir" rev-parse --git-path MERGE_HEAD 2>/dev/null || true)
  _rh=$(git -C "$dir" rev-parse --git-path REBASE_HEAD 2>/dev/null || true)
  _ra=$(git -C "$dir" rev-parse --git-path rebase-apply 2>/dev/null || true)
  _rm=$(git -C "$dir" rev-parse --git-path rebase-merge 2>/dev/null || true)
  { [ -n "$_mh" ] && [ -f "$_mh" ]; } \
    || { [ -n "$_rh" ] && [ -f "$_rh" ]; } \
    || { [ -n "$_ra" ] && [ -d "$_ra" ]; } \
    || { [ -n "$_rm" ] && [ -d "$_rm" ]; }
}

sb_main_branch() {
  local dir="${1:-.}"
  local b
  b=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
  if [ -z "$b" ]; then
    for cand in main master; do
      if git -C "$dir" show-ref --verify --quiet "refs/heads/$cand"; then
        b="$cand"
        break
      fi
    done
  fi
  printf '%s' "${b:-main}"
}

sb_list_worktrees() {
  local dir="${1:-.}"
  git -C "$dir" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{ path=substr($0, 10) }
    /^branch /{ br=substr($0, 19); if (path != "") printf "%s\t%s\n", path, br; path="" }
  '
}
