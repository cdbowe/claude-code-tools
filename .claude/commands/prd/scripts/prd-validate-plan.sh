#!/bin/bash
# Validates PRD plan JSON structure (wave-based schema)

set -e

PLAN_FILE="${1:-/tmp/.prd_plan.json}"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "{\"status\":\"error\",\"error\":\"Plan file not found: $PLAN_FILE\"}"
  exit 1
fi

# Track validation errors
ERRORS=()

# Required top-level fields
if ! jq -e '.prd' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("Missing required field: prd")
fi
if ! jq -e '.phase' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("Missing required field: phase")
fi
if ! jq -e '.phaseName' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("Missing required field: phaseName")
fi
if ! jq -e '.totalTasks' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("Missing required field: totalTasks")
fi

# Check for forbidden old-schema fields
if jq -e '.parallelAgents' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("FORBIDDEN: found 'parallelAgents' - use wave-based schema with 'waves' array")
fi
if jq -e '.sequentialTasks' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("FORBIDDEN: found 'sequentialTasks' - use wave-based schema with 'waves' array")
fi
if jq -e '.parallelGroups' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("FORBIDDEN: found 'parallelGroups' - use wave-based schema with 'waves' array")
fi

# Validate waves array exists
if ! jq -e '.waves | type == "array"' "$PLAN_FILE" > /dev/null 2>&1; then
  ERRORS+=("Missing required field: waves (array)")
else
  WAVE_COUNT=$(jq '.waves | length' "$PLAN_FILE")

  for ((w=0; w<WAVE_COUNT; w++)); do
    # Check waveId
    if ! jq -e ".waves[$w].waveId | type == \"number\"" "$PLAN_FILE" > /dev/null 2>&1; then
      ERRORS+=("waves[$w]: missing or invalid 'waveId' (must be number)")
    fi

    # Check useWorktrees
    if ! jq -e ".waves[$w].useWorktrees | type == \"boolean\"" "$PLAN_FILE" > /dev/null 2>&1; then
      ERRORS+=("waves[$w]: missing or invalid 'useWorktrees' (must be boolean)")
    fi

    # Check tasks array
    if ! jq -e ".waves[$w].tasks | type == \"array\"" "$PLAN_FILE" > /dev/null 2>&1; then
      ERRORS+=("waves[$w]: missing 'tasks' array")
    else
      TASK_COUNT=$(jq ".waves[$w].tasks | length" "$PLAN_FILE")
      if [[ $TASK_COUNT -gt 0 ]]; then
        # Check first task has required fields
        if ! jq -e ".waves[$w].tasks[0] | type == \"object\"" "$PLAN_FILE" | grep -q true; then
          ERRORS+=("waves[$w].tasks[0]: task must be object, not string")
        fi
        if ! jq -e ".waves[$w].tasks[0].taskId" "$PLAN_FILE" > /dev/null 2>&1; then
          ERRORS+=("waves[$w].tasks[0]: missing 'taskId' field")
        fi
        if ! jq -e ".waves[$w].tasks[0].taskName" "$PLAN_FILE" > /dev/null 2>&1; then
          ERRORS+=("waves[$w].tasks[0]: missing 'taskName' field")
        fi
        if ! jq -e ".waves[$w].tasks[0].taskType" "$PLAN_FILE" > /dev/null 2>&1; then
          ERRORS+=("waves[$w].tasks[0]: missing 'taskType' field")
        fi
        if ! jq -e ".waves[$w].tasks[0].model" "$PLAN_FILE" > /dev/null 2>&1; then
          ERRORS+=("waves[$w].tasks[0]: missing 'model' field")
        fi
      fi

      # Validate useWorktrees logic (should be true if 2+ tasks)
      use_worktrees=$(jq -r ".waves[$w].useWorktrees" "$PLAN_FILE")
      if [[ $TASK_COUNT -ge 2 && "$use_worktrees" != "true" ]]; then
        ERRORS+=("waves[$w]: useWorktrees should be true when 2+ tasks ($TASK_COUNT tasks)")
      fi
    fi
  done
fi

# Report results
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "❌ VALIDATION FAILED: $PLAN_FILE"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  exit 1
else
  echo "✅ VALIDATION PASSED: $PLAN_FILE"
  exit 0
fi
