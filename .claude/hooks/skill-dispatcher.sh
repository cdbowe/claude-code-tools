#!/bin/bash

# PreToolUse hook: Dispatcher for skill preprocessing
#
# Routes Skill invocations to the appropriate parse-args.sh script
# based on skill name. Unknown skills pass through unchanged.
#
# Supported skills:
#   - prd        -> commands/prd/scripts/parse-args.sh
#   - debug-e2e  -> commands/debug-e2e/scripts/parse-args.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DIR="$SCRIPT_DIR/../commands"

# Read hook input from stdin
INPUT=$(cat)

# Extract skill name and arguments
SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')
ARGUMENTS=$(echo "$INPUT" | jq -r '.tool_input.args // empty')

# Route to appropriate parser based on skill name
case "$SKILL_NAME" in
    prd)
        PARSE_SCRIPT="$COMMANDS_DIR/prd/scripts/parse-args.sh"
        ;;
    debug-e2e)
        PARSE_SCRIPT="$COMMANDS_DIR/debug-e2e/scripts/parse-args.sh"
        ;;
    *)
        # Unknown skill - pass through unchanged
        exit 0
        ;;
esac

# Check if parser script exists
if [[ ! -f "$PARSE_SCRIPT" ]]; then
    # Parser not found - pass through unchanged
    exit 0
fi

# Run the parser on the arguments
PARSED_OUTPUT=$(printf '%s' "$ARGUMENTS" | bash "$PARSE_SCRIPT")

# Escape the parsed output for JSON (handle newlines)
ESCAPED_OUTPUT=$(echo "$PARSED_OUTPUT" | jq -Rs '.')

# Return the parsed output as the new arguments
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "updatedInput": {
      "args": $ESCAPED_OUTPUT
    }
  }
}
EOF
exit 0
