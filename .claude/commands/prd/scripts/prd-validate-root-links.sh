#!/bin/bash
# PRD Validate Root Links - Ensures ROOT.md links to all phase JSON files
# Usage: prd-validate-root-links.sh <prd_name>
# Checks that all phase_*.json files are listed in ROOT.md Phase Files table

set -e

PRD_NAME="${1:-}"
if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"

if [ -z "$PRD_NAME" ]; then
    # Try to read from state
    if [ -f /tmp/.prd_state ]; then
        source /tmp/.prd_state
        PRD_NAME="$ACTIVE_PRD"
    fi
fi

if [ -z "$PRD_NAME" ]; then
    echo '{"status":"error","error":"PRD name required"}'
    exit 1
fi

PRD_DIR="$PRD_BASE/$PRD_NAME"
ROOT_FILE="$PRD_DIR/00_ROOT.md"

if [ ! -d "$PRD_DIR" ]; then
    echo "{\"status\":\"error\",\"error\":\"PRD directory not found: $PRD_DIR\"}"
    exit 1
fi

if [ ! -f "$ROOT_FILE" ]; then
    echo "{\"status\":\"error\",\"error\":\"ROOT.md not found: $ROOT_FILE\"}"
    exit 1
fi

#------------------------------------------------------------------------------
# Collect all phase JSON files
#------------------------------------------------------------------------------
phase_files=()
missing_links=()
extra_links=()

for f in "$PRD_DIR"/phase_*.json; do
    [ -f "$f" ] || continue
    filename=$(basename "$f")
    phase_files+=("$filename")

    # Check if this file is referenced in ROOT.md
    if ! grep -q "$filename" "$ROOT_FILE"; then
        missing_links+=("$filename")
    fi
done

#------------------------------------------------------------------------------
# Check for links in ROOT.md that don't have corresponding files
#------------------------------------------------------------------------------
# Extract all phase_*.json references from ROOT.md
linked_files=$(grep -oE 'phase_[0-9]+_[a-z_]+\.json' "$ROOT_FILE" 2>/dev/null | sort -u)

for linked in $linked_files; do
    if [ ! -f "$PRD_DIR/$linked" ]; then
        extra_links+=("$linked")
    fi
done

#------------------------------------------------------------------------------
# Report results
#------------------------------------------------------------------------------
total_phases=${#phase_files[@]}
missing_count=${#missing_links[@]}
extra_count=${#extra_links[@]}

if [ "$missing_count" -gt 0 ] || [ "$extra_count" -gt 0 ]; then
    echo "❌ ROOT.md LINK VALIDATION FAILED"
    echo ""

    if [ "$missing_count" -gt 0 ]; then
        echo "Missing from ROOT.md Phase Files table:"
        for f in "${missing_links[@]}"; do
            echo "  - $f"
        done
        echo ""
    fi

    if [ "$extra_count" -gt 0 ]; then
        echo "Referenced in ROOT.md but file not found:"
        for f in "${extra_links[@]}"; do
            echo "  - $f"
        done
        echo ""
    fi

    echo "To fix: Update the Phase Files table in 00_ROOT.md"
    exit 1
else
    echo "✅ ROOT.md links validated: $total_phases phase files correctly linked"
    exit 0
fi
