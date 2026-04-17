#!/bin/bash
# t15 — post-merge hook auto-syncs .uplift/sandbox/ after merge.
# Covers:
#   - install.sh writes a post-merge hook
#   - After a merge, .uplift/sandbox/ core files are updated automatically
#   - Tampered installed files get restored by post-merge
#
# The post-merge hook calls $REPO_ROOT/install.sh, so this test mirrors
# the self-hosting layout: source tree (core/, adapters/, install.sh) lives
# at the repo root alongside .uplift/sandbox/.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

echo "== install.sh creates post-merge hook =="
REPO=$(fixture_repo "t15")

# Mirror the self-hosting layout: copy source tree into the test repo
cp -r "$ROOT/core" "$REPO/core"
cp -r "$ROOT/adapters" "$REPO/adapters"
cp "$ROOT/install.sh" "$REPO/install.sh"
(cd "$REPO" && git add -A && git commit -q -m "chore: add source tree")

bash "$REPO/install.sh" --target "$REPO" --with-claude-code >/dev/null 2>&1
GIT_COMMON=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null)
case "$GIT_COMMON" in
  /*|[A-Za-z]:*) ;;
  *) GIT_COMMON="$REPO/$GIT_COMMON" ;;
esac

assert_file_exists "post-merge hook installed" "$GIT_COMMON/hooks/post-merge"

echo "== tamper installed file to detect re-sync =="
echo "TAMPERED" > "$REPO/.uplift/sandbox/core/lib/heartbeat.sh"
BEFORE=$(cat "$REPO/.uplift/sandbox/core/lib/heartbeat.sh")
assert_contains "file is tampered" "TAMPERED" "$BEFORE"

echo "== post-merge hook restores files after merge =="
# Create a feature branch, commit, and merge to trigger post-merge
(cd "$REPO" && git checkout -q -b feat-dummy)
echo "dummy" > "$REPO/dummy.txt"
(cd "$REPO" && git add dummy.txt && git commit -q -m "feat: dummy")
(cd "$REPO" && git checkout -q main && git merge -q feat-dummy --no-edit)

# post-merge runs in background; give it a moment
sleep 3

AFTER=$(head -1 "$REPO/.uplift/sandbox/core/lib/heartbeat.sh")
assert_not_contains "tampered file restored" "TAMPERED" "$AFTER"
assert_contains "restored file has shebang" "#!/bin/bash" "$AFTER"

echo "== post-merge detects --with-claude-code from existing adapter dir =="
assert_file_exists "adapter still present after post-merge" "$REPO/.uplift/sandbox/adapter/hooks/session-start.sh"

test_summary
