#!/bin/bash
# stop.sh — Claude Code Stop hook wrapper.
# On session stop: locate sandbox → run merge-gate → merge if ok → cleanup.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

MARKER="$REPO/.git/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

BRANCH=$(awk '{print $1}' "$MARKER")
SB="$REPO/.sandbox/worktrees/$BRANCH"

touch "$MARKER" 2>/dev/null

_emit_block() {
  local raw="$1"
  local esc=${raw//\/\\}
  esc=${esc//\"/\\\"}
  esc=${esc//$'\n'/ }
  printf '{"decision":"block","reason":"%s"}' "$esc"
}

if [ -d "$SB" ]; then
  if ! reason=$(bash "$ROOT/core/cmd/sandbox-merge-gate.sh" --worktree "$SB" 2>&1); then
    _emit_block "$reason"
    exit 0
  fi

  # Gate passed — remove TASK.md so it does not pollute main, then merge.
  rm -f "$SB/TASK.md" 2>/dev/null

  if ! git -C "$REPO" merge-base --is-ancestor "$BRANCH" main 2>/dev/null; then
    if ! git -C "$REPO" merge "$BRANCH" --no-edit >/dev/null 2>&1; then
      git -C "$REPO" merge --abort >/dev/null 2>&1 || true
      _emit_block "Merge conflict on $BRANCH — resolve manually."
      exit 0
    fi
  fi
fi

rm -f "$MARKER" 2>/dev/null
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1 || true
exit 0
