#!/bin/bash
# PreToolUse hook: Validates PRD JSON files before Write tool executes
#
# Intercepts Write tool calls to PRD JSON files and validates content
# before allowing the write to complete.
#
# Exit codes:
#   0 - Allow write (validation passed or not a PRD file)
#   2 - Block write (validation failed)

SCRIPTS_DIR="/tmp/claude-shared/commands/prd/scripts"
PRD_BASE="${WORKSPACE_DIR:-/workspaces/bankjet}/claude_files/PRDs"

# Read hook input from stdin
INPUT=$(cat)

# Extract tool name and file path
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')

# Only process Write tool calls
if [[ "$TOOL_NAME" != "Write" ]]; then
    exit 0
fi

# Skip if no file path
if [[ -z "$FILE_PATH" ]]; then
    exit 0
fi

# Check if file is JSON
if [[ "$FILE_PATH" != *.json ]]; then
    exit 0
fi

# Determine if this is a PRD JSON file and what schema type to use
SCHEMA_TYPE=""

# Phase JSON files in PRD directories
if [[ "$FILE_PATH" == "$PRD_BASE"*/phase_*.json ]]; then
    SCHEMA_TYPE="phase-json"
# Temp PRD files
elif [[ "$FILE_PATH" == /tmp/.prd_review.json ]]; then
    SCHEMA_TYPE="review"
elif [[ "$FILE_PATH" == /tmp/.prd_phase_review_*.json ]]; then
    SCHEMA_TYPE="review"
elif [[ "$FILE_PATH" == /tmp/.prd_review_all_compile.json ]]; then
    SCHEMA_TYPE="review-all-compile"
elif [[ "$FILE_PATH" == /tmp/.prd_review_all_findings.json ]]; then
    SCHEMA_TYPE="review-all-findings"
elif [[ "$FILE_PATH" == /tmp/.prd_review_all_edits.json ]]; then
    SCHEMA_TYPE="review-all-edits"
elif [[ "$FILE_PATH" == /tmp/.prd_review_all_report.json ]]; then
    SCHEMA_TYPE="review-all-report"
elif [[ "$FILE_PATH" == /tmp/.prd_plan.json ]]; then
    SCHEMA_TYPE="plan"
elif [[ "$FILE_PATH" == /tmp/.prd_infra_plan.json ]]; then
    SCHEMA_TYPE="plan-infra"
elif [[ "$FILE_PATH" == /tmp/.prd_build.json ]]; then
    SCHEMA_TYPE="build"
elif [[ "$FILE_PATH" == /tmp/.prd_infra_build.json ]]; then
    SCHEMA_TYPE="build-infra"
elif [[ "$FILE_PATH" == /tmp/.prd_edit.json ]]; then
    SCHEMA_TYPE="edit"
elif [[ "$FILE_PATH" == /tmp/.prd_agent_*_results.json ]]; then
    SCHEMA_TYPE="agent-result"
fi

# Skip if not a recognized PRD file
if [[ -z "$SCHEMA_TYPE" ]]; then
    exit 0
fi

# Validate JSON syntax first
if ! echo "$CONTENT" | jq -e '.' > /dev/null 2>&1; then
    cat <<EOF
{
  "decision": "block",
  "reason": "Invalid JSON syntax in PRD file: $FILE_PATH"
}
EOF
    exit 2
fi

# Write content to temp file for validation
TEMP_FILE=$(mktemp)
echo "$CONTENT" > "$TEMP_FILE"

# Validate using existing validation script
VALIDATION_RESULT=$(bash "$SCRIPTS_DIR/prd-validate.sh" "$TEMP_FILE" "$SCHEMA_TYPE" 2>&1)
VALIDATION_EXIT=$?

rm -f "$TEMP_FILE"

if [[ $VALIDATION_EXIT -ne 0 ]]; then
    # Extract error message from validation result
    ERROR_MSG=$(echo "$VALIDATION_RESULT" | jq -r '.error // "Schema validation failed"' 2>/dev/null || echo "Schema validation failed")

    cat <<EOF
{
  "decision": "block",
  "reason": "PRD JSON validation failed ($SCHEMA_TYPE): $ERROR_MSG"
}
EOF
    exit 2
fi

# Validation passed
exit 0
