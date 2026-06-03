#!/usr/bin/env bash
set -xeuo pipefail

echo "Starting Cuda Bindings wheel build, PY_VER=${PY_VER}..."

mkdir -p dist
mkdir -p final-dist-bindings

# Function: echo build-system.requires from pyproject.toml as a space-separated list
get_build_system_requires() {
  "${PYBIN}/python" - << 'EOF'
from pathlib import Path
try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:
    import tomli as tomllib  # Python 3.10, tomli installed by the script

_pyproject = Path("./cuda_bindings/pyproject.toml")
data = tomllib.loads(_pyproject.read_text(encoding="utf-8"))
reqs = list(data["build-system"]["requires"])
print(" ".join(reqs))
EOF
}

echo "Creating build venv for ${PYBIN}"
"${PYBIN}/python" -m venv /tmp/ctk-build-env
# shellcheck source=/dev/null
source /tmp/ctk-build-env/bin/activate

if [ "${PY_VER}" = "3.10" ]; then
  python -m pip install -U tomli
fi

REQS="$(get_build_system_requires)"
echo "build-system.requires -> ${REQS}"

echo "Installing build requirements into venv (resolving cuda-pathfinder from local artifacts)"
python -m pip install -U \
  --find-links "${CI_PROJECT_DIR}/final-dist-pathfinder" \
  ${REQS} build wheel

echo "Building wheels from venv"
python -m pip wheel \
  --no-build-isolation \
  -w dist \
  -v \
   ./cuda_bindings

echo "Built wheels:"

ls -l dist || true

echo "Repairing wheels with auditwheel..."
for WHEEL in dist/*-linux_x86_64.whl; do
  echo "Repairing ${WHEEL}"
  auditwheel -v repair -w final-dist-bindings "${WHEEL}"
done

echo "List of wheels pkgs:"
ls -l final-dist-bindings || true

# for clarity
deactivate