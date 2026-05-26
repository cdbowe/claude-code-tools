#!/bin/bash
# PRD Infrastructure Finalize Script - Updates infra checklist after build
# Usage: prd-infra-finalize.sh
# Discovers agent results from /tmp/.prd_agent_W*-T*_results.json (written by workers)
# This approach is robust across multiple waves - no dependency on orchestrator state

set -e

STATE_FILE="/tmp/.prd_state"
SUMMARY_FILE="/tmp/.prd_context_summary"
PRD_BASE="${WORKSPACE_DIR:-/workspaces/bankjet}/claude_files/PRDs"

#------------------------------------------------------------------------------
# Discover and build AGENT_STATUS from individual worker result files
# Pattern: /tmp/.prd_agent_W{wave}-T{task}_results.json
#------------------------------------------------------------------------------
shopt -s nullglob
agent_files=(/tmp/.prd_agent_W*-T*_results.json)
shopt -u nullglob

if [ ${#agent_files[@]} -eq 0 ]; then
    echo '{"status":"error","error":"No agent result files found. Workers must write /tmp/.prd_agent_W{wave}-T{task}_results.json"}'
    exit 1
fi

# Build AGENT_STATUS array from discovered files
AGENT_STATUS="[]"
for result_file in "${agent_files[@]}"; do
    if [ -f "$result_file" ] && jq -e '.agentId and .status' "$result_file" > /dev/null 2>&1; then
        agent_id=$(jq -r '.agentId' "$result_file")
        status=$(jq -r '.status' "$result_file")
        task_ids=$(jq '.taskIds // []' "$result_file")

        agent_entry=$(jq -n \
            --arg id "$agent_id" \
            --arg status "$status" \
            --argjson taskIds "$task_ids" \
            '{agentId: $id, status: $status, taskIds: $taskIds}')
        AGENT_STATUS=$(echo "$AGENT_STATUS" | jq --argjson entry "$agent_entry" '. + [$entry]')
    fi
done

if [ "$(echo "$AGENT_STATUS" | jq 'length')" -eq 0 ]; then
    echo '{"status":"error","error":"No valid agent results found in discovered files."}'
    exit 1
fi

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded."}'
    exit 1
fi
source "$STATE_FILE"

if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
    echo '{"status":"error","error":"No PRD loaded."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Find infrastructure JSON file (phase_0_*.json)
INFRA_FILE=""
for f in "$PRD_DIR"/phase_0_*.json; do
    [ -f "$f" ] && INFRA_FILE="$f" && break
done

if [ -z "$INFRA_FILE" ]; then
    echo '{"status":"error","error":"Infrastructure file not found (phase_0_*.json)"}'
    exit 1
fi

#------------------------------------------------------------------------------
# Collect results from agent result files
#------------------------------------------------------------------------------
results="[]"
all_files_created="[]"
all_files_modified="[]"
completed_tasks=""

agent_count=$(echo "$AGENT_STATUS" | jq 'length')
for ((i=0; i<agent_count; i++)); do
    agent=$(echo "$AGENT_STATUS" | jq ".[$i]")
    agent_id=$(echo "$agent" | jq -r '.agentId')
    status=$(echo "$agent" | jq -r '.status')
    task_ids=$(echo "$agent" | jq '.taskIds')

    result_file="/tmp/.prd_agent_${agent_id}_results.json"

    files_created="[]"
    files_modified="[]"
    notes=""
    model=""

    if [ -f "$result_file" ]; then
        # Validate and extract
        if jq -e '.agentId and .status' "$result_file" > /dev/null 2>&1; then
            files_created=$(jq '.filesCreated // []' "$result_file")
            files_modified=$(jq '.filesModified // []' "$result_file")
            notes=$(jq -r '.notes // ""' "$result_file")
            model=$(jq -r '.model // ""' "$result_file")
        fi
    fi

    # Aggregate files
    all_files_created=$(echo "$all_files_created $files_created" | jq -s 'add | unique')
    all_files_modified=$(echo "$all_files_modified $files_modified" | jq -s 'add | unique')

    # Collect completed task IDs
    if [ "$status" = "complete" ]; then
        for tid in $(echo "$task_ids" | jq -r '.[]'); do
            completed_tasks="$completed_tasks $tid"
        done
    fi

    # Build result entry
    result_entry=$(jq -n \
        --arg id "$agent_id" \
        --arg status "$status" \
        --arg model "$model" \
        --argjson taskIds "$task_ids" \
        --argjson created "$files_created" \
        --argjson modified "$files_modified" \
        --arg notes "$notes" \
        '{agentId: $id, status: $status, model: $model, taskIds: $taskIds, filesCreated: $created, filesModified: $modified, notes: $notes}')
    results=$(echo "$results" | jq --argjson entry "$result_entry" '. + [$entry]')
done

#------------------------------------------------------------------------------
# Update infrastructure JSON (mark completed tasks)
#------------------------------------------------------------------------------
TEMP_FILE=$(mktemp)
cp "$INFRA_FILE" "$TEMP_FILE"

for tid in $completed_tasks; do
    # Update task status to "Complete" in JSON
    jq --arg tid "$tid" '
        .tasks |= map(if .taskId == $tid then .taskStatus = "Complete" else . end)
    ' "$TEMP_FILE" > "${TEMP_FILE}.new" && mv "${TEMP_FILE}.new" "$TEMP_FILE"
done

# Write updated JSON back to file
cp "$TEMP_FILE" "$INFRA_FILE"
rm -f "$TEMP_FILE"

#------------------------------------------------------------------------------
# Calculate infrastructure progress from JSON
#------------------------------------------------------------------------------
infra_total=$(jq '.tasks | length' "$INFRA_FILE")
infra_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$INFRA_FILE")

if [ "$infra_total" -gt 0 ]; then
    infra_pct=$((infra_complete * 100 / infra_total))
else
    infra_pct=0
fi

#------------------------------------------------------------------------------
# Update summary cache
#------------------------------------------------------------------------------
if [ -f "$SUMMARY_FILE" ]; then
    # Update infrastructure line
    sed -i "s/^Infrastructure:.*/Infrastructure: $infra_complete\/$infra_total tasks ($infra_pct%)/" "$SUMMARY_FILE"
else
    cat > "$SUMMARY_FILE" << EOF
PRD: $ACTIVE_PRD
Infrastructure: $infra_complete/$infra_total tasks ($infra_pct%)
EOF
fi

#------------------------------------------------------------------------------
# Clean up temp files
#------------------------------------------------------------------------------
rm -f /tmp/.prd_agent_*_results.json
rm -f /tmp/.prd_agent_results.json
rm -f /tmp/.prd_infra_plan.json
rm -f /tmp/.prd_infra_build.json

#------------------------------------------------------------------------------
# Output JSON result
#------------------------------------------------------------------------------
jq -n \
    --arg status "complete" \
    --arg prd "$ACTIVE_PRD" \
    --argjson infraComplete "$infra_complete" \
    --argjson infraTotal "$infra_total" \
    --argjson infraPct "$infra_pct" \
    --argjson results "$results" \
    --argjson filesCreated "$all_files_created" \
    --argjson filesModified "$all_files_modified" \
    '{
        status: $status,
        prd: $prd,
        infraProgress: {complete: $infraComplete, total: $infraTotal, pct: $infraPct},
        results: $results,
        filesCreated: $filesCreated,
        filesModified: $filesModified
    }'
