#!/bin/bash
# session-start.sh — Codex SessionStart hook wrapper.

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
SOURCE=$(json_field "source" "$INPUT")
CWD=$(json_field "cwd" "$INPUT")
[ -z "$CWD" ] && CWD="$(pwd)"

REPO="${CODEX_SANDBOX_REPO:-}"
[ -z "$REPO" ] && REPO=$(sb_git_root "$CWD" 2>/dev/null || printf '%s' "$CWD")
SESSION="${CODEX_SANDBOX_SESSION:-$CODEX_SESSION}"
[ -z "$SESSION" ] && exit 0

WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")
BR_PREFIX=$(sandbox_adapter_branch_prefix)
BR_GLOB=$(sandbox_adapter_branch_glob)

_is_msys=0
case "$(uname -s)" in MINGW*|MSYS*) _is_msys=1 ;; esac

_resolve_parent_winpid() {
  local _wpid _parent _name _depth
  _wpid=$(cat /proc/$$/winpid 2>/dev/null) || return 0
  [ -z "$_wpid" ] && return 0
  for _depth in 1 2 3 4 5 6; do
    _parent=$(wmic process where "ProcessId=$_wpid" get ParentProcessId /format:value 2>/dev/null \
              | tr -d '\r\n' | sed 's/.*=//') || return 0
    [ -z "$_parent" ] && return 0
    _name=$(wmic process where "ProcessId=$_parent" get Name /format:value 2>/dev/null \
            | tr -d '\r\n' | sed 's/.*=//') || return 0
    case "$_name" in
      codex.exe)
        printf '%s' "$_parent"
        return 0
        ;;
    esac
    _wpid="$_parent"
  done
  return 0
}

_launch_heartbeat() {
  local _marker="$1"
  [ -f "$_marker" ] || return 0
  if [ "$_is_msys" = 1 ]; then
    local _winpid
    _winpid=$(_resolve_parent_winpid)
    ( bash "$ROOT/core/lib/heartbeat.sh" \
        --pid 0 --marker "$_marker" \
        --repo "$REPO" --sandbox-root "$ROOT" \
        --worktrees-dir "$WT_DIR" --branch-prefix "$BR_GLOB" \
        --owner-process-names "codex.exe" \
        ${_winpid:+--parent-winpid "$_winpid"} \
        </dev/null >/dev/null 2>&1 & )
  else
    nohup bash "$ROOT/core/lib/heartbeat.sh" \
      --pid "$PPID" --marker "$_marker" \
      --repo "$REPO" --sandbox-root "$ROOT" \
      --worktrees-dir "$WT_DIR" --branch-prefix "$BR_GLOB" \
      --owner-process-names "codex" \
      </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

_emit_context() {
  local _path="$1" _escaped
  _escaped=$(json_escape "worktree-sandbox active. Use this root for all file operations: $_path")
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$_escaped"
}

GIT_COMMON=$(sb_git_common_dir "$REPO") || exit 0

# Launcher mode: codex-sandbox already created the worktree and forced Codex
# to start in it. The hook only refreshes lifecycle state and reinforces cwd.
if [ "${CODEX_SANDBOX_ACTIVE:-}" = "1" ] && [ -n "${CODEX_SANDBOX_WORKTREE:-}" ]; then
  bash "$ROOT/core/cmd/sandbox-lifecycle.sh" \
    --repo "$REPO" \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_GLOB" >/dev/null 2>&1 || true
  _launch_heartbeat "$GIT_COMMON/sandbox-markers/$SESSION"
  _emit_context "$CODEX_SANDBOX_WORKTREE"
  exit 0
fi

LC_OUT=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" \
  --repo "$REPO" \
  --worktrees-dir "$WT_DIR" \
  --branch-prefix "$BR_GLOB" 2>/dev/null || true)

if SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" \
    --repo "$REPO" \
    --session "$SESSION" \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_PREFIX" 2>&1) && [ -n "$SB" ]; then
  _launch_heartbeat "$GIT_COMMON/sandbox-markers/$SESSION"
  if [ -n "$LC_OUT" ]; then
    _msg=$(json_escape "$LC_OUT"$'\n'"Use this root for all file operations: $SB")
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$_msg"
  else
    _emit_context "$SB"
  fi
else
  _msg=$(json_escape "worktree-sandbox warning: sandbox creation failed; continuing without isolation. ${SB:-no details}")
  printf '{"systemMessage":"%s"}' "$_msg"
fi

exit 0
