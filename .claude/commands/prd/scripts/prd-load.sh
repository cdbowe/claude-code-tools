#!/bin/bash
# PRD Load Script - Loads a PRD by search text (requires exactly one match)
# Usage: prd-load.sh <search_text>
#   - Searches PRD directories for names containing search_text (case-insensitive)
#   - If exactly one match: loads it
#   - If multiple matches: lists them (user retries with more specific text)
#   - If no matches: shows error message

set -e

STATE_FILE="/tmp/.prd_state"
SUMMARY_FILE="/tmp/.prd_context_summary"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

SEARCH_TEXT="${1:-}"

if [ -z "$SEARCH_TEXT" ]; then
    echo "Error: search_text required. Usage: /prd load <search_text>"
    exit 1
fi

# Find all PRDs with 00_ROOT.md that match search text
shopt -s nullglob
all_root_files=("$PRD_BASE"/*/00_ROOT.md)

# Filter by search text (case-insensitive)
matching_prds=()
for root_file in "${all_root_files[@]}"; do
    prd_dir=$(dirname "$root_file")
    prd_name=$(basename "$prd_dir")

    if echo "$prd_name" | grep -qi "$SEARCH_TEXT"; then
        matching_prds+=("$prd_name")
    fi
done

#------------------------------------------------------------------------------
# CASE 1: No matches
#------------------------------------------------------------------------------
if [ ${#matching_prds[@]} -eq 0 ]; then
    echo "No PRDs found matching '$SEARCH_TEXT'"
    exit 0
fi

#------------------------------------------------------------------------------
# CASE 2: Multiple matches - list them
#------------------------------------------------------------------------------
if [ ${#matching_prds[@]} -gt 1 ]; then
    echo "Multiple PRDs match '$SEARCH_TEXT':"
    echo ""
    for prd_name in "${matching_prds[@]}"; do
        # Get progress info
        prd_dir="$PRD_BASE/$prd_name"
        total=0
        complete=0
        for phase_file in "$prd_dir"/phase_*.json; do
            [ -f "$phase_file" ] || continue
            phase_total=$(jq '.tasks | length' "$phase_file" 2>/dev/null || echo "0")
            phase_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file" 2>/dev/null || echo "0")
            total=$((total + phase_total))
            complete=$((complete + phase_complete))
        done

        if [ "$total" -gt 0 ]; then
            pct=$((complete * 100 / total))
        else
            pct=0
        fi

        echo "  - $prd_name ($complete/$total tasks, $pct%)"
    done
    echo ""
    echo "Retry with a more specific search term."
    exit 0
fi

#------------------------------------------------------------------------------
# CASE 3: Exactly one match - load it
#------------------------------------------------------------------------------
SELECTED_PRD="${matching_prds[0]}"
PRD_DIR="$PRD_BASE/$SELECTED_PRD"
ROOT_FILE="$PRD_DIR/00_ROOT.md"
INFRA_FILE="$PRD_DIR/01_Infrastructure.md"

# Update state
cat > "$STATE_FILE" << EOF
ACTIVE_PRD=$SELECTED_PRD
CURRENT_PHASE=
PHASE_JSON_FILE=
EOF

# Extract description (first paragraph after ## Overview)
description=$(awk '/^## Overview/,/^## / {if (!/^##/ && NF) {print; exit}}' "$ROOT_FILE" 2>/dev/null || echo "No description")

# Count total progress from phase files
total_tasks=0
complete_tasks=0
shopt -s nullglob
phase_files=("$PRD_DIR"/phase_*.json)

declare -A phase_info
for phase_file in "${phase_files[@]}"; do
    filename=$(basename "$phase_file" .json)
    phase_num=$(echo "$filename" | sed -E 's/phase_([0-9]+).*/\1/')
    phase_name=$(jq -r '.phaseName // .name // empty' "$phase_file" 2>/dev/null)
    [ -z "$phase_name" ] && phase_name=$(echo "$filename" | sed 's/phase_[0-9]*_*//' | tr '_' ' ')

    p_total=$(jq '.tasks | length' "$phase_file" 2>/dev/null || echo "0")
    p_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file" 2>/dev/null || echo "0")

    total_tasks=$((total_tasks + p_total))
    complete_tasks=$((complete_tasks + p_complete))

    # Status emoji
    if [ "$p_complete" -eq "$p_total" ] && [ "$p_total" -gt 0 ]; then
        emoji="✅ Done"
    elif [ "$p_complete" -gt 0 ]; then
        emoji="🛠 In-Progress"
    else
        emoji="Not Started"
    fi

    phase_info["$phase_num"]="$phase_name|$p_complete|$p_total|$emoji|$filename.json"
done

# Check infrastructure
infra_total=0
infra_complete=0
if [ -f "$PRD_DIR/infrastructure.json" ]; then
    infra_total=$(jq '.tasks | length' "$PRD_DIR/infrastructure.json" 2>/dev/null || echo "0")
    infra_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$PRD_DIR/infrastructure.json" 2>/dev/null || echo "0")
elif [ -f "$INFRA_FILE" ]; then
    # Count markdown checklist items
    infra_total=$(grep -c '^\s*- \[' "$INFRA_FILE" 2>/dev/null || echo "0")
    infra_complete=$(grep -c '^\s*- \[x\]' "$INFRA_FILE" 2>/dev/null || echo "0")
fi

# Calculate percentage
if [ "$total_tasks" -gt 0 ]; then
    pct=$((complete_tasks * 100 / total_tasks))
else
    pct=0
fi

# Write context summary
cat > "$SUMMARY_FILE" << EOF
PRD: $SELECTED_PRD
Description: $description
Progress: $complete_tasks/$total_tasks tasks ($pct%)
Infrastructure: $infra_complete/$infra_total tasks

Phases:
EOF

# Sort and add phases to summary
for phase_num in $(echo "${!phase_info[@]}" | tr ' ' '\n' | sort -n); do
    IFS='|' read -r name comp tot emoji file <<< "${phase_info[$phase_num]}"
    echo "- $phase_num. $name ($file) - $comp/$tot" >> "$SUMMARY_FILE"
done

# Output markdown
echo "## $SELECTED_PRD Loaded"
echo ""
echo "**Progress**: $complete_tasks/$total_tasks tasks complete ($pct%)"
echo ""

# Phase table
echo "| Phase | Description | Tasks | Status |"
echo "|-------|-------------|-------|--------|"

# Infrastructure row if exists
if [ "$infra_total" -gt 0 ]; then
    if [ "$infra_complete" -eq "$infra_total" ]; then
        i_status="✅ Done $infra_complete/$infra_total"
    elif [ "$infra_complete" -gt 0 ]; then
        i_status="🛠 In-Progress $infra_complete/$infra_total"
    else
        i_status="Not Started 0/$infra_total"
    fi
    echo "| 0 | Infrastructure Setup | $infra_total | $i_status |"
fi

# Phase rows
for phase_num in $(echo "${!phase_info[@]}" | tr ' ' '\n' | sort -n); do
    IFS='|' read -r name comp tot emoji file <<< "${phase_info[$phase_num]}"
    echo "| $phase_num | $name | $tot | $emoji $comp/$tot |"
done

echo ""
echo "**Next Steps**:"
echo "- \`/prd read <phase>\` to load a phase"
if [ "$infra_complete" -lt "$infra_total" ] && [ "$infra_total" -gt 0 ]; then
    echo "- \`/prd plan-infra\` for infrastructure tasks"
fi
