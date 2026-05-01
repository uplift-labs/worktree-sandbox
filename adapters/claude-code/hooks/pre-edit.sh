#!/bin/bash
# pre-edit.sh — Claude Code PreToolUse hook wrapper for Edit/Write.
# Denies writes that target the main repo when a sandbox is active for this
# session. Emits the native Claude permissionDecision JSON.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
FILE=$(json_field "file_path" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")

[ -z "$SESSION" ] && exit 0
[ -z "$FILE" ] && exit 0

if reason=$(bash "$ROOT/core/cmd/sandbox-guard.sh" \
    --session "$SESSION" \
    --file "$FILE" \
    --repo "$REPO" \
    --worktrees-dir "$WT_DIR" 2>&1); then
  exit 0
fi

# Pure-bash JSON string escape (no sed — avoids Windows MSYS sed quirks)
escaped=${reason//\/\\}
escaped=${escaped//\"/\\\"}
escaped=${escaped//$'\n'/ }
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$escaped"
exit 0
