#!/bin/bash
# stop.sh — Claude Code Stop hook wrapper.
# Per-turn heartbeat: refresh the marker so lifecycle's TTL reclaim treats
# this session as live across long conversations.
#
# This hook fires after every agent turn. It must NOT merge, clean, or block
# based on filesystem state — uncommitted work is normal mid-session.
# Filesystem cleanliness is enforced at merge time by the pre-merge-commit
# hook (sandbox-merge-gate).

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

MARKER="$REPO/.git/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

# Heartbeat: refresh marker mtime so lifecycle's TTL reclaim treats this
# session as live across long conversations.
touch "$MARKER" 2>/dev/null

exit 0
