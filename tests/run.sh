#!/bin/bash
# run.sh — test runner for worktree-sandbox
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export WORKTREE_SANDBOX_ROOT="$PROJECT_ROOT"

MODE="${1:-all}"
PASS=0; FAIL=0; FILES=0; FAILED_FILES=""

run_one() {
  local file="$1"
  FILES=$((FILES + 1))
  printf '\n--- %s ---\n' "$(basename "$file")"
  if bash "$file"; then PASS=$((PASS + 1))
  else FAIL=$((FAIL + 1)); FAILED_FILES="${FAILED_FILES}\n  - $(basename "$file")"
  fi
}

collect() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    run_one "$f"
  done
}

case "$MODE" in
  all)  collect "$SCRIPT_DIR/unit"; collect "$SCRIPT_DIR/e2e" ;;
  unit) collect "$SCRIPT_DIR/unit" ;;
  e2e)  collect "$SCRIPT_DIR/e2e" ;;
  *)
    if [ -f "$MODE" ]; then run_one "$MODE"
    else echo "Unknown mode or file not found: $MODE" >&2; exit 2
    fi
    ;;
esac

printf '\n===================\n'
printf 'Test files: %d   passed: %d   failed: %d\n' "$FILES" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'FAILED:%b\n' "$FAILED_FILES"
  exit 1
fi
printf 'ALL GREEN\n'
exit 0
