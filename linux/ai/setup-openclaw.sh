#!/usr/bin/env bash
# setup-openclaw.sh - install/configure OpenClaw for PhaseZero Linux agents
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

NPM_PREFIX="${PZ_NPM_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
CONFIG_DIR="${HOME}/.openclaw"
CONFIG_FILE="$CONFIG_DIR/config.json"
GATEWAY_CONFIG_FILE="$CONFIG_DIR/openclaw.json"
PLUGIN_DIR="$CONFIG_DIR/plugins/ai-memory"
PHASEZERO_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai"
ENV_FILE="$PHASEZERO_CONFIG_DIR/openclaw.env"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai/openclaw.json"
AI_MEMORY_ORIGIN="${AI_MEMORY_SERVER_URL:-http://127.0.0.1:49374}"
AI_MEMORY_ORIGIN="${AI_MEMORY_ORIGIN%/}"
AI_MEMORY_MCP_URL="${AI_MEMORY_ORIGIN}/mcp"

openclaw_cmd() {
    command -v openclaw 2>/dev/null || {
        [ -x "$LOCAL_BIN/openclaw" ] && echo "$LOCAL_BIN/openclaw" && return 0
        [ -x "$NPM_PREFIX/bin/openclaw" ] && echo "$NPM_PREFIX/bin/openclaw" && return 0
        return 1
    }
}

ai_memory_cmd() {
    command -v ai-memory 2>/dev/null || {
        [ -x "$LOCAL_BIN/ai-memory" ] && echo "$LOCAL_BIN/ai-memory" && return 0
        return 1
    }
}

node_version_ok() {
    command -v node >/dev/null 2>&1 || return 1
    local version major minor
    version="$(node --version 2>/dev/null | sed 's/^v//')"
    major="${version%%.*}"
    minor="${version#*.}"
    minor="${minor%%.*}"
    [ "${major:-0}" -gt 22 ] && return 0
    [ "${major:-0}" -eq 22 ] && [ "${minor:-0}" -ge 19 ] && return 0
    return 1
}

link_managed_bin() {
    local command_name="$1" source_path="$2"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    ln -sfn "$source_path" "$LOCAL_BIN/$command_name"
    pz_info "linked $command_name into $LOCAL_BIN"
}

OPENCLAW_VERSION="${PZ_OPENCLAW_VERSION:-0.9.4}"

require_connection_grant() {
    pz_error "OpenClaw usage blocked: PhaseZero cannot bind an account grant to every request"
    jq -cn '{schemaVersion:1,tool:"openclaw",id:"openclaw",status:"blocked",
      ready:false,usageBlocked:true,blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
    return 69
}

install_openclaw() {
    pz_check_deps npm node jq
    if ! node_version_ok; then
        pz_error "OpenClaw requires Node >=22.19; current: $(node --version 2>/dev/null || echo missing)"
        return 1
    fi
    if ! bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check openclaw-install version="$OPENCLAW_VERSION" >/dev/null 2>&1; then
        pz_error "AI policy denies OpenClaw install (pinned version required); policy: ai-policy-broker status"
        return 1
    fi
    if openclaw_cmd >/dev/null 2>&1; then
        pz_info "OpenClaw already installed: $(openclaw_cmd)"
    else
        mkdir -p "$NPM_PREFIX"
        pz_info "installing OpenClaw $OPENCLAW_VERSION into user npm prefix: $NPM_PREFIX"
        npm install -g --prefix "$NPM_PREFIX" "openclaw@$OPENCLAW_VERSION"
        export PATH="$NPM_PREFIX/bin:$LOCAL_BIN:$PATH"
    fi
    link_managed_bin openclaw "$NPM_PREFIX/bin/openclaw"
}

write_env_template() {
    mkdir -p "$PHASEZERO_CONFIG_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        pz_write_managed_file "$ENV_FILE" <<'EOF'
# PhaseZero OpenClaw env template. No raw keys in repo files.
# OpenClaw auth/provider setup stays in official OpenClaw onboarding/configure flow.
# Optional BYOK examples:
# OPENAI_API_KEY=<manual-secret-store-value>
# ANTHROPIC_API_KEY=<manual-secret-store-value>
# OPENROUTER_API_KEY=<manual-secret-store-value>
EOF
        chmod 600 "$ENV_FILE" 2>/dev/null || true
    fi
}

write_state() {
    local cmd="${1:-}" version=""
    [ -n "$cmd" ] && version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    mkdir -p "$(dirname "$STATE_FILE")"
    jq -n \
        --arg installedAt "$(date -Iseconds)" \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg configPath "$CONFIG_FILE" \
        --arg gatewayConfigPath "$GATEWAY_CONFIG_FILE" \
        --arg envFile "$ENV_FILE" \
        --arg aiMemoryUrl "$AI_MEMORY_MCP_URL" \
        '{tool:"openclaw",installedAt:$installedAt,commandPath:$commandPath,version:$version,configPath:$configPath,gatewayConfigPath:$gatewayConfigPath,envFile:$envFile,aiMemoryMcpUrl:$aiMemoryUrl}' > "$STATE_FILE"
}

auth_args() {
    if [ -n "${AI_MEMORY_AUTH_TOKEN:-}" ]; then
        printf '%s\n' "--auth-token" "$AI_MEMORY_AUTH_TOKEN"
    fi
}

wire_ai_memory() {
    local cmd args=()
    cmd="$(ai_memory_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "ai-memory missing; skipping OpenClaw memory wiring"; return 0; }
    mapfile -t args < <(auth_args)
    "$cmd" install-mcp --client openclaw --apply --config-file "$CONFIG_FILE" --server-url "$AI_MEMORY_MCP_URL" "${args[@]}" >/dev/null 2>&1 || \
        pz_warn "ai-memory MCP wiring failed for OpenClaw"
    "$cmd" install-hooks --agent openclaw --apply --config-file "$PLUGIN_DIR" --project-strategy repo-root --server-url "$AI_MEMORY_ORIGIN" "${args[@]}" >/dev/null 2>&1 || {
        pz_warn "ai-memory hooks wiring failed for OpenClaw"
        return 0
    }
    if [ -d "$PLUGIN_DIR" ]; then
        local openclaw_bin
        openclaw_bin="$(openclaw_cmd || true)"
        if [ -n "$openclaw_bin" ]; then
            "$openclaw_bin" plugins install --link "$PLUGIN_DIR" >/dev/null 2>&1 || \
                pz_warn "OpenClaw plugin link failed; run: openclaw plugins install --link $PLUGIN_DIR"
        fi
    fi
}

configure_openclaw() {
    local cmd
    write_env_template
    cmd="$(openclaw_cmd || true)"
    [ -n "$cmd" ] || { pz_warn "OpenClaw not installed; run install first"; return 0; }

    mkdir -p "$CONFIG_DIR"
    if timeout 90 "$cmd" setup --non-interactive --accept-risk </dev/null >/dev/null 2>&1; then
        pz_info "OpenClaw baseline setup complete"
    elif [ -f "$GATEWAY_CONFIG_FILE" ]; then
        pz_warn "OpenClaw baseline config exists; gateway is stopped until daemon/run starts"
    elif timeout 90 "$cmd" setup --baseline --non-interactive </dev/null >/dev/null 2>&1; then
        pz_info "OpenClaw legacy baseline setup complete"
    else
        pz_warn "OpenClaw baseline setup failed; run: openclaw setup"
    fi

    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync openclaw >/dev/null || pz_warn "OpenClaw MCP sync failed"
    wire_ai_memory
    timeout 30 "$cmd" doctor --non-interactive >/dev/null 2>&1 || pz_warn "OpenClaw doctor reported issues; run: openclaw doctor"
    write_state "$cmd"
}

install_daemon() {
    local cmd
    cmd="$(openclaw_cmd || true)"
    [ -n "$cmd" ] || { pz_error "OpenClaw not installed"; return 1; }
    pz_info "installing OpenClaw gateway user service"
    if "$cmd" gateway install --force --runtime node >/dev/null 2>&1; then
        "$cmd" gateway start >/dev/null 2>&1 || \
            pz_warn "OpenClaw gateway service installed but did not start; run: openclaw gateway start"
    else
        pz_warn "OpenClaw gateway install failed; falling back to guided onboarding"
        "$cmd" onboard --install-daemon
    fi
}

gateway_status_text() {
    local cmd="$1"
    [ -n "$cmd" ] || return 0
    timeout 10 "$cmd" gateway status --no-color 2>/dev/null | head -40 | tr -d '\r' || true
}

status_json() {
    local cmd="" version="" gateway="" active=false enabled=false ai_memory=false phasezero_count=0 hooks=false
    cmd="$(openclaw_cmd || true)"
    if [ -n "$cmd" ]; then
        version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        gateway="$(gateway_status_text "$cmd")"
    fi
    systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1 && active=true
    systemctl --user is-enabled openclaw-gateway.service >/dev/null 2>&1 && enabled=true
    if [ -f "$CONFIG_FILE" ] && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        jq -e '.mcp.servers["ai-memory"]' "$CONFIG_FILE" >/dev/null 2>&1 && ai_memory=true
        phasezero_count="$(jq '.mcp.servers // {} | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
    fi
    if [ -d "$PLUGIN_DIR" ] || [ -d "$CONFIG_DIR/plugins/ai_memory" ]; then
        hooks=true
    fi
    jq -cn \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg configPath "$CONFIG_FILE" \
        --arg gatewayConfigPath "$GATEWAY_CONFIG_FILE" \
        --arg envFile "$ENV_FILE" \
        --arg pluginDir "$PLUGIN_DIR" \
        --arg stateFile "$STATE_FILE" \
        --arg gateway "$gateway" \
        --argjson available "$([ -n "$cmd" ] && echo true || echo false)" \
        --argjson configExists "$([ -f "$CONFIG_FILE" ] && echo true || echo false)" \
        --argjson gatewayConfigExists "$([ -f "$GATEWAY_CONFIG_FILE" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson stateExists "$([ -f "$STATE_FILE" ] && echo true || echo false)" \
        --argjson serviceActive "$active" \
        --argjson serviceEnabled "$enabled" \
        --argjson aiMemoryMcp "$ai_memory" \
        --argjson aiMemoryHooks "$hooks" \
        --argjson mcpServerCount "$phasezero_count" \
        '{tool:"openclaw",available:$available,commandPath:$commandPath,version:$version,configPath:$configPath,configExists:$configExists,gatewayConfigPath:$gatewayConfigPath,gatewayConfigExists:$gatewayConfigExists,envFile:$envFile,envExists:$envExists,stateFile:$stateFile,stateExists:$stateExists,service:{unit:"openclaw-gateway.service",scope:"user",active:$serviceActive,enabled:$serviceEnabled},gatewayStatus:$gateway,mcp:{serverCount:$mcpServerCount,aiMemory:$aiMemoryMcp},hooks:{aiMemory:$aiMemoryHooks,pluginDir:$pluginDir},status:"blocked",ready:false,usageBlocked:true,blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
}

dry_run() {
    jq -cn \
        --arg npmPrefix "$NPM_PREFIX" \
        --arg localBin "$LOCAL_BIN" \
        --arg configPath "$CONFIG_FILE" \
        --arg envFile "$ENV_FILE" \
        '{tool:"openclaw",status:"blocked",allowed:false,usageBlocked:true,blockedReason:"connection-grant-not-enforceable",planned:[],npmPrefix:$npmPrefix,localBin:$localBin,configPath:$configPath,envFile:$envFile,secretsRedacted:true}'
}

case "${1:-setup}" in
    setup|install|configure|daemon|install-daemon) require_connection_grant ;;
    status|doctor) status_json ;;
    dry-run|plan) dry_run ;;
    *) echo "usage: setup-openclaw.sh (setup|install|configure|daemon|status|doctor|dry-run)"; exit 1 ;;
esac
