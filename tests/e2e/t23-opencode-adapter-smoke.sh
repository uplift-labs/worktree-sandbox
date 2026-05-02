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

  echo "== plugin auto-creates session sandbox without launcher =="
  NODE_AUTO_SCRIPT="$FIXTURE_ROOT/opencode-plugin-auto-smoke.mjs"
  cat > "$NODE_AUTO_SCRIPT" <<'JS'
import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, repo] = process.argv.slice(2)
const sessionID = "auto-session"
const sandbox = path.join(repo, ".sandbox", "worktrees", "wt-opencode-auto-session")
const marker = path.join(repo, ".git", "sandbox-markers", "opencode-auto-session")

function posix(value) {
  return String(value || "").replace(/\\/g, "/")
}

for (const key of [
  "OPENCODE_SANDBOX_ACTIVE",
  "OPENCODE_SANDBOX_SOURCE",
  "OPENCODE_SANDBOX_SESSION",
  "OPENCODE_SANDBOX_REPO",
  "OPENCODE_SANDBOX_ROOT",
  "OPENCODE_SANDBOX_WORKTREE",
  "OPENCODE_SANDBOX_WORKTREES_DIR",
  "OPENCODE_SANDBOX_BRANCH_PREFIX",
]) {
  delete process.env[key]
}

const mod = await import(pathToFileURL(pluginPath).href)
const hooks = await mod.WorktreeSandbox({ directory: repo, worktree: repo })

await hooks.event({ event: { type: "session.created", properties: { sessionID } } })
if (!fs.existsSync(sandbox)) throw new Error(`sandbox missing: ${sandbox}`)
if (!fs.existsSync(marker)) throw new Error(`marker missing: ${marker}`)

const system = { system: [] }
await hooks["experimental.chat.system.transform"]({ sessionID, model: {} }, system)
if (!posix(system.system.join("\n")).includes(posix(sandbox))) throw new Error("system prompt missing sandbox root")

const shell = { env: {} }
await hooks["shell.env"]({ sessionID, cwd: repo }, shell)
if (posix(shell.env.OPENCODE_SANDBOX_WORKTREE) !== posix(sandbox)) throw new Error("shell env missing sandbox")

const definition = { description: "Run commands" }
await hooks["tool.definition"]({ toolID: "bash" }, definition)
if (!definition.description.includes("worktree-sandbox is active")) throw new Error("tool definition missing sandbox note")

const relativeWrite = { args: { filePath: "created.txt" } }
await hooks["tool.execute.before"]({ tool: "write", sessionID, callID: "relative-write" }, relativeWrite)
if (posix(relativeWrite.args.filePath) !== posix(path.join(sandbox, "created.txt"))) {
  throw new Error(`relative write was not mapped into sandbox: ${relativeWrite.args.filePath}`)
}

let deniedWrite = false
try {
  await hooks["tool.execute.before"](
    { tool: "write", sessionID, callID: "main-write" },
    { args: { filePath: path.join(repo, "README.md") } },
  )
} catch (error) {
  deniedWrite = String(error.message).includes("sandbox-guard")
}
if (!deniedWrite) throw new Error("absolute write to main repo was not denied")

const grep = { args: { pattern: "README" } }
await hooks["tool.execute.before"]({ tool: "grep", sessionID, callID: "grep" }, grep)
if (posix(grep.args.path) !== posix(sandbox)) throw new Error(`grep default path was not sandbox: ${grep.args.path}`)

const patch = {
  args: {
    patchText: "*** Begin Patch\n*** Add File: auto-patch.txt\n+hello\n*** End Patch",
  },
}
await hooks["tool.execute.before"]({ tool: "apply_patch", sessionID, callID: "patch" }, patch)
if (!posix(patch.args.patchText).includes(".sandbox/worktrees/wt-opencode-auto-session/auto-patch.txt")) {
  throw new Error(`patch path was not mapped into sandbox: ${patch.args.patchText}`)
}

const bashDefault = { args: { command: "git status", description: "Shows git status" } }
await hooks["tool.execute.before"]({ tool: "bash", sessionID, callID: "bash-default" }, bashDefault)
if (posix(bashDefault.args.workdir) !== posix(sandbox)) throw new Error(`bash default workdir was not sandbox: ${bashDefault.args.workdir}`)

let deniedBash = false
try {
  await hooks["tool.execute.before"](
    { tool: "bash", sessionID, callID: "bash-main" },
    { args: { command: "touch README.md", workdir: repo, description: "Touches file" } },
  )
} catch (error) {
  deniedBash = String(error.message).includes("sandbox-guard")
}
if (!deniedBash) throw new Error("bash from main repo was not denied")

await hooks.event({ event: { type: "session.deleted", properties: { info: { id: sessionID } } } })
if (fs.existsSync(sandbox)) throw new Error("empty auto sandbox was not cleaned up")
if (fs.existsSync(marker)) throw new Error("empty auto marker was not cleaned up")
JS
  OUT=$(node "$NODE_AUTO_SCRIPT" "$ROOT/adapters/opencode/plugins/worktree-sandbox.js" "$REPO" 2>&1)
  ec=$?
  assert_exit "plugin auto sandbox smoke exits 0" 0 "$ec"
  assert_not_contains "plugin auto sandbox does not write TUI-noisy stderr" "\[sandbox\]" "$OUT"

  echo "== TUI branch watcher refreshes on HEAD changes and polling fallback =="
  WATCH_REPO=$(fixture_repo "t23-branch-watch")
  WATCH_WT=$(fixture_worktree "$WATCH_REPO" "watch-start" "watch.txt" "one")
  NODE_BRANCH_SCRIPT="$FIXTURE_ROOT/opencode-branch-watch.mjs"
  cat > "$NODE_BRANCH_SCRIPT" <<'JS'
import { execFileSync } from "node:child_process"
import { pathToFileURL } from "node:url"

const [corePath, worktree] = process.argv.slice(2)
const core = await import(pathToFileURL(corePath).href)

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(predicate, timeoutMs, label) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await sleep(50)
  }
  throw new Error(`timed out waiting for ${label}`)
}

const watchUpdates = []
const watched = core.createBranchObserver({
  getWorktree: () => worktree,
  env: { AISB_OPENCODE_BRANCH_REFRESH_MS: "10000" },
  debounceMs: 50,
  onChange: (update) => watchUpdates.push(update),
})

await waitFor(() => watchUpdates.some((item) => item.branch === "watch-start"), 2000, "initial watched branch")
if (!watched.status().watcherActive) throw new Error("HEAD watcher did not start")

execFileSync("git", ["-C", worktree, "switch", "-c", "watch-next"], { stdio: "ignore" })
await waitFor(() => watchUpdates.some((item) => item.branch === "watch-next"), 5000, "watched branch switch")
watched.close()
if (watched.status().watcherActive) throw new Error("HEAD watcher stayed active after close")

const pollUpdates = []
const polled = core.createBranchObserver({
  getWorktree: () => worktree,
  env: {
    AISB_OPENCODE_BRANCH_WATCH: "0",
    AISB_OPENCODE_BRANCH_REFRESH_MS: "200",
  },
  debounceMs: 50,
  onChange: (update) => pollUpdates.push(update),
})

await waitFor(() => pollUpdates.some((item) => item.branch === "watch-next"), 2000, "initial polled branch")
if (polled.status().watcherActive) throw new Error("watcher started despite AISB_OPENCODE_BRANCH_WATCH=0")

execFileSync("git", ["-C", worktree, "switch", "-c", "poll-next"], { stdio: "ignore" })
await waitFor(() => pollUpdates.some((item) => item.branch === "poll-next"), 5000, "polled branch switch")
polled.close()
JS
  OUT=$(node "$NODE_BRANCH_SCRIPT" "$ROOT/adapters/opencode/tui/worktree-sandbox-branch-core.js" "$WATCH_WT" 2>&1)
  ec=$?
  assert_exit "TUI branch watcher smoke exits 0" 0 "$ec"

  echo "== TUI sandbox sidebar diff reads worktree changes =="
  DIFF_REPO=$(fixture_repo "t23-sidebar-diff")
  DIFF_WT=$(fixture_worktree "$DIFF_REPO" "diff-start" "tracked.txt" "one")
  printf 'main\n' > "$DIFF_REPO/main-only.txt"
  git -C "$DIFF_REPO" add main-only.txt
  git -C "$DIFF_REPO" commit -q -m "feat: main-only change"
  git -C "$DIFF_WT" merge -q --no-edit main
  printf 'committed\n' >> "$DIFF_WT/README.md"
  git -C "$DIFF_WT" add README.md
  git -C "$DIFF_WT" commit -q -m "feat: committed sandbox change"
  printf 'working\n' >> "$DIFF_WT/tracked.txt"
  printf 'free\n' > "$DIFF_WT/free.txt"
  printf 'dirty main\n' > "$DIFF_REPO/main-dirty.txt"

  NODE_DIFF_SCRIPT="$FIXTURE_ROOT/opencode-sidebar-diff.mjs"
  cat > "$NODE_DIFF_SCRIPT" <<'JS'
import fs from "node:fs"
import path from "node:path"
import { pathToFileURL } from "node:url"

const [corePath, worktree] = process.argv.slice(2)
const core = await import(pathToFileURL(corePath).href)

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitFor(predicate, timeoutMs, label) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (predicate()) return
    await sleep(50)
  }
  throw new Error(`timed out waiting for ${label}`)
}

function names(files) {
  return files.map((item) => item.file)
}

function hasOwn(object, key) {
  return Object.prototype.hasOwnProperty.call(object || {}, key)
}

const files = core.readSandboxChangedFiles(worktree)
const initialNames = names(files)
for (const expected of ["README.md", "tracked.txt", "free.txt"]) {
  if (!initialNames.includes(expected)) throw new Error(`missing changed file: ${expected}`)
}
for (const unexpected of ["main-only.txt", "main-dirty.txt"]) {
  if (initialNames.includes(unexpected)) throw new Error(`main repo change leaked into sandbox list: ${unexpected}`)
}

const readme = files.find((item) => item.file === "README.md")
if (!readme || readme.additions < 1) throw new Error("committed diff additions were not counted")

const updates = []
const observer = core.createChangedFilesObserver({
  getWorktree: () => worktree,
  env: { AISB_OPENCODE_FILES_REFRESH_MS: "200" },
  debounceMs: 50,
  onChange: (update) => updates.push(update),
})

await waitFor(() => updates.some((update) => names(update.files).includes("free.txt")), 2000, "initial sidebar diff")
fs.writeFileSync(path.join(worktree, "another.txt"), "another\n")
await waitFor(() => updates.some((update) => names(update.files).includes("another.txt")), 3000, "updated sidebar diff")
if (observer.status().pollMs !== 200) throw new Error("files observer did not use configured poll interval")
observer.close()

const pluginID = "internal:sidebar-files"
let pluginActive = true
let pluginEnabled = true
const calls = []
const kv = {}
const fakeApi = {
  kv: {
    get(key, fallback) {
      return hasOwn(kv, key) ? kv[key] : fallback
    },
    set(key, value) {
      kv[key] = value
    },
  },
  plugins: {
    list() {
      return [{ id: pluginID, enabled: pluginEnabled, active: pluginActive }]
    },
    async deactivate(id) {
      calls.push(`deactivate:${id}`)
      pluginActive = false
      kv.plugin_enabled = { ...(kv.plugin_enabled || {}), [id]: false }
      return true
    },
    async activate(id) {
      calls.push(`activate:${id}`)
      pluginActive = true
      pluginEnabled = true
      kv.plugin_enabled = { ...(kv.plugin_enabled || {}), [id]: true }
      return true
    },
  },
}

const release = core.acquireBuiltinFilesHidden(fakeApi)
await waitFor(() => calls.includes(`deactivate:${pluginID}`), 2000, "built-in files deactivation")
if (pluginActive) throw new Error("built-in files plugin stayed active")
if (!core.builtinFilesHiddenStatus().hidden) throw new Error("hidden status was not tracked")
if (hasOwn(kv.plugin_enabled, pluginID)) throw new Error("built-in files disabled state leaked into KV")

release()
await waitFor(() => calls.includes(`activate:${pluginID}`), 2000, "built-in files restoration")
if (!pluginActive) throw new Error("built-in files plugin was not restored")
if (core.builtinFilesHiddenStatus().hidden) throw new Error("hidden status stayed enabled after release")
if (hasOwn(kv.plugin_enabled, pluginID)) throw new Error("built-in files restored state leaked into KV")

calls.length = 0
pluginActive = false
pluginEnabled = false
const releaseInactive = core.acquireBuiltinFilesHidden(fakeApi)
await sleep(100)
releaseInactive()
await sleep(100)
if (calls.length !== 0) throw new Error("inactive/user-disabled built-in files plugin was toggled")
JS
  OUT=$(node "$NODE_DIFF_SCRIPT" "$ROOT/adapters/opencode/tui/worktree-sandbox-branch-core.js" "$DIFF_WT" 2>&1)
  ec=$?
  assert_exit "TUI sandbox sidebar diff smoke exits 0" 0 "$ec"
else
  echo "node not found; skipping plugin import smoke"
fi

test_summary
