#!/bin/bash
# opencode-sandbox.sh — launch OpenCode inside a worktree-sandbox session.

set -u

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$BIN_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")
. "$ROOT/core/lib/git-context.sh"

usage() {
  printf 'usage: opencode-sandbox.sh [--repo <dir>] [--session <id>] [--] [opencode args...]\n' >&2
  exit 2
}

REPO=""
SESSION=""
OPENCODE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --) shift; OPENCODE_ARGS+=("$@"); break ;;
    -h|--help) usage ;;
    *) OPENCODE_ARGS+=("$1"); shift ;;
  esac
done

if ! command -v opencode >/dev/null 2>&1; then
  printf 'opencode-sandbox: opencode command not found on PATH\n' >&2
  exit 1
fi

[ -z "$REPO" ] && REPO=$(sb_git_root "$(pwd)" 2>/dev/null || pwd)
REPO=$(sb_git_root "$REPO" 2>/dev/null || printf '%s' "$REPO")
if [ -z "$SESSION" ]; then
  SESSION="opencode-$(date +%s)-$$"
fi

WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")
BR_PREFIX=$(sandbox_adapter_branch_prefix)
BR_GLOB=$(sandbox_adapter_branch_glob)

LC_OUT=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" \
  --repo "$REPO" \
  --worktrees-dir "$WT_DIR" \
  --branch-prefix "$BR_GLOB" 2>/dev/null || true)
[ -n "$LC_OUT" ] && printf '[sandbox] %s\n' "$LC_OUT" >&2

if ! SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" \
    --repo "$REPO" \
    --session "$SESSION" \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_PREFIX" 2>&1); then
  printf 'opencode-sandbox: sandbox creation failed: %s\n' "$SB" >&2
  exit 1
fi
[ -z "$SB" ] && { printf 'opencode-sandbox: sandbox creation produced no path\n' >&2; exit 1; }

GIT_COMMON=$(sb_git_common_dir "$REPO") || GIT_COMMON=""
MARKER="$GIT_COMMON/sandbox-markers/$SESSION"
OPENCODE_PID=""
CLEANED=0

_kill_heartbeat() {
  [ -n "$MARKER" ] || return 0
  [ -f "${MARKER}.hb" ] || return 0
  local _hb_pid
  _hb_pid=$(awk '{print $1}' "${MARKER}.hb" 2>/dev/null)
  [ -n "$_hb_pid" ] && kill "$_hb_pid" 2>/dev/null || true
  rm -f "${MARKER}.hb" 2>/dev/null || true
}

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  local _rc="$1"
  [ "$CLEANED" -eq 1 ] && return "$_rc"
  CLEANED=1

  if [ -n "$OPENCODE_PID" ] && kill -0 "$OPENCODE_PID" 2>/dev/null; then
    kill "$OPENCODE_PID" 2>/dev/null || true
    wait "$OPENCODE_PID" 2>/dev/null || true
  fi

  _kill_heartbeat

  bash "$ROOT/core/cmd/sandbox-cleanup.sh" \
    --repo "$REPO" \
    --session "$SESSION" \
    --trust-dead \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_GLOB" >/dev/null 2>&1 || true

  return "$_rc"
}

_on_exit() {
  local _rc=$?
  cleanup "$_rc"
  exit "$_rc"
}

_launch_heartbeat() {
  local _pid="$1"
  [ -n "$MARKER" ] || return 0
  [ -f "$MARKER" ] || return 0
  bash "$ROOT/core/lib/heartbeat.sh" \
    --pid "$_pid" \
    --marker "$MARKER" \
    --repo "$REPO" \
    --sandbox-root "$ROOT" \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_GLOB" \
    --owner-process-names "opencode,opencode.exe,node,node.exe,bun,bun.exe" \
    </dev/null >/dev/null 2>&1 &
}

export OPENCODE_SANDBOX_ACTIVE=1
export OPENCODE_SANDBOX_SESSION="$SESSION"
export OPENCODE_SANDBOX_REPO="$REPO"
export OPENCODE_SANDBOX_ROOT="$ROOT"
export OPENCODE_SANDBOX_WORKTREE="$SB"
export OPENCODE_SANDBOX_WORKTREES_DIR="$WT_DIR"
export OPENCODE_SANDBOX_BRANCH_PREFIX="$BR_PREFIX"

# Make the adapter plugin available even before the installed files are
# committed into the sandbox worktree. OpenCode still loads project .opencode.
if [ -z "${OPENCODE_CONFIG_DIR:-}" ] && [ -d "$ADAPTER_DIR/plugins" ]; then
  export OPENCODE_CONFIG_DIR="$ADAPTER_DIR"
fi

printf '[sandbox] OpenCode sandbox: %s\n' "$SB" >&2

trap _on_exit EXIT
trap 'exit 130' HUP INT TERM

(
  cd "$SB" || exit 1
  opencode "${OPENCODE_ARGS[@]}"
) &
OPENCODE_PID=$!
_launch_heartbeat "$OPENCODE_PID"

wait "$OPENCODE_PID"
rc=$?
trap - EXIT
cleanup "$rc"
exit "$rc"
