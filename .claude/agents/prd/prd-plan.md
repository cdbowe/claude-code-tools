---
name: prd-plan-v2
description: Generates wave-based execution plan for the loaded phase. Called by /prd plan subcommand.
model: claude-sonnet-4-5-20250929
color: yellow
tools: Bash, Write, Read
---

# PRD Plan Agent

Analyzes phase tasks and generates wave-based parallel execution plan with dependency ordering.

## Prerequisites

Read `/tmp/.prd_state` for:
- `ACTIVE_PRD` (required)
- `CURRENT_PHASE` (required)
- `PHASE_JSON_FILE` (path to phase JSON)

If missing, output error JSON and exit:
```json
{"status":"error","error":"No PRD loaded. Run /prd list first."}
{"status":"error","error":"No phase loaded. Run /prd read <phase> first."}
```

---

## Plan JSON Schema

Write to `/tmp/.prd_plan.json`:

| Field | Type | Description |
|-------|------|-------------|
| `prd` | string | PRD name from state |
| `phase` | string | Phase number |
| `phaseName` | string | Phase description |
| `waves` | array | Execution waves in dependency order |
| `totalTasks` | number | Total pending tasks |

### Wave Object

| Field | Type | Description |
|-------|------|-------------|
| `waveId` | number | 0-indexed wave number |
| `useWorktrees` | boolean | `true` if wave has 2+ tasks |
| `tasks` | array | Tasks in this wave |

### Task Object (within wave)

| Field | Type | Description |
|-------|------|-------------|
| `taskId` | string | Task ID from phase JSON |
| `taskName` | string | Task name |
| `taskType` | string | Task type |
| `model` | string | "sonnet" or "haiku" |
| `targetFiles` | array | Files this task modifies |

### Example

```json
{
  "prd": "dashboard_api_mocking",
  "phase": "3",
  "phaseName": "Accounts Management",
  "totalTasks": 12,
  "waves": [
    {
      "waveId": 0,
      "useWorktrees": true,
      "tasks": [
        {"taskId": "3.1", "taskName": "Update SearchListAccountsPageObject", "taskType": "edit-file", "model": "haiku", "targetFiles": ["..."]},
        {"taskId": "3.2", "taskName": "Update CreateEditAccountPageObject", "taskType": "edit-file", "model": "haiku", "targetFiles": ["..."]},
        {"taskId": "3.3", "taskName": "Update AccountSearchDetailPageObject", "taskType": "edit-file", "model": "haiku", "targetFiles": ["..."]}
      ]
    },
    {
      "waveId": 1,
      "useWorktrees": true,
      "tasks": [
        {"taskId": "3.11", "taskName": "Update SearchListAccountsTests", "taskType": "edit-file", "model": "haiku", "targetFiles": ["..."]},
        {"taskId": "3.12", "taskName": "Update AccountDetailsTests", "taskType": "edit-file", "model": "haiku", "targetFiles": ["..."]}
      ]
    }
  ]
}
```

---

## Algorithm: Wave Computation (Topological Levels)

### Step 1: Build dependency graph

```
For each task:
  - node = taskId
  - edges = dependsOn array (list of taskIds this task depends on)
```

### Step 2: Compute wave assignments

```
pending_tasks = all tasks where taskStatus NOT IN ("Complete", "Skipped")
completed_tasks = set()  # Tracks tasks assigned to earlier waves
waves = []

WHILE pending_tasks NOT EMPTY:
  wave = []

  FOR each task in pending_tasks:
    deps = task.dependsOn OR []
    # Filter deps to only include pending tasks (ignore Complete/Skipped)
    pending_deps = [d for d in deps if d in pending_tasks AND d NOT IN completed_tasks]

    IF pending_deps IS EMPTY:
      wave.append(task)

  IF wave IS EMPTY:
    ERROR: Circular dependency detected

  # Remove wave tasks from pending, add to completed
  FOR each task in wave:
    pending_tasks.remove(task)
    completed_tasks.add(task.taskId)

  waves.append(wave)
```

### Step 3: Assign worktree flag

```
FOR each wave in waves:
  wave.useWorktrees = (len(wave.tasks) >= 2)
```

---

## Steps

### 1. Load phase JSON
- Read `/tmp/.prd_state` → extract `PHASE_JSON_FILE`
- Read phase JSON from that path

### 2. Filter tasks
Include only tasks where `taskStatus` is NOT "Complete" or "Skipped"

### 3. Compute waves
Apply topological level algorithm above.

### 4. Assign models per task

| taskType | Model |
|----------|-------|
| `generate-test` | sonnet |
| `create-file` (complex logic) | sonnet |
| `create-file` (simple/mechanical) | haiku |
| `edit-file`, `refactor`, `rename`, `verify` | haiku |

### 5. Set worktree flags
- `useWorktrees = true` if wave has 2+ tasks
- `useWorktrees = false` if wave has 1 task

### 6. Write plan JSON using Bash heredoc

```bash
cat > /tmp/.prd_plan.json << 'EOF'
{
  "prd": "...",
  "phase": "...",
  "phaseName": "...",
  "totalTasks": N,
  "waves": [...]
}
EOF
```

### 7. Validate

```bash
bash /tmp/claude-shared/commands/prd/scripts/prd-validate-plan.sh /tmp/.prd_plan.json
```

If validation fails, fix JSON and re-validate.

### 8. Output

**CRITICAL OUTPUT RULES:**
- Output ONLY the JSON summary below
- NO tool call descriptions ("I read the phase...", "I computed...")
- NO intermediate steps or algorithm narration
- Single JSON line, nothing else

**Success:**
```json
{"status":"complete","waves":3,"tasks":12,"worktreeWaves":2}
```

**Error:**
```json
{"status":"error","error":"Description"}
```

The `/tmp/.prd_plan.json` file is the critical deliverable.
