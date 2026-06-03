#!/usr/bin/env bash
set -xeuo pipefail

echo "Starting cuda_python wheel build..."

PYBIN="/opt/python/cp312-cp312/bin"
"${PYBIN}/python" -m venv /tmp/python-build-env
# shellcheck source=/dev/null
source /tmp/python-build-env/bin/activate

python -m pip install -U pip build wheel twine

# Sanity-check that twine is importable from this interpreter.
python -m twine --version

mkdir -p "${CI_PROJECT_DIR}/final-dist-python"

pushd "${CI_PROJECT_DIR}/cuda_python"
python -m pip wheel -v --no-deps -w "${CI_PROJECT_DIR}/final-dist-python" .
popd

echo "Built wheels:"
ls -l "${CI_PROJECT_DIR}/final-dist-python" || true

python -m twine check --strict "${CI_PROJECT_DIR}/final-dist-python"/*.whl

deactivate
