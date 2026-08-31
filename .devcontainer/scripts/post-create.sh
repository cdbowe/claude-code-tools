#!/bin/bash
set -e

echo "Running post-create setup..."
echo "  WORKSPACE_DIR: ${WORKSPACE_DIR}"

###########################################
# Git Safe Directory
###########################################

git config --global --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true

###########################################
# Docker Socket
###########################################

if [ -S /var/run/docker.sock ]; then
  sudo chgrp docker /var/run/docker.sock 2>/dev/null || true
  sudo chmod g+rw /var/run/docker.sock 2>/dev/null || true
fi

###########################################
# Script Execute Bits
###########################################

# .claude/ is bind-mounted from the host, so mode bits come from the host
# filesystem and are routinely lost (Windows/macOS mounts, fresh clones, zip
# extraction). /prd summarize and the hooks exec these directly, and
# `Bash(chmod:*)` is denied in settings.json — so this cannot be repaired from
# inside a Claude session. Re-assert it on every container create.
#
# Downstream projects get the same treatment from install.sh --all; this repo
# does not install into itself, hence the duplicate here.

fixed=0
while IFS= read -r f; do
  chmod +x "$f" 2>/dev/null && fixed=$((fixed + 1))
done < <(find "${WORKSPACE_DIR}/.claude/commands" "${WORKSPACE_DIR}/.claude/hooks" \
              "${WORKSPACE_DIR}/.claude/statusline" \
              -name '*.sh' -type f ! -perm -u+x 2>/dev/null)
echo "  chmod +x on ${fixed} script(s)"

###########################################
# Project Dependencies
###########################################

# jq and python3 are installed in the image (see Dockerfile). Verify, because a
# missing one breaks /prd in ways that are confusing to diagnose at runtime.
for dep in jq python3; do
  if command -v "$dep" >/dev/null 2>&1; then
    echo "  ok    $dep ($($dep --version 2>&1 | head -1))"
  else
    echo "  WARN  $dep not found — /prd will not work. Rebuild the container."
  fi
done


echo ""
echo "Post-create setup complete!"
