#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: LicenseRef-NVIDIA-SOFTWARE-LICENSE

# HINT to get started:
#     git clone --branch ctk-next https://github.com/rwgk/cuda-python-private.git ctk-next
#     cd ctk-next/

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

set +e # keep going as much as possible
set -x

if command -v nproc >/dev/null 2>&1; then
    export CUDA_PYTHON_PARALLEL_LEVEL="$(nproc)"
fi

git log -n 1
git status
git diff

python3 -VV
python3 -c 'import sys; sys.exit(sys.version_info < (3,10))' || exit 1
python3 -m venv TestVenv && . TestVenv/bin/activate && python -VV && pip install --upgrade pip

cd cuda_pathfinder/
pip install -v -e . --group test
cd ..

cd cuda_bindings/
pip install -v -e . --group test
bash tests/cython/build_tests.sh
cd ..

cd cuda_core/
pip install -v -e . --group test
PYTHONPATH="$(dirname $(pwd))/cuda_bindings" ./tests/cython/build_tests.sh
cd ..
