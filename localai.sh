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

_acquire_container_lock() {
    local container="$1"
    local lock_dir="${BASE_DIR}/${container}"
    mkdir -p "${lock_dir}"
    local lock_file="${lock_dir}/.container.lock"
    exec 200>"${lock_file}"
    if ! flock -n 200 2>/dev/null; then
        die "Another install or uninstall operation is currently running on container '${container}'. Please wait."
    fi
}

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
            _validate_tool_name "${tool}"
        done
    done
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
            trap 'log_warn "Installation interrupted by user! Exiting..."; exit 130' INT TERM
            "install_${tool}" "${container}"
            trap - INT TERM
        done
    done
}

cmd_uninstall() {
    _validate_target_args "Usage: localai.sh uninstall <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        _acquire_container_lock "${container}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
            [[ -z "${tool}" ]] && continue
            "uninstall_${tool}" "${container}"
        done
    done
}

cmd_start() {
    _validate_target_args "Usage: localai.sh start <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
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

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
            [[ -z "${tool}" ]] && continue
            "stop_${tool}" "${container}"
        done
    done
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

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
            [[ -z "${tool}" ]] && continue
            status_service_in_container "${container}" "${tool}"
        done
    done
}

cmd_logs() {
    _validate_target_args "Usage: localai.sh logs <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    local -a log_files=()

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
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

    log_info "Following runtime logs... (showing last 100 lines, Press Ctrl+C to stop)"
    tail -n 100 -f "${log_files[@]}"
}

cmd_restart() {
    _validate_target_args "Usage: localai.sh restart <container>:<tool1,tool2,...> [<container2>:<tool3,...> ...]" "$@"

    for arg in "$@"; do
        local container="${arg%%:*}"
        local tools="${arg#*:}"

        IFS=',' read -ra tool_array <<< "${tools}"
        for tool in "${tool_array[@]}"; do
            tool="${tool// /}"
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

cmd_help() {
    local tools; tools="$(get_supported_tools)"
    cat <<EOF

${BOLD}${CYAN}LocalAI Environment Manager${RESET} ${DIM}v${SCRIPT_VERSION}${RESET}

${BOLD}USAGE${RESET}
  localai.sh [${CYAN}-v${RESET} | ${CYAN}--verbose${RESET}] <command> [arguments]

${BOLD}CONTAINER MANAGEMENT${RESET}
  ${CYAN}container new${RESET}   <name>
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

${BOLD}SERVICE & TOOL MANAGEMENT${RESET} (Supported tools: ${tools})
  ${CYAN}install${RESET}         <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Install tool(s) inside container(s) (idempotent / safe to re-run).

  ${CYAN}uninstall${RESET}       <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Uninstall tool(s) and remove application files from container(s).

  ${CYAN}start${RESET}           <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Start tool(s) in background inside container(s) (PID double-start protected).

  ${CYAN}stop${RESET}            <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Gracefully stop running tool service(s) (SIGTERM → SIGKILL after timeout).

  ${CYAN}restart${RESET}         <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Restart tool service(s) inside container(s) (stop then start).

  ${CYAN}status${RESET}          [<container>:<tool1,tool2,...> ...]
      No args : Display status tree of all managed containers and installed tools.
      With args: Check service status for specified container(s) and tool(s).

  ${CYAN}logs${RESET}            <container>:<tool1,tool2,...> [<container2>:<tool3,...>]
      Tail live runtime logs for tool(s) inside container(s).

${BOLD}SYSTEM COMMANDS${RESET}
  ${CYAN}doctor${RESET}
      Check host system for core (podman, distrobox, git, etc.) and optional dependencies.

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

    # Check for global flags
    if [[ "${1:-}" =~ ^(-v|--verbose)$ ]]; then
        export LOCALAI_VERBOSE=1
        shift
    fi

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
        start)      cmd_start      "$@" ;;
        stop)     cmd_stop     "$@" ;;
        restart)  cmd_restart  "$@" ;;
        status)   cmd_status   "$@" ;;
        logs)     cmd_logs     "$@" ;;
        shell)    cmd_shell    "$@" ;;
        doctor)   cmd_doctor        ;;
        help|-h|--help) cmd_help    ;;
        *)
            log_error "Unknown command: '${cmd}'"
            log_info  "Use '${CYAN}-h${RESET}' or '${CYAN}--help${RESET}' for usage information."
            exit 1
            ;;
    esac
}

main "$@"
