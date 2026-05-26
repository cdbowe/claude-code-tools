#!/bin/bash
# PRD Unblock Compile Script - Compiles worker specs from unblock plan JSON (v2 - wave-based)
# Usage: prd-unblock-compile.sh [MAX_TASKS_PER_WAVE]
# Requires: /tmp/.prd_unblock_plan.json (from prd-unblock agent)
# Outputs: /tmp/.prd_unblock_build.json (wave-based manifest)

set -e

# Parse arguments - max tasks per wave (default 10)
MAX_TASKS_PER_WAVE="${1:-10}"

# Validate it's a positive integer
if ! [[ "$MAX_TASKS_PER_WAVE" =~ ^[1-9][0-9]*$ ]]; then
    echo '{"status":"error","error":"Invalid max-tasks-per-wave: must be a positive integer"}'
    exit 1
fi

STATE_FILE="/tmp/.prd_state"
PLAN_FILE="/tmp/.prd_unblock_plan.json"
OUTPUT_FILE="/tmp/.prd_unblock_build.json"
PRD_BASE="${WORKSPACE_DIR:-/workspaces/bankjet}/claude_files/PRDs"

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

# Verify unblock plan exists
if [ ! -f "$PLAN_FILE" ]; then
    echo '{"status":"error","error":"Unblock plan not found. Run /prd plan-unblock first."}'
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

# Get blocked tasks info from the unblock plan
BLOCKED_TASKS=$(jq -c '.blockedTasks' "$PLAN_FILE")

# Read phase JSON to look up agentHint for tasks
PHASE_FILE="${PHASE_JSON_FILE:-}"
PHASE_JSON=""
if [ -n "$PHASE_FILE" ] && [ -f "$PHASE_FILE" ]; then
    PHASE_JSON=$(cat "$PHASE_FILE")
fi

#------------------------------------------------------------------------------
# Step 1: Extract resolution tasks and compute waves using Python
#------------------------------------------------------------------------------
jq -c '.resolutionTasks' "$PLAN_FILE" > /tmp/.prd_resolution_tasks.json

# Check for empty resolution tasks
if [ "$(jq 'length' /tmp/.prd_resolution_tasks.json)" -eq 0 ]; then
    echo '{"status":"error","error":"No resolution tasks in unblock plan"}'
    exit 1
fi

# Compute waves using Python (topological sort + wave splitting)
python3 << PYEOF > /tmp/.prd_unblock_waves.json
import json

MAX_TASKS_PER_WAVE = $MAX_TASKS_PER_WAVE
CURRENT_PHASE = "$CURRENT_PHASE"

with open('/tmp/.prd_resolution_tasks.json') as f:
    tasks = json.load(f)

# Build task map and pending set
pending_ids = {t['taskId'] for t in tasks}
task_map = {t['taskId']: t for t in tasks}
assigned = set()
waves = []

# Topological sort with wave splitting
while pending_ids - assigned:
    # Find all tasks whose dependencies are satisfied
    ready = []
    for task_id in list(pending_ids - assigned):
        task = task_map[task_id]
        deps = set(task.get('dependsOn') or [])
        # Only consider dependencies that are in our task set
        pending_deps = deps & pending_ids
        if pending_deps <= assigned:
            ready.append(task)

    if not ready:
        # Circular dependency - take remaining (shouldn't happen with valid plan)
        ready = [task_map[tid] for tid in (pending_ids - assigned)]

    # Split ready tasks into chunks of MAX_TASKS_PER_WAVE
    for i in range(0, len(ready), MAX_TASKS_PER_WAVE):
        wave = ready[i:i + MAX_TASKS_PER_WAVE]
        for t in wave:
            assigned.add(t['taskId'])
        waves.append(wave)

# Build wave objects with useWorktrees flag
result = []
for wave_id, wave_tasks in enumerate(waves):
    use_worktrees = len(wave_tasks) >= 2

    agents = []
    for task_idx, task in enumerate(wave_tasks):
        agent_id = f"W{wave_id}-T{task_idx}"

        # Build worktree/branch names if using worktrees
        if use_worktrees:
            worktree = f"wt-prd-unblock-{CURRENT_PHASE}-{agent_id}"
            branch = f"prd/unblock-{CURRENT_PHASE}/{agent_id}"
        else:
            worktree = None
            branch = None

        agents.append({
            'agentId': agent_id,
            'waveId': wave_id,
            'taskId': task['taskId'],
            'taskName': task.get('taskName', ''),
            'taskType': task.get('taskType', ''),
            'model': task.get('model', 'haiku'),
            'originalBlockedTask': task.get('originalBlockedTask', ''),
            'resolution': task.get('resolution', ''),
            'targetFiles': task.get('targetFiles', []),
            'dependsOn': task.get('dependsOn', []),
            'worktree': worktree,
            'branch': branch,
            'useWorktrees': use_worktrees
        })

    result.append({
        'waveId': wave_id,
        'useWorktrees': use_worktrees,
        'agents': agents
    })

print(json.dumps(result))
PYEOF

#------------------------------------------------------------------------------
# Step 2: Build unblock-specific agent context
#------------------------------------------------------------------------------
UNBLOCK_CONTEXT="
## Unblock Task Context

You are resolving blocked tasks from the PRD. Each task you're assigned either:
1. **UNBLOCK-X.Y**: Creates a missing dependency or fixes an issue that was blocking task X.Y
2. **RETRY-X.Y**: Re-attempts the original blocked task X.Y now that dependencies exist

### Originally Blocked Tasks

$(echo "$BLOCKED_TASKS" | jq -r '.[] | "- **Task \(.taskId)** (\(.taskName)): \(.blockReason)"')

### Your Goal

Complete the resolution tasks assigned to you. After successful completion, the originally blocked tasks will be marked as Complete.
"

#------------------------------------------------------------------------------
# Step 3: Generate agent prompts and build final manifest
#------------------------------------------------------------------------------
WAVES_JSON=$(cat /tmp/.prd_unblock_waves.json)
wave_count=$(echo "$WAVES_JSON" | jq 'length')

# Build waves with prompts
waves_with_prompts="[]"

for ((w=0; w<wave_count; w++)); do
    wave=$(echo "$WAVES_JSON" | jq ".[$w]")
    wave_id=$(echo "$wave" | jq -r '.waveId')
    use_worktrees=$(echo "$wave" | jq -r '.useWorktrees')

    agents_with_prompts="[]"
    agent_count=$(echo "$wave" | jq '.agents | length')

    for ((a=0; a<agent_count; a++)); do
        agent=$(echo "$wave" | jq ".agents[$a]")
        agent_id=$(echo "$agent" | jq -r '.agentId')
        task_id=$(echo "$agent" | jq -r '.taskId')
        task_name=$(echo "$agent" | jq -r '.taskName')
        task_type=$(echo "$agent" | jq -r '.taskType')
        model=$(echo "$agent" | jq -r '.model')
        original_task=$(echo "$agent" | jq -r '.originalBlockedTask')
        resolution=$(echo "$agent" | jq -r '.resolution')
        worktree=$(echo "$agent" | jq -r '.worktree // empty')
        branch=$(echo "$agent" | jq -r '.branch // empty')
        target_files=$(echo "$agent" | jq -r '(.targetFiles // []) | map(if startswith("main/") then .[5:] else . end) | join(", ")')
        depends_on=$(echo "$agent" | jq -r '(.dependsOn // []) | join(", ")')

        # Get original blocked task details
        original_info=$(echo "$BLOCKED_TASKS" | jq --arg id "$original_task" '.[] | select(.taskId == $id)')
        original_reason=$(echo "$original_info" | jq -r '.blockReason // "Unknown"')

        # Get agentHint from resolution task or look up from phase JSON
        agent_hint=$(echo "$agent" | jq -r '.agentHint // empty')
        if [ -z "$agent_hint" ] && [ -n "$PHASE_JSON" ]; then
            # Try to get agentHint from original task in phase JSON
            agent_hint=$(echo "$PHASE_JSON" | jq -r --arg id "$original_task" '.tasks[] | select(.taskId == $id) | .agentHint // empty')
        fi

        # Build worktree setup instructions if applicable
        if [ "$use_worktrees" = "true" ] && [ -n "$worktree" ]; then
            worktree_setup="
## Worktree Setup

You are working in an isolated git worktree. Your changes will be merged back to main after completion.

\`\`\`bash
# Worktree already created by orchestrator - verify and use it
WORKTREE_PATH=\"\$WORKSPACE_DIR/worktrees/$worktree\"
cd \"\$WORKTREE_PATH\" || (echo 'ERROR: Worktree not found' && exit 1)
\`\`\`

**IMPORTANT**: All file operations must be relative to the worktree path, not main.
"
            commit_instructions="
## Commit Your Changes

After completing your work, commit changes in the worktree:

\`\`\`bash
cd \"\$WORKSPACE_DIR/worktrees/$worktree\"
git add -A
git commit -m \"$agent_id: $task_name

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>\"
\`\`\`

## ⛔ EXIT AFTER COMMIT (MANDATORY)
After commit: write results JSON → EXIT. NEVER merge/rebase/resolve conflicts. Orchestrator handles merges.
"
        else
            worktree_setup=""
            commit_instructions=""
        fi

        # Build full prompt
        prompt="$AGENT_CONTEXT
$DESIGN_REFERENCE

$UNBLOCK_CONTEXT
$worktree_setup
## Your Assignment

**Agent ID**: $agent_id
**Wave**: $wave_id
**Task**: $task_id - $task_name
**Target Files**: $target_files
**Dependencies**: $depends_on

## Task Details

### Task $task_id: $task_name

**Type**: $task_type
**Original Blocked Task**: $original_task
**Block Reason**: $original_reason
**Resolution**: $resolution
**Target Files**: $target_files
$([ -n "$agent_hint" ] && echo "**Agent Hint**: $agent_hint")
$commit_instructions
## Output Requirements (MANDATORY)

Write your detailed results to \`/tmp/.prd_agent_${agent_id}_results.json\`:
\`\`\`json
{
  \"agentId\": \"$agent_id\",
  \"waveId\": $wave_id,
  \"taskIds\": [\"$task_id\"],
  \"status\": \"complete\",
  \"model\": \"$model\",
  \"filesModified\": [\"path/to/file\"],
  \"filesCreated\": [\"path/to/file\"],
  \"worktree\": $(if [ -n "$worktree" ]; then echo "\"$worktree\""; else echo "null"; fi),
  \"branch\": $(if [ -n "$branch" ]; then echo "\"$branch\""; else echo "null"; fi),
  \"notes\": \"Brief summary of what was done to resolve the blocker\"
}
\`\`\`
If blocked, set \"status\": \"blocked\" and include \"blockedReason\" field.
Write this file IMMEDIATELY when you start, then update as you work.

Return ONLY this single-line JSON as your final response:
{\"agentId\":\"$agent_id\",\"status\":\"complete|blocked\",\"taskIds\":[\"$task_id\"]}"

        # Build agent object with prompt
        task_ids_array="[\"$task_id\"]"
        # Write prompt to temp file to avoid ARG_MAX limit
        PROMPT_TMP="/tmp/.prd_unblock_prompt_tmp.txt"
        echo "$prompt" > "$PROMPT_TMP"

        agent_obj=$(jq -n \
            --arg id "$agent_id" \
            --argjson waveId "$wave_id" \
            --arg taskId "$task_id" \
            --arg taskName "$task_name" \
            --argjson taskIds "$task_ids_array" \
            --arg model "$model" \
            --arg worktree "$worktree" \
            --arg branch "$branch" \
            --argjson useWorktrees "$use_worktrees" \
            --arg desc "Unblock: $task_id" \
            --rawfile prompt "$PROMPT_TMP" \
            '{
                agentId: $id,
                waveId: $waveId,
                taskId: $taskId,
                taskName: $taskName,
                taskIds: $taskIds,
                model: $model,
                worktree: (if $worktree == "" then null else $worktree end),
                branch: (if $branch == "" then null else $branch end),
                useWorktrees: $useWorktrees,
                description: $desc,
                prompt: $prompt
            }')
        rm -f "$PROMPT_TMP"

        agents_with_prompts=$(echo "$agents_with_prompts" | jq --argjson obj "$agent_obj" '. + [$obj]')
    done

    # Build wave object
    wave_obj=$(jq -n \
        --argjson waveId "$wave_id" \
        --argjson useWorktrees "$use_worktrees" \
        --argjson agents "$agents_with_prompts" \
        '{waveId: $waveId, useWorktrees: $useWorktrees, agents: $agents}')

    waves_with_prompts=$(echo "$waves_with_prompts" | jq --argjson obj "$wave_obj" '. + [$obj]')
done

#------------------------------------------------------------------------------
# Step 4: Write output file
#------------------------------------------------------------------------------
jq -n \
    --arg status "ready_to_build" \
    --arg buildType "unblock" \
    --arg prd "$ACTIVE_PRD" \
    --arg phase "$CURRENT_PHASE" \
    --argjson blockedTasks "$BLOCKED_TASKS" \
    --argjson waves "$waves_with_prompts" \
    '{status: $status, buildType: $buildType, prd: $prd, phase: $phase, blockedTasks: $blockedTasks, waves: $waves}' > "$OUTPUT_FILE"

# Cleanup temp files
rm -f /tmp/.prd_resolution_tasks.json /tmp/.prd_unblock_waves.json

#------------------------------------------------------------------------------
# Step 5: Output summary
#------------------------------------------------------------------------------
total_waves=$(echo "$waves_with_prompts" | jq 'length')
total_agents=$(echo "$waves_with_prompts" | jq '[.[].agents | length] | add')
worktree_waves=$(echo "$waves_with_prompts" | jq '[.[] | select(.useWorktrees == true)] | length')
blocked_count=$(echo "$BLOCKED_TASKS" | jq 'length')

echo "{\"status\":\"ready\",\"blockedTasks\":$blocked_count,\"waves\":$total_waves,\"agents\":$total_agents,\"worktreeWaves\":$worktree_waves,\"outputFile\":\"$OUTPUT_FILE\"}"
