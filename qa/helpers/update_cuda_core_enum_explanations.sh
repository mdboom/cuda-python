#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

# Script to update CUDA core enum explanation files
# Usage: update_cuda_core_enum_explanations.sh <CTK_VERSION>
# Example: update_cuda_core_enum_explanations.sh 13.2

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <CTK_VERSION>" >&2
    echo "Example: $0 13.2" >&2
    exit 1
fi

CTK_VERSION="$1"
CTK_VERSION_FULL="${CTK_VERSION}.0" # e.g., 13.2 -> 13.2.0

# Check that we're in the repo root (look for toolshed script)
REPO_ROOT="$(realpath .)"
if [ ! -f "${REPO_ROOT}/toolshed/reformat_cuda_enums_as_py.py" ]; then
    echo "ERROR: Not in ctk-next or cuda-python repository root directory" >&2
    echo "  Current directory: $REPO_ROOT" >&2
    echo "  Expected to find: toolshed/reformat_cuda_enums_as_py.py" >&2
    echo "" >&2
    echo "Please run this script from the repository root directory." >&2
    exit 1
fi

CUDA_HOME="/usr/local/cuda-${CTK_VERSION}"

# Check that CUDA_HOME exists
if [ ! -d "$CUDA_HOME" ]; then
    echo "ERROR: CUDA installation not found at $CUDA_HOME" >&2
    exit 1
fi

# Check that header files exist
DRIVER_HEADER="${CUDA_HOME}/include/cuda.h"
RUNTIME_HEADER="${CUDA_HOME}/include/driver_types.h"

if [ ! -f "$DRIVER_HEADER" ]; then
    echo "ERROR: Driver header not found at $DRIVER_HEADER" >&2
    exit 1
fi

if [ ! -f "$RUNTIME_HEADER" ]; then
    echo "ERROR: Runtime header not found at $RUNTIME_HEADER" >&2
    exit 1
fi

# Target files
DRIVER_TARGET="${REPO_ROOT}/cuda_core/cuda/core/_utils/driver_cu_result_explanations.py"
RUNTIME_TARGET="${REPO_ROOT}/cuda_core/cuda/core/_utils/runtime_cuda_error_explanations.py"

if [ ! -f "$DRIVER_TARGET" ]; then
    echo "ERROR: Driver target file not found at $DRIVER_TARGET" >&2
    exit 1
fi

if [ ! -f "$RUNTIME_TARGET" ]; then
    echo "ERROR: Runtime target file not found at $RUNTIME_TARGET" >&2
    exit 1
fi

echo "Updating CUDA core enum explanations for CTK ${CTK_VERSION}..."
echo "CUDA_HOME: $CUDA_HOME"
echo ""

# Create temporary files for generated output
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

DRIVER_TMP="${TMP_DIR}/driver_enum_output.py"
RUNTIME_TMP="${TMP_DIR}/runtime_enum_output.py"

# Generate driver enum explanations
echo "Generating driver enum explanations..."
python "${REPO_ROOT}/toolshed/reformat_cuda_enums_as_py.py" "$DRIVER_HEADER" >"$DRIVER_TMP" || {
    echo "ERROR: Failed to generate driver enum explanations" >&2
    exit 1
}

# Generate runtime enum explanations
echo "Generating runtime enum explanations..."
python "${REPO_ROOT}/toolshed/reformat_cuda_enums_as_py.py" "$RUNTIME_HEADER" >"$RUNTIME_TMP" || {
    echo "ERROR: Failed to generate runtime enum explanations" >&2
    exit 1
}

# Function to update a target file
update_file() {
    local TARGET_FILE="$1"
    local GENERATED_FILE="$2"
    local DICT_NAME="$3"

    # Find the line number where the dictionary starts
    local DICT_START_LINE
    DICT_START_LINE=$(grep -n "^${DICT_NAME} = {" "$TARGET_FILE" | cut -d: -f1 | head -1)

    if [ -z "$DICT_START_LINE" ]; then
        echo "ERROR: Could not find dictionary start in $TARGET_FILE" >&2
        return 1
    fi

    # Find the line number where the dictionary ends (closing brace on its own line)
    # We need to find the matching closing brace for the dictionary
    local DICT_END_LINE
    DICT_END_LINE=$(awk -v start="$DICT_START_LINE" '
        NR >= start {
            for (i=1; i<=length($0); i++) {
                char = substr($0, i, 1)
                if (char == "{") depth++
                if (char == "}") {
                    depth--
                    if (depth == 0) {
                        print NR
                        exit
                    }
                }
            }
        }
    ' "$TARGET_FILE")

    if [ -z "$DICT_END_LINE" ]; then
        # Fallback: look for standalone closing brace after dictionary start
        DICT_END_LINE=$(awk -v start="$DICT_START_LINE" 'NR >= start && /^}$/ {print NR; exit}' "$TARGET_FILE")
    fi

    if [ -z "$DICT_END_LINE" ]; then
        echo "ERROR: Could not find dictionary end in $TARGET_FILE" >&2
        return 1
    fi

    # Extract header (lines 1 to DICT_START_LINE-1)
    local HEADER_END=$((DICT_START_LINE - 1))
    head -n "$HEADER_END" "$TARGET_FILE" >"${TMP_DIR}/header.txt"

    # Update version number in header if present
    sed -i "s/# CUDA Toolkit v[0-9.]*/# CUDA Toolkit v${CTK_VERSION_FULL}/" "${TMP_DIR}/header.txt"

    # Extract footer (everything after the dictionary closing brace)
    local TOTAL_LINES
    TOTAL_LINES=$(wc -l <"$TARGET_FILE")
    local FOOTER_START=$((DICT_END_LINE + 1))
    if [ "$FOOTER_START" -le "$TOTAL_LINES" ]; then
        tail -n +$FOOTER_START "$TARGET_FILE" >"${TMP_DIR}/footer.txt"
    else
        touch "${TMP_DIR}/footer.txt"
    fi

    # Combine header, generated dictionary, and footer
    cat "${TMP_DIR}/header.txt" "$GENERATED_FILE" "${TMP_DIR}/footer.txt" >"${TMP_DIR}/updated.txt"

    # Replace the original file
    mv "${TMP_DIR}/updated.txt" "$TARGET_FILE"
}

# Update driver file
echo "Updating driver_cu_result_explanations.py..."
update_file "$DRIVER_TARGET" "$DRIVER_TMP" "DRIVER_CU_RESULT_EXPLANATIONS" || exit 1

# Update runtime file
echo "Updating runtime_cuda_error_explanations.py..."
update_file "$RUNTIME_TARGET" "$RUNTIME_TMP" "RUNTIME_CUDA_ERROR_EXPLANATIONS" || exit 1

# Format files with ruff via pre-commit
# Run twice: first run applies fixes (may exit non-zero), second run verifies success
echo ""
echo "Formatting files with ruff (via pre-commit)..."
pre-commit run --all-files ruff-format || true # First run: apply fixes, ignore exit code
pre-commit run --all-files ruff-format         # Second run: verify formatting is correct

# Run ruff-check to catch any linting issues
echo ""
echo "Checking files with ruff (via pre-commit)..."
pre-commit run --all-files ruff-check || true # First run: apply fixes, ignore exit code
pre-commit run --all-files ruff-check         # Second run: verify linting is correct

# Verify files compile
echo ""
echo "Verifying files compile..."
python -m py_compile "$DRIVER_TARGET" || {
    echo "ERROR: Driver file does not compile" >&2
    exit 1
}

python -m py_compile "$RUNTIME_TARGET" || {
    echo "ERROR: Runtime file does not compile" >&2
    exit 1
}

echo ""
echo "Files updated:"
echo "  - $DRIVER_TARGET"
echo "  - $RUNTIME_TARGET"

# Report git diff if there are changes
echo ""
echo "Checking for changes..."
GIT_DIFF_OUTPUT=$(git diff "$DRIVER_TARGET" "$RUNTIME_TARGET" 2>/dev/null || true)
if [ -n "$GIT_DIFF_OUTPUT" ]; then
    DIFF_LINES=$(echo "$GIT_DIFF_OUTPUT" | wc -l)
    echo "Changes detected (${DIFF_LINES} lines):"
    echo ""
    echo "$GIT_DIFF_OUTPUT" | head -10
    if [ "$DIFF_LINES" -gt 10 ]; then
        echo "... (${DIFF_LINES} total lines, showing first 10)"
    fi
    echo ""
    echo "Review the changes: git diff cuda_core/cuda/core/_utils/"
else
    echo "No changes detected (files are already up to date)"
fi
