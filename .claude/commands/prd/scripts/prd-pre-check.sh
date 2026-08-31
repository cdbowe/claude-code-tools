#!/bin/bash
# PRD Pre-Check — fast script-based validation per worker before review.
# Runs in seconds, no tokens. Catches mechanical failures before reviewer agents spawn.
#
# Usage: prd-pre-check.sh <agentId> <worktreePath> <branch> <resultJsonPath>
# Output: /tmp/.prd_precheck_{agentId}.json

AGENT_ID="$1"
WORKTREE_PATH="$2"
BRANCH="$3"
RESULT_JSON_PATH="$4"
OUTPUT_FILE="/tmp/.prd_precheck_${AGENT_ID}.json"

if [ -z "${WORKSPACE_DIR:-}" ]; then
    echo '{"status":"error","error":"WORKSPACE_DIR environment variable is not set"}'
    exit 1
fi

RUN_CAPTURE="${WORKSPACE_DIR}/.claude/commands/scripts/run-and-capture.sh"
WORKSPACE_BUILD="/tmp/claude-workspace/scripts/pre-check-build.sh"

issues="[]"
passed=true
requires_user_approval=false
migration_files="[]"

add_issue() {
    local severity="$1"
    local message="$2"
    issues=$(echo "$issues" | jq --arg s "$severity" --arg m "$message" '. + [{"severity": $s, "message": $m}]')
}

# --- Validate inputs ---

if [ -z "$AGENT_ID" ] || [ -z "$WORKTREE_PATH" ] || [ -z "$BRANCH" ] || [ -z "$RESULT_JSON_PATH" ]; then
    jq -n '{agentId: "unknown", passed: false, requiresUserApproval: false, migrationFiles: [], issues: [{"severity": "error", "message": "Missing arguments. Usage: prd-pre-check.sh <agentId> <worktreePath> <branch> <resultJsonPath>"}]}' > "$OUTPUT_FILE"
    cat "$OUTPUT_FILE"
    exit 0
fi

# --- Check worker result JSON ---

if [ ! -f "$RESULT_JSON_PATH" ]; then
    add_issue "error" "Worker result file not found: $RESULT_JSON_PATH"
    passed=false
else
    if ! jq empty "$RESULT_JSON_PATH" 2>/dev/null; then
        add_issue "error" "Worker result is not valid JSON"
        passed=false
    else
        worker_status=$(jq -r '.status // "unknown"' "$RESULT_JSON_PATH")

        if [ "$worker_status" = "blocked" ]; then
            jq -n --arg aid "$AGENT_ID" '{agentId: $aid, passed: false, requiresUserApproval: false, migrationFiles: [], issues: [{"severity": "info", "message": "Worker already blocked — skipping pre-check"}]}' > "$OUTPUT_FILE"
            cat "$OUTPUT_FILE"
            exit 0
        fi

        required_fields=("agentId" "status" "taskIds" "model")
        for field in "${required_fields[@]}"; do
            val=$(jq -r ".$field // empty" "$RESULT_JSON_PATH")
            if [ -z "$val" ]; then
                add_issue "error" "Worker result missing required field: $field"
                passed=false
            fi
        done
    fi
fi

# --- Check worktree exists ---

if [ ! -d "$WORKTREE_PATH" ]; then
    add_issue "error" "Worktree directory not found: $WORKTREE_PATH"
    passed=false
fi

# --- Check modified/created files exist in worktree ---

if [ "$passed" = true ] && [ -f "$RESULT_JSON_PATH" ]; then
    for file_field in "filesModified" "filesCreated"; do
        files=$(jq -r ".${file_field} // [] | .[]" "$RESULT_JSON_PATH" 2>/dev/null)
        for filepath in $files; do
            if [ -n "$filepath" ] && [ ! -f "${WORKTREE_PATH}/${filepath}" ]; then
                add_issue "warning" "Worker reported ${file_field} file not found in worktree: $filepath"
            fi
        done
    done
fi

# --- DB migration detection ---

if [ "$passed" = true ] && [ -d "$WORKTREE_PATH" ]; then
    git_dir="${WORKSPACE_DIR}/.git"
    if [ -d "$git_dir" ] || [ -f "$git_dir" ]; then
        changed_files=$(cd "$WORKTREE_PATH" && git diff main..."$BRANCH" --name-only 2>/dev/null || true)

        if [ -n "$changed_files" ]; then
            detected_migrations=$(echo "$changed_files" | grep -iE "(Migrations/|migrations/|\.migration\.|/schema/.*\.sql$|/migrate/)" || true)

            if [ -n "$detected_migrations" ]; then
                requires_user_approval=true
                migration_files=$(echo "$detected_migrations" | jq -R -s 'split("\n") | map(select(length > 0))')
                add_issue "migration" "DB migration files detected — requires manual review before merge"
            fi
        fi
    fi
fi

# --- Optional workspace build command ---

if [ "$passed" = true ] && [ -x "$WORKSPACE_BUILD" ]; then
    build_output=$(bash "$RUN_CAPTURE" "cd '$WORKTREE_PATH' && bash '$WORKSPACE_BUILD'" 50 120 2>&1)
    if echo "$build_output" | grep -q "Status: FAILED\|Status: TIMEOUT"; then
        add_issue "error" "Workspace build check failed in worktree"
        passed=false
    fi
fi

# --- Write output ---

jq -n \
    --arg aid "$AGENT_ID" \
    --argjson passed "$passed" \
    --argjson rua "$requires_user_approval" \
    --argjson mf "$migration_files" \
    --argjson issues "$issues" \
    '{
        agentId: $aid,
        passed: $passed,
        requiresUserApproval: $rua,
        migrationFiles: $mf,
        issues: $issues
    }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
