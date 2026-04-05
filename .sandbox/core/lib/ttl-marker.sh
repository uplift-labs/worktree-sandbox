#!/bin/bash
# ttl-marker.sh — filesystem marker primitives with explicit TTL.
#
# Markers are small files whose mtime acts as a heartbeat and whose first line
# is "<value> <created_epoch>". The TTL is always passed explicitly by the
# caller — no hardcoded defaults. Crashed sessions leave immortal markers that
# block automated cleanup; TTL is the only safe escape hatch.
#
# Public functions:
#   sb_marker_write <path> <value>               write "<value> <now_epoch>"
#   sb_marker_read_value <path>                  echo first whitespace field
#   sb_marker_read_epoch <path>                  echo second whitespace field
#   sb_marker_touch <path>                       heartbeat: refresh mtime
#   sb_marker_is_fresh <path> <ttl-seconds>      exit 0 = fresh, 1 = stale/missing
#   sb_marker_prune_stale <glob> <ttl-seconds>   delete stale files matching glob

sb_marker_write() {
  local path="$1" value="$2"
  mkdir -p "$(dirname "$path")" 2>/dev/null
  printf '%s %s' "$value" "$(date +%s)" > "$path"
}

sb_marker_read_value() {
  local path="$1"
  [ -f "$path" ] || return 1
  awk '{print $1}' "$path" 2>/dev/null
}

sb_marker_read_epoch() {
  local path="$1"
  [ -f "$path" ] || return 1
  awk '{print $2}' "$path" 2>/dev/null
}

sb_marker_touch() {
  local path="$1"
  [ -f "$path" ] && touch "$path" 2>/dev/null
}

sb_marker_is_fresh() {
  local path="$1" ttl="$2"
  [ -f "$path" ] || return 1
  local mtime now age
  mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -lt "$ttl" ]
}

sb_marker_prune_stale() {
  local glob="$1" ttl="$2"
  local mins=$(( (ttl + 59) / 60 ))
  local dir pattern
  dir=$(dirname "$glob")
  pattern=$(basename "$glob")
  find "$dir" -maxdepth 1 -name "$pattern" -type f -mmin "+$mins" -delete 2>/dev/null || true
}
