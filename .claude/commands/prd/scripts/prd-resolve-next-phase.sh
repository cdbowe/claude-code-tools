#!/bin/bash
# Resolves the next phase number for /prd build --next
# Output: JSON with status and phase info

set -e

STATE_FILE="/tmp/.prd_state"
PRD_BASE="$WORKSPACE_DIR/claude_files/PRDs"

# Check state file exists
if [ ! -f "$STATE_FILE" ]; then
  echo '{"status":"error","error":"No PRD loaded. Run `/prd list` first."}'
  exit 0
fi

# Read state (same pattern as other prd scripts)
source "$STATE_FILE"

# Check PRD is loaded
if [ -z "$ACTIVE_PRD" ] || [ "$ACTIVE_PRD" = "none" ]; then
  echo '{"status":"error","error":"No PRD loaded. Run `/prd list` first."}'
  exit 0
fi

# Construct PRD_DIR from ACTIVE_PRD (same pattern as prd-read.sh)
PRD_DIR="$PRD_BASE/$ACTIVE_PRD"

# Find all phase files and extract final phase number
shopt -s nullglob
phase_files=("$PRD_DIR"/phase_*.json)

if [ ${#phase_files[@]} -eq 0 ]; then
  echo '{"status":"error","error":"No phase files found in PRD directory."}'
  exit 0
fi

# Sort and get final phase number
PHASE_FILES=$(ls "$PRD_DIR"/phase_*.json 2>/dev/null | sort -V)
FINAL_PHASE=$(echo "$PHASE_FILES" | tail -1 | grep -oP 'phase_\K[0-9]+')

# Calculate target phase
# CURRENT_PHASE may be empty string (from gen) or unset (never loaded a phase)
if [ -z "$CURRENT_PHASE" ]; then
  TARGET_PHASE=0
else
  TARGET_PHASE=$((CURRENT_PHASE + 1))
fi

# Validate target phase
if [ "$TARGET_PHASE" -gt "$FINAL_PHASE" ]; then
  echo '{"status":"complete","targetPhase":'$TARGET_PHASE',"finalPhase":'$FINAL_PHASE',"message":"PRD complete — all phases finished."}'
  exit 0
fi

# Check if target phase file exists (handle both phase_N_name.json and phase_N.json patterns)
TARGET_FILE=""
for f in "$PRD_DIR"/phase_"$TARGET_PHASE"_*.json "$PRD_DIR"/phase_"$TARGET_PHASE".json; do
  if [ -f "$f" ]; then
    TARGET_FILE="$f"
    break
  fi
done

if [ -n "$TARGET_FILE" ]; then
  echo '{"status":"success","targetPhase":'$TARGET_PHASE',"finalPhase":'$FINAL_PHASE'}'
else
  echo '{"status":"corrupted","targetPhase":'$TARGET_PHASE',"finalPhase":'$FINAL_PHASE',"error":"Phase '$TARGET_PHASE' not found but is within range (0-'$FINAL_PHASE'). Phase files may be corrupted."}'
fi
