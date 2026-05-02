import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"

const DEFAULT_REFRESH_MS = 1000
const WATCH_REFRESH_MS = 5000
const DEFAULT_DEBOUNCE_MS = 100

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

function parsePositiveInt(value, fallback) {
  const next = Number.parseInt(String(value || ""), 10)
  return Number.isFinite(next) && next > 0 ? next : fallback
}

function unrefTimer(timer) {
  if (timer && typeof timer.unref === "function") timer.unref()
}

function sanitizeId(value) {
  const safe = String(value || "")
    .replace(/[^a-zA-Z0-9-]/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96)
  return safe || `${Date.now()}-${process.pid}`
}

export function sandboxSessionID(sessionID, env = process.env) {
  const safe = sanitizeId(sessionID || envValue(env, "OPENCODE_RUN_ID") || envValue(env, "OPENCODE_SANDBOX_SESSION"))
  return safe.startsWith("opencode-") ? safe : `opencode-${safe}`
}

export function branchWatchEnabled(env = process.env) {
  return envValue(env, "AISB_OPENCODE_BRANCH_WATCH") !== "0"
}

export function branchRefreshMs(env = process.env, watcherActive = false) {
  const fallback = watcherActive ? WATCH_REFRESH_MS : DEFAULT_REFRESH_MS
  return parsePositiveInt(envValue(env, "AISB_OPENCODE_BRANCH_REFRESH_MS"), fallback)
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

function readMarkerBranch(marker) {
  if (!marker || !fs.existsSync(marker)) return ""
  try {
    return fs.readFileSync(marker, "utf8").trim().split(/\s+/)[0] || ""
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
  if (!repo) return ""

  const sessionID = input.sessionID || envValue(env, "OPENCODE_SANDBOX_SESSION")
  if (!sessionID) return ""

  const common = resolveGitCommonDir(repo)
  const marker = common ? path.join(common, "sandbox-markers", sandboxSessionID(sessionID, env)) : ""
  const branch = readMarkerBranch(marker)
  if (!branch) return ""

  return worktreeFromList(repo, branch) || worktreeFromKnownLayout(repo, branch, env)
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
