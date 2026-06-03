#!/usr/bin/env bash
set -xeuo pipefail

echo "Starting cuda_pathfinder wheel build..."

PYBIN="/opt/python/cp312-cp312/bin"
"${PYBIN}/python" -m venv /tmp/pathfinder-build-env
# shellcheck source=/dev/null
source /tmp/pathfinder-build-env/bin/activate

python -m pip install -U pip build wheel twine

# Sanity-check that twine is importable from this interpreter.
python -m twine --version

mkdir -p "${CI_PROJECT_DIR}/final-dist-pathfinder"

pushd "${CI_PROJECT_DIR}/cuda_pathfinder"
python -m pip wheel -v --no-deps -w "${CI_PROJECT_DIR}/final-dist-pathfinder" .
popd

echo "Built wheels:"
ls -l "${CI_PROJECT_DIR}/final-dist-pathfinder" || true

python -m twine check --strict "${CI_PROJECT_DIR}/final-dist-pathfinder"/*.whl

deactivate
