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
  PreToolUse(Edit|Write), Stop, and SessionEnd hooks.
- **Git hooks** — installed automatically by `install.sh` as
  `pre-merge-commit`.

A new adapter is ~30-50 lines per hook: read host input, extract what you
need, call a `core/cmd/*` script with CLI flags, translate exit code + stdout
into the host's native decision format.

## Worktree lifecycle (Claude Code adapter)

The Claude Code adapter splits a sandbox's life into five phases. Understanding
this avoids a class of subtle bugs (graduating mid-conversation, losing work
on `/clear`, ghost CWDs after merge). The split below is the authoritative
mental model — source files implement it but should not need to be read to
use the tool.

### Phase A — Create (SessionStart)

`adapters/claude-code/hooks/session-start.sh` runs on every session start.

- **Compact restart** (`source == "compact"`): read the existing marker,
  verify its worktree still exists, re-emit the `[sandbox] ...` banner, and
  exit. No lifecycle, no init — touching either would destroy the sandbox
  we are about to resume into.
- **Normal start**: run `sandbox-lifecycle` first (cleans tails from prior
  sessions — see Phase E), then `sandbox-init`. If a fresh marker (<24h)
  for this `session_id` already exists and the worktree is on disk,
  `sandbox-init` is a no-op and returns the existing path (reentrancy on
  process restarts).

Invariant after Phase A: exactly one live marker, one branch, one worktree
directory per session.

### Phase B — Live session (per-turn Stop)

`adapters/claude-code/hooks/stop.sh` runs after **every agent turn**, not
at session end. Its job is deliberately small:

1. **Heartbeat** the marker (`touch`) so lifecycle's TTL reclaim treats the
   session as live even on long, quiet turns.
2. Run `sandbox-merge-gate` as a **read-only** check. On failure (unchecked
   `TASK.md`, tracked modifications, untracked files) emit
   `{"decision":"block","reason":"..."}` so the agent gets a chance to fix
   it on the next turn.
3. On success — do nothing else. **No merge. No cleanup. No marker removal.**
   The sandbox stays alive for the next turn.

This is the load-bearing change vs earlier versions. `Stop` firing per turn
means any graduation logic here will destroy a live sandbox the first time
`TASK.md` happens to be fully checked.

### Phase C — Graduation (SessionEnd)

`adapters/claude-code/hooks/session-end.sh` runs on real terminations
(`/exit`, Ctrl+D/C, SIGHUP on terminal close, logout, idle timeout). Branch
on the `reason` field from stdin JSON:

| `reason`                          | Action                                   | Rationale                                       |
|-----------------------------------|------------------------------------------|-------------------------------------------------|
| `clear`                           | heartbeat marker only                    | `/clear` resets context; session continues      |
| `compact`                         | heartbeat marker only                    | Symmetric to SessionStart compact handling      |
| `prompt_input_exit`, `logout`, `other`, ... | full graduate (see below)       | Real termination                                |

Full graduate steps:

1. Run `sandbox-merge-gate`. If it fails: **log and leave everything alive**.
   SessionEnd cannot block exit, so the only safe move is to let the TTL
   safety-net reclaim it later (or a resume session pick it up). Do not
   remove the marker.
2. Delete the sandbox's `TASK.md` so the template does not pollute main.
3. `git merge <branch>` into main (skipped if already ancestor). On conflict:
   `merge --abort`, leave the branch + marker alive, log the conflict.
4. Remove the marker and invoke `sandbox-lifecycle` — it reaps the (now
   merged + clean) worktree, deletes the branch, and sweeps any residual
   directory.

Invariant after a successful graduate: no marker, no branch, no worktree
directory. Commits are in main. The CWD becomes a "ghost" (physically gone),
which is fine because the session is already terminating.

### Phase D — Compact restart

`/compact` (manual or automatic) ends the current agent process but the
session formally continues. Both `session-end.sh` (if it fires with a
compact-shaped reason) and `session-start.sh` (when invoked with
`source == "compact"`) treat this as no-op: marker heartbeat only, never
merge, never clean. This guarantees **one `session_id` ↔ one sandbox** across
any number of compact cycles.

### Phase E — Safety net (lifecycle on next SessionStart)

Windows cannot guarantee SIGHUP delivery, and any session can be killed by
OOM / power loss / `kill -9`. SessionEnd is not authoritative — the TTL
safety-net in `sandbox-lifecycle.sh` is. It runs in this order at the start
of every normal session:

1. `git worktree prune` — drop metadata for manually-removed worktrees.
2. **TTL reclaim**: delete marker files whose mtime is older than TTL
   (default `3600s` in lifecycle; `sandbox-init` treats markers <24h as
   fresh — see TTL note below).
3. **Clean merged worktrees**: for each worktree whose branch is a live
   marker's branch → skip. Otherwise, if the branch is an ancestor of main
   AND the tree has no tracked modifications or untracked files (TASK.md
   is excluded from the dirty check), remove the worktree and delete the
   branch. Anything unmerged or dirty is preserved.
4. **Orphan branch sweep**: delete branches matching `sandbox-session-*`
   that no worktree references and that are ancestors of main.
5. **Residual dir sweep**: remove empty `.sandbox/worktrees/*` directories
   that have no `.git` marker and no unhidden files.

Behaviour under different crash scenarios:

| State after crash                               | Marker pruned?      | Branch removed?                  | Worktree removed?             | Where work goes                                              |
|-------------------------------------------------|---------------------|----------------------------------|-------------------------------|--------------------------------------------------------------|
| Clean close, SessionEnd never fired             | Yes (via TTL)       | Phase 4, only if ancestor of main| Phase 3, only if merged+clean | Stays as unmerged feature branch if work never merged        |
| Live session, heartbeat still fresh             | No                  | No                               | No                            | Keeps running                                                |
| Crash mid-work with uncommitted changes         | Yes via TTL         | No (unmerged)                    | No (dirty)                    | **Entirely preserved** — user can recover manually           |
| SessionEnd gate failed                          | No (we kept it)     | No                               | No                            | Lives until manual resolution or the TTL eventually trips    |
| Ghost empty directory after successful graduate | —                   | —                                | Phase 5                       | Nothing to lose                                              |

### TTL mismatch note

`sandbox-init` considers markers <24h fresh (reentrancy window), while
`sandbox-lifecycle` prunes them at >1h. If a session sits idle for >1h with
no agent turns (no heartbeat), a parallel session running lifecycle can
prune its marker. The branch and worktree survive (unmerged/dirty is
preserved), but the marker→worktree link is lost; a subsequent SessionStart
for the same `session_id` will create a **new** sandbox, and the orphan can
only be recovered manually. In practice this window is closed by the
per-turn heartbeat in Phase B — the only vulnerable case is "open client,
walk away for hours without sending a message". If you need to close the
window completely, pass `--ttl 86400` from `session-start.sh` to align both
TTLs.

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
