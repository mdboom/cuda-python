#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

# Script to update cybind headers from a CUDA Toolkit installation
# Usage: cybind_header_update.sh <version>
# Example: cybind_header_update.sh 13.2

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <CTK-version>" >&2
    echo "Example: $0 13.2" >&2
    exit 1
fi

CTK_VERSION="$1"
CTK_VERSION_DIR="${CTK_VERSION}.0" # e.g., 13.2 -> 13.2.0

CUDA_HOME="/usr/local/cuda-${CTK_VERSION}"

# Check that CUDA_HOME exists
if [ ! -d "$CUDA_HOME" ]; then
    echo "ERROR: CUDA installation not found at $CUDA_HOME" >&2
    exit 1
fi

CYBIND_DIR="$(realpath .)"
if [ ! -d "${CYBIND_DIR}/cybind/assets/headers" ]; then
    echo "ERROR: Not in cybind repository root directory" >&2
    echo "  Current directory: $CYBIND_DIR" >&2
    echo "  Expected to find: cybind/assets/headers/" >&2
    echo "" >&2
    echo "Please run this script from the cybind repository root directory." >&2
    echo "Example: cd /path/to/cybind && $0 $CTK_VERSION" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/cybind_cufile.patch"

# Check that patch file exists
if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Patch file not found at $PATCH_FILE" >&2
    exit 1
fi

echo "Updating cybind headers for CTK ${CTK_VERSION}..."
echo "CUDA_HOME: $CUDA_HOME"
echo "cybind directory: $CYBIND_DIR"
echo ""

# Copy headers
echo "Copying headers..."

# cufile.h
CUFILE_SRC="${CUDA_HOME}/include/cufile.h"
CUFILE_DST="${CYBIND_DIR}/cybind/assets/headers/cufile/${CTK_VERSION_DIR}/cufile.h"
if [ -f "$CUFILE_SRC" ]; then
    mkdir -p "$(dirname "$CUFILE_DST")"
    cp "$CUFILE_SRC" "$CUFILE_DST"
    echo "  Copied cufile.h"
else
    echo "  WARNING: cufile.h not found at $CUFILE_SRC" >&2
fi

# nvJitLink.h
NVJITLINK_SRC="${CUDA_HOME}/include/nvJitLink.h"
NVJITLINK_DST="${CYBIND_DIR}/cybind/assets/headers/nvJitLink/${CTK_VERSION_DIR}/nvJitLink.h"
if [ -f "$NVJITLINK_SRC" ]; then
    mkdir -p "$(dirname "$NVJITLINK_DST")"
    cp "$NVJITLINK_SRC" "$NVJITLINK_DST"
    echo "  Copied nvJitLink.h"
else
    echo "  WARNING: nvJitLink.h not found at $NVJITLINK_SRC" >&2
fi

# nvml.h
NVML_SRC="${CUDA_HOME}/include/nvml.h"
NVML_DST="${CYBIND_DIR}/cybind/assets/headers/nvml/${CTK_VERSION_DIR}/nvml.h"
if [ -f "$NVML_SRC" ]; then
    mkdir -p "$(dirname "$NVML_DST")"
    cp "$NVML_SRC" "$NVML_DST"
    echo "  Copied nvml.h"
else
    echo "  WARNING: nvml.h not found at $NVML_SRC" >&2
fi

# nvvm.h
NVVM_SRC="${CUDA_HOME}/nvvm/include/nvvm.h"
NVVM_DST="${CYBIND_DIR}/cybind/assets/headers/nvvm/${CTK_VERSION_DIR}/nvvm.h"
if [ -f "$NVVM_SRC" ]; then
    mkdir -p "$(dirname "$NVVM_DST")"
    cp "$NVVM_SRC" "$NVVM_DST"
    echo "  Copied nvvm.h"
else
    echo "  WARNING: nvvm.h not found at $NVVM_SRC" >&2
fi

# Apply cufile patch
if [ -f "$CUFILE_DST" ]; then
    echo ""
    echo "Applying cufile.h patch..."
    CUFILE_DIR="$(dirname "$CUFILE_DST")"
    CUFILE_NAME="$(basename "$CUFILE_DST")"
    set +e # Temporarily disable exit on error for patch command
    (cd "$CUFILE_DIR" && patch "$CUFILE_NAME" <"$PATCH_FILE" 2>&1)
    PATCH_EXIT=$?
    set -e # Re-enable exit on error
    if [ $PATCH_EXIT -eq 0 ]; then
        echo "  Patch applied successfully"
    elif [ $PATCH_EXIT -eq 1 ]; then
        echo "  WARNING: Patch may have already been applied (exit code 1)" >&2
        echo "  Please verify manually" >&2
    else
        echo "  ERROR: Patch failed with exit code $PATCH_EXIT" >&2
        exit 1
    fi
fi

echo ""
echo "Header update complete!"
echo ""
echo "Next steps:"
echo "1. Verify the changes: git diff cybind/assets/headers/"
echo "2. Update version lists in config files if needed"
echo "3. Regenerate bindings: run_cybind_native $CTK_VERSION_DIR ../ctk-next"
