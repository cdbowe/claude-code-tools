#!/bin/bash
# PRD Read Script - Lists phases or loads specific phase
# Usage: prd-read.sh [phase_num]

set -e

STATE_FILE="/tmp/.prd_state"
OUTPUT_FILE="/tmp/.prd_read.json"
PRD_BASE="${WORKSPACE_DIR:-/workspaces/bankjet}/claude_files/PRDs"

PHASE_NUM="${1:-}"

# Read state
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
else
    echo "No PRD loaded. Run \`/prd list\` first."
    exit 1
fi

if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
    echo "No PRD loaded. Run \`/prd list\` first."
    exit 1
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Clean stale output
rm -f "$OUTPUT_FILE"

#------------------------------------------------------------------------------
# CASE 1: No phase number → output selection JSON
#------------------------------------------------------------------------------
if [ -z "$PHASE_NUM" ]; then
    # Find all phase JSON files
    shopt -s nullglob
    phase_files=("$PRD_DIR"/phase_*.json)

    if [ ${#phase_files[@]} -eq 0 ]; then
        echo "No phase files found in $PRD_DIR"
        exit 1
    fi

    # Build options array
    options="[]"
    for phase_file in "${phase_files[@]}"; do
        filename=$(basename "$phase_file" .json)
        phase_num=$(echo "$filename" | sed -E 's/phase_([0-9]+).*/\1/')

        phase_name=$(jq -r '.phaseName // .name // empty' "$phase_file" 2>/dev/null)
        [ -z "$phase_name" ] && phase_name=$(echo "$filename" | sed 's/phase_[0-9]*_*//' | tr '_' ' ')

        p_total=$(jq '.tasks | length' "$phase_file" 2>/dev/null || echo "0")
        p_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file" 2>/dev/null || echo "0")

        if [ "$p_total" -gt 0 ]; then
            pct=$((p_complete * 100 / p_total))
        else
            pct=0
        fi

        # Status
        if [ "$pct" -eq 100 ] && [ "$p_total" -gt 0 ]; then
            status="Complete"
        elif [ "$pct" -gt 0 ]; then
            status="In Progress"
        else
            status="Pending"
        fi

        label="Phase $phase_num: $phase_name"
        desc="$p_complete/$p_total tasks ($pct%) - $status"

        option=$(jq -n --arg label "$label" --arg desc "$desc" --arg num "$phase_num" \
            '{label: $label, description: $desc, value: $num}')
        options=$(echo "$options" | jq --argjson opt "$option" '. + [$opt]')
    done

    # Sort by phase number
    options=$(echo "$options" | jq 'sort_by(.value | tonumber)')

    # Write selection JSON
    jq -n --argjson opts "$options" '{
        status: "awaiting_selection",
        selectionType: "phase",
        question: "Which phase would you like to load?",
        header: "Phase",
        multiSelect: false,
        options: $opts
    }' > "$OUTPUT_FILE"

    exit 0
fi

#------------------------------------------------------------------------------
# CASE 2: Phase number provided → load phase and output markdown
#------------------------------------------------------------------------------

# Find phase file - use underscore after number to avoid phase_1 matching phase_10/11
phase_file=""
for f in "$PRD_DIR"/phase_"$PHASE_NUM"_*.json "$PRD_DIR"/phase_"$PHASE_NUM".json; do
    if [ -f "$f" ]; then
        phase_file="$f"
        break
    fi
done

if [ -z "$phase_file" ] || [ ! -f "$phase_file" ]; then
    echo "Error: Phase $PHASE_NUM not found in $ACTIVE_PRD"
    echo ""
    echo "Available phases:"
    for f in "$PRD_DIR"/phase_*.json; do
        [ -f "$f" ] || continue
        num=$(basename "$f" .json | sed -E 's/phase_([0-9]+).*/\1/')
        name=$(jq -r '.phaseName // .name // empty' "$f" 2>/dev/null)
        echo "  - Phase $num: $name"
    done
    exit 1
fi

# Update state
cat > "$STATE_FILE" << EOF
ACTIVE_PRD=$ACTIVE_PRD
CURRENT_PHASE=$PHASE_NUM
PHASE_JSON_FILE=$phase_file
EOF

# Read phase data
phase_name=$(jq -r '.phaseName // .name // "Phase"' "$phase_file")
phase_desc=$(jq -r '.phaseDescription // .description // ""' "$phase_file")

# Count tasks by status
total=$(jq '.tasks | length' "$phase_file")
complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$phase_file")
pending=$(jq '[.tasks[] | select(.taskStatus == "Pending")] | length' "$phase_file")
inprogress=$(jq '[.tasks[] | select(.taskStatus == "InProgress")] | length' "$phase_file")
blocked=$(jq '[.tasks[] | select(.taskStatus == "Blocked")] | length' "$phase_file")
needs_clarification=$(jq '[.tasks[] | select(.taskStatus == "NeedsClarification")] | length' "$phase_file")
skipped=$(jq '[.tasks[] | select(.taskStatus == "Skipped")] | length' "$phase_file")

if [ "$total" -gt 0 ]; then
    pct=$((complete * 100 / total))
else
    pct=0
fi

# Output markdown
echo "## Phase $PHASE_NUM: $phase_name"
echo ""
if [ -n "$phase_desc" ]; then
    echo "**Description**: $phase_desc"
    echo ""
fi
echo "**Progress**: $complete/$total tasks complete ($pct%)"
echo ""

# Status breakdown table
echo "| Status | Count |"
echo "|--------|-------|"
[ "$complete" -gt 0 ] && echo "| Complete | $complete |"
[ "$pending" -gt 0 ] && echo "| Pending | $pending |"
[ "$inprogress" -gt 0 ] && echo "| InProgress | $inprogress |"
[ "$blocked" -gt 0 ] && echo "| Blocked | $blocked |"
[ "$needs_clarification" -gt 0 ] && echo "| NeedsClarification | $needs_clarification |"
[ "$skipped" -gt 0 ] && echo "| Skipped | $skipped |"
echo ""

# Tasks table
echo "### Tasks"
echo ""
echo "| ID | Name | Type | Status |"
echo "|----|------|------|--------|"

# Extract and display tasks
jq -r '.tasks[] | "| \(.taskId) | \(.taskName) | \(.taskType) | \(.taskStatus) |"' "$phase_file"

echo ""
echo "**Next Steps**:"
echo "- \`/prd plan\` to generate execution plan"
