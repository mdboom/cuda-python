#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Prepare a squash-merge of the private `ctk-next` branch into the public repo,
# excluding QA-only paths (e.g., the `qa/` directory).
#
# Typical workflow (run from a clean working tree in the public repo):
#   cuda-python/toolshed/git_squash-merge_ctk-next.sh --yes --push
#
# What it does:
#   1) Updates the base branch (default: main)
#   2) Creates a new branch (default: merge-ctk-next) from the base
#   3) Fetches the private branch (default: ctk-next) from URL (default: NVIDIA/cuda-python-private)
#   4) `git merge --squash --no-commit FETCH_HEAD`
#   5) Excludes configured paths (default: qa/)
#   6) Commits with a standardized message
#   7) Optionally pushes to origin
#
# Options:
#   -u, --url URL              Source repo URL (private). Default:
#                                git@github.com:NVIDIA/cuda-python-private.git
#   -s, --source-branch BR     Source branch in private repo (default: ctk-next)
#   -b, --base BR              Base branch in public repo (default: main)
#   -n, --new-branch BR        New branch to create (default: merge-ctk-next)
#   -x, --exclude PATH         Exclude path (repeatable; default: qa)
#       --edit                 Open editor for squash commit (default: --no-edit)
#       --signoff              Add Signed-off-by line to commit
#       --show-commits         Show upstream commits to be squashed
#   -y, --yes                  Non-interactive; skip confirmations
#       --push                 Push resulting branch to origin
#   -h, --help                 Show this help
#
# Most of this script is for checking preconditions and error conditions.
# The core functionality is:
#
#   git fetch origin main
#   git switch main
#   git pull
#   git switch -c merge-ctk-next
#   git fetch git@github.com:NVIDIA/cuda-python-private.git ctk-next
#   git merge --squash FETCH_HEAD
#   git restore --staged --worktree --source=HEAD -- qa
#   git commit -m "Squash-merge private 'ctk-next' into public 'main' (exclude: qa)"
#   git push -u origin merge-ctk-next
#
set -euo pipefail

URL_DEFAULT="git@github.com:NVIDIA/cuda-python-private.git"
SRC_BRANCH_DEFAULT="ctk-next"
BASE_DEFAULT="main"
NEW_BRANCH_DEFAULT="merge-ctk-next"

URL="$URL_DEFAULT"
SRC_BRANCH="$SRC_BRANCH_DEFAULT"
BASE="$BASE_DEFAULT"
NEW_BRANCH="$NEW_BRANCH_DEFAULT"
EXCLUDES=("qa") # paths relative to repo root; can repeat -x

CONFIRM="yes"
DO_PUSH="no"
EDIT_FLAG="--no-edit"
SIGNOFF=""
SHOW_COMMITS="no"

print_help() {
    sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//'
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
    -u | --url)
        URL="${2:-}"
        shift 2
        ;;
    -s | --source-branch)
        SRC_BRANCH="${2:-}"
        shift 2
        ;;
    -b | --base)
        BASE="${2:-}"
        shift 2
        ;;
    -n | --new-branch)
        NEW_BRANCH="${2:-}"
        shift 2
        ;;
    -x | --exclude)
        EXCLUDES+=("${2:-}")
        shift 2
        ;;
    --edit)
        EDIT_FLAG="--edit"
        shift
        ;;
    --signoff)
        SIGNOFF="--signoff"
        shift
        ;;
    --show-commits)
        SHOW_COMMITS="yes"
        shift
        ;;
    -y | --yes)
        CONFIRM="no"
        shift
        ;;
    --push)
        DO_PUSH="yes"
        shift
        ;;
    -h | --help)
        print_help
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        print_help
        exit 2
        ;;
    esac
done

# Sanity checks
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: working tree is not clean. Commit/stash/discard changes first." >&2
    exit 1
fi

# Ensure we have the latest base
echo "Fetching and fast-forwarding '$BASE' from origin..."
git fetch origin "$BASE"
git switch "$BASE"
git pull --ff-only

# Create or reset the destination branch from the updated base
echo "Creating new branch '$NEW_BRANCH' from '$BASE'..."
git switch -c "$NEW_BRANCH"

# Fetch the source private branch
echo "Fetching '$SRC_BRANCH' from $URL ..."
git fetch "$URL" "$SRC_BRANCH"

# Optionally show commits that will be included
if [[ "$SHOW_COMMITS" == "yes" ]]; then
    echo
    echo "Upstream commits to be squashed (relative to merge base):"
    # Safely compute log from merge base to FETCH_HEAD
    if MB=$(git merge-base HEAD FETCH_HEAD); then
        git log --oneline --decorate --graph "$MB"..FETCH_HEAD || true
    else
        echo "(No merge-base; histories may be unrelated — proceeding regardless.)"
        git log --oneline --decorate --graph FETCH_HEAD || true
    fi
fi

if [[ "$CONFIRM" == "yes" ]]; then
    echo
    read -r -p "Proceed with squash of '$SRC_BRANCH' into '$NEW_BRANCH' and exclude paths: ${EXCLUDES[*]} ? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || {
        echo "Aborted."
        exit 1
    }
fi

# Stage a squash merge but do not commit yet
echo
echo "Squashing (staging changes without committing)..."
git merge --squash --no-commit FETCH_HEAD

# Exclude paths (reset them back to HEAD, i.e., the base branch state)
echo
echo "Excluding paths from squash commit: ${EXCLUDES[*]}"
for p in "${EXCLUDES[@]}"; do
    # Normalize: strip trailing slashes for messaging; but pass as-is to git
    echo " - $p"
    # Reset both index and worktree for that path back to HEAD
    git restore --staged --worktree --source=HEAD -- "$p" 2>/dev/null || true
done

# Build a conventional commit message
echo
echo "Creating squash commit..."
SQUASH_MSG="Squash-merge private '${SRC_BRANCH}' into public '${BASE}' (exclude: ${EXCLUDES[*]})"

# Optionally append a short included-commits list (best-effort)
if MB=$(git merge-base HEAD FETCH_HEAD 2>/dev/null); then
    INCLUDED=$(git log --oneline "$MB"..FETCH_HEAD | sed 's/^/  - /' || true)
    if [[ -n "$INCLUDED" ]]; then
        SQUASH_MSG+=$'\n\nIncluded commits (from private branch):\n'"$INCLUDED"
    fi
fi

git commit $SIGNOFF $EDIT_FLAG -m "$SQUASH_MSG"

# Optional push
if [[ "$DO_PUSH" == "yes" ]]; then
    echo
    echo "Pushing '$NEW_BRANCH' to origin..."
    git push -u origin "$NEW_BRANCH"
fi

echo
echo "Done."
echo "Branch '$NEW_BRANCH' is ready. Open a PR to merge into '$BASE'."
