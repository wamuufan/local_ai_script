#!/usr/bin/env bash
# ==============================================================================
#  bin/common.sh — Common Constants, Utilities & Logging Helpers
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# GLOBAL CONSTANTS
# ------------------------------------------------------------------------------
if [[ -f "${SCRIPT_DIR:-.}/VERSION" ]]; then
    readonly SCRIPT_VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR:-.}/VERSION")"
else
    readonly SCRIPT_VERSION="0.1.0-beta"
fi
readonly BASE_DIR="${HOME}/.local/containers"
readonly BASE_IMAGE="docker.io/library/ubuntu:26.04"

# PID file path helper (inside the container's home so host can read it)
pid_file() {
    local container="$1" tool="$2"
    echo "${BASE_DIR}/${container}/.run/${tool}.pid"
}

# Log configuration
if [[ -w "${SCRIPT_DIR:-.}" ]]; then
    readonly LOG_DIR="${SCRIPT_DIR:-.}/log"
else
    readonly LOG_DIR="${HOME}/.local/share/localai/log"
fi

get_log_file() {
    echo "${LOG_DIR}/localai_$(date '+%Y-%m-%d').jsonl"
}

init_logging() {
    mkdir -p "${LOG_DIR}" 2>/dev/null || return 0
}

_json_escape() {
    local str="$1"
    if require_cmd jq; then
        printf '%s' "$str" | jq -Rsa '.' | sed 's/^"//;s/"$//'
        return
    fi
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\b'/\\b}"
    str="${str//$'\f'/\\f}"
    echo "$str"
}

log_to_file() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    local msg; msg="$(_json_escape "$*")"
    local log_f; log_f="$(get_log_file)"
    printf '{"timestamp":"%s","level":"%s","message":"%s"}\n' "$ts" "$level" "$msg" >> "$log_f" 2>/dev/null || return 0
}

# Run logging initialization once on load
init_logging

# ------------------------------------------------------------------------------
# COLOUR & LOGGING HELPERS
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly CYAN=$'\033[0;36m'
    readonly BOLD=$'\033[1m'
    readonly DIM=$'\033[2m'
    readonly RESET=$'\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly CYAN=''
    readonly BOLD=''
    readonly DIM=''
    readonly RESET=''
fi

log_info()    { log_to_file "INFO" "$*"; printf "${CYAN}[INFO]${RESET}    %s\n"    "$*"; }
log_success() { log_to_file "SUCCESS" "$*"; printf "${GREEN}[SUCCESS]${RESET} %s\n"   "$*"; }
log_warn()    { log_to_file "WARN" "$*"; printf "${YELLOW}[WARN]${RESET}    %s\n"  "$*"; }
log_error()   { log_to_file "ERROR" "$*"; printf "${RED}[ERROR]${RESET}   %s\n"     "$*" >&2; }
log_debug()   { if [[ "${LOCALAI_VERBOSE:-0}" == "1" ]]; then log_to_file "DEBUG" "$*"; printf "${DIM}[DEBUG]   %s${RESET}\n" "$*"; fi; }
# Plain (un-numbered) action line — used by nested helpers (start/stop/etc.)
log_action()  { log_to_file "STEP" "$*"; printf "${BOLD}${CYAN} ──▶${RESET} %s\n"  "$*"; }
log_header()  {
    log_to_file "HEADER" "$*"
    printf "\n${BOLD}${CYAN}%s${RESET}\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "${BOLD}  %s${RESET}\n"         "$*"
    printf "${BOLD}${CYAN}%s${RESET}\n\n"  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ------------------------------------------------------------------------------
# PROGRESS HELPERS (numbered steps, timers, spinner)
# ------------------------------------------------------------------------------
# Human readable duration: 75 -> "1m 15s"
format_duration() {
    local s="${1:-0}"
    if (( s >= 3600 )); then
        printf '%dh %02dm %02ds' $(( s / 3600 )) $(( (s % 3600) / 60 )) $(( s % 60 ))
    elif (( s >= 60 )); then
        printf '%dm %02ds' $(( s / 60 )) $(( s % 60 ))
    else
        printf '%ds' "${s}"
    fi
}

_STEP_TOTAL=0
_STEP_NO=0
_STEP_ACTIVE=0
_STEP_START=0
_STEP_LABEL=""
_OP_START=0

# Begin a numbered multi-step operation: steps_begin <total_steps>
steps_begin() {
    _STEP_TOTAL="${1:-0}"
    _STEP_NO=0
    _STEP_ACTIVE=0
    _STEP_LABEL=""
    _OP_START=${SECONDS}
}

# Close the currently running step (prints its duration)
_step_close() {
    if (( _STEP_ACTIVE == 1 )); then
        local el=$(( SECONDS - _STEP_START ))
        printf "     ${GREEN}✓${RESET} ${DIM}Step %d/%d completed in %s${RESET}\n\n" \
            "${_STEP_NO}" "${_STEP_TOTAL}" "$(format_duration "${el}")"
        log_to_file "STEP_DONE" "[${_STEP_NO}/${_STEP_TOTAL}] ${_STEP_LABEL} (${el}s)"
        _STEP_ACTIVE=0
    fi
}

# Finish the numbered operation (closes the last step)
steps_end() {
    _step_close
    _STEP_TOTAL=0
    _STEP_NO=0
    _STEP_LABEL=""
}

# Numbered + timed step when inside steps_begin/steps_end, plain arrow otherwise
log_step() {
    if (( _STEP_TOTAL > 0 )); then
        _step_close
        _STEP_NO=$(( _STEP_NO + 1 ))
        (( _STEP_NO > _STEP_TOTAL )) && _STEP_TOTAL=${_STEP_NO}
        _STEP_LABEL="$*"
        _STEP_START=${SECONDS}
        _STEP_ACTIVE=1
        log_to_file "STEP" "[${_STEP_NO}/${_STEP_TOTAL}] $*"
        printf "${BOLD}${CYAN} ──▶ [%d/%d]${RESET} ${BOLD}%s${RESET}  ${DIM}(started %s)${RESET}\n" \
            "${_STEP_NO}" "${_STEP_TOTAL}" "$*" "$(date '+%H:%M:%S')"
    else
        log_action "$*"
    fi
}

# Called from EXIT/INT traps: tells the user exactly which step failed/was interrupted
report_active_step() {
    local reason="${1:-failed}"
    (( _STEP_ACTIVE == 1 )) || return 0
    local el=$(( SECONDS - _STEP_START ))
    printf "\n${RED}${BOLD} ✗ Step %d/%d %s:${RESET} %s ${DIM}(after %s)${RESET}\n" \
        "${_STEP_NO}" "${_STEP_TOTAL}" "${reason}" "${_STEP_LABEL}" "$(format_duration "${el}")" >&2
    if [[ "${reason}" == "failed" ]]; then
        printf "   ${DIM}Scroll up to see the command output that caused the error.${RESET}\n" >&2
        printf "   ${DIM}Re-running the same command is safe; completed work is reused.${RESET}\n" >&2
    fi
    log_to_file "STEP_FAILED" "[${_STEP_NO}/${_STEP_TOTAL}] ${_STEP_LABEL} ${reason} after ${el}s"
    _STEP_ACTIVE=0
}

# Run a (normally silent) host command with a live spinner + elapsed timer.
# Usage: run_with_spinner "Removing files" rm -rf /path
run_with_spinner() {
    local msg="$1"; shift
    if [[ ! -t 1 ]]; then
        log_action "${msg}..."
        "$@"
        return $?
    fi
    "$@" &
    local pid=$! start=${SECONDS} i=0 rc=0
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r ${CYAN}%s${RESET} %s ${DIM}(%s)${RESET}\033[K" \
            "${frames:$(( i % 10 )):1}" "${msg}" "$(format_duration $(( SECONDS - start )))"
        i=$(( i + 1 ))
        sleep 0.2
    done
    wait "${pid}" || rc=$?
    printf "\r\033[K"
    if (( rc == 0 )); then
        printf " ${GREEN}✓${RESET} %s ${DIM}(%s)${RESET}\n" "${msg}" "$(format_duration $(( SECONDS - start )))"
    else
        printf " ${RED}✗${RESET} %s ${DIM}(failed, exit code %d)${RESET}\n" "${msg}" "${rc}"
    fi
    log_to_file "SPINNER" "${msg} rc=${rc}"
    return "${rc}"
}

die() {
    log_error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# PREREQUISITE & SYSTEM HELPERS
# ------------------------------------------------------------------------------
require_cmd() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

is_port_in_use() {
    local port="$1"
    if require_cmd ss; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q "${port}"
    elif require_cmd netstat; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        (echo > "/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

get_all_containers() {
    if ! require_cmd distrobox; then
        return 0
    fi
    local list
    list="$(distrobox list --no-color 2>/dev/null)" || return 0
    echo "${list}" | awk -F'|' 'NR>1 {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        if ($2 ~ /^[a-zA-Z0-9_.-]+$/ && $2 != "NAME") print $2
    }'
}

check_container_exists() {
    local name="$1"
    if ! require_cmd distrobox; then
        return 1
    fi
    get_all_containers | grep -Fxq -- "$name"
}

assert_container_exists() {
    local name="$1"
    if ! check_container_exists "$name"; then
        die "Container '${name}' not found. Create it first: localai.sh container new ${name}"
    fi
}

container_has_gpu() {
    distrobox enter "$1" -- bash -c "command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null" 2>/dev/null
}

ensure_base_packages() {
    local container="$1"
    shift
    local -a pkgs=("$@")
    (( ${#pkgs[@]} == 0 )) && return 0
    distrobox enter "${container}" -- bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        needed=()
        for p in ${pkgs[*]}; do
            if ! dpkg-query -W -f='\${Status}' \"\$p\" 2>/dev/null | grep -q 'ok installed'; then
                needed+=(\"\$p\")
            fi
        done
        if (( \${#needed[@]} == 0 )); then
            echo '     All ${#pkgs[@]} required system packages are already installed (skipping apt).'
            exit 0
        fi
        echo \"     Missing packages (\${#needed[@]}): \${needed[*]}\"
        echo '     Refreshing package index (apt-get update)...'
        sudo apt-get update -q -o Acquire::Languages=none
        echo \"     Downloading and installing \${#needed[@]} package(s)...\"
        sudo apt-get install -y -q \"\${needed[@]}\"
    "
}

# Shell helpers that run INSIDE the container (native Python venv creation;
# PyTorch install with automatic GPU/CPU selection).
# Usage:  distrobox enter c -- bash -c "${CONTAINER_HELPERS}
#             ensure_python_venv <venv_dir>
#             pip_install_torch torch torchvision ..."
readonly CONTAINER_HELPERS='
ensure_python_venv() {
    local venv_dir="$1"
    if [[ -x "${venv_dir}/bin/python" ]]; then
        echo "     Python virtual environment already present at ${venv_dir} (skipping)."
        return 0
    fi
    echo "     Creating Python virtual environment at ${venv_dir}..."
    python3 -m venv "${venv_dir}"
    echo "     Virtual environment created."
}
pip_install_torch() {
    # $@ = packages, e.g. torch torchvision torchaudio
    if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
        echo "     NVIDIA GPU detected — installing latest CUDA PyTorch (~2.5 GB download, please wait)..."
        pip install "$@"
    else
        echo "     No NVIDIA GPU detected — installing CPU-only PyTorch (~200 MB)..."
        pip install "$@" --index-url https://download.pytorch.org/whl/cpu
    fi
}
'
