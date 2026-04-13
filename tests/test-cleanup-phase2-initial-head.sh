#!/bin/bash
# test-cleanup-phase2-initial-head.sh — regression for Bug B
# (plan C:/Users/Sergey/.claude/plans/sandbox-ghost-worktree-fix.md).
#
# Bug: sandbox-cleanup.sh Phase 2 self-release used to drop the marker for
# any fresh session because a branch that never diverged is trivially
# merge-base-ancestor-of-main AND trivially clean. With initial_head guard
# mirroring lifecycle Phase 3, fresh sessions must keep their marker.
#
# This test covers three scenarios:
#   1. Fresh session (HEAD == initial_head) → marker preserved (Bug B regression)
#   2. Legacy marker (no initial_head) → marker preserved (fall through to TTL)
#   3. Session that committed and merged → marker released (Phase 2 still works)
#
# Exit 0 on success, 1 on any failure.

set -u
FAIL=0
PASS=0

_here="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_ROOT="$(cd "$_here/.." && pwd)"

_tmpdir=$(mktemp -d -t sb-cleanup-p2-test-XXXXXX)
trap 'rm -rf "$_tmpdir"' EXIT

_assert() {
  local desc="$1" rc="$2"
  if [ "$rc" = "0" ]; then
    printf 'PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$desc"
    FAIL=$((FAIL + 1))
  fi
}

# --- helpers ----------------------------------------------------------------

_init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "T"
  printf 'hello\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
}

_create_sandbox() {
  local repo="$1" session="$2"
  bash "$SANDBOX_ROOT/core/cmd/sandbox-init.sh" --repo "$repo" --session "$session" 2>/dev/null
}

# --- Scenario 1: fresh session, HEAD == initial_head -----------------------
REPO1="$_tmpdir/repo1"
_init_repo "$REPO1"
SB1=$(_create_sandbox "$REPO1" "fresh-session-1")
[ -n "$SB1" ] && [ -d "$SB1" ] && rc=0 || rc=1
_assert "scenario1: sandbox created" "$rc"

MARKER1="$REPO1/.git/sandbox-markers/fresh-session-1"
[ -f "$MARKER1" ] && rc=0 || rc=1
_assert "scenario1: marker exists before cleanup" "$rc"

# Run cleanup without any commits — HEAD still equals initial_head.
bash "$SANDBOX_ROOT/core/cmd/sandbox-cleanup.sh" --repo "$REPO1" --session "fresh-session-1" >/dev/null 2>&1

[ -f "$MARKER1" ] && rc=0 || rc=1
_assert "scenario1: fresh session — marker PRESERVED (Bug B regression)" "$rc"

[ -d "$SB1" ] && rc=0 || rc=1
_assert "scenario1: fresh session — worktree PRESERVED" "$rc"

# --- Scenario 2: legacy marker (no initial_head field) ---------------------
REPO2="$_tmpdir/repo2"
_init_repo "$REPO2"
SB2=$(_create_sandbox "$REPO2" "legacy-session-2")
[ -n "$SB2" ] && rc=0 || rc=1
_assert "scenario2: sandbox created" "$rc"

MARKER2="$REPO2/.git/sandbox-markers/legacy-session-2"
# Rewrite marker in legacy 2-field format (value epoch, no initial_head).
BR2=$(awk '{print $1}' "$MARKER2")
printf '%s %s' "$BR2" "$(date +%s)" > "$MARKER2"

bash "$SANDBOX_ROOT/core/cmd/sandbox-cleanup.sh" --repo "$REPO2" --session "legacy-session-2" >/dev/null 2>&1

[ -f "$MARKER2" ] && rc=0 || rc=1
_assert "scenario2: legacy marker — PRESERVED (falls through to TTL)" "$rc"

# --- Scenario 3: session that committed and merged into main ---------------
REPO3="$_tmpdir/repo3"
_init_repo "$REPO3"
SB3=$(_create_sandbox "$REPO3" "merged-session-3")
[ -n "$SB3" ] && rc=0 || rc=1
_assert "scenario3: sandbox created" "$rc"

MARKER3="$REPO3/.git/sandbox-markers/merged-session-3"
BR3=$(awk '{print $1}' "$MARKER3")

# Commit inside the sandbox so HEAD diverges from initial_head.
printf 'work\n' > "$SB3/work.txt"
git -C "$SB3" add work.txt
git -C "$SB3" commit -q -m "sandbox work"

# Fast-forward main to the sandbox branch — now merged ancestor.
git -C "$REPO3" merge --ff-only "$BR3" -q

bash "$SANDBOX_ROOT/core/cmd/sandbox-cleanup.sh" --repo "$REPO3" --session "merged-session-3" >/dev/null 2>&1

[ ! -f "$MARKER3" ] && rc=0 || rc=1
_assert "scenario3: merged+committed — marker RELEASED (Phase 2 still works)" "$rc"

# --- Summary ---
printf '\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
