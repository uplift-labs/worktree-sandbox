#!/bin/bash
# stop.sh — Codex Stop hook heartbeat.

set -u
[ "${CI:-}" = "true" ] && { printf '{"continue":true}'; exit 0; }

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")
. "$ROOT/core/lib/git-context.sh"

INPUT=$(cat)
CODEX_SESSION=$(json_field "session_id" "$INPUT")
CWD=$(json_field "cwd" "$INPUT")
[ -z "$CWD" ] && CWD="$(pwd)"

REPO="${CODEX_SANDBOX_REPO:-}"
[ -z "$REPO" ] && REPO=$(sb_git_root "$CWD" 2>/dev/null || printf '%s' "$CWD")
SESSION="${CODEX_SANDBOX_SESSION:-$CODEX_SESSION}"

if [ -n "$SESSION" ]; then
  GIT_COMMON=$(sb_git_common_dir "$REPO" 2>/dev/null || true)
  if [ -n "$GIT_COMMON" ] && [ -f "$GIT_COMMON/sandbox-markers/$SESSION" ]; then
    touch "$GIT_COMMON/sandbox-markers/$SESSION" 2>/dev/null || true
  fi
fi

printf '{"continue":true}'
exit 0
