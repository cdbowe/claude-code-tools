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
MAIN_DIR="${WORKTREE_MAIN_DIR:-${WORKSPACE_DIR}/main}"

# Validate the split bare-repo layout up front. Without this the script created
# worktrees/ and then died on a raw `cd` error partway through, leaving debris
# and no indication of what was actually wrong. Run prd-doctor.sh to diagnose.
if [ ! -d "$MAIN_DIR" ]; then
    echo "{\"status\":\"error\",\"message\":\"Main checkout not found at $MAIN_DIR. /prd build needs the split layout: primary checkout at \$WORKSPACE_DIR/main with worktrees under \$WORKSPACE_DIR/worktrees. Move the checkout there, or set WORKTREE_MAIN_DIR.\"}" >&2
    exit 1
fi
if ! git -C "$MAIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "{\"status\":\"error\",\"message\":\"$MAIN_DIR is not a git repository. /prd build is worktree-based and cannot run without one.\"}" >&2
    exit 1
fi
if ! git -C "$MAIN_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "{\"status\":\"error\",\"message\":\"$MAIN_DIR has no commits. git worktree add needs a base commit — make an initial commit first.\"}" >&2
    exit 1
fi

# Ensure worktree root directory exists
mkdir -p "$WORKTREE_ROOT"

WORKTREE_PATH="${WORKTREE_ROOT}/${WORKTREE_NAME}"

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
    echo "{\"status\":\"error\",\"message\":\"Worktree $WORKTREE_NAME already exists at $WORKTREE_PATH\"}" >&2
    exit 1
fi

# Check if branch already exists
cd "$MAIN_DIR"
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
