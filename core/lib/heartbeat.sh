#!/bin/bash
# heartbeat.sh — background PID monitor that keeps a marker file fresh.
#
# Launched by the session-start adapter hook, this script runs as a detached
# background process. It touches the marker file every INTERVAL seconds while
# the target PID (Claude Code) is alive. When the PID dies, the script stops
# heartbeating and exits — the marker's mtime freezes, and lifecycle's TTL
# reclaim picks it up on the next SessionStart.
#
# Marker-only mode (--pid 0 or omitted):
#   On platforms where the parent PID is not observable (MSYS/Windows — $PPID
#   is always 1 because the native Windows parent is invisible to MSYS), the
#   heartbeat runs without PID monitoring. It keeps touching the marker until
#   killed explicitly by session-end.sh or until --max-age is reached. The
#   --max-age safety valve prevents immortal orphans when session-end.sh
#   never fires (crash, SIGKILL, power loss).
#
# Windows parent PID monitoring (--parent-winpid):
#   On MSYS, the adapter resolves the Windows PID of the parent claude.exe
#   process via wmic tree walk and passes it here. Heartbeat checks every
#   WINPID_CHECK_EVERY ticks whether that native PID is still alive using
#   wmic. When the PID disappears, heartbeat exits — same as PID mode on
#   Linux. This closes the gap where SessionEnd never fires (Ctrl+C, terminal
#   close, crash) and the heartbeat would otherwise run for up to MAX_AGE.
#
# Usage:
#   bash heartbeat.sh --pid <target-pid> --marker <marker-path> \
#                      [--interval <seconds>] [--max-age <seconds>] \
#                      [--parent-winpid <windows-pid>]
#
# Sidecar file:
#   Writes its own PID to "${MARKER}.hb" on startup, removes it on exit.
#   This lets session-end.sh kill the heartbeat explicitly for a clean shutdown,
#   and lets lifecycle verify whether a heartbeat process is still alive.
#
# Exit conditions (all graceful):
#   - Target PID dies (kill -0 fails) — PID mode only
#   - Marker file deleted by someone else
#   - Max age reached — marker-only mode safety valve
#   - Heartbeat process receives a signal (trap cleans up sidecar)

set -u

PID=""
MARKER=""
INTERVAL=1
MAX_AGE=86400   # 24 hours — safety valve for marker-only mode
PARENT_WINPID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)            PID="$2";            shift 2 ;;
    --marker)         MARKER="$2";         shift 2 ;;
    --interval)       INTERVAL="$2";       shift 2 ;;
    --max-age)        MAX_AGE="$2";        shift 2 ;;
    --parent-winpid)  PARENT_WINPID="$2";  shift 2 ;;
    *) shift ;;
  esac
done

[ -z "$MARKER" ] && exit 1

# PID=0 or empty → marker-only mode (no PID monitoring).
_check_pid=1
if [ -z "$PID" ] || [ "$PID" = "0" ]; then
  _check_pid=0
fi

# Windows parent PID monitoring via wmic (MSYS only).
# wmic takes ~200ms per call, so check every N ticks instead of every tick.
_check_winpid=0
WINPID_CHECK_EVERY=5
if [ -n "$PARENT_WINPID" ] && [ "$PARENT_WINPID" != "0" ]; then
  _check_winpid=1
fi

# Write sidecar with our PID; clean it up on any exit.
_hb_sidecar="${MARKER}.hb"
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -f "$_hb_sidecar" 2>/dev/null; }
trap cleanup EXIT

printf '%s' "$$" > "$_hb_sidecar" 2>/dev/null || exit 1

_start=$(date +%s)
_tick=0

while true; do
  # Marker gone — someone cleaned up, nothing left to heartbeat.
  [ -f "$MARKER" ] || break

  # PID mode: target PID dead — stop heartbeating so mtime freezes.
  if [ "$_check_pid" = 1 ]; then
    kill -0 "$PID" 2>/dev/null || break
  fi

  # MSYS Windows PID mode: check native parent every WINPID_CHECK_EVERY ticks.
  if [ "$_check_winpid" = 1 ] && [ $((_tick % WINPID_CHECK_EVERY)) -eq 0 ]; then
    if ! wmic process where "ProcessId=$PARENT_WINPID" get ProcessId /format:value 2>/dev/null \
         | grep -q "ProcessId"; then
      break
    fi
  fi

  # Max-age safety valve (marker-only mode guard against immortal orphans).
  _now=$(date +%s)
  if [ $((_now - _start)) -ge "$MAX_AGE" ]; then
    break
  fi

  # Refresh mtime (inode metadata only, no data written).
  touch "$MARKER" 2>/dev/null

  sleep "$INTERVAL"
  _tick=$((_tick + 1))
done

exit 0
