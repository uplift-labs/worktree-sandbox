#!/bin/bash
# remote-install.sh — fetch worktree-sandbox and install into the current repo.
#
# Usage:
#   bash <(curl -sSL https://raw.githubusercontent.com/uplift-labs/worktree-sandbox/main/remote-install.sh) [--prefix <dir>] [--with-claude-code] [--with-codex]
#
# Clones the repo into a temp directory, runs install.sh with forwarded args,
# and removes the temp directory. Requires git and curl/bash.
# Default --prefix is .uplift (installs to <target>/.uplift/sandbox).

set -u

REPO_URL="https://github.com/uplift-labs/worktree-sandbox.git"

tmpdir=$(mktemp -d) || { printf 'remote-install: failed to create temp dir\n' >&2; exit 1; }
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

printf '[remote-install] cloning worktree-sandbox...\n'
if ! git clone --depth 1 --quiet "$REPO_URL" "$tmpdir/worktree-sandbox" 2>&1; then
  printf '[remote-install] git clone failed\n' >&2
  exit 1
fi

printf '[remote-install] running install.sh...\n'
bash "$tmpdir/worktree-sandbox/install.sh" "$@"
