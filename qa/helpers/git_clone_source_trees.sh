#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE
#
# Clone the standard sibling source trees used for ctk-next QA work and
# configure `upstream`/`origin` remotes for each checkout.
#
# Usage:
#   qa/helpers/git_clone_source_trees.sh [--gitlab-username <gitlab-username>] [--tolerate-missing-forks] <github-username> [repo...]
#
# Repos:
#   cuda-python
#   ctk-next
#   cybind
#
# Examples:
#   qa/helpers/git_clone_source_trees.sh ghusername
#   qa/helpers/git_clone_source_trees.sh ghusername ctk-next
#   qa/helpers/git_clone_source_trees.sh ghusername cuda-python cybind
#   qa/helpers/git_clone_source_trees.sh ghusername --gitlab-username nvusername cybind
#   qa/helpers/git_clone_source_trees.sh --tolerate-missing-forks ghusername
#
# Notes:
#   - If no repo names are provided, all three source trees are cloned.
#   - Existing checkout directories are reported and skipped.
#   - Missing forks are checked before any clone starts.
#   - Use `--tolerate-missing-forks` to continue anyway.
#   - For `cybind`, the fork namespace defaults to `$USER`; override with
#     `--gitlab-username` if your GitLab namespace is different.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
export GIT_PAGER=

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [--gitlab-username <gitlab-username>] [--tolerate-missing-forks] <github-username> [repo...]

Repos:
  cuda-python
  ctk-next
  cybind

Examples:
  $SCRIPT_NAME ghusername
  $SCRIPT_NAME ghusername ctk-next
  $SCRIPT_NAME ghusername cuda-python cybind
  $SCRIPT_NAME ghusername --gitlab-username nvusername cybind
  $SCRIPT_NAME --tolerate-missing-forks ghusername

Notes:
  - If no repo names are provided, all three source trees are cloned.
  - Existing checkout directories are reported and skipped.
  - Required forks are checked before any clone starts.
  - Fork checks are skipped for repos that already exist locally.
  - Use --tolerate-missing-forks to continue even if a fork is missing.
  - For cybind, the GitLab namespace defaults to \$USER.
EOF
}

err() {
    echo "ERROR: $*" >&2
}

warn() {
    echo "WARNING: $*" >&2
}

append_unique_repo() {
    local repo="$1"
    local existing
    for existing in "${SELECTED_REPOS[@]}"; do
        if [[ "$existing" == "$repo" ]]; then
            return 0
        fi
    done
    SELECTED_REPOS+=("$repo")
}

selected_repo_exists() {
    local repo="$1"
    local existing
    for existing in "${SELECTED_REPOS[@]}"; do
        if [[ "$existing" == "$repo" ]]; then
            return 0
        fi
    done
    return 1
}

missing_fork_recorded_for_repo() {
    local repo="$1"
    local existing
    for existing in "${MISSING_FORK_REPOS[@]}"; do
        if [[ "$existing" == "$repo" ]]; then
            return 0
        fi
    done
    return 1
}

resolve_repo_config() {
    local repo="$1"

    BRANCH_NAME=""
    UPSTREAM_FETCH_URL=""
    UPSTREAM_PUSH_URL=""
    ORIGIN_FETCH_URL=""
    ORIGIN_PUSH_URL=""
    CLONE_DIR=""

    case "$repo" in
    cuda-python)
        CLONE_DIR="cuda-python"
        UPSTREAM_FETCH_URL="https://github.com/NVIDIA/cuda-python.git"
        UPSTREAM_PUSH_URL="git@github.com:NVIDIA/cuda-python.git"
        ORIGIN_FETCH_URL="https://github.com/${GITHUB_USERNAME}/cuda-python.git"
        ORIGIN_PUSH_URL="git@github.com:${GITHUB_USERNAME}/cuda-python.git"
        ;;
    ctk-next)
        CLONE_DIR="ctk-next"
        BRANCH_NAME="ctk-next"
        UPSTREAM_FETCH_URL="git@github.com:NVIDIA/cuda-python-private.git"
        UPSTREAM_PUSH_URL="$UPSTREAM_FETCH_URL"
        ORIGIN_FETCH_URL="git@github.com:${GITHUB_USERNAME}/cuda-python-private.git"
        ORIGIN_PUSH_URL="$ORIGIN_FETCH_URL"
        ;;
    cybind)
        CLONE_DIR="cybind"
        UPSTREAM_FETCH_URL="ssh://git@gitlab-master.nvidia.com:12051/leof/cybind.git"
        UPSTREAM_PUSH_URL="$UPSTREAM_FETCH_URL"
        ORIGIN_FETCH_URL="ssh://git@gitlab-master.nvidia.com:12051/${GITLAB_USERNAME}/cybind.git"
        ORIGIN_PUSH_URL="$ORIGIN_FETCH_URL"
        ;;
    *)
        err "Unknown repo: $repo"
        return 1
        ;;
    esac
}

preflight_required_forks() {
    local repo
    local clone_target_path

    echo "Preflight: checking required forks before cloning..."
    for repo in "${SELECTED_REPOS[@]}"; do
        resolve_repo_config "$repo" || return 1
        clone_target_path="$PWD/$CLONE_DIR"

        if [[ -e "$CLONE_DIR" ]]; then
            echo "  Skipping fork check for '$repo': path already exists at $clone_target_path (clone phase will skip this repo)"
            PREFLIGHT_SKIPPED_REPOS+=("$repo")
            continue
        fi

        echo "  Checking '$repo' fork: $ORIGIN_FETCH_URL"
        PREFLIGHT_CHECKED_REPOS+=("$repo")
        if ! git ls-remote "$ORIGIN_FETCH_URL" >/dev/null 2>&1; then
            MISSING_FORK_REPOS+=("$repo")
            MISSING_FORK_DETAILS+=("$repo -> $ORIGIN_FETCH_URL")
        fi
    done

    if [[ ${#PREFLIGHT_CHECKED_REPOS[@]} -eq 0 ]]; then
        echo "Preflight: all selected repositories already exist locally, so no fork reachability checks were run."
        echo "Preflight: this run does not validate the supplied usernames."
        echo
        return 0
    fi

    if [[ ${#PREFLIGHT_SKIPPED_REPOS[@]} -gt 0 ]]; then
        echo "Preflight: fork checks were skipped for existing directories: ${PREFLIGHT_SKIPPED_REPOS[*]}"
    fi

    if [[ ${#MISSING_FORK_REPOS[@]} -eq 0 ]]; then
        echo "Preflight: no blocking fork issues detected for repositories that need cloning."
        echo
        return 0
    fi

    if [[ "$TOLERATE_MISSING_FORKS" == "yes" ]]; then
        warn "Continuing despite missing or inaccessible forks because --tolerate-missing-forks was requested."
        for repo in "${MISSING_FORK_REPOS[@]}"; do
            WARNED_REPOS+=("$repo (missing or inaccessible fork tolerated)")
        done
        for detail in "${MISSING_FORK_DETAILS[@]}"; do
            echo "  - $detail" >&2
        done
        echo >&2
        return 0
    fi

    err "Required fork check failed before cloning."
    echo "The following required forks are missing or inaccessible:" >&2
    for detail in "${MISSING_FORK_DETAILS[@]}"; do
        echo "  - $detail" >&2
    done
    echo >&2
    echo "No clone commands were run." >&2
    echo "Create the missing fork(s), then re-run this command." >&2
    echo "If you really want to continue anyway, pass --tolerate-missing-forks." >&2
    exit 1
}

configure_cloned_repo() {
    local repo="$1"

    (
        cd "$CLONE_DIR"

        echo "Renaming 'origin' to 'upstream'"
        git remote rename origin upstream

        if [[ "$UPSTREAM_PUSH_URL" != "$UPSTREAM_FETCH_URL" ]]; then
            git remote set-url --push upstream "$UPSTREAM_PUSH_URL"
        fi

        echo "Adding fork as 'origin': $ORIGIN_FETCH_URL"
        git remote add origin "$ORIGIN_FETCH_URL"

        if [[ "$ORIGIN_PUSH_URL" != "$ORIGIN_FETCH_URL" ]]; then
            git remote set-url --push origin "$ORIGIN_PUSH_URL"
        fi

        if missing_fork_recorded_for_repo "$repo"; then
            warn "Skipping 'git fetch origin' for '$repo' because fork preflight failed."
        elif ! git fetch origin; then
            warn "Could not fetch origin for '$repo'. The fork may not exist yet, or access may be missing."
            WARNED_REPOS+=("$repo (origin fetch failed)")
        fi

        echo
        echo "Your remotes:"
        git remote -v
        echo
        echo "Your branches:"
        git branch --all
        echo
    )
}

clone_one_repo() {
    local repo="$1"

    resolve_repo_config "$repo" || return 1

    echo "==> $repo"

    if [[ -e "$CLONE_DIR" ]]; then
        echo "Skipping clone for '$repo': path already exists at $PWD/$CLONE_DIR"
        echo
        SKIPPED_REPOS+=("$repo")
        return 0
    fi

    echo "Cloning upstream: $UPSTREAM_FETCH_URL"
    if [[ -n "$BRANCH_NAME" ]]; then
        echo "Using branch: $BRANCH_NAME"
        if ! git clone --branch "$BRANCH_NAME" "$UPSTREAM_FETCH_URL" "$CLONE_DIR"; then
            err "git clone failed for '$repo'"
            FAILED_REPOS+=("$repo")
            echo
            return 1
        fi
    else
        if ! git clone "$UPSTREAM_FETCH_URL" "$CLONE_DIR"; then
            err "git clone failed for '$repo'"
            FAILED_REPOS+=("$repo")
            echo
            return 1
        fi
    fi

    if ! configure_cloned_repo "$repo"; then
        err "Remote configuration failed for '$repo'"
        FAILED_REPOS+=("$repo")
        echo
        return 1
    fi

    CLONED_REPOS+=("$repo")
    return 0
}

GITHUB_USERNAME=""
GITLAB_USERNAME="${USER:-}"
TOLERATE_MISSING_FORKS="no"
declare -a REQUESTED_REPOS=()
declare -a SELECTED_REPOS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
    --gitlab-username | -g)
        shift
        if [[ $# -eq 0 ]]; then
            err "--gitlab-username requires a value"
            usage
            exit 1
        fi
        GITLAB_USERNAME="$1"
        shift
        ;;
    --tolerate-missing-forks)
        TOLERATE_MISSING_FORKS="yes"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --)
        shift
        while [[ $# -gt 0 ]]; do
            if [[ -z "$GITHUB_USERNAME" ]]; then
                GITHUB_USERNAME="$1"
            else
                REQUESTED_REPOS+=("$1")
            fi
            shift
        done
        ;;
    -*)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    *)
        if [[ -z "$GITHUB_USERNAME" ]]; then
            GITHUB_USERNAME="$1"
        else
            REQUESTED_REPOS+=("$1")
        fi
        shift
        ;;
    esac
done

if [[ -z "$GITHUB_USERNAME" ]]; then
    err "Missing <github-username>"
    usage
    exit 1
fi

if [[ ${#REQUESTED_REPOS[@]} -eq 0 ]]; then
    REQUESTED_REPOS=(cuda-python ctk-next cybind)
fi

for repo in "${REQUESTED_REPOS[@]}"; do
    case "$repo" in
    cuda-python | ctk-next | cybind)
        append_unique_repo "$repo"
        ;;
    *)
        err "Unknown repo: $repo"
        echo "Valid repo names: cuda-python ctk-next cybind" >&2
        usage
        exit 1
        ;;
    esac
done

if selected_repo_exists cybind && [[ -z "$GITLAB_USERNAME" ]]; then
    err "Could not determine GitLab username from \$USER"
    echo "Pass --gitlab-username <name> to clone cybind." >&2
    exit 1
fi

echo "GitHub username: $GITHUB_USERNAME"
echo "GitLab username: $GITLAB_USERNAME"
echo "Repositories: ${SELECTED_REPOS[*]}"
echo "Tolerate missing forks: $TOLERATE_MISSING_FORKS"
echo

declare -a CLONED_REPOS=()
declare -a SKIPPED_REPOS=()
declare -a FAILED_REPOS=()
declare -a WARNED_REPOS=()
declare -a MISSING_FORK_REPOS=()
declare -a MISSING_FORK_DETAILS=()
declare -a PREFLIGHT_CHECKED_REPOS=()
declare -a PREFLIGHT_SKIPPED_REPOS=()

preflight_required_forks

for repo in "${SELECTED_REPOS[@]}"; do
    clone_one_repo "$repo" || true
done

echo "Run summary:"
if [[ ${#PREFLIGHT_CHECKED_REPOS[@]} -gt 0 ]]; then
    echo "  Preflight checked: ${PREFLIGHT_CHECKED_REPOS[*]}"
else
    echo "  Preflight checked: (none)"
fi

if [[ ${#PREFLIGHT_SKIPPED_REPOS[@]} -gt 0 ]]; then
    echo "  Preflight skipped (directory exists): ${PREFLIGHT_SKIPPED_REPOS[*]}"
else
    echo "  Preflight skipped (directory exists): (none)"
fi

if [[ ${#CLONED_REPOS[@]} -gt 0 ]]; then
    echo "  Cloned:  ${CLONED_REPOS[*]}"
else
    echo "  Cloned:  (none)"
fi

if [[ ${#SKIPPED_REPOS[@]} -gt 0 ]]; then
    echo "  Skipped: ${SKIPPED_REPOS[*]}"
else
    echo "  Skipped: (none)"
fi

if [[ ${#WARNED_REPOS[@]} -gt 0 ]]; then
    echo "  Warnings: ${WARNED_REPOS[*]}"
else
    echo "  Warnings: (none)"
fi

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
    echo "  Failed:  ${FAILED_REPOS[*]}"
    exit 1
else
    echo "  Failed:  (none)"
fi
