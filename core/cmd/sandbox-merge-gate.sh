#!/bin/bash
# sandbox-merge-gate.sh — pre-merge validation gate.
#
# Usage:
#   sandbox-merge-gate.sh --worktree <dir>
#
# Checks:
#   1. No filesystem dirt (tracked/untracked user files)
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
. "$ROOT/core/lib/scan-uncommitted.sh"

usage() { printf 'usage: sandbox-merge-gate.sh --worktree <dir>\n' >&2; exit 2; }

WT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$WT" ] && usage
[ -d "$WT" ] || { printf 'not a directory: %s\n' "$WT"; exit 1; }

BLOCKS=""

if ! scan=$(sb_scan_uncommitted "$WT"); then
  BLOCKS="${BLOCKS}filesystem not clean: ${scan} — commit or stash before merge\n"
fi

if [ -n "$BLOCKS" ]; then
  printf 'sandbox-merge-gate: BLOCKED\n'
  printf '%b' "$BLOCKS"
  exit 1
fi
exit 0
