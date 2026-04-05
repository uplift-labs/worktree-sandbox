# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial extraction from singularity monorepo.
- `core/lib/` — tool-agnostic bash primitives (git context, TASK.md parsing,
  uncommitted scanning, TTL markers, worktree cleanup).
- `core/cmd/` — high-level CLI commands (sandbox-init, sandbox-guard,
  sandbox-lifecycle, sandbox-merge-gate).
- `adapters/claude-code/` — Claude Code hook wrappers.
- E2E test suite covering happy path, TASK.md gate, uncommitted protection,
  TTL reclaim, parallel sessions, nested rejection, adapter smoke.
- GitHub Actions CI matrix (ubuntu, macOS).

[Unreleased]: https://github.com/sergey-akhalkov/singularity-sandbox/commits/main
