#!/bin/bash
# cleanup-log.sh — structured diagnostic log for sandbox destroy/release events.
#
# Sandbox cleanup and lifecycle reap used to delete worktrees, branches and
# markers silently. When ghost-worktree destruction hit a live session, the
# only evidence was indirect (user noticing their sandbox had vanished).
# This helper writes one grep-friendly line per destructive action to
# .sandbox/logs/cleanup-YYYY-MM-DD.log so post-mortems have a primary source.
#
# Public function:
#   sb_cleanup_log <sandbox-root> <action> <session> <branch> <reason> [extra]
#     action : DESTROY | RELEASE | SKIP | PRUNE | RESCUE | ORPHAN
#     session: session id (or "-" if unknown)
#     branch : branch name (or "-" if unknown)
#     reason : short tag identifying the call-site, e.g. "heartbeat-parent-death",
#              "lifecycle-phase3-reap", "cleanup-phase2-self-release",
#              "heartbeat-sanity-skip".
#     extra  : optional free-form tail (no newlines).
#
# Log format (single line, space-separated):
#   <iso8601-utc> <action> session=<id> branch=<br> reason=<tag> [<extra>]
#
# All writes are best-effort — failures are swallowed so observability never
# blocks the cleanup path itself.

sb_cleanup_log() {
  local _root="${1:-}" _action="${2:-?}" _session="${3:--}" _branch="${4:--}" _reason="${5:--}" _extra="${6:-}"
  [ -z "$_root" ] && return 0
  local _dir="$_root/logs"
  mkdir -p "$_dir" 2>/dev/null || return 0
  local _day _ts _line _file
  _day=$(date -u +%Y-%m-%d 2>/dev/null) || return 0
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 0
  _file="$_dir/cleanup-$_day.log"
  if [ -n "$_extra" ]; then
    _line="$_ts $_action session=$_session branch=$_branch reason=$_reason $_extra"
  else
    _line="$_ts $_action session=$_session branch=$_branch reason=$_reason"
  fi
  printf '%s\n' "$_line" >> "$_file" 2>/dev/null || true
  return 0
}
