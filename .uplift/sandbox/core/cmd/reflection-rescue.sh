#!/bin/bash
# reflection-rescue.sh — rescue orphaned sidecar files from sandbox worktrees.
#
# Usage:
#   reflection-rescue.sh --repo <dir> [--worktrees-dir <rel>]
#
# Problem this solves:
#   Sidecar files (e.g. session reflections) are written inside the
#   currently-active sandbox worktree. If a sandbox ends up PRESERVED
#   (unmerged-stale, or blocked on uncommitted work) those files stay
#   trapped inside the worktree and never reach main. Over time, this
#   drops the observed end-to-end delivery rate to near zero.
#
# Strategy:
#   For every wt-* worktree, scan its $REFL_REL directory
#   for .md files. For each file:
#     - If the same basename already exists in main, remove it from the
#       worktree (main already has the authoritative copy).
#     - Otherwise, copy it to main and remove it from the worktree.
#   Idempotent: repeated runs converge (no duplicates, no growth).
#
# Side-effects on downstream cleanup:
#   Removing these files from the worktree drops one category of
#   "unsaved work" that keeps sb_scan_uncommitted flagging worktrees as
#   PRESERVED. So rescue also unblocks worktree reap on subsequent
#   lifecycle passes.
#
# Contract:
#   --repo            main repo path (required)
#   --worktrees-dir   relative path of sandbox worktrees root
#                     (default: .sandbox/worktrees)
#
# Environment:
#   REFLECTION_RESCUE_DIR  relative path of the sidecar directory to
#                          rescue from each worktree and copy into main
#                          (default: .reinforce/reflections). Fails open
#                          if the directory does not exist in a worktree
#                          or in main — safe to leave unset when the
#                          sidecar is not installed.
#
# Always exits 0 (fail-open). Prints one line per rescue action to stdout:
#   rescued:   <basename>  from <branch>
#   deduped:   <basename>  from <branch>   (already in main)
#
# No-op silently if there is nothing to rescue.

set -u

usage() { printf 'usage: reflection-rescue.sh --repo <dir> [--worktrees-dir <rel>]\n' >&2; exit 2; }

REPO=""
WT_DIR_REL=".sandbox/worktrees"
REFL_REL="${REFLECTION_RESCUE_DIR:-.reinforce/reflections}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --worktrees-dir) WT_DIR_REL="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$REPO" ] && usage
[ -d "$REPO" ] || exit 0

WT_DIR="$REPO/$WT_DIR_REL"
MAIN_REFL_DIR="$REPO/$REFL_REL"

# Nothing to do if no worktrees root.
[ -d "$WT_DIR" ] || exit 0

# Ensure the destination exists so `cp` can't fail with ENOENT.
mkdir -p "$MAIN_REFL_DIR" 2>/dev/null || exit 0

RESCUED=0
DEDUPED=0

for WT in "$WT_DIR"/wt-*; do
  [ -d "$WT" ] || continue
  SRC_DIR="$WT/$REFL_REL"
  [ -d "$SRC_DIR" ] || continue

  _branch=$(basename "$WT")

  # Use a loop over shell glob rather than find(1) — find on MSYS can
  # produce surprising quoting and is slower for small sets.
  for SRC in "$SRC_DIR"/*.md; do
    # Guard against "no match" leaving the literal glob.
    [ -f "$SRC" ] || continue

    _base=$(basename "$SRC")
    DEST="$MAIN_REFL_DIR/$_base"

    if [ -f "$DEST" ]; then
      # Main already has the authoritative copy — drop the worktree copy
      # so sb_scan_uncommitted stops flagging it as unsaved work.
      # Suppression rationale: if the rm fails (permission, locked file
      # on Windows), skip to the next file rather than abort — main is
      # unaffected, and the next lifecycle pass will retry the delete.
      if ! rm -f "$SRC" 2>/dev/null; then
        continue
      fi
      DEDUPED=$((DEDUPED + 1))
      printf 'deduped:   %s  from %s\n' "$_base" "$_branch"
      continue
    fi

    # Copy first, then remove source. cp+rm instead of mv so a partial
    # copy never leaves main empty-handed.
    if cp "$SRC" "$DEST" 2>/dev/null; then
      # Suppression rationale: cp already succeeded, so main has the
      # authoritative copy. A failed rm leaves a duplicate in the
      # worktree that the next rescue run will dedupe — harmless, not
      # worth aborting.
      rm -f "$SRC" 2>/dev/null || true
      RESCUED=$((RESCUED + 1))
      printf 'rescued:   %s  from %s\n' "$_base" "$_branch"
    fi
  done
done

# Only print a summary if something happened — silent no-op otherwise,
# matching sandbox-lifecycle's convention.
if [ $((RESCUED + DEDUPED)) -gt 0 ]; then
  printf 'reflection-rescue: rescued=%d deduped=%d\n' "$RESCUED" "$DEDUPED"
fi

exit 0
