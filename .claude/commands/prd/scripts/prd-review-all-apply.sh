#!/bin/bash
# PRD Review-All Apply Script - Auto-applies edits based on aggregated findings
# Usage: prd-review-all-apply.sh
# Input: /tmp/.prd_review_all_findings.json
# Output: /tmp/.prd_review_all_edits.json

set -e

STATE_FILE="/tmp/.prd_state"
FINDINGS_FILE="/tmp/.prd_review_all_findings.json"
OUTPUT_FILE="/tmp/.prd_review_all_edits.json"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

# This script lives in the scripts dir it calls into, so resolve from its own
# location. PRD_SCRIPTS_DIR overrides for non-standard layouts.
SCRIPTS_DIR="${PRD_SCRIPTS_DIR:-${WORKSPACE_DIR}/.claude/commands/prd/scripts}"
PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded."}'
    exit 1
fi
source "$STATE_FILE"

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Read findings
if [ ! -f "$FINDINGS_FILE" ]; then
    echo '{"status":"error","error":"Findings file not found. Run prd-review-all-aggregate.sh first."}'
    exit 1
fi

#------------------------------------------------------------------------------
# Extract auto-fixable findings
#------------------------------------------------------------------------------
auto_fixable=$(jq '[
    .findingsBySeverity.high[],
    .findingsBySeverity.medium[],
    .findingsBySeverity.low[]
] | [.[] | select(.autoFixable == true)]' "$FINDINGS_FILE")

auto_fixable_count=$(echo "$auto_fixable" | jq 'length')

if [ "$auto_fixable_count" -eq 0 ]; then
    # No auto-fixable findings - output success with zero edits
    jq -n \
        --arg status "complete" \
        --arg prd "$ACTIVE_PRD" \
        --argjson editsApplied "[]" \
        --argjson editsSkipped "[]" \
        --argjson validationResults "{}" \
        --argjson summary '{"applied": 0, "skipped": 0, "failed": 0}' \
        '{status: $status, prd: $prd, editsApplied: $editsApplied, editsSkipped: $editsSkipped, validationResults: $validationResults, summary: $summary}' > "$OUTPUT_FILE"
    echo '{"status":"complete","applied":0,"skipped":0,"message":"No auto-fixable findings"}'
    exit 0
fi

#------------------------------------------------------------------------------
# Process each auto-fixable finding
#------------------------------------------------------------------------------
edits_applied="[]"
edits_skipped="[]"
validation_results="{}"
applied_count=0
skipped_count=0
failed_count=0

# Group findings by phase file for efficient editing
# Handle empty string phaseFile by using phase number fallback
phase_files=$(echo "$auto_fixable" | jq -r '[.[] | if .phaseFile == "" or .phaseFile == null then "phase_\(.phase).json" else .phaseFile end] | unique | .[]')

for phase_file in $phase_files; do
    # Get full path
    if [[ "$phase_file" == phase_* ]]; then
        phase_path="$PRD_DIR/$phase_file"
    else
        # Try to find the phase file
        phase_num=$(echo "$phase_file" | sed 's/\.json$//')
        phase_path=$(ls "$PRD_DIR"/phase_${phase_num}_*.json 2>/dev/null | head -1)
        if [ -z "$phase_path" ]; then
            phase_path="$PRD_DIR/$phase_file"
        fi
    fi

    if [ ! -f "$phase_path" ]; then
        # Skip if phase file not found
        echo "Warning: Phase file not found: $phase_path" >&2
        continue
    fi

    # Create backup
    backup_path="${phase_path}.backup"
    cp "$phase_path" "$backup_path"

    # Get findings for this phase
    phase_findings=$(echo "$auto_fixable" | jq --arg pf "$phase_file" '[.[] | select(.phaseFile == $pf or ((.phase | tostring) + ".json") == $pf)]')

    # Track if any edit was made to this file
    file_modified=false

    # Process each finding
    for row in $(echo "$phase_findings" | jq -r '.[] | @base64'); do
        _jq() {
            echo "${row}" | base64 --decode | jq -r "${1}"
        }

        task_id=$(_jq '.taskId')
        action=$(_jq '.autoFixAction')
        value=$(_jq '.autoFixValue // empty')
        description=$(_jq '.description')
        severity=$(_jq '.severity')
        finding_type=$(_jq '.type')

        # Build jq edit command based on action
        jq_cmd=""
        case "$action" in
            update_description)
                if [ -n "$value" ]; then
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .description = \"$value\" else . end)"
                fi
                ;;
            add_acceptance_criteria)
                if [ -n "$value" ]; then
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .acceptanceCriteria = ((.acceptanceCriteria // []) + [\"$value\"]) else . end)"
                fi
                ;;
            add_target_file)
                if [ -n "$value" ]; then
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .targetFiles = ((.targetFiles // []) + [\"$value\"]) else . end)"
                fi
                ;;
            remove_task)
                jq_cmd=".tasks |= map(select(.taskId != \"$task_id\"))"
                ;;
            update_status)
                if [ -n "$value" ]; then
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .taskStatus = \"$value\" else . end)"
                fi
                ;;
            add_block_reason)
                if [ -n "$value" ]; then
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .taskStatus = \"Blocked\" | .blockReason = \"$value\" else . end)"
                fi
                ;;
            add_dependency)
                # value should be a JSON array of taskIds, e.g., ["3.1", "3.2"]
                if [ -n "$value" ]; then
                    # Merge with existing dependsOn - $value is already a JSON array literal
                    jq_cmd=".tasks |= map(if .taskId == \"$task_id\" then .dependsOn = ((.dependsOn // []) + $value | unique) else . end)"
                fi
                ;;
            *)
                # Unknown action - skip
                skip_obj=$(jq -n \
                    --arg phase "$phase_file" \
                    --arg taskId "$task_id" \
                    --arg reason "Unknown autoFixAction: $action" \
                    '{phase: $phase, taskId: $taskId, reason: $reason}')
                edits_skipped=$(echo "$edits_skipped" | jq --argjson s "$skip_obj" '. + [$s]')
                skipped_count=$((skipped_count + 1))
                continue
                ;;
        esac

        if [ -z "$jq_cmd" ]; then
            # No valid command - skip
            skip_obj=$(jq -n \
                --arg phase "$phase_file" \
                --arg taskId "$task_id" \
                --arg reason "No autoFixValue provided for action: $action" \
                '{phase: $phase, taskId: $taskId, reason: $reason}')
            edits_skipped=$(echo "$edits_skipped" | jq --argjson s "$skip_obj" '. + [$s]')
            skipped_count=$((skipped_count + 1))
            continue
        fi

        # Apply edit to temp file
        temp_file="${phase_path}.tmp"
        if jq "$jq_cmd" "$phase_path" > "$temp_file" ; then
            # Move temp to actual
            mv "$temp_file" "$phase_path"
            file_modified=true

            # Record edit
            edit_obj=$(jq -n \
                --arg phase "$phase_file" \
                --arg taskId "$task_id" \
                --arg editType "$action" \
                --arg severity "$severity" \
                --arg before "$description" \
                --arg after "$value" \
                '{phase: $phase, taskId: $taskId, editType: $editType, severity: $severity, before: $before, after: $after}')
            edits_applied=$(echo "$edits_applied" | jq --argjson e "$edit_obj" '. + [$e]')
            applied_count=$((applied_count + 1))
        else
            # jq command failed
            rm -f "$temp_file"
            skip_obj=$(jq -n \
                --arg phase "$phase_file" \
                --arg taskId "$task_id" \
                --arg reason "jq edit command failed" \
                '{phase: $phase, taskId: $taskId, reason: $reason}')
            edits_skipped=$(echo "$edits_skipped" | jq --argjson s "$skip_obj" '. + [$s]')
            failed_count=$((failed_count + 1))
        fi
    done

    # Validate the modified phase file
    if [ "$file_modified" = true ]; then
        if bash "$SCRIPTS_DIR/prd-validate-phase.sh" "$phase_path" > /dev/null 2>&1; then
            validation_results=$(echo "$validation_results" | jq --arg pf "$phase_file" '. + {($pf): {valid: true}}')
            # Remove backup on success
            rm -f "$backup_path"
        else
            # Validation failed - rollback
            mv "$backup_path" "$phase_path"
            validation_results=$(echo "$validation_results" | jq --arg pf "$phase_file" '. + {($pf): {valid: false, rolledBack: true}}')

            # Mark all edits for this phase as rolled back
            edits_applied=$(echo "$edits_applied" | jq --arg pf "$phase_file" '[.[] | if .phase == $pf then . + {rolledBack: true} else . end]')
            failed_count=$((failed_count + 1))
        fi
    else
        # No modifications - remove backup
        rm -f "$backup_path"
    fi
done

#------------------------------------------------------------------------------
# Write output file
#------------------------------------------------------------------------------
jq -n \
    --arg status "complete" \
    --arg prd "$ACTIVE_PRD" \
    --argjson editsApplied "$edits_applied" \
    --argjson editsSkipped "$edits_skipped" \
    --argjson validationResults "$validation_results" \
    --argjson summary "$(jq -n \
        --argjson applied "$applied_count" \
        --argjson skipped "$skipped_count" \
        --argjson failed "$failed_count" \
        '{applied: $applied, skipped: $skipped, failed: $failed}')" \
    '{status: $status, prd: $prd, editsApplied: $editsApplied, editsSkipped: $editsSkipped, validationResults: $validationResults, summary: $summary}' > "$OUTPUT_FILE"

# Output summary
echo "{\"status\":\"complete\",\"applied\":$applied_count,\"skipped\":$skipped_count,\"failed\":$failed_count}"
