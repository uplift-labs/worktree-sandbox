#!/bin/bash
# sandbox-merge-gate.sh — pre-merge validation gate.
#
# Usage:
#   sandbox-merge-gate.sh --worktree <dir> [--strict-tasks]
#
# Checks:
#   1. TASK.md has no unchecked boxes (or is absent and not --strict-tasks)
#   2. No filesystem dirt (tracked/untracked user files — TASK.md is excluded)
#
# Designed to be invoked from a git pre-merge-commit hook OR a session-stop
# wrapper. Produces human-readable stdout; no JSON.
#
# Exit:
#   0 = ok to merge
#   1 = blocked (reason on stdout)
#   2 = bad usage

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/task-md.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"

usage() { printf 'usage: sandbox-merge-gate.sh --worktree <dir> [--strict-tasks]\n' >&2; exit 2; }

WT=""; STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree)     WT="$2"; shift 2 ;;
    --strict-tasks) STRICT=1; shift ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$WT" ] && usage
[ -d "$WT" ] || { printf 'not a directory: %s\n' "$WT"; exit 1; }

BLOCKS=""

if [ -f "$WT/TASK.md" ]; then
  if ! reason=$(sb_task_check_completion "$WT"); then
    BLOCKS="${BLOCKS}${reason}\n"
  fi
else
  if [ "$STRICT" -eq 1 ]; then
    BLOCKS="${BLOCKS}no TASK.md at ${WT} (--strict-tasks)\n"
  fi
fi

if ! scan=$(sb_scan_uncommitted "$WT"); then
  BLOCKS="${BLOCKS}filesystem not clean: ${scan} — commit or stash before merge\n"
fi

if [ -n "$BLOCKS" ]; then
  printf 'sandbox-merge-gate: BLOCKED\n'
  printf '%b' "$BLOCKS"
  exit 1
fi
exit 0
