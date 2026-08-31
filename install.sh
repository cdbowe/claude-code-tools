#!/usr/bin/env bash
# 
# install.sh — copy claude-code-tools modules into a Claude Code config dir.
#
# Source of truth for the install layout lives with the files it installs.
# devcontainer-init (or you, by hand) invokes this against a target .claude dir.
#
# Usage:
#   ./install.sh [--dir TARGET] [--minimal|--all] [--with-local] [--force]
#
#   --dir TARGET   Destination config dir. Default: $CLAUDE_CONFIG_DIR, else ~/.claude
#   --minimal      Copy settings.json + statusline/ only. (default)
#   --all          Also copy agents/, commands/, hooks/.
#   --with-local   Seed settings.local.json if none exists — from the repo's
#                  copy when it has one, else a fresh empty scaffold.
#   --force        Re-seed an existing settings.local.json from the repo's copy.
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

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)        TARGET="$2"; shift 2 ;;
    --dir=*)      TARGET="${1#*=}"; shift ;;
    --minimal)    MODE="minimal"; shift ;;
    --all)        MODE="all"; shift ;;
    --with-local) WITH_LOCAL=1; shift ;;
    --force)      FORCE=1; shift ;;
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
  if [ -d "$src" ]; then
    mkdir -p "$TARGET/$item"
    cp -R "$src/." "$TARGET/$item/"
  else
    cp "$src" "$TARGET/$item"
  fi
  echo "  copy   $item"
}

# Copy an item whose repo location is unambiguous. Needed for .gitignore: the
# repo root has its own (*.bak), and find_src would prefer it over .claude/.
copy_from() {
  local src="$SCRIPT_DIR/$1" dest="$2"
  if [ ! -e "$src" ]; then
    echo "  skip   $dest (not found in repo)"
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
fi

echo "Done."
