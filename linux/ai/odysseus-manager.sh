#!/usr/bin/env bash
# PhaseZero provisioner for the official Odysseus AI workspace.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true
REPO="https://github.com/pewdiepie-archdaemon/odysseus.git"
BRANCH="dev"
ROOT="${PZ_ODYSSEUS_ROOT:-$HOME/.local/share/phasezero/odysseus}"
RELEASES="$ROOT/releases"
CURRENT="$ROOT/current"
DATA="$ROOT/data"
LOGS="$ROOT/logs"
BACKUPS="$ROOT/backups"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/odysseus"
ENV_FILE="$CONFIG/odysseus.env"
MANIFEST="$CONFIG/manifest.json"
LOCK_FILE="$CONFIG/compose.images.lock.yml"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="phasezero-odysseus.service"
COMPOSE_WRAPPER="${PZ_LOCAL_BIN:-$HOME/.local/bin}/phasezero-odysseus-compose"
ENDPOINT="http://127.0.0.1:7000"
ROUTER_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies/9router.env"
DASHBOARD_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/phasezero-odysseus.desktop"
ROUTER_PROXY="$CONFIG/router-proxy.py"
ROUTER_ENTRYPOINT="$CONFIG/entrypoint-router.sh"
ROUTER_SOCKET_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero"

ensure_dirs() {
    install -d -m 0700 "$ROOT" "$RELEASES" "$DATA" "$LOGS" "$BACKUPS" "$CONFIG"
    install -d "$(dirname "$COMPOSE_WRAPPER")" "$SYSTEMD_USER_DIR"
}

require_runtime() {
    command -v git >/dev/null || { pz_error "git required"; return 1; }
    command -v podman >/dev/null || { pz_error "rootless Podman required"; return 1; }
    podman info >/dev/null 2>&1 || { pz_error "Podman user runtime unavailable"; return 1; }
    podman compose version >/dev/null 2>&1 || { pz_error "Podman Compose provider unavailable"; return 1; }
}

remote_sha() {
    git ls-remote "$REPO" "refs/heads/$BRANCH" | awk 'NR==1 {print $1}'
}

current_sha() {
    jq -r '.commit // empty' "$MANIFEST" 2>/dev/null || true
}

router_key() {
    awk -F= '$1=="PHASEZERO_9ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' "$ROUTER_ENV" 2>/dev/null || true
}

random_secret() {
    openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-'
}

write_env() {
    local admin_password searxng_secret key
    admin_password="$(awk -F= '$1=="ODYSSEUS_ADMIN_PASSWORD" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true)"
    searxng_secret="$(awk -F= '$1=="SEARXNG_SECRET" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true)"
    [ -n "$admin_password" ] || admin_password="pz-$(random_secret)"
    [ -n "$searxng_secret" ] || searxng_secret="$(random_secret)"
    key="$(router_key)"
    umask 077
    {
        printf 'COMPOSE_PROJECT_NAME=phasezero-odysseus\n'
        printf 'APP_BIND=127.0.0.1\nAPP_PORT=7000\n'
        printf 'APP_DATA_DIR=%s\nAPP_LOGS_DIR=%s\n' "$DATA" "$LOGS"
        printf 'AUTH_ENABLED=true\nLOCALHOST_BYPASS=false\nSECURE_COOKIES=false\n'
        printf 'ODYSSEUS_ADMIN_USER=admin\nODYSSEUS_ADMIN_PASSWORD=%s\n' "$admin_password"
        printf 'ALLOWED_ORIGINS=http://127.0.0.1:7000,http://localhost:7000\n'
        printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)"
        printf 'SEARXNG_SECRET=%s\n' "$searxng_secret"
        printf 'LLM_HOST=127.0.0.1:20128\n'
        printf 'LLM_HOSTS=127.0.0.1:20128\n'
        printf 'OPENAI_API_KEY=%s\n' "$key"
        printf 'RESEARCH_LLM_ENDPOINT=http://127.0.0.1:20128/v1/chat/completions\n'
        printf 'CLEANUP_INTERVAL_HOURS=24\n'
    } > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
}

write_runtime() {
    local provider
    provider="$(command -v docker-compose || command -v podman-compose || true)"
    [ -n "$provider" ] || { pz_error "Compose provider missing"; return 1; }
    pz_write_managed_file "$COMPOSE_WRAPPER" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PODMAN_COMPOSE_PROVIDER="$provider"
exec "$(command -v podman)" compose --env-file "$ENV_FILE" -f "$CURRENT/docker-compose.yml" -f "$LOCK_FILE" --project-directory "$CURRENT" "\$@"
EOF
    chmod 0700 "$COMPOSE_WRAPPER"
    install -d "$(dirname "$DASHBOARD_ENTRY")"
    pz_write_managed_file "$DASHBOARD_ENTRY" user <<EOF
[Desktop Entry]
Type=Application
Name=Odysseus
Comment=PhaseZero agnostic AI workspace
Exec=$HOME/.local/share/phasezero/current/linux/pz ai odysseus open
Icon=phasezero-odysseus
Terminal=false
Categories=X-PhaseZero-WebApp;
X-PHZ-Group=ia
X-PhaseZero-MenuGroup=web.ai
X-PhaseZero-Managed=true
EOF
    chmod 0644 "$DASHBOARD_ENTRY"
    if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$(dirname "$DASHBOARD_ENTRY")" >/dev/null 2>&1 || true; fi
    pz_write_managed_file "$SYSTEMD_USER_DIR/$SERVICE" user <<EOF
[Unit]
Description=PhaseZero Odysseus AI workspace (rootless Podman)
After=network-online.target podman.socket phasezero-9router.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$COMPOSE_WRAPPER up -d
ExecStop=$COMPOSE_WRAPPER down
TimeoutStartSec=1800
TimeoutStopSec=180

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
}

write_router_proxy() {
    pz_write_managed_file "$ROUTER_PROXY" user <<'PY'
#!/usr/bin/env python3
import asyncio
import contextlib

SOCKET = "/run/phasezero-host/9router.sock"

async def copy(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        with contextlib.suppress(Exception):
            writer.close()
            await writer.wait_closed()

async def handle(client_reader, client_writer):
    try:
        router_reader, router_writer = await asyncio.open_unix_connection(SOCKET)
    except Exception:
        client_writer.close()
        await client_writer.wait_closed()
        return
    await asyncio.gather(
        copy(client_reader, router_writer),
        copy(router_reader, client_writer),
    )

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", 20128)
    async with server:
        await server.serve_forever()

asyncio.run(main())
PY
    chmod 0644 "$ROUTER_PROXY"
    pz_write_managed_file "$ROUTER_ENTRYPOINT" user <<'SH'
#!/bin/sh
set -eu
/usr/local/bin/python /run/phasezero-config/router-proxy.py &
[ "$#" -gt 0 ] || set -- uvicorn app:app --host 0.0.0.0 --port 7000
exec /usr/local/bin/entrypoint.sh "$@"
SH
    chmod 0755 "$ROUTER_ENTRYPOINT"
}

record_runtime_image() {
    local image tmp
    image="$(podman inspect phasezero-odysseus-odysseus-1 --format '{{.Image}}' 2>/dev/null || true)"
    [ -n "$image" ] || return 0
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    jq --arg image "$image" '.runtimeImage=$image' "$MANIFEST" > "$tmp"
    install -m 0600 "$tmp" "$MANIFEST"
    rm -f "$tmp"
}

lock_images() {
    local chroma searx ntfy
    pz_info "Resolving Odysseus dependency image digests"
    podman pull docker.io/chromadb/chroma:latest >/dev/null
    podman pull docker.io/searxng/searxng:2026.5.31-7159b8aed >/dev/null
    podman pull docker.io/binwiederhier/ntfy:latest >/dev/null
    chroma="$(podman image inspect docker.io/chromadb/chroma:latest --format '{{index .RepoDigests 0}}')"
    searx="$(podman image inspect docker.io/searxng/searxng:2026.5.31-7159b8aed --format '{{index .RepoDigests 0}}')"
    ntfy="$(podman image inspect docker.io/binwiederhier/ntfy:latest --format '{{index .RepoDigests 0}}')"
    [[ "$chroma" == *@sha256:* && "$searx" == *@sha256:* && "$ntfy" == *@sha256:* ]] || {
        pz_error "dependency image digest resolution failed"
        return 1
    }
    pz_write_managed_file "$LOCK_FILE" user <<EOF
services:
  odysseus:
    mem_limit: ${PZ_ODYSSEUS_MEMORY_LIMIT:-6g}
    cpus: ${PZ_ODYSSEUS_CPUS:-5.0}
    pids_limit: 1024
    security_opt:
      - no-new-privileges:true
    volumes:
      - $ROUTER_SOCKET_DIR:/run/phasezero-host
      - $ROUTER_PROXY:/run/phasezero-config/router-proxy.py:ro
      - $ROUTER_ENTRYPOINT:/run/phasezero-config/entrypoint-router.sh:ro
    entrypoint:
      - /run/phasezero-config/entrypoint-router.sh
  chromadb:
    image: $chroma
    mem_limit: 2g
    cpus: 2.0
    pids_limit: 512
  searxng:
    image: $searx
    mem_limit: 1g
    cpus: 1.0
    pids_limit: 256
  ntfy:
    image: $ntfy
    mem_limit: 256m
    cpus: 0.5
    pids_limit: 128
EOF
    chmod 0600 "$LOCK_FILE"
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    jq --arg chroma "$chroma" --arg searx "$searx" --arg ntfy "$ntfy" \
        '.dependencyImages={chromadb:$chroma,searxng:$searx,ntfy:$ntfy}' "$MANIFEST" > "$tmp"
    install -m 0600 "$tmp" "$MANIFEST"
    rm -f "$tmp"
}

install_release() {
    local expected="${1:-}" temporary head destination tree signature
    [ -n "$expected" ] || expected="$(remote_sha)"
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { pz_error "invalid Odysseus commit"; return 1; }
    destination="$RELEASES/$expected"
    if [ ! -d "$destination/.git" ]; then
        temporary="$RELEASES/.stage-$expected-$$"
        rm -rf "$temporary"
        git clone --filter=blob:none --depth=1 --branch "$BRANCH" "$REPO" "$temporary"
        head="$(git -C "$temporary" rev-parse HEAD)"
        [ "$head" = "$expected" ] || {
            rm -rf "$temporary"
            pz_error "Odysseus branch changed during verification; retry"
            return 1
        }
        git -C "$temporary" remote set-url --push origin DISABLED
        mv "$temporary" "$destination"
    fi
    tree="$(git -C "$destination" rev-parse 'HEAD^{tree}')"
    signature="$(git -C "$destination" log -1 --format='%G?' 2>/dev/null || echo N)"
    ln -sfn "$destination" "$CURRENT"
    jq -n --arg source "$REPO" --arg branch "$BRANCH" --arg commit "$expected" \
        --arg tree "$tree" --arg signature "$signature" --arg installedAt "$(date -Iseconds)" \
        '{schemaVersion:1,source:$source,branch:$branch,commit:$commit,tree:$tree,gitSignature:$signature,releaseModel:"pinned-commit",installedAt:$installedAt}' > "$MANIFEST"
    chmod 0600 "$MANIFEST"
}

harden_build_context() {
    local script="$CURRENT/docker/build-realesrgan-wheels.sh" dockerfile="$CURRENT/Dockerfile" patch_hash tmp
    [ -f "$script" ] || { pz_error "Odysseus Real-ESRGAN build helper missing"; return 1; }
    if ! grep -Fq 'PHASEZERO: pure-Python wheel build' "$script"; then
        # shellcheck disable=SC2016 # literal ${OUT} must stay unexpanded in sed pattern
        sed -i '/echo ">> building wheels into ${OUT}"/i\
# PHASEZERO: pure-Python wheel build; setup_requires pulls Torch/CUDA needlessly.\
sed -E -i "s/setup_requires=\\[[^]]*\\]/setup_requires=[]/" ./*/setup.py' "$script"
    fi
    if ! grep -Fq 'PHASEZERO_APT_RETRY' "$dockerfile"; then
        sed -i '1i# PHASEZERO_APT_RETRY: rootless build DNS resilience (IPv4 + bounded retries).' "$dockerfile"
        sed -i 's/apt-get update/apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true update/g; s/apt-get install/apt-get -o Acquire::Retries=5 -o Acquire::ForceIPv4=true install/g' "$dockerfile"
    fi
    patch_hash="$(git -C "$CURRENT" diff -- Dockerfile docker/build-realesrgan-wheels.sh | sha256sum | awk '{print $1}')"
    [ -n "$patch_hash" ] || { pz_error "Odysseus build patch hash missing"; return 1; }
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    jq --arg hash "$patch_hash" \
        '.localPatches=[{id:"phasezero-container-build-hardening",sha256:$hash,reason:"avoid Torch/CUDA setup_requires; force bounded IPv4 APT retries"}]' \
        "$MANIFEST" > "$tmp"
    install -m 0600 "$tmp" "$MANIFEST"
    rm -f "$tmp"
}

wait_ready() {
    local timeout="${1:-300}" i
    for ((i=0; i<timeout; i++)); do
        curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1 && return 0
        sleep 1
    done
    pz_error "Odysseus did not become ready within ${timeout}s"
    return 1
}

provision() {
    ensure_dirs
    require_runtime
    install_release
    harden_build_context
    write_env
    write_router_proxy
    lock_images
    write_runtime
    "$COMPOSE_WRAPPER" build
    systemctl --user enable "$SERVICE" >/dev/null
    if [ "$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)" = active ]; then
        systemctl --user restart "$SERVICE"
    else
        systemctl --user start "$SERVICE"
    fi
    wait_ready 600
    record_runtime_image
    status_json
}

status_json() {
    local installed=false service healthy=false containers='[]' sha latest=""
    [ -L "$CURRENT" ] && [ -f "$CURRENT/docker-compose.yml" ] && installed=true
    service="$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)"; service="${service:-inactive}"
    curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1 && healthy=true
    if command -v podman >/dev/null 2>&1; then
        containers="$(podman ps -a --filter label=com.docker.compose.project=phasezero-odysseus --format json 2>/dev/null \
            | jq '[.[] | {name:(.Names[0] // .Names // ""),state:(.State // .Status // "unknown"),image:(.Image // "")}]' 2>/dev/null || echo '[]')"
    fi
    sha="$(current_sha)"
    jq -cn --argjson installed "$installed" --arg service "$service" --argjson healthy "$healthy" \
        --arg endpoint "$ENDPOINT" --arg commit "$sha" --arg manifest "$MANIFEST" --arg credentials "$ENV_FILE" \
        --argjson containers "$containers" \
        '{schemaVersion:1,id:"odysseus",installed:$installed,service:$service,healthy:$healthy,endpoint:$endpoint,commit:$commit,releaseModel:"pinned-commit",containers:$containers,manifestPath:$manifest,credentialsPath:$credentials,secretsRedacted:true}'
}

check_update() {
    local current latest
    current="$(current_sha)"; latest="$(remote_sha)"
    jq -cn --arg current "$current" --arg latest "$latest" \
        '{id:"odysseus",branch:"dev",releaseAvailable:false,currentCommit:$current,latestCommit:$latest,updateAvailable:($current!=$latest),policy:"manual-pinned-commit"}'
}

update_odysseus() {
    local before latest
    before="$(current_sha)"; latest="$(remote_sha)"
    [ -n "$before" ] || { provision; return; }
    [ "$before" != "$latest" ] || { check_update; return; }
    systemctl --user stop "$SERVICE" >/dev/null 2>&1 || true
    install_release "$latest"
    harden_build_context
    write_env
    write_router_proxy
    lock_images
    write_runtime
    if ! "$COMPOSE_WRAPPER" build; then
        install_release "$before"
        harden_build_context
        write_runtime
        pz_error "Odysseus image build failed; previous commit restored"
        return 1
    fi
    if ! systemctl --user start "$SERVICE" || ! wait_ready 600; then
        install_release "$before"
        harden_build_context
        write_runtime
        systemctl --user start "$SERVICE" >/dev/null 2>&1 || true
        pz_error "Odysseus update failed; previous commit restored"
        return 1
    fi
    record_runtime_image
    status_json
}

backup_data() {
    local output="$BACKUPS/odysseus-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C "$ROOT" -czf "$output" data
    chmod 0600 "$output"
    jq -cn --arg path "$output" --arg sha256 "$(sha256sum "$output" | awk '{print $1}')" '{status:"complete",backup:$path,sha256:$sha256}'
}

doctor_odysseus() {
    local compose=false rootless=false env_mode="missing" current=false auth=false bypass=true socket=false images_locked=false router_bridge=false
    if podman compose version >/dev/null 2>&1; then compose=true; fi
    [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)" = true ] && rootless=true
    [ -f "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE")"
    [ -f "$CURRENT/docker-compose.yml" ] && current=true
    grep -qx 'AUTH_ENABLED=true' "$ENV_FILE" 2>/dev/null && auth=true
    grep -qx 'LOCALHOST_BYPASS=false' "$ENV_FILE" 2>/dev/null && bypass=false
    if grep -Rqs '/var/run/docker.sock' "$CONFIG" 2>/dev/null; then socket=true; fi
    [ "$(grep -c '@sha256:' "$LOCK_FILE" 2>/dev/null || true)" -eq 3 ] && images_locked=true
    [ -S "$ROUTER_SOCKET_DIR/9router.sock" ] && router_bridge=true
    jq -cn --argjson compose "$compose" --argjson rootless "$rootless" --arg envMode "$env_mode" \
        --argjson current "$current" --argjson auth "$auth" --argjson bypass "$bypass" --argjson socket "$socket" --argjson locked "$images_locked" --argjson routerBridge "$router_bridge" \
        '{id:"odysseus",compose:$compose,rootless:$rootless,currentRelease:$current,dependencyImagesLocked:$locked,envMode:$envMode,authEnabled:$auth,localhostBypass:$bypass,dockerSocketMounted:$socket,routerPrivateBridge:$routerBridge,secure:($compose and $rootless and $current and $locked and $envMode=="600" and $auth and ($bypass|not) and ($socket|not) and $routerBridge),secretsRedacted:true}'
}

open_ui() {
    xdg-open "$ENDPOINT" >/dev/null 2>&1 &
    pz_info "Odysseus opened: $ENDPOINT"
}

case "$ACTION" in
    install|setup|provision) provision ;;
    status) status_json ;;
    check|check-update) check_update ;;
    update|upgrade) update_odysseus ;;
    start) systemctl --user enable --now "$SERVICE"; wait_ready 600 ;;
    stop) systemctl --user disable --now "$SERVICE" ;;
    restart) systemctl --user restart "$SERVICE"; wait_ready 600 ;;
    open|dashboard) open_ui ;;
    logs) "$COMPOSE_WRAPPER" logs --tail "${1:-150}" ;;
    backup) backup_data ;;
    doctor|health) doctor_odysseus ;;
    credentials-path) printf '%s\n' "$ENV_FILE" ;;
    *) pz_error "usage: pz ai odysseus (status|install|start|stop|restart|open|logs|check-update|update|backup|doctor|credentials-path)"; exit 2 ;;
esac
