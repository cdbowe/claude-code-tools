# Claude Code Tools

A production-tested collection of custom skills, subagents, hooks, and scripts for Claude Code. I use these on a daily basis in my own Claude-assisted development workflows.

Built for real-world development workflows: PRD-driven planning with parallel execution, git worktree orchestration, usage tracking, and more.

## Why I Built This

Coding agents fail predictably at scale: they one-shot large tasks, produce output that is confident, plausible, and wrong, and burn tokens on work a shell script could do for free. This toolkit is the workflow I built to solve that on a production codebase where I'm the only engineer.

**Design principles**

| Principle | Implementation |
|-----------|----------------|
| No one-shotting | Work decomposes into sequential phases; tasks parallelize *within* a phase |
| Quality gates at boundaries | Review/validation layer between every wave — a phase can't advance on broken output |
| Validate at agent handoffs | Schema validation between agents; pipeline self-corrects or stalls and escalates to a human |
| Bounded retries | Failed tests retry up to N times, then stop and ask rather than looping |
| Script-first orchestration | Deterministic work runs locally in bash — not paid for in tokens |
| JSON over markdown | Structured state that `jq` reads and mutates cheaply, instead of rewriting prose files |
| Model routing by cost | Expensive models only where task difficulty justifies them |
| Backgrounded specialists | Purpose-built subagents keep the main context window clean |

**Result:** a database migration originally scoped at ~6 months shipped in 2, with documentation and workflow state persisted to disk so long sessions don't re-pay for context.


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

## Use in other workspaces

`install.sh` copies these modules into a Claude Code config directory. It's the source of truth for the install layout, so it works whether you run it by hand or have [devcontainer-init](https://github.com/cdbowe/devcontainer-init) invoke it.

```bash
# Into your user config ($CLAUDE_CONFIG_DIR, else ~/.claude): settings.json + statusline
./install.sh

# Into a project's .claude/, and seed settings.local.json (won't overwrite an existing one)
./install.sh --dir "$WORKSPACE_DIR/.claude" --with-local

# The full toolkit (agents, commands, hooks too)
./install.sh --all
```

| Flag | Effect |
|------|--------|
| `--dir TARGET` | Destination config dir. Default: `$CLAUDE_CONFIG_DIR`, else `~/.claude` |
| `--minimal` | Copy `settings.json` + `statusline/` only *(default)* |
| `--all` | Also copy `agents/`, `commands/`, `hooks/`, `rules/`, and set up the `/prd` environment |
| `--with-local` | Also seed `settings.local.json` (only if absent, unless `--force`) |
| `--force` | Re-seed `settings.local.json` from the repo's copy even if it already exists |
| `--no-prd-env` | Skip the `/prd` environment setup that `--all` performs |

The install is idempotent and never clobbers an existing `settings.local.json` unless you pass `--force`.

### `/prd` environment setup

Copying files is necessary but not sufficient for `/prd` — it also needs an executable script set, a PRD base dir, and a **split bare-repo git layout**. With `--all`, and only when `--dir` points at `$WORKSPACE_DIR/.claude`, `install.sh` does the parts that are safe and idempotent:

- `chmod +x` on the installed hooks and command scripts (bind mounts routinely drop the bit, and `Bash(chmod:*)` is denied in `settings.json`, so it can't be repaired from inside a session);
- `mkdir -p $WORKSPACE_DIR/claude_files/PRDs`.

It then runs `prd-doctor.sh` and **reports** what it won't do on its own. It never runs `git init`, creates branches, or relocates a checkout into `main/` — restructuring a working tree unattended from `postCreateCommand` is destructive.

`/prd build` is worktree-based and expects the primary checkout at `$WORKSPACE_DIR/main` with worktrees under `$WORKSPACE_DIR/worktrees` (override the former with `WORKTREE_MAIN_DIR`). A plain `git init` at the workspace root does **not** satisfy this.

### Runtime dependencies

`/prd` needs these on `PATH` in the container. `install.sh` cannot install them — `prd-doctor.sh` reports a missing one as a hard failure.

| Binary | Needed by | Breaks if missing |
|--------|-----------|-------------------|
| `jq` | every PRD script | all of `/prd` |
| `python3` | `prd-plan.sh`, `prd-unblock-compile.sh` (topological sort + wave splitting) | `/prd plan`, `/prd unblock` |
| `git` | `worktree-*.sh`, `commit-main.sh` | `/prd build` |

This repo's `.devcontainer/Dockerfile` installs all three. **If you consume this toolkit from a devcontainer generated elsewhere, add `python3` to that image** — `jq` and `git` are usually present already, `python3` often is not on `debian:*-slim` bases.

### Model versions per tier

`/prd` picks a model per task type. Both the task-type→tier map and the exact version each tier resolves to live in **`.claude/prd-models.json`**, which `install.sh --all` copies into the target so a new environment runs the versions pinned in this repo.

```json
"tiers":    { "opus": "claude-opus-5[1m]", "sonnet": "claude-sonnet-5[1m]", "haiku": "claude-haiku-4-5" },
"taskTypes": { "generate-test": "sonnet", "create-file": "sonnet", "verify": "sonnet" },
"defaultTaskTier": "haiku",
"roles":    { "phase-reviewer": "opus", "unblock-plan": "sonnet", "unblock-task": "haiku" }
```

To pin a different version, edit `tiers` — nothing else references a version string. To change which tier a task type gets, edit `taskTypes`. `roles` covers the three non-worker decisions (phase reviewers, unblock planning, unblock retries).

Inspect what everything resolves to:

```bash
bash "$WORKSPACE_DIR/.claude/commands/prd/scripts/prd-model.sh" --list
```

Plans carry both `modelTier` (the alias, used for validation and display) and `model` (the exact version passed to `Task(model: ...)`), so `/prd plan` shows the version each task will actually run on. A task type mapped to a tier that doesn't exist is a hard error, not a silent fallback — `prd-doctor.sh` checks for it.

| Tier | Default | Input / output per MTok | Context |
|------|---------|------------------------|---------|
| `opus` | `claude-opus-5[1m]` | $5 / $25 | 1M |
| `sonnet` | `claude-sonnet-5[1m]` | $3 / $15 | 1M |
| `haiku` | `claude-haiku-4-5` | $1 / $5 | 200K |

Diagnose a broken `/prd` at any time, without re-installing:

```bash
bash "$WORKSPACE_DIR/.claude/commands/prd/scripts/prd-doctor.sh"   # --strict to fail on build-only warnings
```

`FAIL` blocks all of `/prd`; `WARN` affects only `/prd build` or self-heals on first use. Exit code is non-zero only on `FAIL` (or any finding under `--strict`).

## Pairing with devcontainer-init

[devcontainer-init](https://github.com/cdbowe/devcontainer-init)'s `claude-code` template can wire this repo into a freshly generated devcontainer automatically. Keep a checkout of `claude-code-tools` next to your project (a sibling `../claude-code-tools`), then generate with the template:

```bash
devcontainer-init --template claude-code   # wizard prompts for the checkout path
```

On container create it mounts this checkout read-only at `/opt/claude-code-tools` and runs `install.sh` twice:

- into `$CLAUDE_CONFIG_DIR` (the shared `claude-code-home` volume) — `settings.json` + statusline, so the statusline works from any directory and survives rebuilds;
- into `$WORKSPACE_DIR/.claude` with `--with-local` — project-scoped config plus a seeded `settings.local.json`.

If you use `--all` to get `/prd`, the generated image also needs `jq` and `python3` (see [Runtime dependencies](#runtime-dependencies)) — `install.sh` copies files but cannot install packages. Run `prd-doctor.sh` after the first build to confirm.

Because the project-scoped copy is bind-mounted back to the host, add this to your **project's** `.gitignore`:

```gitignore
.claude/settings.local.json
```

## License

MIT
