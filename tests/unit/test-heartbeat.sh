#!/bin/bash
# Unit tests for core/lib/heartbeat.sh
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

# ── Helper: get mtime as epoch seconds ──────────────────────────────
_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# ── 1. Heartbeat touches marker while PID alive ─────────────────────
echo "== heartbeat touches marker while PID alive =="
M1="$MARKERS/alive.marker"
printf 'branch-a %s abc123' "$(date +%s)" > "$M1"
# Backdate marker so we can detect refresh
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$M1"
OLD_MTIME=$(_mtime "$M1")

# Use a long-lived sleep as the "target PID"
sleep 300 &
TARGET_PID=$!

bash "$HB" --pid "$TARGET_PID" --marker "$M1" --interval 1 &
HB_PID=$!
sleep 3

NEW_MTIME=$(_mtime "$M1")
assert_eq "mtime refreshed" "1" "$([ "$NEW_MTIME" -gt "$OLD_MTIME" ] && echo 1 || echo 0)"

# Sidecar exists with heartbeat PID
assert_file_exists "sidecar created" "${M1}.hb"
SIDECAR_PID=$(awk '{print $1}' "${M1}.hb" 2>/dev/null)
assert_eq "sidecar contains HB PID" "$HB_PID" "$SIDECAR_PID"

kill "$TARGET_PID" 2>/dev/null; wait "$TARGET_PID" 2>/dev/null || true
wait "$HB_PID" 2>/dev/null || true

# ── 2. Heartbeat exits when PID dies ────────────────────────────────
echo "== heartbeat exits when PID dies =="
M2="$MARKERS/die.marker"
printf 'branch-b %s abc456' "$(date +%s)" > "$M2"

sleep 1 &
SHORT_PID=$!

bash "$HB" --pid "$SHORT_PID" --marker "$M2" --interval 1 &
HB2_PID=$!

# Wait for the short sleep to finish + heartbeat to detect
sleep 4

# Heartbeat should have exited
if kill -0 "$HB2_PID" 2>/dev/null; then
  _hb_alive=1
  kill "$HB2_PID" 2>/dev/null; wait "$HB2_PID" 2>/dev/null || true
else
  _hb_alive=0
fi
assert_eq "heartbeat exited after PID death" "0" "$_hb_alive"
assert_file_absent "sidecar cleaned up after PID death" "${M2}.hb"

# ── 3. Heartbeat exits when marker deleted ──────────────────────────
echo "== heartbeat exits when marker deleted =="
M3="$MARKERS/vanish.marker"
printf 'branch-c %s abc789' "$(date +%s)" > "$M3"

sleep 300 &
LONG_PID=$!

bash "$HB" --pid "$LONG_PID" --marker "$M3" --interval 1 &
HB3_PID=$!
sleep 2

# Delete the marker
rm -f "$M3"
sleep 3

if kill -0 "$HB3_PID" 2>/dev/null; then
  _hb3_alive=1
  kill "$HB3_PID" 2>/dev/null; wait "$HB3_PID" 2>/dev/null || true
else
  _hb3_alive=0
fi
assert_eq "heartbeat exited after marker deleted" "0" "$_hb3_alive"
assert_file_absent "sidecar cleaned after marker deleted" "${M3}.hb"

kill "$LONG_PID" 2>/dev/null; wait "$LONG_PID" 2>/dev/null || true

# ── 4. Sidecar created and cleaned on signal ────────────────────────
echo "== sidecar cleanup on signal =="
M4="$MARKERS/signal.marker"
printf 'branch-d %s abcdef' "$(date +%s)" > "$M4"

sleep 300 &
SIG_PID=$!

bash "$HB" --pid "$SIG_PID" --marker "$M4" --interval 1 &
HB4_PID=$!
sleep 2

assert_file_exists "sidecar exists before kill" "${M4}.hb"

# Send TERM to heartbeat
kill "$HB4_PID" 2>/dev/null; wait "$HB4_PID" 2>/dev/null || true
sleep 1

assert_file_absent "sidecar cleaned after SIGTERM" "${M4}.hb"

kill "$SIG_PID" 2>/dev/null; wait "$SIG_PID" 2>/dev/null || true

# ── 5. Marker-only mode (--pid 0) ──────────────────────────────────
echo "== marker-only mode (--pid 0) =="
M5="$MARKERS/marker-only.marker"
printf 'branch-e %s def456' "$(date +%s)" > "$M5"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$M5"
OLD_MTIME5=$(_mtime "$M5")

bash "$HB" --pid 0 --marker "$M5" --interval 1 &
HB5_PID=$!
sleep 3

NEW_MTIME5=$(_mtime "$M5")
assert_eq "marker-only: mtime refreshed" "1" "$([ "$NEW_MTIME5" -gt "$OLD_MTIME5" ] && echo 1 || echo 0)"
assert_file_exists "marker-only: sidecar created" "${M5}.hb"

# Still alive (no PID to die)
if kill -0 "$HB5_PID" 2>/dev/null; then
  _hb5_alive=1
else
  _hb5_alive=0
fi
assert_eq "marker-only: heartbeat still running" "1" "$_hb5_alive"

kill "$HB5_PID" 2>/dev/null; wait "$HB5_PID" 2>/dev/null || true

# ── 6. Marker-only mode exits on marker deletion ───────────────────
echo "== marker-only mode exits on marker deletion =="
M6="$MARKERS/marker-only-del.marker"
printf 'branch-f %s def789' "$(date +%s)" > "$M6"

bash "$HB" --pid 0 --marker "$M6" --interval 1 &
HB6_PID=$!
sleep 2

rm -f "$M6"
sleep 3

if kill -0 "$HB6_PID" 2>/dev/null; then
  _hb6_alive=1
  kill "$HB6_PID" 2>/dev/null; wait "$HB6_PID" 2>/dev/null || true
else
  _hb6_alive=0
fi
assert_eq "marker-only: exited after marker deleted" "0" "$_hb6_alive"
assert_file_absent "marker-only: sidecar cleaned" "${M6}.hb"

# ── 7. Max-age safety valve ─────────────────────────────────────────
echo "== max-age safety valve =="
M7="$MARKERS/maxage.marker"
printf 'branch-g %s ghi123' "$(date +%s)" > "$M7"

bash "$HB" --pid 0 --marker "$M7" --interval 1 --max-age 3 &
HB7_PID=$!
sleep 5

if kill -0 "$HB7_PID" 2>/dev/null; then
  _hb7_alive=1
  kill "$HB7_PID" 2>/dev/null; wait "$HB7_PID" 2>/dev/null || true
else
  _hb7_alive=0
fi
assert_eq "max-age: heartbeat exited" "0" "$_hb7_alive"
assert_file_absent "max-age: sidecar cleaned" "${M7}.hb"
# Marker should still exist (heartbeat stopped, not deleted)
assert_file_exists "max-age: marker still exists" "$M7"
rm -f "$M7"

test_summary
