#!/bin/bash
# PRD Build Compile Script - Compiles wave-based worker specs from plan JSON
# Usage: prd-build-compile.sh
# Requires: /tmp/.prd_plan.json (from prd-plan agent)

set -e

# Validate WORKSPACE_DIR is set and valid
if [ -z "$WORKSPACE_DIR" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi
if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "{\"status\":\"error\",\"error\":\"WORKSPACE_DIR does not exist: $WORKSPACE_DIR\"}"
    exit 1
fi

STATE_FILE="/tmp/.prd_state"
PLAN_FILE="/tmp/.prd_plan.json"
OUTPUT_FILE="/tmp/.prd_build.json"
PRD_BASE="$WORKSPACE_DIR/claude_files/PRDs"
WORKSPACE_ROOT="$WORKSPACE_DIR"

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi
source "$STATE_FILE"

if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi

if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "none" ]; then
    echo '{"status":"error","error":"No phase loaded. Run /prd read <phase> first."}'
    exit 1
fi

# Verify plan exists
if [ ! -f "$PLAN_FILE" ]; then
    echo '{"status":"error","error":"Plan not found. Run /prd plan first."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Read AGENT_CONTEXT or fall back to ROOT
CONTEXT_FILE="$PRD_DIR/AGENT_CONTEXT.md"
if [ ! -f "$CONTEXT_FILE" ]; then
    CONTEXT_FILE="$PRD_DIR/00_ROOT.md"
fi
AGENT_CONTEXT=$(cat "$CONTEXT_FILE")

# Read DESIGN_REFERENCE if it exists
DESIGN_REF_FILE="$PRD_DIR/DESIGN_REFERENCE.md"
if [ -f "$DESIGN_REF_FILE" ]; then
    DESIGN_REFERENCE=$(cat "$DESIGN_REF_FILE")
else
    DESIGN_REFERENCE=""
fi

# Get phase file from state (preferred) or fall back to plan
if [ -n "$PHASE_JSON_FILE" ] && [ -f "$PHASE_JSON_FILE" ]; then
    PHASE_PATH="$PHASE_JSON_FILE"
else
    # Fallback: get from plan
    PHASE_FILE=$(jq -r '.phaseFile // empty' "$PLAN_FILE")
    if [ -n "$PHASE_FILE" ]; then
        PHASE_PATH="$PRD_DIR/$PHASE_FILE"
    else
        echo '{"status":"error","error":"Phase file path not found"}'
        exit 1
    fi
fi

if [ ! -f "$PHASE_PATH" ]; then
    echo "{\"status\":\"error\",\"error\":\"Phase file not found: $PHASE_PATH\"}"
    exit 1
fi

# Read phase JSON
PHASE_JSON=$(cat "$PHASE_PATH")

# Build waves array with compiled agents
compiled_waves="[]"

#------------------------------------------------------------------------------
# Process each wave
#------------------------------------------------------------------------------
wave_count=$(jq '.waves | length' "$PLAN_FILE")

for ((w=0; w<wave_count; w++)); do
    wave=$(jq ".waves[$w]" "$PLAN_FILE")
    wave_id=$(echo "$wave" | jq -r '.waveId')
    use_worktrees=$(echo "$wave" | jq -r '.useWorktrees')

    wave_agents="[]"
    task_count=$(echo "$wave" | jq '.tasks | length')

    for ((t=0; t<task_count; t++)); do
        task_spec=$(echo "$wave" | jq ".tasks[$t]")
        task_id=$(echo "$task_spec" | jq -r '.taskId')
        task_name=$(echo "$task_spec" | jq -r '.taskName')
        task_type=$(echo "$task_spec" | jq -r '.taskType')
        model=$(echo "$task_spec" | jq -r '.model')
        # Strip 'main/' prefix from target files - agents work in worktrees with relative paths
        target_files=$(echo "$task_spec" | jq -c '.targetFiles | map(if startswith("main/") then .[5:] else . end)')

        # Generate agent ID based on wave and task index
        agent_id="W${wave_id}-T${t}"

        # Get full task details from phase JSON
        task=$(echo "$PHASE_JSON" | jq --arg id "$task_id" '.tasks[] | select(.taskId == $id)')
        task_desc=$(echo "$task" | jq -r '.description // .taskDescription // "No description"')
        acceptance=$(echo "$task" | jq -r '.acceptanceCriteria // [] | map("- " + .) | join("\n")')
        agent_hint=$(echo "$task" | jq -r '.agentHint // empty')

        # Extract test details if present
        test_details=""
        if echo "$task" | jq -e '.test' >/dev/null 2>&1; then
            test_method=$(echo "$task" | jq -r '.test.testMethod // "N/A"')
            test_details="
**Test Details**:
- Test Method: $test_method"
        fi

        # Extract fileStructureDetails for create-file tasks
        file_structure_section=""
        if [[ "$task_type" == "create-file" ]] && echo "$task" | jq -e '.fileStructureDetails' >/dev/null 2>&1; then
            fsd_language=$(echo "$task" | jq -r '.fileStructureDetails.language // "unknown"')
            fsd_template=$(echo "$task" | jq -r '.fileStructureDetails.templateReference // "none"')
            fsd_namespace=$(echo "$task" | jq -r '.fileStructureDetails.structure.namespace // ""')
            fsd_classname=$(echo "$task" | jq -r '.fileStructureDetails.structure.className // ""')
            fsd_baseclass=$(echo "$task" | jq -r '.fileStructureDetails.structure.baseClass // ""')
            fsd_notes=$(echo "$task" | jq -r '.fileStructureDetails.notes // ""')

            # Build imports list
            fsd_imports=""
            if echo "$task" | jq -e '.fileStructureDetails.structure.imports | length > 0' >/dev/null 2>&1; then
                fsd_imports=$(echo "$task" | jq -r '.fileStructureDetails.structure.imports | map("  - " + .) | join("\n")')
            fi

            # Build interfaces list
            fsd_interfaces=""
            if echo "$task" | jq -e '.fileStructureDetails.structure.interfaces | length > 0' >/dev/null 2>&1; then
                fsd_interfaces=$(echo "$task" | jq -r '.fileStructureDetails.structure.interfaces | join(", ")')
            fi

            # Build members list
            fsd_members=""
            if echo "$task" | jq -e '.fileStructureDetails.structure.members | length > 0' >/dev/null 2>&1; then
                while IFS= read -r member_json; do
                    m_type=$(echo "$member_json" | jq -r '.type')
                    m_name=$(echo "$member_json" | jq -r '.name')
                    m_sig=$(echo "$member_json" | jq -r '.signature // ""')
                    m_desc=$(echo "$member_json" | jq -r '.description')
                    if [[ -n "$m_sig" && "$m_sig" != "null" ]]; then
                        fsd_members+="
  - **$m_type** \`$m_name\`: $m_desc
    - Signature: \`$m_sig\`"
                    else
                        fsd_members+="
  - **$m_type** \`$m_name\`: $m_desc"
                    fi
                done < <(echo "$task" | jq -c '.fileStructureDetails.structure.members[]')
            fi

            file_structure_section="
## File Structure Specification

**Language**: $fsd_language
**Template Reference**: $fsd_template"

            if [[ -n "$fsd_namespace" && "$fsd_namespace" != "null" ]]; then
                file_structure_section+="
**Namespace/Module**: $fsd_namespace"
            fi

            if [[ -n "$fsd_classname" && "$fsd_classname" != "null" ]]; then
                file_structure_section+="
**Class/Type Name**: $fsd_classname"
            fi

            if [[ -n "$fsd_baseclass" && "$fsd_baseclass" != "null" ]]; then
                file_structure_section+="
**Base Class**: $fsd_baseclass"
            fi

            if [[ -n "$fsd_interfaces" && "$fsd_interfaces" != "null" ]]; then
                file_structure_section+="
**Interfaces**: $fsd_interfaces"
            fi

            if [[ -n "$fsd_imports" ]]; then
                file_structure_section+="

**Required Imports**:
$fsd_imports"
            fi

            if [[ -n "$fsd_members" ]]; then
                file_structure_section+="

**Members to Implement**:$fsd_members"
            fi

            if [[ -n "$fsd_notes" && "$fsd_notes" != "null" ]]; then
                file_structure_section+="

**Implementation Notes**: $fsd_notes"
            fi
        fi

        # Extract verification steps if present
        verify_steps=""
        if echo "$task" | jq -e '.verificationSteps | length > 0' >/dev/null 2>&1; then
            verify_steps="
**Verification Steps**:"
            while IFS= read -r step; do
                verify_steps+="
- $step"
            done < <(echo "$task" | jq -r '.verificationSteps[]? | .step')
        fi

        # Extract preValidation if present
        pre_validation=""
        if echo "$task" | jq -e '.preValidation | length > 0' >/dev/null 2>&1; then
            pre_validation="
## Pre-Validation (BEFORE Implementation)

**Complete these checks BEFORE writing any code:**
"
            while IFS= read -r key; do
                value=$(echo "$task" | jq -r ".preValidation[\"$key\"]")
                pre_validation+="
- **$key**: $value"
            done < <(echo "$task" | jq -r '.preValidation | keys[]')
        fi

        # Extract postValidation if present
        post_validation=""
        if echo "$task" | jq -e '.postValidation | length > 0' >/dev/null 2>&1; then
            post_validation="
## Post-Validation (AFTER Implementation - MANDATORY)

**Complete these checks AFTER implementation, BEFORE marking task complete:**
"
            while IFS= read -r key; do
                value=$(echo "$task" | jq -r ".postValidation[\"$key\"]")
                post_validation+="
- **$key**: $value"
            done < <(echo "$task" | jq -r '.postValidation | keys[]')
            post_validation+="

⚠️ **Do NOT mark task complete until all post-validation checks pass.**"
        fi

        # Build worktree setup block if this wave uses worktrees
        worktree_setup=""
        worktree_commit=""
        worktree_name=""
        branch_name=""

        if [ "$use_worktrees" = "true" ]; then
            worktree_name="wt-prd-${CURRENT_PHASE}-${agent_id}"
            branch_name="prd/phase-${CURRENT_PHASE}/${agent_id}"

            worktree_setup="
## Worktree Setup (EXECUTE FIRST)

\`\`\`bash
WORKSPACE_ROOT=\"${WORKSPACE_ROOT}\"
WORKTREE_NAME=\"${worktree_name}\"
WORKTREE_DIR=\"\$WORKSPACE_ROOT/worktrees/\$WORKTREE_NAME\"
BRANCH_NAME=\"${branch_name}\"

# Ensure worktrees directory exists
mkdir -p \"\$WORKSPACE_ROOT/worktrees\"

# Create worktree from main
cd \"\$WORKSPACE_ROOT/main\"
git worktree add \"\$WORKTREE_DIR\" -b \"\$BRANCH_NAME\"

# Move to worktree for all subsequent work
cd \"\$WORKTREE_DIR\"
\`\`\`

**CRITICAL**: All file paths in this task are relative to \`\$WORKTREE_DIR\`. Do NOT modify files in \`\$WORKSPACE_ROOT/main\`.
"

            worktree_commit="
## Commit Changes (EXECUTE LAST)

After completing all tasks, commit your changes:

\`\`\`bash
cd \"\$WORKTREE_DIR\"
git add -A
git commit -m \"PRD Phase ${CURRENT_PHASE}: ${task_name}

Task ID: ${task_id}
Agent ID: ${agent_id}

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>\"
\`\`\`

## ⛔ EXIT AFTER COMMIT (MANDATORY)
After commit: write results JSON → EXIT. NEVER merge/rebase/resolve conflicts. Orchestrator handles merges.
"
        fi

        # Build full prompt
        prompt=$(cat <<PROMPT_EOF
$AGENT_CONTEXT
$DESIGN_REFERENCE
$worktree_setup
## Your Assignment

**Agent ID**: $agent_id
**Wave**: $wave_id ($([ "$use_worktrees" = "true" ] && echo "worktree isolated" || echo "direct execution"))
**Task ID**: $task_id
**Task**: $task_name
**Type**: $task_type
**Target Files**: $(echo "$target_files" | jq -r 'join(", ")')
$pre_validation
## Task Details

**Description**: $task_desc

**Acceptance Criteria**:
$acceptance
$([ -n "$agent_hint" ] && echo "
**Agent Hint**: $agent_hint")
$test_details
$verify_steps
$file_structure_section
$post_validation
$worktree_commit
## Output Requirements (MANDATORY)

Write your detailed results to \`/tmp/.prd_agent_${agent_id}_results.json\`:
\`\`\`json
{
  "agentId": "$agent_id",
  "waveId": $wave_id,
  "taskIds": ["$task_id"],
  "status": "complete",
  "model": "$model",
  "filesModified": ["path/to/file"],
  "filesCreated": ["path/to/file"],
  "worktree": $([ "$use_worktrees" = "true" ] && echo "\"$worktree_name\"" || echo "null"),
  "branch": $([ "$use_worktrees" = "true" ] && echo "\"$branch_name\"" || echo "null"),
  "notes": "Brief summary of what was done"
}
\`\`\`
Set "status": "blocked" if unable to complete, explain in "notes".
Write this file IMMEDIATELY when you start, then update as you work.

Return ONLY this single-line JSON as your final response:
{"agentId":"$agent_id","waveId":$wave_id,"status":"complete|blocked","taskIds":["$task_id"]}
PROMPT_EOF
)

        # Build agent object
        # Write prompt to temp file to avoid ARG_MAX limit
        PROMPT_TMP="/tmp/.prd_build_prompt_tmp.txt"
        echo "$prompt" > "$PROMPT_TMP"

        agent_obj=$(jq -n \
            --arg id "$agent_id" \
            --argjson waveId "$wave_id" \
            --argjson useWorktrees "$use_worktrees" \
            --arg taskId "$task_id" \
            --arg taskName "$task_name" \
            --arg model "$model" \
            --arg worktree "$worktree_name" \
            --arg branch "$branch_name" \
            --rawfile prompt "$PROMPT_TMP" \
            '{
                agentId: $id,
                waveId: $waveId,
                useWorktrees: $useWorktrees,
                taskId: $taskId,
                taskName: $taskName,
                model: $model,
                worktree: (if $worktree == "" then null else $worktree end),
                branch: (if $branch == "" then null else $branch end),
                prompt: $prompt
            }')
        rm -f "$PROMPT_TMP"

        # Accumulate agents via temp files to avoid ARG_MAX
        AGENTS_TMP="/tmp/.prd_build_agents_tmp.json"
        echo "$wave_agents" > "$AGENTS_TMP"
        AGENT_OBJ_TMP="/tmp/.prd_build_agent_obj_tmp.json"
        echo "$agent_obj" > "$AGENT_OBJ_TMP"
        wave_agents=$(jq --slurpfile obj "$AGENT_OBJ_TMP" '. + $obj' "$AGENTS_TMP")
        rm -f "$AGENTS_TMP" "$AGENT_OBJ_TMP"
    done

    # Build wave object via temp files
    WAVE_AGENTS_TMP="/tmp/.prd_build_wave_agents_tmp.json"
    echo "$wave_agents" > "$WAVE_AGENTS_TMP"
    wave_obj=$(jq -n \
        --argjson waveId "$wave_id" \
        --argjson useWorktrees "$use_worktrees" \
        --slurpfile agents "$WAVE_AGENTS_TMP" \
        '{waveId: $waveId, useWorktrees: $useWorktrees, agents: $agents[0]}')
    rm -f "$WAVE_AGENTS_TMP"

    COMPILED_TMP="/tmp/.prd_build_compiled_tmp.json"
    echo "$compiled_waves" > "$COMPILED_TMP"
    WAVE_OBJ_TMP="/tmp/.prd_build_wave_obj_tmp.json"
    echo "$wave_obj" > "$WAVE_OBJ_TMP"
    compiled_waves=$(jq --slurpfile obj "$WAVE_OBJ_TMP" '. + $obj' "$COMPILED_TMP")
    rm -f "$COMPILED_TMP" "$WAVE_OBJ_TMP"
done

#------------------------------------------------------------------------------
# Write output file
#------------------------------------------------------------------------------
# Write waves to temp file to avoid ARG_MAX limit (large prompts exceed 2MB limit)
WAVES_TMP="/tmp/.prd_build_waves_tmp.json"
echo "$compiled_waves" > "$WAVES_TMP"

jq -n \
    --arg status "ready_to_build" \
    --arg buildType "phase" \
    --arg prd "$ACTIVE_PRD" \
    --arg phase "$CURRENT_PHASE" \
    --slurpfile waves "$WAVES_TMP" \
    '{status: $status, buildType: $buildType, prd: $prd, phase: $phase, waves: $waves[0]}' > "$OUTPUT_FILE"

rm -f "$WAVES_TMP"

# Output summary
total_waves=$(echo "$compiled_waves" | jq 'length')
total_agents=$(echo "$compiled_waves" | jq '[.[].agents | length] | add')
worktree_waves=$(echo "$compiled_waves" | jq '[.[] | select(.useWorktrees == true)] | length')

echo "{\"status\":\"ready\",\"waves\":$total_waves,\"agents\":$total_agents,\"worktreeWaves\":$worktree_waves,\"outputFile\":\"$OUTPUT_FILE\"}"
