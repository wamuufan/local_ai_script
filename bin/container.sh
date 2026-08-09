#!/usr/bin/env bash
# ==============================================================================
#  bin/container.sh — Distrobox Container Management Commands
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# COMMAND: container new
# ------------------------------------------------------------------------------
cmd_container_new() {
    local name="" cpu_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu-only|--no-nvidia) cpu_only=true; shift ;;
            -*) die "Unknown option '$1' for container new" ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    die "Unexpected argument '$1'"
                fi
                shift
                ;;
        esac
    done
    [[ -z "${name}" ]] && die "Usage: localai.sh container new <name> [--cpu-only|--no-nvidia]"

    local home_dir="${BASE_DIR}/${name}"

    log_header "Creating container: ${name}"

    if check_container_exists "${name}"; then
        log_warn "Container '${name}' already exists. Skipping creation."
        return 0
    fi

    log_step "Creating isolated home directory: ${home_dir}"
    mkdir -p "${home_dir}"

    log_step "Checking base container image (${BASE_IMAGE})..."
    if require_cmd podman; then
        if ! podman image exists "${BASE_IMAGE}" 2>/dev/null; then
            log_info "Pulling container image ${BASE_IMAGE}..."
            if ! podman pull "${BASE_IMAGE}"; then
                die "Failed to pull base image '${BASE_IMAGE}'. Please check your internet connection or registry availability."
            fi
        fi
    fi

    log_step "Creating Distrobox container (Ubuntu 26.04)..."
    local nvidia_args=()
    if [[ "${cpu_only}" == "false" ]] && require_cmd nvidia-smi; then
        nvidia_args=("--nvidia")
    fi

    distrobox create \
        --name      "${name}" \
        --image     "${BASE_IMAGE}" \
        --home      "${home_dir}" \
        "${nvidia_args[@]}" \
        --pre-init-hooks "mkdir -p /etc/apt/apt.conf.d 2>/dev/null || true; printf 'Dir::Etc::sourcelist \"/etc/apt/sources.list.d/ubuntu.sources\";\nDir::Etc::sourceparts \"/dev/null\";\n' > /etc/apt/apt.conf.d/99-isolate-ubuntu.conf 2>/dev/null || true" \
        --yes

    log_step "Initialising container and installing base packages..."
    distrobox enter "${name}" -- bash -c "
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export TZ=Etc/UTC
        export HTTP_PROXY=\"\${HTTP_PROXY:-}\"
        export HTTPS_PROXY=\"\${HTTPS_PROXY:-}\"
        sudo apt-get update -q -o Acquire::Languages=none
        sudo apt-get upgrade -y -q
        sudo apt-get install -y -q \
            python3 python3-pip python3-venv \
            git curl wget ca-certificates \
            zstd lz4 pigz tar gzip unzip xz-utils \
            procps pciutils jq libzstd-dev \
            build-essential software-properties-common
    "

    log_success "Container '${name}' is ready."
    log_info    "Home directory : ${home_dir}"
    log_info    "Enter shell    : localai.sh shell ${name}"
    log_info    "Install a tool : localai.sh install ${name} <tool>"
}

# ------------------------------------------------------------------------------
# COMMAND: container list
# ------------------------------------------------------------------------------
cmd_container_list() {
    log_header "LocalAI Containers"

    if ! require_cmd distrobox; then
        die "distrobox not found. Run: localai.sh doctor"
    fi

    local raw
    raw="$(distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1 {
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        gsub(/^[ \t]+|[ \t]+$/, "", $4)
        if ($2 ~ /^[a-zA-Z0-9_.-]+$/ && $2 != "NAME") print $2 "|" $3 "|" $4
    }')" || true

    if [[ -z "$raw" ]]; then
        log_info "No containers found."
        return 0
    fi

    printf "${BOLD}%-24s %-12s %-10s %-10s %-s${RESET}\n" "NAME" "STATUS" "DATA DIR" "SIZE" "IMAGE"
    printf "${DIM}%s${RESET}\n" "─────────────────────────────────────────────────────────────────────────────────────────"

    local has_timeout=false
    require_cmd timeout && has_timeout=true

    local data_dir data_label data_size status_color
    while IFS='|' read -r name status image; do
        [[ -z "$name" ]] && continue

        data_dir="${BASE_DIR}/${name}"
        data_label="✗ missing"
        data_size="—"
        if [[ -d "$data_dir" ]]; then
            data_label="✓ exists"
            if [[ "${has_timeout}" == "true" ]]; then
                data_size="$(timeout 3 du -sh "$data_dir" 2>/dev/null | awk '{print $1}')" || data_size="unknown"
            else
                data_size="skipped"
            fi
        fi

        status_color="${GREEN}"
        [[ "$status" != Up* ]] && status_color="${DIM}"

        printf "${status_color}%-24s${RESET} %-12s %-10s %-10s %-s\n" \
            "$name" "$status" "$data_label" "$data_size" "$image"
    done <<< "$raw"

    printf "\n${DIM}Tip: data dirs are never deleted by 'container rm'${RESET}\n\n"
}

# ------------------------------------------------------------------------------
# COMMAND: container rm
# ------------------------------------------------------------------------------
cmd_container_rm() {
    local name=""
    local force_yes=0
    local purge_data=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) force_yes=1; shift ;;
            -p|--purge) purge_data=1; shift ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    log_error "Unexpected argument: '$1'"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        die "Usage: localai.sh container rm <name> [-y|--yes] [-p|--purge]"
    fi

    local home_dir="${BASE_DIR}/${name}"

    log_header "Removing container: ${name}"
    assert_container_exists "${name}"
    _acquire_container_lock "${name}"

    if [[ "${purge_data}" -eq 1 ]]; then
        log_warn "WARNING: --purge flag specified! This will PERMANENTLY DELETE:"
        log_warn "  ${home_dir}"
    else
        log_warn "This will REMOVE the container but KEEP all data in:"
        log_warn "  ${home_dir}"
    fi

    if [[ "${force_yes}" -ne 1 ]]; then
        printf "${YELLOW}Proceed? [y/N]: ${RESET}"
        read -r answer
        [[ "${answer,,}" =~ ^y ]] || { log_info "Aborted."; return 0; }
    fi

    log_step "Stopping any running services in '${name}'..."
    local tools; tools="$(get_supported_tools)"
    local t
    for t in ${tools}; do
        local pid_f; pid_f="$(pid_file "${name}" "${t}")"
        if [[ -f "${pid_f}" ]]; then
            stop_service_in_container "${name}" "${t}" 5 || true
        fi
    done

    log_step "Removing container '${name}'..."
    distrobox rm --force "${name}"

    if [[ "${purge_data}" -eq 1 ]]; then
        log_step "Purging data directory ${home_dir}..."
        rm -rf "${home_dir}"
        log_success "Container '${name}' and data directory purged."
    else
        log_success "Container '${name}' removed."
        log_info    "Data preserved at : ${home_dir}"
        log_info    "To restore        : localai.sh container new ${name}"
    fi
}
