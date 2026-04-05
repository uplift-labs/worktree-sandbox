#!/bin/bash
# Unit tests for core/lib/task-md.sh
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/task-md.sh"

fixture_init
trap fixture_cleanup EXIT

WT="$FIXTURE_ROOT/wt"
mkdir -p "$WT"

echo "== missing TASK.md =="
assert_eq "unchecked=0" "0" "$(sb_task_unchecked_count "$WT/TASK.md")"
assert_eq "total=0" "0" "$(sb_task_total_count "$WT/TASK.md")"
sb_task_is_placeholder "$WT"; assert_exit "missing is placeholder" 0 $?
sb_task_check_completion "$WT"; assert_exit "missing passes check" 0 $?

echo "== placeholder purpose =="
cat > "$WT/TASK.md" << 'TM1'
---
purpose: TODO — replace me
---
## Tasks
- [ ] TODO — replace
TM1
sb_task_is_placeholder "$WT"; assert_exit "TODO purpose is placeholder" 0 $?

echo "== all checkboxes placeholder text =="
cat > "$WT/TASK.md" << 'TM2'
---
purpose: Real goal
---
## Tasks
- [ ] TODO item one
- [ ] <describe>
TM2
sb_task_is_placeholder "$WT"; assert_exit "all placeholder boxes = placeholder" 0 $?

echo "== valid filled TASK.md =="
cat > "$WT/TASK.md" << 'TM3'
---
created: 2026-04-05
purpose: Ship the feature
---
## Tasks
- [x] First done
- [ ] Second pending
TM3
sb_task_is_placeholder "$WT"; assert_exit "valid is NOT placeholder" 1 $?
assert_eq "unchecked=1" "1" "$(sb_task_unchecked_count "$WT/TASK.md")"
assert_eq "total=2" "2" "$(sb_task_total_count "$WT/TASK.md")"
assert_eq "purpose" "Ship the feature" "$(sb_task_purpose "$WT/TASK.md")"
assert_eq "created" "2026-04-05" "$(sb_task_created "$WT/TASK.md")"

echo "== check_completion blocks with unchecked =="
reason=$(sb_task_check_completion "$WT" || true)
assert_contains "reason mentions unchecked" "1/2 unchecked" "$reason"
assert_contains "reason mentions purpose" "Ship the feature" "$reason"

echo "== all checked passes check =="
cat > "$WT/TASK.md" << 'TM4'
---
created: 2026-04-05
purpose: Done
---
## Tasks
- [x] One
- [x] Two
TM4
sb_task_check_completion "$WT" >/dev/null; assert_exit "all checked passes" 0 $?

echo "== context string =="
got=$(sb_task_context "$WT")
assert_contains "has purpose" "Done" "$got"
assert_contains "has tasks" "0/2" "$got"
assert_contains "has created" "2026-04-05" "$got"

test_summary
