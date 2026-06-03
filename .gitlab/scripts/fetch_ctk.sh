#!/usr/bin/env bash
set -xeuo pipefail

setup_ctk_cache_variable() {
    local cccl_component

    # Initialize CACHE_TMP_DIR
    rm -rf $CACHE_TMP_DIR
    mkdir $CACHE_TMP_DIR

    # Pre-process the component list to ensure hash uniqueness
    cuda_components="${CUDA_COMPONENTS:-cuda_nvcc,cuda_cudart,cuda_crt,libnvvm,cuda_nvrtc,cuda_profiler_api,cuda_cupti,libnvjitlink,libcufile,libnvfatbin}"
    cuda_path="${CUDA_PATH:-./cuda_toolkit}"
    CTK_CACHE_COMPONENTS=${cuda_components}

    cccl_component="$(select_cccl_component)"
    CTK_CACHE_COMPONENTS+=",${cccl_component}"

    # Conditionally strip out libnvjitlink for CUDA versions < 12
    if [[ "${CUDA_MAJOR_VER}" -lt 12 ]]; then
        CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS//libnvjitlink/}"
    fi
    # Conditionally strip out cuda_crt and libnvvm for CUDA versions < 13
    if [[ "${CUDA_MAJOR_VER}" -lt 13 ]]; then
        CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS//cuda_crt/}"
        CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS//libnvvm/}"
    fi

    # Conditionally strip out libcufile since it does not support Windows
    if [[ "${host_platform}" == win-* ]]; then
        CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS//libcufile/}"
    fi

    # Cleanup stray commas after removing components
    CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS//,,/,}"
    echo "CTK_CACHE_COMPONENTS : ${CTK_CACHE_COMPONENTS}"

    HASH=$(echo -n "${CTK_CACHE_COMPONENTS}" | sha256sum | awk '{print $1}')
    echo "CTK_CACHE_KEY=mini-ctk-${cuda_version}-${host_platform}-$HASH" >> $GITHUB_ENV
    echo "CTK_CACHE_FILENAME=mini-ctk-${cuda_version}-${host_platform}-$HASH.tar.gz" >> $GITHUB_ENV
    echo "CTK_CACHE_COMPONENTS=${CTK_CACHE_COMPONENTS}" >> $GITHUB_ENV
    export CTK_CACHE_COMPONENTS="${CTK_CACHE_COMPONENTS}"
}

install_dependencies() {
    DEPENDENT_EXES="zstd curl xz"
    dnf install -y $DEPENDENT_EXES
}

set_ctk_base_url() {
    get_latest_ctk_iteration() {
        local json names numeric latest
        CTK_ITER_SEARCH_URL="https://kitmaker-web.nvidia.com/kitpicks/${cuda_rel}/${cuda_version}/"
        ctk_iter_json=$(curl -H "Accept: application/json" "${CTK_ITER_SEARCH_URL}" | jq '.')
        names=$(echo "$ctk_iter_json" | jq -r '.[].name | sub("/$"; "")') # Extract names and strip trailing "/"
        numeric=$(echo "$names" | grep -E '^[0-9]+$') || true # Keep numeric values
        latest=$(echo "$numeric" | sort -n | tail -1) # Get max/latest value
        [[ -n "$latest" ]] || return 1
        echo "$latest"
    }

    ctk_iteration=$(get_latest_ctk_iteration)
    export CTK_BASE_URL="https://kitmaker-web.nvidia.com/kitpicks/${cuda_rel}/${cuda_version}/${ctk_iteration}/redist/cuda"
    export CTK_JSON_URL="$CTK_BASE_URL/redistrib_${cuda_version}.json"
    echo "CTK_BASE_URL: $CTK_BASE_URL"
    echo "CTK_JSON_URL: $CTK_JSON_URL"
}

fetch_ctk_manifest() {
    CTK_JSON_FILE="./redistrib_${cuda_version}.json"
    curl -sS --fail "${CTK_JSON_URL}" -o "${CTK_JSON_FILE}"
}

select_cccl_component() {
    local component
    component="$(
        jq -r 'if has("cuda_cccl") then "cuda_cccl" elif has("cccl") then "cccl" else empty end' "${CTK_JSON_FILE}"
    )"
    if [[ -z "${component}" ]]; then
        echo "Could not find CCCL component in ${CTK_JSON_URL}" >&2
        return 1
    fi
    printf '%s\n' "${component}"
}

setup_platform() {
    case "$host_platform" in
        linux-64)      CTK_SUBDIR="linux-x86_64" ;;
        linux-aarch64) CTK_SUBDIR="linux-sbsa" ;;
        win-64)        CTK_SUBDIR="windows-x86_64" ;;
        *) echo "Unsupported platform: $host_platform" >&2; return 1 ;;
    esac
}

extract() {
    local archive=$1
    case "${CTK_SUBDIR}" in
        linux-x86_64|linux-sbsa)
            tar -xvf "$archive" -C "$CACHE_TMP_DIR" --strip-components=1
            ;;
        windows-x86_64)
            echo "Extract: $archive"
            local temp_dir
            temp_dir=$(mktemp -d)
            unzip "$archive" -d "$temp_dir"
            cp -r "$temp_dir"/*/* "$CACHE_TMP_DIR"
            rm -rf "$temp_dir"
            chmod 644 "$CACHE_TMP_DIR/LICENSE"
            ;;
    esac
}

get_cuda_components() {
    function populate_cuda_path() {
        # take the component name as a argument
        function download() {
            echo "Download: $1 to $2"
            curl -kLSs $1 -o $2
        }
        CTK_COMPONENT=$1
        if ! CTK_COMPONENT_REL_PATH="$(
            jq -er --arg component "${CTK_COMPONENT}" --arg subdir "${CTK_SUBDIR}" \
                '.[$component][$subdir].relative_path' "${CTK_JSON_FILE}"
        )"; then
            echo "Could not find ${CTK_COMPONENT} for ${CTK_SUBDIR} in ${CTK_JSON_URL}" >&2
            return 1
        fi
        CTK_COMPONENT_URL="${CTK_BASE_URL}/${CTK_COMPONENT_REL_PATH}"
        CTK_COMPONENT_FILENAME="$(basename ${CTK_COMPONENT_REL_PATH})"
        download $CTK_COMPONENT_URL ${CTK_COMPONENT_FILENAME}
        extract ${CTK_COMPONENT_FILENAME}
        rm ${CTK_COMPONENT_FILENAME}
    }

    # Get headers and shared libraries in place
    for item in $(echo ${CTK_CACHE_COMPONENTS} | tr ',' ' '); do
        populate_cuda_path "$item"
    done

    if [[ "${host_platform}" == linux* && -d "${CACHE_TMP_DIR}/lib" ]]; then
        mv ${CACHE_TMP_DIR}/lib ${CACHE_TMP_DIR}/lib64
    fi

    # "Move" files from temp dir to CUDA_PATH
    mkdir -p $cuda_path
    cp -r ${CACHE_TMP_DIR}/* $cuda_path
    rm -rf ${CACHE_TMP_DIR}
    ls -lAR ${cuda_path}

    # name: Set output environment variables
    # mimics actual CTK installation
    if [[ "${host_platform}" == linux* ]]; then
        CUDA_PATH=$(realpath "${cuda_path}")
        export CUDA_PATH="${CUDA_PATH}"
        echo "${CUDA_PATH}/bin" >> $GITHUB_PATH
        echo "LD_LIBRARY_PATH=${CUDA_PATH}/lib64:${LD_LIBRARY_PATH:-}" >> $GITHUB_ENV
    elif [[ "${host_platform}" == win* ]]; then
        function normpath() {
            echo "$(echo $(cygpath -w $1) | sed 's/\\/\\\\/g')"
        }
        CUDA_PATH=$(normpath $(realpath "${cuda_path}"))
        echo "$(normpath ${CUDA_PATH}/bin)" >> $GITHUB_PATH
    fi
    echo "CUDA_PATH=${CUDA_PATH}"
    echo "CUDA_HOME=${CUDA_PATH}" 

    echo "CUDA_PATH=${CUDA_PATH}" >> $GITHUB_ENV
    echo "CUDA_HOME=${CUDA_PATH}" >> $GITHUB_ENV
}

init_globals() {
    CUDA_MAJOR_VER="$(cut -d '.' -f 1 <<< "${cuda_version}")"
    CUDA_MINOR_VER="$(cut -d '.' -f 2 <<< "${cuda_version}")"
    cuda_rel="cuda-r${CUDA_MAJOR_VER}-${CUDA_MINOR_VER}"
    CACHE_TMP_DIR="./cache_tmp_dir"
    CTK_SUBDIR="linux-x86_64"
}

main() {
    echo "host_platform: $host_platform"
    echo "cuda_version: $cuda_version"
    init_globals
    setup_platform
    install_dependencies
    set_ctk_base_url
    fetch_ctk_manifest
    setup_ctk_cache_variable
    get_cuda_components
    echo "DONE"
}

main "$@"
