#!/usr/bin/env bash
set -xeuo pipefail

echo "Setting up GitHub-style env files..."
pwd

export GITHUB_ENV="${CI_PROJECT_DIR}/github_env"
export GITHUB_PATH="${CI_PROJECT_DIR}/github_path"

> "$GITHUB_ENV"
> "$GITHUB_PATH"

echo "Running env-vars tool..."
"${CI_PROJECT_DIR}/ci/tools/env-vars" build

echo "Generated env vars:"
cat "$GITHUB_ENV"

export host_platform="${HOST_PLATFORM}"
export cuda_version="${CUDA_VER}"
export CUDA_PATH="${CI_PROJECT_DIR}/cuda_toolkit"

"${CI_PROJECT_DIR}/.gitlab/scripts/fetch_ctk.sh"

echo "Loading env variables..."
set -a
source "$GITHUB_ENV"
set +a

export PATH="$(paste -sd: "$GITHUB_PATH"):${PATH}"

echo "Creating setup.env..."
cp "$GITHUB_ENV" "${CI_PROJECT_DIR}/setup.env"
echo "CUDA_VER=${CUDA_VER}" >> "${CI_PROJECT_DIR}/setup.env"
echo "HOST_PLATFORM=${HOST_PLATFORM}" >> "$CI_PROJECT_DIR/setup.env"
echo "SHA=$SHA" >> "${CI_PROJECT_DIR}/setup.env"
echo "BUILD_PATH=$PATH" >> "${CI_PROJECT_DIR}/setup.env"

tr -d '\r' < "${CI_PROJECT_DIR}/setup.env" > "${CI_PROJECT_DIR}/setup.clean"
mv "${CI_PROJECT_DIR}/setup.clean" "${CI_PROJECT_DIR}/setup.env"

grep -nPv '^[A-Za-z_][A-Za-z0-9_]*=.*$' "${CI_PROJECT_DIR}/setup.env" || echo "setup.env valid"
cat -A "${CI_PROJECT_DIR}/setup.env"

echo "Configuring CUDA paths..."
export CUDA_HOME="${CUDA_PATH}"
export CUDA_PATH="${CUDA_PATH}"

echo "CUDA_HOME=${CUDA_HOME}"
cp "${CI_PROJECT_DIR}/setup.env" "${CUDA_HOME}/."
