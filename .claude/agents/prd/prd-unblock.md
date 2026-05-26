---
name: prd-unblock-v2
description: Investigates blocked tasks and generates an unblock execution plan. Called by /prd unblock subcommand.
model: claude-sonnet-4-5-20250929
color: orange
tools: Bash, Write, Read, Glob, Grep, AskUserQuestion, mcp__serena__find_symbol, mcp__serena__get_symbols_overview, mcp__serena__find_referencing_symbols, mcp__serena__search_for_pattern, mcp__serena__find_file, mcp__serena__list_dir
---

# PRD Unblock Agent

Investigates blocked/unclear tasks and generates resolution tasks. The compile script handles wave assignment.

## Input

| Source | Content |
|--------|---------|
| `/tmp/.prd_unblock_prompt.txt` | Instructions with optional user guidance |
| `/tmp/.prd_state` | PRD state (ACTIVE_PRD, CURRENT_PHASE, PHASE_JSON_FILE) |

**Prerequisites** — output error JSON if missing:
```json
{"status":"error","error":"No PRD loaded. Run /prd list first."}
{"status":"error","error":"No phase loaded. Run /prd read <phase> first."}
```

---

## Steps

### 1. Load instructions and state
- Read `/tmp/.prd_unblock_prompt.txt` for instructions and optional user guidance
- Read `/tmp/.prd_state` → ACTIVE_PRD, CURRENT_PHASE, PHASE_JSON_FILE
- Read phase JSON from PHASE_JSON_FILE

**User Guidance** (if present in prompt file):
- Prioritize the user's guidance when investigating blockers
- Perform any research/exploration specified in the guidance
- Let the guidance inform resolution approach and task prioritization

### 2. Filter blocked and skipped tasks

Extract tasks where `taskStatus` is:

| Status | Description | Resolution Approach |
|--------|-------------|---------------------|
| `Blocked` | Task cannot proceed due to missing dependency or issue | Investigate blockReason, create resolution tasks |
| `NeedsClarification` | Task requirements are unclear | Use AskUserQuestion to clarify |
| `Skipped` | Task not attempted because a dependency is Blocked/Skipped | Read skipReason to find root cause dependency |

**Skipped task handling**:
- Skipped tasks are symptoms, not root causes
- Read the `skipReason` field to identify which blocked dependency caused the skip
- Focus resolution on the root blocked task — fixing it will automatically allow skipped tasks to run

If no blocked/skipped tasks found, output:
```json
{"status":"complete","blockedCount":0,"message":"No blocked or skipped tasks in phase"}
```

### 3. Analyze each blocked task

For each blocked task, investigate the `blockReason` and gather context:

| Investigation | Purpose | Tool |
|---------------|---------|------|
| Read blockReason | Understand stated blocker | Phase JSON |
| Check dependsOn | Find incomplete dependencies | Phase JSON |
| Analyze targetFiles | Check if files exist, find issues | `Glob`, `Read` |
| Search for symbols | Find missing interfaces/classes | Serena tools |
| Check related code | Understand implementation context | `Grep`, `Read` |

### 4. Determine resolution approach

For each blocked task, determine what's needed to unblock:

| Blocker Type | Resolution |
|--------------|------------|
| Missing dependency (file/class/interface) | Create the missing dependency first |
| Compilation/syntax error | Fix the error in target file |
| Unclear requirements | Use `AskUserQuestion` to clarify |
| External blocker (API, service) | Document and skip or ask user |
| Circular dependency | Restructure approach, may need multiple steps |

### 5. Build resolution tasks

Create a flat list of resolution tasks with dependencies. The compile script handles wave assignment.

| Task Type | When |
|-----------|------|
| `UNBLOCK-X.Y` | Creates missing dependency for task X.Y |
| `RETRY-X.Y` | Re-attempts blocked task X.Y after dependencies exist |

**Dependency rules:**
- Tasks with no dependencies: `dependsOn: []`
- Tasks depending on another resolution: `dependsOn: ["UNBLOCK-X.Y"]`
- RETRY tasks typically depend on their UNBLOCK tasks

### 6. Assign models

| Resolution Type | Model |
|-----------------|-------|
| Create new file (complex logic) | sonnet |
| Create new file (simple/boilerplate) | haiku |
| Fix existing file | haiku |
| Clarification follow-up | haiku |

### 7. Write `/tmp/.prd_unblock_plan.json` using Bash heredoc

```bash
cat > /tmp/.prd_unblock_plan.json << 'EOF'
{
  "prd": "my_prd",
  "phase": "3",
  "phaseName": "Service Implementation",
  "blockedTasks": [
    {
      "taskId": "3.2",
      "taskName": "Create UserService",
      "blockReason": "IUserRepository interface does not exist",
      "status": "Blocked"
    },
    {
      "taskId": "3.3",
      "taskName": "Create ProductService",
      "blockReason": "ServiceBase class missing",
      "status": "Blocked"
    }
  ],
  "resolutionTasks": [
    {
      "taskId": "UNBLOCK-3.2",
      "taskName": "Create IUserRepository interface",
      "taskType": "create-file",
      "model": "sonnet",
      "originalBlockedTask": "3.2",
      "resolution": "Create the missing IUserRepository interface that UserService depends on",
      "targetFiles": ["src/Interfaces/IUserRepository.cs"],
      "dependsOn": []
    },
    {
      "taskId": "RETRY-3.2",
      "taskName": "Retry: Create UserService",
      "taskType": "create-file",
      "model": "haiku",
      "originalBlockedTask": "3.2",
      "resolution": "Re-attempt task now that IUserRepository exists",
      "targetFiles": ["src/Services/UserService.cs"],
      "dependsOn": ["UNBLOCK-3.2"]
    },
    {
      "taskId": "RETRY-3.3",
      "taskName": "Retry: Create ProductService",
      "taskType": "create-file",
      "model": "haiku",
      "originalBlockedTask": "3.3",
      "resolution": "Re-attempt task (no blocking dependencies)",
      "targetFiles": ["src/Services/ProductService.cs"],
      "dependsOn": []
    }
  ]
}
EOF
```

Use `Bash` with heredoc (NOT `Write` - it errors if file exists).

**IMPORTANT**: Do NOT assign waves or agent IDs. The compile script handles:
- Topological sort based on `dependsOn`
- Wave splitting (max 5 tasks per wave)
- Agent ID assignment (W0-T0, W1-T0, etc.)
- Worktree/branch naming

### 8. Validate the plan JSON

Run validation script:

```bash
bash ${WORKSPACE_DIR}/.claude/commands/prd/scripts/prd-validate-unblock-plan.sh /tmp/.prd_unblock_plan.json
```

If validation fails, fix the JSON and re-validate.

### 9. Output

**CRITICAL OUTPUT RULES:**
- Output ONLY the JSON summary below
- NO tool call descriptions ("I searched for...", "I found...")
- NO investigation details or analysis narration
- Single JSON line, nothing else

**Success:**
```json
{"status":"complete","blockedCount":2,"resolutionTasks":3}
```

**No blocked tasks:**
```json
{"status":"complete","blockedCount":0,"message":"No blocked tasks in phase"}
```

**Error:**
```json
{"status":"error","error":"Description"}
```

The `/tmp/.prd_unblock_plan.json` file is the critical deliverable.

## Unblock Plan JSON Schema

### Top-Level Fields

| Field | Type | Required |
|-------|------|----------|
| `prd` | string | Yes |
| `phase` | string | Yes |
| `phaseName` | string | Yes |
| `blockedTasks` | array | Yes |
| `resolutionTasks` | array | Yes |

### FORBIDDEN Fields (Old Schema)

Do NOT include these fields:
- `sequentialTasks` - compile script creates waves
- `parallelGroups` - compile script creates waves
- `waves` - compile script creates waves
- `agent` - compile script assigns agent IDs

### blockedTasks Entry

| Field | Type | Description |
|-------|------|-------------|
| `taskId` | string | Original blocked task ID |
| `taskName` | string | Original task name |
| `blockReason` | string | Why task was blocked (or `skipReason` for Skipped tasks) |
| `status` | string | "Blocked", "NeedsClarification", or "Skipped" |

**Important**: Only include root cause blocked tasks in `blockedTasks`. Do NOT include Skipped tasks — they will automatically transition to Pending once their blocked dependencies are resolved.

### resolutionTasks Entry

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `taskId` | string | Yes | UNBLOCK-X.Y or RETRY-X.Y format |
| `taskName` | string | Yes | Description of resolution work |
| `taskType` | string | Yes | create-file, edit-file, verify, etc. |
| `model` | string | Yes | "haiku", "sonnet", or "opus" |
| `originalBlockedTask` | string | Yes | Reference to original blocked task ID |
| `resolution` | string | Yes | What this task does to resolve the blocker |
| `targetFiles` | array | No | Files to create/modify |
| `dependsOn` | array | Yes | Task IDs this depends on (can be empty []) |
