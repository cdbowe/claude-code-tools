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
# Eighth block characters for fractional fill (index 0=empty, 1-7=partial, 8=full)
PROGRESS_EIGHTHS=(" " "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█")
# Lookup: maps remainder 0-9 to eighth index (uniform distribution, duplicates at 3-4 and 7-8)
EIGHTH_LOOKUP=(0 1 2 3 3 4 5 6 6 7)

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
RATE_LIMIT_5H_USED_PCT=$(echo "$JSON_INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty')
RATE_LIMIT_5H_RESETS_AT=$(echo "$JSON_INPUT" | jq -r '.rate_limits.five_hour.resets_at // empty')
RATE_LIMIT_7D_USED_PCT=$(echo "$JSON_INPUT" | jq -r '.rate_limits.seven_day.used_percentage // empty')
RATE_LIMIT_7D_RESETS_AT=$(echo "$JSON_INPUT" | jq -r '.rate_limits.seven_day.resets_at // empty')

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

# Function: Build a 10-character progress bar with fractional fill using eighth blocks
# Usage: build_progress_bar <percentage>
# Args: percentage - value 0-100 (capped at boundaries)
# Each of the 10 chars represents 10%. The transition char uses eighth blocks
# for sub-10% precision (~1.25% resolution).
build_progress_bar() {
    local pct=$1
    local max=10

    # Clamp percentage to 0-100
    if (( $(echo "$pct > 100" | bc -l) )); then pct=100; fi
    if (( $(echo "$pct < 0" | bc -l) )); then pct=0; fi

    # Calculate filled chars and fractional eighth via lookup table
    local filled=$(echo "$pct / 10" | bc)
    local remainder=$(echo "$pct - ($filled * 10)" | bc)
    local remainder_int=${remainder%.*}
    if [ -z "$remainder_int" ] || [ "$remainder_int" -lt 0 ] 2>/dev/null; then remainder_int=0; fi
    if [ "$remainder_int" -gt 9 ]; then remainder_int=9; fi
    local eighth=${EIGHTH_LOOKUP[$remainder_int]}

    if [ "$filled" -ge $max ]; then
        filled=$max
        eighth=0
    fi

    local empty=$((max - filled))
    # If there's a fractional char, it takes one of the empty slots
    if [ "$eighth" -gt 0 ] && [ "$empty" -gt 0 ]; then
        empty=$((empty - 1))
    fi

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="$PROGRESS_FILLED"; done
    if [ "$eighth" -gt 0 ] && [ "$filled" -lt $max ]; then
        bar+="${PROGRESS_EIGHTHS[$eighth]}"
    fi
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

    PROGRESS_BAR=$(build_progress_bar "$CONTEXT_PCT")

    # Display debug line
    if [ "$display_mode" = "debug" ]; then
        echo -e "${COLOR_CONTEXT_SIZE}${CURRENT_DISPLAY}/${CONTEXT_LIMIT_K}K | ${CONTEXT_PCT}% [${PROGRESS_BAR}] (${CONTEXT_USED_PCT}% | ${input_tokens} ${output_tokens} ${cache_write_tokens} ${cache_read_tokens}) ${COLOR_RESET}"
        return
    fi

    # Display default line
    echo -e "${COLOR_CONTEXT_SIZE}${CURRENT_DISPLAY}/${CONTEXT_LIMIT_K}K | ${CONTEXT_PCT}% [${PROGRESS_BAR}] (${CONTEXT_USED_PCT}%) ${COLOR_RESET}"
}

# Function: Format remaining seconds as human-readable duration
format_remaining_time() {
    local remaining=$1
    if [ "$remaining" -lt 0 ]; then remaining=0; fi

    local days=$((remaining / 86400))
    local hours=$(((remaining % 86400) / 3600))
    local mins=$(((remaining % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# Function: Build a rate limit line with usage bar + time bar
# Args: label used_pct resets_at_epoch window_size_seconds show_day
build_rate_limit_line() {
    local label=$1
    local used_pct=$2
    local resets_at=$3
    local window_size=$4
    local show_day=$5

    if [ -z "$used_pct" ] || [ -z "$resets_at" ]; then
        printf "${COLOR_TRANSCRIPT}%-8s N/A${COLOR_RESET}\n" "${label}:"
        return
    fi

    local current_time=$(date +%s)
    local rounded_pct=$(printf "%.1f" "$used_pct")

    # Usage progress bar
    local usage_bar=$(build_progress_bar "$rounded_pct")

    # Time progress calculation
    local session_start=$((resets_at - window_size))
    local elapsed=$((current_time - session_start))
    if [ "$elapsed" -lt 0 ]; then elapsed=0; fi
    if [ "$elapsed" -gt "$window_size" ]; then elapsed=$window_size; fi

    local time_pct_x10=$((elapsed * 1000 / window_size))
    local time_pct_whole=$((time_pct_x10 / 10))
    local time_pct_decimal=$((time_pct_x10 % 10))
    local time_pct=$(echo "scale=1; $time_pct_x10 / 10" | bc)
    local time_bar=$(build_progress_bar "$time_pct")

    # Remaining time
    local remaining=$((resets_at - current_time))
    local remaining_display=$(format_remaining_time "$remaining")

    # Format reset time
    local reset_display
    if [ "$show_day" = "true" ]; then
        reset_display=$(date -d "@$resets_at" +"%a @ %-I:%M%p" 2>/dev/null || date -r "$resets_at" +"%a @ %l:%M%p" 2>/dev/null)
    else
        reset_display=$(date -d "@$resets_at" +"%-I:%M%p" 2>/dev/null || date -r "$resets_at" +"%l:%M%p" 2>/dev/null)
    fi
    reset_display=$(echo "$reset_display" | tr '[:upper:]' '[:lower:]' | sed 's/^ //')

    printf "${COLOR_TRANSCRIPT}%-8s[%s] %5s  usage${COLOR_RESET}\n" \
        "${label}" "${usage_bar}" "${rounded_pct}%"
    printf "${COLOR_TRANSCRIPT}        [%s] %5s  resets %s (%s)${COLOR_RESET}\n" \
        "${time_bar}" "${time_pct_whole}.${time_pct_decimal}%" "${reset_display}" "${remaining_display}"
}

# Function: Output both rate limit lines and sync session state
get_rate_limits_element() {
    # Sync 5-hour reset time to session state file for the estimation script
    if [ -n "$RATE_LIMIT_5H_RESETS_AT" ]; then
        save_reset_time "$RATE_LIMIT_5H_RESETS_AT"
    fi

    build_rate_limit_line "5-HOUR" "$RATE_LIMIT_5H_USED_PCT" "$RATE_LIMIT_5H_RESETS_AT" "$SESSION_TIME_WINDOW_SIZE" "false"
    build_rate_limit_line "WEEKLY" "$RATE_LIMIT_7D_USED_PCT" "$RATE_LIMIT_7D_RESETS_AT" "604800" "true"
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


# ============================================================================
# BUILD AND OUTPUT STATUS LINE
# ============================================================================

# Build status line from individual elements (multiline for readability, output as single line)

# Debug: Output the entire JSON payload
# echo "$JSON_INPUT" > "$WORKSPACE_DIR/.claude/statusline_data.json"

echo -e "$(get_model_element) | $(get_context_element)"
# Debug: Show debug display mode
# echo -e "$(get_model_element) | $(get_context_element "debug")"

echo -e "$(get_directory_element)"

get_rate_limits_element

echo -e "$(get_cost_element)"

# Debug: Output the current session ID
# echo -e "Session ID: ${SESSION_ID}"