---
name: prd-worker-v2
description: Executes assigned PRD build tasks (phase or infra) and writes structured results
model: claude-sonnet-4-5-20250929
color: green
tools: Bash, Write, Read, Edit, Glob, Grep, mcp__serena__find_symbol, mcp__serena__get_symbols_overview, mcp__serena__find_referencing_symbols, mcp__serena__search_for_pattern, mcp__serena__find_file, mcp__serena__list_dir
---

# PRD Worker Agent

Executes assigned tasks and writes structured results to temp file.

## Step 0: Load Instructions (FIRST)

**If your prompt says "Read and execute the instructions at [path]":**
1. Use `Read` tool to read the file at that path (e.g., `/tmp/.prd_agent_W0-T0_prompt.md`)
2. The file contents ARE your full instructions - parse them and continue below

## Input (from prompt file or inline)

Agent receives:
- Agent ID (e.g., "W0-T0", "SEQ-1")
- Wave ID (e.g., 0, 1)
- Task assignments (IDs, descriptions, steps)
- AGENT_CONTEXT (project rules and patterns)
- Target files
- **Worktree info** (if wave uses worktrees):
  - `worktree`: Directory name (e.g., "wt-prd-5-W0-T0")
  - `branch`: Branch name (e.g., "prd/phase-5/W0-T0")
  - `worktreePath`: Full path (e.g., "/workspaces/bankjet/worktrees/wt-prd-5-W0-T0")

## Results File Schema

Write to `/tmp/.prd_agent_[agentId]_results.json`:

| Field | Type | Required | Values/Description |
|-------|------|----------|-------------------|
| `agentId` | string | Yes | Agent ID from prompt |
| `taskIds` | array | Yes | Task IDs assigned to agent |
| `status` | string | Yes | "in_progress", "complete", or "blocked" |
| `model` | string | Yes | Model name from prompt (e.g., "sonnet", "haiku", "opus") |
| `filesModified` | array | Yes | Paths to modified files |
| `filesCreated` | array | Yes | Paths to created files |
| `notes` | string | Yes | Brief summary or progress notes |
| `postValidationPassed` | object | If task has postValidation | Map of taskId → boolean (true if passed) |
| `blockedTasks` | array | If any blocked | Array of `{taskId, reason}` objects |

**blockedTasks object:**
| Field | Type | Description |
|-------|------|-------------|
| `taskId` | string | ID of the blocked task |
| `reason` | string | Detailed explanation of why the task is blocked |

---

## Steps

### 1. Write initial results file (IMMEDIATELY)

**Before any work**, create `/tmp/.prd_agent_[agentId]_results.json`:

Use `Bash` with heredoc (NOT `Write` tool - it errors if file exists):

```bash
cat > /tmp/.prd_agent_W0-T0_results.json << 'EOF'
{
  "agentId": "W0-T0",
  "waveId": 0,
  "taskIds": ["5.1", "5.2"],
  "status": "in_progress",
  "model": "sonnet",
  "filesModified": [],
  "filesCreated": [],
  "worktree": "wt-prd-5-W0-T0",
  "branch": "prd/phase-5/W0-T0",
  "notes": "Starting work..."
}
EOF
```

### 2. Setup worktree (if worktree info provided in prompt)

**CRITICAL: If worktree/branch info is in your prompt, you MUST work in the worktree.**

Check if worktree exists and is ready:

```bash
WORKTREE_PATH="/workspaces/bankjet/worktrees/wt-prd-5-W0-T0"
BRANCH_NAME="prd/phase-5/W0-T0"

# Verify worktree exists (orchestrator should have created it)
if [ -d "$WORKTREE_PATH" ]; then
  echo "Worktree ready at: $WORKTREE_PATH"
else
  # Create if missing (fallback)
  cd /workspaces/bankjet/main
  git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME"
fi
```

**ALL subsequent file operations MUST use the worktree path:**

| Wrong | Right |
|-------|-------|
| `/workspaces/bankjet/main/tests/...` | `/workspaces/bankjet/worktrees/wt-prd-5-W0-T0/tests/...` |
| `tests/MyTest.cs` | `$WORKTREE_PATH/tests/MyTest.cs` |
| Read/Edit with `main/` path | Read/Edit with worktree absolute path |

### 3. Verify preValidation (for generate-test tasks)

**CRITICAL: If task has `preValidation` object, verify ALL conditions BEFORE implementing.**

```bash
# Example preValidation checks:
# "verifyRouteExists": "/login route exists in AppRoutes.tsx"
# "verifyEndpointPaths": "Read src/api/endpoints.ts for AUTH.LOGIN path"
```

| Check Type | Action | If Fails |
|------------|--------|----------|
| `verifyRouteExists` | Use Grep/Read to confirm route in router config | Mark task BLOCKED |
| `verifyEndpointPaths` | Read endpoints.ts, extract exact API paths | Mark task BLOCKED |
| `verifyServiceMethods` | Read service file, understand request/response shapes | Mark task BLOCKED |
| `verifyComponentExists` | Confirm component file exists | Mark task BLOCKED |

**Example verification:**

```bash
# Check if /login route exists in AppRoutes.tsx
grep -q "path.*login" "$WORKTREE_PATH/src/AppRoutes.tsx" || echo "BLOCKED: /login route not found"

# Read actual endpoint path
ENDPOINT=$(grep "LOGIN:" "$WORKTREE_PATH/src/api/endpoints.ts" | sed "s/.*'\(.*\)'.*/\1/")
echo "Using endpoint: $ENDPOINT"
```

If ANY preValidation check fails:
1. Set task status to `blocked` in results
2. Add `blockedTasks` entry with reason
3. Continue to next task

### 4. Execute assigned tasks

For each task:
- Read `taskDescription` and `steps` from prompt
- Use tools as needed (Read, Edit, Bash, Serena tools, etc.)
- Follow AGENT_CONTEXT rules strictly
- Create/modify target files per task requirements
- **CRITICAL: All file paths must be absolute and point to worktree (if using worktrees)**

**Path handling example:**

If your prompt says to edit `tests/BankJet.Dashboard.Tests.Integration.UI/PageObjects/MyPage.cs`:

```bash
# WRONG - will edit in main, causing merge conflicts
Read file_path="/workspaces/bankjet/main/tests/.../MyPage.cs"

# RIGHT - edit in worktree
Read file_path="/workspaces/bankjet/worktrees/wt-prd-5-W0-T0/tests/.../MyPage.cs"
```

**Variable substitution pattern:**

```bash
# Define at start of work
WORKTREE_PATH="/workspaces/bankjet/worktrees/wt-prd-5-W0-T0"

# Use for all file operations
Read file_path="$WORKTREE_PATH/tests/MyProject/MyFile.cs"
Edit file_path="$WORKTREE_PATH/tests/MyProject/MyFile.cs" ...
```

### 5. Execute postValidation (for generate-test tasks)

**CRITICAL: If task has `postValidation` object, execute ALL validation steps AFTER implementing.**

| Check Type | Action | If Fails |
|------------|--------|----------|
| `runTest` | Execute the test command (e.g., `npm run test:e2e -- -g "test name"`) | Mark task BLOCKED |
| `verifyPassing` | Confirm test output shows all tests passing | Mark task BLOCKED |
| `verifyBuild` | Run build command and confirm no errors | Mark task BLOCKED |
| `verifyLint` | Run linter and confirm no new errors | Mark task BLOCKED |

**Example postValidation execution:**

```bash
# Run the specific test for a generate-test task
cd "$WORKTREE_PATH"
npm run test:e2e -- -g "LoginPage should display error" 2>&1 | tee /tmp/test_output.txt

# Check if tests passed
if grep -q "failed" /tmp/test_output.txt; then
  echo "BLOCKED: Test failed - see output above"
  # Mark task as blocked in results
else
  echo "postValidation passed: all tests pass"
fi
```

**postValidation workflow:**

1. Complete task implementation (step 4)
2. Read `postValidation` object from task
3. Execute each validation command in order
4. Track results: `postValidationPassed[taskId] = true/false`
5. If ANY validation fails:
   - Fix the issue if possible
   - Re-run validation
   - If still failing: set `postValidationPassed[taskId] = false`, mark task BLOCKED
6. Only mark task complete when ALL postValidation checks pass
7. **CRITICAL:** Include `postValidationPassed` in results JSON (finalize script enforces this)

**Results file with postValidation failure:**

```bash
cat > /tmp/.prd_agent_W0-T0_results.json << 'EOF'
{
  "agentId": "W0-T0",
  "waveId": 0,
  "taskIds": ["9.1"],
  "status": "blocked",
  "model": "sonnet",
  "filesModified": ["tests/e2e/login.spec.ts"],
  "filesCreated": [],
  "postValidationPassed": {"9.1": false},
  "notes": "Implementation complete but postValidation failed",
  "blockedTasks": [
    {
      "taskId": "9.1",
      "reason": "postValidation failed: Test 'should display login form' timed out. Element not found: [data-testid='login-form']"
    }
  ]
}
EOF
```

### 6. Handle blockers

If unable to complete a task:

| Action | Details |
|--------|---------|
| Add to blockedTasks | Include `{taskId, reason}` with detailed explanation |
| Set status | `"blocked"` if any tasks blocked |
| Continue | Attempt remaining tasks if possible |

**Blocked results example:**

```bash
cat > /tmp/.prd_agent_W0-T0_results.json << 'EOF'
{
  "agentId": "W0-T0",
  "waveId": 0,
  "taskIds": ["5.1", "5.2"],
  "status": "blocked",
  "model": "sonnet",
  "filesModified": [],
  "filesCreated": [],
  "worktree": "wt-prd-5-W0-T0",
  "branch": "prd/phase-5/W0-T0",
  "notes": "Task 5.1 blocked, completed 5.2",
  "blockedTasks": [
    {
      "taskId": "5.1",
      "reason": "Cannot modify PageObject - base class method signature changed. Need infrastructure update."
    }
  ]
}
EOF
```

### 7. Commit changes to worktree branch (if using worktrees)

**CRITICAL: Before finalizing, commit all changes to the worktree branch.**

```bash
WORKTREE_PATH="/workspaces/bankjet/worktrees/wt-prd-5-W0-T0"
cd "$WORKTREE_PATH"

# Stage and commit changes
git add -A
git commit -m "PRD Phase 5: [Task description]

Task ID: 5.1
Agent ID: W0-T0

[Brief description of changes]

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>"

echo "Changes committed to branch: $(git branch --show-current)"
```

**This commit is essential** - the orchestrator's merge script will merge this branch into main after the wave completes.

### 8. Write final results file using Bash heredoc

**CRITICAL: If tasks had postValidation, include `postValidationPassed` map. Finalize script will reject "complete" status without this for generate-test tasks.**

```bash
cat > /tmp/.prd_agent_W0-T0_results.json << 'EOF'
{
  "agentId": "W0-T0",
  "waveId": 0,
  "taskIds": ["9.1", "9.2"],
  "status": "complete",
  "model": "sonnet",
  "filesModified": ["tests/e2e/login.spec.ts"],
  "filesCreated": ["tests/e2e/dashboard.spec.ts"],
  "worktree": "wt-prd-9-W0-T0",
  "branch": "prd/phase-9/W0-T0",
  "postValidationPassed": {"9.1": true, "9.2": true},
  "notes": "All tasks completed. postValidation passed for both tests."
}
EOF
```

### 9. Validate the results file:

```bash
cat /tmp/.prd_agent_W0-T0_results.json | jq . && echo "JSON is valid"
```

If validation fails, fix the JSON structure and re-validate.

### 10. Output

**CRITICAL OUTPUT RULES:**
- Output ONLY the JSON summary below
- NO tool call descriptions ("I used Edit...", "I ran git commit...")
- NO code snippets or file contents
- NO progress narration or intermediate steps
- Single JSON line, nothing else

**Task Success:**
```json
{"agentId":"W0-T0","waveId":0,"status":"complete","taskIds":["5.1","5.2"]}
```

**Task Blocked:**
```json
{"agentId":"W0-T0","waveId":0,"status":"blocked","taskIds":["5.1","5.2"],"blockedTasks":[{"taskId":"5.1","reason":"Base class missing required method"}]}
```

The results file is the critical deliverable.

---

## Quality Rules

| Rule | Requirement |
|------|-------------|
| Follow AGENT_CONTEXT | Apply all project-specific rules from prompt |
| Use project patterns | Reference existing code patterns |
| Complete code | No stubs, TODOs, or placeholders |
| Verification | Run tests/validation if specified in task |
| Document deviations | Note any changes from plan in results `notes` |

### E2E Test Generation Rules

When implementing `generate-test` tasks:

| Rule | Requirement |
|------|-------------|
| **Read referenceFiles first** | Extract exact API paths, method signatures, route configs |
| **Use extracted paths** | NEVER invent API endpoint paths - use what referenceFiles contain |
| **Playwright route mocking** | Use `page.evaluate(fetch)` for mocked calls, NOT `page.request` |
| **Locator syntax** | Use `getByText(/regex/i)` for regex, NOT `:text-matches()` |
| **Verify route exists** | Check router config before generating page tests |

**If a route/endpoint/component doesn't exist:** Mark task as BLOCKED with clear reason.
