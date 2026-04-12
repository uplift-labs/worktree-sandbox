#!/bin/bash
# scan-uncommitted.sh — filesystem-level scan for unsaved work in a worktree.
#
# Public function:
#   sb_scan_uncommitted <wt-path> [--ignore-deletions]
#     exit 0 = filesystem clean
#     exit 1 = has unsaved work on disk; echoes short summary on stdout
#
#   --ignore-deletions  Filter out ' D' entries (file tracked by index but
#                       absent from working tree) before counting. Safe ONLY
#                       for merged branches where these are phantom staleness
#                       from files deleted in main, not real unsaved work.
#
# Signals checked:
#   (a) tracked modifications or staged changes (git status --porcelain, non-'??')
#   (b) untracked files not covered by .gitignore ('??' lines)

sb_scan_uncommitted() {
  local wt_path="$1"
  local flags="${2:-}"
  [ ! -d "$wt_path" ] && return 0

  local status tracked untracked
  # Refresh stat cache to avoid phantom modifications on Windows/MSYS where
  # stale index timestamps cause git status to report files as modified even
  # when their content is identical to HEAD.
  git -C "$wt_path" update-index --refresh >/dev/null 2>&1 || true
  status=$(git -C "$wt_path" status --porcelain 2>/dev/null)

  # For merged branches, ' D' entries (file in index, absent from working tree)
  # are phantom staleness from files deleted in main after the branch was
  # created — not real unsaved work. Filter them out when caller opts in.
  if [ "$flags" = "--ignore-deletions" ] && [ -n "$status" ]; then
    status=$(printf '%s\n' "$status" | grep -v '^ D ' || true)
  fi

  if [ -z "$status" ]; then
    tracked=0
    untracked=0
  else
    tracked=$(printf '%s\n' "$status" | grep -cv '^??' || true)
    tracked=${tracked:-0}
    untracked=$(printf '%s\n' "$status" | grep -c '^??' || true)
    untracked=${untracked:-0}
  fi

  if [ "$tracked" -gt 0 ] || [ "$untracked" -gt 0 ]; then
    printf '%s modified, %s untracked' "$tracked" "$untracked"
    return 1
  fi

  return 0
}
