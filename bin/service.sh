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
    expected_comm="${expected_comm//\\|/|}"

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

rotate_log_file() {
    local log_f="$1"
    local max_size="${2:-10485760}" # 10MB
    local max_backups="${3:-3}"
    [[ ! -f "${log_f}" ]] && return 0
    local size; size="$(stat -c%s "${log_f}" 2>/dev/null || echo 0)"
    (( size < max_size )) && return 0
    for (( i = max_backups; i >= 1; i-- )); do
        local prev=$(( i - 1 ))
        if (( prev == 0 )); then
            [[ -f "${log_f}" ]] && mv "${log_f}" "${log_f}.1"
        else
            [[ -f "${log_f}.${prev}" ]] && mv "${log_f}.${prev}" "${log_f}.${i}"
        fi
    done
    rm -f "${log_f}.$((max_backups + 1))" 2>/dev/null || true
}

start_service_in_container() {
    local container="$1"
    local tool_name="$2"
    local target_port="$3"
    local expected_comm="$4"
    local start_script="$5"
    local timeout="${6:-15}"
    local health_url="${7:-http://localhost:${target_port}}"

    local home_dir="${BASE_DIR}/${container}"
    local pid_f; pid_f="$(pid_file "${container}" "${tool_name,,}")"
    local log_f="${LOG_DIR}/${container}/${tool_name,,}.log"

    mkdir -p "${home_dir}/.run" "${LOG_DIR}/${container}"
    rotate_log_file "${log_f}"

    check_and_clean_pid "${container}" "${pid_f}" "${tool_name}" "${expected_comm}" || return 0

    if [[ -n "${target_port}" ]] && is_port_in_use "${target_port}"; then
        log_error "Port ${target_port} is already in use on host!"
        log_info  "${tool_name} or another service appears to be running on port ${target_port}."
        return 1
    fi

    log_action "Starting ${tool_name} in '${container}' (background)..."
    # Launch in true detached daemon mode via podman exec -d to prevent session termination
    local current_user; current_user="$(id -un)"
    if ! podman exec -d --user "${current_user}" --env "HOME=${home_dir}" --workdir "${home_dir}" "${container}" bash -c "${start_script}" 2>/dev/null; then
        # Fallback to distrobox enter if podman direct exec is unavailable
        log_debug "podman exec failed (container may be stopped); falling back to distrobox enter..."
        if ! distrobox enter "${container}" -- bash -c "${start_script}"; then
            log_error "${tool_name} failed to start or stopped immediately. Check logs: ${log_f}"
            rm -f "${pid_f}"
            return 1
        fi
    fi

    local pid=""
    for (( i = 1; i <= 20; i++ )); do
        if [[ -f "${pid_f}" ]]; then
            pid="$(cat "${pid_f}" 2>/dev/null || echo "")"
            [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && break
        fi
        sleep 0.25
    done

    if [[ -n "${pid}" ]]; then
        log_info "Process launched (PID ${pid}). Logs: ${log_f}"
        if [[ -n "${target_port}" ]]; then
            local wrc=0
            wait_for_service "${health_url}" "${timeout}" "${tool_name}" "${pid}" "${log_f}" "${container}" || wrc=$?
            if (( wrc == 2 )); then
                log_error "${tool_name} exited during startup. Last log lines:"
                _show_log_tail "${log_f}" 20
                rm -f "${pid_f}"
                return 1
            elif (( wrc == 1 )); then
                log_warn "${tool_name} is running (PID ${pid}) but not responding yet — it may still be loading."
                log_info "Follow progress: localai.sh logs ${container}:${tool_name,,}"
                log_info "Check later    : localai.sh status ${container}:${tool_name,,}"
                return 0
            fi
            log_success "${tool_name} started (PID ${pid}). Access: ${health_url}"
        else
            log_success "${tool_name} started (PID ${pid})."
        fi
        return 0
    fi

    log_error "${tool_name} failed to start or stopped immediately. Last log lines:"
    _show_log_tail "${log_f}" 20
    rm -f "${pid_f}"
    return 1
}

# Print last N lines of a log file, indented & dimmed
_show_log_tail() {
    local log_f="$1" n="${2:-20}"
    if [[ -s "${log_f}" ]]; then
        printf "${DIM}%s${RESET}\n" "────────── ${log_f} (last ${n} lines) ──────────" >&2
        tail -n "${n}" "${log_f}" | while IFS= read -r l; do printf "${DIM}  │${RESET} %s\n" "${l}" >&2; done
        printf "${DIM}%s${RESET}\n" "──────────────────────────────────────────────" >&2
    else
        log_info "(log file is empty or missing: ${log_f})"
    fi
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

    log_action "Stopping ${tool_name} (PID ${pid}) in '${container}' (graceful timeout: ${timeout}s)..."
    log_to_file "SERVICE_STOP" "Initiating stop sequence for ${tool_name} (PID ${pid}) in container '${container}'"

    local current_user; current_user="$(id -un)"
    local stop_rc=0
    # Execute non-interactive stop sequence via podman to avoid PTY/TTY corruption
    if ! podman exec --user "${current_user}" "${container}" bash -c "
        if kill -0 '${pid}' 2>/dev/null; then
            pkill -P '${pid}' 2>/dev/null || true
            kill -TERM '${pid}' 2>/dev/null || true
            echo '     Sent SIGTERM to ${tool_name} and child processes, waiting for exit...'
            for (( i = 1; i <= ${timeout} * 2; i++ )); do
                if ! kill -0 '${pid}' 2>/dev/null; then
                    echo \"     ${tool_name} stopped gracefully after \$(( (i + 1) / 2 ))s.\"
                    exit 0
                fi
                if (( i % 6 == 0 )); then
                    echo \"     ...still shutting down (\$(( i / 2 ))s / ${timeout}s)\"
                fi
                sleep 0.5
            done
            echo '     Graceful timeout reached — sending SIGKILL...'
            pkill -9 -P '${pid}' 2>/dev/null || true
            kill -KILL '${pid}' 2>/dev/null && echo '     Forced kill after timeout.'
        else
            echo '     ${tool_name} process not running.'
        fi
    " 2>/dev/null; then
        stop_rc=$?
    fi

    # Quiet verification without leaking stderr
    if kill -0 "${pid}" 2>/dev/null || podman exec --user "${current_user}" "${container}" bash -c "kill -0 '${pid}' 2>/dev/null"; then
        log_error "Failed to stop ${tool_name} (PID ${pid}) in '${container}'."
        stty sane 2>/dev/null || true
        return 1
    else
        rm -f "${pid_f}"
        log_success "${tool_name} stopped."
        log_to_file "SERVICE_STOPPED" "${tool_name} in '${container}' stopped successfully."
        if declare -f post_stop_cleanup >/dev/null 2>&1; then
            post_stop_cleanup "${container}" "${tool_name}"
        fi
        stty sane 2>/dev/null || true
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
    local hook="is_installed_${tool,,}"
    if declare -f "${hook}" >/dev/null 2>&1; then
        "${hook}" "${container}"
        return $?
    fi
    local home_dir="${BASE_DIR}/${container}"
    local tool_l="${tool,,}"
    [[ -d "${home_dir}/.${tool_l}" || -d "${home_dir}/${tool_l}" || -f "${home_dir}/.${tool_l}.env" ]]
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
            # Fast check on shared host PID namespace first (avoids podman lock contention)
            if kill -0 "${pid}" 2>/dev/null || distrobox enter "${container}" -- bash -c "kill -0 '${pid}'" 2>/dev/null; then
                echo "running (PID ${pid})"
                return 0
            fi
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

        local pid_pairs=""
        declare -A tool_status
        for tool in "${installed_tools[@]}"; do
            tool_status["$tool"]="stopped"
            local pid_f; pid_f="$(pid_file "${container}" "${tool}")"
            if [[ -f "${pid_f}" ]]; then
                local pid; pid="$(cat "${pid_f}" 2>/dev/null || true)"
                if [[ "$pid" =~ ^[0-9]+$ ]]; then
                    pid_pairs+="${tool}:${pid} "
                else
                    rm -f "${pid_f}" 2>/dev/null || true
                fi
            fi
        done

        if [[ -n "${pid_pairs}" ]]; then
            local db_out; db_out="$(distrobox enter "${container}" -- bash -c "
                for pair in ${pid_pairs}; do
                    tool=\${pair%%:*}
                    pid=\${pair#*:}
                    if kill -0 \"\$pid\" 2>/dev/null; then
                        echo \"\$tool:running:\$pid\"
                    else
                        echo \"\$tool:dead:\$pid\"
                    fi
                done
            " 2>/dev/null || true)"

            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local t="${line%%:*}"
                local rest="${line#*:}"
                local st="${rest%%:*}"
                local p="${rest#*:}"
                if [[ "$st" == "running" ]]; then
                    tool_status["$t"]="running (PID $p)"
                elif [[ "$st" == "dead" ]]; then
                    local pid_f; pid_f="$(pid_file "${container}" "${t}")"
                    rm -f "${pid_f}" 2>/dev/null || true
                fi
            done <<< "$db_out"
        fi

        local t_idx=0
        for tool in "${installed_tools[@]}"; do
            t_idx=$((t_idx + 1))
            local t_prefix="├── "
            if (( t_idx == num_installed )); then
                t_prefix="└── "
            fi

            local st="${tool_status[$tool]}"
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

# wait_for_service <url> [timeout] [name] [pid] [log_file] [container]
# Returns: 0 = ready, 1 = timed out (process still alive), 2 = process died
wait_for_service() {
    local url="$1" timeout="${2:-30}" name="${3:-service}"
    local pid="${4:-}" log_f="${5:-}" container="${6:-}"
    log_action "Waiting for ${name} to become ready at ${url} (timeout ${timeout}s)..."

    local start=${SECONDS} i=0 last_report=0 elapsed=0
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local is_tty=0; [[ -t 1 ]] && is_tty=1
    local cols; cols="$(tput cols 2>/dev/null || echo 100)"
    local max_log=$(( cols - 40 )); (( max_log < 20 )) && max_log=20

    while :; do
        elapsed=$(( SECONDS - start ))
        if curl -sf -m 2 "${url}" > /dev/null 2>&1; then
            (( is_tty )) && printf "\r\033[K"
            log_success "${name} is online and responding at ${url} (after $(format_duration "${elapsed}"))"
            log_to_file "HEALTH_CHECK" "${name} responds OK at ${url}"
            return 0
        fi

        # Early crash detection (host PID namespace first; confirm inside container once)
        if [[ -n "${pid}" ]] && ! kill -0 "${pid}" 2>/dev/null; then
            if [[ -n "${container}" ]] && distrobox enter "${container}" -- bash -c "kill -0 '${pid}'" 2>/dev/null; then
                pid=""   # PID namespaces are not shared; stop checking from host
            else
                (( is_tty )) && printf "\r\033[K"
                log_to_file "HEALTH_CHECK_DIED" "${name} (PID ${pid}) exited after ${elapsed}s"
                return 2
            fi
        fi

        if (( elapsed >= timeout )); then
            break
        fi

        local last=""
        if [[ -n "${log_f}" && -s "${log_f}" ]]; then
            last="$(tail -n 1 "${log_f}" 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\033' | cut -c1-"${max_log}")" || last=""
        fi
        if (( is_tty )); then
            printf "\r ${CYAN}%s${RESET} Waiting for %s ${DIM}(%ss / %ss)${RESET} ${DIM}%s${RESET}\033[K" \
                "${frames:$(( i % 10 )):1}" "${name}" "${elapsed}" "${timeout}" "${last}"
        elif (( elapsed - last_report >= 10 )); then
            printf "     ...still waiting for %s (%ss / %ss) %s\n" "${name}" "${elapsed}" "${timeout}" "${last}"
            last_report=${elapsed}
        fi
        i=$(( i + 1 ))
        sleep 0.5
    done

    (( is_tty )) && printf "\r\033[K"
    log_warn "${name} did not respond at ${url} within ${timeout} seconds."
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
