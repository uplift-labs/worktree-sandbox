#!/bin/bash
# assert.sh — shared test assertions.

T_TOTAL=${T_TOTAL:-0}
T_PASS=${T_PASS:-0}
T_FAIL=${T_FAIL:-0}

_t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }
_t_pass() { T_PASS=$((T_PASS + 1)); }

assert_eq() {
  T_TOTAL=$((T_TOTAL + 1))
  if [ "$2" = "$3" ]; then _t_pass; else _t_fail "$1 — expected [$2], got [$3]"; fi
}
assert_exit() { assert_eq "$1" "$2" "$3"; }

assert_contains() {
  T_TOTAL=$((T_TOTAL + 1))
  if printf '%s' "$3" | grep -q -- "$2"; then _t_pass
  else _t_fail "$1 — output should contain [$2]"; printf '  GOT: %s\n' "$3" >&2; fi
}

assert_not_contains() {
  T_TOTAL=$((T_TOTAL + 1))
  if printf '%s' "$3" | grep -q -- "$2"; then
    _t_fail "$1 — output should NOT contain [$2]"
    printf '  GOT: %s\n' "$3" >&2
  else _t_pass; fi
}

assert_file_exists() {
  T_TOTAL=$((T_TOTAL + 1))
  if [ -f "$2" ]; then _t_pass; else _t_fail "$1 — file missing: $2"; fi
}
assert_file_absent() {
  T_TOTAL=$((T_TOTAL + 1))
  if [ ! -e "$2" ]; then _t_pass; else _t_fail "$1 — should be absent: $2"; fi
}
assert_dir_exists() {
  T_TOTAL=$((T_TOTAL + 1))
  if [ -d "$2" ]; then _t_pass; else _t_fail "$1 — dir missing: $2"; fi
}
assert_dir_absent() {
  T_TOTAL=$((T_TOTAL + 1))
  if [ ! -d "$2" ]; then _t_pass; else _t_fail "$1 — dir should be absent: $2"; fi
}

test_summary() {
  printf 'results: total=%d pass=%d fail=%d\n' "$T_TOTAL" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -gt 0 ] && return 1
  return 0
}
