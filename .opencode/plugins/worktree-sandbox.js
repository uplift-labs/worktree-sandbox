import { execFileSync, spawn } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url))

const state = {
  sessions: new Map(),
  warnings: new Map(),
  heartbeats: new Map(),
  cleanupRegistered: false,
  currentSession: "",
}

const PATH_TOOLS = new Set(["read", "edit", "write", "lsp"])
const SEARCH_TOOLS = new Set(["grep", "glob"])
const PATCH_TOOLS = new Set(["apply_patch", "patch"])
const SANDBOXED_TOOLS = new Set([...PATH_TOOLS, ...SEARCH_TOOLS, ...PATCH_TOOLS, "bash"])

function envValue(name) {
  return process.env[name] || ""
}

function commandOutput(value) {
  if (!value) return ""
  if (Buffer.isBuffer(value)) return value.toString("utf8")
  return String(value)
}

function toPosix(file) {
  return String(file || "").replace(/\\/g, "/")
}

function normalize(file) {
  const resolved = path.resolve(file)
  return process.platform === "win32" ? toPosix(resolved).toLowerCase() : toPosix(resolved)
}

function isWithin(child, parent) {
  if (!child || !parent) return false
  const rel = path.relative(path.resolve(parent), path.resolve(child))
  return rel === "" || (!!rel && !rel.startsWith("..") && !path.isAbsolute(rel))
}

function absolutize(file, base) {
  if (!file) return ""
  return path.isAbsolute(file) || /^[A-Za-z]:[\\/]/.test(file) ? path.resolve(file) : path.resolve(base, file)
}

function isExplicitAbsolute(file) {
  return path.isAbsolute(file || "") || /^[A-Za-z]:[\\/]/.test(file || "")
}

function sanitizeId(value) {
  const safe = String(value || "")
    .replace(/[^a-zA-Z0-9-]/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96)
  return safe || `${Date.now()}-${process.pid}`
}

function sandboxSessionID(sessionID) {
  const safe = sanitizeId(sessionID || envValue("OPENCODE_RUN_ID") || `${Date.now()}-${process.pid}`)
  return safe.startsWith("opencode-") ? safe : `opencode-${safe}`
}

function emptyConfig() {
  return {
    active: false,
    session: "",
    repo: "",
    root: "",
    worktree: "",
    worktreesDir: ".sandbox/worktrees",
    branchPrefix: "wt",
    branchGlob: "wt-*",
    auto: false,
  }
}

function launcherConfig() {
  if (envValue("OPENCODE_SANDBOX_SOURCE") === "opencode-plugin") return emptyConfig()

  const repo = envValue("OPENCODE_SANDBOX_REPO")
  const root = envValue("OPENCODE_SANDBOX_ROOT") || (repo ? path.join(repo, ".uplift", "sandbox") : "")
  const session = envValue("OPENCODE_SANDBOX_SESSION")
  const worktree = envValue("OPENCODE_SANDBOX_WORKTREE")
  const branchPrefix = envValue("OPENCODE_SANDBOX_BRANCH_PREFIX") || "wt"

  if (envValue("OPENCODE_SANDBOX_ACTIVE") !== "1" || !session || !repo || !root || !worktree) return emptyConfig()
  return {
    active: true,
    session,
    repo,
    root,
    worktree,
    worktreesDir: envValue("OPENCODE_SANDBOX_WORKTREES_DIR") || ".sandbox/worktrees",
    branchPrefix,
    branchGlob: branchPrefix.includes("*") ? branchPrefix : `${branchPrefix}-*`,
    auto: false,
  }
}

function hasCore(root) {
  return !!root && fs.existsSync(path.join(root, "core", "cmd", "sandbox-init.sh"))
}

function findSandboxRoot(repo) {
  const candidates = []
  if (envValue("OPENCODE_SANDBOX_ROOT")) candidates.push(envValue("OPENCODE_SANDBOX_ROOT"))
  if (repo) {
    candidates.push(path.join(repo, ".uplift", "sandbox"))
    candidates.push(path.join(repo, ".sandbox"))
  }

  let cur = MODULE_DIR
  for (let i = 0; i < 8; i += 1) {
    candidates.push(cur)
    const next = path.dirname(cur)
    if (next === cur) break
    cur = next
  }

  for (const candidate of candidates) {
    if (hasCore(candidate)) return candidate
  }
  return ""
}

function gitOutput(args, cwd) {
  return execFileSync("git", ["-C", cwd, ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim()
}

function resolveRepo(base) {
  try {
    return gitOutput(["rev-parse", "--show-toplevel"], base)
  } catch {
    return ""
  }
}

function resolveGitCommonDir(repo) {
  try {
    const common = gitOutput(["rev-parse", "--git-common-dir"], repo)
    if (path.isAbsolute(common) || /^[A-Za-z]:[\\/]/.test(common)) return path.resolve(common)
    return path.resolve(repo, common)
  } catch {
    return ""
  }
}

function worktreesDir(repo, root) {
  if (envValue("WORKTREE_SANDBOX_WORKTREES_DIR")) return envValue("WORKTREE_SANDBOX_WORKTREES_DIR")
  if (envValue("OPENCODE_SANDBOX_WORKTREES_DIR")) return envValue("OPENCODE_SANDBOX_WORKTREES_DIR")
  if (repo && root && isWithin(root, repo) && normalize(root) !== normalize(repo)) {
    return `${toPosix(path.relative(repo, root))}/worktrees`
  }
  return ".sandbox/worktrees"
}

function branchPrefix() {
  return envValue("WORKTREE_SANDBOX_BRANCH_PREFIX") || envValue("OPENCODE_SANDBOX_BRANCH_PREFIX") || "wt"
}

function branchGlob(prefix) {
  return prefix.includes("*") ? prefix : `${prefix}-*`
}

let cachedBash = ""

function resolveBash() {
  if (cachedBash) return cachedBash

  const candidates = []
  const add = (candidate) => {
    if (candidate && !candidates.includes(candidate)) candidates.push(candidate)
  }

  add(envValue("WORKTREE_SANDBOX_BASH"))
  add(envValue("GIT_BASH"))
  if (process.platform === "win32") {
    add("C:\\Program Files\\Git\\bin\\bash.exe")
    add("C:\\Program Files\\Git\\usr\\bin\\bash.exe")
    add("C:\\Program Files (x86)\\Git\\bin\\bash.exe")
  }
  add("bash")

  for (const candidate of candidates) {
    if ((path.isAbsolute(candidate) || /^[A-Za-z]:[\\/]/.test(candidate)) && !fs.existsSync(candidate)) continue
    try {
      execFileSync(candidate, ["--version"], { stdio: "ignore", timeout: 3000 })
      cachedBash = candidate
      return candidate
    } catch {
      // Try the next candidate. On Windows, bare bash can resolve to WSL.
    }
  }

  throw new Error("bash command not found")
}

function execSandbox(root, rel, args, options = {}) {
  return execFileSync(resolveBash(), [path.join(root, rel), ...args], {
    cwd: options.cwd || root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  })
}

function markerPath(cfg) {
  const common = resolveGitCommonDir(cfg.repo)
  return common ? path.join(common, "sandbox-markers", cfg.session) : ""
}

function setProcessEnv(cfg) {
  process.env.OPENCODE_SANDBOX_ACTIVE = "1"
  process.env.OPENCODE_SANDBOX_SOURCE = "opencode-plugin"
  process.env.OPENCODE_SANDBOX_SESSION = cfg.session
  process.env.OPENCODE_SANDBOX_REPO = cfg.repo
  process.env.OPENCODE_SANDBOX_ROOT = cfg.root
  process.env.OPENCODE_SANDBOX_WORKTREE = cfg.worktree
  process.env.OPENCODE_SANDBOX_WORKTREES_DIR = cfg.worktreesDir
  process.env.OPENCODE_SANDBOX_BRANCH_PREFIX = cfg.branchPrefix
}

function touchMarker(cfg) {
  const marker = markerPath(cfg)
  if (!marker || !fs.existsSync(marker)) return
  const now = new Date()
  try {
    fs.utimesSync(marker, now, now)
  } catch {
    // Heartbeat/lifecycle TTL is a safety net if this best-effort touch fails.
  }
}

function killHeartbeat(cfg) {
  const hb = state.heartbeats.get(cfg.session)
  if (hb) {
    try {
      hb.kill()
    } catch {
      // The process may already be gone.
    }
    state.heartbeats.delete(cfg.session)
  }

  const sidecar = `${markerPath(cfg)}.hb`
  if (!sidecar || !fs.existsSync(sidecar)) return

  try {
    const pid = fs.readFileSync(sidecar, "utf8").trim().split(/\s+/)[0]
    if (pid) {
      try {
        process.kill(Number(pid))
      } catch {
        // The heartbeat may already have exited.
      }
    }
    fs.rmSync(sidecar, { force: true })
  } catch {
    // Cleanup must never make OpenCode fail to exit.
  }
}

function cleanupConfig(cfg) {
  if (!cfg.active || !cfg.auto) return
  killHeartbeat(cfg)
  try {
    execSandbox(cfg.root, "core/cmd/sandbox-cleanup.sh", [
      "--repo",
      cfg.repo,
      "--session",
      cfg.session,
      "--trust-dead",
      "--worktrees-dir",
      cfg.worktreesDir,
      "--branch-prefix",
      cfg.branchGlob,
    ])
  } catch {
    // Fail open. Stale markers are still TTL-managed by sandbox-lifecycle.
  }
}

function registerProcessCleanup() {
  if (state.cleanupRegistered) return
  state.cleanupRegistered = true
  process.once("exit", () => {
    for (const cfg of state.sessions.values()) cleanupConfig(cfg)
  })
}

function launchHeartbeat(cfg) {
  const marker = markerPath(cfg)
  if (!marker || !fs.existsSync(marker)) return

  const pidArgs = process.platform === "win32" ? ["--pid", "0", "--parent-winpid", String(process.pid)] : ["--pid", String(process.pid)]
  const child = spawn(
    resolveBash(),
    [
      path.join(cfg.root, "core/lib/heartbeat.sh"),
      ...pidArgs,
      "--marker",
      marker,
      "--repo",
      cfg.repo,
      "--sandbox-root",
      cfg.root,
      "--worktrees-dir",
      cfg.worktreesDir,
      "--branch-prefix",
      cfg.branchGlob,
      "--owner-process-names",
      "opencode,opencode.exe,node,node.exe,bun,bun.exe",
    ],
    { detached: true, stdio: "ignore" },
  )
  child.unref()
  state.heartbeats.set(cfg.session, child)
}

function createSessionConfig(sessionID, baseDirectory) {
  const session = sandboxSessionID(sessionID)
  if (state.sessions.has(session)) return state.sessions.get(session)

  const repo = resolveRepo(baseDirectory)
  if (!repo) return emptyConfig()

  const root = findSandboxRoot(repo)
  if (!root) {
    state.warnings.set(session, "installed sandbox core not found")
    return emptyConfig()
  }

  const wtDir = worktreesDir(repo, root)
  const brPrefix = branchPrefix()
  const brGlob = branchGlob(brPrefix)

  try {
    execSandbox(root, "core/cmd/sandbox-lifecycle.sh", [
      "--repo",
      repo,
      "--worktrees-dir",
      wtDir,
      "--branch-prefix",
      brGlob,
    ])
  } catch {
    // Lifecycle is only a cleanup pre-pass; sandbox-init below decides safety.
  }

  let worktree = ""
  try {
    worktree = execSandbox(root, "core/cmd/sandbox-init.sh", [
      "--repo",
      repo,
      "--session",
      session,
      "--worktrees-dir",
      wtDir,
      "--branch-prefix",
      brPrefix,
    ]).trim()
  } catch (error) {
    const warning = (commandOutput(error.stdout) || commandOutput(error.stderr) || error.message).trim()
    state.warnings.set(session, warning || "sandbox creation failed")
    return emptyConfig()
  }

  if (!worktree) return emptyConfig()

  const cfg = {
    active: true,
    session,
    repo,
    root,
    worktree,
    worktreesDir: wtDir,
    branchPrefix: brPrefix,
    branchGlob: brGlob,
    auto: true,
  }
  state.sessions.set(session, cfg)
  state.currentSession = session
  setProcessEnv(cfg)
  launchHeartbeat(cfg)
  registerProcessCleanup()
  return cfg
}

function configFor(sessionID, baseDirectory) {
  const launched = launcherConfig()
  if (launched.active) return launched

  const raw = sessionID || state.currentSession
  if (!raw || envValue("OPENCODE_SANDBOX_AUTO") === "0") return emptyConfig()

  const session = sandboxSessionID(raw)
  return state.sessions.get(session) || createSessionConfig(raw, baseDirectory)
}

function warningFor(sessionID) {
  const session = sandboxSessionID(sessionID || state.currentSession)
  return state.warnings.get(session) || ""
}

function mapPathToSandbox(cfg, file, base) {
  const abs = absolutize(file, base)
  if (!abs || !cfg.active) return abs
  if (isWithin(abs, cfg.worktree)) return abs

  const worktreesBase = path.resolve(cfg.repo, cfg.worktreesDir)
  if (isWithin(abs, worktreesBase)) return abs

  if (isWithin(abs, cfg.repo)) {
    return path.join(cfg.worktree, path.relative(cfg.repo, abs))
  }
  return abs
}

function mapImplicitPathToSandbox(cfg, file, base) {
  const abs = absolutize(file, base)
  if (isExplicitAbsolute(file) && isWithin(abs, cfg.repo) && !isWithin(abs, cfg.worktree)) return abs
  return mapPathToSandbox(cfg, file, base)
}

function mapPatchPath(cfg, file, base) {
  const target = mapImplicitPathToSandbox(cfg, file, base)
  if (isWithin(target, base)) return toPosix(path.relative(base, target)) || "."
  return toPosix(target)
}

function rewritePatch(cfg, patchText, base) {
  return String(patchText || "")
    .split(/\r?\n/)
    .map((line) => {
      const match = line.match(/^(\*\*\* (?:Add File|Update File|Delete File|Move to): )(.+)$/)
      if (!match) return line
      return `${match[1]}${mapPatchPath(cfg, match[2].trim(), base)}`
    })
    .join("\n")
}

function patchTargets(patchText, base) {
  const targets = []
  for (const line of String(patchText || "").split(/\r?\n/)) {
    const match = line.match(/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/)
    if (!match) continue
    targets.push(absolutize(match[1].trim(), base))
  }
  return targets
}

function guardPath(cfg, file) {
  if (!cfg.active || !file) return
  const guard = path.join(cfg.root, "core", "cmd", "sandbox-guard.sh")
  if (!fs.existsSync(guard)) return

  try {
    execFileSync(
      resolveBash(),
      [
        guard,
        "--session",
        cfg.session,
        "--file",
        file,
        "--repo",
        cfg.repo,
        "--worktrees-dir",
        cfg.worktreesDir,
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    )
  } catch (error) {
    if (error && error.status === 1) {
      const reason = (commandOutput(error.stdout) || commandOutput(error.stderr)).trim()
      throw new Error(reason || "worktree-sandbox blocked a write outside the sandbox")
    }
  }
}

function commandMentionsMainRepo(cfg, command) {
  const normalized = toPosix(String(command || "")).toLowerCase()
  const repo = toPosix(cfg.repo).toLowerCase()
  const sandbox = toPosix(cfg.worktree).toLowerCase()
  return normalized.includes(repo) && !normalized.includes(sandbox)
}

function eventSessionID(event) {
  return event?.properties?.sessionID || event?.properties?.info?.id || event?.sessionID || ""
}

function injectShellEnv(cfg, output) {
  output.env.OPENCODE_SANDBOX_ACTIVE = "1"
  output.env.OPENCODE_SANDBOX_SESSION = cfg.session
  output.env.OPENCODE_SANDBOX_REPO = cfg.repo
  output.env.OPENCODE_SANDBOX_ROOT = cfg.root
  output.env.OPENCODE_SANDBOX_WORKTREE = cfg.worktree
  output.env.OPENCODE_SANDBOX_WORKTREES_DIR = cfg.worktreesDir
  output.env.OPENCODE_SANDBOX_BRANCH_PREFIX = cfg.branchPrefix
}

function sandboxToolDefinition(output) {
  const note = [
    "worktree-sandbox is active for this project.",
    "Use OPENCODE_SANDBOX_WORKTREE as the project root for file operations.",
    "Do not target the main repository path directly.",
  ].join(" ")
  if (!output.description || output.description.includes("worktree-sandbox is active")) return
  output.description = `${output.description}\n\n${note}`
}

export const WorktreeSandbox = async ({ directory, worktree }) => {
  const baseDirectory = directory || worktree || process.cwd()

  return {
    event: async ({ event }) => {
      const id = eventSessionID(event)
      if (!id) return

      if (event.type === "session.created" || event.type === "session.updated") {
        configFor(id, baseDirectory)
        return
      }

      if (event.type === "session.idle" || event.type === "session.status") {
        const cfg = configFor(id, baseDirectory)
        if (cfg.active) touchMarker(cfg)
        return
      }

      if (event.type === "session.deleted") {
        const session = sandboxSessionID(id)
        const cfg = state.sessions.get(session)
        if (cfg) cleanupConfig(cfg)
        state.sessions.delete(session)
        state.warnings.delete(session)
      }
    },

    "experimental.chat.system.transform": async (input, output) => {
      const cfg = configFor(input?.sessionID, baseDirectory)
      const warning = warningFor(input?.sessionID)
      if (!output || !Array.isArray(output.system)) return

      if (cfg.active && cfg.worktree) {
        output.system.push(`worktree-sandbox active. Use this root for all file operations: ${cfg.worktree}`)
        return
      }

      if (warning) output.system.push(`worktree-sandbox warning: ${warning}`)
    },

    "tool.definition": async (input, output) => {
      if (!input || !output || !SANDBOXED_TOOLS.has(input.toolID)) return
      sandboxToolDefinition(output)
    },

    "shell.env": async (input, output) => {
      const cfg = configFor(input?.sessionID, baseDirectory)
      if (!cfg.active || !output || !output.env) return
      injectShellEnv(cfg, output)
    },

    "tool.execute.before": async (input, output) => {
      const cfg = configFor(input?.sessionID, baseDirectory)
      if (!cfg.active || !input || !output) return

      const args = output.args || {}
      const tool = input.tool
      const cwd = absolutize(args.workdir || baseDirectory, baseDirectory)

      if (PATH_TOOLS.has(tool) && args.filePath) {
        args.filePath = mapImplicitPathToSandbox(cfg, args.filePath, cwd)
        guardPath(cfg, args.filePath)
        return
      }

      if (SEARCH_TOOLS.has(tool)) {
        args.path = args.path ? mapImplicitPathToSandbox(cfg, args.path, baseDirectory) : cfg.worktree
        guardPath(cfg, args.path)
        return
      }

      if (PATCH_TOOLS.has(tool)) {
        args.patchText = rewritePatch(cfg, args.patchText, baseDirectory)
        const targets = patchTargets(args.patchText, baseDirectory)
        if (targets.length === 0) {
          guardPath(cfg, path.join(cfg.worktree, ".__opencode_apply_patch_target__"))
          return
        }
        for (const target of targets) guardPath(cfg, target)
        return
      }

      if (tool === "bash") {
        const nextCwd = args.workdir ? mapImplicitPathToSandbox(cfg, args.workdir, baseDirectory) : cfg.worktree
        args.workdir = nextCwd
        if (commandMentionsMainRepo(cfg, args.command)) {
          throw new Error(
            `sandbox-guard: bash command mentions the main repo (${cfg.repo}). Run it from the sandbox instead: ${cfg.worktree}`,
          )
        }
        guardPath(cfg, path.join(nextCwd, ".__opencode_bash_target__"))
      }
    },
  }
}

export default WorktreeSandbox
