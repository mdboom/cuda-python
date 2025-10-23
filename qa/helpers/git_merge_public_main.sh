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
#   - (Optional) pushes the result to the branch’s upstream with --push
#
# Usage:
#   qa/helpers/git_merge_public_main.sh [-u URL] [-b BRANCH] [--yes] [--push] [--edit]
#
# Examples:
#   qa/helpers/git_merge_public_main.sh
#   qa/helpers/git_merge_public_main.sh -b main
#   qa/helpers/git_merge_public_main.sh -u https://github.com/NVIDIA/cuda-python.git -b main --yes --push
#
# Most of this script is for checking preconditions and error conditions.
# The core functionality is simply:
#
#   git fetch https://github.com/NVIDIA/cuda-python.git main
#   git merge FETCH_HEAD
#   git push
#
set -euo pipefail

URL_DEFAULT="https://github.com/NVIDIA/cuda-python.git"
BRANCH_DEFAULT="main"
CONFIRM="yes"
DO_PUSH="no"
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
    --push)
        DO_PUSH="yes"
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

if [[ "$current_branch" != "ctk-next" ]]; then
    echo "Warning: current branch is '$current_branch', not 'ctk-next'." >&2
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

echo
echo "Merging..."
git merge "${ALLOW_FLAG[@]}" $EDIT_FLAG FETCH_HEAD

if [[ "$DO_PUSH" == "yes" ]]; then
    echo
    echo "Pushing to upstream..."
    # Push to the branch’s configured upstream (safer in multi-remote setups)
    if upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
        git push
    else
        echo "No upstream configured for '$current_branch'. Attempting to push to 'upstream' remote..."
        if git remote get-url upstream >/dev/null 2>&1; then
            git push -u upstream "$current_branch"
        else
            echo "Remote 'upstream' not found. Skipping push."
        fi
    fi
fi

echo
echo "Done."
