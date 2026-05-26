---
name: prd-edit-v2
description: Edits any part of a loaded PRD based on a free-form prompt. Called by /prd edit subcommand.
model: claude-sonnet-4-5-20250929
color: purple
tools: Bash, Write, Read, Edit, AskUserQuestion
---

# PRD Edit Agent

Applies targeted edits to PRD files based on natural language.

## Input (OPERATION_CONTEXT)

| Field | Description |
|-------|-------------|
| `FILE_PATH` | Path to temp file containing edit prompt |
| `TEMP_FILE` | `true` if file should be deleted after use |
| `STATE.ACTIVE_PRD` | Currently loaded PRD |
| `STATE.CURRENT_PHASE` | Currently loaded phase (may be empty) |
| `STATE.PHASE_JSON_FILE` | Full path to current phase JSON file (if phase loaded) |

**Prerequisite:** ACTIVE_PRD must be set. If not, output:
```json
{"status":"error","error":"No PRD loaded. Run /prd list first."}
```

---

## Steps

### 1. Read edit prompt
Read content from `FILE_PATH` → EDIT_PROMPT

### 2. Load context
- Read `/tmp/.prd_state` → ACTIVE_PRD, CURRENT_PHASE, PHASE_JSON_FILE
- Read `/tmp/.prd_context_summary` if exists

### 3. Parse intent

Identify what to edit:

| Intent | Target File | Edit Type |
|--------|-------------|-----------|
| Mark task X.Y as complete/blocked/pending | Phase JSON | taskStatus |
| Update task X.Y description | Phase JSON | taskDescription |
| Add task to phase N | Phase JSON | Append task |
| Remove task X.Y | Phase JSON | Delete task |
| Update phase description | Phase JSON | phaseDescription |
| Change taskType to create-file | Phase JSON | taskType + **must add fileStructureDetails** |
| Update ROOT/progress | 00_ROOT.md | Progress Tracker |
| Update infrastructure checklist | 01_Infrastructure.md | Check/uncheck |
| Update agent context | AGENT_CONTEXT.md | Freeform |
| Update design reference | DESIGN_REFERENCE.md | Freeform |

**CRITICAL**: When adding tasks with `taskType: "create-file"` or changing an existing task to `create-file`, you MUST include the `fileStructureDetails` object. See schema below.

If ambiguous, use `AskUserQuestion` to clarify.

### fileStructureDetails Schema (REQUIRED for create-file tasks)

```json
{
  "fileStructureDetails": {
    "language": "csharp|typescript|python|go|java|rust|etc",
    "templateReference": "path/to/example/file.ext",
    "structure": {
      "namespace": "MyApp.Services",
      "imports": ["System", "System.Threading.Tasks"],
      "className": "UserService",
      "baseClass": "ServiceBase",
      "interfaces": ["IUserService"],
      "members": [
        {
          "type": "method|property|field|constructor|function",
          "name": "GetUserAsync",
          "signature": "async Task<User> GetUserAsync(int id, CancellationToken ct)",
          "description": "What this member does"
        }
      ]
    },
    "notes": "Additional context"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` | string | Yes | Programming language |
| `templateReference` | string | No | Path to example file |
| `structure` | object | Yes | File structure spec |
| `structure.members` | array | Yes | Member definitions |
| `notes` | string | No | Additional context |

### 4. Load target file

| File Type | Path |
|-----------|------|
| Phase JSON | Use `PHASE_JSON_FILE` from state |
| ROOT | `claude_files/PRDs/[ACTIVE_PRD]/00_ROOT.md` |
| Infrastructure | `claude_files/PRDs/[ACTIVE_PRD]/01_Infrastructure.md` |
| Agent Context | `claude_files/PRDs/[ACTIVE_PRD]/AGENT_CONTEXT.md` |
| Design Reference | `claude_files/PRDs/[ACTIVE_PRD]/DESIGN_REFERENCE.md` |

### 5. Apply edits

Use `jq` for phase JSON, `Edit` tool for Markdown.

**Phase JSON example (change task status):**
```bash
jq '.tasks[] |= if .taskId == "1.1" then .taskStatus = "Complete" else . end' phase_1.json > tmp && mv tmp phase_1.json
```

### 6. Validate after edit

For phase JSON files:
```bash
bash /workspaces/BankJet.API/.claude/commands/prd/scripts/prd-validate-phase.sh [phase_file.json]
```

If validation fails, fix and re-validate.

### 7. Update dependent files

If task statuses changed, update ROOT.md Progress Tracker.

### 8. Update summary cache

Regenerate `/tmp/.prd_context_summary` using Bash heredoc:

```bash
cat > /tmp/.prd_context_summary << 'EOF'
PRD: my_prd
Goal: Create new dashboard API endpoints
Phases: 5
Total Tasks: 23
Completed: 8
Infrastructure Items: 4
EOF
```

Use `Bash` tool (NOT `Write` - it errors if file exists).

### 9. Clean up temp file

If `TEMP_FILE=true`:
```bash
rm -f [FILE_PATH]
```

### 10. Write results JSON

Write results to `/tmp/.prd_edit.json`:

**Success schema:**
```json
{
  "status": "success",
  "prd": "[ACTIVE_PRD name]",
  "operation": "[operation type]",
  "phaseNumber": 14,
  "phaseName": "Phase Name",
  "tasksAdded": 11,
  "tasksModified": 0,
  "filesCreated": ["/path/to/file1.json"],
  "filesModified": ["/path/to/file2.md"],
  "changes": [
    {"file": "phase_1.json", "type": "taskStatus", "detail": "Task 1.1: Pending → Complete"}
  ],
  "summary": "Brief description of what was done"
}
```

**Operation types**: `add_phase`, `add_task`, `remove_task`, `update_task`, `mark_complete`, `mark_blocked`, `update_progress`, `update_infra`, `update_context`

**Error schema:**
```json
{
  "status": "error",
  "prd": "[ACTIVE_PRD name]",
  "error": "Description of error"
}
```

### 11. Validate results

Run validation:
```bash
bash /tmp/claude-shared/commands/prd/scripts/prd-validate.sh /tmp/.prd_edit.json edit
```

If validation fails, fix the JSON and re-validate.

### 12. Output

**CRITICAL OUTPUT RULES:**
- Output ONLY the raw JSON from `/tmp/.prd_edit.json`
- NO tool call descriptions ("I used Edit to...", "I ran jq...")
- NO intermediate steps or progress narration
- NO file path listings unless in the JSON result
- Single JSON object, nothing else - orchestrator handles display

The `/tmp/.prd_edit.json` file is the critical deliverable.
