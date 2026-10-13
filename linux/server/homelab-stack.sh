#!/usr/bin/env bash
# homelab-stack.sh - PhaseZero home server stack (Docker Compose) + Tailscale.
#
# Core: Portainer, Jellyfin, Syncthing, Vaultwarden, Uptime Kuma.
# Extras: Nextcloud, Prometheus/Grafana, Paperless, n8n.
# Default access is local-only. Tailscale and LAN exposure are explicit.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
CORE_FILE="$COMPOSE_DIR/docker-compose.homelab.yml"
EXTRAS_FILE="$COMPOSE_DIR/docker-compose.extras.yml"
APPS_CATALOG="${PZ_HOMELAB_APPS_CATALOG:-$COMPOSE_DIR/apps/catalog.json}"
PROJECT="${PZ_HOMELAB_PROJECT:-phasezero-homelab}"
HOMELAB_STATE="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
PINS_ENV="${PZ_HOMELAB_IMAGE_PINS:-$HOMELAB_STATE/image-pins.env}"
ENV_FILE="${PZ_HOMELAB_ENV_FILE:-$HOMELAB_STATE/.env}"
ENABLED_FILE="${PZ_HOMELAB_APPS_ENABLED:-$HOMELAB_STATE/apps.enabled.json}"
BACKUP_ROOT="${PZ_HOMELAB_BACKUP_ROOT:-$HOMELAB_STATE/backups}"
PZ_HOMELAB_BACKUP_SCHEMA="2"

ACTION="${1:-status}"
shift 2>/dev/null || true

WITH_EXTRAS=0
JSON_OUTPUT=0
YES=0
CONFIRM_FILE=""
FOLLOW=0
ACCESS_MODE="${PZ_HOMELAB_ACCESS_MODE:-local}"
HOMELAB_PROFILE="${PZ_HOMELAB_PROFILE:-}"
ALLOW_EMPTY=0
APP=""
DEST=""
SOURCE=""
VERIFY_MODE=0
PLAN=0
PREPARE_APPS=()

usage() {
    cat <<EOF
Usage:
  homelab-stack.sh status [--json] [--extras] [--access local|tailscale|lan]
  homelab-stack.sh plan [--json] [--extras] [--access local|tailscale|lan]
  homelab-stack.sh up|down|restart [--extras] [--access local|tailscale|lan] [--profile <key>]
  homelab-stack.sh reconcile [--access local|tailscale|lan]
  homelab-stack.sh open <app> [--access local|tailscale|lan]
  homelab-stack.sh logs <app> [--follow]
  homelab-stack.sh backup [--extras] [--dest PATH] [--dry-run]
  homelab-stack.sh backup verify --source PATH
  homelab-stack.sh restore --source PATH [--plan] [--yes] [--confirm-file PATH] [--dry-run]
  homelab-stack.sh update [--extras] [--access local|tailscale|lan] [--dry-run]
  homelab-stack.sh repair [--extras] [--access local|tailscale|lan]
  homelab-stack.sh prepare [--app KEY]... [--access local|tailscale|lan] [--dry-run]
  homelab-stack.sh tailscale

Apps: portainer jellyfin syncthing vaultwarden uptime-kuma nextcloud grafana prometheus paperless n8n
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --extras) WITH_EXTRAS=1 ;;
        --json) JSON_OUTPUT=1 ;;
        --yes|-y) YES=1 ;;
        --confirm-file)
            [ "${2:-}" ] || { pz_error "--confirm-file requires value"; exit 2; }
            CONFIRM_FILE="$2"
            shift
            ;;
        --confirm-file=*) CONFIRM_FILE="${1#*=}" ;;
        --plan) PLAN=1 ;;
        --follow|-f) FOLLOW=1 ;;
        --dry-run|-n) PZ_DRY_RUN=1 ;;
        --access)
            [ "${2:-}" ] || { pz_error "--access requires value"; exit 2; }
            ACCESS_MODE="$2"
            shift
            ;;
        --access=*) ACCESS_MODE="${1#--access=}" ;;
        --profile)
            [ "${2:-}" ] || { pz_error "--profile requires value"; exit 2; }
            HOMELAB_PROFILE="$2"
            shift
            ;;
        --profile=*) HOMELAB_PROFILE="${1#--profile=}" ;;
        --dest)
            [ "${2:-}" ] || { pz_error "--dest requires value"; exit 2; }
            DEST="$2"
            shift
            ;;
        --app)
            [ "${2:-}" ] || { pz_error "--app requires value"; exit 2; }
            PREPARE_APPS+=("$2")
            shift
            ;;
        --app=*) PREPARE_APPS+=("${1#--app=}") ;;
        --source)
            [ "${2:-}" ] || { pz_error "--source requires path"; exit 2; }
            SOURCE="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *)
            case "$ACTION" in
                open|logs)
                    if [ -z "$APP" ]; then
                        APP="$1"
                    else
                        pz_error "unexpected argument: $1"
                        exit 2
                    fi
                    ;;
                restore)
                    if [ -z "$SOURCE" ]; then
                        SOURCE="$1"
                    else
                        pz_error "unexpected argument: $1"
                        exit 2
                    fi
                    ;;
                backup)
                    if [ "$1" = "verify" ]; then
                        VERIFY_MODE=1
                    elif [ "$1" = "--allow-empty" ] || [ "$1" = "allow-empty" ]; then
                        ALLOW_EMPTY=1
                    else
                        pz_error "unexpected argument: $1"
                        exit 2
                    fi
                    ;;
                *) pz_error "unexpected argument: $1"; usage; exit 2 ;;
            esac
            ;;
    esac
    shift
done

case "$ACCESS_MODE" in
    local|tailscale|lan) ;;
    *) pz_error "invalid access mode: $ACCESS_MODE"; exit 2 ;;
esac

docker_cli() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        return 127
    fi
}

compose_args() {
    [ -f "$ENV_FILE" ] && printf '%s\0' --env-file "$ENV_FILE"
    [ -f "$PINS_ENV" ] && printf '%s\0' --env-file "$PINS_ENV"
    printf '%s\0' -p "$PROJECT" -f "$CORE_FILE"
    [ "$WITH_EXTRAS" = "1" ] && [ -f "$EXTRAS_FILE" ] && printf '%s\0' -f "$EXTRAS_FILE"
}

run_compose() {
    local args=()
    while IFS= read -r -d '' a; do args+=("$a"); done < <(compose_args)
    docker_cli "${args[@]}" "$@"
}

docker_installed() { command -v docker >/dev/null 2>&1; }
docker_reachable() { docker_installed && docker info >/dev/null 2>&1; }
compose_available() { docker_cli version >/dev/null 2>&1; }
tailscale_installed() { command -v tailscale >/dev/null 2>&1; }
tailscale_authenticated() { tailscale_installed && tailscale status >/dev/null 2>&1; }

require_docker() {
    docker_installed || { pz_error "docker not installed (pz install server-homelab, or install docker/docker-compose)"; return 1; }
    docker_reachable || { pz_error "docker daemon not reachable; enable docker and add user to docker group"; return 1; }
    compose_available || { pz_error "docker compose unavailable"; return 1; }
}

env_get() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE"
}

env_has_value() {
    local value
    value="$(env_get "$1")"
    [ -n "$value" ]
}

random_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        od -An -tx1 -N 32 /dev/urandom | tr -d ' \n'
    fi
}

env_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$(dirname "$ENV_FILE")"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$ENV_FILE" ]; then
        awk -v k="$key" -v v="$value" '
            BEGIN { done = 0 }
            $0 ~ "^" k "=" { print k "=" v; done = 1; next }
            { print }
            END { if (!done) print k "=" v }
        ' "$ENV_FILE" > "$tmp"
    else
        {
            echo "# PhaseZero Homelab environment"
            echo "# Generated locally. Do not commit."
            echo "$key=$value"
        } > "$tmp"
    fi
    install -m 0600 "$tmp" "$ENV_FILE"
    rm -f "$tmp"
}

lan_ip() {
    hostname -I 2>/dev/null | awk '{print $1; exit}'
}

tailscale_ip() {
    tailscale ip -4 2>/dev/null | head -1
}

access_bind_plan() {
    local mode="$1" ts_ip
    case "$mode" in
        local)
            printf '%s|%s|%s|%s\n' "local" "127.0.0.1" "127.0.0.1" "local-only"
            ;;
        tailscale)
            ts_ip="$(tailscale_ip || true)"
            if [ -n "$ts_ip" ] && tailscale_authenticated; then
                printf '%s|%s|%s|%s\n' "tailscale" "$ts_ip" "$ts_ip" "tailscale"
            else
                printf '%s|%s|%s|%s\n' "blocked" "127.0.0.1" "127.0.0.1" "tailscale-not-authenticated"
            fi
            ;;
        lan)
            printf '%s|%s|%s|%s\n' "lan" "0.0.0.0" "0.0.0.0" "lan-opt-in"
            ;;
    esac
}

access_host_for_urls() {
    local effective="$1" admin_bind="$2" public_bind="$3" host
    case "$effective" in
        tailscale) host="$(tailscale_ip || true)" ;;
        lan) host="$(lan_ip || true)" ;;
        *) host="127.0.0.1" ;;
    esac
    [ -n "$host" ] || host="127.0.0.1"
    printf '%s|%s|%s\n' "$host" "$admin_bind" "$public_bind"
}

ensure_env_file() {
    local mode="${1:-$ACCESS_MODE}" effective admin_bind public_bind reason
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$mode")
    mkdir -p "$HOMELAB_STATE"
    if [ ! -f "$ENV_FILE" ]; then
        umask 077
        {
            echo "# PhaseZero Homelab environment"
            echo "# Generated locally. Do not commit."
        } > "$ENV_FILE"
        chmod 0600 "$ENV_FILE"
    fi

    env_set HOMELAB_ACCESS_MODE "$mode"
    env_set HOMELAB_ACCESS_EFFECTIVE "$effective"
    env_set HOMELAB_ACCESS_REASON "$reason"
    env_set HOMELAB_ADMIN_BIND_ADDR "$admin_bind"
    env_set HOMELAB_PUBLIC_BIND_ADDR "$public_bind"
    env_has_value HOMELAB_MEDIA_DIR || env_set HOMELAB_MEDIA_DIR "$HOME/Videos"
    env_has_value VW_SIGNUPS_ALLOWED || env_set VW_SIGNUPS_ALLOWED "false"

    env_has_value VW_ADMIN_TOKEN || env_set VW_ADMIN_TOKEN "$(random_secret)"
    env_has_value NEXTCLOUD_DB_ROOT_PASSWORD || env_set NEXTCLOUD_DB_ROOT_PASSWORD "$(random_secret)"
    env_has_value NEXTCLOUD_DB_PASSWORD || env_set NEXTCLOUD_DB_PASSWORD "$(random_secret)"
    env_has_value GRAFANA_ADMIN_PASSWORD || env_set GRAFANA_ADMIN_PASSWORD "$(random_secret)"
    env_has_value PAPERLESS_SECRET_KEY || env_set PAPERLESS_SECRET_KEY "$(random_secret)"
    env_has_value N8N_ENCRYPTION_KEY || env_set N8N_ENCRYPTION_KEY "$(random_secret)"
}

ensure_tailscale() {
    command -v tailscale >/dev/null 2>&1 || { pz_warn "tailscale not installed; remote access disabled"; return 1; }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would ensure tailscaled up"
        return 0
    fi
    if pz_can_sudo_noninteractive; then
        sudo -n systemctl enable --now tailscaled >/dev/null 2>&1 || pz_warn "could not enable tailscaled"
    else
        pz_warn "run once: phasezero-admin systemctl enable --now tailscaled"
    fi
    if tailscale_authenticated; then
        pz_info "tailscale authenticated ($(tailscale_ip || true))"
    else
        pz_warn "tailscale logged out; authenticate once with: phasezero-admin tailscale up"
        return 1
    fi
}

HOMELAB_APPS_CATALOG="${PZ_HOMELAB_APPS_CATALOG:-$COMPOSE_DIR/apps/catalog.json}"

app_rows() {
    jq -r '
        .apps[] | select(.listInStatus == true)
        | [
            .key, .title, .service, .container, .layer,
            (.port | tostring), .bindKind,
            (if .sensitive then "true" else "false" end),
            ((.volumes // []) | join(" "))
          ] | join("|")
    ' "$HOMELAB_APPS_CATALOG"
}

secret_rows() {
    jq -r '
        .apps[] | select((.secrets // []) | length > 0) as $a
        | $a.secrets[] | "\(.)|\($a.service)|\($a.layer)"
    ' "$HOMELAB_APPS_CATALOG"
}

all_volumes() {
    # PZ-AUD-012: when the curated registry exists, back up exactly the
    # volumes in use (enabled set); an explicit --extras keeps covering
    # the extras layer as the operator requested.
    if [ -f "$ENABLED_FILE" ] && [ -f "$APPS_CATALOG" ]; then
        local keys
        keys="$(enabled_keys)" || return 1
        {
            jq -r --argjson en "$keys" '
                .apps[] | select(.key as $k | ($en | index($k) != null))
                | (.volumes // [])[]
            ' "$APPS_CATALOG" 2>/dev/null
            if [ "$WITH_EXTRAS" = "1" ]; then
                jq -r '.apps[] | select(.layer == "extras") | (.volumes // [])[]' \
                    "$APPS_CATALOG" 2>/dev/null
            fi
        } | sort -u
        return 0
    fi
    app_rows | awk -F'|' -v extras="$WITH_EXTRAS" '
        $5 == "core" || extras == "1" {
            n = split($9, vols, " ")
            for (i = 1; i <= n; i++) if (vols[i] != "") print vols[i]
        }
    ' | sort -u
}

enabled_keys() {
    # Desired set from the curated registry; errors when corrupt so the
    # caller never converges a guessed set.
    local raw
    raw="$(cat "$ENABLED_FILE" 2>/dev/null || true)"
    if ! jq -e '.schemaVersion == 1 and (.enabled | type == "array")' <<< "$raw" >/dev/null 2>&1; then
        pz_error "enabled-apps registry corrupt: $ENABLED_FILE"
        return 1
    fi
    jq -c '.enabled' <<< "$raw"
}

enabled_keys_with_deps() {
    local keys
    keys="$(enabled_keys)" || return 1
    jq -n -c --argjson en "$keys" --slurpfile cat "$APPS_CATALOG" '
        ($cat[0].apps) as $apps
        | ([$apps[] | select(.key as $k | ($en | index($k) != null))
            | ((.dependsOn // [])[]?), (.key)] | unique)
        | map(select(. as $k | ($apps | map(.key) | index($k) != null)))
    '
}

reconcile_files_for_keys() {
    local keys="$1"
    jq -r --argjson en "$keys" '
        .apps[] | select(.key as $k | ($en | index($k) != null)) | .composeFile
    ' "$APPS_CATALOG" 2>/dev/null | sort -u | while IFS= read -r f; do
        [ -n "$f" ] && [ "$f" != "null" ] && printf '%s/%s\n' "$COMPOSE_DIR" "$f"
    done
}

reconcile_services_for_keys() {
    local keys="$1"
    jq -r --argjson en "$keys" '
        .apps[] | select(.key as $k | ($en | index($k) != null)) | (.services // [])[]
    ' "$APPS_CATALOG" 2>/dev/null | sort -u
}

cmd_reconcile() {
    # PZ-AUD-012: one reconciler for boot/restart/update/backup. Desired =
    # curated registry; without a registry fall back to legacy layer up.
    require_docker || return 1
    if [ ! -f "$ENABLED_FILE" ]; then
        pz_info "no curated registry; reconciling via legacy layer up"
        cmd_up
        return $?
    fi
    local keys files services
    keys="$(enabled_keys_with_deps)" || return 1
    if [ "$(jq -r 'length' <<< "$keys")" = "0" ]; then
        jq -n --arg project "$PROJECT" \
            '{action:"reconcile", ok:true, project:$project, desired:[], started:[], note:"registry empty; nothing to start (use down to stop running services)"}'
        return 0
    fi
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        pz_error "tailscale access requested but Tailscale is logged out; run: pz server homelab tailscale"
        return 1
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --argjson desired "$keys" \
            '{action:"reconcile", dryRun:true, desired:$desired}'
        return 0
    fi
    mapfile -t files < <(reconcile_files_for_keys "$keys")
    mapfile -t services < <(reconcile_services_for_keys "$keys")
    [ "${#files[@]}" -gt 0 ] || { pz_error "no compose modules for enabled set"; return 1; }
    ensure_env_file "$ACCESS_MODE"
    local -a args=()
    [ -f "$ENV_FILE" ] && args+=(--env-file "$ENV_FILE")
    [ -f "$PINS_ENV" ] && args+=(--env-file "$PINS_ENV")
    args+=(-p "$PROJECT")
    local f
    for f in "${files[@]}"; do args+=(-f "$f"); done
    docker_cli "${args[@]}" config --services >/dev/null || { pz_error "compose config failed for enabled set"; return 1; }
    docker_cli "${args[@]}" up -d "${services[@]}" || { pz_error "reconcile up failed for enabled set"; return 1; }
    local started_json
    started_json="$(printf '%s\n' "${services[@]}" | jq -R . | jq -cs .)"
    jq -n --arg project "$PROJECT" --argjson desired "$keys" --argjson started "$started_json" \
        '{action:"reconcile", ok:true, project:$project, desired:$desired, started:$started}'
}

app_info() {
    local key="$1"
    app_rows | awk -F'|' -v key="$key" '$1 == key {print; found=1} END {exit found ? 0 : 1}'
}

service_for_app() {
    app_info "$1" | awk -F'|' '{print $3}'
}

container_for_app() {
    app_info "$1" | awk -F'|' '{print $4}'
}

app_port() {
    app_info "$1" | awk -F'|' '{print $6}'
}

app_bind_kind() {
    app_info "$1" | awk -F'|' '{print $7}'
}

running_containers_json() {
    if docker_reachable; then
        # PZ-AUD-011: scope discovery to this compose project; a second
        # project on the same daemon must never leak into our status.
        docker ps --filter "label=com.docker.compose.project=$PROJECT" --filter "name=phasezero-" --format '{{.Names}}' 2>/dev/null | jq -R . | jq -cs .
    else
        echo '[]'
    fi
}

services_json() {
    if compose_available && [ -f "$CORE_FILE" ]; then
        run_compose config --services 2>/dev/null | jq -R . | jq -cs .
    else
        echo '[]'
    fi
}

profile_definition_json() {
    local registry="$COMPOSE_DIR/homelab-profiles.json"
    [ -n "$HOMELAB_PROFILE" ] || { echo 'null'; return 0; }
    [ -f "$registry" ] || { echo 'null'; return 0; }
    jq -c --arg profile "$HOMELAB_PROFILE" '[.profiles[] | select(.key == $profile)] | .[0] // null' \
        "$registry" 2>/dev/null || echo 'null'
}

profile_coverage_json() {
    local profile services
    profile="$(profile_definition_json)"
    services="$(services_json)"
    if [ "$profile" = null ]; then
        jq -cn --arg requested "$HOMELAB_PROFILE" \
            '{requested:$requested,known:($requested==""),complete:($requested==""),composeManaged:[],unmanaged:[]}'
        return 0
    fi
    jq -cn --argjson profile "$profile" --argjson compose "$services" \
        '{requested:$profile.key,known:true,
          maturity:($profile.maturity // "preview"),
          installable:($profile.installable // false),
          installNote:($profile.installNote // "no install recipe yet"),
          complete:(([$profile.services[] as $service | select(($compose|index($service)) == null) | $service]|length)==0),
          composeManaged:[$profile.services[] as $service | select(($compose|index($service)) != null) | $service],
          unmanaged:[$profile.services[] as $service | select(($compose|index($service)) == null) | $service],
          reason:"profile registry is declarative; homelab-stack may start only services present in rendered Compose"}'
}

profile_budget_json() {
    [ -n "$HOMELAB_PROFILE" ] || { echo 'null'; return 0; }
    bash "$PZ_ROOT/linux/server/homelab-governor.sh" budget "$HOMELAB_PROFILE" 2>/dev/null || echo 'null'
}

secrets_json() {
    local rows=()
    while IFS='|' read -r key service layer; do
        local present=false required=false
        env_has_value "$key" && present=true
        [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ] && required=true
        rows+=("$(jq -cn \
            --arg key "$key" --arg service "$service" --arg layer "$layer" \
            --argjson present "$present" --argjson required "$required" \
            '{key:$key, service:$service, layer:$layer, present:$present, required:$required, sensitive:true}')")
    done < <(secret_rows)
    printf '%s\n' "${rows[@]}" | jq -s .
}

apps_json() {
    local effective admin_bind public_bind reason host names_json rows=()
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    IFS='|' read -r host _ _ < <(access_host_for_urls "$effective" "$admin_bind" "$public_bind")
    names_json="$(running_containers_json)"
    while IFS='|' read -r key title service container layer port bind_kind sensitive volumes; do
        [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ] || continue
        local bind="$public_bind"
        [ "$bind_kind" = "admin" ] && bind="$admin_bind"
        local url="http://$host:$port"
        local running=false
        echo "$names_json" | jq -e --arg c "$container" 'index($c)' >/dev/null 2>&1 && running=true
        rows+=("$(jq -cn \
            --arg key "$key" --arg title "$title" --arg service "$service" --arg container "$container" \
            --arg layer "$layer" --arg bind "$bind" --arg url "$url" --arg volumes "$volumes" \
            --argjson port "$port" --argjson sensitive "$sensitive" --argjson running "$running" \
            '{key:$key,title:$title,service:$service,container:$container,layer:$layer,port:$port,bind:$bind,url:$url,sensitive:$sensitive,running:$running,volumes:($volumes|split(" ")|map(select(.!="")))}')")
    done < <(app_rows)
    printf '%s\n' "${rows[@]}" | jq -s .
}

blockers_json() {
    local blockers=() coverage unmanaged
    [ -f "$CORE_FILE" ] || blockers+=("compose core missing: $CORE_FILE")
    [ "$WITH_EXTRAS" = "0" ] || [ -f "$EXTRAS_FILE" ] || blockers+=("compose extras missing: $EXTRAS_FILE")
    docker_installed || blockers+=("docker not installed")
    docker_reachable || blockers+=("docker daemon not reachable")
    compose_available || blockers+=("docker compose unavailable")
    [ -f "$ENV_FILE" ] || blockers+=("homelab .env missing; run: pz server homelab repair")
    while IFS='|' read -r key service layer; do
        if { [ "$layer" = "core" ] || [ "$WITH_EXTRAS" = "1" ]; } && ! env_has_value "$key"; then
            blockers+=("missing secret $key for $service")
        fi
    done < <(secret_rows)
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        blockers+=("tailscale logged out; sensitive services stay local-only")
    fi
    if [ -n "$HOMELAB_PROFILE" ]; then
        coverage="$(profile_coverage_json)"
        if [ "$(jq -r '.known' <<< "$coverage")" != true ]; then
            blockers+=("unknown homelab profile: $HOMELAB_PROFILE")
        elif [ "$(jq -r '.complete' <<< "$coverage")" != true ]; then
            unmanaged="$(jq -r '.unmanaged | join(",")' <<< "$coverage")"
            blockers+=("profile $HOMELAB_PROFILE is not orchestrated by this Compose stack: $unmanaged")
        fi
    fi
    [ "${#blockers[@]}" -gt 0 ] || { echo '[]'; return 0; }
    printf '%s\n' "${blockers[@]}" | jq -R . | jq -cs .
}

next_steps_json() {
    local steps=() coverage
    docker_reachable || steps+=("ativar Docker e permitir acesso do usuário")
    [ -f "$ENV_FILE" ] || steps+=("gerar secrets com: pz server homelab repair")
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        steps+=("autenticar Tailscale com: phasezero-admin tailscale up")
    fi
    coverage="$(profile_coverage_json)"
    if [ -n "$HOMELAB_PROFILE" ] && [ "$(jq -r '.complete' <<< "$coverage")" != true ]; then
        steps+=("executar diagnóstico: pz ai workspaces doctor")
        steps+=("não aplicar perfil até adapters, proveniência e release gate estarem completos")
    else
        steps+=("subir core com: pz server homelab up --access local")
        steps+=("subir extras só se precisar: pz server homelab up --extras --access tailscale")
    fi
    printf '%s\n' "${steps[@]}" | jq -R . | jq -cs .
}

emit_status_json() {
    local effective admin_bind public_bind reason host blockers secrets apps running services profile coverage budget
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    host="$(access_host_for_urls "$effective" "$admin_bind" "$public_bind" | cut -d'|' -f1)"
    blockers="$(blockers_json)"
    secrets="$(secrets_json)"
    apps="$(apps_json)"
    running="$(running_containers_json)"
    services="$(services_json)"
    profile="$(profile_definition_json)"
    coverage="$(profile_coverage_json)"
    budget="$(profile_budget_json)"
    jq -n \
        --arg project "$PROJECT" \
        --arg stateDir "$HOMELAB_STATE" \
        --arg envFile "$ENV_FILE" \
        --arg core "$CORE_FILE" \
        --arg extras "$EXTRAS_FILE" \
        --arg access "$ACCESS_MODE" \
        --arg effective "$effective" \
        --arg reason "$reason" \
        --arg adminBind "$admin_bind" \
        --arg publicBind "$public_bind" \
        --arg host "$host" \
        --argjson withExtras "$WITH_EXTRAS" \
        --argjson dockerInstalled "$(docker_installed && echo true || echo false)" \
        --argjson dockerReachable "$(docker_reachable && echo true || echo false)" \
        --argjson composeAvailable "$(compose_available && echo true || echo false)" \
        --argjson tailscaleInstalled "$(tailscale_installed && echo true || echo false)" \
        --argjson tailscaleAuthenticated "$(tailscale_authenticated && echo true || echo false)" \
        --argjson coreExists "$([ -f "$CORE_FILE" ] && echo true || echo false)" \
        --argjson extrasExists "$([ -f "$EXTRAS_FILE" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson blockers "$blockers" \
        --argjson secrets "$secrets" \
        --argjson apps "$apps" \
        --argjson running "$running" \
        --argjson services "$services" \
        --arg profileId "$HOMELAB_PROFILE" \
        --argjson profile "$profile" \
        --argjson profileCoverage "$coverage" \
        --argjson resourceBudget "$budget" \
        --argjson nextSteps "$(next_steps_json)" \
        '{
          tool:"homelab-stack",
          status:(if ($blockers|length)==0 then "ok" else "blocked" end),
          project:$project,
          withExtras:$withExtras,
          paths:{stateDir:$stateDir, envFile:$envFile, composeCore:$core, composeExtras:$extras},
          docker:{installed:$dockerInstalled, reachable:$dockerReachable, compose:$composeAvailable},
          tailscale:{installed:$tailscaleInstalled, authenticated:$tailscaleAuthenticated},
          access:{requested:$access, effective:$effective, reason:$reason, host:$host, adminBind:$adminBind, publicBind:$publicBind},
          compose:{coreExists:$coreExists, extrasExists:$extrasExists, services:$services},
          profileId:$profileId,profile:$profile,profileCoverage:$profileCoverage,resourceBudget:$resourceBudget,
          env:{exists:$envExists, secrets:$secrets},
          apps:$apps,
          running:$running,
          blockers:$blockers,
          nextSteps:$nextSteps
        }'
}

cmd_status() {
    emit_status_json
}

cmd_plan() {
    local data
    data="$(emit_status_json)"
    if [ "$JSON_OUTPUT" = "1" ]; then
        printf '%s\n' "$data"
        return 0
    fi
    echo "$data" | jq -r '
        "PhaseZero Homelab plan",
        "  status: \(.status)",
        "  access: \(.access.requested) -> \(.access.effective) (\(.access.reason))",
        "  docker: installed=\(.docker.installed) reachable=\(.docker.reachable) compose=\(.docker.compose)",
        "  env: \(.paths.envFile) exists=\(.env.exists)",
        "  apps:",
        (.apps[] | "    - \(.key): \(.url) bind=\(.bind) running=\(.running)"),
        "  blockers:",
        (if (.blockers|length)==0 then "    none" else (.blockers[] | "    - " + .) end),
        "  next:",
        (.nextSteps[] | "    - " + .)
    '
}

cmd_up() {
    # REV-018: profile maturity is a pure decision — it must refuse before
    # any Docker requirement, so a clean host sees the honest refusal (rc 69)
    # instead of a misleading daemon error.
    if [ -n "$HOMELAB_PROFILE" ]; then
        local coverage
        coverage="$(profile_coverage_json)"
        if [ "$(jq -r '.installable' <<< "$coverage")" != true ]; then
            pz_error "profile $HOMELAB_PROFILE is $(jq -r '.maturity' <<< "$coverage") and not installable: $(jq -r '.installNote' <<< "$coverage")"
            return 69
        fi
        if [ "$(jq -r '.known and .complete' <<< "$coverage")" != true ]; then
            pz_error "profile $HOMELAB_PROFILE cannot be applied: services are not fully orchestrated ($(jq -r '.unmanaged|join(",")' <<< "$coverage"))"
            return 69
        fi
        if ! bash "$PZ_ROOT/linux/server/homelab-governor.sh" check "$HOMELAB_PROFILE" >/dev/null 2>&1; then
            pz_error "profile $HOMELAB_PROFILE rejected by resource governor; check budget: pz server homelab governor budget $HOMELAB_PROFILE"
            return 1
        fi
    fi
    require_docker || return 1
    [ -f "$CORE_FILE" ] || { pz_error "compose file missing: $CORE_FILE"; return 1; }
    [ "$WITH_EXTRAS" = "0" ] || [ -f "$EXTRAS_FILE" ] || { pz_error "extras compose file missing: $EXTRAS_FILE"; return 1; }
    if [ "$ACCESS_MODE" = "tailscale" ] && ! tailscale_authenticated; then
        pz_error "tailscale access requested but Tailscale is logged out; run: pz server homelab tailscale"
        return 1
    fi
    if [ -n "$HOMELAB_PROFILE" ]; then
        # Persist the profile only after every gate passed (never record
        # intent for a refused up).
        mkdir -p "$HOMELAB_STATE"
        printf '%s\n' "$HOMELAB_PROFILE" > "$HOMELAB_STATE/profile.active"
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would generate .env, validate compose, and run compose up -d (project $PROJECT, extras=$WITH_EXTRAS, access=$ACCESS_MODE)"
        PZ_DRY_RUN=1 cmd_plan
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    run_compose config --services >/dev/null
    pz_info "starting homelab stack (project $PROJECT, extras=$WITH_EXTRAS, access=$ACCESS_MODE)"
    run_compose up -d
    if [ "$ACCESS_MODE" = "tailscale" ]; then
        ensure_tailscale || true
    fi
    cmd_plan
}

cmd_down() {
    # Fixture/override mode has no daemon to stop; treat as stopped.
    if [ -n "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ]; then
        pz_info "homelab stack stopped (volume-mount override; no daemon)"
        return 0
    fi
    require_docker || return 1
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would run compose down (volumes preserved)"
        return 0
    fi
    # R01-001: callers use `if ! cmd_down`, which suppresses errexit inside
    # this function — a failed compose down must be propagated explicitly,
    # otherwise restore snapshots/applies over live writers while reporting
    # the stack as stopped.
    if ! run_compose down; then
        pz_error "compose down failed; the stack may still be running"
        return 1
    fi
    pz_info "homelab stack stopped (named volumes preserved)"
}

url_for_app() {
    local key="$1" row port bind_kind effective admin_bind public_bind reason host
    row="$(app_info "$key")" || { pz_error "unknown homelab app: $key"; return 1; }
    port="$(echo "$row" | awk -F'|' '{print $6}')"
    bind_kind="$(echo "$row" | awk -F'|' '{print $7}')"
    IFS='|' read -r effective admin_bind public_bind reason < <(access_bind_plan "$ACCESS_MODE")
    host="$(access_host_for_urls "$effective" "$admin_bind" "$public_bind" | cut -d'|' -f1)"
    printf 'http://%s:%s\n' "$host" "$port"
}

cmd_open() {
    [ -n "$APP" ] || { pz_error "usage: homelab-stack.sh open <app>"; return 2; }
    local url
    url="$(url_for_app "$APP")" || return 1
    if [ "$JSON_OUTPUT" = "1" ]; then
        jq -n --arg app "$APP" --arg url "$url" '{app:$app,url:$url}'
        return 0
    fi
    echo "$url"
    if [ "${PZ_DRY_RUN:-0}" = "1" ] || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    else
        pz_warn "xdg-open unavailable; open manually: $url"
    fi
}

cmd_logs() {
    [ -n "$APP" ] || { pz_error "usage: homelab-stack.sh logs <app>"; return 2; }
    require_docker || return 1
    local container args=(--tail=200)
    container="$(container_for_app "$APP")" || { pz_error "unknown homelab app: $APP"; return 1; }
    [ "$FOLLOW" = "1" ] && args+=("--follow")
    docker logs "${args[@]}" "$container"
}

volume_actual_name() {
    # PZ-AUD-011: deterministic identity. Compose always creates
    # <project>_<logical>; never fuzzy-match another project's suffix.
    local logical="$1"
    [ -n "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ] && { printf '%s\n' "$logical"; return 0; }
    printf '%s_%s\n' "$PROJECT" "$logical"
}

volume_project_label() {
    # Owning compose project recorded on the volume, empty when unknown.
    docker volume inspect -f '{{ index .Labels "com.docker.compose.project" }}' "$1" 2>/dev/null || true
}

volume_owned_by_project() {
    # PZ-AUD-011: refuse volumes owned by another project. Unlabeled
    # (legacy) volumes are allowed with a warning, never silently shared:
    # a foreign label is a hard error before backup/restore/rm.
    local vol="$1" owner
    [ -n "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ] && return 0
    owner="$(volume_project_label "$vol")"
    if [ -n "$owner" ] && [ "$owner" != "$PROJECT" ]; then
        pz_error "volume $vol belongs to project $owner, not $PROJECT; refusing"
        return 1
    fi
    if [ -z "$owner" ] && docker volume inspect "$vol" >/dev/null 2>&1; then
        pz_warn "volume $vol has no project label (legacy); assuming $PROJECT"
    fi
    return 0
}

volume_mount() {
    local vol="$1" ov="${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}"
    if [ -n "$ov" ]; then
        printf '%s/%s\n' "$ov" "$vol"
        return 0
    fi
    docker volume inspect -f '{{ .Mountpoint }}' "$vol"
}

wipe_dir_contents() {
    # Empty a directory without removing it (rm refuses trailing /.).
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    find "$dir" -mindepth 1 -delete 2>/dev/null
}

all_volumes_override() {
    if [ -n "${PZ_HOMELAB_VOLUMES_OVERRIDE:-}" ]; then
        # Intentional word-splitting: the override is a space-separated list.
        # shellcheck disable=SC2086
        printf '%s\n' $PZ_HOMELAB_VOLUMES_OVERRIDE
        return 0
    fi
    all_volumes
}

json_arr() {
    if [ "$#" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -cs .
    fi
}

stage_volume_consistent() {
    # PZ-AUD-009 + REV-002 + R01-004: copy mount -> staging, then hot-backup
    # SQLite files FROM THE LIVE MOUNT via the sqlite3 backup API, so a
    # write in flight cannot ship a torn database and stale WAL/SHM copies
    # are never shipped beside the hot backup. Server engines
    # (MariaDB/Postgres data dirs) and Prometheus TSDB layouts cannot be
    # made consistent from files alone: they are archived as-is and flagged
    # consistent:false with the reason. Prints ONE tab-separated record
    # "<method>\t<consistent>\t<reason>" — a reason carried in a side
    # variable would be lost inside the $(...) command substitution.
    # R01-005: the real TSDB layout is wal/ + chunks_head/ + block
    # directories (01XXXX/index + chunks); any of those shapes must never
    # be classified consistent from a plain file copy.
    local mount="$1" stage="$2" db rel tmp blk tsdb=false
    # SQLite can unlink/recreate -wal and -shm while writers checkpoint.
    # They are never part of the staged snapshot: the live .backup below
    # replaces each database, and copying a disappearing sidecar makes cp fail.
    if ! tar -C "$mount" --exclude='*-wal' --exclude='*-shm' -cf - . | tar -C "$stage" -xf -; then
        return 1
    fi
    if find "$stage" -maxdepth 4 \( -name 'PG_VERSION' -o -name 'ibdata1' -o -name 'mysql' \) -print -quit 2>/dev/null | grep -q .; then
        printf 'staged-tar\t%s\t%s\n' false "server database directory copied as-is; needs native dump or stopped-stack snapshot"
        return 0
    fi
    if [ -d "$stage/wal" ]; then
        if [ -d "$stage/chunks_head" ] || [ -d "$stage/chunks" ] || [ -f "$stage/index" ]; then
            tsdb=true
        else
            for blk in "$stage"/*/; do
                [ -d "$blk" ] || continue
                if [ -f "${blk}index" ] || [ -d "${blk}chunks" ]; then
                    tsdb=true
                    break
                fi
            done
        fi
    fi
    if [ "$tsdb" = true ]; then
        printf 'staged-tar\t%s\t%s\n' false "TSDB directory copied as-is; needs the service snapshot API or stopped-stack snapshot"
        return 0
    fi
    local -a dbs=()
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        case "$db" in
            *.db|*.sqlite|*.sqlite3) dbs+=("$db") ;;
        esac
    done < <(find "$stage" -maxdepth 4 -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) 2>/dev/null)
    if [ "${#dbs[@]}" -eq 0 ]; then
        printf 'staged-tar\t%s\t\n' true
        return 0
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        pz_warn "sqlite3 unavailable; shipping ${#dbs[@]} sqlite file(s) without hot-backup"
        printf 'staged-tar\t%s\t%s\n' false "sqlite3 unavailable; plain file copy is not a consistent snapshot"
        return 0
    fi
    for db in "${dbs[@]}"; do
        rel="${db#"$stage"/}"
        tmp="$db.pzhot"
        # Stale sidecar copies from the cp would corrupt the hot backup on
        # open; drop them before replacing the staged database.
        rm -f "$db-wal" "$db-shm"
        if sqlite3 "$mount/$rel" ".timeout 2000" ".backup '$tmp'" 2>/dev/null && [ -f "$tmp" ]; then
            mv -f "$tmp" "$db"
        else
            pz_warn "sqlite hot-backup failed for $db; shipping file as-is"
            rm -f "$tmp"
            printf 'staged-tar\t%s\t%s\n' false "sqlite hot-backup failed for $rel; file shipped as-is"
            return 0
        fi
    done
    printf 'staged-tar+sqlite-live-hotbackup\t%s\t\n' true
    return 0
}

cmd_backup() {
    local dest="${DEST:-$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')}" vol actual mount started finished
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --arg dest "$dest" --argjson volumes "$(all_volumes_override | jq -R . | jq -cs .)" \
            '{action:"backup", dryRun:true, destination:$dest, volumes:$volumes}'
        return 0
    fi
    [ -n "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ] || require_docker || return 1
    local -a expected=() _raw=()
    mapfile -t _raw < <(all_volumes_override)
    local _v
    for _v in "${_raw[@]}"; do [ -n "$_v" ] && expected+=("$_v"); done
    if [ "${#expected[@]}" -eq 0 ]; then
        # PZ-AUD-009: an empty set is only a success when explicitly asked.
        if [ "$ALLOW_EMPTY" = "1" ]; then
            mkdir -p "$dest"
            finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            jq -cn --arg schemaVersion "$PZ_HOMELAB_BACKUP_SCHEMA" --arg tool "homelab-backup" \
                --arg id "$(basename "$dest")" --arg createdAt "$started" --arg finishedAt "$finished" \
                --arg project "$PROJECT" \
                '{schemaVersion:$schemaVersion, tool:$tool, id:$id, createdAt:$createdAt, finishedAt:$finishedAt,
                  project:$project, volumes:[], verified:false, consistent:true, empty:true}' \
                > "$dest/manifest.json"
            jq -n --arg destination "$dest" --arg id "$(basename "$dest")" \
                '{action:"backup", destination:$destination, id:$id, volumes:[], ok:true, consistent:true, empty:true}'
            return 0
        fi
        pz_error "no volumes expected; refusing empty backup (pass backup --allow-empty to record one explicitly)"
        return 1
    fi
    mkdir -p "$dest"
    local stage_root="$dest/.staging"
    rm -rf "$stage_root"
    mkdir -p "$stage_root"
    local -a vol_json=() missing=()
    local err=0 consistent_all=true
    while IFS= read -r vol; do
        [ -n "$vol" ] || continue
        actual="$(volume_actual_name "$vol")"
        if ! volume_owned_by_project "$actual"; then
            err=1
            continue
        fi
        mount="$(volume_mount "$actual")"
        if [ ! -d "$mount" ]; then
            # PZ-AUD-009: required data is never silently omitted.
            pz_error "volume mount missing, cannot back up: $actual"
            missing+=("$vol")
            err=1
            continue
        fi
        local stage="$stage_root/$vol"
        mkdir -p "$stage"
        local method consistent reason
        if stage_line="$(stage_volume_consistent "$mount" "$stage")"; then
            # R01-004: single tab-separated record; nothing rides on a side
            # variable that a command substitution would discard.
            IFS=$'\t' read -r method consistent reason <<< "$stage_line"
        else
            pz_error "staging failed for $actual"
            err=1
            continue
        fi
        if ! tar -C "$stage" -czf "$dest/$vol.tgz" . 2>/dev/null; then
            pz_error "tar failed for $actual"
            err=1
            continue
        fi
        [ "$consistent" = true ] || consistent_all=false
        local sha size entries
        sha="$(sha256sum "$dest/$vol.tgz" | cut -d' ' -f1)"
        size="$(stat -c%s "$dest/$vol.tgz")"
        entries="$(tar -tzf "$dest/$vol.tgz" 2>/dev/null | wc -l)"
        vol_json+=("$(jq -cn --arg name "$vol" --arg archive "$vol.tgz" --arg sha256 "$sha" \
            --arg method "$method" --argjson consistent "$consistent" --arg reason "$reason" \
            --argjson size "$size" --argjson entries "$entries" \
            '{name:$name, archive:$archive, sha256:$sha256, sizeBytes:$size, entries:$entries,
              method:$method, consistent:$consistent,
              reason:(if $consistent then null else $reason end)}')")
        pz_info "backed up $actual -> $dest/$vol.tgz ($method)"
    done < <(printf '%s\n' "${expected[@]}")
    rm -rf "$stage_root"
    if [ "$err" != "0" ]; then
        local missing_json
        missing_json="$(json_arr "${missing[@]}")"
        jq -n --arg destination "$dest" --argjson missing "$missing_json" \
            '{action:"backup", destination:$destination, ok:false, missingVolumes:$missing,
              reason:"backup incomplete; manifest not written"}' || true
        pz_error "backup incomplete; manifest not written"
        return 1
    fi
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local volumes_json manifest
    volumes_json="$(printf '%s\n' "${vol_json[@]}" | jq -s .)"
    manifest="$(jq -cn --arg schemaVersion "$PZ_HOMELAB_BACKUP_SCHEMA" --arg tool "homelab-backup" \
        --arg id "$(basename "$dest")" --arg createdAt "$started" --arg finishedAt "$finished" \
        --arg project "$PROJECT" --argjson volumes "$volumes_json" --argjson consistent "$consistent_all" \
        '{schemaVersion:$schemaVersion, tool:$tool, id:$id, createdAt:$createdAt, finishedAt:$finishedAt,
          project:$project, volumes:$volumes, verified:false, consistent:$consistent,
          empty:false}')"
    printf '%s\n' "$manifest" > "$dest/manifest.json.tmp" && mv "$dest/manifest.json.tmp" "$dest/manifest.json"
    local msha
    msha="$(sha256sum "$dest/manifest.json" | cut -d' ' -f1)"
    mkdir -p "$BACKUP_ROOT"
    jq -n --arg latest "$dest" --arg id "$(basename "$dest")" --arg createdAt "$started" \
        --arg manifestSha "$msha" --argjson verified false --argjson consistent "$consistent_all" \
        '{latest:$latest, id:$id, createdAt:$createdAt, manifestSha:$manifestSha, verified:false, consistent:$consistent}' \
        > "$BACKUP_ROOT/last.json"
    jq -n --arg destination "$dest" --arg id "$(basename "$dest")" \
        --argjson volumes "$volumes_json" --argjson consistent "$consistent_all" \
        '{action:"backup", destination:$destination, id:$id, volumes:$volumes, ok:true, consistent:$consistent}'
}

cmd_verify_backup() {
    local src="${1:-}" fail=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source) src="${2:-}"; shift ;;
            --source=*) src="${1#--source=}" ;;
        esac
        shift
    done
    [ -n "$src" ] || { pz_error "verify requires --source PATH"; return 2; }
    [ -d "$src" ] || { pz_error "backup source missing: $src"; return 1; }
    [ -f "$src/manifest.json" ] || { pz_error "no manifest.json (not a verifiable backup)"; return 1; }
    local manifest
    manifest="$(cat "$src/manifest.json")"
    local -a reasons=()
    if ! printf '%s\n' "$manifest" | jq -e '.schemaVersion == "2" or .schemaVersion == 2' >/dev/null 2>&1; then
        reasons+=("unsupported manifest schemaVersion")
        fail=1
    fi
    if ! printf '%s\n' "$manifest" | jq -e '.volumes | type == "array"' >/dev/null 2>&1; then
        reasons+=("volumes list missing")
        fail=1
    fi
    while IFS=$'\t' read -r archive sha; do
        [ -n "$archive" ] || continue
        local f="$src/$archive"
        if [ ! -f "$f" ]; then
            reasons+=("archive missing: $archive")
            fail=1
            continue
        fi
        local got
        got="$(sha256sum "$f" | cut -d' ' -f1)"
        [ "$got" = "$sha" ] || { reasons+=("checksum mismatch: $archive"); fail=1; }
        tar -tzf "$f" >/dev/null 2>&1 || { reasons+=("tar corrupt: $archive"); fail=1; }
    done < <(printf '%s\n' "$manifest" | jq -r '.volumes[]? | [.archive, .sha256] | @tsv')
    # PZ-AUD-009/010: size/entries recorded at backup time must still hold;
    # extra archives outside the manifest are reported (restore ignores them).
    while IFS=$'\t' read -r archive size entries; do
        [ -n "$archive" ] || continue
        local f="$src/$archive"
        [ -f "$f" ] || continue
        if [ -n "$size" ] && [ "$size" != "null" ]; then
            [ "$(stat -c%s "$f")" = "$size" ] || { reasons+=("size changed: $archive"); fail=1; }
        fi
        if [ -n "$entries" ] && [ "$entries" != "null" ]; then
            [ "$(tar -tzf "$f" 2>/dev/null | wc -l)" = "$entries" ] || { reasons+=("entries changed: $archive"); fail=1; }
        fi
    done < <(printf '%s\n' "$manifest" | jq -r '.volumes[]? | [.archive, (.sizeBytes|tostring), (.entries|tostring)] | @tsv')
    local extra
    extra="$(comm -23 <(find "$src" -maxdepth 1 -name '*.tgz' -printf '%f\n' 2>/dev/null | sort) \
        <(printf '%s\n' "$manifest" | jq -r '.volumes[]?.archive' | sort) | tr '\n' ' ')"
    [ -z "${extra// }" ] || reasons+=("extra archives outside manifest (ignored by restore):${extra}")
    local consistent
    consistent="$(printf '%s\n' "$manifest" | jq -r '.consistent // "unknown"')"
    local out
    out="$(jq -cn --arg source "$src" --arg schemaVersion "$PZ_HOMELAB_BACKUP_SCHEMA" \
        --argjson verified "$([ "$fail" -eq 0 ] && echo true || echo false)" \
        --argjson checks "$(json_arr "${reasons[@]}")" \
        --arg consistent "$consistent" \
        '{action:"verify-backup", source:$source, schemaVersion:$schemaVersion, verified:$verified, checks:$checks, consistent:$consistent}')"
    printf '%s\n' "$out"
    [ "$fail" -eq 0 ]
}

cmd_restore() {
    [ -n "$SOURCE" ] || { pz_error "restore requires --source PATH"; return 2; }
    if [ "$PLAN" = "1" ]; then
        # CCS-004: --plan = verify + impacto, zero escrita. É o caminho que a
        # Central (catálogo e Player) usa; aplicar segue exigindo --yes na CLI.
        if [ "$YES" = "1" ] || [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_error "restore: use --plan sozinho; --dry-run e --yes não se combinam com ele"
            return 2
        fi
        [ -f "$SOURCE/manifest.json" ] || { pz_error "restore source is not a verifiable backup (manifest.json missing)"; return 1; }
        local verify_json verify_rc=0 archives checks verified
        verify_json="$(cmd_verify_backup --source "$SOURCE")" || verify_rc=$?
        verified="$(jq -r '.verified' <<< "$verify_json")"
        checks="$(jq -c '.checks' <<< "$verify_json")"
        archives="$(find "$SOURCE" -maxdepth 1 -name '*.tgz' -printf '%f\n' 2>/dev/null | jq -R . | jq -cs .)"
        volumes="$(jq -c '[.volumes[]?.name]' "$SOURCE/manifest.json")"
        jq -cn \
            --arg source "$SOURCE" \
            --arg schemaVersion "$PZ_HOMELAB_BACKUP_SCHEMA" \
            --argjson manifestOk true \
            --argjson verified "$verified" \
            --argjson checks "$checks" \
            --argjson archives "$archives" \
            --argjson volumesAffected "$volumes" \
            '{action:"restore", plan:true, source:$source, schemaVersion:$schemaVersion,
              manifestOk:$manifestOk, verified:$verified, checks:$checks,
              archives:$archives, volumesAffected:$volumesAffected,
              requiresConfirmation:true}'
        return "$verify_rc"
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        jq -n --arg source "$SOURCE" --argjson archives "$(find "$SOURCE" -maxdepth 1 -name '*.tgz' -printf '%f\n' 2>/dev/null | jq -R . | jq -cs .)" \
            --argjson manifestOk "$([ -f "$SOURCE/manifest.json" ] && echo true || echo false)" \
            '{action:"restore", dryRun:true, source:$source, archives:$archives, manifestOk:$manifestOk, requiresConfirmation:true}'
        return 0
    fi
    [ -f "$SOURCE/manifest.json" ] || { pz_error "restore source is not a verifiable backup (manifest.json missing)"; return 1; }
    if ! cmd_verify_backup --source "$SOURCE" >/dev/null 2>&1; then
        pz_error "backup verification failed; refusing restore"
        return 1
    fi
    # PZ-AUD-010: a backup belongs to exactly one project; never apply a
    # foreign project's data onto this one.
    local manifest_project
    manifest_project="$(jq -r '.project // empty' "$SOURCE/manifest.json")"
    if [ -n "$manifest_project" ] && [ "$manifest_project" != "$PROJECT" ]; then
        pz_error "backup project $manifest_project != $PROJECT; refusing restore"
        return 1
    fi
    if [ "$YES" != "1" ]; then
        # CCS-004: a Central nunca usa --yes; o operador confirma gerando um
        # arquivo com a frase exata vinculada à origem do restore.
        [ -n "$CONFIRM_FILE" ] || { pz_error "restore is destructive; pass --yes or --confirm-file after verifying backup"; return 1; }
        [ -f "$CONFIRM_FILE" ] || { pz_error "confirmation file missing: $CONFIRM_FILE"; return 1; }
        grep -qx "RESTAURAR $(basename "$SOURCE")" "$CONFIRM_FILE" \
            || { pz_error "confirmation phrase mismatch in $CONFIRM_FILE (esperado: RESTAURAR $(basename "$SOURCE"))"; return 1; }
    fi
    [ -n "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ] || require_docker || return 1
    [ -d "$SOURCE" ] || { pz_error "restore source missing: $SOURCE"; return 1; }
    # Manifest-driven volume list: extra *.tgz files in the directory are
    # NEVER applied (PZ-AUD-010).
    local -a manifest_vols=()
    mapfile -t manifest_vols < <(jq -r '.volumes[]? | "\(.name)\t\(.archive)\t\(.sha256)"' "$SOURCE/manifest.json")
    [ "${#manifest_vols[@]}" -gt 0 ] || { pz_error "manifest lists no volumes; refusing empty restore"; return 1; }
    # REV-003: stop the stack BEFORE capturing the pre-restore snapshot —
    # a rollback copy taken while writers are live can ship a torn database.
    # The previous execution state is remembered so a successful restore can
    # bring the stack back up.
    local stack_was_running=false
    if [ -z "${PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE:-}" ] && docker_reachable; then
        if [ -n "$(docker ps --filter "label=com.docker.compose.project=$PROJECT" -q 2>/dev/null)" ]; then
            stack_was_running=true
        fi
    fi
    # PZ-AUD-010: a failed stop must block mutation, never be ignored.
    if ! cmd_down; then
        pz_error "could not stop stack; refusing to mutate volumes"
        return 1
    fi
    local pre_dir="$SOURCE.pre-restore"
    mkdir -p "$pre_dir"
    local -a pre_vol=()
    local vol actual mount archive sha
    while IFS=$'\t' read -r vol archive sha; do
        [ -n "$vol" ] || continue
        actual="$(volume_actual_name "$vol")"
        if ! volume_owned_by_project "$actual"; then
            pz_error "pre-restore snapshot refused for foreign volume $actual; aborting restore"
            return 1
        fi
        mount="$(volume_mount "$actual")"
        if [ ! -d "$mount" ]; then
            pz_warn "no pre-restore snapshot for $actual (mount missing)"
            continue
        fi
        if ! tar -C "$mount" -czf "$pre_dir/$vol.tgz" . 2>/dev/null; then
            pz_error "pre-restore snapshot failed for $actual; aborting restore"
            return 1
        fi
        local sha2 size entries
        sha2="$(sha256sum "$pre_dir/$vol.tgz" | cut -d' ' -f1)"
        size="$(stat -c%s "$pre_dir/$vol.tgz")"
        entries="$(tar -tzf "$pre_dir/$vol.tgz" 2>/dev/null | wc -l)"
        pre_vol+=("$(jq -cn --arg name "$vol" --arg archive "$vol.tgz" --arg sha256 "$sha2" \
            --argjson size "$size" --argjson entries "$entries" \
            '{name:$name, archive:$archive, sha256:$sha256, sizeBytes:$size, entries:$entries}')")
    done < <(printf '%s\n' "${manifest_vols[@]}")
    if [ "${#pre_vol[@]}" -gt 0 ]; then
        jq -cn --arg schemaVersion "$PZ_HOMELAB_BACKUP_SCHEMA" --arg tool "homelab-restore-pre" \
            --arg id "$(basename "$SOURCE").pre-restore" --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg project "$PROJECT" --argjson volumes "$(printf '%s\n' "${pre_vol[@]}" | jq -s .)" \
            '{schemaVersion:$schemaVersion, tool:$tool, id:$id, createdAt:$createdAt, project:$project, volumes:$volumes, verified:false}' \
            > "$pre_dir/manifest.json"
    fi
    local work
    work="$(mktemp -d "${TMPDIR:-/tmp}/pz-restore.XXXXXX")" || { pz_error "no temp dir for restore staging"; return 1; }
    local -a applied=()
    local failed="" mutating=""
    while IFS=$'\t' read -r vol archive sha; do
        [ -n "$vol" ] || continue
        actual="$(volume_actual_name "$vol")"
        if ! volume_owned_by_project "$actual"; then
            pz_error "refusing foreign volume $actual"
            failed="$vol"
            break
        fi
        if [ ! -f "$SOURCE/$archive" ]; then
            pz_error "manifest archive missing: $archive"
            failed="$vol"
            break
        fi
        # TOCTOU: re-checksum right before applying.
        if [ "$(sha256sum "$SOURCE/$archive" | cut -d' ' -f1)" != "$sha" ]; then
            pz_error "checksum changed since verify: $archive; aborting"
            failed="$vol"
            break
        fi
        # Path safety: no absolute paths, no parent escapes.
        if tar -tzf "$SOURCE/$archive" 2>/dev/null | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
            pz_error "unsafe paths in $archive; aborting"
            failed="$vol"
            break
        fi
        mount="$(volume_mount "$actual")"
        rm -rf "$work/stage"
        mkdir -p "$work/stage" "$mount" || { pz_error "mount dir unavailable for $vol"; failed="$vol"; break; }
        if ! tar -C "$work/stage" -xzf "$SOURCE/$archive"; then
            pz_error "restore failed for $vol"
            failed="$vol"
            break
        fi
        # REV-001: the volume is mutated from here on. Register it BEFORE
        # the first destructive write so a failed swap is part of the
        # rollback set instead of being silently dropped with its
        # destination wiped.
        mutating="$vol"
        # Exact state: wipe current contents, then populate from staging.
        if ! wipe_dir_contents "$mount" || ! cp -a "$work/stage/." "$mount/"; then
            pz_error "swap failed for $vol"
            failed="$vol"
            break
        fi
        mutating=""
        applied+=("$vol")
        pz_info "restored $archive -> $actual"
    done < <(printf '%s\n' "${manifest_vols[@]}")
    rm -rf "$work"
    if [ -n "$failed" ]; then
        # REV-001: roll back every mutated volume — including the one whose
        # swap failed mid-copy — to its pre-restore snapshot. A rollback
        # that cannot complete is reported as recovery-required, never as
        # an applied rollback.
        local -a rb_targets=("${applied[@]}")
        [ -n "$mutating" ] && rb_targets+=("$mutating")
        local rb_ok=true rb_fail="" rb_work
        rb_work="$(mktemp -d "${TMPDIR:-/tmp}/pz-restore-rb.XXXXXX")" || { pz_error "no temp dir for rollback"; return 1; }
        for v in "${rb_targets[@]}"; do
            if [ -f "$pre_dir/$v.tgz" ]; then
                local rbm
                rbm="$(volume_mount "$(volume_actual_name "$v")")"
                rm -rf "$rb_work/swap"
                mkdir -p "$rb_work/swap"
                if [ -n "$rbm" ] && [ -d "$rbm" ] \
                    && tar -C "$rb_work/swap" -xzf "$pre_dir/$v.tgz" 2>/dev/null \
                    && wipe_dir_contents "$rbm" && cp -a "$rb_work/swap/." "$rbm/"; then
                    :
                else
                    rb_ok=false
                    rb_fail="$rb_fail $v"
                fi
            else
                rb_ok=false
                rb_fail="$rb_fail $v"
            fi
        done
        rm -rf "$rb_work"
        jq -n --arg source "$SOURCE" --arg pre "$pre_dir" --arg volume "$failed" \
            --argjson rollbackApplied "$([ "$rb_ok" = "true" ] && echo true || echo false)" \
            --argjson recoveryRequired "$([ "$rb_ok" = "true" ] && echo false || echo true)" \
            --arg rolledBack "$(printf '%s' "${rb_targets[@]}")" --arg rollbackFailed "${rb_fail# }" \
            --argjson stackWasRunning "$stack_was_running" \
            --arg nextAction "inspect $pre_dir and restore it manually before any retry" \
            '{action:"restore", source:$source, ok:false, failedVolume:$volume, preRestore:$pre,
              rollbackApplied:$rollbackApplied, recoveryRequired:$recoveryRequired,
              rolledBack:$rolledBack, rollbackFailed:$rollbackFailed,
              stackWasRunning:$stackWasRunning,
              nextAction:(if $recoveryRequired then $nextAction else null end)}'
        return 1
    fi
    # REV-003: a successful restore returns the stack to its previous
    # execution state (best effort, honestly reported).
    local stack_restarted=false
    if [ "$stack_was_running" = "true" ]; then
        if run_compose up -d >/dev/null 2>&1; then
            stack_restarted=true
        else
            pz_warn "stack was running before restore; bring it back with: pz server homelab up"
        fi
    fi
    jq -n --arg source "$SOURCE" --arg pre "$pre_dir" \
        --argjson stackWasRunning "$stack_was_running" --argjson stackRestarted "$stack_restarted" \
        '{action:"restore", source:$source, ok:true, preRestore:$pre,
          stackWasRunning:$stackWasRunning, stackRestarted:$stackRestarted}'
}

cmd_update() {
    require_docker || return 1
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would backup, pull pinned images, then compose up -d"
        cmd_backup
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    cmd_backup >/dev/null
    run_compose pull
    run_compose up -d
    pz_info "homelab updated using pinned compose tags"
}

capabilities_cli() {
    # Test seam: PZ_HOMELAB_CAPABILITIES_CLI overrides the real engine.
    if [ -n "${PZ_HOMELAB_CAPABILITIES_CLI:-}" ]; then
        # Intentional word-splitting: the override is a command line.
        # shellcheck disable=SC2086
        printf '%s\n' $PZ_HOMELAB_CAPABILITIES_CLI
        return 0
    fi
    printf '%s\n' "$PZ_ROOT/linux/pz" capabilities
}

prepare_missing_deps() {
    local -a missing=()
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    docker compose version >/dev/null 2>&1 || missing+=("compose")
    [ "${#missing[@]}" -gt 0 ] && printf '%s\n' "${missing[@]}"
    return 0
}

prepare_install_deps() {
    # PZ-AUD-002: one approval (this invocation) covers the whole plan:
    # create the capabilities plan, then apply it with its own token.
    local plan_json plan_id token apply_out
    mapfile -t cap_args < <(capabilities_cli)
    plan_json="$("${cap_args[@]}" plan --capability development.docker --capability development.docker-compose 2>/dev/null)" || {
        pz_error "capabilities plan for docker/compose failed"
        return 1
    }
    plan_id="$(jq -r '.planId // .plan_id // .id // empty' <<< "$plan_json")"
    token="$(jq -r '.confirmToken // .confirm_token // .token // empty' <<< "$plan_json")"
    # shellcheck disable=SC2015 # guarda: sem plano/token, aborta com erro
    [ -n "$plan_id" ] && [ -n "$token" ] || {
        pz_error "capabilities plan returned no plan-id/token"
        return 1
    }
    apply_out="$("${cap_args[@]}" apply --plan-id "$plan_id" --confirm "$token" 2>/dev/null)" || {
        pz_error "capabilities apply for docker/compose failed"
        return 1
    }
    [ "$(jq -r '.ok // false' <<< "$apply_out")" = "true" ] || {
        pz_error "capabilities apply did not report ok"
        return 1
    }
    return 0
}

prepare_ensure_daemon() {
    docker info >/dev/null 2>&1 && return 0
    # Installed but inactive: enable + start once via the admin bridge.
    pz_admin_run systemctl enable --now docker >/dev/null 2>&1 || return 1
    local i
    for i in $(seq 1 15); do
        docker info >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

prepare_ensure_access() {
    # Returns 0 when this session can drive the daemon, 2 when group
    # membership was configured but the session needs a re-login, 1 on
    # failure. Installing the package, starting the daemon and granting
    # access are distinct steps; group access grants elevated privileges
    # and always needs a fresh session (Docker post-install).
    docker info >/dev/null 2>&1 && return 0
    local user="${USER:-$(id -un 2>/dev/null)}"
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        pz_error "user $user is in docker group but this session cannot reach the daemon; log out and back in, then re-run prepare"
        return 2
    fi
    pz_admin_run usermod -aG docker "$user" >/dev/null 2>&1 || return 1
    pz_error "user $user added to docker group; log out and back in, then re-run prepare (group access needs a fresh session)"
    return 2
}

default_prepare_apps() {
    if [ -f "$APPS_CATALOG" ]; then
        jq -r '[.apps[] | select(.userFacing == true and .defaultEnabled == true) | .key] | .[]' "$APPS_CATALOG" 2>/dev/null
    fi
}

cmd_prepare() {
    # PZ-AUD-002: the install path. Dependencies -> daemon -> access ->
    # configure -> apps -> verify, idempotent, one approval, honest states.
    local -a steps=() apps=()
    local step_status="failed" next_action="" detail=""
    # REV-006/007: the plan is typed. It carries the host it targets and the
    # profile the operator reviewed; the Player binds its confirmation to
    # exactly this identity, and an unknown profile fails closed first.
    local host_alias="${PZ_HOMELAB_HOST_ALIAS:-local}"
    # R01-003: the plan states the profile truth. Today every appliance
    # profile is budget-only (installable:false with no service recipe), so
    # the plan carries installable/note/services/budget explicitly instead
    # of silently implying that profile.active delivers the profile's
    # services. Apps enabled by prepare come from the catalog defaults.
    local prep_installable="null" prep_note="" prep_services="null" prep_budget="null"
    if [ -n "$HOMELAB_PROFILE" ]; then
        local prep_cov prep_def
        prep_cov="$(profile_coverage_json)"
        if [ "$(jq -r '.known' <<< "$prep_cov")" != true ]; then
            pz_error "prepare: unknown profile $HOMELAB_PROFILE"
            return 2
        fi
        prep_installable="$(jq -r '.installable' <<< "$prep_cov")"
        if [ "$prep_installable" != "true" ]; then
            prep_note="$(jq -r '.installNote // "no install recipe yet"' <<< "$prep_cov")"
        fi
        prep_def="$(profile_definition_json)"
        prep_services="$(jq -c '.services // []' <<< "$prep_def" 2>/dev/null || echo '[]')"
        prep_budget="$(profile_budget_json)"
    fi
    step() { steps+=("$(jq -cn --arg name "$1" --arg status "$2" --arg detail "${3:-}" '{name:$name, status:$status, detail:$detail}')"); }
    finish() {
        local ok="$1" state="$2"
        jq -n --argjson ok "$ok" --arg state "$state" \
            --argjson steps "$(printf '%s\n' "${steps[@]}" | jq -cs '.')" \
            --arg nextAction "$next_action" \
            --arg host "$host_alias" --arg profile "$HOMELAB_PROFILE" \
            --argjson installable "$prep_installable" --arg note "$prep_note" \
            --argjson services "$prep_services" --argjson budget "$prep_budget" \
            '{action:"prepare", tool:"homelab-stack", ok:$ok, state:$state, steps:$steps,
              host:$host, profile:(if $profile == "" then null else $profile end),
              profileInstallable:$installable,
              profileNote:(if $installable == false then $note else null end),
              profileServices:$services, budget:$budget,
              appsSource:"catalog-defaults",
              nextAction:(if $nextAction == "" then null else $nextAction end)}'
        [ "$ok" = true ]
    }
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        apps=("${PREPARE_APPS[@]}")
        [ "${#apps[@]}" -gt 0 ] || mapfile -t apps < <(default_prepare_apps)
        jq -n --argjson apps "$(printf '%s\n' "${apps[@]}" | jq -R . | jq -cs .)" \
            --arg access "$ACCESS_MODE" \
            --arg host "$host_alias" --arg profile "$HOMELAB_PROFILE" \
            --argjson installable "$prep_installable" --arg note "$prep_note" \
            --argjson services "$prep_services" --argjson budget "$prep_budget" \
            '{action:"prepare", dryRun:true, host:$host,
              profile:(if $profile == "" then null else $profile end),
              profileInstallable:$installable,
              profileNote:(if $installable == false then $note else null end),
              profileServices:$services, budget:$budget,
              appsSource:"catalog-defaults",
              access:$access, apps:$apps,
              steps:["dependencies","daemon","access","configure","apps","verify"]}'
        return 0
    fi
    apps=("${PREPARE_APPS[@]}")
    [ "${#apps[@]}" -gt 0 ] || mapfile -t apps < <(default_prepare_apps)
    # 1. dependencies
    local -a missing=()
    mapfile -t missing < <(prepare_missing_deps)
    if [ "${#missing[@]}" -gt 0 ]; then
        if prepare_install_deps; then
            mapfile -t missing < <(prepare_missing_deps)
            if [ "${#missing[@]}" -gt 0 ]; then
                step dependencies failed "still missing after install: ${missing[*]}"
                next_action="inspect capabilities apply output; then re-run: pz server homelab prepare"
                finish false failed
                return 1
            fi
            step dependencies installed "installed via capabilities: development.docker + development.docker-compose"
        else
            step dependencies failed "could not install: ${missing[*]}"
            next_action="install docker + compose for your distro, then re-run: pz server homelab prepare"
            finish false failed
            return 1
        fi
    else
        step dependencies ready "docker + compose present"
    fi
    # 2. daemon
    if prepare_ensure_daemon; then
        step daemon ready "engine reachable"
    else
        step daemon failed "engine not reachable and could not be started (admin bridge needed)"
        next_action="start the docker daemon (systemctl enable --now docker), then re-run: pz server homelab prepare"
        finish false failed
        return 1
    fi
    # 3. access
    local access_rc=0
    prepare_ensure_access || access_rc=$?
    if [ "$access_rc" = "0" ]; then
        step access ready "session drives the daemon"
    elif [ "$access_rc" = "2" ]; then
        step access needs-reauth "group configured; fresh session required"
        next_action="log out and back in, then re-run: pz server homelab prepare"
        finish false needs-reauth
        return 1
    else
        step access failed "no daemon access and could not configure group (admin bridge needed)"
        next_action="grant daemon access, then re-run: pz server homelab prepare"
        finish false failed
        return 1
    fi
    # 4. configure
    ensure_env_file "$ACCESS_MODE" || {
        step configure failed "could not write homelab .env"
        finish false failed
        return 1
    }
    if [ -n "$HOMELAB_PROFILE" ]; then
        # REV-007/R01-003: the reviewed profile selection drives the
        # RESOURCE BUDGET (governor reads profile.active). It does not
        # claim the profile's services are installed — the plan states
        # installable/note and apps stay catalog-driven.
        mkdir -p "$HOMELAB_STATE"
        printf '%s\n' "$HOMELAB_PROFILE" > "$HOMELAB_STATE/profile.active"
    fi
    step configure ready ".env ensured (access=$ACCESS_MODE)"
    # 5. apps
    local app enable_out
    for app in "${apps[@]}"; do
        enable_out="$(bash "$PZ_ROOT/linux/server/homelab-apps.sh" enable "$app" --json 2>/dev/null)" || {
            step apps failed "enable $app failed: $(jq -r '.reason // "unknown"' <<< "$enable_out" 2>/dev/null || echo unknown)"
            next_action="fix the reported cause, then re-run: pz server homelab prepare"
            finish false failed
            return 1
        }
    done
    if ! bash "$PZ_ROOT/linux/server/homelab-stack.sh" reconcile --access "$ACCESS_MODE" >/dev/null 2>&1; then
        step apps failed "reconcile failed after enable"
        next_action="check compose output, then re-run: pz server homelab prepare"
        finish false failed
        return 1
    fi
    step apps ready "enabled + reconciled: ${apps[*]}"
    # 6. verify
    local status_json ready
    status_json="$(bash "$PZ_ROOT/linux/server/homelab-status.sh" status --json 2>/dev/null)" || {
        step verify failed "status collection failed"
        finish false failed
        return 1
    }
    ready="$(jq -r '.ready' <<< "$status_json")"
    if [ "$ready" = "true" ]; then
        step verify ready "homelab ready"
        finish true ready
        return 0
    fi
    step verify failed "not ready: $(jq -r '.reasons[:3] | join("; ")' <<< "$status_json")"
    next_action="review status reasons, then re-run: pz server homelab prepare"
    finish false failed
    return 1
}

cmd_repair() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would generate missing secrets and validate compose"
        cmd_plan
        return 0
    fi
    ensure_env_file "$ACCESS_MODE"
    if compose_available && [ -f "$CORE_FILE" ]; then
        run_compose config --services >/dev/null || pz_warn "compose config reported issues"
    fi
    if [ "$ACCESS_MODE" = "tailscale" ]; then
        ensure_tailscale || true
    fi
    cmd_plan
}

case "$ACTION" in
    up|install|start) cmd_up ;;
    down|stop) cmd_down ;;
    restart) cmd_down; cmd_up ;;
    reconcile) cmd_reconcile ;;
    prepare) cmd_prepare ;;
    tailscale) ensure_tailscale ;;
    status) cmd_status ;;
    plan|dry-run) PZ_DRY_RUN="${PZ_DRY_RUN:-0}" cmd_plan ;;
    open) cmd_open ;;
    logs|log) cmd_logs ;;
    backup) if [ "$VERIFY_MODE" = "1" ]; then cmd_verify_backup --source "$SOURCE"; else cmd_backup; fi ;;
    restore) cmd_restore ;;
    update) cmd_update ;;
    repair) cmd_repair ;;
    *) pz_error "usage: homelab-stack.sh (up|down|restart|tailscale|status|plan|open|logs|backup|restore|update|repair) [--extras]"; exit 2 ;;
esac
