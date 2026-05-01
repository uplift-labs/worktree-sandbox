#!/bin/bash
# wt-cleanup.sh — worktree lifecycle cleanup primitives.
# Depends on scan-uncommitted.sh.
#
# Public functions:
#   sb_wt_prune_metadata <repo-dir>
#     git worktree prune — removes stale metadata for deleted worktrees.
#
#   sb_wt_remove_if_merged <repo-dir> <wt-path> <wt-branch> <main-branch> [detail]
#     Safety order:
#       1. merge-base ancestor check — not merged → preserve (exit 1)
#       2. scan_uncommitted — filesystem dirty → preserve (exit 2)
#       3. git worktree remove + branch -d
#     Exit codes:
#       0 = removed
#       1 = preserved (unmerged branch)
#       2 = preserved (dirty filesystem / live sandbox)
#       3 = preserved (merged but remove failed / locked)
#     Echoes a one-line status report on stdout.
#
#   sb_wt_sweep_orphan_branches <repo-dir> <prefix-glob> <main-branch>
#     Delete branches matching prefix that are merged and unreferenced.
#     Echoes one "REMOVED branch <name>" line per deletion.
#
#   sb_wt_sweep_residual_dirs <worktrees-parent-dir>
#     Remove empty subdirs without .git marker; preserve those with content.

sb_wt_prune_metadata() {
  local repo="$1"
  git -C "$repo" worktree prune 2>/dev/null || true
}

sb_wt_remove_if_merged() {
  local repo="$1" wt_path="$2" wt_branch="$3" main_branch="$4" detail="${5:-}"

  # Check 1: branch merged into main?
  if ! git -C "$repo" merge-base --is-ancestor "$wt_branch" "$main_branch" 2>/dev/null; then
    printf 'PRESERVED %s — unmerged (%s)' "$wt_branch" "${detail:-needs manual review}"
    return 1
  fi

  # Check 2: filesystem clean?
  # Pass --ignore-deletions: Check 1 confirmed branch is merged into main, so
  # ' D' entries are phantom staleness (files deleted in main after branch
  # creation), not real unsaved work worth preserving.
  local scan_summary
  if ! scan_summary=$(sb_scan_uncommitted "$wt_path" --ignore-deletions); then
    if [ -n "$detail" ] && [ "$detail" != "needs manual review" ]; then
      printf 'PRESERVED %s — unsaved work: %s | %s' "$wt_branch" "$scan_summary" "$detail"
    else
      printf 'PRESERVED %s — unsaved work: %s' "$wt_branch" "$scan_summary"
    fi
    return 2
  fi

  # Remove
  if git -C "$repo" worktree remove "$wt_path" 2>/dev/null \
     || git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null; then
    git -C "$repo" branch -d "$wt_branch" >/dev/null 2>&1
    printf 'REMOVED %s' "$wt_branch"
    return 0
  fi

  printf 'PRESERVED %s — merged but locked' "$wt_branch"
  return 3
}

sb_wt_sweep_orphan_branches() {
  local repo="$1" prefix_glob="$2" main_branch="$3"

  git -C "$repo" branch --list "$prefix_glob" 2>/dev/null | while IFS= read -r line; do
    local branch="${line#  }"
    branch="${branch#\* }"
    [ -z "$branch" ] && continue
    if git -C "$repo" worktree list --porcelain 2>/dev/null \
       | grep -q "branch refs/heads/$branch"; then
      continue
    fi
    if git -C "$repo" merge-base --is-ancestor "$branch" "$main_branch" 2>/dev/null; then
      if git -C "$repo" branch -d "$branch" 2>/dev/null; then
        printf 'REMOVED branch %s\n' "$branch"
      fi
    fi
  done
}

sb_wt_sweep_residual_dirs() {
  local parent="$1"
  [ -d "$parent" ] || return 0
  local dir base count
  for dir in "$parent"/*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/.git" ] && continue
    [ -d "$dir/.git" ] && continue
    count=$(find "$dir" -type f ! -name '.*' 2>/dev/null | head -5 | wc -l | tr -d ' ')
    count=${count:-0}
    base=$(basename "$dir")
    if [ "$count" -eq 0 ]; then
      rm -rf "$dir" 2>/dev/null && printf 'REMOVED residual %s\n' "$base"
    else
      printf 'PRESERVED residual %s — %s+ files, no .git\n' "$base" "$count"
    fi
  done
}
