#!/bin/bash
# heartbeat.sh — background PID monitor that keeps a marker file fresh.
#
# Launched by the session-start adapter hook, this script runs as a detached
# background process. It touches the marker file every INTERVAL seconds while
# the target PID (Claude Code) is alive. When the PID dies, the heartbeat
# invokes sandbox-cleanup.sh for immediate session cleanup (capture-commit +
# self-release + lifecycle), then exits. If --repo / --sandbox-root are not
# provided, falls back to legacy behavior: mtime freezes and lifecycle's TTL
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
#   wmic. When the PID disappears, heartbeat runs cleanup and exits — same
#   as PID mode on Linux.
#
# Usage:
#   bash heartbeat.sh --pid <target-pid> --marker <marker-path> \
#                      [--interval <seconds>] [--max-age <seconds>] \
#                      [--parent-winpid <windows-pid>] \
#                      [--repo <dir>] [--sandbox-root <dir>]
#
# Sidecar file:
#   Writes "<heartbeat_pid> <parent_winpid|0> <monitored_pid|0>" to
#   "${MARKER}.hb" on startup.  On parent-death exit the sidecar is cleaned
#   up by sandbox-cleanup.sh (or left behind as a dead-PID signal for
#   lifecycle if cleanup is unavailable).  On signal exit (session-end.sh
#   sends kill) or marker-gone exit, the sidecar is removed.  Field layout:
#     $1 = heartbeat PID (used by session-end.sh to kill on clean shutdown)
#     $2 = Windows PID of parent claude.exe (0 if not on MSYS or unresolved)
#     $3 = Unix PID being monitored via kill -0 (0 in marker-only mode)
#   Lifecycle uses fields 2-3 to independently verify whether the owning
#   Claude Code process is still alive, rather than trusting the heartbeat
#   process alone.
#
# Exit conditions (all graceful):
#   - Target PID dies (kill -0 fails) — PID mode only; triggers cleanup
#   - Windows parent PID dies — MSYS mode; triggers cleanup
#   - Marker file deleted by someone else
#   - Max age reached — marker-only mode safety valve
#   - Heartbeat process receives a signal (trap cleans up sidecar)

set -u

# Detect MSYS/Windows for tasklist-based sanity check before destructive cleanup.
_is_msys=0
case "$(uname -s)" in MINGW*|MSYS*) _is_msys=1 ;; esac

PID=""
MARKER=""
INTERVAL=1
MAX_AGE=86400   # 24 hours — safety valve for marker-only mode
PARENT_WINPID=""
REPO=""
SANDBOX_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)            PID="$2";            shift 2 ;;
    --marker)         MARKER="$2";         shift 2 ;;
    --interval)       INTERVAL="$2";       shift 2 ;;
    --max-age)        MAX_AGE="$2";        shift 2 ;;
    --parent-winpid)  PARENT_WINPID="$2";  shift 2 ;;
    --repo)           REPO="$2";           shift 2 ;;
    --sandbox-root)   SANDBOX_ROOT="$2";   shift 2 ;;
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

# Write sidecar with our PID.
# On parent-death: run sandbox-cleanup.sh which handles marker + sidecar
# removal.  If cleanup is unavailable (no --repo / --sandbox-root), leave
# sidecar behind as dead-PID signal for lifecycle Phase 3.
# On signal exit (session-end.sh kills us) or marker-gone: remove sidecar.
_hb_sidecar="${MARKER}.hb"
_parent_died=0
_cleanup_ran=0
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  if [ "$_parent_died" = 1 ] && [ "$_cleanup_ran" = 0 ]; then
    return  # leave sidecar — dead PID is the signal for lifecycle
  fi
  rm -f "$_hb_sidecar" 2>/dev/null
}
trap cleanup EXIT
# SIGHUP arrives when the terminal closes. Treat it as parent death so we
# run cleanup instead of just deleting the sidecar and exiting silently.
# On MSYS nohup is not used (broken), so this is the primary defence.
# The flag is picked up at the top of the next loop iteration.
trap '_parent_died=1' HUP

printf '%s %s %s' "$$" "${PARENT_WINPID:-0}" "${PID:-0}" > "$_hb_sidecar" 2>/dev/null || exit 1

_start=$(date +%s)
_tick=0

while true; do
  # SIGHUP received — terminal closed, parent is dead.
  [ "$_parent_died" = 1 ] && break

  # Marker gone — someone cleaned up, nothing left to heartbeat.
  [ -f "$MARKER" ] || break

  # PID mode: target PID dead — stop heartbeating so mtime freezes.
  if [ "$_check_pid" = 1 ]; then
    if ! kill -0 "$PID" 2>/dev/null; then
      _parent_died=1; break
    fi
  fi

  # MSYS Windows PID mode: check native parent every WINPID_CHECK_EVERY ticks.
  if [ "$_check_winpid" = 1 ] && [ $((_tick % WINPID_CHECK_EVERY)) -eq 0 ]; then
    if ! wmic process where "ProcessId=$PARENT_WINPID" get ProcessId /format:value 2>/dev/null \
         | grep -q "ProcessId"; then
      _parent_died=1; break
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

# --- On parent death: immediate cleanup via sandbox-cleanup.sh -----------
#
# When the parent process dies (crash, SIGKILL, terminal close), session-end.sh
# never fires. The heartbeat is the only survivor that can clean up. Delegate
# to sandbox-cleanup.sh which handles capture-commit + self-release + lifecycle.
#
# If --repo / --sandbox-root were not provided, fall back to legacy behavior:
# sidecar stays behind, lifecycle picks up on next SessionStart.
#
# Race safety: session-end.sh kills the heartbeat BEFORE calling cleanup. If
# session-end fires (graceful exit), we never reach this code. If it doesn't
# fire (crash), we are the only cleanup path. No race possible.
if [ "$_parent_died" = 1 ] && [ -n "$SANDBOX_ROOT" ] && [ -n "$REPO" ]; then
  _session=$(basename "$MARKER")

  # Load cleanup log helper for diagnostic trail. Best-effort source — if the
  # file is missing (e.g., older installed copy), the helper calls below become
  # no-ops via the stub defined right after.
  # shellcheck disable=SC1091
  . "$SANDBOX_ROOT/core/lib/cleanup-log.sh" 2>/dev/null || sb_cleanup_log() { :; }

  # Final sanity check: even if our specific parent-winpid was classified as
  # dead, a live claude.exe anywhere in the system means this was likely a
  # false-positive (wrong ancestor monitored, wmic race, etc.). Aborting
  # cleanup in that case trades a potential orphan worktree (bounded by
  # MAX_AGE safety valve, ~24h) for avoiding instant destruction of a live
  # user session — a strictly safer failure mode.
  _skip_cleanup=0
  if [ "$_is_msys" = 1 ] && command -v tasklist >/dev/null 2>&1; then
    if tasklist /FI "IMAGENAME eq claude.exe" /NH 2>/dev/null | grep -qi 'claude\.exe' \
       || tasklist /FI "IMAGENAME eq claude-code.exe" /NH 2>/dev/null | grep -qi 'claude-code\.exe' \
       || tasklist /FI "IMAGENAME eq claude-desktop.exe" /NH 2>/dev/null | grep -qi 'claude-desktop\.exe'; then
      _skip_cleanup=1
    fi
  fi

  if [ "$_skip_cleanup" = 1 ]; then
    sb_cleanup_log "$SANDBOX_ROOT" "SKIP" "$_session" "-" "heartbeat-sanity-live-claude-exe"
    # Drop the .hb sidecar so the (now-exiting) heartbeat doesn't look alive
    # to lifecycle. Keep the marker — session appears live to the owner.
    rm -f "$_hb_sidecar" 2>/dev/null || true
    _cleanup_ran=1  # suppress the "leave sidecar behind" branch in trap
    exit 0
  fi

  sb_cleanup_log "$SANDBOX_ROOT" "DESTROY" "$_session" "-" "heartbeat-parent-death"
  if bash "$SANDBOX_ROOT/core/cmd/sandbox-cleanup.sh" \
       --repo "$REPO" --session "$_session" 2>/dev/null; then
    _cleanup_ran=1
  fi
fi

exit 0
