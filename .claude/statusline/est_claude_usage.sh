#!/bin/bash
# Claude Usage Calculator - reads from ~/.claude/ directory
# Estimates usage % for Max 5x plan
# Uses session state from statusline_script.sh for accurate window timing
#
# Usage:
#   ./est_claude_usage.sh              # Full calculation with detailed output
#   ./est_claude_usage.sh --statusline # Minimal output for statusline integration
#   ./est_claude_usage.sh --debug      # Verbose debug output
#   ./est_claude_usage.sh --reset-epoch=<epoch> # Override reset time (debug mode)
#   ./est_claude_usage.sh --enable-oauth-api   # Enable actual usage fetch from Anthropic API
#
# All runs are logged to usage-logs.txt in the same directory as this script.

# ============================================================================
# CONFIG
# ============================================================================

CLAUDE_DIR="$HOME/.claude"
# Session state file (shared with statusline_script.sh)
SESSION_STATE_FILE="$HOME/.claude/claude-code-session-state"

# Usage cache file (for debugging/analysis only)
USAGE_CACHE_FILE="$HOME/.claude/claude-code-usage-cache"

# Log file in the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LOG_FILE="$SCRIPT_DIR/usage-logs.txt"

SESSION_TIME_WINDOW_SIZE=18000  # Session window size in seconds (must match statusline_script.sh)

SESSION_TIME_WINDOW_SIZE_HOURS=$(($SESSION_TIME_WINDOW_SIZE / 60 / 60)) # Session window calculated in hours

# Current API cost limit estimates per 5-hour session:
# Pro:       $X/session
# Max 5x:    $(X*5)/session (Pro*5)
# Max 20x:   $(X*20)/session (Pro*20)
# ESTIMATED_LIMIT=60  # dollars per 5-hour session

# Pricing multipliers (per million tokens) - adjust these to calibrate estimation
# Official API pricing: https://platform.claude.com/docs/en/about-claude/pricing
OPUS_INPUT_RATE=5.0         # Model: Opus 4.5
OPUS_OUTPUT_RATE=25.0       # Output Tokens: 5x input token cost
OPUS_CACHE_WRITE_5M_RATE=6.25   # 5-minute cache write: 1.25x input token cost
OPUS_CACHE_WRITE_1H_RATE=10.0   # 1-hour cache write: 1.25x input token cost
OPUS_CACHE_READ_RATE=0.50   # Cache Read: 0.1x input token cost

SONNET_INPUT_RATE=3.0       # Model: Sonnet 4.5
SONNET_OUTPUT_RATE=15.0
SONNET_CACHE_WRITE_5M_RATE=3.75
SONNET_CACHE_WRITE_1H_RATE=6.0
SONNET_CACHE_READ_RATE=0.30

HAIKU_INPUT_RATE=1.0        # Model: Haiku 4.5
HAIKU_OUTPUT_RATE=5.0
HAIKU_CACHE_WRITE_5M_RATE=1.25
HAIKU_CACHE_WRITE_1H_RATE=2.0
HAIKU_CACHE_READ_RATE=0.10

# Cache token coefficient multipliers (for SUBSCRIPTION credit calculations)
# Source: https://she-llac.com/claude-limits
# NOTE: These differ from API billing rates!
# - API: cache writes = 1.25×/2×, cache reads = 0.1×
# - Subscription: cache writes = 1× (regular price), cache reads = FREE
CACHE_WRITE_5M_COEFF=1.25     # 5-minute cache write = regular input price for subs
CACHE_WRITE_1H_COEFF=2.0     # 1-hour cache write = regular input price for subs
CACHE_READ_COEFF=0.0         # Cache reads

# Tool use and feature pricing
TOOL_USE_SYSTEM_PROMPT_TOKENS=346       # Tool choice auto/none (default)
# TOOL_USE_SYSTEM_PROMPT_TOKENS=313     # Tool choice any/tool (forced, alternative)
WEB_SEARCH_COST_PER_1000=10.00          # $10 per 1,000 WebSearch tool calls

# Credits-based usage estimation (experimental)
# Formula: (input + cw_5m × cw_5m_coeff + cw_1h × cw_1h_coeff) × in_coeff + output × out_coeff + compaction × compaction_coeff
# Cache reads are free for subscriptions
# SESSION_CREDIT_LIMIT=3300000            # Credits per 5-hour session
SESSION_CREDIT_LIMIT=6000000            # Credits per 5-hour session

# OPUS_INPUT_CREDIT_COEFF=1.0               # 1 credit per token
# OPUS_OUTPUT_CREDIT_COEFF=5.0              # 5 credits per token

# SONNET_INPUT_CREDIT_COEFF=0.6             # 3/5 credits per token
# SONNET_OUTPUT_CREDIT_COEFF=3.0            # 3 credits per token

# HAIKU_INPUT_CREDIT_COEFF=0.2              # 1/5 credits per token
# HAIKU_OUTPUT_CREDIT_COEFF=1.0             # 1 credit per token

OPUS_INPUT_CREDIT_COEFF=0.833333          # 5/6 credit per token
OPUS_OUTPUT_CREDIT_COEFF=4.166667         # 25/6 credits per token

SONNET_INPUT_CREDIT_COEFF=0.50            # 1/2 credits per token
SONNET_OUTPUT_CREDIT_COEFF=2.5            # 5/2 credits per token

HAIKU_INPUT_CREDIT_COEFF=0.166667         # 1/6 credits per token
HAIKU_OUTPUT_CREDIT_COEFF=0.833333        # 5/6 credit per token

# Compaction tokens use the same coefficient as the model's input tokens
# (compaction is context summarization, consuming input tokens on the selected model)
OPUS_COMPACTION_COEFF=$OPUS_INPUT_CREDIT_COEFF
SONNET_COMPACTION_COEFF=$SONNET_INPUT_CREDIT_COEFF
HAIKU_COMPACTION_COEFF=$HAIKU_INPUT_CREDIT_COEFF

# Calibration multiplier to adjust for unmeasured overhead
# (system prompts, MCP tools, subagent context, etc.)
# If estimated consistently underestimates actual, increase this value
# CALIBRATION_MULTIPLIER=1.333333       # 4/3 - calibrated from actual vs estimated comparison
# CALIBRATION_MULTIPLIER=1.25           # 5/4 - calibrated from actual vs estimated comparison
# CALIBRATION_MULTIPLIER=1.1            # 1.1 - calibrated from actual vs estimated comparison
CALIBRATION_MULTIPLIER=1.0              # 1 - calibrated from actual vs estimated comparison

# Anthropic OAuth Usage API configuration
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
USAGE_API_URL="https://api.anthropic.com/api/oauth/usage"
USAGE_API_BETA_HEADER="oauth-2025-04-20"
OAUTH_API_CACHE_FILE="$HOME/.claude/oauth-usage-cache.json"
API_CALL_COOLDOWN_DURATION=600  # seconds (2 minutes)

# Raw credits total offset, to skew the usage estimation additively.
# Applies after all other calculations.
TOTAL_CREDITS_OFFSET=0 # Default: 0

# Historical usage data log (for coefficient calibration)
USAGE_DATA_LOG="$SCRIPT_DIR/usage-data-log.txt"


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
is_statusline_mode() { [ "$STATUSLINE_MODE" = true ]; }
is_debug_mode() { [ "$DEBUG" = true ]; }
is_save_cache() { [ "$SAVE_CACHE" = true ]; }

# Log a line to the log file
log_line() {
    if [ ! -z "$LOG_FILE" ]; then
        echo "$1" >> "$LOG_FILE" 2>&1
    fi
}

# Write log separator with timestamp
write_log_separator() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    log_line " "
    log_line "********************************************************************************"
    log_line "Run started: $timestamp"
    log_line "Args: $*"
    log_line "********************************************************************************"
}

# Print only when NOT in statusline mode
echo_nq() {
    if ! is_statusline_mode; then
        echo "$1"
        log_line "$1"
    fi
}

printf_nq() {
    if ! is_statusline_mode; then
        printf "$@"
        log_line "$@"
    fi
}

# Print only when IN statusline mode
echo_q() {
    if is_statusline_mode; then
        echo "$1"
        log_line "$1"
    fi
}

# Print only when in debug mode
print_debug() {
    if is_debug_mode; then
        echo "## [${2:-DEBUG}] $1" >&2
        log_line "## [${2:-DEBUG}] $1"
    fi
}

# Execute a function and print timing in debug mode
# Usage: time_debug function_name [args...]
time_debug() {
    local fn_name="$1"
    shift

    local t0=$EPOCHREALTIME
    "$fn_name" "$@"
    local exit_code=$?
    local delta=$(echo "$EPOCHREALTIME - $t0" | bc)

    print_debug "$(printf '%-35s %.3fs' "$fn_name" "$delta")" "TIME"
    return $exit_code
}

echo_nq_checkmark() {
    echo_nq "✅ ${1}"
}

# ============================================================================
# ARG PARSING
# ============================================================================
STATUSLINE_MODE=false
DEBUG=false
SAVE_CACHE=true
OVERRIDE_RESET_EPOCH=""
ENABLE_OAUTH_API=false
OAUTH_CACHE_VALID_UNTIL=""  # Set by read_cached_usage() when cache is valid

for arg in "$@"; do
    case $arg in
        --reset-epoch=*) OVERRIDE_RESET_EPOCH="${arg#--reset-epoch=}" ;;
        --statusline|-q) STATUSLINE_MODE=true ;;
        --debug) DEBUG=true ;;
        --no-save-cache) SAVE_CACHE=false ;;
        --enable-oauth-api) ENABLE_OAUTH_API=true ;;
    esac
done

# If reset epoch override is provided, disable cache saving (debug mode)
if [ -n "$OVERRIDE_RESET_EPOCH" ]; then
    SAVE_CACHE=false
    print_debug "Reset epoch override detected - disabling cache writes"
fi

# ============================================================================
# OAUTH USAGE API
# ============================================================================

# Format cache valid until timestamp for display
# Returns: formatted time string (e.g. "22:15" or "tomorrow @ 00:04")
format_cache_valid_until_time() {
    local valid_until_epoch=$1
    local now_epoch=$(date +%s)
    local valid_date=$(date -d @$valid_until_epoch +%Y%m%d 2>/dev/null)
    local today_date=$(date -d @$now_epoch +%Y%m%d 2>/dev/null)
    local valid_time=$(date -d @$valid_until_epoch +%H:%M 2>/dev/null)

    if [ "$valid_date" -gt "$today_date" ]; then
        echo "tomorrow @ $valid_time"
    else
        echo "$valid_time"
    fi
}

# Write OAuth usage cache with full JSON response and valid until timestamp
# Takes full JSON response as parameter
write_oauth_cache() {
    local json_response=$1
    local now_epoch=$(date +%s)
    local valid_until_epoch=$((now_epoch + API_CALL_COOLDOWN_DURATION))
    # Round up to next minute
    valid_until_epoch=$(((valid_until_epoch + 59) / 60 * 60))

    # Add cache metadata to the response JSON
    local cached_json
    cached_json=$(echo "$json_response" | jq --arg cached_at "$now_epoch" --arg valid_until "$valid_until_epoch" \
        '. + {"_cacheMetadata": {"cached_at": ($cached_at | tonumber), "valid_until": ($valid_until | tonumber)}}')

    echo "$cached_json" > "$OAUTH_API_CACHE_FILE"
    print_debug "Wrote OAuth cache: valid_until=$valid_until_epoch ($(date -d @$valid_until_epoch '+%Y-%m-%d %H:%M:%S'))"
}

# Read cached OAuth usage if valid
# Returns: "utilization seconds_remaining" if cache is valid, empty if not
# seconds_remaining is the number of seconds until cache expires
read_cached_usage() {
    if [ ! -f "$OAUTH_API_CACHE_FILE" ]; then
        print_debug "OAuth cache file not found"
        return 1
    fi

    local now_epoch=$(date +%s)
    local utilization
    local valid_until

    utilization=$(jq -r '.five_hour.utilization // empty' "$OAUTH_API_CACHE_FILE" 2>/dev/null)
    valid_until=$(jq -r '._cacheMetadata.valid_until // empty' "$OAUTH_API_CACHE_FILE" 2>/dev/null)

    if [ -z "$utilization" ] || [ -z "$valid_until" ]; then
        print_debug "OAuth cache file invalid or incomplete"
        return 1
    fi

    # Check if cache is still valid
    if [ "$now_epoch" -lt "$valid_until" ]; then
        local seconds_remaining=$((valid_until - now_epoch))
        print_debug "OAuth cache is valid (seconds_remaining=$seconds_remaining)"
        echo "$utilization $seconds_remaining"
        return 0
    else
        print_debug "OAuth cache is expired (valid_until=$valid_until, now=$now_epoch)"
        return 1
    fi
}

# Fetch actual usage from Anthropic OAuth API
# Returns: "utilization seconds_remaining" where seconds_remaining is:
#   -3 = API call failed
#   -2 = no actual usage available
#   -1 = fresh from API call
#   >= 0 = cached (seconds until cache expires)
# Caches the full JSON response and respects cooldown period
fetch_actual_usage() {
    # Check if OAuth API is enabled
    if [ "$ENABLE_OAUTH_API" != true ]; then
        print_debug "OAuth API disabled (use --enable-oauth-api to enable)"
        echo ""
        return 1
    fi

    # Try to read from cache first
    local cached_result
    cached_result=$(read_cached_usage)
    if [ $? -eq 0 ]; then
        # Result contains: "utilization seconds_remaining"
        print_debug "Using cached OAuth usage: $cached_result"
        echo "$cached_result"
        return 0
    fi

    # Cache expired - make API call
    # Check if credentials file exists
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        print_debug "Credentials file not found: $CREDENTIALS_FILE"
        echo "- -3"  # -3 indicates API call failure
        return 1
    fi

    # Extract OAuth access token
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)

    if [ -z "$token" ]; then
        print_debug "No OAuth access token found in credentials file"
        echo "- -3"  # -3 indicates API call failure
        return 1
    fi

    # Call the usage API
    local response
    response=$(curl -s --max-time 5 "$USAGE_API_URL" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: $USAGE_API_BETA_HEADER" \
        -H "Content-Type: application/json" 2>/dev/null)

    if [ -z "$response" ]; then
        print_debug "Empty response from usage API"
        echo "- -3"  # -3 indicates API call failure
        return 1
    fi

    # Extract five_hour utilization
    local utilization
    utilization=$(echo "$response" | jq -r '.five_hour.utilization // empty' 2>/dev/null)

    if [ -n "$utilization" ] && [ "$utilization" != "null" ]; then
        print_debug "Fetched actual utilization: $utilization%"
        # Cache the full response
        write_oauth_cache "$response"

        # Sync session reset time from API's authoritative resets_at
        local api_resets_at
        api_resets_at=$(echo "$response" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
        if [ -n "$api_resets_at" ]; then
            local api_reset_epoch
            api_reset_epoch=$(date -d "$api_resets_at" +%s 2>/dev/null)
            if [ -n "$api_reset_epoch" ] && [ "$api_reset_epoch" -gt 1000000000 ] 2>/dev/null; then
                local current_stored
                current_stored=$(cat "$SESSION_STATE_FILE" 2>/dev/null)
                if [ "$current_stored" != "$api_reset_epoch" ]; then
                    save_reset_time "$api_reset_epoch"
                    print_debug "Synced reset time from API: $api_reset_epoch ($(date -d @$api_reset_epoch '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
                fi
            fi
        fi

        echo "$utilization -1"  # -1 indicates fresh API call
        return 0
    else
        print_debug "Failed to parse utilization from response: $response"
        echo "- -3"  # -3 indicates API call failure
        return 1
    fi
}

# ============================================================================
# SESSION WINDOW
# ============================================================================

# Calculate reset time from current time
calculate_reset_time() {
    local current_epoch=$1
    local reset_time=$((current_epoch + SESSION_TIME_WINDOW_SIZE))
    echo $reset_time
}

# Save reset time to shared state file
save_reset_time() {
    local reset_time=$1
    echo "$reset_time" > "$SESSION_STATE_FILE"
    print_debug "Saved new reset time to SESSION_STATE_FILE: $reset_time"
}

determine_window_start() {
    # Check if reset epoch override was provided
    if [ -n "$OVERRIDE_RESET_EPOCH" ] && [ "$OVERRIDE_RESET_EPOCH" -gt 1000000000 ]; then
        # Use provided reset epoch
        RESET_TIME=$OVERRIDE_RESET_EPOCH
        NOW_EPOCH=$((RESET_TIME - SESSION_TIME_WINDOW_SIZE))
        SESSION_START_EPOCH=$NOW_EPOCH

        print_debug "Using override reset epoch: $RESET_TIME"
        print_debug "Calculated NOW_EPOCH: $NOW_EPOCH ($(date -d @$NOW_EPOCH '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
        WINDOW_SOURCE="override (reset epoch provided)"
    else
        NOW_EPOCH=$(date +%s)

        print_debug "NOW_EPOCH: $NOW_EPOCH ($(date -d @$NOW_EPOCH '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"

        # Read stored reset time from session state file
        STORED_RESET_TIME=""
        if [ -f "$SESSION_STATE_FILE" ]; then
            STORED_RESET_TIME=$(cat "$SESSION_STATE_FILE" 2>/dev/null)
            print_debug "STORED_RESET_TIME from file: $STORED_RESET_TIME"
        fi

        # Check if stored reset time is valid and hasn't expired
        if [ -n "$STORED_RESET_TIME" ] && [ "$STORED_RESET_TIME" -gt 0 ] && [ "$STORED_RESET_TIME" -gt "$NOW_EPOCH" ] 2>/dev/null; then
            # Valid stored reset time - use it
            RESET_TIME=$STORED_RESET_TIME
            SESSION_START_EPOCH=$((RESET_TIME - SESSION_TIME_WINDOW_SIZE))

            print_debug "Using valid stored reset time: $RESET_TIME"
            WINDOW_SOURCE="session state (valid)"
        else
            # Reset time has expired or doesn't exist - calculate new one
            # This matches statusline_script.sh behavior when reset time expires
            print_debug "Stored reset time expired or missing, calculating new reset time..."

            RESET_TIME=$(calculate_reset_time $NOW_EPOCH)
            SESSION_START_EPOCH=$((RESET_TIME - SESSION_TIME_WINDOW_SIZE))

            # Save the new reset time so all scripts use it
            save_reset_time "$RESET_TIME"

            print_debug "Calculated new RESET_TIME: $RESET_TIME ($(date -d @$RESET_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
            WINDOW_SOURCE="calculated (reset time expired)"
        fi
    fi

    WINDOW_START=$(date -d "@$SESSION_START_EPOCH" -Iseconds 2>/dev/null || \
                   date -r "$SESSION_START_EPOCH" +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    WINDOW_START_EPOCH=$SESSION_START_EPOCH

    # Format reset time for display
    STORED_START_DATE_FMT=$(date -d @$SESSION_START_EPOCH +"%Y%m%d" 2>/dev/null || date -d "$SESSION_START_EPOCH" +"%Y%m%d")
    STORED_RESET_DATE_FMT=$(date -d @$RESET_TIME +"%Y%m%d" 2>/dev/null || date -d "$RESET_TIME" +"%Y%m%d")
    STORED_RESET_TIME_FMT=$(date -d @$RESET_TIME +"%H:%M" 2>/dev/null || date -d "$RESET_TIME" +"%H:%M")

    if [ $STORED_START_DATE_FMT -lt $STORED_RESET_DATE_FMT ]; then
        WINDOW_SOURCE="$WINDOW_SOURCE (reset tomorrow @ $STORED_RESET_TIME_FMT [$RESET_TIME])"
    else
        WINDOW_SOURCE="$WINDOW_SOURCE (reset @ $STORED_RESET_TIME_FMT [$RESET_TIME])"
    fi

    print_debug "SESSION_START_EPOCH: $SESSION_START_EPOCH"
    print_debug "WINDOW_START: $WINDOW_START"
    print_debug "WINDOW_SOURCE: $WINDOW_SOURCE"
}

# ============================================================================
# TOTALS
# ============================================================================
init_totals() {
    declare -gA TOTALS
    for model in opus sonnet haiku; do
        TOTALS[${model}_in]=0
        TOTALS[${model}_out]=0
        TOTALS[${model}_cw_5m]=0
        TOTALS[${model}_cw_1h]=0
        TOTALS[${model}_cr]=0
        TOTALS[${model}_msgs]=0
        TOTALS[${model}_tool_use]=0
        TOTALS[${model}_compaction]=0
    done
    TOTALS[web_search]=0
    LAST_TIMESTAMP=""
    LAST_TIMESTAMP_EPOCH=0
    SESSION_TIME_WINDOW_SIZE_HOURS=$(($SESSION_TIME_WINDOW_SIZE / 60 / 60))
}

save_cache() {
    if ! is_save_cache; then
        print_debug "Cache saving disabled"
        return 0
    fi

    cat > "$USAGE_CACHE_FILE" << EOF
{
  "session_start": "$WINDOW_START",
  "session_start_epoch": $WINDOW_START_EPOCH,
  "last_timestamp": "$LAST_TIMESTAMP",
  "last_timestamp_epoch": $LAST_TIMESTAMP_EPOCH,
  "total_cost": $TOTAL_COST,
  "totals": {
    "opus": {
      "input": ${TOTALS[opus_in]},
      "output": ${TOTALS[opus_out]},
      "cache_write_5m": ${TOTALS[opus_cw_5m]},
      "cache_write_1h": ${TOTALS[opus_cw_1h]},
      "cache_read": ${TOTALS[opus_cr]},
      "messages": ${TOTALS[opus_msgs]},
      "cost": $OPUS_COST
    },
    "sonnet": {
      "input": ${TOTALS[sonnet_in]},
      "output": ${TOTALS[sonnet_out]},
      "cache_write_5m": ${TOTALS[sonnet_cw_5m]},
      "cache_write_1h": ${TOTALS[sonnet_cw_1h]},
      "cache_read": ${TOTALS[sonnet_cr]},
      "messages": ${TOTALS[sonnet_msgs]},
      "cost": $SONNET_COST
    },
    "haiku": {
      "input": ${TOTALS[haiku_in]},
      "output": ${TOTALS[haiku_out]},
      "cache_write_5m": ${TOTALS[haiku_cw_5m]},
      "cache_write_1h": ${TOTALS[haiku_cw_1h]},
      "cache_read": ${TOTALS[haiku_cr]},
      "messages": ${TOTALS[haiku_msgs]},
      "cost": $HAIKU_COST
    }
  },
  "web_search": {
    "total_searches": ${TOTALS[web_search]},
    "cost": $WEB_SEARCH_COST
  },
  "tool_use": {
    "opus_count": ${TOTALS[opus_tool_use]},
    "sonnet_count": ${TOTALS[sonnet_tool_use]},
    "haiku_count": ${TOTALS[haiku_tool_use]},
    "overhead_tokens": $TOOL_USE_SYSTEM_PROMPT_TOKENS
  }
}
EOF
    print_debug "Cache saved (last_timestamp_epoch=$LAST_TIMESTAMP_EPOCH)"
}

# ============================================================================
# JSONL PROCESSING
# ============================================================================
find_jsonl_files() {
    local from_epoch="$1"

    # Validate from_epoch parameter
    if [ -z "$from_epoch" ] || [ "$from_epoch" -lt 1000000000 ]; then
        echo "ERROR: find_jsonl_files called with invalid epoch: '$from_epoch'" >&2
        print_debug "from_epoch=$from_epoch (invalid!)"
        exit 1
    fi

    echo_nq "Searching JSONL source files (modified after epoch $from_epoch)..."
    print_debug "find_jsonl_files: from_epoch=$from_epoch ($(date -d "@$from_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"

    JSONL_FILES=$(find "$CLAUDE_DIR/projects" -name "*.jsonl" -type f -newermt "$(date -d "@$from_epoch" +%Y-%m-%dT%H:%M:%S)" 2>/dev/null)

    if [ -z "$JSONL_FILES" ]; then
        echo_nq "No JSONL files found modified after $(date -d "@$from_epoch" '+%Y-%m-%d %H:%M:%S')."
        JSONL_FILES=""
    else
        local file_count=$(echo "$JSONL_FILES" | wc -l)
        print_debug "Found $file_count JSONL file(s) to process"
    fi
}

# Process JSONL files for assistant messages with .timestamp > from_epoch.
# Populates the global NEW_DATA variable.
process_jsonl() {
    local from_epoch="$1"

    # Validate from_epoch parameter
    if [ -z "$from_epoch" ] || [ "$from_epoch" -lt 1000000000 ]; then
        echo "ERROR: process_jsonl called with invalid epoch: '$from_epoch'" >&2
        print_debug "from_epoch=$from_epoch (invalid!)"
        exit 1
    fi

    print_debug "Processing messages with timestamp > $from_epoch ($(date -d "@$from_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null))"
    print_debug "JSONL_FILES ($(echo "$JSONL_FILES" | wc -l) files):"
    print_debug "$JSONL_FILES"

    # CRITICAL: Use TZ=UTC for jq's fromdateiso8601 to avoid timezone offset bugs.
    # Without this, jq applies local DST offset to "Z" timestamps, causing epoch drift
    # (e.g., +3600s in EDT) that includes messages from before the session window.
    NEW_DATA=$(echo "$JSONL_FILES" | xargs cat 2>/dev/null | TZ=UTC jq -s --arg from_epoch "$from_epoch" '
    # CRITICAL: Group by message.id FIRST, then filter by max timestamp of each group.
    # This prevents double-counting when a message streams over multiple seconds.
    # A message is either fully counted (if its final timestamp > from_epoch) or not counted at all.
    # Note: jq -s natively handles JSONL (newline-separated JSON objects)

    # Build a lookup table by uuid for parent chain traversal
    [.[] | select(type == "object")] as $all_raw |
    ($all_raw | map(select(.uuid != null) | {(.uuid): .}) | add // {}) as $by_uuid |

    # Filter to assistant messages with usage data
    [$all_raw[] | select(
      .type == "assistant" and
      .timestamp != null and
      .message != null
    )] as $all_messages |

    # Compaction detection: For each message, check if parent.isCompactSummary == true,
    # if so, get grandparent.compactMetadata.preTokens and attribute to message.model
    (
      [ $all_messages[] |
          (.timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601) as $message_epoch |
          select($message_epoch > ($from_epoch | tonumber)) |
          .parentUuid as $parent_uuid |
          .message.model as $model |
          select($parent_uuid != null) |
          ($by_uuid[$parent_uuid] // null) as $parent |
          select($parent != null and $parent.isCompactSummary == true) |
          $parent.parentUuid as $grandparent_uuid |
          select($grandparent_uuid != null) |
          ($by_uuid[$grandparent_uuid] // null) as $grandparent |
          select($grandparent != null and $grandparent.compactMetadata.preTokens != null) |
          {model: $model, preTokens: $grandparent.compactMetadata.preTokens}
      ] | group_by(.model) | map({
          model: .[0].model,
          total: (map(.preTokens) | add // 0)
        }) | {
          opus: (map(select(.model | test("opus"))) | .[0].total // 0),
          sonnet: (map(select(.model | test("sonnet"))) | .[0].total // 0),
          haiku: (map(select(.model | test("haiku"))) | .[0].total // 0)
        }
    ) as $compaction_by_model |

    # Step 2: Group by message.id, filter groups by their MAX timestamp, then flatten
    # This ensures we only include messages whose FINAL entry is after from_epoch
    [
        $all_messages
      | group_by(.message.id)
      | .[]
      | { entries: ., max_ts_epoch: ([.[].timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601] | max) }
      | select(.max_ts_epoch > ($from_epoch | tonumber))
      | .entries[]
    ] as $new_messages |

    # Subset with usage data (for token counting)
    [$new_messages[] | select(.message.usage != null)] as $usage_messages |

    if ($usage_messages | length) == 0 then
      { has_new: false, max_ts: "", max_ts_epoch: ($from_epoch | tonumber) }
    else
      {
        has_new: true,
        max_ts: ([$new_messages[] | .timestamp] | max),
        max_ts_epoch: ([$new_messages[] | .timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601] | max),
        web_search_count: [$new_messages[] | select(.message.content and (.message.content | type == "array")) | .message.content[] | select(.type == "tool_use" and .name == "WebSearch")] | length,
        opus: (
          [$usage_messages[] | select(.message.model and (.message.model | test("opus")))]
          | group_by(.message.id)
          | map({
              input: (map(.message.usage.input_tokens // 0) | max),
              output: (map(.message.usage.output_tokens // 0) | max),
              cache_write_5m: (map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | max),
              cache_write_1h: (map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | max),
              cache_read: (map(.message.usage.cache_read_input_tokens // 0) | max)
            })
          | {
              input: (map(.input) | add // 0),
              output: (map(.output) | add // 0),
              cache_write_5m: (map(.cache_write_5m) | add // 0),
              cache_write_1h: (map(.cache_write_1h) | add // 0),
              cache_read: (map(.cache_read) | add // 0),
              messages: length
            }
        ),
        opus_tool_use: [$new_messages[] | select(.message.model and (.message.model | test("opus")) and .message.content and (.message.content | type == "array")) | .message.content[] | select(.type == "tool_use")] | length,
        sonnet: (
          [$usage_messages[] | select(.message.model and (.message.model | test("sonnet")))]
          | group_by(.message.id)
          | map({
              input: (map(.message.usage.input_tokens // 0) | max),
              output: (map(.message.usage.output_tokens // 0) | max),
              cache_write_5m: (map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | max),
              cache_write_1h: (map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | max),
              cache_read: (map(.message.usage.cache_read_input_tokens // 0) | max)
            })
          | {
              input: (map(.input) | add // 0),
              output: (map(.output) | add // 0),
              cache_write_5m: (map(.cache_write_5m) | add // 0),
              cache_write_1h: (map(.cache_write_1h) | add // 0),
              cache_read: (map(.cache_read) | add // 0),
              messages: length
            }
        ),
        sonnet_tool_use: [$new_messages[] | select(.message.model and (.message.model | test("sonnet")) and .message.content and (.message.content | type == "array")) | .message.content[] | select(.type == "tool_use")] | length,
        haiku: (
          [$usage_messages[] | select(.message.model and (.message.model | test("haiku")))]
          | group_by(.message.id)
          | map({
              input: (map(.message.usage.input_tokens // 0) | max),
              output: (map(.message.usage.output_tokens // 0) | max),
              cache_write_5m: (map(.message.usage.cache_creation.ephemeral_5m_input_tokens // 0) | max),
              cache_write_1h: (map(.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) | max),
              cache_read: (map(.message.usage.cache_read_input_tokens // 0) | max)
            })
          | {
              input: (map(.input) | add // 0),
              output: (map(.output) | add // 0),
              cache_write_5m: (map(.cache_write_5m) | add // 0),
              cache_write_1h: (map(.cache_write_1h) | add // 0),
              cache_read: (map(.cache_read) | add // 0),
              messages: length
            }
        ),
        haiku_tool_use: [$new_messages[] | select(.message.model and (.message.model | test("haiku")) and .message.content and (.message.content | type == "array")) | .message.content[] | select(.type == "tool_use")] | length,
        # Compaction tokens by model (input tokens consumed when summarizing conversation)
        opus_compaction: ($compaction_by_model.opus // 0),
        sonnet_compaction: ($compaction_by_model.sonnet // 0),
        haiku_compaction: ($compaction_by_model.haiku // 0)
      }
    end
    ')

    print_debug "$NEW_DATA"
    print_debug "has_new: $(echo "$NEW_DATA" | jq -r '.has_new')"
    print_debug "sonnet input: $(echo "$NEW_DATA" | jq -r '.sonnet.input // 0')"
}

# Add NEW_DATA results to TOTALS and update LAST_TIMESTAMP_EPOCH
accumulate_data() {
    local HAS_NEW
    HAS_NEW=$(echo "$NEW_DATA" | jq -r '.has_new')

    if [ "$HAS_NEW" = "true" ]; then
        read -r LAST_TIMESTAMP LAST_TIMESTAMP_EPOCH opus_in opus_out opus_cw_5m opus_cw_1h opus_cr opus_msgs \
          sonnet_in sonnet_out sonnet_cw_5m sonnet_cw_1h sonnet_cr sonnet_msgs \
          haiku_in haiku_out haiku_cw_5m haiku_cw_1h haiku_cr haiku_msgs \
          opus_tool_use sonnet_tool_use haiku_tool_use web_search \
          opus_compaction sonnet_compaction haiku_compaction \
          < <(echo "$NEW_DATA" | jq -r '[
            .max_ts // "",
            .max_ts_epoch // 0,
            .opus.input,
            .opus.output,
            .opus.cache_write_5m,
            .opus.cache_write_1h,
            .opus.cache_read,
            .opus.messages,
            .sonnet.input,
            .sonnet.output,
            .sonnet.cache_write_5m,
            .sonnet.cache_write_1h,
            .sonnet.cache_read,
            .sonnet.messages,
            .haiku.input,
            .haiku.output,
            .haiku.cache_write_5m,
            .haiku.cache_write_1h,
            .haiku.cache_read,
            .haiku.messages,
            .opus_tool_use,
            .sonnet_tool_use,
            .haiku_tool_use,
            .web_search_count,
            .opus_compaction // 0,
            .sonnet_compaction // 0,
            .haiku_compaction // 0
          ] | join(" ")')

        TOTALS[opus_in]=$((         TOTALS[opus_in]         + $opus_in))
        TOTALS[opus_out]=$((        TOTALS[opus_out]        + $opus_out))
        TOTALS[opus_cw_5m]=$((      TOTALS[opus_cw_5m]      + $opus_cw_5m))
        TOTALS[opus_cw_1h]=$((      TOTALS[opus_cw_1h]      + $opus_cw_1h))
        TOTALS[opus_cr]=$((         TOTALS[opus_cr]         + $opus_cr))
        TOTALS[opus_msgs]=$((       TOTALS[opus_msgs]       + $opus_msgs))
        TOTALS[sonnet_in]=$((       TOTALS[sonnet_in]       + $sonnet_in))
        TOTALS[sonnet_out]=$((      TOTALS[sonnet_out]      + $sonnet_out))
        TOTALS[sonnet_cw_5m]=$((    TOTALS[sonnet_cw_5m]    + $sonnet_cw_5m))
        TOTALS[sonnet_cw_1h]=$((    TOTALS[sonnet_cw_1h]    + $sonnet_cw_1h))
        TOTALS[sonnet_cr]=$((       TOTALS[sonnet_cr]       + $sonnet_cr))
        TOTALS[sonnet_msgs]=$((     TOTALS[sonnet_msgs]     + $sonnet_msgs))
        TOTALS[haiku_in]=$((        TOTALS[haiku_in]        + $haiku_in))
        TOTALS[haiku_out]=$((       TOTALS[haiku_out]       + $haiku_out))
        TOTALS[haiku_cw_5m]=$((     TOTALS[haiku_cw_5m]     + $haiku_cw_5m))
        TOTALS[haiku_cw_1h]=$((     TOTALS[haiku_cw_1h]     + $haiku_cw_1h))
        TOTALS[haiku_cr]=$((        TOTALS[haiku_cr]        + $haiku_cr))
        TOTALS[haiku_msgs]=$((      TOTALS[haiku_msgs]      + $haiku_msgs))
        TOTALS[opus_tool_use]=$((   TOTALS[opus_tool_use]   + $opus_tool_use))
        TOTALS[sonnet_tool_use]=$(( TOTALS[sonnet_tool_use] + $sonnet_tool_use))
        TOTALS[haiku_tool_use]=$((  TOTALS[haiku_tool_use]  + $haiku_tool_use))
        TOTALS[web_search]=$((      TOTALS[web_search]      + $web_search))
        TOTALS[opus_compaction]=$((   TOTALS[opus_compaction]   + ${opus_compaction:-0}))
        TOTALS[sonnet_compaction]=$(( TOTALS[sonnet_compaction] + ${sonnet_compaction:-0}))
        TOTALS[haiku_compaction]=$((  TOTALS[haiku_compaction]  + ${haiku_compaction:-0}))

        print_debug "Accumulated data. last_timestamp_epoch=$LAST_TIMESTAMP_EPOCH"
    else
        print_debug "No data to accumulate"
    fi
}

# ============================================================================
# COST CALCULATION
# ============================================================================
calculate_costs() {
    OPUS_COST=$(echo "scale=6; (${TOTALS[opus_in]} * $OPUS_INPUT_RATE + ${TOTALS[opus_out]} * $OPUS_OUTPUT_RATE + ${TOTALS[opus_cw_5m]} * $OPUS_CACHE_WRITE_5M_RATE + ${TOTALS[opus_cw_1h]} * $OPUS_CACHE_WRITE_1H_RATE + ${TOTALS[opus_cr]} * $OPUS_CACHE_READ_RATE) / 1000000" | bc)
    SONNET_COST=$(echo "scale=6; (${TOTALS[sonnet_in]} * $SONNET_INPUT_RATE + ${TOTALS[sonnet_out]} * $SONNET_OUTPUT_RATE + ${TOTALS[sonnet_cw_5m]} * $SONNET_CACHE_WRITE_5M_RATE + ${TOTALS[sonnet_cw_1h]} * $SONNET_CACHE_WRITE_1H_RATE + ${TOTALS[sonnet_cr]} * $SONNET_CACHE_READ_RATE) / 1000000" | bc)
    HAIKU_COST=$(echo "scale=6; (${TOTALS[haiku_in]} * $HAIKU_INPUT_RATE + ${TOTALS[haiku_out]} * $HAIKU_OUTPUT_RATE + ${TOTALS[haiku_cw_5m]} * $HAIKU_CACHE_WRITE_5M_RATE + ${TOTALS[haiku_cw_1h]} * $HAIKU_CACHE_WRITE_1H_RATE + ${TOTALS[haiku_cr]} * $HAIKU_CACHE_READ_RATE) / 1000000" | bc)

    WEB_SEARCH_COST=$(echo "scale=6; ${TOTALS[web_search]} * $WEB_SEARCH_COST_PER_1000 / 1000" | bc)

    OPUS_TOOL_OVERHEAD=$((TOTALS[opus_tool_use] * TOOL_USE_SYSTEM_PROMPT_TOKENS))
    SONNET_TOOL_OVERHEAD=$((TOTALS[sonnet_tool_use] * TOOL_USE_SYSTEM_PROMPT_TOKENS))
    HAIKU_TOOL_OVERHEAD=$((TOTALS[haiku_tool_use] * TOOL_USE_SYSTEM_PROMPT_TOKENS))

    OPUS_TOOL_COST=$(echo "scale=6; $OPUS_TOOL_OVERHEAD * $OPUS_INPUT_RATE / 1000000" | bc)
    SONNET_TOOL_COST=$(echo "scale=6; $SONNET_TOOL_OVERHEAD * $SONNET_INPUT_RATE / 1000000" | bc)
    HAIKU_TOOL_COST=$(echo "scale=6; $HAIKU_TOOL_OVERHEAD * $HAIKU_INPUT_RATE / 1000000" | bc)

    OPUS_COST=$(echo "scale=6; $OPUS_COST + $OPUS_TOOL_COST" | bc)
    SONNET_COST=$(echo "scale=6; $SONNET_COST + $SONNET_TOOL_COST" | bc)
    HAIKU_COST=$(echo "scale=6; $HAIKU_COST + $HAIKU_TOOL_COST" | bc)

    TOTAL_COST=$(echo "scale=6; $OPUS_COST + $SONNET_COST + $HAIKU_COST + $WEB_SEARCH_COST" | bc)
}

# calculate_usage_percent() {
#     local total_cost=$1
#     local estimated_limit=$2

#     printf "%.1f" "$(echo "scale=1; $total_cost * 100 / $estimated_limit" | bc)"
# }

calculate_credits() {
    # Credits formula: (input + cw_5m × cw_5m_coeff + cw_1h × cw_1h_coeff) × in_coeff + output × out_coeff + cr × cr_coeff × in_coeff
    # Cache reads appear to be FREE for subscriptions (0.1x is for API billing, not usage limits)
    # Compaction tokens are input tokens consumed when summarizing conversation history (added separately)

    # Calculate cache read credits separately for visibility
    OPUS_CR_CREDITS=$(echo "scale=2; ${TOTALS[opus_cr]} * $CACHE_READ_COEFF * $OPUS_INPUT_CREDIT_COEFF" | bc)
    SONNET_CR_CREDITS=$(echo "scale=2; ${TOTALS[sonnet_cr]} * $CACHE_READ_COEFF * $SONNET_INPUT_CREDIT_COEFF" | bc)
    HAIKU_CR_CREDITS=$(echo "scale=2; ${TOTALS[haiku_cr]} * $CACHE_READ_COEFF * $HAIKU_INPUT_CREDIT_COEFF" | bc)

    OPUS_CREDITS=$(echo "scale=2; (${TOTALS[opus_in]} + ${TOTALS[opus_cw_5m]} * $CACHE_WRITE_5M_COEFF + ${TOTALS[opus_cw_1h]} * $CACHE_WRITE_1H_COEFF) * $OPUS_INPUT_CREDIT_COEFF + ${TOTALS[opus_out]} * $OPUS_OUTPUT_CREDIT_COEFF + $OPUS_CR_CREDITS" | bc)
    SONNET_CREDITS=$(echo "scale=2; (${TOTALS[sonnet_in]} + ${TOTALS[sonnet_cw_5m]} * $CACHE_WRITE_5M_COEFF + ${TOTALS[sonnet_cw_1h]} * $CACHE_WRITE_1H_COEFF) * $SONNET_INPUT_CREDIT_COEFF + ${TOTALS[sonnet_out]} * $SONNET_OUTPUT_CREDIT_COEFF + $SONNET_CR_CREDITS" | bc)
    HAIKU_CREDITS=$(echo "scale=2; (${TOTALS[haiku_in]} + ${TOTALS[haiku_cw_5m]} * $CACHE_WRITE_5M_COEFF + ${TOTALS[haiku_cw_1h]} * $CACHE_WRITE_1H_COEFF) * $HAIKU_INPUT_CREDIT_COEFF + ${TOTALS[haiku_out]} * $HAIKU_OUTPUT_CREDIT_COEFF + $HAIKU_CR_CREDITS" | bc)

    # Per-model compaction credits
    OPUS_COMPACTION_CREDITS=$(echo "scale=2; ${TOTALS[opus_compaction]:-0} * $OPUS_COMPACTION_COEFF" | bc)
    SONNET_COMPACTION_CREDITS=$(echo "scale=2; ${TOTALS[sonnet_compaction]:-0} * $SONNET_COMPACTION_COEFF" | bc)
    HAIKU_COMPACTION_CREDITS=$(echo "scale=2; ${TOTALS[haiku_compaction]:-0} * $HAIKU_COMPACTION_COEFF" | bc)
    TOTAL_COMPACTION_CREDITS=$(echo "scale=2; $OPUS_COMPACTION_CREDITS + $SONNET_COMPACTION_CREDITS + $HAIKU_COMPACTION_CREDITS" | bc)

    # Sum raw credits, then apply calibration multiplier for unmeasured overhead
    RAW_CREDITS=$(echo "scale=2; $OPUS_CREDITS + $SONNET_CREDITS + $HAIKU_CREDITS + $TOTAL_COMPACTION_CREDITS" | bc)
    TOTAL_CREDITS=$(echo "scale=2; $RAW_CREDITS * $CALIBRATION_MULTIPLIER + ${TOTAL_CREDITS_OFFSET:-0}" | bc)
    CREDITS_PCT=$(echo "scale=1; $TOTAL_CREDITS * 100 / $SESSION_CREDIT_LIMIT" | bc)
}

# ============================================================================
# DISPLAY
# ============================================================================
display_model() {
    local name=$1 in_rate=$2 out_rate=$3 cw_5m_rate=$4 cw_1h_rate=$5 cr_rate=$6
    local in_val=${TOTALS[${name}_in]} out_val=${TOTALS[${name}_out]}
    local cw_5m_val=${TOTALS[${name}_cw_5m]} cw_1h_val=${TOTALS[${name}_cw_1h]} cr_val=${TOTALS[${name}_cr]}
    local msgs=${TOTALS[${name}_msgs]}
    local tool_use=${TOTALS[${name}_tool_use]}

    [ "$msgs" -eq 0 ] && return

    local cost_var="${name^^}_COST"
    local cost=${!cost_var}
    local tool_cost_var="${name^^}_TOOL_COST"
    local tool_cost=${!tool_cost_var}

    printf_nq "Model: claude-%s-4-5 (%d messages)\n" "$name" "$msgs"
    printf_nq "  Input:         %12d × \$%-5s = \$%.4f\n" "$in_val" "$in_rate" "$(echo "scale=4; $in_val * $in_rate / 1000000" | bc)"
    printf_nq "  Output:        %12d × \$%-5s = \$%.4f\n" "$out_val" "$out_rate" "$(echo "scale=4; $out_val * $out_rate / 1000000" | bc)"
    printf_nq "  Cache Write 5m:%12d × \$%-5s = \$%.4f\n" "$cw_5m_val" "$cw_5m_rate" "$(echo "scale=4; $cw_5m_val * $cw_5m_rate / 1000000" | bc)"
    printf_nq "  Cache Write 1h:%12d × \$%-5s = \$%.4f\n" "$cw_1h_val" "$cw_1h_rate" "$(echo "scale=4; $cw_1h_val * $cw_1h_rate / 1000000" | bc)"
    printf_nq "  Cache Read:    %12d × \$%-5s = \$%.4f\n" "$cr_val" "$cr_rate" "$(echo "scale=4; $cr_val * $cr_rate / 1000000" | bc)"
    [ "$tool_use" -gt 0 ] && printf_nq "  Tool Use:      %6d calls × %-6s = \$%.4f\n" "$tool_use" "${TOOL_USE_SYSTEM_PROMPT_TOKENS}tok" "$tool_cost"
    echo_nq "  ────────────────────────────────────────────"
    printf_nq "  Subtotal:                              \$%.2f\n\n" "$cost"
}

display_results() {
    # Fetch actual usage from API
    # Parse output into ACTUAL_USAGE and SECONDS_REMAINING
    local USAGE_API_CALL_RESPONSE
    read -r ACTUAL_USAGE SECONDS_REMAINING <<< "$(time_debug fetch_actual_usage)"
    USAGE_API_CALL_RESPONSE=$?

    if is_statusline_mode; then
        display_results_statusline "$CREDITS_PCT" "$ACTUAL_USAGE" "$TOTAL_CREDITS" "$TOTAL_COST" "$SECONDS_REMAINING"

        local display_results_statusline_ret=$?
        return $display_results_statusline_ret
    fi

    echo_nq "========================================"
    echo_nq "Claude Usage Estimate"
    echo_nq "========================================"
    echo_nq "Window start: $(date -d $WINDOW_START +'%Y-%m-%d %H:%M [%s]')"
    echo_nq "Source: $WINDOW_SOURCE"
    echo_nq ""
    echo_nq "--- Pricing Formulas (per 1M tokens) ---"
    printf_nq "Opus 4.5:   (input × \$%.2f) + (output × \$%.2f) + (cache_write_5m × \$%.2f) + (cache_write_1h × \$%.2f) + (cache_read × \$%.2f)\n" "$OPUS_INPUT_RATE" "$OPUS_OUTPUT_RATE" "$OPUS_CACHE_WRITE_5M_RATE" "$OPUS_CACHE_WRITE_1H_RATE" "$OPUS_CACHE_READ_RATE"
    printf_nq "Sonnet 4.5: (input × \$%.2f) + (output × \$%.2f) + (cache_write_5m × \$%.2f) + (cache_write_1h × \$%.2f) + (cache_read × \$%.2f)\n" "$SONNET_INPUT_RATE" "$SONNET_OUTPUT_RATE" "$SONNET_CACHE_WRITE_5M_RATE" "$SONNET_CACHE_WRITE_1H_RATE" "$SONNET_CACHE_READ_RATE"
    printf_nq "Haiku 4.5:  (input × \$%.2f) + (output × \$%.2f) + (cache_write_5m × \$%.2f) + (cache_write_1h × \$%.2f) + (cache_read × \$%.2f)\n" "$HAIKU_INPUT_RATE" "$HAIKU_OUTPUT_RATE" "$HAIKU_CACHE_WRITE_5M_RATE" "$HAIKU_CACHE_WRITE_1H_RATE" "$HAIKU_CACHE_READ_RATE"
    printf_nq "Tool Use:   (tool calls × %d tokens × (model input \$ rate))\n" "$TOOL_USE_SYSTEM_PROMPT_TOKENS"
    printf_nq "Web Search: \$%.2f per 1,000 WebSearch tool calls\n" "$WEB_SEARCH_COST_PER_1000"
    echo_nq ""
    echo_nq "--- Usage by Model ---"

    display_model "opus"   "$OPUS_INPUT_RATE"   "$OPUS_OUTPUT_RATE"   "$OPUS_CACHE_WRITE_5M_RATE"   "$OPUS_CACHE_WRITE_1H_RATE"   "$OPUS_CACHE_READ_RATE"
    display_model "sonnet" "$SONNET_INPUT_RATE" "$SONNET_OUTPUT_RATE" "$SONNET_CACHE_WRITE_5M_RATE" "$SONNET_CACHE_WRITE_1H_RATE" "$SONNET_CACHE_READ_RATE"
    display_model "haiku"  "$HAIKU_INPUT_RATE"  "$HAIKU_OUTPUT_RATE"  "$HAIKU_CACHE_WRITE_5M_RATE"  "$HAIKU_CACHE_WRITE_1H_RATE"  "$HAIKU_CACHE_READ_RATE"

    # Show compaction if any model has compaction tokens
    local total_compaction=$((${TOTALS[opus_compaction]:-0} + ${TOTALS[sonnet_compaction]:-0} + ${TOTALS[haiku_compaction]:-0}))
    if [ $total_compaction -gt 0 ]; then
        echo_nq "--- Compaction (by model) ---"
        [ ${TOTALS[opus_compaction]:-0} -gt 0 ] && printf_nq "  Opus:   %12d tokens × %.4f = %.0f credits\n" "${TOTALS[opus_compaction]}" "$OPUS_COMPACTION_COEFF" "$OPUS_COMPACTION_CREDITS"
        [ ${TOTALS[sonnet_compaction]:-0} -gt 0 ] && printf_nq "  Sonnet: %12d tokens × %.4f = %.0f credits\n" "${TOTALS[sonnet_compaction]}" "$SONNET_COMPACTION_COEFF" "$SONNET_COMPACTION_CREDITS"
        [ ${TOTALS[haiku_compaction]:-0} -gt 0 ] && printf_nq "  Haiku:  %12d tokens × %.4f = %.0f credits\n" "${TOTALS[haiku_compaction]}" "$HAIKU_COMPACTION_COEFF" "$HAIKU_COMPACTION_CREDITS"
        printf_nq "  Total:  %12d tokens           = %.0f credits\n" "$total_compaction" "$TOTAL_COMPACTION_CREDITS"
        echo_nq ""
    fi

    if [ ${TOTALS[web_search]} -gt 0 ]; then
        echo_nq "--- Web Search Usage ---"
        printf_nq "Total searches: %d × \$%.2f per 1,000 = \$%.4f\n" "${TOTALS[web_search]}" "$WEB_SEARCH_COST_PER_1000" "$WEB_SEARCH_COST"
        echo_nq ""
    fi

    echo_nq "--- Credits Estimate (based on she-llac.com/claude-limits) ---"
    echo_nq "Formula: (input + cache_writes) × in_coeff + output × out_coeff (output + cache reads)"
    echo_nq ""
    if [ ${TOTALS[opus_msgs]} -gt 0 ]; then
        printf_nq "Opus:   (%d + (%d × %.4f) + (%d × %.4f)) × %.4f + (%d × %.4f) + (%d × %.4f × %.4f) = %s credits\n" \
            "${TOTALS[opus_in]}" \
            "${TOTALS[opus_cw_5m]}" "$CACHE_WRITE_5M_COEFF" \
            "${TOTALS[opus_cw_1h]}" "$CACHE_WRITE_1H_COEFF" \
            "$OPUS_INPUT_CREDIT_COEFF" \
            "${TOTALS[opus_out]}" "$OPUS_OUTPUT_CREDIT_COEFF" \
            "${TOTALS[opus_cr]}" "$CACHE_READ_COEFF" "$OPUS_INPUT_CREDIT_COEFF" \
            "$(printf "%.0f" "$OPUS_CREDITS")"
        printf_nq "        (cache reads: %d tokens → %.0f credits)\n" "${TOTALS[opus_cr]}" "$OPUS_CR_CREDITS"
    fi
    if [ ${TOTALS[sonnet_msgs]} -gt 0 ]; then
        printf_nq "Sonnet: (%d + (%d × %.4f) + (%d × %.4f)) × %.4f + (%d × %.4f) + (%d × %.4f × %.4f) = %s credits\n" \
            "${TOTALS[sonnet_in]}" \
            "${TOTALS[sonnet_cw_5m]}" "$CACHE_WRITE_5M_COEFF" \
            "${TOTALS[sonnet_cw_1h]}" "$CACHE_WRITE_1H_COEFF" \
            "$SONNET_INPUT_CREDIT_COEFF" \
            "${TOTALS[sonnet_out]}" "$SONNET_OUTPUT_CREDIT_COEFF" \
            "${TOTALS[sonnet_cr]}" "$CACHE_READ_COEFF" "$SONNET_INPUT_CREDIT_COEFF" \
            "$(printf "%.0f" "$SONNET_CREDITS")"
        printf_nq "        (cache reads: %d tokens → %.0f credits)\n" "${TOTALS[sonnet_cr]}" "$SONNET_CR_CREDITS"
    fi
    if [ ${TOTALS[haiku_msgs]} -gt 0 ]; then
        printf_nq "Haiku:  (%d + (%d × %.4f) + (%d × %.4f)) × %.4f + (%d × %.4f) + (%d × %.4f × %.4f) = %s credits\n" \
            "${TOTALS[haiku_in]}" \
            "${TOTALS[haiku_cw_5m]}" "$CACHE_WRITE_5M_COEFF" \
            "${TOTALS[haiku_cw_1h]}" "$CACHE_WRITE_1H_COEFF" \
            "$HAIKU_INPUT_CREDIT_COEFF" \
            "${TOTALS[haiku_out]}" "$HAIKU_OUTPUT_CREDIT_COEFF" \
            "${TOTALS[haiku_cr]}" "$CACHE_READ_COEFF" "$HAIKU_INPUT_CREDIT_COEFF" \
            "$(printf "%.0f" "$HAIKU_CREDITS")"
        printf_nq "        (cache reads: %d tokens → %.0f credits)\n" "${TOTALS[haiku_cr]}" "$HAIKU_CR_CREDITS"
    fi
    # Per-model compaction credits in formula display
    local total_compaction_for_formula=$((${TOTALS[opus_compaction]:-0} + ${TOTALS[sonnet_compaction]:-0} + ${TOTALS[haiku_compaction]:-0}))
    if [ $total_compaction_for_formula -gt 0 ]; then
        echo_nq "Compaction:"
        [ ${TOTALS[opus_compaction]:-0} -gt 0 ] && printf_nq "  Opus:   %d × %.4f = %.0f credits\n" "${TOTALS[opus_compaction]}" "$OPUS_COMPACTION_COEFF" "$OPUS_COMPACTION_CREDITS"
        [ ${TOTALS[sonnet_compaction]:-0} -gt 0 ] && printf_nq "  Sonnet: %d × %.4f = %.0f credits\n" "${TOTALS[sonnet_compaction]}" "$SONNET_COMPACTION_COEFF" "$SONNET_COMPACTION_CREDITS"
        [ ${TOTALS[haiku_compaction]:-0} -gt 0 ] && printf_nq "  Haiku:  %d × %.4f = %.0f credits\n" "${TOTALS[haiku_compaction]}" "$HAIKU_COMPACTION_COEFF" "$HAIKU_COMPACTION_CREDITS"
        printf_nq "  Total: %.0f credits\n" "$TOTAL_COMPACTION_CREDITS"
    fi
    echo_nq "  ────────────────────────────────────────────"
    printf_nq "Final Credits: %.0f × %.4f + %.0f (muliplier + offset calibration) = %.0f\n" "$RAW_CREDITS" "$CALIBRATION_MULTIPLIER" "$TOTAL_CREDITS_OFFSET" "$TOTAL_CREDITS"
    echo_nq "  ────────────────────────────────────────────"
    printf_nq "Total Credits: %s / %s\n" "$(printf "%.0f" "$TOTAL_CREDITS")" "$(printf "%.0f" "$SESSION_CREDIT_LIMIT")"
    printf_nq "CREDITS USAGE: %.1f%% (%.0f / %.0f)\n" "$CREDITS_PCT" "$TOTAL_CREDITS" "$SESSION_CREDIT_LIMIT"
    printf_nq "%s%% (%.0f / %.0f) | API Cost: \$%.2f\n" "$CREDITS_PCT" "$TOTAL_CREDITS" "$SESSION_CREDIT_LIMIT" "$TOTAL_COST"
    echo_nq ""

    echo_nq "----------------------------------------"
    printf_nq "Total API Cost:  \$%.2f\n" "$TOTAL_COST"
    echo_nq ""

    # Display ACTUAL vs ESTIMATED comparison
    echo_nq "--- Actual vs Estimated Usage ---"
    if [ "$ENABLE_OAUTH_API" != true ]; then
        echo_nq ""
        echo_nq "  ⚠️  OAuth API disabled"
        echo_nq ""
        echo_nq "  Use --enable-oauth-api to compare actual vs estimated usage"
        echo_nq ""
    elif [ $USAGE_API_CALL_RESPONSE -eq 0 ] && [ -n "$ACTUAL_USAGE" ] && [ "$ACTUAL_USAGE" != "-" ]; then
        local diff
        diff=$(echo "scale=1; $CREDITS_PCT - $ACTUAL_USAGE" | bc)
        local abs_diff
        abs_diff=$(echo "$diff" | sed 's/^-//')
        local diff_sign="-"
        # Check sign (negative means underestimated, positive means overestimated)
        if (( $(echo "$diff > 0" | bc -l) )); then
            diff_sign="+"
        fi

        # Log data point on fresh API call with actual > 0
        if [ "$SECONDS_REMAINING" = "-1" ] && [ "$ACTUAL_USAGE" -gt 0 ] 2>/dev/null; then
            write_usage_data_log "$ACTUAL_USAGE"
        fi

        # Show cache status based on seconds_remaining
        # -2 = no actual usage, -1 = fresh API call, >= 0 = cached (seconds until expiry)
        if [ "$SECONDS_REMAINING" = "-1" ]; then
            echo_nq_checkmark "OAuth API call success (fresh data)"
        elif [ "$SECONDS_REMAINING" -ge 0 ] 2>/dev/null; then
            echo_nq "🔵 Read from cache ($SECONDS_REMAINING seconds until expiry)"
        fi

        printf_nq "ESTIMATED USAGE: %6.1f%%  (calculated from tokens)\n" "$CREDITS_PCT"
        printf_nq "ACTUAL USAGE:    %6.1f%%  (from Anthropic API)\n" "$ACTUAL_USAGE"
        printf_nq "DIFFERENCE:      %s  %s%%\n" "$diff_sign" "$abs_diff"
        echo_nq ""

        # Visual comparison
        local est_bar=$(build_comparison_bar "$CREDITS_PCT")
        local actual_bar=$(build_comparison_bar "$ACTUAL_USAGE")
        printf_nq "ESTIMATED: [%s] %.1f%%\n" "$est_bar" "$CREDITS_PCT"
        printf_nq "ACTUAL:    [%s] %.1f%%\n" "$actual_bar" "$ACTUAL_USAGE"
    else
        echo_nq ""
        echo_nq "  ❌ API call failed"
        echo_nq ""
        printf_nq "  Estimated usage: %6.1f%%\n" "$CREDITS_PCT"
        echo_nq ""
    fi
    echo_nq "========================================"
}

display_results_statusline() {
    local estimated_pct="$1"
    local actual_pct="$2"
    local total_credit_count="$3"
    local estimated_cost="$4"
    local seconds_remaining="$5"  # -2 = no actual usage available, -1 = fresh API call, >= 0 = cached (seconds until expiry)

    # Log data point on fresh API call with actual > 0
    if [ "$seconds_remaining" = "-1" ] && [ "$actual_pct" -gt 0 ] 2>/dev/null; then
        write_usage_data_log "$actual_pct"
    fi

    # Log summary line with **API** marker if fresh API call
    local api_marker=""
    if [ "$seconds_remaining" = "-1" ]; then
        api_marker=" **API**"
    fi

    local actual_display="$actual_pct"
    [ "$actual_pct" = "-" ] && actual_display="-"

    log_line "$(printf "[%s%%] (%s / %s) | API Cost: \$%s | Actual: %s%%%s" \
        "$estimated_pct" \
        "$(printf "%.0f" "$total_credit_count")" \
        "$(printf "%.0f" "$SESSION_CREDIT_LIMIT")" \
        "$estimated_cost" \
        "$actual_display" \
        "$api_marker")"

    # Output for statusline script
    if [ -n "$actual_pct" ]; then
        local diff=$(echo "scale=1; $estimated_pct - $actual_pct" | bc)
        echo_q "$(printf "%.1f" "$estimated_pct") $(printf "%.0f" "$total_credit_count") $(printf "%.0f" "$SESSION_CREDIT_LIMIT") $(printf "%.2f" "$estimated_cost") $(printf "%.1f" "$actual_pct") $(printf "%.1f" "$diff") $seconds_remaining"
    else
        echo_q "$(printf "%.1f" "$estimated_pct") $(printf "%.0f" "$total_credit_count") $(printf "%.0f" "$SESSION_CREDIT_LIMIT") $(printf "%.2f" "$estimated_cost") - - -2"
    fi
}

# Helper function for visual comparison bars
build_comparison_bar() {
    local pct=$1
    local filled=$(echo "$pct / 10" | bc)
    local max=10
    if [ "$filled" -gt $max ]; then filled=$max; fi
    if [ "$filled" -lt 0 ]; then filled=0; fi
    local empty=$((max - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

# ============================================================================
# HISTORICAL DATA LOGGING
# ============================================================================

USAGE_DATA_LOG_HEADER="timestamp|session_start_epoch|reset_epoch|elapsed_pct|actual_pct|estimated_pct|total_credits|estimated_cost|total_cost_with_websearch|opus_input|opus_output|opus_cw_5m|opus_cw_1h|opus_cr|opus_msgs|opus_compaction|sonnet_input|sonnet_output|sonnet_cw_5m|sonnet_cw_1h|sonnet_cr|sonnet_msgs|sonnet_compaction|haiku_input|haiku_output|haiku_cw_5m|haiku_cw_1h|haiku_cr|haiku_msgs|haiku_compaction|opus_tool_use|sonnet_tool_use|haiku_tool_use|web_search_count|session_credit_limit|calibration_multiplier|cw_5m_coeff|cw_1h_coeff|cr_coeff|credits_offset"

# Write a data row to the usage data log.
# Only called when a fresh API call returns actual_pct > 0.
write_usage_data_log() {
    local actual_pct="$1"

    # Ensure header exists
    if [ ! -f "$USAGE_DATA_LOG" ]; then
        echo "# $USAGE_DATA_LOG_HEADER" > "$USAGE_DATA_LOG"
    fi

    # Calculate elapsed % of session window
    local now_epoch=$(date +%s)
    local elapsed_seconds=$((now_epoch - WINDOW_START_EPOCH))
    local elapsed_pct
    elapsed_pct=$(echo "scale=1; $elapsed_seconds * 100 / $SESSION_TIME_WINDOW_SIZE" | bc)

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local total_cost_with_ws
    total_cost_with_ws=$(echo "scale=2; $TOTAL_COST" | bc)

    printf '%s|%s|%s|%s|%s|%s|%.0f|%.2f|%.2f|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%.0f|%s|%s|%s|%s|%s\n' \
        "$ts" \
        "$WINDOW_START_EPOCH" \
        "$RESET_TIME" \
        "$elapsed_pct" \
        "$actual_pct" \
        "$CREDITS_PCT" \
        "$TOTAL_CREDITS" \
        "$TOTAL_COST" \
        "$total_cost_with_ws" \
        "${TOTALS[opus_in]}" \
        "${TOTALS[opus_out]}" \
        "${TOTALS[opus_cw_5m]}" \
        "${TOTALS[opus_cw_1h]}" \
        "${TOTALS[opus_cr]}" \
        "${TOTALS[opus_msgs]}" \
        "${TOTALS[opus_compaction]:-0}" \
        "${TOTALS[sonnet_in]}" \
        "${TOTALS[sonnet_out]}" \
        "${TOTALS[sonnet_cw_5m]}" \
        "${TOTALS[sonnet_cw_1h]}" \
        "${TOTALS[sonnet_cr]}" \
        "${TOTALS[sonnet_msgs]}" \
        "${TOTALS[sonnet_compaction]:-0}" \
        "${TOTALS[haiku_in]}" \
        "${TOTALS[haiku_out]}" \
        "${TOTALS[haiku_cw_5m]}" \
        "${TOTALS[haiku_cw_1h]}" \
        "${TOTALS[haiku_cr]}" \
        "${TOTALS[haiku_msgs]}" \
        "${TOTALS[haiku_compaction]:-0}" \
        "${TOTALS[opus_tool_use]}" \
        "${TOTALS[sonnet_tool_use]}" \
        "${TOTALS[haiku_tool_use]}" \
        "${TOTALS[web_search]}" \
        "$SESSION_CREDIT_LIMIT" \
        "$CALIBRATION_MULTIPLIER" \
        "$CACHE_WRITE_5M_COEFF" \
        "$CACHE_WRITE_1H_COEFF" \
        "$CACHE_READ_COEFF" \
        "$TOTAL_CREDITS_OFFSET" \
        >> "$USAGE_DATA_LOG"

    print_debug "Wrote usage data log entry (actual=$actual_pct%, estimated=$CREDITS_PCT%)"
}

# ============================================================================
# MAIN
# ============================================================================

# Write log separator for this run (skip in statusline mode to reduce log spam)
if ! is_statusline_mode; then
    write_log_separator "$@"
fi

# Determine session window
determine_window_start
echo_nq "Starting full calculation..."

# Initialize totals
time_debug init_totals

# Validate that WINDOW_START_EPOCH is set and valid
if [ -z "$WINDOW_START_EPOCH" ] || [ "$WINDOW_START_EPOCH" -lt 1000000000 ]; then
    echo "ERROR: WINDOW_START_EPOCH is not set or invalid: '$WINDOW_START_EPOCH'" >&2
    print_debug "WINDOW_START_EPOCH=$WINDOW_START_EPOCH (invalid!)"
    exit 1
fi
print_debug "WINDOW_START_EPOCH validated: $WINDOW_START_EPOCH"

# Subtract 1 so the strictly-greater-than filter includes messages at exactly session_start_epoch
from_epoch=$((WINDOW_START_EPOCH - 1))
LAST_TIMESTAMP_EPOCH=$from_epoch

print_debug "Using from_epoch=$from_epoch for full calculation"
time_debug find_jsonl_files "$WINDOW_START_EPOCH"

# If no files found, show zero usage
if [ -z "$JSONL_FILES" ]; then
    echo_nq "No JSONL files to process."
    time_debug calculate_costs
    time_debug calculate_credits
    time_debug display_results
    exit 0
fi

time_debug process_jsonl "$from_epoch"
time_debug accumulate_data
time_debug calculate_costs
time_debug calculate_credits
time_debug save_cache
time_debug display_results
