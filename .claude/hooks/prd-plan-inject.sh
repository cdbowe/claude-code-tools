#!/bin/bash
# prd-plan-inject.sh - Intercept /prd plan, output directly to transcript
#
# UserPromptSubmit hook that runs the plan scripts and outputs directly to stdout.
# Output appears in the transcript immediately - no LLM passthrough needed.

set -e

SCRIPTS_DIR=/tmp/claude-shared/commands/prd/scripts

# Read hook input from stdin
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // .user_prompt // ""')

# Check if this is a /prd plan command
# Match: /prd plan (with optional trailing args like max-tasks)
# Note: regex also matches legacy /prd-v2 plan for backward compatibility
if [[ "$PROMPT" =~ ^/prd(-v2)?[[:space:]]+plan([[:space:]]|$) ]]; then
    # Extract optional argument (max tasks per wave)
    MAX_TASKS=""
    if [[ "$PROMPT" =~ plan[[:space:]]+([0-9]+) ]]; then
        MAX_TASKS="${BASH_REMATCH[1]}"
    fi

    # Run the plan script
    PLAN_RESULT=$("$SCRIPTS_DIR/prd-plan.sh" $MAX_TASKS 2>&1)
    PLAN_EXIT=$?

    if [[ $PLAN_EXIT -ne 0 ]]; then
        # Script failed - output error directly
        echo "Error: $PLAN_RESULT"
        exit 0
    fi

    # Check for error status in JSON output
    if echo "$PLAN_RESULT" | jq -e '.status == "error"' >/dev/null 2>&1; then
        ERROR_MSG=$(echo "$PLAN_RESULT" | jq -r '.error // "Unknown error"')
        echo "Error: $ERROR_MSG"
        exit 0
    fi

    # Validate the plan
    VALIDATE_RESULT=$("$SCRIPTS_DIR/prd-validate.sh" /tmp/.prd_plan.json plan 2>&1)
    if ! echo "$VALIDATE_RESULT" | jq -e '.valid == true' >/dev/null 2>&1; then
        echo "Plan validation failed: $VALIDATE_RESULT"
        exit 0
    fi

    # Generate display output and write to file for skill passthrough
    "$SCRIPTS_DIR/prd-display.sh" plan /tmp/.prd_plan.json > /tmp/.prd_plan_display.txt 2>&1

    # Also output to stdout for hook transcript (may or may not be visible)
    cat /tmp/.prd_plan_display.txt
    exit 0
fi

# Not a /prd plan command - no output, allow normal processing
exit 0
