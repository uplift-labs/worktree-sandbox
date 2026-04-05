# singularity-sandbox

> Git worktree + TASK.md + auto-cleanup isolation for AI-assisted (and human)
> development. Keeps main untouchable. Makes session scope explicit. Cleans
> up after itself. No dependencies beyond bash and git.

## What this solves

Three recurring failure modes in AI-assisted development:

1. **Main branch contamination.** The assistant edits main directly, leaving
   half-finished work checked out in the primary branch.
2. **Implicit scope.** Nobody — human or AI — can point at a file and say
   "this is what the current session promised to deliver." Scope lives in
   chat and dies at context compaction.
3. **Abandoned state.** Crashed sessions leave stale worktrees, orphan
   branches, and marker files that pile up for months.

singularity-sandbox fixes all three with a tiny tool-agnostic bash layer.

## How it works

- **Sandbox per session.** `sandbox-init` creates a git worktree at
  `.sandbox/worktrees/sandbox-session-<id>` and seeds a placeholder `TASK.md`.
  All subsequent edits happen there; main is never touched by the assistant.
- **Explicit scope.** `TASK.md` at the sandbox root lists 3-7 concrete
  deliverables as checkboxes. `sandbox-merge-gate` refuses the merge while
  any box is unchecked.
- **Safe cleanup.** `sandbox-lifecycle` prunes merged sandboxes, reclaims
  crashed sessions via TTL-expired markers, and preserves anything with
  unsaved work on disk.

Nothing runs automatically unless you wire a host-assistant adapter or the
git `pre-merge-commit` hook. The core is plain bash scripts you can call.

## Install

```
git clone https://github.com/sergey-akhalkov/singularity-sandbox
cd /path/to/your/project
bash /path/to/singularity-sandbox/install.sh
```

This installs to `.sandbox/core/` in your project and wires a
`pre-merge-commit` hook that invokes the merge gate. To also install the
Claude Code adapter:

```
bash /path/to/singularity-sandbox/install.sh --with-claude-code
```

The adapter lands at `.sandbox/adapter/` and its hook config is merged into
`.claude/settings.json` (via jq if available, otherwise printed for manual
merge).

## Quickstart

```
# From inside your project, on main
bash .sandbox/core/cmd/sandbox-init.sh --repo "$PWD" --session demo
#  prints: <repo>/.sandbox/worktrees/sandbox-session-demo
cd .sandbox/worktrees/sandbox-session-demo

# Replace the TODO placeholders in TASK.md with real work
$EDITOR TASK.md

# Do work
echo "hello" > feature.txt
git add feature.txt && git commit -m "feat: add feature"

# Check off TASK.md boxes as you go
$EDITOR TASK.md

# Try to merge — the pre-merge-commit hook runs the gate
cd ..
git merge sandbox-session-demo

# Clean up (removes merged sandboxes, preserves dirty ones)
bash .sandbox/core/cmd/sandbox-lifecycle.sh --repo "$PWD"
```

## CLI

Four public commands. Full contract in `CONTRACT.md`.

| Command                   | Purpose                                                    |
|---------------------------|------------------------------------------------------------|
| `sandbox-init.sh`         | Create session sandbox worktree + seed `TASK.md`.          |
| `sandbox-guard.sh`        | Path gate: is an edit allowed given the active sandbox?    |
| `sandbox-lifecycle.sh`    | Periodic cleanup (merged, stale, orphan, residual).        |
| `sandbox-merge-gate.sh`   | Pre-merge validation (`TASK.md` + filesystem).             |

## Adapters

- **Claude Code** — `adapters/claude-code/`. Wraps SessionStart,
  PreToolUse(Edit|Write) and Stop hooks.
- **Git hooks** — installed automatically by `install.sh` as
  `pre-merge-commit`.

A new adapter is ~30-50 lines per hook: read host input, extract what you
need, call a `core/cmd/*` script with CLI flags, translate exit code + stdout
into the host's native decision format.

## Testing

```
bash tests/run.sh          # all
bash tests/run.sh unit     # unit only
bash tests/run.sh e2e      # e2e only
```

All tests use real temporary git repos via `mktemp -d` + `git init`. No mocks.
Current coverage: 5 unit files, 7 e2e scenarios, ~130 assertions.

## Why bash?

- Zero runtime dependencies. bash and git exist everywhere the audience lives.
- Git hooks are bash anyway — one language, one translation layer.
- The entire public surface is ~1000 lines, lint-clean under `shellcheck`.
  A rewrite in any compiled language would add install friction without
  changing what the tool can do.

Windows users: Git Bash / WSL are the supported environments. No native
PowerShell port is planned.

## License

TBD
