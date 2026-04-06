# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`singularity-sandbox` is a tool-agnostic bash layer that enforces git-worktree isolation and TTL-based cleanup for AI-assisted (and human) sessions. Zero runtime dependencies beyond `bash` and `git`. Target environments: Linux, macOS, Git Bash / WSL on Windows. All code must stay lint-clean under `shellcheck` (config in `.shellcheckrc`).

The parent repo `D:\singularity\CLAUDE.md` applies on top of this file — guard conventions, worktree discipline, and commit discipline in that file override defaults.

## Commands

```bash
bash tests/run.sh               # run all tests (unit + e2e)
bash tests/run.sh unit          # unit only
bash tests/run.sh e2e           # e2e only
bash tests/run.sh tests/e2e/t01-happy-path.sh   # single file (path as arg)

bash install.sh --target <repo>                     # install core + pre-merge-commit hook
bash install.sh --target <repo> --with-claude-code  # also install CC adapter hooks
```

The test runner sets `SINGULARITY_SANDBOX_ROOT` to the project root and executes each `*.sh` file under `tests/unit` and `tests/e2e` as its own bash script. A test file is "pass" iff it exits `0`. There is no per-assertion selector — to run a single case, run the whole file.

All tests create real temporary git repos via `mktemp -d` + `git init`. There are no mocks, no fixtures checked in. `tests/lib/assert.sh` and `tests/lib/fixture.sh` are the only shared helpers.

## Architecture

### Two-layer split: `core/` is the contract, `adapters/` are translators

- **`core/cmd/*.sh`** — stable public CLI. Four scripts: `sandbox-init`, `sandbox-guard`, `sandbox-lifecycle`, `sandbox-merge-gate`. Inputs are CLI flags + env vars only (never JSON on stdin). Outputs are human-readable text. Exit codes follow a fixed convention: `0` = allow/success, `1` = deny/blocked with reason on stdout, `2` = bad usage. Full spec lives in `CONTRACT.md` and must be kept in sync when flags change.
- **`core/lib/*.sh`** — internal helpers, sourced by `core/cmd/` scripts. Not part of the public contract; callers outside `core/` must not source these directly. Header comments in each file are the reference. Current libs: `git-context.sh`, `scan-uncommitted.sh`, `ttl-marker.sh`, `wt-cleanup.sh`.
- **`adapters/<host>/`** — thin translation layers (~30-50 lines per hook) that read a host tool's native input format (Claude Code JSON on stdin, git hook args, etc.), extract what they need, call `core/cmd/*` with flags, and translate the exit code + stdout back into the host's decision format. Adding a new host means writing a new adapter dir, never modifying `core/`.

### Fail-open safety-net policy

`core/cmd/` scripts exit `0` silently when git context cannot be resolved (not a repo, detached HEAD, etc.). These are safety nets, not gatekeepers — a broken install must never block a user's workflow. Preserve this when editing: any new failure path should default to allow unless it is detecting a concrete violation.

### State lives in two places, both TTL-managed

1. **Markers** at `<git-common-dir>/sandbox-markers/<session-id>`. One small file per active session; first field = branch name, second field = creation epoch. `ttl-marker.sh` is the only module that reads/writes these. Any marker format change ripples through `sandbox-lifecycle` (stale reclaim) and `sandbox-guard` (active-session lookup).
2. **Worktrees** at `<repo-root>/.sandbox/worktrees/<branch-name>`. Created by `sandbox-init`, cleaned by `sandbox-lifecycle` via `wt-cleanup.sh`. `scan-uncommitted.sh` is the safety check that prevents cleanup of dirty trees.

Every file-based marker must carry an expiry — crashed sessions leave immortal orphans otherwise (see parent `CLAUDE.md` guard-implementation principles).

### Lifecycle phases run in a fixed order

`sandbox-lifecycle.sh` executes: prune git metadata → reclaim stale markers (TTL-expired) → clean merged worktrees → sweep orphan branches → sweep residual dirs. Order matters: earlier phases feed later ones (a reclaimed marker's branch becomes an orphan-sweep candidate). When adding a phase, place it carefully and update the `CONTRACT.md` listing.

### Merge gate is the enforcement point

`sandbox-merge-gate.sh` is invoked by the installed `pre-merge-commit` hook (and, in the Claude Code adapter, by the `stop` hook). It blocks merge iff the worktree has tracked modifications / untracked files. This is the single point where worktree cleanliness becomes a hard requirement — changes here affect every downstream host.

## Conventions specific to this repo

- Shebang is `#!/bin/bash` everywhere, never `#!/bin/sh` — `/bin/sh` is unresolvable on Windows Git Bash.
- `set -u` is used in `core/cmd/` scripts but `set -e` is avoided in spots where non-zero exits from `grep`/`git` are expected control flow; read the existing file before adding `set -euo pipefail` wholesale.
- When changing a `core/cmd/` flag or exit code, update `CONTRACT.md` in the same commit.
- Windows/MSYS quirks (documented in parent `CLAUDE.md`): no `timeout` in sequential benchmarks, `[[:space:]]` instead of `\s` in grep/sed, `grep PATTERN || true` + `${var:-0}` instead of `grep -c ... || echo 0`. `t08-custom-layout-flags.sh` already skips a full-path equality check on MSYS — mirror that pattern for other path-sensitive tests.
