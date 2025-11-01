#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

if (($# != 1)); then
    echo "FATAL: expected exactly one argument (e.g. 13.1), $# given" >&2
    exit 1
fi

set -x
export CUDA_HOME="/usr/local/cuda-$1"
set +x

if [[ ! -d "$CUDA_HOME" ]]; then
    echo "FATAL: NOT A DIRECTORY: $CUDA_HOME"
    exit 1
fi

ldconfig -p | grep -E '^[[:space:]]*libnvrtc.*\.so.*[[:space:]]=>[[:space:]]'"$(realpath "${CUDA_HOME}")" || {
    echo "FATAL: libnvrtc matching $(realpath "$CUDA_HOME") not found in ldconfig cache" >&2
    exit 1
}

set +e # keep going as much as possible
set -x

if [[ -d ./TestVenv && -z "$VIRTUAL_ENV" ]]; then
    . ./TestVenv/bin/activate
fi
pip list

cd cuda_pathfinder/
python -m pytest -ra -s -vv tests/
cd ..

cd cuda_bindings/
python -m pytest -ra -s -vv tests/
CUDA_PYTHON_CUDA_PER_THREAD_DEFAULT_STREAM=1 python -m pytest -ra -s -vv tests/
python -m pytest -ra -s -vv examples/
python -m pytest -ra -s -vv tests/cython/
cd ..

cd cuda_core/
python -m pytest -ra -s -vv tests/
python -m pytest -ra -s -vv tests/example_tests/
cd ..
