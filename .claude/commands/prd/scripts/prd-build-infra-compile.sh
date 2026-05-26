#!/bin/bash
# PRD Build Infra Compile Script - Compiles wave-based worker specs from infra plan JSON
# Usage: prd-build-infra-compile.sh
# Requires: /tmp/.prd_infra_plan.json (from prd-plan-infra agent)

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
PLAN_FILE="/tmp/.prd_infra_plan.json"
OUTPUT_FILE="/tmp/.prd_infra_build.json"
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

# Verify plan exists
if [ ! -f "$PLAN_FILE" ]; then
    echo '{"status":"error","error":"Infra plan not found. Run /prd plan-infra first."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"
ROOT_FILE="$PRD_DIR/00_ROOT.md"

# Find infrastructure JSON file (phase_0_*.json)
INFRA_FILE=""
for f in "$PRD_DIR"/phase_0_*.json; do
    [ -f "$f" ] && INFRA_FILE="$f" && break
done

if [ -z "$INFRA_FILE" ]; then
    echo '{"status":"error","error":"No infrastructure file found (phase_0_*.json)."}'
    exit 1
fi

# Read context files
ROOT_CONTENT=""
if [ -f "$ROOT_FILE" ]; then
    ROOT_CONTENT=$(cat "$ROOT_FILE")
fi

# Read infrastructure JSON for context
INFRA_JSON=$(cat "$INFRA_FILE")
INFRA_DESCRIPTION=$(echo "$INFRA_JSON" | jq -r '.description // "Infrastructure Setup"')

# Extract project goals from ROOT (Overview section)
GOALS=$(echo "$ROOT_CONTENT" | awk '/^## Overview/,/^## / {if (!/^## / || /^## Overview/) print}' | head -20)

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
        task_category=$(echo "$task_spec" | jq -r '.taskCategory // "Infrastructure"')
        model=$(echo "$task_spec" | jq -r '.model')
        # Strip 'main/' prefix from target files - agents work in worktrees with relative paths
        target_files=$(echo "$task_spec" | jq -c '(.targetFiles // []) | map(if startswith("main/") then .[5:] else . end)')

        # Generate agent ID based on wave and task index
        agent_id="INFRA-W${wave_id}-T${t}"

        # Get full task details from infrastructure JSON
        task=$(echo "$INFRA_JSON" | jq --arg id "$task_id" '.tasks[] | select(.taskId == $id)')
        task_desc=$(echo "$task" | jq -r '.description // "No description"')
        acceptance=$(echo "$task" | jq -r '.acceptanceCriteria // [] | map("- " + .) | join("\n")')
        reference_files=$(echo "$task" | jq -r '.referenceFiles // [] | join(", ")')
        agent_hint=$(echo "$task" | jq -r '.agentHint // empty')

        # Build worktree setup block if this wave uses worktrees
        worktree_setup=""
        worktree_commit=""
        worktree_name=""
        branch_name=""

        if [ "$use_worktrees" = "true" ]; then
            worktree_name="wt-prd-infra-${agent_id}"
            branch_name="prd/infra/${agent_id}"

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
git commit -m \"PRD Infra: ${task_name}

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
# $ACTIVE_PRD - Infrastructure Task
$worktree_setup
## Project Goals
$GOALS

## Your Assignment

**Agent ID**: $agent_id
**Wave**: $wave_id ($([ "$use_worktrees" = "true" ] && echo "worktree isolated" || echo "direct execution"))
**Task ID**: $task_id
**Task**: $task_name
**Type**: $task_type
**Category**: $task_category
**Target Files**: $(echo "$target_files" | jq -r 'join(", ")')
**Reference Files**: $reference_files

## Task Details

**Description**: $task_desc

**Acceptance Criteria**:
$acceptance
$([ -n "$agent_hint" ] && echo "
**Agent Hint**: $agent_hint")
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

Verification: Ensure code compiles after your changes.

Return ONLY this single-line JSON as your final response:
{"agentId":"$agent_id","waveId":$wave_id,"status":"complete|blocked","taskIds":["$task_id"]}
PROMPT_EOF
)

        # Build agent object
        agent_obj=$(jq -n \
            --arg id "$agent_id" \
            --argjson waveId "$wave_id" \
            --argjson useWorktrees "$use_worktrees" \
            --arg taskId "$task_id" \
            --arg taskName "$task_name" \
            --arg model "$model" \
            --arg worktree "$worktree_name" \
            --arg branch "$branch_name" \
            --arg prompt "$prompt" \
            --arg infraFile "$INFRA_FILE" \
            '{
                agentId: $id,
                waveId: $waveId,
                useWorktrees: $useWorktrees,
                taskId: $taskId,
                taskName: $taskName,
                model: $model,
                worktree: (if $worktree == "" then null else $worktree end),
                branch: (if $branch == "" then null else $branch end),
                prompt: $prompt,
                infraFile: $infraFile
            }')

        wave_agents=$(echo "$wave_agents" | jq --argjson obj "$agent_obj" '. + [$obj]')
    done

    # Build wave object
    wave_obj=$(jq -n \
        --argjson waveId "$wave_id" \
        --argjson useWorktrees "$use_worktrees" \
        --argjson agents "$wave_agents" \
        '{waveId: $waveId, useWorktrees: $useWorktrees, agents: $agents}')

    compiled_waves=$(echo "$compiled_waves" | jq --argjson obj "$wave_obj" '. + [$obj]')
done

#------------------------------------------------------------------------------
# Write output file
#------------------------------------------------------------------------------
jq -n \
    --arg status "ready_to_build" \
    --arg buildType "infra" \
    --arg prd "$ACTIVE_PRD" \
    --argjson waves "$compiled_waves" \
    '{status: $status, buildType: $buildType, prd: $prd, waves: $waves}' > "$OUTPUT_FILE"

# Output summary
total_waves=$(echo "$compiled_waves" | jq 'length')
total_agents=$(echo "$compiled_waves" | jq '[.[].agents | length] | add // 0')
worktree_waves=$(echo "$compiled_waves" | jq '[.[] | select(.useWorktrees == true)] | length')

echo "{\"status\":\"ready\",\"waves\":$total_waves,\"agents\":$total_agents,\"worktreeWaves\":$worktree_waves,\"outputFile\":\"$OUTPUT_FILE\"}"
