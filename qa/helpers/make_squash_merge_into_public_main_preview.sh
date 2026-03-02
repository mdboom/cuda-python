#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Create a squash-merge preview branch for merging a branch into public main.
#
# Usage:
#   qa/helpers/make_squash_merge_into_public_main_preview.sh <branch-name>
#
# IMPORTANT: Before creating the squash-merge preview, ensure that there are
# no missing cython-gen updates and no missing cybind updates on the branch.

set -euo pipefail

# Check that exactly one argument is provided
if [ $# -ne 1 ]; then
    echo "ERROR: Exactly one argument required (branch-name)" >&2
    echo "Usage: $0 <branch-name>" >&2
    exit 1
fi

BRANCH_NAME="$1"

# Check that we're in a git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not in a git repository" >&2
    exit 1
fi

# Check that branch exists
if ! git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
    echo "ERROR: Branch '$BRANCH_NAME' does not exist" >&2
    exit 1
fi

# Check that working tree is clean (ignoring *Venv directories at repo root)
check_clean_tree() {
    local repo_name="$1"
    local staged=0 unstaged=0 untracked=0 conflicted=0 stash=0

    # Parse git status --porcelain, filtering out *Venv directories at repo root
    while IFS= read -r line; do
        local file="${line:3}"
        # Skip *Venv directories at repo root (e.g., "CythonGenVenv/", "TestVenv/")
        if [[ "$file" =~ ^[^/]*Venv(/|$) ]]; then
            continue
        fi

        local X="${line:0:1}" Y="${line:1:1}"
        if [[ "$X$Y" == "??" ]]; then
            ((untracked++))
        elif [[ "$X" == "U" || "$Y" == "U" || ("$X" == "A" && "$Y" == "A") || ("$X" == "D" && "$Y" == "D") ]]; then
            ((conflicted++))
        else
            [[ "$X" != " " ]] && ((staged++))
            [[ "$Y" != " " ]] && ((unstaged++))
        fi
    done < <(git status --porcelain)

    # Check stash
    if git rev-parse --quiet --verify refs/stash >/dev/null 2>&1; then
        stash=$(git rev-list --count refs/stash 2>/dev/null || echo 0)
    fi

    if [ $staged -ne 0 ] || [ $unstaged -ne 0 ] || [ $untracked -ne 0 ] || [ $conflicted -ne 0 ] || [ $stash -ne 0 ]; then
        echo "ERROR: $repo_name working tree is not clean" >&2
        echo "  staged:$staged unstaged:$unstaged untracked:$untracked conflicted:$conflicted stash:$stash" >&2
        exit 1
    fi
}

# Find ctk-next repo root (where .git is)
CTK_NEXT_ROOT=$(git rev-parse --show-toplevel)
PARENT_DIR=$(dirname "$CTK_NEXT_ROOT")

# Check that all repos are clean before making any modifications
echo "Checking that all repos are clean..."

echo "  Checking ctk-next..."
check_clean_tree "ctk-next"
echo "    ✓ ctk-next is clean"

if [ ! -d "$PARENT_DIR/cython-gen" ]; then
    echo "ERROR: cython-gen directory not found at $PARENT_DIR/cython-gen" >&2
    exit 1
fi

echo "  Checking cython-gen..."
if ! (
    cd "$PARENT_DIR/cython-gen"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: cython-gen is not a git work tree" >&2
        exit 1
    fi
    check_clean_tree "cython-gen"
); then
    echo "ERROR: cython-gen check failed (see error above)" >&2
    exit 1
fi
echo "    ✓ cython-gen is clean"

if [ ! -d "$PARENT_DIR/cybind" ]; then
    echo "ERROR: cybind directory not found at $PARENT_DIR/cybind" >&2
    exit 1
fi

echo "  Checking cybind..."
if ! (
    cd "$PARENT_DIR/cybind"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ERROR: cybind is not a git work tree" >&2
        exit 1
    fi
    check_clean_tree "cybind"
); then
    echo "ERROR: cybind check failed (see error above)" >&2
    exit 1
fi
echo "    ✓ cybind is clean"

# Source activate_helpers.sh to get run_cython_gen and run_cybind functions
# This must be done before switching branches, since qa/ won't exist in the new branch
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/activate_helpers.sh" ]; then
    # shellcheck source=qa/helpers/activate_helpers.sh
    source "${SCRIPT_DIR}/activate_helpers.sh"
else
    echo "ERROR: activate_helpers.sh not found at ${SCRIPT_DIR}/activate_helpers.sh" >&2
    exit 1
fi

# Set up logging if $L is defined
if [ -n "${L:-}" ]; then
    _ensure_log_dir
    LOG_FILE="${L}/make_squash_merge_into_public_main_preview_log_$(_make_log_timestamp).txt"
    echo "Logging output to: $LOG_FILE"
    # Redirect all output (stdout and stderr) to both log file and terminal
    exec > >(tee "$LOG_FILE") 2>&1
fi

# Get timestamp for branch name
NOWISH=$(date "+%Y-%m-%d+%H%M")
PREVIEW_BRANCH="squash_merge_into_public_main_preview_${NOWISH}"

# sync_public_main_to_private
public_repo.py sync

cd "$CTK_NEXT_ROOT"
git fetch public_repo

# Create a worktree from public_repo/main in the parent directory
# This allows us to keep access to qa/helpers in the original repo
WORKTREE_PATH="$PARENT_DIR/$PREVIEW_BRANCH"
git worktree add -b "$PREVIEW_BRANCH" "$WORKTREE_PATH" public_repo/main

cd "$WORKTREE_PATH"

cd "$PARENT_DIR/cython-gen/"
git clean -fdx
run_cython_gen 13.2 "$WORKTREE_PATH"
cd "$WORKTREE_PATH"
# Run pre-commit twice: first run may exit non-zero (auto-fixes), second must succeed
set +e
pre-commit run --all-files
PRE_COMMIT_EXIT=$?
set -e
if [ $PRE_COMMIT_EXIT -ne 0 ]; then
    echo "Exit code from first pre-commit run was $PRE_COMMIT_EXIT, rerunning..."
    pre-commit run --all-files
fi
git commit -a -m 'cython-gen updates (automatic, NO MANUAL CHANGES)'

cd "$PARENT_DIR/cybind"
git clean -fdx
run_cybind 13.2 "$WORKTREE_PATH"
cd "$WORKTREE_PATH"
# Run pre-commit twice: first run may exit non-zero (auto-fixes), second must succeed
set +e
pre-commit run --all-files
PRE_COMMIT_EXIT=$?
set -e
if [ $PRE_COMMIT_EXIT -ne 0 ]; then
    echo "Exit code from first pre-commit run was $PRE_COMMIT_EXIT, rerunning..."
    pre-commit run --all-files
fi
git commit -a -m 'cybind updates (automatic, NO MANUAL CHANGES)'

# Get list of generated files BEFORE squash merge (from the branch we're merging)
# This automatically finds all cython-gen and cybind generated files
echo
echo "Identifying generated files in $BRANCH_NAME..."
GENERATED_FILES_IN_BRANCH=$(git grep -l -e 'This code was automatically generated with version' -e 'This code was automatically generated across versions from' "$BRANCH_NAME" 2>/dev/null | cut -d: -f2- | grep -v '\.sh$' | sort -u || true)

if [ -z "$GENERATED_FILES_IN_BRANCH" ]; then
    echo "  No generated files found with generation markers"
    GENERATED_FILES_IN_BRANCH=""
else
    GENERATED_COUNT=$(echo "$GENERATED_FILES_IN_BRANCH" | grep -c . || echo "0")
    echo "  Found $GENERATED_COUNT generated file(s)"
fi

echo
echo "Squash merging $BRANCH_NAME..."
set +e
git merge --squash "$BRANCH_NAME"
MERGE_EXIT=$?
set -e

# If merge had conflicts, automatically resolve conflicts in generated files
# Note: git merge --squash doesn't create MERGE_HEAD, so we check for conflicts differently
if [[ $MERGE_EXIT -ne 0 ]]; then
    # Check for conflicted files (git merge --squash leaves conflicts in the index)
    CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    if [ -z "$CONFLICTED_FILES" ]; then
        # Also check git status for unmerged files
        CONFLICTED_FILES=$(git status --short 2>/dev/null | grep -E '^UU|^AA|^DD|^AU|^UA|^DU|^UD' | awk '{print $2}' || true)
    fi

    if [ -n "$CONFLICTED_FILES" ] && [ -n "$GENERATED_FILES_IN_BRANCH" ]; then
        echo
        echo "Resolving conflicts in generated files (taking ours - freshly generated)..."

        RESOLVED_COUNT=0

        while IFS= read -r file; do
            # Skip empty lines
            [ -z "$file" ] && continue

            # Check if this file is in our generated files list
            if echo "$GENERATED_FILES_IN_BRANCH" | grep -Fxq "$file" 2>/dev/null; then
                echo "Resolving conflict in: $file (taking ours - freshly generated)"
                if git checkout --ours "$file" 2>/dev/null || git restore --ours "$file" 2>/dev/null; then
                    git add "$file"
                    ((RESOLVED_COUNT++)) || true
                else
                    echo "  WARNING: Could not restore --ours for $file" >&2
                fi
            fi
        done <<<"$CONFLICTED_FILES"

        echo "  Resolved $RESOLVED_COUNT generated file(s)"

        # Check for remaining conflicts (non-generated files)
        REMAINING_CONFLICTS=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        if [ -z "$REMAINING_CONFLICTS" ]; then
            REMAINING_CONFLICTS=$(git status --short 2>/dev/null | grep -E '^UU|^AA|^DD|^AU|^UA|^DU|^UD' | awk '{print $2}' || true)
        fi

        if [ -n "$REMAINING_CONFLICTS" ]; then
            echo
            echo "ERROR: Remaining conflicts in non-generated files:" >&2
            echo "$REMAINING_CONFLICTS" | sed 's/^/  /' >&2
            echo "These conflicts must be resolved manually." >&2
            exit 1
        fi
    elif [ -n "$CONFLICTED_FILES" ]; then
        echo
        echo "ERROR: Merge conflicts detected but no generated files found to resolve" >&2
        echo "Conflicted files:" >&2
        echo "$CONFLICTED_FILES" | sed 's/^/  /' >&2
        exit 1
    else
        echo "ERROR: Merge failed but no conflicts detected" >&2
        exit 1
    fi
fi

git rm -r -f qa/
git commit -m "git merge --squash $BRANCH_NAME && git rm -r -f qa/ (NO MANUAL CHANGES)"

# Show diff, filtering out hash-only changes
echo
echo "Diff between $BRANCH_NAME and current branch (excluding qa/):"
DIFF_OUTPUT=$(git diff "$BRANCH_NAME" -- . ':(exclude)qa' 2>&1 || true)
if [ -z "$DIFF_OUTPUT" ]; then
    echo "  (no differences)"
else
    # Filter out hunks that only contain hash changes
    # Use the reusable filter script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    FILTER_SCRIPT="$SCRIPT_DIR/filter_git_hash_diffs.sh"

    if [ ! -f "$FILTER_SCRIPT" ]; then
        echo "ERROR: filter_git_hash_diffs.sh not found at $FILTER_SCRIPT" >&2
        echo "$DIFF_OUTPUT"
        exit 1
    fi

    FILTERED_DIFF=$(echo "$DIFF_OUTPUT" | "$FILTER_SCRIPT" 2>&1 || true)

    # Check if filtered diff is empty (after trimming whitespace)
    FILTERED_DIFF_TRIMMED=$(echo "$FILTERED_DIFF" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$FILTERED_DIFF_TRIMMED" ]; then
        echo "  (no differences after filtering hash-only changes)"
    else
        echo "$FILTERED_DIFF"
    fi
fi

echo
echo "The new branch is ready under $(realpath "$WORKTREE_PATH")"
echo
echo "Hint: To clean up the worktree later:"
echo "  cd $CTK_NEXT_ROOT"
echo "  git worktree remove $WORKTREE_PATH"
