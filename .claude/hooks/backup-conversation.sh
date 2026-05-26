#!/bin/bash
# PreCompact hook: Backs up conversation transcript before compaction
# Fires regardless of whether compaction succeeds or fails afterward

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

BACKUP_DIR="/tmp/claude-convo-backups"
mkdir -p "$BACKUP_DIR"

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  BACKUP_FILE="$BACKUP_DIR/convo-${TIMESTAMP}-${TRIGGER}.jsonl"

  cp "$TRANSCRIPT_PATH" "$BACKUP_FILE"

  # Keep only last 10 backups
  ls -t "$BACKUP_DIR"/convo-*.jsonl 2>/dev/null | tail -n +11 | xargs -r rm

  echo "Backed up: $BACKUP_FILE" >&2
fi

exit 0
