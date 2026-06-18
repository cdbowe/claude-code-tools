#!/bin/bash
set -e

echo "Running post-start setup..."

###########################################
# Git Safe Directory
###########################################

git config --global --add safe.directory "${WORKSPACE_DIR}" 2>/dev/null || true


echo "Post-start setup complete!"
