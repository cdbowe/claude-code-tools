#!/bin/bash
# Validates PRD phase JSON file structure

set -e

PHASE_FILE="${1}"

if [[ -z "$PHASE_FILE" ]]; then
  echo "Usage: $0 <phase_file>"
  exit 1
fi

if [[ ! -f "$PHASE_FILE" ]]; then
  echo "❌ VALIDATION FAILED: Phase file not found: $PHASE_FILE"
  exit 1
fi

# Track validation errors
ERRORS=()

# Check if file is valid JSON
if ! jq empty "$PHASE_FILE" 2>/dev/null; then
  echo "❌ VALIDATION FAILED: Invalid JSON in $PHASE_FILE"
  exit 1
fi

# Check if this is an infrastructure phase
IS_INFRA=$(jq -r '.isInfrastructure // false' "$PHASE_FILE")
PHASE_ID=$(jq -r '.phaseId' "$PHASE_FILE")

# Required top-level fields (designPatternInstructions optional for infrastructure)
if [[ "$IS_INFRA" == "true" ]] || [[ "$PHASE_ID" == "0" ]]; then
  REQUIRED_FIELDS=("phaseId" "phaseName" "tasks")
else
  REQUIRED_FIELDS=("phaseId" "phaseName" "tasks" "designPatternInstructions")
fi

for field in "${REQUIRED_FIELDS[@]}"; do
  if ! jq -e ".$field" "$PHASE_FILE" > /dev/null 2>&1; then
    ERRORS+=("Missing required field: $field")
  fi
done

# Type validation for top-level fields
# phaseId can be number or string (phase 0 uses "0" as string in review outputs)
if jq -e '.phaseId' "$PHASE_FILE" > /dev/null 2>&1; then
  PHASE_ID_TYPE=$(jq -r '.phaseId | type' "$PHASE_FILE")
  if [[ "$PHASE_ID_TYPE" != "number" && "$PHASE_ID_TYPE" != "string" ]]; then
    ERRORS+=("Field 'phaseId' must be number or string")
  fi
fi

if jq -e '.phaseName' "$PHASE_FILE" > /dev/null 2>&1; then
  if ! jq -e '.phaseName | type == "string"' "$PHASE_FILE" | grep -q true; then
    ERRORS+=("Field 'phaseName' must be string")
  fi
fi

if jq -e '.description' "$PHASE_FILE" > /dev/null 2>&1; then
  if ! jq -e '.description | type == "string"' "$PHASE_FILE" | grep -q true; then
    ERRORS+=("Field 'description' must be string")
  fi
fi

# Validate designPatternInstructions is a non-empty string
if jq -e '.designPatternInstructions' "$PHASE_FILE" > /dev/null 2>&1; then
  if ! jq -e '.designPatternInstructions | type == "string"' "$PHASE_FILE" | grep -q true; then
    ERRORS+=("Field 'designPatternInstructions' must be string")
  else
    DPI_LEN=$(jq -r '.designPatternInstructions | length' "$PHASE_FILE")
    if [[ $DPI_LEN -lt 10 ]]; then
      ERRORS+=("Field 'designPatternInstructions' must contain meaningful instructions (min 10 chars)")
    fi
  fi
fi

if jq -e '.priority' "$PHASE_FILE" > /dev/null 2>&1; then
  PRIORITY=$(jq -r '.priority' "$PHASE_FILE")
  if [[ "$PRIORITY" != "high" && "$PRIORITY" != "medium" && "$PRIORITY" != "low" ]]; then
    ERRORS+=("Field 'priority' must be 'high', 'medium', or 'low', got: $PRIORITY")
  fi
fi

# Validate tasks array
if jq -e '.tasks' "$PHASE_FILE" > /dev/null 2>&1; then
  if ! jq -e '.tasks | type == "array"' "$PHASE_FILE" | grep -q true; then
    ERRORS+=("Field 'tasks' must be array")
  else
    TASK_COUNT=$(jq '.tasks | length' "$PHASE_FILE")

    if [[ $TASK_COUNT -eq 0 ]]; then
      ERRORS+=("Phase must have at least one task")
    fi

    # Validate each task
    for ((i=0; i<TASK_COUNT; i++)); do
      # Required task fields
      TASK_REQUIRED=("taskId" "taskName" "taskType" "taskStatus")
      for field in "${TASK_REQUIRED[@]}"; do
        if ! jq -e ".tasks[$i].$field" "$PHASE_FILE" > /dev/null 2>&1; then
          ERRORS+=("tasks[$i]: Missing required field '$field'")
        fi
      done

      # Check for forbidden field names
      if jq -e ".tasks[$i] | has(\"title\")" "$PHASE_FILE" | grep -q true; then
        ERRORS+=("tasks[$i]: FORBIDDEN field 'title' - must use 'taskName'")
      fi

      if jq -e ".tasks[$i] | has(\"name\")" "$PHASE_FILE" | grep -q true; then
        ERRORS+=("tasks[$i]: FORBIDDEN field 'name' - must use 'taskName'")
      fi

      if jq -e ".tasks[$i] | has(\"targetFile\")" "$PHASE_FILE" | grep -q true; then
        ERRORS+=("tasks[$i]: FORBIDDEN field 'targetFile' (singular) - must use 'targetFiles' (array)")
      fi

      # Validate dependsOn references exist in same phase (intra-phase only, no cross-phase)
      if jq -e ".tasks[$i].dependsOn" "$PHASE_FILE" > /dev/null 2>&1; then
        if ! jq -e ".tasks[$i].dependsOn | type == \"array\"" "$PHASE_FILE" | grep -q true; then
          ERRORS+=("tasks[$i]: Field 'dependsOn' must be array")
        else
          TASK_ID_FOR_DEP=$(jq -r ".tasks[$i].taskId" "$PHASE_FILE")
          DEP_COUNT=$(jq ".tasks[$i].dependsOn | length" "$PHASE_FILE")
          for ((d=0; d<DEP_COUNT; d++)); do
            DEP_ID=$(jq -r ".tasks[$i].dependsOn[$d]" "$PHASE_FILE")
            if ! jq -e "[.tasks[].taskId] | index(\"$DEP_ID\")" "$PHASE_FILE" | grep -q -v null; then
              ERRORS+=("tasks[$i] ($TASK_ID_FOR_DEP): dependsOn '$DEP_ID' not found in this phase — cross-phase dependencies are forbidden")
            fi
          done
        fi
      fi

      # Validate taskType
      if jq -e ".tasks[$i].taskType" "$PHASE_FILE" > /dev/null 2>&1; then
        TASK_TYPE=$(jq -r ".tasks[$i].taskType" "$PHASE_FILE")
        VALID_TYPES=("create-file" "edit-file" "refactor" "verify" "rename" "delete-file" "generate-test")
        VALID=0
        for vtype in "${VALID_TYPES[@]}"; do
          if [[ "$TASK_TYPE" == "$vtype" ]]; then
            VALID=1
            break
          fi
        done
        if [[ $VALID -eq 0 ]]; then
          ERRORS+=("tasks[$i]: Invalid taskType '$TASK_TYPE' - must be one of: ${VALID_TYPES[*]}")
        fi

        # Validate preValidation for generate-test tasks
        if [[ "$TASK_TYPE" == "generate-test" ]]; then
          TASK_STATUS=$(jq -r ".tasks[$i].taskStatus" "$PHASE_FILE")

          # Guard: Skip validation for Skipped tasks
          [[ "$TASK_STATUS" == "Skipped" ]] && continue

          # preValidation is required for generate-test tasks
          if ! jq -e ".tasks[$i].preValidation" "$PHASE_FILE" > /dev/null 2>&1; then
            ERRORS+=("tasks[$i]: taskType 'generate-test' requires 'preValidation' object")
          else
            # Validate preValidation structure (must have at least one check)
            PV_KEYS=$(jq -r ".tasks[$i].preValidation | keys | length" "$PHASE_FILE")
            if [[ "$PV_KEYS" -lt 1 ]]; then
              ERRORS+=("tasks[$i].preValidation: Must contain at least one validation check")
            fi
          fi

          # referenceFiles recommended for generate-test tasks
          if ! jq -e ".tasks[$i].referenceFiles | length > 0" "$PHASE_FILE" 2>/dev/null | grep -q true; then
            # This is a warning, not an error - but we'll skip adding to ERRORS for now
            # Could be upgraded to ERRORS if strictness is desired
            :
          fi

          # Validate postValidation structure (optional but validated if present)
          # Guard: Skip if no postValidation (optional field)
          HAS_POST_V=$(jq -e ".tasks[$i].postValidation" "$PHASE_FILE" > /dev/null 2>&1 && echo "1" || echo "0")
          if [[ "$HAS_POST_V" == "1" ]]; then
            POST_V_TYPE=$(jq -r ".tasks[$i].postValidation | type" "$PHASE_FILE")
            # Guard: Must be an object
            [[ "$POST_V_TYPE" != "object" ]] && ERRORS+=("tasks[$i].postValidation: Must be an object, got '$POST_V_TYPE'") && continue

            # Guard: Must have at least one check
            POST_V_KEYS=$(jq -r ".tasks[$i].postValidation | keys | length" "$PHASE_FILE")
            [[ "$POST_V_KEYS" -lt 1 ]] && ERRORS+=("tasks[$i].postValidation: Must contain at least one validation check")
          fi
        fi

        # Validate fileStructureDetails for create-file tasks (using guard clauses)
        if [[ "$TASK_TYPE" == "create-file" ]]; then
          TASK_STATUS=$(jq -r ".tasks[$i].taskStatus" "$PHASE_FILE")

          # Guard: Skip validation for Skipped tasks
          [[ "$TASK_STATUS" == "Skipped" ]] && continue

          # Guard: fileStructureDetails must exist
          if ! jq -e ".tasks[$i].fileStructureDetails" "$PHASE_FILE" > /dev/null 2>&1; then
            ERRORS+=("tasks[$i]: taskType 'create-file' requires 'fileStructureDetails' object")
            continue
          fi

          # Validate language field
          FSD_LANG=$(jq -r ".tasks[$i].fileStructureDetails.language // \"\"" "$PHASE_FILE")
          [[ -z "$FSD_LANG" || "$FSD_LANG" == "null" ]] && \
            ERRORS+=("tasks[$i].fileStructureDetails: Missing or empty required field 'language'")

          # Guard: structure object must exist
          if ! jq -e ".tasks[$i].fileStructureDetails.structure" "$PHASE_FILE" > /dev/null 2>&1; then
            ERRORS+=("tasks[$i].fileStructureDetails: Missing required field 'structure'")
            continue
          fi

          # Guard: structure.members must exist and be array
          if ! jq -e ".tasks[$i].fileStructureDetails.structure.members | type == \"array\"" "$PHASE_FILE" | grep -q true; then
            ERRORS+=("tasks[$i].fileStructureDetails.structure: Missing or invalid 'members' array")
            continue
          fi

          # Validate each member
          MEMBER_COUNT=$(jq ".tasks[$i].fileStructureDetails.structure.members | length" "$PHASE_FILE")
          for ((m=0; m<MEMBER_COUNT; m++)); do
            MEMBER_PREFIX="tasks[$i].fileStructureDetails.structure.members[$m]"

            jq -e ".tasks[$i].fileStructureDetails.structure.members[$m].type" "$PHASE_FILE" > /dev/null 2>&1 || \
              ERRORS+=("$MEMBER_PREFIX: Missing required field 'type'")

            jq -e ".tasks[$i].fileStructureDetails.structure.members[$m].name" "$PHASE_FILE" > /dev/null 2>&1 || \
              ERRORS+=("$MEMBER_PREFIX: Missing required field 'name'")

            jq -e ".tasks[$i].fileStructureDetails.structure.members[$m].description" "$PHASE_FILE" > /dev/null 2>&1 || \
              ERRORS+=("$MEMBER_PREFIX: Missing required field 'description'")
          done
        fi
      fi

      # Validate taskStatus
      if jq -e ".tasks[$i].taskStatus" "$PHASE_FILE" > /dev/null 2>&1; then
        TASK_STATUS=$(jq -r ".tasks[$i].taskStatus" "$PHASE_FILE")
        VALID_STATUSES=("Pending" "Complete" "InProgress" "Blocked" "NeedsClarification" "Skipped")
        VALID=0
        for vstatus in "${VALID_STATUSES[@]}"; do
          if [[ "$TASK_STATUS" == "$vstatus" ]]; then
            VALID=1
            break
          fi
        done
        if [[ $VALID -eq 0 ]]; then
          ERRORS+=("tasks[$i]: Invalid taskStatus '$TASK_STATUS' - must be one of: ${VALID_STATUSES[*]}")
        fi

        # Check for common mistake
        if [[ "$TASK_STATUS" == "Not Started" ]]; then
          ERRORS+=("tasks[$i]: taskStatus 'Not Started' is invalid - use 'Pending'")
        fi

        # Require blockReason for Blocked or NeedsClarification status
        if [[ "$TASK_STATUS" == "Blocked" || "$TASK_STATUS" == "NeedsClarification" ]]; then
          if ! jq -e ".tasks[$i].blockReason" "$PHASE_FILE" > /dev/null 2>&1; then
            ERRORS+=("tasks[$i]: Status '$TASK_STATUS' requires 'blockReason' field")
          else
            BLOCK_REASON=$(jq -r ".tasks[$i].blockReason" "$PHASE_FILE")
            [[ -z "$BLOCK_REASON" || "$BLOCK_REASON" == "null" ]] && ERRORS+=("tasks[$i]: 'blockReason' cannot be empty for status '$TASK_STATUS'")
          fi
        fi

        # Require skipReason for Skipped status
        if [[ "$TASK_STATUS" == "Skipped" ]]; then
          if ! jq -e ".tasks[$i].skipReason" "$PHASE_FILE" > /dev/null 2>&1; then
            ERRORS+=("tasks[$i]: Status 'Skipped' requires 'skipReason' field")
          else
            SKIP_REASON=$(jq -r ".tasks[$i].skipReason" "$PHASE_FILE")
            [[ -z "$SKIP_REASON" || "$SKIP_REASON" == "null" ]] && ERRORS+=("tasks[$i]: 'skipReason' cannot be empty for status 'Skipped'")
          fi
        fi
      fi

      # Validate targetFiles is array
      if jq -e ".tasks[$i].targetFiles" "$PHASE_FILE" > /dev/null 2>&1; then
        if ! jq -e ".tasks[$i].targetFiles | type == \"array\"" "$PHASE_FILE" | grep -q true; then
          ERRORS+=("tasks[$i]: Field 'targetFiles' must be array")
        fi
      fi


      # Validate acceptanceCriteria is array
      if jq -e ".tasks[$i].acceptanceCriteria" "$PHASE_FILE" > /dev/null 2>&1; then
        if ! jq -e ".tasks[$i].acceptanceCriteria | type == \"array\"" "$PHASE_FILE" | grep -q true; then
          ERRORS+=("tasks[$i]: Field 'acceptanceCriteria' must be array")
        fi
      fi

      # Infrastructure-specific validations
      if [[ "$IS_INFRA" == "true" ]] || [[ "$PHASE_ID" == "0" ]]; then
        # Validate taskCategory for infrastructure tasks
        if jq -e ".tasks[$i].taskCategory" "$PHASE_FILE" > /dev/null 2>&1; then
          TASK_CATEGORY=$(jq -r ".tasks[$i].taskCategory" "$PHASE_FILE")
          VALID_CATEGORIES=("Project Setup" "Fixtures" "Helpers" "Base Classes" "Sample Tests")
          VALID=0
          for vcat in "${VALID_CATEGORIES[@]}"; do
            if [[ "$TASK_CATEGORY" == "$vcat" ]]; then
              VALID=1
              break
            fi
          done
          if [[ $VALID -eq 0 ]]; then
            ERRORS+=("tasks[$i]: Invalid taskCategory '$TASK_CATEGORY' - must be one of: ${VALID_CATEGORIES[*]}")
          fi
        fi

        # Validate referenceFiles is array if present
        if jq -e ".tasks[$i].referenceFiles" "$PHASE_FILE" > /dev/null 2>&1; then
          if ! jq -e ".tasks[$i].referenceFiles | type == \"array\"" "$PHASE_FILE" | grep -q true; then
            ERRORS+=("tasks[$i]: Field 'referenceFiles' must be array")
          fi
        fi
      fi
    done
  fi
fi

# Report results
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "❌ VALIDATION FAILED: $PHASE_FILE"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  - $err"
  done
  exit 1
else
  echo "✅ VALIDATION PASSED: $PHASE_FILE"
  exit 0
fi
