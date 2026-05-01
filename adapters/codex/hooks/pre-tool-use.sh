#!/bin/bash
# pre-tool-use.sh — Codex PreToolUse guard for supported write tools.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")
. "$ROOT/core/lib/git-context.sh"

INPUT=$(cat)
CODEX_SESSION=$(json_field "session_id" "$INPUT")
TOOL=$(json_field "tool_name" "$INPUT")
CWD=$(json_field "cwd" "$INPUT")
[ -z "$CWD" ] && CWD="$(pwd)"

REPO="${CODEX_SANDBOX_REPO:-}"
[ -z "$REPO" ] && REPO=$(sb_git_root "$CWD" 2>/dev/null || printf '%s' "$CWD")
SESSION="${CODEX_SANDBOX_SESSION:-$CODEX_SESSION}"
[ -z "$SESSION" ] && exit 0

WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")

case "$TOOL" in
  apply_patch|Edit|Write) ;;
  *) exit 0 ;;
esac

# Codex's apply_patch hook input does not expose a normalized target path.
# Use the hook cwd as the target surface: apply_patch running from main is
# blocked when this session owns a sandbox, while apply_patch from the
# sandbox worktree is allowed.
TARGET="$CWD/.__codex_apply_patch_target__"

if reason=$(bash "$ROOT/core/cmd/sandbox-guard.sh" \
    --session "$SESSION" \
    --file "$TARGET" \
    --repo "$REPO" \
    --worktrees-dir "$WT_DIR" 2>&1); then
  exit 0
fi

escaped=$(json_escape "$reason")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$escaped"
exit 0
