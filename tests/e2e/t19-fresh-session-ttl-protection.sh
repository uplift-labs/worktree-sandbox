#!/bin/bash
# t19 — fresh sessions (HEAD == init_head, no heartbeat) use FRESH_SESSION_TTL
# instead of the standard short TTL. This prevents lifecycle from reaping live
# sessions whose heartbeat died (e.g., parent PID resolution raced on MSYS).
#
# Scenarios:
#   1. Marker stale by standard TTL but within FRESH_SESSION_TTL → survives
#   2. Marker past FRESH_SESSION_TTL → reaped
#   3. Session with commits uses standard TTL → marker reaped quickly
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t19")

# ---- Scenario 1: fresh session, mtime stale by short TTL, within 5-min TTL ----
echo "== fresh session survives standard TTL (protected by FRESH_SESSION_TTL) =="
SESSION1="t19-fresh-survives"
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION1")
MARKER1="$REPO/.git/sandbox-markers/$SESSION1"

assert_file_exists "marker1 created" "$MARKER1"
assert_dir_exists "sandbox1 created" "$SB1"

# Backdate marker by 60 seconds — well past the default TTL (5s) and the
# 30-second grace period, but within FRESH_SESSION_TTL (300s).
touch -t "$(date -d '-60 seconds' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-60S '+%Y%m%d%H%M.%S')" "$MARKER1"

# Run lifecycle with short TTL (same as production default).
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null
assert_file_exists "fresh marker survives short TTL" "$MARKER1"
assert_dir_exists "fresh sandbox survives short TTL" "$SB1"

# ---- Scenario 2: fresh session, mtime past FRESH_SESSION_TTL → reaped ----
echo "== fresh session past FRESH_SESSION_TTL gets reaped =="
SESSION2="t19-fresh-expired"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
BRANCH2=$(basename "$SB2")
MARKER2="$REPO/.git/sandbox-markers/$SESSION2"

assert_file_exists "marker2 created" "$MARKER2"

# Backdate marker by 6 minutes — past FRESH_SESSION_TTL (300s).
touch -t "$(date -d '-6 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-6M '+%Y%m%d%H%M.%S')" "$MARKER2"
# Also backdate creation epoch in marker content so 30s grace doesn't protect.
_branch2=$(awk '{print $1}' "$MARKER2")
_init2=$(awk '{print $3}' "$MARKER2")
_old_epoch=$(( $(date +%s) - 400 ))
printf '%s %s %s' "$_branch2" "$_old_epoch" "$_init2" > "$MARKER2"
# Re-backdate mtime (printf overwrites it).
touch -t "$(date -d '-6 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-6M '+%Y%m%d%H%M.%S')" "$MARKER2"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null
assert_file_absent "expired fresh marker reaped" "$MARKER2"

# ---- Scenario 3: session WITH commits uses standard TTL ----
echo "== session with commits uses standard TTL (marker reaped quickly) =="
SESSION3="t19-committed"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
BRANCH3=$(basename "$SB3")
MARKER3="$REPO/.git/sandbox-markers/$SESSION3"

# Make a commit so HEAD != init_head.
echo "work" > "$SB3/work.txt"
(cd "$SB3" && git add work.txt && git commit -q -m "feat: actual work")

# Backdate marker by 60 seconds — past standard TTL.
touch -t "$(date -d '-60 seconds' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-60S '+%Y%m%d%H%M.%S')" "$MARKER3"
# Also backdate creation epoch.
_branch3=$(awk '{print $1}' "$MARKER3")
_init3=$(awk '{print $3}' "$MARKER3")
_old_epoch3=$(( $(date +%s) - 60 ))
printf '%s %s %s' "$_branch3" "$_old_epoch3" "$_init3" > "$MARKER3"
touch -t "$(date -d '-60 seconds' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-60S '+%Y%m%d%H%M.%S')" "$MARKER3"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null
assert_file_absent "committed session marker reaped by standard TTL" "$MARKER3"

# Sandbox1 (fresh, still within FRESH_SESSION_TTL) must STILL be alive.
assert_file_exists "scenario1 session still protected" "$MARKER1"
assert_dir_exists "scenario1 sandbox still alive" "$SB1"

test_summary
