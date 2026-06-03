#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Create a squash-merge preview branch for merging a branch into public main.
#
# Usage:
#   qa/helpers/make_squash_merge_into_public_main_preview.sh <branch-name> <ctk-version>
#
# IMPORTANT: Before creating the squash-merge preview, ensure that there are
# no missing legacy or native cybind updates on the branch.

set -euo pipefail

# Check that exactly two arguments are provided
if [ $# -ne 2 ]; then
    echo "ERROR: Exactly two arguments required (branch-name and ctk-version)" >&2
    echo "Usage: $0 <branch-name> <ctk-version>" >&2
    exit 1
fi

BRANCH_NAME="$1"
CTK_TARGET_VERSION="$2"
HASH_DRIFT_COMMIT_MESSAGE="cybind-generated version hash drift (NO MANUAL CHANGES)"

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

run_pre_commit_until_clean() {
    # First run may exit non-zero after auto-fixing files; the second must pass.
    set +e
    pre-commit run --all-files
    PRE_COMMIT_EXIT=$?
    set -e
    if [ $PRE_COMMIT_EXIT -ne 0 ]; then
        echo "Exit code from first pre-commit run was $PRE_COMMIT_EXIT, rerunning..."
        pre-commit run --all-files
    fi
}

commit_if_changed() {
    local message="$1"

    if [ -z "$(git status --porcelain)" ]; then
        echo "No changes for: $message"
        return
    fi

    git add -A
    git commit -m "$message"
}

staged_file_has_generated_version_hash_drift() {
    local file="$1"

    git diff --cached --unified=0 -- "$file" | awk '
    function is_generated_version_line(line) {
        return line ~ /^[-+]# This code was automatically generated across versions from .*generator version .*dev[0-9]+[+-]g[0-9a-f]+/
    }
    is_generated_version_line($0) {
        if (substr($0, 1, 1) == "-") {
            minus_count++
        } else {
            plus_count++
        }
    }
    END {
        if (minus_count == 0 || minus_count != plus_count) {
            exit 1
        }
    }'
}

staged_generated_version_hash_drift_files() {
    local file

    while IFS= read -r -d "" file; do
        if staged_file_has_generated_version_hash_drift "$file"; then
            printf "%s\0" "$file"
        fi
    done < <(git diff --cached --name-only -z --)
}

validate_generated_version_hash_drift_commit() {
    local commit="$1"
    local validation_output
    local validation_exit

    set +e
    validation_output=$(git show --format= --unified=0 "$commit" | awk '
    function is_generated_version_line(line) {
        return line ~ /^[-+]# This code was automatically generated across versions from .*generator version .*dev[0-9]+[+-]g[0-9a-f]+/
    }
    function is_spdx_copyright_line(line) {
        return line ~ /^[-+]# SPDX-FileCopyrightText: /
    }
    function is_allowed_metadata_line(line) {
        return is_generated_version_line(line) || is_spdx_copyright_line(line)
    }
    function reset_hunk() {
        minus_count = 0
        plus_count = 0
    }
    function flush_hunk() {
        if (minus_count != plus_count) {
            print current_file ": unmatched generated version metadata line(s)"
            bad = 1
        }
        reset_hunk()
    }
    BEGIN {
        current_file = "<unknown>"
        reset_hunk()
    }
    /^diff --git / {
        flush_hunk()
        current_file = $0
        next
    }
    /^\+\+\+ b\// {
        current_file = substr($0, 7)
        next
    }
    /^@@ / {
        flush_hunk()
        next
    }
    /^(index |--- |\+\+\+ |new file mode|deleted file mode|similarity index|rename from|rename to)/ {
        next
    }
    /^[-+]/ {
        if (!is_allowed_metadata_line($0)) {
            print current_file ": unexpected changed line"
            print "  " $0
            bad = 1
            next
        }
        if (substr($0, 1, 1) == "-") {
            minus_count++
        } else {
            plus_count++
        }
        next
    }
    END {
        flush_hunk()
        exit bad
    }')
    validation_exit=$?
    set -e

    if [ $validation_exit -ne 0 ]; then
        echo "ERROR: Commit $commit ($HASH_DRIFT_COMMIT_MESSAGE) contains unexpected changes." >&2
        echo "Please review that commit manually before using this preview branch." >&2
        echo >&2
        echo "$validation_output" | sed "s/^/  /" >&2
        return 1
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

# Source activate_helpers.sh to get run_cybind_cython_gen and run_cybind_native functions
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

cd "$PARENT_DIR/cybind"
run_cybind_cython_gen "$CTK_TARGET_VERSION" "$WORKTREE_PATH"
cd "$WORKTREE_PATH"
run_pre_commit_until_clean
commit_if_changed "run_cybind_cython_gen $CTK_TARGET_VERSION ../ctk-next (NO MANUAL CHANGES)"

cd "$PARENT_DIR/cybind"
run_cybind_native "$CTK_TARGET_VERSION" "$WORKTREE_PATH"
cd "$WORKTREE_PATH"
run_pre_commit_until_clean
commit_if_changed "run_cybind_native $CTK_TARGET_VERSION ../ctk-next (NO MANUAL CHANGES)"

# Get list of generated files BEFORE squash merge (from the branch we're merging)
# This automatically finds legacy and native cybind-generated files
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

HASH_DRIFT_FILES=()
mapfile -d "" HASH_DRIFT_FILES < <(staged_generated_version_hash_drift_files)
HASH_DRIFT_COMMIT=""
if [ ${#HASH_DRIFT_FILES[@]} -ne 0 ]; then
    echo
    echo "Splitting generated version hash drift into a separate commit..."
    printf "  %s\n" "${HASH_DRIFT_FILES[@]}"

    git reset --quiet
    git add -- "${HASH_DRIFT_FILES[@]}"
    git commit -m "$HASH_DRIFT_COMMIT_MESSAGE"
    HASH_DRIFT_COMMIT=$(git rev-parse HEAD)
else
    echo
    echo "No generated version hash drift files found."
fi

FINAL_SQUASH_COMMIT=""
TRANSFER_PATCH="$PARENT_DIR/${PREVIEW_BRANCH}_non_gen_transfer.patch"
BEFORE_FINAL_COMMIT=$(git rev-parse HEAD)
git add -A
commit_if_changed "git merge --squash $BRANCH_NAME && git rm -r -f qa/ (NO MANUAL CHANGES)"
AFTER_FINAL_COMMIT=$(git rev-parse HEAD)
if [ "$AFTER_FINAL_COMMIT" != "$BEFORE_FINAL_COMMIT" ]; then
    FINAL_SQUASH_COMMIT="$AFTER_FINAL_COMMIT"
    git show --format= --binary "$FINAL_SQUASH_COMMIT" >"$TRANSFER_PATCH"
    echo
    echo "Non-generated transfer patch written to:"
    echo "  $TRANSFER_PATCH"
else
    echo
    echo "No final squash commit was created; no non-generated transfer patch written."
fi

HASH_DRIFT_VALIDATION_EXIT=0
if [ -n "$HASH_DRIFT_COMMIT" ]; then
    echo
    echo "Validating generated version hash drift commit..."
    if validate_generated_version_hash_drift_commit "$HASH_DRIFT_COMMIT"; then
        echo "  $HASH_DRIFT_COMMIT contains only expected generated version hash changes"
    else
        HASH_DRIFT_VALIDATION_EXIT=1
    fi
fi

# Show diff, filtering out hash-only changes
echo
echo "Diff between $BRANCH_NAME and current branch (excluding qa/):"
DIFF_OUTPUT=$(git diff "$BRANCH_NAME" -- . ':(exclude)qa' 2>&1 || true)
if [ -z "$DIFF_OUTPUT" ]; then
    echo "  (no differences)"
else
    # Filter out hunks that only contain hash changes
    # Use the reusable filter script from the original checkout; qa/ has been
    # removed from the preview worktree by this point.
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
echo "Preview branch commit stack:"
git log --oneline --reverse public_repo/main..HEAD

echo
echo "The new branch is ready under $(realpath "$WORKTREE_PATH")"
echo
echo "Hint: To clean up the worktree later:"
echo "  cd $CTK_NEXT_ROOT"
echo "  git worktree remove $WORKTREE_PATH"

if [ $HASH_DRIFT_VALIDATION_EXIT -ne 0 ]; then
    echo >&2
    echo "ERROR: Preview branch was created, but the generated version hash drift commit needs review." >&2
    exit 1
fi
