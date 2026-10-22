#!/usr/bin/env bash
# ==============================================================================
#  localai.sh — Local AI Environment Manager
#  Version : 0.1.0-beta
#  Author  : wamuufan
#  License : BSD 2-Clause
#
#  Manages isolated, modular AI development & runtime environments
#  using Podman and Distrobox.
#
#  USAGE:
#    localai.sh container new <name>
#    localai.sh container list
#    localai.sh container rm <name>
#    localai.sh install <container> <tool>
#    localai.sh start   <container> <tool>
#    localai.sh stop    <container> <tool>
#    localai.sh status  <container> <tool>
#    localai.sh logs    <container> <tool>
#    localai.sh shell   <container>
#    localai.sh doctor
# ==============================================================================

set -euo pipefail
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Find script directory reliably (supporting macOS and Linux)
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"

# Source core components
source "${SCRIPT_DIR}/bin/common.sh"
source "${SCRIPT_DIR}/bin/config.sh"
source "${SCRIPT_DIR}/bin/service.sh"
source "${SCRIPT_DIR}/bin/container.sh"
source "${SCRIPT_DIR}/bin/doctor.sh"
source "${SCRIPT_DIR}/bin/memory.sh"

# Source all tool modules automatically
if [[ -d "${SCRIPT_DIR}/bin/tools" ]]; then
    for tool_script in "${SCRIPT_DIR}/bin/tools"/*.sh; do
        [[ -f "${tool_script}" ]] && source "${tool_script}"
    done
fi

# ------------------------------------------------------------------------------
# COMMAND IMPLEMENTATIONS
# ------------------------------------------------------------------------------

_validate_tool_name() {
    local tool="$1"
    if [[ ! "${tool}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid tool name format: '${tool}'"
        exit 1
    fi
    local supported_tools; supported_tools="$(get_supported_tools)"
    local found=false
    local t
    for t in ${supported_tools}; do
        if [[ "$t" == "$tool" ]]; then
            found=true
            break
        fi
    done
    if [[ "${found}" != "true" ]]; then
        log_error "Unknown tool: '${tool}'"
        log_info  "Supported tools: ${supported_tools}"
        exit 1
    fi
}

_ACTIVE_LOCK_DIRS=()

_acquire_container_lock() {
    local container="$1"
    local lock_dir="${BASE_DIR}/${container}/.container.lock.d"
    mkdir -p "${BASE_DIR}/${container}"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        die "Another install or uninstall operation is currently running on container '${container}'. If stale, remove: ${lock_dir}"
    fi
    _ACTIVE_LOCK_DIRS+=("${lock_dir}")
}

_release_container_lock() {
    local container="$1"
    local lock_dir="${BASE_DIR}/${container}/.container.lock.d"
    rmdir "${lock_dir}" 2>/dev/null || true
}

_release_all_locks() {
    for ld in "${_ACTIVE_LOCK_DIRS[@]:-}"; do
        [[ -d "${ld}" ]] && rmdir "${ld}" 2>/dev/null || true
    done
    _ACTIVE_LOCK_DIRS=()
}

_on_interrupt() {
    log_warn "Operation interrupted by user! Cleaning up..."
    report_active_step "interrupted"
    _release_all_locks
    stty sane 2>/dev/null || true
    exit 130
}

_on_exit() {
    local rc=$?
    (( rc != 0 && rc != 130 )) && report_active_step "failed"
    _release_all_locks
    stty sane 2>/dev/null || true
}

trap '_on_exit' EXIT
trap '_on_interrupt' INT TERM

_validate_target_args() {
    local usage_msg="$1"
    shift
    [[ $# -eq 0 ]] && die "${usage_msg}"

    for arg in "$@"; do
        if [[ "${arg}" != *":"* ]]; then
            die "Invalid target format: '${arg}'. Expected format: <container>:<tool1,tool2,...>"
        fi
        local container="${arg%%:*}"
        local tools="${arg#*:}"
        if [[ "${tools}" == *":"* ]]; then
            die "Invalid target format: '${arg}'. Only one colon separator is allowed."
        fi
        [[ -z "${container}" || -z "${tools}" ]] && die "Invalid target format: '${arg}'. Both container and tool(s) must be specified."

        assert_container_exists "${container}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
            [[ -z "${tool}" ]] && continue
            if [[ "${tool}" == "all" ]]; then
                continue
            fi
            _validate_tool_name "${tool}"
        done
    done
}

_expand_container_tools() {
    local container="$1"
    local tools_csv="$2"
    local mode="${3:-service}"

    local -a raw_tools=()
    local has_all=false
    IFS=',' read -ra raw_tools <<< "${tools_csv}"

    local -a result=()
    for t in "${raw_tools[@]}"; do
        t="${t// /}"
        [[ -z "$t" ]] && continue
        if [[ "$t" == "all" ]]; then
            has_all=true
        else
            result+=("$t")
        fi
    done

    if [[ "${has_all}" == "true" ]]; then
        local supported_tools; supported_tools="$(get_supported_tools)"
        local found_any=false
        for t in ${supported_tools}; do
            if [[ "${mode}" == "service" && "$t" == "viewer" ]]; then
                continue
            fi
            if is_tool_installed_in_container "${container}" "$t"; then
                found_any=true
                result+=("$t")
            fi
        done
        if [[ "${found_any}" == "false" ]]; then
            log_warn "No installed tools found in '${container}'." >&2
        fi
    fi

    local -a unique=()
    for t in "${result[@]}"; do
        local already=false
        for u in "${unique[@]:-}"; do
            if [[ "$u" == "$t" ]]; then
                already=true
                break
            fi
        done
        if [[ "${already}" == "false" ]]; then
            unique+=("$t")
        fi
    done

    echo "${unique[*]:-}"
}

cmd_install() {
    _validate_target_args "Usage: localai.sh install <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        _acquire_container_lock "${container}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
            [[ -z "${tool}" ]] && continue
            if [[ "${tool}" == "all" ]]; then
                die "'all' target is not supported for install. Please specify explicit tool names."
            fi
            "install_${tool}" "${container}"
        done
        _release_container_lock "${container}"
    done
}

cmd_uninstall() {
    _validate_target_args "Usage: localai.sh uninstall <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        _acquire_container_lock "${container}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}" "all")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            "uninstall_${tool}" "${container}"
        done
        _release_container_lock "${container}"
    done
}

cmd_update() {
    _validate_target_args "Usage: localai.sh update <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        _acquire_container_lock "${container}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            if declare -f "update_${tool}" >/dev/null 2>&1; then
                "update_${tool}" "${container}"
            else
                die "Update is not supported for tool '${tool}'"
            fi
        done
        _release_container_lock "${container}"
    done
}

cmd_start() {
    _validate_target_args "Usage: localai.sh start <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            "start_${tool}" "${container}"
        done
    done
}

cmd_stop() {
    _validate_target_args "Usage: localai.sh stop <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            "stop_${tool}" "${container}"
        done
    done
    stty sane 2>/dev/null || true
}

cmd_status() {
    if [[ $# -eq 0 ]]; then
        status_all_containers_tree
        return 0
    fi

    _validate_target_args "Usage: localai.sh status [<container>:<tool1,tool2,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            status_service_in_container "${container}" "${tool}"
        done
    done
}

cmd_logs() {
    local lines=100
    local follow=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--lines)
                if [[ $# -lt 2 || -z "${2:-}" || ! "${2}" =~ ^[0-9]+$ || "${2}" -le 0 ]]; then
                    die "Option '$1' requires a positive integer argument."
                fi
                lines="$2"
                shift 2
                ;;
            --no-follow|--no-tail)
                follow=false
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "Unknown logs option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    _validate_target_args "Usage: localai.sh logs [-n <lines>] [--no-follow] <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    local -a log_files=()

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue

            local log_f="${LOG_DIR}/${container}/${tool}.log"
            if [[ ! -f "${log_f}" ]]; then
                log_error "No log file found for ${tool} in '${container}' (${log_f})."
                log_info  "Please start the service first using: localai.sh start ${container}:${tool}"
                exit 1
            fi
            log_files+=("${log_f}")
        done
    done

    if [[ ${#log_files[@]} -eq 0 ]]; then
        die "No valid log files specified or found."
    fi

    if [[ "${follow}" == "true" ]]; then
        log_info "Following runtime logs... (showing last ${lines} lines, Press Ctrl+C to stop)"
        tail -n "${lines}" -f "${log_files[@]}"
    else
        log_info "Showing last ${lines} lines of runtime logs..."
        tail -n "${lines}" "${log_files[@]}"
    fi
}

cmd_restart() {
    _validate_target_args "Usage: localai.sh restart <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        local expanded_tools; expanded_tools="$(_expand_container_tools "${container}" "${tools}")"
        for tool in ${expanded_tools}; do
            [[ -z "${tool}" ]] && continue
            log_info "Restarting ${tool} in '${container}'..."
            "stop_${tool}" "${container}"
            sleep 1
            "start_${tool}" "${container}"
        done
    done
}

cmd_shell() {
    local container="${1:-}"
    [[ -z "${container}" ]] && die "Usage: localai.sh shell <container>"
    assert_container_exists "${container}"
    log_info "Entering '${container}' — type 'exit' to return to host."
    distrobox enter "${container}"
}

cmd_model() {
    local action="${1:-}"
    case "${action}" in
        pull)
            local target="${2:-}"
            local model_name="${3:-}"
            [[ -z "${target}" || "${target}" != *":"* ]] && die "Usage: localai.sh model pull <container>:<tool> <model_name>"
            [[ -z "${model_name}" ]] && die "Model name required."

            local container="${target%%:*}"
            local tool="${target#*:}"
            assert_container_exists "${container}"
            _validate_tool_name "${tool}"

            local hook="pull_model_${tool}"
            if declare -f "${hook}" >/dev/null 2>&1; then
                "${hook}" "${container}" "${model_name}"
            else
                die "Tool '${tool}' does not support standalone model pulling via this script."
            fi
            ;;
        list)
            local target="${2:-}"
            [[ -z "${target}" || "${target}" != *":"* ]] && die "Usage: localai.sh model list <container>:<tool>"

            local container="${target%%:*}"
            local tool="${target#*:}"
            assert_container_exists "${container}"
            _validate_tool_name "${tool}"

            local hook="list_models_${tool}"
            if declare -f "${hook}" >/dev/null 2>&1; then
                "${hook}" "${container}"
            else
                die "Tool '${tool}' does not support model listing via this script."
            fi
            ;;
        *)
            die "Usage: localai.sh model {pull|list} <container>:<tool> [model_name]"
            ;;
    esac
}

cmd_transcribe() {
    local target="${1:-}"
    local file="${2:-}"
    [[ -z "${target}" || -z "${file}" ]] && die "Usage: localai.sh transcribe <container>:whisper <audio_file> [args...]"

    local container="${target%%:*}"
    local tool="${target#*:}"
    [[ "${tool}" != "whisper" ]] && die "Transcribe command is only for the whisper tool."
    assert_container_exists "${container}"

    if [[ ! -f "${file}" ]]; then
        die "Audio file not found: ${file}"
    fi

    local hook="transcribe_${tool}"
    if declare -f "${hook}" >/dev/null 2>&1; then
        "${hook}" "${container}" "${file}" "${@:3}"
    else
        die "Transcribe hook not found for tool '${tool}'"
    fi
}

cmd_open() {
    local target="${1:-}"
    local extra_arg="${2:-}"

    if [[ -z "${target}" ]]; then
        die "Usage: localai.sh open <container>:<tool>  (e.g., localai.sh open vision:comfyui)"
    fi

    local container=""
    local tool=""
    local url=""
    local title=""

    if [[ "${target}" == *":"* ]]; then
        container="${target%%:*}"
        tool="${target#*:}"
    elif [[ -n "${extra_arg}" ]]; then
        container="${target}"
        if [[ "${extra_arg}" =~ ^[0-9]+$ ]]; then
            url="http://localhost:${extra_arg}"
            title="LocalAI (${extra_arg})"
        elif [[ "${extra_arg}" =~ ^https?:// ]]; then
            url="${extra_arg}"
            title="LocalAI (${extra_arg})"
        else
            tool="${extra_arg}"
        fi
    else
        die "Invalid target format: '${target}'. Expected <container>:<tool> or <container> <port|url>"
    fi

    assert_container_exists "${container}"

    if [[ -n "${tool}" ]]; then
        local home_dir="${BASE_DIR}/${container}"
        case "${tool}" in
            comfyui)
                local port="8188"
                local user_env="${home_dir}/.comfyui.user.env"
                if [[ -f "${user_env}" ]]; then
                    local p; p="$(awk -F'=' '/^[ \t]*export[ \t]+COMFYUI_PORT=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
                    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && port="$p"
                fi
                url="http://localhost:${port}"
                title="ComfyUI - LocalAI"
                ;;
            openwebui)
                local port="8080"
                local user_env="${home_dir}/.openwebui.user.env"
                if [[ -f "${user_env}" ]]; then
                    local p; p="$(grep -E '^export PORT=' "${user_env}" | cut -d'"' -f2 || true)"
                    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && port="$p"
                fi
                url="http://localhost:${port}"
                title="Open WebUI - LocalAI"
                ;;
            iopaint)
                local port="8082"
                local user_env="${home_dir}/.iopaint.user.env"
                if [[ -f "${user_env}" ]]; then
                    local p; p="$(awk -F'=' '/^[ \t]*export[ \t]+(IOPAINT_PORT|PORT)=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
                    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && port="$p"
                fi
                url="http://localhost:${port}"
                title="IOPaint - LocalAI"
                ;;
            whisper)
                local port="8083"
                local user_env="${home_dir}/.whisper.user.env"
                if [[ -f "${user_env}" ]]; then
                    local p; p="$(awk -F'=' '/^[ \t]*export[ \t]+(WHISPER_PORT|PORT)=/ {gsub(/"/, "", $2); print $2}' "${user_env}" | tail -n 1)"
                    [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] && port="$p"
                fi
                url="http://localhost:${port}"
                title="Whisper - LocalAI"
                ;;
            ollama)
                url="http://localhost:11434"
                title="Ollama API - LocalAI"
                ;;
            viewer)
                url="http://localhost:8188"
                title="LocalAI App"
                ;;
            *)
                die "Unknown tool '${tool}' to open. Supported tools: comfyui, openwebui, iopaint, whisper, ollama"
                ;;
        esac

        # Auto-start service if it is stopped
        if [[ "${tool}" != "viewer" ]]; then
            local status
            status="$(get_tool_status_in_container "${container}" "${tool}")"
            if [[ "${status}" == "stopped" ]]; then
                log_info "${tool} is stopped in '${container}'. Starting ${tool} first..."
                "start_${tool}" "${container}"
            elif [[ "${status}" == "not installed" ]]; then
                die "${tool} is not installed in '${container}'. Install it first: localai.sh install ${container}:${tool}"
            fi
        fi
    fi

    # Ensure viewer launcher is installed
    if ! is_installed_viewer "${container}"; then
        log_info "Viewer is not installed in '${container}'. Installing automatically..."
        install_viewer "${container}"
    fi

    local app_id="localai-${container}-viewer"
    local icon_path=""
    if [[ -n "${tool}" ]]; then
        app_id="localai-${container}-${tool}"
        ensure_viewer_desktop_entry "${container}" "${tool}" "${title}"
        local host_icon="${HOME}/.local/share/icons/localai/${tool}.png"
        if [[ -f "${host_icon}" ]]; then
            icon_path="${host_icon}"
        fi
    fi

    log_info "Opening ${title} (${url}) in lightweight WebKitGTK window..."
    local viewer_log="${LOG_DIR}/${container}/viewer_${tool:-app}.log"
    mkdir -p "$(dirname "${viewer_log}")"
    nohup distrobox enter "${container}" --no-workdir --no-tty -- bash -l -c 'exec localai-viewer "$1" "$2" "$3" "$4"' _ "${url}" "${title}" "${app_id}" "${icon_path}" >"${viewer_log}" 2>&1 &
    disown 2>/dev/null || true
    log_success "Window opened."
}


cmd_help() {
    local tools; tools="$(get_supported_tools)"
    cat <<EOF

${BOLD}${CYAN}LocalAI Environment Manager${RESET} ${DIM}v${SCRIPT_VERSION}${RESET}

${BOLD}USAGE${RESET}
  localai.sh [${CYAN}-v${RESET} | ${CYAN}--verbose${RESET}] [${CYAN}-c${RESET} | ${CYAN}--config${RESET} <file>] <command> [arguments]
  localai.sh [${CYAN}-V${RESET} | ${CYAN}--version${RESET}]

${BOLD}CONTAINER MANAGEMENT${RESET}
  ${CYAN}container new${RESET}   <name> [--cpu-only|--no-nvidia]
      Create a new Ubuntu Distrobox container with isolated home directory
      at ~/.local/containers/<name>. (NVIDIA GPU passthrough auto-enabled if available)

  ${CYAN}container list${RESET}
      List all managed containers, data directory status, and disk usage.

  ${CYAN}container rm${RESET}    <name> [${CYAN}-y${RESET} | ${CYAN}--yes${RESET}] [${CYAN}-p${RESET} | ${CYAN}--purge${RESET}]
      Remove a container (distrobox rm).
      ${DIM}-y, --yes  :${RESET} Skip interactive prompt.
      ${DIM}-p, --purge:${RESET} Permanently delete container data directory as well.

  ${CYAN}shell${RESET}           <container>
      Open an interactive shell (bash) inside the specified container.

${BOLD}SERVICE & TOOL MANAGEMENT${RESET}
  ${CYAN}model pull${RESET}      <container>:<tool> <model_name>
      Download and set a model for a specific tool (e.g., whisper, ollama).

  ${CYAN}model list${RESET}      <container>:<tool>
      List downloaded or available models for a specific tool (e.g., whisper, ollama).

  ${CYAN}transcribe${RESET}      <container>:whisper <file> [--lang <lang>] [--format <format>]
      Transcribe an audio file using whisper. Output saved next to original file.

  ${CYAN}install${RESET}         <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Install tool(s) inside container(s) (idempotent / safe to re-run).
      ${DIM}Available tools:${RESET}
        ${CYAN}• ollama${RESET}    ${DIM}: Local LLM runtime (Llama 3, Mistral, Gemma, etc.)     [Port: 11434]${RESET}
        ${CYAN}• comfyui${RESET}   ${DIM}: Node-based Generative AI & Stable Diffusion UI      [Port: 8188]${RESET}
        ${CYAN}• openwebui${RESET} ${DIM}: User-friendly web UI frontend for LLMs              [Port: 8080]${RESET}
        ${CYAN}• iopaint${RESET}   ${DIM}: AI image inpainting and object removal (LaMa, etc.) [Port: 8082]${RESET}
        ${CYAN}• whisper${RESET}   ${DIM}: AI Speech-to-Text & Subtitles (faster-whisper)      [Port: 8083]${RESET}
        ${CYAN}• viewer${RESET}    ${DIM}: Ultra-lightweight WebKitGTK kiosk app window        [RAM: ~45MB]${RESET}

  ${CYAN}uninstall${RESET}       <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Uninstall tool(s) and remove application files from container(s).

  ${CYAN}update${RESET}          <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Update tool(s) to their latest release inside container(s).

  ${CYAN}start${RESET}           <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Start tool(s) in background inside container(s) (PID double-start protected).

  ${CYAN}stop${RESET}            <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Gracefully stop running tool service(s) (SIGTERM → SIGKILL after timeout).

  ${CYAN}restart${RESET}         <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Restart tool service(s) inside container(s) (stop then start).

  ${CYAN}status${RESET}          [<container>:<tool1,tool2,...> ...]
      No args : Display status tree of all managed containers and installed tools.
      With args: Check service status for specified container(s) and tool(s).

  ${CYAN}logs${RESET}            [${CYAN}-n${RESET} <lines>] [${CYAN}--no-follow${RESET}] <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Tail live runtime logs for tool(s) inside container(s).

  ${CYAN}open${RESET}            <container>:<tool>
      Open tool UI in an ultra-lightweight, distraction-free WebKitGTK window (~45MB RAM).
      (Auto-starts tool if stopped, auto-installs viewer if missing).

${BOLD}SUPPORTED TOOLS${RESET}
  ${CYAN}ollama${RESET}          Local LLM server supporting Llama 3, Mistral, Qwen, etc.
                  ${DIM}Default Port: 11434 | Data: ~/.local/containers/<name>/.ollama${RESET}
  ${CYAN}comfyui${RESET}         Modular graph-based Stable Diffusion and image/video workflow UI
                  ${DIM}Default Port: 8188  | App:  ~/.local/containers/<name>/comfyui${RESET}
  ${CYAN}openwebui${RESET}       Self-hosted web chat UI and model management for LLMs (Ollama)
                  ${DIM}Default Port: 8080  | App:  ~/.local/containers/<name>/.openwebui${RESET}
  ${CYAN}iopaint${RESET}         Image inpainting & object removal tool powered by SOTA models (LaMa, etc.)
                  ${DIM}Default Port: 8082  | App:  ~/.local/containers/<name>/iopaint${RESET}
  ${CYAN}whisper${RESET}         Lightning-fast speech-to-text (faster-whisper) with OpenAI API compatibility
                  ${DIM}Default Port: 8083  | App:  ~/.local/containers/<name>/whisper${RESET}
  ${CYAN}viewer${RESET}          Ultra-lightweight native WebKitGTK app window (no address bar)
                  ${DIM}RAM: ~45MB | Launcher: ~/.local/bin/localai-viewer${RESET}

${BOLD}MEMORY MANAGEMENT${RESET}
  ${CYAN}memory status${RESET} [<container>]
      Display host RAM, Swap, NVIDIA GPU VRAM, and AI process memory usage.

  ${CYAN}memory clean${RESET}  [<container>] [${CYAN}--all${RESET}|${CYAN}--vram${RESET}|${CYAN}--ram${RESET}|${CYAN}--cache${RESET}]
      Reclaim VRAM (evict resident models), purge shared memory, and sync caches.

${BOLD}SYSTEM COMMANDS${RESET}
  ${CYAN}doctor${RESET}
      Check host system for core (podman, distrobox, git, etc.) and optional dependencies.

  ${CYAN}version${RESET}, ${CYAN}-V${RESET}, ${CYAN}--version${RESET}
      Display script version.

  ${CYAN}help${RESET}, ${CYAN}-h${RESET}, ${CYAN}--help${RESET}
      Show this help message.

${BOLD}LOGGING ARCHITECTURE${RESET}
  ${DIM}System Logs :${RESET} ${LOG_DIR}/localai_YYYY-MM-DD.jsonl (daily JSONL format)
  ${DIM}Tool Logs   :${RESET} ${LOG_DIR}/<container>/<tool>.log

EOF
}

# ------------------------------------------------------------------------------
# MAIN DISPATCHER
# ------------------------------------------------------------------------------
main() {
    if [[ $# -eq 0 ]]; then
        log_info "Use '${CYAN}-h${RESET}' or '${CYAN}--help${RESET}' for usage information."
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -V|--version|version)
                echo "localai.sh v${SCRIPT_VERSION}"
                exit 0
                ;;
            -h|--help|help)
                cmd_help
                exit 0
                ;;
            -v|--verbose)
                export LOCALAI_VERBOSE=1
                shift
                ;;
            -c|--config)
                if [[ $# -lt 2 || -z "${2:-}" || ! -f "${2:-}" ]]; then
                    die "Configuration file not found: ${2:-}"
                fi
                export LOCALAI_CONFIG="$2"
                shift 2
                ;;
            -*)
                die "Unknown global option: $1"
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        log_info "Use '${CYAN}-h${RESET}' or '${CYAN}--help${RESET}' for usage information."
        exit 1
    fi

    local cmd="${1}"
    shift || true

    case "${cmd}" in
        container)
            local sub="${1:-}"
            shift || true
            case "${sub}" in
                new)    cmd_container_new  "$@" ;;
                list)   cmd_container_list      ;;
                rm)     cmd_container_rm    "$@" ;;
                *)
                    log_error "Unknown container sub-command: '${sub}'"
                    log_info  "Usage: localai.sh container {new|list|rm} [args]"
                    exit 1
                    ;;
            esac
            ;;
        install)    cmd_install    "$@" ;;
        uninstall)  cmd_uninstall  "$@" ;;
        update)     cmd_update     "$@" ;;
        start)      cmd_start      "$@" ;;
        stop)       cmd_stop       "$@" ;;
        restart)    cmd_restart    "$@" ;;
        status)     cmd_status     "$@" ;;
        logs)       cmd_logs       "$@" ;;
        open)       cmd_open       "$@" ;;
        shell)      cmd_shell      "$@" ;;
        model)      cmd_model      "$@" ;;
        transcribe) cmd_transcribe "$@" ;;
        doctor)     cmd_doctor          ;;
        memory)     cmd_memory     "$@" ;;
        version|-V|--version) echo "localai.sh v${SCRIPT_VERSION}" ;;
        help|-h|--help) cmd_help        ;;
        *)
            log_error "Unknown command: '${cmd}'"
            log_info  "Use '${CYAN}-h${RESET}' or '${CYAN}--help${RESET}' for usage information."
            exit 1
            ;;
    esac
}

main "$@"
