#!/usr/bin/env bash
# ==============================================================================
#  bin/common.sh — Common Constants, Utilities & Logging Helpers
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# GLOBAL CONSTANTS
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="0.1.0-beta"
readonly BASE_DIR="${HOME}/.local/containers"
readonly BASE_IMAGE="docker.io/library/ubuntu:26.04"

# PID file path helper (inside the container's home so host can read it)
pid_file() {
    local container="$1" tool="$2"
    echo "${BASE_DIR}/${container}/.run/${tool}.pid"
}

# Log configuration
if [[ -w "${SCRIPT_DIR}" ]]; then
    readonly LOG_DIR="${SCRIPT_DIR}/log"
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
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\t'/\\t}"
    str="${str//$'\r'/\\r}"
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
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

log_info()    { log_to_file "INFO" "$*"; printf "${CYAN}[INFO]${RESET}    %s\n"    "$*"; }
log_success() { log_to_file "SUCCESS" "$*"; printf "${GREEN}[SUCCESS]${RESET} %s\n"   "$*"; }
log_warn()    { log_to_file "WARN" "$*"; printf "${YELLOW}[WARN]${RESET}    %s\n"  "$*"; }
log_error()   { log_to_file "ERROR" "$*"; printf "${RED}[ERROR]${RESET}   %s\n"     "$*" >&2; }
log_debug()   { if [[ "${LOCALAI_VERBOSE:-0}" == "1" ]]; then log_to_file "DEBUG" "$*"; printf "${DIM}[DEBUG]   %s${RESET}\n" "$*"; fi; }
log_step()    { log_to_file "STEP" "$*"; printf "${BOLD}${CYAN} ──▶${RESET} %s\n"  "$*"; }
log_header()  {
    log_to_file "HEADER" "$*"
    printf "\n${BOLD}${CYAN}%s${RESET}\n" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "${BOLD}  %s${RESET}\n"         "$*"
    printf "${BOLD}${CYAN}%s${RESET}\n\n"  "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

die() {
    log_error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# PREREQUISITE CHECKS
# ------------------------------------------------------------------------------
require_cmd() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
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
    local list
    list="$(distrobox list --no-color 2>/dev/null)" || { log_debug "distrobox list returned non-zero exit code"; return 1; }
    echo "${list}" | awk -F'|' 'NR>1 {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        if ($2 ~ /^[a-zA-Z0-9_.-]+$/ && $2 != "NAME") print $2
    }' | grep -qx "$name" || return 1
}

assert_container_exists() {
    local name="$1"
    if ! check_container_exists "$name"; then
        die "Container '${name}' not found. Create it first: localai.sh container new ${name}"
    fi
}
