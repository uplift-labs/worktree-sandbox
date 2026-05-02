import { execFile, execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const DEFAULT_REFRESH_MS = 1000
const WATCH_REFRESH_MS = 5000
const DEFAULT_DEBOUNCE_MS = 100
const DEFAULT_FILES_REFRESH_MS = 2000
const DEFAULT_GIT_TIMEOUT_MS = 3000
const DEFAULT_GIT_MAX_BUFFER = 10 * 1024 * 1024
const BUILTIN_FILES_PLUGIN_ID = "internal:sidebar-files"
const TUI_PLUGIN_ID_PREFIX = "worktree-sandbox.branch"
const PLUGIN_ENABLED_KV = "plugin_enabled"

const builtinFilesState = {
  refs: 0,
  hidden: false,
  previousEnabled: undefined,
  task: Promise.resolve(),
}

function commandOutput(value) {
  if (!value) return ""
  if (Buffer.isBuffer(value)) return value.toString("utf8")
  return String(value)
}

function envValue(env, name) {
  return env?.[name] || ""
}

function gitOutput(args, cwd) {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim()
}

function gitTimeoutMs(env = process.env) {
  return parsePositiveInt(envValue(env, "AISB_OPENCODE_GIT_TIMEOUT_MS"), DEFAULT_GIT_TIMEOUT_MS)
}

function gitOutputAsync(args, cwd, env = process.env) {
  return new Promise((resolve, reject) => {
    execFile(
      "git",
      ["-C", cwd, ...args],
      {
        encoding: "utf8",
        maxBuffer: DEFAULT_GIT_MAX_BUFFER,
        timeout: gitTimeoutMs(env),
        windowsHide: true,
      },
      (error, stdout) => {
        if (error) {
          reject(error)
          return
        }
        resolve(String(stdout || "").trim())
      },
    )
  })
}

function parsePositiveInt(value, fallback) {
  const next = Number.parseInt(String(value || ""), 10)
  return Number.isFinite(next) && next > 0 ? next : fallback
}

function parseNonNegativeInt(value, fallback) {
  const next = Number.parseInt(String(value || ""), 10)
  return Number.isFinite(next) && next >= 0 ? next : fallback
}

function unrefTimer(timer) {
  if (timer && typeof timer.unref === "function") timer.unref()
}

function defer(fn) {
  if (typeof queueMicrotask === "function") {
    queueMicrotask(fn)
    return
  }
  void Promise.resolve().then(fn)
}

function sanitizeOptionalId(value) {
  const safe = String(value || "")
    .replace(/[^a-zA-Z0-9-]/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96)
  return safe
}

function sanitizeId(value) {
  return sanitizeOptionalId(value) || `${Date.now()}-${process.pid}`
}

function normalizePathForCompare(file) {
  const resolved = path.resolve(file)
  return process.platform === "win32" ? resolved.toLowerCase() : resolved
}

function isWithinPath(child, parent) {
  if (!child || !parent) return false
  const rel = path.relative(path.resolve(parent), path.resolve(child))
  return rel === "" || (!!rel && !rel.startsWith("..") && !path.isAbsolute(rel))
}

function moduleFilePath(moduleURL) {
  if (!moduleURL) return ""
  try {
    if (String(moduleURL).startsWith("file://")) return fileURLToPath(moduleURL)
    return path.resolve(String(moduleURL))
  } catch {
    return ""
  }
}

function hashString(value) {
  let hash = 2166136261
  for (let i = 0; i < value.length; i += 1) {
    hash ^= value.charCodeAt(i)
    hash = Math.imul(hash, 16777619)
  }
  return (hash >>> 0).toString(36)
}

export function tuiPluginID(moduleURL = "") {
  const file = moduleFilePath(moduleURL)
  if (!file) return TUI_PLUGIN_ID_PREFIX
  return `${TUI_PLUGIN_ID_PREFIX}.${hashString(normalizePathForCompare(file))}`
}

export function shouldRunTuiPlugin(moduleURL = "", input = {}) {
  const env = input.env || process.env
  const worktree = resolveSandboxWorktree({ ...input, env })
  const directory = input.directory || input.worktreeHint || process.cwd()
  if (!worktree || !directory || !isWithinPath(directory, worktree)) return true

  const modulePath = moduleFilePath(moduleURL)
  if (!modulePath || isWithinPath(modulePath, worktree)) return true

  const sandboxPlugin = path.join(worktree, ".opencode", "tui-plugins", path.basename(modulePath))
  return !fs.existsSync(sandboxPlugin)
}

export function sandboxSessionID(sessionID, env = process.env) {
  const safe = sanitizeId(sessionID || envValue(env, "OPENCODE_RUN_ID") || envValue(env, "OPENCODE_SANDBOX_SESSION"))
  return safe.startsWith("opencode-") ? safe : `opencode-${safe}`
}

function sandboxSessionIDCandidates(sessionID, env = process.env) {
  const ids = []
  const add = (value) => {
    const safe = sanitizeOptionalId(value)
    if (!safe) return
    const prefixed = safe.startsWith("opencode-") ? safe : `opencode-${safe}`
    for (const id of [prefixed, safe]) {
      if (id && !ids.includes(id)) ids.push(id)
    }
  }

  add(sessionID)
  add(envValue(env, "OPENCODE_RUN_ID"))
  add(envValue(env, "OPENCODE_SANDBOX_SESSION"))
  return ids
}

export function branchWatchEnabled(env = process.env) {
  return envValue(env, "AISB_OPENCODE_BRANCH_WATCH") !== "0"
}

export function branchRefreshMs(env = process.env, watcherActive = false) {
  const fallback = watcherActive ? WATCH_REFRESH_MS : DEFAULT_REFRESH_MS
  return parsePositiveInt(envValue(env, "AISB_OPENCODE_BRANCH_REFRESH_MS"), fallback)
}

export function filesRefreshMs(env = process.env) {
  return parseNonNegativeInt(envValue(env, "AISB_OPENCODE_FILES_REFRESH_MS"), DEFAULT_FILES_REFRESH_MS)
}

export function resolveRepo(base) {
  if (!base) return ""
  try {
    return gitOutput(["rev-parse", "--show-toplevel"], base)
  } catch {
    return ""
  }
}

export function resolveGitCommonDir(repo) {
  if (!repo) return ""
  try {
    const common = gitOutput(["rev-parse", "--git-common-dir"], repo)
    if (path.isAbsolute(common) || /^[A-Za-z]:[\\/]/.test(common)) return path.resolve(common)
    return path.resolve(repo, common)
  } catch {
    return ""
  }
}

export function resolveGitDir(worktree) {
  if (!worktree) return ""
  try {
    const gitDir = gitOutput(["rev-parse", "--git-dir"], worktree)
    if (path.isAbsolute(gitDir) || /^[A-Za-z]:[\\/]/.test(gitDir)) return path.resolve(gitDir)
    return path.resolve(worktree, gitDir)
  } catch {
    return ""
  }
}

export function resolveHeadPath(worktree) {
  const gitDir = resolveGitDir(worktree)
  return gitDir ? path.join(gitDir, "HEAD") : ""
}

export function readCurrentBranch(worktree) {
  if (!worktree) return ""
  try {
    return gitOutput(["branch", "--show-current"], worktree)
  } catch {
    return ""
  }
}

async function readCurrentBranchAsync(worktree, env = process.env) {
  if (!worktree) return ""
  try {
    return await gitOutputAsync(["branch", "--show-current"], worktree, env)
  } catch {
    return ""
  }
}

function readMarkerBranch(marker) {
  return readMarkerField(marker, 0)
}

function clonePluginEnabled(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {}
  return Object.fromEntries(Object.entries(value).filter((entry) => typeof entry[1] === "boolean"))
}

function restorePluginEnabled(api, value) {
  try {
    api?.kv?.set?.(PLUGIN_ENABLED_KV, clonePluginEnabled(value))
  } catch {
    // Runtime plugin visibility should not fail the TUI plugin itself.
  }
}

function findPlugin(api, id) {
  try {
    return api?.plugins?.list?.().find((item) => item.id === id)
  } catch {
    return undefined
  }
}

async function reconcileBuiltinFilesPlugin(api, options = {}) {
  const shouldHide = builtinFilesState.refs > 0

  if (shouldHide && !builtinFilesState.hidden) {
    const plugin = findPlugin(api, BUILTIN_FILES_PLUGIN_ID)
    if (!plugin?.active || plugin.enabled === false) return

    const previousEnabled = clonePluginEnabled(api?.kv?.get?.(PLUGIN_ENABLED_KV, {}))
    const ok = await api.plugins.deactivate(BUILTIN_FILES_PLUGIN_ID)
    if (!ok) return

    builtinFilesState.hidden = true
    builtinFilesState.previousEnabled = previousEnabled
    restorePluginEnabled(api, previousEnabled)
    return
  }

  if (!shouldHide && builtinFilesState.hidden) {
    const previousEnabled = builtinFilesState.previousEnabled || {}
    if (previousEnabled[BUILTIN_FILES_PLUGIN_ID] !== false) await api.plugins.activate(BUILTIN_FILES_PLUGIN_ID)
    builtinFilesState.hidden = false
    builtinFilesState.previousEnabled = undefined
    restorePluginEnabled(api, previousEnabled)
    return
  }

  if (typeof options.onSettled === "function") options.onSettled({ hidden: builtinFilesState.hidden })
}

function queueBuiltinFilesReconcile(api, options = {}) {
  builtinFilesState.task = builtinFilesState.task
    .then(() => reconcileBuiltinFilesPlugin(api, options))
    .catch((error) => {
      if (typeof options.onError === "function") options.onError(error, "builtin-files")
    })
  return builtinFilesState.task
}

export function acquireBuiltinFilesHidden(api, options = {}) {
  let released = false
  builtinFilesState.refs += 1
  void queueBuiltinFilesReconcile(api, options)

  return () => {
    if (released) return
    released = true
    builtinFilesState.refs = Math.max(0, builtinFilesState.refs - 1)
    void queueBuiltinFilesReconcile(api, options)
  }
}

export function builtinFilesHiddenStatus() {
  return {
    refs: builtinFilesState.refs,
    hidden: builtinFilesState.hidden,
  }
}

function readMarkerInitialHead(marker) {
  return readMarkerField(marker, 2)
}

function readMarkerField(marker, index) {
  if (!marker || !fs.existsSync(marker)) return ""
  try {
    return fs.readFileSync(marker, "utf8").trim().split(/\s+/)[index] || ""
  } catch {
    return ""
  }
}

function worktreeFromList(repo, branch) {
  if (!repo || !branch) return ""

  let current = ""
  try {
    for (const raw of gitOutput(["worktree", "list", "--porcelain"], repo).split(/\r?\n/)) {
      const line = raw.trimEnd()
      if (line.startsWith("worktree ")) {
        current = line.slice("worktree ".length)
        continue
      }
      if (line === `branch refs/heads/${branch}` && current && fs.existsSync(current)) return current
    }
  } catch {
    return ""
  }

  return ""
}

function configuredWorktreesDirs(repo, env) {
  const dirs = []
  const add = (value) => {
    if (!value) return
    const resolved = path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value) ? path.resolve(value) : path.resolve(repo, value)
    if (!dirs.includes(resolved)) dirs.push(resolved)
  }

  add(envValue(env, "OPENCODE_SANDBOX_WORKTREES_DIR"))
  add(envValue(env, "WORKTREE_SANDBOX_WORKTREES_DIR"))
  add(path.join(".uplift", "sandbox", "worktrees"))
  add(path.join(".sandbox", "worktrees"))
  return dirs
}

function worktreeFromKnownLayout(repo, branch, env) {
  if (!repo || !branch) return ""
  for (const dir of configuredWorktreesDirs(repo, env)) {
    const candidate = path.join(dir, branch)
    if (fs.existsSync(candidate)) return candidate
  }
  return ""
}

export function resolveSandboxWorktree(input = {}) {
  const env = input.env || process.env
  const direct = envValue(env, "OPENCODE_SANDBOX_WORKTREE")
  if (envValue(env, "OPENCODE_SANDBOX_ACTIVE") === "1" && direct && fs.existsSync(direct)) return path.resolve(direct)

  const base = input.directory || input.worktreeHint || envValue(env, "OPENCODE_SANDBOX_REPO") || process.cwd()
  const repo = resolveRepo(base)
  const marker = resolveSandboxMarker({ ...input, directory: base, env })
  const branch = readMarkerBranch(marker)
  if (!branch) return ""

  return worktreeFromList(repo, branch) || worktreeFromKnownLayout(repo, branch, env)
}

export function resolveSandboxMarker(input = {}) {
  const env = input.env || process.env
  const base = input.directory || input.worktreeHint || input.worktree || envValue(env, "OPENCODE_SANDBOX_REPO") || process.cwd()
  const repo = resolveRepo(base)
  if (!repo) return ""

  const common = resolveGitCommonDir(repo)
  if (!common) return ""

  const ids = sandboxSessionIDCandidates(input.sessionID, env)
  for (const id of ids) {
    const marker = path.join(common, "sandbox-markers", id)
    if (fs.existsSync(marker)) return marker
  }
  return ids[0] ? path.join(common, "sandbox-markers", ids[0]) : ""
}

function gitOutputOrEmpty(args, cwd) {
  try {
    return gitOutput(args, cwd)
  } catch {
    return ""
  }
}

async function gitOutputOrEmptyAsync(args, cwd, env = process.env) {
  try {
    return await gitOutputAsync(args, cwd, env)
  } catch {
    return ""
  }
}

function gitCommitExists(worktree, ref) {
  if (!worktree || !ref) return false
  try {
    gitOutput(["cat-file", "-e", `${ref}^{commit}`], worktree)
    return true
  } catch {
    return false
  }
}

async function gitCommitExistsAsync(worktree, ref, env = process.env) {
  if (!worktree || !ref) return false
  try {
    await gitOutputAsync(["cat-file", "-e", `${ref}^{commit}`], worktree, env)
    return true
  } catch {
    return false
  }
}

export function resolveSandboxBaseRef(input = {}, worktree = "") {
  const env = input.env || process.env
  const explicit = input.baseRef || envValue(env, "OPENCODE_SANDBOX_BASE_REF")
  if (gitCommitExists(worktree, explicit)) return explicit

  const mainBase = resolveMainMergeBase(worktree, env)
  if (mainBase) return mainBase

  const marker = resolveSandboxMarker({ ...input, worktree, env })
  const initialHead = readMarkerInitialHead(marker)
  return gitCommitExists(worktree, initialHead) ? initialHead : ""
}

export async function resolveSandboxBaseRefAsync(input = {}, worktree = "") {
  const env = input.env || process.env
  const explicit = input.baseRef || envValue(env, "OPENCODE_SANDBOX_BASE_REF")
  if (await gitCommitExistsAsync(worktree, explicit, env)) return explicit

  const mainBase = await resolveMainMergeBaseAsync(worktree, env)
  if (mainBase) return mainBase

  const marker = resolveSandboxMarker({ ...input, worktree, env })
  const initialHead = readMarkerInitialHead(marker)
  return (await gitCommitExistsAsync(worktree, initialHead, env)) ? initialHead : ""
}

function resolveMainMergeBase(worktree, env = process.env) {
  if (!worktree) return ""
  const current = readCurrentBranch(worktree)
  const candidates = [
    envValue(env, "OPENCODE_SANDBOX_COMPARE_REF"),
    "main",
    "master",
    "origin/main",
    "origin/master",
  ].filter(Boolean)

  for (const candidate of candidates) {
    if (candidate === current || !gitCommitExists(worktree, candidate)) continue
    const base = gitOutputOrEmpty(["merge-base", "HEAD", candidate], worktree)
    if (gitCommitExists(worktree, base)) return base
  }
  return ""
}

async function resolveMainMergeBaseAsync(worktree, env = process.env) {
  if (!worktree) return ""
  const current = await readCurrentBranchAsync(worktree, env)
  const candidates = [
    envValue(env, "OPENCODE_SANDBOX_COMPARE_REF"),
    "main",
    "master",
    "origin/main",
    "origin/master",
  ].filter(Boolean)

  for (const candidate of candidates) {
    if (candidate === current || !(await gitCommitExistsAsync(worktree, candidate, env))) continue
    const base = await gitOutputOrEmptyAsync(["merge-base", "HEAD", candidate], worktree, env)
    if (await gitCommitExistsAsync(worktree, base, env)) return base
  }
  return ""
}

function parseNumstatCount(value) {
  const next = Number.parseInt(String(value || ""), 10)
  return Number.isFinite(next) && next > 0 ? next : 0
}

function addChangedFile(files, file, additions = 0, deletions = 0) {
  const name = String(file || "").trim()
  if (!name) return
  const current = files.get(name) || { file: name, additions: 0, deletions: 0 }
  current.additions += additions
  current.deletions += deletions
  files.set(name, current)
}

function addNumstat(files, output) {
  for (const raw of String(output || "").split(/\r?\n/)) {
    const line = raw.trimEnd()
    if (!line) continue
    const parts = line.split("\t")
    if (parts.length < 3) continue
    addChangedFile(files, parts.slice(2).join("\t"), parseNumstatCount(parts[0]), parseNumstatCount(parts[1]))
  }
}

function addUntracked(files, output) {
  for (const raw of String(output || "").split(/\r?\n/)) {
    const file = raw.trimEnd()
    if (file) addChangedFile(files, file)
  }
}

export function readSandboxChangedFiles(worktree, input = {}) {
  if (!worktree || !fs.existsSync(worktree)) return []

  const files = new Map()
  const baseRef = resolveSandboxBaseRef(input, worktree)
  if (baseRef) addNumstat(files, gitOutputOrEmpty(["diff", "--numstat", `${baseRef}..HEAD`, "--"], worktree))

  addNumstat(files, gitOutputOrEmpty(["diff", "--numstat", "--cached", "--"], worktree))
  addNumstat(files, gitOutputOrEmpty(["diff", "--numstat", "--"], worktree))
  addUntracked(files, gitOutputOrEmpty(["ls-files", "--others", "--exclude-standard"], worktree))

  return Array.from(files.values()).sort((a, b) => a.file.localeCompare(b.file))
}

export async function readSandboxChangedFilesAsync(worktree, input = {}) {
  if (!worktree || !fs.existsSync(worktree)) return []

  const env = input.env || process.env
  const files = new Map()
  const baseRef = await resolveSandboxBaseRefAsync(input, worktree)
  const [headDiff, cachedDiff, workingDiff, untracked] = await Promise.all([
    baseRef ? gitOutputOrEmptyAsync(["diff", "--numstat", `${baseRef}..HEAD`, "--"], worktree, env) : Promise.resolve(""),
    gitOutputOrEmptyAsync(["diff", "--numstat", "--cached", "--"], worktree, env),
    gitOutputOrEmptyAsync(["diff", "--numstat", "--"], worktree, env),
    gitOutputOrEmptyAsync(["ls-files", "--others", "--exclude-standard"], worktree, env),
  ])

  addNumstat(files, headDiff)
  addNumstat(files, cachedDiff)
  addNumstat(files, workingDiff)
  addUntracked(files, untracked)

  return Array.from(files.values()).sort((a, b) => a.file.localeCompare(b.file))
}

function isHeadEvent(filename) {
  if (!filename) return true
  const text = Buffer.isBuffer(filename) ? filename.toString("utf8") : String(filename)
  return path.basename(text).toLowerCase() === "head"
}

function closeWatcher(state) {
  if (!state.watcher) return
  state.closingWatcher = true
  try {
    state.watcher.close()
  } catch {
    // Watchers are best-effort; polling remains the fallback.
  }
  state.watcher = undefined
  state.watcherActive = false
  state.closingWatcher = false
}

function clearTimer(timer) {
  if (timer) clearTimeout(timer)
}

function clearIntervalTimer(timer) {
  if (timer) clearInterval(timer)
}

export function createBranchObserver(options = {}) {
  const env = options.env || process.env
  const debounceMs = parsePositiveInt(options.debounceMs, DEFAULT_DEBOUNCE_MS)
  const state = {
    branch: "",
    worktree: "",
    headPath: "",
    watcher: undefined,
    watcherActive: false,
    closingWatcher: false,
    pollTimer: undefined,
    pollMs: 0,
    debounceTimer: undefined,
    refreshing: false,
    pendingRefresh: false,
    stopped: false,
  }

  const debug = (message, extra = {}) => {
    if (envValue(env, "AISB_OPENCODE_BRANCH_DEBUG") !== "1") return
    console.error(`[worktree-sandbox.branch] ${message}`, extra)
  }

  const reportError = (error, phase) => {
    debug(`branch refresh ${phase} failed`, { error: commandOutput(error?.message || error) })
    if (typeof options.onError === "function") options.onError(error, phase)
  }

  const startPolling = () => {
    const nextMs = branchRefreshMs(env, state.watcherActive)
    if (state.pollTimer && state.pollMs === nextMs) return
    clearIntervalTimer(state.pollTimer)
    state.pollMs = nextMs
    state.pollTimer = setInterval(() => {
      void observer.refresh("poll")
    }, nextMs)
    unrefTimer(state.pollTimer)
  }

  const startWatcher = (worktree) => {
    closeWatcher(state)
    state.headPath = ""

    if (!branchWatchEnabled(env) || !worktree) {
      startPolling()
      return
    }

    const headPath = resolveHeadPath(worktree)
    if (!headPath || !fs.existsSync(headPath)) {
      startPolling()
      return
    }

    state.headPath = headPath
    try {
      const watcher = fs.watch(path.dirname(headPath), { persistent: false }, (_event, filename) => {
        if (!isHeadEvent(filename)) return
        observer.schedule("head-watch")
      })
      watcher.on("error", (error) => {
        if (state.stopped) return
        reportError(error, "watch")
        closeWatcher(state)
        startPolling()
      })
      watcher.on("close", () => {
        if (state.closingWatcher || state.stopped) return
        state.watcherActive = false
        startPolling()
      })
      if (typeof watcher.unref === "function") watcher.unref()
      state.watcher = watcher
      state.watcherActive = true
    } catch (error) {
      reportError(error, "watch")
      state.watcherActive = false
    }

    startPolling()
  }

  const resolveWorktree = () => {
    const worktree = typeof options.getWorktree === "function" ? options.getWorktree() : resolveSandboxWorktree(options)
    return worktree ? path.resolve(worktree) : ""
  }

  const refresh = async (reason) => {
    if (state.stopped) return
    if (state.refreshing) {
      state.pendingRefresh = true
      return
    }

    state.refreshing = true
    try {
      const worktree = resolveWorktree()
      if (worktree !== state.worktree) {
        state.worktree = worktree
        startWatcher(worktree)
      }

      const branch = worktree ? readCurrentBranch(worktree) : ""
      if (branch !== state.branch) {
        state.branch = branch
        if (typeof options.onChange === "function") options.onChange({ branch, worktree, reason })
      }
    } catch (error) {
      reportError(error, "refresh")
    } finally {
      state.refreshing = false
      if (state.pendingRefresh) {
        state.pendingRefresh = false
        observer.schedule("pending")
      }
    }
  }

  const observer = {
    refresh(reason = "manual") {
      return refresh(reason)
    },

    schedule(reason = "schedule") {
      if (state.stopped) return
      clearTimer(state.debounceTimer)
      state.debounceTimer = setTimeout(() => {
        state.debounceTimer = undefined
        void observer.refresh(reason)
      }, debounceMs)
      unrefTimer(state.debounceTimer)
    },

    close() {
      state.stopped = true
      clearTimer(state.debounceTimer)
      clearIntervalTimer(state.pollTimer)
      closeWatcher(state)
    },

    status() {
      return {
        branch: state.branch,
        worktree: state.worktree,
        headPath: state.headPath,
        watcherActive: state.watcherActive,
        pollMs: state.pollMs,
      }
    },
  }

  observer.schedule("start")
  startPolling()
  return observer
}

function filesSignature(files, worktree) {
  return JSON.stringify({ files, worktree })
}

export function createChangedFilesObserver(options = {}) {
  const env = options.env || process.env
  const debounceMs = parsePositiveInt(options.debounceMs, DEFAULT_DEBOUNCE_MS)
  const state = {
    files: [],
    signature: "[]",
    worktree: "",
    pollTimer: undefined,
    pollMs: 0,
    debounceTimer: undefined,
    refreshing: false,
    pendingRefresh: false,
    stopped: false,
  }

  const debug = (message, extra = {}) => {
    if (envValue(env, "AISB_OPENCODE_FILES_DEBUG") !== "1") return
    console.error(`[worktree-sandbox.files] ${message}`, extra)
  }

  const reportError = (error, phase) => {
    debug(`files refresh ${phase} failed`, { error: commandOutput(error?.message || error) })
    if (typeof options.onError === "function") options.onError(error, phase)
  }

  const startPolling = () => {
    const nextMs = filesRefreshMs(env)
    if (nextMs <= 0) {
      clearIntervalTimer(state.pollTimer)
      state.pollTimer = undefined
      state.pollMs = 0
      return
    }
    if (state.pollTimer && state.pollMs === nextMs) return
    clearIntervalTimer(state.pollTimer)
    state.pollMs = nextMs
    state.pollTimer = setInterval(() => {
      void observer.refresh("poll")
    }, nextMs)
    unrefTimer(state.pollTimer)
  }

  const resolveWorktree = async () => {
    const worktree = typeof options.getWorktree === "function" ? options.getWorktree() : resolveSandboxWorktree(options)
    const resolved = worktree && typeof worktree.then === "function" ? await worktree : worktree
    return resolved ? path.resolve(resolved) : ""
  }

  const refresh = async (reason) => {
    if (state.stopped) return
    if (state.refreshing) {
      state.pendingRefresh = true
      return
    }

    state.refreshing = true
    try {
      const worktree = await resolveWorktree()
      const files = worktree ? await readSandboxChangedFilesAsync(worktree, { ...options, worktree, env }) : []
      if (state.stopped) return
      const signature = filesSignature(files, worktree)
      state.worktree = worktree
      if (signature !== state.signature) {
        state.files = files
        state.signature = signature
        if (typeof options.onChange === "function") options.onChange({ files, worktree, reason })
      }
    } catch (error) {
      reportError(error, "refresh")
    } finally {
      state.refreshing = false
      if (state.pendingRefresh) {
        state.pendingRefresh = false
        observer.schedule("pending")
      }
    }
  }

  const observer = {
    refresh(reason = "manual") {
      return refresh(reason)
    },

    schedule(reason = "schedule") {
      if (state.stopped) return
      clearTimer(state.debounceTimer)
      state.debounceTimer = setTimeout(() => {
        state.debounceTimer = undefined
        void observer.refresh(reason)
      }, debounceMs)
      unrefTimer(state.debounceTimer)
    },

    close() {
      state.stopped = true
      clearTimer(state.debounceTimer)
      clearIntervalTimer(state.pollTimer)
    },

    status() {
      return {
        files: state.files,
        worktree: state.worktree,
        pollMs: state.pollMs,
      }
    },
  }

  defer(() => {
    void observer.refresh("start")
  })
  startPolling()
  return observer
}
