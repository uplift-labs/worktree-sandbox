#!/bin/bash
# stop.sh — Claude Code Stop hook wrapper.
# Per-turn read-only gate: heartbeat the marker and block the turn if the
# worktree is not in a mergeable state. Graduation (merge + cleanup) lives
# in session-end.sh and must NOT happen here — Stop fires after every agent
# turn, so merging here would destroy a live session mid-conversation.

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

# Heartbeat: refresh marker mtime so lifecycle's TTL reclaim treats this
# session as live across long conversations.
touch "$MARKER" 2>/dev/null

[ -d "$SB" ] || exit 0

_emit_block() {
  local raw="$1"
  local esc=${raw//\/\\}
  esc=${esc//\"/\\\"}
  esc=${esc//$'\n'/ }
  printf '{"decision":"block","reason":"%s"}' "$esc"
}

if ! reason=$(bash "$ROOT/core/cmd/sandbox-merge-gate.sh" --worktree "$SB" 2>&1); then
  _emit_block "$reason"
  exit 0
fi

# Gate passed — do nothing. Sandbox stays alive for the next turn; graduation
# only happens in session-end.sh on a real session termination.
exit 0
