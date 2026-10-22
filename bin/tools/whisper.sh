#!/usr/bin/env bash
# ==============================================================================
#  bin/tools/whisper.sh — Whisper (Speaches) Tool Module
# ==============================================================================

set -euo pipefail

install_whisper() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local whisper_dir="${home_dir}/whisper"
    local models_dir="${whisper_dir}/models"

    log_header "Installing Whisper (Speaches) → ${container}"
    log_info "Estimated time: 3-15 min depending on network (PyTorch is the largest download)."

    local avail_kb
    avail_kb="$(df -Pk "${home_dir}" 2>/dev/null | awk 'END {print $4}')" || avail_kb=0
    if (( avail_kb > 0 && avail_kb < 5242880 )); then
        log_warn "Low disk space detected (<5 GB free). Whisper models require sufficient disk space."
    fi

    steps_begin 5

    log_step "Installing system dependencies (ffmpeg, etc.)..."
    ensure_base_packages "${container}" git curl ca-certificates ffmpeg procps jq

    log_step "Installing Miniforge and creating Python 3.12 environment..."
    distrobox enter "${container}" -- bash -c "
        set -e
        ${CONTAINER_HELPERS}
        mkdir -p '${whisper_dir}'
        rm -rf '${whisper_dir}/.venv'
        install_miniforge '${whisper_dir}/conda' '${home_dir}/.cache'
        ensure_conda_env  '${whisper_dir}/conda' whisper 3.12
    "

    log_step "Installing Speaches (faster-whisper) and PyTorch (large download)..."
    distrobox enter "${container}" -- bash -c "
        set -e
        ${CONTAINER_HELPERS}
        source '${whisper_dir}/conda/bin/activate' whisper
        export PIP_CACHE_DIR='${home_dir}/.cache/pip'
        export PIP_PROGRESS_BAR=on
        mkdir -p \"\${PIP_CACHE_DIR}\"

        echo '     [1/3] Upgrading pip tooling...'
        pip install --upgrade pip setuptools wheel huggingface_hub
        echo '     [2/3] Installing PyTorch...'
        pip_install_torch torch torchvision torchaudio
        echo '     [3/3] Installing Speaches...'
        pip install git+https://github.com/speaches-ai/speaches.git
    "

    log_step "Writing runtime configuration..."
    mkdir -p "${models_dir}" "${home_dir}/.run"

    local default_device="cpu"
    local default_compute="int8"
    if container_has_gpu "${container}"; then
        default_device="cuda"
        default_compute="float16"
    fi

    cat > "${home_dir}/.whisper.env" <<EOF
# Whisper (Speaches) runtime environment
export WHISPER_DIR="${whisper_dir}"
export WHISPER_CONDA="${whisper_dir}/conda"
export WHISPER_ENV_NAME="whisper"
export HF_HOME="${models_dir}"
export WHISPER_DEFAULT_DEVICE="${default_device}"
export WHISPER_COMPUTE_TYPE="${default_compute}"
EOF
    log_info "Device: ${default_device} / compute type: ${default_compute}"

    log_step "Verifying Whisper installation..."
    if ! distrobox enter "${container}" -- bash -c "source '${whisper_dir}/conda/bin/activate' whisper && python -c 'import speaches' &>/dev/null"; then
        die "Speaches verification failed. Installation may be incomplete."
    fi
    steps_end

    log_success "Whisper engine installed successfully in '${container}'."
    log_warn    "NO MODEL DOWNLOADED YET! You must pull a model before starting."
    log_info    "Run this command to download a model:"
    log_info    "  localai.sh model pull ${container}:whisper Systran/faster-whisper-large-v3"
}

is_installed_whisper() {
    local h="${BASE_DIR}/$1"
    [[ -d "${h}/whisper" || -f "${h}/.whisper.env" ]]
}

update_whisper() {
    local container="$1"
    local whisper_dir="${BASE_DIR}/${container}/whisper"

    log_header "Updating Whisper → ${container}"
    steps_begin 2
    log_step "Upgrading speaches and huggingface_hub via pip..."
    distrobox enter "${container}" -- bash -c "
        set -e
        source '${whisper_dir}/conda/bin/activate' whisper
        old=\$(pip show speaches 2>/dev/null | grep '^Version:' | awk '{print \$2}')
        echo \"     Current speaches version: \${old:-unknown}\"
        pip install --upgrade git+https://github.com/speaches-ai/speaches.git huggingface_hub
        new=\$(pip show speaches 2>/dev/null | grep '^Version:' | awk '{print \$2}')
        if [[ \"\${old}\" == \"\${new}\" ]]; then
            echo \"     speaches is already up to date (\${new}).\"
        else
            echo \"     speaches upgraded: \${old:-unknown} → \${new}\"
        fi
    "
    log_step "Checking if a restart is needed..."
    if [[ "$(get_tool_status_in_container "${container}" whisper)" == running* ]]; then
        log_warn "Whisper is running with the old version. Apply with: localai.sh restart ${container}:whisper"
    else
        log_info "Whisper is not running; new version will be used on next start."
    fi
    steps_end
    log_success "Whisper updated in '${container}'."
}

pull_model_whisper() {
    local container="$1"
    local model="${2:-}"
    
    if [[ -z "${model}" ]]; then
        die "Model name is required! (e.g., Systran/faster-whisper-large-v3, Systran/faster-whisper-small)"
    fi

    local home_dir="${BASE_DIR}/${container}"
    local whisper_dir="${home_dir}/whisper"
    local user_env="${home_dir}/.whisper.user.env"
    local model_cache="${whisper_dir}/models/hub/models--${model//\//--}"

    if [[ ! -x "${whisper_dir}/conda/envs/whisper/bin/python" ]]; then
        die "Whisper is not installed in '${container}'. Install it first: localai.sh install ${container}:whisper"
    fi
    
    log_header "Pulling Whisper Model: ${model} → ${container}"
    steps_begin 2

    log_step "Downloading model files from HuggingFace Hub..."
    log_info "Typical sizes: small ≈ 0.5 GB, medium ≈ 1.5 GB, large-v3 ≈ 3 GB. Live progress bars follow."
    log_info "Interrupted downloads resume automatically when you re-run this command."
    distrobox enter "${container}" -- bash -c "
        set -e
        source '${whisper_dir}/conda/bin/activate' whisper
        export HF_HOME='${whisper_dir}/models'
        unset HF_HUB_DISABLE_PROGRESS_BARS
        if command -v hf &>/dev/null; then
            hf download '${model}'
        elif command -v huggingface-cli &>/dev/null; then
            huggingface-cli download '${model}'
        else
            echo 'ERROR: Neither hf nor huggingface-cli found in the whisper environment.' >&2
            echo 'Fix: localai.sh update ${container}:whisper' >&2
            exit 1
        fi
    "
    
    log_step "Setting '${model}' as default model..."
    touch "${user_env}"
    sed -i '/^[ \t]*export[ \t]*WHISPER_MODEL=/d' "${user_env}"
    echo "export WHISPER_MODEL=\"${model}\"" >> "${user_env}"
    steps_end

    if [[ -d "${model_cache}" ]]; then
        local size; size="$(du -sh "${model_cache}" 2>/dev/null | awk '{print $1}')" || size="?"
        log_info "Model size on disk: ${size} (${model_cache})"
    fi
    log_success "Model '${model}' downloaded and set as default for '${container}'."
    log_info    "Start the server: localai.sh start ${container}:whisper"
}

list_models_whisper() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local hub_dir="${home_dir}/whisper/models/hub"
    local user_env="${home_dir}/.whisper.user.env"

    if ! is_installed_whisper "${container}"; then
        die "Whisper is not installed in '${container}'. Install it first: localai.sh install ${container}:whisper"
    fi

    local current_model=""
    if [[ -f "${user_env}" ]]; then
        current_model="$(awk -F'=' '/^[ \t]*export[ \t]+WHISPER_MODEL=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
    fi

    log_header "Whisper Models in '${container}'"

    local -a model_dirs=()
    if [[ -d "${hub_dir}" ]]; then
        for d in "${hub_dir}"/models--*; do
            [[ -d "$d" ]] && model_dirs+=("$d")
        done
    fi

    if [[ ${#model_dirs[@]} -eq 0 ]]; then
        log_info "No downloaded Whisper models found in '${container}'."
        log_info "Pull a model using: localai.sh model pull ${container}:whisper Systran/faster-whisper-large-v3"
        return 0
    fi

    for md in "${model_dirs[@]}"; do
        local dirname; dirname="$(basename "$md")"
        local raw_name="${dirname#models--}"
        local model_name="${raw_name//--//}"
        local size; size="$(du -sh "${md}" 2>/dev/null | awk '{print $1}')" || size="?"

        if [[ -n "${current_model}" && "${model_name}" == "${current_model}" ]]; then
            printf "  ${GREEN}•${RESET} %-45s ${DIM}(%s)${RESET} ${CYAN}[default]${RESET}\n" "${model_name}" "${size}"
        else
            printf "  ${DIM}•${RESET} %-45s ${DIM}(%s)${RESET}\n" "${model_name}" "${size}"
        fi
    done
    printf "\n"
}

start_whisper() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"
    local pid_f; pid_f="$(pid_file "${container}" "whisper")"
    local log_f="${LOG_DIR}/${container}/whisper.log"
    local user_env="${home_dir}/.whisper.user.env"

    local saved_model_line=""
    if [[ -f "${user_env}" ]]; then
        saved_model_line="$(grep -E '^[[:space:]]*export[[:space:]]+WHISPER_MODEL=' "${user_env}" | tail -n 1 || true)"
    fi

    local active_conf
    if active_conf="$(resolve_config_file "${container}")"; then
        extract_tool_config "${active_conf}" "whisper" > "${user_env}"
    else
        > "${user_env}"
    fi

    if [[ -n "${saved_model_line}" ]] && ! grep -q -E '^[[:space:]]*export[[:space:]]+WHISPER_MODEL=' "${user_env}"; then
        echo "${saved_model_line}" >> "${user_env}"
    fi

    # Config değerlerini okuyalım
    local target_port="8083"
    local target_model=""
    
    if [[ -f "${user_env}" ]]; then
        local env_port; env_port="$(awk -F'=' '/^[ \t]*export[ \t]+WHISPER_PORT=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
        [[ -n "${env_port}" && "${env_port}" =~ ^[0-9]+$ ]] && target_port="${env_port}"
        
        target_model="$(awk -F'=' '/^[ \t]*export[ \t]+WHISPER_MODEL=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
    fi

    if [[ -z "${target_model}" ]]; then
        log_warn "No Whisper model selected/configured for '${container}'!"
        log_info "Server will start, but you won't be able to transcribe until you download a model."
    fi

    local start_script="
        set -e
        source '${home_dir}/.whisper.env' 2>/dev/null || true
        source '${home_dir}/.whisper.user.env' 2>/dev/null || true
        source \"\${WHISPER_CONDA}/bin/activate\" \"\${WHISPER_ENV_NAME:-whisper}\"
        
        export UVICORN_HOST=\"\${WHISPER_HOST:-0.0.0.0}\"
        export UVICORN_PORT=\"\${WHISPER_PORT:-${target_port}}\"
        export WHISPER__INFERENCE_DEVICE=\"\${WHISPER_DEVICE:-\${WHISPER_DEFAULT_DEVICE}}\"
        export STT_MODEL_TTL=\"\${WHISPER_TTL:-300}\"
        if [[ -n \"${target_model}\" ]]; then
            export PRELOAD_MODELS=\"[\\\"${target_model}\\\"]\"
        else
            export PRELOAD_MODELS=\"[]\"
        fi
        
        nohup uvicorn --factory speaches.main:create_app >> '${log_f}' 2>&1 &
        echo \"\$!\" > '${pid_f}'
    "

    # Health check url is usually /health for speaches, but let's just check the root or /v1/models
    start_service_in_container "${container}" "whisper" "${target_port}" "python|speaches" "${start_script}" 30 "http://localhost:${target_port}/v1/models"
}

stop_whisper() {
    stop_service_in_container "$1" "whisper" 15
}

uninstall_whisper() {
    local container="$1"
    local home_dir="${BASE_DIR}/${container}"

    log_header "Uninstalling Whisper ← ${container}"
    steps_begin 2
    log_step "Stopping Whisper if running..."
    stop_whisper "${container}" || true

    log_step "Removing Whisper application directory and virtualenv..."
    # Keep models directory by default to save bandwidth, unless purged
    run_with_spinner "Deleting conda environment and config files" \
        rm -rf "${home_dir}/whisper/conda" "${home_dir}/.whisper.env" "${home_dir}/.whisper.user.env"
    steps_end
    log_info "Note: Downloaded models in ${home_dir}/whisper/models were kept. Delete them manually if you want to free up space."

    log_success "Whisper uninstalled from '${container}'."
}

transcribe_whisper() {
    local container="$1"
    local file="$2"
    shift 2

    # CLI args parse
    local lang=""
    local format="json"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --language|--lang) lang="$2"; shift 2 ;;
            --format) format="$2"; shift 2 ;;
            *) log_warn "Unknown transcribe arg: $1"; shift ;;
        esac
    done

    # Get port
    local home_dir="${BASE_DIR}/${container}"
    local user_env="${home_dir}/.whisper.user.env"
    local target_port="8083"
    local target_model=""
    if [[ -f "${user_env}" ]]; then
        local env_port; env_port="$(awk -F'=' '/^[ \t]*export[ \t]+WHISPER_PORT=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
        [[ -n "${env_port}" && "${env_port}" =~ ^[0-9]+$ ]] && target_port="${env_port}"
        target_model="$(awk -F'=' '/^[ \t]*export[ \t]+WHISPER_MODEL=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
    fi

    # Check if running
    local status; status="$(get_tool_status_in_container "${container}" "whisper")"
    if [[ "${status}" == "not installed" ]]; then
        die "Whisper is not installed in '${container}'. Install it first: localai.sh install ${container}:whisper"
    elif [[ "${status}" == "stopped" ]]; then
        log_info "Whisper is currently stopped. Starting it temporarily for transcription..."
        start_whisper "${container}"
    fi

    local fsize; fsize="$(du -h "${file}" 2>/dev/null | awk '{print $1}')" || fsize="?"
    log_step "Sending audio (${fsize}) to Whisper for transcription..."
    log_info "Model: ${target_model:-default} | Format: ${format}${lang:+ | Language: ${lang}}"
    log_info "First request may take longer while the model is loaded into memory."
    local outfile="${file}.${format}"
    local curl_cmd=(curl -sS --fail-with-body -X POST "http://localhost:${target_port}/v1/audio/transcriptions"
                    -F "file=@${file}"
                    -F "model=${target_model}"
                    -F "response_format=${format}"
                    -o "${outfile}")
    [[ -n "${lang}" ]] && curl_cmd+=(-F "language=${lang}")

    if ! run_with_spinner "Transcribing $(basename "${file}")" "${curl_cmd[@]}"; then
        log_error "Transcription request failed. Server response:"
        [[ -f "${outfile}" ]] && head -c 2000 "${outfile}" >&2 && echo >&2
        rm -f "${outfile}"
        log_info "Check server logs: localai.sh logs ${container}:whisper"
        exit 1
    fi

    log_success "Transcription saved to: ${outfile}"
}
