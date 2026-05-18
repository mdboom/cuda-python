#!/bin/bash

TAG="${1?Usage: $0 <tag>}"

# Get commit info for the tag
COMMIT_HASH=$(git rev-list -n 1 "$TAG" 2>/dev/null) || {
    echo "Error: tag '$TAG' not found"
    exit 1
}
COMMIT_DATE=$(TZ='America/Los_Angeles' git show -s --format='%cd' --date=format-local:'%a %b %d %H:%M:%S %Y %z' "$COMMIT_HASH")
COMMIT_MSG=$(git show -s --format='%s' "$COMMIT_HASH")

# Extract PR number from commit message (expects format like "... (#123)")
PR_NUM=$(echo "$COMMIT_MSG" | grep -oE '#[0-9]+' | tail -1 | tr -d '#')
[ -z "$PR_NUM" ] && {
    echo "Error: no PR number found in commit message"
    exit 1
}

PR_URL="https://github.com/NVIDIA/cuda-python-private/pull/${PR_NUM}"

echo "* ${PR_URL} — Merged ${COMMIT_DATE} — commit ${COMMIT_HASH}, tag: ${TAG}"
