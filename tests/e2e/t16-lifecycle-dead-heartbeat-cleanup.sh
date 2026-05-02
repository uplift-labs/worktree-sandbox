#!/bin/bash
# t16 — lifecycle cleans sessions whose heartbeat PID is dead or orphaned.
# Covers:
#   - Session with dead heartbeat PID + expired TTL is cleaned
#   - Session with dead heartbeat PID but within grace period survives
#   - Heartbeat sidecar (.hb) files are cleaned along with markers
#   - Worktree directories are removed after marker cleanup
#   - Dead heartbeat PID + live owner PID preserves an active session
#   - Live heartbeat + dead parent winpid → lifecycle kills heartbeat + reclaims
#   - Live heartbeat + unknown parent (winpid=0) within 2h grace → survives
#   - Live heartbeat + unknown parent (winpid=0) past 2h grace → reclaimed
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"
. "$ROOT/core/lib/ttl-marker.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t16")
MARKERS="$REPO/.git/sandbox-markers"
mkdir -p "$MARKERS"

# ── 1. Dead heartbeat + stale mtime → lifecycle reclaims ─────────────
echo "== dead heartbeat + stale mtime → reclaimed =="

SESSION1="t16-dead-hb"
SB1=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION1")
BRANCH1=$(basename "$SB1")
MARKER1="$MARKERS/$SESSION1"
assert_file_exists "marker created" "$MARKER1"

# Merge so branch is ancestor of main
echo "work" > "$SB1/work.txt"
(cd "$SB1" && git add work.txt && git commit -q -m "feat: work")
(cd "$REPO" && git merge -q "$BRANCH1")

# Write a fake dead PID into sidecar (format: <hb_pid> <parent_winpid> <monitored_pid>)
printf '99999 0 0' > "${MARKER1}.hb"

# Backdate created_epoch past grace period and mtime past TTL
_val=$(sb_marker_read_value "$MARKER1")
_head=$(sb_marker_read_initial_head "$MARKER1")
printf '%s %s %s' "$_val" "1000000000" "$_head" > "$MARKER1"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER1"

# Lifecycle should reclaim
out=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (dead heartbeat)" "$MARKER1"
assert_file_absent "sidecar cleaned" "${MARKER1}.hb"
assert_dir_absent "worktree removed" "$SB1"

# ── 2. Dead heartbeat + no commits + fresh marker → still cleaned ────
# A dead heartbeat means the session is confirmed dead. Even if the marker
# is fresh and HEAD hasn't changed, Phase 3 should clean up because the
# branch is trivially an ancestor of main and the worktree is clean.
echo "== dead heartbeat + no commits + fresh marker → cleaned =="

SESSION2="t16-grace"
SB2=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2")
MARKER2="$MARKERS/$SESSION2"
assert_file_exists "fresh marker created" "$MARKER2"

# Write a fake dead PID but do NOT backdate the epoch — marker is fresh
printf '99998 0 0' > "${MARKER2}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_absent "marker cleaned (dead heartbeat, no work)" "$MARKER2"
assert_dir_absent "worktree cleaned (dead heartbeat, no work)" "$SB2"

# ── 2b. Dead heartbeat + live owner PID → preserved, then reclaimed ───
# Regression: OpenCode can leave a dead heartbeat PID in .hb while the owning
# OpenCode process is still alive.  Lifecycle must trust the live owner PID and
# not destroy the active session's clean/empty worktree.
echo "== dead heartbeat + live monitored PID → preserved, then cleaned after owner death =="

SESSION2B="t16-dead-hb-live-owner"
SB2B=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2B")
MARKER2B="$MARKERS/$SESSION2B"
assert_file_exists "live-owner marker created" "$MARKER2B"

sleep 9999 &
LIVE_OWNER_PID=$!
(exit 0) &
DEAD_HB_PID=$!
wait "$DEAD_HB_PID" 2>/dev/null || true
printf '%s %s %s' "$DEAD_HB_PID" "0" "$LIVE_OWNER_PID" > "${MARKER2B}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "dead heartbeat but live monitored PID preserves marker" "$MARKER2B"
assert_dir_exists "dead heartbeat but live monitored PID preserves worktree" "$SB2B"

kill "$LIVE_OWNER_PID" 2>/dev/null; wait "$LIVE_OWNER_PID" 2>/dev/null || true
bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_absent "marker cleaned after monitored PID exits" "$MARKER2B"
assert_file_absent "sidecar cleaned after monitored PID exits" "${MARKER2B}.hb"
assert_dir_absent "worktree cleaned after monitored PID exits" "$SB2B"

# ── 2c. Dead heartbeat + live Windows parent PID → preserved (MSYS) ─────
case "$(uname -s)" in
  MINGW*|MSYS*)
    echo "== dead heartbeat + live parent WINPID → preserved, then cleaned after parent death =="

    SESSION2C="t16-dead-hb-live-winparent"
    SB2C=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION2C")
    MARKER2C="$MARKERS/$SESSION2C"
    assert_file_exists "live-winparent marker created" "$MARKER2C"

    sleep 9999 &
    LIVE_PARENT_PID=$!
    LIVE_PARENT_WINPID=$(cat "/proc/$LIVE_PARENT_PID/winpid" 2>/dev/null || true)

    if [ -n "$LIVE_PARENT_WINPID" ]; then
      (exit 0) &
      DEAD_HB_WINPID=$!
      wait "$DEAD_HB_WINPID" 2>/dev/null || true
      printf '%s %s %s' "$DEAD_HB_WINPID" "$LIVE_PARENT_WINPID" "0" > "${MARKER2C}.hb"

      bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
      assert_file_exists "dead heartbeat but live WINPID preserves marker" "$MARKER2C"
      assert_dir_exists "dead heartbeat but live WINPID preserves worktree" "$SB2C"

      kill "$LIVE_PARENT_PID" 2>/dev/null; wait "$LIVE_PARENT_PID" 2>/dev/null || true
      bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
      assert_file_absent "marker cleaned after WINPID exits" "$MARKER2C"
      assert_file_absent "sidecar cleaned after WINPID exits" "${MARKER2C}.hb"
      assert_dir_absent "worktree cleaned after WINPID exits" "$SB2C"
    else
      printf 'SKIP: cannot resolve WINPID from /proc for live-parent regression\n'
      kill "$LIVE_PARENT_PID" 2>/dev/null; wait "$LIVE_PARENT_PID" 2>/dev/null || true
    fi
    ;;
esac

# ── 3. No sidecar at all + stale → TTL reclaim works ─────────────────
echo "== no sidecar + stale → TTL reclaims =="

SESSION3="t16-no-hb"
SB3=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION3")
BRANCH3=$(basename "$SB3")
MARKER3="$MARKERS/$SESSION3"

# Merge
echo "work3" > "$SB3/work3.txt"
(cd "$SB3" && git add work3.txt && git commit -q -m "feat: work3")
(cd "$REPO" && git merge -q "$BRANCH3")

# Backdate epoch + mtime, no sidecar
_val3=$(sb_marker_read_value "$MARKER3")
_head3=$(sb_marker_read_initial_head "$MARKER3")
printf '%s %s %s' "$_val3" "1000000000" "$_head3" > "$MARKER3"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER3"

out3=$(bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 2>&1)
assert_file_absent "marker cleaned (no sidecar + stale)" "$MARKER3"
assert_dir_absent "worktree removed (no sidecar)" "$SB3"

# Cleanup case 2 residuals (marker+sidecar already removed by lifecycle)
rm -f "$MARKER2" "${MARKER2}.hb" 2>/dev/null || true

# ── 4. Live heartbeat + dead parent winpid → lifecycle kills + reclaims ──
echo "== live heartbeat + dead parent winpid → reclaimed =="

SESSION4="t16-deadpar"
SB4=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION4")
BRANCH4=$(basename "$SB4")
MARKER4="$MARKERS/$SESSION4"

# Merge so branch is ancestor of main
echo "work4" > "$SB4/work4.txt"
(cd "$SB4" && git add work4.txt && git commit -q -m "feat: work4")
(cd "$REPO" && git merge -q "$BRANCH4")

# Launch a real background process to act as the heartbeat
sleep 9999 &
_fake_hb=$!

# Write sidecar with live PID + dead parent winpid (99999 is almost certainly dead)
# Field 3 = 0 (marker-only mode, no Unix PID monitoring)
printf '%s %s %s' "$_fake_hb" "99999" "0" > "${MARKER4}.hb"

# Backdate created_epoch past grace period and mtime past TTL
_val4=$(sb_marker_read_value "$MARKER4")
_head4=$(sb_marker_read_initial_head "$MARKER4")
printf '%s %s %s' "$_val4" "1000000000" "$_head4" > "$MARKER4"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER4"

# On non-Windows, tasklist is absent → parent check returns "alive" (can't verify).
# The test still validates the TTL fallback path after heartbeat is killed.
_is_msys=0
case "$(uname -s)" in MINGW*|MSYS*) _is_msys=1 ;; esac

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1

if [ "$_is_msys" = 1 ]; then
  # On MSYS: lifecycle detects dead parent via tasklist → kills heartbeat → reclaims
  assert_file_absent "marker cleaned (dead parent)" "$MARKER4"
  assert_file_absent "sidecar cleaned (dead parent)" "${MARKER4}.hb"
  assert_dir_absent "worktree removed (dead parent)" "$SB4"
  # Fake heartbeat should have been killed
  if kill -0 "$_fake_hb" 2>/dev/null; then
    echo "FAIL: fake heartbeat still alive after lifecycle"
    kill "$_fake_hb" 2>/dev/null; wait "$_fake_hb" 2>/dev/null || true
    T_FAIL=$((T_FAIL + 1)); T_TOTAL=$((T_TOTAL + 1))
  else
    echo "PASS: fake heartbeat killed by lifecycle"
    T_PASS=$((T_PASS + 1)); T_TOTAL=$((T_TOTAL + 1))
  fi
  wait "$_fake_hb" 2>/dev/null || true
else
  # On Linux/macOS: no tasklist → parent check returns 0 (can't verify) →
  # falls through to unknown-parent path → grace period applies.
  # Since epoch is backdated past ORPHAN_HB_GRACE (2h), orphan grace expired
  # → lifecycle kills the heartbeat anyway.
  assert_file_absent "marker cleaned (orphan grace expired, non-MSYS)" "$MARKER4"
  assert_file_absent "sidecar cleaned (orphan grace expired, non-MSYS)" "${MARKER4}.hb"
  kill "$_fake_hb" 2>/dev/null; wait "$_fake_hb" 2>/dev/null || true
fi

# ── 5. Live heartbeat + unknown parent (winpid=0) + within grace → survives ──
echo "== live heartbeat + unknown parent within grace → survives =="

SESSION5="t16-unkfresh"
SB5=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION5")
MARKER5="$MARKERS/$SESSION5"

# Launch a real background process to act as the heartbeat
sleep 9999 &
_fake_hb5=$!

# Write sidecar with live PID + unknown parent (0) — marker epoch is fresh (now)
printf '%s %s %s' "$_fake_hb5" "0" "0" > "${MARKER5}.hb"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_exists "marker survives (unknown parent, within grace)" "$MARKER5"
assert_dir_exists "worktree survives (unknown parent, within grace)" "$SB5"

# Cleanup
kill "$_fake_hb5" 2>/dev/null; wait "$_fake_hb5" 2>/dev/null || true
rm -f "$MARKER5" "${MARKER5}.hb" 2>/dev/null || true

# ── 6. Live heartbeat + unknown parent (winpid=0) + past grace → reclaimed ──
echo "== live heartbeat + unknown parent past grace → reclaimed =="

SESSION6="t16-unkstale"
SB6=$(bash "$ROOT/core/cmd/sandbox-init.sh" --repo "$REPO" --session "$SESSION6")
BRANCH6=$(basename "$SB6")
MARKER6="$MARKERS/$SESSION6"

# Merge so branch is ancestor of main
echo "work6" > "$SB6/work6.txt"
(cd "$SB6" && git add work6.txt && git commit -q -m "feat: work6")
(cd "$REPO" && git merge -q "$BRANCH6")

# Launch a real background process to act as the heartbeat
sleep 9999 &
_fake_hb6=$!

# Write sidecar with live PID + unknown parent (0), no Unix PID monitoring
printf '%s %s %s' "$_fake_hb6" "0" "0" > "${MARKER6}.hb"

# Backdate created_epoch past orphan grace (2h) and mtime past TTL
_val6=$(sb_marker_read_value "$MARKER6")
_head6=$(sb_marker_read_initial_head "$MARKER6")
printf '%s %s %s' "$_val6" "1000000000" "$_head6" > "$MARKER6"
touch -t "$(date -d '-5 minutes' '+%Y%m%d%H%M.%S' 2>/dev/null || date -v-5M '+%Y%m%d%H%M.%S')" "$MARKER6"

bash "$ROOT/core/cmd/sandbox-lifecycle.sh" --repo "$REPO" --ttl 5 >/dev/null 2>&1
assert_file_absent "marker cleaned (unknown parent, grace expired)" "$MARKER6"
assert_file_absent "sidecar cleaned (unknown parent, grace expired)" "${MARKER6}.hb"
assert_dir_absent "worktree removed (unknown parent, grace expired)" "$SB6"

# Fake heartbeat should have been killed
if kill -0 "$_fake_hb6" 2>/dev/null; then
  echo "FAIL: fake heartbeat still alive after lifecycle (case 6)"
  kill "$_fake_hb6" 2>/dev/null
  T_FAIL=$((T_FAIL + 1)); T_TOTAL=$((T_TOTAL + 1))
else
  echo "PASS: fake heartbeat killed by lifecycle (case 6)"
  T_PASS=$((T_PASS + 1)); T_TOTAL=$((T_TOTAL + 1))
fi
wait "$_fake_hb6" 2>/dev/null || true

test_summary
