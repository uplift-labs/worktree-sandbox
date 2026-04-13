#!/bin/bash
# test-cleanup-log.sh — verify sb_cleanup_log writes grep-friendly lines
# under <sandbox-root>/logs/cleanup-YYYY-MM-DD.log and never fails loudly.
#
# Exit 0 on success, 1 on any failure.

set -u
FAIL=0
PASS=0

_here="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_ROOT="$(cd "$_here/.." && pwd)"
. "$SANDBOX_ROOT/core/lib/cleanup-log.sh"

_tmpdir=$(mktemp -d -t sb-cleanup-log-test-XXXXXX)
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

# --- happy path: writes one line with expected fields ---
ROOT1="$_tmpdir/root1"
mkdir -p "$ROOT1"
sb_cleanup_log "$ROOT1" "DESTROY" "sess-abc" "sandbox-session-xyz" "test-reason"
_day=$(date -u +%Y-%m-%d)
_file="$ROOT1/logs/cleanup-$_day.log"

[ -f "$_file" ] && rc=0 || rc=1
_assert "happy path: log file created under logs/" "$rc"

grep -q "DESTROY session=sess-abc branch=sandbox-session-xyz reason=test-reason" "$_file" 2>/dev/null \
  && rc=0 || rc=1
_assert "happy path: line contains action session= branch= reason=" "$rc"

_line_count=$(wc -l < "$_file" 2>/dev/null | tr -d ' ')
[ "$_line_count" = "1" ] && rc=0 || rc=1
_assert "happy path: exactly one line written" "$rc"

# --- extra field appended ---
sb_cleanup_log "$ROOT1" "SKIP" "sess-def" "-" "sanity-check" "ttl=300"
grep -q "SKIP session=sess-def branch=- reason=sanity-check ttl=300" "$_file" 2>/dev/null \
  && rc=0 || rc=1
_assert "extra field appended at end of line" "$rc"

# --- missing sandbox-root: silent no-op, no error ---
_stderr_out=$(sb_cleanup_log "" "DESTROY" "x" "y" "z" 2>&1 1>/dev/null); rc=$?
[ -z "$_stderr_out" ] && [ "$rc" = "0" ] && res=0 || res=1
_assert "empty sandbox-root: silent no-op, returns 0" "$res"

# --- unwritable logs dir: best-effort, returns 0 ---
ROOT2="$_tmpdir/root2"
mkdir -p "$ROOT2"
# Create logs as a regular file so mkdir -p fails inside the helper.
printf 'blocker' > "$ROOT2/logs"
sb_cleanup_log "$ROOT2" "DESTROY" "x" "y" "z"; rc=$?
_assert "unwritable logs path: returns 0 (best-effort)" "$rc"

# --- Summary ---
printf '\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
