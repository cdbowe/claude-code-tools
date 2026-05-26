#!/bin/bash
# PRD Worktree Merge Script - Merges completed worktree branches back to main
# Usage: prd-worktree-merge.sh <wave_id>
# Reads agent results from /tmp/.prd_agent_results.json

set -e

WAVE_ID="$1"

# Validate WORKSPACE_DIR is set and valid
if [ -z "$WORKSPACE_DIR" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi
if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "{\"status\":\"error\",\"error\":\"WORKSPACE_DIR does not exist: $WORKSPACE_DIR\"}"
    exit 1
fi

WORKSPACE_ROOT="$WORKSPACE_DIR"
MAIN_DIR="${WORKTREE_MAIN_DIR:-$WORKSPACE_DIR/main}"
WORKTREES_DIR="$WORKSPACE_ROOT/worktrees"
RESULTS_FILE="/tmp/.prd_wave_${WAVE_ID}_merge.json"

if [ -z "$WAVE_ID" ]; then
    echo '{"status":"error","error":"Wave ID required"}'
    exit 1
fi

# Read agent results for this wave
BUILD_FILE="/tmp/.prd_build.json"
if [ ! -f "$BUILD_FILE" ]; then
    echo '{"status":"error","error":"Build file not found"}'
    exit 1
fi

# Get agents for this wave that used worktrees
agents=$(jq -c --argjson waveId "$WAVE_ID" '.waves[] | select(.waveId == $waveId) | .agents[] | select(.useWorktrees == true)' "$BUILD_FILE")

if [ -z "$agents" ]; then
    echo "{\"status\":\"complete\",\"waveId\":$WAVE_ID,\"merged\":0,\"message\":\"No worktrees to merge\"}"
    exit 0
fi

# Track merge results
merged=0
failed=0
conflicts=()
cleanup_list=()

cd "$MAIN_DIR"

# Process each agent's worktree
# NOTE: Use here-string (<<<) instead of pipe to avoid subshell - preserves variable modifications
while IFS= read -r agent; do
    [ -z "$agent" ] && continue

    agent_id=$(echo "$agent" | jq -r '.agentId')
    worktree=$(echo "$agent" | jq -r '.worktree')
    branch=$(echo "$agent" | jq -r '.branch')
    worktree_path="$WORKTREES_DIR/$worktree"

    # Check if agent completed successfully
    result_file="/tmp/.prd_agent_${agent_id}_results.json"
    if [ -f "$result_file" ]; then
        status=$(jq -r '.status' "$result_file")
        if [ "$status" = "blocked" ]; then
            echo "Skipping blocked agent: $agent_id" >&2
            continue
        fi
    fi

    # Check if worktree exists
    if [ ! -d "$worktree_path" ]; then
        echo "Warning: Worktree not found: $worktree_path" >&2
        continue
    fi

    # Check if branch has commits
    if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
        echo "Warning: Branch not found: $branch" >&2
        continue
    fi

    # Attempt merge
    echo "Merging branch: $branch" >&2
    if git merge --no-ff "$branch" -m "Merge $agent_id from wave $WAVE_ID

🤖 PRD Build Auto-Merge"; then
        ((merged++)) || true
        echo "Merge successful: $agent_id ($branch)" >&2
        cleanup_list+=("$worktree:$branch")
    else
        # Merge conflict
        git merge --abort 2>/dev/null || true
        echo "ERROR: Merge conflict for agent $agent_id on branch $branch" >&2
        ((failed++)) || true
        conflicts+=("$agent_id:$branch")
    fi
done <<< "$agents"

# Cleanup successful merges
for item in "${cleanup_list[@]}"; do
    worktree="${item%%:*}"
    branch="${item##*:}"
    worktree_path="$WORKTREES_DIR/$worktree"

    # Remove worktree
    if [ -d "$worktree_path" ]; then
        echo "Removing worktree: $worktree_path" >&2
        git worktree remove "$worktree_path" --force 2>/dev/null || true
        echo "Remove success: $worktree_path" >&2
    fi

    # Delete branch
    echo "Deleting branch: $branch" >&2
    git branch -d "$branch" 2>/dev/null || true
    echo "Delete success: $branch" >&2
done

# Write results
if [ $failed -gt 0 ]; then
    conflict_json=$(printf '%s\n' "${conflicts[@]}" | jq -R -s 'split("\n") | map(select(. != ""))')
    jq -n \
        --arg status "partial" \
        --argjson waveId "$WAVE_ID" \
        --argjson merged "$merged" \
        --argjson failed "$failed" \
        --argjson conflicts "$conflict_json" \
        '{status: $status, waveId: $waveId, merged: $merged, failed: $failed, conflicts: $conflicts}' > "$RESULTS_FILE"
    cat "$RESULTS_FILE"
    exit 1
else
    jq -n \
        --arg status "complete" \
        --argjson waveId "$WAVE_ID" \
        --argjson merged "$merged" \
        '{status: $status, waveId: $waveId, merged: $merged}' > "$RESULTS_FILE"
    cat "$RESULTS_FILE"
fi
