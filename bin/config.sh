#!/usr/bin/env bash
# ==============================================================================
#  bin/config.sh — Configuration Parser Helper
# ==============================================================================

set -euo pipefail

# Extract tool section from localai.conf and print KEY=VALUE pairs as bash export statements
extract_tool_config() {
    local conf_file="$1"
    local section="$2"

    if [[ ! -f "${conf_file}" ]]; then
        return 0
    fi

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
            gsub(/\\/, "\\\\", val);
            gsub(/"/, "\\\"", val);
            print "export " key "=\"" val "\""
        }
    ' "${conf_file}"
}
