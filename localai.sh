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
export LC_ALL=C

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

cmd_install() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh install <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"
    _acquire_container_lock "${container}"

    "install_${tool}" "${container}"
}

cmd_uninstall() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh uninstall <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"
    _acquire_container_lock "${container}"

    "uninstall_${tool}" "${container}"
}

cmd_start() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh start <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"

    "start_${tool}" "${container}"
}

cmd_stop() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh stop <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"

    "stop_${tool}" "${container}"
}

cmd_status() {
    local container="${1:-}" tool="${2:-}"
    if [[ -z "${container}" && -z "${tool}" ]]; then
        status_all_containers_tree
        return 0
    fi

    if [[ -z "${container}" || -z "${tool}" ]]; then
        die "Usage: localai.sh status [<container> <tool>]"
    fi

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"

    status_service_in_container "${container}" "${tool}"
}

cmd_logs() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh logs <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"

    local log_f="${LOG_DIR}/${container}/${tool}.log"

    if [[ ! -f "${log_f}" ]]; then
        log_error "No log file found for ${tool} in '${container}' (${log_f})."
        log_info  "Please start the service first using: localai.sh start ${container} ${tool}"
        exit 1
    fi

    log_info "Following runtime logs for ${tool} in '${container}'... (Ctrl+C to stop)"
    tail -f "${log_f}"
}

cmd_restart() {
    local container="${1:-}" tool="${2:-}"
    [[ -z "${container}" || -z "${tool}" ]] && die "Usage: localai.sh restart <container> <tool>"

    assert_container_exists "${container}"
    _validate_tool_name "${tool}"

    log_info "Restarting ${tool} in '${container}'..."
    cmd_stop "${container}" "${tool}"
    sleep 1
    cmd_start "${container}" "${tool}"
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
  ${CYAN}install${RESET}         <container> <tool>
      Install a tool inside a container (idempotent / safe to re-run).

  ${CYAN}uninstall${RESET}       <container> <tool>
      Uninstall a tool and remove its application files from the specified container.

  ${CYAN}start${RESET}           <container> <tool>
      Start a tool in the background inside the container (PID double-start protected).

  ${CYAN}stop${RESET}            <container> <tool>
      Gracefully stop a running tool service (SIGTERM → SIGKILL after timeout).

  ${CYAN}restart${RESET}         <container> <tool>
      Restart a tool service inside the container (stop then start).

  ${CYAN}status${RESET}          [<container> <tool>]
      No args : Display status tree of all managed containers and installed tools.
      With args: Check single service status for specified container and tool.

  ${CYAN}logs${RESET}            <container> <tool>
      Tail live runtime logs for a specific tool inside a container.

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
