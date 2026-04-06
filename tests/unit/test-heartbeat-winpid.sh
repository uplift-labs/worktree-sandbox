#!/bin/bash
# Unit tests for heartbeat.sh --parent-winpid (MSYS parent PID monitoring)
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

# Skip entirely on non-MSYS — wmic is Windows-only.
case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) printf 'SKIP: test-heartbeat-winpid requires MSYS/Windows\n'; exit 0 ;;
esac

fixture_init
trap fixture_cleanup EXIT

HB="$ROOT/core/lib/heartbeat.sh"
MARKERS="$FIXTURE_ROOT/markers"
mkdir -p "$MARKERS"

# ── Helper: get WINPID of an MSYS PID ─────────────────────────────
_winpid_of() {
  cat "/proc/$1/winpid" 2>/dev/null || echo ""
}

# ── 1. Heartbeat exits when parent WINPID dies ────────────────────
echo "== heartbeat exits when parent WINPID dies =="
M1="$MARKERS/winpid-die.marker"
printf 'branch-wp1 %s abc123' "$(date +%s)" > "$M1"

# Start a process to simulate claude.exe; get its WINPID.
sleep 300 &
FAKE_CLAUDE_PID=$!
FAKE_CLAUDE_WINPID=$(_winpid_of "$FAKE_CLAUDE_PID")

if [ -z "$FAKE_CLAUDE_WINPID" ]; then
  printf 'SKIP: cannot resolve WINPID from /proc — test not applicable\n'
  kill "$FAKE_CLAUDE_PID" 2>/dev/null; wait "$FAKE_CLAUDE_PID" 2>/dev/null || true
  exit 0
fi

# Launch heartbeat with --parent-winpid.
# Use WINPID_CHECK_EVERY=1 via short interval (check every tick for fast test).
bash "$HB" --pid 0 --marker "$M1" --interval 1 --parent-winpid "$FAKE_CLAUDE_WINPID" &
HB_PID=$!
sleep 2

# Heartbeat should be alive while parent is alive.
if kill -0 "$HB_PID" 2>/dev/null; then
  _alive_before=1
else
  _alive_before=0
fi
assert_eq "heartbeat alive while parent WINPID alive" "1" "$_alive_before"

# Kill the fake parent.
kill "$FAKE_CLAUDE_PID" 2>/dev/null; wait "$FAKE_CLAUDE_PID" 2>/dev/null || true

# Wait for heartbeat to detect death (WINPID_CHECK_EVERY=5 ticks * 1s + margin).
sleep 8

if kill -0 "$HB_PID" 2>/dev/null; then
  _alive_after=1
  kill "$HB_PID" 2>/dev/null; wait "$HB_PID" 2>/dev/null || true
else
  _alive_after=0
fi
assert_eq "heartbeat exited after parent WINPID died" "0" "$_alive_after"
assert_file_absent "sidecar cleaned after WINPID death" "${M1}.hb"

# ── 2. Heartbeat keeps running with live parent WINPID ────────────
echo "== heartbeat keeps running with live parent WINPID =="
M2="$MARKERS/winpid-alive.marker"
printf 'branch-wp2 %s def456' "$(date +%s)" > "$M2"

sleep 300 &
LIVE_PID=$!
LIVE_WINPID=$(_winpid_of "$LIVE_PID")

bash "$HB" --pid 0 --marker "$M2" --interval 1 --parent-winpid "$LIVE_WINPID" &
HB2_PID=$!
sleep 8

# Should still be alive after 8 seconds (well past check interval).
if kill -0 "$HB2_PID" 2>/dev/null; then
  _still_alive=1
else
  _still_alive=0
fi
assert_eq "heartbeat still running with live parent" "1" "$_still_alive"
assert_file_exists "sidecar still present" "${M2}.hb"

kill "$HB2_PID" 2>/dev/null; wait "$HB2_PID" 2>/dev/null || true
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null || true

# ── 3. --parent-winpid 0 is ignored (treated as no-op) ───────────
echo "== --parent-winpid 0 ignored =="
M3="$MARKERS/winpid-zero.marker"
printf 'branch-wp3 %s ghi789' "$(date +%s)" > "$M3"

bash "$HB" --pid 0 --marker "$M3" --interval 1 --parent-winpid 0 &
HB3_PID=$!
sleep 3

# Should be alive (no WINPID check active).
if kill -0 "$HB3_PID" 2>/dev/null; then
  _zero_alive=1
else
  _zero_alive=0
fi
assert_eq "winpid=0: heartbeat still running" "1" "$_zero_alive"

kill "$HB3_PID" 2>/dev/null; wait "$HB3_PID" 2>/dev/null || true

# ── 4. Bogus WINPID (already dead) causes immediate exit ─────────
echo "== bogus WINPID causes exit =="
M4="$MARKERS/winpid-bogus.marker"
printf 'branch-wp4 %s jkl012' "$(date +%s)" > "$M4"

# Use a PID that almost certainly doesn't exist.
bash "$HB" --pid 0 --marker "$M4" --interval 1 --parent-winpid 99999 &
HB4_PID=$!
# First tick checks WINPID (tick 0, 0 % 5 == 0), should exit quickly.
sleep 3

if kill -0 "$HB4_PID" 2>/dev/null; then
  _bogus_alive=1
  kill "$HB4_PID" 2>/dev/null; wait "$HB4_PID" 2>/dev/null || true
else
  _bogus_alive=0
fi
assert_eq "bogus WINPID: heartbeat exited" "0" "$_bogus_alive"
assert_file_absent "bogus WINPID: sidecar cleaned" "${M4}.hb"

test_summary
