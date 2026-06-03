#!/usr/bin/env bash
set -xeuo pipefail

COMPONENT="${1:?usage: wheels_upload.sh <bindings|pathfinder|python|core>}"

case "$COMPONENT" in
  bindings)
    REPO_PATH="cuda-python/cuda-bindings/linux-64"
    DIST_DIR="final-dist-bindings"
    GLOB="cuda_bindings*.whl"
    ;;
  pathfinder)
    REPO_PATH="cuda-python/cuda-pathfinder/linux-64"
    DIST_DIR="final-dist-pathfinder"
    GLOB="cuda_pathfinder*.whl"
    ;;
  python)
    REPO_PATH="cuda-python/cuda-python/linux-64"
    DIST_DIR="final-dist-python"
    GLOB="cuda_python*.whl"
    ;;
  core)
    REPO_PATH="cuda-python/cuda-core/linux-64"
    DIST_DIR="final-dist-core"
    GLOB="cuda_core*.whl"
    ;;
  *)
    echo "Unknown component: $COMPONENT" >&2
    exit 2
    ;;
esac

ARTIFACT_SERVER="https://artifactory.nvidia.com"
ARTIFACT_REPOS="sw-cuda-python-pypi-local"
ARTIFACT_USER="svc-sw-cuda-python-pypi-local-cicd"

ls -lAR "${CI_PROJECT_DIR}/${DIST_DIR}"
if [[ -n "${DEFAULT_CUDA_BUILD_VER:-}" ]]; then
  cuda_build_ver="${DEFAULT_CUDA_BUILD_VER}"
else
  cuda_build_ver=$(yq '.cuda.build.version' "${CI_PROJECT_DIR}/ci/versions.yml")
fi
echo "cuda_build_ver=$cuda_build_ver"

echo "Uploading files..."
cd "${CI_PROJECT_DIR}/${DIST_DIR}"

jf c remove urm-server --quiet 2>/dev/null || true
jf c add urm-server \
    --url "${ARTIFACT_SERVER}" \
    --access-token "${ARTIFACT_TOKEN}" \
    --interactive=false

jf rt u \
  --url "${ARTIFACT_SERVER}/artifactory" \
  --user "${ARTIFACT_USER}" \
  --access-token "${ARTIFACT_TOKEN}" \
  --target-props '' \
  "${GLOB}" \
  "${ARTIFACT_REPOS}/${REPO_PATH}/${cuda_build_ver}/"

echo "Upload complete"
