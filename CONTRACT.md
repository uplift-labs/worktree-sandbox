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
  = creation epoch. Markers are auto-expired via TTL.
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

**Phases:** prune metadata → reclaim stale markers → clean merged worktrees →
sweep orphan branches → sweep residual dirs.

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

## Library functions

Source files under `core/lib/` are not part of the public contract. They are
documented in their own header comments for internal reference.
