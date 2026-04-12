#!/bin/bash
# Unit tests for core/cmd/reflection-rescue.sh
#
# 5 cases, covering: orphan rescue, dedup, empty worktrees, idempotency,
# multiple worktrees in one pass, and custom REFLECTION_RESCUE_DIR.

set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

RESCUE="$ROOT/core/cmd/reflection-rescue.sh"

fixture_init
trap fixture_cleanup EXIT

# --- TP-1: orphan rescue — file in worktree, absent in main ---
echo "== TP-1: orphan rescue =="
T1="$FIXTURE_ROOT/tp1"
mkdir -p "$T1/.sandbox/worktrees/sandbox-session-abc/.reinforce/reflections"
mkdir -p "$T1/.reinforce/reflections"
printf 'orphan content' > "$T1/.sandbox/worktrees/sandbox-session-abc/.reinforce/reflections/2026-01-01.md"

OUT1=$(bash "$RESCUE" --repo "$T1" 2>&1)
assert_contains "TP1: rescued line" "rescued:" "$OUT1"
assert_file_exists "TP1: file landed in main" "$T1/.reinforce/reflections/2026-01-01.md"
assert_file_absent "TP1: removed from worktree" "$T1/.sandbox/worktrees/sandbox-session-abc/.reinforce/reflections/2026-01-01.md"
CONTENT=$(cat "$T1/.reinforce/reflections/2026-01-01.md")
assert_eq "TP1: content preserved" "orphan content" "$CONTENT"

# --- TP-2: dedup — same file in both main and worktree ---
echo "== TP-2: dedup =="
T2="$FIXTURE_ROOT/tp2"
mkdir -p "$T2/.sandbox/worktrees/sandbox-session-def/.reinforce/reflections"
mkdir -p "$T2/.reinforce/reflections"
printf 'main copy' > "$T2/.reinforce/reflections/dup.md"
printf 'wt copy' > "$T2/.sandbox/worktrees/sandbox-session-def/.reinforce/reflections/dup.md"

OUT2=$(bash "$RESCUE" --repo "$T2" 2>&1)
assert_contains "TP2: deduped line" "deduped:" "$OUT2"
assert_file_absent "TP2: removed from worktree" "$T2/.sandbox/worktrees/sandbox-session-def/.reinforce/reflections/dup.md"
MAIN_CONTENT=$(cat "$T2/.reinforce/reflections/dup.md")
assert_eq "TP2: main copy untouched" "main copy" "$MAIN_CONTENT"

# --- TN-1: empty worktrees — silent no-op ---
echo "== TN-1: empty worktrees =="
T3="$FIXTURE_ROOT/tn1"
mkdir -p "$T3/.sandbox/worktrees/sandbox-session-ghi"
mkdir -p "$T3/.reinforce/reflections"

OUT3=$(bash "$RESCUE" --repo "$T3" 2>&1)
assert_eq "TN1: no output" "" "$OUT3"

# --- IDEM: second run converges ---
echo "== IDEM: idempotency =="
OUT1B=$(bash "$RESCUE" --repo "$T1" 2>&1)
assert_eq "IDEM: second run produces no output" "" "$OUT1B"

# --- MULTI: multiple worktrees in one pass ---
echo "== MULTI: multiple worktrees =="
T5="$FIXTURE_ROOT/multi"
mkdir -p "$T5/.sandbox/worktrees/sandbox-session-aaa/.reinforce/reflections"
mkdir -p "$T5/.sandbox/worktrees/sandbox-session-bbb/.reinforce/reflections"
mkdir -p "$T5/.reinforce/reflections"
printf 'orphan-a' > "$T5/.sandbox/worktrees/sandbox-session-aaa/.reinforce/reflections/a.md"
printf 'main-b' > "$T5/.reinforce/reflections/b.md"
printf 'dup-b' > "$T5/.sandbox/worktrees/sandbox-session-bbb/.reinforce/reflections/b.md"
printf 'orphan-c' > "$T5/.sandbox/worktrees/sandbox-session-bbb/.reinforce/reflections/c.md"

OUT5=$(bash "$RESCUE" --repo "$T5" 2>&1)
assert_contains "MULTI: rescued line" "rescued:" "$OUT5"
assert_contains "MULTI: deduped line" "deduped:" "$OUT5"
assert_file_exists "MULTI: a.md in main" "$T5/.reinforce/reflections/a.md"
assert_file_exists "MULTI: c.md in main" "$T5/.reinforce/reflections/c.md"
assert_file_absent "MULTI: b.md removed from wt" "$T5/.sandbox/worktrees/sandbox-session-bbb/.reinforce/reflections/b.md"

# --- ENV: custom REFLECTION_RESCUE_DIR ---
echo "== ENV: custom REFLECTION_RESCUE_DIR =="
T6="$FIXTURE_ROOT/env"
mkdir -p "$T6/.sandbox/worktrees/sandbox-session-xyz/custom/data"
mkdir -p "$T6/custom/data"
printf 'custom orphan' > "$T6/.sandbox/worktrees/sandbox-session-xyz/custom/data/note.md"

OUT6=$(REFLECTION_RESCUE_DIR="custom/data" bash "$RESCUE" --repo "$T6" 2>&1)
assert_contains "ENV: rescued line" "rescued:" "$OUT6"
assert_file_exists "ENV: file in main custom dir" "$T6/custom/data/note.md"
assert_file_absent "ENV: removed from worktree" "$T6/.sandbox/worktrees/sandbox-session-xyz/custom/data/note.md"

test_summary
