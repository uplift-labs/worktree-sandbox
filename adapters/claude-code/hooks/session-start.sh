#!/bin/bash
# session-start.sh — Claude Code SessionStart hook wrapper.
# Reads Claude JSON on stdin, creates a sandbox worktree for the session,
# and runs lifecycle cleanup. Output lines prefixed '[sandbox]' are visible
# to the user via the Claude Code banner; the core commands' own output is
# forwarded as-is.

set -u
CI_NOOP=0
[ "${CI:-}" = "true" ] && CI_NOOP=1
[ -n "${GITHUB_ACTIONS:-}" ] && CI_NOOP=1
[ "$CI_NOOP" -eq 1 ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
SOURCE=$(json_field "source" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

# Suppress creation on compact restart — just re-emit the banner for existing sandbox
if [ "$SOURCE" = "compact" ]; then
  MARKERS_DIR="$REPO/.git/sandbox-markers"
  if [ -f "$MARKERS_DIR/$SESSION" ]; then
    BR=$(awk '{print $1}' "$MARKERS_DIR/$SESSION" 2>/dev/null)
    if [ -n "$BR" ] && [ -d "$REPO/.sandbox/worktrees/$BR" ]; then
      printf '[sandbox] Sandbox (re-injected): %s/.sandbox/worktrees/%s — use this root for all file ops.\n' "$REPO" "$BR"
    fi
  fi
  exit 0
fi

# Run lifecycle first (cleans old state before claiming new sandbox)
LC_OUT=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" 2>/dev/null || true)
[ -n "$LC_OUT" ] && printf '[sandbox] %s\n' "$LC_OUT"

# Then create this session's sandbox
if SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION" 2>&1) && [ -n "$SB" ]; then
  printf '[sandbox] Sandbox: %s — use this root for all file ops.\n' "$SB"
fi
exit 0
