#!/usr/bin/env bash
set -xeuo pipefail

echo "Setting up Python from manylinux image..."

# Select CPython based on PY_VER
export PYBIN="/opt/python/cp${PY_VER_MAJOR}-cp${PY_VER_MAJOR}/bin"

echo "PY_VER_MAJOR=${PY_VER_MAJOR}"
echo "PYBIN=${PYBIN}"

"${PYBIN}/python" --version

echo "Installing Python build tools..."
"${PYBIN}/python" -m pip install --upgrade pip
"${PYBIN}/python" -m pip install build auditwheel

echo "Installing system dependencies..."
dnf install -y git wget ca-certificates

echo "Installing jq..."
dnf install -y epel-release
dnf install -y jq

echo "Installing yq..."
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq

chmod +x /usr/local/bin/yq
yq --version

echo "Reading CUDA versions from YAML..."

if [[ -n "${DEFAULT_CUDA_BUILD_VER:-}" ]]; then
  cuda_build_ver="${DEFAULT_CUDA_BUILD_VER}"
else
  cuda_build_ver=$(yq '.cuda.build.version' ci/versions.yml)
fi
echo "cuda_build_ver=${cuda_build_ver}"

cuda_prev_build_ver=$(yq '.cuda.prev_build.version' ci/versions.yml)
echo "cuda_prev_build_ver=${cuda_prev_build_ver}"

export CUDA_VER="${cuda_build_ver}"
export HOST_PLATFORM="linux-64"
export SHA="${CI_COMMIT_SHA}"

echo "Fetching git tags..."
git fetch --tags
