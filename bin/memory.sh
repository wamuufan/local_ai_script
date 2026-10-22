#!/usr/bin/env bash
# ==============================================================================
#  bin/memory.sh — Memory & Resource Management for LocalAI
# ==============================================================================

set -euo pipefail

_format_bytes() {
    local bytes="$1"
    if [[ "${bytes}" -ge 1073741824 ]]; then
        awk -v b="${bytes}" 'BEGIN { printf "%.2f GiB", b/1073741824 }'
    elif [[ "${bytes}" -ge 1048576 ]]; then
        awk -v b="${bytes}" 'BEGIN { printf "%.2f MiB", b/1048576 }'
    elif [[ "${bytes}" -ge 1024 ]]; then
        awk -v b="${bytes}" 'BEGIN { printf "%.2f KiB", b/1024 }'
    else
        echo "${bytes} B"
    fi
}

_format_kb() {
    local kb="$1"
    if [[ "${kb}" -ge 1048576 ]]; then
        awk -v k="${kb}" 'BEGIN { printf "%.2f GiB", k/1048576 }'
    elif [[ "${kb}" -ge 1024 ]]; then
        awk -v k="${kb}" 'BEGIN { printf "%.2f MiB", k/1024 }'
    else
        echo "${kb} KiB"
    fi
}

memory_status() {
    local target_container="${1:-}"

    log_header "Host & Container Memory Status"

    # 1. System RAM & Swap
    echo -e "${BOLD}${CYAN}SYSTEM MEMORY (RAM & SWAP)${RESET}"
    if command -v free &>/dev/null; then
        free -h --wide 2>/dev/null || free -m
    elif [[ -f /proc/meminfo ]]; then
        awk '
            /MemTotal/     { total=$2 }
            /MemFree/      { free=$2 }
            /MemAvailable/ { avail=$2 }
            /SwapTotal/    { stotal=$2 }
            /SwapFree/     { sfree=$2 }
            END {
                printf "  RAM Total: %s, Available: %s, Free: %s\n", total" kB", avail" kB", free" kB";
                printf "  Swap Total: %s, Free: %s\n", stotal" kB", sfree" kB";
            }
        ' /proc/meminfo
    fi
    echo ""

    # 2. NVIDIA GPU & VRAM
    echo -e "${BOLD}${CYAN}GPU & VRAM STATUS${RESET}"
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null | awk -F', ' '{
                printf "  GPU: %s (Driver: %s)\n", $1, $2;
                printf "  VRAM: %s MiB used / %s MiB total (%s MiB free)\n", $4, $3, $5;
                printf "  GPU Load: %s%% | Temp: %s°C\n", $6, $7;
            }' || echo "  Unable to query nvidia-smi."

        echo ""
        echo -e "${BOLD}${CYAN}ACTIVE GPU COMPUTE PROCESSES${RESET}"
        local gpu_procs
        gpu_procs="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)"
        if [[ -n "${gpu_procs}" ]]; then
            printf "  %-10s %-35s %-15s\n" "PID" "NAME" "VRAM USED"
            echo "  --------------------------------------------------------------"
            while IFS=', ' read -r pid name mem; do
                printf "  %-10s %-35s %-15s\n" "${pid}" "${name}" "${mem} MiB"
            done <<< "${gpu_procs}"
        else
            echo "  No active GPU compute processes detected."
        fi
    else
        echo "  No NVIDIA GPU detected or nvidia-smi is not available."
    fi
    echo ""

    # 3. AI Service Process Memory Usage
    echo -e "${BOLD}${CYAN}LOCAL AI PROCESSES MEMORY USAGE${RESET}"
    local containers=()
    if [[ -n "${target_container}" ]]; then
        assert_container_exists "${target_container}"
        containers=("${target_container}")
    else
        containers=($(get_all_containers 2>/dev/null || true))
    fi

    if [[ ${#containers[@]} -eq 0 ]]; then
        echo "  No managed containers found."
        return 0
    fi

    local found_ai_process=false
    printf "  %-16s %-12s %-8s %-14s %-12s\n" "CONTAINER" "TOOL" "PID" "RESIDENT RAM" "STATUS"
    echo "  ----------------------------------------------------------------------"

    for c in "${containers[@]}"; do
        local run_dir="${BASE_DIR}/${c}/.run"
        [[ ! -d "${run_dir}" ]] && continue

        for pid_file in "${run_dir}"/*.pid; do
            [[ ! -f "${pid_file}" ]] && continue
            local tool_name; tool_name="$(basename "${pid_file}" .pid)"
            local pid; pid="$(cat "${pid_file}" 2>/dev/null || true)"
            [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] && continue

            if distrobox enter "${c}" -- kill -0 "${pid}" 2>/dev/null; then
                found_ai_process=true
                local rss_kb
                rss_kb="$(distrobox enter "${c}" -- ps -o rss= -p "${pid}" 2>/dev/null | tr -d ' ' || echo 0)"
                local rss_fmt; rss_fmt="$(_format_kb "${rss_kb}")"
                printf "  %-16s %-12s %-8s %-14s %-12s\n" "${c}" "${tool_name}" "${pid}" "${rss_fmt}" "${GREEN}running${RESET}"
            fi
        done
    done

    if [[ "${found_ai_process}" != "true" ]]; then
        echo "  No active LocalAI services currently running."
    fi
    echo ""

    # 4. Active Config Status
    local active_conf
    if active_conf="$(resolve_config_file "${target_container}")"; then
        local strategy
        strategy="$(get_config_value "${active_conf}" "memory" "MEMORY_STRATEGY" 2>/dev/null || true)"
        [[ -z "${strategy}" ]] && strategy="$(get_config_value "${active_conf}" "memory" "MEMORY_MANAGEMENT_STRATEGY" 2>/dev/null || true)"
        [[ -z "${strategy}" ]] && strategy="$(get_config_value "${active_conf}" "memory" "MEMORY_PROFILE" 2>/dev/null || true)"

        if [[ -n "${strategy}" ]]; then
            local desc; desc="$(get_memory_strategy_description "${strategy}")"
            echo -e "${BOLD}Active Config  :${RESET} ${active_conf}"
            echo -e "${BOLD}Memory Strategy:${RESET} ${CYAN}${strategy}${RESET} — ${DIM}${desc}${RESET}"
        else
            echo -e "${BOLD}Active Config  :${RESET} ${active_conf} (${CYAN}Direct Static Configuration${RESET})"
        fi
    else
        echo -e "${BOLD}Active Config  :${RESET} ${DIM}None active (.disabled files ignored, using built-in defaults)${RESET}"
    fi
}

memory_clean() {
    local target_container=""
    local mode="all"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)    mode="all" ;;
            --vram)   mode="vram" ;;
            --ram)    mode="ram" ;;
            --cache)  mode="cache" ;;
            -*)
                die "Unknown option for memory clean: $1"
                ;;
            *)
                if [[ -z "${target_container}" ]]; then
                    target_container="$1"
                fi
                ;;
        esac
        shift
    done

    log_header "LocalAI Memory & VRAM Reclamation"

    local containers=()
    if [[ -n "${target_container}" ]]; then
        assert_container_exists "${target_container}"
        containers=("${target_container}")
    else
        containers=($(get_all_containers 2>/dev/null || true))
    fi

    # --- 1. VRAM Reclamation (Ollama model unloads) ---
    if [[ "${mode}" == "all" || "${mode}" == "vram" ]]; then
        log_step "Reclaiming GPU VRAM from running AI services..."

        for c in "${containers[@]}"; do
            # Ollama model eviction via API
            local ollama_pid_f="${BASE_DIR}/${c}/.run/ollama.pid"
            if [[ -f "${ollama_pid_f}" ]]; then
                local user_env="${BASE_DIR}/${c}/.ollama/user.env"
                local port="11434"
                if [[ -f "${user_env}" ]]; then
                    local p; p="$(awk -F'=' '/^[ \t]*export[ \t]+OLLAMA_HOST=/ {print $2}' "${user_env}" | tr -d '"'\'' ' | awk -F':' '{print $NF}')"
                    [[ -n "${p}" && "${p}" =~ ^[0-9]+$ ]] && port="${p}"
                fi

                # Query running models in Ollama
                local running_models
                running_models="$(curl -s "http://127.0.0.1:${port}/api/ps" 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || true)"
                if [[ -n "${running_models}" ]]; then
                    for m in ${running_models}; do
                        log_info "Evicting model '${m}' from VRAM in '${c}' (Ollama port ${port})..."
                        curl -s "http://127.0.0.1:${port}/api/generate" -d "{\"model\": \"${m}\", \"keep_alive\": 0}" >/dev/null 2>&1 || true
                    done
                    log_success "Ollama models evicted from VRAM in '${c}'."
                else
                    log_debug "No resident models reported by Ollama in '${c}'."
                fi
            fi

            # ComfyUI memory cleanup trigger
            local comfy_pid_f="${BASE_DIR}/${c}/.run/comfyui.pid"
            if [[ -f "${comfy_pid_f}" ]]; then
                local comfy_user_env="${BASE_DIR}/${c}/.comfyui.user.env"
                local cport="8188"
                if [[ -f "${comfy_user_env}" ]]; then
                    local cp; cp="$(awk -F'=' '/^[ \t]*export[ \t]+COMFYUI_PORT=/ {print $2}' "${comfy_user_env}" | tr -d '"'\'' ')"
                    [[ -n "${cp}" && "${cp}" =~ ^[0-9]+$ ]] && cport="${cp}"
                fi
                # Prompt ComfyUI unload models endpoint if available
                curl -s -X POST "http://127.0.0.1:${cport}/free" -d '{"unload_models":true,"free_memory":true}' >/dev/null 2>&1 || true
                log_info "Sent memory release signal to ComfyUI (port ${cport}) in '${c}'."
            fi
        done
    fi

    # --- 2. Temporary & Shared Memory Cleanup ---
    if [[ "${mode}" == "all" || "${mode}" == "ram" || "${mode}" == "cache" ]]; then
        log_step "Cleaning temporary files and shared memory..."

        for c in "${containers[@]}"; do
            # Clean obsolete lock files or sockets
            find "${BASE_DIR}/${c}/.run" -name "*.sock" -delete 2>/dev/null || true
            # Clean container /dev/shm remnants
            distrobox enter "${c}" -- bash -c "
                rm -f /dev/shm/torch_* /dev/shm/cuda_* /dev/shm/sem.* 2>/dev/null || true
            " 2>/dev/null || true
        done
    fi

    # --- 3. Linux Page Cache / System Sync ---
    if [[ "${mode}" == "all" || "${mode}" == "cache" || "${mode}" == "ram" ]]; then
        log_step "Syncing filesystem page cache..."
        sync

        # Check if drop_caches was configured or can be performed
        local active_conf
        local auto_drop="false"
        if active_conf="$(resolve_config_file "${target_container}")"; then
            auto_drop="$(get_config_value "${active_conf}" "memory" "AUTO_DROP_CACHES" 2>/dev/null || echo "false")"
        fi

        if [[ "${auto_drop}" == "true" ]]; then
            if [[ -w /proc/sys/vm/drop_caches ]]; then
                echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && log_success "System page cache dropped (/proc/sys/vm/drop_caches)."
            elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
                sudo sync && sudo sysctl -w vm.drop_caches=3 >/dev/null 2>&1 && log_success "System page cache dropped via sudo."
            else
                log_info "To drop host system buffer/page cache manually, run: sudo sysctl -w vm.drop_caches=3"
            fi
        fi
    fi

    log_success "Memory cleanup completed."
}

# Post-stop cleanup hook called whenever a tool service is terminated
post_stop_cleanup() {
    local container="$1"
    local tool_name="$2"

    log_debug "Running post-stop cleanup for ${tool_name} in '${container}'..."
    local current_user; current_user="$(id -un)"

    # 1. Clean container shared memory without allocating interactive PTY
    podman exec --user "${current_user}" "${container}" bash -c "
        rm -f /dev/shm/torch_* /dev/shm/cuda_* /dev/shm/sem.* 2>/dev/null || true
    " 2>/dev/null || true

    # 2. Check if auto memory clean on stop is enabled
    local active_conf
    if active_conf="$(resolve_config_file "${container}")"; then
        local auto_clean
        auto_clean="$(get_config_value "${active_conf}" "memory" "AUTO_CLEAN_ON_STOP" 2>/dev/null || echo "false")"
        if [[ "${auto_clean}" == "true" ]]; then
            log_info "Auto-clean on stop active: reclaiming VRAM/cache for '${container}'..."
            memory_clean "${container}" --all >/dev/null 2>&1 || true
        fi
    fi

    # Ensure terminal line settings remain intact
    stty sane 2>/dev/null || true
    log_debug "Post-stop cleanup finished for ${tool_name}."
}

cmd_memory() {
    local sub="${1:-status}"
    shift || true

    case "${sub}" in
        status)
            memory_status "$@"
            ;;
        clean)
            memory_clean "$@"
            ;;
        *)
            log_error "Unknown memory sub-command: '${sub}'"
            log_info  "Usage: localai.sh memory {status|clean} [args]"
            exit 1
            ;;
    esac
}
