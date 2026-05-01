#!/bin/bash
# layout.sh — adapter helpers for source-tree vs installed sandbox layout.

sandbox_adapter_root() {
  local adapter_dir="$1"
  if [ -d "$adapter_dir/../core/cmd" ]; then
    (cd "$adapter_dir/.." && pwd)
    return
  fi
  if [ -d "$adapter_dir/../../core/cmd" ]; then
    (cd "$adapter_dir/../.." && pwd)
    return
  fi
  if [ -d "$adapter_dir/../../../core/cmd" ]; then
    (cd "$adapter_dir/../../.." && pwd)
    return
  fi
  (cd "$adapter_dir/../.." && pwd)
}

sandbox_adapter_worktrees_dir() {
  local repo="$1" sandbox_root="$2"
  local repo_norm root_norm
  if [ -n "${WORKTREE_SANDBOX_WORKTREES_DIR:-}" ]; then
    printf '%s' "$WORKTREE_SANDBOX_WORKTREES_DIR"
    return
  fi
  if [ -n "${OPENCODE_SANDBOX_WORKTREES_DIR:-}" ]; then
    printf '%s' "$OPENCODE_SANDBOX_WORKTREES_DIR"
    return
  fi
  if command -v cygpath >/dev/null 2>&1; then
    repo_norm=$(cygpath -am "$repo" 2>/dev/null || printf '%s' "$repo")
    root_norm=$(cygpath -am "$sandbox_root" 2>/dev/null || printf '%s' "$sandbox_root")
  else
    repo_norm="$repo"
    root_norm="$sandbox_root"
  fi
  case "$root_norm" in
    "$repo_norm"/*)
      printf '%s/worktrees' "${root_norm#"$repo_norm"/}"
      ;;
    *)
      printf '.sandbox/worktrees'
      ;;
  esac
}

sandbox_adapter_branch_prefix() {
  printf '%s' "${WORKTREE_SANDBOX_BRANCH_PREFIX:-${OPENCODE_SANDBOX_BRANCH_PREFIX:-wt}}"
}

sandbox_adapter_branch_glob() {
  local prefix
  prefix=$(sandbox_adapter_branch_prefix)
  case "$prefix" in
    *'*'*) printf '%s' "$prefix" ;;
    *)     printf '%s-*' "$prefix" ;;
  esac
}
