#!/bin/bash
# t05 — two parallel sandbox-init calls for different sessions produce two
# distinct sandboxes without race/overlap.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t05")

# Launch both in background, capture stdout via files
OUT1="$FIXTURE_ROOT/out1"
OUT2="$FIXTURE_ROOT/out2"
bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t05-a" > "$OUT1" &
P1=$!
bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t05-b" > "$OUT2" &
P2=$!
wait $P1
e1=$?
wait $P2
e2=$?

assert_eq "p1 exit 0" "0" "$e1"
assert_eq "p2 exit 0" "0" "$e2"

SB_A=$(cat "$OUT1")
SB_B=$(cat "$OUT2")
assert_dir_exists "sb-a exists" "$SB_A"
assert_dir_exists "sb-b exists" "$SB_B"

T_TOTAL=$((T_TOTAL + 1))
if [ "$SB_A" != "$SB_B" ]; then
  T_PASS=$((T_PASS + 1))
else
  T_FAIL=$((T_FAIL + 1))
  printf '  FAIL: both sessions got same sandbox: %s\n' "$SB_A" >&2
fi

# Markers for both sessions must exist
assert_file_exists "marker a" "$REPO/.git/sandbox-markers/t05-a"
assert_file_exists "marker b" "$REPO/.git/sandbox-markers/t05-b"

# And marker values differ
VAL_A=$(awk '{print $1}' "$REPO/.git/sandbox-markers/t05-a")
VAL_B=$(awk '{print $1}' "$REPO/.git/sandbox-markers/t05-b")
T_TOTAL=$((T_TOTAL + 1))
if [ "$VAL_A" != "$VAL_B" ]; then
  T_PASS=$((T_PASS + 1))
else
  T_FAIL=$((T_FAIL + 1))
  printf '  FAIL: marker values identical: %s\n' "$VAL_A" >&2
fi

test_summary
