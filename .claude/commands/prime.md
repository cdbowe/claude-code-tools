---
allowed-tools: mcp__serena__list_memories mcp__serena__read_memory
argument-hint: [all|src|arch|sln|api|test|bg]
description: Load Serena MCP architecture/design memory files into context
model: haiku
disable-model-invocation: true
---

## Argument Mapping

Default empty `$ARGUMENTS` to `all`.

| Arg | Memory Files |
|-----|--------------|
| `all` | solution-architecture, api-endpoint-design, api-controller-design, api-dto-design, api-mediatr-handlers, api-services-layer, background-service-design, integration-test-design, unit-test-design |
| `src` | solution-architecture, api-endpoint-design, api-controller-design, api-dto-design, api-mediatr-handlers, api-services-layer, background-service-design |
| `arch`/`sln` | solution-architecture |
| `api` | api-endpoint-design, api-controller-design, api-dto-design, api-mediatr-handlers, api-services-layer |
| `test` | integration-test-design, unit-test-design |
| `bg` | background-service-design |

If `$ARGUMENTS` doesn't match, respond: "Unknown group. Valid: all, src, arch, sln, api, test, bg"

## Execution

1. Parse `$ARGUMENTS` to matched group (default: all)
2. Call `mcp__serena__read_memory` for each file in parallel
3. Respond: `Primed: {group} ({N} files loaded)`
4. Do not summarize contents — load for context only
