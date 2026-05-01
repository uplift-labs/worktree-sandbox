import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"

function envValue(name) {
  return process.env[name] || ""
}

function activeConfig() {
  const repo = envValue("OPENCODE_SANDBOX_REPO")
  const root = envValue("OPENCODE_SANDBOX_ROOT") || (repo ? path.join(repo, ".uplift", "sandbox") : "")
  const session = envValue("OPENCODE_SANDBOX_SESSION")
  const worktree = envValue("OPENCODE_SANDBOX_WORKTREE")
  return {
    active: envValue("OPENCODE_SANDBOX_ACTIVE") === "1" && !!session && !!repo && !!root,
    session,
    repo,
    root,
    worktree,
    worktreesDir: envValue("OPENCODE_SANDBOX_WORKTREES_DIR") || ".sandbox/worktrees",
  }
}

function absolutize(file, base) {
  if (!file) return ""
  return path.isAbsolute(file) ? file : path.resolve(base, file)
}

function commandOutput(value) {
  if (!value) return ""
  if (Buffer.isBuffer(value)) return value.toString("utf8")
  return String(value)
}

function guardPath(cfg, file) {
  if (!cfg.active || !file) return
  const guard = path.join(cfg.root, "core", "cmd", "sandbox-guard.sh")
  if (!fs.existsSync(guard)) return

  try {
    execFileSync(
      "bash",
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

function patchTargets(patchText, base) {
  const targets = []
  for (const line of String(patchText || "").split(/\r?\n/)) {
    const match = line.match(/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/)
    if (!match) continue
    targets.push(absolutize(match[1].trim(), base))
  }
  return targets
}

export const WorktreeSandbox = async ({ directory, worktree }) => {
  const baseDirectory = directory || worktree || process.cwd()

  return {
    "experimental.chat.system.transform": async (_input, output) => {
      const cfg = activeConfig()
      if (!cfg.active || !cfg.worktree || !output || !Array.isArray(output.system)) return
      output.system.push(`worktree-sandbox active. Use this root for all file operations: ${cfg.worktree}`)
    },

    "shell.env": async (_input, output) => {
      const cfg = activeConfig()
      if (!cfg.active || !output || !output.env) return
      output.env.OPENCODE_SANDBOX_ACTIVE = "1"
      output.env.OPENCODE_SANDBOX_SESSION = cfg.session
      output.env.OPENCODE_SANDBOX_REPO = cfg.repo
      output.env.OPENCODE_SANDBOX_ROOT = cfg.root
      output.env.OPENCODE_SANDBOX_WORKTREE = cfg.worktree
      output.env.OPENCODE_SANDBOX_WORKTREES_DIR = cfg.worktreesDir
      output.env.OPENCODE_SANDBOX_BRANCH_PREFIX = envValue("OPENCODE_SANDBOX_BRANCH_PREFIX") || "wt"
    },

    "tool.execute.before": async (input, output) => {
      const cfg = activeConfig()
      if (!cfg.active || !input || !output) return

      const args = output.args || {}
      const tool = input.tool
      const cwd = absolutize(args.workdir || baseDirectory, baseDirectory)

      if (tool === "edit" || tool === "write") {
        guardPath(cfg, absolutize(args.filePath, cwd))
        return
      }

      if (tool === "apply_patch" || tool === "patch") {
        const targets = patchTargets(args.patchText, cwd)
        if (targets.length === 0) {
          guardPath(cfg, path.join(cwd, ".__opencode_apply_patch_target__"))
          return
        }
        for (const target of targets) guardPath(cfg, target)
        return
      }

      if (tool === "bash") {
        guardPath(cfg, path.join(cwd, ".__opencode_bash_target__"))
      }
    },
  }
}

export default WorktreeSandbox
