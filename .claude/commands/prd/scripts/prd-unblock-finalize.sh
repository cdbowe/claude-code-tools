#!/bin/bash
# PRD Unblock Finalize Script - Updates phase JSON after unblock tasks complete (v2 - wave-based)
# Usage: prd-unblock-finalize.sh
# Discovers agent results from /tmp/.prd_agent_W*-T*_results.json (written by workers)
# Reads unblock plan from /tmp/.prd_unblock_plan.json
# Marks originally blocked tasks as Complete and clears blockReason

set -e

STATE_FILE="/tmp/.prd_state"
SUMMARY_FILE="/tmp/.prd_context_summary"
PRD_BASE="${WORKSPACE_DIR:-/workspaces/bankjet}/claude_files/PRDs"
UNBLOCK_PLAN_FILE="/tmp/.prd_unblock_plan.json"

#------------------------------------------------------------------------------
# Discover and build AGENT_STATUS from individual worker result files
# Pattern: /tmp/.prd_agent_W{wave}-T{task}_results.json (wave-based format)
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

# Read unblock plan
if [ ! -f "$UNBLOCK_PLAN_FILE" ]; then
    echo '{"status":"error","error":"Unblock plan file not found."}'
    exit 1
fi

UNBLOCK_PLAN=$(cat "$UNBLOCK_PLAN_FILE")

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

if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "none" ]; then
    echo '{"status":"error","error":"No phase loaded."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Get phase file from state or fall back to search
if [ -n "$PHASE_JSON_FILE" ] && [ -f "$PHASE_JSON_FILE" ]; then
    phase_file="$PHASE_JSON_FILE"
else
    phase_file=""
    for f in "$PRD_DIR"/phase_"$CURRENT_PHASE"*.json "$PRD_DIR"/phase_"$CURRENT_PHASE".json; do
        if [ -f "$f" ]; then
            phase_file="$f"
            break
        fi
    done
fi

if [ -z "$phase_file" ] || [ ! -f "$phase_file" ]; then
    echo "{\"status\":\"error\",\"error\":\"Phase file not found for phase $CURRENT_PHASE\"}"
    exit 1
fi

#------------------------------------------------------------------------------
# Collect results from agent result files
#------------------------------------------------------------------------------
results="[]"
all_files_created="[]"
all_files_modified="[]"

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
# Determine which original blocked tasks are now resolved
#------------------------------------------------------------------------------
# Get originally blocked task IDs from the unblock plan
originally_blocked=$(echo "$UNBLOCK_PLAN" | jq -r '.blockedTasks[].taskId')

# Check if all agents completed successfully
all_complete=true
for ((i=0; i<agent_count; i++)); do
    status=$(echo "$AGENT_STATUS" | jq -r ".[$i].status")
    if [ "$status" != "complete" ]; then
        all_complete=false
        break
    fi
done

# Track which tasks were resolved
resolved_tasks="[]"
still_blocked_tasks="[]"

if [ "$all_complete" = true ]; then
    # All agents completed - mark all originally blocked tasks as Complete
    for tid in $originally_blocked; do
        resolved_tasks=$(echo "$resolved_tasks" | jq --arg tid "$tid" '. + [$tid]')

        # Update task status to Complete and remove blockReason
        jq --arg tid "$tid" \
            '(.tasks[] | select(.taskId == $tid)).taskStatus = "Complete" |
             (.tasks[] | select(.taskId == $tid)) |= del(.blockReason)' \
            "$phase_file" > "${phase_file}.tmp" && mv "${phase_file}.tmp" "$phase_file"
    done
else
    # Some agents blocked - check which unblock tasks completed
    for tid in $originally_blocked; do
        # Find all resolution tasks for this original task
        resolved=true

        # Check resolution tasks (handles comma-separated originalBlockedTask values)
        res_tasks=$(echo "$UNBLOCK_PLAN" | jq -r --arg tid "$tid" \
            '.resolutionTasks[] | select((.originalBlockedTask | split(",") | map(ltrimstr(" ") | rtrimstr(" ")) | index($tid)) != null) | .taskId')
        for unblock_tid in $res_tasks; do
            # Find which agent had this task and check its status
            for ((i=0; i<agent_count; i++)); do
                has_task=$(echo "$AGENT_STATUS" | jq --arg tid "$unblock_tid" ".[$i].taskIds | index(\$tid)")
                if [ "$has_task" != "null" ]; then
                    status=$(echo "$AGENT_STATUS" | jq -r ".[$i].status")
                    if [ "$status" != "complete" ]; then
                        resolved=false
                    fi
                    break
                fi
            done
        done

        if [ "$resolved" = true ]; then
            resolved_tasks=$(echo "$resolved_tasks" | jq --arg tid "$tid" '. + [$tid]')
            jq --arg tid "$tid" \
                '(.tasks[] | select(.taskId == $tid)).taskStatus = "Complete" |
                 (.tasks[] | select(.taskId == $tid)) |= del(.blockReason)' \
                "$phase_file" > "${phase_file}.tmp" && mv "${phase_file}.tmp" "$phase_file"
        else
            still_blocked_tasks=$(echo "$still_blocked_tasks" | jq --arg tid "$tid" '. + [$tid]')
        fi
    done
fi

#------------------------------------------------------------------------------
# Calculate progress
#------------------------------------------------------------------------------
phase_name=$(jq -r '.phaseName // .name // "Phase"' "$phase_file")
phase_total=$(jq '.tasks | length' "$phase_file")
phase_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file")
phase_blocked=$(jq '[.tasks[] | select(.taskStatus == "Blocked")] | length' "$phase_file")

if [ "$phase_total" -gt 0 ]; then
    phase_pct=$((phase_complete * 100 / phase_total))
else
    phase_pct=0
fi

# Calculate overall PRD progress
total_tasks=0
total_complete=0
shopt -s nullglob
for f in "$PRD_DIR"/phase_*.json; do
    [ -f "$f" ] || continue
    t=$(jq '.tasks | length' "$f")
    c=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$f")
    total_tasks=$((total_tasks + t))
    total_complete=$((total_complete + c))
done

if [ "$total_tasks" -gt 0 ]; then
    total_pct=$((total_complete * 100 / total_tasks))
else
    total_pct=0
fi

#------------------------------------------------------------------------------
# Update summary cache
#------------------------------------------------------------------------------
cat > "$SUMMARY_FILE" << EOF
PRD: $ACTIVE_PRD
Phase: $CURRENT_PHASE - $phase_name
Progress: $total_complete/$total_tasks tasks ($total_pct%)
Phase Progress: $phase_complete/$phase_total tasks ($phase_pct%)
EOF

#------------------------------------------------------------------------------
# Clean up temp files
#------------------------------------------------------------------------------
rm -f /tmp/.prd_agent_*_results.json
rm -f /tmp/.prd_agent_results.json
rm -f /tmp/.prd_unblock_plan.json
rm -f /tmp/.prd_unblock_build.json

#------------------------------------------------------------------------------
# Output JSON result
#------------------------------------------------------------------------------
resolved_count=$(echo "$resolved_tasks" | jq 'length')
still_blocked_count=$(echo "$still_blocked_tasks" | jq 'length')

jq -n \
    --arg status "complete" \
    --arg prd "$ACTIVE_PRD" \
    --arg phase "$CURRENT_PHASE" \
    --arg phaseName "$phase_name" \
    --argjson phaseComplete "$phase_complete" \
    --argjson phaseTotal "$phase_total" \
    --argjson phasePct "$phase_pct" \
    --argjson overallComplete "$total_complete" \
    --argjson overallTotal "$total_tasks" \
    --argjson overallPct "$total_pct" \
    --argjson blocked "$phase_blocked" \
    --argjson resolvedTasks "$resolved_tasks" \
    --argjson stillBlockedTasks "$still_blocked_tasks" \
    --argjson resolvedCount "$resolved_count" \
    --argjson stillBlockedCount "$still_blocked_count" \
    --argjson results "$results" \
    --argjson filesCreated "$all_files_created" \
    --argjson filesModified "$all_files_modified" \
    '{
        status: $status,
        prd: $prd,
        phase: $phase,
        phaseName: $phaseName,
        phaseProgress: {complete: $phaseComplete, total: $phaseTotal, pct: $phasePct},
        overallProgress: {complete: $overallComplete, total: $overallTotal, pct: $overallPct},
        blocked: $blocked,
        resolvedTasks: $resolvedTasks,
        stillBlockedTasks: $stillBlockedTasks,
        resolvedCount: $resolvedCount,
        stillBlockedCount: $stillBlockedCount,
        results: $results,
        filesCreated: $filesCreated,
        filesModified: $filesModified
    }' | tee /tmp/.prd_unblock_finalize.json
