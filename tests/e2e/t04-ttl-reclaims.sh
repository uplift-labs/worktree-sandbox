#!/bin/bash
# t04 — stale marker (TTL expired) gets pruned → its worktree is no longer
# protected → lifecycle can sweep the merged worktree.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t04")
SESSION="t04-crashed"
SB=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION")
BRANCH=$(basename "$SB")

# Merge the sandbox branch into main so it's eligible for removal
echo "done" > "$SB/done.txt"
(cd "$SB" && git add done.txt && git commit -q -m "feat: done")
(cd "$REPO" && git merge -q "$BRANCH")

MARKER="$REPO/.git/sandbox-markers/$SESSION"
assert_file_exists "marker exists" "$MARKER"

# Lifecycle with tiny TTL + backdate marker to simulate crashed session
touch -t "$(date -d '-2 hours' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-2H '+%Y%m%d%H%M.%S')" "$MARKER"

echo "== lifecycle with --ttl 60 reclaims stale marker =="
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 60)
assert_file_absent "stale marker pruned" "$MARKER"
assert_contains "reports removal" "REMOVED" "$out"
assert_dir_absent "sandbox swept" "$SB"

test_summary
