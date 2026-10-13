#!/usr/bin/env bash
# PhaseZero-managed 9Router installer, health, routing and telemetry layer.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true

PROXY_ROOT="${PZ_AI_PROXY_ROOT:-$HOME/.local/share/phasezero/ai-proxies}"
INSTALL_ROOT="${PZ_9ROUTER_INSTALL_ROOT:-$PROXY_ROOT/9router}"
RUNTIME="$PROXY_ROOT/.runtime/node24"
# 9Router may run on a newer system Node; its PATH shim lives apart from the
# proxy suite shim ($RUNTIME/bin), whose native modules are built for Node 24.
ROUTER_BIN="$PROXY_ROOT/.runtime/9router-bin"
NODE_BIN="${PZ_9ROUTER_NODE_BIN:-$RUNTIME/node_modules/node/bin/node}"
NPM_CLI="${PZ_9ROUTER_NPM_CLI:-$RUNTIME/node_modules/npm/bin/npm-cli.js}"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/9router"
PROXY_ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies"
ENV_FILE="$PROXY_ENV_DIR/9router.env"
ENV_BACKUP_DIR="$PROXY_ENV_DIR/.9router-env-backups"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
DATA_DIR="${PZ_9ROUTER_DATA_DIR:-$HOME/.9router}"
STATE_DIR="$PZ_STATE/9router"
USAGE_LOG="$STATE_DIR/usage.log"
HEALTH_LOG="$STATE_DIR/health.log"
PORT="${PZ_9ROUTER_PORT:-20128}"
HOST="127.0.0.1"
BASE_URL="http://$HOST:$PORT"
SERVICE="phasezero-9router.service"
WATCH_SERVICE="phasezero-9router-watch.service"
WATCH_TIMER="phasezero-9router-watch.timer"
BRIDGE_SERVICE="phasezero-9router-unix-bridge.service"
PACKAGE_BIN="$INSTALL_ROOT/bin/9router"
PACKAGE_JSON="$INSTALL_ROOT/lib/node_modules/9router/package.json"
PACKAGE_ROOT="$INSTALL_ROOT/lib/node_modules/9router"
SERVER_RUNNER="$PZ_ROOT/linux/ai/9router-server-runner.js"
SERVER_WRAPPER="$LOCAL_BIN/phasezero-9router-server"
BACKUP_ROOT="$PROXY_ROOT/.9router-backups"
CLIENT_WRAPPER="$LOCAL_BIN/phasezero-9router-run"
DASHBOARD_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/phasezero-9router.desktop"

connection_grant_blocked() {
    jq -nc '{schemaVersion:1,ok:false,status:"blocked",
      blockedReason:"connection-grant-not-enforceable",
      summary:"Uso do 9Router bloqueado: não há vínculo de conta e consumidor aplicado por requisição.",
      next:"Aguarde adapter com grant por requisição e rejeição de fallback."}'
}

ensure_dirs() {
    install -d -m 700 "$CONFIG_DIR" "$PROXY_ENV_DIR" "$DATA_DIR" "$STATE_DIR"
    install -d "$LOCAL_BIN" "$SYSTEMD_USER_DIR" "$INSTALL_ROOT" "$BACKUP_ROOT"
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
    # Only real env names. A single-letter placeholder key is the signature of a
    # test or scratch call that escaped its sandbox onto the live file.
    [[ "$key" =~ ^[A-Z][A-Z0-9_]{2,}$ ]] || {
        pz_error "refusing to write malformed 9Router env key: $key"
        return 1
    }
    ensure_dirs
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    backup_env_file
    tmp="$(mktemp)"
    chmod 0600 "$tmp"
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    install -m 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

ensure_node_runtime() {
    local npm system_node system_npm_cli node_version node_major
    if [ -n "${PZ_9ROUTER_NODE_BIN:-}" ] && [ -x "$NODE_BIN" ] \
        && [ -n "${PZ_9ROUTER_NPM_CLI:-}" ] && [ -f "$NPM_CLI" ]; then
        install -d "$ROUTER_BIN"
        ln -sfn "$NODE_BIN" "$ROUTER_BIN/node"
        pz_debug "Using verified external Node.js runtime for 9Router"
        return 0
    fi
    npm="$(command -v npm || true)"
    [ -n "$npm" ] || { pz_error "npm required"; return 1; }
    system_node="$(command -v node || true)"
    if [ -n "$system_node" ]; then
        node_version="$("$system_node" --version 2>/dev/null || true)"
        node_major="${node_version#v}"
        node_major="${node_major%%.*}"
        system_npm_cli="$(readlink -f "$npm" 2>/dev/null || true)"
        if [[ "$node_major" =~ ^[0-9]+$ ]] && [ "$node_major" -ge 24 ] \
            && [ -f "$system_npm_cli" ]; then
            NODE_BIN="$system_node"
            NPM_CLI="$system_npm_cli"
            install -d "$ROUTER_BIN"
            ln -sfn "$NODE_BIN" "$ROUTER_BIN/node"
            pz_debug "Using existing Node.js $node_version for 9Router"
            return 0
        fi
    fi
    if [ ! -x "$NODE_BIN" ] || [ ! -f "$NPM_CLI" ]; then
        pz_info "Installing isolated Node.js 24 runtime for 9Router"
        install -d "$RUNTIME"
        "$npm" install --prefix "$RUNTIME" --no-save "node@24" "npm@10"
    fi
    install -d "$ROUTER_BIN"
    ln -sfn "$NODE_BIN" "$ROUTER_BIN/node"
}

# Keep a rotating 0600 copy of the env before every rewrite. This file holds the
# only copy of the server secrets and the client credential: a truncating write
# from any source (a stray env_upsert, a test pointed at the real $HOME) leaves
# no way back, takes the systemd EnvironmentFile with it, and drops the service
# to its defaults -- which binds 0.0.0.0:3000 instead of loopback.
backup_env_file() {
    local stamp
    [ -s "$ENV_FILE" ] || return 0
    install -d -m 0700 "$ENV_BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S)"
    install -m 0600 "$ENV_FILE" "$ENV_BACKUP_DIR/9router.env.$stamp"
    find "$ENV_BACKUP_DIR" -maxdepth 1 -name '9router.env.*' -type f -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f
}

env_file_is_complete() {
    local file="${1:-$ENV_FILE}" key
    [ -f "$file" ] || return 1
    for key in DATA_DIR PORT HOSTNAME BASE_URL JWT_SECRET API_KEY_SECRET; do
        grep -qE "^${key}=." "$file" || return 1
    done
}

write_runtime_config() {
    local initial_password jwt_secret api_secret machine_salt client_key tmp
    initial_password="$(env_get INITIAL_PASSWORD)"
    jwt_secret="$(env_get JWT_SECRET)"
    api_secret="$(env_get API_KEY_SECRET)"
    machine_salt="$(env_get MACHINE_ID_SALT)"
    # Carried, not regenerated: this is the credential every downstream client
    # reads (Hermes launchers, Claude Code, OpenCode, Odysseus). Dropping it here
    # used to break all of them on every install and update.
    client_key="$(env_get PHASEZERO_9ROUTER_API_KEY)"
    [ -n "$initial_password" ] || initial_password="pz-$(random_hex 18)"
    [ -n "$jwt_secret" ] || jwt_secret="$(random_hex 32)"
    [ -n "$api_secret" ] || api_secret="$(random_hex 32)"
    [ -n "$machine_salt" ] || machine_salt="$(random_hex 24)"
    backup_env_file
    # Staged write: a partial or failed write must not truncate the live file the
    # service reads at boot.
    tmp="$(mktemp)"
    chmod 0600 "$tmp"
    cat > "$tmp" <<EOF
DATA_DIR=$DATA_DIR
PORT=$PORT
HOSTNAME=$HOST
BASE_URL=$BASE_URL
NEXT_PUBLIC_BASE_URL=$BASE_URL
NODE_ENV=production
INITIAL_PASSWORD=$initial_password
JWT_SECRET=$jwt_secret
API_KEY_SECRET=$api_secret
MACHINE_ID_SALT=$machine_salt
REQUIRE_API_KEY=true
ENABLE_REQUEST_LOGS=false
AUTH_COOKIE_SECURE=false
EOF
    [ -z "$client_key" ] || printf 'PHASEZERO_9ROUTER_API_KEY=%s\n' "$client_key" >> "$tmp"
    if ! env_file_is_complete "$tmp"; then
        rm -f "$tmp"
        pz_error "refusing to install incomplete 9Router environment"
        return 1
    fi
    install -m 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"

    local active_model
    active_model="$(jq -r '.activeCombo // .model // "Default"' "$SETTINGS_FILE" 2>/dev/null || echo Default)"
    jq -n --arg endpoint "$BASE_URL/v1" --arg dashboard "$BASE_URL/dashboard" \
        --arg model "$active_model" --arg env "$ENV_FILE" \
        '{schemaVersion:1,baseUrl:$endpoint,dashboardUrl:$dashboard,apiKeyEnv:"PHASEZERO_9ROUTER_API_KEY",model:$model,activeCombo:$model,managedEnv:$env}' \
        > "$SETTINGS_FILE"
    chmod 0600 "$SETTINGS_FILE"
}

write_wrapper_and_units() {
    local managed_pz="${PZ_9ROUTER_MANAGED_PZ:-$PZ_ROOT/linux/pz}"
    if [ -z "${PZ_9ROUTER_MANAGED_PZ:-}" ] && [ -x /usr/lib/phasezero/linux/pz ]; then
        managed_pz=/usr/lib/phasezero/linux/pz
    fi
    pz_write_managed_file "$LOCAL_BIN/9router" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-} \${2:-}" in
  "xai video") exec "$PACKAGE_BIN" "\$@" ;;
esac
exec "$managed_pz" ai 9router tui "\$@"
EOF
    chmod +x "$LOCAL_BIN/9router"

    # Fail closed on a damaged EnvironmentFile. systemd tolerates missing keys,
    # and the upstream server then falls back to its own defaults -- which listen
    # on 0.0.0.0:3000. Refusing to boot is the safe outcome: a dead loopback
    # gateway is visible and repairable, a wildcard-bound one is neither.
    pz_write_managed_file "$SERVER_WRAPPER" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${HOSTNAME:-}" != "$HOST" ] || [ "\${PORT:-}" != "$PORT" ]; then
  echo "9Router refusing to start: managed environment missing or altered (expected $HOST:$PORT, got \${HOSTNAME:-unset}:\${PORT:-unset})" >&2
  echo "repair with: pz ai 9router repair" >&2
  exit 78
fi
export PATH="$ROUTER_BIN:\$PATH"
exec "$NODE_BIN" "$SERVER_RUNNER" "$PACKAGE_ROOT"
EOF
    chmod 0700 "$SERVER_WRAPPER"

    pz_write_managed_file "$CLIENT_WRAPPER" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
jq -nc '{ok:false,status:"blocked",blockedReason:"connection-grant-not-enforceable",summary:"9Router client launch blocked until per-request grants are enforced."}'
exit 69
EOF
    chmod 0700 "$CLIENT_WRAPPER"

    install -d "$(dirname "$DASHBOARD_ENTRY")"
    pz_write_managed_file "$DASHBOARD_ENTRY" user <<EOF
[Desktop Entry]
Type=Application
Name=9Router dashboard (uso bloqueado)
Comment=Bloqueado: testes de provider podem consumir cota sem grant por requisição.
Exec=$managed_pz ai 9router dashboard
Icon=applications-science
Terminal=true
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
Description=PhaseZero 9Router AI routing gateway
After=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$SERVER_WRAPPER
Restart=on-failure
RestartSec=5
WorkingDirectory=$INSTALL_ROOT
KillMode=mixed

[Install]
WantedBy=default.target
EOF

    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCH_SERVICE" user <<EOF
[Unit]
Description=PhaseZero 9Router provider health and telemetry sample
After=$SERVICE

[Service]
Type=oneshot
ExecStart=$managed_pz ai 9router watch-once
EOF

    pz_write_managed_file "$SYSTEMD_USER_DIR/$WATCH_TIMER" user <<EOF
[Unit]
Description=Sample passive 9Router health every ten minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min
Unit=$WATCH_SERVICE

[Install]
WantedBy=timers.target
EOF

    pz_write_managed_file "$SYSTEMD_USER_DIR/$BRIDGE_SERVICE" user <<EOF
[Unit]
Description=PhaseZero private Unix bridge for container access to 9Router
After=$SERVICE
Requires=$SERVICE
PartOf=$SERVICE

[Service]
Type=simple
RuntimeDirectory=phasezero
RuntimeDirectoryMode=0700
ExecStart=/usr/sbin/socat UNIX-LISTEN:%t/phasezero/9router.sock,fork,mode=0600 TCP:127.0.0.1:$PORT
# socat exits 143 on SIGTERM. Without this, every ordinary stop -- including the
# one an update performs -- leaves the unit in "failed" and it never comes back.
SuccessExitStatus=143
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

ensure_attached_service() {
    if [ "$(service_state)" != active ]; then
        systemctl --user start "$SERVICE"
    fi
    wait_ready 60
}

tui_show() {
    local title="$1" body="$2"
    if command -v whiptail >/dev/null 2>&1 && [ -t 1 ]; then
        whiptail --title "$title" --scrolltext --msgbox "$body" 24 90
    else
        printf '\n=== %s ===\n%s\n' "$title" "$body"
    fi
}

tui_9router() {
    ensure_attached_service || return 1
    if [ ! -t 0 ] || [ ! -t 1 ] || ! command -v whiptail >/dev/null 2>&1; then
        status_json
        return 0
    fi
    local choice body
    while :; do
        choice="$(whiptail --title "9Router — PhaseZero" \
            --menu "Attach seguro ao serviço ativo. Chaves sempre ocultas." 22 82 10 \
            status "Saúde, listener e watchdog" \
            providers "Providers ativos" \
            combos "Combos e fallback" \
            usage "Uso agregado" \
            dashboard "Abrir dashboard local" \
            exit "Sair sem parar o serviço" \
            3>&1 1>&2 2>&3)" || choice="exit"
        case "$choice" in
            status)
                body="$(status_json | jq 'del(.settingsPath,.healthLog)')"
                tui_show "Status 9Router" "$body"
                ;;
            providers)
                body="$(provider_status | jq 'walk(if type == "object" then del(.apiKey,.key,.secret,.token,.authorization) else . end)')"
                tui_show "Providers" "$body"
                ;;
            combos)
                body="$(combo_list | jq 'walk(if type == "object" then del(.apiKey,.key,.secret,.token,.authorization) else . end)')"
                tui_show "Combos" "$body"
                ;;
            usage)
                body="$(api_request GET /api/usage/stats | usage_summary)"
                tui_show "Uso agregado" "$body"
                ;;
            dashboard) dashboard ;;
            exit|"") return 0 ;;
        esac
    done
}

# Recover a truncated or partially written env without a package reinstall.
# Prefer the newest complete backup: it keeps the original server secrets, so
# existing API keys and dashboard credentials survive. Regenerating is the last
# resort and is announced, because it invalidates issued keys.
ensure_env_file() {
    local candidate
    # Snapshot while it is still good: a backup taken only on write would not
    # exist yet the first time something truncates the file.
    if env_file_is_complete; then
        backup_env_file
        return 0
    fi
    pz_warn "9Router environment is incomplete: $ENV_FILE"
    while read -r candidate; do
        [ -n "$candidate" ] || continue
        env_file_is_complete "$candidate" || continue
        install -m 0600 "$candidate" "$ENV_FILE"
        pz_info "restored 9Router environment from $(basename "$candidate")"
        return 0
    done < <(find "$ENV_BACKUP_DIR" -maxdepth 1 -name '9router.env.*' -type f -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | cut -d' ' -f2-)
    pz_warn "no usable 9Router environment backup; regenerating server secrets (issued API keys will stop working)"
    write_runtime_config
}

repair_9router() {
    ensure_dirs
    [ -x "$PACKAGE_BIN" ] || { pz_error "9Router package missing; run install first"; return 1; }
    [ -f "$SERVER_RUNNER" ] || { pz_error "PhaseZero 9Router server runner missing"; return 1; }
    # The generated systemd wrapper embeds NODE_BIN.  Resolve the managed or
    # system runtime before rewriting it; otherwise a removed isolated runtime
    # produces a permanent 127 restart loop.
    ensure_node_runtime
    if [ -n "$(listener_pid)" ] && ! service_owns_listener; then
        pz_error "port $PORT is owned by a non-PhaseZero process; refusing to kill it"
        return 1
    fi
    ensure_env_file
    write_wrapper_and_units
    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE" "$BRIDGE_SERVICE" "$WATCH_TIMER" >/dev/null
    systemctl --user restart "$SERVICE"
    systemctl --user restart "$BRIDGE_SERVICE"
    systemctl --user start "$WATCH_TIMER"
    wait_ready 90
    # oneshot start must succeed; systemd returns non-zero for 203/EXEC and
    # proves the migrated stable ExecStart path is executable now.
    systemctl --user start "$WATCH_SERVICE"
    ensure_api_key
    status_json
}

registry_metadata() {
    ensure_node_runtime
    # npm >= 10 wraps multi-field `view` output in an array; older npm emits a
    # bare object.  Normalize to an object so callers can index fields directly.
    PATH="$ROUTER_BIN:$PATH" "$NODE_BIN" "$NPM_CLI" view 9router version dist.integrity dist.shasum --json \
        | jq -c 'if type == "array" then (.[0] // {}) else . end'
}

installed_version() {
    jq -r '.version // empty' "$PACKAGE_JSON" 2>/dev/null || true
}

install_verified_package() (
    local metadata version expected_integrity work pack_json tarball stage backup was_active=false
    metadata="$(registry_metadata)"
    version="$(jq -r '.version // empty' <<< "$metadata")"
    expected_integrity="$(jq -r '."dist.integrity" // empty' <<< "$metadata")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { pz_error "invalid npm version metadata"; return 1; }
    [ -n "$expected_integrity" ] || { pz_error "npm registry did not publish package integrity"; return 1; }
    work="$(mktemp -d)"
    stage="$PROXY_ROOT/.9router-stage.$$"
    trap 'rm -rf "${work:-}" "${stage:-}"' EXIT
    pack_json="$(PATH="$ROUTER_BIN:$PATH" "$NODE_BIN" "$NPM_CLI" pack "9router@$version" --pack-destination "$work" --json)"
    [ "$(jq -r '.[0].integrity // empty' <<< "$pack_json")" = "$expected_integrity" ] || {
        pz_error "9Router npm integrity mismatch"
        return 1
    }
    tarball="$work/$(jq -r '.[0].filename' <<< "$pack_json")"
    [ -f "$tarball" ] || { pz_error "9Router package archive missing"; return 1; }
    install -d "$stage"
    PATH="$ROUTER_BIN:$PATH" "$NODE_BIN" "$NPM_CLI" install -g --prefix "$stage" --ignore-scripts "$tarball"
    [ -x "$stage/bin/9router" ] || { pz_error "9Router staged binary missing"; return 1; }
    [ "$(jq -r '.version // empty' "$stage/lib/node_modules/9router/package.json")" = "$version" ] || {
        pz_error "9Router staged version mismatch"
        return 1
    }
    [ "$(service_state)" = active ] && was_active=true
    if $was_active; then
        systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
    fi
    backup="$BACKUP_ROOT/$(installed_version)-$(date +%Y%m%d-%H%M%S)"
    if [ -e "$INSTALL_ROOT" ]; then mv "$INSTALL_ROOT" "$backup"; fi
    if ! mv "$stage" "$INSTALL_ROOT"; then
        [ -e "$backup" ] && mv "$backup" "$INSTALL_ROOT"
        return 1
    fi
    write_runtime_config
    write_wrapper_and_units
    systemctl --user daemon-reload
    if $was_active || [ "$ACTION" = install ] || [ "$ACTION" = setup ]; then
        if ! systemctl --user enable --now "$SERVICE" || ! wait_ready 90; then
            systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
            rm -rf "$INSTALL_ROOT"
            [ -e "$backup" ] && mv "$backup" "$INSTALL_ROOT"
            systemctl --user daemon-reload
            if $was_active; then
                systemctl --user start "$SERVICE" >/dev/null 2>&1 || true
            fi
            pz_error "9Router update failed health check; rollback applied"
            return 1
        fi
        # PartOf propagates the stop above to the bridge but never the start
        # back, so an update would otherwise leave containers with no socket.
        systemctl --user reset-failed "$BRIDGE_SERVICE" >/dev/null 2>&1 || true
        systemctl --user start "$BRIDGE_SERVICE" >/dev/null 2>&1 || true
    fi
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | awk 'NR>2 {$1=""; sub(/^ /,""); print}' | xargs -r rm -rf --
    jq -cn --arg version "$version" --arg integrity "$expected_integrity" \
        '{status:"complete",version:$version,integrityVerified:true,integrity:$integrity}'
)

install_9router() {
    command -v jq >/dev/null || { pz_error "jq required"; return 1; }
    [ -x /usr/sbin/socat ] || { pz_error "socat required for private container bridge"; return 1; }
    ensure_dirs
    ensure_node_runtime
    pz_info "Installing exact 9Router package after npm integrity verification"
    install_verified_package
    [ -x "$PACKAGE_BIN" ] || { pz_error "9Router package binary missing after install"; return 1; }
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        systemctl --user enable --now "$SERVICE"
        systemctl --user enable --now "$BRIDGE_SERVICE"
        systemctl --user enable --now "$WATCH_TIMER" >/dev/null 2>&1 || pz_warn "9Router watchdog timer could not be enabled"
    elif command -v pm2 >/dev/null 2>&1; then
        pm2 delete phasezero-9router >/dev/null 2>&1 || true
        pm2 start "$LOCAL_BIN/9router" --name phasezero-9router
        pm2 save
    else
        pz_error "systemd user unavailable and pm2 missing"
        return 1
    fi
    wait_ready 90
    ensure_api_key
    pz_info "9Router installed: $BASE_URL/dashboard"
}

wait_ready() {
    local timeout="${1:-30}" i
    for ((i = 0; i < timeout; i++)); do
        if curl -fsS --max-time 2 "$BASE_URL/api/health" >/dev/null 2>&1 \
            && service_owns_listener && listener_is_loopback; then
            return 0
        fi
        sleep 1
    done
    pz_error "9Router did not become healthy within ${timeout}s"
    systemctl --user status "$SERVICE" --no-pager >&2 2>/dev/null || true
    return 1
}

listener_row() {
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltnp "sport = :$PORT" 2>/dev/null | head -1
}

listener_pid() {
    listener_row | sed -nE 's/.*pid=([0-9]+).*/\1/p'
}

listener_address() {
    listener_row | awk 'NR == 1 {print $4}'
}

listener_is_loopback() {
    local address
    address="$(listener_address)"
    case "$address" in
        127.0.0.1:*|'[::1]':*) return 0 ;;
        *) return 1 ;;
    esac
}

pid_descends_from() {
    local pid="$1" ancestor="$2" parent steps=0
    [ -n "$pid" ] && [ -n "$ancestor" ] && [ "$ancestor" -gt 0 ] 2>/dev/null || return 1
    while [ "$pid" -gt 1 ] 2>/dev/null && [ "$steps" -lt 32 ]; do
        [ "$pid" = "$ancestor" ] && return 0
        parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        [ -n "$parent" ] || return 1
        pid="$parent"
        steps=$((steps + 1))
    done
    return 1
}

service_owns_listener() {
    local pid main
    [ "$(service_state)" = active ] || return 1
    pid="$(listener_pid)"
    main="$(systemctl --user show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
    pid_descends_from "$pid" "$main"
}

cli_token() {
    local machine secret
    [ -s "$DATA_DIR/machine-id" ] && [ -s "$DATA_DIR/auth/cli-secret" ] || return 1
    machine="$(tr -d '\r\n' < "$DATA_DIR/machine-id")"
    secret="$(tr -d '\r\n' < "$DATA_DIR/auth/cli-secret")"
    printf '%s' "${machine}9r-cli-auth${secret}" | sha256sum | cut -c1-16
}

api_request() {
    local method="$1" path="$2" data_file="${3:-}" max_time="${4:-8}" token args
    token="$(cli_token)" || { pz_error "9Router CLI authentication unavailable"; return 1; }
    args=(-fsS --max-time "$max_time" -X "$method" -H "x-9r-cli-token: $token" -H 'Content-Type: application/json')
    [ -z "$data_file" ] || args+=(--data-binary "@$data_file")
    curl "${args[@]}" "$BASE_URL$path"
}

ensure_api_key() {
    local key response payload
    key="$(env_get PHASEZERO_9ROUTER_API_KEY)"
    if [ -z "$key" ]; then
        payload="$(mktemp)"
        printf '{"name":"PhaseZero managed client"}\n' > "$payload"
        response="$(api_request POST /api/keys "$payload")"
        rm -f "$payload"
        key="$(jq -r '.key // .apiKey // .data.key // empty' <<< "$response")"
        [ -n "$key" ] || { pz_error "9Router API key creation failed"; return 1; }
        env_upsert PHASEZERO_9ROUTER_API_KEY "$key"
        systemctl --user restart "$SERVICE" >/dev/null 2>&1 || true
        wait_ready 30
    fi
}

service_state() {
    if systemctl --user list-unit-files "$SERVICE" >/dev/null 2>&1; then
        systemctl --user is-active "$SERVICE" 2>/dev/null || true
    elif command -v pm2 >/dev/null 2>&1 && pm2 describe phasezero-9router >/dev/null 2>&1; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
}

status_json() {
    local installed=false service version="" health=false owner=false loopback=false providers='{"connections":[]}' combos='{"combos":[]}' usage='{}' address pid
    [ -x "$PACKAGE_BIN" ] && installed=true
    service="$(service_state)"; service="${service:-inactive}"
    if $installed; then version="$(installed_version)"; fi
    service_owns_listener && owner=true
    listener_is_loopback && loopback=true
    address="$(listener_address)"
    pid="$(listener_pid)"
    if $installed && $owner && $loopback && curl -fsS --max-time 2 "$BASE_URL/api/health" >/dev/null 2>&1; then
        health=true
        providers="$(api_request GET /api/providers 2>/dev/null || echo '{"connections":[]}')"
        combos="$(api_request GET /api/combos 2>/dev/null || echo '{"combos":[]}')"
        usage="$(api_request GET /api/usage/stats 2>/dev/null | usage_summary || echo '{}')"
    fi
    jq -cn --arg version "$version" --arg service "$service" --arg endpoint "$BASE_URL/v1" \
        --arg dashboard "$BASE_URL/dashboard" --arg settings "$SETTINGS_FILE" \
        --arg healthLog "$HEALTH_LOG" --arg listenerAddress "$address" --arg listenerPid "$pid" \
        --argjson installed "$installed" --argjson health "$health" \
        --argjson owner "$owner" --argjson loopback "$loopback" \
        --argjson providers "$providers" --argjson combos "$combos" --argjson usage "$usage" \
        '{schemaVersion:1,id:"9router",installed:$installed,version:$version,service:$service,healthy:$health,
          endpoint:$endpoint,dashboard:$dashboard,settingsPath:$settings,
          listener:{address:$listenerAddress,pid:($listenerPid|tonumber? // null),ownedByService:$owner,loopbackOnly:$loopback},
          providers:{total:(($providers.connections // $providers.providers // [])|length),active:(($providers.connections // $providers.providers // [])|map(select((.isActive // true)==true))|length)},
          combos:{total:(($combos.combos // $combos.data // [])|length),names:(($combos.combos // $combos.data // [])|map(.name))},
          usage:$usage,
          watchdog:{enabled:false,log:$healthLog},
          nextAction:(if ($installed|not) then "linux/pz ai 9router install" elif ($health|not) then "linux/pz ai 9router start" elif (($providers.connections // [])|length)==0 then "Abra o dashboard e conecte um provider" else "Uso por cliente bloqueado até grant por requisição" end)}' \
        | jq --argjson enabled "$(systemctl --user is-enabled "$WATCH_TIMER" >/dev/null 2>&1 && echo true || echo false)" '.watchdog.enabled=$enabled'
}

usage_summary() {
    sanitize_usage | jq '{
      totalRequests:(.totalRequests // 0),
      totalPromptTokens:(.totalPromptTokens // 0),
      totalCompletionTokens:(.totalCompletionTokens // 0),
      totalCachedTokens:(.totalCachedTokens // 0),
      totalCost:(.totalCost // 0),
      providerCount:((.byProvider // {}) | length),
      modelCount:((.byModel // {}) | length),
      activeRequestCount:((.activeRequests // []) | length)
    }'
}

test_9router() {
    local key body code models_ok=false health_ok=false provider_count=0
    curl -fsS --max-time 3 "$BASE_URL/api/health" >/dev/null 2>&1 && health_ok=true
    key="$(env_get PHASEZERO_9ROUTER_API_KEY)"
    body="$(curl -sS --max-time 10 -H "Authorization: Bearer $key" "$BASE_URL/v1/models" 2>/dev/null || true)"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $key" "$BASE_URL/v1/models" 2>/dev/null || true)"
    jq -e '(.data // []) | type == "array"' <<< "$body" >/dev/null 2>&1 && [ "$code" = 200 ] && models_ok=true
    provider_count="$(api_request GET /api/providers 2>/dev/null | jq '(.connections // .providers // []) | map(select((.isActive // true)==true)) | length' 2>/dev/null || echo 0)"
    jq -cn --arg endpoint "$BASE_URL/v1" --arg httpCode "$code" --argjson health "$health_ok" \
        --argjson providers "$provider_count" \
        --argjson models "$models_ok" --argjson count "$(jq '(.data // []) | length' <<< "$body" 2>/dev/null || echo 0)" \
        '{id:"9router",endpoint:$endpoint,health:$health,modelsEndpoint:$models,httpCode:$httpCode,
          modelCount:$count,providerCount:$providers,chat:"blocked",
          blockedReason:"connection-grant-not-enforceable"}'
    $health_ok && $models_ok
}

provider_status() {
    api_request GET /api/providers | jq '{connections:(.connections // .providers // [])|map({id,provider:(.provider // .providerId),name:(.name // .displayName // .email // ""),active:(.isActive // true),status:(.testStatus // "unknown")})}'
}

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

# shellcheck disable=SC2317
# PXA-008 keeps legacy provider writes unreachable until request-bound grants exist.
sync_secrets() {
    connection_grant_blocked
    return 69
    local manifest provider secret name payload response imported=0 skipped=0
    manifest="${1:-}"
    [ -n "$manifest" ] || manifest="$(find_secrets_manifest || true)"
    [ -f "$manifest" ] || { pz_warn "bootstrap-secrets.json not found; provider import skipped"; return 0; }
    while IFS=$'\t' read -r provider name secret; do
        case "$provider" in openai|anthropic|gemini|openrouter|glm|kimi|minimax) ;; *) skipped=$((skipped + 1)); continue ;; esac
        [ -n "$secret" ] || { skipped=$((skipped + 1)); continue; }
        payload="$(mktemp)"
        jq -n --arg provider "$provider" --arg name "${name:-PhaseZero $provider}" --arg apiKey "$secret" \
            '{provider:$provider,name:$name,apiKey:$apiKey}' > "$payload"
        if response="$(api_request POST /api/providers "$payload" 2>/dev/null)" && jq -e '(.error // empty) == ""' <<< "$response" >/dev/null; then
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
    ' "$manifest")
    jq -cn --arg manifest "$manifest" --argjson imported "$imported" --argjson skipped "$skipped" \
        '{manifest:$manifest,imported:$imported,skipped:$skipped,secretsRedacted:true}'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
provider_remove() {
    connection_grant_blocked
    return 69
    local id="${1:-}"
    [ -n "$id" ] || { pz_error "usage: pz ai 9router provider remove <connection-id>"; return 2; }
    api_request DELETE "/api/providers/$id" | jq 'del(.apiKey,.secret,.token)'
}

model_rows() {
    local key available
    key="$(env_get PHASEZERO_9ROUTER_API_KEY)"
    available="$(curl -fsS --max-time 15 -H "Authorization: Bearer $key" "$BASE_URL/v1/models" 2>/dev/null || echo '{"data":[]}')"
    jq -r '(.data // [])[] | (.id // empty) | select(startswith("phasezero-")|not)' <<< "$available" | awk 'NF && !seen[$0]++'
}

tier_models_json() {
    local tier="$1"
    model_rows | awk -v tier="$tier" '
      BEGIN { IGNORECASE=1 }
      {
        free=($0 ~ /(^kr\/|^opencode\/|^mmf\/|[-/]free($|-))/)
        cheap=($0 ~ /(flash|mini|haiku)/)
        premium=($0 ~ /(opus|pro|max|o1|gpt-5)/)
        if (tier=="free" && free) print "0|" $0
        else if (tier=="smart" && free) print "0|" $0
        else if (tier=="smart" && cheap) print "1|" $0
        else if (tier=="smart" && !premium) print "2|" $0
        else if (tier=="max" && premium) print "0|" $0
      }' | sort -t'|' -k1,1n | awk -F'|' 'emitted < 6 {sub(/^[^|]*\|/, ""); print; emitted++}' \
      | jq -R -s 'split("\n") | map(select(length>0))'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
upsert_combo() {
    connection_grant_blocked
    return 69
    local name="$1" models="$2" combos id payload
    [ "$(jq 'length' <<< "$models")" -gt 0 ] || return 0
    combos="$(api_request GET /api/combos)"
    id="$(jq -r --arg name "$name" '(.combos // .data // [])[] | select(.name==$name) | .id' <<< "$combos" | head -1)"
    payload="$(mktemp)"
    jq -n --arg name "$name" --argjson models "$models" '{name:$name,models:$models}' > "$payload"
    if [ -n "$id" ]; then api_request PUT "/api/combos/$id" "$payload" >/dev/null
    else api_request POST /api/combos "$payload" >/dev/null
    fi
    rm -f "$payload"
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
combo_sync() {
    connection_grant_blocked
    return 69
    local free smart max
    free="$(tier_models_json free)"; smart="$(tier_models_json smart)"; max="$(tier_models_json max)"
    upsert_combo phasezero-free "$free"
    upsert_combo phasezero-smart "$smart"
    upsert_combo phasezero-max "$max"
    jq -cn --argjson free "$free" --argjson smart "$smart" --argjson max "$max" \
        '{synced:true,combos:{"phasezero-free":$free,"phasezero-smart":$smart,"phasezero-max":$max},routing:"ordered-fallback",costPolicy:"free-first then budget then premium"}'
}

combo_list() {
    api_request GET /api/combos | jq '{combos:(.combos // .data // [])|map({id,name,models})}'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
combo_create() {
    connection_grant_blocked
    return 69
    local name="${1:-}" csv="${2:-}" models payload
    if [ -z "$name" ] || [ -z "$csv" ]; then
        pz_error "usage: pz ai 9router combo create <name> <model1,model2>"
        return 2
    fi
    models="$(printf '%s' "$csv" | jq -R 'split(",") | map(select(length>0))')"
    payload="$(mktemp)"; jq -n --arg name "$name" --argjson models "$models" '{name:$name,models:$models}' > "$payload"
    api_request POST /api/combos "$payload" | jq 'del(.apiKey,.secret,.token)'
    rm -f "$payload"
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
combo_switch() {
    connection_grant_blocked
    return 69
    local name="${1:-}" tmp
    [ -n "$name" ] || { pz_error "usage: pz ai 9router combo switch <name>"; return 2; }
    combo_list | jq -e --arg name "$name" '.combos[] | select(.name==$name)' >/dev/null || { pz_error "combo not found: $name"; return 1; }
    tmp="$(mktemp)"
    jq --arg name "$name" '.model=$name | .activeCombo=$name' "$SETTINGS_FILE" > "$tmp"
    install -m 0600 "$tmp" "$SETTINGS_FILE"; rm -f "$tmp"
    jq -cn --arg combo "$name" --arg settings "$SETTINGS_FILE" '{activeCombo:$combo,settings:$settings}'
}

# shellcheck disable=SC2317
# PXA-008 retains this handler behind its request-bound grant gate.
ensure_active_combo() {
    connection_grant_blocked
    return 69
    local combo_json current selected
    combo_json="$(combo_list)"
    current="$(jq -r '.activeCombo // .model // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
    if [ -n "$current" ] && printf '%s' "$combo_json" | jq -e --arg name "$current" '.combos[] | select(.name==$name)' >/dev/null; then
        return 0
    fi
    selected="$(printf '%s' "$combo_json" | jq -r '
        [.combos[]?.name] as $names
        | (($names | map(select(test("claude"; "i"))) | .[0])
           // (if ($names | index("Default")) then "Default" else $names[0] end)
           // empty)
    ')"
    [ -n "$selected" ] || { pz_error "9Router has no combo available for Claude"; return 1; }
    combo_switch "$selected" >/dev/null
    pz_info "9Router Claude combo selected: $selected"
}

usage_json() {
    local usage
    usage="$(api_request GET /api/usage/stats | usage_summary)"
    printf '%s\n' "$usage" | jq '.'
    printf '%s\n' "$usage" | jq -c --arg at "$(date -Iseconds)" '{at:$at,sample:.}' >> "$USAGE_LOG"
    chmod 0600 "$USAGE_LOG"
}

sanitize_usage() {
    jq '
      .apiKeyCount = ((.byApiKey // {}) | length)
      | del(.byApiKey)
      | walk(if type == "object" then del(.apiKey,.secret,.token,.authorization) else . end)
    '
}

watch_once() {
    local providers total=0 active=0 degraded=0 usage
    curl -fsS --max-time 2 "$BASE_URL/api/health" >/dev/null 2>&1 || {
        jq -cn --arg at "$(date -Iseconds)" '{at:$at,service:"down",providers:{total:0,healthy:0,failed:0}}' >> "$HEALTH_LOG"
        return 1
    }
    providers="$(api_request GET /api/providers)"
    total="$(jq '(.connections // .providers // []) | length' <<< "$providers")"
    active="$(jq '(.connections // .providers // []) | map(select((.isActive // true)==true)) | length' <<< "$providers")"
    degraded="$(jq '(.connections // .providers // []) | map(select((.isActive // true)==true and ((.testStatus // "unknown") == "failed"))) | length' <<< "$providers")"
    usage="$(api_request GET /api/usage/stats 2>/dev/null | usage_summary || echo '{}')"
    jq -cn --arg at "$(date -Iseconds)" --argjson total "$total" --argjson active "$active" --argjson degraded "$degraded" \
        --argjson usage "$usage" '{at:$at,service:"running",providers:{total:$total,active:$active,degraded:$degraded},usage:$usage}' >> "$HEALTH_LOG"
    tail -n 1008 "$HEALTH_LOG" > "$HEALTH_LOG.tmp" && mv "$HEALTH_LOG.tmp" "$HEALTH_LOG"
    chmod 0600 "$HEALTH_LOG"
}

check_update() {
    local metadata current latest
    metadata="$(registry_metadata)"
    current="$(installed_version)"
    latest="$(jq -r '.version // empty' <<< "$metadata")"
    jq -cn --arg current "$current" --arg latest "$latest" \
        --arg integrity "$(jq -r '."dist.integrity" // empty' <<< "$metadata")" \
        '{id:"9router",installedVersion:$current,latestVersion:$latest,updateAvailable:($current!=$latest),integrityPublished:($integrity!="")}'
}

rollback_package() {
    local backup current
    # failed-* é evidência de falha, não backup restaurável: sem o filtro, o
    # rollback manual mais novo que o auto-rollback reinstalava a versão ruim.
    backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name 'failed-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
    [ -n "$backup" ] || { pz_error "no 9Router rollback available"; return 1; }
    systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
    current="$BACKUP_ROOT/failed-$(installed_version)-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_ROOT" "$current"
    mv "$backup" "$INSTALL_ROOT"
    systemctl --user daemon-reload
    systemctl --user start "$SERVICE"
    wait_ready 90
    jq -cn --arg version "$(installed_version)" '{status:"complete",rolledBackTo:$version}'
}

client_status() {
    jq -cn --arg wrapper "$CLIENT_WRAPPER" --arg endpoint "$BASE_URL/v1" --arg model "$(jq -r '.model // "phasezero-smart"' "$SETTINGS_FILE" 2>/dev/null || echo phasezero-smart)" \
        --argjson ready false \
        '{ready:$ready,wrapper:$wrapper,endpoint:$endpoint,model:$model,usage:"blocked until per-request connection grants are enforced",blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
}

doctor_9router() {
    local package=false env_mode="missing" data_mode="missing" service health=false owner=false loopback=false timer bridge=false
    [ -x "$PACKAGE_BIN" ] && package=true
    [ -e "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE")"
    [ -e "$DATA_DIR" ] && data_mode="$(stat -c %a "$DATA_DIR")"
    service="$(service_state)"; service="${service:-inactive}"
    service_owns_listener && owner=true
    listener_is_loopback && loopback=true
    if $package && $owner && $loopback && curl -fsS --max-time 2 "$BASE_URL/api/health" >/dev/null 2>&1; then health=true; fi
    timer="$(systemctl --user is-enabled "$WATCH_TIMER" 2>/dev/null || true)"
    [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero/9router.sock" ] && bridge=true
    jq -cn --argjson package "$package" --arg service "$service" --argjson health "$health" \
        --arg envMode "$env_mode" --arg dataMode "$data_mode" --arg timer "$timer" --argjson bridge "$bridge" \
        --argjson owner "$owner" --argjson loopback "$loopback" \
        '{id:"9router",package:$package,service:$service,healthy:$health,
          listener:{ownedByService:$owner,loopbackOnly:$loopback},
          permissions:{env:$envMode,data:$dataMode},passiveWatchdog:$timer,
          privateContainerBridge:$bridge,
          secure:($envMode=="600" and $dataMode=="700" and $bridge and $owner and $loopback),
          secretsRedacted:true}'
}

dashboard() {
    connection_grant_blocked
    return 69
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
case "$ACTION" in
    install|setup) install_9router ;;
    check-update|check) check_update ;;
    update|upgrade) ensure_dirs; install_verified_package; ensure_api_key ;;
    rollback) rollback_package ;;
    doctor) doctor_9router ;;
    status) status_json ;;
    start) systemctl --user enable --now "$SERVICE" "$BRIDGE_SERVICE"; wait_ready 60 ;;
    stop) systemctl --user disable --now "$BRIDGE_SERVICE" "$SERVICE" ;;
    restart) systemctl --user restart "$SERVICE" "$BRIDGE_SERVICE"; wait_ready 60 ;;
    test|health) test_9router ;;
    dashboard|open) dashboard ;;
    tui|terminal) tui_9router ;;
    repair|migrate) repair_9router ;;
    sync-secrets) sync_secrets "${1:-}" ;;
    provider)
        case "${1:-status}" in
            status|list) provider_status ;;
            sync|sync-secrets) sync_secrets "${2:-}" ;;
            remove|delete) provider_remove "${2:-}" ;;
            *) pz_error "usage: pz ai 9router provider (status|sync-secrets|remove <id>)"; exit 2 ;;
        esac ;;
    combo)
        case "${1:-list}" in
            list|status) combo_list ;;
            sync|auto) combo_sync ;;
            create) combo_create "${2:-}" "${3:-}" ;;
            switch) combo_switch "${2:-}" ;;
            *) pz_error "usage: pz ai 9router combo (list|sync|create <name> <models-csv>|switch <name>)"; exit 2 ;;
        esac ;;
    usage|telemetry) usage_json ;;
    client)
        case "${1:-status}" in
            status|env) client_status ;;
            run) connection_grant_blocked; exit 69 ;;
            *) pz_error "usage: pz ai 9router client (status|run <command>)"; exit 2 ;;
        esac ;;
    watch-once) watch_once ;;
    watchdog)
        case "${1:-status}" in
            install|enable) systemctl --user enable --now "$WATCH_TIMER" ;;
            remove|disable) systemctl --user disable --now "$WATCH_TIMER" ;;
            run) watch_once ;;
            status) systemctl --user status "$WATCH_TIMER" --no-pager ;;
            *) pz_error "usage: pz ai 9router watchdog (status|install|remove|run)"; exit 2 ;;
        esac ;;
    *) pz_error "usage: pz ai 9router (install|status|start|stop|restart|test|dashboard|tui|repair|provider|combo|usage|client|check-update|update|rollback|doctor|watchdog)"; exit 2 ;;
esac
fi
