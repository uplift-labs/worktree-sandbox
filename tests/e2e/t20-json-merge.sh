#!/bin/bash
# t20 — json-merge.py idempotent hook merging.
# Covers:
#   - Fresh merge into nonexistent target.
#   - Idempotent: merge twice produces same result.
#   - User hooks preserved during merge.
#   - Sandbox hook updated (not duplicated) on re-merge.
#   - --uninstall removes only sandbox hooks.
#   - Empty result after uninstall deletes target file.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"

MERGER="$ROOT/core/lib/json-merge.py"
SNIPPET="$ROOT/adapters/claude-code/settings-hooks.json"
TMPDIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'sbx-merge')
trap 'rm -rf "$TMPDIR"' EXIT

echo "== 1. fresh merge into nonexistent target =="
TARGET="$TMPDIR/fresh/.claude/settings.json"
python3 "$MERGER" "$TARGET" "$SNIPPET"
ec=$?
assert_exit "fresh merge exits 0" 0 "$ec"
assert_file_exists "target created" "$TARGET"
# Must contain all 4 event types from the snippet.
for event in SessionStart PreToolUse Stop SessionEnd; do
  assert_contains "has $event" "$event" "$(cat "$TARGET")"
done

echo "== 2. idempotent: merge twice produces same result =="
FIRST=$(cat "$TARGET")
python3 "$MERGER" "$TARGET" "$SNIPPET"
SECOND=$(cat "$TARGET")
assert_eq "idempotent merge" "$FIRST" "$SECOND"

echo "== 3. user hooks preserved =="
# Inject a user hook into PreToolUse Bash matcher (not sandbox).
cat > "$TMPDIR/with-user.json" <<'USERJSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash /my/custom/guard.sh"
          }
        ]
      }
    ]
  }
}
USERJSON
TARGET2="$TMPDIR/user-test/.claude/settings.json"
mkdir -p "$(dirname "$TARGET2")"
cp "$TMPDIR/with-user.json" "$TARGET2"
python3 "$MERGER" "$TARGET2" "$SNIPPET"
ec=$?
assert_exit "merge with user hooks exits 0" 0 "$ec"
assert_contains "user hook preserved" "/my/custom/guard.sh" "$(cat "$TARGET2")"
# Sandbox hooks also present.
assert_contains "sandbox hooks added" ".sandbox/adapter/hooks/" "$(cat "$TARGET2")"

echo "== 4. sandbox hook updated, not duplicated =="
# Merge again — should not create a second copy of sandbox hooks.
python3 "$MERGER" "$TARGET2" "$SNIPPET"
# Count occurrences of session-start.sh — must be exactly 1.
COUNT=$(grep -o 'session-start\.sh' "$TARGET2" | wc -l)
assert_eq "no duplicate session-start hook" 1 "$((COUNT))"
# User hook still there.
assert_contains "user hook still preserved" "/my/custom/guard.sh" "$(cat "$TARGET2")"

echo "== 5. --uninstall removes only sandbox hooks =="
python3 "$MERGER" "$TARGET2" "$SNIPPET" --uninstall
ec=$?
assert_exit "uninstall exits 0" 0 "$ec"
assert_contains "user hook survives uninstall" "/my/custom/guard.sh" "$(cat "$TARGET2")"
assert_not_contains "sandbox hooks removed" ".sandbox/adapter/hooks/" "$(cat "$TARGET2")"

echo "== 6. uninstall everything → target file deleted =="
# Start with sandbox-only settings.
TARGET3="$TMPDIR/clean/.claude/settings.json"
python3 "$MERGER" "$TARGET3" "$SNIPPET"
assert_file_exists "target exists before uninstall" "$TARGET3"
python3 "$MERGER" "$TARGET3" "$SNIPPET" --uninstall
assert_file_absent "target deleted after full uninstall" "$TARGET3"

echo "== 7. non-hook keys in settings.json preserved =="
TARGET4="$TMPDIR/extra/.claude/settings.json"
mkdir -p "$(dirname "$TARGET4")"
cat > "$TARGET4" <<'EXTRAJSON'
{
  "allowedTools": ["Bash", "Read"],
  "permissions": {"allow": ["read"]}
}
EXTRAJSON
python3 "$MERGER" "$TARGET4" "$SNIPPET"
assert_contains "allowedTools preserved" "allowedTools" "$(cat "$TARGET4")"
assert_contains "permissions preserved" "permissions" "$(cat "$TARGET4")"
assert_contains "hooks added" ".sandbox/adapter/hooks/" "$(cat "$TARGET4")"

test_summary
