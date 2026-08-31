#!/bin/bash
# PRD Unblock Fast Plan — generates unblock plan directly for verify-retry cases
# Skips the agent entirely when ALL blocked tasks are verify types with satisfied deps.
#
# Usage: prd-unblock-fast-plan.sh
# Outputs:
#   {"status":"fast_plan","blockedCount":N} — plan written to /tmp/.prd_unblock_plan.json
#   {"status":"needs_agent"}               — agent required (non-verify blockers)
#   {"status":"none","blockedCount":0}     — no blocked tasks
#   {"status":"error","error":"..."}       — missing state/files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE="/tmp/.prd_state"
OUTPUT_FILE="/tmp/.prd_unblock_plan.json"

# Retry-task model comes from prd-models.json (role: unblock-plan), not a literal.
RETRY_TIER=$(bash "$SCRIPT_DIR/prd-model.sh" role-tier unblock-plan)
RETRY_MODEL=$(bash "$SCRIPT_DIR/prd-model.sh" role unblock-plan)

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi
source "$STATE_FILE"

if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi

if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "none" ]; then
    echo '{"status":"error","error":"No phase loaded. Run /prd read <phase> first."}'
    exit 1
fi

if [ -z "$PHASE_JSON_FILE" ] || [ ! -f "$PHASE_JSON_FILE" ]; then
    echo '{"status":"error","error":"Phase file not found."}'
    exit 1
fi

PHASE_JSON=$(cat "$PHASE_JSON_FILE")

# Find blocked tasks (not Skipped — those resolve automatically)
blocked_tasks=$(echo "$PHASE_JSON" | jq -c '[.tasks[] | select(.taskStatus == "Blocked")]')
blocked_count=$(echo "$blocked_tasks" | jq 'length')

if [ "$blocked_count" -eq 0 ]; then
    echo '{"status":"none","blockedCount":0}'
    exit 0
fi

# Check if ALL blocked tasks qualify for verify-retry:
# - taskType == "verify"
# - all dependsOn tasks are Complete
all_verify_retry=true

for ((i=0; i<blocked_count; i++)); do
    task=$(echo "$blocked_tasks" | jq ".[$i]")
    task_type=$(echo "$task" | jq -r '.taskType')

    if [ "$task_type" != "verify" ]; then
        all_verify_retry=false
        break
    fi

    # Check all dependencies are Complete
    deps=$(echo "$task" | jq -r '.dependsOn // [] | .[]')
    for dep_id in $deps; do
        dep_status=$(echo "$PHASE_JSON" | jq -r --arg id "$dep_id" '.tasks[] | select(.taskId == $id) | .taskStatus')
        if [ "$dep_status" != "Complete" ]; then
            all_verify_retry=false
            break 2
        fi
    done
done

if [ "$all_verify_retry" = false ]; then
    echo '{"status":"needs_agent"}'
    exit 0
fi

# All blocked tasks qualify — generate plan directly
phase_name=$(echo "$PHASE_JSON" | jq -r '.phaseName // .name // "Phase"')

# Build blockedTasks and resolutionTasks arrays
plan_blocked="[]"
plan_resolution="[]"

for ((i=0; i<blocked_count; i++)); do
    task=$(echo "$blocked_tasks" | jq ".[$i]")
    task_id=$(echo "$task" | jq -r '.taskId')
    task_name=$(echo "$task" | jq -r '.taskName')
    task_desc=$(echo "$task" | jq -r '.description // ""')
    block_reason=$(echo "$task" | jq -r '.blockReason // "Verify task failed during previous build"')
    target_files=$(echo "$task" | jq -c '.targetFiles // []')
    acceptance=$(echo "$task" | jq -c '.acceptanceCriteria // []')

    # Add to blockedTasks
    blocked_entry=$(jq -n \
        --arg tid "$task_id" \
        --arg name "$task_name" \
        --arg reason "$block_reason" \
        '{taskId: $tid, taskName: $name, blockReason: $reason, status: "Blocked"}')
    plan_blocked=$(echo "$plan_blocked" | jq --argjson e "$blocked_entry" '. + [$e]')

    # Build resolution description with original task info
    resolution="Verify-retry: ${task_desc} Previous failure: ${block_reason}"

    # Add RETRY task (no UNBLOCK needed)
    retry_entry=$(jq -n \
        --arg tid "RETRY-${task_id}" \
        --arg name "Retry: ${task_name}" \
        --arg original "$task_id" \
        --arg resolution "$resolution" \
        --argjson targets "$target_files" \
        --arg modelTier "$RETRY_TIER" \
        --arg model "$RETRY_MODEL" \
        '{
            taskId: $tid,
            taskName: $name,
            taskType: "verify-retry",
            modelTier: $modelTier,
            model: $model,
            originalBlockedTask: $original,
            resolution: $resolution,
            targetFiles: $targets,
            dependsOn: []
        }')
    plan_resolution=$(echo "$plan_resolution" | jq --argjson e "$retry_entry" '. + [$e]')
done

# Write plan
jq -n \
    --arg prd "$ACTIVE_PRD" \
    --arg phase "$CURRENT_PHASE" \
    --arg phaseName "$phase_name" \
    --argjson blocked "$plan_blocked" \
    --argjson resolution "$plan_resolution" \
    '{
        prd: $prd,
        phase: $phase,
        phaseName: $phaseName,
        blockedTasks: $blocked,
        resolutionTasks: $resolution
    }' > "$OUTPUT_FILE"

resolution_count=$(echo "$plan_resolution" | jq 'length')
echo "{\"status\":\"fast_plan\",\"blockedCount\":$blocked_count,\"resolutionTasks\":$resolution_count}"
