#!/bin/bash
# PRD Display Script - Formats JSON output to markdown
# Usage: prd-display.sh <type> [json_file]
# Types: plan, plan-infra, plan-unblock, gen, edit, build-result, infra-result, unblock-result, review, review-all

set -e

TYPE="${1:-}"
JSON_FILE="${2:-}"

if [ -z "$TYPE" ]; then
    echo "Usage: prd-display.sh <type> [json_file]"
    echo "Types: plan, plan-infra, plan-unblock, gen, edit, build-result, infra-result, unblock-result"
    exit 1
fi

# Read JSON from file or stdin
if [ -n "$JSON_FILE" ] && [ -f "$JSON_FILE" ]; then
    JSON=$(cat "$JSON_FILE")
else
    JSON=$(cat)
fi

# Validate JSON
if [ -z "$JSON" ]; then
    echo "Error: No JSON input provided. Pass a file path or pipe JSON via stdin."
    exit 1
fi

if ! echo "$JSON" | jq -e '.' > /dev/null 2>&1; then
    echo "Error: Invalid JSON input"
    exit 1
fi

#------------------------------------------------------------------------------
# Display functions
#------------------------------------------------------------------------------

display_plan() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local phase=$(echo "$json" | jq -r '.phase // "N/A"')
    local phase_name=$(echo "$json" | jq -r '.phaseName // "Phase"')
    local total_tasks=$(echo "$json" | jq -r '.totalTasks // 0')

    echo "## Execution Plan for Phase $phase: $phase_name"
    echo ""

    local wave_count=$(echo "$json" | jq '.waves | length // 0')
    local worktree_waves=$(echo "$json" | jq '[.waves[] | select(.useWorktrees == true)] | length // 0')
    wave_count=${wave_count:-0}
    worktree_waves=${worktree_waves:-0}

    echo "**Tasks**: $total_tasks | **Waves**: $wave_count | **Worktree Waves**: $worktree_waves"
    echo ""

    # Display each wave
    for ((w=0; w<wave_count; w++)); do
        local wave=$(echo "$json" | jq ".waves[$w]")
        local wave_id=$(echo "$wave" | jq -r '.waveId')
        local use_worktrees=$(echo "$wave" | jq -r '.useWorktrees')
        local task_count=$(echo "$wave" | jq '.tasks | length')

        local wt_label=""
        if [ "$use_worktrees" = "true" ]; then
            wt_label=" 🌿 (worktrees)"
        fi

        echo "### Wave $wave_id$wt_label ($task_count tasks)"
        echo ""
        echo "| Task | Name | Type | Model | Files |"
        echo "|------|------|------|-------|-------|"
        echo "$wave" | jq -r '.tasks[] | "| \(.taskId) | \(.taskName) | \(.taskType) | \(.model) | \(.targetFiles | join(", ") | .[0:40]) |"'
        echo ""
    done

    echo "**Execution Strategy**:"
    echo "- Waves execute sequentially, in order (0, 1, 2, ...)"
    echo "- Tasks within each wave run in parallel"
    if [ "$worktree_waves" -gt 0 ]; then
        echo "- Worktree waves: each agent works in isolated git worktree, merged after wave completes"
    fi
    echo ""
    # Display skipped tasks if any
    local skipped_count=$(echo "$json" | jq '.skippedCount // 0')
    skipped_count=${skipped_count:-0}

    if [ "$skipped_count" -gt 0 ]; then
        echo "### Skipped Tasks ($skipped_count)"
        echo ""
        echo "The following tasks were skipped due to blocked/incomplete dependencies:"
        echo ""
        echo "| Task | Name | Reason |"
        echo "|------|------|--------|"
        echo "$json" | jq -r '.skippedTasks[] | "| \(.taskId) | \(.taskName) | \(.reason) |"'
        echo ""
        echo "**To retry skipped tasks**: Fix the blocked dependencies, then run \`/prd build\` again."
        echo ""
    fi

    echo "**Next Steps**:"
    if [ "$skipped_count" -gt 0 ]; then
        echo "- Run \`/prd build\` to execute $total_tasks eligible tasks"
        echo "- $skipped_count tasks are skipped until their dependencies are resolved"
    else
        echo "- Run \`/prd build\` to execute with subagents"
    fi
}

display_plan_infra() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local total=$(echo "$json" | jq -r '.totalTasks // 0')
    local complete=$(echo "$json" | jq -r '.completeTasks // 0')
    local remaining=$(echo "$json" | jq -r '.remainingTasks // 0')

    echo "## Infrastructure Execution Plan"
    echo ""
    echo "**Summary**: $remaining/$total tasks remaining ($complete already complete)"
    echo ""

    local wave_count=$(echo "$json" | jq '.waves | length // 0')
    local worktree_waves=$(echo "$json" | jq '[.waves[] | select(.useWorktrees == true)] | length // 0')
    wave_count=${wave_count:-0}
    worktree_waves=${worktree_waves:-0}

    echo "**Waves**: $wave_count | **Worktree Waves**: $worktree_waves"
    echo ""

    # Display each wave
    for ((w=0; w<wave_count; w++)); do
        local wave=$(echo "$json" | jq ".waves[$w]")
        local wave_id=$(echo "$wave" | jq -r '.waveId')
        local use_worktrees=$(echo "$wave" | jq -r '.useWorktrees')
        local task_count=$(echo "$wave" | jq '.tasks | length // 0')

        local wt_label=""
        if [ "$use_worktrees" = "true" ]; then
            wt_label=" 🌿 (worktrees)"
        fi

        echo "### Wave $wave_id$wt_label ($task_count tasks)"
        echo ""
        echo "| Task | Name | Category | Model |"
        echo "|------|------|----------|-------|"
        echo "$wave" | jq -r '.tasks[] | "| \(.taskId) | \(.taskName) | \(.taskCategory // "-") | \(.model) |"'
        echo ""
    done

    echo "**Execution Strategy**:"
    echo "- Waves execute in order (0, 1, 2, ...)"
    echo "- Tasks within each wave run in parallel"
    if [ "$worktree_waves" -gt 0 ]; then
        echo "- Worktree waves: each agent works in isolated git worktree, merged after wave completes"
    fi
    echo ""
    echo "**Next Steps**:"
    echo "- Run \`/prd build-infra\` to execute with subagents"
}

display_gen() {
    local json="$1"
    local status=$(echo "$json" | jq -r '.status // "unknown"')
    local prd_name=$(echo "$json" | jq -r '.prdName // "Unknown"')
    local directory=$(echo "$json" | jq -r '.directory // ""')
    local task_count=$(echo "$json" | jq -r '.taskCount // 0')

    if [ "$status" = "error" ]; then
        echo "## PRD Generation Failed"
        echo ""
        echo "**Error**: $(echo "$json" | jq -r '.error // "Unknown error"')"
        return
    fi

    echo "## PRD Generated: $prd_name"
    echo ""
    echo "**Directory**: \`$directory\`"
    echo "**Tasks**: $task_count tasks"
    echo ""

    echo "### Files Created"
    echo ""
    echo "$json" | jq -r '.files[]? | "- `\(.)`"'
    echo ""

    echo "**Next Steps** (PRD auto-loaded):"
    echo "- \`/prd read <phase>\` to load a specific phase"
    echo "- \`/prd build 0\` for infrastructure tasks"
    echo "- \`/prd build <N>\` to build any phase directly"
}

display_edit() {
    local json="$1"
    local status=$(echo "$json" | jq -r '.status // "unknown"')
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')

    if [ "$status" = "error" ]; then
        echo "## Edit Failed"
        echo ""
        echo "**PRD**: $prd"
        echo "**Error**: $(echo "$json" | jq -r '.error // "Unknown error"')"
        return
    fi

    local operation=$(echo "$json" | jq -r '.operation // "update"')
    local summary=$(echo "$json" | jq -r '.summary // ""')

    echo "## PRD Updated: $prd"
    echo ""
    echo "**Operation**: $operation"
    echo "**Summary**: $summary"
    echo ""

    # Phase info for add_phase operation
    local phase_num=$(echo "$json" | jq -r '.phaseNumber // empty')
    local phase_name=$(echo "$json" | jq -r '.phaseName // empty')
    if [ -n "$phase_num" ] && [ -n "$phase_name" ]; then
        echo "**Phase**: $phase_num - $phase_name"
        local tasks_added=$(echo "$json" | jq -r '.tasksAdded // 0')
        if [ "$tasks_added" -gt 0 ]; then
            echo "**Tasks Added**: $tasks_added"
        fi
        echo ""
    fi

    # Files created/modified
    local created=$(echo "$json" | jq -r '.filesCreated | length')
    local modified=$(echo "$json" | jq -r '.filesModified | length')
    if [ "$created" -gt 0 ] || [ "$modified" -gt 0 ]; then
        echo "### Files"
        echo ""
        echo "$json" | jq -r '.filesCreated[]? | "- \(.) (created)"'
        echo "$json" | jq -r '.filesModified[]? | "- \(.) (modified)"'
        echo ""
    fi

    # Changes detail table
    local changes_count=$(echo "$json" | jq '.changes | length // 0')
    if [ "$changes_count" -gt 0 ]; then
        echo "### Changes Applied"
        echo ""
        echo "| File | Type | Detail |"
        echo "|------|------|--------|"
        echo "$json" | jq -r '.changes[] | "| \(.file) | \(.type) | \(.detail) |"'
        echo ""
    fi
}

display_build_result() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local phase=$(echo "$json" | jq -r '.phase // "N/A"')
    local phase_name=$(echo "$json" | jq -r '.phaseName // "Phase"')

    echo "## Build Complete - Phase $phase: $phase_name"
    echo ""

    # Task status summary - dynamic from statusCounts
    echo "### Status Summary"
    echo ""
    echo "| Status | Count |"
    echo "|--------|-------|"
    # Display all status counts from the statusCounts object (dynamic keys)
    echo "$json" | jq -r '.statusCounts // {} | to_entries | sort_by(.key) | .[] | "| \(.key) | \(.value) |"'
    echo ""

    # Results table
    echo "### Results"
    echo ""
    echo "| Agent | Tasks | Status | Model | Files | Notes |"
    echo "|-------|-------|--------|-------|-------|-------|"
    echo "$json" | jq -r '.results[] | "| \(.agentId) | \(.taskIds | join(", ")) | \(if .status == "complete" then "Complete" else "Blocked" end) | \(.model // "-") | \(.filesCreated | length) created, \(.filesModified | length) modified | \(.notes // "-") |"'
    echo ""

    # Progress
    local phase_complete=$(echo "$json" | jq -r '.phaseProgress.complete // 0')
    local phase_total=$(echo "$json" | jq -r '.phaseProgress.total // 0')
    local phase_pct=$(echo "$json" | jq -r '.phaseProgress.pct // 0')
    local overall_complete=$(echo "$json" | jq -r '.overallProgress.complete // 0')
    local overall_total=$(echo "$json" | jq -r '.overallProgress.total // 0')
    local overall_pct=$(echo "$json" | jq -r '.overallProgress.pct // 0')

    echo "### Updated Progress"
    echo "- **Phase $phase**: $phase_complete/$phase_total tasks complete ($phase_pct%)"
    echo "- **Overall PRD**: $overall_complete/$overall_total tasks complete ($overall_pct%)"
    echo ""

    # Files
    local created=$(echo "$json" | jq -r '.filesCreated | length // 0')
    local modified=$(echo "$json" | jq -r '.filesModified | length // 0')
    created=${created:-0}
    modified=${modified:-0}
    if [ "$created" -gt 0 ] || [ "$modified" -gt 0 ]; then
        echo "### Files Created/Modified"
        echo "$json" | jq -r '.filesCreated[]? | "- \(.) (created)"'
        echo "$json" | jq -r '.filesModified[]? | "- \(.) (modified)"'
        echo ""
    fi

    # TypeScript check
    local ts_touched=$(echo "$json" | jq -r '.typescriptFilesTouched // false')
    echo "### TypeScript Compilation"
    if [ "$ts_touched" = "true" ]; then
        echo "- TypeScript files were created/modified. Run build to verify."
    else
        echo "- Skipped (no TS files touched)"
    fi
    echo ""

    # postValidation warnings
    local pv_warning_count=$(echo "$json" | jq -r '.postValidationWarningCount // 0')
    pv_warning_count=${pv_warning_count:-0}
    if [ "$pv_warning_count" -gt 0 ]; then
        echo "### ⚠️ postValidation Warnings"
        echo ""
        echo "**$pv_warning_count task(s) reported complete without postValidation confirmation. Downgraded to Blocked.**"
        echo ""
        echo "| Agent | Task | Reason |"
        echo "|-------|------|--------|"
        echo "$json" | jq -r '.postValidationWarnings[]? | "| \(.agentId) | \(.taskId) | \(.reason) |"'
        echo ""
    fi

    # Skipped tasks due to blocked dependencies
    local skipped=$(echo "$json" | jq -r '.skipped // 0')
    skipped=${skipped:-0}
    if [ "$skipped" -gt 0 ]; then
        echo "### Skipped Tasks ($skipped)"
        echo ""
        echo "The following tasks were skipped due to blocked dependencies:"
        echo ""
        echo "| Task | Blocked Dependency | Dependency Status |"
        echo "|------|-------------------|-------------------|"
        echo "$json" | jq -r '.skippedTasks[]? | "| \(.taskId) | \(.blockedDep) | \(.depStatus) |"'
        echo ""
    fi

    # Next steps
    local blocked=$(echo "$json" | jq -r '.blocked // 0')
    blocked=${blocked:-0}
    phase_complete=${phase_complete:-0}
    phase_total=${phase_total:-0}
    echo "### Next Steps"
    if [ "$pv_warning_count" -gt 0 ]; then
        echo "- ⚠️ **$pv_warning_count task(s) need postValidation** - workers must run tests and report \`postValidationPassed\`"
    fi
    if [ "$blocked" -gt 0 ]; then
        echo "- Review $blocked blocked task(s)"
    fi
    if [ "$skipped" -gt 0 ]; then
        echo "- $skipped task(s) skipped due to blocked dependencies - fix blocked tasks first"
    fi
    if [ "$blocked" -gt 0 ] || [ "$skipped" -gt 0 ]; then
        echo "- Run \`/prd plan-unblock\` to investigate and generate resolution plan"
    fi
    if [ "$phase_complete" -lt "$phase_total" ]; then
        echo "- Run \`/prd plan\` and \`/prd build\` for remaining tasks"
    else
        echo "- Run \`/prd read <next_phase>\` to continue"
    fi
}

display_infra_result() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')

    echo "## Infrastructure Build Complete"
    echo ""

    # Results table
    echo "### Results"
    echo ""
    echo "| Agent | Tasks | Status | Model | Notes |"
    echo "|-------|-------|--------|-------|-------|"
    echo "$json" | jq -r '.results[] | "| \(.agentId) | \(.taskIds | join(", ")) | \(if .status == "complete" then "Complete" else "Blocked" end) | \(.model // "-") | \(.notes // "-") |"'
    echo ""

    # Progress
    local infra_complete=$(echo "$json" | jq -r '.infraProgress.complete // 0')
    local infra_total=$(echo "$json" | jq -r '.infraProgress.total // 0')
    local infra_pct=$(echo "$json" | jq -r '.infraProgress.percentage // .infraProgress.pct // 0')

    echo "### Updated Progress"
    echo "- **Infrastructure**: $infra_complete/$infra_total tasks complete ($infra_pct%)"
    echo ""

    # Files
    local created=$(echo "$json" | jq -r '.filesCreated | length // 0')
    local modified=$(echo "$json" | jq -r '.filesModified | length // 0')
    created=${created:-0}
    modified=${modified:-0}
    if [ "$created" -gt 0 ] || [ "$modified" -gt 0 ]; then
        echo "### Files Created/Modified"
        echo "$json" | jq -r '.filesCreated[]? | "- \(.) (created)"'
        echo "$json" | jq -r '.filesModified[]? | "- \(.) (modified)"'
        echo ""
    fi

    # Next steps
    infra_complete=${infra_complete:-0}
    infra_total=${infra_total:-0}
    echo "### Next Steps"
    if [ "$infra_complete" -lt "$infra_total" ]; then
        echo "- Run \`/prd plan-infra\` again for remaining tasks"
    else
        echo "- Infrastructure complete! Run \`/prd read <phase>\` to start implementation"
    fi
}

display_plan_unblock() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local phase=$(echo "$json" | jq -r '.phase // "N/A"')
    local phase_name=$(echo "$json" | jq -r '.phaseName // "Phase"')

    echo "## Unblock Plan for Phase $phase: $phase_name"
    echo ""

    # Blocked tasks summary
    echo "### Blocked Tasks"
    echo ""
    local blocked_count=$(echo "$json" | jq '.blockedTasks | length // 0')
    blocked_count=${blocked_count:-0}
    if [ "$blocked_count" -gt 0 ]; then
        echo "| Task | Name | Block Reason |"
        echo "|------|------|--------------|"
        echo "$json" | jq -r '.blockedTasks[] | "| \(.taskId) | \(.taskName) | \(.blockReason) |"'
    else
        echo "None."
    fi
    echo ""

    # resolutionTasks schema: tasks with empty dependsOn = parallel, non-empty = sequential
    local par_count=$(echo "$json" | jq '[.resolutionTasks[]? | select(.dependsOn | length == 0)] | length')
    local seq_count=$(echo "$json" | jq '[.resolutionTasks[]? | select(.dependsOn | length > 0)] | length')
    par_count=${par_count:-0}
    seq_count=${seq_count:-0}

    # Step 1: Parallel resolution tasks (run first, concurrently)
    echo "### Step 1: Parallel Resolution ($par_count concurrent)"
    echo ""
    if [ "$par_count" -gt 0 ]; then
        echo "| Task | Type | Model | Resolution |"
        echo "|------|------|-------|------------|"
        echo "$json" | jq -r '.resolutionTasks[]? | select(.dependsOn | length == 0) | "| \(.taskId) | \(.taskType) | \(.model) | \(.resolution) |"'
    else
        echo "None."
    fi
    echo ""

    # Step 2: Sequential resolution tasks (run after parallel complete)
    echo "### Step 2: Sequential Resolution (after parallel complete)"
    echo ""
    if [ "$seq_count" -gt 0 ]; then
        echo "| Task | Type | Model | Depends On | Resolution |"
        echo "|------|------|-------|------------|------------|"
        echo "$json" | jq -r '.resolutionTasks[]? | select(.dependsOn | length > 0) | "| \(.taskId) | \(.taskType) | \(.model) | \(.dependsOn | join(", ")) | \(.resolution) |"'
    else
        echo "None."
    fi
    echo ""

    local total_tasks=$(echo "$json" | jq '.resolutionTasks | length // 0')
    total_tasks=${total_tasks:-0}
    echo "**Total**: $blocked_count blocked tasks, $par_count parallel + $seq_count sequential resolution tasks ($total_tasks total)"
    echo ""
    echo "**Next Steps**:"
    echo "- Run \`/prd unblock\` to execute resolution tasks"
}

display_unblock_result() {
    local json="$1"
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local phase=$(echo "$json" | jq -r '.phase // "N/A"')
    local phase_name=$(echo "$json" | jq -r '.phaseName // "Phase"')

    echo "## Unblock Complete - Phase $phase: $phase_name"
    echo ""

    # Results table
    echo "### Agent Results"
    echo ""
    echo "| Agent | Tasks | Status | Model | Files | Notes |"
    echo "|-------|-------|--------|-------|-------|-------|"
    echo "$json" | jq -r '.results[] | "| \(.agentId) | \(.taskIds | join(", ")) | \(if .status == "complete" then "Complete" else "Blocked" end) | \(.model // "-") | \(.filesCreated | length) created, \(.filesModified | length) modified | \(.notes // "-") |"'
    echo ""

    # Resolved tasks
    local resolved_count=$(echo "$json" | jq -r '.resolvedCount // 0')
    local still_blocked_count=$(echo "$json" | jq -r '.stillBlockedCount // 0')
    still_blocked_count=${still_blocked_count:-0}

    echo "### Task Resolution"
    echo "- **Resolved**: $resolved_count task(s) marked Complete"
    if [ "$still_blocked_count" -gt 0 ]; then
        echo "- **Still blocked**: $still_blocked_count task(s)"
        echo "$json" | jq -r '.stillBlockedTasks[]? | "  - \(.)"'
    fi
    echo ""

    # Progress
    local phase_complete=$(echo "$json" | jq -r '.phaseProgress.complete // 0')
    local phase_total=$(echo "$json" | jq -r '.phaseProgress.total // 0')
    local phase_pct=$(echo "$json" | jq -r '.phaseProgress.pct // 0')
    local overall_complete=$(echo "$json" | jq -r '.overallProgress.complete // 0')
    local overall_total=$(echo "$json" | jq -r '.overallProgress.total // 0')
    local overall_pct=$(echo "$json" | jq -r '.overallProgress.pct // 0')

    echo "### Updated Progress"
    echo "- **Phase $phase**: $phase_complete/$phase_total tasks complete ($phase_pct%)"
    echo "- **Overall PRD**: $overall_complete/$overall_total tasks complete ($overall_pct%)"
    echo ""

    # Files
    local created=$(echo "$json" | jq -r '.filesCreated | length // 0')
    local modified=$(echo "$json" | jq -r '.filesModified | length // 0')
    created=${created:-0}
    modified=${modified:-0}
    if [ "$created" -gt 0 ] || [ "$modified" -gt 0 ]; then
        echo "### Files Created/Modified"
        echo "$json" | jq -r '.filesCreated[]? | "- \(.) (created)"'
        echo "$json" | jq -r '.filesModified[]? | "- \(.) (modified)"'
        echo ""
    fi

    # Next steps
    local blocked=$(echo "$json" | jq -r '.blocked // 0')
    phase_complete=${phase_complete:-0}
    phase_total=${phase_total:-0}
    echo "### Next Steps"
    if [ "$still_blocked_count" -gt 0 ]; then
        echo "- Run \`/prd plan-unblock\` again for remaining blocked tasks"
    elif [ "$phase_complete" -lt "$phase_total" ]; then
        echo "- Run \`/prd plan\` and \`/prd build\` for remaining tasks"
    else
        echo "- Phase complete! Run \`/prd read <next_phase>\` to continue"
    fi
}

display_review() {
    local json="$1"
    local status=$(echo "$json" | jq -r '.status // "unknown"')
    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')
    local phase=$(echo "$json" | jq -r '.phase // "N/A"')
    local phase_name=$(echo "$json" | jq -r '.phaseName // "Phase"')

    if [ "$status" = "error" ]; then
        echo "## Review Failed"
        echo ""
        echo "**Error**: $(echo "$json" | jq -r '.error // "Unknown error"')"
        return
    fi

    echo "## Phase Review: Phase $phase - $phase_name"
    echo ""

    # Summary counts
    local total=$(echo "$json" | jq -r '.summary.total // 0')
    local ambiguous=$(echo "$json" | jq -r '.summary.ambiguous // 0')
    local missing=$(echo "$json" | jq -r '.summary.missing // 0')
    local clarification=$(echo "$json" | jq -r '.summary.clarification // 0')
    total=${total:-0}
    ambiguous=${ambiguous:-0}
    missing=${missing:-0}
    clarification=${clarification:-0}

    if [ "$total" -eq 0 ]; then
        echo "**No issues found.** Phase is ready for execution."
        echo ""
        echo "**Next Steps**:"
        echo "- Run \`/prd plan\` to generate execution plan"
        return
    fi

    echo "**Summary**: $total finding(s)"
    echo ""
    echo "| Type | Count |"
    echo "|------|-------|"
    [ "$ambiguous" -gt 0 ] && echo "| Ambiguous | $ambiguous |"
    [ "$missing" -gt 0 ] && echo "| Missing | $missing |"
    [ "$clarification" -gt 0 ] && echo "| Clarification | $clarification |"
    echo ""

    # High severity findings
    local high_count=$(echo "$json" | jq '[.findings[] | select(.severity == "high")] | length // 0')
    high_count=${high_count:-0}
    if [ "$high_count" -gt 0 ]; then
        echo "### High Severity"
        echo ""
        echo "| Task | Type | Issue | Suggestion |"
        echo "|------|------|-------|------------|"
        echo "$json" | jq -r '.findings[] | select(.severity == "high") | "| \(.taskId) | \(.type) | \(.description) | \(.suggestion) |"'
        echo ""
    fi

    # Medium severity findings
    local med_count=$(echo "$json" | jq '[.findings[] | select(.severity == "medium")] | length // 0')
    med_count=${med_count:-0}
    if [ "$med_count" -gt 0 ]; then
        echo "### Medium Severity"
        echo ""
        echo "| Task | Type | Issue | Suggestion |"
        echo "|------|------|-------|------------|"
        echo "$json" | jq -r '.findings[] | select(.severity == "medium") | "| \(.taskId) | \(.type) | \(.description) | \(.suggestion) |"'
        echo ""
    fi

    # Low severity findings
    local low_count=$(echo "$json" | jq '[.findings[] | select(.severity == "low")] | length // 0')
    low_count=${low_count:-0}
    if [ "$low_count" -gt 0 ]; then
        echo "### Low Severity"
        echo ""
        echo "| Task | Type | Issue | Suggestion |"
        echo "|------|------|-------|------------|"
        echo "$json" | jq -r '.findings[] | select(.severity == "low") | "| \(.taskId) | \(.type) | \(.description) | \(.suggestion) |"'
        echo ""
    fi

    echo "**Next Steps**:"
    if [ "$high_count" -gt 0 ]; then
        echo "- Address $high_count high-severity finding(s) before proceeding"
        echo "- Run \`/prd edit <fix>\` to update tasks"
    else
        echo "- Review findings and update PRD if needed"
        echo "- Run \`/prd plan\` when ready to proceed"
    fi
}

display_review_all() {
    local json="$1"
    local status=$(echo "$json" | jq -r '.status // "unknown"')

    if [ "$status" = "error" ]; then
        echo "## Review-All Failed"
        echo ""
        echo "**Error**: $(echo "$json" | jq -r '.error // "Unknown error"')"
        return
    fi

    # Validate this is the expected findings JSON format (has phaseSummaries and findingsBySeverity)
    local is_findings_json=$(echo "$json" | jq -r 'if has("phaseSummaries") and has("findingsBySeverity") then "true" else "false" end')
    if [ "$is_findings_json" != "true" ]; then
        echo "## Review-All Failed"
        echo ""
        echo "**Error**: Invalid JSON format. Expected findings JSON with phaseSummaries and findingsBySeverity fields."
        return 1
    fi

    local prd=$(echo "$json" | jq -r '.prd // "Unknown"')

    echo "## PRD Review Complete: $prd"
    echo ""
    echo "**Phases Reviewed**: $(echo "$json" | jq -r '.phasesReviewed // 0')"
    echo ""

    # Initial findings summary
    echo "### Initial Review Findings"
    echo ""
    local init_total=$(echo "$json" | jq -r '.totalFindings // 0')
    local init_high=$(echo "$json" | jq -r '.highCount // (.findingsBySeverity.high | length) // 0')
    local init_med=$(echo "$json" | jq -r '.mediumCount // (.findingsBySeverity.medium | length) // 0')
    local init_low=$(echo "$json" | jq -r '.lowCount // (.findingsBySeverity.low | length) // 0')

    echo "| Severity | Count |"
    echo "|----------|-------|"
    echo "| High | $init_high |"
    echo "| Medium | $init_med |"
    echo "| Low | $init_low |"
    echo "| **Total** | **$init_total** |"
    echo ""

    # Show auto-fixable findings if any exist
    local auto_fix_count=$(echo "$json" | jq '[.findingsBySeverity.high[]?, .findingsBySeverity.medium[]?, .findingsBySeverity.low[]? | select(.autoFixable == true)] | length // 0')
    auto_fix_count=${auto_fix_count:-0}
    if [ "$auto_fix_count" -gt 0 ]; then
        echo "### Auto-Fixable Findings ($auto_fix_count)"
        echo ""
        echo "| Phase | Task | Severity | Type | Fix Action |"
        echo "|-------|------|----------|------|------------|"
        echo "$json" | jq -r '
            [.findingsBySeverity.high[]?, .findingsBySeverity.medium[]?, .findingsBySeverity.low[]? | select(.autoFixable == true)]
            | sort_by(.phase, .taskId)
            | .[]
            | "| \(.phase) | \(.taskId) | \(.severity) | \(.type) | \(.autoFixAction) |"'
        echo ""
        echo "_These findings may be automatically fixed by running the \`prd-review-all-apply.sh\` script._"
        echo ""
    fi

    # Show grouped manual fixes if any exist
    local manual_groups_count=$(echo "$json" | jq '.manualFixGroups | length // 0')
    manual_groups_count=${manual_groups_count:-0}
    if [ "$manual_groups_count" -gt 0 ]; then
        echo "### Manual Fixes Required (Grouped by Fix)"
        echo ""
        echo "| Type | Severity | Tasks | Recommended Fix |"
        echo "|------|----------|-------|-----------------|"
        echo "$json" | jq -r '.manualFixGroups[] | "| \(.type) | \(.severity) | \(.count) (\(.taskIds | join(", "))) | `\(.recommendedFix)` |"'
        echo ""
        echo "**Usage**: Copy a recommended fix and run \`/prd edit <fix>\`"
        echo ""
    fi

    # Readiness assessment - readinessAssessment is a string status value
    local score=$(echo "$json" | jq -r '.readinessScore // 0')
    local ready_status=$(echo "$json" | jq -r '.readinessAssessment // "unknown"')
    local message=$(echo "$json" | jq -r '.readinessMessage // ""')

    echo "### Readiness Assessment"
    echo ""
    echo "**Score**: $score/100"
    echo "**Status**: $ready_status"
    echo "**Assessment**: $message"
    echo ""

    # Next steps
    echo "### Next Steps"
    if [ "$auto_fix_count" -gt 0 ]; then
        echo "- Apply auto-fixes: \`bash ${WORKSPACE_DIR}/.claude/commands/prd/scripts/prd-review-all-apply.sh\`"
    fi
    case "$ready_status" in
        ready)
            echo "- PRD is ready for execution"
            echo "- Run \`/prd read <phase>\` then \`/prd plan\` and \`/prd build\`"
            ;;
        needs-work)
            echo "- Copy recommended fixes from table above"
            echo "- Run \`/prd edit <fix>\` for each grouped issue"
            echo "- Run \`/prd review-all\` to re-assess"
            ;;
        blocked)
            echo "- Critical issues found - use recommended fixes above"
            echo "- Run \`/prd edit <fix>\` for each high-severity group"
            echo "- Run \`/prd review-all\` to re-assess"
            ;;
        *)
            echo "- Review output and address any issues"
            ;;
    esac
}

#------------------------------------------------------------------------------
# Route to appropriate display function
#------------------------------------------------------------------------------
case "$TYPE" in
    plan)
        display_plan "$JSON"
        ;;
    plan-infra)
        display_plan_infra "$JSON"
        ;;
    plan-unblock)
        display_plan_unblock "$JSON"
        ;;
    gen)
        display_gen "$JSON"
        ;;
    edit)
        display_edit "$JSON"
        ;;
    build-result)
        display_build_result "$JSON"
        ;;
    infra-result)
        display_infra_result "$JSON"
        ;;
    unblock-result)
        display_unblock_result "$JSON"
        ;;
    review)
        display_review "$JSON"
        ;;
    review-all)
        display_review_all "$JSON"
        ;;
    *)
        echo "Error: Unknown display type: $TYPE"
        echo "Valid types: plan, plan-infra, plan-unblock, gen, edit, build-result, infra-result, unblock-result, review, review-all"
        exit 1
        ;;
esac
