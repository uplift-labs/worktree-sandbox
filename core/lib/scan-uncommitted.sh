#!/bin/bash
# scan-uncommitted.sh — filesystem-level scan for unsaved work in a worktree.
#
# Public function:
#   sb_scan_uncommitted <wt-path>
#     exit 0 = filesystem clean
#     exit 1 = has unsaved work on disk; echoes short summary on stdout
#
# Signals checked:
#   (a) tracked modifications or staged changes (git status --porcelain, non-'??')
#   (b) untracked files not covered by .gitignore ('??' lines)

sb_scan_uncommitted() {
  local wt_path="$1"
  [ ! -d "$wt_path" ] && return 0

  local status tracked untracked
  # Refresh stat cache to avoid phantom modifications on Windows/MSYS where
  # stale index timestamps cause git status to report files as modified even
  # when their content is identical to HEAD.
  git -C "$wt_path" update-index --refresh >/dev/null 2>&1 || true
  status=$(git -C "$wt_path" status --porcelain 2>/dev/null)
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
