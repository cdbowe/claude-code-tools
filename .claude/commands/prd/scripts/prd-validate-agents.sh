#!/bin/bash
# PRD Validate Agents Script - Validates all agent result files after build
# Usage: prd-validate-agents.sh
#
# Discovers and validates: /tmp/.prd_agent_W*-T*_results.json (written by workers)
# Supports wave-based agent IDs (W0-T0, W0-T1, W1-T0, etc.)
# This approach is robust across multiple waves - no dependency on orchestrator state
#
# Returns JSON: {"valid":true} or {"valid":false,"error":"...","details":[...]}

set -e

errors=()
details=()
all_valid=true

#------------------------------------------------------------------------------
# Helper: Validate single agent result file
#------------------------------------------------------------------------------
validate_agent_file() {
    local file="$1"

    # Check valid JSON
    if ! jq -e '.' "$file" > /dev/null 2>&1; then
        echo "invalid_json"
        return 1
    fi

    # Check required fields: agentId, status, taskIds, model
    if ! jq -e '.agentId and .status and (.taskIds | type == "array") and .model' "$file" > /dev/null 2>&1; then
        echo "missing_fields"
        return 1
    fi

    # Check status is valid
    local status
    status=$(jq -r '.status' "$file")
    if [[ "$status" != "complete" && "$status" != "blocked" && "$status" != "in_progress" ]]; then
        echo "invalid_status:$status"
        return 1
    fi

    # Check taskIds is non-empty array
    local task_count
    task_count=$(jq '.taskIds | length' "$file")
    if [ "$task_count" -eq 0 ]; then
        echo "empty_taskIds"
        return 1
    fi

    echo "valid"
    return 0
}

#------------------------------------------------------------------------------
# Step 1: Discover agent result files
#------------------------------------------------------------------------------
shopt -s nullglob
agent_files=(/tmp/.prd_agent_W*-T*_results.json)
shopt -u nullglob

if [ ${#agent_files[@]} -eq 0 ]; then
    jq -n '{valid: false, error: "No agent result files found. Workers must write /tmp/.prd_agent_W{wave}-T{task}_results.json", details: []}'
    exit 1
fi

#------------------------------------------------------------------------------
# Step 2: Validate each agent result file
#------------------------------------------------------------------------------
for file in "${agent_files[@]}"; do
    # Extract expected agent ID from filename
    # Pattern: .prd_agent_W{wave}-T{task}_results.json
    # Supports: W0-T0, W0-T1, W1-T0, etc.
    filename=$(basename "$file")
    agent_id=$(echo "$filename" | sed -n 's/^\.prd_agent_\(W[0-9]*-T[0-9]*\)_results\.json$/\1/p')

    if [ -z "$agent_id" ]; then
        all_valid=false
        details+=("{\"file\":\"$file\",\"error\":\"cannot_parse_agentId_from_filename\"}")
        continue
    fi

    result=$(validate_agent_file "$file")

    if [ "$result" != "valid" ]; then
        all_valid=false
        details+=("{\"agentId\":\"$agent_id\",\"file\":\"$file\",\"error\":\"$result\"}")
    else
        # Verify agentId in file matches filename
        file_agent_id=$(jq -r '.agentId' "$file")
        if [ "$file_agent_id" != "$agent_id" ]; then
            all_valid=false
            details+=("{\"agentId\":\"$agent_id\",\"file\":\"$file\",\"error\":\"agentId_mismatch:filename=$agent_id,content=$file_agent_id\"}")
        fi
    fi
done

#------------------------------------------------------------------------------
# Step 3: Output result
#------------------------------------------------------------------------------
agent_count=${#agent_files[@]}

if [ "$all_valid" = true ]; then
    jq -n --argjson count "$agent_count" \
        '{valid: true, agentCount: $count, message: "All agent result files validated successfully"}'
else
    # Build details array
    details_json="["
    first=true
    for d in "${details[@]}"; do
        if [ "$first" = true ]; then
            details_json+="$d"
            first=false
        else
            details_json+=",$d"
        fi
    done
    details_json+="]"

    jq -n --argjson details "$details_json" \
        '{valid: false, error: "Agent result validation failed", details: $details}'
    exit 1
fi
