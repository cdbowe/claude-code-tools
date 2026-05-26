#!/bin/bash
# PRD Review-All Aggregate Script - Combines per-phase review results into unified findings
# Usage: prd-review-all-aggregate.sh
# Input: /tmp/.prd_phase_review_*.json files
# Output: /tmp/.prd_review_all_findings.json

set -e

STATE_FILE="/tmp/.prd_state"
COMPILE_FILE="/tmp/.prd_review_all_compile.json"
OUTPUT_FILE="/tmp/.prd_review_all_findings.json"
PASS_TRACKER="/tmp/.prd_review_pass_tracker"

# Constants for convergence
MAX_PASSES=3

# Read state
if [ ! -f "$STATE_FILE" ]; then
    echo '{"status":"error","error":"No PRD loaded."}'
    exit 1
fi
source "$STATE_FILE"

# Read compile file for phase info
if [ ! -f "$COMPILE_FILE" ]; then
    echo '{"status":"error","error":"Compile file not found. Run prd-review-all-compile.sh first."}'
    exit 1
fi

total_phases=$(jq -r '.totalPhases' "$COMPILE_FILE")

#------------------------------------------------------------------------------
# Track pass number for convergence
#------------------------------------------------------------------------------
current_pass=1
if [ -f "$PASS_TRACKER" ]; then
    current_pass=$(cat "$PASS_TRACKER")
    current_pass=$((current_pass + 1))
fi
echo "$current_pass" > "$PASS_TRACKER"

#------------------------------------------------------------------------------
# Collect all per-phase review results
#------------------------------------------------------------------------------
all_findings="[]"
phase_summaries="[]"
phases_reviewed=0
phases_failed=0
failed_phases="[]"

for review_file in /tmp/.prd_phase_review_*.json; do
    [ -f "$review_file" ] || continue

    status=$(jq -r '.status // "unknown"' "$review_file" 2>/dev/null)
    phase_id=$(jq -r '.phaseId // .phase // "?"' "$review_file" 2>/dev/null)
    phase_name=$(jq -r '.phaseName // "Unknown"' "$review_file" 2>/dev/null)

    if [ "$status" = "complete" ]; then
        phases_reviewed=$((phases_reviewed + 1))

        # Get phaseFile from compile data (compare as strings, handle empty result)
        phase_file=$(jq -r --arg pid "$phase_id" '.phases[] | select(.phaseId == $pid) | .phaseFile' "$COMPILE_FILE" 2>/dev/null)
        if [ -z "$phase_file" ] || [ "$phase_file" = "null" ]; then
            phase_file="phase_${phase_id}.json"
        fi

        # Extract findings with phase context
        findings=$(jq --arg phase "$phase_id" --arg phaseName "$phase_name" --arg phaseFile "$phase_file" \
            '[.findings[]? | . + {phase: ($phase | tonumber), phaseName: $phaseName, phaseFile: $phaseFile}]' "$review_file" 2>/dev/null || echo "[]")
        all_findings=$(echo "$all_findings $findings" | jq -s '.[0] + .[1]')

        # Extract summary
        summary=$(jq '{
            phase: (.phaseId // .phase),
            phaseName: .phaseName,
            findings: (.summary.total // 0),
            high: (.summary.high // 0),
            medium: (.summary.medium // 0),
            low: (.summary.low // 0),
            sourceFilesAnalyzed: (.sourceFilesAnalyzed // 0)
        }' "$review_file" 2>/dev/null)
        phase_summaries=$(echo "$phase_summaries" | jq --argjson s "$summary" '. + [$s]')
    else
        phases_failed=$((phases_failed + 1))
        error_msg=$(jq -r '.error // "Unknown error"' "$review_file" 2>/dev/null)
        failed_obj=$(jq -n --arg phase "$phase_id" --arg error "$error_msg" '{phase: $phase, error: $error}')
        failed_phases=$(echo "$failed_phases" | jq --argjson f "$failed_obj" '. + [$f]')
    fi
done

#------------------------------------------------------------------------------
# Sort findings by severity
#------------------------------------------------------------------------------
high_findings=$(echo "$all_findings" | jq '[.[] | select(.severity == "high")]')
medium_findings=$(echo "$all_findings" | jq '[.[] | select(.severity == "medium")]')
low_findings=$(echo "$all_findings" | jq '[.[] | select(.severity == "low")]')

high_count=$(echo "$high_findings" | jq 'length')
medium_count=$(echo "$medium_findings" | jq 'length')
low_count=$(echo "$low_findings" | jq 'length')
total_findings=$(echo "$all_findings" | jq 'length')

#------------------------------------------------------------------------------
# Count by type
#------------------------------------------------------------------------------
ambiguous_count=$(echo "$all_findings" | jq '[.[] | select(.type == "ambiguous")] | length')
missing_count=$(echo "$all_findings" | jq '[.[] | select(.type == "missing")] | length')
clarification_count=$(echo "$all_findings" | jq '[.[] | select(.type == "clarification")] | length')

#------------------------------------------------------------------------------
# Calculate convergence status
# CONVERGED when: high == 0 AND medium == 0
#------------------------------------------------------------------------------
if [ "$high_count" -eq 0 ] && [ "$medium_count" -eq 0 ]; then
    converged=true
    readiness_status="ready"
    readiness_message="PRD is ready for execution (no HIGH/MEDIUM issues)"
elif [ "$current_pass" -ge "$MAX_PASSES" ]; then
    converged=false
    readiness_status="max-passes-reached"
    readiness_message="Max review passes ($MAX_PASSES) reached. Manual review required for $high_count HIGH and $medium_count MEDIUM issues."
else
    converged=false
    if [ "$high_count" -gt 0 ]; then
        readiness_status="blocked"
        readiness_message="$high_count HIGH severity issues must be resolved"
    else
        readiness_status="needs-work"
        readiness_message="$medium_count MEDIUM severity issues should be resolved"
    fi
fi

# Legacy readiness score (kept for compatibility)
readiness_score=$((100 - (high_count * 15) - (medium_count * 5) - (low_count * 1)))
if [ "$readiness_score" -lt 0 ]; then
    readiness_score=0
fi

#------------------------------------------------------------------------------
# Count auto-fixable findings
#------------------------------------------------------------------------------
auto_fixable_count=$(echo "$all_findings" | jq '[.[] | select(.autoFixable == true)] | length')

#------------------------------------------------------------------------------
# Group non-autoFixable findings by type + recommendedFix (for read-only display)
#------------------------------------------------------------------------------
manual_fix_groups=$(echo "$all_findings" | jq '
    [.[] | select(.autoFixable == false)] |
    group_by(.type + "|" + (.recommendedFix // "")) |
    map({
        type: .[0].type,
        recommendedFix: .[0].recommendedFix,
        severity: .[0].severity,
        count: length,
        taskIds: [.[].taskId] | unique,
        phases: [.[].phase] | unique
    }) |
    sort_by(
        if .severity == "high" then 0
        elif .severity == "medium" then 1
        else 2 end
    )
')

#------------------------------------------------------------------------------
# Write output file
#------------------------------------------------------------------------------
jq -n \
    --arg status "complete" \
    --arg prd "$ACTIVE_PRD" \
    --argjson phasesReviewed "$phases_reviewed" \
    --argjson phasesFailed "$phases_failed" \
    --argjson totalFindings "$total_findings" \
    --argjson highCount "$high_count" \
    --argjson mediumCount "$medium_count" \
    --argjson lowCount "$low_count" \
    --argjson currentPass "$current_pass" \
    --argjson maxPasses "$MAX_PASSES" \
    --argjson converged "$converged" \
    --argjson findingsBySeverity "$(jq -n \
        --argjson high "$high_findings" \
        --argjson medium "$medium_findings" \
        --argjson low "$low_findings" \
        '{high: $high, medium: $medium, low: $low}')" \
    --argjson findingsByType "$(jq -n \
        --argjson ambiguous "$ambiguous_count" \
        --argjson missing "$missing_count" \
        --argjson clarification "$clarification_count" \
        '{ambiguous: $ambiguous, missing: $missing, clarification: $clarification}')" \
    --argjson phaseSummaries "$phase_summaries" \
    --argjson failedPhases "$failed_phases" \
    --argjson readinessScore "$readiness_score" \
    --arg readinessStatus "$readiness_status" \
    --arg readinessMessage "$readiness_message" \
    --argjson autoFixableCount "$auto_fixable_count" \
    --argjson manualFixGroups "$manual_fix_groups" \
    '{
        status: $status,
        prd: $prd,
        phasesReviewed: $phasesReviewed,
        phasesFailed: $phasesFailed,
        totalFindings: $totalFindings,
        highCount: $highCount,
        mediumCount: $mediumCount,
        lowCount: $lowCount,
        currentPass: $currentPass,
        maxPasses: $maxPasses,
        converged: $converged,
        findingsBySeverity: $findingsBySeverity,
        findingsByType: $findingsByType,
        phaseSummaries: $phaseSummaries,
        failedPhases: $failedPhases,
        readinessScore: $readinessScore,
        readinessAssessment: $readinessStatus,
        readinessMessage: $readinessMessage,
        autoFixableCount: $autoFixableCount,
        manualFixGroups: $manualFixGroups
    }' > "$OUTPUT_FILE"

# Output summary with convergence status
echo "{\"status\":\"complete\",\"phasesReviewed\":$phases_reviewed,\"totalFindings\":$total_findings,\"high\":$high_count,\"medium\":$medium_count,\"low\":$low_count,\"autoFixable\":$auto_fixable_count,\"pass\":$current_pass,\"converged\":$converged,\"readinessStatus\":\"$readiness_status\"}"
