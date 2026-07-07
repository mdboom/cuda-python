#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

# Helper script to add qa/helpers directory to PATH
# Usage: . /wrk/forked/ctk-next/qa/helpers/activate_helpers.sh

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prepend to PATH if not already present
if [[ ":$PATH:" != *":${SCRIPT_DIR}:"* ]]; then
    export PATH="${SCRIPT_DIR}:${PATH}"
    echo "Added ${SCRIPT_DIR} to PATH"
else
    echo "${SCRIPT_DIR} is already in PATH"
fi

# Helper function to validate output directory
_validate_output_dir() {
    local OUTPUT_DIR_ARG="$1"
    local OUTPUT_DIR
    OUTPUT_DIR="$(realpath "$OUTPUT_DIR_ARG" 2>/dev/null || echo "")"
    if [ -z "$OUTPUT_DIR" ] || [ ! -d "$OUTPUT_DIR" ]; then
        echo "ERROR: Output directory does not exist: $OUTPUT_DIR_ARG" >&2
        echo "  Resolved path: ${OUTPUT_DIR:-<could not resolve>}" >&2
        return 1
    fi
    echo "$OUTPUT_DIR"
}

# Helper function to ensure log directory is set
_ensure_log_dir() {
    if [ -z "${L:-}" ]; then
        local LOG_DIR="/tmp/${USER}-logs"
        mkdir -p "$LOG_DIR"
        export L="$LOG_DIR"
        echo "Set L=$L"
    fi
}

# Helper function to validate CUDA installation
_validate_cuda_home() {
    local CTK_VERSION="$1"
    local CUDA_VERSION_DIR="$CTK_VERSION"
    if [[ "$CTK_VERSION" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
        CUDA_VERSION_DIR="${BASH_REMATCH[1]}"
    fi

    local CUDA_HOME="/usr/local/cuda-${CUDA_VERSION_DIR}"
    if [ ! -d "$CUDA_HOME" ]; then
        echo "ERROR: CUDA installation not found at $CUDA_HOME" >&2
        return 1
    fi
    echo "$CUDA_HOME"
}

# Helper function to require CTK version in major.minor.patch form
_require_ctk_target_version() {
    local CTK_VERSION="$1"
    if [[ "$CTK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$CTK_VERSION"
        return 0
    fi

    echo "ERROR: CTK version must look like <major>.<minor>.<patch>" >&2
    echo "  Got: $CTK_VERSION" >&2
    return 1
}

# Helper function to create fresh virtual environment
_create_fresh_venv() {
    local VENV_NAME="$1"
    local INSTALL_CMD="$2"
    echo "Creating fresh ${VENV_NAME} virtual environment..."
    rm -rf "$VENV_NAME"
    python -m venv "$VENV_NAME"
    (
        . "${VENV_NAME}/bin/activate"
        pip install --upgrade pip
        eval "$INSTALL_CMD"
    )
    echo "Fresh ${VENV_NAME} virtual environment created successfully!"
}

# Helper function to create log file timestamp
# Uses timezone offset if not in Los Angeles timezone to reduce the potential for confusion
_make_log_timestamp() {
    local TZ_ABBR
    TZ_ABBR="$(date +%Z 2>/dev/null || echo "")"

    # Check if we're in Los Angeles timezone (PST/PDT)
    if [[ "$TZ_ABBR" == "PST" ]] || [[ "$TZ_ABBR" == "PDT" ]]; then
        date "+%Y-%m-%d+%H%M%S"
    else
        date "+%Y-%m-%d+%H%M%S%z"
    fi
}

# Function to create a fresh cybind virtual environment
cybind_fresh_venv() {
    local CYBIND_DIR
    CYBIND_DIR="$(realpath .)"
    if [ ! -d "${CYBIND_DIR}/cybind/assets/headers" ]; then
        echo "ERROR: Not in cybind repository root directory" >&2
        echo "  Current directory: $CYBIND_DIR" >&2
        echo "  Expected to find: cybind/assets/headers/" >&2
        echo "" >&2
        echo "Please run this function from the cybind repository root directory." >&2
        return 1
    fi

    _create_fresh_venv "CybindVenv" "pip install -e ."
}

run_cybind_native() {
    if [ $# -ne 2 ]; then
        echo "Usage: run_cybind_native <CTK_VERSION> <OUTPUT_DIR>" >&2
        echo "Example: run_cybind_native 13.1.0 ../cuda-python" >&2
        echo "Example: run_cybind_native 13.2.0 ../ctk-next" >&2
        return 1
    fi

    local CTK_VERSION
    CTK_VERSION="$(_require_ctk_target_version "$1")" || return 1
    local OUTPUT_DIR_ARG="$2"
    local CYBIND_DIR
    CYBIND_DIR="$(realpath .)"

    # Check that we're in cybind directory
    if [ ! -d "${CYBIND_DIR}/cybind/assets/headers" ]; then
        echo "ERROR: Not in cybind repository root directory" >&2
        echo "  Current directory: $CYBIND_DIR" >&2
        echo "  Expected to find: cybind/assets/headers/" >&2
        echo "" >&2
        echo "Please run this function from the cybind repository root directory." >&2
        return 1
    fi

    # Validate output directory exists
    local OUTPUT_DIR
    OUTPUT_DIR="$(_validate_output_dir "$OUTPUT_DIR_ARG")" || return 1

    # Validate cuda_bindings subdirectory exists
    if [ ! -d "${OUTPUT_DIR}/cuda_bindings" ]; then
        echo "ERROR: cuda_bindings subdirectory not found in output directory" >&2
        echo "  Output directory: $OUTPUT_DIR" >&2
        echo "  Expected: ${OUTPUT_DIR}/cuda_bindings/" >&2
        return 1
    fi

    _ensure_log_dir

    # Ensure CybindVenv exists
    if [ ! -d "CybindVenv" ]; then
        echo "CybindVenv not found. Creating fresh virtual environment..."
        cybind_fresh_venv || return 1
    fi

    local CUDA_HOME
    CUDA_HOME="$(_validate_cuda_home "$CTK_VERSION")" || return 1

    local LOG_FILE="${L}/run_cybind_native_$(_make_log_timestamp).txt"
    echo "Running cybind generation..."
    echo "CTK target version: $CTK_VERSION"
    echo "CUDA_HOME: $CUDA_HOME"
    echo "Output directory: $OUTPUT_DIR/cuda_bindings"
    echo "Log file: $LOG_FILE"
    echo ""

    (
        . CybindVenv/bin/activate
        CUDA_PATH="$CUDA_HOME" CybindVenv/bin/python -m cybind -vvv --generate cudla cufile nvfatbin nvjitlink nvml nvvm --output-dir "${OUTPUT_DIR}/cuda_bindings" 2>&1 | tee "$LOG_FILE"
    )
}

run_cybind_cython_gen() {
    if [ $# -ne 2 ]; then
        echo "Usage: run_cybind_cython_gen <CTK_VERSION> <OUTPUT_DIR>" >&2
        echo "Example: run_cybind_cython_gen 13.1.0 ../cuda-python" >&2
        echo "Example: run_cybind_cython_gen 13.2.0 ../ctk-next" >&2
        return 1
    fi

    local CTK_VERSION="$1"
    local OUTPUT_DIR_ARG="$2"
    local CTK_TARGET_VERSION
    CTK_TARGET_VERSION="$(_require_ctk_target_version "$CTK_VERSION")" || return 1
    # Keep only major.minor for the target version, dropping the patch component
    CTK_TARGET_VERSION="${CTK_TARGET_VERSION%.*}"
    local CYBIND_DIR
    CYBIND_DIR="$(realpath .)"

    # Check that we're in cybind directory
    if [ ! -d "${CYBIND_DIR}/cybind/assets/headers" ]; then
        echo "ERROR: Not in cybind repository root directory" >&2
        echo "  Current directory: $CYBIND_DIR" >&2
        echo "  Expected to find: cybind/assets/headers/" >&2
        echo "" >&2
        echo "Please run this function from the cybind repository root directory." >&2
        return 1
    fi

    # Validate output directory exists
    local OUTPUT_DIR
    OUTPUT_DIR="$(_validate_output_dir "$OUTPUT_DIR_ARG")" || return 1

    # Validate cuda_bindings subdirectory exists
    if [ ! -d "${OUTPUT_DIR}/cuda_bindings" ]; then
        echo "ERROR: cuda_bindings subdirectory not found in output directory" >&2
        echo "  Output directory: $OUTPUT_DIR" >&2
        echo "  Expected: ${OUTPUT_DIR}/cuda_bindings/" >&2
        return 1
    fi

    _ensure_log_dir

    # Ensure CybindVenv exists
    if [ ! -d "CybindVenv" ]; then
        echo "CybindVenv not found. Creating fresh virtual environment..."
        cybind_fresh_venv || return 1
    fi

    local LOG_FILE="${L}/cybind_generate_driver_runtime_nvrtc_log_$(_make_log_timestamp).txt"
    echo "Running cybind driver/runtime/nvrtc generation..."
    echo "CTK target version: $CTK_TARGET_VERSION"
    echo "Output directory: $OUTPUT_DIR/cuda_bindings"
    echo "Log file: $LOG_FILE"
    echo ""

    (
        . CybindVenv/bin/activate
        CybindVenv/bin/python -m cybind -vvv --ctk-target-version "$CTK_TARGET_VERSION" --generate driver runtime nvrtc --output-dir "${OUTPUT_DIR}/cuda_bindings" 2>&1 | tee "$LOG_FILE"
    )
}
