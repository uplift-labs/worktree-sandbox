# worktree-sandbox

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> **This is a personal pet project. Use at your own risk.**

Git worktree isolation and automatic cleanup for AI-assisted development sessions. Keeps `main` untouched. Cleans up after itself. Core runtime has zero dependencies beyond `bash` and `git`.

## Quickstart

Install into your project with Claude Code:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/v1.1.0/remote-install.sh) --with-claude-code
```

Or install for Codex CLI:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/v1.1.0/remote-install.sh) --with-codex
bash .uplift/sandbox/adapters/codex/bin/codex-sandbox.sh
```

Or install for OpenCode:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/v1.1.0/remote-install.sh) --with-opencode
opencode
```

Or add OS-level sandboxing for OpenCode `bash` commands on macOS/Linux:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/v1.1.0/remote-install.sh) --with-opencode-os-sandbox
opencode
```

That's it. Your repo now has sandbox isolation. Every session gets its own worktree, `main` is protected by a merge gate, and stale sandboxes clean themselves up.

<details>
<summary>Manual usage (after install)</summary>

```bash
# Create a sandbox (from main)
bash .uplift/sandbox/core/cmd/sandbox-init.sh \
  --repo "$PWD" \
  --session demo \
  --worktrees-dir .uplift/sandbox/worktrees
cd .uplift/sandbox/worktrees/wt-demo

# Work freely
echo "hello" > feature.txt
git add feature.txt && git commit -m "feat: add feature"

# Merge back (pre-merge-commit hook validates cleanliness)
cd /path/to/repo
git merge wt-demo

# Clean up (automatic on next session start, or manual)
bash .uplift/sandbox/core/cmd/sandbox-lifecycle.sh \
  --repo "$PWD" \
  --worktrees-dir .uplift/sandbox/worktrees
```

</details>

## The problem

AI coding assistants (Claude Code, Cursor, Copilot Workspace, etc.) operate inside your git repository. Without guardrails, two things go wrong repeatedly:

1. **Main branch contamination.** The assistant edits files directly on `main`, leaving half-finished work in the primary branch. A careless `git push` ships broken code. Reverting requires manual archaeology through uncommitted changes, staged hunks, and new files.

2. **Abandoned state accumulates.** Every crashed session, lost connection, or force-quit leaves behind stale worktrees, orphan branches, and marker files. After a few weeks of active use, `git branch` returns dozens of dead `session-*` branches, and sandbox worktree directories are full of state nobody remembers.

These aren't theoretical — they happen in every team that gives an AI agent write access to a real repo.

## How worktree-sandbox solves this

The tool creates a disposable **git worktree** for each session, enforces a **merge gate** before anything reaches `main`, and runs **automatic cleanup** of everything that's no longer needed.

```
main (protected)          wt-abc123… (worktree)
│                         │
│  ┌─── merge gate ───┐   │  AI works here freely
│  │ uncommitted work? │◄─┤  - edits, commits, experiments
│  │ → block merge     │  │  - main is never touched
│  │ clean?            │  │
│  │ → allow merge     │  │
│  └───────────────────┘  │
│                         │
▼                         ▼
after merge: lifecycle auto-removes the worktree, branch, and markers
```

**Three guarantees:**

- **Isolation.** Every session gets its own worktree branched from `main`. The assistant physically cannot edit files in the main working tree (enforced by a path gate on every Edit/Write).
- **No data loss.** Merged and clean sandboxes are reaped. Dirty or unmerged sandboxes are preserved — even if the session crashed and never called cleanup. Uncommitted work stays on disk until the user deals with it.
- **No accumulation.** TTL-expired markers, merged branches, orphan branches, and empty directories are cleaned up automatically on every session start. Nothing piles up.

## Architecture

```
worktree-sandbox/
├── core/
│   ├── cmd/         ← public CLI (stable contract)
│   │   ├── sandbox-init.sh
│   │   ├── sandbox-guard.sh
│   │   ├── sandbox-lifecycle.sh
│   │   ├── sandbox-cleanup.sh
│   │   └── sandbox-merge-gate.sh
│   └── lib/         ← internal helpers (not public API)
│       └── json-merge.py  ← idempotent settings.json merger
├── adapters/
│   ├── claude-code/ ← Claude Code hook translation layer
│   ├── codex/       ← Codex hook wrappers + launcher
│   └── opencode/    ← OpenCode plugin + optional launcher
└── install.sh
```

### Two-layer design

- **`core/`** is the contract. CLI flags in, human-readable text out, fixed exit codes (`0` = allow, `1` = deny, `2` = bad usage). Tool-agnostic — knows nothing about Claude Code, Cursor, or any specific host. Full spec in [`CONTRACT.md`](CONTRACT.md).
- **`adapters/`** are translators. Each adapter is ~30-50 lines per hook: read the host's native input (JSON, env vars, hook args), call a `core/cmd/*` script, translate the result back. Adding support for a new tool means writing a new adapter, never touching `core/`.

### State management

State lives in two places, both TTL-managed:

1. **Markers** — one small file per session at `<git-common-dir>/sandbox-markers/<session-id>`. Contains branch name, creation epoch, and initial HEAD. A background **heartbeat** process touches the marker every second while the session is alive.
2. **Worktrees** — by default at `<repo>/.sandbox/worktrees/<branch-name>` when running from the source tree; installed adapters pass `<repo>/.uplift/sandbox/worktrees/<branch-name>`. Standard git worktrees, created by `sandbox-init`, cleaned by `sandbox-lifecycle`.

### Fail-open policy

All `core/cmd/` scripts exit `0` silently when git context can't be resolved (not a repo, detached HEAD, etc.). A broken install must never block your workflow. These are safety nets, not gatekeepers.

## Install

**One-liner (remote):**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/v1.1.0/remote-install.sh) --with-claude-code
```

**From a local clone:**

```bash
git clone https://github.com/uplift-labs/worktree-sandbox
bash worktree-sandbox/install.sh --with-claude-code
bash worktree-sandbox/install.sh --with-codex
bash worktree-sandbox/install.sh --with-opencode
bash worktree-sandbox/install.sh --with-opencode-os-sandbox
```

Installs `core/` to `.uplift/sandbox/core/`, wires `pre-merge-commit` + `post-merge` git hooks, and ignores only `.uplift/sandbox/worktrees/`. With `--with-claude-code`, the adapter goes to `.uplift/sandbox/adapter/` and its hook config is merged into `.claude/settings.json` (requires `python3`). With `--with-codex`, the adapter goes to `.uplift/sandbox/adapters/codex/`, hooks are merged into `.codex/hooks.json`, and `features.codex_hooks = true` is enabled in `.codex/config.toml`. With `--with-opencode`, the adapter goes to `.uplift/sandbox/adapters/opencode/`, project-local plugins are written to `.opencode/plugins/` and `.opencode/tui-plugins/`, and normal `opencode` launches create sandbox sessions through plugin hooks. With `--with-opencode-os-sandbox`, `--with-opencode` is implied and the external `opencode-sandbox` npm plugin is added to `opencode.json` (requires `python3`).

Re-running is safe (idempotent). The `post-merge` hook auto-syncs `.uplift/sandbox/` on every merge and preserves installed adapter flags.

## CLI reference

Five public commands. Full contract in [`CONTRACT.md`](CONTRACT.md).

| Command | Purpose |
|---|---|
| `sandbox-init.sh` | Create a session sandbox worktree branched from main. |
| `sandbox-guard.sh` | Path gate: allow or deny an edit based on active sandbox location. |
| `sandbox-lifecycle.sh` | Periodic cleanup: merged worktrees, stale markers, orphan branches, residual dirs. |
| `sandbox-cleanup.sh` | Session cleanup: capture-commit + self-release + lifecycle. Called by session-end and heartbeat. |
| `sandbox-merge-gate.sh` | Pre-merge validation: block if worktree has uncommitted changes. |

## Adapters

### Claude Code

The Claude Code adapter (`adapters/claude-code/`) wires four hooks:

| Hook | What it does |
|---|---|
| **SessionStart** | Runs lifecycle (cleans prior sessions), creates sandbox, launches heartbeat. On compact restart: re-emits banner, skips init. |
| **PreToolUse** | Enforces that Edit/Write targets the sandbox worktree, not main. |
| **Stop** | Per-turn heartbeat: touches marker so lifecycle treats session as live. No merge, no cleanup, no blocking. |
| **SessionEnd** | On real exit: kills heartbeat, capture-commits pending work, runs lifecycle. On `/clear` or `/compact`: heartbeat only. Never merges — that's the user's choice. |

### Codex CLI

The Codex adapter (`adapters/codex/`) has a recommended launcher plus lifecycle hooks:

| Component | What it does |
|---|---|
| `codex-sandbox.sh` | Creates the sandbox before Codex starts, runs `codex -C <sandbox>`, exports `CODEX_SANDBOX_*` env vars for hooks, and calls cleanup when Codex exits. |
| **SessionStart** | Runs lifecycle, creates a sandbox in hook-only mode, or reinforces the launcher-created sandbox via additional context. |
| **PreToolUse** | Blocks supported write tools, including `apply_patch`, when they run from the main repo while the session owns a sandbox. |
| **Stop** | Returns Codex `{"continue":true}` and refreshes marker mtime. |

Codex currently has no `SessionEnd` hook equivalent to Claude Code. Use the launcher for the strongest guarantee; hook-only mode is a fallback that adds context and blocks supported write tools but cannot change Codex's process cwd after startup.

### OpenCode

The OpenCode adapter (`adapters/opencode/`) is plugin-first:

| Component | What it does |
|---|---|
| Plugin | Loads automatically from `.opencode/plugins/`, creates a sandbox on `session.created` or the first session-aware hook, injects system context, passes sandbox env vars to shell tools, maps supported built-in tools to the sandbox, blocks explicit main-repo write targets, refreshes markers, and cleans up on `session.deleted` or process exit. |
| TUI plugin | Loads from `.opencode/tui.json`, adds a right-sidebar `Sandbox Modified Files` list from the real sandbox git diff, watches the worktree's real git `HEAD` for branch changes, and keeps polling as a fallback. The branch badge is disabled by default because OpenCode already renders the current branch in its footer. |
| `opencode-sandbox.sh` | Optional strict mode: creates the sandbox before OpenCode starts and runs `opencode` from the sandbox worktree. Useful when you need the OpenCode process cwd itself to be the sandbox. |

The plugin is the normal path: after `--with-opencode`, run `opencode` as usual. OpenCode does not expose a pre-bootstrap hook that mutates its internal project root, so the plugin virtualizes supported tool paths into the sandbox and uses the launcher only as an optional stricter cwd mode. In plugin-first mode OpenCode's own footer/status may still show the original repo and branch; trust `OPENCODE_SANDBOX_WORKTREE`, tool working dirs, or `git status` run by the tool for the active sandbox state. Use the launcher when the UI/process root itself must show the sandbox worktree.

The TUI plugin resolves the session sandbox worktree from `OPENCODE_SANDBOX_WORKTREE` or the session marker, then watches the resolved worktree git `HEAD` path. `git switch` normally updates immediately through the file watcher; polling remains as a fallback for missed branch events. The sidebar file list reads committed changes on the current sandbox branch relative to its merge-base with `main`/`master`, plus staged, unstaged, and untracked files in the sandbox worktree. This keeps unrelated main-repo changes out of the sidebar, even when main has moved or been merged into the sandbox branch. File refreshes are debounced and use asynchronous git commands with a timeout so OpenCode's UI thread is not blocked after edits. Tune fallback polling with `AISB_OPENCODE_BRANCH_REFRESH_MS` (default `5000` ms while the watcher is active, `1000` ms without it), `AISB_OPENCODE_FILES_REFRESH_MS` (disabled by default; set a positive ms value to enable), and `AISB_OPENCODE_GIT_TIMEOUT_MS` (default `3000`). Enable the old prompt branch badge with `AISB_OPENCODE_BRANCH_BADGE=1`, disable branch watching with `AISB_OPENCODE_BRANCH_WATCH=0`, and enable debug logs with `AISB_OPENCODE_BRANCH_DEBUG=1` or `AISB_OPENCODE_FILES_DEBUG=1`.

The built-in OpenCode `Modified Files` sidebar reads OpenCode's original project root. To avoid mutating OpenCode's internal plugin state during normal UI rendering, the TUI plugin no longer deactivates `internal:sidebar-files` by default. Set `AISB_OPENCODE_HIDE_BUILTIN_FILES=1` to restore the old behavior.

Optional OS-level sandboxing is available with `--with-opencode-os-sandbox`. This does not replace worktree isolation; it adds the community `opencode-sandbox` npm plugin so OpenCode `bash` tool calls are wrapped by `@anthropic-ai/sandbox-runtime`. On macOS this uses Seatbelt / `sandbox-exec`; on Linux it uses `bubblewrap` plus runtime helpers; on Windows it is unsupported and commands pass through unsandboxed. The launcher points OpenCode at the source repo `opencode.json` when that config enables `opencode-sandbox`, so the npm plugin can load even before the install changes have been committed into the newly-created worktree.

### Git hooks

Installed automatically by `install.sh`:

| Hook | Purpose |
|---|---|
| `pre-merge-commit` | Blocks merge if the sandbox worktree has tracked modifications or untracked files. |
| `post-merge` | Re-runs `install.sh` in background after every merge to keep `.uplift/sandbox/` in sync. |

### Writing a new adapter

A new adapter is ~30-50 lines per hook: read host input → extract session ID and file path → call `core/cmd/*` with CLI flags → translate exit code + stdout into the host's decision format. No changes to `core/` required.

## Sandbox lifecycle

A sandbox goes through a predictable lifecycle. Understanding it prevents subtle bugs (premature cleanup, lost work on `/clear`, ghost CWDs after merge).

### Phase A — Create

`session-start.sh` runs on every session start. On a **compact restart**, it re-emits the banner and exits (no init, no lifecycle). On a **normal start**, it runs `sandbox-lifecycle` first (cleans prior sessions), then `sandbox-init`.

**Invariant:** exactly one marker, one branch, one worktree per session.

### Phase B — Live session

`stop.sh` runs after every agent turn. Its only job: touch the marker to keep the TTL fresh. No merge, no cleanup.

### Phase C — Session end

For Claude Code, `session-end.sh` runs on termination (`/exit`, Ctrl+C/D, terminal close, logout). On real exit: (1) kill heartbeat, (2) stage + commit pending work, (3) run lifecycle. On `/clear` or `/compact`: heartbeat only. For Codex CLI, `codex-sandbox.sh` performs the equivalent cleanup when the launched `codex` process exits. For OpenCode, the project plugin cleanup runs on `session.deleted` and process exit; the optional launcher performs the same cleanup when the launched `opencode` process exits.

**SessionEnd never merges into main.** The user merges when ready.

### Phase D — Compact restart

`/compact` ends the process but the session continues. Both session-end and session-start treat this as a no-op: heartbeat only. One `session_id` maps to one sandbox across any number of compact cycles.

### Phase E — Safety net

Windows can't guarantee SIGHUP delivery. Sessions can be killed by OOM, power loss, or `kill -9`. The TTL safety net in `sandbox-lifecycle` catches everything that SessionEnd missed:

1. `git worktree prune` — drop metadata for manually-removed worktrees.
2. **TTL reclaim** — delete markers whose mtime exceeds TTL. Sessions that never committed get an extended 5-minute TTL to protect live sessions with dead heartbeats.
3. **Proactive release** — drop markers for sandboxes already merged+clean, even if TTL hasn't expired.
4. **Clean merged worktrees** — remove worktrees whose branch is an ancestor of main and has no uncommitted work. Marker-protected branches are skipped.
5. **Orphan branch sweep** — delete `wt-*` branches that no worktree references and are ancestors of main.
6. **Residual dir sweep** — remove empty worktree directories.

### What happens in each scenario

| Scenario | Marker | Branch | Worktree | Work |
|---|---|---|---|---|
| Live session, heartbeat fresh | kept | kept | kept | keeps running |
| Clean exit, not yet merged | kept (fresh) | kept (unmerged) | kept | captured to branch, user merges when ready |
| User merges after exit | next TTL prune | reaped next lifecycle | reaped next lifecycle | in main |
| Crash, uncommitted changes | TTL prune | kept (unmerged) | kept (dirty) | **preserved on disk** — user recovers manually |
| Crash, no uncommitted changes | TTL prune | reaped if ancestor of main | reaped if clean | nothing to lose |

### Squash/rebase caveat

Lifecycle's "merged" check uses `git merge-base --is-ancestor`. Squash-merged or rebase-merged branches are not detected as ancestors. Delete them manually or rely on the orphan branch sweep (Phase 5) if the original commits are in main.

## Testing

```bash
bash tests/run.sh               # all (unit + e2e)
bash tests/run.sh unit          # unit only
bash tests/run.sh e2e           # e2e only
bash tests/run.sh tests/e2e/t01-happy-path.sh   # single file
```

32 test files (9 unit + 23 e2e) covering all core commands and adapter hooks. All tests create real temporary git repos via `mktemp -d` + `git init`. No mocks.

## Platform support

| Platform | Status |
|---|---|
| Windows (Git Bash / MSYS) | Fully supported. Windows-specific code handles PID resolution via `wmic`, path normalization via `cygpath`, and `nohup` workarounds. |
| Linux | TBD |
| macOS | TBD |
| Windows (WSL) | TBD |
| Windows (PowerShell native) | Not supported. No port planned. |

## Why bash?

- **Zero dependencies.** `bash` and `git` exist everywhere the target audience works.
- **Git hooks are bash anyway.** One language, one translation layer, no build step.
- **Small surface area.** The entire public CLI is ~800 lines, lint-clean under `shellcheck`. A rewrite in a compiled language would add install friction without changing capability.

## License

[MIT](LICENSE)
