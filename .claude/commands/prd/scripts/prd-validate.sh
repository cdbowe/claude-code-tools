#!/bin/bash
# PRD Validate Script - Validates JSON files before use
# Usage: prd-validate.sh <file_path> <schema_type>
# Schema types: plan, plan-infra, build, build-infra, build-unblock, unblock-finalize, build-finalize, list, read, gen, edit, agent-result

set -e

FILE_PATH="${1:-}"
SCHEMA_TYPE="${2:-}"

if [ -z "$FILE_PATH" ] || [ -z "$SCHEMA_TYPE" ]; then
    echo '{"valid":false,"error":"Usage: prd-validate.sh <file_path> <schema_type>"}'
    exit 1
fi

if [ ! -f "$FILE_PATH" ]; then
    echo "{\"valid\":false,\"error\":\"File not found: $FILE_PATH\"}"
    exit 1
fi

# Check if valid JSON
if ! jq -e '.' "$FILE_PATH" > /dev/null 2>&1; then
    echo '{"valid":false,"error":"Invalid JSON format"}'
    exit 1
fi

#------------------------------------------------------------------------------
# Schema validation functions
#------------------------------------------------------------------------------

validate_plan() {
    # Check top-level fields (wave-based schema)
    if ! jq -e '.prd and .phase and .phaseName and .totalTasks and (.waves | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Plan must have prd, phase, phaseName, totalTasks, and waves array" >&2
        return 1
    fi

    # Reject forbidden old-schema fields
    if jq -e 'has("sequentialTasks") or has("parallelGroups") or has("parallelAgents")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Plan uses old schema (sequentialTasks/parallelGroups). Use wave-based schema with 'waves' array." >&2
        return 1
    fi

    # Validate waves structure
    if jq -e '.waves | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        # Check first wave has required fields
        if ! jq -e '.waves[0] | has("waveId") and has("useWorktrees") and has("tasks")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each wave must have waveId (number), useWorktrees (boolean), and tasks (array)" >&2
            return 1
        fi
        # Check tasks are objects with required fields
        if jq -e '.waves[0].tasks | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
            if ! jq -e '.waves[0].tasks[0] | type == "object" and has("taskId") and has("taskName") and has("taskType") and has("model")' "$FILE_PATH" > /dev/null 2>&1; then
                echo "Error: waves[].tasks must be array of objects with taskId, taskName, taskType, model fields" >&2
                return 1
            fi
        fi
    fi

    return 0
}

validate_plan_infra() {
    # Check top-level fields (wave-based schema, no .phase field required for infra)
    if ! jq -e '.prd and .totalTasks and (.waves | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Infra plan must have prd, totalTasks, and waves array" >&2
        return 1
    fi

    # Reject forbidden old-schema fields
    if jq -e 'has("sequentialTasks") or has("parallelGroups") or has("parallelAgents")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Infra plan uses old schema (sequentialTasks/parallelGroups). Use wave-based schema with 'waves' array." >&2
        return 1
    fi

    # Validate waves structure
    if jq -e '.waves | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        # Check first wave has required fields
        if ! jq -e '.waves[0] | has("waveId") and has("useWorktrees") and has("tasks")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each wave must have waveId (number), useWorktrees (boolean), and tasks (array)" >&2
            return 1
        fi
        # Check tasks are objects with required fields
        if jq -e '.waves[0].tasks | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
            if ! jq -e '.waves[0].tasks[0] | type == "object" and has("taskId") and has("taskName") and has("taskType") and has("model")' "$FILE_PATH" > /dev/null 2>&1; then
                echo "Error: waves[].tasks must be array of objects with taskId, taskName, taskType, model fields" >&2
                return 1
            fi
        fi
    fi

    return 0
}

validate_build() {
    # Wave-based build schema: status, buildType=phase, prd, phase, waves array
    if ! jq -e '.status == "ready_to_build" and .buildType == "phase" and .prd and .phase and (.waves | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Build must have status=ready_to_build, buildType=phase, prd, phase, and waves array" >&2
        return 1
    fi
    # Check waves have agents
    if jq -e '.waves | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.waves[0] | has("waveId") and has("useWorktrees") and has("agents")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each wave must have waveId, useWorktrees, and agents array" >&2
            return 1
        fi
    fi
    return 0
}

validate_build_infra() {
    # Wave-based infra build schema: status, buildType=infra, prd, waves array
    if ! jq -e '.status == "ready_to_build" and .buildType == "infra" and .prd and (.waves | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Infra build must have status=ready_to_build, buildType=infra, prd, and waves array" >&2
        return 1
    fi
    # Check waves have agents
    if jq -e '.waves | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.waves[0] | has("waveId") and has("useWorktrees") and has("agents")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each wave must have waveId, useWorktrees, and agents array" >&2
            return 1
        fi
    fi
    return 0
}

validate_build_unblock() {
    # Validate output of prd-unblock-compile.sh (v2 - waves structure)
    # Required: status=ready_to_build, buildType=unblock, prd, phase, blockedTasks array, waves array

    if ! jq -e '.status == "ready_to_build" and .buildType == "unblock"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-unblock must have status=ready_to_build and buildType=unblock" >&2
        return 1
    fi

    if ! jq -e '.prd and .phase' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-unblock must have prd and phase fields" >&2
        return 1
    fi

    if ! jq -e '.blockedTasks | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-unblock must have blockedTasks array" >&2
        return 1
    fi

    # Check for FORBIDDEN old schema fields
    if jq -e '.agents' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-unblock must use 'waves' array, not 'agents' (old schema)" >&2
        return 1
    fi

    if ! jq -e '(.waves | type == "array") and (.waves | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-unblock must have non-empty waves array" >&2
        return 1
    fi

    # Validate each wave has required fields
    if jq -e '.waves | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.waves[0] | has("waveId") and has("useWorktrees") and has("agents")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each wave must have waveId, useWorktrees, and agents array" >&2
            return 1
        fi
        # Validate first wave's first agent has required fields
        if jq -e '.waves[0].agents | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
            if ! jq -e '.waves[0].agents[0] | has("agentId") and has("prompt") and has("model") and has("taskIds")' "$FILE_PATH" > /dev/null 2>&1; then
                echo "Error: agents must have agentId, prompt, model, and taskIds fields" >&2
                return 1
            fi
        fi
    fi

    return 0
}

validate_unblock_finalize() {
    # Validate output of prd-unblock-finalize.sh
    # Required: status, prd, phase, phaseName, phaseProgress, overallProgress, resolvedTasks, results

    if ! jq -e '.status == "complete"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have status=complete" >&2
        return 1
    fi

    if ! jq -e '.prd and .phase and .phaseName' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have prd, phase, and phaseName fields" >&2
        return 1
    fi

    if ! jq -e '.phaseProgress | has("complete") and has("total") and has("pct")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have phaseProgress with complete, total, pct" >&2
        return 1
    fi

    if ! jq -e '.overallProgress | has("complete") and has("total") and has("pct")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have overallProgress with complete, total, pct" >&2
        return 1
    fi

    if ! jq -e '(.resolvedTasks | type == "array") and (.stillBlockedTasks | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have resolvedTasks and stillBlockedTasks arrays" >&2
        return 1
    fi

    if ! jq -e 'has("resolvedCount") and has("stillBlockedCount")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have resolvedCount and stillBlockedCount fields" >&2
        return 1
    fi

    if ! jq -e '.results | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: unblock-finalize must have results array" >&2
        return 1
    fi

    return 0
}

validate_build_finalize() {
    # Validate output of prd-finalize.sh
    # Required: status, prd, phase, phaseName, phaseProgress, overallProgress, results, statusCounts

    if ! jq -e '.status == "complete"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have status=complete" >&2
        return 1
    fi

    if ! jq -e '.prd and .phase and .phaseName' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have prd, phase, and phaseName fields" >&2
        return 1
    fi

    if ! jq -e '.phaseProgress | has("complete") and has("total") and has("pct")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have phaseProgress with complete, total, pct" >&2
        return 1
    fi

    if ! jq -e '.overallProgress | has("complete") and has("total") and has("pct")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have overallProgress with complete, total, pct" >&2
        return 1
    fi

    if ! jq -e '.results | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have results array" >&2
        return 1
    fi

    # Validate results array entries have required fields
    if jq -e '.results | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.results[0] | has("agentId") and has("status") and has("taskIds")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: results entries must have agentId, status, and taskIds fields" >&2
            return 1
        fi
    fi

    if ! jq -e '.statusCounts | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have statusCounts object" >&2
        return 1
    fi

    if ! jq -e 'has("blocked") and has("skipped")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have blocked and skipped count fields" >&2
        return 1
    fi

    if ! jq -e '.skippedTasks | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have skippedTasks array" >&2
        return 1
    fi

    if ! jq -e '.postValidationWarnings | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have postValidationWarnings array" >&2
        return 1
    fi

    if ! jq -e 'has("postValidationWarningCount") and has("needsRetrospective")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have postValidationWarningCount and needsRetrospective fields" >&2
        return 1
    fi

    if ! jq -e '(.filesCreated | type == "array") and (.filesModified | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have filesCreated and filesModified arrays" >&2
        return 1
    fi

    if ! jq -e 'has("typescriptFilesTouched")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: build-finalize must have typescriptFilesTouched field" >&2
        return 1
    fi

    return 0
}

validate_list() {
    jq -e '.status == "awaiting_selection" and .selectionType == "prd" and (.options | type == "array")' "$FILE_PATH" > /dev/null 2>&1
}

validate_read() {
    jq -e '.status == "awaiting_selection" and .selectionType == "phase" and (.options | type == "array")' "$FILE_PATH" > /dev/null 2>&1
}

validate_gen() {
    jq -e '.status and (.status == "complete" or .status == "error")' "$FILE_PATH" > /dev/null 2>&1
}

validate_edit() {
    # Check status is present and valid
    if ! jq -e '.status and (.status == "success" or .status == "error")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have status field (success or error)" >&2
        return 1
    fi

    # Check prd field is present
    if ! jq -e '.prd and (.prd | type == "string") and (.prd | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have prd field (non-empty string)" >&2
        return 1
    fi

    # If error status, must have error message
    if jq -e '.status == "error"' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.error and (.error | type == "string") and (.error | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Error status must include error message" >&2
            return 1
        fi
        return 0
    fi

    # Success status validation
    # Check operation field
    valid_operations='["add_phase", "add_task", "remove_task", "update_task", "mark_complete", "mark_blocked", "update_progress", "update_infra", "update_context"]'
    if ! jq -e --argjson ops "$valid_operations" '.operation and (.operation | IN($ops[]))' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have valid operation field (add_phase, add_task, remove_task, update_task, mark_complete, mark_blocked, update_progress, update_infra, update_context)" >&2
        return 1
    fi

    # Check filesCreated is array
    if ! jq -e '.filesCreated | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have filesCreated array" >&2
        return 1
    fi

    # Check filesModified is array
    if ! jq -e '.filesModified | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have filesModified array" >&2
        return 1
    fi

    # Check summary is present
    if ! jq -e '.summary and (.summary | type == "string") and (.summary | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Edit result must have summary field (non-empty string)" >&2
        return 1
    fi

    # Check changes array if present
    if jq -e 'has("changes")' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.changes | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: changes field must be an array" >&2
            return 1
        fi
        # Check each change has required fields
        if jq -e '.changes | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
            if ! jq -e '.changes | all(has("file") and has("type") and has("detail"))' "$FILE_PATH" > /dev/null 2>&1; then
                echo "Error: Each change must have file, type, and detail fields" >&2
                return 1
            fi
        fi
    fi

    # Operation-specific validation
    local operation=$(jq -r '.operation' "$FILE_PATH")

    # add_phase requires phaseNumber and phaseName
    if [ "$operation" = "add_phase" ]; then
        if ! jq -e '.phaseNumber and (.phaseNumber | type == "number")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: add_phase operation requires phaseNumber (number)" >&2
            return 1
        fi
        if ! jq -e '.phaseName and (.phaseName | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: add_phase operation requires phaseName (string)" >&2
            return 1
        fi
    fi

    return 0
}

validate_agent_result() {
    jq -e '.agentId and .status and (.taskIds | type == "array")' "$FILE_PATH" > /dev/null 2>&1
}

validate_phase_json() {
    # Validate phase JSON file schema
    # Required top-level: phaseId (int), phaseName (string), tasks (array), designPatternInstructions (string)

    # Check top-level required fields
    if ! jq -e '.phaseId and .phaseName and (.tasks | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Phase JSON must have phaseId (int), phaseName (string), and tasks (array)" >&2
        return 1
    fi

    # Check designPatternInstructions is present and non-empty string
    if ! jq -e '.designPatternInstructions and (.designPatternInstructions | type == "string") and (.designPatternInstructions | length > 10)' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Phase JSON must have designPatternInstructions (non-empty string with Serena MCP instructions)" >&2
        return 1
    fi

    # Check tasks array has items
    task_count=$(jq '.tasks | length' "$FILE_PATH" 2>/dev/null || echo "0")
    if [ "$task_count" -eq 0 ]; then
        echo "Error: Phase JSON must have at least one task" >&2
        return 1
    fi

    # Check each task has required fields: taskId, taskName, taskType, taskStatus
    # CRITICAL: Must use taskName (NOT title)
    invalid_tasks=$(jq -r '[.tasks[] | select(
        (.taskId | type != "string") or
        (.taskName | type != "string" or . == null or . == "") or
        (.taskType | type != "string") or
        (.taskStatus | type != "string")
    )] | length' "$FILE_PATH" 2>/dev/null || echo "0")

    if [ "$invalid_tasks" -gt 0 ]; then
        # Check specifically for 'title' field being used instead of 'taskName'
        has_title=$(jq '[.tasks[] | select(has("title") and (has("taskName") | not))] | length' "$FILE_PATH" 2>/dev/null || echo "0")
        if [ "$has_title" -gt 0 ]; then
            echo "Error: Tasks use 'title' field - must use 'taskName' instead" >&2
        else
            echo "Error: Tasks must have taskId (string), taskName (string), taskType (string), taskStatus (string)" >&2
        fi
        return 1
    fi

    # Check valid taskStatus values (Pending is the correct initial status, NOT "Not Started")
    invalid_status=$(jq -r '[.tasks[] | select(
        .taskStatus != "Complete" and
        .taskStatus != "Pending" and
        .taskStatus != "InProgress" and
        .taskStatus != "Blocked" and
        .taskStatus != "NeedsClarification" and
        .taskStatus != "Skipped"
    )] | length' "$FILE_PATH" 2>/dev/null || echo "0")

    if [ "$invalid_status" -gt 0 ]; then
        # Check specifically for "Not Started" which is a common mistake
        has_not_started=$(jq '[.tasks[] | select(.taskStatus == "Not Started")] | length' "$FILE_PATH" 2>/dev/null || echo "0")
        if [ "$has_not_started" -gt 0 ]; then
            echo "Error: taskStatus uses 'Not Started' - must use 'Pending' instead" >&2
        else
            echo "Error: taskStatus must be one of: Pending, Complete, InProgress, Blocked, NeedsClarification, Skipped" >&2
        fi
        return 1
    fi

    # Check valid taskType values
    invalid_type=$(jq -r '[.tasks[] | select(
        .taskType != "create-file" and
        .taskType != "edit-file" and
        .taskType != "refactor" and
        .taskType != "verify" and
        .taskType != "rename" and
        .taskType != "delete-file" and
        .taskType != "generate-test"
    )] | length' "$FILE_PATH" 2>/dev/null || echo "0")

    if [ "$invalid_type" -gt 0 ]; then
        # Show the invalid taskType values found
        bad_types=$(jq -r '[.tasks[] | select(
            .taskType != "create-file" and
            .taskType != "edit-file" and
            .taskType != "refactor" and
            .taskType != "verify" and
            .taskType != "rename" and
            .taskType != "delete-file" and
            .taskType != "generate-test"
        ) | .taskType] | unique | join(", ")' "$FILE_PATH" 2>/dev/null)
        echo "Error: Invalid taskType value(s): $bad_types" >&2
        echo "Valid taskType values: create-file, edit-file, refactor, verify, rename, delete-file, generate-test" >&2
        return 1
    fi

    # Check for forbidden 'targetFile' field (must use 'targetFiles' array instead)
    has_target_file=$(jq '[.tasks[] | select(has("targetFile"))] | length' "$FILE_PATH" 2>/dev/null || echo "0")
    if [ "$has_target_file" -gt 0 ]; then
        echo "Error: Tasks use 'targetFile' (string) - must use 'targetFiles' (array of strings) instead" >&2
        return 1
    fi

    # Check that targetFiles is an array when present
    invalid_target_files=$(jq '[.tasks[] | select(has("targetFiles") and (.targetFiles | type != "array"))] | length' "$FILE_PATH" 2>/dev/null || echo "0")
    if [ "$invalid_target_files" -gt 0 ]; then
        echo "Error: 'targetFiles' must be an array of strings, not a single value" >&2
        return 1
    fi

    return 0
}

validate_gen_output() {
    # Validate prd-gen-v2 output JSON
    if ! jq -e '.status and (.status == "complete" or .status == "error")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Gen output must have status field (complete or error)" >&2
        return 1
    fi

    # If complete, check required fields
    if jq -e '.status == "complete"' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.prdName and .directory and (.files | type == "array") and .taskCount' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Complete gen output must have prdName, directory, files array, taskCount" >&2
            return 1
        fi
    fi

    return 0
}

validate_review() {
    # Validate prd-reviewer-v2 output JSON
    # Required: status, prd, phase, phaseName, findings array, summary object

    # Check status
    if ! jq -e '.status and (.status == "complete" or .status == "error")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have status field (complete or error)" >&2
        return 1
    fi

    # If error status, must have error message
    if jq -e '.status == "error"' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.error and (.error | type == "string") and (.error | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Error status must include error message" >&2
            return 1
        fi
        return 0
    fi

    # Check required fields for complete status
    if ! jq -e '.prd and (.prd | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have prd field (string)" >&2
        return 1
    fi

    if ! jq -e '.phase and (.phase | type == "number")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have phase field (number)" >&2
        return 1
    fi

    if ! jq -e '.phaseName and (.phaseName | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have phaseName field (string)" >&2
        return 1
    fi

    # Check findings array
    if ! jq -e '.findings | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have findings array" >&2
        return 1
    fi

    # Check each finding has required fields
    if jq -e '.findings | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        # Check type field (required, must be valid value)
        if ! jq -e '.findings | all(has("type") and (.type | IN("ambiguous", "missing", "clarification")))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each finding must have type field (ambiguous, missing, or clarification)" >&2
            return 1
        fi

        # Check severity field (required, must be valid value)
        if ! jq -e '.findings | all(has("severity") and (.severity | IN("high", "medium", "low")))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each finding must have severity field (high, medium, or low)" >&2
            return 1
        fi

        # Check taskId field (required)
        if ! jq -e '.findings | all(has("taskId") and (.taskId | type == "string") and (.taskId | length > 0))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each finding must have taskId field (non-empty string)" >&2
            return 1
        fi

        # Check description field (required)
        if ! jq -e '.findings | all(has("description") and (.description | type == "string") and (.description | length > 0))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each finding must have description field (non-empty string)" >&2
            return 1
        fi

        # Check suggestion field (required)
        if ! jq -e '.findings | all(has("suggestion") and (.suggestion | type == "string") and (.suggestion | length > 0))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each finding must have suggestion field (non-empty string)" >&2
            return 1
        fi

        # Check recommendedFix field (required when autoFixable is false)
        if ! jq -e '.findings | all(if .autoFixable == false then (has("recommendedFix") and (.recommendedFix | type == "string") and (.recommendedFix | length > 0)) else true end)' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each non-autoFixable finding must have recommendedFix field (actionable prompt for /prd edit)" >&2
            return 1
        fi
    fi

    # Check summary object
    if ! jq -e '.summary | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Review must have summary object" >&2
        return 1
    fi

    if ! jq -e '.summary | has("ambiguous") and has("missing") and has("clarification") and has("total")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Summary must have ambiguous, missing, clarification, and total counts" >&2
        return 1
    fi

    if ! jq -e '.summary | (.ambiguous | type == "number") and (.missing | type == "number") and (.clarification | type == "number") and (.total | type == "number")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Summary counts must be numbers" >&2
        return 1
    fi

    return 0
}

validate_review_all_compile() {
    # Validate prd-review-all-compile.sh output
    # Required: status=ready, prd, phases array, agents array

    if ! jq -e '.status == "ready"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-compile must have status=ready" >&2
        return 1
    fi

    if ! jq -e '.prd and (.prd | type == "string") and (.prd | length > 0)' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-compile must have prd field (non-empty string)" >&2
        return 1
    fi

    if ! jq -e '.phases | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-compile must have phases array" >&2
        return 1
    fi

    if ! jq -e '.agents | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-compile must have agents array" >&2
        return 1
    fi

    # Check each agent has required fields
    if jq -e '.agents | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.agents | all(has("agentId") and has("phaseId") and has("prompt"))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each agent must have agentId, phaseId, and prompt fields" >&2
            return 1
        fi
    fi

    return 0
}

validate_review_all_findings() {
    # Validate prd-review-all-aggregate.sh output
    # Required: status=complete, prd, findingsBySeverity object with high/medium/low

    if ! jq -e '.status == "complete"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-findings must have status=complete" >&2
        return 1
    fi

    if ! jq -e '.prd and (.prd | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-findings must have prd field (string)" >&2
        return 1
    fi

    if ! jq -e '.findingsBySeverity | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-findings must have findingsBySeverity object" >&2
        return 1
    fi

    if ! jq -e '.findingsBySeverity | has("high") and has("medium") and has("low")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: findingsBySeverity must have high, medium, low arrays" >&2
        return 1
    fi

    if ! jq -e '.findingsBySeverity | (.high | type == "array") and (.medium | type == "array") and (.low | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: findingsBySeverity.high/medium/low must be arrays" >&2
        return 1
    fi

    if ! jq -e 'has("readinessScore") and (.readinessScore | type == "number")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-findings must have readinessScore (number)" >&2
        return 1
    fi

    # Check manualFixGroups array exists
    if ! jq -e '.manualFixGroups | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-findings must have manualFixGroups array" >&2
        return 1
    fi

    # If manualFixGroups has entries, each must have required fields
    if jq -e '.manualFixGroups | length > 0' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.manualFixGroups | all(has("type") and has("recommendedFix") and has("count") and has("taskIds"))' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Each manualFixGroup must have type, recommendedFix, count, and taskIds fields" >&2
            return 1
        fi
    fi

    return 0
}

validate_review_all_edits() {
    # Validate prd-review-all-apply.sh output
    # Required: status, prd, editsApplied array, summary object

    if ! jq -e '.status and (.status == "complete" or .status == "partial" or .status == "error")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-edits must have status field (complete, partial, or error)" >&2
        return 1
    fi

    if ! jq -e '.prd and (.prd | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-edits must have prd field (string)" >&2
        return 1
    fi

    if ! jq -e '.editsApplied | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-edits must have editsApplied array" >&2
        return 1
    fi

    if ! jq -e '.summary | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-edits must have summary object" >&2
        return 1
    fi

    if ! jq -e '.summary | has("applied") and has("skipped") and has("failed")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: summary must have applied, skipped, failed counts" >&2
        return 1
    fi

    return 0
}

validate_review_all_report() {
    # Validate final review-all report
    # Required: status=complete, mode, prd, passes object, readinessAssessment object

    if ! jq -e '.status == "complete"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-report must have status=complete" >&2
        return 1
    fi

    if ! jq -e '.mode and (.mode | IN("full", "read-only"))' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-report must have mode field (full or read-only)" >&2
        return 1
    fi

    if ! jq -e '.prd and (.prd | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-report must have prd field (string)" >&2
        return 1
    fi

    if ! jq -e '.passes | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-report must have passes object" >&2
        return 1
    fi

    if ! jq -e '.passes | has("initial")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: passes must have initial field" >&2
        return 1
    fi

    if ! jq -e '.readinessAssessment | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: review-all-report must have readinessAssessment object" >&2
        return 1
    fi

    if ! jq -e '.readinessAssessment | has("score") and has("status") and has("message")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: readinessAssessment must have score, status, message" >&2
        return 1
    fi

    return 0
}

validate_retrospective() {
    # Validate retrospective agent output
    # Required: status, prd, phase, analysis object

    if ! jq -e '.status == "complete" or .status == "error"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: retrospective must have status (complete or error)" >&2
        return 1
    fi

    # If error status, only need error field
    if jq -e '.status == "error"' "$FILE_PATH" > /dev/null 2>&1; then
        if ! jq -e '.error and (.error | type == "string")' "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: error status must have error message string" >&2
            return 1
        fi
        return 0
    fi

    # For complete status, validate full schema
    if ! jq -e '.prd and .phase and .phaseName' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: retrospective must have prd, phase, phaseName" >&2
        return 1
    fi

    if ! jq -e '.analysis | type == "object"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: retrospective must have analysis object" >&2
        return 1
    fi

    if ! jq -e '.analysis | has("tasksAnalyzed") and has("rootCauses")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: analysis must have tasksAnalyzed and rootCauses" >&2
        return 1
    fi

    if ! jq -e '.analysis.rootCauses | type == "array"' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: rootCauses must be array" >&2
        return 1
    fi

    if ! jq -e 'has("unblockPlanGenerated") and (.unblockPlanGenerated | type == "boolean")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: retrospective must have unblockPlanGenerated boolean" >&2
        return 1
    fi

    return 0
}

validate_worktree_manifest_core() {
    # Core fields required by ANY worktree build (PRD or standalone)
    # This is permissive and only validates essential structure
    if ! jq -e '.status and .buildType and (.waves | type == "array")' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: Core manifest requires status, buildType, and waves array" >&2
        return 1
    fi

    # Validate waves structure
    local wave_count=$(jq '.waves | length' "$FILE_PATH" 2>/dev/null || echo "0")
    for ((i=0; i<wave_count; i++)); do
        if ! jq -e ".waves[$i].waveId" "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Wave $i missing waveId" >&2
            return 1
        fi
        if ! jq -e ".waves[$i].useWorktrees | type == \"boolean\"" "$FILE_PATH" > /dev/null 2>&1; then
            echo "Error: Wave $i: useWorktrees must be boolean" >&2
            return 1
        fi

        # Validate agents
        local agent_count=$(jq ".waves[$i].agents | length" "$FILE_PATH" 2>/dev/null || echo "0")
        for ((j=0; j<agent_count; j++)); do
            local prefix=".waves[$i].agents[$j]"

            # Core agent fields
            if ! jq -e "${prefix}.agentId and ${prefix}.model" "$FILE_PATH" > /dev/null 2>&1; then
                echo "Error: Wave $i, Agent $j: missing agentId or model" >&2
                return 1
            fi

            # If wave uses worktrees, require worktree/branch
            local use_worktrees=$(jq -r ".waves[$i].useWorktrees" "$FILE_PATH" 2>/dev/null)
            if [ "$use_worktrees" = "true" ]; then
                if ! jq -e "${prefix}.worktree and ${prefix}.branch" "$FILE_PATH" > /dev/null 2>&1; then
                    echo "Error: Wave $i, Agent $j: missing worktree/branch" >&2
                    return 1
                fi
            fi
        done
    done
    return 0
}

validate_worktree_manifest_prd() {
    # Validate core first
    validate_worktree_manifest_core || return 1

    # PRD-specific fields
    if ! jq -e '.prd and .phase' "$FILE_PATH" > /dev/null 2>&1; then
        echo "Error: PRD manifest requires prd and phase fields" >&2
        return 1
    fi

    # PRD agents should have taskId and taskName (recommended but not required)
    local wave_count=$(jq '.waves | length' "$FILE_PATH" 2>/dev/null || echo "0")
    for ((i=0; i<wave_count; i++)); do
        local agent_count=$(jq ".waves[$i].agents | length" "$FILE_PATH" 2>/dev/null || echo "0")
        for ((j=0; j<agent_count; j++)); do
            local prefix=".waves[$i].agents[$j]"
            if ! jq -e "${prefix}.taskId and ${prefix}.taskName" "$FILE_PATH" > /dev/null 2>&1; then
                echo "Warning: Wave $i, Agent $j: missing taskId/taskName (recommended for PRD)" >&2
            fi
        done
    done
    return 0
}

#------------------------------------------------------------------------------
# Route to appropriate validator
#------------------------------------------------------------------------------
case "$SCHEMA_TYPE" in
    plan)
        if validate_plan; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Phase plan schema validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    plan-infra)
        if validate_plan_infra; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Infrastructure plan schema validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    build)
        if validate_build; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid build spec: status must be ready_to_build, buildType must be phase, agents array required"}'
            exit 1
        fi
        ;;
    build-infra)
        if validate_build_infra; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid infra build spec: status must be ready_to_build, buildType must be infra, agents array required"}'
            exit 1
        fi
        ;;
    build-unblock)
        if validate_build_unblock; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Unblock build spec validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    unblock-finalize)
        if validate_unblock_finalize; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Unblock finalize validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    build-finalize)
        if validate_build_finalize; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Build finalize validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    list)
        if validate_list; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid list spec: status must be awaiting_selection, selectionType must be prd"}'
            exit 1
        fi
        ;;
    read)
        if validate_read; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid read spec: status must be awaiting_selection, selectionType must be phase"}'
            exit 1
        fi
        ;;
    gen)
        if validate_gen; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid gen result: status must be complete or error"}'
            exit 1
        fi
        ;;
    edit)
        if validate_edit; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid edit result: status must be complete or error"}'
            exit 1
        fi
        ;;
    agent-result)
        if validate_agent_result; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Invalid agent result: agentId, status, and taskIds array required"}'
            exit 1
        fi
        ;;
    phase-json)
        if validate_phase_json; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Phase JSON validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    gen-output)
        if validate_gen_output; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Gen output validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    review)
        if validate_review; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Review validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    retrospective)
        if validate_retrospective; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Retrospective validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    review-all-compile)
        if validate_review_all_compile; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Review-all compile validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    review-all-findings)
        if validate_review_all_findings; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Review-all findings validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    review-all-edits)
        if validate_review_all_edits; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Review-all edits validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    review-all-report)
        if validate_review_all_report; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Review-all report validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    worktree-manifest-core)
        if validate_worktree_manifest_core; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"Core worktree manifest validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    worktree-manifest-prd)
        if validate_worktree_manifest_prd; then
            echo '{"valid":true}'
        else
            echo '{"valid":false,"error":"PRD worktree manifest validation failed. Check stderr for details."}'
            exit 1
        fi
        ;;
    *)
        echo "{\"valid\":false,\"error\":\"Unknown schema type: $SCHEMA_TYPE\"}"
        exit 1
        ;;
esac
