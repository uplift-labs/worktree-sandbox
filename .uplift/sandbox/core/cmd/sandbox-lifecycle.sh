#!/bin/bash
# sandbox-lifecycle.sh — periodic cleanup of sandbox worktrees.
#
# Usage:
#   sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>]
#
# Contract:
#   --repo           main repo path
#   --ttl            marker TTL for stale-reclaim (default 5)
#   --branch-prefix  glob for orphan branch sweep (default 'wt-*')
#
# Phases:
#   1. git worktree prune (stale metadata)
#   2. Prune expired markers (TTL — reclaims crashed sessions)
#   3. Proactive marker release — drop markers whose branch is already an
#      ancestor of main AND whose worktree is clean, regardless of TTL. Closes
#      the crashed / `clear` / `compact` session gap where SessionEnd never
#      fired to self-release, leaving an immortal orphan until TTL.
#   4. For each linked worktree, try sb_wt_remove_if_merged with marker protection
#   5. Sweep orphan branches matching --branch-prefix
#   6. Sweep empty residual dirs under .sandbox/worktrees/
#
# Always exits 0. Prints a multi-line report to stdout summarizing actions.
# No-op silently if there is nothing to do.

set -u
CMD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CMD_DIR/../.." && pwd)"
. "$ROOT/core/lib/git-context.sh"
. "$ROOT/core/lib/scan-uncommitted.sh"
. "$ROOT/core/lib/ttl-marker.sh"
. "$ROOT/core/lib/wt-cleanup.sh"
. "$ROOT/core/lib/cleanup-log.sh"

usage() { printf 'usage: sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>]\n' >&2; exit 2; }

# Grace period for heartbeats with unknown parent (winpid=0 or absent).
# After this many seconds from marker creation, lifecycle kills the heartbeat
# and proceeds with TTL reclaim. Covers the case where _resolve_parent_winpid
# failed at launch time AND SessionEnd never fired (crash/force-close).
ORPHAN_HB_GRACE=7200  # 2 hours

# Extended TTL for markers whose session never committed (HEAD == init_head).
# These sessions look indistinguishable from merged+clean dead sessions, so
# the standard short TTL would reap them immediately. A longer TTL protects
# live sessions whose heartbeat died (e.g., parent PID resolution raced on
# MSYS) while still cleaning genuinely dead empty sessions after this period.
FRESH_SESSION_TTL=300  # 5 minutes

# _sb_hb_is_session_alive <sidecar_path> <marker_path>
# Checks whether a heartbeat with a live PID is protecting a truly active
# session. Returns 0 (session alive / protected) or 1 (orphan — safe to kill).
#
# Decision matrix:
#   parent_winpid known + parent alive → 0 (protected)
#   parent_winpid known + parent dead  → 1 (orphan: kill heartbeat)
#   parent_winpid unknown (0/absent)   → 0 if within ORPHAN_HB_GRACE,
#                                        1 if grace expired
_sb_hb_is_session_alive() {
  local _hb_path="$1" _marker_path="$2"
  local _content _parent_wp _monitored_pid _field_count
  _content=$(cat "$_hb_path" 2>/dev/null) || return 0

  # Legacy sidecar format (single field — heartbeat PID only, no parent/
  # monitored PID).  Written by older code before the 3-field format was
  # introduced.  Cannot verify session liveness — treat as dead so that
  # the caller kills the zombie heartbeat and proceeds with TTL reclaim.
  _field_count=$(printf '%s' "$_content" | awk '{print NF}')
  if [ "${_field_count:-0}" -lt 2 ]; then
    return 1
  fi

  _parent_wp=$(printf '%s' "$_content" | awk '{print $2}')
  _monitored_pid=$(printf '%s' "$_content" | awk '{print $3}')

  # Field 3: Unix PID monitored via kill -0 (Linux/macOS --pid $PPID mode).
  # If present and > 0, directly verify whether the parent process is alive.
  if [ -n "$_monitored_pid" ] && [ "$_monitored_pid" != "0" ]; then
    if kill -0 "$_monitored_pid" 2>/dev/null; then
      return 0  # monitored parent alive
    fi
    return 1  # monitored parent dead
  fi

  # Field 2: Windows PID of parent claude.exe (MSYS --parent-winpid mode).
  if [ -n "$_parent_wp" ] && [ "$_parent_wp" != "0" ]; then
    # On non-Windows, tasklist is absent → can't verify → assume alive.
    if ! command -v tasklist >/dev/null 2>&1; then
      return 0
    fi
    if tasklist /FI "PID eq $_parent_wp" /NH 2>/dev/null | grep -q "$_parent_wp"; then
      return 0  # parent alive
    fi
    return 1  # parent confirmed dead
  fi

  # Neither monitored PID nor parent winpid — marker-only mode with no
  # external monitoring. Apply orphan grace period from marker creation epoch.
  local _created _now
  _created=$(sb_marker_read_epoch "$_marker_path")
  _now=$(date +%s)
  if [ -n "$_created" ] && [ $((_now - _created)) -ge "$ORPHAN_HB_GRACE" ]; then
    return 1  # grace expired — treat as orphan
  fi
  return 0  # within grace — protected
}

# _sb_kill_dead_heartbeat <marker_path>
# Check heartbeat sidecar for a marker and kill zombie heartbeats.
# Returns: 0 = session alive (caller should skip),
#          1 = no heartbeat file,
#          2 = heartbeat existed but session is confirmed dead.
_sb_kill_dead_heartbeat() {
  local mf="$1"
  [ -f "${mf}.hb" ] || return 1
  local _hb_pid
  _hb_pid=$(awk '{print $1}' "${mf}.hb" 2>/dev/null)
  if [ -n "$_hb_pid" ] && kill -0 "$_hb_pid" 2>/dev/null; then
    if _sb_hb_is_session_alive "${mf}.hb" "$mf"; then
      return 0  # session genuinely alive
    fi
    kill "$_hb_pid" 2>/dev/null || true
    rm -f "${mf}.hb" 2>/dev/null || true
  fi
  # .hb with dead PID is left for later phases; caller deletes with marker.
  return 2  # heartbeat existed, session confirmed dead
}

REPO=""; TTL=5; PREFIX="wt-*"; WT_DIR=".sandbox/worktrees"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="$2"; shift 2 ;;
    --ttl)           TTL="$2"; shift 2 ;;
    --branch-prefix) PREFIX="$2"; shift 2 ;;
    --worktrees-dir) WT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage ;;
  esac
done
[ -z "$REPO" ] && usage

GIT_ROOT=$(sb_git_root "$REPO") || exit 0
GIT_COMMON=$(sb_git_common_dir "$GIT_ROOT") || exit 0
MAIN_BRANCH=$(sb_main_branch "$GIT_ROOT")
MARKERS_DIR="$GIT_COMMON/sandbox-markers"

REMOVED=0
LINES=""

# Phase 0: rescue orphaned sidecar files from sandbox worktrees.
#
# Sidecar files (e.g. session reflections) written inside a sandbox worktree
# get stranded when the worktree ends up PRESERVED (unmerged-stale or flagged
# as unsaved work). Without rescue, downstream consumers never see them.
# Running before the worktree-reap phases (1-6) also has a useful side-effect:
# removing the files from the worktree drops one category of "unsaved work"
# that was blocking reap, so subsequent phases can reclaim the worktree too.
RESCUE_OUT=$(bash "$ROOT/core/cmd/reflection-rescue.sh" --repo "$GIT_ROOT" --worktrees-dir "$WT_DIR" 2>/dev/null || true)
[ -n "$RESCUE_OUT" ] && LINES="${LINES}${RESCUE_OUT}"$'\n'

# Phase 1: prune stale git worktree metadata
sb_wt_prune_metadata "$GIT_ROOT"

# Phase 2: TTL reclaim — drop markers older than $TTL (crashed sessions).
# Per-marker loop instead of bulk find: respects heartbeat sidecar PID and
# applies a grace period for freshly-created markers (heartbeat may not have
# started yet).
if [ -d "$MARKERS_DIR" ]; then
  for mf in "$MARKERS_DIR"/*; do
    [ -f "$mf" ] || continue
    [[ "$(basename "$mf")" == *.hb ]] && continue   # skip heartbeat sidecar files

    # Orphan marker: if the marker's worktree directory no longer exists,
    # the marker protects nothing — clean it up unconditionally.  This
    # covers the case where a worktree was manually removed or cleaned by
    # another process while the heartbeat kept the marker alive.
    _m_branch=$(sb_marker_read_value "$mf")
    if [ -n "$_m_branch" ]; then
      _m_wt="$GIT_ROOT/$WT_DIR/$_m_branch"
      if [ ! -d "$_m_wt" ]; then
        if [ -f "${mf}.hb" ]; then
          _hb_pid=$(awk '{print $1}' "${mf}.hb" 2>/dev/null)
          [ -n "$_hb_pid" ] && kill "$_hb_pid" 2>/dev/null || true
        fi
        rm -f "$mf" "${mf}.hb" 2>/dev/null || true
        sb_cleanup_log "$ROOT" "PRUNE" "$(basename "$mf")" "$_m_branch" "lifecycle-phase2-orphan-marker"
        continue
      fi
    fi

    # If heartbeat sidecar exists, verify whether session is truly alive.
    _sb_kill_dead_heartbeat "$mf" && continue

    # Grace period: marker created < 30s ago — heartbeat may not have started yet.
    _created=$(sb_marker_read_epoch "$mf")
    _now=$(date +%s)
    if [ -n "$_created" ] && [ $((_now - _created)) -lt 30 ]; then
      continue
    fi

    # Fresh-session protection: if HEAD == init_head (session never committed),
    # the worktree looks indistinguishable from a merged+clean dead session.
    # Use ORPHAN_HB_GRACE instead of the short TTL — the session might still be
    # active with a dead heartbeat (e.g., parent PID resolution raced on MSYS).
    #
    # Malformed/legacy marker protection: if _init_head is empty — either a
    # legacy marker pre-dating the initial_head field, or a partially-written
    # marker from a failed sb_marker_write — apply the same extended TTL. The
    # short TTL (5s) is too aggressive to distinguish live-but-legacy from
    # genuinely corrupt. Genuinely corrupt markers still get reaped after
    # FRESH_SESSION_TTL (5 min), keeping leak bounded.
    _effective_ttl="$TTL"
    if [ -n "$_m_branch" ]; then
      _init_head=$(sb_marker_read_initial_head "$mf")
      if [ -z "$_init_head" ]; then
        _effective_ttl="$FRESH_SESSION_TTL"
        LINES="${LINES}WARN malformed/legacy marker: $(basename "$mf")"$'\n'
      elif [ -d "$_m_wt" ]; then
        _cur_head=$(git -C "$_m_wt" rev-parse HEAD 2>/dev/null || true)
        if [ "$_cur_head" = "$_init_head" ]; then
          _effective_ttl="$FRESH_SESSION_TTL"
        fi
      fi
    fi

    # Standard TTL check on mtime (uses extended TTL for fresh sessions).
    if ! sb_marker_is_fresh "$mf" "$_effective_ttl"; then
      rm -f "$mf" "${mf}.hb" 2>/dev/null || true
      sb_cleanup_log "$ROOT" "PRUNE" "$(basename "$mf")" "${_m_branch:--}" "lifecycle-phase2-ttl-reclaim ttl=$_effective_ttl"
    fi
  done
fi

# Phase 3: proactive marker release for merged+clean sandboxes.
#
# A marker's job is to protect an *in-progress* session from being reaped
# mid-conversation. If the session's branch is already an ancestor of main
# AND the worktree has no uncommitted work, the marker protects nothing —
# it only delays the inevitable reap until TTL expiry. Dropping it here lets
# Phase 4 reclaim the worktree in the same pass.
#
# This covers the gap where SessionEnd's fast-path self-release never ran:
# crashed processes, SIGKILL, power loss, and `/clear`/`/compact` reasons
# (which intentionally skip self-release in session-end.sh).
#
# Critical guard: a fresh session whose branch has never diverged from main
# (HEAD == initial_head stored in the marker) looks structurally identical to
# a completed+merged session. Without the initial_head check, Phase 3 would
# reap a live session that simply hasn't started committing yet.
#
# Safety: skip branches in mid-rebase / mid-merge / detached-HEAD state —
# mirrors the `_can_commit` guard in adapters/claude-code/hooks/session-end.sh
# to avoid reaping a worktree during conflict resolution.
# Legacy markers (no initial_head field) → skip, fall back to TTL (Phase 2).
if [ -d "$MARKERS_DIR" ] && [ -n "$MAIN_BRANCH" ]; then
  for mf in "$MARKERS_DIR"/*; do
    [ -f "$mf" ] || continue
    [[ "$(basename "$mf")" == *.hb ]] && continue   # skip heartbeat sidecar files

    # If heartbeat sidecar exists, verify whether session is truly alive.
    _sb_kill_dead_heartbeat "$mf"; _hb_rc=$?
    [ "$_hb_rc" -eq 0 ] && continue  # session genuinely alive — skip

    _branch=$(sb_marker_read_value "$mf")
    [ -z "$_branch" ] && continue
    _sb="$GIT_ROOT/$WT_DIR/$_branch"
    [ -d "$_sb" ] || continue

    # Legacy marker without initial_head — cannot distinguish fresh from
    # merged; fall back to TTL safety net (Phase 2).
    _init_head=$(sb_marker_read_initial_head "$mf")
    [ -z "$_init_head" ] && continue

    # Session never committed anything — branch HEAD still equals the HEAD
    # at marker creation time. This is a live session that hasn't started
    # work yet; the marker is still load-bearing.
    # Exception: if the heartbeat confirmed the session is dead, allow
    # cleanup even when HEAD hasn't changed — the session died before
    # doing any work (e.g. after /clear + terminal close).
    _cur_head=$(git -C "$_sb" rev-parse HEAD 2>/dev/null || true)
    if [ "$_cur_head" = "$_init_head" ]; then
      [ "$_hb_rc" -eq 2 ] || continue
    fi

    # In-progress state guards (see session-end.sh Phase 2 rationale).
    sb_has_in_progress_operation "$_sb" && continue
    git -C "$_sb" symbolic-ref -q HEAD >/dev/null 2>&1 || continue

    # Merged into main AND clean AND session did real work → marker is no
    # longer load-bearing.
    if git -C "$_sb" merge-base --is-ancestor "$_branch" "$MAIN_BRANCH" 2>/dev/null \
       && sb_scan_uncommitted "$_sb" --ignore-deletions >/dev/null 2>&1; then
      rm -f "$mf" "${mf}.hb" 2>/dev/null || true
      sb_cleanup_log "$ROOT" "RELEASE" "$(basename "$mf")" "$_branch" "lifecycle-phase3-proactive-release"
    fi
  done
fi

# Phase 4: try to clean each linked worktree
# Collect marker-protected branches (still-alive sessions)
PROTECTED=""
if [ -d "$MARKERS_DIR" ]; then
  for mf in "$MARKERS_DIR"/*; do
    [ -f "$mf" ] || continue
    [[ "$(basename "$mf")" == *.hb ]] && continue   # skip heartbeat sidecar files
    v=$(sb_marker_read_value "$mf")
    [ -n "$v" ] && PROTECTED="$PROTECTED $v "
  done
fi

while IFS="	" read -r WT_PATH WT_BRANCH; do
  [ -z "$WT_PATH" ] && continue
  [ "$WT_PATH" = "$GIT_ROOT" ] && continue
  [ "$WT_BRANCH" = "$MAIN_BRANCH" ] && continue

  # Respect marker protection
  case "$PROTECTED" in
    *" $WT_BRANCH "*) continue ;;
  esac

  status=$(sb_wt_remove_if_merged "$GIT_ROOT" "$WT_PATH" "$WT_BRANCH" "$MAIN_BRANCH" "stale") || true
  case "$status" in
    "REMOVED "*)
      REMOVED=$((REMOVED + 1)); LINES="${LINES}${status}\n"
      sb_cleanup_log "$ROOT" "DESTROY" "-" "$WT_BRANCH" "lifecycle-phase4-wt-remove"
      ;;
    "PRESERVED "*)
      LINES="${LINES}${status}\n"
      sb_cleanup_log "$ROOT" "PRESERVE" "-" "$WT_BRANCH" "lifecycle-phase4-preserve"
      ;;
  esac
done <<SBL
$(sb_list_worktrees "$GIT_ROOT")
SBL

# Phase 5: orphan branches matching prefix
ORPHAN_OUT=$(sb_wt_sweep_orphan_branches "$GIT_ROOT" "$PREFIX" "$MAIN_BRANCH")
[ -n "$ORPHAN_OUT" ] && LINES="${LINES}${ORPHAN_OUT}\n"

# Phase 6: residual directory sweep
SB_WT_DIR="$GIT_ROOT/$WT_DIR"
if [ -d "$SB_WT_DIR" ]; then
  RESIDUAL=$(sb_wt_sweep_residual_dirs "$SB_WT_DIR")
  [ -n "$RESIDUAL" ] && LINES="${LINES}${RESIDUAL}\n"
fi

if [ -n "$LINES" ]; then
  printf 'sandbox-lifecycle: cleaned=%d\n' "$REMOVED"
  printf '%b' "$LINES"
fi
exit 0
