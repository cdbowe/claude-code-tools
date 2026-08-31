#!/bin/bash
# PRD Review-All Compile Script - Enumerates phases and builds reviewer agent specs
# Usage: prd-review-all-compile.sh [--max-parallel N]
# Output: /tmp/.prd_review_all_compile.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate WORKSPACE_DIR is set and valid
if [ -z "$WORKSPACE_DIR" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi
if [ ! -d "$WORKSPACE_DIR" ]; then
    echo "{\"status\":\"error\",\"error\":\"WORKSPACE_DIR does not exist: $WORKSPACE_DIR\"}"
    exit 1
fi

# Worktree main directory - where source files actually live
# Check env var first, fallback to $WORKSPACE_DIR/main
WORKTREE_MAIN_DIR="${WORKTREE_MAIN_DIR:-$WORKSPACE_DIR/main}"

STATE_FILE="/tmp/.prd_state"
OUTPUT_FILE="/tmp/.prd_review_all_compile.json"
CACHE_FILE="/tmp/.prd_source_cache.json"
PASS_TRACKER="/tmp/.prd_review_pass_tracker"
PRD_BASE="$WORKSPACE_DIR/claude_files/PRDs"
MAX_PARALLEL="${1:-10}"

# Reviewer model comes from prd-models.json (role: phase-reviewer), not a literal.
REVIEWER_TIER=$(bash "$SCRIPT_DIR/prd-model.sh" role-tier phase-reviewer)
REVIEWER_MODEL=$(bash "$SCRIPT_DIR/prd-model.sh" role phase-reviewer)

# Reset pass tracker on fresh compile (new review-all session)
rm -f "$PASS_TRACKER"
rm -f /tmp/.prd_phase_review_*.json

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi
source "$STATE_FILE"

if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
    echo '{"status":"error","error":"No PRD loaded. Run /prd list first."}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

if [ ! -d "$PRD_DIR" ]; then
    echo "{\"status\":\"error\",\"error\":\"PRD directory not found: $PRD_DIR\"}"
    exit 1
fi

#------------------------------------------------------------------------------
# Collect all phase files (including infrastructure phase_0_*.json)
#------------------------------------------------------------------------------
phases="[]"
phase_files=()

for f in "$PRD_DIR"/phase_*.json; do
    [ -f "$f" ] || continue
    phase_files+=("$f")

    filename=$(basename "$f")
    phase_id=$(jq -r '.phaseId' "$f" 2>/dev/null || echo "0")
    phase_name=$(jq -r '.phaseName // "Unknown"' "$f" 2>/dev/null)
    task_count=$(jq '.tasks | length' "$f" 2>/dev/null || echo "0")
    is_infra=$(jq -r '.isInfrastructure // false' "$f" 2>/dev/null)

    # Use phaseId directly (no special "infra" naming - phase 0 is just "0")
    phase_id_str="$phase_id"

    phase_obj=$(jq -n \
        --arg phaseId "$phase_id_str" \
        --arg phaseFile "$filename" \
        --arg phaseName "$phase_name" \
        --argjson taskCount "$task_count" \
        --argjson isInfrastructure "$is_infra" \
        '{phaseId: $phaseId, phaseFile: $phaseFile, phaseName: $phaseName, taskCount: $taskCount, isInfrastructure: $isInfrastructure}')
    phases=$(echo "$phases" | jq --argjson obj "$phase_obj" '. + [$obj]')
done

total_phases=$(echo "$phases" | jq 'length')

if [ "$total_phases" -eq 0 ]; then
    echo '{"status":"error","error":"No phase files found in PRD directory"}'
    exit 1
fi

#------------------------------------------------------------------------------
# Build source cache (analyze targetFiles from all phases)
#------------------------------------------------------------------------------
all_target_files="[]"
missing_files="[]"
source_files="{}"

for f in "${phase_files[@]}"; do
    # Extract all targetFiles from this phase
    target_files=$(jq -r '.tasks[]?.targetFiles[]? // empty' "$f" 2>/dev/null)
    for tf in $target_files; do
        [ -z "$tf" ] && continue
        # Normalize path
        if [[ "$tf" != /* ]]; then
            full_path="$WORKTREE_MAIN_DIR/$tf"
        else
            full_path="$tf"
        fi

        # Check if already processed
        exists_in_list=$(echo "$all_target_files" | jq --arg f "$tf" 'any(. == $f)')
        if [ "$exists_in_list" = "true" ]; then
            continue
        fi

        all_target_files=$(echo "$all_target_files" | jq --arg f "$tf" '. + [$f]')

        if [ -f "$full_path" ]; then
            file_size=$(stat -c%s "$full_path" 2>/dev/null || echo "0")
            last_modified=$(stat -c%Y "$full_path" 2>/dev/null || echo "0")

            source_files=$(echo "$source_files" | jq \
                --arg path "$tf" \
                --argjson exists true \
                --argjson size "$file_size" \
                --arg modified "$last_modified" \
                '. + {($path): {exists: $exists, size: $size, lastModified: $modified}}')
        else
            missing_files=$(echo "$missing_files" | jq --arg f "$tf" '. + [$f]')
        fi
    done
done

# Write source cache
jq -n \
    --arg prd "$ACTIVE_PRD" \
    --arg timestamp "$(date -Iseconds)" \
    --argjson sourceFiles "$source_files" \
    --argjson missingFiles "$missing_files" \
    '{cacheVersion: 1, prd: $prd, timestamp: $timestamp, sourceFiles: $sourceFiles, missingFiles: $missingFiles}' > "$CACHE_FILE"

#------------------------------------------------------------------------------
# Read AGENT_CONTEXT for prompts
#------------------------------------------------------------------------------
CONTEXT_FILE="$PRD_DIR/AGENT_CONTEXT.md"
if [ ! -f "$CONTEXT_FILE" ]; then
    CONTEXT_FILE="$PRD_DIR/00_ROOT.md"
fi
AGENT_CONTEXT=""
if [ -f "$CONTEXT_FILE" ]; then
    AGENT_CONTEXT=$(cat "$CONTEXT_FILE")
fi

#------------------------------------------------------------------------------
# Build agent specs (one per phase, up to MAX_PARALLEL concurrent)
#------------------------------------------------------------------------------
agents="[]"

for ((i=0; i<total_phases; i++)); do
    phase=$(echo "$phases" | jq ".[$i]")
    phase_id=$(echo "$phase" | jq -r '.phaseId')
    phase_file=$(echo "$phase" | jq -r '.phaseFile')
    phase_name=$(echo "$phase" | jq -r '.phaseName')
    task_count=$(echo "$phase" | jq -r '.taskCount')
    is_infra=$(echo "$phase" | jq -r '.isInfrastructure // false')

    # Use consistent "reviewer-pN" naming for all phases (including phase 0)
    agent_id="reviewer-p${phase_id}"
    phase_path="$PRD_DIR/$phase_file"

    # Build prompt for reviewer agent
    prompt=$(cat <<PROMPT_EOF
## Review Assignment

**PRD**: $ACTIVE_PRD
**Phase**: $phase_id - $phase_name
**Phase File**: $phase_path
**Task Count**: $task_count

## Source Cache

Source cache is available at: $CACHE_FILE
Read this file first to understand which target files exist and which are missing.

## Agent Context

$AGENT_CONTEXT

## CRITICAL: Bounded Review Policy

Flag ONLY these issues:
- HIGH: targetFiles refs non-existent file, invalid dependsOn taskId, circular dependency
- MEDIUM: empty targetFiles for create-file, no acceptance criteria, Blocked without reason, empty description

DO NOT flag: style preferences, alternative implementations, optional improvements.
Target: ZERO false positives.

## Output Requirements

Write your review results to \`/tmp/.prd_phase_review_${phase_id}.json\`

Return ONLY this single-line JSON as your final response:
{"phaseId":"$phase_id","status":"complete|error","findingsCount":N,"high":H,"medium":M,"low":L}
PROMPT_EOF
)

    agent_obj=$(jq -n \
        --arg agentId "$agent_id" \
        --arg phaseId "$phase_id" \
        --arg phaseFile "$phase_file" \
        --arg phaseName "$phase_name" \
        --arg modelTier "$REVIEWER_TIER" \
        --arg model "$REVIEWER_MODEL" \
        --arg prompt "$prompt" \
        '{agentId: $agentId, phaseId: $phaseId, phaseFile: $phaseFile, phaseName: $phaseName, modelTier: $modelTier, model: $model, prompt: $prompt}')
    agents=$(echo "$agents" | jq --argjson obj "$agent_obj" '. + [$obj]')
done

#------------------------------------------------------------------------------
# Calculate parallel batches
#------------------------------------------------------------------------------
parallel_batches=$(( (total_phases + MAX_PARALLEL - 1) / MAX_PARALLEL ))

#------------------------------------------------------------------------------
# Write output file
#------------------------------------------------------------------------------
jq -n \
    --arg status "ready" \
    --arg prd "$ACTIVE_PRD" \
    --arg prdDir "$PRD_DIR" \
    --argjson phases "$phases" \
    --argjson agents "$agents" \
    --argjson totalPhases "$total_phases" \
    --argjson maxParallel "$MAX_PARALLEL" \
    --argjson parallelBatches "$parallel_batches" \
    --arg sourceCacheFile "$CACHE_FILE" \
    --argjson missingFilesCount "$(echo "$missing_files" | jq 'length')" \
    '{
        status: $status,
        prd: $prd,
        prdDir: $prdDir,
        phases: $phases,
        agents: $agents,
        totalPhases: $totalPhases,
        maxParallel: $maxParallel,
        parallelBatches: $parallelBatches,
        sourceCacheFile: $sourceCacheFile,
        missingFilesCount: $missingFilesCount
    }' > "$OUTPUT_FILE"

# Output summary
echo "{\"status\":\"ready\",\"phases\":$total_phases,\"agents\":$total_phases,\"batches\":$parallel_batches,\"missingFiles\":$(echo "$missing_files" | jq 'length')}"
