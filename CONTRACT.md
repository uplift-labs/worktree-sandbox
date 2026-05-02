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
- **Heartbeat sidecar:** `<marker-path>.hb`. Format:
  `<heartbeat_pid> <parent_winpid|0> <monitored_pid|0>`. Field 1 is the
  heartbeat process PID (used by session-end.sh to kill on clean shutdown).
  Field 2 is the Windows PID of the parent Claude Code process (resolved
  via wmic at launch); `0` on Linux/macOS or when wmic resolution failed on
  MSYS. Field 3 is the Unix PID being monitored via `kill -0` (the `--pid`
  argument, typically `$PPID`); `0` in marker-only mode. The heartbeat
  touches the marker every 1s while the owning process is alive; when the
  PID dies, the heartbeat invokes `sandbox-cleanup.sh` for immediate
  session cleanup (capture-commit + self-release + lifecycle), then exits.
  If `--repo` / `--sandbox-root` were not provided to the heartbeat, it
  falls back to legacy behavior: mtime freezes and lifecycle's TTL reclaim
  picks it up on the next SessionStart. Lifecycle
  Phases 2 and 3 verify the owning process independently: field 3 > 0 →
  `kill -0`; else field 2 > 0 → `tasklist` check; else both 0 (marker-only
  mode, no external monitoring) → orphan grace period (default 2h from
  marker creation), after which the heartbeat is killed as a presumed
  orphan. Legacy single-field `.hb` files (missing fields 2-3) are treated
  as unknown-parent and fall through to the orphan grace path.
- **Worktree location:** default `<repo-root>/.sandbox/worktrees/<branch-name>`.
  Installed adapters pass their installed layout explicitly, e.g.
  `<repo-root>/.uplift/sandbox/worktrees/<branch-name>`.

## Commands

### `sandbox-init`

Create a session sandbox worktree.

```
sandbox-init.sh --repo <dir> --session <id> [--base <branch>] [--worktrees-dir <rel>] [--branch-prefix <prefix>]
```

| Flag        | Required | Description                                        |
|-------------|----------|----------------------------------------------------|
| `--repo`    | yes      | Absolute path to the main repo (must be on main/master) |
| `--session` | yes      | Unique session identifier (becomes part of branch name) |
| `--base`    | no       | Base branch to fork from (default: auto-detected)  |
| `--worktrees-dir` | no | Worktree directory relative to repo root (default `.sandbox/worktrees`) |
| `--branch-prefix` | no | Branch name prefix (default `wt`) |

**Output:** absolute sandbox path on stdout on success.
**Exit:** `0` success or no-op (already sandboxed / not on main) / `1` hard
failure (with message) / `2` bad usage.

### `sandbox-guard`

Path gate: decide whether an edit at `<file>` is allowed.

```
sandbox-guard.sh --session <id> --file <path> [--repo <dir>] [--worktrees-dir <rel>]
```

**Allow** when: no active sandbox / file inside sandbox / file outside repo.
**Deny** when: file is inside main repo but outside the session's sandbox.

| Flag              | Required | Default              | Description |
|-------------------|----------|----------------------|-------------|
| `--worktrees-dir` | no       | `.sandbox/worktrees` | Worktree directory relative to repo root |

**Exit:** `0` allow / `1` deny (reason on stdout) / `2` bad usage.

### `sandbox-lifecycle`

Periodic cleanup. Call from session start, session stop, or a cron job.

```
sandbox-lifecycle.sh --repo <dir> [--ttl <seconds>] [--branch-prefix <glob>] [--worktrees-dir <rel>]
```

| Flag              | Required | Default               | Description              |
|-------------------|----------|-----------------------|--------------------------|
| `--repo`          | yes      | —                     | Main repo path           |
| `--ttl`           | no       | `5`                   | Marker TTL in seconds (stale reclaim) |
| `--branch-prefix` | no       | `wt-*`                | Glob for orphan branch sweep |
| `--worktrees-dir` | no       | `.sandbox/worktrees`  | Worktree directory relative to repo root |

**Phases:** prune metadata → reclaim stale markers (TTL, with heartbeat
sidecar PID check and 30s grace period for freshly-created markers) →
proactive marker release for merged+clean sandboxes (with heartbeat
sidecar PID check; ignores TTL, closes the crashed-session immortal-orphan
gap) → clean merged worktrees → sweep orphan branches → sweep residual dirs.

**Timing constants** (hardcoded in `sandbox-lifecycle.sh`):

| Constant             | Value    | Purpose                                                                                  |
|----------------------|----------|------------------------------------------------------------------------------------------|
| `ORPHAN_HB_GRACE`   | `7200`s  | Grace period for heartbeats with unknown parent (winpid=0). After 2h from marker creation, lifecycle kills the heartbeat as a presumed orphan. |
| `FRESH_SESSION_TTL`  | `300`s   | Extended TTL for sessions that never committed (HEAD == init_head). Protects live sessions whose heartbeat died early. |

**Timing constants** (hardcoded in `heartbeat.sh`):

| Constant             | Value    | Purpose                                                                                  |
|----------------------|----------|------------------------------------------------------------------------------------------|
| `MAX_AGE`            | `86400`s | Safety valve: heartbeat self-terminates after 24h to prevent immortal orphans in marker-only mode. |
| `WINPID_CHECK_EVERY` | `5`      | Check Windows parent PID every N ticks (wmic is ~200ms per call).                        |

**Exit:** always `0`. Prints a multi-line report on stdout if any action was
taken; silent otherwise.

### `sandbox-cleanup`

Session cleanup: capture-commit + self-release + lifecycle.

```
sandbox-cleanup.sh --repo <dir> --session <id> [--worktrees-dir <rel>] [--branch-prefix <glob>]
```

| Flag              | Required | Default              | Description |
|-------------------|----------|----------------------|-------------|
| `--repo`          | yes      | —                    | Main repo path |
| `--session`       | yes      | —                    | Session identifier (marker filename) |
| `--worktrees-dir` | no       | `.sandbox/worktrees` | Worktree directory relative to repo root |
| `--branch-prefix` | no       | `wt-*`               | Glob for orphan branch sweep |

**Phases:** capture-commit pending work (skipped if merge/rebase in progress
or HEAD is detached) → self-release marker if branch is merged into main AND
worktree is clean → invoke `sandbox-lifecycle` for full cleanup pass.

**Callers:** adapter session-end/launcher cleanup paths and `heartbeat.sh`
(parent-death cleanup when a host-specific end hook never fired).

**Exit:** always `0` (fail-open). Diagnostic output on stderr.

### `sandbox-merge-gate`

Pre-merge validation. Call from `pre-merge-commit` git hook or session-stop
wrapper.

```
sandbox-merge-gate.sh --worktree <dir>
```

Blocks merge if: filesystem has tracked modifications / untracked files.

**Exit:** `0` ok to merge / `1` blocked (reason on stdout) / `2` bad usage.

## Adapter responsibilities (Claude Code)

The Claude Code adapter wires four hooks. Stop vs SessionEnd split is
load-bearing — don't collapse them:

| Hook           | Script              | Role                                                                 |
|----------------|---------------------|----------------------------------------------------------------------|
| `SessionStart` | `session-start.sh`  | Run lifecycle, create (or re-banner on compact) the session sandbox, launch background heartbeat to keep marker fresh while Claude Code PID is alive. |
| `PreToolUse`   | `pre-edit.sh`       | Enforce that Edit/Write lands inside the session's sandbox worktree. |
| `Stop`         | `stop.sh`           | **Per-turn marker heartbeat.** Refreshes marker mtime so lifecycle treats the session as live. Never merges, never cleans, never blocks. |
| `SessionEnd`   | `session-end.sh`    | **Durability + housekeeping.** On real terminations (`prompt_input_exit`, `logout`, `other`, ...): (0) kill the heartbeat process for clean shutdown, then (1) delegate to `sandbox-cleanup.sh` which capture-commits pending work and runs lifecycle. Does **not** merge the current session's branch. On `clear` / `compact` reasons it only heartbeats the marker. Cannot block exit, so failures are logged and the sandbox is left alive for the TTL safety-net. |

**Why the split:** Claude Code's `Stop` hook fires after every agent turn,
not at session end. Any merge or cleanup in `Stop` would destroy a live
sandbox mid-conversation.

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

## Adapter responsibilities (Codex CLI)

Codex support has two modes:

| Mode | Role |
|------|------|
| `codex-sandbox.sh` launcher | Creates the sandbox before Codex starts, runs `codex -C <sandbox>`, exports `CODEX_SANDBOX_*` env vars for hooks, and calls `sandbox-cleanup.sh --trust-dead` when Codex exits. This is the recommended enforcement path. |
| Codex lifecycle hooks | Provide additional context on `SessionStart`, block supported write tools from running in main via `PreToolUse`, and refresh marker mtime via `Stop`. |

Codex currently does not expose a `SessionEnd` hook equivalent to Claude
Code. Cleanup therefore relies on the launcher exit path plus heartbeat/TTL
safety nets. Hook-only mode is useful as a fallback, but the launcher is the
stronger guarantee because it changes Codex's working root to the sandbox.

## Adapter responsibilities (OpenCode)

OpenCode support is plugin-first with an optional strict launcher:

| Component | Role |
|-----------|------|
| OpenCode plugin | Loads from `.opencode/plugins/`, creates a sandbox on `session.created` or the first session-aware hook, injects system context, propagates sandbox env vars via `shell.env`, maps supported built-in tool paths into the session sandbox, blocks explicit main-repo write targets, refreshes markers on idle/status events, and calls `sandbox-cleanup.sh --trust-dead` on `session.deleted` or process exit. This is the normal `opencode` enforcement path. |
| `opencode-sandbox.sh` launcher | Optional strict mode. Creates the sandbox before OpenCode starts, runs `opencode` from the sandbox worktree, exports `OPENCODE_SANDBOX_*` env vars for the plugin and shell tools, launches heartbeat, and calls `sandbox-cleanup.sh --trust-dead` when OpenCode exits. |
| `--with-opencode-os-sandbox` install option | Implies `--with-opencode` and adds the external `opencode-sandbox` npm plugin to root `opencode.json`. The launcher passes that source config to OpenCode when the plugin is present so it can load before the install files are committed into a fresh worktree. |

OpenCode does not expose a pre-bootstrap hook that mutates its already-created
instance `directory`/`worktree`. The plugin therefore virtualizes supported
built-in tool paths into the sandbox instead of moving the process cwd. Use the
launcher when the OpenCode process cwd itself must be the sandbox. In
plugin-first mode OpenCode UI surfaces that read the instance `directory` or VCS
state may continue to display the original repo/branch even while tool calls are
mapped into the sandbox.

The OS sandbox option is adapter configuration only. It wraps OpenCode `bash`
tool calls through `@anthropic-ai/sandbox-runtime` on supported platforms
(macOS Seatbelt / Linux bubblewrap) and passes through unsandboxed on Windows or
unsupported setups. It does not change `core/cmd/*` behavior or exit codes.

## Git hooks installed by `install.sh`

| Hook               | Purpose                                                        |
|--------------------|----------------------------------------------------------------|
| `pre-merge-commit` | Gates sandbox merges via `sandbox-merge-gate` — validates worktree cleanliness of the branch being merged. |
| `post-merge`       | Re-runs `install.sh` after every merge so installed sandbox scripts stay in sync with source. Runs in background; fail-open. Auto-detects installed Claude Code, Codex, and OpenCode adapters and preserves the matching flags. |

## Library functions

Source files under `core/lib/` are not part of the public contract. They are
documented in their own header comments for internal reference.
