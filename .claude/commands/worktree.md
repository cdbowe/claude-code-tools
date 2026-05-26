---
name: worktree
description: Execute tasks in parallel git worktrees (bare repo optimized)
# disable-model-invocation: true
allowed-tools: Bash, Task, TaskOutput, Read, Glob, Grep
model: claude-opus-4-5-20251101
argument-hint: [task prompt]
---

# Worktree Parallel Execution (Bare Repository)

Execute: `$ARGUMENTS`

---

## Constants (Preprocessed)

**Paths resolved from `WORKSPACE_DIR` environment variable at skill load time.**

| Constant | Value |
|----------|-------|
| SCRIPTS_DIR | !`echo $WORKSPACE_DIR/.claude/commands/scripts` |
| PRD_SCRIPTS | !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts` |
| MAIN_DIR | !`echo ${WORKTREE_MAIN_DIR:-$WORKSPACE_DIR/main}` |
| WORKTREES_DIR | !`echo $WORKSPACE_DIR/worktrees` |

---

## Pre-flight Checks

Run before any work:

```bash
# WORKSPACE_DIR must be set by devcontainer
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo "ERROR: WORKSPACE_DIR environment variable not set" && exit 1
fi

GIT_DIR="$WORKSPACE_DIR/.git"

# Verify we're in a bare repository setup
if ! git --git-dir="$GIT_DIR" config core.bare 2>/dev/null | grep -q "true"; then
    echo "ERROR: Not a bare repository. Run migration script first." && exit 1
fi

# Verify main worktree exists
cd "$WORKSPACE_DIR/main" || (echo "ERROR: main worktree not found" && exit 1)

# Commit any uncommitted changes (uses check-main.sh logic internally)
bash "$WORKSPACE_DIR/.claude/commands/scripts/commit-main.sh" "Pre-worktree pre-flight commit" 2>/dev/null || true

# Create worktrees directory if needed
mkdir -p "$WORKSPACE_DIR/worktrees"
```

---

## Step 1: Task Decomposition

Analyze work into independent units. 

**Independence criteria** (ALL must be true):

| Criterion | Test |
|-----------|------|
| File isolation | Modifies different files than other units |
| No output dependencies | Doesn't need output from other units |
| Testable alone | Can verify correctness without other units |

**Grouping strategy:**

| Work Type | Group By |
|-----------|----------|
| Multi-file refactor | File or module |
| Feature implementation | Component |
| Bug fixes | Individual bug |
| Test updates | Test file |

**Maximum unit count:**

| Condition | Value |
|-----------|-------|
| Prompt argument indicates max group or unit count | Max count from prompt argument (override default) |
| Default | 5 |

**Output:**
1. Numbered list with scope (files/dirs each unit will modify)
2. Build manifest to `/tmp/.worktree_build.json` (REQUIRED for Step 3+ execution)

Manifest format:

```json
{
  "status": "ready_to_build",
  "buildType": "worktree",
  "waves": [
    {
      "waveId": 0,
      "useWorktrees": true,
      "agents": [
        {
          "agentId": "W0-T0",
          "waveId": 0,
          "model": "haiku|sonnet|opus",
          "worktree": "wt-unit-1",
          "branch": "worktree/unit-1",
          "agentHint": "Optional hint for the agent (e.g., test commands, build instructions)",
          "prompt": "Full task prompt (passed to agent)"
        }
      ]
    }
  ]
}
```

**Fields:**
- `agentId`: Unique agent identifier within wave (e.g., W0-T0, W0-T1)
- `model`: Model for this unit's agent (haiku/sonnet/opus)
- `worktree`: Worktree directory name (must be unique, no spaces)
- `branch`: Branch name (typically `worktree/{unit-name}`)
- `agentHint`: Optional context hint (test commands, build instructions, gotchas)
- `prompt`: Full task prompt — use Prompt Template structure (Step 4)

---

## Step 2: Model Assignment

| Unit Complexity | Model | When |
|-----------------|-------|------|
| Simple | `haiku` | <10 lines, no logic changes (rename, format) |
| Standard | `sonnet` | 10-100 lines, clear requirements |
| Complex | `opus` | >100 lines OR ambiguous requirements |

---

## Step 2b: Commit Uncommitted Main Changes

**Before creating worktrees, ensure main branch has no uncommitted changes.**

```bash
bash $WORKSPACE_DIR/.claude/commands/scripts/commit-main.sh "Pre-worktree execution commit"
```

---

## Step 3: Pre-Create Worktrees

**Before spawning agents, pre-create ALL worktrees for the wave.**

This ensures worktrees exist before agents start, avoiding race conditions.

```
FOR each wave in manifest.waves:
  FOR each agent in wave.agents:
    worktreeName = agent.worktree  # e.g., "wt-unit-1"
    branchName = agent.branch      # e.g., "worktree/unit-1"

    Run: bash !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-create.sh "$worktreeName" "$branchName" main
```

---

## Step 4: Spawn Workers (PARALLEL)

**Context optimization**: Prompts written to temp files (`/tmp/.worktree_agent_{agentId}_prompt.md`) instead of inline.

For EACH agent in the manifest:

1. **Extract prompt from manifest and write to temp file:**
   ```bash
   jq -r ".waves[$waveId].agents[$agentIndex].prompt" /tmp/.worktree_build.json > /tmp/.worktree_agent_${agentId}_prompt.md
   ```

2. **Launch agent with minimal 1-line prompt:**
   ```
   Task(
     subagent_type: "general-purpose",
     model: agent.model,
     prompt: "Read and execute the instructions at /tmp/.worktree_agent_[agentId]_prompt.md",
     run_in_background: true
   )
   ```

### Prompt Template (written to temp file)

The manifest `prompt` field uses this structure.

**Substitution:** Use bash preprocessing to resolve paths at manifest generation time. The orchestrator substitutes `[WORKTREE_NAME]` and `[BRANCH_NAME]` with actual values when writing the manifest.

```
# [agentId]: [UNIT_NAME]

## EXECUTION CONTEXT

| Property | Value |
|----------|-------|
| **Worktree** | `!`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]` |
| **Branch** | `[BRANCH_NAME]` |
| **Main (OFF-LIMITS)** | `!`echo $WORKSPACE_DIR`/main` |

---

## ⛔ CRITICAL RULES (READ FIRST)

1. **Location**: You MUST work in `!`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]`
   - Verify: `pwd` must output the worktree path
   - If wrong: STOP and `cd !`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]`

2. **Branch**: You MUST stay on `[BRANCH_NAME]`
   - Verify: `git branch` must show `* [BRANCH_NAME]`
   - If on `main` or wrong branch: STOP and report error — DO NOT CONTINUE

3. **Exit protocol**: After commit → write results JSON → EXIT
   - NEVER merge, rebase, or push
   - Orchestrator handles all integration

---

## ❌ FORBIDDEN ACTIONS

- `cd !`echo $WORKSPACE_DIR`/main` — Main worktree is off-limits
- `git checkout main` — Never switch to main branch
- `git push` — Never push (orchestrator handles)
- `git merge` / `git rebase` — Never merge or rebase
- Editing files in `!`echo $WORKSPACE_DIR`/main/` — Main files are locked

If uncertain, STOP and report rather than guessing.

---

## Setup Verification (EXECUTE FIRST)

```bash
cd !`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]

# 1. Verify location
pwd
# Expected: !`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]

# 2. Verify branch (CRITICAL)
git branch
# Expected: * [BRANCH_NAME]
# If output shows * main, STOP IMMEDIATELY
```

If EITHER verification fails, STOP and report the error. Do NOT proceed.

---

## Your Task

Scope: [FILES/DIRS]
[If agentHint present: **Agent Hint**: [AGENT_HINT]]

[DETAILED WORK INSTRUCTIONS]

---

## Commit (WITH MANDATORY VERIFICATION)

**BEFORE committing, verify branch:**

```bash
# MANDATORY: Verify you're on the correct branch
git branch
# Must show: * [BRANCH_NAME]
# ⛔ If it shows * main, STOP and report error — DO NOT COMMIT

# MANDATORY: Verify location
pwd
# Must show: !`echo $WORKSPACE_DIR`/worktrees/[WORKTREE_NAME]

# Only if BOTH checks pass:
git add -A && git commit -m "[agentId]: [DESCRIPTION]

Branch: [BRANCH_NAME]
Worktree: [WORKTREE_NAME]

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## Results

Write to /tmp/.worktree_agent_[agentId]_results.json:
{"agentId":"[agentId]","waveId":[waveId],"status":"complete|blocked","filesModified":[],"notes":"..."}

Report: DONE: [agentId] or FAILED: [agentId] - [REASON]

⛔ After commit and results JSON: EXIT IMMEDIATELY.
Orchestrator handles merges. Do NOT merge, push, or continue work.
```

**CRITICAL:** Use `run_in_background: true` for all subagents.

**WAIT:** Block with `TaskOutput` until ALL subagents return DONE or FAILED.

---

## Step 5: Merge (SEQUENTIAL)

1. **Validate manifest:**
   ```bash
   bash !`echo $WORKSPACE_DIR`/.claude/commands/prd/scripts/prd-validate.sh /tmp/.worktree_build.json worktree-manifest-core
   ```
   If invalid: Output error — STOP

2. **Merge all waves with conflict resolution:**

   ```
   FOR each wave in manifest.waves:
     waveId = wave.waveId

     Run: bash cd !`echo $WORKSPACE_DIR` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh /tmp/.worktree_build.json "$waveId" worktree_agent

     # Parse merge result and handle based on status
     Parse JSON output for status field

     IF status == "complete":
       Continue to next wave

     IF status == "needs_resolution":
       # Spawn conflict resolver agent
       Write conflict resolver prompt to /tmp/.worktree_agent_conflict_W${waveId}_prompt.md:
         "Resolve conflicts for wave $waveId. Read conflict details from /tmp/.prd_conflict_${waveId}.json"

       Task(
         subagent_type: "conflict-resolver",
         model: !`echo $SONNET_MODEL`,
         prompt: "Read and execute the instructions at /tmp/.worktree_agent_conflict_W${waveId}_prompt.md"
       )

       Parse resolution from /tmp/.prd_conflict_resolution_${waveId}.json

       IF resolution.status == "resolved":
         # Retry merge for resolved branches
         Run: bash cd !`echo $WORKSPACE_DIR` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh --retry /tmp/.worktree_build.json $waveId worktree_agent
         IF retry succeeds: Continue to next wave
         ELSE: Output error — STOP

       IF resolution.status == "partial" OR resolution.status == "failed":
         Output: "⚠️ Merge conflicts require manual resolution"
         Output conflict details from resolution JSON
         STOP

     IF status == "partial":
       Output error with conflict list — STOP
   ```

3. **Merge script behavior:**
   - Phase 1: Attempt parallel merge (fast path)
   - Phase 2: Sequential rebase+merge for conflicts
   - Phase 3: Output `needs_resolution` status for AI handling
   - Skips blocked agents
   - Cleans up worktree and branch on success
   - Reports merged/skipped/failed/needs_resolution counts

4. **Clean up temp prompt files:**
   ```bash
   rm -f /tmp/.worktree_agent_*_prompt.md
   ```

---

## Output Format

```
## Completed
- [unit-a] Merged successfully
- [unit-b] Merged successfully

## Failed
- [unit-c] Merge conflict in: src/file.cs (lines 10-15)
- [unit-d] Subagent error: "compilation failed"

## Remaining Worktrees
[List any worktrees not cleaned up, with paths]

## Summary
[2-3 sentences: what was accomplished, what needs manual attention]
```

---

## Error Recovery

| Failure | Recovery |
|---------|----------|
| Pre-flight fails (dirty repo) | Abort. Instruct user to commit or stash. |
| Pre-flight fails (not bare) | Abort. Instruct user to run migration script. |
| Worktree creation fails | Run `git worktree prune`, retry once. |
| Subagent timeout | Kill via `TaskOutput`, keep worktree, report as FAILED. |
| Merge conflict (parallel) | Automatic: Sequential rebase+merge fallback. |
| Merge conflict (rebase) | Automatic: AI conflict-resolver agent attempts resolution. |
| Merge conflict (AI fails) | Stop. Report files and conflict details. User resolves manually. |
| Partial completion | Report completed merges. Preserve failed worktrees with paths. |

---

## Cleanup Command (Manual)

If needed, user can run:

```bash
# Using the shared cleanup script
bash !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-cleanup.sh "wt-*"

# Or manually
cd "$WORKSPACE_DIR/main"
git worktree list | grep "$WORKSPACE_DIR/worktrees" | awk '{print $1}' | xargs -I {} git worktree remove {}
git branch --list "worktree/*" | xargs -I {} git branch -D {}
```

---

## Bare Repository Benefits

- **Symmetry**: All worktrees (including main) are equal
- **Clarity**: Git operations work from `$WORKSPACE_DIR` or any worktree
- **Safety**: No confusion about "primary" vs "linked" worktrees
- **Standard**: Follows git worktree best practices

---

## Directory Structure

```
$WORKSPACE_DIR/                    # Workspace root (env var)
├── .git/                          # Bare repository
│   ├── worktrees/
│   │   ├── main/                  # Metadata for main worktree
│   │   └── wt-*/                  # Metadata for parallel worktrees
│   └── ...
├── main/                          # Main worktree (equal to others)
│   ├── .git                       # File: gitdir: ../.git/worktrees/main
│   ├── src/                       # Bound from host
│   ├── tests/                     # Bound from host
│   └── ...
└── worktrees/                     # Parallel worktrees
    ├── wt-unit-1/
    ├── wt-unit-2/
    └── ...
```
