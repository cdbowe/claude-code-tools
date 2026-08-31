#!/bin/bash
# prd-doctor.sh - Preflight check for the /prd runtime environment.
#
# Usage: prd-doctor.sh [--strict] [--quiet]
#   --strict  Treat WARN as failure (exit 1). Default: only FAIL is fatal.
#   --quiet   Print only WARN/FAIL lines and the summary.
#
# Exit codes:
#   0 - No hard failures. /prd commands can run (see WARNs for build-only gaps).
#   1 - Hard failure. /prd is broken until the reported prerequisite is fixed.
#
# Severity model:
#   FAIL - blocks all /prd subcommands
#   WARN - blocks only /prd build (git worktree layout) or self-heals on first use

STRICT=0
QUIET=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "prd-doctor.sh: unknown option '$arg'" >&2; exit 2 ;;
  esac
done

FAILS=0
WARNS=0

pass() { [ "$QUIET" -eq 1 ] || printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; [ -n "${2:-}" ] && printf '        -> %s\n' "$2"; WARNS=$((WARNS + 1)); return 0; }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        -> %s\n' "$2"; FAILS=$((FAILS + 1)); return 0; }

echo "prd-doctor: checking /prd runtime environment"
echo

# --- 1. jq -------------------------------------------------------------------
# Every PRD script parses JSON with jq; without it nothing works.
if command -v jq >/dev/null 2>&1; then
  pass "jq found ($(command -v jq))"
else
  fail "jq not found on PATH" "Install it: sudo apt-get install -y jq"
fi

# --- 1b. python3 ---------------------------------------------------------------
# prd-plan.sh and prd-unblock-compile.sh shell out to python3 for the
# topological sort / wave splitting. Without it, /prd plan and /prd unblock die.
if command -v python3 >/dev/null 2>&1; then
  pass "python3 found ($(command -v python3))"
else
  fail "python3 not found on PATH (/prd plan and /prd unblock need it)" \
       "Install it: sudo apt-get install -y python3"
fi

# --- 2. WORKSPACE_DIR --------------------------------------------------------
if [ -z "${WORKSPACE_DIR:-}" ]; then
  fail "WORKSPACE_DIR is not set" \
       "Set it in devcontainer.json containerEnv, e.g. \"WORKSPACE_DIR\": \"\${containerWorkspaceFolder}\""
elif [ ! -d "$WORKSPACE_DIR" ]; then
  fail "WORKSPACE_DIR points at a missing directory: $WORKSPACE_DIR" \
       "Correct WORKSPACE_DIR or create the directory."
else
  pass "WORKSPACE_DIR=$WORKSPACE_DIR"
fi

# --- 3. scripts dir + execute bits -------------------------------------------
# Resolve the same way the hooks and agents do, so the doctor validates the path
# that /prd will actually use rather than its own location.
SCRIPTS_DIR="${PRD_SCRIPTS_DIR:-${WORKSPACE_DIR}/.claude/commands/prd/scripts}"
CLAUDE_DIR="${WORKSPACE_DIR}/.claude"

if [ ! -d "$SCRIPTS_DIR" ]; then
  fail "PRD scripts dir not found: $SCRIPTS_DIR" \
       "Run: bash <claude-code-tools>/install.sh --all --dir \"\$WORKSPACE_DIR/.claude\""
else
  pass "PRD scripts dir: $SCRIPTS_DIR"

  # /prd summarize and the hooks exec scripts directly, so a missing +x is fatal
  # rather than cosmetic. chmod is often denied in Claude settings, so the fix
  # has to happen at install time.
  NOEXEC=$(find "$SCRIPTS_DIR" "$CLAUDE_DIR/commands/scripts" "$CLAUDE_DIR/hooks" \
             -name '*.sh' ! -perm -u+x 2>/dev/null | sort)
  if [ -n "$NOEXEC" ]; then
    fail "$(printf '%s\n' "$NOEXEC" | wc -l) installed script(s) are not executable" \
         "Re-run install.sh (it chmods on install), or: chmod +x $SCRIPTS_DIR/*.sh"
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$NOEXEC" | sed 's/^/           /'
  else
    pass "all installed .sh files are executable"
  fi
fi

# --- 4. no stale staging-path references -------------------------------------
# /tmp/claude-shared was never created by anything and does not survive a
# container restart; any surviving reference is a latent breakage.
if [ -d "$CLAUDE_DIR" ]; then
  # Exclude this script: it names the stale path in its own remediation text.
  STALE=$(grep -rl '/tmp/claude-shared' "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks" \
            "$CLAUDE_DIR/agents" "$CLAUDE_DIR/settings.json" 2>/dev/null \
            | grep -v '/prd-doctor\.sh$' | sort)
  if [ -n "$STALE" ]; then
    warn "$(printf '%s\n' "$STALE" | wc -l) file(s) still reference /tmp/claude-shared" \
         "Re-install from a current claude-code-tools checkout."
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$STALE" | sed 's/^/           /'
  else
    pass "no /tmp/claude-shared references"
  fi
fi

# --- 4b. model tier config ---------------------------------------------------
# Every tier must resolve to a concrete version; an unresolvable tier would put
# an empty model string into a plan and silently fall back to a default model.
if [ -x "$SCRIPTS_DIR/prd-model.sh" ] || [ -f "$SCRIPTS_DIR/prd-model.sh" ]; then
  if MODEL_TABLE=$(bash "$SCRIPTS_DIR/prd-model.sh" --list 2>&1); then
    if printf '%s' "$MODEL_TABLE" | grep -q UNRESOLVED; then
      fail "prd-models.json maps a task type or role to an undefined tier" \
           "Run: bash $SCRIPTS_DIR/prd-model.sh --list"
    else
      pass "model tiers resolve: $(bash "$SCRIPTS_DIR/prd-model.sh" --json \
              | jq -r '.tiers | to_entries | map("\(.key)=\(.value)") | join("  ")')"
    fi
  else
    fail "prd-models.json missing or invalid" \
         "$(printf '%s' "$MODEL_TABLE" | head -1)"
  fi
else
  warn "prd-model.sh not installed; cannot verify model tier config" \
       "Re-run install.sh --all from a current checkout."
fi

# --- 5. agent registry -------------------------------------------------------
# Agents register under their frontmatter `name:`, not their filename. A
# subagent_type in prd.md with no matching name fails at spawn time.
PRD_MD="$CLAUDE_DIR/commands/prd.md"
if [ ! -f "$PRD_MD" ]; then
  fail "commands/prd.md not found at $PRD_MD" \
       "Run install.sh --all against \"\$WORKSPACE_DIR/.claude\"."
else
  # Registered names come from both the project dir and the user config dir.
  AGENT_DIRS="$CLAUDE_DIR/agents ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents"
  REGISTERED=$(for d in $AGENT_DIRS; do
                 [ -d "$d" ] || continue
                 find "$d" -name '*.md' -type f 2>/dev/null | while read -r a; do
                   # tr -d '\r': several agent files ship with CRLF frontmatter,
                   # which would otherwise make every name miscompare.
                   grep -m1 '^name:[[:space:]]' "$a" 2>/dev/null | tr -d '\r' | awk '{print $2}'
                 done
               done | sort -u)

  MISSING=""
  for st in $(grep -o 'subagent_type: *"[A-Za-z0-9_-]*"' "$PRD_MD" \
                | sed 's/.*"\(.*\)"/\1/' | sort -u); do
    printf '%s\n' "$REGISTERED" | grep -qx "$st" || MISSING="$MISSING $st"
  done

  if [ -n "$MISSING" ]; then
    fail "prd.md spawns unregistered agent(s):$MISSING" \
         "Agents register under frontmatter 'name:'. Fix prd.md or the agent frontmatter."
  else
    pass "all subagent_type values in prd.md resolve to registered agents"
  fi
fi

# --- 6. PRD_BASE -------------------------------------------------------------
PRD_BASE="${WORKSPACE_DIR}/claude_files/PRDs"
if [ -d "$PRD_BASE" ]; then
  pass "PRD base: $PRD_BASE"
else
  warn "PRD base missing: $PRD_BASE" \
       "/prd gen creates it; list/load/stat fail until then. mkdir -p \"$PRD_BASE\""
fi

# --- 7. git worktree layout (required by /prd build) -------------------------
# worktree-create.sh cds to $WORKSPACE_DIR/main and adds worktrees under
# $WORKSPACE_DIR/worktrees. A plain `git init` at the workspace root does not
# satisfy this. install.sh deliberately does not create it — restructuring an
# existing checkout is destructive.
MAIN_DIR="${WORKTREE_MAIN_DIR:-${WORKSPACE_DIR}/main}"
WORKTREE_ROOT="${WORKSPACE_DIR}/worktrees"

if [ ! -d "$MAIN_DIR" ]; then
  warn "main checkout not found: $MAIN_DIR" \
       "/prd build only. Move your checkout to \$WORKSPACE_DIR/main, or set WORKTREE_MAIN_DIR."
elif ! git -C "$MAIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  warn "$MAIN_DIR is not a git repository" \
       "/prd build only. Run: git -C \"$MAIN_DIR\" init"
else
  pass "main checkout: $MAIN_DIR ($(git -C "$MAIN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no HEAD'))"
  if ! git -C "$MAIN_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    warn "$MAIN_DIR has no commits yet" \
         "/prd build only. git worktree add needs a base commit; make an initial commit."
  fi
fi

if [ -d "$WORKTREE_ROOT" ]; then
  pass "worktree root: $WORKTREE_ROOT"
else
  warn "worktree root missing: $WORKTREE_ROOT" \
       "/prd build only. worktree-create.sh mkdir -p's this, so it self-heals."
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$FAILS" -gt 0 ]; then
  echo "prd-doctor: $FAILS failure(s), $WARNS warning(s) — /prd is not usable yet."
  exit 1
fi
if [ "$WARNS" -gt 0 ]; then
  echo "prd-doctor: 0 failures, $WARNS warning(s) — /prd works; warnings above affect /prd build."
  [ "$STRICT" -eq 1 ] && exit 1
  exit 0
fi
echo "prd-doctor: all checks passed."
exit 0
