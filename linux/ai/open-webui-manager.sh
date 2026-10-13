#!/usr/bin/env bash
# Read-only status and explicit browser open for the existing Open WebUI container.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

container_name="open-webui"
container_port="8080/tcp"

container_exists() {
    local names
    names="$(timeout 5 docker ps -a --filter "name=^/${container_name}$" --format '{{.Names}}' 2>/dev/null)" || return 2
    grep -Fxq "$container_name" <<< "$names"
}

container_running() {
    local names
    names="$(timeout 5 docker ps --filter "name=^/${container_name}$" --format '{{.Names}}' 2>/dev/null)" || return 2
    grep -Fxq "$container_name" <<< "$names"
}

host_port() {
    local bindings port
    bindings="$(timeout 5 docker port "$container_name" "$container_port" 2>/dev/null)" || return 1
    port="$(sed -n '1{s/.*://;p;}' <<< "$bindings")"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    printf '%s\n' "$port"
}

http_ready() {
    local port="$1" code rc
    if code="$(timeout 4 curl --silent --show-error --output /dev/null --connect-timeout 1 --max-time 3 --write-out '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)"; then
        case "$code" in
            [234][0-9][0-9]) printf 'online\n' ;;
            5[0-9][0-9]) printf 'failed\n' ;;
            *) printf 'unknown\n' ;;
        esac
    else
        rc=$?
        case "$rc" in
            7) printf 'offline\n' ;;
            *) printf 'unknown\n' ;;
        esac
    fi
}

status_json() {
    local installed=false health=unknown config=unknown port="" has_status=true
    if ! command -v docker >/dev/null 2>&1; then
        has_status=false
    elif container_exists; then
        installed=true
        if container_running; then
            if port="$(host_port)"; then
                config=ready
                health="$(http_ready "$port")"
            fi
        else
            local rc=$?
            if [ "$rc" -eq 2 ]; then
                has_status=false
                installed=false
            else
                config=ready
                health=offline
            fi
        fi
    else
        local rc=$?
        if [ "$rc" -eq 2 ]; then has_status=false; else config=needed; fi
    fi

    jq -cn \
        --argjson hasStatus "$has_status" --argjson installed "$installed" \
        --arg configuration "$config" --arg health "$health" --arg port "$port" \
        '{schemaVersion:1,id:"open-webui",hasStatus:$hasStatus,
          installationState:(if ($hasStatus|not) then "unknown" elif $installed then "present" else "absent" end),
          origin:"unknown",configurationState:$configuration,health:$health,
          usageBlocked:true,blockedReason:"connection-grant-not-enforceable",
          dashboardUrl:(if $port!="" then "http://127.0.0.1:"+$port+"/" else "" end),
          error:(if ($hasStatus|not) then "backend-unavailable" else null end)}'
}

case "${1:-status}" in
    status) status_json ;;
    open|dashboard)
        pz_error "Open WebUI usage blocked: provider connections can hold shared credentials, but requests are not bound to PhaseZero grants"
        exit 69
        ;;
    *) pz_error "usage: open-webui-manager.sh (status|open)"; exit 2 ;;
esac
