# worktree-sandbox

[![CI](https://github.com/uplift-labs/worktree-sandbox/actions/workflows/ci.yml/badge.svg)](https://github.com/uplift-labs/worktree-sandbox/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Git worktree isolation and automatic cleanup for AI-assisted development sessions. Keeps `main` untouched. Cleans up after itself. Zero dependencies beyond `bash` and `git`.

## Quickstart

Install into your project (one command, nothing to clone manually):

```bash
cd /path/to/your/project
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/main/remote-install.sh)
```

Or with the Claude Code adapter:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/main/remote-install.sh) --with-claude-code
```

That's it. Your repo now has sandbox isolation. Every session gets its own worktree, `main` is protected by a merge gate, and stale sandboxes clean themselves up.

<details>
<summary>Manual usage (after install)</summary>

```bash
# Create a sandbox (from main)
bash .sandbox/core/cmd/sandbox-init.sh --repo "$PWD" --session demo
cd .sandbox/worktrees/sandbox-session-demo

# Work freely
echo "hello" > feature.txt
git add feature.txt && git commit -m "feat: add feature"

# Merge back (pre-merge-commit hook validates cleanliness)
cd /path/to/repo
git merge sandbox-session-demo

# Clean up (automatic on next session start, or manual)
bash .sandbox/core/cmd/sandbox-lifecycle.sh --repo "$PWD"
```

</details>

## The problem

AI coding assistants (Claude Code, Cursor, Copilot Workspace, etc.) operate inside your git repository. Without guardrails, two things go wrong repeatedly:

1. **Main branch contamination.** The assistant edits files directly on `main`, leaving half-finished work in the primary branch. A careless `git push` ships broken code. Reverting requires manual archaeology through uncommitted changes, staged hunks, and new files.

2. **Abandoned state accumulates.** Every crashed session, lost connection, or force-quit leaves behind stale worktrees, orphan branches, and marker files. After a few weeks of active use, `git branch` returns dozens of dead `session-*` branches, and `.sandbox/worktrees/` is full of directories nobody remembers.

These aren't theoretical — they happen in every team that gives an AI agent write access to a real repo.

## How worktree-sandbox solves this

The tool creates a disposable **git worktree** for each session, enforces a **merge gate** before anything reaches `main`, and runs **automatic cleanup** of everything that's no longer needed.

```
main (protected)          sandbox-session-abc123 (worktree)
│                         │
│  ┌─── merge gate ───┐  │  AI works here freely
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
├── adapters/
│   └── claude-code/ ← host-specific translation layer
└── install.sh
```

### Two-layer design

- **`core/`** is the contract. CLI flags in, human-readable text out, fixed exit codes (`0` = allow, `1` = deny, `2` = bad usage). Tool-agnostic — knows nothing about Claude Code, Cursor, or any specific host. Full spec in [`CONTRACT.md`](CONTRACT.md).
- **`adapters/`** are translators. Each adapter is ~30-50 lines per hook: read the host's native input (JSON, env vars, hook args), call a `core/cmd/*` script, translate the result back. Adding support for a new tool means writing a new adapter, never touching `core/`.

### State management

State lives in two places, both TTL-managed:

1. **Markers** — one small file per session at `<git-common-dir>/sandbox-markers/<session-id>`. Contains branch name, creation epoch, and initial HEAD. A background **heartbeat** process touches the marker every second while the session is alive.
2. **Worktrees** — at `<repo>/.sandbox/worktrees/<branch-name>`. Standard git worktrees, created by `sandbox-init`, cleaned by `sandbox-lifecycle`.

### Fail-open policy

All `core/cmd/` scripts exit `0` silently when git context can't be resolved (not a repo, detached HEAD, etc.). A broken install must never block your workflow. These are safety nets, not gatekeepers.

## Install

**One-liner (remote):**

```bash
bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/main/remote-install.sh) --with-claude-code
```

**From a local clone:**

```bash
git clone https://github.com/uplift-labs/worktree-sandbox
bash worktree-sandbox/install.sh --with-claude-code
```

Installs `core/` to `.sandbox/core/`, wires `pre-merge-commit` + `post-merge` git hooks. With `--with-claude-code`, the adapter goes to `.sandbox/adapter/` and its hook config is merged into `.claude/settings.json` (via `jq` if available, otherwise printed for manual merge).

Re-running is safe (idempotent). The `post-merge` hook auto-syncs `.sandbox/` on every merge.

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

### Git hooks

Installed automatically by `install.sh`:

| Hook | Purpose |
|---|---|
| `pre-merge-commit` | Blocks merge if the sandbox worktree has tracked modifications or untracked files. |
| `post-merge` | Re-runs `install.sh` in background after every merge to keep `.sandbox/` in sync. |

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

`session-end.sh` runs on termination (`/exit`, Ctrl+C/D, terminal close, logout). On real exit: (1) kill heartbeat, (2) stage + commit pending work, (3) run lifecycle. On `/clear` or `/compact`: heartbeat only.

**SessionEnd never merges into main.** The user merges when ready.

### Phase D — Compact restart

`/compact` ends the process but the session continues. Both session-end and session-start treat this as a no-op: heartbeat only. One `session_id` maps to one sandbox across any number of compact cycles.

### Phase E — Safety net

Windows can't guarantee SIGHUP delivery. Sessions can be killed by OOM, power loss, or `kill -9`. The TTL safety net in `sandbox-lifecycle` catches everything that SessionEnd missed:

1. `git worktree prune` — drop metadata for manually-removed worktrees.
2. **TTL reclaim** — delete markers whose mtime exceeds TTL. Sessions that never committed get an extended 5-minute TTL to protect live sessions with dead heartbeats.
3. **Proactive release** — drop markers for sandboxes already merged+clean, even if TTL hasn't expired.
4. **Clean merged worktrees** — remove worktrees whose branch is an ancestor of main and has no uncommitted work. Marker-protected branches are skipped.
5. **Orphan branch sweep** — delete `sandbox-session-*` branches that no worktree references and are ancestors of main.
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

25 test files (7 unit + 18 e2e) covering all core commands and adapter hooks. All tests create real temporary git repos via `mktemp -d` + `git init`. No mocks.

## Platform support

| Platform | Status |
|---|---|
| Linux | Fully supported, tested in CI |
| macOS | Fully supported, tested in CI |
| Windows (Git Bash / MSYS) | Fully supported, tested in CI. Windows-specific code handles PID resolution via `wmic`, path normalization via `cygpath`, and `nohup` workarounds. |
| Windows (WSL) | Works (same as Linux) |
| Windows (PowerShell native) | Not supported. No port planned. |

## Why bash?

- **Zero dependencies.** `bash` and `git` exist everywhere the target audience works.
- **Git hooks are bash anyway.** One language, one translation layer, no build step.
- **Small surface area.** The entire public CLI is ~800 lines, lint-clean under `shellcheck`. A rewrite in a compiled language would add install friction without changing capability.

## License

[MIT](LICENSE)
