#!/usr/bin/env bash
# ==============================================================================
#  bin/service.sh — Service Control Helpers & Tool Auto-Discovery
# ==============================================================================

set -euo pipefail

_validate_pid() {
    local pid="$1" pid_f="$2"
    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        log_error "Invalid PID format '${pid}' in ${pid_f}. Cleaning up file."
        rm -f "${pid_f}"
        return 1
    fi
    return 0
}

check_and_clean_pid() {
    local container="$1"
    local pid_f="$2"
    local tool_name="$3"
    local expected_comm="${4:-}"

    if [[ -f "${pid_f}" ]]; then
        local old_pid
        old_pid="$(cat "${pid_f}" 2>/dev/null)" || { rm -f "${pid_f}"; return 0; }
        _validate_pid "${old_pid}" "${pid_f}" || return 0
        if distrobox enter "${container}" -- bash -c "kill -0 '${old_pid}'" 2>/dev/null; then
            if [[ -n "${expected_comm}" ]]; then
                if ! distrobox enter "${container}" -- bash -c "ps -p '${old_pid}' -o comm= 2>/dev/null | grep -qiE '${expected_comm}'"; then
                    log_info "Stale PID file found (PID ${old_pid} does not match '${expected_comm}'), cleaning up..."
                    rm -f "${pid_f}"
                    return 0
                fi
            fi
            log_warn "${tool_name} is already running (PID ${old_pid}) in '${container}'."
            return 1
        else
            log_info "Stale PID file found, cleaning up..."
            rm -f "${pid_f}"
        fi
    fi
    return 0
}

stop_service_in_container() {
    local container="$1"
    local tool_name="$2"
    local timeout="${3:-10}"
    local pid_f; pid_f="$(pid_file "${container}" "${tool_name}")"

    if [[ ! -f "${pid_f}" ]]; then
        log_warn "No PID file found for ${tool_name} in '${container}'. Is it running?"
        return 0
    fi

    local pid
    pid="$(cat "${pid_f}" 2>/dev/null || echo "")"
    _validate_pid "${pid}" "${pid_f}" || return 0

    log_step "Stopping ${tool_name} (PID ${pid}) in '${container}'..."
    log_to_file "SERVICE_STOP" "Initiating stop sequence for ${tool_name} (PID ${pid}) in container '${container}'"

    local stop_rc=0
    distrobox enter "${container}" -- bash -c "
        if kill -0 '${pid}' 2>/dev/null; then
            pkill -P '${pid}' 2>/dev/null || true
            kill -TERM '${pid}' 2>/dev/null || true
            echo 'Sent SIGTERM to ${tool_name} and child processes.'
            for (( i = 1; i <= ${timeout} * 2; i++ )); do
                if ! kill -0 '${pid}' 2>/dev/null; then
                    echo '${tool_name} stopped gracefully.'
                    exit 0
                fi
                sleep 0.5
            done
            pkill -9 -P '${pid}' 2>/dev/null || true
            kill -KILL '${pid}' 2>/dev/null && echo 'Forced kill after timeout.'
        else
            echo '${tool_name} process not running.'
        fi
    " || stop_rc=$?

    if (( stop_rc != 0 )); then
        log_warn "Distrobox returned exit code ${stop_rc} during stop sequence."
    fi

    if distrobox enter "${container}" -- bash -c "kill -0 '${pid}'" 2>/dev/null; then
        log_error "Failed to stop ${tool_name} (PID ${pid}) in '${container}'."
        return 1
    else
        rm -f "${pid_f}"
        log_success "${tool_name} stopped."
        log_to_file "SERVICE_STOPPED" "${tool_name} in '${container}' stopped successfully."
    fi
}

status_service_in_container() {
    local container="$1"
    local tool_name="$2"
    local pid_f; pid_f="$(pid_file "${container}" "${tool_name}")"

    log_header "Status: ${tool_name} in container '${container}'"

    if [[ -f "${pid_f}" ]]; then
        local pid
        pid="$(cat "${pid_f}" 2>/dev/null || echo "")"
        _validate_pid "${pid}" "${pid_f}" || return 0

        if distrobox enter "${container}" -- bash -c "kill -0 '${pid}'" 2>/dev/null; then
            log_success "${tool_name} is RUNNING (PID ${pid})."
            log_info    "PID File: ${pid_f}"
            return 0
        else
            log_warn "${tool_name} PID file exists (${pid}) but process is NOT running (stale PID). Cleaning up..."
            rm -f "${pid_f}"
            return 1
        fi
    else
        log_info "${tool_name} is STOPPED."
        return 0
    fi
}

is_tool_installed_in_container() {
    local container="$1" tool="$2"
    local home_dir="${BASE_DIR}/${container}"

    local tool_lower="${tool,,}"
    local tool_upper="${tool^^}"

    if [[ -d "${home_dir}/.${tool}" ]] || \
       [[ -d "${home_dir}/${tool}" ]] || \
       [[ -d "${home_dir}/.${tool_lower}" ]] || \
       [[ -d "${home_dir}/${tool_lower}" ]] || \
       [[ -d "${home_dir}/.${tool_upper}" ]] || \
       [[ -d "${home_dir}/${tool_upper}" ]] || \
       [[ -f "${home_dir}/.${tool}.env" ]] || \
       [[ -f "${home_dir}/.${tool_lower}.env" ]] || \
       [[ -f "${home_dir}/.${tool_lower}.user.env" ]]; then
        return 0
    fi

    case "${tool_lower}" in
        ollama)
            [[ -d "${home_dir}/.ollama" ]]
            ;;
        comfyui)
            [[ -d "${home_dir}/comfyui" || -d "${home_dir}/ComfyUI" || -d "${home_dir}/.comfyui" ]]
            ;;
        openwebui)
            [[ -d "${home_dir}/.openwebui" || -d "${home_dir}/open-webui" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

get_tool_status_in_container() {
    local container="$1"
    local tool_name="$2"

    if ! is_tool_installed_in_container "${container}" "${tool_name}"; then
        echo "not installed"
        return 0
    fi

    local pid_f; pid_f="$(pid_file "${container}" "${tool_name}")"

    if [[ -f "${pid_f}" ]]; then
        local pid
        pid="$(cat "${pid_f}" 2>/dev/null || echo "")"
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            if distrobox enter "${container}" -- bash -c "kill -0 '${pid}'" 2>/dev/null; then
                echo "running (PID ${pid})"
                return 0
            else
                rm -f "${pid_f}" 2>/dev/null || true
            fi
        else
            rm -f "${pid_f}" 2>/dev/null || true
        fi
    fi
    echo "stopped"
}

status_all_containers_tree() {
    log_header "LocalAI Managed Status"

    local container_list; container_list="$(get_all_containers)"
    local containers=()
    if [[ -n "${container_list}" ]]; then
        while IFS= read -r c; do
            [[ -n "$c" ]] && containers+=("$c")
        done <<< "${container_list}"
    fi

    if [[ ${#containers[@]} -eq 0 ]]; then
        log_info "No containers found."
        return 0
    fi

    local tools=()
    local t
    for t in $(get_supported_tools); do
        [[ -n "$t" ]] && tools+=("$t")
    done

    printf "${BOLD}status${RESET}\n"

    local num_containers=${#containers[@]}
    local c_idx=0

    for container in "${containers[@]}"; do
        c_idx=$((c_idx + 1))
        local c_prefix="├── "
        local c_sub_prefix="│   "
        if (( c_idx == num_containers )); then
            c_prefix="└── "
            c_sub_prefix="    "
        fi

        printf "%s${BOLD}${CYAN}%s${RESET}\n" "${c_prefix}" "${container}"

        local num_tools=${#tools[@]}
        local t_idx=0

        local installed_tools=()
        for tool in "${tools[@]}"; do
            if is_tool_installed_in_container "${container}" "${tool}"; then
                installed_tools+=("${tool}")
            fi
        done

        local num_installed=${#installed_tools[@]}
        if (( num_installed == 0 )); then
            printf "%s└── ${DIM}(no tools installed)${RESET}\n" "${c_sub_prefix}"
            continue
        fi

        local t_idx=0
        for tool in "${installed_tools[@]}"; do
            t_idx=$((t_idx + 1))
            local t_prefix="├── "
            if (( t_idx == num_installed )); then
                t_prefix="└── "
            fi

            local st; st="$(get_tool_status_in_container "${container}" "${tool}")"
            local st_color="${DIM}"
            if [[ "${st}" == running* ]]; then
                st_color="${GREEN}"
            elif [[ "${st}" == "stopped" ]]; then
                st_color="${YELLOW}"
            fi

            printf "%s%s%-15s ${st_color}%s${RESET}\n" "${c_sub_prefix}" "${t_prefix}" "${tool}" "[${st}]"
        done
    done
    printf "\n"
}

wait_for_service() {
    local url="$1" timeout="${2:-30}" name="${3:-service}"
    log_step "Waiting for ${name} to become ready at ${url}..."
    local i
    for (( i = 1; i <= timeout; i++ )); do
        if curl -sf "${url}" > /dev/null 2>&1; then
            log_success "${name} is online and responding at ${url}"
            log_to_file "HEALTH_CHECK" "${name} responds OK at ${url}"
            return 0
        fi
        sleep 1
    done
    log_warn "${name} did not respond at ${url} within ${timeout} seconds. Check tool logs."
    log_to_file "HEALTH_CHECK_TIMEOUT" "${name} timed out after ${timeout}s at ${url}"
    return 1
}

# Auto-discover tools placed in bin/tools/
get_supported_tools() {
    local tools=()
    local tool_dir="${SCRIPT_DIR}/bin/tools"
    if [[ -d "${tool_dir}" ]]; then
        local sh_files
        sh_files=("${tool_dir}"/*.sh)
        for f in "${sh_files[@]}"; do
            if [[ -f "$f" ]]; then
                local bname
                bname="$(basename "$f" .sh)"
                tools+=("$bname")
            fi
        done
    fi
    echo "${tools[*]:-}"
}

tool_is_supported() {
    local tool="$1"
    local t
    local supported_tools; supported_tools="$(get_supported_tools)"
    for t in ${supported_tools}; do
        [[ "$t" == "$tool" ]] && return 0
    done
    return 1
}
