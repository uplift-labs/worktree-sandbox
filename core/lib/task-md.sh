#!/bin/bash
# task-md.sh — TASK.md parsing and validation primitives.
#
# TASK.md schema (the only shape treated as valid):
#   ---
#   created: YYYY-MM-DD
#   purpose: <one-line goal>
#   ---
#   ## Tasks
#   - [ ] <deliverable>
#   - [x] <done>
#
# Public functions:
#   sb_task_unchecked_count <file>   echo integer (0 if missing)
#   sb_task_total_count <file>       echo integer
#   sb_task_purpose <file>           echo purpose value or empty
#   sb_task_created <file>           echo created value or empty
#   sb_task_is_placeholder <wt-dir>  exit 0 placeholder / 1 valid
#   sb_task_check_completion <wt>    exit 0 ok-or-missing / 1 unchecked;
#                                    echoes reason on failure
#   sb_task_context <wt>             echo "purpose: X | tasks: U/T | created: D"

sb_task_unchecked_count() {
  local file="$1"
  [ -f "$file" ] || { printf '0'; return 0; }
  local n
  n=$(grep -c '^[[:space:]]*- \[ \]' "$file" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

sb_task_total_count() {
  local file="$1"
  [ -f "$file" ] || { printf '0'; return 0; }
  local n
  n=$(grep -c '^[[:space:]]*- \[.\]' "$file" 2>/dev/null || true)
  printf '%s' "${n:-0}"
}

sb_task_purpose() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep '^purpose:' "$file" 2>/dev/null | head -1 | sed 's/^purpose:[[:space:]]*//'
}

sb_task_created() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep '^created:' "$file" 2>/dev/null | head -1 | sed 's/^created:[[:space:]]*//'
}

sb_task_is_placeholder() {
  local wt="$1"
  local file="$wt/TASK.md"
  [ ! -f "$file" ] && return 0

  local purpose total ph
  purpose=$(sb_task_purpose "$file")
  [ -z "$purpose" ] && return 0
  case "$purpose" in *TODO*) return 0 ;; esac

  total=$(sb_task_total_count "$file")
  [ "$total" -eq 0 ] && return 0

  ph=$(grep -cE '^[[:space:]]*- \[.\].*(TODO|replace|<[^>]+>)' "$file" 2>/dev/null || true)
  ph=${ph:-0}
  [ "$ph" -ge "$total" ] && return 0
  return 1
}

sb_task_check_completion() {
  local wt="$1"
  local file="$wt/TASK.md"
  [ ! -f "$file" ] && return 0

  local uc tc purpose
  uc=$(sb_task_unchecked_count "$file")
  [ "$uc" -eq 0 ] && return 0

  tc=$(sb_task_total_count "$file")
  purpose=$(sb_task_purpose "$file")
  printf 'TASK.md has %s/%s unchecked task(s) (purpose: %s). Check off completed items or drop tasks no longer needed.' \
    "$uc" "$tc" "${purpose:-unknown}"
  return 1
}

sb_task_context() {
  local wt="$1"
  local file="$wt/TASK.md"
  [ ! -f "$file" ] && return 0
  local purpose created uc tc
  purpose=$(sb_task_purpose "$file")
  created=$(sb_task_created "$file")
  uc=$(sb_task_unchecked_count "$file")
  tc=$(sb_task_total_count "$file")
  printf 'purpose: %s | tasks: %s/%s unchecked' "${purpose:-unknown}" "$uc" "$tc"
  [ -n "$created" ] && printf ' | created: %s' "$created"
}
