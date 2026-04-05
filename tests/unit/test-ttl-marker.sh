#!/bin/bash
# Unit tests for core/lib/ttl-marker.sh
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

M="$FIXTURE_ROOT/markers/hello.marker"

echo "== write and read =="
sb_marker_write "$M" "branch-name"
assert_file_exists "marker created" "$M"
assert_eq "value read" "branch-name" "$(sb_marker_read_value "$M")"
epoch=$(sb_marker_read_epoch "$M")
assert_contains "epoch numeric" "^[0-9]" "$epoch"
assert_eq "initial_head absent for legacy write" "" "$(sb_marker_read_initial_head "$M")"

echo "== write with initial_head =="
M3="$FIXTURE_ROOT/markers/with-head.marker"
sb_marker_write "$M3" "branch-x" "abc123deadbeef"
assert_eq "value read (3-arg)" "branch-x" "$(sb_marker_read_value "$M3")"
assert_eq "initial_head read" "abc123deadbeef" "$(sb_marker_read_initial_head "$M3")"
assert_contains "epoch still numeric (3-arg)" "^[0-9]" "$(sb_marker_read_epoch "$M3")"

echo "== is_fresh true for new =="
sb_marker_is_fresh "$M" 60; assert_exit "new is fresh (ttl 60s)" 0 $?

echo "== is_fresh false for missing =="
sb_marker_is_fresh "$FIXTURE_ROOT/nope" 60; assert_exit "missing is stale" 1 $?

echo "== is_fresh false for aged =="
# Backdate mtime by 120s
touch -t "$(date -d '-3 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-3M '+%Y%m%d%H%M.%S')" "$M"
sb_marker_is_fresh "$M" 60; assert_exit "aged is stale" 1 $?

echo "== touch refreshes =="
sb_marker_touch "$M"
sb_marker_is_fresh "$M" 60; assert_exit "refreshed is fresh" 0 $?

echo "== prune_stale removes old =="
OLD="$FIXTURE_ROOT/markers/old.marker"
NEW="$FIXTURE_ROOT/markers/new.marker"
sb_marker_write "$OLD" "old"
sb_marker_write "$NEW" "new"
touch -t "$(date -d '-2 hours' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-2H '+%Y%m%d%H%M.%S')" "$OLD"
sb_marker_prune_stale "$FIXTURE_ROOT/markers/*.marker" 60
assert_file_absent "old pruned" "$OLD"
assert_file_exists "new preserved" "$NEW"

test_summary
