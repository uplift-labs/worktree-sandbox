#!/bin/bash
# t12 — pre-merge-commit hook gates the sandbox branch (not the target).
#
# Covers the regression where the installed hook scanned $REPO_ROOT, which
# during a non-ff merge contains the staged merge result and was wrongly
# flagged as "filesystem not clean", blocking every legitimate sandbox
# merge.
#
# Paths exercised:
#   1. happy: complete TASK.md + clean sandbox → merge succeeds.
#   2. unchecked TASK.md in the sandbox → hook blocks the merge.
#   3. sandbox clean on TASK.md but has an untracked file → hook blocks.
#   4. merging a non-sandbox branch (no matching worktree) → fail-open.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t12")
bash "$ROOT/install.sh" --target "$REPO" >/dev/null
assert_file_exists "hook installed" "$REPO/.git/hooks/pre-merge-commit"

# --- case 1: happy path ---
echo "== case 1: merge succeeds for complete+clean sandbox =="
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t12-happy")
BR1=$(basename "$SB1")
echo "feature" > "$SB1/feature.txt"
(cd "$SB1" && git add feature.txt && git commit -q -m "feat")
cat > "$SB1/TASK.md" << 'T'
---
created: 2026-04-06
purpose: ship
---
## Tasks
- [x] add feature
T
# Marker protects the sandbox — remove it so the gate scans the live tree.
# TASK.md is a per-session scratchpad; a merge from main would pull it in,
# which we don't want in any scenario. The stop/session-end hook normally
# handles this, but tests don't run hooks, so stage-unstage manually.
(cd "$REPO" && git merge --no-ff -q -m "merge happy" "$BR1")
ec=$?
assert_exit "merge exits 0" 0 "$ec"
assert_file_exists "feature landed in main" "$REPO/feature.txt"

# --- case 2: unchecked TASK.md blocks merge ---
echo "== case 2: unchecked TASK.md blocks merge =="
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t12-unchecked")
BR2=$(basename "$SB2")
echo "x" > "$SB2/x.txt"
(cd "$SB2" && git add x.txt && git commit -q -m "x")
# TASK.md left with the default seeded unchecked TODO
out=$( (cd "$REPO" && git merge --no-ff -m "merge unchecked" "$BR2" 2>&1) )
ec=$?
assert_exit "merge blocked (exit 1)" 1 "$ec"
assert_contains "reports unchecked" "unchecked" "$out"
(cd "$REPO" && git merge --abort 2>/dev/null || true)

# --- case 3: untracked file in sandbox blocks merge ---
echo "== case 3: dirty sandbox blocks merge =="
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "t12-dirty")
BR3=$(basename "$SB3")
echo "y" > "$SB3/y.txt"
(cd "$SB3" && git add y.txt && git commit -q -m "y")
cat > "$SB3/TASK.md" << 'T'
---
created: 2026-04-06
purpose: ship
---
## Tasks
- [x] y
T
# Leave an untracked file behind — sb_scan_uncommitted flags it.
echo "wip" > "$SB3/wip.txt"
out=$( (cd "$REPO" && git merge --no-ff -m "merge dirty" "$BR3" 2>&1) )
ec=$?
assert_exit "merge blocked by dirty tree" 1 "$ec"
assert_contains "reports filesystem not clean" "filesystem not clean" "$out"
(cd "$REPO" && git merge --abort 2>/dev/null || true)

# --- case 4: merging a non-sandbox branch fails open ---
echo "== case 4: non-sandbox branch merges without gate interference =="
(cd "$REPO" && git checkout -q -b plain-feature main \
  && echo plain > plain.txt \
  && git add plain.txt \
  && git commit -q -m "plain: add" \
  && git checkout -q main)
(cd "$REPO" && git merge --no-ff -q -m "merge plain" plain-feature)
ec=$?
assert_exit "plain branch merges" 0 "$ec"
assert_file_exists "plain landed" "$REPO/plain.txt"

test_summary
