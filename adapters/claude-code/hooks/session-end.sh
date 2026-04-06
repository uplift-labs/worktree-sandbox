#!/bin/bash
# session-end.sh — Claude Code SessionEnd hook wrapper.
# Fires on real session termination (/exit, Ctrl+D/C, SIGHUP, logout, idle).
#
# Responsibility: durability, not graduation.
#   1. Kill the heartbeat process (prevents it from racing with cleanup).
#   2. Delegate to sandbox-cleanup.sh (capture-commit + self-release + lifecycle).
#
# This hook does NOT merge the current session's branch into main. Merging
# is always a deliberate user action (`git merge <branch>` or the
# pre-merge-commit hook). Auto-merging on exit is too aggressive — the user
# may want to review, rebase, or discard.
#
# SessionEnd CANNOT block termination, so this script must be fast and
# idempotent. Any failure leaves the sandbox alive for the TTL safety-net
# in sandbox-lifecycle.sh (next SessionStart) to reclaim later.
#
# Reason branching:
#   compact — compact restart; same session_id reused. Heartbeat only.
#   clear   — /clear creates a new session_id; old session is dead.
#             Kill heartbeat + delegate cleanup (same as real termination).
#   other   — real termination. Kill heartbeat + delegate cleanup.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ROOT/core/lib/git-context.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
REASON=$(json_field "reason" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

GIT_COMMON=$(sb_git_common_dir "$REPO") || exit 0
MARKER="$GIT_COMMON/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

# Compact: session continues with the same session_id — just heartbeat
# the marker and bail. SessionStart with source=compact will re-launch
# the heartbeat for the surviving sandbox.
case "$REASON" in
  compact)
    touch "$MARKER" 2>/dev/null
    exit 0
    ;;
esac

# Kill heartbeat for clean shutdown — must happen BEFORE sandbox-cleanup.sh
# so the heartbeat doesn't race with cleanup on parent-death detection.
if [ -f "${MARKER}.hb" ]; then
  _hb_pid=$(awk '{print $1}' "${MARKER}.hb" 2>/dev/null)
  [ -n "$_hb_pid" ] && kill "$_hb_pid" 2>/dev/null || true
  rm -f "${MARKER}.hb" 2>/dev/null || true
fi

# Delegate cleanup to core (capture-commit + self-release + lifecycle).
bash "$ROOT/core/cmd/sandbox-cleanup.sh" --repo "$REPO" --session "$SESSION"

exit 0
