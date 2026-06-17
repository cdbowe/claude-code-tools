#!/bin/bash
# Runs a command, captures output to a temp file, returns truncated results.
# Usage: run-and-capture.sh '<command>' [tail_lines] [timeout_seconds]
# - On success (exit 0): prints pass summary + log path
# - On failure (exit >0): prints exit code + last N lines of output + log path
# - On timeout: kills the command, reports TIMEOUT with partial output
# - Always exits 0 so the calling agent can read the result without error handling

COMMAND="$1"
TAIL_LINES="${2:-50}"
TIMEOUT_SECS="${3:-120}"

if [ -z "$COMMAND" ]; then
    echo '{"status":"error","error":"No command provided. Usage: run-and-capture.sh '\''<command>'\'' [tail_lines] [timeout_seconds]"}'
    exit 0
fi

LOG_FILE=$(mktemp /tmp/.prd_cmd_output_XXXXXX.log)

timeout --kill-after=10 "$TIMEOUT_SECS" bash -c "$COMMAND" > "$LOG_FILE" 2>&1
EXIT_CODE=$?
TOTAL_LINES=$(wc -l < "$LOG_FILE")

echo "--- COMMAND RESULT ---"
echo "Exit code: $EXIT_CODE"
echo "Output lines: $TOTAL_LINES"
echo "Timeout: ${TIMEOUT_SECS}s"
echo "Log file: $LOG_FILE"

if [ "$EXIT_CODE" -eq 124 ] || [ "$EXIT_CODE" -eq 137 ]; then
    echo "Status: TIMEOUT (killed after ${TIMEOUT_SECS}s)"
    echo "--- LAST $TAIL_LINES LINES (before kill) ---"
    tail -n "$TAIL_LINES" "$LOG_FILE"
elif [ "$EXIT_CODE" -eq 0 ]; then
    echo "Status: PASSED"
    if [ "$TOTAL_LINES" -le 5 ]; then
        echo "--- OUTPUT ---"
        cat "$LOG_FILE"
    fi
else
    echo "Status: FAILED"
    # Check first 10 lines for early errors (setup failures, compile errors, missing deps)
    FIRST_10=$(head -n 10 "$LOG_FILE")
    if echo "$FIRST_10" | grep -iE "(error|exception|failed|cannot|undefined|not found|ENOENT|ERR!)" >/dev/null 2>&1; then
        echo "--- FIRST 10 LINES (error detected early) ---"
        head -n 10 "$LOG_FILE"
        echo ""
    fi
    echo "--- LAST $TAIL_LINES LINES ---"
    tail -n "$TAIL_LINES" "$LOG_FILE"
fi

echo "--- END ---"
exit 0
