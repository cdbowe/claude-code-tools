#!/bin/bash

# worktree-merge.sh - Merge worktrees back to main branch
# Usage (new-style): worktree-merge.sh [--retry] <manifest-file> <wave-id> <result-prefix>
# Usage (old-style): worktree-merge.sh <wave-id>  [backward compatible]
# Returns JSON with merge results
#
# --retry flag: Used after conflict resolution. Skips already-merged branches,
#               preserves worktrees until successful merge.

set -euo pipefail

# WORKSPACE_DIR must be set by devcontainer, do not default
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo "{\"status\":\"error\",\"message\":\"WORKSPACE_DIR environment variable not set\"}" >&2
    exit 1
fi

MAIN_DIR="${WORKTREE_MAIN_DIR:-$WORKSPACE_DIR/main}"
WORKTREE_ROOT="${WORKSPACE_DIR}/worktrees"

# Check for --retry flag
RETRY_MODE=false
if [ "${1:-}" = "--retry" ]; then
    RETRY_MODE=true
    shift
fi

# Parse arguments - support both old and new style
if [ $# -eq 3 ]; then
    # New style: manifest file, wave ID, result prefix
    MANIFEST_FILE="$1"
    WAVE_ID="$2"
    RESULT_PREFIX="$3"
elif [ $# -eq 1 ]; then
    # Old style: just wave ID (backward compatible)
    WAVE_ID="$1"
    MANIFEST_FILE="/tmp/.prd_build.json"
    RESULT_PREFIX="prd_agent"
elif [ $# -eq 2 ] && [ "$1" -eq "$1" ] 2>/dev/null; then
    # Old style with explicit prefix
    WAVE_ID="$1"
    RESULT_PREFIX="${2:-prd_agent}"
    MANIFEST_FILE="/tmp/.prd_build.json"
else
    echo "{\"status\":\"error\",\"message\":\"Usage: worktree-merge.sh [--retry] <manifest> <wave> <prefix> OR <wave>\"}" >&2
    exit 1
fi

# Check if manifest exists for new-style calls
if [ $# -eq 3 ] && [ ! -f "$MANIFEST_FILE" ]; then
    echo "{\"status\":\"error\",\"message\":\"Manifest file not found: $MANIFEST_FILE\"}" >&2
    exit 1
fi

cd "$MAIN_DIR"

MERGED=0
SKIPPED=0
FAILED=0
ERRORS=()
SKIPPED_REASONS=()  # Track reasons for skipping agents/branches
FAILED_BRANCHES=()  # Track failed branches for conflict resolution

# Get wave data from manifest if available
if [ -f "$MANIFEST_FILE" ]; then
    agents=$(jq -r ".waves[$WAVE_ID].agents[]? | @base64" "$MANIFEST_FILE" 2>/dev/null || echo "")
else
    agents=""
fi

# If no agents from manifest, try to find result files
if [ -z "$agents" ]; then
    # Backward compatible: look for result files
    for result_file in /tmp/.${RESULT_PREFIX}_*_results.json; do
        if [ -f "$result_file" ]; then
            agent_id=$(jq -r '.agentId // empty' "$result_file" 2>/dev/null || echo "")
            branch_name=$(jq -r '.branch // empty' "$result_file" 2>/dev/null || echo "")

            if [ -n "$agent_id" ]; then
                if [ -z "$agents" ]; then
                    agents="$agent_id"
                else
                    agents="$agents
$agent_id"
                fi
            fi
        fi
    done
fi

# Process each agent in the wave
while IFS= read -r agent_b64 || [ -n "$agent_b64" ]; do
    [ -z "$agent_b64" ] && continue

    agent=$(echo "$agent_b64" | base64 -d 2>/dev/null || echo "")
    [ -z "$agent" ] && continue

    agent_id=$(echo "$agent" | jq -r '.agentId' 2>/dev/null || echo "")
    branch=$(echo "$agent" | jq -r '.branch' 2>/dev/null || echo "")
    worktree=$(echo "$agent" | jq -r '.worktree' 2>/dev/null || echo "")

    [ -z "$agent_id" ] && continue

    # Check result file for status
    result_file="/tmp/.${RESULT_PREFIX}_${agent_id}_results.json"

    if [ -f "$result_file" ]; then
        status=$(jq -r '.status // "unknown"' "$result_file" 2>/dev/null || echo "unknown")

        if [ "$status" = "blocked" ]; then
            echo "Skipping blocked agent: $agent_id"
            ((SKIPPED++)) || true
            SKIPPED_REASONS+=("agent=$agent_id branch=$branch worktree=$worktree reason=agent_blocked")
            continue
        fi

        if [ "$status" != "complete" ] && [ "$status" != "success" ]; then
            echo "Agent $agent_id did not complete successfully (status: $status)"
            ((FAILED++)) || true
            ERRORS+=("Agent $agent_id: $status")
            continue
        fi
    else
        # If no result file but continue anyway for local testing
        if [ "$#" -eq 1 ] || [ "$#" -eq 2 ]; then
            # Only strict in new-style calls
            echo "Warning: No result file for agent $agent_id"
        fi
    fi

    # Track if this agent's merge succeeded (for cleanup decision)
    merge_succeeded=false

    # Merge the branch if we have it
    if [ -n "$branch" ]; then
        if git rev-parse --verify "$branch" >/dev/null 2>&1; then
            # Check if branch is already merged into HEAD (main)
            if git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
                # Branch already merged - skip silently in retry mode, log otherwise
                if [ "$RETRY_MODE" = true ]; then
                    ((SKIPPED++)) || true
                    SKIPPED_REASONS+=("agent=$agent_id branch=$branch worktree=$worktree reason=already_merged_into_main_retry_mode")
                else
                    echo "Skipping $branch (already merged into main)"
                    ((SKIPPED++)) || true
                    SKIPPED_REASONS+=("agent=$agent_id branch=$branch worktree=$worktree reason=already_merged_into_main")
                fi
                merge_succeeded=true  # Consider already-merged as success for cleanup
            else
                # Check if branch has commits ahead of HEAD (main)
                commits_ahead=$(git rev-list --count HEAD.."$branch" 2>/dev/null || echo "0")
                if [ "$commits_ahead" -eq 0 ]; then
                    echo "Skipping $branch (no commits ahead of main)"
                    ((SKIPPED++)) || true
                    SKIPPED_REASONS+=("agent=$agent_id branch=$branch worktree=$worktree reason=no_commits_ahead_of_main")
                    merge_succeeded=true
                elif git merge --no-ff -m "Merge $agent_id from wave $WAVE_ID

🤖 Generated with [Claude Code](https://claude.com/claude-code)" "$branch"; then
                    ((MERGED++)) || true
                    echo "Merged branch: $branch"
                    merge_succeeded=true
                else
                    ((FAILED++)) || true
                    ERRORS+=("Failed to merge branch: $branch")
                    FAILED_BRANCHES+=("{\"branch\":\"$branch\",\"worktree\":\"$worktree\",\"agentId\":\"$agent_id\"}")
                fi
            fi
        else
            # Branch not found
            if [ "$RETRY_MODE" = true ]; then
                # In retry mode, silently skip missing branches (may have been cleaned up)
                ((SKIPPED++)) || true
                SKIPPED_REASONS+=(\"agent=$agent_id branch=$branch worktree=$worktree reason=branch_not_found_in_retry_mode\")
                merge_succeeded=true  # Don't try to clean up non-existent branch
            else
                echo "Branch not found: $branch"
                ((FAILED++)) || true
            fi
        fi
    fi

    # Clean up worktree if specified
    # Only clean up after successful merge (preserve failed worktrees for conflict resolution)
    if [ -n "$worktree" ] && [ -d "$WORKTREE_ROOT/$worktree" ]; then
        if [ "$merge_succeeded" = true ]; then
            bash "${WORKSPACE_DIR}/.claude/commands/scripts/worktree-cleanup.sh" "$worktree" 2>&1 || true
        fi
        # Failed worktrees are preserved for conflict-resolver agent
    fi
done <<< "$agents"

# Output results
# Build skippedReasons JSON (handle empty array)
SKIPPED_REASONS_JSON=""
if [ ${#SKIPPED_REASONS[@]} -gt 0 ]; then
    SKIPPED_REASONS_JSON=$(printf '"%s",' "${SKIPPED_REASONS[@]}" | sed 's/,$//')
fi

if [ ${#FAILED_BRANCHES[@]} -gt 0 ]; then
    # Create conflict details file for conflict-resolver agent
    CONFLICT_FILE="/tmp/.prd_conflict_${WAVE_ID}.json"
    cat > "$CONFLICT_FILE" << EOF
{
  "waveId": $WAVE_ID,
  "mainDir": "$MAIN_DIR",
  "worktreeRoot": "$WORKTREE_ROOT",
  "failedBranches": [$(printf '%s,' "${FAILED_BRANCHES[@]}" | sed 's/,$//')]
}
EOF
    echo "{\"status\":\"needs_resolution\",\"merged\":$MERGED,\"skipped\":$SKIPPED,\"failed\":$FAILED,\"conflictFile\":\"$CONFLICT_FILE\",\"errors\":[$(printf '"%s",' "${ERRORS[@]}" | sed 's/,$//')],\"failedBranches\":[$(printf '%s,' "${FAILED_BRANCHES[@]}" | sed 's/,$///')],\"skippedReasons\":[$SKIPPED_REASONS_JSON]}"
elif [ ${#ERRORS[@]} -gt 0 ]; then
    # Errors but no failed branches (e.g., agent didn't complete)
    echo "{\"status\":\"error\",\"merged\":$MERGED,\"skipped\":$SKIPPED,\"failed\":$FAILED,\"errors\":[$(printf '"%s",' "${ERRORS[@]}" | sed 's/,$///')],\"skippedReasons\":[$SKIPPED_REASONS_JSON]}"
else
    echo "{\"status\":\"complete\",\"merged\":$MERGED,\"skipped\":$SKIPPED,\"failed\":$FAILED,\"skippedReasons\":[$SKIPPED_REASONS_JSON]}"
fi
