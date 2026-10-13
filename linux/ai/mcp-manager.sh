#!/usr/bin/env bash
# mcp-manager.sh - install, repair, and inspect MCP servers across Linux AI clients.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq

MCP_SOURCES="$PZ_ROOT/assets/mcp/servers"
WORKSPACE_ROOT="${PZ_WORKSPACE_ROOT:-$PZ_ROOT}"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
OPENCODE_CONFIG="$XDG_CONFIG/opencode/opencode.json"
CLAUDE_CONFIG="$XDG_CONFIG/claude/claude.json"
CLAUDE_DESKTOP_CONFIG="$XDG_CONFIG/Claude/claude_desktop_config.json"
CODEX_CONFIG="${HOME}/.codex/config.toml"
CODEX_PROJECT_CONFIG="${WORKSPACE_ROOT}/.codex/config.toml"
VSCODE_WORKSPACE_MCP_CONFIG="${WORKSPACE_ROOT}/.vscode/mcp.json"
VSCODE_USER_MCP_CONFIG="$XDG_CONFIG/Code/User/mcp.json"
CURSOR_MCP_CONFIG="$XDG_CONFIG/Cursor/User/mcp.json"
ZED_CONFIG="$XDG_CONFIG/zed/settings.json"
ZCODE_STORE="$XDG_CONFIG/ai.z.zcode/store.json"
OPENCLAW_CONFIG="${HOME}/.openclaw/config.json"
HERMES_CONFIG="${HOME}/.hermes/config.yaml"
AI_MEMORY_MCP_URL="${AI_MEMORY_SERVER_URL:-http://127.0.0.1:49374}/mcp"
MCP_BACKUP_DIR="$PZ_STATE/backups/ai-mcp"

backup_config() {
    local cfg="$1" label backup
    [ -f "$cfg" ] || return 0
    mkdir -p "$MCP_BACKUP_DIR"
    label="$(printf '%s' "$cfg" | sed 's#[^A-Za-z0-9._-]#_#g')"
    backup="$MCP_BACKUP_DIR/${label}.bak.$(date +%s%N)"
    cp "$cfg" "$backup"
    pz_rollback_register file "$cfg" "$backup"
    local -a backups=()
    mapfile -d '' backups < <(
        find "$MCP_BACKUP_DIR" -maxdepth 1 -type f -name "${label}.bak.*" \
            -printf '%T@ %p\0' | sort -zrn
    )
    local index path
    for ((index = 5; index < ${#backups[@]}; index++)); do
        path="${backups[$index]#* }"
        rm -f -- "$path"
    done
}

available_definitions() {
    find "$MCP_SOURCES" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort
}

definition_names() {
    {
        echo "ai-memory"
        available_definitions | while IFS= read -r file; do
            basename "$file" .json
        done
    } | sort -u
}

definition_json() {
    local name="$1" source_file
    if [ "$name" = "ai-memory" ]; then
        jq -cn --arg url "$AI_MEMORY_MCP_URL" '{
          type: "http",
          url: $url,
          enabled: true,
          auto: true,
          phasezeroSafe: true,
          description: "PhaseZero local ai-memory loopback MCP"
        }'
        return 0
    fi

    source_file="$MCP_SOURCES/${name}.json"
    [ -f "$source_file" ] || return 1
    jq '.' "$source_file"
}

validate_definition_json() {
    jq -e '
      has("type") and
      (
        ((.type == "http" or .type == "streamable-http" or .type == "remote") and ((.url // "") | type == "string") and ((.url // "") | length > 0))
        or
        ((.type == "stdio" or has("command")) and (((.command // .url // "") | type == "string") and (((.command // .url // "") | length) > 0)))
      )
    ' >/dev/null
}

definition_has_placeholder() {
    jq -e '.. | strings | select(test("<[^>]+>"))' >/dev/null 2>&1
}

definition_safe() {
    local name="$1" json="$2"
    [ "$name" = "ai-memory" ] && return 0
    jq -e '(.enabled // true) == true and ((.phasezeroSafe // false) == true or (.auto // false) == true)' <<< "$json" >/dev/null || return 1
    ! definition_has_placeholder <<< "$json"
}

json_target_path() {
    case "$1" in
        opencode) echo "$OPENCODE_CONFIG" ;;
        claude) echo "$CLAUDE_CONFIG" ;;
        claude-desktop) echo "$CLAUDE_DESKTOP_CONFIG" ;;
        vscode) echo "$VSCODE_WORKSPACE_MCP_CONFIG" ;;
        vscode-user) echo "$VSCODE_USER_MCP_CONFIG" ;;
        cursor) echo "$CURSOR_MCP_CONFIG" ;;
        zed) echo "$ZED_CONFIG" ;;
        *) return 1 ;;
    esac
}

target_field() {
    case "$1" in
        opencode) echo "mcp" ;;
        vscode|vscode-user) echo "servers" ;;
        zed) echo "context_servers" ;;
        *) echo "mcpServers" ;;
    esac
}

standard_server_json() {
    jq 'if (.type == "stdio" or has("command")) then
          {
            command: (.command // .url),
            args: (.args // [])
          }
          + (if has("env") then {env: .env} else {} end)
        else
          {
            command: "npx",
            args: (
              ["-y", "mcp-remote@latest", .url]
              + (((.headers // {}) | to_entries | map(["--header", (.key + ": " + (.value | tostring))]) | add) // [])
            )
          }
        end
        + (if has("enabled") then {enabled: .enabled} else {} end)'
}

opencode_server_json() {
    jq 'if (.type == "stdio" or has("command")) then
          {
            type: "local",
            command: ([.command // .url] + (.args // [])),
            enabled: (.enabled // true)
          }
          + (if has("env") then {environment: .env} else {} end)
        else
          {
            type: "remote",
            url: .url,
            enabled: (.enabled // true)
          }
          + (if has("headers") then {headers: .headers} else {} end)
          + (if has("oauth") then {oauth: .oauth} else {} end)
        end'
}

vscode_server_json() {
    jq 'if (.type == "stdio" or has("command")) then
          {
            type: "stdio",
            command: (.command // .url),
            args: (.args // [])
          }
          + (if has("env") then {env: .env} else {} end)
        else
          {
            type: "http",
            url: .url
          }
          + (if has("headers") then {headers: .headers} else {} end)
        end'
}

zed_server_json() {
    jq 'if (.type == "stdio" or has("command")) then
          {
            command: (.command // .url),
            args: (.args // [])
          }
          + (if has("env") then {env: .env} else {} end)
        else
          {
            url: .url
          }
          + (if has("headers") then {headers: .headers} else {} end)
        end'
}

openclaw_server_json() {
    jq 'if (.type == "stdio" or has("command")) then
          {
            transport: "stdio",
            command: (.command // .url),
            args: (.args // [])
          }
          + (if has("env") then {env: .env} else {} end)
        else
          {
            transport: "streamable-http",
            url: .url
          }
          + (if has("headers") then {headers: .headers} else {} end)
        end'
}

server_json_for_target() {
    local target="$1" json="$2"
    case "$target" in
        opencode) opencode_server_json <<< "$json" ;;
        vscode|vscode-user|zcode) vscode_server_json <<< "$json" ;;
        zed) zed_server_json <<< "$json" ;;
        openclaw) openclaw_server_json <<< "$json" ;;
        *) standard_server_json <<< "$json" ;;
    esac
}

ensure_json_config() {
    local target="$1" cfg field tmp
    cfg="$(json_target_path "$target")"
    field="$(target_field "$target")"
    mkdir -p "$(dirname "$cfg")"
    if [ ! -f "$cfg" ]; then
        jq -n --arg field "$field" '{($field): {}}' > "$cfg"
        return 0
    fi
    if ! jq empty "$cfg" >/dev/null 2>&1; then
        pz_warn "$cfg is not strict JSON; skipped $target"
        return 1
    fi
    backup_config "$cfg"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    if [ "$target" = "opencode" ]; then
        jq '.mcp = (if (.mcp | type) == "object" then .mcp else {} end) | del(.mcpServers)' "$cfg" > "$tmp"
    else
        jq --arg field "$field" '.[$field] = (if (.[$field] | type) == "object" then .[$field] else {} end)' "$cfg" > "$tmp"
    fi
    mv "$tmp" "$cfg"
}

install_json_target() {
    local target="$1" name="$2" json="$3" cfg field server tmp
    cfg="$(json_target_path "$target")"
    field="$(target_field "$target")"
    ensure_json_config "$target" || return 0
    server="$(server_json_for_target "$target" "$json")"
    backup_config "$cfg"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq --arg field "$field" --arg name "$name" --argjson server "$server" '.[$field][$name] = $server' "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
    pz_info "MCP $name installed in $target config: $cfg"
}

remove_json_target() {
    local target="$1" name="$2" cfg field tmp
    cfg="$(json_target_path "$target")"
    field="$(target_field "$target")"
    [ -f "$cfg" ] || return 0
    if ! jq empty "$cfg" >/dev/null 2>&1; then
        pz_warn "$cfg is not strict JSON; skipped $target"
        return 0
    fi
    backup_config "$cfg"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    if [ "$target" = "opencode" ]; then
        jq --arg name "$name" 'del(.mcp[$name]) | del(.mcpServers)' "$cfg" > "$tmp"
    else
        jq --arg field "$field" --arg name "$name" 'del(.[$field][$name])' "$cfg" > "$tmp"
    fi
    mv "$tmp" "$cfg"
    pz_info "MCP $name removed from $target config: $cfg"
}

toml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

toml_array() {
    jq -r '[.[] | @json] | "[" + join(", ") + "]"'
}

strip_codex_block() {
    local name="$1" cfg="$2" tmp
    [ -f "$cfg" ] || return 0
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    awk -v name="$name" -v begin="# BEGIN PHASEZERO MCP ${name}" -v end="# END PHASEZERO MCP ${name}" '
        $0 == begin {managed=1; next}
        $0 == end {managed=0; next}
        managed == 1 {next}
        {
            table = "[mcp_servers." name "]"
            prefix = "[mcp_servers." name "."
            if ($0 == table || index($0, prefix) == 1) {
                loose=1
                next
            }
            if (loose == 1 && $0 ~ /^\[/ && $0 != table && index($0, prefix) != 1) {
                loose=0
            }
            if (loose != 1) {
                print
            }
        }
    ' "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
}

install_codex_target() {
    local name="$1" json="$2" cfg="${3:-$CODEX_CONFIG}" type url command args tmp
    mkdir -p "$(dirname "$cfg")"
    [ -f "$cfg" ] || : > "$cfg"
    backup_config "$cfg"
    strip_codex_block "$name" "$cfg"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    {
        cat "$cfg"
        echo
        echo "# BEGIN PHASEZERO MCP ${name}"
        echo "[mcp_servers.${name}]"
        type="$(jq -r '.type // ""' <<< "$json")"
        url="$(jq -r '.url // ""' <<< "$json")"
        command="$(jq -r '.command // empty' <<< "$json")"
        if [ "$type" = "stdio" ] || [ -n "$command" ]; then
            [ -z "$command" ] && command="$url"
            echo "command = \"$(toml_escape "$command")\""
            args="$(jq -c '.args // []' <<< "$json")"
            echo "args = $(toml_array <<< "$args")"
            if jq -e '.env // empty' <<< "$json" >/dev/null; then
                jq -r '.env | to_entries[] | "env." + .key + " = " + (.value | @json)' <<< "$json"
            fi
        else
            echo "url = \"$(toml_escape "$url")\""
            [ "$name" = "ai-memory" ] && echo 'default_tools_approval_mode = "approve"'
            if jq -e '.headers // empty' <<< "$json" >/dev/null; then
                echo
                echo "[mcp_servers.${name}.http_headers]"
                jq -r '.headers | to_entries[] | .key + " = " + (.value | @json)' <<< "$json"
            fi
        fi
        echo "# END PHASEZERO MCP ${name}"
    } > "$tmp"
    mv "$tmp" "$cfg"
    pz_info "MCP $name installed in codex config: $cfg"
}

remove_codex_target() {
    local name="$1" cfg="${2:-$CODEX_CONFIG}"
    [ -f "$cfg" ] || return 0
    backup_config "$cfg"
    strip_codex_block "$name" "$cfg"
    pz_info "MCP $name removed from codex config: $cfg"
}

yaml_scalar() {
    jq -Rr '@json' <<< "$1"
}

hermes_server_yaml() {
    local name="$1" json="$2" type url command args
    echo "  # BEGIN PHASEZERO MCP ${name}"
    echo "  ${name}:"
    type="$(jq -r '.type // ""' <<< "$json")"
    command="$(jq -r '.command // empty' <<< "$json")"
    url="$(jq -r '.url // empty' <<< "$json")"
    if [ "$type" = "stdio" ] || [ -n "$command" ]; then
        [ -z "$command" ] && command="$url"
        echo "    command: $(yaml_scalar "$command")"
        args="$(jq -c '.args // []' <<< "$json")"
        if jq -e 'length > 0' <<< "$args" >/dev/null; then
            echo "    args:"
            jq -r '.[] | "      - " + (. | @json)' <<< "$args"
        else
            echo "    args: []"
        fi
        if jq -e '.env // empty' <<< "$json" >/dev/null; then
            echo "    env:"
            jq -r '.env | to_entries[] | "      " + .key + ": " + (.value | @json)' <<< "$json"
        fi
    else
        echo "    url: $(yaml_scalar "$url")"
        if jq -e '.headers // empty' <<< "$json" >/dev/null; then
            echo "    headers:"
            jq -r '.headers | to_entries[] | "      " + .key + ": " + (.value | @json)' <<< "$json"
        fi
    fi
    echo "    enabled: true"
    echo "    connect_timeout: 30"
    echo "    timeout: 120"
    echo "  # END PHASEZERO MCP ${name}"
}

strip_hermes_block() {
    local name="$1" cfg="$2" tmp
    [ -f "$cfg" ] || return 0
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    awk -v begin="  # BEGIN PHASEZERO MCP ${name}" -v end="  # END PHASEZERO MCP ${name}" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        skip != 1 {print}
    ' "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
}

strip_hermes_entry() {
    local name="$1" cfg="$2" tmp
    [ -f "$cfg" ] || return 0
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    awk -v key="  ${name}:" '
        /^mcp_servers:[[:space:]]*$/ {inmcp=1; print; next}
        inmcp == 1 && skip == 1 && $0 !~ /^ / && $0 !~ /^$/ {skip=0; inmcp=0}
        inmcp == 1 && $0 == key {skip=1; next}
        inmcp == 1 && skip == 1 && $0 ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {skip=0}
        inmcp == 1 && $0 !~ /^ / && $0 !~ /^$/ {inmcp=0}
        skip != 1 {print}
    ' "$cfg" > "$tmp"
    mv "$tmp" "$cfg"
}

ensure_hermes_config() {
    mkdir -p "$(dirname "$HERMES_CONFIG")"
    [ -f "$HERMES_CONFIG" ] || : > "$HERMES_CONFIG"
    if ! grep -Eq '^mcp_servers:[[:space:]]*$' "$HERMES_CONFIG"; then
        # shellcheck disable=SC2094 # intentional: read and append to same file
        {
            [ -s "$HERMES_CONFIG" ] && echo
            echo "mcp_servers:"
        } >> "$HERMES_CONFIG"
    fi
}

install_hermes_target() {
    local name="$1" json="$2" block tmp inserted
    ensure_hermes_config
    backup_config "$HERMES_CONFIG"
    strip_hermes_block "$name" "$HERMES_CONFIG"
    strip_hermes_entry "$name" "$HERMES_CONFIG"
    block="$(hermes_server_yaml "$name" "$json")"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    inserted=0
    awk -v block="$block" '
        {
            print
            if (inserted == 0 && $0 ~ /^mcp_servers:[[:space:]]*$/) {
                print block
                inserted=1
            }
        }
        END {
            if (inserted == 0) {
                print "mcp_servers:"
                print block
            }
        }
    ' "$HERMES_CONFIG" > "$tmp"
    mv "$tmp" "$HERMES_CONFIG"
    pz_info "MCP $name installed in hermes config: $HERMES_CONFIG"
}

remove_hermes_target() {
    local name="$1"
    [ -f "$HERMES_CONFIG" ] || return 0
    backup_config "$HERMES_CONFIG"
    strip_hermes_block "$name" "$HERMES_CONFIG"
    strip_hermes_entry "$name" "$HERMES_CONFIG"
    pz_info "MCP $name removed from hermes config: $HERMES_CONFIG"
}

ensure_openclaw_config() {
    mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
    if [ ! -f "$OPENCLAW_CONFIG" ]; then
        jq -n '{mcp:{servers:{}}}' > "$OPENCLAW_CONFIG"
        return 0
    fi
    if ! jq empty "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
        pz_warn "$OPENCLAW_CONFIG is not strict JSON; skipped openclaw"
        return 1
    fi
    backup_config "$OPENCLAW_CONFIG"
    local tmp
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq '.mcp = (.mcp // {}) | .mcp.servers = (if (.mcp.servers | type) == "object" then .mcp.servers else {} end) | del(.mcpServers)' "$OPENCLAW_CONFIG" > "$tmp"
    mv "$tmp" "$OPENCLAW_CONFIG"
}

install_openclaw_target() {
    local name="$1" json="$2" server tmp
    ensure_openclaw_config || return 0
    server="$(server_json_for_target openclaw "$json")"
    backup_config "$OPENCLAW_CONFIG"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq --arg name "$name" --argjson server "$server" '.mcp.servers[$name] = $server' "$OPENCLAW_CONFIG" > "$tmp"
    mv "$tmp" "$OPENCLAW_CONFIG"
    pz_info "MCP $name installed in openclaw config: $OPENCLAW_CONFIG"
}

remove_openclaw_target() {
    local name="$1" tmp
    [ -f "$OPENCLAW_CONFIG" ] || return 0
    if ! jq empty "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
        pz_warn "$OPENCLAW_CONFIG is not strict JSON; skipped openclaw"
        return 0
    fi
    backup_config "$OPENCLAW_CONFIG"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq --arg name "$name" 'del(.mcp.servers[$name]) | del(.mcpServers)' "$OPENCLAW_CONFIG" > "$tmp"
    mv "$tmp" "$OPENCLAW_CONFIG"
    pz_info "MCP $name removed from openclaw config: $OPENCLAW_CONFIG"
}

ensure_zcode_store() {
    mkdir -p "$(dirname "$ZCODE_STORE")"
    if [ ! -f "$ZCODE_STORE" ]; then
        jq -n '{}' > "$ZCODE_STORE"
        return 0
    fi
    if ! jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        pz_warn "$ZCODE_STORE is not strict JSON; skipped zcode"
        return 1
    fi
}

zcode_storage_json() {
    jq -r '."mcp-storage" // "{}"' "$ZCODE_STORE" | jq -c 'fromjson? // {}'
}

install_zcode_target() {
    local name="$1" json="$2" server storage new_storage tmp
    ensure_zcode_store || return 0
    server="$(server_json_for_target zcode "$json")"
    storage="$(zcode_storage_json)"
    new_storage="$(jq -c --arg name "$name" --arg id "mcp-$name" --argjson server "$server" '
      .state.config.mcp.mcpServers[$name] = $server
      | .state.servers = (((.state.servers // []) | map(select(.name != $name))) + [{
          id: $id,
          name: $name,
          config: $server,
          enabled: true,
          source: "phasezero",
          status: "disconnected"
        }])
    ' <<< "$storage")"
    backup_config "$ZCODE_STORE"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq --arg storage "$new_storage" '."mcp-storage" = $storage' "$ZCODE_STORE" > "$tmp"
    mv "$tmp" "$ZCODE_STORE"
    pz_info "MCP $name installed in zcode store: $ZCODE_STORE"
}

remove_zcode_target() {
    local name="$1" storage new_storage tmp
    [ -f "$ZCODE_STORE" ] || return 0
    if ! jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        pz_warn "$ZCODE_STORE is not strict JSON; skipped zcode"
        return 0
    fi
    storage="$(zcode_storage_json)"
    new_storage="$(jq -c --arg name "$name" '
      del(.state.config.mcp.mcpServers[$name])
      | .state.servers = ((.state.servers // []) | map(select(.name != $name)))
    ' <<< "$storage")"
    backup_config "$ZCODE_STORE"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    jq --arg storage "$new_storage" '."mcp-storage" = $storage' "$ZCODE_STORE" > "$tmp"
    mv "$tmp" "$ZCODE_STORE"
    pz_info "MCP $name removed from zcode store: $ZCODE_STORE"
}

target_list() {
    local target="${1:-all}"
    case "$target" in
        # Do not adopt or rewrite an externally installed OpenClaw during broad MCP sync.
        # Operators can still select openclaw explicitly for an intentional MCP change.
        all) printf '%s\n' opencode claude claude-desktop codex codex-project vscode vscode-user cursor zed zcode hermes ;;
        opencode|claude|claude-desktop|codex|codex-project|vscode|vscode-user|copilot|cursor|zed|zcode|hermes|openclaw) printf '%s\n' "$target" ;;
        *) pz_error "unknown MCP target: $target"; return 1 ;;
    esac
}

install_target() {
    local target="$1" name="$2" json="$3"
    case "$target" in
        codex) remove_codex_target "$name" "$CODEX_CONFIG"; install_codex_target "$name" "$json" "$CODEX_CONFIG" ;;
        codex-project) remove_codex_target "$name" "$CODEX_PROJECT_CONFIG"; install_codex_target "$name" "$json" "$CODEX_PROJECT_CONFIG" ;;
        vscode|copilot) install_json_target "vscode" "$name" "$json" ;;
        vscode-user) install_json_target "vscode-user" "$name" "$json" ;;
        cursor) install_json_target "cursor" "$name" "$json" ;;
        zed) install_json_target "zed" "$name" "$json" ;;
        zcode) remove_zcode_target "$name"; install_zcode_target "$name" "$json" ;;
        openclaw) remove_openclaw_target "$name"; install_openclaw_target "$name" "$json" ;;
        hermes) remove_hermes_target "$name"; install_hermes_target "$name" "$json" ;;
        *) install_json_target "$target" "$name" "$json" ;;
    esac
}

remove_target() {
    local target="$1" name="$2"
    case "$target" in
        codex) remove_codex_target "$name" "$CODEX_CONFIG" ;;
        codex-project) remove_codex_target "$name" "$CODEX_PROJECT_CONFIG" ;;
        vscode|copilot) remove_json_target "vscode" "$name" ;;
        vscode-user) remove_json_target "vscode-user" "$name" ;;
        cursor) remove_json_target "cursor" "$name" ;;
        zed) remove_json_target "zed" "$name" ;;
        zcode) remove_zcode_target "$name" ;;
        openclaw) remove_openclaw_target "$name" ;;
        hermes) remove_hermes_target "$name" ;;
        *) remove_json_target "$target" "$name" ;;
    esac
}

mcp_install() {
    local name="$1" target="${2:-all}" json t
    [ -n "$name" ] || { pz_error "usage: mcp-manager.sh install <name> [target]"; return 1; }
    json="$(definition_json "$name")" || { pz_error "MCP server definition not found: $name"; return 1; }
    validate_definition_json <<< "$json" || { pz_error "invalid MCP definition: $name"; return 1; }
    if definition_has_placeholder <<< "$json"; then
        pz_warn "MCP $name contains placeholder values; install is explicit but may need secrets/login"
    fi
    while IFS= read -r t; do
        install_target "$t" "$name" "$json"
    done < <(target_list "$target")
}

mcp_sync() {
    local target="${1:-all}" mode="${2:-safe}" name json
    while IFS= read -r name; do
        json="$(definition_json "$name")" || continue
        validate_definition_json <<< "$json" || continue
        if [ "$mode" != "all" ] && ! definition_safe "$name" "$json"; then
            continue
        fi
        mcp_install "$name" "$target"
    done < <(definition_names)
}

mcp_remove() {
    local name="$1" target="${2:-all}" t
    [ -n "$name" ] || { pz_error "usage: mcp-manager.sh remove <name> [target]"; return 1; }
    while IFS= read -r t; do
        remove_target "$t" "$name"
    done < <(target_list "$target")
}

mcp_repair() {
    local target="${1:-all}" name t
    while IFS= read -r t; do
        while IFS= read -r name; do
            remove_target "$t" "$name"
        done < <(definition_names)
    done < <(target_list "$target")
    mcp_sync "$target" safe
}

json_target_status() {
    local target="$1" cfg field count valid legacy
    cfg="$(json_target_path "$target")"
    field="$(target_field "$target")"
    valid=false
    legacy=false
    count=0
    if [ -f "$cfg" ] && jq empty "$cfg" >/dev/null 2>&1; then
        valid=true
        count="$(jq --arg field "$field" '.[$field] // {} | length' "$cfg" 2>/dev/null || echo 0)"
        if [ "$target" = "opencode" ] && jq -e 'has("mcpServers")' "$cfg" >/dev/null 2>&1; then
            legacy=true
        fi
    fi
    jq -cn --arg target "$target" --arg path "$cfg" --argjson exists "$([ -f "$cfg" ] && echo true || echo false)" \
        --argjson valid "$valid" --argjson count "$count" --argjson legacy "$legacy" \
        '{target:$target,path:$path,exists:$exists,valid:$valid,count:$count,legacyMcpServers:$legacy}'
}

codex_status() {
    local target="${1:-codex}" cfg="${2:-$CODEX_CONFIG}" count=0
    if [ -f "$cfg" ]; then
        count="$(grep -c -E '^\[mcp_servers\.[^].]+\]$' "$cfg" 2>/dev/null || true)"
    fi
    jq -cn --arg target "$target" --arg path "$cfg" --argjson exists "$([ -f "$cfg" ] && echo true || echo false)" \
        --argjson valid true --argjson count "$count" \
        '{target:$target,path:$path,exists:$exists,valid:$valid,count:$count}'
}

openclaw_status() {
    local count=0 valid=false
    if [ -f "$OPENCLAW_CONFIG" ] && jq empty "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
        valid=true
        count="$(jq '.mcp.servers // {} | length' "$OPENCLAW_CONFIG" 2>/dev/null || echo 0)"
    fi
    jq -cn --arg target "openclaw" --arg path "$OPENCLAW_CONFIG" --argjson exists "$([ -f "$OPENCLAW_CONFIG" ] && echo true || echo false)" \
        --argjson valid "$valid" --argjson count "$count" \
        '{target:$target,path:$path,exists:$exists,valid:$valid,count:$count}'
}

hermes_status() {
    local count=0 entries=0
    if [ -f "$HERMES_CONFIG" ]; then
        count="$(grep -c -E '^  # BEGIN PHASEZERO MCP ' "$HERMES_CONFIG" 2>/dev/null || true)"
        entries="$(awk '/^mcp_servers:[[:space:]]*$/ {inmcp=1; next} inmcp && /^  [A-Za-z0-9_.-]+:/ {c++} inmcp && /^[A-Za-z0-9_]+:/ {inmcp=0} END {print c+0}' "$HERMES_CONFIG" 2>/dev/null || echo 0)"
    fi
    jq -cn --arg target "hermes" --arg path "$HERMES_CONFIG" --argjson exists "$([ -f "$HERMES_CONFIG" ] && echo true || echo false)" \
        --argjson valid true --argjson count "$count" --argjson entries "$entries" \
        '{target:$target,path:$path,exists:$exists,valid:$valid,count:$count,entries:$entries}'
}

zcode_status() {
    local count=0 valid=false
    if [ -f "$ZCODE_STORE" ] && jq empty "$ZCODE_STORE" >/dev/null 2>&1; then
        valid=true
        count="$(jq '."mcp-storage" // "{}" | fromjson? | .state.config.mcp.mcpServers // {} | length' "$ZCODE_STORE" 2>/dev/null || echo 0)"
    fi
    jq -cn --arg target "zcode" --arg path "$ZCODE_STORE" --argjson exists "$([ -f "$ZCODE_STORE" ] && echo true || echo false)" \
        --argjson valid "$valid" --argjson count "$count" \
        '{target:$target,path:$path,exists:$exists,valid:$valid,count:$count}'
}

definition_status_json() {
    local name="$1" json valid placeholder safe auto url type
    json="$(definition_json "$name" 2>/dev/null || true)"
    valid=false
    placeholder=false
    safe=false
    auto=false
    type=""
    url=""
    if [ -n "$json" ]; then
        validate_definition_json <<< "$json" && valid=true
        definition_has_placeholder <<< "$json" && placeholder=true
        definition_safe "$name" "$json" && safe=true
        auto="$(jq -r '(.auto // false)' <<< "$json")"
        type="$(jq -r '.type // ""' <<< "$json")"
        url="$(jq -r '.url // ""' <<< "$json")"
    fi
    jq -cn --arg name "$name" --arg type "$type" --arg url "$url" \
        --argjson valid "$valid" --argjson placeholder "$placeholder" --argjson safe "$safe" --argjson auto "$auto" \
        '{name:$name,type:$type,url:$url,valid:$valid,hasPlaceholder:$placeholder,safeDefault:$safe,auto:$auto}'
}

mcp_status() {
    local tmp_defs tmp_targets defs targets
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp_defs="$(pz_tempfile)"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp_targets="$(pz_tempfile)"
    while IFS= read -r name; do
        definition_status_json "$name" >> "$tmp_defs"
    done < <(definition_names)
    {
        json_target_status opencode
        json_target_status claude
        json_target_status claude-desktop
        codex_status codex "$CODEX_CONFIG"
        codex_status codex-project "$CODEX_PROJECT_CONFIG"
        json_target_status vscode
        json_target_status vscode-user
        json_target_status cursor
        json_target_status zed
        zcode_status
        hermes_status
        openclaw_status
    } >> "$tmp_targets"
    defs="$(jq -s '.' "$tmp_defs")"
    targets="$(jq -s 'map({(.target): del(.target)}) | add' "$tmp_targets")"
    rm -f "$tmp_defs" "$tmp_targets"
    jq -cn --argjson definitions "$defs" --argjson targets "$targets" \
        '{schemaVersion:1,syncDefault:"safe",safeDefinition:"ai-memory",definitions:$definitions,targets:$targets}'
}

mcp_doctor() {
    local status
    status="$(mcp_status)"
    jq -cn --argjson status "$status" '{
      schemaVersion: 1,
      status: $status,
      problems: (
        [
          ($status.definitions[] | select(.valid == false) | {severity:"error", id:"invalid-definition", name:.name}),
          ($status.definitions[] | select(.hasPlaceholder == true) | {severity:"warn", id:"placeholder-definition", name:.name}),
          ($status.targets | to_entries[] | select(.value.valid == false) | {severity:"error", id:"invalid-target-config", target:.key, path:.value.path}),
          ($status.targets | to_entries[] | select(.value.legacyMcpServers == true) | {severity:"error", id:"opencode-legacy-mcpServers", target:.key, path:.value.path})
        ]
      ),
      nextActions: [
        "linux/pz ai mcp repair",
        "linux/pz ai mcp install context7 opencode",
        "codex mcp login sentry",
        "opencode mcp auth sentry"
      ]
    }'
}

mcp_list() {
    echo "=== Available MCP definitions ==="
    mcp_status | jq -r '.definitions[] | "\(.name): safe=\(.safeDefault) auto=\(.auto) placeholder=\(.hasPlaceholder) url=\(.url)"'
    echo
    echo "=== Installed MCP status ==="
    mcp_status | jq -r '.targets | to_entries[] | "\(.key): count=\(.value.count) valid=\(.value.valid) path=\(.value.path)"'
}

case "${1:-list}" in
    install) mcp_install "${2:-}" "${3:-all}" ;;
    sync|configure-safe) mcp_sync "${2:-all}" safe ;;
    sync-all|configure-all) mcp_sync "${2:-all}" all ;;
    repair) mcp_repair "${2:-all}" ;;
    doctor) mcp_doctor ;;
    list) mcp_list ;;
    status) mcp_status ;;
    remove) mcp_remove "${2:-}" "${3:-all}" ;;
    *) echo "usage: mcp-manager.sh (install|sync|sync-all|repair|doctor|list|status|remove) [name|target] [target]"; exit 1 ;;
esac
