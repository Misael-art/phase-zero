#!/usr/bin/env bash
# setup-memory.sh - install/configure ai-memory for Linux agent CLIs
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

AI_MEMORY_ORIGIN="${AI_MEMORY_SERVER_URL:-http://127.0.0.1:49374}"
AI_MEMORY_ORIGIN="${AI_MEMORY_ORIGIN%/}"
AI_MEMORY_MCP_URL="${AI_MEMORY_ORIGIN}/mcp"
AI_MEMORY_DATA_DIR="${AI_MEMORY_DATA_DIR:-$HOME/.local/share/ai-memory}"
AI_MEMORY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-memory"
AI_MEMORY_CONFIG="${AI_MEMORY_CONFIG:-$AI_MEMORY_CONFIG_DIR/config.toml}"
AI_MEMORY_ENV="${AI_MEMORY_ENV:-$AI_MEMORY_CONFIG_DIR/env}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
AI_MEMORY_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai"
AI_MEMORY_INTEGRATIONS_STATE="$AI_MEMORY_STATE_DIR/memory-integrations.json"

# Audited upstream release. Native binary avoids the old Docker-wrapper split:
# the agent runs on the host, while only the server may remain containerized.
AI_MEMORY_VERSION="${AI_MEMORY_VERSION:-1.31.1}"
AI_MEMORY_RELEASE_BASE="${AI_MEMORY_RELEASE_BASE:-https://github.com/akitaonrails/ai-memory/releases/download/v${AI_MEMORY_VERSION}}"
AI_MEMORY_SHA256_X86_64="${AI_MEMORY_SHA256_X86_64:-ee3bde8d2e843127152dc7a89b0c06bf3a64cf7c2894eedf69d8d2b4ec7b68cb}"
AI_MEMORY_SHA256_AARCH64="${AI_MEMORY_SHA256_AARCH64:-cdb80e14779cacca2aa479ee95a1ba2d0c1bd0dbb56297dcd37d0267cd4d6f84}"

ai_memory_cmd() {
    command -v ai-memory 2>/dev/null || {
        [ -x "$LOCAL_BIN/ai-memory" ] && echo "$LOCAL_BIN/ai-memory"
    }
}

is_phasezero_docker_wrapper() {
    local cmd="$1"
    [ -f "$cmd" ] && grep -q 'AI_MEMORY_DOCKER_IMAGE' "$cmd" 2>/dev/null
}

detected_agents() {
    command -v claude >/dev/null 2>&1 && echo "claude-code:claude-code"
    command -v codex >/dev/null 2>&1 && echo "codex:codex"
    command -v opencode >/dev/null 2>&1 && echo "opencode:open-code"
    command -v cursor >/dev/null 2>&1 && echo "cursor:cursor"
    command -v gemini >/dev/null 2>&1 && echo "gemini-cli:gemini-cli"
    { command -v grok >/dev/null 2>&1 || [ -d "$HOME/.grok" ]; } && echo "grok:grok"
    { command -v kimi >/dev/null 2>&1 || command -v kimi-code >/dev/null 2>&1 || [ -d "$HOME/.kimi" ] || [ -d "$HOME/.kimi-code" ]; } && echo "kimi-code:kimi-code"
}

resolved_auth_token() {
    if [ -n "${AI_MEMORY_AUTH_TOKEN:-}" ]; then
        printf '%s\n' "$AI_MEMORY_AUTH_TOKEN"
    elif [ -f "$AI_MEMORY_ENV" ]; then
        awk -F= '$1=="AI_MEMORY_AUTH_TOKEN" {sub(/^[^=]*=/, ""); print; exit}' "$AI_MEMORY_ENV"
    fi
}

ai_memory_asset() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\t%s\n' "ai-memory-linux-x86_64.tar.gz" "$AI_MEMORY_SHA256_X86_64" ;;
        aarch64|arm64) printf '%s\t%s\n' "ai-memory-linux-aarch64.tar.gz" "$AI_MEMORY_SHA256_AARCH64" ;;
        *) return 1 ;;
    esac
}

install_native_release() {
    local row asset expected work archive actual binary existing="" current=""
    row="$(ai_memory_asset)" || {
        pz_error "unsupported ai-memory Linux architecture: $(uname -m)"
        return 1
    }
    IFS=$'\t' read -r asset expected <<< "$row"
    existing="$(ai_memory_cmd || true)"
    if [ -n "$existing" ] && ! is_phasezero_docker_wrapper "$existing"; then
        current="$(timeout 8 "$existing" --version 2>/dev/null | head -1 || true)"
        if grep -qE "(^|[[:space:]])${AI_MEMORY_VERSION}([[:space:]]|$)" <<< "$current"; then
            pz_info "ai-memory already current: $existing ($current)"
            return 0
        fi
    fi
    pz_check_deps curl tar sha256sum >/dev/null
    work="$(mktemp -d)"
    trap 'rm -rf -- "${work:?}"; trap - RETURN' RETURN
    archive="$work/$asset"
    curl -fL "$AI_MEMORY_RELEASE_BASE/$asset" -o "$archive"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        pz_error "ai-memory checksum mismatch. expected=$expected actual=$actual"
        return 1
    fi
    tar -xzf "$archive" -C "$work"
    binary="$work/ai-memory"
    [ -f "$binary" ] || { pz_error "ai-memory binary missing from $asset"; return 1; }
    mkdir -p "$LOCAL_BIN" "$AI_MEMORY_STATE_DIR"
    [ -f "$LOCAL_BIN/ai-memory" ] && pz_backup_file "$LOCAL_BIN/ai-memory" user >/dev/null
    install -m 0755 "$binary" "$LOCAL_BIN/ai-memory"
    pz_record_created ai "$LOCAL_BIN/ai-memory"
    jq -n --arg version "$AI_MEMORY_VERSION" --arg asset "$asset" \
        --arg source "$AI_MEMORY_RELEASE_BASE/$asset" --arg sha256 "$expected" \
        --arg path "$LOCAL_BIN/ai-memory" --arg installedAt "$(date -Iseconds)" \
        '{schemaVersion:1,tool:"ai-memory",version:$version,asset:$asset,source:$source,sha256:$sha256,path:$path,installedAt:$installedAt}' \
        > "$AI_MEMORY_STATE_DIR/ai-memory-install.json"
    export PATH="$LOCAL_BIN:$PATH"
    pz_info "ai-memory native installed: $LOCAL_BIN/ai-memory (v$AI_MEMORY_VERSION)"
}

install_ai_memory() {
    install_native_release
}

write_default_config() {
    mkdir -p "$AI_MEMORY_CONFIG_DIR" "$AI_MEMORY_DATA_DIR"
    if [ ! -f "$AI_MEMORY_CONFIG" ]; then
        pz_write_managed_file "$AI_MEMORY_CONFIG" <<EOF
# PhaseZero managed ai-memory user config.
# Loopback default. Put provider credentials in $AI_MEMORY_ENV, never in repo files.
bind = "127.0.0.1:49374"
data_dir = "$AI_MEMORY_DATA_DIR"
EOF
    fi
    if [ ! -f "$AI_MEMORY_ENV" ]; then
        pz_write_managed_file "$AI_MEMORY_ENV" <<'EOF'
# PhaseZero managed ai-memory env.
# Optional:
# AI_MEMORY_LLM_PROVIDER=anthropic
# ANTHROPIC_API_KEY=<put-in-secret-store-or-edit-manually>
EOF
        chmod 600 "$AI_MEMORY_ENV" 2>/dev/null || true
    fi
}

init_ai_memory() {
    local cmd
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_error "ai-memory not installed; init unavailable"; return 1; }
    mkdir -p "$AI_MEMORY_DATA_DIR" "$AI_MEMORY_CONFIG_DIR"
    if "$cmd" --data-dir "$AI_MEMORY_DATA_DIR" --config "$AI_MEMORY_CONFIG" init >/dev/null 2>&1; then
        return 0
    fi
    pz_error "ai-memory init failed; service and clients were not declared ready"
    return 1
}

install_user_service() {
    local cmd service_dir service_path
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "ai-memory not installed; skipping service"; return 0; }
    service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    service_path="$service_dir/ai-memory.service"
    mkdir -p "$service_dir"
    if [ ! -f "$service_path" ] || grep -q 'PhaseZero managed' "$service_path" 2>/dev/null; then
        local exec_start
        if is_phasezero_docker_wrapper "$cmd"; then
            exec_start="$cmd serve --transport http --bind 127.0.0.1:49374"
        else
            exec_start="$cmd --data-dir $AI_MEMORY_DATA_DIR --config $AI_MEMORY_CONFIG serve --transport http --bind 127.0.0.1:49374"
        fi
        pz_write_managed_file "$service_path" <<EOF
[Unit]
Description=ai-memory local loopback server
Documentation=https://github.com/akitaonrails/ai-memory

[Service]
# PhaseZero managed
EnvironmentFile=-$AI_MEMORY_ENV
ExecStart=$exec_start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    else
        pz_info "existing ai-memory user service preserved: $service_path"
    fi
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user enable --now ai-memory.service >/dev/null 2>&1 || \
            pz_warn "could not enable ai-memory user service; run: systemctl --user enable --now ai-memory.service"
    else
        pz_warn "systemd user session unavailable; service file written only"
    fi
}

wire_agents() {
    local cmd pair client agent token rows tmp canonical_ok=true all_ok=true mcp_ok hook_ok
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_error "ai-memory not installed; agent wiring unavailable"; return 1; }
    mkdir -p "$AI_MEMORY_STATE_DIR"
    rows="$(mktemp)"
    tmp="$(mktemp)"
    trap 'rm -f -- "$rows" "$tmp"; trap - RETURN' RETURN
    : > "$rows"
    token="$(resolved_auth_token)"
    if ! bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync >/dev/null 2>&1; then
        canonical_ok=false
        all_ok=false
        pz_warn "PhaseZero MCP sync failed; individual client wiring will still be attempted"
    fi
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        client="${pair%%:*}"
        agent="${pair##*:}"
        mcp_ok=true
        hook_ok=true
        AI_MEMORY_AUTH_TOKEN="$token" "$cmd" install-mcp --client "$client" --apply \
            --server-url "$AI_MEMORY_MCP_URL" >/dev/null 2>&1 || mcp_ok=false
        AI_MEMORY_AUTH_TOKEN="$token" "$cmd" install-hooks --agent "$agent" --apply \
            --project-strategy repo-root --server-url "$AI_MEMORY_ORIGIN" >/dev/null 2>&1 || hook_ok=false
        if [ "$mcp_ok" != true ]; then
            all_ok=false
            pz_warn "ai-memory MCP wiring failed for $client"
        fi
        if [ "$hook_ok" != true ]; then
            all_ok=false
            pz_warn "ai-memory hooks wiring failed for $agent"
        fi
        jq -cn --arg client "$client" --arg agent "$agent" \
            --argjson mcp "$mcp_ok" --argjson hooks "$hook_ok" \
            '{client:$client,agent:$agent,mcp:$mcp,hooks:$hooks,ready:($mcp and $hooks)}' >> "$rows"
    done < <(detected_agents)
    if command -v openclaw >/dev/null 2>&1; then
        pz_warn "OpenClaw memory wiring skipped: managed use is blocked until per-request grants are enforceable"
        jq -cn '{client:"openclaw",agent:"openclaw",mcp:false,hooks:false,ready:false,
          usageBlocked:true,blockedReason:"connection-grant-not-enforceable"}' >> "$rows"
    fi
    # ZCode consumes PhaseZero's canonical MCP store. It has no documented
    # ai-memory lifecycle-hook adapter; claiming hooks here would be false.
    if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/ai.z.zcode/store.json" ]; then
        jq -cn --argjson mcp "$canonical_ok" \
            '{client:"zcode",agent:"zcode",mcp:$mcp,hooks:null,ready:$mcp,note:"MCP supported; lifecycle hooks not documented"}' >> "$rows"
    fi
    jq -s --arg checkedAt "$(date -Iseconds)" --argjson canonicalMcp "$canonical_ok" \
        --argjson ok "$all_ok" \
        '{schemaVersion:1,checkedAt:$checkedAt,ok:$ok,canonicalMcp:$canonicalMcp,clients:.}' \
        "$rows" > "$tmp"
    mv "$tmp" "$AI_MEMORY_INTEGRATIONS_STATE"
    chmod 600 "$AI_MEMORY_INTEGRATIONS_STATE"
    trap - RETURN
    rm -f "$rows"
    [ "$all_ok" = true ]
}

status_json() {
    local base integrations='{"schemaVersion":1,"ok":false,"canonicalMcp":false,"clients":[]}'
    base="$(bash "$PZ_ROOT/linux/ai/status.sh" | jq '.memory')"
    if [ -f "$AI_MEMORY_INTEGRATIONS_STATE" ] && jq empty "$AI_MEMORY_INTEGRATIONS_STATE" >/dev/null 2>&1; then
        integrations="$(cat "$AI_MEMORY_INTEGRATIONS_STATE")"
    fi
    jq -cn --argjson base "$base" --argjson integrations "$integrations" '
      $base + {
        ready:($base.installed and $base.serverReachable and $base.userServiceActive and ($base.version != "") and $integrations.ok),
        status:(if ($base.installed|not) then "missing"
                elif (($base.serverReachable and $base.userServiceActive)|not) then "service-error"
                elif $base.version == "" then "version-unknown"
                elif ($integrations.ok|not) then "integration-error"
                else "ready" end),
        integrations:$integrations
      }'
}

dry_run() {
    local row asset="" sha256=""
    row="$(ai_memory_asset || true)"
    IFS=$'\t' read -r asset sha256 <<< "$row"
    jq -cn --arg dataDir "$AI_MEMORY_DATA_DIR" --arg config "$AI_MEMORY_CONFIG" --arg origin "$AI_MEMORY_ORIGIN" \
        --arg version "$AI_MEMORY_VERSION" --arg asset "$asset" --arg sha256 "$sha256" \
        --arg agents "$(detected_agents | cut -d: -f1 | paste -sd ',' -)" \
        '{tool:"ai-memory",version:$version,asset:$asset,sha256:$sha256,planned:["install verified native release","create user config/env","enable user service","sync MCPs and lifecycle hooks for detected agents"],dataDir:$dataDir,config:$config,serverUrl:$origin,detectedAgents:($agents|split(",")|map(select(length>0)))}'
}

configure_ai_memory() {
    local init_ok=true wire_ok=true
    write_default_config
    init_ai_memory || init_ok=false
    install_user_service
    wire_agents || wire_ok=false
    status_json
    [ "$init_ok" = true ] && [ "$wire_ok" = true ]
}

case "${1:-setup}" in
    setup)
        install_ai_memory
        configure_ai_memory
        ;;
    install) install_ai_memory ;;
    configure) configure_ai_memory ;;
    service)
        write_default_config
        init_ai_memory
        install_user_service
        ;;
    wire) wire_agents ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-memory.sh (setup|install|configure|service|wire|status|dry-run)"; exit 1 ;;
esac
