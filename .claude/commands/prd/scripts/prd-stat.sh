#!/bin/bash
# PRD Status Script - Displays current PRD state and phase progress

STATE_FILE="/tmp/.prd_state"
PRD_BASE="$WORKSPACE_DIR/claude_files/PRDs"

# Read state
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
else
    ACTIVE_PRD="none"
    CURRENT_PHASE="none"
fi

# No PRD loaded
if [ "$ACTIVE_PRD" = "none" ] || [ -z "$ACTIVE_PRD" ]; then
    echo "No PRD loaded. Run \`/prd list\` to select one."
    exit 0
fi

PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Verify PRD directory exists
if [ ! -d "$PRD_DIR" ]; then
    echo "Error: PRD directory not found: $PRD_DIR"
    exit 1
fi

# Header
echo "## PRD Status: $ACTIVE_PRD"
echo ""
echo "**Current Phase**: ${CURRENT_PHASE:-none}"
if [ -n "$PHASE_JSON_FILE" ] && [ "$PHASE_JSON_FILE" != "none" ]; then
    echo "**Phase File**: $PHASE_JSON_FILE"
fi
echo ""

# Check for infrastructure.json
INFRA_FILE="$PRD_DIR/infrastructure.json"
if [ -f "$INFRA_FILE" ]; then
    infra_total=$(jq '.tasks | length' "$INFRA_FILE" 2>/dev/null || echo "0")
    infra_complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$INFRA_FILE" 2>/dev/null || echo "0")
    if [ "$infra_total" != "0" ]; then
        echo "**Infrastructure**: $infra_complete/$infra_total tasks complete"
        echo ""
    fi
fi

# Table header
echo "| Phase | Name | Progress |"
echo "|-------|------|----------|"

# Find and process phase files
shopt -s nullglob
phase_files=("$PRD_DIR"/phase_*.json)

if [ ${#phase_files[@]} -eq 0 ]; then
    echo "| - | No phases found | - |"
else
    # Sort phase files numerically by phase number
    mapfile -t sorted_files < <(
        for f in "${phase_files[@]}"; do
            filename=$(basename "$f" .json)
            phase_num=$(echo "$filename" | sed -E 's/phase_([0-9]+).*/\1/')
            printf "%03d %s\n" "$phase_num" "$f"
        done | sort -n | cut -d' ' -f2-
    )

    for f in "${sorted_files[@]}"; do
        filename=$(basename "$f" .json)
        # Extract phase number from filename (e.g., phase_1 -> 1, phase_2_dashboard -> 2)
        phase_num=$(echo "$filename" | sed -E 's/phase_([0-9]+).*/\1/')

        # Get phase name from JSON if available, otherwise from filename
        phase_name=$(jq -r '.phaseName // .name // empty' "$f" 2>/dev/null)
        if [ -z "$phase_name" ]; then
            phase_name=$(echo "$filename" | sed 's/phase_[0-9]*_*//' | tr '_' ' ')
            [ -z "$phase_name" ] && phase_name="Phase $phase_num"
        fi

        # Count tasks
        total=$(jq '.tasks | length' "$f" 2>/dev/null || echo "0")
        complete=$(jq '[.tasks[] | select(.taskStatus == "Complete")] | length' "$f" 2>/dev/null || echo "0")

        # Determine status indicator
        if [ "$complete" -eq "$total" ] && [ "$total" -gt 0 ]; then
            progress="✓ $complete/$total"
        elif [ "$complete" -gt 0 ]; then
            progress="◐ $complete/$total"
        else
            progress="○ $complete/$total"
        fi

        # Mark current phase
        if [ "$CURRENT_PHASE" = "$phase_num" ]; then
            phase_num="* $phase_num"
        fi

        echo "| $phase_num | $phase_name | $progress |"
    done
fi

echo ""

# Show current phase tasks table if a phase is loaded
if [ -n "$PHASE_JSON_FILE" ] && [ "$PHASE_JSON_FILE" != "none" ] && [ -f "$PHASE_JSON_FILE" ]; then
    phase_name=$(jq -r '.phaseName // .name // "Phase"' "$PHASE_JSON_FILE")

    echo "### Current Phase Tasks (Phase $CURRENT_PHASE: $phase_name)"
    echo ""

    # Status summary table
    echo "| Status | Count |"
    echo "|--------|-------|"
    jq -r '[.tasks[].taskStatus] | group_by(.) | map({status: .[0], count: length}) | .[] | "| \(.status) | \(.count) |"' "$PHASE_JSON_FILE"
    echo ""

    # Tasks table
    echo "| ID | Name | Type | Status |"
    echo "|----|------|------|--------|"
    jq -r '.tasks[] | "| \(.taskId) | \(.taskName) | \(.taskType) | \(.taskStatus) |"' "$PHASE_JSON_FILE"
    echo ""
fi

echo "Run \`/prd read <phase>\` to load a phase."
