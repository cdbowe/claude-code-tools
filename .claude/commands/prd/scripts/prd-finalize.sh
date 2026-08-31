#!/bin/bash
# PRD Phase Finalize Script - Updates phase JSON status after build
# Usage: prd-finalize.sh
# Discovers agent results from /tmp/.prd_agent_W*-T*_results.json (written by workers)
# This approach is robust across multiple waves - no dependency on orchestrator state

set -e

STATE_FILE="/tmp/.prd_state"
SUMMARY_FILE="/tmp/.prd_context_summary"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

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

if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "none" ]; then
    echo '{"status":"error","error":"No phase loaded."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Get phase file from state (preferred) or fall back to search
if [ -n "$PHASE_JSON_FILE" ] && [ -f "$PHASE_JSON_FILE" ]; then
    phase_file="$PHASE_JSON_FILE"
else
    # Fallback: Find phase file by searching
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
ts_files_touched=false
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
        # Validate and extract
        if jq -e '.agentId and .status' "$result_file" > /dev/null 2>&1; then
            files_created=$(jq '.filesCreated // []' "$result_file")
            files_modified=$(jq '.filesModified // []' "$result_file")
            notes=$(jq -r '.notes // ""' "$result_file")
            model=$(jq -r '.model // ""' "$result_file")

            # Check for TS files
            all_files=$(echo "$files_created $files_modified" | jq -s 'add | .[]' 2>/dev/null || echo "")
            if echo "$all_files" | grep -qE '\.(ts|tsx)$'; then
                ts_files_touched=true
            fi
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
# Validate postValidation compliance for generate-test tasks
# Workers must report postValidationPassed[taskId]=true for tasks with postValidation
#------------------------------------------------------------------------------
post_validation_warnings="[]"

for ((i=0; i<agent_count; i++)); do
    agent=$(echo "$AGENT_STATUS" | jq ".[$i]")
    agent_id=$(echo "$agent" | jq -r '.agentId')
    status=$(echo "$agent" | jq -r '.status')
    task_ids=$(echo "$agent" | jq -r '.taskIds[]')

    # Guard: Only check "complete" status - blocked is expected to fail
    [[ "$status" != "complete" ]] && continue

    result_file="/tmp/.prd_agent_${agent_id}_results.json"
    [[ ! -f "$result_file" ]] && continue

    for tid in $task_ids; do
        # Check if task has postValidation in phase JSON
        has_post_v=$(jq -e --arg tid "$tid" '.tasks[] | select(.taskId == $tid) | .postValidation' "$phase_file" 2>/dev/null && echo "1" || echo "0")
        [[ "$has_post_v" != "1" ]] && continue

        # Task has postValidation - check if worker reported it passed
        pv_passed=$(jq -r --arg tid "$tid" '.postValidationPassed[$tid] // false' "$result_file")

        if [[ "$pv_passed" != "true" ]]; then
            warning=$(jq -n \
                --arg agent "$agent_id" \
                --arg task "$tid" \
                --arg reason "Task has postValidation but worker did not report postValidationPassed[$tid]=true. Downgrading to Blocked." \
                '{agentId: $agent, taskId: $task, reason: $reason}')
            post_validation_warnings=$(echo "$post_validation_warnings" | jq --argjson w "$warning" '. + [$w]')

            # Downgrade this agent's status for this task
            AGENT_STATUS=$(echo "$AGENT_STATUS" | jq --arg id "$agent_id" \
                '(.[] | select(.agentId == $id)).status = "blocked"')
        fi
    done
done

#------------------------------------------------------------------------------
# Update phase JSON task statuses
#------------------------------------------------------------------------------
for ((i=0; i<agent_count; i++)); do
    agent=$(echo "$AGENT_STATUS" | jq ".[$i]")
    agent_id=$(echo "$agent" | jq -r '.agentId')
    status=$(echo "$agent" | jq -r '.status')
    task_ids=$(echo "$agent" | jq -r '.taskIds[]')
    result_file="/tmp/.prd_agent_${agent_id}_results.json"

    # Determine new taskStatus
    if [ "$status" = "complete" ]; then
        new_status="Complete"
    elif [ "$status" = "blocked" ]; then
        new_status="Blocked"
    else
        continue
    fi

    # Update each task
    for tid in $task_ids; do
        if [ "$new_status" = "Blocked" ] && [ -f "$result_file" ]; then
            # Extract block reason from worker results
            reason=$(jq -r --arg tid "$tid" \
                '(.blockedTasks // [])[] | select(.taskId == $tid) | .reason // empty' \
                "$result_file" 2>/dev/null)
            if [ -z "$reason" ]; then
                reason=$(jq -r '.notes // empty' "$result_file" 2>/dev/null)
            fi
            : "${reason:=Worker reported blocked (no reason captured)}"

            # Build blockDetails object with full diagnostic context
            worker_notes=$(jq -r '.notes // ""' "$result_file" 2>/dev/null)
            worker_model=$(jq -r '.model // ""' "$result_file" 2>/dev/null)
            files_attempted=$(jq -c '[(.filesCreated // [])[], (.filesModified // [])[]] | unique' "$result_file" 2>/dev/null || echo '[]')
            captured_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            jq --arg tid "$tid" --arg status "$new_status" --arg reason "$reason" \
                --arg notes "$worker_notes" --arg model "$worker_model" \
                --argjson filesAttempted "$files_attempted" \
                --arg capturedAt "$captured_at" --arg phase "$CURRENT_PHASE" \
                '(.tasks[] | select(.taskId == $tid)) |= . + {
                    taskStatus: $status,
                    blockReason: $reason,
                    blockDetails: {
                        workerNotes: $notes,
                        filesAttempted: $filesAttempted,
                        model: $model,
                        capturedAt: $capturedAt,
                        phase: $phase
                    }
                }' \
                "$phase_file" > "${phase_file}.tmp" && mv "${phase_file}.tmp" "$phase_file"
        else
            jq --arg tid "$tid" --arg status "$new_status" \
                '(.tasks[] | select(.taskId == $tid)).taskStatus = $status' \
                "$phase_file" > "${phase_file}.tmp" && mv "${phase_file}.tmp" "$phase_file"
        fi
    done
done

#------------------------------------------------------------------------------
# Mark dependent tasks as Skipped if their dependencies are Blocked
# This prevents cascading failures in subsequent builds
#------------------------------------------------------------------------------
skipped_tasks="[]"

# Get all task statuses after updates
task_statuses=$(jq '[.tasks[] | {taskId: .taskId, taskStatus: .taskStatus}]' "$phase_file")

# Find pending tasks with blocked dependencies
pending_tasks=$(jq -c '[.tasks[] | select(.taskStatus == "Pending") | {taskId: .taskId, dependsOn: (.dependsOn // [])}]' "$phase_file")

for row in $(echo "$pending_tasks" | jq -c '.[]'); do
    task_id=$(echo "$row" | jq -r '.taskId')
    deps=$(echo "$row" | jq -r '.dependsOn[]' 2>/dev/null || true)

    for dep_id in $deps; do
        dep_status=$(echo "$task_statuses" | jq -r --arg id "$dep_id" '.[] | select(.taskId == $id) | .taskStatus')

        # If dependency is Blocked or Skipped, this task should be Skipped
        if [[ "$dep_status" == "Blocked" || "$dep_status" == "Skipped" ]]; then
            skip_reason="Dependency $dep_id has status: $dep_status"

            # Update phase JSON to mark task as Skipped
            jq --arg tid "$task_id" --arg reason "$skip_reason" \
                '(.tasks[] | select(.taskId == $tid)) |= . + {taskStatus: "Skipped", skipReason: $reason}' \
                "$phase_file" > "${phase_file}.tmp" && mv "${phase_file}.tmp" "$phase_file"

            # Track skipped task
            skipped_entry=$(jq -n --arg tid "$task_id" --arg dep "$dep_id" --arg depStatus "$dep_status" \
                '{taskId: $tid, blockedDep: $dep, depStatus: $depStatus}')
            skipped_tasks=$(echo "$skipped_tasks" | jq --argjson entry "$skipped_entry" '. + [$entry]')

            break  # Only need one blocked dependency to skip
        fi
    done
done

phase_skipped=$(echo "$skipped_tasks" | jq 'length')

#------------------------------------------------------------------------------
# Calculate progress and status counts
#------------------------------------------------------------------------------
phase_name=$(jq -r '.phaseName // .name // "Phase"' "$phase_file")
phase_total=$(jq '.tasks | length' "$phase_file")
phase_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file")
phase_blocked=$(jq '[.tasks[] | select(.taskStatus == "Blocked")] | length' "$phase_file")

# Get counts for all unique statuses
# NOTE: from_entries expects {key, value} objects, NOT {status, count}
status_counts=$(jq '[.tasks[].taskStatus] | group_by(.) | map({key: .[0], value: length}) | from_entries' "$phase_file")

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
shopt -u nullglob

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
# Conditional cleanup - preserve artifacts if retrospective needed
#------------------------------------------------------------------------------
pv_warning_count=$(echo "$post_validation_warnings" | jq 'length')

# Check if retrospective is needed
needs_retrospective=false
if [ "$phase_blocked" -gt 0 ] || [ "$pv_warning_count" -gt 0 ]; then
    needs_retrospective=true
fi
# Also check for conflict files
if compgen -G "/tmp/.prd_conflict_*.json" >/dev/null; then
    needs_retrospective=true
fi

if [ "$needs_retrospective" = true ]; then
    # Preserve artifacts for retrospective - it will clean up after analysis
    jq -n \
        --argjson results "$results" \
        --argjson pvWarnings "$post_validation_warnings" \
        '{agentResults: $results, postValidationWarnings: $pvWarnings}' \
        > /tmp/.prd_retrospective_input.json
    # Keep .prd_build.json for retrospective to read task details
    # Only clean up agent results (already aggregated into retrospective input)
    rm -f /tmp/.prd_agent_*_results.json
    rm -f /tmp/.prd_agent_results.json
else
    # No issues - clean up all temp files
    rm -f /tmp/.prd_agent_*_results.json
    rm -f /tmp/.prd_agent_results.json
    rm -f /tmp/.prd_plan.json
    rm -f /tmp/.prd_build.json
fi

#------------------------------------------------------------------------------
# Output JSON result
#------------------------------------------------------------------------------

# Convert bash boolean to jq boolean
if [ "$needs_retrospective" = true ]; then
    needs_retro_json=true
else
    needs_retro_json=false
fi

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
    --argjson skipped "$phase_skipped" \
    --argjson skippedTasks "$skipped_tasks" \
    --argjson statusCounts "$status_counts" \
    --argjson results "$results" \
    --argjson filesCreated "$all_files_created" \
    --argjson filesModified "$all_files_modified" \
    --argjson tsTouched "$ts_files_touched" \
    --argjson pvWarnings "$post_validation_warnings" \
    --argjson pvWarningCount "$pv_warning_count" \
    --argjson needsRetrospective "$needs_retro_json" \
    '{
        status: $status,
        prd: $prd,
        phase: $phase,
        phaseName: $phaseName,
        phaseProgress: {complete: $phaseComplete, total: $phaseTotal, pct: $phasePct},
        overallProgress: {complete: $overallComplete, total: $overallTotal, pct: $overallPct},
        blocked: $blocked,
        skipped: $skipped,
        skippedTasks: $skippedTasks,
        statusCounts: $statusCounts,
        postValidationWarnings: $pvWarnings,
        postValidationWarningCount: $pvWarningCount,
        needsRetrospective: $needsRetrospective,
        results: $results,
        filesCreated: $filesCreated,
        filesModified: $filesModified,
        typescriptFilesTouched: $tsTouched
    }' | tee /tmp/.prd_finalize.json
