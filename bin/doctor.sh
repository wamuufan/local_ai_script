#!/usr/bin/env bash
# ==============================================================================
#  bin/doctor.sh — Prerequisites & System Doctor Command
# ==============================================================================

set -euo pipefail

_doctor_check_dep() {
    local cmd="$1"
    local label="${2:-$cmd}"
    local hint="${3:-}"
    local optional="${4:-false}"
    printf "  %-22s " "${label}:"
    if require_cmd "${cmd}"; then
        local ver; ver="$("${cmd}" --version 2>&1 | head -1)" || ver="(version unknown)"
        printf "${GREEN}✓ found${RESET}  ${DIM}%s${RESET}\n" "${ver}"
        return 0
    else
        if [[ "${optional}" == "true" ]]; then
            printf "${YELLOW}⚠ not found (optional)${RESET}"
        else
            printf "${RED}✗ not found${RESET}"
        fi
        [[ -n "${hint}" ]] && printf "  ${DIM}→ %s${RESET}" "${hint}"
        printf "\n"
        [[ "${optional}" == "true" ]] && return 0 || return 1
    fi
}

cmd_doctor() {
    log_header "LocalAI System Doctor v${SCRIPT_VERSION}"

    local all_ok=true

    printf "${BOLD}Core dependencies:${RESET}\n"
    _doctor_check_dep "podman"    "Podman"          "dnf install podman  /  apt install podman" || all_ok=false
    if require_cmd podman; then
        printf "  %-22s " "Podman rootless:"
        if podman info &>/dev/null; then
            printf "${GREEN}✓ functional${RESET}\n"
        else
            printf "${RED}✗ non-functional${RESET}  ${DIM}→ Check /etc/subuid & /etc/subgid rootless setup${RESET}\n"
            all_ok=false
        fi
    fi
    _doctor_check_dep "distrobox" "Distrobox"       "curl -s https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh" || all_ok=false
    _doctor_check_dep "git"       "Git"             "apt install git" || all_ok=false
    _doctor_check_dep "curl"      "curl"            "apt install curl" || all_ok=false
    _doctor_check_dep "zstd"      "zstd"            "apt install zstd" || all_ok=false

    printf "\n${BOLD}Optional / GPU:${RESET}\n"
    _doctor_check_dep "nvidia-smi" "nvidia-smi (GPU)"  "Install NVIDIA drivers + Container Toolkit" "true" || true
    _doctor_check_dep "nvcc"       "nvcc (CUDA)"        "Install CUDA toolkit" "true" || true

    printf "\n${BOLD}Base directory:${RESET}\n"
    printf "  %-22s " "~/.local/containers:"
    if [[ -d "${BASE_DIR}" ]]; then
        printf "${GREEN}✓ exists${RESET}  ${DIM}%s${RESET}\n" "${BASE_DIR}"
    else
        printf "${YELLOW}⚠ missing${RESET}  ${DIM}(created automatically on first use)${RESET}\n"
    fi

    printf "\n${BOLD}Disk Space:${RESET}\n"
    local check_dir="${BASE_DIR}"
    [[ ! -d "${check_dir}" ]] && check_dir="${HOME}"
    local free_space
    free_space="$(df -Ph "${check_dir}" 2>/dev/null | awk 'END {print $4}')" || free_space="unknown"
    printf "  %-22s ${CYAN}%s${RESET} free\n" "Available storage:" "${free_space}"

    printf "\n${BOLD}Distrobox containers:${RESET}\n"
    if require_cmd distrobox; then
        local count
        count="$(distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1 {gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 ~ /^[a-zA-Z0-9_.-]+$/ && $2 != "NAME") c++} END {print c+0}')"
        printf "  %-22s ${CYAN}%s${RESET}\n" "Total containers:" "${count}"
    else
        printf "  ${DIM}(distrobox not available)${RESET}\n"
    fi

    printf "\n"
    if [[ "${all_ok}" == "true" ]]; then
        log_success "All core dependencies satisfied. System is ready."
    else
        log_warn    "Some dependencies are missing. Install them and re-run: localai.sh doctor"
        exit 1
    fi
}
