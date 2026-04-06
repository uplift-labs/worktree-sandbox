# singularity-sandbox

> Git worktree isolation + auto-cleanup for AI-assisted (and human)
> development. Keeps main untouchable. Cleans up after itself.
> No dependencies beyond bash and git.

## What this solves

Two recurring failure modes in AI-assisted development:

1. **Main branch contamination.** The assistant edits main directly, leaving
   half-finished work checked out in the primary branch.
2. **Abandoned state.** Crashed sessions leave stale worktrees, orphan
   branches, and marker files that pile up for months.

singularity-sandbox fixes both with a tiny tool-agnostic bash layer.

## How it works

- **Sandbox per session.** `sandbox-init` creates a git worktree at
  `.sandbox/worktrees/sandbox-session-<id>`.
  All subsequent edits happen there; main is never touched by the assistant.
- **Merge gate.** `sandbox-merge-gate` refuses the merge while the worktree
  has uncommitted changes (tracked modifications or untracked files).
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

# Do work
echo "hello" > feature.txt
git add feature.txt && git commit -m "feat: add feature"

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
| `sandbox-init.sh`         | Create session sandbox worktree.                           |
| `sandbox-guard.sh`        | Path gate: is an edit allowed given the active sandbox?    |
| `sandbox-lifecycle.sh`    | Periodic cleanup (merged, stale, orphan, residual).        |
| `sandbox-merge-gate.sh`   | Pre-merge validation (filesystem cleanliness).             |

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
at session end. Its only job:

1. **Heartbeat** the marker (`touch`) so lifecycle's TTL reclaim treats the
   session as live even on long, quiet turns.

**No merge. No cleanup. No blocking.** Filesystem cleanliness is enforced
at merge time by the `pre-merge-commit` hook, not mid-session.

### Phase C — Durability + housekeeping (SessionEnd)

`adapters/claude-code/hooks/session-end.sh` runs on real terminations
(`/exit`, Ctrl+D/C, SIGHUP on terminal close, logout, idle timeout). Branch
on the `reason` field from stdin JSON:

| `reason`                                    | Action                               | Rationale                                    |
|---------------------------------------------|--------------------------------------|----------------------------------------------|
| `clear`                                     | heartbeat marker only                | `/clear` resets context; session continues   |
| `compact`                                   | heartbeat marker only                | Symmetric to SessionStart compact handling   |
| `prompt_input_exit`, `logout`, `other`, ... | capture-commit + lifecycle (below)   | Real termination                             |

**SessionEnd does not merge into main.** Auto-merging on exit is too
aggressive — the user may want to review the diff, rebase, or discard.
Merging is always a deliberate user action (`git merge <branch>` or the
installed `pre-merge-commit` hook).

Steps on real termination:

1. Guard against in-progress states (`MERGE_HEAD`, rebase dirs, detached
   HEAD) — skip the commit phase if any apply, logging to stderr.
2. Stage everything in the sandbox (`git add -A`).
3. If anything is staged, commit with
   `chore(session-end): capture pending work on exit`. Project pre-commit
   hooks run normally; failures are logged and the sandbox is left as-is.
4. Invoke `sandbox-lifecycle.sh --repo <REPO>`. Lifecycle reaps *other*
   sandboxes whose branches are ancestors of `main` and whose worktrees
   are clean — the current session's branch is protected because its
   marker is live.

**Invariant after SessionEnd:** the current session's sandbox is still on
disk, its branch has all work committed, main is untouched. Any
previously-merged sandboxes from this or other sessions have been reaped.
The user merges when ready; the *next* SessionEnd (of any session) will
then reap the now-merged branch + worktree.

**Squash / rebase caveat:** the "merged" check uses
`git merge-base --is-ancestor`. Branches squash-merged or rebase-merged
into main are not ancestors and will not be auto-reaped. Either delete
them manually, or rely on the orphan-branch sweep (Phase 4 of lifecycle)
which matches branches by the `sandbox-session-*` prefix when they are
ancestors of main and no worktree references them.

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
   AND the tree has no tracked modifications or untracked files,
   remove the worktree and delete the branch. Anything unmerged or dirty
   is preserved.
4. **Orphan branch sweep**: delete branches matching `sandbox-session-*`
   that no worktree references and that are ancestors of main.
5. **Residual dir sweep**: remove empty `.sandbox/worktrees/*` directories
   that have no `.git` marker and no unhidden files.

Behaviour under different scenarios:

| State                                              | Marker pruned?  | Branch removed?                      | Worktree removed?             | Where work goes                                                            |
|----------------------------------------------------|-----------------|--------------------------------------|-------------------------------|----------------------------------------------------------------------------|
| Live session, heartbeat still fresh                | No              | No                                   | No                            | Keeps running                                                              |
| Clean SessionEnd, user has NOT merged yet          | No (fresh)      | No (unmerged)                        | No                            | Captured to branch, waits for user `git merge`                             |
| Clean SessionEnd, branch was already merged        | No (fresh)      | Protected by live marker this round  | Same                          | Reaped on the NEXT SessionEnd (of any session) once marker goes stale      |
| User runs `git merge` after SessionEnd             | Next TTL prune  | Yes (Phase 3/4) on next lifecycle    | Yes (Phase 3/5)               | In main; branch + worktree reaped next lifecycle pass                      |
| Crash mid-work, uncommitted changes never captured | Yes via TTL     | No (unmerged)                        | No (dirty)                    | **Entirely preserved** in the worktree — user can recover manually         |
| SessionEnd capture-commit failed (hook error)      | No (still fresh)| No                                   | No                            | Worktree stays dirty; user resolves on resume                              |
| Ghost empty directory from earlier reap            | —               | —                                    | Phase 5                       | Nothing to lose                                                            |

### TTL mismatch note

`sandbox-init` considers markers <24h fresh (reentrancy window), while
`sandbox-lifecycle` prunes them at >1h. If a session sits idle for >1h with
no agent turns (no heartbeat), a parallel session running lifecycle can
prune its marker. The branch and worktree survive (unmerged/dirty is
preserved), but the marker→worktree link is lost; a subsequent SessionStart
for the same `session_id` will create a **new** sandbox, and the orphan can
only be recovered manually. In practice this window is closed by the
per-turn heartbeat in Phase B and by the pre-lifecycle `touch` in Phase C —
the only vulnerable case is "open client, walk away for hours without
sending a message". If you need to close the window completely, pass
`--ttl 86400` from `session-start.sh` / `session-end.sh` to align both TTLs.

## Testing

```
bash tests/run.sh          # all
bash tests/run.sh unit     # unit only
bash tests/run.sh e2e      # e2e only
```

All tests use real temporary git repos via `mktemp -d` + `git init`. No mocks.

## Why bash?

- Zero runtime dependencies. bash and git exist everywhere the audience lives.
- Git hooks are bash anyway — one language, one translation layer.
- The entire public surface is ~800 lines, lint-clean under `shellcheck`.
  A rewrite in any compiled language would add install friction without
  changing what the tool can do.

Windows users: Git Bash / WSL are the supported environments. No native
PowerShell port is planned.

## License

TBD
