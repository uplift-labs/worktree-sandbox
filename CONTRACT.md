# Public CLI Contract

Every script under `core/cmd/` is a stable public entry point. Scripts under
`core/lib/` are internal helpers and may change without notice.

## Conventions

- **Input:** CLI flags + env vars only. No JSON on stdin.
- **Output:** human-readable text on stdout. No JSON unless explicitly noted.
- **Exit codes:** `0` = success / allow, `1` = blocked / failure with reason on
  stdout, `2` = bad usage (missing required flag, etc.), higher codes are
  defined per-command below.
- **Fail-open policy:** when git context cannot be resolved, commands exit `0`
  silently — they are safety nets, not gatekeepers.
- **Marker storage:** `<git-common-dir>/sandbox-markers/<session-id>`.
  One small file per active session; first field = branch name, second field
  = creation epoch, third field = initial HEAD at marker creation (added
  v0.x — absent in legacy markers). The initial HEAD lets lifecycle Phase 3
  distinguish "session never committed" from "session committed and merged"
  when both leave branch == main. Markers are auto-expired via TTL.
- **Worktree location:** `<repo-root>/.sandbox/worktrees/<branch-name>`.

## Commands

### `sandbox-init`

Create a session sandbox worktree with a seeded `TASK.md` template.

```
sandbox-init.sh --repo <dir> --session <id> [--base <branch>]
```

| Flag        | Required | Description                                        |
|-------------|----------|----------------------------------------------------|
| `--repo`    | yes      | Absolute path to the main repo (must be on main/master) |
| `--session` | yes      | Unique session identifier (becomes part of branch name) |
| `--base`    | no       | Base branch to fork from (default: auto-detected)  |

**Output:** absolute sandbox path on stdout on success.
**Exit:** `0` success or no-op (already sandboxed / not on main) / `1` hard
failure (with message) / `2` bad usage.

### `sandbox-guard`

Path gate: decide whether an edit at `<file>` is allowed.

```
sandbox-guard.sh --session <id> --file <path> [--repo <dir>]
```

**Allow** when: no active sandbox / file inside sandbox / file outside repo.
**Deny** when: file is inside main repo but outside the session's sandbox.

**Exit:** `0` allow / `1` deny (reason on stdout) / `2` bad usage.

### `sandbox-lifecycle`

Periodic cleanup. Call from session start, session stop, or a cron job.

```
sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>]
```

| Flag              | Required | Default               | Description              |
|-------------------|----------|-----------------------|--------------------------|
| `--repo`          | yes      | —                     | Main repo path           |
| `--ttl`           | no       | `3600`                | Marker TTL (stale reclaim) |
| `--branch-prefix` | no       | `sandbox-session-*`   | Glob for orphan branch sweep |

**Phases:** prune metadata → reclaim stale markers (TTL) → proactive marker
release for merged+clean sandboxes (ignores TTL, closes the crashed-session
immortal-orphan gap) → clean merged worktrees → sweep orphan branches →
sweep residual dirs.

**Exit:** always `0`. Prints a multi-line report on stdout if any action was
taken; silent otherwise.

### `sandbox-merge-gate`

Pre-merge validation. Call from `pre-merge-commit` git hook or session-stop
wrapper.

```
sandbox-merge-gate.sh --worktree <dir> [--strict-tasks]
```

Blocks merge if: `TASK.md` has unchecked boxes, OR filesystem has tracked
modifications / untracked files, OR (with `--strict-tasks`) `TASK.md` is
missing.

**Exit:** `0` ok to merge / `1` blocked (reason on stdout) / `2` bad usage.

## Adapter responsibilities (Claude Code)

The Claude Code adapter wires four hooks. Stop vs SessionEnd split is
load-bearing — don't collapse them:

| Hook           | Script              | Role                                                                 |
|----------------|---------------------|----------------------------------------------------------------------|
| `SessionStart` | `session-start.sh`  | Run lifecycle, create (or re-banner on compact) the session sandbox. |
| `PreToolUse`   | `pre-edit.sh`       | Enforce that Edit/Write lands inside the session's sandbox worktree. |
| `Stop`         | `stop.sh`           | **Per-turn read-only gate + marker heartbeat.** Never merges, never cleans. Emits `{"decision":"block",...}` if the worktree is unmergeable so the agent gets a chance to fix it on the next turn. |
| `SessionEnd`   | `session-end.sh`    | **Durability + housekeeping.** On real terminations (`prompt_input_exit`, `logout`, `other`, ...): (1) capture-commit any pending tracked mods + untracked files in the current sandbox (excluding `TASK.md`) so nothing is lost when the process exits, and (2) invoke `sandbox-lifecycle` to reap *other* sandboxes whose branches are already ancestors of `main` and whose worktrees are clean. Does **not** merge the current session's branch. On `clear` / `compact` reasons it only heartbeats the marker. Cannot block exit, so failures are logged and the sandbox is left alive for the TTL safety-net. |

**Why the split:** Claude Code's `Stop` hook fires after every agent turn,
not at session end. Any merge or cleanup in `Stop` would destroy a live
sandbox mid-conversation the first time `TASK.md` is fully checked.

**Why SessionEnd does not merge:** auto-merging on exit is too aggressive —
the user may want to review the diff, rebase, or discard. SessionEnd's only
active job is durability: capture uncommitted work into the branch so
nothing is lost if the process dies. Merging into `main` is always a
deliberate user action (`git merge <branch>` or the `pre-merge-commit`
hook). Once the user has merged, the NEXT `SessionEnd` (of any session)
will reap the resulting ancestor-clean branch + worktree via lifecycle.

**Squash / rebase caveat:** lifecycle's "merged" check uses
`git merge-base --is-ancestor`. Branches squash-merged or rebase-merged
are not ancestors of `main` and will not be auto-reaped — the user must
delete such branches manually or rely on the orphan-branch sweep if the
branch name matches the sandbox prefix and the original commits are in
`main`.

## Library functions

Source files under `core/lib/` are not part of the public contract. They are
documented in their own header comments for internal reference.
