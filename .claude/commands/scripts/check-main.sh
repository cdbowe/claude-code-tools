#!/usr/bin/env bash
# Check if main worktree has uncommitted changes
# Used by PreToolUse hook to block operations until main is clean
#
# Exit codes:
#   0 - Main is clean, operation can proceed
#   2 - Main is dirty, operation blocked (stderr contains instructions)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_DIR="${WORKTREE_MAIN_DIR:-${WORKSPACE_DIR:-}/main}"

# Validate main directory exists
if [[ -z "$MAIN_DIR" || ! -d "$MAIN_DIR" ]]; then
    echo "Warning: Main worktree directory not found: $MAIN_DIR" >&2
    exit 0  # Allow operation if we can't verify
fi

cd "$MAIN_DIR"

# Check for uncommitted changes or untracked files
if git status --porcelain | grep -q .; then
    cat >&2 <<EOF
Run commit-main.sh before proceeding:

EOF
    # Show usage from commit-main.sh
    "$SCRIPT_DIR/commit-main.sh" --help >&2
    exit 2  # Block the operation
fi

# Main is clean
exit 0
