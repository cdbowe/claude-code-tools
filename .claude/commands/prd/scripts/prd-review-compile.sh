#!/bin/bash
# PRD Review Compile — assembles reviewer prompts for workers that passed pre-check.
# Usage: prd-review-compile.sh <waveId>
# Requires: /tmp/.prd_build.json, /tmp/.prd_precheck_{agentId}.json, /tmp/.prd_agent_{agentId}_results.json
# Output: /tmp/.prd_review_compile.json + /tmp/.prd_reviewer_{agentId}_prompt.md per reviewer

set -e

WAVE_ID="$1"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspaces/bankjet}"
BUILD_FILE="/tmp/.prd_build.json"
OUTPUT_FILE="/tmp/.prd_review_compile.json"
PRIME_SKILL="/tmp/claude-workspace/skills/prime/SKILL.md"

if [ -z "$WAVE_ID" ]; then
    echo '{"status":"error","error":"Usage: prd-review-compile.sh <waveId>"}'
    exit 1
fi

if [ ! -f "$BUILD_FILE" ]; then
    echo '{"status":"error","error":"Build manifest not found: /tmp/.prd_build.json"}'
    exit 1
fi

# --- Parse /prime skill for memory file mapping (if available) ---

prime_available=false
prime_mappings=""
if [ -f "$PRIME_SKILL" ]; then
    prime_available=true
fi

get_prime_arg_for_task() {
    local target_files="$1"
    if echo "$target_files" | grep -qi "bankjet-myaccount-react-web\|react"; then
        echo "all"
    elif echo "$target_files" | grep -qi "BankJet\.Web\|WebForms\|\.aspx\|BankJet\.Admin"; then
        echo "legacy"
    elif echo "$target_files" | grep -qi "BankJet\.Data\|\.Tests\|tests/"; then
        echo "legacy"
    else
        echo "everything"
    fi
}

get_memory_files_for_arg() {
    local arg="$1"
    case "$arg" in
        all)
            echo "myaccount_react_api_client_layer myaccount_react_hooks_data_layer myaccount_react_pages_layer myaccount_react_components_layer myaccount_react_routing_layer myaccount_react_state_types_lib_layer react_unit_testing_patterns react_e2e_testing_patterns"
            ;;
        legacy)
            echo "webforms_architecture webforms_page_inventory e2e_testing_patterns_and_bugs api_e2e_known_patterns db_schema_testdatafactory"
            ;;
        everything)
            echo "$(get_memory_files_for_arg all) $(get_memory_files_for_arg legacy)"
            ;;
        *)
            echo ""
            ;;
    esac
}

# --- Get wave agents from build manifest ---

wave_json=$(jq ".waves[] | select(.waveId == $WAVE_ID)" "$BUILD_FILE")
if [ -z "$wave_json" ]; then
    echo "{\"status\":\"error\",\"error\":\"Wave $WAVE_ID not found in build manifest\"}"
    exit 1
fi

agent_count=$(echo "$wave_json" | jq '.agents | length')

reviewers="[]"
skipped_blocked="[]"
skipped_precheck="[]"

for ((i=0; i<agent_count; i++)); do
    agent=$(echo "$wave_json" | jq ".agents[$i]")
    agent_id=$(echo "$agent" | jq -r '.agentId')
    worktree=$(echo "$agent" | jq -r '.worktree // empty')
    branch=$(echo "$agent" | jq -r '.branch // empty')

    result_file="/tmp/.prd_agent_${agent_id}_results.json"
    precheck_file="/tmp/.prd_precheck_${agent_id}.json"

    worktree_path="${WORKSPACE_DIR}/worktrees/${worktree}"

    # --- Check worker result ---

    if [ ! -f "$result_file" ]; then
        skipped_blocked=$(echo "$skipped_blocked" | jq --arg aid "$agent_id" '. + [$aid]')
        continue
    fi

    worker_status=$(jq -r '.status // "unknown"' "$result_file")
    if [ "$worker_status" = "blocked" ]; then
        skipped_blocked=$(echo "$skipped_blocked" | jq --arg aid "$agent_id" '. + [$aid]')
        continue
    fi

    # --- Check pre-check result ---

    if [ ! -f "$precheck_file" ]; then
        skipped_precheck=$(echo "$skipped_precheck" | jq --arg aid "$agent_id" '. + [$aid]')
        continue
    fi

    precheck_passed=$(jq -r '.passed' "$precheck_file")
    if [ "$precheck_passed" != "true" ]; then
        skipped_precheck=$(echo "$skipped_precheck" | jq --arg aid "$agent_id" '. + [$aid]')
        continue
    fi

    requires_user_approval=$(jq -r '.requiresUserApproval' "$precheck_file")

    # --- Build reviewer prompt ---

    PROMPT_FILE="/tmp/.prd_reviewer_${agent_id}_prompt.md"

    # Get git diff
    git_diff=""
    if [ -d "$worktree_path" ] && [ -n "$branch" ]; then
        git_diff=$(cd "$worktree_path" && git diff main..."$branch" 2>/dev/null || echo "(diff unavailable)")
    fi

    # Get task definition from build manifest
    task_definition=$(echo "$agent" | jq -r '.prompt // empty' | head -200)

    # Get worker result
    worker_result=$(cat "$result_file")

    # Get pre-check result
    precheck_result=$(cat "$precheck_file")

    # Determine architecture context instructions
    arch_context_instructions=""
    if [ "$prime_available" = true ]; then
        target_files=$(jq -r '.targetFiles // [] | join(" ")' "$result_file" 2>/dev/null || echo "")
        if [ -z "$target_files" ]; then
            target_files=$(echo "$agent" | jq -r '[.tasks[]? | .targetFiles[]?] // [] | join(" ")' 2>/dev/null || echo "")
        fi
        prime_arg=$(get_prime_arg_for_task "$target_files")
        memory_files=$(get_memory_files_for_arg "$prime_arg")

        if [ -n "$memory_files" ]; then
            arch_context_instructions="## Architecture Context\n\nLoad workspace architecture context by calling \`mcp__serena__read_memory\` for each of these files (call in parallel):\n"
            for mf in $memory_files; do
                arch_context_instructions="${arch_context_instructions}\n- \`${mf}\`"
            done
            arch_context_instructions="${arch_context_instructions}\n\nThis provides workspace conventions and patterns for your review."
        fi
    fi

    # Write prompt file (temp file approach to avoid heredoc backtick issues)
    cat > "$PROMPT_FILE" << PROMPT_HEADER
# Review Assignment

## Agent Info

- **Agent ID:** ${agent_id}
- **Worktree:** ${worktree_path}
- **Branch:** ${branch}
- **Requires User Approval:** ${requires_user_approval}

PROMPT_HEADER

    # Architecture context (may contain backticks)
    if [ -n "$arch_context_instructions" ]; then
        echo -e "$arch_context_instructions" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    cat >> "$PROMPT_FILE" << 'PROMPT_DIFF_HEADER'
## Git Diff (main...branch)

```diff
PROMPT_DIFF_HEADER

    echo "$git_diff" >> "$PROMPT_FILE"

    cat >> "$PROMPT_FILE" << 'PROMPT_DIFF_FOOTER'
```

PROMPT_DIFF_FOOTER

    cat >> "$PROMPT_FILE" << PROMPT_WORKER
## Worker Result

\`\`\`json
${worker_result}
\`\`\`

## Pre-Check Result

\`\`\`json
${precheck_result}
\`\`\`

PROMPT_WORKER

    # Task definition (from the worker's original prompt — first 200 lines for context)
    if [ -n "$task_definition" ]; then
        echo "## Task Definition (from build manifest)" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
        echo "$task_definition" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi

    # Add to reviewers list
    reviewers=$(echo "$reviewers" | jq \
        --arg aid "$agent_id" \
        --arg pf "$PROMPT_FILE" \
        --arg wt "$worktree" \
        --argjson rua "$requires_user_approval" \
        '. + [{"agentId": $aid, "promptFile": $pf, "worktree": $wt, "requiresUserApproval": $rua}]')
done

# --- Write output ---

jq -n \
    --argjson wid "$WAVE_ID" \
    --argjson reviewers "$reviewers" \
    --argjson sb "$skipped_blocked" \
    --argjson sp "$skipped_precheck" \
    '{
        waveId: $wid,
        reviewers: $reviewers,
        skippedBlocked: $sb,
        skippedPreCheck: $sp
    }' > "$OUTPUT_FILE"

reviewer_count=$(echo "$reviewers" | jq 'length')
echo "{\"status\":\"compiled\",\"waveId\":$WAVE_ID,\"reviewers\":$reviewer_count,\"skippedBlocked\":$(echo "$skipped_blocked" | jq 'length'),\"skippedPreCheck\":$(echo "$skipped_precheck" | jq 'length')}"
