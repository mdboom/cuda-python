#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Merge the public cuda-python main branch into the current ctk-next worktree.
#
# Default behavior:
#   - Fetches from https://github.com/NVIDIA/cuda-python.git (branch: main)
#   - Shows incoming commits
#   - Asks for confirmation
#   - Performs `git merge --no-edit FETCH_HEAD`
#
# Usage:
#   qa/helpers/git_merge_public_main.sh [-u URL] [-b BRANCH] [--yes] [--edit]
#
# Examples:
#   qa/helpers/git_merge_public_main.sh
#   qa/helpers/git_merge_public_main.sh -b main
#   qa/helpers/git_merge_public_main.sh -u https://github.com/NVIDIA/cuda-python.git -b main --yes
#
# Most of this script is for checking preconditions and error conditions.
# The core functionality is simply:
#
#   git fetch https://github.com/NVIDIA/cuda-python.git main
#   git merge FETCH_HEAD
#
set -euo pipefail

URL_DEFAULT="https://github.com/NVIDIA/cuda-python.git"
BRANCH_DEFAULT="main"
CONFIRM="yes"
EDIT_FLAG="--no-edit"

URL="$URL_DEFAULT"
BRANCH="$BRANCH_DEFAULT"

print_usage() {
    sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
    -u | --url)
        URL="${2:-}"
        shift 2
        ;;
    -b | --branch)
        BRANCH="${2:-}"
        shift 2
        ;;
    --yes | -y)
        CONFIRM="no"
        shift
        ;;
    --edit)
        EDIT_FLAG="--edit"
        shift
        ;;
    -h | --help)
        print_usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        print_usage
        exit 2
        ;;
    esac
done

# Sanity checks
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

current_branch="$(git branch --show-current 2>/dev/null || true)"
if [[ -z "$current_branch" ]]; then
    echo "Error: detached HEAD; please checkout your ctk-next branch first." >&2
    exit 1
fi

if [[ "$current_branch" != merge-public-main* ]]; then
    echo "Warning: current branch is '$current_branch', not starting with 'merge-public-main'." >&2
    echo "Continue anyway? [y/N]"
    if [[ "$CONFIRM" == "yes" ]]; then
        read -r ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi
fi

echo "Fetching '$BRANCH' from $URL ..."
git fetch "$URL" "$BRANCH"

echo
echo "Incoming commits (HEAD..FETCH_HEAD):"
set +e
git log --oneline --decorate --graph HEAD..FETCH_HEAD
log_status=$?
set -e
if [[ $log_status -ne 0 ]]; then
    echo "(No new commits or unable to show log; continuing.)"
fi

if [[ "$CONFIRM" == "yes" ]]; then
    echo
    read -r -p "Merge FETCH_HEAD into '$current_branch'? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || {
        echo "Aborted."
        exit 1
    }
fi

# Determine if histories are unrelated (shouldn’t be after initial seed, but safe)
ALLOW_FLAG=()
if ! git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null &&
    ! git merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
    # If there is no merge-base, allow unrelated histories
    if ! git merge-base HEAD FETCH_HEAD >/dev/null 2>&1; then
        ALLOW_FLAG=(--allow-unrelated-histories)
    fi
fi

# Get list of auto-generated files BEFORE merge (from HEAD)
# This automatically finds all cython-gen and cybind generated files
# Exclude .sh files to avoid matching this script itself
echo
echo "Identifying auto-generated files..."
GENERATED_FILES_BEFORE_MERGE=$(git grep -l -e 'This code was automatically generated with version' -e 'This code was automatically generated across versions from' 2>/dev/null | cut -d: -f1 | grep -v '\.sh$' | sort -u || true)

if [ -z "$GENERATED_FILES_BEFORE_MERGE" ]; then
    echo "  No auto-generated files found with generation markers"
    GENERATED_FILES_BEFORE_MERGE=""
else
    GENERATED_COUNT=$(echo "$GENERATED_FILES_BEFORE_MERGE" | grep -c . || echo "0")
    echo "  Found $GENERATED_COUNT auto-generated file(s)"
fi

echo
echo "Merging..."
set +e
git merge "${ALLOW_FLAG[@]}" $EDIT_FLAG FETCH_HEAD
MERGE_EXIT=$?
set -e

# If merge had conflicts, automatically resolve conflicts in generated files
if [[ $MERGE_EXIT -ne 0 ]]; then
    if git rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
        if [ -n "$GENERATED_FILES_BEFORE_MERGE" ]; then
            echo
            echo "Resolving conflicts in auto-generated files..."

            RESOLVED_COUNT=0
            SKIPPED_COUNT=0

            # Get list of files with conflicts
            CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
            # Also check git status for unmerged files (UU, AA, etc.)
            UNMERGED_STATUS=$(git status --short 2>/dev/null | grep -E '^UU|^AA|^DD|^AU|^UA|^DU|^UD' | awk '{print $2}' || true)

            while IFS= read -r file; do
                # Skip empty lines
                [ -z "$file" ] && continue

                # Check if file exists in MERGE_HEAD (theirs/public main)
                FILE_IN_THEIRS="no"
                if git rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
                    if git ls-tree -r --name-only MERGE_HEAD 2>/dev/null | grep -Fxq "$file" 2>/dev/null; then
                        FILE_IN_THEIRS="yes"
                    elif git show MERGE_HEAD:"$file" >/dev/null 2>&1; then
                        FILE_IN_THEIRS="yes"
                    fi
                fi

                # Also check merge stages directly - if file has stage 3 (theirs)
                # This handles cases where git's "previous resolution" left files in weird states
                if git ls-files -u "$file" >/dev/null 2>&1; then
                    MERGE_STAGES=$(git ls-files -u "$file" | awk '{print $2}')
                    if echo "$MERGE_STAGES" | grep -q "^3$"; then
                        FILE_IN_THEIRS="yes"
                    fi
                fi

                # Check if file is in conflicted/unmerged state (multiple ways to detect)
                IS_CONFLICTED=false
                if git ls-files -u "$file" >/dev/null 2>&1; then
                    IS_CONFLICTED=true
                elif echo "$CONFLICTED_FILES" | grep -Fxq "$file" 2>/dev/null; then
                    IS_CONFLICTED=true
                elif echo "$UNMERGED_STATUS" | grep -Fxq "$file" 2>/dev/null; then
                    IS_CONFLICTED=true
                fi

                # Case 1: File exists in public main (theirs) - take ours (will be regenerated anyway)
                if [[ "$FILE_IN_THEIRS" == "yes" ]]; then
                    if [[ "$IS_CONFLICTED" == "true" ]]; then
                        echo "Resolving conflict in: $file (taking ours, will be regenerated)"
                        if git checkout --ours "$file" 2>/dev/null || git restore --ours "$file" 2>/dev/null; then
                            git add "$file"
                            ((RESOLVED_COUNT++)) || true
                        else
                            echo "  WARNING: Could not restore --ours for $file" >&2
                        fi
                    else
                        ((SKIPPED_COUNT++)) || true
                    fi
                # Case 2: File removed in public main (theirs) - remove it
                else
                    # File was in our list but not in theirs, so it was removed
                    if [[ "$IS_CONFLICTED" == "true" ]] || [ -f "$file" ]; then
                        echo "Resolving conflict in: $file (removed in public main, removing)"
                        # Try git rm first (handles both index and working tree)
                        if git rm "$file" 2>/dev/null; then
                            ((RESOLVED_COUNT++)) || true
                        else
                            # Fallback: remove from cache and filesystem separately
                            git rm --cached "$file" 2>/dev/null || true
                            rm -f "$file" 2>/dev/null || true
                            # Mark as resolved (deletion)
                            git add "$file" 2>/dev/null || true
                            ((RESOLVED_COUNT++)) || true
                        fi
                    else
                        ((SKIPPED_COUNT++)) || true
                    fi
                fi
            done <<<"$GENERATED_FILES_BEFORE_MERGE"

            echo ""
            echo "Resolved $RESOLVED_COUNT auto-generated file(s)"
            if [ $SKIPPED_COUNT -gt 0 ]; then
                echo "Skipped $SKIPPED_COUNT auto-generated file(s) (no conflicts)"
            fi
        fi

        echo
        echo "Remaining conflicts (if any):"
        git diff --name-only --diff-filter=U || echo "  (none - merge conflicts resolved)"
    else
        echo "ERROR: Merge failed but not in merge state" >&2
        exit 1
    fi
fi

echo
echo "Done."
