#!/bin/bash
# Validates PRD unblock plan JSON structure (v2 - resolutionTasks schema)

set -e

PLAN_FILE="${1:-/tmp/.prd_unblock_plan.json}"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "❌ VALIDATION FAILED: Unblock plan file not found: $PLAN_FILE"
  exit 1
fi

# Check if file is valid JSON
if ! jq empty "$PLAN_FILE" 2>/dev/null; then
  echo "❌ VALIDATION FAILED: Invalid JSON in $PLAN_FILE"
  exit 1
fi

# Track validation errors
ERRORS=()

# Required top-level fields (new schema)
for field in prd phase phaseName blockedTasks resolutionTasks; do
  jq -e ".$field" "$PLAN_FILE" > /dev/null 2>&1 || ERRORS+=("Missing required field: $field")
done

# Check for FORBIDDEN old schema fields
jq -e '.sequentialTasks' "$PLAN_FILE" > /dev/null 2>&1 && ERRORS+=("FORBIDDEN: found 'sequentialTasks', use 'resolutionTasks' array")
jq -e '.parallelGroups' "$PLAN_FILE" > /dev/null 2>&1 && ERRORS+=("FORBIDDEN: found 'parallelGroups', use 'resolutionTasks' array")
jq -e '.parallelAgents' "$PLAN_FILE" > /dev/null 2>&1 && ERRORS+=("FORBIDDEN: found 'parallelAgents', use 'resolutionTasks' array")
jq -e '.waves' "$PLAN_FILE" > /dev/null 2>&1 && ERRORS+=("FORBIDDEN: found 'waves', compile script creates waves from resolutionTasks")

# Validate blockedTasks array
if jq -e '.blockedTasks | type == "array"' "$PLAN_FILE" | grep -q true; then
  BLOCKED_COUNT=$(jq '.blockedTasks | length' "$PLAN_FILE")
  for ((i=0; i<BLOCKED_COUNT; i++)); do
    jq -e ".blockedTasks[$i].taskId" "$PLAN_FILE" > /dev/null 2>&1 || ERRORS+=("blockedTasks[$i]: missing 'taskId'")
    jq -e ".blockedTasks[$i].taskName" "$PLAN_FILE" > /dev/null 2>&1 || ERRORS+=("blockedTasks[$i]: missing 'taskName'")
    jq -e ".blockedTasks[$i].blockReason" "$PLAN_FILE" > /dev/null 2>&1 || ERRORS+=("blockedTasks[$i]: missing 'blockReason'")
    jq -e ".blockedTasks[$i].status" "$PLAN_FILE" > /dev/null 2>&1 || ERRORS+=("blockedTasks[$i]: missing 'status'")
  done
fi

# Validate resolutionTasks array
if jq -e '.resolutionTasks | type == "array"' "$PLAN_FILE" | grep -q true; then
  TASK_COUNT=$(jq '.resolutionTasks | length' "$PLAN_FILE")

  if [[ $TASK_COUNT -eq 0 ]]; then
    ERRORS+=("resolutionTasks array cannot be empty")
  fi

  for ((i=0; i<TASK_COUNT; i++)); do
    # Check task is object not string
    if ! jq -e ".resolutionTasks[$i] | type == \"object\"" "$PLAN_FILE" | grep -q true; then
      ERRORS+=("resolutionTasks[$i]: must be object, not string")
      continue
    fi

    # Required task fields
    jq -e ".resolutionTasks[$i].taskId" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'taskId'")
    jq -e ".resolutionTasks[$i].taskName" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'taskName'")
    jq -e ".resolutionTasks[$i].taskType" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'taskType'")
    jq -e ".resolutionTasks[$i].model" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'model'")
    jq -e ".resolutionTasks[$i].originalBlockedTask" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'originalBlockedTask'")
    jq -e ".resolutionTasks[$i].resolution" "$PLAN_FILE" > /dev/null 2>&1 || \
      ERRORS+=("resolutionTasks[$i]: missing 'resolution'")

    # dependsOn must be array (can be empty)
    if ! jq -e ".resolutionTasks[$i].dependsOn | type == \"array\"" "$PLAN_FILE" | grep -q true; then
      ERRORS+=("resolutionTasks[$i]: 'dependsOn' must be array (can be empty [])")
    fi

    # Validate the tier alias, not the model string. `model` now carries the
    # concrete version resolved from prd-models.json (e.g. claude-sonnet-5[1m]),
    # so the old haiku|sonnet|opus check belongs on modelTier instead. A plan
    # that predates modelTier falls back to checking model against the aliases.
    MODEL_TIER=$(jq -r ".resolutionTasks[$i].modelTier // \"\"" "$PLAN_FILE")
    if [[ -z "$MODEL_TIER" ]]; then
      MODEL=$(jq -r ".resolutionTasks[$i].model // \"\"" "$PLAN_FILE")
      case "$MODEL" in
        ""|haiku|sonnet|opus|claude-*) ;;
        *) ERRORS+=("resolutionTasks[$i]: model must be a tier alias or a claude-* version, got '$MODEL'") ;;
      esac
    elif [[ "$MODEL_TIER" != "haiku" && "$MODEL_TIER" != "sonnet" && "$MODEL_TIER" != "opus" ]]; then
      ERRORS+=("resolutionTasks[$i]: modelTier must be 'haiku', 'sonnet', or 'opus', got '$MODEL_TIER'")
    fi

    # Validate taskId format (UNBLOCK-X.Y or RETRY-X.Y)
    TASK_ID=$(jq -r ".resolutionTasks[$i].taskId // \"\"" "$PLAN_FILE")
    if [[ -n "$TASK_ID" && ! "$TASK_ID" =~ ^(UNBLOCK|RETRY)- ]]; then
      ERRORS+=("resolutionTasks[$i]: taskId must start with 'UNBLOCK-' or 'RETRY-', got '$TASK_ID'")
    fi
  done
else
  ERRORS+=("resolutionTasks must be an array")
fi

# Report results
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "❌ VALIDATION FAILED: $PLAN_FILE"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  exit 1
fi

echo "✅ VALIDATION PASSED: $PLAN_FILE"
exit 0
