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
#
# TASK.md is the sandbox's own metadata and is excluded from both counts — it is
# never user work. Fresh-sandbox preservation (the case where a brand-new sandbox
# has only a seeded TASK.md and no other state) is handled one layer up by the
# lifecycle command via marker protection, not here. Keeping scan_uncommitted
# semantics clean ("is there unsaved user work on disk?") makes it reusable by
# pre-merge hooks and other callers.

sb_scan_uncommitted() {
  local wt_path="$1"
  [ ! -d "$wt_path" ] && return 0

  local status tracked untracked
  # Filter TASK.md entries (both modified and untracked) out of the scan.
  status=$(git -C "$wt_path" status --porcelain 2>/dev/null | grep -v ' TASK\.md$')
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
