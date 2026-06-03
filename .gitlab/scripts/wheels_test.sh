#!/usr/bin/env bash
set -xeuo pipefail

COMPONENT="${1:?usage: wheels_test.sh <pathfinder|bindings|core|python> <cpu|gpu>}"
MODE="${2:?usage: wheels_test.sh <pathfinder|bindings|core|python> <cpu|gpu>}"
TEST_LEVEL="${WHEELS_TEST_LEVEL:-smoke}"
DUMMY=1

case "${COMPONENT}" in
  pathfinder|bindings|core|python) ;;
  *)
    echo "Unknown component: ${COMPONENT}" >&2
    exit 2
    ;;
esac

case "${MODE}" in
  cpu|gpu) ;;
  *)
    echo "Unknown test mode: ${MODE}" >&2
    exit 2
    ;;
esac

case "${TEST_LEVEL}" in
  smoke|standard) ;;
  *)
    echo "Unknown test level: ${TEST_LEVEL}" >&2
    exit 2
    ;;
esac

PY_VER_MAJOR="$(echo "${PY_VER:?PY_VER is required}" | tr -d '.')"
PYBIN="/opt/python/cp${PY_VER_MAJOR}-cp${PY_VER_MAJOR}/bin"
TEST_ENV="/tmp/${COMPONENT}-${MODE}-test-env"

"${PYBIN}/python" --version
"${PYBIN}/python" -m venv "${TEST_ENV}"
# shellcheck source=/dev/null
source "${TEST_ENV}/bin/activate"

python -m pip install -U pip

find_links=(
  --find-links "${CI_PROJECT_DIR}/final-dist-pathfinder"
  --find-links "${CI_PROJECT_DIR}/final-dist-bindings"
  --find-links "${CI_PROJECT_DIR}/final-dist-core"
  --find-links "${CI_PROJECT_DIR}/final-dist-python"
)

resolve_cuda_ver() {
  if [[ -n "${CUDA_VER:-}" ]]; then
    return
  fi
  if [[ -n "${DEFAULT_CUDA_BUILD_VER:-}" ]]; then
    export CUDA_VER="${DEFAULT_CUDA_BUILD_VER}"
    return
  fi
  CUDA_VER="$(
    sed -n 's/^[[:space:]]*version: "\([^"]*\)"/\1/p' "${CI_PROJECT_DIR}/ci/versions.yml" | head -n 1
  )"
  export CUDA_VER
  if [[ -z "${CUDA_VER}" ]]; then
    echo "Could not resolve CUDA_VER" >&2
    exit 1
  fi
}

install_linux_test_deps() {
  dnf install -y git wget ca-certificates curl xz zstd gcc-c++ mesa-libGL mesa-libEGL
  dnf install -y epel-release
  dnf install -y jq
}

artifact_dir() {
  local dir="${1}"
  if [[ -d "${dir}" ]]; then
    realpath "${dir}"
  else
    printf '%s\n' "${dir}"
  fi
}

select_python_wheel() {
  local dist_dir="${1}"
  local dist_prefix="${2}"
  local python_tag="cp${PY_VER_MAJOR}-cp${PY_VER_MAJOR}"
  local previous_nullglob
  previous_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local wheels=("${dist_dir}/${dist_prefix}-"*"-${python_tag}-"*.whl)
  eval "${previous_nullglob}"

  if [[ ${#wheels[@]} -ne 1 ]]; then
    echo "Expected exactly one ${dist_prefix} wheel for ${python_tag}, found ${#wheels[@]}:" >&2
    printf '  %s\n' "${dist_dir}/${dist_prefix}-"*".whl" >&2
    exit 1
  fi

  printf '%s\n' "${wheels[0]}"
}

select_single_wheel() {
  local dist_dir="${1}"
  local dist_prefix="${2}"
  local previous_nullglob
  previous_nullglob="$(shopt -p nullglob || true)"
  shopt -s nullglob
  local wheels=("${dist_dir}/${dist_prefix}-"*.whl)
  eval "${previous_nullglob}"

  if [[ ${#wheels[@]} -ne 1 ]]; then
    echo "Expected exactly one ${dist_prefix} wheel, found ${#wheels[@]}:" >&2
    printf '  %s\n' "${dist_dir}/${dist_prefix}-"*.whl >&2
    exit 1
  fi

  printf '%s\n' "${wheels[0]}"
}

setup_current_ctk() {
  if [[ -d "${CI_PROJECT_DIR}/cuda_toolkit/include" ]]; then
    export CUDA_PATH="${CI_PROJECT_DIR}/cuda_toolkit"
    export CUDA_HOME="${CUDA_PATH}"
    return
  fi

  install_linux_test_deps

  export GITHUB_ENV="${CI_PROJECT_DIR}/github_test_env_${COMPONENT}_${MODE}"
  export GITHUB_PATH="${CI_PROJECT_DIR}/github_test_path_${COMPONENT}_${MODE}"
  : > "${GITHUB_ENV}"
  : > "${GITHUB_PATH}"

  export host_platform="linux-64"
  export cuda_version="${CUDA_VER}"
  export CUDA_PATH="${CI_PROJECT_DIR}/cuda_toolkit"
  export CUDA_HOME="${CUDA_PATH}"

  bash "${CI_PROJECT_DIR}/.gitlab/scripts/fetch_ctk.sh"

  set -a
  # shellcheck source=/dev/null
  source "${GITHUB_ENV}"
  set +a

  local github_path_entries
  github_path_entries="$(paste -sd: "${GITHUB_PATH}")"
  export PATH="${github_path_entries}:${PATH}"
  export CUDA_HOME="${CUDA_PATH}"
}

setup_standard_env() {
  resolve_cuda_ver

  export SANITIZER_CMD="${SANITIZER_CMD:-}"
  export TEST_CUDA_MAJOR
  TEST_CUDA_MAJOR="$(cut -d '.' -f 1 <<< "${CUDA_VER}")"
  export CUDA_VER_MINOR
  CUDA_VER_MINOR="$(cut -d '.' -f 1-2 <<< "${CUDA_VER}")"

  export CUDA_PATHFINDER_ARTIFACTS_DIR
  CUDA_PATHFINDER_ARTIFACTS_DIR="$(artifact_dir "${CI_PROJECT_DIR}/final-dist-pathfinder")"
  export CUDA_BINDINGS_ARTIFACTS_DIR
  CUDA_BINDINGS_ARTIFACTS_DIR="$(artifact_dir "${CI_PROJECT_DIR}/final-dist-bindings")"
  export CUDA_CORE_ARTIFACTS_DIR
  CUDA_CORE_ARTIFACTS_DIR="$(artifact_dir "${CI_PROJECT_DIR}/final-dist-core")"
  export CUDA_PYTHON_ARTIFACTS_DIR
  CUDA_PYTHON_ARTIFACTS_DIR="$(artifact_dir "${CI_PROJECT_DIR}/final-dist-python")"
}

install_runtime_deps() {
  python -m pip install -U numpy
  if [[ "${PY_VER}" == "3.10" ]]; then
    python -m pip install -U backports.strenum
  fi
}

free_threading_suffix() {
  local suffix=""
  if python -c 'import sys; assert not sys._is_gil_enabled()' 2> /dev/null; then
    suffix="-ft"
  fi
  printf '%s\n' "${suffix}"
}

run_pathfinder_tests_with_strictness() {
  local strictness="${1}"
  local log_file="/tmp/pathfinder_${strictness}_${MODE}_test_log.txt"

  echo "Running pathfinder tests with LD:${strictness} FH:${strictness} BC:${strictness}"
  CUDA_PATHFINDER_TEST_LOAD_NVIDIA_DYNAMIC_LIB_STRICTNESS="${strictness}" \
  CUDA_PATHFINDER_TEST_FIND_NVIDIA_HEADERS_STRICTNESS="${strictness}" \
  CUDA_PATHFINDER_TEST_FIND_NVIDIA_BITCODE_LIB_STRICTNESS="${strictness}" \
    python -m pytest -ra -s -v --durations=0 "${CI_PROJECT_DIR}/cuda_pathfinder/tests/" |& tee "${log_file}"

  local line_count
  line_count="$(awk '/^INFO test_/ {count++} END {print count+0}' "${log_file}")"
  echo "Number of \"INFO test_\" lines: ${line_count}"
}

run_standard_pathfinder() {
  setup_standard_env
  setup_current_ctk

  local pathfinder_wheel
  pathfinder_wheel="$(select_single_wheel "${CUDA_PATHFINDER_ARTIFACTS_DIR}" "cuda_pathfinder")"

  python -m pip install "${pathfinder_wheel}" --group "${CI_PROJECT_DIR}/cuda_pathfinder/pyproject.toml:test"
  run_pathfinder_tests_with_strictness see_what_works

  python -m pip install \
    --only-binary=:all: \
    -v \
    "${pathfinder_wheel}" \
    --group "${CI_PROJECT_DIR}/cuda_pathfinder/pyproject.toml:test-cu${TEST_CUDA_MAJOR}"
  python -m pip list
  run_pathfinder_tests_with_strictness all_must_work
}

run_standard_bindings() {
  setup_standard_env
  setup_current_ctk

  local bindings_wheel
  bindings_wheel="$(select_python_wheel "${CUDA_BINDINGS_ARTIFACTS_DIR}" "cuda_bindings")"

  python -m pip install "${CUDA_PATHFINDER_ARTIFACTS_DIR}"/*.whl
  python -m pip install "${bindings_wheel}" --group "${CI_PROJECT_DIR}/cuda_bindings/pyproject.toml:test"
  ${SANITIZER_CMD} python -m pytest -rxXs -v --durations=0 --randomly-dont-reorganize "${CI_PROJECT_DIR}/cuda_bindings/tests/"
  bash "${CI_PROJECT_DIR}/cuda_bindings/tests/cython/build_tests.sh"
  ${SANITIZER_CMD} python -m pytest -rxXs -v --durations=0 --randomly-dont-reorganize "${CI_PROJECT_DIR}/cuda_bindings/tests/cython"

  python -m pip install -U pyperf
  pushd "${CI_PROJECT_DIR}/benchmarks/cuda_bindings"
  python run_pyperf.py --debug-single-value
  popd
}

run_standard_core() {
  setup_standard_env
  setup_current_ctk

  local bindings_wheel
  local core_wheel
  local thread_suffix
  bindings_wheel="$(select_python_wheel "${CUDA_BINDINGS_ARTIFACTS_DIR}" "cuda_bindings")"
  core_wheel="$(select_python_wheel "${CUDA_CORE_ARTIFACTS_DIR}" "cuda_core")"
  thread_suffix="$(free_threading_suffix)"

  python -m pip install "${CUDA_PATHFINDER_ARTIFACTS_DIR}"/*.whl
  python -m pip install "${bindings_wheel}"
  python -m pip install \
    "${core_wheel}" \
    --group "${CI_PROJECT_DIR}/cuda_core/pyproject.toml:test-cu${TEST_CUDA_MAJOR}${thread_suffix}" \
    "cuda-toolkit==${CUDA_VER_MINOR}.*"
  python -m pip list

  bash "${CI_PROJECT_DIR}/cuda_core/tests/cython/build_tests.sh"
  ${SANITIZER_CMD} python -m pytest -rxXs -v --durations=0 --randomly-dont-reorganize "${CI_PROJECT_DIR}/cuda_core/tests/"
  ${SANITIZER_CMD} python -m pytest -rxXs -v --durations=0 --randomly-dont-reorganize "${CI_PROJECT_DIR}/cuda_core/tests/cython"
}

run_standard_python() {
  setup_standard_env
  install_runtime_deps

  local python_wheel
  python_wheel="$(select_single_wheel "${CUDA_PYTHON_ARTIFACTS_DIR}" "cuda_python")"

  python -m pip install \
    --only-binary=:all: \
    --no-index \
    "${find_links[@]}" \
    "${python_wheel}"
  python - <<'PY'
import cuda.bindings
import cuda.core
import cuda.pathfinder

print("cuda.bindings:", cuda.bindings.__version__)
print("cuda.core:", cuda.core.__version__)
print("cuda.pathfinder:", cuda.pathfinder.__version__)
PY
}

if [[ "${TEST_LEVEL}" == "standard" ]]; then
  case "${COMPONENT}" in
    pathfinder)
      run_standard_pathfinder
      ;;
    bindings)
      run_standard_bindings
      ;;
    core)
      run_standard_core
      ;;
    python)
      run_standard_python
      ;;
    *)
      echo "Standard GitLab wheel tests are currently ported for pathfinder, bindings, core, and python only" >&2
      exit 2
      ;;
  esac

  python -m pip list
  deactivate
  exit 0
fi

case "${COMPONENT}" in
  pathfinder)
    python -m pip install --no-index \
      --find-links "${CI_PROJECT_DIR}/final-dist-pathfinder" \
      cuda-pathfinder
    python - <<'PY'
import cuda.pathfinder

print("cuda.pathfinder:", cuda.pathfinder.__version__)
PY
    ;;
  bindings)
    python -m pip install --no-index \
      --find-links "${CI_PROJECT_DIR}/final-dist-pathfinder" \
      --find-links "${CI_PROJECT_DIR}/final-dist-bindings" \
      cuda-bindings
    if [[ "${MODE}" == "gpu" ]]; then
      python - <<'PY'
from cuda.bindings import driver

(err,) = driver.cuInit(0)
assert err == driver.CUresult.CUDA_SUCCESS, err
print("cuInit:", err)
PY
    else
      python - <<'PY'
import cuda.bindings

print("cuda.bindings:", cuda.bindings.__version__)
PY
    fi
    ;;
  core)
    install_runtime_deps
    python -m pip install --no-index "${find_links[@]}" cuda-bindings cuda-core
    if [[ "${MODE}" == "gpu" ]]; then
      python - <<'PY'
from cuda.core import Device

d = Device(0)
print(d.name)
PY
    else
      python - <<'PY'
import cuda.core

print("cuda.core:", cuda.core.__version__)
PY
    fi
    ;;
  python)
    install_runtime_deps
    python -m pip install --no-index "${find_links[@]}" cuda-python
    python - <<'PY'
import cuda.bindings
import cuda.core
import cuda.pathfinder

print("cuda.bindings:", cuda.bindings.__version__)
print("cuda.core:", cuda.core.__version__)
print("cuda.pathfinder:", cuda.pathfinder.__version__)
PY
    ;;
esac

python -m pip list
deactivate
