#!/bin/bash
# fixture.sh — temp git repo builders for tests.

fixture_init() {
  FIXTURE_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'sandbox-test')
  export FIXTURE_ROOT
  unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true
  unset OPENCODE_SANDBOX_ACTIVE OPENCODE_SANDBOX_SOURCE OPENCODE_SANDBOX_SESSION 2>/dev/null || true
  unset OPENCODE_SANDBOX_REPO OPENCODE_SANDBOX_ROOT OPENCODE_SANDBOX_WORKTREE 2>/dev/null || true
  unset OPENCODE_SANDBOX_WORKTREES_DIR OPENCODE_SANDBOX_BRANCH_PREFIX 2>/dev/null || true
  unset WORKTREE_SANDBOX_WORKTREES_DIR WORKTREE_SANDBOX_BRANCH_PREFIX 2>/dev/null || true
}

fixture_cleanup() {
  [ -n "${FIXTURE_ROOT:-}" ] && rm -rf "$FIXTURE_ROOT"
}

fixture_repo() {
  local name="$1"
  local dir="$FIXTURE_ROOT/$name"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email "test@worktree-sandbox.local"
    git config user.name "Test"
    echo "# $name" > README.md
    git add README.md
    git commit -q -m "chore: seed repo"
  )
  printf '%s' "$dir"
}

fixture_worktree() {
  local repo="$1" branch="$2" file="$3" content="$4"
  local wt="$repo.wt-$branch"
  (
    cd "$repo" || exit 1
    git worktree add -q "$wt" -b "$branch" 2>/dev/null
  )
  (
    cd "$wt" || exit 1
    printf '%s' "$content" > "$file"
    git add "$file"
    git commit -q -m "feat: add $file"
  )
  printf '%s' "$wt"
}
