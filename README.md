# Claude Code Tools

A production-tested collection of custom skills, subagents, hooks, and scripts for Claude Code. I use these on a daily basis in my own Claude-assisted development workflows.

Built for real-world development workflows: PRD-driven planning with parallel execution, git worktree orchestration, usage tracking, and more.

## What's Included

| Category | Count | Description |
|----------|-------|-------------|
| Commands (Skills) | 3 | Slash-command workflows (`/prd`, `/worktree`, `/prime`) |
| Subagents | 11 | Specialized agents for PRD execution, code review, and conflict resolution |
| Hooks | 4 | Event-driven automation (logging, validation, dispatch) |
| Scripts | 25+ | Shell scripts for PRD orchestration, worktree management, and validation |
| Status Line | 1 | Custom status bar with context, cost, and rate limit tracking |

## Directory Structure

```
.claude/
├── settings.json                    # Permissions, env vars, hooks, status line
├── commands/
│   ├── prd.md                       # /prd skill — full PRD lifecycle orchestrator
│   ├── worktree.md                  # /worktree skill — parallel git worktree execution
│   ├── prime.md                     # /prime skill — load Serena MCP memory into context
│   ├── prd/scripts/                 # 25+ shell scripts for PRD orchestration
│   │   ├── prd-stat.sh              # Show current PRD status
│   │   ├── prd-list.sh              # Browse and load PRDs
│   │   ├── prd-load.sh              # Load PRD by name
│   │   ├── prd-read.sh              # Read a specific phase
│   │   ├── prd-plan.sh              # Generate execution plan
│   │   ├── prd-display.sh           # Format output for display
│   │   ├── prd-finalize.sh          # Finalize build results
│   │   ├── prd-validate.sh          # JSON schema validation
│   │   ├── prd-validate-agents.sh   # Validate agent results
│   │   ├── prd-build-compile.sh     # Compile build manifest
│   │   ├── prd-unblock-compile.sh   # Compile unblock manifest
│   │   ├── prd-unblock-finalize.sh  # Finalize unblock results
│   │   ├── prd-resolve-next-phase.sh # Auto-increment phase
│   │   ├── prd-review-all-*.sh      # Multi-phase review pipeline
│   │   ├── prd-worktree-merge.sh    # PRD-specific merge orchestration
│   │   └── prd-validate-*.sh        # Schema validators (phase, plan, etc.)
│   └── scripts/
│       ├── check-main.sh            # Block ops if main has uncommitted changes
│       ├── commit-main.sh           # Auto-commit main before worktree ops
│       ├── worktree-create.sh       # Create git worktrees
│       ├── worktree-merge.sh        # Merge worktree branches (parallel + sequential)
│       └── worktree-cleanup.sh      # Clean up stale worktrees
├── agents/
│   ├── prd/
│   │   ├── prd-gen.md               # Generate PRDs from goal prompts
│   │   ├── prd-plan.md              # Wave-based execution planning
│   │   ├── prd-worker.md            # Execute assigned build tasks
│   │   ├── prd-reviewer.md          # Phase review for ambiguities
│   │   ├── prd-edit.md              # Free-form PRD editing
│   │   ├── prd-unblock.md           # Investigate and resolve blocked tasks
│   │   ├── prd-retrospective.md     # Analyze failures, document learnings
│   │   └── conflict-resolver.md     # Semantic git conflict resolution
│   ├── ts-expert.md                 # TypeScript/JavaScript specialist
│   └── tsql-expert.md               # SQL Server / T-SQL specialist
├── hooks/
│   ├── backup-conversation.sh       # PreCompact: save transcript before compression
│   ├── skill-dispatcher.sh          # PreToolUse: route skill invocations to parsers
│   ├── validate-prd-json.sh         # PreToolUse: validate PRD JSON on Write
│   └── prd-plan-inject.sh           # UserPromptSubmit: intercept /prd plan
└── statusline/
    └── statusline_script.sh         # Multi-line status bar (model, context, cost, rate limits)
```

## Commands (Skills)

### `/prd` — PRD Lifecycle Management

Full lifecycle PRD workflow: generate, review, plan, build, and unblock — all from a single command. Builds execute via parallel subagents in isolated git worktrees with automatic merge and conflict resolution.

```
/prd gen "Build a user authentication system"   # Generate PRD
/prd list                                        # Browse and load PRDs
/prd build 3                                     # Read phase 3 → plan → build (combined)
/prd build --next                                # Auto-build next incomplete phase
/prd review-all                                  # Review all phases, auto-fix, report
/prd plan-unblock                                # Investigate blocked tasks
/prd unblock                                     # Execute unblock plan
/prd edit "Add rate limiting to phase 2"         # Edit loaded PRD
```

**Subcommands**:

| Command | Description |
|---------|-------------|
| `stat` | Show current PRD status |
| `list [search]` | Browse PRDs, optional filter |
| `load <search>` | Load PRD by name |
| `read <phase>` | Load a specific phase (0 = infrastructure) |
| `plan` | Generate wave-based execution plan |
| `build [phase] [--next] [--tasks-per-wave N]` | Execute plan with parallel agents |
| `plan-unblock [prompt]` | Investigate blocked tasks |
| `unblock [prompt]` | Execute unblock plan |
| `gen <prompt>` | Generate new PRD from prompt |
| `gen --file <path>` | Generate PRD from goal file |
| `edit <prompt>` | Edit loaded PRD |
| `review <phase>` | Review single phase |
| `review-all [--read-only] [--cache-only]` | Review all phases with convergence loop |

**Architecture**: The `/prd` skill is a script-first orchestrator — it routes subcommands to shell scripts (preferred) or specialized agents, validates JSON schemas at every step, and manages parallel execution across git worktrees. Delegates deterministic work to scripts instead of prompts wherever possible.

### `/worktree` — Parallel Git Worktree Execution

Decomposes work into independent units, assigns model tiers, and executes in parallel across isolated git worktrees with automatic merge and conflict resolution.

```
/worktree Refactor the auth module into three separate files
/worktree Add error handling to all API endpoints (max 3 units)
```

**How it works**:
1. Analyzes work into independent units (file/module isolation)
2. Assigns model tiers (haiku/sonnet/opus) by complexity
3. Pre-creates worktrees and branches
4. Spawns parallel agents (each in its own worktree)
5. Merges branches sequentially with automatic conflict resolution
6. Falls back to AI conflict resolver if needed

Requires a **bare git repository** setup. The skill includes pre-flight checks and error recovery for all failure modes.

### `/prime` — Load Architecture Context

Loads Serena MCP memory files into context for architecture-aware conversations.

```
/prime              # Load all architecture files
/prime api          # Load API-specific files only
/prime test         # Load test design files only
```

| Argument | Memory Files Loaded |
|----------|-------------------|
| `all` (default) | Solution architecture, API design, background services, tests |
| `src` | Solution architecture + all API layers + background services |
| `api` | Endpoint, controller, DTO, MediatR, services |
| `test` | Integration + unit test design |
| `arch` / `sln` | Solution architecture only |
| `bg` | Background service design only |

## Subagents

### PRD Agents

| Agent | Model | Description |
|-------|-------|-------------|
| `prd-gen-v2` | Opus | Generates complete PRDs from goal prompts with codebase analysis |
| `prd-plan-v2` | Sonnet | Generates wave-based parallel execution plans with dependency ordering |
| `prd-worker-v2` | Sonnet | Executes assigned build tasks in worktrees, writes structured results |
| `prd-reviewer-v2` | Opus | Reviews phases for execution-blocking ambiguities |
| `prd-edit-v2` | Sonnet | Applies targeted PRD edits from natural language |
| `prd-unblock-v2` | Sonnet | Investigates blocked tasks, generates resolution plans |
| `prd-retrospective-v1` | Sonnet | Post-build failure analysis, root cause patterns, learnings |
| `conflict-resolver-v1` | Sonnet | Resolves git merge/rebase conflicts using semantic analysis |

### Code Specialists

| Agent | Model | Description |
|-------|-------|-------------|
| `ts-expert` | Sonnet | TypeScript/JavaScript specialist — code review, latest docs, compiler verification |
| `tsql-expert` | Sonnet | SQL Server / T-SQL specialist — queries, stored procedures, optimization (SQL Server 2017+ compatible) |

## Hooks

| Event | Script | Purpose |
|-------|--------|---------|
| `PreCompact` | `backup-conversation.sh` | Backs up conversation transcript before context compression. Keeps last 10 backups. |
| `UserPromptSubmit` | `prd-plan-inject.sh` | Intercepts `/prd plan`, runs the plan pipeline, and outputs directly to transcript (no LLM passthrough needed). |
| `PreToolUse` | `skill-dispatcher.sh` | Routes Skill invocations to skill-specific argument parsers (e.g., `prd/scripts/parse-args.sh`). |
| `PreToolUse` | `validate-prd-json.sh` | Validates PRD JSON files against schemas before Write tool executes. Blocks invalid writes with error details. |

Additionally, `settings.json` includes inline `jq` hooks that log all prompts and tool calls with timestamps to `hooks-log.txt` and `skill-log.txt`.

## Status Line

### `statusline_script.sh`
Multi-line status bar displaying model name, context window usage with progress bar, working directory, 5-hour and weekly rate limit usage with reset countdowns, cost, and elapsed time.

Rate limit data (usage percentage and reset times) comes directly from Claude Code's JSON input — no estimation or external API calls needed.

**Configurable**: timezone, time format, colors, progress bar characters, system overhead offset.

## Settings

### Permission Model

| Mode | Scope |
|------|-------|
| **Allow** | Write, WebFetch, WebSearch, file listing/search, dotnet build/restore, Serena MCP tools |
| **Deny** | Secrets (.env, appsettings), sudo/chmod/chown, git push/remote, yarn/pnpm/nvm |
| **Ask** | rm, rmdir |

### Environment Variables

| Variable | Value |
|----------|-------|
| `ANTHROPIC_MODEL` | `claude-opus-4-6[1m]` (1M context) |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `95` |
| `DISABLE_AUTOUPDATER` | `1` |
| `ENABLE_TOOL_SEARCH` | `true` |

## Installation

### Copy into your project
```bash
git clone https://github.com/cdbowe/claude-code-tools.git
cp -r claude-code-tools/.claude /path/to/your/project/
```

### Use as addon directory
```bash
git clone https://github.com/cdbowe/claude-code-tools.git
claude --add-dir /path/to/claude-code-tools
```

### Post-install

1. Review and customize `settings.json` for your environment
2. Update permission allowlists/denylists for your security requirements
3. Set your preferred model in `env.ANTHROPIC_MODEL`
4. For `/worktree`: set up a bare git repository (see skill docs)
5. For `/prime`: configure Serena MCP server and populate memory files
6. For status line: review configurable options in `statusline_script.sh` (timezone, colors, etc.)

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- Bash, `jq`, `bc`
- Git (bare repo setup required for `/worktree`)
- Optional: [Serena MCP server](https://github.com/oraios/serena) (for `/prime` and agent code analysis tools)

## License

MIT
