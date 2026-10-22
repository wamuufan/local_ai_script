#!/usr/bin/env bash
# ==============================================================================
#  bin/config.sh — Configuration Parser & Resolver Helper
# ==============================================================================

set -euo pipefail

# Resolves active configuration file path in order of priority.
# NOTE: Files ending with '.disabled' are strictly ignored.
resolve_config_file() {
    local container="${1:-}"

    # 1. Environment / explicit override
    if [[ -n "${LOCALAI_CONFIG:-}" && -f "${LOCALAI_CONFIG}" ]]; then
        if [[ "${LOCALAI_CONFIG}" != *.disabled ]]; then
            echo "${LOCALAI_CONFIG}"
            return 0
        fi
    fi

    # 2. Container-specific config
    if [[ -n "${container}" ]]; then
        local c_conf="${BASE_DIR}/${container}/localai.conf"
        if [[ -f "${c_conf}" && "${c_conf}" != *.disabled ]]; then
            echo "${c_conf}"
            return 0
        fi
    fi

    # 3. Dynamic config (active)
    local dynamic_conf="${SCRIPT_DIR}/localai.dynamic.conf"
    if [[ -f "${dynamic_conf}" && "${dynamic_conf}" != *.disabled ]]; then
        echo "${dynamic_conf}"
        return 0
    fi

    # 4. Static config (active)
    local static_conf="${SCRIPT_DIR}/localai.static.conf"
    if [[ -f "${static_conf}" && "${static_conf}" != *.disabled ]]; then
        echo "${static_conf}"
        return 0
    fi

    # 5. Default localai.conf
    local def_conf="${SCRIPT_DIR}/localai.conf"
    if [[ -f "${def_conf}" && "${def_conf}" != *.disabled ]]; then
        echo "${def_conf}"
        return 0
    fi

    # 6. User home config
    local home_conf="${HOME}/.config/localai/localai.conf"
    if [[ -f "${home_conf}" && "${home_conf}" != *.disabled ]]; then
        echo "${home_conf}"
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
    [[ "${conf_file}" == *.disabled ]] && return 1

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
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    ;;
                comfyui)
                    echo "export COMFYUI_EXTRA_ARGS=\"--disable-smart-memory --preview-method auto --enable-triton-backend\""
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True,garbage_collection_threshold:0.8,max_split_size_mb:128\""
                    echo "export FLORENCE2_UNLOAD_IMMEDIATE=\"1\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    ;;
                iopaint)
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True,garbage_collection_threshold:0.8,max_split_size_mb:128\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    echo "export IOPAINT_EXTRA_ARGS=\"--low-mem\""
                    ;;
                whisper)
                    echo "export WHISPER_TTL=\"0\""
                    echo "export WHISPER_COMPUTE_TYPE=\"int8\""
                    ;;
            esac
            ;;
        balanced_caching|balanced)
            case "${section}" in
                ollama)
                    echo "export OLLAMA_KEEP_ALIVE=\"5m\""
                    echo "export OLLAMA_FLASH_ATTENTION=\"1\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    ;;
                comfyui)
                    echo "export COMFYUI_EXTRA_ARGS=\"--preview-method auto --enable-triton-backend\""
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    ;;
                iopaint)
                    echo "export PYTORCH_CUDA_ALLOC_CONF=\"expandable_segments:True\""
                    echo "export LD_PRELOAD=\"/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4\""
                    ;;
                whisper)
                    echo "export WHISPER_TTL=\"300\""
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
            return 0
        fi
    fi

    # Strictly ignore disabled files
    if [[ "${conf_file}" == *.disabled || ! -f "${conf_file}" ]]; then
        return 0
    fi

    # Check for memory management strategy (supports MEMORY_STRATEGY, MEMORY_MANAGEMENT_STRATEGY, MEMORY_PROFILE)
    local mem_strategy
    mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_STRATEGY" 2>/dev/null || true)"
    [[ -z "${mem_strategy}" ]] && mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_MANAGEMENT_STRATEGY" 2>/dev/null || true)"
    [[ -z "${mem_strategy}" ]] && mem_strategy="$(get_config_value "${conf_file}" "memory" "MEMORY_PROFILE" 2>/dev/null || true)"

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
}
