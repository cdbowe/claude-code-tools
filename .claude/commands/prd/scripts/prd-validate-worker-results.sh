#!/bin/bash
# Validates PRD worker results JSON structure

set -e

RESULTS_FILE="${1}"

if [[ -z "$RESULTS_FILE" ]]; then
  echo "Usage: $0 <results_file>"
  exit 1
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "❌ VALIDATION FAILED: Results file not found: $RESULTS_FILE"
  exit 1
fi

# Track validation errors
ERRORS=()

# Check if file is valid JSON
if ! jq empty "$RESULTS_FILE" 2>/dev/null; then
  echo "❌ VALIDATION FAILED: Invalid JSON in $RESULTS_FILE"
  exit 1
fi

# Required fields
REQUIRED_FIELDS=("agentId" "taskIds" "status" "filesModified" "filesCreated" "notes")

for field in "${REQUIRED_FIELDS[@]}"; do
  if ! jq -e ".$field" "$RESULTS_FILE" > /dev/null 2>&1; then
    ERRORS+=("Missing required field: $field")
  fi
done

# Type validation
if jq -e '.agentId' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.agentId | type == "string"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'agentId' must be string")
  fi
fi

if jq -e '.taskIds' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.taskIds | type == "array"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'taskIds' must be array")
  fi
fi

if jq -e '.status' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.status | type == "string"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'status' must be string")
  else
    # Validate status values
    STATUS=$(jq -r '.status' "$RESULTS_FILE")
    if [[ "$STATUS" != "in_progress" && "$STATUS" != "complete" && "$STATUS" != "blocked" ]]; then
      ERRORS+=("Field 'status' must be 'in_progress', 'complete', or 'blocked', got: $STATUS")
    fi
  fi
fi

if jq -e '.filesModified' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.filesModified | type == "array"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'filesModified' must be array")
  fi
fi

if jq -e '.filesCreated' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.filesCreated | type == "array"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'filesCreated' must be array")
  fi
fi

if jq -e '.notes' "$RESULTS_FILE" > /dev/null 2>&1; then
  if ! jq -e '.notes | type == "string"' "$RESULTS_FILE" | grep -q true; then
    ERRORS+=("Field 'notes' must be string")
  fi
fi

# Blocked status validation
if ! jq -e '.status == "blocked"' "$RESULTS_FILE" | grep -q true; then
  : # Not blocked, skip validation
elif ! jq -e '.blockedTasks' "$RESULTS_FILE" > /dev/null 2>&1; then
  ERRORS+=("Status 'blocked' requires 'blockedTasks' array")
elif ! jq -e '.blockedTasks | type == "array"' "$RESULTS_FILE" | grep -q true; then
  ERRORS+=("Field 'blockedTasks' must be array")
elif [[ $(jq '.blockedTasks | length' "$RESULTS_FILE") -eq 0 ]]; then
  ERRORS+=("Status 'blocked' requires at least one entry in 'blockedTasks'")
else
  # Validate each blockedTask entry
  BLOCKED_COUNT=$(jq '.blockedTasks | length' "$RESULTS_FILE")
  for ((i=0; i<BLOCKED_COUNT; i++)); do
    [[ $(jq -e ".blockedTasks[$i].taskId" "$RESULTS_FILE" 2>/dev/null) ]] || ERRORS+=("blockedTasks[$i]: missing 'taskId' field")

    if ! jq -e ".blockedTasks[$i].reason" "$RESULTS_FILE" > /dev/null 2>&1; then
      ERRORS+=("blockedTasks[$i]: missing 'reason' field")
      continue
    fi

    REASON=$(jq -r ".blockedTasks[$i].reason" "$RESULTS_FILE")
    [[ -z "$REASON" || "$REASON" == "null" ]] && ERRORS+=("blockedTasks[$i]: 'reason' cannot be empty - provide detailed explanation")
  done
fi

# Report results
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "❌ VALIDATION FAILED: $RESULTS_FILE"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  exit 1
else
  echo "✅ VALIDATION PASSED: $RESULTS_FILE"
  exit 0
fi
