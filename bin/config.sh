#!/usr/bin/env bash
# ==============================================================================
#  bin/config.sh — Configuration Parser & Resolver Helper
# ==============================================================================

set -euo pipefail

# Resolves active configuration file path in order of priority:
#   1. LOCALAI_CONFIG environment variable
#   2. ${XDG_CONFIG_HOME:-$HOME/.config}/localai/localai.conf
#   3. ${LOCALAI_ROOT}/localai.conf
resolve_config_file() {
    local container="${1:-}"
    local localai_root="${LOCALAI_ROOT:-${SCRIPT_DIR:-.}}"

    # 1. LOCALAI_CONFIG environment variable
    if [[ -n "${LOCALAI_CONFIG:-}" && -f "${LOCALAI_CONFIG}" ]]; then
        echo "${LOCALAI_CONFIG}"
        return 0
    fi

    # 2. ${XDG_CONFIG_HOME:-$HOME/.config}/localai/localai.conf
    local xdg_conf="${XDG_CONFIG_HOME:-${HOME}/.config}/localai/localai.conf"
    if [[ -f "${xdg_conf}" ]]; then
        echo "${xdg_conf}"
        return 0
    fi

    # 3. ${LOCALAI_ROOT}/localai.conf
    local root_conf="${localai_root}/localai.conf"
    if [[ -f "${root_conf}" ]]; then
        echo "${root_conf}"
        return 0
    fi

    return 1
}

# Reads a single key value from a given section in a conf file
get_config_value() {
    local conf_file="$1"
    local section="$2"
    local key="$3"

    [[ ! -f "${conf_file}" ]] && return 1

    awk -v section="${section}" -v target_key="${key}" '
        BEGIN { sec = "^[ \t]*\\[" section "\\][ \t]*$" }
        $0 ~ sec { flag=1; next }
        /^[ \t]*\[/ && flag { flag=0; next }
        flag && /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/ {
            sub(/\r$/, "");
            sub(/^[ \t]+/, "");
            idx = index($0, "=");
            k = substr($0, 1, idx-1);
            val = substr($0, idx+1);
            sub(/^[ \t]+/, "", val);

            if (k == target_key) {
                if (val ~ /^"/) {
                    if (match(val, /^"([^"\\]|\\.)*"/)) {
                        val = substr(val, 2, RLENGTH-2);
                    } else if (match(val, /^"[^"]*"/)) {
                        val = substr(val, 2, RLENGTH-2);
                    }
                } else {
                    sub(/[ \t]*#.*$/, "", val);
                    sub(/[ \t]+$/, "", val);
                }
                print val;
                exit;
            }
        }
    ' "${conf_file}"
}

# Returns human-readable description for a memory usage strategy
get_memory_strategy_description() {
    local strategy="$1"
    case "${strategy}" in
        aggressive_release|aggressive_cleanup|aggressive)
            echo "Aggressive Memory Release (Immediate VRAM/RAM Offloading, Anti-Fragmentation, Single Context)"
            ;;
        balanced_caching|balanced)
            echo "Balanced Caching Strategy (5m Idle Model Retention, Moderate VRAM Caching)"
            ;;
        high_performance_pinned|performance_pinned|performance)
            echo "High-Performance Strategy (Models Pinned in VRAM/RAM, Multi-Context Concurrency)"
            ;;
        *)
            echo "Custom Strategy (${strategy})"
            ;;
    esac
}

# Emits baseline environment variables according to the selected memory strategy
_emit_memory_strategy_defaults() {
    local strategy="$1"
    local section="$2"

    case "${strategy}" in
        aggressive_release|aggressive_cleanup|aggressive)
            case "${section}" in
                ollama)
                    echo "export OLLAMA_KEEP_ALIVE=\"0\""
                    echo "export OLLAMA_NUM_PARALLEL=\"1\""
                    echo "export OLLAMA_FLASH_ATTENTION=\"1\""
                    echo "export OLLAMA_MAX_LOADED_MODELS=\"1\""
                    echo "export OLLAMA_KV_CACHE_TYPE=\"q8_0\""
                    echo "export OLLAMA_GPU_OVERHEAD=\"536870912\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
                comfyui)
                    echo "export COMFYUI_EXTRA_ARGS=\"--disable-smart-memory --reserve-vram 0.6 --preview-method auto --enable-triton-backend\""
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True,garbage_collection_threshold:0.8,max_split_size_mb:128\""
                    echo "export FLORENCE2_UNLOAD_IMMEDIATE=\"1\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
                openwebui)
                    echo "export DEVICE_TYPE=\"cpu\""
                    echo "export USE_CUDA_DOCKER=\"false\""
                    ;;
                iopaint)
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True,garbage_collection_threshold:0.8,max_split_size_mb:128\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    echo "export IOPAINT_EXTRA_ARGS=\"--low-mem\""
                    ;;
                whisper)
                    echo "export WHISPER_TTL=\"0\""
                    echo "export WHISPER_COMPUTE_TYPE=\"int8\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
            esac
            ;;
        balanced_caching|balanced)
            case "${section}" in
                ollama)
                    echo "export OLLAMA_KEEP_ALIVE=\"5m\""
                    echo "export OLLAMA_FLASH_ATTENTION=\"1\""
                    echo "export OLLAMA_MAX_LOADED_MODELS=\"1\""
                    echo "export OLLAMA_KV_CACHE_TYPE=\"q8_0\""
                    echo "export OLLAMA_GPU_OVERHEAD=\"536870912\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
                comfyui)
                    echo "export COMFYUI_EXTRA_ARGS=\"--reserve-vram 0.6 --preview-method auto --enable-triton-backend\""
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
                openwebui)
                    echo "export DEVICE_TYPE=\"cpu\""
                    echo "export USE_CUDA_DOCKER=\"false\""
                    ;;
                iopaint)
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
                whisper)
                    echo "export WHISPER_TTL=\"300\""
                    echo "export WHISPER_COMPUTE_TYPE=\"int8\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4\""
                    ;;
            esac
            ;;
        high_performance_pinned|performance_pinned|performance)
            case "${section}" in
                ollama)
                    echo "export OLLAMA_KEEP_ALIVE=\"-1\""
                    echo "export OLLAMA_NUM_PARALLEL=\"4\""
                    echo "export OLLAMA_FLASH_ATTENTION=\"1\""
                    ;;
                comfyui)
                    echo "export COMFYUI_EXTRA_ARGS=\"--highvram --preview-method auto\""
                    ;;
                iopaint)
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
                    ;;
                whisper)
                    echo "export WHISPER_TTL=\"-1\""
                    ;;
            esac
            ;;
    esac
}

# Extract tool section from active conf and print KEY=VALUE pairs as bash export statements
extract_tool_config() {
    local conf_file="${1:-}"
    local section="${2:-}"

    # If conf_file is not explicitly passed or empty, resolve it
    if [[ -z "${conf_file}" || ! -f "${conf_file}" ]]; then
        local resolved
        if resolved="$(resolve_config_file)"; then
            conf_file="${resolved}"
        else
            _emit_memory_strategy_defaults "aggressive_release" "${section}"
            return 0
        fi
    fi

    # Check for memory management strategy (supports MEMORY_STRATEGY, MEMORY_MANAGEMENT_STRATEGY, MEMORY_PROFILE)
    local mem_strategy
    mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_STRATEGY" 2>/dev/null || true)"
    [[ -z "${mem_strategy}" ]] && mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_MANAGEMENT_STRATEGY" 2>/dev/null || true)"
    [[ -z "${mem_strategy}" ]] && mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_PROFILE" 2>/dev/null || true)"

    {
        if [[ -n "${mem_strategy}" ]]; then
            _emit_memory_strategy_defaults "${mem_strategy}" "${section}"
        fi

        # Parse INI section; user entries will override any preceding strategy exports
        awk -v section="${section}" '
            BEGIN { sec = "^[ \t]*\\[" section "\\][ \t]*$" }
            $0 ~ sec { flag=1; next }
            /^[ \t]*\[/ && flag { flag=0; next }
            flag && /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/ {
                sub(/\r$/, "");
                sub(/^[ \t]+/, "");
                idx = index($0, "=");
                key = substr($0, 1, idx-1);
                val = substr($0, idx+1);
                sub(/^[ \t]+/, "", val);

                if (val ~ /^"/) {
                    if (match(val, /^"([^"\\]|\\.)*"/)) {
                        val = substr(val, 2, RLENGTH-2);
                    } else if (match(val, /^"[^"]*"/)) {
                        val = substr(val, 2, RLENGTH-2);
                    }
                } else {
                    sub(/[ \t]*#.*$/, "", val);
                    sub(/[ \t]+$/, "", val);
                }
                gsub(/\\/, "\\\\", val);
                gsub(/"/, "\\\"", val);
                print "export " key "=\"" val "\""
            }
        ' "${conf_file}"
    } | awk -F'=' '
        /^export [A-Za-z_][A-Za-z0-9_]*=/ {
            k = $1
            if (!(k in seen)) {
                order[++n] = k
                seen[k] = 1
            }
            val[k] = $0
        }
        END {
            for (i = 1; i <= n; i++) {
                print val[order[i]]
            }
        }
    '
}

# Updates memory strategy and synchronized tool parameters in active localai.conf
cmd_config_profile() {
    local profile_name="${1:-}"
    if [[ -z "${profile_name}" ]]; then
        die "Usage: localai.sh config profile <aggressive|balanced|performance>"
    fi

    local canonical_strategy=""
    local ollama_keep_alive=""
    local ollama_num_parallel=""
    local whisper_ttl=""
    local comfyui_extra_args=""

    case "${profile_name}" in
        aggressive|aggressive_release|aggressive_cleanup)
            canonical_strategy="aggressive_release"
            ollama_keep_alive="0"
            ollama_num_parallel="1"
            whisper_ttl="0"
            comfyui_extra_args="--disable-smart-memory --reserve-vram 0.6 --preview-method auto --enable-triton-backend"
            ;;
        balanced|balanced_caching)
            canonical_strategy="balanced_caching"
            ollama_keep_alive="5m"
            ollama_num_parallel="1"
            whisper_ttl="300"
            comfyui_extra_args="--reserve-vram 0.6 --preview-method auto --enable-triton-backend"
            ;;
        performance|high_performance_pinned|performance_pinned)
            canonical_strategy="high_performance_pinned"
            ollama_keep_alive="-1"
            ollama_num_parallel="4"
            whisper_ttl="-1"
            comfyui_extra_args="--highvram --preview-method auto"
            ;;
        *)
            die "Unknown memory profile: '${profile_name}'. Choose from: aggressive, balanced, performance"
            ;;
    esac

    local localai_root="${LOCALAI_ROOT:-${SCRIPT_DIR:-.}}"
    local conf_file=""
    if ! conf_file="$(resolve_config_file)"; then
        conf_file="${localai_root}/localai.conf"
    fi

    if [[ ! -f "${conf_file}" ]]; then
        die "Configuration file not found: ${conf_file}"
    fi

    local tmp_file
    tmp_file="$(mktemp "${conf_file}.tmp.XXXXXX")"

    if awk \
        -v strategy="${canonical_strategy}" \
        -v keep_alive="${ollama_keep_alive}" \
        -v num_parallel="${ollama_num_parallel}" \
        -v whisper_ttl="${whisper_ttl}" \
        -v comfy_args="${comfyui_extra_args}" '
        /^[ \t]*MEMORY_STRATEGY=/     { print "MEMORY_STRATEGY=" strategy; next }
        /^[ \t]*OLLAMA_KEEP_ALIVE=/   { print "OLLAMA_KEEP_ALIVE=" keep_alive; next }
        /^[ \t]*OLLAMA_NUM_PARALLEL=/ { print "OLLAMA_NUM_PARALLEL=" num_parallel; next }
        /^[ \t]*WHISPER_TTL=/         { print "WHISPER_TTL=" whisper_ttl; next }
        /^[ \t]*COMFYUI_EXTRA_ARGS=/  { print "COMFYUI_EXTRA_ARGS=\"" comfy_args "\""; next }
        { print }
    ' "${conf_file}" > "${tmp_file}"; then
        chmod --reference="${conf_file}" "${tmp_file}" 2>/dev/null || chmod 644 "${tmp_file}" 2>/dev/null || true
        mv "${tmp_file}" "${conf_file}"
    else
        rm -f "${tmp_file}" 2>/dev/null || true
        die "Failed to update configuration file: ${conf_file}"
    fi

    log_success "Memory profile updated to '${canonical_strategy}' in ${conf_file}."
    log_info    "Description: $(get_memory_strategy_description "${canonical_strategy}")"
}

# CLI handler: localai.sh config [show|profile <name>]
cmd_config() {
    local sub="${1:-show}"
    shift || true

    case "${sub}" in
        show)
            log_header "LocalAI Configuration & Memory Profile"
            local conf_file=""
            if conf_file="$(resolve_config_file)"; then
                local strategy
                strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_STRATEGY" 2>/dev/null || true)"
                [[ -z "${strategy}" ]] && strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_MANAGEMENT_STRATEGY" 2>/dev/null || true)"
                [[ -z "${strategy}" ]] && strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_PROFILE" 2>/dev/null || true)"

                local auto_clean
                auto_clean="$(get_config_value "${conf_file}" "memory" "AUTO_CLEAN_ON_STOP" 2>/dev/null || echo "false")"
                local auto_drop
                auto_drop="$(get_config_value "${conf_file}" "memory" "AUTO_DROP_CACHES" 2>/dev/null || echo "false")"

                echo -e "  ${BOLD}Active Config   :${RESET} ${conf_file}"
                if [[ -n "${strategy}" ]]; then
                    local desc; desc="$(get_memory_strategy_description "${strategy}")"
                    echo -e "  ${BOLD}Memory Strategy :${RESET} ${CYAN}${strategy}${RESET}"
                    echo -e "  ${BOLD}Description     :${RESET} ${DIM}${desc}${RESET}"
                else
                    echo -e "  ${BOLD}Memory Strategy :${RESET} ${CYAN}Direct / Custom Overrides${RESET}"
                fi
                echo -e "  ${BOLD}Auto Clean Stop :${RESET} ${auto_clean:-false}"
                echo -e "  ${BOLD}Auto Drop Cache :${RESET} ${auto_drop:-false}"
            else
                local desc; desc="$(get_memory_strategy_description "aggressive_release")"
                echo -e "  ${BOLD}Active Config   :${RESET} ${YELLOW}Built-in Fallback (aggressive_release)${RESET}"
                echo -e "  ${BOLD}Memory Strategy :${RESET} ${CYAN}aggressive_release${RESET}"
                echo -e "  ${BOLD}Description     :${RESET} ${DIM}${desc}${RESET}"
            fi
            echo ""
            echo -e "  ${DIM}Switch profile: localai.sh config profile <aggressive|balanced|performance>${RESET}"
            echo ""
            ;;
        profile)
            cmd_config_profile "$@"
            ;;
        *)
            log_error "Unknown config sub-command: '${sub}'"
            log_info  "Usage: localai.sh config [show|profile <aggressive|balanced|performance>]"
            exit 1
            ;;
    esac
}
