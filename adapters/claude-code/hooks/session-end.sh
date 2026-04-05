#!/bin/bash
# session-end.sh — Claude Code SessionEnd hook wrapper.
# Fires on real session termination (/exit, Ctrl+D/C, SIGHUP, logout, idle).
# Responsible for graduating the sandbox branch: merge-gate → merge → cleanup.
#
# SessionEnd CANNOT block termination, so this script must be fast and
# idempotent. If gate fails or merge conflicts, the sandbox is left alive
# so the TTL safety-net in sandbox-lifecycle.sh can reclaim it later.
#
# Reason branching:
#   clear   — /clear, context reset; session continues. No-op except heartbeat.
#   compact — compact restart; session continues. No-op except heartbeat.
#   other   — real termination (prompt_input_exit, logout, other, ...). Graduate.

set -u
[ "${CI:-}" = "true" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$HOOK_DIR/.." && pwd)"
ROOT="$(cd "$ADAPTER_DIR/../.." && pwd)"
. "$ADAPTER_DIR/lib/json-field.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
REASON=$(json_field "reason" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"

[ -z "$SESSION" ] && exit 0

MARKER="$REPO/.git/sandbox-markers/$SESSION"
[ -f "$MARKER" ] || exit 0

BRANCH=$(awk '{print $1}' "$MARKER")
SB="$REPO/.sandbox/worktrees/$BRANCH"

# Non-terminating reasons: session is not actually ending — just heartbeat
# the marker and bail. SessionStart will re-inject the banner on the next
# turn / compact-restart.
case "$REASON" in
  clear|compact)
    touch "$MARKER" 2>/dev/null
    exit 0
    ;;
esac

# Real termination path — graduate the sandbox.
[ -d "$SB" ] || { rm -f "$MARKER" 2>/dev/null; exit 0; }

# Gate check: if unmergeable (unchecked TASK.md, dirty tree, untracked),
# leave everything alive. Next SessionStart resume will pick it up; if the
# session never resumes, lifecycle's TTL reclaim will eventually handle it.
if ! reason_msg=$(bash "$ROOT/core/cmd/sandbox-merge-gate.sh" --worktree "$SB" 2>&1); then
  printf '[sandbox] SessionEnd: gate failed, leaving sandbox alive: %s\n' "$reason_msg" >&2
  exit 0
fi

# Gate passed — remove TASK.md so the template does not pollute main.
rm -f "$SB/TASK.md" 2>/dev/null

# Merge the branch into main, unless already an ancestor.
if ! git -C "$REPO" merge-base --is-ancestor "$BRANCH" main 2>/dev/null; then
  if ! git -C "$REPO" merge "$BRANCH" --no-edit >/dev/null 2>&1; then
    git -C "$REPO" merge --abort >/dev/null 2>&1 || true
    printf '[sandbox] SessionEnd: merge conflict on %s — resolve manually.\n' "$BRANCH" >&2
    exit 0
  fi
fi

# Merge succeeded — drop the marker and let lifecycle reap the worktree,
# branch, and any residual dir.
rm -f "$MARKER" 2>/dev/null
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" >/dev/null 2>&1 || true
exit 0
