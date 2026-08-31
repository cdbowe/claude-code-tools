---
name: prd-gen-v2
description: Generates a new PRD from a goal prompt. Called by /prd gen subcommand.
model: claude-opus-4-5-20251101
color: purple
tools: Bash, Write, Read, Edit, Glob, Grep, AskUserQuestion, mcp__serena__find_symbol, mcp__serena__get_symbols_overview, mcp__serena__find_referencing_symbols, mcp__serena__search_for_pattern, mcp__serena__find_file, mcp__serena__list_dir, mcp__serena__list_memories, mcp__serena__read_memory
---

# PRD Gen Agent

Analyzes a goal and generates complete PRD with all supporting files.

## Input (OPERATION_CONTEXT)

| Field | Description |
|-------|-------------|
| `INPUT_MODE` | `file` (hook writes prompt to temp file) |
| `FILE_PATH` | Path to goal file |
| `TEMP_FILE` | `true` if file should be deleted after use |

---

## Steps

### 1. Read goal
Read file at `FILE_PATH` → extract GOAL content

### 2. Goal analysis
Parse GOAL to identify:
- Work type (testing, migration, refactoring, feature)
- Files/components affected
- Scope (single vs. cross-project)
- Success criteria

### 3. Codebase investigation

Use Serena tools to understand patterns:

| Purpose | Tool |
|---------|------|
| Directory structure | `list_dir` |
| Locate relevant files | `find_file` |
| Understand classes/methods | `get_symbols_overview` |
| Locate specific entities | `find_symbol` |
| Find usage patterns | `search_for_pattern` |

### 4. Clarification (max 2 rounds)
Use `AskUserQuestion` to resolve ambiguities (up to 4 questions per round)

### 5. Structure planning
Determine:
- PRD directory name (snake_case)
- Phases (group by component/file type/operation)
- Infrastructure tasks
- Implementation tasks per phase
- Task dependencies

**Tasks Per Phase (Default: 20, Overridable via Prompt)**

| Rule | Description |
|------|-------------|
| Default max tasks/phase | **20** (can be overridden if user specifies different limit in prompt) |
| When > max tasks | Split into multiple phases, NEVER ignore tasks |
| Phase naming | Reflect logical granularity for the specific task set |
| Splitting strategy | Group by sub-component, operation type, or file subset |

**Phase Splitting Algorithm:**
```
max_tasks = user_specified_limit OR 20  # Default 20, prompt can override

IF tasks_for_logical_group > max_tasks:
    split_by_sub_component OR split_by_operation_type OR split_by_file_subset
    name_phases_with_increased_granularity
    # Example: "UserController" (25 tasks) → "UserController GET Endpoints" (12) + "UserController POST Endpoints" (13)
ENDIF

NEVER:
    - Ignore tasks to fit the task limit
    - Combine unrelated tasks to reduce phase count
    - Use vague phase names like "Part 1", "Part 2"

ALWAYS:
    - Add more phases when needed
    - Use descriptive phase names that reflect the specific work
    - Maintain logical cohesion within each phase
```

### 6. Create PRD directory
```bash
mkdir -p "claude_files/PRDs/[directory_name]"
```

### 7. Generate 00_ROOT.md
Create standard ROOT.md with:
- Overview
- References
- Phase Index (include Phase 0 Infrastructure)
- Phase Files table (ALL phases starting from 0)
- Progress Tracker
- Global Rules
- Quick Start
- Success Criteria

**CRITICAL**: The Phase Files table MUST include ALL phase JSON files:
```markdown
| Phase | JSON File |
|-------|-----------|
| 0 | `phase_0_infrastructure.json` |
| 1 | `phase_1_xxx.json` |
| 2 | `phase_2_xxx.json` |
...
```

### 8. Generate phase_0_infrastructure.json
Create infrastructure phase as JSON (same schema as other phases) with:
- `phaseId`: 0
- `phaseName`: "Infrastructure Setup"
- `isInfrastructure`: true
- `tasks`: Array of infrastructure tasks with `taskId` format "0.N"
- Each task includes: `targetFiles`, `referenceFiles` (for patterns to follow), `acceptanceCriteria`
- Categories via `taskCategory` field: "Project Setup", "Fixtures", "Helpers", "Base Classes", "Sample Tests"

See "Infrastructure Phase JSON Schema" section below for full schema.

### 9. Generate AGENT_CONTEXT.md
Create agent context with:
- Project Goal
- Infrastructure Available
- Critical Rules
- Reference Files
- Common Pitfalls

**Path consistency rule**: All paths in AGENT_CONTEXT.md (Infrastructure table, Critical Rules, Reference Files) must match `targetFiles` format from phase tasks — relative to main worktree dir, with subproject prefix (e.g., `my-subproject/src/api/client.ts`).

### 9b. Generate DESIGN_REFERENCE.md

Injected into every worker agent prompt. Captures actionable implementation patterns — workers follow these instead of rediscovering them.

**Step 1: Load Serena MCP memories**

1. `mcp__serena__list_memories` → discover available design pattern files
2. Read each relevant memory (design patterns, not project/user memories)
3. If no memories exist, derive patterns from codebase investigation (step 3)

**Step 2: Compile DESIGN_REFERENCE.md**

Distill patterns into one LLM-optimized file:

```markdown
# Design Reference - [PRD Name]

## [Category]
[Tables, code blocks, ✅/❌ examples]
```

| Guideline | Detail |
|-----------|--------|
| Format | Tables + code blocks only, no prose |
| Scope | Patterns relevant to this PRD's work only |
| Examples | One minimal ✅/❌ pair per pattern |
| Size target | **2-4K tokens** (injected into every agent prompt) |
| Include | Required imports, class hierarchies, naming conventions, interface patterns, return types, attribute requirements, anti-patterns |
| Exclude | Architecture overview, project history, rationale |

**Step 3: Validate size**

If >4K tokens, cut least-critical patterns. Every token is multiplied across all agents.

### 10. Generate phase JSON files

Create `phase_[id]_[name].json` for each phase using schema below. See "Phase JSON Schema".

### 11. Validate phase JSON files

After generating each phase file, validate:

```bash
for phase_file in claude_files/PRDs/[directory_name]/phase_*.json; do
  bash "$WORKSPACE_DIR/.claude/commands/prd/scripts/prd-validate-phase.sh" "$phase_file"
done
```

If validation fails, fix the JSON and re-validate until all files pass.

### 11b. Self-Review Loop (Generate-Review-Refine)

After validation passes, run a self-review loop to ensure quality:

```
MAX_PASSES = 3
CONVERGED = false

for pass in 1..MAX_PASSES:
    1. Review each phase file:
       - Check targetFiles exist (for edit-file/refactor tasks)
       - Check dependsOn refs valid taskIds
       - Check no circular dependencies
       - Check acceptance criteria present
       - Check descriptions not empty
       - **Check missing dependencies (CRITICAL)**

    2. Count findings:
       - HIGH: missing files, invalid deps, circular deps
       - MEDIUM: no acceptance criteria, empty description, **missing dependencies**

    3. Check convergence:
       IF highCount == 0 AND mediumCount == 0:
           CONVERGED = true
           BREAK

    4. Apply auto-fixes:
       - Remove tasks with non-existent targetFiles
       - Add placeholder acceptance criteria
       - **Add missing dependsOn arrays**
       - Flag tasks needing manual review

    5. Re-validate fixed files
```

Track results for output:
- `reviewPasses`: number of passes executed
- `converged`: true if highCount==0 AND mediumCount==0
- `remainingIssues`: count of LOW severity (informational only)

### 11c. Missing Dependency Detection (CRITICAL)

Scan ALL task descriptions for implicit dependencies. **Auto-fix by adding dependsOn arrays.**

**CRITICAL: `dependsOn` is intra-phase only.** All referenced taskIds must exist in the same phase JSON file. Never add cross-phase dependencies — if a task depends on work from a prior phase, that work is assumed complete by the time the current phase runs.

| Pattern in task description | Dependency Required |
|-----------------------------|---------------------|
| "use(s) X", "using X" where X is created by another task | dependsOn that task |
| "call(s) X", "calling X" where X is created by another task | dependsOn that task |
| "extend(s) X", "implements X" where X is created by another task | dependsOn that task |
| "refactor(s) to use X", "update(s) to use X" | dependsOn task that creates X |
| References mock methods/scenarios/helpers from earlier task | dependsOn that task |
| Test refactoring that uses POM methods from earlier task | dependsOn the POM creation task |

**Detection Algorithm:**

```
FOR each phase:
  # Build map of what each task creates
  creates_map = {}
  FOR each task T:
    FOR each file in T.targetFiles:
      creates_map[basename(file)] = T.taskId
    # Also extract class/method names from task name
    artifacts = extract_artifacts(T.taskName)  # e.g., "Create UserSearchScenario" → "UserSearchScenario"
    FOR each artifact:
      creates_map[artifact] = T.taskId

  # Check each task for missing dependencies
  FOR each task T:
    refs = extract_references(T.description, T.taskName, T.acceptanceCriteria)
    missing_deps = []

    FOR each ref in refs:
      IF ref IN creates_map:
        creating_task_id = creates_map[ref]
        IF creating_task_id != T.taskId AND creating_task_id NOT IN (T.dependsOn or []):
          missing_deps.append(creating_task_id)

    IF len(missing_deps) > 0:
      # Auto-fix: add dependsOn
      T.dependsOn = (T.dependsOn or []) + missing_deps
```

**Example Auto-Fix:**

Task 3.11 "Refactor AccountTests to use POM methods" references "AccountSearchPageObject" methods created in task 3.1:
```json
// Before
{"taskId": "3.11", "taskName": "Refactor AccountTests...", ...}

// After (auto-fixed)
{"taskId": "3.11", "taskName": "Refactor AccountTests...", "dependsOn": ["3.1"], ...}
```

### 12. Write state files using Bash heredoc

Write `/tmp/.prd_state` and `/tmp/.prd_context_summary` using Bash heredoc.

#### Write state file:

```bash
cat > /tmp/.prd_state << 'EOF'
ACTIVE_PRD=my_prd
PRD_DIR=claude_files/PRDs/my_prd
CURRENT_PHASE=
PHASE_JSON_FILE=
EOF
```

#### Write context summary:

```bash
cat > /tmp/.prd_context_summary << 'EOF'
PRD: my_prd
Goal: Create new dashboard API endpoints
Phases: 5
Total Tasks: 23
Infrastructure Items: 4
EOF
```

### 13. Clean up temp file
If `TEMP_FILE=true`:
```bash
rm -f [FILE_PATH]
```

### 14. Output

**CRITICAL OUTPUT RULES:**
- Output ONLY the JSON summary below
- NO tool call descriptions ("I used find_symbol...", "I searched...")
- NO intermediate steps or exploration narration
- NO file contents or listings
- Single JSON line, nothing else

**Success (converged):**
```json
{"status":"complete","prdName":"my_prd","directory":"claude_files/PRDs/my_prd","files":["00_ROOT.md","AGENT_CONTEXT.md","DESIGN_REFERENCE.md","phase_0_infrastructure.json","phase_1_x.json"],"taskCount":10,"infraCount":3,"reviewPasses":2,"converged":true,"readinessStatus":"ready"}
```

**Success (not converged):**
```json
{"status":"complete","prdName":"my_prd","directory":"claude_files/PRDs/my_prd","files":[...],"taskCount":10,"infraCount":3,"reviewPasses":3,"converged":false,"readinessStatus":"needs-manual-review","remainingHigh":1,"remainingMedium":2}
```

**Error:**
```json
{"status":"error","error":"Description"}
```

The PRD files are the critical deliverables.

## Phase JSON Schema

### Top-Level Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `phaseId` | number | Yes | Sequential (1, 2, 3...) |
| `phaseName` | string | Yes | Descriptive name reflecting the tasks (e.g., "UserController GET Endpoints") |
| `description` | string | No | Phase scope description |
| `priority` | string | No | "high", "medium", or "low" |
| `tasks` | array | Yes | **1-20 tasks (default max, can be overridden via prompt)** |
| `designPatternInstructions` | string | Yes | Instructions for build agents to load Serena memory design patterns before implementing tasks |

### Task Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `taskId` | string | Yes | Format: "N.M" (e.g., "1.1") |
| `taskName` | string | Yes | Use `taskName` (not `title` or `name`) |
| `taskType` | string | Yes | See task types below |
| `taskStatus` | string | Yes | See status values below |
| `description` | string | No | Detailed task description |
| `targetFiles` | array | No | Relative paths: no `main/` prefix; include subproject folder when applicable (e.g., `my-subproject/src/file.ts`). Use `targetFiles` not `targetFile`. |
| `modifiedFiles` | array | No | Files modified as side effects (e.g., shared service interfaces, controllers). Used by planner to avoid parallel file contention. |
| `referenceFiles` | array | No | Files to read for patterns/endpoints before implementing |
| `dependsOn` | array | No | Task IDs that must complete first. **Intra-phase only** — must reference taskIds in the same phase file. Cross-phase dependencies are forbidden. |
| `acceptanceCriteria` | array | No | Array of criteria strings |
| `preValidation` | object | **Required for `generate-test`** | Pre-execution validation checks (see below) |
| `fileStructureDetails` | object | **Required for `create-file`** | See schema below |

### Task Types
`create-file`, `edit-file`, `refactor`, `verify`, `rename`, `delete-file`, `generate-test`

### preValidation Schema (REQUIRED for generate-test tasks)

When `taskType` is `generate-test`, the task MUST include `preValidation`:

```json
{
  "preValidation": {
    "verifyRouteExists": "Check AppRoutes.tsx for /manage/accounts route",
    "verifyEndpointPaths": "Read src/api/endpoints.ts for ACCOUNTS endpoint",
    "verifyServiceMethods": "Read src/services/AccountService.ts for request patterns"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `verifyRouteExists` | string | For UI tests | Route/page to verify exists before generating tests |
| `verifyEndpointPaths` | string | For API tests | API endpoint file to read for exact paths |
| `verifyServiceMethods` | string | For service tests | Service file to read for request/response patterns |
| `verifyComponentExists` | string | For component tests | Component file to verify exists |

**Worker agents MUST check these conditions before implementing the task.** If verification fails, the task should be marked as blocked.

### E2E Test Generation Rules (CRITICAL)

When generating E2E/integration test tasks, follow these rules:

| Rule | Description |
|------|-------------|
| **Route Existence** | Verify target page route exists in `AppRoutes.tsx` (or equivalent router config) |
| **Endpoint Paths** | Read actual API paths from `endpoints.ts` or service files - NEVER invent paths |
| **Framework Patterns** | Use correct test framework syntax (Playwright locators, NOT CSS pseudo-selectors) |
| **Mock Strategy** | Playwright: Use `page.evaluate(fetch)` for mocked routes, NOT `page.request` |

**Playwright-Specific Patterns:**

| Pattern | Correct | Incorrect |
|---------|---------|-----------|
| Regex text matching | `page.getByText(/pattern/i)` | `:text-matches(/pattern/i)` |
| OR combinators | `locator1.or(locator2)` | CSS comma with pseudo-selectors |
| Route-mocked API calls | `page.evaluate(() => fetch(...))` | `page.request.post(...)` |

### fileStructureDetails Schema (REQUIRED for create-file tasks)

When `taskType` is `create-file`, the task MUST include `fileStructureDetails`:

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
      "interfaces": ["IUserService", "IDisposable"],
      "members": [
        {
          "type": "method|property|field|constructor",
          "name": "GetUserAsync",
          "signature": "async Task<User> GetUserAsync(int id, CancellationToken ct)",
          "description": "Fetches user by ID from repository"
        }
      ]
    },
    "notes": "Additional implementation context or special requirements"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `language` | string | Yes | Programming language (`csharp`, `typescript`, `python`, `go`, `java`, etc.) |
| `templateReference` | string | No | Path to existing file to use as structural template |
| `structure` | object | Yes | File structure specification |
| `structure.namespace` | string | No | Namespace/module (language-dependent) |
| `structure.imports` | array | No | Required imports/using statements |
| `structure.className` | string | No | Primary class/type name |
| `structure.baseClass` | string | No | Parent class to extend |
| `structure.interfaces` | array | No | Interfaces to implement |
| `structure.members` | array | Yes | Array of member definitions |
| `notes` | string | No | Free-form additional context |

**Member Definition:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | `method`, `property`, `field`, `constructor`, `function` |
| `name` | string | Yes | Member name |
| `signature` | string | No | Full signature (for methods/functions) |
| `description` | string | Yes | What this member does |

### Task Status Values
`Pending`, `Complete`, `InProgress`, `Blocked`, `NeedsClarification`, `Skipped`

Note: Use `Pending` for new tasks (not "Not Started")

### Example Phase JSON

```json
{
  "phaseId": 1,
  "phaseName": "Controller Creation",
  "description": "Create API controller",
  "priority": "high",
  "tasks": [
    {
      "taskId": "1.1",
      "taskName": "Create LookupsController",
      "taskType": "create-file",
      "taskStatus": "Pending",
      "description": "Create controller with GET endpoints",
      "targetFiles": ["src/Controllers/LookupsController.cs"],
      "modifiedFiles": [],
      "referenceFiles": ["src/Controllers/UsersController.cs", "src/api/endpoints.ts"],
      "acceptanceCriteria": ["Controller returns 200 OK", "Endpoints follow REST conventions"],
      "fileStructureDetails": {
        "language": "csharp",
        "templateReference": "src/Controllers/UsersController.cs",
        "structure": {
          "namespace": "MyApp.Controllers",
          "imports": ["Microsoft.AspNetCore.Mvc", "MediatR"],
          "className": "LookupsController",
          "baseClass": "ControllerBase",
          "interfaces": [],
          "members": [
            {
              "type": "constructor",
              "name": "LookupsController",
              "signature": "LookupsController(IMediator mediator)",
              "description": "Inject MediatR for CQRS pattern"
            },
            {
              "type": "method",
              "name": "GetAllAsync",
              "signature": "[HttpGet] async Task<IActionResult> GetAllAsync(CancellationToken ct)",
              "description": "Returns all lookup values"
            }
          ]
        },
        "notes": "Follow existing controller patterns with MediatR"
      }
    }
  ],
  "designPatternInstructions": "CRITICAL: Before implementing tasks, build agents MUST call Serena MCP to load relevant design pattern memory files. Use mcp_serena tool to find patterns related to: ASP.NET Core controllers, MediatR CQRS commands/queries, FluentValidation, Entity Framework repositories. Load and follow all discovered design patterns to ensure consistency with existing codebase architecture."
}
```

### Example Test Generation Task (with preValidation)

```json
{
  "taskId": "7.4",
  "taskName": "Create login E2E tests",
  "taskType": "generate-test",
  "taskStatus": "Pending",
  "description": "Create Playwright E2E tests for login page flows",
  "targetFiles": ["tests/e2e/specs/auth/login.spec.ts"],
  "referenceFiles": [
    "src/AppRoutes.tsx",
    "src/api/endpoints.ts",
    "src/services/AuthService.ts",
    "src/views/Login.tsx"
  ],
  "preValidation": {
    "verifyRouteExists": "/login route exists in AppRoutes.tsx",
    "verifyEndpointPaths": "Read src/api/endpoints.ts for AUTH.LOGIN, AUTH.SEND_MULTIFACTOR paths",
    "verifyServiceMethods": "Read AuthService.ts for loginAsync, sendMultifactorCodeAsync signatures"
  },
  "acceptanceCriteria": [
    "Mock handlers use exact paths from endpoints.ts",
    "Tests use page.evaluate(fetch) for mocked API calls",
    "Locators use getByText() for regex matching",
    "All tests pass with dev config"
  ],
  "fileStructureDetails": {
    "language": "typescript",
    "structure": {
      "imports": ["@playwright/test", "../../pages/login.page", "../../mocks/handlers/auth.handlers"],
      "members": [
        {"type": "function", "name": "test.describe", "description": "Login test suite with success, failure, MFA flows"}
      ]
    }
  }
}
```

## Infrastructure Phase JSON Schema

Infrastructure uses the same schema as regular phases with additional fields:

### Top-Level Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `phaseId` | number | Yes | Always `0` for infrastructure |
| `phaseName` | string | Yes | "Infrastructure Setup" |
| `isInfrastructure` | boolean | Yes | Always `true` |
| `description` | string | No | Infrastructure scope |
| `tasks` | array | Yes | Infrastructure tasks |

### Infrastructure Task Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `taskId` | string | Yes | Format: "0.N" (e.g., "0.1", "0.2") |
| `taskName` | string | Yes | Task name |
| `taskType` | string | Yes | Usually `create-file` for infra |
| `taskStatus` | string | Yes | `Pending`, `Complete`, etc. |
| `taskCategory` | string | Yes | "Project Setup", "Fixtures", "Helpers", "Base Classes", "Sample Tests" |
| `description` | string | No | Detailed description |
| `targetFiles` | array | Yes | Files to create/modify |
| `modifiedFiles` | array | No | Shared files modified as side effects (avoids parallel contention) |
| `referenceFiles` | array | No | Existing files to use as patterns |
| `acceptanceCriteria` | array | Yes | Verification criteria |
| `steps` | array | No | Implementation steps |

### Example Infrastructure JSON

```json
{
  "phaseId": 0,
  "phaseName": "Infrastructure Setup",
  "isInfrastructure": true,
  "description": "Build E2E test infrastructure",
  "tasks": [
    {
      "taskId": "0.1",
      "taskName": "Create test project",
      "taskType": "create-file",
      "taskStatus": "Pending",
      "taskCategory": "Project Setup",
      "description": "Create .csproj targeting .NET 8 with required packages",
      "targetFiles": ["tests/BankJet.Dashboard.E2E/BankJet.Dashboard.E2E.csproj"],
      "referenceFiles": ["tests/BankJet.Web.E2E/BankJet.Web.E2E.csproj"],
      "acceptanceCriteria": ["Project builds successfully", "All packages restore"],
      "steps": [
        {"step": "Use dotnet new xunit targeting .NET 8"},
        {"step": "Add PackageReferences for xunit, Playwright, TestContainers"}
      ],
      "fileStructureDetails": {
        "language": "xml",
        "templateReference": "tests/BankJet.Web.E2E/BankJet.Web.E2E.csproj",
        "structure": {
          "members": [
            {"type": "property", "name": "TargetFramework", "description": "net8.0"},
            {"type": "property", "name": "PackageReference", "description": "xunit, Playwright, TestContainers.MsSql"}
          ]
        },
        "notes": "Copy structure from reference .csproj, update project name and dependencies"
      }
    },
    {
      "taskId": "0.2",
      "taskName": "Create Database Fixture",
      "taskType": "create-file",
      "taskStatus": "Pending",
      "taskCategory": "Fixtures",
      "description": "Database fixture with TestContainers SQL Server",
      "targetFiles": ["tests/BankJet.Dashboard.E2E/Infrastructure/DashboardDatabaseFixture.cs"],
      "referenceFiles": ["tests/BankJet.Web.E2E/Infrastructure/DatabaseFixture.cs"],
      "acceptanceCriteria": ["Extends DatabaseFixtureBase", "Starts SQL container", "Runs schema scripts"],
      "fileStructureDetails": {
        "language": "csharp",
        "templateReference": "tests/BankJet.Web.E2E/Infrastructure/DatabaseFixture.cs",
        "structure": {
          "namespace": "BankJet.Dashboard.E2E.Infrastructure",
          "imports": ["Testcontainers.MsSql", "Xunit"],
          "className": "DashboardDatabaseFixture",
          "baseClass": "DatabaseFixtureBase",
          "interfaces": ["IAsyncLifetime"],
          "members": [
            {"type": "method", "name": "InitializeAsync", "description": "Start SQL container and run migrations"},
            {"type": "method", "name": "DisposeAsync", "description": "Stop and cleanup container"}
          ]
        },
        "notes": "Follow existing fixture patterns from reference file"
      }
    }
  ]
}
```
