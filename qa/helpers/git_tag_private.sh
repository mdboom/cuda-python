#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME <tag-name>

Create a lightweight git tag and push it to the upstream remote.

Example:
  $SCRIPT_NAME vN.M.Orc0

This will:
  1. Create tag: git tag vN.M.Orc0
  2. Push to upstream: git push upstream vN.M.Orc0
EOF
}

# Check for exactly one argument
if [ $# -eq 0 ]; then
    echo "Error: tag name required"
    echo
    usage
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Error: exactly one argument required (got $#)"
    echo
    usage
    exit 1
fi

TAG_NAME="$1"

# Validate upstream remote exists
if ! git remote get-url upstream &>/dev/null; then
    echo "Error: upstream remote not found"
    echo
    echo "Expected remote: git@github.com:NVIDIA/cuda-python-private.git"
    echo "Add it with: git remote add upstream git@github.com:NVIDIA/cuda-python-private.git"
    exit 1
fi

# Create lightweight tag
echo "Creating tag: $TAG_NAME"
git tag "$TAG_NAME"

# Push to upstream
echo "Pushing tag to upstream..."
git push upstream "$TAG_NAME"

echo "✓ Tag $TAG_NAME created and pushed to upstream"
