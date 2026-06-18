#!/bin/bash
# prd-plan.sh - Generate wave-based execution plan from phase JSON
# Skips tasks with blocked/incomplete dependencies

set -e

# Parse arguments - max tasks per wave (default 10)
MAX_TASKS_PER_WAVE="${1:-10}"

# Validate it's a positive integer
if ! [[ "$MAX_TASKS_PER_WAVE" =~ ^[1-9][0-9]*$ ]]; then
    echo '{"status":"error","error":"Invalid max-tasks-per-wave: must be a positive integer"}'
    exit 1
fi

# Read state
if [[ ! -f /tmp/.prd_state ]]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi

source /tmp/.prd_state

if [[ -z "$ACTIVE_PRD" ]]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi

if [[ -z "$CURRENT_PHASE" || -z "$PHASE_JSON_FILE" ]]; then
    echo '{"status":"error","error":"No phase loaded. Run /prd read <phase> first."}'
    exit 1
fi

if [[ ! -f "$PHASE_JSON_FILE" ]]; then
    echo "{\"status\":\"error\",\"error\":\"Phase file not found: $PHASE_JSON_FILE\"}"
    exit 1
fi

# Extract phase name
PHASE_NAME=$(jq -r '.phaseName // .name // "Unknown"' "$PHASE_JSON_FILE")

# Get all tasks with status for dependency checking
jq '.tasks | map({taskId: .taskId, taskStatus: .taskStatus})' "$PHASE_JSON_FILE" > /tmp/.prd_all_task_statuses.json

# Get pending tasks with model assignment and write to temp file
jq '
  [.tasks[] | select(.taskStatus == "Pending")] |
  map({
    taskId: .taskId,
    taskName: .taskName,
    taskType: .taskType,
    dependsOn: (.dependsOn // []),
    targetFiles: (.targetFiles // []),
    modifiedFiles: (.modifiedFiles // []),
    model: (
      if .taskType == "generate-test" then "sonnet"
      elif .taskType == "create-file" then "sonnet"
      elif .taskType == "verify" then "sonnet"
      else "haiku"
      end
    )
  })
' "$PHASE_JSON_FILE" > /tmp/.prd_pending_tasks.json

PENDING_COUNT=$(jq 'length' /tmp/.prd_pending_tasks.json)

if [[ "$PENDING_COUNT" -eq 0 ]]; then
    # Check if there are skipped tasks to report
    SKIPPED_COUNT=$(jq '[.tasks[] | select(.taskStatus == "Skipped")] | length' "$PHASE_JSON_FILE")
    cat > /tmp/.prd_plan.json << EOF
{
  "prd": "$ACTIVE_PRD",
  "phase": "$CURRENT_PHASE",
  "phaseName": "$PHASE_NAME",
  "totalTasks": 0,
  "skippedCount": $SKIPPED_COUNT,
  "skippedTasks": [],
  "waves": []
}
EOF
    echo "{\"status\":\"complete\",\"waves\":0,\"tasks\":0,\"skipped\":$SKIPPED_COUNT,\"worktreeWaves\":0}"
    exit 0
fi

# Compute waves using Python - now with dependency status checking
python3 << PYEOF > /tmp/.prd_waves_and_skipped.json
import json

MAX_TASKS_PER_WAVE = $MAX_TASKS_PER_WAVE

with open('/tmp/.prd_pending_tasks.json') as f:
    pending_tasks = json.load(f)

with open('/tmp/.prd_all_task_statuses.json') as f:
    all_statuses = {t['taskId']: t['taskStatus'] for t in json.load(f)}

# First pass: identify tasks that must be skipped due to blocked dependencies
# A task is skipped if ANY of its dependencies has status other than "Complete" or "Pending"
skipped_tasks = []
eligible_tasks = []

for task in pending_tasks:
    deps = task.get('dependsOn') or []
    blocked_deps = []

    for dep_id in deps:
        dep_status = all_statuses.get(dep_id, 'Unknown')
        # Allowed dependency statuses: Complete (done) or Pending (will be done in this build)
        if dep_status not in ('Complete', 'Pending'):
            blocked_deps.append({'depId': dep_id, 'depStatus': dep_status})

    if blocked_deps:
        skipped_tasks.append({
            'taskId': task['taskId'],
            'taskName': task['taskName'],
            'reason': f"Dependency {blocked_deps[0]['depId']} has status: {blocked_deps[0]['depStatus']}",
            'blockedDeps': blocked_deps
        })
    else:
        eligible_tasks.append(task)

# Second pass: compute waves from eligible tasks only
pending_ids = {t['taskId'] for t in eligible_tasks}
task_map = {t['taskId']: t for t in eligible_tasks}
assigned = set()
waves = []

while pending_ids - assigned:
    # Find all tasks whose dependencies are satisfied
    ready = []
    for task_id in list(pending_ids - assigned):
        task = task_map[task_id]
        deps = set(task.get('dependsOn') or [])
        # Only consider dependencies that are in our eligible set
        pending_deps = deps & pending_ids
        if pending_deps <= assigned:
            ready.append(task)

    if not ready:
        # Circular dependency - take remaining
        ready = [task_map[tid] for tid in (pending_ids - assigned)]

    # Split ready tasks into waves, avoiding file overlap within each wave
    remaining = list(ready)
    while remaining:
        wave = []
        wave_files = set()
        deferred = []

        for task in remaining:
            # Collect all files this task touches (target + modified)
            task_files = set(task.get('targetFiles') or []) | set(task.get('modifiedFiles') or [])

            # Check for overlap with files already claimed by this wave
            if task_files & wave_files:
                deferred.append(task)
            else:
                wave.append(task)
                wave_files |= task_files
                if len(wave) >= MAX_TASKS_PER_WAVE:
                    deferred.extend(remaining[remaining.index(task) + 1:])
                    break

        for t in wave:
            assigned.add(t['taskId'])
        waves.append(wave)
        remaining = deferred

wave_result = []
for i, wave_tasks in enumerate(waves):
    wave_result.append({
        'waveId': i,
        'useWorktrees': len(wave_tasks) >= 2,
        'tasks': wave_tasks
    })

print(json.dumps({'waves': wave_result, 'skippedTasks': skipped_tasks}))
PYEOF

# Parse output
WAVE_COUNT=$(jq '.waves | length' /tmp/.prd_waves_and_skipped.json)
WORKTREE_WAVES=$(jq '[.waves[] | select(.useWorktrees == true)] | length' /tmp/.prd_waves_and_skipped.json)
SKIPPED_COUNT=$(jq '.skippedTasks | length' /tmp/.prd_waves_and_skipped.json)
ELIGIBLE_COUNT=$(jq '[.waves[].tasks[]] | length' /tmp/.prd_waves_and_skipped.json)

# Write plan JSON
jq -n \
  --arg prd "$ACTIVE_PRD" \
  --arg phase "$CURRENT_PHASE" \
  --arg phaseName "$PHASE_NAME" \
  --argjson totalTasks "$ELIGIBLE_COUNT" \
  --argjson skippedCount "$SKIPPED_COUNT" \
  --slurpfile data /tmp/.prd_waves_and_skipped.json \
  '{
    prd: $prd,
    phase: $phase,
    phaseName: $phaseName,
    totalTasks: $totalTasks,
    skippedCount: $skippedCount,
    skippedTasks: $data[0].skippedTasks,
    waves: $data[0].waves
  }' > /tmp/.prd_plan.json

# Cleanup
rm -f /tmp/.prd_pending_tasks.json /tmp/.prd_waves_and_skipped.json /tmp/.prd_all_task_statuses.json

echo "{\"status\":\"complete\",\"waves\":$WAVE_COUNT,\"tasks\":$ELIGIBLE_COUNT,\"skipped\":$SKIPPED_COUNT,\"worktreeWaves\":$WORKTREE_WAVES}"
