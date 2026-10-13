#!/usr/bin/env bash
# PhaseZero-managed OmniRoute installer, health, routing and telemetry layer.
# Operates in parallel with 9Router on auto-detected port (20128+).
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true

connection_grant_blocked() {
    jq -cn --arg action "$ACTION" \
        '{schemaVersion:1,action:$action,status:"blocked",usageBlocked:true,
          blockedReason:"connection-grant-not-enforceable",
          message:"OmniRoute cannot pin each request to one granted connection; no provider, route, dashboard or client action was performed.",
          secretsRedacted:true}'
    return 69
}

PROXY_ROOT="${PZ_AI_PROXY_ROOT:-$HOME/.local/share/phasezero/ai-proxies}"
INSTALL_PREFIX="${PZ_OMNIROUTE_PREFIX:-$HOME/.local/share/npm}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/omniroute"
ENV_FILE="$CONFIG_DIR/omniroute.env"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/omniroute"
STATE_DIR="$PZ_STATE/omniroute"
USAGE_LOG="$STATE_DIR/usage.log"
HEALTH_LOG="$STATE_DIR/health.log"
SERVICE="phasezero-omniroute.service"
WATCH_SERVICE="phasezero-omniroute-watch.service"
WATCH_TIMER="phasezero-omniroute-watch.timer"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DASHBOARD_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/phasezero-omniroute.desktop"
CLIENT_WRAPPER="$LOCAL_BIN/phasezero-omniroute-run"
OPENCODE_CONFIG="${HOME}/.config/opencode/opencode.json"
OPENCODE_CONFIG_JSON="${HOME}/.config/opencode/opencode.jsonc"
BACKUP_ROOT="$PROXY_ROOT/.omniroute-backups"

# ─── helpers ──────────────────────────────────────────────────────────────────

find_free_port() {
    local base="${1:-20128}" port
    for port in $(seq "$base" $((base + 19))); do
        if ! ss -tlnH "sport = :$port" 2>/dev/null | grep -q .; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    pz_error "no free TCP port in range $base-$((base + 19))"
    return 1
}

ensure_dirs() {
    install -d -m 700 "$CONFIG_DIR" "$DATA_DIR" "$STATE_DIR"
    install -d "$LOCAL_BIN" "$SYSTEMD_USER_DIR" "$BACKUP_ROOT"
}

random_hex() {
    local bytes="${1:-32}" value
    if command -v openssl >/dev/null 2>&1; then
        value="$(openssl rand -hex "$bytes")"
    else
        value="$(od -An -N"$bytes" -tx1 /dev/urandom | tr -d '[:space:]')"
    fi
    [ "${#value}" -ge $((bytes * 2)) ] || { pz_error "secure random generation failed"; return 1; }
    printf '%s\n' "$value"
}

env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
}

env_upsert() {
    local key="$1" value="$2" tmp
    ensure_dirs
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    install -m 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

# ─── runtime config ───────────────────────────────────────────────────────────

detect_port() {
    local port
    port="$(env_get PORT)"
    if [ -n "$port" ]; then
        printf '%s\n' "$port"
        return 0
    fi
    find_free_port 20128
}

write_runtime_config() {
    local port initial_password jwt_secret api_secret machine_salt
    port="$(detect_port)"
    initial_password="$(env_get INITIAL_PASSWORD)"
    jwt_secret="$(env_get JWT_SECRET)"
    api_secret="$(env_get API_KEY_SECRET)"
    machine_salt="$(env_get MACHINE_ID_SALT)"
    [ -n "$initial_password" ] || initial_password="pz-$(random_hex 18)"
    [ -n "$jwt_secret" ] || jwt_secret="$(random_hex 32)"
    [ -n "$api_secret" ] || api_secret="$(random_hex 32)"
    [ -n "$machine_salt" ] || machine_salt="$(random_hex 24)"

    # A chave de cliente vem de env_upsert e precisa sobreviver ao rewrite:
    # descartá-la fazia ensure_api_key recriá-la, invalidando a chave já
    # colada no opencode.json.
    local client_key
    client_key="$(env_get OMNIROUTE_API_KEY)"
    # EnvironmentFile do systemd vivo: nunca truncar no lugar (mesma lição
    # do incidente 9router.env). Backup + escrita staged no mesmo diretório.
    if [ -f "$ENV_FILE" ]; then
        cp -a "$ENV_FILE" "$ENV_FILE.pz-bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    local tmp="$ENV_FILE.tmp.$$"
    cat > "$tmp" <<EOF
PORT=$port
HOSTNAME=127.0.0.1
NODE_ENV=production
INITIAL_PASSWORD=$initial_password
JWT_SECRET=$jwt_secret
API_KEY_SECRET=$api_secret
MACHINE_ID_SALT=$machine_salt
REQUIRE_API_KEY=true
ENABLE_REQUEST_LOGS=false
AUTH_COOKIE_SECURE=false
OMNIROUTE_DATA_DIR=$DATA_DIR
EOF
    [ -n "$client_key" ] && printf 'OMNIROUTE_API_KEY=%s\n' "$client_key" >> "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$ENV_FILE"

    local active_combo
    active_combo="$(jq -r '.activeCombo // "phasezero-smart"' "$SETTINGS_FILE" 2>/dev/null || echo phasezero-smart)"
    jq -n --arg port "$port" \
        --arg baseUrl "http://127.0.0.1:$port" \
        --arg endpoint "http://127.0.0.1:$port/v1" \
        --arg dashboard "http://127.0.0.1:$port/dashboard" \
        --arg combo "$active_combo" \
        --arg env "$ENV_FILE" \
        '{schemaVersion:1,port:$port|tonumber,baseUrl:$baseUrl,endpoint:$endpoint,dashboardUrl:$dashboard,activeCombo:$combo,managedEnv:$env}' \
        > "$SETTINGS_FILE"
    chmod 0600 "$SETTINGS_FILE"
}

# ─── wrappers, units, desktop ─────────────────────────────────────────────────

write_wrapper_and_units() {
    local port
    port="$(detect_port)"

    pz_write_managed_file "$LOCAL_BIN/omniroute" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$INSTALL_PREFIX/bin:\$PATH"
exec omniroute --port "$port" --host 127.0.0.1 --no-browser "\$@"
EOF
    chmod +x "$LOCAL_BIN/omniroute"

    pz_write_managed_file "$CLIENT_WRAPPER" user \
        < "$PZ_ROOT/linux/ai/omniroute-client-wrapper.sh"
    chmod 0700 "$CLIENT_WRAPPER"

    install -d "$(dirname "$DASHBOARD_ENTRY")"
    pz_write_managed_file "$DASHBOARD_ENTRY" user <<EOF
[Desktop Entry]
Type=Application
Name=OmniRoute
Comment=PhaseZero OmniRoute AI routing dashboard
Exec=$HOME/.local/share/phasezero/current/linux/pz ai omniroute dashboard
Icon=applications-science
Terminal=false
Categories=X-PhaseZero-WebApp;
X-PHZ-Group=ia
X-PhaseZero-MenuGroup=web.ai
X-PhaseZero-Managed=true
EOF
    chmod 0644 "$DASHBOARD_ENTRY"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$(dirname "$DASHBOARD_ENTRY")" >/dev/null 2>&1 || true
    fi

    pz_write_managed_file "$SYSTEMD_USER_DIR/$SERVICE" user <<EOF
[Unit]
Description=PhaseZero OmniRoute AI routing gateway
Documentation=https://omniroute.online
After=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$LOCAL_BIN/omniroute
Restart=on-failure
RestartSec=5
WorkingDirectory=$INSTALL_PREFIX

[Install]
WantedBy=default.target
EOF

    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCH_SERVICE" user <<EOF
[Unit]
Description=PhaseZero OmniRoute provider health sample
After=$SERVICE

[Service]
Type=oneshot
ExecStart=$HOME/.local/share/phasezero/current/linux/ai/omniroute-manager.sh watch-once
EOF

    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCH_TIMER" user <<EOF
[Unit]
Description=Sample passive OmniRoute health every ten minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min
Unit=$WATCH_SERVICE

[Install]
WantedBy=timers.target
EOF
}

# ─── install ──────────────────────────────────────────────────────────────────

installed_version() {
    [ -f "$INSTALL_PREFIX/lib/node_modules/omniroute/package.json" ] || return 0
    jq -r '.version // empty' "$INSTALL_PREFIX/lib/node_modules/omniroute/package.json" 2>/dev/null || true
}

install_omniroute() {
    pz_check_deps node npm jq curl
    local port
    port="$(detect_port)"
    pz_info "installing OmniRoute on port $port"

    local current version
    current="$(installed_version)"

    if [ -n "$current" ] && [ "${ACTION}" = install ]; then
        pz_info "OmniRoute $current already installed; use 'pz ai omniroute update' to upgrade"
    fi

    ensure_dirs
    mkdir -p "$INSTALL_PREFIX"

    npm install -g --prefix "$INSTALL_PREFIX" omniroute 2>&1 || {
        pz_error "npm install -g omniroute failed"
        return 1
    }

    version="$(installed_version)"
    [ -n "$version" ] || { pz_error "OmniRoute binary not found after install"; return 1; }

    write_runtime_config
    write_wrapper_and_units

    if systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user enable --now "$SERVICE"
        systemctl --user enable --now "$WATCH_TIMER" >/dev/null 2>&1 || pz_warn "watchdog timer could not be enabled"
    elif command -v pm2 >/dev/null 2>&1; then
        pm2 delete phasezero-omniroute >/dev/null 2>&1 || true
        pm2 start "$LOCAL_BIN/omniroute" --name phasezero-omniroute
        pm2 save
    else
        pz_error "systemd user unavailable and pm2 missing"
        return 1
    fi

    if [ "${PZ_DRY_RUN:-0}" != "1" ]; then
        wait_ready 90
        ensure_api_key
        combo_auto
        opencode_integration
    fi

    pz_info "OmniRoute $version installed: http://127.0.0.1:$port/dashboard"
    jq -cn --arg version "$version" --arg port "$port" \
        '{status:"complete",version:$version,port:$port|tonumber,endpoint:("http://127.0.0.1:"+$port+"/v1"),dashboard:("http://127.0.0.1:"+$port+"/dashboard")}'
}

wait_ready() {
    local timeout="${1:-30}" port i
    port="$(detect_port)"
    for ((i = 0; i < timeout; i++)); do
        curl -fsS --max-time 2 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    pz_error "OmniRoute did not become healthy within ${timeout}s"
    systemctl --user status "$SERVICE" --no-pager >&2 2>/dev/null || true
    return 1
}

# ─── API key ──────────────────────────────────────────────────────────────────

ensure_api_key() {
    local key port response payload
    key="$(env_get OMNIROUTE_API_KEY)"
    port="$(detect_port)"
    [ -n "$key" ] && return 0

    local password
    password="$(env_get INITIAL_PASSWORD)"

    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    payload="$(pz_tempfile)"
    jq -n --arg name "phasezero-managed" '{name:$name}' > "$payload"

    response="$(curl -fsS --max-time 10 -X POST "http://127.0.0.1:$port/api/keys" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $password" \
        --data-binary "@$payload" 2>/dev/null || true)"
    rm -f "$payload"

    key="$(jq -r '.key // .apiKey // .data.key // empty' <<< "$response" 2>/dev/null || true)"
    [ -n "$key" ] || { pz_error "OmniRoute API key creation failed"; return 1; }
    env_upsert OMNIROUTE_API_KEY "$key"
    pz_info "OmniRoute API key generated"
}

# ─── service ──────────────────────────────────────────────────────────────────

service_state() {
    if systemctl --user list-unit-files "$SERVICE" >/dev/null 2>&1; then
        systemctl --user is-active "$SERVICE" 2>/dev/null || true
    elif command -v pm2 >/dev/null 2>&1 && pm2 describe phasezero-omniroute >/dev/null 2>&1; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
}

# ─── status ───────────────────────────────────────────────────────────────────

status_json() {
    local port installed=false service version="" health=false providers='[]' combos='[]' usage='{}'
    port="$(detect_port)"
    [ -x "$(command -v omniroute 2>/dev/null || true)" ] || [ -f "$INSTALL_PREFIX/bin/omniroute" ] && installed=true
    service="$(service_state)"; service="${service:-inactive}"
    if $installed; then version="$(installed_version)"; fi
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then
        health=true
        local providers_raw combos_raw
        providers_raw="$(api_request GET /api/providers 2>/dev/null || echo '[]')"
        combos_raw="$(api_request GET /api/combos 2>/dev/null || echo '[]')"
        providers="$(jq -c '[.connections // .providers // .data // . | .[]? | {id,provider:(.provider // .providerId // ""),name:(.name // .displayName // .email // ""),active:(.isActive // true)}]' <<< "$providers_raw" 2>/dev/null || echo '[]')"
        combos="$(jq -c '[.combos // .data // . | .[]? | {id,name,modelCount:((.models // [])|length)}]' <<< "$combos_raw" 2>/dev/null || echo '[]')"
        usage="$(api_request GET /api/usage/stats 2>/dev/null | usage_summary || echo '{}')"
    fi
    jq -cn --arg port "$port" --arg version "$version" --arg service "$service" \
        --arg endpoint "http://127.0.0.1:$port/v1" \
        --arg dashboard "http://127.0.0.1:$port/dashboard" \
        --arg settings "$SETTINGS_FILE" --arg healthLog "$HEALTH_LOG" \
        --argjson installed "$installed" --argjson health "$health" \
        --argjson providers "$providers" --argjson combos "$combos" --argjson usage "$usage" \
        '{schemaVersion:1,id:"omniroute",port:$port|tonumber,installed:$installed,version:$version,service:$service,healthy:$health,
          endpoint:$endpoint,dashboard:$dashboard,settingsPath:$settings,
          providers:{total:($providers|length),active:[$providers[] | select(.active==true)]|length,list:$providers},
          combos:{total:($combos|length),names:[$combos[] | .name],list:$combos},
          usage:$usage,usageBlocked:true,blockedReason:"connection-grant-not-enforceable",
          nextAction:"connection-grant-not-enforceable"}'
}

usage_summary() {
    jq '{
      totalRequests:(.totalRequests // 0),
      totalPromptTokens:(.totalPromptTokens // 0),
      totalCompletionTokens:(.totalCompletionTokens // 0),
      totalCost:(.totalCost // 0),
      providerCount:((.byProvider // {}) | length),
      modelCount:((.byModel // {}) | length)
    }' 2>/dev/null || echo '{}'
}

# ─── API request helper ───────────────────────────────────────────────────────

api_request() {
    local method="$1" path="$2" data_file="${3:-}" max_time="${4:-8}" port key args out
    port="$(detect_port)"
    key="$(env_get OMNIROUTE_API_KEY)"
    if [ -z "$key" ]; then
        if [ "$method" = "GET" ]; then
            printf '{"ok":false,"state":"needs-config","summary":"OmniRoute nao tem chave de API; o servico pode nao estar instalado.","nextAction":"linux/pz ai omniroute install"}\n'
            return 0
        fi
        pz_error "OmniRoute API key unavailable; run install first"
        return 1
    fi
    args=(-fsS --max-time "$max_time" -X "$method" -H "Authorization: Bearer $key" -H 'Content-Type: application/json')
    [ -z "$data_file" ] || args+=(--data-binary "@$data_file")
    if ! out="$(curl "${args[@]}" "http://127.0.0.1:$port$path")"; then
        if [ "$method" = "GET" ]; then
            printf '{"ok":false,"state":"unavailable","summary":"O servico OmniRoute nao respondeu na porta %s.","nextAction":"linux/pz ai omniroute install"}\n' "$port"
            return 0
        fi
        return 1
    fi
    printf '%s\n' "$out"
}

# ─── test ─────────────────────────────────────────────────────────────────────

test_omniroute() {
    local port key health=false models_ok=false chat_status="blocked" provider_count=0
    port="$(detect_port)"
    curl -fsS --max-time 3 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && health=true
    key="$(env_get OMNIROUTE_API_KEY)"

    local code body
    body="$(curl -sS --max-time 10 -H "Authorization: Bearer $key" "http://127.0.0.1:$port/v1/models" 2>/dev/null || true)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $key" "http://127.0.0.1:$port/v1/models" 2>/dev/null || true)"
    jq -e '(.data // []) | type == "array"' <<< "$body" >/dev/null 2>&1 && [ "$code" = 200 ] && models_ok=true

    provider_count="$(api_request GET /api/providers 2>/dev/null | jq '[.connections // .providers // .data // . | .[]? | select((.isActive // true)==true)] | length' 2>/dev/null || echo 0)"
    jq -cn --arg endpoint "http://127.0.0.1:$port/v1" --arg httpCode "$code" \
        --argjson health "$health" --arg chat "$chat_status" \
        --argjson providers "$provider_count" --argjson models "$models_ok" \
        --argjson count "$(jq '(.data // []) | length' <<< "$body" 2>/dev/null || echo 0)" \
        '{id:"omniroute",endpoint:$endpoint,health:$health,modelsEndpoint:$models,httpCode:$httpCode,modelCount:$count,providerCount:$providers,chat:$chat,blockedReason:"connection-grant-not-enforceable"}'
    $health && $models_ok
}

# ─── provider sync ────────────────────────────────────────────────────────────

find_secrets_manifest() {
    local candidate
    for candidate in \
        "${BOOTSTRAP_DATA_ROOT:-}/bootstrap-secrets.json" \
        "$HOME/.bootstrap-tools/bootstrap-secrets.json" \
        "${LOCALAPPDATA:-}/bootstrap-tools/bootstrap-secrets.json" \
        "$PZ_ROOT/.bootstrap-tools/bootstrap-secrets.json"; do
        [ "$candidate" != "/bootstrap-secrets.json" ] && [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

provider_sync() {
    local manifest provider name secret payload response imported=0 skipped=0
    manifest="${1:-}"
    [ -n "$manifest" ] || manifest="$(find_secrets_manifest || true)"
    [ -f "$manifest" ] || { pz_warn "bootstrap-secrets.json not found; provider import skipped"; return 0; }

    while IFS=$'\t' read -r provider name secret; do
        case "$provider" in openai|anthropic|gemini|openrouter|deepseek|glm|kimi|minimask|qwen|mistral|groq|nvidia) ;; *) skipped=$((skipped + 1)); continue ;; esac
        [ -n "$secret" ] || { skipped=$((skipped + 1)); continue; }
        # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
        payload="$(pz_tempfile)"
        jq -n --arg provider "$provider" --arg name "${name:-PhaseZero $provider}" --arg apiKey "$secret" \
            '{provider:$provider,name:$name,apiKey:$apiKey}' > "$payload"
        if response="$(api_request POST /api/providers "$payload" 2>/dev/null)" && jq -e '(.error // empty) == ""' <<< "$response" >/dev/null 2>&1; then
            imported=$((imported + 1))
        else
            skipped=$((skipped + 1))
        fi
        rm -f "$payload"
    done < <(jq -r '
      (.providers // {}) | to_entries[] as $p |
      ($p.value.activeCredential // "") as $active |
      ($p.value.credentials[$active] // {}) as $c |
      select(($c.secret // "") != "" and (($c.validation.state // "unknown") == "passed")) |
      [($p.key | if . == "google" then "gemini" elif . == "moonshot" then "kimi" else . end), ($c.displayName // $active), $c.secret] | @tsv
    ' "$manifest" 2>/dev/null || true)

    jq -cn --arg manifest "$manifest" --argjson imported "$imported" --argjson skipped "$skipped" \
        '{manifest:$manifest,imported:$imported,skipped:$skipped,secretsRedacted:true}'
}

provider_status() {
    api_request GET /api/providers | jq '{(.connections // .providers // .data // [] | length | tostring): "providers", providers: [.connections // .providers // .data // .[]? | {id, provider: (.provider // .providerId // ""), name: (.name // .displayName // .email // ""), active: (.isActive // true)}]}' 2>/dev/null || echo '{"providers":[]}'
}

# ─── combo auto ───────────────────────────────────────────────────────────────

tier_classify() {
    local model="$1"
    local lower
    lower="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"

    if echo "$lower" | grep -qE '^(claude|opus|sonnet|gpt-4|gpt-5|gemini-2\.[56]|o1|o3|k3\b)'; then
        echo 1; return
    fi
    if echo "$lower" | grep -qE '(flash|mini|haiku|deepseek|kimi|glm-4|glm-5|minimax|qwen-?2\.[56]|llama-?3\.|mistral|mixtral|command)'; then
        echo 2; return
    fi
    echo 3
}

model_rows() {
    local port key
    port="$(detect_port)"
    key="$(env_get OMNIROUTE_API_KEY)"
    [ -n "$key" ] || return 0
    curl -fsS --max-time 15 -H "Authorization: Bearer $key" "http://127.0.0.1:$port/v1/models" 2>/dev/null | jq -r '.data[].id // empty' 2>/dev/null || true
}

create_combo() {
    local name="$1" models_json="$2" port combos id payload
    port="$(detect_port)"
    [ "$(jq 'length' <<< "$models_json" 2>/dev/null || echo 0)" -gt 0 ] || return 0

    combos="$(api_request GET /api/combos 2>/dev/null || echo '{"combos":[]}')"
    id="$(jq -r --arg name "$name" '(.combos // .data // [])[] | select(.name==$name) | .id // empty' <<< "$combos" | head -1)"

    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    payload="$(pz_tempfile)"
    jq -n --arg name "$name" --argjson models "$models_json" '{name:$name,models:$models}' > "$payload"
    if [ -n "$id" ]; then
        api_request PUT "/api/combos/$id" "$payload" >/dev/null 2>&1 || true
    else
        api_request POST /api/combos "$payload" >/dev/null 2>&1 || true
    fi
    rm -f "$payload"
    pz_info "combo '$name' synced ($(jq 'length' <<< "$models_json") models)"
}

combo_auto() {
    local port key all_models tier1 tier2 tier3
    port="$(detect_port)"
    key="$(env_get OMNIROUTE_API_KEY)"
    [ -n "$key" ] || { pz_error "OmniRoute not configured yet"; return 1; }

    make_http "http://127.0.0.1:$port/api/health" "health check failed" || { pz_error "OmniRoute not healthy; start it first"; return 1; }

    all_models="$(model_rows)"
    [ -n "$all_models" ] || { pz_warn "no models found; connect a provider first"; return 0; }

    tier1="$(echo "$all_models" | while IFS= read -r m; do [ "$(tier_classify "$m")" = 1 ] && echo "$m"; done | jq -R -s 'split("\n") | map(select(length>0))')"
    tier2="$(echo "$all_models" | while IFS= read -r m; do [ "$(tier_classify "$m")" = 2 ] && echo "$m"; done | jq -R -s 'split("\n") | map(select(length>0))')"
    tier3="$(echo "$all_models" | while IFS= read -r m; do [ "$(tier_classify "$m")" = 3 ] && echo "$m"; done | jq -R -s 'split("\n") | map(select(length>0))')"

    local smart_models
    smart_models="$(jq -n --argjson t3 "$tier3" --argjson t2 "$tier2" --argjson t1 "$tier1" '$t3 + $t2 + $t1')"

    create_combo phasezero-free "$tier3"
    create_combo phasezero-smart "$smart_models"
    create_combo phasezero-max "$tier1"

    local active
    active="$(jq -r '.activeCombo // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
    [ -n "$active" ] || active="phasezero-smart"

    jq -cn \
        --argjson free "$(jq 'length' <<< "$tier3")" \
        --argjson smart "$(jq 'length' <<< "$smart_models")" \
        --argjson max "$(jq 'length' <<< "$tier1")" \
        --arg active "$active" \
        '{synced:true,combos:{free:$free,smart:$smart,max:$max},active:$active,routing:"ordered-fallback"}'
}

# ─── OpenCode integration ─────────────────────────────────────────────────────

opencode_has_plugin() {
    command -v npx >/dev/null 2>&1 && npx -y @omniroute/opencode-provider --version 2>/dev/null && return 0
    return 1
}

opencode_plugin_install() {
    pz_info "installing OmniRoute OpenCode plugin"
    local result
    result="$(npx -y @omniroute/opencode-provider setup 2>&1)" && {
        pz_info "OmniRoute OpenCode plugin installed"
        return 0
    }
    pz_warn "OmniRoute OpenCode plugin failed: $(echo "$result" | head -1)"
    return 1
}

opencode_custom_provider() {
    local port key
    port="$(detect_port)"
    key="$(env_get OMNIROUTE_API_KEY)"
    [ -n "$key" ] || { pz_warn "OmniRoute API key missing; cannot configure custom provider"; return 1; }

    local config_file=""
    [ -f "$OPENCODE_CONFIG" ] && config_file="$OPENCODE_CONFIG"
    [ -z "$config_file" ] && [ -f "$OPENCODE_CONFIG_JSON" ] && config_file="$OPENCODE_CONFIG_JSON"
    [ -n "$config_file" ] || config_file="$OPENCODE_CONFIG"

    mkdir -p "$(dirname "$config_file")"
    # shellcheck disable=SC2016 # literal "$schema" JSON key in generated config
    [ -f "$config_file" ] || printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "mcp": {}\n}\n' > "$config_file"
    pz_backup_file "$config_file" user >/dev/null

    local tmp
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    jq --arg key "$key" --arg port "$port" '
        .provider.omniroute = {
            name: "OmniRoute Smart Router",
            options: {
                baseURL: ("http://127.0.0.1:" + $port + "/v1"),
                apiKey: $key
            },
            models: ["auto", "phasezero-free", "phasezero-smart", "phasezero-max"]
        }
        | if (.model // "") == "" or (.model // "") == "ollama" then .model = "auto" else . end
    ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
    chmod 0644 "$config_file"

    pz_info "OpenCode custom provider configured (model: auto)"
}

opencode_integration() {
    if opencode_has_plugin; then
        opencode_plugin_install || opencode_custom_provider
    else
        opencode_custom_provider
    fi
    jq -cn '{opencodeConfigured:true,method:"plugin-or-custom"}'
}

# ─── doctor ───────────────────────────────────────────────────────────────────

doctor_omniroute() {
    local port installed=false service health=false env_mode="missing" data_mode="missing" timer
    port="$(detect_port)"
    [ -x "$(command -v omniroute 2>/dev/null || true)" ] || [ -f "$INSTALL_PREFIX/bin/omniroute" ] && installed=true
    service="$(service_state)"; service="${service:-inactive}"
    [ -e "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo missing)"
    [ -e "$DATA_DIR" ] && data_mode="$(stat -c %a "$DATA_DIR" 2>/dev/null || echo missing)"
    curl -fsS --max-time 2 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && health=true
    timer="$(systemctl --user is-enabled "$WATCH_TIMER" 2>/dev/null || echo disabled)"

    local problems=() next_actions=()
    $installed || { problems+=("not_installed"); next_actions+=("connection-grant-not-enforceable"); }
    [ "$service" = "active" ] || { problems+=("service_$service"); next_actions+=("connection-grant-not-enforceable"); }
    $health || { problems+=("unhealthy"); next_actions+=("connection-grant-not-enforceable"); }
    [ "$env_mode" = "600" ] || { problems+=("env_perms_$env_mode"); next_actions+=("chmod 600 $ENV_FILE"); }
    [ "$data_mode" = "700" ] || { problems+=("data_perms_$data_mode"); next_actions+=("chmod 700 $DATA_DIR"); }

    jq -cn --arg port "$port" --argjson installed "$installed" --arg service "$service" --argjson health "$health" \
        --arg envMode "$env_mode" --arg dataMode "$data_mode" --arg timer "$timer" \
        --argjson problems "$(printf '%s\n' "${problems[@]:-none}" | jq -R -s 'split("\n") | map(select(length>0 and .!="none"))')" \
        --argjson nextActions "$(printf '%s\n' "${next_actions[@]:-none}" | jq -R -s 'split("\n") | map(select(length>0 and .!="none"))')" \
        '{id:"omniroute",port:$port|tonumber,installed:$installed,service:$service,healthy:$health,
          permissions:{env:$envMode,data:$dataMode},
          timer:$timer,
          secure:($envMode=="600" and $dataMode=="700"),
          problems:$problems,
          nextActions:$nextActions,usageBlocked:true,blockedReason:"connection-grant-not-enforceable",
          secretsRedacted:true}'
}

# ─── dashboard ────────────────────────────────────────────────────────────────

dashboard() {
    local port
    port="$(detect_port)"
    command -v xdg-open >/dev/null 2>&1 || { pz_error "xdg-open missing"; return 1; }
    xdg-open "http://127.0.0.1:$port/dashboard" >/dev/null 2>&1 &
    pz_info "OmniRoute dashboard opened: http://127.0.0.1:$port/dashboard"
}

# ─── watchdog ─────────────────────────────────────────────────────────────────

watch_once() {
    local port
    port="$(detect_port)"
    curl -fsS --max-time 2 "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 || {
        jq -cn --arg at "$(date -Iseconds)" '{at:$at,service:"down"}' >> "$HEALTH_LOG"
        return 1
    }
    local providers usage_json
    providers="$(api_request GET /api/providers 2>/dev/null || echo '{"connections":[]}')"
    local total active degraded
    total="$(jq '[.connections // .providers // .data // . | .[]?] | length' <<< "$providers" 2>/dev/null || echo 0)"
    active="$(jq '[.connections // .providers // .data // . | .[]? | select((.isActive // true)==true)] | length' <<< "$providers" 2>/dev/null || echo 0)"
    degraded="$(jq '[.connections // .providers // .data // . | .[]? | select((.isActive // true)==true and ((.testStatus // "unknown") == "failed"))] | length' <<< "$providers" 2>/dev/null || echo 0)"
    usage_json="$(api_request GET /api/usage/stats 2>/dev/null | usage_summary || echo '{}')"
    jq -cn --arg at "$(date -Iseconds)" --argjson total "$total" --argjson active "$active" \
        --argjson degraded "$degraded" --argjson usage "$usage_json" \
        '{at:$at,service:"running",providers:{total:$total,active:$active,degraded:$degraded},usage:$usage}' >> "$HEALTH_LOG"
    tail -n 1008 "$HEALTH_LOG" > "$HEALTH_LOG.tmp" && mv "$HEALTH_LOG.tmp" "$HEALTH_LOG"
    chmod 0600 "$HEALTH_LOG"
}

# ─── usage ────────────────────────────────────────────────────────────────────

usage_json() {
    local usage
    usage="$(api_request GET /api/usage/stats | usage_summary)"
    printf '%s\n' "$usage" | jq '.'
    printf '%s\n' "$usage" | jq -c --arg at "$(date -Iseconds)" '{at:$at,sample:.}' >> "$USAGE_LOG"
    chmod 0600 "$USAGE_LOG"
}

# ─── check update ─────────────────────────────────────────────────────────────

check_update() {
    local current latest metadata
    current="$(installed_version)"
    metadata="$(npm view omniroute version --json 2>/dev/null || echo '""')"
    latest="$(jq -r '. // empty' <<< "$metadata")"
    jq -cn --arg current "$current" --arg latest "$latest" \
        '{id:"omniroute",installedVersion:$current,latestVersion:$latest,updateAvailable:($current!=$latest and $latest!="")}'
}

# ─── dispatch ─────────────────────────────────────────────────────────────────

case "$ACTION" in
    install|setup|start|restart|dashboard|open|update|upgrade|opencode|opencode-integration|integrate)
        connection_grant_blocked
        ;;
    provider)
        case "${1:-status}" in sync|sync-secrets) connection_grant_blocked ;; esac
        ;;
    combo)
        case "${1:-auto}" in auto|sync) connection_grant_blocked ;; esac
        ;;
    client)
        case "${1:-status}" in run) connection_grant_blocked ;; esac
        ;;
esac

case "$ACTION" in
    install|setup)
        install_omniroute
        ;;
    status)
        status_json
        ;;
    start)
        systemctl --user enable --now "$SERVICE"
        wait_ready 60
        ;;
    stop)
        systemctl --user disable --now "$SERVICE"
        ;;
    restart)
        systemctl --user restart "$SERVICE"
        wait_ready 60
        ;;
    test|health)
        test_omniroute
        ;;
    dashboard|open)
        dashboard
        ;;
    doctor)
        doctor_omniroute
        ;;
    provider)
        case "${1:-status}" in
            status|list) provider_status ;;
            sync|sync-secrets) provider_sync "${2:-}" ;;
            *) pz_error "usage: pz ai omniroute provider (status|sync)"; exit 2 ;;
        esac ;;
    combo)
        case "${1:-auto}" in
            auto|sync) combo_auto ;;
            list|status) api_request GET /api/combos | jq '{combos:(.combos // .data // .)}' ;;
            *) pz_error "usage: pz ai omniroute combo (auto|list)"; exit 2 ;;
        esac ;;
    opencode|opencode-integration|integrate)
        opencode_integration
        ;;
    usage|telemetry)
        usage_json
        ;;
    check-update|check)
        check_update
        ;;
    update|upgrade)
        ensure_dirs
        rm -f "$INSTALL_PREFIX/bin/omniroute" 2>/dev/null || true
        npm install -g --prefix "$INSTALL_PREFIX" omniroute@latest
        write_runtime_config
        systemctl --user daemon-reload
        systemctl --user restart "$SERVICE" || true
        wait_ready 60
        ensure_api_key
        jq -cn --arg version "$(installed_version)" '{status:"complete",version:$version}'
        ;;
    watch-once)
        watch_once
        ;;
    watchdog)
        case "${1:-status}" in
            install|enable) systemctl --user enable --now "$WATCH_TIMER" ;;
            remove|disable) systemctl --user disable --now "$WATCH_TIMER" ;;
            run|once) watch_once ;;
            status) systemctl --user status "$WATCH_TIMER" --no-pager ;;
            *) pz_error "usage: pz ai omniroute watchdog (status|install|remove|run)"; exit 2 ;;
        esac ;;
    client)
        case "${1:-status}" in
            status|env)
                jq -cn --arg wrapper "$CLIENT_WRAPPER" --arg port "$(detect_port)" \
                    '{ready:false,wrapper:$wrapper,endpoint:("http://127.0.0.1:"+$port+"/v1"),usageBlocked:true,blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
                ;;
            run) shift; [ "$#" -gt 0 ] || { pz_error "usage: pz ai omniroute client run <command> [args...]"; exit 2; }; exec "$CLIENT_WRAPPER" "$@" ;;
            *) pz_error "usage: pz ai omniroute client (status|run <command>)"; exit 2 ;;
        esac ;;
    *)
        cat <<EOF
PhaseZero OmniRoute Manager

Usage:
  pz ai omniroute install              Blocked until request-bound account grants exist
  pz ai omniroute status               JSON status
  pz ai omniroute stop                 Stop managed service
  pz ai omniroute start/restart        Blocked until request-bound account grants exist
  pz ai omniroute test                 Probe health/models only; chat inference blocked
  pz ai omniroute dashboard            Blocked; upstream dashboard can bypass grants
  pz ai omniroute doctor               Diagnostico de seguranca
  pz ai omniroute provider status      List providers
  pz ai omniroute provider sync        Blocked; importing secrets does not grant usage
  pz ai omniroute combo auto           Blocked; global fallback combos lack account binding
  pz ai omniroute combo list           List combos
  pz ai omniroute opencode             Blocked until request-bound account grants exist
  pz ai omniroute usage                Token/request telemetry
  pz ai omniroute update               Blocked until request-bound account grants exist
  pz ai omniroute check-update         Check npm for newer version
  pz ai omniroute watchdog status      Watchdog health
  pz ai omniroute watchdog install     Enable passive watchdog (10min timer)
  pz ai omniroute client run <cmd>     Blocked until request-bound account grants exist
EOF
        exit 0 ;;
esac
