#!/bin/bash

# ============================================================================
# Claude Code Status Line Script
# ============================================================================

# CONFIGURATION
# ----------------------------------------------------------------------------

# Timezone (e.g., "America/New_York", "Europe/London", "Asia/Tokyo", "UTC")
TIMEZONE="America/New_York"

# Time format: "12h" or "24h"
TIME_FORMAT="12h"

# JSON output directory (comment out this line to disable logging)
# When enabled (i.e. not commented out or set to empty string), this will log 
# the complete JSON input payload to a new file. 
# NOTE: This will log a new file every time the script is called (i.e. every time the status line updates).
# JSON_OUTPUT_DIR="$HOME/.claude-code-status-logs"

# Persistent session state file (stores reset time shared across all instances)
# All Claude Code instances pointing to the same subscription share this reset time.
# This file will regularly be cleared and overwritten, no extra files created.
SESSION_STATE_FILE="$HOME/.claude/claude-code-session-state"

# Session time window size in seconds (how long a session lasts before reset)
# The current time is always inside this window, so session start can never be older than this
# Default: 5 hours = 18000 seconds
SESSION_TIME_WINDOW_SIZE=18000

# System overhead tokens (approximate) AKA Context Size Offset
# The status line JSON only includes conversational message tokens in current_usage.
# It does NOT include: system prompt or memory files.
# Add an estimated overhead here to match the /context command's total.
# Check /context output to calibrate this value for your setup.
SYSTEM_OVERHEAD=0 # 11000

# Enable OAuth API usage fetching (true/false)
# Set to false to disable actual usage API calls (e.g., if rate limited)
ENABLE_OAUTH_API=true

# ANSI Color Codes (configure as needed)
# Use format: "\033[XXm" where XX is the color code
# Common codes: 31=red, 32=green, 33=yellow, 34=blue, 35=magenta, 36=cyan, 37=white
# Comprehensive color code list: https://gist.github.com/JBlond/2fea43a3049b38287e5e9cefc87b2124
COLOR_MODEL="\033[36m"        # Cyan
COLOR_FOLDER="\033[33m"       # Yellow
COLOR_CONTEXT_PCT="\033[35m"  # Magenta
COLOR_CONTEXT_SIZE="\033[35m" # Magenta
COLOR_COST="\033[32m"         # Green
COLOR_RESET="\033[0m"         # Reset color
COLOR_TRANSCRIPT="\033[38;5;239m"   # Grey
COLOR_RED="\033[31m"    # Red (for API failure indicator)

# Progress bar characters (Unicode blocks for better visual appearance)
PROGRESS_FILLED="█"           # U+2588 - Full block
PROGRESS_EMPTY="░"            # U+2591 - Light shade

# Path to estimated usage script file (passed in from statusline command)
USAGE_SCRIPT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --usage-script)
            if [ -z "$2" ]; then
                echo "Error: --usage-script requires a value" >&2
                exit 1
            fi
            usage_script_file_input="$2"
            if [ ! -f "$usage_script_file_input" ]; then
                echo "Error: usage script file not found: $usage_script_file_input"
                exit 1
            fi
            USAGE_SCRIPT="$usage_script_file_input"
            shift 2
            ;;
        --help)
            echo "Usage: $0 --usage-script <path> [other options]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

[ ! -z "$USAGE_SCRIPT" ] && HAS_USAGE_SCRIPT="true" || HAS_USAGE_SCRIPT="false"

# ============================================================================
# SCRIPT LOGIC
# ============================================================================

# Migration: Remove old state file if it exists (renamed to SESSION_STATE_FILE)
OLD_RESET_TIME_FILE="$HOME/.claude_code_reset_time"
if [ -f "$OLD_RESET_TIME_FILE" ]; then
    rm -f "$OLD_RESET_TIME_FILE" 2>/dev/null
fi

# Read JSON from stdin
JSON_INPUT=$(cat)

# Log JSON to file if output directory is configured
if [ -n "${JSON_OUTPUT_DIR+x}" ] && [ -n "$JSON_OUTPUT_DIR" ]; then
    mkdir -p "$JSON_OUTPUT_DIR" 2>/dev/null
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S_%N")
    echo "$JSON_INPUT" > "$JSON_OUTPUT_DIR/status_${TIMESTAMP}.json" 2>/dev/null
fi

# Parse JSON fields (shared across all functions)
MODEL=$(echo "$JSON_INPUT" | jq -r '.model.display_name // "unknown"')
TRANSCRIPT_PATH=$(echo "$JSON_INPUT" | jq -r '.transcript_path // "unknown"')
SESSION_ID=$(echo "$JSON_INPUT" | jq -r '.session_id // "unknown"')
CURRENT_DIR=$(echo "$JSON_INPUT" | jq -r '.workspace.current_dir // "unknown"')
CONTEXT_WINDOW=$(echo "$JSON_INPUT" | jq -r '.context_window // 0')
CONTEXT_LIMIT=$(echo "$JSON_INPUT" | jq -r '.context_window.context_window_size // 0')
USAGE=$(echo "$JSON_INPUT" | jq '.context_window.current_usage')
CONTEXT_EXCEEDS_200K=$(echo "$JSON_INPUT" | jq -r '.exceeds_200k_tokens // false')
TOTAL_COST_USD=$(echo "$JSON_INPUT" | jq -r '.cost.total_cost_usd // 0')
ELAPSED_DURATION_MS=$(echo "$JSON_INPUT" | jq -r '.cost.total_duration_ms // 0')
API_DURATION_MS=$(echo "$JSON_INPUT" | jq -r '.cost.total_api_duration_ms // 0')
CONTEXT_USED_PCT=$(echo "$JSON_INPUT" | jq -r '.context_window.used_percentage // 0')

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Function: check if usage script was passed
has_usage_script() {
    # echo "HAS_USAGE_SCRIPT: $HAS_USAGE_SCRIPT"
    if [ "$HAS_USAGE_SCRIPT" = "true" ]; then
        # echo "True"
        return 0;
    else
        # echo "False"
        return 1;
    fi
}

# Function: Build a 10-character progress bar
# Usage: build_progress_bar <filled_count>
# Args: filled_count - number of filled chars (0-10, values >10 are capped)
# Note: Uses loop instead of substring expansion to handle multi-byte UTF-8 chars
build_progress_bar() {
    # echo "build_progress_bar $1"
    local filled=$1
    local max=${2:-10}
    # Cap at 0-max range
    if [ "$filled" -gt $max ]; then filled=$max; fi
    if [ "$filled" -lt 0 ]; then filled=0; fi
    local empty=$(($max - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="$PROGRESS_FILLED"; done
    for ((i=0; i<empty; i++)); do bar+="$PROGRESS_EMPTY"; done
    echo "$bar"
}


# Function: Calculate reset time from a session start epoch
calculate_reset_time() {
    local session_start_epoch=$1
    local reset_time=$((session_start_epoch + SESSION_TIME_WINDOW_SIZE))
    echo $reset_time
}

# Function: Parse ISO timestamp to epoch (handles both GNU date and BSD date)
parse_iso_to_epoch() {
    local iso_timestamp=$1
    local epoch=""

    # Try GNU date first (Linux)
    epoch=$(date -d "$iso_timestamp" +%s 2>/dev/null)

    # If GNU date failed, try BSD date (macOS)
    if [ -z "$epoch" ] || [ "$epoch" = "" ]; then
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_timestamp:0:19}" +%s 2>/dev/null)
    fi

    # Validate result is a positive number
    if [ -n "$epoch" ] && [ "$epoch" -gt 0 ] 2>/dev/null; then
        echo "$epoch"
    else
        echo ""
    fi
}

# Function: Find the first timestamp in transcript that is >= min_epoch
# This finds the start of the current session window
get_session_start_from_transcript() {
    local transcript_path=$1
    local min_epoch=$2

    # Check if transcript exists and is readable
    if [ ! -f "$transcript_path" ] || [ ! -r "$transcript_path" ]; then
        echo ""
        return
    fi

    # Find first timestamp >= min_epoch using jq
    local first_valid_ts
    first_valid_ts=$(jq -r --arg min_epoch "$min_epoch" '
        select(.timestamp != null) |
        .timestamp as $ts |
        ($ts | sub("\\.[0-9]+"; "") | fromdateiso8601) as $epoch |
        select($epoch >= ($min_epoch | tonumber)) |
        $ts
    ' < "$transcript_path" 2>/dev/null | head -1)

    if [ -n "$first_valid_ts" ] && [ "$first_valid_ts" != "null" ]; then
        echo "$first_valid_ts"
    fi
}

# Function: Load stored reset time from shared state file
# All Claude Code instances read from the same file
load_stored_reset_time() {
    if [ -f "$SESSION_STATE_FILE" ]; then
        cat "$SESSION_STATE_FILE" 2>/dev/null
    fi
}

# Function: Save reset time to shared state file
# When any instance calculates a reset time, it propagates to all other instances
save_reset_time() {
    local reset_time=$1
    echo "$reset_time" > "$SESSION_STATE_FILE"
}

# ============================================================================
# STATUS LINE ELEMENT FUNCTIONS
# ============================================================================

# Function: Get model display name
get_model_element() {
    echo -e "${COLOR_MODEL}${MODEL}${COLOR_RESET}"
}

# Function: Get current directory
get_directory_element() {
    echo -e "${COLOR_FOLDER}📂 ${CURRENT_DIR}${COLOR_RESET}"
}

# Function: Get context window size and percentage with progress bar
get_context_element() {
    # Valid values: "default", "debug"
    local display_mode="${1:-}"

    # Calculate current context window usage using Anthropic's method plus output tokens
    if [ "$USAGE" != "null" ]; then
        USAGE_TOKENS=$(echo "$USAGE" | jq '.input_tokens + .output_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
    else
        USAGE_TOKENS=0
    fi
    # Add system overhead to match /context command
    CURRENT_TOKENS=$((USAGE_TOKENS + SYSTEM_OVERHEAD))

    # Debug: read the tokens in individually
    read -r input_tokens output_tokens cache_write_tokens cache_read_tokens < <(echo "$USAGE" | jq -r '
        [ 
            .input_tokens // 0,
            .output_tokens // 0,
            .cache_creation_input_tokens // 0,
            .cache_read_input_tokens // 0 
        ] | join(" ")')

    # Format context window size display
    CONTEXT_LIMIT_K=$((CONTEXT_LIMIT / 1000))
    if [ "$CURRENT_TOKENS" -lt 1000 ]; then
        CURRENT_DISPLAY="$CURRENT_TOKENS"
    else
        CURRENT_DISPLAY="$((CURRENT_TOKENS / 1000))K"
    fi

    # Add star "**" characters if the session indicates it's gone above 200K
    if [ "$CONTEXT_EXCEEDS_200K" = "true" ]; then
        CURRENT_DISPLAY="${CURRENT_DISPLAY}**"
    fi

    # Calculate context window percentage with 1 decimal place
    if [ "$CONTEXT_LIMIT" -gt 0 ]; then
        CONTEXT_PCT=$(echo "scale=1; $CURRENT_TOKENS * 100 / $CONTEXT_LIMIT" | bc)
    else
        CONTEXT_PCT="0.0"
    fi

    # Build progress bar (10 characters, each representing 10%)
    FILLED_CHARS=$(echo "$CONTEXT_PCT / 10" | bc)
    PROGRESS_BAR=$(build_progress_bar "$FILLED_CHARS")

    # Display debug line
    if [ "$display_mode" = "debug" ]; then
        echo -e "${COLOR_CONTEXT_SIZE}${CURRENT_DISPLAY}/${CONTEXT_LIMIT_K}K | ${CONTEXT_PCT}% [${PROGRESS_BAR}] (${CONTEXT_USED_PCT}% | ${input_tokens} ${output_tokens} ${cache_write_tokens} ${cache_read_tokens}) ${COLOR_RESET}"
        return
    fi

    # Display default line
    echo -e "${COLOR_CONTEXT_SIZE}${CURRENT_DISPLAY}/${CONTEXT_LIMIT_K}K | ${CONTEXT_PCT}% [${PROGRESS_BAR}] (${CONTEXT_USED_PCT}%) ${COLOR_RESET}"
}

# Function: call the passed usage script (if provided)
get_est_usage_element() {
    if ! has_usage_script; then
        return
    fi

    # Call the script to estimate current usage
    # Output format: est_pct total_credits session_limit api_cost actual_pct est_usage_diff seconds_remaining
    # seconds_remaining: -2 = no actual usage, -1 = fresh API call, >= 0 = cached (seconds until expiry)
    local usage_script_args="--statusline"
    if [ "$ENABLE_OAUTH_API" = true ]; then
        usage_script_args="$usage_script_args --enable-oauth-api"
    fi
    read -r est_usage_pct est_total_credits est_session_limit est_api_cost actual_usage_pct est_usage_diff seconds_remaining < \
        <(bash "$USAGE_SCRIPT" $usage_script_args)

    # Build progress bar (10 characters, each representing 10%)
    local filled_usage_chars=$(echo "$est_usage_pct / 10" | bc)
    local usage_progress_bar=$(build_progress_bar "$filled_usage_chars")

    # Format actual usage percentage and build progress bar
    # seconds_remaining: -3 = API call failed, -2 = no actual usage, -1 = fresh API call, >= 0 = cached (seconds until expiry)
    local actual_pct_value="0.0"
    local actual_pct_display="0.0%"
    local actual_indicator=""

    if [ "$ENABLE_OAUTH_API" = false ]; then
        # OAuth API disabled - show [OFF]
        actual_indicator=" ${COLOR_RED}[OFF]${COLOR_RESET}"
    elif [ "$seconds_remaining" = "-3" ]; then
        # API call failed - show red [!]
        actual_indicator=" ${COLOR_RED}[!]${COLOR_RESET}"
        if [ -n "$actual_usage_pct" ] && [ "$actual_usage_pct" != "-" ]; then
            actual_pct_value="$actual_usage_pct"
            actual_pct_display="$actual_usage_pct%"
        fi
    elif [ -n "$actual_usage_pct" ] && [ "$actual_usage_pct" != "-" ]; then
        actual_pct_value="$actual_usage_pct"
        actual_pct_display="$actual_usage_pct%"
    fi

    # Build progress bar for actual usage (10 characters, each representing 10%)
    local filled_actual_chars=$(echo "$actual_pct_value / 10" | bc)
    local actual_progress_bar=$(build_progress_bar "$filled_actual_chars")

    # Format the diff
    local diff_display=""
    if [ -n "$est_usage_diff" ] && [ "$est_usage_diff" != "-" ]; then
        if (( $(echo "$est_usage_diff >= 0" | bc -l) )); then
            diff_display=" (+${est_usage_diff}%)"
        else
            diff_display=" (${est_usage_diff}%)"
        fi
    fi

    # Show seconds remaining OR updated indicator (mutually exclusive)
    local seconds_remaining_display=""
    if [ "$seconds_remaining" = "-1" ]; then
        # Fresh API call - show **UPDATED** instead of cache time
        # seconds_remaining_display=" **UPDATED**"
        actual_pct_display="**UPDATE** $actual_pct_display"
    elif [ "$seconds_remaining" -ge 0 ] 2>/dev/null; then
        # Cached - show seconds remaining
        if [ "$seconds_remaining" -ge 60 ]; then
            local minutes_remaining=$(echo "$seconds_remaining / 60" | bc)
            local seconds_remainder=$(echo "$seconds_remaining % 60" | bc)

            seconds_remaining_display=" [${minutes_remaining}m ${seconds_remainder}s]"
        else
            seconds_remaining_display=" [${seconds_remaining}s]"
        fi
    fi

    # Output ESTIMATED USAGE line
    printf "ESTIMATED USAGE: %17s [%s] (\$%s)\n" "${est_usage_pct}%" "${usage_progress_bar}" "${est_api_cost}"

    # Output ACTUAL USAGE line (aligned with estimated - "ACTUAL USAGE: " is 3 chars shorter, so use %20s instead of %17s)
    # KEEP for now: printf "ACTUAL USAGE: %20s [%s]%b%b%b\n" "${actual_pct_display}%" "${actual_progress_bar}" "${actual_indicator}" "${diff_display}" "${seconds_remaining_display}"
    printf "ACTUAL USAGE: %20s [%s]%b%b%b\n" "${actual_pct_display}" "${actual_progress_bar}" "${actual_indicator}" "${diff_display}" "${seconds_remaining_display}"
}

# Function: Format cost as USD currency
get_cost_element() {
    # Format the cost with 2 decimal places and prepend dollar sign
    COST_FORMATTED=$(printf "%.2f" "$TOTAL_COST_USD")

    # Convert milliseconds to total seconds
    local total_seconds=$((ELAPSED_DURATION_MS / 1000))

    # Calculate elapsed time components
    local elapsed_days=$((total_seconds / 86400))
    local remaining=$((total_seconds % 86400)) # remaining total seconds after X days
    local elapsed_hours=$((remaining / 3600))

    remaining=$((remaining % 3600))  # remaining total seconds after X hours
    local elapsed_mins=$((remaining / 60)) # convert remaining seconds into minutes and final remaining seconds

    # Format the time elapsed
    local duration_time_formatted;
    if [ "$elapsed_days" -gt 0 ]; then
        duration_time_formatted="${elapsed_days}d ${elapsed_hours}h"
    elif [ "$elapsed_hours" -gt 0 ]; then
        duration_time_formatted="${elapsed_hours}h ${elapsed_mins}m"
    else
        duration_time_formatted="${elapsed_mins}m"
    fi

    # Calculate API time components
    local total_api_seconds=$((API_DURATION_MS / 1000))
    local api_days=$((total_api_seconds / 86400))
    local remaining=$((total_api_seconds % 86400)) # remaining total seconds after X days
    local api_hours=$((remaining / 3600))
    
    remaining=$((remaining % 3600))  # remaining total seconds after X hours
    local api_mins=$((remaining / 60)) # convert remaining seconds into minutes and final remaining seconds

    # Format the API time
    local api_time_formatted;
    if [ "$api_days" -gt 0 ]; then
        api_time_formatted="${api_days}d ${api_hours}h"
    elif [ "$api_hours" -gt 0 ]; then
        api_time_formatted="${api_hours}h ${api_mins}m"
    else
        api_time_formatted="${api_mins}m"
    fi

    # Format cost per hour (API)
    local duration_hours=$(echo "scale=2; ($API_DURATION_MS / (1000 * 60 * 60))" | bc)
    # local cost_per_hour=$(echo "scale=2; $TOTAL_COST_USD / $duration_hours" | bc)
    # local cost_per_hour_fmt=$(printf "%.2f" "$cost_per_hour")

    printf "${COLOR_COST}Cost: 💰 \$${COST_FORMATTED} | ⌚ API: ${api_time_formatted} | ⌚ Elapsed: ${duration_time_formatted} ${COLOR_RESET}\n"
    # printf "${COLOR_COST}Cost: 💰 \$${COST_FORMATTED} ${COLOR_RESET}\n"
    # printf "${COLOR_COST}${TOTAL_COST_USD} | ${API_DURATION_MS} | ${ELAPSED_DURATION_MS} ${elapsed_days} ${elapsed_hours} ${elapsed_mins} ${COLOR_RESET}\n"
}

# Function: Get session reset time with progress bar
get_reset_time_element() {
    CURRENT_TIME=$(date +%s)
    SESSION_START_EPOCH=""
    RESET_TIME=""

    # Key insight: The current time is ALWAYS inside a session window of SESSION_TIME_WINDOW_SIZE.
    # Therefore, the session start can NEVER be older than (CURRENT_TIME - SESSION_TIME_WINDOW_SIZE).
    EARLIEST_VALID_SESSION_START=$((CURRENT_TIME - SESSION_TIME_WINDOW_SIZE))

    # Check if we have a valid cached reset time shared across all instances
    STORED_RESET_TIME=$(load_stored_reset_time)

    if [ -n "$STORED_RESET_TIME" ] && [ "$STORED_RESET_TIME" -gt 0 ] 2>/dev/null; then
        if [ "$CURRENT_TIME" -lt "$STORED_RESET_TIME" ]; then
            # Current time is before stored reset time - session is still valid, use cached value
            RESET_TIME=$STORED_RESET_TIME
            SESSION_START_EPOCH=$((RESET_TIME - SESSION_TIME_WINDOW_SIZE))
        fi
    fi

    # If we don't have a valid cached reset time, calculate from this instance's transcript
    if [ -z "$RESET_TIME" ]; then
        # Determine the minimum epoch to search for session start
        # Use the GREATER of: expired stored reset time OR (current_time - 5 hours)
        # This handles two scenarios:
        #   1. Within 5 hours of reset: use stored reset time (new session starts after it)
        #   2. More than 5 hours since reset: use (current_time - 5 hours) as minimum
        if [ -n "$STORED_RESET_TIME" ] && [ "$STORED_RESET_TIME" -gt 0 ] 2>/dev/null; then
            # Use the greater of stored reset time or earliest valid session start
            if [ "$STORED_RESET_TIME" -gt "$EARLIEST_VALID_SESSION_START" ]; then
                MIN_EPOCH_FOR_SESSION_START=$STORED_RESET_TIME
            else
                MIN_EPOCH_FOR_SESSION_START=$EARLIEST_VALID_SESSION_START
            fi
        else
            # No stored reset time - look for activity within the session window
            MIN_EPOCH_FOR_SESSION_START=$EARLIEST_VALID_SESSION_START
        fi

        # Find the first timestamp in transcript that is >= MIN_EPOCH_FOR_SESSION_START
        # This is the start of the current session window
        SESSION_START_ISO=$(get_session_start_from_transcript "$TRANSCRIPT_PATH" "$MIN_EPOCH_FOR_SESSION_START")

        if [ -n "$SESSION_START_ISO" ]; then
            SESSION_START_EPOCH=$(parse_iso_to_epoch "$SESSION_START_ISO")
        fi

        # If no valid timestamp found (empty transcript or all timestamps too old), use current time
        if [ -z "$SESSION_START_EPOCH" ] || ! [ "$SESSION_START_EPOCH" -gt 0 ] 2>/dev/null; then
            SESSION_START_EPOCH=$CURRENT_TIME
        fi

        RESET_TIME=$(calculate_reset_time $SESSION_START_EPOCH)
        # Save to shared file so all other instances use this reset time
        save_reset_time "$RESET_TIME"
    fi

    # Format reset time for display
    RESET_DISPLAY=$(date -d "@$RESET_TIME" +"%-I:%M%p" 2>/dev/null || date -r "$RESET_TIME" +"%l:%M%p" 2>/dev/null)
    RESET_DISPLAY=$(echo "$RESET_DISPLAY" | tr '[:upper:]' '[:lower:]' | sed 's/^ //')

    # Calculate reset time progress percentage
    TOTAL_DURATION=$((RESET_TIME - SESSION_START_EPOCH))
    ELAPSED=$((CURRENT_TIME - SESSION_START_EPOCH))

    # Prevent division by zero and negative values
    if [ "$TOTAL_DURATION" -le 0 ]; then
        TOTAL_DURATION=$SESSION_TIME_WINDOW_SIZE
    fi
    if [ "$ELAPSED" -lt 0 ]; then
        ELAPSED=0
    fi

    PERCENTAGE_TIMES_10=$((ELAPSED * 1000 / TOTAL_DURATION))
    PERCENTAGE_WHOLE=$((PERCENTAGE_TIMES_10 / 10))
    PERCENTAGE_DECIMAL=$((PERCENTAGE_TIMES_10 % 10))

    # Calculate remaining time
    REMAINING=$((RESET_TIME - CURRENT_TIME))
    if [ "$REMAINING" -lt 0 ]; then
        REMAINING=0
    fi
    REMAINING_HOURS=$((REMAINING / 3600))
    REMAINING_MINUTES=$(((REMAINING % 3600) / 60))

    # Build 10-character progress bar (each character = 10%)
    FILLED=$((PERCENTAGE_WHOLE / 10))
    RESET_BAR=$(build_progress_bar "$FILLED")

    printf "${COLOR_TRANSCRIPT}%-25s %8s [%s]${COLOR_RESET}\n" "RESETS @ ${RESET_DISPLAY} | ${REMAINING_HOURS}h ${REMAINING_MINUTES}m" "${PERCENTAGE_WHOLE}.${PERCENTAGE_DECIMAL}%" "${RESET_BAR}"
}

# ============================================================================
# BUILD AND OUTPUT STATUS LINE
# ============================================================================

# Build status line from individual elements (multiline for readability, output as single line)

echo -e "$(get_model_element) | $(get_context_element)"
# Debug: Show debug display mode
# echo -e "$(get_model_element) | $(get_context_element "debug")"

echo -e "$(get_directory_element)"

if has_usage_script; then
    echo -e "$(get_est_usage_element)"
fi

echo -e "$(get_reset_time_element)"

echo -e "$(get_cost_element)"

# Debug: Output the current session ID
# echo -e "Session ID: ${SESSION_ID}"

# Debug: Output the entire JSON payload
# echo -e "$JSON_INPUT"