#!/usr/bin/env bash
set -xeuo pipefail

echo "Starting cuda_core wheel build, PY_VER=${PY_VER}..."

mkdir -p dist-core
mkdir -p final-dist-core

# Function: echo build-system.requires from cuda_core/pyproject.toml as a space-separated list.
get_build_system_requires() {
  "${PYBIN}/python" - << 'EOF'
from pathlib import Path
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    import tomli as tomllib  # Python 3.10, tomli installed by the script

_pyproject = Path("./cuda_core/pyproject.toml")
data = tomllib.loads(_pyproject.read_text(encoding="utf-8"))
reqs = list(data["build-system"]["requires"])
print(" ".join(reqs))
EOF
}

echo "Creating build venv for ${PYBIN}"
"${PYBIN}/python" -m venv /tmp/core-build-env
# shellcheck source=/dev/null
source /tmp/core-build-env/bin/activate

if [ "${PY_VER}" = "3.10" ]; then
  python -m pip install -U tomli
fi

REQS="$(get_build_system_requires)"
echo "build-system.requires -> ${REQS}"

# --find-links makes pip prefer our just-built wheels for cuda-pathfinder and cuda-bindings
# over PyPI; --no-index makes it strict for those two by side-effect when we install them
# explicitly below.
FIND_LINKS_ARGS=(
  --find-links "${CI_PROJECT_DIR}/final-dist-pathfinder"
  --find-links "${CI_PROJECT_DIR}/final-dist-bindings"
)

echo "Installing build requirements into venv (resolving cuda-pathfinder locally)"
python -m pip install -U "${FIND_LINKS_ARGS[@]}" ${REQS} build wheel auditwheel twine

# Pre-install cuda-bindings from the local artifact dir so build_hooks.py does not need to
# resolve it from PyPI during the wheel build (it derives the major version from CUDA_PATH
# but may still attempt to install bindings as a build-time dep).
echo "Installing cuda-bindings from local artifacts"
python -m pip install -U --no-deps "${FIND_LINKS_ARGS[@]}" cuda-bindings

# Sanity-check that twine is importable from this interpreter.
python -m twine --version

echo "Building cuda_core wheel"
python -m pip wheel \
  --no-build-isolation \
  -w dist-core \
  -v \
  ./cuda_core

echo "Built (pre-repair) wheels:"
ls -l dist-core || true

echo "Repairing wheels with auditwheel..."
for WHEEL in dist-core/*-linux_x86_64.whl; do
  echo "Repairing ${WHEEL}"
  auditwheel -v repair -w final-dist-core "${WHEEL}"
done

echo "Final cuda_core wheels:"
ls -l final-dist-core || true

python -m twine check --strict final-dist-core/*.whl

deactivate
