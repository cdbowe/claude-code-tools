#!/bin/bash
# PRD List Script - Finds PRDs and outputs selection JSON or loads selected PRD
# Usage: prd-list.sh [search_text|selected_prd]
#   - No args: list all PRDs for selection
#   - search_text: filter PRDs by name containing search_text (case-insensitive)
#   - selected_prd: load the specified PRD (exact match of directory name)

set -e

STATE_FILE="/tmp/.prd_state"
OUTPUT_FILE="/tmp/.prd_list.json"
SUMMARY_FILE="/tmp/.prd_context_summary"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

ARG="${1:-}"
SEARCH_TEXT=""
SELECTED_PRD=""

# Clean stale output
rm -f "$OUTPUT_FILE"

# Determine if arg is a search filter or exact PRD selection
if [ -n "$ARG" ]; then
    if [ -d "$PRD_BASE/$ARG" ]; then
        # Exact match - treat as selection
        SELECTED_PRD="$ARG"
    else
        # Not exact match - treat as search filter
        SEARCH_TEXT="$ARG"
    fi
fi

#------------------------------------------------------------------------------
# CASE 1: No selection (or search filter) → output selection JSON
#------------------------------------------------------------------------------
if [ -z "$SELECTED_PRD" ]; then
    # Find all PRDs with 00_ROOT.md
    shopt -s nullglob
    all_root_files=("$PRD_BASE"/*/00_ROOT.md)

    # Filter by search text if provided
    root_files=()
    for root_file in "${all_root_files[@]}"; do
        prd_dir=$(dirname "$root_file")
        prd_name=$(basename "$prd_dir")

        if [ -n "$SEARCH_TEXT" ]; then
            # Case-insensitive match
            if echo "$prd_name" | grep -qi "$SEARCH_TEXT"; then
                root_files+=("$root_file")
            fi
        else
            root_files+=("$root_file")
        fi
    done

    if [ ${#root_files[@]} -eq 0 ]; then
        if [ -n "$SEARCH_TEXT" ]; then
            echo "No PRDs found matching '$SEARCH_TEXT'"
        else
            echo "No PRDs found in $PRD_BASE"
        fi
        exit 0
    fi

    # If exactly one match with search filter, auto-select it
    if [ -n "$SEARCH_TEXT" ] && [ ${#root_files[@]} -eq 1 ]; then
        prd_dir=$(dirname "${root_files[0]}")
        SELECTED_PRD=$(basename "$prd_dir")
        # Fall through to CASE 2 (selection handling)
    fi
fi

#------------------------------------------------------------------------------
# CASE 1 continued: Multiple matches → output selection JSON
#------------------------------------------------------------------------------
if [ -z "$SELECTED_PRD" ]; then

    # Build options array
    options="[]"
    for root_file in "${root_files[@]}"; do
        prd_dir=$(dirname "$root_file")
        prd_name=$(basename "$prd_dir")

        # Extract progress from ROOT.md (look for "**Tasks**: X/Y" pattern)
        progress_line=$(grep -E '\*\*Tasks\*\*:|Tasks:' "$root_file" 2>/dev/null | head -1 || echo "")
        if [[ "$progress_line" =~ ([0-9]+)/([0-9]+) ]]; then
            complete="${BASH_REMATCH[1]}"
            total="${BASH_REMATCH[2]}"
            if [ "$total" -gt 0 ]; then
                pct=$((complete * 100 / total))
            else
                pct=0
            fi
        else
            # Fallback: count tasks from phase JSON files
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
        fi

        # Determine status
        if [ "$pct" -eq 100 ] && [ "$total" -gt 0 ]; then
            status="Complete"
        elif [ "$pct" -gt 0 ]; then
            status="In Progress"
        else
            status="Not Started"
        fi

        # Add to options (format for AskUserQuestion)
        option=$(jq -n \
            --arg lbl "$prd_name" \
            --arg dsc "$complete/$total tasks ($pct%) - $status" \
            '{("label"): $lbl, ("description"): $dsc}')
        options=$(echo "$options" | jq --argjson opt "$option" '. + [$opt]')
    done

    # Sort: incomplete first, then by percentage ascending
    options=$(echo "$options" | jq 'sort_by(.description | capture("(?<pct>[0-9]+)%") | .pct | tonumber)')

    # Write selection JSON
    jq -n --argjson opts "$options" '{
        status: "awaiting_selection",
        selectionType: "prd",
        question: "Which PRD would you like to work on?",
        header: "PRD",
        multiSelect: false,
        options: $opts
    }' | tee "$OUTPUT_FILE"

    exit 0
fi

#------------------------------------------------------------------------------
# CASE 2: Selection provided → load PRD and output markdown
#------------------------------------------------------------------------------
PRD_DIR="$PRD_BASE/$SELECTED_PRD"
ROOT_FILE="$PRD_DIR/00_ROOT.md"
INFRA_FILE="$PRD_DIR/01_Infrastructure.md"

if [ ! -d "$PRD_DIR" ]; then
    echo "Error: PRD directory not found: $PRD_DIR"
    exit 1
fi

if [ ! -f "$ROOT_FILE" ]; then
    echo "Error: ROOT file not found: $ROOT_FILE"
    exit 1
fi

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
