#!/bin/bash
# t23 — OpenCode adapter launcher + plugin smoke test.
set -u
SELF="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/fixture.sh"

fixture_init
trap fixture_cleanup EXIT

REPO=$(fixture_repo "t23")
FAKE_BIN="$FIXTURE_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/opencode" <<'SH'
#!/bin/bash
printf '%s' "$PWD" > "$OPENCODE_FAKE_CWD"
printf '%s' "${OPENCODE_CONFIG_DIR:-}" > "$OPENCODE_FAKE_CONFIG_DIR"
printf '%s' "$OPENCODE_SANDBOX_WORKTREE" > "$OPENCODE_FAKE_WORKTREE"
if [ "${OPENCODE_FAKE_WRITE_PENDING:-0}" = "1" ]; then
  printf 'pending\n' > "$OPENCODE_SANDBOX_WORKTREE/pending.txt"
fi
exit "${OPENCODE_FAKE_EXIT:-0}"
SH
chmod +x "$FAKE_BIN/opencode"

echo "== launcher runs fake OpenCode inside source-tree sandbox and reaps empty worktree =="
SESSION_EMPTY="t23-empty"
FAKE_CWD="$FIXTURE_ROOT/cwd-empty.txt"
FAKE_CONFIG="$FIXTURE_ROOT/config-empty.txt"
FAKE_WORKTREE="$FIXTURE_ROOT/worktree-empty.txt"
OUT=$(PATH="$FAKE_BIN:$PATH" \
  OPENCODE_FAKE_CWD="$FAKE_CWD" \
  OPENCODE_FAKE_CONFIG_DIR="$FAKE_CONFIG" \
  OPENCODE_FAKE_WORKTREE="$FAKE_WORKTREE" \
  bash "$ROOT/adapters/opencode/bin/opencode-sandbox.sh" \
    --repo "$REPO" --session "$SESSION_EMPTY" -- run "hello" 2>&1)
ec=$?
assert_exit "launcher exits with opencode status" 0 "$ec"
assert_contains "launcher prints sandbox banner" "OpenCode sandbox" "$OUT"
assert_file_exists "fake opencode recorded cwd" "$FAKE_CWD"
assert_contains "cwd is source-tree sandbox" ".sandbox/worktrees/wt-$SESSION_EMPTY" "$(cat "$FAKE_CWD")"
assert_contains "config dir points at adapter" "adapters/opencode" "$(cat "$FAKE_CONFIG")"
assert_contains "worktree env is sandbox" ".sandbox/worktrees/wt-$SESSION_EMPTY" "$(cat "$FAKE_WORKTREE")"
assert_dir_absent "empty launcher sandbox reaped" "$REPO/.sandbox/worktrees/wt-$SESSION_EMPTY"
assert_file_absent "empty launcher marker reaped" "$REPO/.git/sandbox-markers/$SESSION_EMPTY"

echo "== launcher capture-commits pending work and preserves unmerged sandbox =="
SESSION_DIRTY="t23-dirty"
FAKE_CWD_DIRTY="$FIXTURE_ROOT/cwd-dirty.txt"
OUT=$(PATH="$FAKE_BIN:$PATH" \
  OPENCODE_FAKE_CWD="$FAKE_CWD_DIRTY" \
  OPENCODE_FAKE_CONFIG_DIR="$FIXTURE_ROOT/config-dirty.txt" \
  OPENCODE_FAKE_WORKTREE="$FIXTURE_ROOT/worktree-dirty.txt" \
  OPENCODE_FAKE_WRITE_PENDING=1 \
  bash "$ROOT/adapters/opencode/bin/opencode-sandbox.sh" \
    --repo "$REPO" --session "$SESSION_DIRTY" 2>&1)
ec=$?
assert_exit "dirty launcher exits 0" 0 "$ec"
SB_DIRTY="$REPO/.sandbox/worktrees/wt-$SESSION_DIRTY"
assert_dir_exists "dirty sandbox preserved" "$SB_DIRTY"
assert_file_exists "dirty marker preserved" "$REPO/.git/sandbox-markers/$SESSION_DIRTY"
assert_file_exists "pending file exists in sandbox" "$SB_DIRTY/pending.txt"
LAST_SUBJ=$(git -C "$SB_DIRTY" log -1 --format=%s)
assert_contains "pending work capture-committed" "capture pending work" "$LAST_SUBJ"
assert_file_absent "main remains untouched" "$REPO/pending.txt"

echo "== plugin guards write-capable tools against main repo targets =="
if command -v node >/dev/null 2>&1; then
  NODE_SCRIPT="$FIXTURE_ROOT/opencode-plugin-smoke.mjs"
  cat > "$NODE_SCRIPT" <<'JS'
import path from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, repo, sandbox, session, root] = process.argv.slice(2)
process.env.OPENCODE_SANDBOX_ACTIVE = "1"
process.env.OPENCODE_SANDBOX_SESSION = session
process.env.OPENCODE_SANDBOX_REPO = repo
process.env.OPENCODE_SANDBOX_ROOT = root
process.env.OPENCODE_SANDBOX_WORKTREE = sandbox
process.env.OPENCODE_SANDBOX_WORKTREES_DIR = ".sandbox/worktrees"
process.env.OPENCODE_SANDBOX_BRANCH_PREFIX = "wt"

const mod = await import(pathToFileURL(pluginPath).href)
const hooks = await mod.WorktreeSandbox({ directory: sandbox, worktree: sandbox })

await hooks["tool.execute.before"](
  { tool: "write", sessionID: session, callID: "allow" },
  { args: { filePath: path.join(sandbox, "allowed.txt") } },
)

let deniedWrite = false
try {
  await hooks["tool.execute.before"](
    { tool: "write", sessionID: session, callID: "deny" },
    { args: { filePath: path.join(repo, "README.md") } },
  )
} catch (error) {
  deniedWrite = String(error.message).includes("sandbox-guard")
}
if (!deniedWrite) throw new Error("write to main repo was not denied")

await hooks["tool.execute.before"](
  { tool: "bash", sessionID: session, callID: "bash-allow" },
  { args: { command: "git status", workdir: sandbox } },
)

let deniedBash = false
try {
  await hooks["tool.execute.before"](
    { tool: "bash", sessionID: session, callID: "bash-deny" },
    { args: { command: "touch README.md", workdir: repo } },
  )
} catch (error) {
  deniedBash = String(error.message).includes("sandbox-guard")
}
if (!deniedBash) throw new Error("bash from main repo was not denied")

const system = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID: session }, system)
if (!system.system.join("\n").includes(sandbox)) throw new Error("system context missing sandbox")

const shell = { env: {} }
await hooks["shell.env"]({ cwd: sandbox, sessionID: session }, shell)
if (shell.env.OPENCODE_SANDBOX_SESSION !== session) throw new Error("shell env missing session")
JS
  OUT=$(node "$NODE_SCRIPT" \
    "$ROOT/adapters/opencode/plugins/worktree-sandbox.js" \
    "$REPO" "$SB_DIRTY" "$SESSION_DIRTY" "$ROOT" 2>&1)
  ec=$?
  assert_exit "plugin smoke exits 0" 0 "$ec"
else
  echo "node not found; skipping plugin import smoke"
fi

test_summary
