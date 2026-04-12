#!/bin/bash
# Unit tests for sb_marker_write error propagation + atomicity.
#
# Covers:
#   - sb_marker_write returns non-zero on mkdir/printf/mv failure
#     and never leaves partially-written markers.
#   - Atomic rename guarantees complete-or-absent semantics.
#
# Cross-platform: uses "parent path is a regular file" to force mkdir
# failures (chmod -w on dirs is a no-op on MSYS/Windows).

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

echo "== happy path with initial_head =="
M1="$FIXTURE_ROOT/ok/with-head"
sb_marker_write "$M1" branch-foo abc123; rc=$?
assert_eq "write returns 0" "0" "$rc"
assert_file_exists "marker file exists" "$M1"
_fields=$(awk '{print NF}' "$M1")
assert_eq "marker has 3 fields (value epoch head)" "3" "$_fields"

echo "== happy path without initial_head =="
M2="$FIXTURE_ROOT/ok/no-head"
sb_marker_write "$M2" branch-bar ""; rc=$?
assert_eq "write returns 0 (no head)" "0" "$rc"
_fields=$(awk '{print NF}' "$M2")
assert_eq "marker has 2 fields (value epoch)" "2" "$_fields"

echo "== mkdir fails: parent path is a regular file =="
FILE_PARENT="$FIXTURE_ROOT/is-a-file"
printf 'blocker' > "$FILE_PARENT"
M3="$FILE_PARENT/should-fail"
sb_marker_write "$M3" branch-baz head123 2>/dev/null; rc=$?
assert_eq "mkdir fails (parent is file): non-zero RC" "1" "$rc"
assert_file_absent "mkdir fails: no marker left behind" "$M3"

echo "== mkdir fails deeper in the chain =="
M4="$FILE_PARENT/deeply/nested/marker"
sb_marker_write "$M4" branch-qux "" 2>/dev/null; rc=$?
assert_eq "mkdir fails (nested): non-zero RC" "1" "$rc"
assert_file_absent "mkdir fails (nested): no marker" "$M4"

echo "== no .tmp.* droppings after successful write =="
M_CLEAN="$FIXTURE_ROOT/ok/clean-check"
sb_marker_write "$M_CLEAN" branch-clean head-clean
_tmp_count=$(find "$(dirname "$M_CLEAN")" -maxdepth 1 -name "*.tmp.*" 2>/dev/null | wc -l)
assert_eq "happy-path: no .tmp.* droppings" "0" "$(echo "$_tmp_count" | tr -d '[:space:]')"

echo "== atomicity: written marker reads back correctly =="
M5="$FIXTURE_ROOT/ok/atomic"
sb_marker_write "$M5" branch-atomic headXYZ; rc=$?
assert_eq "atomic write returns 0" "0" "$rc"
v=$(sb_marker_read_value "$M5")
assert_eq "read_value returns branch-atomic" "branch-atomic" "$v"
h=$(sb_marker_read_initial_head "$M5")
assert_eq "read_initial_head returns headXYZ" "headXYZ" "$h"
e=$(sb_marker_read_epoch "$M5")
assert_contains "read_epoch is numeric" "^[0-9]" "$e"

test_summary
