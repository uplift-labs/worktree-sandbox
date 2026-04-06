#!/bin/bash
# json-field.sh — extract a JSON string value by key.
# Tolerates both compact {"key":"val"} and pretty-printed {"key": "val"}.
# This is a minimal, dependency-free alternative to jq for hot-path hook use.
# Source: adapted from guards/core/lib/json-field.sh.

json_field() {
  local key="$1" json="$2"
  printf '%s' "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
    | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
}
