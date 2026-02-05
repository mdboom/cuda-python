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

cuda_home_real=$(realpath "${CUDA_HOME}")
found=0
while IFS= read -r so; do
    [ -z "$so" ] && continue
    resolved=$(realpath "$so" 2>/dev/null) || continue
    case "$resolved" in
    "$cuda_home_real"/*)
        found=1
        break
        ;;
    esac
done < <(ldconfig -p | awk '/libnvrtc\.so/ && /=>/ {print $NF}')
if ((!found)); then
    echo "FATAL: libnvrtc under ${cuda_home_real} not found in ldconfig cache" >&2
    exit 1
fi

nvidia-smi || {
    rc=$?
    echo "FATAL: nvidia-smi exited with status $rc" >&2
    exit $rc
}

set +e # keep going as much as possible
set -x

git log -n 1
git status
git diff

if [[ -d ./TestVenv && -z "$VIRTUAL_ENV" ]]; then
    . ./TestVenv/bin/activate
fi
python -VV
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
python -m pytest -ra -s -vv tests/cython/
cd ..
