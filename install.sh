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
#   --with-local   Create a fresh, empty settings.local.json if none exists.
#                  Never copied from the repo — it's machine-local and yours.
#   --force        Replace an existing settings.local.json with a fresh one.
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

# settings.local.json is machine-local: generated empty, never copied from the
# repo, so a checkout's personal overrides can't leak into a new environment.
write_fresh_local() {
  cat > "$TARGET/settings.local.json" <<'JSON'
{
  "permissions": {
    "allow": [],
    "deny": []
  }
}
JSON
}

mkdir -p "$TARGET"
echo "Installing claude-code-tools ($MODE) -> $TARGET"

# --- minimal set: statusline works out of the box ---
copy_item "settings.json"
copy_item "statusline"
copy_from ".claude/.gitignore" ".gitignore"

# --- machine-local overrides: created fresh, never copied ---
if [ "$WITH_LOCAL" -eq 1 ]; then
  if [ -e "$TARGET/settings.local.json" ] && [ "$FORCE" -eq 0 ]; then
    echo "  keep   settings.local.json (exists; use --force to replace)"
  else
    write_fresh_local
    echo "  create settings.local.json (empty)"
  fi
fi

# --- full toolkit ---
if [ "$MODE" = "all" ]; then
  copy_item "agents"
  copy_item "commands"
  copy_item "hooks"
fi

echo "Done."
