#!/bin/bash
# PRD Summarize Script - Extracts phase data for LLM summarization
# Usage: prd-summarize.sh [phase_num]

set -e

STATE_FILE="/tmp/.prd_state"
OUTPUT_FILE="/tmp/.prd_summarize.json"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

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

# If no phase arg, use current phase from state
if [ -z "$PHASE_NUM" ]; then
    if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "none" ]; then
        echo "No phase loaded. Run \`/prd read <phase>\` first."
        exit 1
    fi
    PHASE_NUM="$CURRENT_PHASE"
fi

# Clean stale output
rm -f "$OUTPUT_FILE"

# Resolve phase file
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

# Validate JSON
if ! jq -e '.' "$phase_file" > /dev/null 2>&1; then
    echo "Error: Phase file is not valid JSON: $phase_file"
    exit 1
fi

# Validate required fields
if ! jq -e '.tasks' "$phase_file" > /dev/null 2>&1; then
    echo "Error: Phase file missing required 'tasks' array: $phase_file"
    exit 1
fi

# Extract minimal payload for summarization
jq '{
  status: "ok",
  prd: $prd,
  phaseId: .phaseId,
  phaseName: (.phaseName // .name // "Phase"),
  phaseDescription: (.description // .phaseDescription // ""),
  tasks: [.tasks[] | {
    taskId,
    taskName,
    taskType,
    taskStatus: (.taskStatus // "Unknown"),
    description: (.description // "")
  }]
}' --arg prd "$ACTIVE_PRD" "$phase_file" > "$OUTPUT_FILE"

echo "ok"
