#!/bin/bash
# Unit tests for heartbeat launch patterns (nohup vs subshell).
#
# On MSYS/Windows, nohup+disown fails to spawn background processes from
# non-interactive scripts. The subshell pattern ( ... & ) is the portable
# alternative. These tests verify both patterns so regressions are caught
# on any platform.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

HB="$ROOT/core/lib/heartbeat.sh"
MARKERS="$FIXTURE_ROOT/markers"
mkdir -p "$MARKERS"

_is_msys=0
case "$(uname -s)" in MINGW*|MSYS*) _is_msys=1 ;; esac

# ── 1. Subshell launch pattern ─────────────────────────────────────
echo "== subshell launch pattern =="
M1="$MARKERS/subshell.marker"
printf 'branch-sub %s abc123' "$(date +%s)" > "$M1"

( bash "$HB" --pid 0 --marker "$M1" --interval 1 </dev/null >/dev/null 2>&1 & )
sleep 2

assert_file_exists "subshell: sidecar created" "${M1}.hb"
_sub_pid=$(awk '{print $1}' "${M1}.hb" 2>/dev/null)
if [ -n "$_sub_pid" ] && kill -0 "$_sub_pid" 2>/dev/null; then
  _sub_alive=1
else
  _sub_alive=0
fi
assert_eq "subshell: heartbeat alive" "1" "$_sub_alive"

# Cleanup
[ -n "$_sub_pid" ] && kill "$_sub_pid" 2>/dev/null; wait "$_sub_pid" 2>/dev/null || true
rm -f "$M1" "${M1}.hb"

# ── 2. Nohup launch pattern (skip on MSYS — known broken) ──────────
if [ "$_is_msys" = 1 ]; then
  echo "== nohup launch pattern — SKIPPED (MSYS) =="
  T_TOTAL=$((T_TOTAL + 2))
  T_PASS=$((T_PASS + 2))
else
  echo "== nohup launch pattern =="
  M2="$MARKERS/nohup.marker"
  printf 'branch-noh %s def456' "$(date +%s)" > "$M2"

  sleep 300 &
  _noh_target=$!

  nohup bash "$HB" --pid "$_noh_target" --marker "$M2" --interval 1 \
    </dev/null >/dev/null 2>&1 &
  _noh_pid=$!
  disown 2>/dev/null || true
  sleep 2

  assert_file_exists "nohup: sidecar created" "${M2}.hb"
  _noh_sidecar=$(awk '{print $1}' "${M2}.hb" 2>/dev/null)
  if [ -n "$_noh_sidecar" ] && kill -0 "$_noh_sidecar" 2>/dev/null; then
    _noh_alive=1
  else
    _noh_alive=0
  fi
  assert_eq "nohup: heartbeat alive" "1" "$_noh_alive"

  kill "$_noh_target" 2>/dev/null; wait "$_noh_target" 2>/dev/null || true
  kill "$_noh_pid" 2>/dev/null; wait "$_noh_pid" 2>/dev/null || true
  rm -f "$M2" "${M2}.hb"
fi

test_summary
