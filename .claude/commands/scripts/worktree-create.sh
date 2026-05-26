#!/bin/bash

# worktree-create.sh - Create a git worktree with branch
# Usage: worktree-create.sh <worktree-name> <branch-name> <base-branch>
# Returns JSON with status, worktreePath, and branch

set -euo pipefail

WORKTREE_NAME="${1:?Worktree name required}"
BRANCH_NAME="${2:?Branch name required}"
BASE_BRANCH="${3:-main}"

# WORKSPACE_DIR must be set by devcontainer, do not default
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo "{\"status\":\"error\",\"message\":\"WORKSPACE_DIR environment variable not set\"}" >&2
    exit 1
fi

WORKTREE_ROOT="${WORKSPACE_DIR}/worktrees"

# Ensure worktree root directory exists
mkdir -p "$WORKTREE_ROOT"

WORKTREE_PATH="${WORKTREE_ROOT}/${WORKTREE_NAME}"

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
    echo "{\"status\":\"error\",\"message\":\"Worktree $WORKTREE_NAME already exists at $WORKTREE_PATH\"}" >&2
    exit 1
fi

# Check if branch already exists
cd "$WORKSPACE_DIR/main"
if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    echo "{\"status\":\"error\",\"message\":\"Branch $BRANCH_NAME already exists\"}" >&2
    exit 1
fi

# Create the worktree with a new branch
if ! git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_BRANCH" 2>/dev/null; then
    echo "{\"status\":\"error\",\"message\":\"Failed to create worktree $WORKTREE_NAME\"}" >&2
    exit 1
fi

echo "{\"status\":\"success\",\"worktreePath\":\"$WORKTREE_PATH\",\"branch\":\"$BRANCH_NAME\"}"
