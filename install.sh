#!/usr/bin/env bash
# 
# install.sh — copy claude-code-tools modules into a Claude Code config dir.
#
# Source of truth for the install layout lives with the files it installs.
# devcontainer-init (or you, by hand) invokes this against a target .claude dir.
#
# Usage:
#   ./install.sh [--dir TARGET] [--minimal|--all] [--with-local] [--force]
#                [--no-prd-env]
#
#   --dir TARGET   Destination config dir. Default: $CLAUDE_CONFIG_DIR, else ~/.claude
#   --minimal      Copy settings.json + statusline/ only. (default)
#   --all          Also copy agents/, commands/, hooks/, rules/, and set up the
#                  /prd runtime environment (see below).
#   --with-local   Seed settings.local.json if none exists — from the repo's
#                  copy when it has one, else a fresh empty scaffold.
#   --force        Re-seed an existing settings.local.json from the repo's copy.
#   --no-prd-env   Skip the /prd environment setup that --all performs.
#
# /prd environment setup (--all, and only when TARGET is $WORKSPACE_DIR/.claude):
#   Copying files is necessary but not sufficient for /prd — it also needs an
#   executable script set, a PRD base dir, and a split bare-repo git layout.
#   This script does the parts that are safe and idempotent:
#     * chmod +x the installed hooks and command scripts
#     * mkdir -p $WORKSPACE_DIR/claude_files/PRDs
#   It then runs prd-doctor.sh and REPORTS anything it cannot safely do itself.
#   It deliberately never runs `git init`, creates branches, or relocates a
#   checkout into main/ — restructuring someone's working tree unattended from
#   postCreateCommand is destructive. Follow the doctor's remediation instead.
#
# Examples:
#   ./install.sh                                   # into ~/.claude (or $CLAUDE_CONFIG_DIR)
#   ./install.sh --dir "$WORKSPACE_DIR/.claude" --with-local
#   ./install.sh --all --force
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MODE="minimal"
WITH_LOCAL=0
FORCE=0
PRD_ENV=1

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        TARGET="$2"; shift 2 ;;
    --dir=*)      TARGET="${1#*=}"; shift ;;
    --minimal)    MODE="minimal"; shift ;;
    --all)        MODE="all"; shift ;;
    --with-local) WITH_LOCAL=1; shift ;;
    --force)      FORCE=1; shift ;;
    --no-prd-env) PRD_ENV=0; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

# Locate a source item whether the repo keeps it at the root or under .claude/.
find_src() {
  local item="$1"
  if [ -e "$SCRIPT_DIR/$item" ]; then
    printf '%s\n' "$SCRIPT_DIR/$item"
  elif [ -e "$SCRIPT_DIR/.claude/$item" ]; then
    printf '%s\n' "$SCRIPT_DIR/.claude/$item"
  else
    return 1
  fi
}

copy_item() {
  local item="$1" src
  if ! src="$(find_src "$item")"; then
    echo "  skip   $item (not found in repo)"
    return 0
  fi
  # Self-install: --dir pointed at the repo's own .claude/. `cp` onto the same
  # path errors ("are the same file") and aborts the script under `set -e`, so
  # guard rather than copy. Same reasoning as write_local() below.
  if [ -e "$TARGET/$item" ] && [ "$src" -ef "$TARGET/$item" ]; then
    echo "  keep   $item (target is the repo copy)"
    return 0
  fi
  if [ -d "$src" ]; then
    mkdir -p "$TARGET/$item"
    cp -R "$src/." "$TARGET/$item/"
    # The repo carries dev-only symlinks (agents/~WORKSPACE, rules/~WORKSPACE)
    # that point into /tmp and dangle everywhere else. cp -R copies the link, not
    # its target, so prune what we just installed rather than shipping breakage.
    find "$TARGET/$item" -xtype l -delete 2>/dev/null || true
  else
    cp "$src" "$TARGET/$item"
  fi
  echo "  copy   $item"
}

# Re-assert the execute bit on installed scripts. Three reasons this cannot be
# left to the repo's file modes alone: cp -R preserves whatever the source has,
# bind mounts from hosts with lossy permission semantics drop the bit, and
# `Bash(chmod:*)` is denied in this toolkit's own settings.json — so a missing
# mode cannot be repaired from inside a Claude session afterwards.
fix_modes() {
  local dir n=0 f
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      chmod +x "$f" 2>/dev/null && n=$((n + 1))
    done < <(find "$dir" -name '*.sh' -type f ! -perm -u+x 2>/dev/null)
  done
  if [ "$n" -gt 0 ]; then
    echo "  chmod  +x on $n script(s)"
  fi
}

# Copy an item whose repo location is unambiguous. Needed for .gitignore: the
# repo root has its own (*.bak), and find_src would prefer it over .claude/.
copy_from() {
  local src="$SCRIPT_DIR/$1" dest="$2"
  if [ ! -e "$src" ]; then
    echo "  skip   $dest (not found in repo)"
    return 0
  fi
  if [ -e "$TARGET/$dest" ] && [ "$src" -ef "$TARGET/$dest" ]; then
    echo "  keep   $dest (target is the repo copy)"
    return 0
  fi
  cp "$src" "$TARGET/$dest"
  echo "  copy   $dest"
}

# settings.local.json is seeded from the repo's copy when it has one, so a new
# environment starts with the same hooks/permissions as the checkout. Falls back
# to an empty scaffold when the repo has none, which keeps this working for a
# checkout that treats the file as untracked and machine-local.
write_local() {
  local src
  if src="$(find_src "settings.local.json")"; then
    # Guard the self-install case (TARGET == the repo's own .claude/), where
    # `cp` onto the same file would abort the script under `set -e`.
    if [ "$src" -ef "$TARGET/settings.local.json" ]; then
      echo "  keep   settings.local.json (target is the repo copy)"
      return 0
    fi
    cp "$src" "$TARGET/settings.local.json"
    echo "  copy   settings.local.json (from repo)"
    return 0
  fi

  cat > "$TARGET/settings.local.json" <<'JSON'
{
  "permissions": {
    "allow": [],
    "deny": []
  }
}
JSON
  echo "  create settings.local.json (empty; none in repo)"
}

mkdir -p "$TARGET"
echo "Installing claude-code-tools ($MODE) -> $TARGET"

# --- minimal set: statusline works out of the box ---
copy_item "settings.json"
copy_item "statusline"
copy_from ".claude/.gitignore" ".gitignore"
fix_modes "$TARGET/statusline"

# --- local overrides: seeded from the repo's copy when it has one ---
if [ "$WITH_LOCAL" -eq 1 ]; then
  if [ -e "$TARGET/settings.local.json" ] && [ "$FORCE" -eq 0 ]; then
    echo "  keep   settings.local.json (exists; use --force to re-seed from repo)"
  else
    write_local
  fi
fi

# --- full toolkit ---
if [ "$MODE" = "all" ]; then
  copy_item "agents"
  copy_item "commands"
  copy_item "hooks"
  copy_item "rules"
  # The pinned model version per tier that /prd uses. Copied so a new
  # environment runs the same versions as the checkout.
  copy_item "prd-models.json"
  fix_modes "$TARGET/commands" "$TARGET/hooks"

  # --- /prd runtime environment ---
  # Keyed off WORKSPACE_DIR, not TARGET: the installer is invoked twice, once for
  # the user config dir and once for the project dir, and claude_files/PRDs must
  # only ever be created next to the workspace. Anything else is a no-op here.
  if [ "$PRD_ENV" -eq 0 ]; then
    echo "  skip   /prd env setup (--no-prd-env)"
  elif [ -z "${WORKSPACE_DIR:-}" ]; then
    echo "  skip   /prd env setup (WORKSPACE_DIR not set)"
  elif [ ! -d "$WORKSPACE_DIR" ]; then
    echo "  skip   /prd env setup (WORKSPACE_DIR does not exist: $WORKSPACE_DIR)"
  elif [ ! -e "$TARGET" ] || [ ! "$TARGET" -ef "$WORKSPACE_DIR/.claude" ]; then
    echo "  skip   /prd env setup (target is not \$WORKSPACE_DIR/.claude)"
  else
    mkdir -p "$WORKSPACE_DIR/claude_files/PRDs"
    echo "  mkdir  claude_files/PRDs"

    DOCTOR="$TARGET/commands/prd/scripts/prd-doctor.sh"
    if [ -x "$DOCTOR" ] || [ -f "$DOCTOR" ]; then
      echo
      # Never fail the install on the doctor's verdict: it also reports the git
      # worktree layout, which install.sh will not create on the user's behalf.
      bash "$DOCTOR" || true
    else
      echo "  warn   prd-doctor.sh not installed; cannot verify /prd environment"
    fi
  fi
fi

echo "Done."
