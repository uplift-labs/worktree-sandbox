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
. "$ADAPTER_DIR/lib/json-field.sh"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")
. "$ROOT/core/lib/git-context.sh"

INPUT=$(cat)
SESSION=$(json_field "session_id" "$INPUT")
SOURCE=$(json_field "source" "$INPUT")
REPO="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")
BR_PREFIX=$(sandbox_adapter_branch_prefix)
BR_GLOB=$(sandbox_adapter_branch_glob)

[ -z "$SESSION" ] && exit 0

# Detect MSYS/Windows — nohup+disown is broken there; use subshell pattern.
_is_msys=0
case "$(uname -s)" in MINGW*|MSYS*) _is_msys=1 ;; esac

# _resolve_parent_winpid
# On MSYS, walk the Windows process tree from our WINPID up to find
# claude.exe (or the closest native parent). Prints the Windows PID
# on success, empty string on failure. Uses wmic (one-time ~400ms cost).
_resolve_parent_winpid() {
  local _wpid _parent _name
  _wpid=$(cat /proc/$$/winpid 2>/dev/null) || return 0
  [ -z "$_wpid" ] && return 0
  local _depth
  for _depth in 1 2 3 4 5; do
    _parent=$(wmic process where "ProcessId=$_wpid" get ParentProcessId /format:value 2>/dev/null \
              | tr -d '\r\n' | sed 's/.*=//') || return 0
    [ -z "$_parent" ] && return 0
    _name=$(wmic process where "ProcessId=$_parent" get Name /format:value 2>/dev/null \
            | tr -d '\r\n' | sed 's/.*=//') || return 0
    case "$_name" in
      claude.exe|claude-code.exe|claude-desktop.exe)
        printf '%s' "$_parent"
        return 0
        ;;
    esac
    _wpid="$_parent"
  done
  # Didn't find claude.exe within the scanned depth. Returning the highest
  # ancestor (bash.exe / cmd.exe / an ephemeral shim) was a ghost-worktree
  # trigger: that ancestor dies quickly even while Claude Code is alive, and
  # heartbeat treats it as parent-death → destructive cleanup on a live
  # session. Return empty instead — heartbeat falls back to marker-only mode
  # guarded by MAX_AGE (24h). A stale orphan is strictly safer than instant
  # destruction of the user's sandbox.
  return 0
}

# _launch_heartbeat <marker-path>
# Spawns heartbeat.sh as a detached background process.
# Passes --repo and --sandbox-root so the heartbeat can invoke
# sandbox-cleanup.sh on parent death for immediate cleanup.
# MSYS: ( ... & ) subshell + --parent-winpid for native PID monitoring.
# Linux/macOS: nohup + disown + --pid $PPID (standard PID monitoring).
_launch_heartbeat() {
  local _marker="$1"
  [ -f "$_marker" ] || return 0
  if [ "$_is_msys" = 1 ]; then
    local _winpid
    _winpid=$(_resolve_parent_winpid)
    if [ -z "$_winpid" ]; then
      # Surface the degraded mode so users understand why session-end may be
      # delayed on crashes. In marker-only mode heartbeat keeps the sandbox
      # alive until MAX_AGE (24h) rather than reacting to parent death.
      printf '[sandbox] WARN: claude.exe not found in process tree — heartbeat in marker-only mode (24h TTL).\n'
    fi
    ( bash "$ROOT/core/lib/heartbeat.sh" \
        --pid 0 --marker "$_marker" \
        --repo "$REPO" --sandbox-root "$ROOT" \
        --worktrees-dir "$WT_DIR" --branch-prefix "$BR_GLOB" \
        ${_winpid:+--parent-winpid "$_winpid"} \
        </dev/null >/dev/null 2>&1 & )
  else
    nohup bash "$ROOT/core/lib/heartbeat.sh" \
      --pid "$PPID" --marker "$_marker" \
      --repo "$REPO" --sandbox-root "$ROOT" \
      --worktrees-dir "$WT_DIR" --branch-prefix "$BR_GLOB" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

# Suppress creation on compact restart — just re-emit the banner for existing sandbox
if [ "$SOURCE" = "compact" ]; then
  GIT_COMMON=$(sb_git_common_dir "$REPO") || exit 0
  MARKERS_DIR="$GIT_COMMON/sandbox-markers"
  if [ -f "$MARKERS_DIR/$SESSION" ]; then
    BR=$(awk '{print $1}' "$MARKERS_DIR/$SESSION" 2>/dev/null)
    if [ -n "$BR" ] && [ -d "$REPO/$WT_DIR/$BR" ]; then
      printf '[sandbox] Sandbox (re-injected): %s/%s/%s — use this root for all file ops.\n' "$REPO" "$WT_DIR" "$BR"
      # Re-launch heartbeat — previous one died with the old process.
      _launch_heartbeat "$MARKERS_DIR/$SESSION"
    fi
  fi
  exit 0
fi

# Run lifecycle first (cleans old state before claiming new sandbox)
LC_OUT=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" \
  --repo "$REPO" \
  --worktrees-dir "$WT_DIR" \
  --branch-prefix "$BR_GLOB" 2>/dev/null || true)
[ -n "$LC_OUT" ] && printf '[sandbox] %s\n' "$LC_OUT"

# Then create this session's sandbox
if SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" \
    --repo "$REPO" \
    --session "$SESSION" \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_PREFIX" 2>&1) && [ -n "$SB" ]; then
  printf '[sandbox] Sandbox: %s — use this root for all file ops.\n' "$SB"

  # Launch heartbeat — keeps marker fresh while Claude Code is alive.
  GIT_COMMON=$(sb_git_common_dir "$REPO") || exit 0
  _launch_heartbeat "$GIT_COMMON/sandbox-markers/$SESSION"
else
  # Surface sandbox creation failure. Without this banner the failure is
  # silent — the session runs in the main repo thinking it has isolation
  # and the user only discovers it when an edit lands outside the sandbox.
  printf '[sandbox] WARN: sandbox creation failed — working without isolation. Details: %s\n' "${SB:-<no output>}"
fi
exit 0
