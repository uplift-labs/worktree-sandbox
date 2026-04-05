#!/bin/bash
# heartbeat.sh — background PID monitor that keeps a marker file fresh.
#
# Launched by the session-start adapter hook, this script runs as a detached
# background process. It touches the marker file every INTERVAL seconds while
# the target PID (Claude Code) is alive. When the PID dies, the script stops
# heartbeating and exits — the marker's mtime freezes, and lifecycle's TTL
# reclaim picks it up on the next SessionStart.
#
# Usage:
#   bash heartbeat.sh --pid <target-pid> --marker <marker-path> [--interval <seconds>]
#
# Sidecar file:
#   Writes its own PID to "${MARKER}.hb" on startup, removes it on exit.
#   This lets session-end.sh kill the heartbeat explicitly for a clean shutdown,
#   and lets lifecycle verify whether a heartbeat process is still alive.
#
# Exit conditions (all graceful):
#   - Target PID dies (kill -0 fails)
#   - Marker file deleted by someone else
#   - Heartbeat process receives a signal (trap cleans up sidecar)

set -u

PID=""
MARKER=""
INTERVAL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)      PID="$2";      shift 2 ;;
    --marker)   MARKER="$2";   shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -z "$PID" ] && exit 1
[ -z "$MARKER" ] && exit 1

# Write sidecar with our PID; clean it up on any exit.
_hb_sidecar="${MARKER}.hb"
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -f "$_hb_sidecar" 2>/dev/null; }
trap cleanup EXIT

printf '%s' "$$" > "$_hb_sidecar" 2>/dev/null || exit 1

while true; do
  # Marker gone — someone cleaned up, nothing left to heartbeat.
  [ -f "$MARKER" ] || break

  # Target PID dead — stop heartbeating so mtime freezes.
  kill -0 "$PID" 2>/dev/null || break

  # Refresh mtime (inode metadata only, no data written).
  touch "$MARKER" 2>/dev/null

  sleep "$INTERVAL"
done

exit 0
