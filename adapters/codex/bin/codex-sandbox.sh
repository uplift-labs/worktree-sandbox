#!/bin/bash
# codex-sandbox.sh — launch Codex CLI inside a worktree-sandbox session.

set -u

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
ADAPTER_DIR="$(cd "$BIN_DIR/.." && pwd)"
. "$ADAPTER_DIR/lib/layout.sh"
ROOT=$(sandbox_adapter_root "$ADAPTER_DIR")
. "$ROOT/core/lib/git-context.sh"

usage() {
  printf 'usage: codex-sandbox.sh [--repo <dir>] [--session <id>] [--] [codex args...]\n' >&2
  exit 2
}

REPO=""
SESSION=""
CODEX_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --) shift; CODEX_ARGS+=("$@"); break ;;
    -h|--help) usage ;;
    *) CODEX_ARGS+=("$1"); shift ;;
  esac
done

[ -z "$REPO" ] && REPO=$(sb_git_root "$(pwd)" 2>/dev/null || pwd)
if [ -z "$SESSION" ]; then
  SESSION="codex-$(date +%s)-$$"
fi

WT_DIR=$(sandbox_adapter_worktrees_dir "$REPO" "$ROOT")
BR_PREFIX=$(sandbox_adapter_branch_prefix)
BR_GLOB=$(sandbox_adapter_branch_glob)

if ! command -v codex >/dev/null 2>&1; then
  printf 'codex-sandbox: codex command not found on PATH\n' >&2
  exit 1
fi

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
  printf 'codex-sandbox: sandbox creation failed: %s\n' "$SB" >&2
  exit 1
fi
[ -z "$SB" ] && { printf 'codex-sandbox: sandbox creation produced no path\n' >&2; exit 1; }

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  bash "$ROOT/core/cmd/sandbox-cleanup.sh" \
    --repo "$REPO" \
    --session "$SESSION" \
    --trust-dead \
    --worktrees-dir "$WT_DIR" \
    --branch-prefix "$BR_GLOB" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

export CODEX_SANDBOX_ACTIVE=1
export CODEX_SANDBOX_SESSION="$SESSION"
export CODEX_SANDBOX_REPO="$REPO"
export CODEX_SANDBOX_WORKTREE="$SB"
export CODEX_SANDBOX_WORKTREES_DIR="$WT_DIR"
export CODEX_SANDBOX_BRANCH_PREFIX="$BR_PREFIX"

printf '[sandbox] Codex sandbox: %s\n' "$SB" >&2
codex -C "$SB" "${CODEX_ARGS[@]}"
exit $?
