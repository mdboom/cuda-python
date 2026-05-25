#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Copy a preview branch created by make_squash_merge_into_public_main_preview.sh
# into the current public cuda-python repository as a new branch.
#
# This script should be run from inside the public cuda-python repository.
# It creates a new branch locally but does not push it (user pushes using their standard workflow).
#
# Usage:
#   cd /wrk/forked/cuda-python
#   qa/helpers/copy_preview_to_public_branch.sh <preview-worktree-path> <branch-name>
#
# Example:
#   cd /wrk/forked/cuda-python
#   qa/helpers/copy_preview_to_public_branch.sh \
#     ../squash_merge_into_public_main_preview_2026-02-28+1250 \
#     cuda_bindings_13.2.0_release

set -euo pipefail

# Check arguments
if [ $# -ne 2 ]; then
    echo "ERROR: Invalid number of arguments" >&2
    echo "Usage: $0 <preview-worktree-path> <branch-name>" >&2
    echo "" >&2
    echo "This script should be run from inside the public cuda-python repository." >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  cd /wrk/forked/cuda-python" >&2
    echo "  $0 ../squash_merge_into_public_main_preview_2026-02-28+1250 \\" >&2
    echo "      cuda_bindings_13.2.0_release" >&2
    exit 1
fi

PREVIEW_WORKTREE="$1"
BRANCH_NAME="$2"

# Validate we're in a git repository (should be cuda-python)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not in a git repository" >&2
    echo "This script must be run from inside the public cuda-python repository." >&2
    exit 1
fi

CURRENT_REPO_DIR=$(pwd)

# Resolve preview worktree path (handle relative paths)
if [[ "$PREVIEW_WORKTREE" != /* ]]; then
    # Relative path - resolve relative to current directory
    PREVIEW_WORKTREE=$(cd "$CURRENT_REPO_DIR" && cd "$PREVIEW_WORKTREE" && pwd)
else
    # Absolute path - just validate it exists
    PREVIEW_WORKTREE=$(cd "$PREVIEW_WORKTREE" && pwd)
fi

# Validate preview worktree path
if [ ! -d "$PREVIEW_WORKTREE" ]; then
    echo "ERROR: Preview worktree path does not exist: $PREVIEW_WORKTREE" >&2
    exit 1
fi

# Validate it's a git repository/worktree (worktrees have .git as a file, not directory)
cd "$PREVIEW_WORKTREE"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Preview worktree path is not a git repository or worktree: $PREVIEW_WORKTREE" >&2
    exit 1
fi
cd "$CURRENT_REPO_DIR"

# Validate preview worktree is clean
cd "$PREVIEW_WORKTREE"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo "ERROR: Working tree in preview worktree is not clean" >&2
    echo "Please commit or stash changes before copying." >&2
    exit 1
fi

# Get the branch name that the preview worktree is on
PREVIEW_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
PREVIEW_HEAD=$(git rev-parse HEAD)

# Validate preview branch name matches expected pattern
if [[ ! "$PREVIEW_BRANCH" =~ ^squash_merge_into_public_main_preview_ ]]; then
    echo "WARNING: Preview worktree is on branch '$PREVIEW_BRANCH'" >&2
    echo "Expected branch name pattern: squash_merge_into_public_main_preview_*" >&2
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Get the base commit (should be public_repo/main)
if ! git rev-parse --verify public_repo/main >/dev/null 2>&1; then
    echo "ERROR: Preview worktree does not have 'public_repo/main' reference" >&2
    echo "The preview worktree should be based on public_repo/main." >&2
    echo "" >&2
    echo "Fix (in the ctk-next repo):" >&2
    echo "  qa/helpers/public_repo.py sync" >&2
    echo "  qa/helpers/make_squash_merge_into_public_main_preview.sh <branch-name> <ctk-version>" >&2
    exit 1
fi

PREVIEW_BASE=$(git rev-parse public_repo/main)

# Switch back to current repo
cd "$CURRENT_REPO_DIR"

# Validate current repo has a main branch
if ! git rev-parse --verify main >/dev/null 2>&1; then
    echo "ERROR: Current repository does not have a 'main' branch" >&2
    exit 1
fi

CURRENT_MAIN=$(git rev-parse main)

# Verify that preview base matches current main
if [ "$PREVIEW_BASE" != "$CURRENT_MAIN" ]; then
    echo "ERROR: Preview branch base does not match current repository's main" >&2
    echo "" >&2
    echo "Preview base (public_repo/main): $PREVIEW_BASE" >&2
    echo "Current repo main:                $CURRENT_MAIN" >&2
    echo "" >&2
    echo "The preview branch must be based on the same commit as your current main branch." >&2
    echo "Please update your main branch or create a new preview branch." >&2
    exit 1
fi

# Check if branch name already exists
if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    echo "ERROR: Branch '$BRANCH_NAME' already exists in current repository" >&2
    echo "Please use a different branch name or delete the existing branch first." >&2
    exit 1
fi

# Show what will be created
echo "Preview worktree: $PREVIEW_WORKTREE"
echo "Preview branch:   $PREVIEW_BRANCH"
echo "Preview HEAD:     $PREVIEW_HEAD"
echo "Base commit:      $PREVIEW_BASE (matches current main)"
echo ""
echo "The following commits will be copied to branch '$BRANCH_NAME':"
cd "$PREVIEW_WORKTREE"
git log --oneline "$PREVIEW_BASE..HEAD"
cd "$CURRENT_REPO_DIR"

# Confirm before creating branch
echo ""
read -p "Create branch '$BRANCH_NAME' in current repository? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Add preview worktree as temporary remote
TEMP_REMOTE="temp_preview_copy"
if git remote get-url "$TEMP_REMOTE" >/dev/null 2>&1; then
    git remote set-url "$TEMP_REMOTE" "$PREVIEW_WORKTREE"
else
    git remote add "$TEMP_REMOTE" "$PREVIEW_WORKTREE"
fi

# Fetch the preview branch
echo ""
echo "Fetching commits from preview worktree..."
git fetch "$TEMP_REMOTE" "$PREVIEW_BRANCH"

# Create new branch from fetched commits
echo "Creating branch '$BRANCH_NAME' from fetched commits..."
git checkout -b "$BRANCH_NAME" "$TEMP_REMOTE/$PREVIEW_BRANCH"

# Clean up temporary remote
git remote remove "$TEMP_REMOTE"

echo ""
echo "✓ Branch '$BRANCH_NAME' created successfully"
echo ""
echo "Next steps:"
echo "1. Review the branch: git log main..$BRANCH_NAME"
echo "2. Push the branch using your standard workflow"
echo "3. Create a Pull Request from branch '$BRANCH_NAME' to 'main'"
echo "4. After the PR is merged, merge the corresponding cybind branch as needed."
