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
SIDECAR_PID=$(cat "${M1}.hb" 2>/dev/null)
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

test_summary
