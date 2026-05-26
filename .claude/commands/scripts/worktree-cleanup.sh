#!/bin/bash

# worktree-cleanup.sh - Remove git worktrees and their branches
# Usage: worktree-cleanup.sh <worktree-pattern>
# Returns JSON with cleaned count and failed count

set -euo pipefail

PATTERN="${1:?Worktree pattern required (e.g., wt-test or wt-*)}"

# WORKSPACE_DIR must be set by devcontainer, do not default
if [ -z "${WORKSPACE_DIR}" ]; then
    echo "{\"cleaned\":0,\"failed\":0,\"error\":\"WORKSPACE_DIR environment variable not set\"}" 2>&1
    exit 1
fi

WORKTREE_ROOT="${WORKSPACE_DIR}/worktrees"
MAIN_DIR="${WORKTREE_MAIN_DIR:-$WORKSPACE_DIR/main}"

CLEANED=0
FAILED=0

# Find matching worktrees
if [ ! -d "$WORKTREE_ROOT" ]; then
    echo "{\"cleaned\":$CLEANED,\"failed\":$FAILED,\"error\":\"WORKTREE_ROOT $WORKTREE_ROOT not found\"}" 2>&1
    exit 1
fi

cd "$MAIN_DIR"

# Use find to locate matching worktree directories
worktree_paths=$(find "$WORKTREE_ROOT" -maxdepth 1 -type d -name "$PATTERN" 2>/dev/null)
for worktree_path in $worktree_paths; do
    # echo "Getting worktree path..."
    worktree_name=$(basename "$worktree_path")
    # echo "Got path $worktree_path"

    # Get the branch name from git worktree list
    # Format: worktree /path\nHEAD abc123\nbranch refs/heads/name\n
    # echo "Getting worktree branch..."

    FOUND_WT="false"
    FOUND_BRANCH="false"
    IS_FAILED="false"

    # Get branch name BEFORE removing the worktree (won't be in git worktree list after removal)
    branch_name=$(git worktree list --porcelain | grep -A2 "^worktree $worktree_path\$" | grep "^branch " | sed 's|^branch refs/heads/||' || echo "")
    if [ -n "$branch_name" ]; then
        FOUND_BRANCH="true"
    fi

    # Search for the worktree and remove it
    if git worktree list | grep -q "$worktree_path"; then
        FOUND_WT="true"
    fi

    if [ "$FOUND_WT" = "true" ]; then
        # Remove the worktree
        echo "Removing worktree '$worktree_path'..."
        if git worktree remove --force "$worktree_path"; then
            echo "Removing worktree success"
        else
            echo "Removing worktree failed"
            IS_FAILED="true"
        fi
    else
        echo "No worktree found for '$worktree_path'."
    fi

    # Delete the branch (regardless of whether worktree was found)
    if [ "$FOUND_BRANCH" = "true" ]; then
        echo "Deleting branch $branch_name..."
        if git branch -D "$branch_name" 2>/dev/null; then
            echo "Deleting branch success"
        else
            echo "Deleting branch failed (may not exist or is current)"
            IS_FAILED="true"
        fi
    else
        echo "No branch found for '$worktree_path'"
    fi

    # Finally, delete the worktree folder
    echo "Deleting worktree folder '$worktree_path'..."
    rm -rf "$worktree_path/"
    echo "Deleted: '$worktree_path'"

    if [ "$IS_FAILED" = "false" ]; then
        ((CLEANED++)) || true
    fi

    if [ "$IS_FAILED" = "true" ]; then
        ((FAILED++)) || true
    fi
done

echo "{\"cleaned\":$CLEANED,\"failed\":$FAILED}"
