#!/usr/bin/env bash
# Commit uncommitted changes in main worktree
# Usage: commit-main.sh "commit message"

set -euo pipefail

show_usage() {
    cat <<'EOF'
Usage: commit-main.sh "commit message"

Commits all uncommitted changes in main worktree.
Script location: $WORKSPACE_DIR/.claude/commands/scripts/commit-main.sh

Examples:
  cd "$WORKSPACE_DIR/.claude/commands/scripts/"
  commit-main.sh "PRD my_prd phase 5: pre-build commit"
  commit-main.sh "Pre-worktree execution commit"

Note: Wrap commit message in double quotes.
EOF
}

# Handle --help flag
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

# Validate argument count and set commit message
if [[ $# -eq 0 ]]; then
    COMMIT_MSG="Checkpoint commit ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "No commit message provided. Using default: '$COMMIT_MSG'"
elif [[ $# -gt 1 ]]; then
    echo "Error: Exactly 1 argument required. Wrap commit message in double quotes." >&2
    show_usage >&2
    exit 1
else
    COMMIT_MSG="$1"
fi

# Determine main worktree directory
MAIN_DIR="${WORKTREE_MAIN_DIR:-${WORKSPACE_DIR:-}/main}"

if [[ -z "$MAIN_DIR" || ! -d "$MAIN_DIR" ]]; then
    echo "Error: Main worktree directory not found: $MAIN_DIR" >&2
    exit 1
fi

cd "$MAIN_DIR"

# Check for main worktree index.lock file, and remove it if found
if [ -f "$WORKSPACE_DIR/.git/worktrees/main/index.lock" ]; then
    echo "Lock file detected. Removing..."
    rm -f "$WORKSPACE_DIR/.git/worktrees/main/index.lock"
    echo "Deleted lock file"
fi

echo "Checking for commits from '$MAIN_DIR'..."
# Check for uncommitted changes or untracked files
if git status --porcelain | grep -q .; then
    git add .
    if git commit -m "$COMMIT_MSG"; then
        echo "Committed changes to main: $COMMIT_MSG"
    else
        echo "Error: Commit failed" >&2
        exit 1
    fi
else
    echo "No changes to commit in main"
fi

# Keep synthetic origin/main ref in sync (no real remote in this container)
git update-ref refs/remotes/origin/main refs/heads/main