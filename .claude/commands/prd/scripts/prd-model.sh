#!/bin/bash
# prd-model.sh - Resolve /prd model tiers to concrete Claude model versions.
#
# Reads prd-models.json (the pipeline's single source of truth for model
# versions) and resolves a tier, task type, or role to the exact model ID that
# should be passed to Task(model: ...).
#
# Usage:
#   prd-model.sh tier <opus|sonnet|haiku>   Concrete version for a tier
#   prd-model.sh task-type <taskType>       Concrete version for a task type
#   prd-model.sh tier-for <taskType>        Tier NAME for a task type (no version)
#   prd-model.sh role <roleName>            Concrete version for a pipeline role
#   prd-model.sh --json                     Whole config as JSON (for jq --argjson)
#   prd-model.sh --list                     Human-readable resolution table
#
# Config lookup order:
#   1. $PRD_MODELS_CONFIG
#   2. <claude-dir>/prd-models.json, derived from this script's own location
#   3. $WORKSPACE_DIR/.claude/prd-models.json
#
# Exit codes: 0 resolved | 1 config missing/invalid | 2 unknown key or bad usage

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "prd-model.sh: jq is required but not on PATH" >&2
    exit 1
fi

# scripts/ -> prd/ -> commands/ -> .claude/
SELF_CLAUDE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd || true)"

CONFIG=""
for candidate in \
    "${PRD_MODELS_CONFIG:-}" \
    "${SELF_CLAUDE_DIR:+$SELF_CLAUDE_DIR/prd-models.json}" \
    "${WORKSPACE_DIR:+$WORKSPACE_DIR/.claude/prd-models.json}"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { CONFIG="$candidate"; break; }
done

if [ -z "$CONFIG" ]; then
    echo "prd-model.sh: prd-models.json not found (set PRD_MODELS_CONFIG or run install.sh --all)" >&2
    exit 1
fi

if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    echo "prd-model.sh: $CONFIG is not valid JSON" >&2
    exit 1
fi

# Resolve a tier name to its concrete version, failing loudly on an unknown tier
# rather than emitting an empty model string into a plan.
resolve_tier() {
    local tier="$1" version
    version=$(jq -r --arg t "$tier" '.tiers[$t] // empty' "$CONFIG")
    if [ -z "$version" ]; then
        echo "prd-model.sh: unknown tier '$tier' (have: $(jq -r '.tiers | keys | join(", ")' "$CONFIG"))" >&2
        exit 2
    fi
    printf '%s\n' "$version"
}

tier_for_task_type() {
    jq -r --arg tt "$1" '.taskTypes[$tt] // .defaultTaskTier // "haiku"' "$CONFIG"
}

case "${1:-}" in
    tier)
        [ $# -eq 2 ] || { echo "usage: prd-model.sh tier <name>" >&2; exit 2; }
        resolve_tier "$2"
        ;;
    task-type)
        [ $# -eq 2 ] || { echo "usage: prd-model.sh task-type <taskType>" >&2; exit 2; }
        resolve_tier "$(tier_for_task_type "$2")"
        ;;
    tier-for)
        [ $# -eq 2 ] || { echo "usage: prd-model.sh tier-for <taskType>" >&2; exit 2; }
        tier_for_task_type "$2"
        ;;
    role|role-tier)
        [ $# -eq 2 ] || { echo "usage: prd-model.sh $1 <roleName>" >&2; exit 2; }
        tier=$(jq -r --arg r "$2" '.roles[$r] // empty' "$CONFIG")
        if [ -z "$tier" ]; then
            echo "prd-model.sh: unknown role '$2' (have: $(jq -r '.roles | keys | join(", ")' "$CONFIG"))" >&2
            exit 2
        fi
        # role -> concrete version; role-tier -> the tier alias
        if [ "$1" = "role-tier" ]; then printf '%s\n' "$tier"; else resolve_tier "$tier"; fi
        ;;
    --json)
        jq -c 'del(._comment)' "$CONFIG"
        ;;
    --list)
        echo "config: $CONFIG"
        echo
        printf '  %-16s %s\n' "TIER" "VERSION"
        jq -r '.tiers | to_entries[] | "\(.key)|\(.value)"' "$CONFIG" \
          | awk -F'|' '{ printf "  %-16s %s\n", $1, $2 }'
        echo
        printf '  %-16s %-10s %s\n' "TASK TYPE" "TIER" "VERSION"
        jq -r '
          (.taskTypes // {}) as $tt | .tiers as $tiers |
          ((.defaultTaskTier // "haiku") as $d |
            ($tt | to_entries[] | "\(.key)|\(.value)|\($tiers[.value] // "UNRESOLVED")"),
            "(default)|\($d)|\($tiers[$d] // "UNRESOLVED")")
        ' "$CONFIG" | awk -F'|' '{ printf "  %-16s %-10s %s\n", $1, $2, $3 }'
        echo
        printf '  %-16s %-10s %s\n' "ROLE" "TIER" "VERSION"
        jq -r '
          .tiers as $tiers |
          (.roles // {}) | to_entries[] | "\(.key)|\(.value)|\($tiers[.value] // "UNRESOLVED")"
        ' "$CONFIG" | awk -F'|' '{ printf "  %-16s %-10s %s\n", $1, $2, $3 }'
        ;;
    -h|--help)
        grep '^#' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "prd-model.sh: unknown command '${1:-}' (try --help)" >&2
        exit 2
        ;;
esac
