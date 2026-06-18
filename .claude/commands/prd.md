---
allowed-tools: Task, TaskOutput, Bash, Read, AskUserQuestion
argument-hint: "stat | list [search_text] | load <search_text> | read <phase> | plan | build [phase] [--next] [--tasks-per-wave N] \n| plan-unblock [prompt] | unblock [prompt] | gen <prompt> | gen --file <path> | edit <prompt> | review <phase> | review-all"
description: PRD management - Script-first orchestration with JSON agent output
---

# MANDATORY OUTPUT RULES

**CRITICAL: You are a SILENT orchestrator. Your ONLY output is script stdout.**

## FORBIDDEN OUTPUT (VIOLATIONS):

```
Here's the result:
[script output]
```
```
I'll run the command for you.
[script output]
```
```
[script output]

Let me know if you need anything else.
```
```
The operation completed successfully. Here's what happened:
[script output]
```

## CORRECT OUTPUT (ONLY ACCEPTABLE):

```
[EXACT script stdout - nothing before, nothing after]
```

**YOU ARE A PASSTHROUGH. SCRIPTS SPEAK. YOU ARE SILENT.**

---

# PRD Skill — Script-First Orchestrator

Routes `/prd` subcommands to scripts (preferred) or specialized agents.

## Constants (Preprocessed)

**Paths are resolved from `WORKSPACE_DIR` environment variable at skill load time.**

| Constant | Value |
|----------|-------|
| SCRIPTS_DIR | !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts` |
| AGENTS_DIR | !`echo $WORKSPACE_DIR/.claude/agents/prd` |
| PRD_BASE | !`echo $WORKSPACE_DIR/claude_files/PRDs` |

## Parsed Arguments

```
$ARGUMENTS
```

Extract:
- `SUBCOMMAND`: stat, list, load, read, gen, plan, build, plan-unblock, unblock, edit, review, review-all, help
- Fields: PHASE_NUM, INPUT_MODE, FILE_PATH, TEMP_FILE, ERROR, TASKS_PER_WAVE (from `--tasks-per-wave <N>`), SEARCH_TEXT (for `list [search_text]` or `load <search_text>`), NEXT_FLAG (true if `--next` present), UNBLOCK_PROMPT (for `plan-unblock [prompt]` or `unblock [prompt]`)

---

## Routing Table

| Subcommand | Handler | Type |
|------------|---------|------|
| `stat` | `prd-stat.sh` | script |
| `list` | `prd-list.sh` | script |
| `load` | `prd-load.sh` | script |
| `read` | `prd-read.sh` | script |
| `plan` | `prd-plan-inject.sh` (UserPromptSubmit hook, stdout) | hook (no action) |
| `plan-unblock` | `prd-unblock` agent + display script | agent+script |
| `build [phase]` | (optional) read+plan, then compile + workers + finalize + display | hybrid |
| `unblock` | compile script + workers + finalize script + display script | hybrid |
| `gen` | `prd-gen` agent + display script | agent+script |
| `edit` | `prd-edit` agent + validate + display script | agent+script |
| `review` | `prd-reviewer` agent + validate + display script | agent+script |
| `review-all` | compile + parallel reviewers + aggregate + apply + display | hybrid |

---

## Step 1: Read State

```bash
if [ -f /tmp/.prd_state ]; then cat /tmp/.prd_state; fi
```

Parse: ACTIVE_PRD, CURRENT_PHASE, PHASE_JSON_FILE

---

## Step 2: Route by SUBCOMMAND

### `help` or `UNRECOGNIZED`

Output EXACTLY (no intro, no outro):

```
## PRD Management Tool

**Usage**:
- `/prd stat` - Show current PRD status
- `/prd list [search]` - Browse and load a PRD (optional: filter by name)
- `/prd load <search>` - Load PRD by name (requires exactly one match)
- `/prd read <phase>` - Load a specific phase (0 = infrastructure)
- `/prd plan` - Generate execution plan for loaded phase
- `/prd build [phase] [--next] [--tasks-per-wave N]` - Execute plan (default 10 tasks/wave)
- `/prd build --next` - Auto-build next phase (increments current phase by 1)
- `/prd plan-unblock [prompt]` - Investigate blocked tasks and generate unblock plan (optional: guidance prompt)
- `/prd unblock [prompt]` - Execute unblock plan to resolve blocked tasks (optional: guidance prompt)
- `/prd gen <prompt>` - Generate new PRD from prompt
- `/prd gen --file <path>` - Generate PRD from goal file
- `/prd edit <prompt>` - Edit any part of the loaded PRD
- `/prd review <phase>` - Review phase for ambiguities and missing details
- `/prd review-all` - Review all phases, apply auto-fixes, report readiness
- `/prd review-all --read-only` - Review all phases without applying edits
- `/prd review-all --cache-only` - Re-display last review from cached files

**Workflows**:
1. Build phase: `list` → `build <N>` (or: `read <N>` → `plan` → `build`)
2. Build next phase: `build --next` (auto-increments from current phase)
3. Unblock: `read <N>` → `plan-unblock` → `unblock` → `plan` → `build`
4. Comprehensive Review: `list` → `review-all` → `plan` → `build`
```

If UNRECOGNIZED, prepend ONLY: `Unknown command: [cmd]\n\n`

**STOP. NO AGENT. NO ADDITIONAL TEXT.**

---

### `stat`

1. Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-stat.sh`
2. Output script stdout EXACTLY. Nothing else.

---

### `list`

1. Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-list.sh [SEARCH_TEXT]`
   (If SEARCH_TEXT provided, pass it as argument to filter PRDs by name)

2. Check: `jq -e '.status == "awaiting_selection"' /tmp/.prd_list.json 2>/dev/null`

3. **If awaiting selection**:
   - Parse options from JSON
   - Call AskUserQuestion.
      - **If more than 4 options:** separate every 4 options into their own question. Expect a **SINGLE** selection.
   - Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-list.sh "[selection]"`
   - Output stdout EXACTLY

4. **If direct output** (single match auto-selected, no matches, or error): Output stdout EXACTLY

---

### `load`

1. If no SEARCH_TEXT provided: Output `Error: search_text required. Usage: /prd load <search_text>` — STOP

2. Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-load.sh [SEARCH_TEXT]`

3. Output script stdout EXACTLY. Nothing else.

---

### `read`

1. If no ACTIVE_PRD: Output `No PRD loaded. Run \`/prd list\` first.` — STOP

2. Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-read.sh [PHASE_NUM]`

3. Check: `jq -e '.status == "awaiting_selection"' /tmp/.prd_read.json 2>/dev/null`

4. **If awaiting selection**:
   - Parse options from JSON
   - Call AskUserQuestion
      - **If more than 4 options:** separate every 4 options into their own question. Expect a **SINGLE** selection.
   - Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-read.sh "[selection]"`
   - Output stdout EXACTLY

5. **If direct output**: Output stdout EXACTLY

---

### `plan`

**Hook-generated output passthrough.** The `prd-plan-inject.sh` UserPromptSubmit hook has ALREADY executed the plan pipeline and written output to `/tmp/.prd_plan_display.txt`.

1. Check file exists: `[ -f /tmp/.prd_plan_display.txt ]`
   - If missing: Output `No plan output found. Ensure /prd plan was invoked correctly.` — STOP

2. Run: `cat /tmp/.prd_plan_display.txt`

3. Output stdout EXACTLY. Nothing else.

---

### `build`

**⚠️ CONTEXT OPTIMIZATION: FILE-BASED PROMPTS**

To minimize parent context consumption, prompts are written to temp files instead of passed inline.
- Each agent's prompt is written to `/tmp/.prd_agent_{agentId}_prompt.md`
- Task receives a 1-line instruction to read and execute that file
- This reduces parent context from ~200 lines/agent to ~1 line/agent

**⛔ AGENT DIRECTIVE (compile script MUST include in prompts):**
```
## ⛔ EXIT AFTER COMMIT (MANDATORY)
After commit: write results JSON → EXIT. NEVER merge/rebase/resolve conflicts. Orchestrator handles merges.
```

---

**-1. Handle `--next` flag (auto-increment phase)**

If NEXT_FLAG is true:

   a. **Run resolver script**:
      ```bash
      bash !`echo $WORKSPACE_DIR`/.claude/commands/prd/scripts/prd-resolve-next-phase.sh
      ```
      Parse JSON output with jq.

   b. **Handle result based on status**:

      | `status` | Action |
      |----------|--------|
      | `error` | Output error message from JSON — STOP |
      | `complete` | Output `✅ PRD complete — all phases finished.` then run `!`echo $WORKSPACE_DIR`/.claude/commands/prd/scripts/prd-stat.sh` — STOP |
      | `corrupted` | Output `Error: Phase [targetPhase] not found but is within range (0-[finalPhase]). Phase files may be corrupted. Run \`/prd edit fix phase numbering\` to repair.` — STOP |
      | `success` | Set `PHASE_NUM = targetPhase` from JSON, continue to step 0 |

---

**0. Check for PHASE_NUM argument (combined workflow)**

If PHASE_NUM is provided (e.g., `/prd build 3` or resolved from `--next`), run combined `read` → `plan` → `build`:

   a. **Run read**: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-read.sh [PHASE_NUM]`
      - Check: `jq -e '.status == "awaiting_selection"' /tmp/.prd_read.json 2>/dev/null`
      - If awaiting selection: Output `Ambiguous phase number. Multiple matches found.` — STOP
      - Output read stdout to transcript

   b. **Run plan** (replicate hook logic):
      - Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-plan.sh [TASKS_PER_WAVE]`
        (If TASKS_PER_WAVE not set, omit argument to use default of 10)
      - Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_plan.json plan`
        - If invalid: Output error — STOP
      - Display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh plan /tmp/.prd_plan.json`
      - Output plan display stdout to transcript

   c. **Check for empty waves**:
      ```bash
      waveCount=$(jq '.waves | length' /tmp/.prd_plan.json)
      ```
      - If `waveCount == 0`:
        - Count skipped tasks: `jq '[.tasks[] | select(.taskStatus == "Skipped")] | length' $PHASE_JSON_FILE`
        - If skippedCount > 0: Output `⚠️ Some tasks are Skipped` — STOP
        - Else: Output `✅ All tasks already completed` — STOP

   d. Continue to step 1 below (normal build)

If NO PHASE_NUM provided:
   - If TASKS_PER_WAVE is set: Re-run plan with override before building:
     - Run: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-plan.sh [TASKS_PER_WAVE]`
     - Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_plan.json plan`
       - If invalid: Output error — STOP
     - Display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh plan /tmp/.prd_plan.json`
     - Output plan display stdout to transcript
   - Proceed to step 1

---

1. Check ACTIVE_PRD and CURRENT_PHASE. If missing: Output error — STOP

2. Run compile: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-build-compile.sh`

3. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_build.json build`
   If invalid: Output error — STOP

3b. Validate worktree manifest (PRD-specific schema): `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_build.json worktree-manifest-prd`
   If invalid: Output error — STOP

4. Read waves: `jq -c '.waves[]' /tmp/.prd_build.json`

4b. **Commit uncommitted main changes** (before worktree creation):
   ```bash
   bash $WORKSPACE_DIR/.claude/commands/scripts/commit-main.sh "PRD [ACTIVE_PRD] phase [CURRENT_PHASE]: pre-build commit"
   ```

5. **Process waves in order** (wave 0, then wave 1, etc.):

   ```
   # Default concurrent agents per batch (can be overridden by --tasks-per-wave)
   MAX_CONCURRENT = TASKS_PER_WAVE if set, else 10

   FOR each wave in waves (in order):
     waveId = wave.waveId
     useWorktrees = wave.useWorktrees
     agents = wave.agents

     # 5a. If wave uses worktrees, PRE-CREATE all worktrees
     IF useWorktrees:
       FOR each agent in agents:
         worktreeName = agent.worktree  # e.g., "wt-prd-5-W0-T0"
         branchName = agent.branch      # e.g., "prd/phase-5/W0-T0"

         Run: bash !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-create.sh "$worktreeName" "$branchName" main

     # 5b. Write prompts to files, then launch agents with minimal inline prompt
     #
     # Workers write results to /tmp/.prd_agent_{agentId}_results.json
     # The finalize script discovers these files automatically.
     #
     FOR batch in chunks(agents, MAX_CONCURRENT):
       FOR each agent in batch:
         agentId = agent.agentId  # e.g., "W0-T0"
         promptFile = "/tmp/.prd_agent_" + agentId + "_prompt.md"

         # Step 1: Extract and write prompt to file
         Run: cd !`echo $WORKSPACE_DIR` && jq -r ".waves[$waveId].agents[$agentIndex].prompt" /tmp/.prd_build.json > $promptFile

         # Step 2: Launch agent with minimal 1-line prompt
         Task(
           subagent_type: "prd-worker-v2",
           model: agent.model,
           prompt: "Read and execute the instructions at /tmp/.prd_agent_[agentId]_prompt.md",
           run_in_background: true
         )

       Use TaskOutput (blocking) to collect all results from batch

     # 5b.5 Pre-merge review (pre-check + reviewer agents)
     #
     # Pre-check: script-based validation (seconds, no tokens)
     # Review: Sonnet agents check diffs against acceptance criteria (parallel)
     # Only approved branches proceed to merge.

     # 5b.5a. Pre-check each worker
     FOR each agent in wave.agents:
       IF agent has worktree AND worker status != "blocked":
         Run: bash !`echo $WORKSPACE_DIR`/.claude/commands/prd/scripts/prd-pre-check.sh "$agentId" "$worktreePath" "$branch" "/tmp/.prd_agent_${agentId}_results.json"

     # 5b.5b. Compile reviewer prompts
     Run: bash !`echo $WORKSPACE_DIR`/.claude/commands/prd/scripts/prd-review-compile.sh $waveId
     Parse /tmp/.prd_review_compile.json
     reviewerCount = reviewers array length

     IF reviewerCount == 0:
       # All workers blocked or failed pre-check — skip review, proceed to merge (will be no-op)
       Continue to 5c

     # 5b.5c. Spawn parallel reviewers
     FOR batch in chunks(reviewers, MAX_CONCURRENT):
       FOR each reviewer in batch:
         promptFile = reviewer.promptFile
         worktree = reviewer.worktree

         Task(
           subagent_type: "prd-build-reviewer",
           model: $SONNET_MODEL,
           prompt: "Read and execute the instructions at $promptFile",
           run_in_background: true
         )

       Use TaskOutput (blocking) to collect all results from batch

     # 5b.5d. Partition results
     FOR each reviewer result at /tmp/.prd_review_{agentId}.json:
       Parse JSON
       IF approved == true AND requiresUserApproval == false:
         Add to approved list
       ELSE IF requiresUserApproval == true:
         Add to needsApproval list
       ELSE:
         Add to rejected list

     # 5b.5e. User approval gate (DB migrations)
     IF needsApproval is non-empty:
       FOR each agent in needsApproval:
         Read migration files from /tmp/.prd_precheck_{agentId}.json
         AskUserQuestion: "Agent {agentId} created DB migration files:\n{migrationFiles}\n\nApprove merge? (yes/no)"
         IF user approves: move to approved list
         ELSE: move to rejected list

     # 5b.5f. Handle rejected workers
     FOR each agent in rejected:
       Read blockers from /tmp/.prd_review_{agentId}.json
       Mark worker result as blocked with reviewer findings as blockReason
       # Rejected worktrees will be skipped by merge script (status=blocked)

     # 5c. Merge approved worktree branches with conflict resolution
     # Note: All waves use worktrees (enforced by build-compile)
     IF useWorktrees:
       Run: bash cd !`echo $WORKSPACE_DIR/` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh /tmp/.prd_build.json $waveId prd_agent

       # Parse merge result JSON
       # Success: {"status":"complete","merged":N,"skipped":N,"failed":0}
       # Conflicts: {"status":"needs_resolution","merged":N,"skipped":N,"failed":N,"conflictFile":"...","failedBranches":[...]}
       # Error: {"status":"error","merged":N,"skipped":N,"failed":N,"errors":[...]}

       IF status == "complete":
         Continue to next wave

       IF status == "needs_resolution":
         # Spawn conflict resolver agent
         # Failed worktrees are preserved by the merge script for resolution
         Task(
           subagent_type: "conflict-resolver-v1",
           model: claude-sonnet-4-5-20250929,
           prompt: "Resolve conflicts for wave $waveId. Read conflict details from /tmp/.prd_conflict_$waveId.json"
         )

         # Parse resolution from /tmp/.prd_conflict_resolution_$waveId.json
         Read: /tmp/.prd_conflict_resolution_$waveId.json

         IF resolution.status == "resolved":
           # Retry merge for resolved branches
           Run: bash cd !`echo $WORKSPACE_DIR` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh --retry /tmp/.prd_build.json $waveId prd_agent
           IF retry status == "complete": Continue to next wave
           ELSE: Output error — STOP

         IF resolution.status == "partial":
           Output: "⚠️ Some conflicts resolved, others require manual resolution"
           Output unresolved list from resolution JSON
           STOP

         IF resolution.status == "failed":
           Output: "⚠️ Merge conflicts require manual resolution"
           Output unresolved list from resolution JSON
           STOP

       IF status == "error":
         # Non-conflict errors (e.g., agent didn't complete)
         Output: "⚠️ Wave $waveId merge error"
         FOR each error in errors:
           Output: "  - $error"
         STOP — Do NOT proceed to finalize

   # After all waves complete, proceed to validate and finalize
   ```

6. **Validate all agent results** (discovers files automatically):
   ```bash
   bash !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate-agents.sh
   ```
   If validation fails (exit code non-zero): Output error JSON and STOP

7. Run finalize: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-finalize.sh`

8. Clean up temp prompt files: `rm -f /tmp/.prd_agent_*_prompt.md`

9. Pipe finalize output to display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh build-result /tmp/.prd_finalize.json`

9b. **Run retrospective** (ONLY if failures detected):
    ```bash
    needsRetrospective=$(jq -r '.needsRetrospective' /tmp/.prd_finalize.json)
    ```

    IF needsRetrospective == "true":
      Task(subagent_type: "prd-retrospective-v1", model: sonnet,
           prompt: "Analyze build results for PRD [ACTIVE_PRD] phase [CURRENT_PHASE]")

      Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_retrospective.json retrospective`
      If invalid: Output error — continue (don't block build completion)

      Output retrospective summary from agent
      Output: "⚠️ Issues detected. Run `/prd unblock [phase]` to resolve."

10. Output display stdout EXACTLY. Nothing else.

---

### `plan-unblock`

1. Check ACTIVE_PRD and CURRENT_PHASE. If missing: Output error — STOP

2. **Try fast plan first** (no agent needed for verify-retry cases):
   ```bash
   bash !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-unblock-fast-plan.sh
   ```
   Parse JSON output:

   | `status` | Action |
   |----------|--------|
   | `fast_plan` | Plan generated — skip to step 6 (validate) |
   | `none` | Output "No blocked tasks in phase" — STOP |
   | `needs_agent` | Continue to step 3 (spawn agent) |
   | `error` | Output error — STOP |

3. Build agent prompt:
   - If UNBLOCK_PROMPT provided: Include as guidance section in prompt
   - Write prompt to `/tmp/.prd_unblock_prompt.txt`:
     ```
     Investigate blocked tasks for PRD [ACTIVE_PRD] phase [CURRENT_PHASE].

     [If UNBLOCK_PROMPT provided:]
     ## User Guidance
     [UNBLOCK_PROMPT]

     Use this guidance to inform your investigation approach and ensure the unblock plan addresses the user's concerns.
     ```

4. Spawn agent (capture JSON output):
   ```
   Task(subagent_type: "prd-unblock", model: claude-sonnet-4-5-20250929, prompt: "Read instructions from /tmp/.prd_unblock_prompt.txt")
   ```

5. Parse JSON. If `status == "error"`: Output error and STOP
   If `blockedCount == 0`: Output "No blocked tasks in phase" — STOP

6. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate-unblock-plan.sh /tmp/.prd_unblock_plan.json`

7. Run display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh plan-unblock /tmp/.prd_unblock_plan.json`

8. Output display stdout EXACTLY. Nothing else.

---

### `unblock`

**0. Check for PHASE_NUM argument (combined workflow)**

If PHASE_NUM is provided (e.g., `/prd unblock 3`), run combined `read` → `plan-unblock` → `unblock`:

   a. **Run read**: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-read.sh [PHASE_NUM]`
      - Check: `jq -e '.status == "awaiting_selection"' /tmp/.prd_read.json 2>/dev/null`
      - If awaiting selection: Output `Ambiguous phase number. Multiple matches found.` — STOP
      - Output read stdout to transcript

   b. **Try fast plan first** (same as `plan-unblock` step 2):
      ```bash
      bash !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-unblock-fast-plan.sh
      ```
      - If `status == "fast_plan"`: Skip to validate below
      - If `status == "none"`: Output "No blocked tasks in phase" — STOP
      - If `status == "error"`: Output error — STOP
      - If `status == "needs_agent"`: Continue to step c

   c. **Run plan-unblock** (only if fast plan returned `needs_agent`):
      - Build agent prompt (same as `plan-unblock` step 3)
      - Spawn prd-unblock agent:
        ```
        Task(subagent_type: "prd-unblock", model: claude-sonnet-4-5-20250929, prompt: "Read instructions from /tmp/.prd_unblock_prompt.txt")
        ```
      - Parse JSON. If `status == "error"`: Output error and STOP
      - If `blockedCount == 0`: Output "No blocked tasks in phase" — STOP

   d. **Validate and display plan**:
      - Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate-unblock-plan.sh /tmp/.prd_unblock_plan.json`
      - Run display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh plan-unblock /tmp/.prd_unblock_plan.json`
      - Output plan display stdout to transcript

   d. Continue to step 1 below (normal unblock execution)

If NO PHASE_NUM provided, proceed directly to step 1 (expects existing plan).

---

1. Check ACTIVE_PRD and CURRENT_PHASE. If missing: Output error — STOP

2. Check plan exists: `/tmp/.prd_unblock_plan.json`. If missing: Output `No unblock plan found. Run \`/prd plan-unblock\` first.` — STOP

3. Run compile: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-unblock-compile.sh`

4. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_unblock_build.json build-unblock`
   If invalid: Output error — STOP

4b. Validate worktree manifest: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_unblock_build.json worktree-manifest-core`
   If invalid: Output error — STOP

5. Read waves: `jq -c '.waves[]' /tmp/.prd_unblock_build.json`

5b. **Commit uncommitted main changes** (before worktree creation):
   ```bash
   bash $WORKSPACE_DIR/.claude/commands/scripts/commit-main.sh "PRD [ACTIVE_PRD] unblock phase [CURRENT_PHASE]: pre-unblock commit"
   ```

6. **Process waves in order** (wave 0, then wave 1, etc.):

   ```
   # Default concurrent agents per batch (can be overridden by --tasks-per-wave)
   MAX_CONCURRENT = TASKS_PER_WAVE if set, else 10
   merge_failed = false

   FOR each wave in waves (in order):
     waveId = wave.waveId
     useWorktrees = wave.useWorktrees
     agents = wave.agents

     # 6a. If wave uses worktrees, PRE-CREATE all worktrees
     IF useWorktrees:
       FOR each agent in agents:
         worktreeName = agent.worktree  # e.g., "wt-prd-unblock-3-W1-T0"
         branchName = agent.branch      # e.g., "prd/unblock-3/W1-T0"

         Run: bash !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-create.sh "$worktreeName" "$branchName" main

     # 6b. Write prompts to files, then launch agents
     FOR batch in chunks(agents, MAX_CONCURRENT):
       FOR each agent in batch:
         agentId = agent.agentId  # e.g., "W0-T0", "W1-T0"
         promptFile = "/tmp/.prd_agent_" + agentId + "_prompt.md"

         # Step 1: Extract and write prompt to file
         Run: cd !`echo $WORKSPACE_DIR` && jq -r ".waves[$waveId].agents[$agentIndex].prompt" /tmp/.prd_unblock_build.json > $promptFile

         # Step 2: Launch agent
         IF useWorktrees AND multiple agents in batch:
           Task(
             subagent_type: "prd-worker-v2",
             model: agent.model,
             prompt: "Read and execute the instructions at /tmp/.prd_agent_[agentId]_prompt.md",
             run_in_background: true
           )
         ELSE:
           Task(
             subagent_type: "prd-worker-v2",
             model: agent.model,
             prompt: "Read and execute the instructions at /tmp/.prd_agent_[agentId]_prompt.md"
           )

       Use TaskOutput (blocking) to collect all results from batch

     # 6c. If wave used worktrees, merge branches with conflict resolution
     IF useWorktrees:
       Run: bash cd !`echo $WORKSPACE_DIR` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh /tmp/.prd_unblock_build.json $waveId prd_agent

       # Parse merge result JSON (same schema as build)
       # Success: {"status":"complete",...}
       # Conflicts: {"status":"needs_resolution","conflictFile":"...",...}
       # Error: {"status":"error","errors":[...],...}

       IF status == "complete":
         Continue to next wave

       IF status == "needs_resolution":
         # Spawn conflict resolver agent (failed worktrees preserved)
         Task(
           subagent_type: "conflict-resolver-v1",
           model: claude-sonnet-4-5-20250929,
           prompt: "Resolve conflicts for wave $waveId. Read conflict details from /tmp/.prd_conflict_$waveId.json"
         )

         Read: /tmp/.prd_conflict_resolution_$waveId.json

         IF resolution.status == "resolved":
           Run: bash cd !`echo $WORKSPACE_DIR` && !`echo $WORKSPACE_DIR`/.claude/commands/scripts/worktree-merge.sh --retry /tmp/.prd_unblock_build.json $waveId prd_agent
           IF retry status == "complete": Continue to next wave
           ELSE: Output error — STOP

         IF resolution.status == "partial" OR resolution.status == "failed":
           Output: "⚠️ Merge conflicts require manual resolution"
           Output unresolved list from resolution JSON
           STOP

       IF status == "error":
         Output: "⚠️ Wave $waveId merge error"
         FOR each error in errors:
           Output: "  - $error"
         STOP — Do NOT proceed to finalize
   ```

**CRITICAL**: Do NOT call `prd-unblock-finalize.sh` if ANY merge failed or has unresolved conflicts.

7. **Validate all agent results** (discovers files automatically):
    ```bash
    bash !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate-agents.sh
    ```
    If validation fails (exit code non-zero): Output error JSON and STOP

8. Run finalize: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-unblock-finalize.sh`

9. Clean up temp prompt files: `rm -f /tmp/.prd_agent_*_prompt.md`

10. Pipe finalize output to display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh unblock-result /tmp/.prd_unblock_finalize.json`

11. Output display stdout EXACTLY. Nothing else.

---

### `gen`

1. Spawn agent: `Task(subagent_type: "prd-gen", model: !`echo $OPUS_MODEL`, prompt: "...")`

2. Parse JSON output. Extract `prdName` from response.

3. Validate and update 00_ROOT.md phase links:
   ```bash
   !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate-root-links.sh [PRD_NAME]
   ```
   Ensures all phase numbers in ROOT file correctly link to phase JSON files.

4. **Auto-load PRD into state** (makes it immediately available for read/plan/build):
   ```bash
   cat > /tmp/.prd_state << EOF
   ACTIVE_PRD=[prdName]
   PRD_DIR=claude_files/PRDs/[prdName]
   CURRENT_PHASE=
   PHASE_JSON_FILE=
   EOF
   ```

5. Pipe to display: `echo '[agent_json]' | !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh gen`

6. Output display stdout EXACTLY. Nothing else.

---

### `edit`

1. Check ACTIVE_PRD. If missing: Output error — STOP

2. Spawn agent: `Task(subagent_type: "prd-edit", model: claude-sonnet-4-5-20250929, prompt: "...")`
   Agent writes results to `/tmp/.prd_edit.json`

3. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_edit.json edit`
   If invalid: Output error JSON and STOP

4. Run display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh edit /tmp/.prd_edit.json`

5. Output display stdout EXACTLY. Nothing else.

---

### `review`

1. Check ACTIVE_PRD. If missing: Output error — STOP

2. If no PHASE_NUM provided: Output `Phase number required. Usage: /prd review <phase>` — STOP

3. Spawn agent: `Task(subagent_type: "prd-reviewer", model: !`echo $OPUS_MODEL`, prompt: "Review phase [PHASE_NUM] of PRD [ACTIVE_PRD]")`
   Agent writes results to `/tmp/.prd_review.json`

4. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_review.json review`
   If invalid: Output error JSON and STOP

5. Run display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh review /tmp/.prd_review.json`

6. Output display stdout EXACTLY. Nothing else.

---

### `review-all`

**Convergence Criteria**: STOP when `highCount == 0 AND mediumCount == 0` (max 3 passes)

1. Check ACTIVE_PRD. If missing: Output error — STOP

2. Parse flags from arguments:
   - If `--cache-only` present: Set `CACHE_ONLY=true` (skip to step 8)
   - If `--read-only` present: Set `READ_ONLY=true`
   - Otherwise: Set `READ_ONLY=false` (default: full review with auto-fix loop)

3. **If CACHE_ONLY**: Skip to step 8

4. Run compile: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-review-all-compile.sh`
   (This resets pass tracker and clears old review files)

5. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_review_all_compile.json review-all-compile`
   If invalid: Output error JSON — STOP

6. **CRITICAL: Read agent specs from compile output**

   The compile script discovers actual phase files and builds correct prompts.
   **DO NOT construct prompts manually** — use the prompts from compile output.

   ```bash
   # Read the agents array - each agent has correct phaseFile and prompt
   jq -c '.agents[]' /tmp/.prd_review_all_compile.json
   ```

   Each agent object contains:
   - `agentId`: Unique identifier (e.g., "reviewer-p4")
   - `phaseId`: Phase number
   - `phaseFile`: **Actual file name** from PRD directory (e.g., "phase_4_cards.json")
   - `phaseName`: Phase name from the JSON file
   - `model`: Model to use ("opus")
   - `prompt`: **Pre-built prompt with correct paths** — USE THIS EXACTLY

7. **CONVERGENCE LOOP** (max 3 passes):

   ```
   MAX_PASSES = 3
   CONVERGED = false

   LOOP:
     # 7a. Write prompts to files, then launch parallel reviewers
     BATCH_SIZE = 10  # Default batch size for review agents

     # Read agents from compile output
     agents = jq -c '.agents[]' /tmp/.prd_review_all_compile.json

     For batch in chunks(agents, BATCH_SIZE):
       For each agent in batch:
         agentId = agent.agentId  # e.g., "reviewer-p4"
         promptFile = "/tmp/.prd_agent_" + agentId + "_prompt.md"

         # Write prompt to file
         Run: jq -r ".agents[$index].prompt" /tmp/.prd_review_all_compile.json > $promptFile

         # Launch with minimal prompt
         Task(
           subagent_type: "prd-reviewer",
           model: agent.model,
           prompt: "Read and execute the instructions at /tmp/.prd_agent_[agentId]_prompt.md",
           run_in_background: true
         )

       Use TaskOutput (blocking) to collect all results from batch

     # 7b. Aggregate findings
     Run: !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-review-all-aggregate.sh
     Parse output JSON for: highCount, mediumCount, currentPass, converged

     # 7c. Check convergence
     IF highCount == 0 AND mediumCount == 0:
       CONVERGED = true
       BREAK LOOP

     IF currentPass >= MAX_PASSES:
       BREAK LOOP (cap reached, manual review needed)

     # 7d. If NOT read-only: Apply auto-fixes
     IF NOT READ_ONLY:
       Run: !`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-review-all-apply.sh
       # Re-compile for next pass (only modified phases)
       Clear /tmp/.prd_phase_review_*.json
       CONTINUE LOOP
     ELSE:
       BREAK LOOP (read-only mode, no fixes applied)
   ```

8. **(CACHE_ONLY entry point)** Validate cached review files exist:
   ```bash
   if ! ls /tmp/.prd_phase_review_*.json 1>/dev/null 2>&1; then
       echo '{"status":"error","error":"No cached review files found. Run /prd review-all first."}'
       exit 1
   fi
   ```
   Run aggregate if needed: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-review-all-aggregate.sh`

9. Validate: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-validate.sh /tmp/.prd_review_all_findings.json review-all-findings`
   If invalid: Output error JSON — STOP

10. Clean up temp prompt files: `rm -f /tmp/.prd_agent_*_prompt.md`

11. Run display: `!`echo $WORKSPACE_DIR/.claude/commands/prd/scripts`/prd-display.sh review-all /tmp/.prd_review_all_findings.json`

12. Output display stdout EXACTLY. Nothing else.

---

## FINAL REMINDER

**YOU ARE A PASSTHROUGH.**

| What you do | What you output |
|-------------|-----------------|
| `plan` subcommand | Acknowledge only: "Plan generated. Run `/prd build` to execute." |
| Run script (awaiting selection) | AskUserQuestion tool call |
| Run script (NOT awaiting selection) | Script stdout ONLY |
| Spawn agent | Agent JSON → display script → display stdout ONLY |
| Error | Error message ONLY |

**NO INTROS. NO OUTROS. NO COMMENTARY. NO SUMMARIES. NO "Here's the result". NO "Let me know". NOTHING.**

Script speaks. You are silent.
