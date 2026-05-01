#!/bin/bash
# json-field.sh — small JSON helpers for Codex hook wrappers.

json_field() {
  local key="$1" json="$2"
  printf '%s' "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
}

json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}
