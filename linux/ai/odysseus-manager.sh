#!/usr/bin/env bash
# PhaseZero provisioner for the official Odysseus AI workspace.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true
REPO="https://github.com/odysseus-dev/odysseus.git"
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
TRUSTED_COMMITS_FILE="${PZ_ODYSSEUS_TRUSTED_COMMITS_FILE:-$PZ_ROOT/assets/ai/odysseus-trusted-commits.json}"
TRUSTED_IMAGES_FILE="${PZ_ODYSSEUS_TRUSTED_IMAGES_FILE:-$PZ_ROOT/assets/ai/odysseus-dependency-images.json}"
TRUSTED_BUILD_BASES_FILE="${PZ_ODYSSEUS_TRUSTED_BUILD_BASES_FILE:-$PZ_ROOT/assets/ai/odysseus-build-bases.json}"
RELEASE_AUDIT_FILE="${PZ_ODYSSEUS_RELEASE_AUDIT_FILE:-$PZ_ROOT/assets/ai/odysseus-release-audit.json}"

trusted_build_base_valid() {
    [ -f "$TRUSTED_BUILD_BASES_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and .trustMode == "registry-manifest-digest" and
      .semanticAudit == false and (.images | length == 1) and
      .images[0].service == "odysseus-python" and
      .images[0].repository == "docker.io/library/python" and
      .images[0].versionTag == "3.14-slim" and
      (.images[0].digest | test("^sha256:[0-9a-f]{64}$")) and
      .images[0].reference == (.images[0].repository + "@" + .images[0].digest) and
      .images[0].mediaType == "application/vnd.oci.image.index.v1+json" and
      .images[0].registryHeaderMatchedBodySha256 == true and
      .images[0].approvedForBuild == true
    ' "$TRUSTED_BUILD_BASES_FILE" >/dev/null 2>&1
}

trusted_build_base_reference() {
    trusted_build_base_valid || return 1
    jq -er '.images[0].reference' "$TRUSTED_BUILD_BASES_FILE"
}

release_audit_valid() {
    [ -f "$RELEASE_AUDIT_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and .id == "odysseus" and
      .source.repository == "https://github.com/odysseus-dev/odysseus.git" and
      .source.branch == "dev" and
      (.source.commit | test("^[0-9a-f]{40}$")) and
      (.source.tree | test("^[0-9a-f]{40}$")) and
      (.source.commitSignatureVerified | type == "boolean") and
      (.files.LICENSE | test("^[0-9a-f]{64}$")) and
      (.files.Dockerfile | test("^[0-9a-f]{64}$")) and
      (.files["docker-compose.yml"] | test("^[0-9a-f]{64}$")) and
      (.files["pyproject.toml"] | test("^[0-9a-f]{64}$")) and
      (.files["package-lock.json"] | test("^[0-9a-f]{64}$")) and
      (.baseImagesPinned | type == "boolean") and
      (.pythonDependenciesLocked | type == "boolean") and
      (.shellExecutionSurface | type == "boolean") and
      (.dockerSocketMountedByPhaseZero | type == "boolean") and
      (.semanticAudit | type == "boolean") and
      (.approvedForDeploy | type == "boolean") and
      (.findings | type == "array" and length > 0)
    ' "$RELEASE_AUDIT_FILE" >/dev/null 2>&1
}

release_audit_approved() {
    local commit="${1:-}" tree="${2:-}"
    release_audit_valid || return 1
    jq -e --arg commit "$commit" --arg tree "$tree" '
      .source.commit == $commit and .source.tree == $tree and
      .source.commitSignatureVerified == true and .baseImagesPinned == true and
      .pythonDependenciesLocked == true and .semanticAudit == true and
      .approvedForDeploy == true and .dockerSocketMountedByPhaseZero == false
    ' "$RELEASE_AUDIT_FILE" >/dev/null 2>&1
}

release_audit_json() {
    if ! release_audit_valid; then
        jq -cn --arg manifest "$RELEASE_AUDIT_FILE" \
          '{manifestPath:$manifest,manifestValid:false,approvedForDeploy:false,semanticAudit:false,
            baseImagesPinned:false,pythonDependenciesLocked:false,shellExecutionSurface:true,
            dockerSocketMountedByPhaseZero:false,findings:[]}'
        return
    fi
    jq -c --arg manifest "$RELEASE_AUDIT_FILE" '
      {manifestPath:$manifest,manifestValid:true,commit:.source.commit,tree:.source.tree,
       commitSignatureVerified:.source.commitSignatureVerified,license:.license,
       baseImagesPinned:.baseImagesPinned,pythonDependenciesLocked:.pythonDependenciesLocked,
       shellExecutionSurface:.shellExecutionSurface,
       dockerSocketMountedByPhaseZero:.dockerSocketMountedByPhaseZero,
       semanticAudit:.semanticAudit,approvedForDeploy:.approvedForDeploy,findings:.findings}' \
      "$RELEASE_AUDIT_FILE"
}

trusted_images_valid() {
    [ -f "$TRUSTED_IMAGES_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and
      .trustMode == "registry-manifest-digest" and
      .semanticAudit == false and
      (.images | length == 3) and
      ([.images[].service] | sort == ["chromadb","ntfy","searxng"]) and
      all(.images[];
        .approvedForDeploy == true and
        (.versionTag | type == "string" and length > 0 and . != "latest") and
        (.repository | test("^docker\\.io/[a-z0-9._/-]+$")) and
        (.digest | test("^sha256:[0-9a-f]{64}$")) and
        .reference == (.repository + "@" + .digest))
    ' "$TRUSTED_IMAGES_FILE" >/dev/null 2>&1
}

trusted_image_reference() {
    local service="$1"
    trusted_images_valid || return 1
    jq -er --arg service "$service" '.images[] | select(.service == $service) | .reference' \
        "$TRUSTED_IMAGES_FILE" 2>/dev/null
}

dependency_lock_valid() {
    local service expected actual
    trusted_images_valid || return 1
    [ -f "$LOCK_FILE" ] || return 1
    for service in chromadb searxng ntfy; do
        expected="$(trusted_image_reference "$service")"
        actual="$(awk -v service="$service" '
          $0 ~ "^  " service ":$" {inside=1; next}
          inside && $0 ~ "^  [^ ]" {inside=0}
          inside && $1 == "image:" {print $2; exit}
        ' "$LOCK_FILE")"
        [ "$actual" = "$expected" ] || return 1
    done
    [ "$(grep -c '@sha256:' "$LOCK_FILE" 2>/dev/null || true)" -eq 3 ]
}

commit_allowlisted() {
    local commit="${1:-}"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    [ -f "$TRUSTED_COMMITS_FILE" ] || return 1
    jq -e --arg commit "$commit" \
        '.schemaVersion == 1 and any(.commits[]?; type == "object" and .commit == $commit and (.tree|test("^[0-9a-f]{40}$")))' \
        "$TRUSTED_COMMITS_FILE" >/dev/null 2>&1
}

trusted_tree_for_commit() {
    local commit="${1:-}"
    [ -f "$TRUSTED_COMMITS_FILE" ] || return 0
    jq -r --arg commit "$commit" \
        'first(.commits[]? | select(.commit == $commit) | .tree) // empty' \
        "$TRUSTED_COMMITS_FILE" 2>/dev/null || true
}

release_trusted() {
    local commit="${1:-}" tree="${2:-}"
    [[ "$commit" =~ ^[0-9a-f]{40}$ && "$tree" =~ ^[0-9a-f]{40}$ ]] || return 1
    [ -f "$TRUSTED_COMMITS_FILE" ] || return 1
    jq -e --arg commit "$commit" --arg tree "$tree" \
        '.schemaVersion == 1 and any(.commits[]?; type == "object" and .commit == $commit and .tree == $tree)' \
        "$TRUSTED_COMMITS_FILE" >/dev/null 2>&1
}

require_workload_release_gate() {
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && return 0
    pz_error "Odysseus changes blocked by Homelab release gate; run: pz ai workspaces plan"
    return 69
}

path_within_root() {
    local path="$1" root="$2" resolved base
    [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
    resolved="$(realpath -e -- "$path" 2>/dev/null || true)"
    base="$(realpath -m -- "$root" 2>/dev/null || true)"
    [ -n "$resolved" ] && [ -n "$base" ] && { [ "$resolved" = "$base" ] || [[ "$resolved" == "$base"/* ]]; }
}

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
    timeout 20 git ls-remote "$REPO" "refs/heads/$BRANCH" | awk 'NR==1 {print $1}'
}

current_sha() {
    jq -r '.commit // empty' "$MANIFEST" 2>/dev/null || true
}

router_credentials_ready() {
    [ -f "$ROUTER_ENV" ] || return 1
    [ "$(stat -c %a "$ROUTER_ENV" 2>/dev/null || echo unknown)" = 600 ] || return 1
    awk -F= '
        $1 == "PHASEZERO_9ROUTER_API_KEY" {
            value=$0; sub(/^[^=]*=/, "", value)
            if (value != "") found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$ROUTER_ENV"
}

random_secret() {
    openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-'
}

write_env() {
    local admin_password searxng_secret
    admin_password="$(awk -F= '$1=="ODYSSEUS_ADMIN_PASSWORD" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true)"
    searxng_secret="$(awk -F= '$1=="SEARXNG_SECRET" {sub(/^[^=]*=/,""); print; exit}' "$ENV_FILE" 2>/dev/null || true)"
    [ -n "$admin_password" ] || admin_password="pz-$(random_secret)"
    [ -n "$searxng_secret" ] || searxng_secret="$(random_secret)"
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
        printf 'RESEARCH_LLM_ENDPOINT=http://127.0.0.1:20128/v1/chat/completions\n'
        printf 'CLEANUP_INTERVAL_HOURS=24\n'
    } > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
}

write_runtime() {
    local provider
    router_credentials_ready || {
        pz_error "canonical 9Router credential reference unavailable or unsafe: $ROUTER_ENV"
        return 69
    }
    provider="$(command -v docker-compose || command -v podman-compose || true)"
    [ -n "$provider" ] || { pz_error "Compose provider missing"; return 1; }
    pz_write_managed_file "$COMPOSE_WRAPPER" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PODMAN_COMPOSE_PROVIDER="$provider"
exec "$(command -v podman)" compose --env-file "$ROUTER_ENV" --env-file "$ENV_FILE" -f "$CURRENT/docker-compose.yml" -f "$LOCK_FILE" --project-directory "$CURRENT" "\$@"
EOF
    chmod 0700 "$COMPOSE_WRAPPER"
    install -d "$(dirname "$DASHBOARD_ENTRY")"
    pz_write_managed_file "$DASHBOARD_ENTRY" user <<EOF
[Desktop Entry]
Type=Application
Name=Odysseus (uso bloqueado)
Comment=Bloqueado: inferência compartilhada do 9Router sem grant por requisição.
Exec=$HOME/.local/share/phasezero/current/linux/pz ai odysseus open
Icon=applications-science
Terminal=true
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
    trusted_images_valid || {
        pz_error "Odysseus dependency image manifest is absent or invalid: $TRUSTED_IMAGES_FILE"
        return 69
    }
    pz_info "Rendering approved Odysseus dependency image digests"
    chroma="$(trusted_image_reference chromadb)"
    searx="$(trusted_image_reference searxng)"
    ntfy="$(trusted_image_reference ntfy)"
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
    environment:
      OPENAI_API_KEY: \${PHASEZERO_9ROUTER_API_KEY:?missing canonical 9Router credential}
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
    dependency_lock_valid || {
        pz_error "generated Odysseus dependency lock differs from approved image manifest"
        return 69
    }
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    jq --arg chroma "$chroma" --arg searx "$searx" --arg ntfy "$ntfy" \
        --arg source "$TRUSTED_IMAGES_FILE" \
        '.dependencyImages={chromadb:$chroma,searxng:$searx,ntfy:$ntfy} |
         .dependencyImagePolicy={mode:"registry-manifest-digest",semanticAudit:false,source:$source}' \
        "$MANIFEST" > "$tmp"
    install -m 0600 "$tmp" "$MANIFEST"
    rm -f "$tmp"
}

install_release() {
    local expected="${1:-}" temporary head destination tree signature
    [ -n "$expected" ] || expected="$(remote_sha)"
    [[ "$expected" =~ ^[0-9a-f]{40}$ ]] || { pz_error "invalid Odysseus commit"; return 1; }
    commit_allowlisted "$expected" || {
        pz_error "Odysseus commit is absent from trusted allowlist: $expected"
        return 69
    }
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
    release_trusted "$expected" "$tree" || {
        pz_error "Odysseus tree does not match trusted allowlist: $tree"
        return 69
    }
    signature="$(git -C "$destination" log -1 --format='%G?' 2>/dev/null || echo N)"
    ln -sfn "$destination" "$CURRENT"
    jq -n --arg source "$REPO" --arg branch "$BRANCH" --arg commit "$expected" \
        --arg tree "$tree" --arg signature "$signature" --arg installedAt "$(date -Iseconds)" \
        '{schemaVersion:1,source:$source,branch:$branch,commit:$commit,tree:$tree,gitSignature:$signature,releaseModel:"pinned-commit",installedAt:$installedAt}' > "$MANIFEST"
    chmod 0600 "$MANIFEST"
}

harden_build_context() {
    local script="$CURRENT/docker/build-realesrgan-wheels.sh" dockerfile="$CURRENT/Dockerfile" patch_hash tmp base
    [ -f "$script" ] || { pz_error "Odysseus Real-ESRGAN build helper missing"; return 1; }
    base="$(trusted_build_base_reference)" || {
        pz_error "Odysseus build base manifest is absent or invalid: $TRUSTED_BUILD_BASES_FILE"
        return 69
    }
    sed -i "s|^FROM python:3.14-slim|FROM $base|g" "$dockerfile"
    if [ "$(grep -Fc "FROM $base" "$dockerfile" 2>/dev/null || true)" -ne 2 ]; then
        pz_error "Odysseus Dockerfile base layout changed; refusing unreviewed build"
        return 69
    fi
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
        --arg base "$base" --arg baseSource "$TRUSTED_BUILD_BASES_FILE" \
        '.localPatches=[{id:"phasezero-container-build-hardening",sha256:$hash,
           reason:"pin Python OCI base; avoid Torch/CUDA setup_requires; force bounded IPv4 APT retries"}] |
         .buildBase={reference:$base,source:$baseSource,trustMode:"registry-manifest-digest",semanticAudit:false}' \
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

# shellcheck disable=SC2317
# PXA-008 retains provisioning code behind its request-bound grant gate.
provision() {
    odysseus_usage_blocked
    return 69
    require_workload_release_gate
    local expected expected_tree
    expected="$(remote_sha)"
    commit_allowlisted "$expected" || {
        pz_error "Odysseus upstream has no trusted release commit: $expected"
        return 69
    }
    expected_tree="$(trusted_tree_for_commit "$expected")"
    release_audit_approved "$expected" "$expected_tree" || {
        pz_error "Odysseus release audit is incomplete or unapproved: $RELEASE_AUDIT_FILE"
        return 69
    }
    trusted_images_valid || {
        pz_error "Odysseus dependency images are not approved by digest"
        return 69
    }
    trusted_build_base_valid || {
        pz_error "Odysseus build base is not approved by digest"
        return 69
    }
    ensure_dirs
    require_runtime
    install_release "$expected"
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
    local installed=false configured=false service healthy=false ready=false containers='[]' sha="" podman_rootless=false
    local manifest_valid=false commit_is_trusted=false audit_approved=false env_mode="missing" lock_valid=false image_manifest_valid=false build_base_valid=false paths_safe=false router_credential=false audit
    [ -L "$CURRENT" ] && [ -f "$CURRENT/docker-compose.yml" ] && installed=true
    service="$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)"; service="${service:-inactive}"
    curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1 && healthy=true
    if command -v podman >/dev/null 2>&1; then
        [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)" = true ] && podman_rootless=true
        containers="$(podman ps -a --filter label=com.docker.compose.project=phasezero-odysseus --format json 2>/dev/null \
            | jq '[.[] | {name:(.Names[0] // .Names // ""),state:(.State // .Status // "unknown"),image:(.Image // "")}]' 2>/dev/null || echo '[]')"
    fi
    sha="$(current_sha)"
    [ -f "$MANIFEST" ] && jq -e '.schemaVersion == 1 and (.commit|test("^[0-9a-f]{40}$")) and (.tree|test("^[0-9a-f]{40}$"))' "$MANIFEST" >/dev/null 2>&1 && manifest_valid=true
    release_trusted "$sha" "$(jq -r '.tree // empty' "$MANIFEST" 2>/dev/null || true)" && commit_is_trusted=true
    release_audit_approved "$sha" "$(jq -r '.tree // empty' "$MANIFEST" 2>/dev/null || true)" && audit_approved=true
    audit="$(release_audit_json)"
    [ -f "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo unknown)"
    trusted_images_valid && image_manifest_valid=true
    trusted_build_base_valid && build_base_valid=true
    dependency_lock_valid && lock_valid=true
    router_credentials_ready && router_credential=true
    if path_within_root "$CURRENT" "$ROOT" && path_within_root "$ENV_FILE" "$CONFIG" &&
        path_within_root "$LOCK_FILE" "$CONFIG"; then
        paths_safe=true
    fi
    if [ "$installed" = true ] && [ "$manifest_valid" = true ] && [ "$commit_is_trusted" = true ] && [ "$audit_approved" = true ] &&
        [ "$env_mode" = 600 ] && [ "$lock_valid" = true ] && [ "$build_base_valid" = true ] && [ "$paths_safe" = true ] &&
        [ "$router_credential" = true ] && [ "$podman_rootless" = true ]; then
        configured=true
    fi
    if [ "$configured" = true ] && [ "$healthy" = true ] && [ "$service" = active ]; then
        ready=true
    fi
    jq -cn --argjson installed "$installed" --argjson configured "$configured" --argjson ready "$ready" \
        --arg service "$service" --argjson healthy "$healthy" \
        --arg endpoint "$ENDPOINT" --arg commit "$sha" --arg manifest "$MANIFEST" --arg credentials "$ENV_FILE" \
        --arg trustedCommits "$TRUSTED_COMMITS_FILE" --arg envMode "$env_mode" \
        --arg trustedImages "$TRUSTED_IMAGES_FILE" \
        --argjson containers "$containers" --argjson podmanRootless "$podman_rootless" \
        --argjson manifestValid "$manifest_valid" --argjson commitTrusted "$commit_is_trusted" \
        --argjson releaseAuditApproved "$audit_approved" --argjson releaseAudit "$audit" \
        --argjson dependencyImageManifestValid "$image_manifest_valid" \
        --argjson buildBaseManifestValid "$build_base_valid" --arg trustedBuildBases "$TRUSTED_BUILD_BASES_FILE" \
        --argjson dependencyImagesLocked "$lock_valid" --argjson pathsSafe "$paths_safe" \
        --argjson routerCredentialReference "$router_credential" \
        '{schemaVersion:1,id:"odysseus",installed:$installed,configured:$configured,ready:$ready,
          usageBlocked:true,blockedReason:"connection-grant-not-enforceable",
          service:$service,healthy:$healthy,endpoint:$endpoint,commit:$commit,releaseModel:"pinned-commit",
          podmanRootless:$podmanRootless,
          provenance:{manifestValid:$manifestValid,commitTrusted:$commitTrusted,trustedCommitsPath:$trustedCommits,
            releaseAuditApproved:$releaseAuditApproved,releaseAudit:$releaseAudit,
            dependencyImageManifestValid:$dependencyImageManifestValid,dependencyImagesLocked:$dependencyImagesLocked,
            trustedImagesPath:$trustedImages,buildBaseManifestValid:$buildBaseManifestValid,
            trustedBuildBasesPath:$trustedBuildBases,semanticAudit:false},pathsSafe:$pathsSafe,envMode:$envMode,
          routerCredential:{source:"canonical-9router-env",configured:$routerCredentialReference,secretsRedacted:true},
          containers:$containers,manifestPath:$manifest,credentialsPath:$credentials,secretsRedacted:true}'
}

odysseus_usage_blocked() {
    jq -nc '{schemaVersion:1,ok:false,status:"blocked",
      blockedReason:"connection-grant-not-enforceable",
      summary:"Uso Odysseus bloqueado: workspace encaminha inferência pela credencial compartilhada do 9Router.",
      next:"Aguarde grant por requisição aplicado ao workspace e rejeição de fallback."}'
}

check_update() {
    local current latest tree="" trusted=false audited=false
    current="$(current_sha)"; latest="$(remote_sha)"
    commit_allowlisted "$latest" && trusted=true
    tree="$(trusted_tree_for_commit "$latest")"
    release_audit_approved "$latest" "$tree" && audited=true
    jq -cn --arg current "$current" --arg latest "$latest" --argjson trusted "$trusted" --argjson audited "$audited" \
        '{schemaVersion:1,id:"odysseus",branch:"dev",releaseAvailable:$trusted,currentCommit:$current,
          latestCommit:$latest,latestCommitTrusted:$trusted,releaseAuditApproved:$audited,
          updateAvailable:($trusted and $audited and $current!=$latest),
          policy:"manual-allowlisted-commit",secretsRedacted:true}'
}

# shellcheck disable=SC2317
# PXA-008 retains update code behind its request-bound grant gate.
update_odysseus() {
    odysseus_usage_blocked
    return 69
    local before latest latest_tree
    before="$(current_sha)"; latest="$(remote_sha)"
    [ -n "$before" ] || { provision; return; }
    [ "$before" != "$latest" ] || { check_update; return; }
    commit_allowlisted "$latest" || {
        pz_error "Odysseus update commit is absent from trusted allowlist: $latest"
        return 69
    }
    latest_tree="$(trusted_tree_for_commit "$latest")"
    release_audit_approved "$latest" "$latest_tree" || {
        pz_error "Odysseus update audit is incomplete or unapproved: $RELEASE_AUDIT_FILE"
        return 69
    }
    trusted_images_valid || {
        pz_error "Odysseus dependency images are not approved by digest"
        return 69
    }
    trusted_build_base_valid || {
        pz_error "Odysseus build base is not approved by digest"
        return 69
    }
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
    local output
    output="$BACKUPS/odysseus-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -C "$ROOT" -czf "$output" data
    chmod 0600 "$output"
    jq -cn --arg path "$output" --arg sha256 "$(sha256sum "$output" | awk '{print $1}')" '{status:"complete",backup:$path,sha256:$sha256}'
}

doctor_odysseus() {
    local compose=false rootless=false env_mode="missing" current=false auth=false bypass=true socket=false images_locked=false router_bridge=false
    local manifest_valid=false trusted=false audit_approved=false image_manifest_valid=false build_base_valid=false paths_safe=false podman_available=false healthy=false service="inactive" sha="" router_credential=false audit
    command -v podman >/dev/null 2>&1 && podman_available=true
    [ "$podman_available" = true ] && podman compose version >/dev/null 2>&1 && compose=true
    [ "$podman_available" = true ] && [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)" = true ] && rootless=true
    [ -f "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE")"
    [ -f "$CURRENT/docker-compose.yml" ] && current=true
    grep -qx 'AUTH_ENABLED=true' "$ENV_FILE" 2>/dev/null && auth=true
    grep -qx 'LOCALHOST_BYPASS=false' "$ENV_FILE" 2>/dev/null && bypass=false
    if grep -Rqs '/var/run/docker.sock' "$CONFIG" 2>/dev/null; then socket=true; fi
    trusted_images_valid && image_manifest_valid=true
    trusted_build_base_valid && build_base_valid=true
    dependency_lock_valid && images_locked=true
    [ -S "$ROUTER_SOCKET_DIR/9router.sock" ] && router_bridge=true
    router_credentials_ready && router_credential=true
    sha="$(current_sha)"
    [ -f "$MANIFEST" ] && jq -e '.schemaVersion == 1 and (.commit|test("^[0-9a-f]{40}$")) and (.tree|test("^[0-9a-f]{40}$"))' "$MANIFEST" >/dev/null 2>&1 && manifest_valid=true
    release_trusted "$sha" "$(jq -r '.tree // empty' "$MANIFEST" 2>/dev/null || true)" && trusted=true
    release_audit_approved "$sha" "$(jq -r '.tree // empty' "$MANIFEST" 2>/dev/null || true)" && audit_approved=true
    audit="$(release_audit_json)"
    if path_within_root "$CURRENT" "$ROOT" && path_within_root "$ENV_FILE" "$CONFIG" && path_within_root "$LOCK_FILE" "$CONFIG"; then paths_safe=true; fi
    service="$(systemctl --user is-active "$SERVICE" 2>/dev/null || true)"; service="${service:-inactive}"
    curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1 && healthy=true
    local configured=false ready=false
    if [ "$current" = true ] && [ "$manifest_valid" = true ] && [ "$trusted" = true ] && [ "$audit_approved" = true ] &&
        [ "$images_locked" = true ] && [ "$build_base_valid" = true ] && [ "$env_mode" = 600 ] && [ "$paths_safe" = true ] &&
        [ "$router_credential" = true ]; then
        configured=true
    fi
    if [ "$configured" = true ] && [ "$compose" = true ] && [ "$rootless" = true ] &&
        [ "$auth" = true ] && [ "$bypass" = false ] && [ "$socket" = false ] &&
        [ "$router_bridge" = true ] && [ "$service" = active ] && [ "$healthy" = true ]; then
        ready=true
    fi
    jq -cn --argjson podman "$podman_available" --argjson compose "$compose" --argjson rootless "$rootless" --arg envMode "$env_mode" \
        --argjson current "$current" --argjson auth "$auth" --argjson bypass "$bypass" --argjson socket "$socket" --argjson locked "$images_locked" --argjson routerBridge "$router_bridge" \
        --argjson manifestValid "$manifest_valid" --argjson trusted "$trusted" --argjson releaseAuditApproved "$audit_approved" --argjson releaseAudit "$audit" --argjson imageManifestValid "$image_manifest_valid" --argjson buildBaseManifestValid "$build_base_valid" --argjson pathsSafe "$paths_safe" \
        --arg service "$service" --argjson healthy "$healthy" --argjson configured "$configured" --argjson ready "$ready" \
        --argjson routerCredentialReference "$router_credential" \
        '{schemaVersion:1,id:"odysseus",diagnosticComplete:true,configured:$configured,ready:$ready,podman:$podman,compose:$compose,rootless:$rootless,
          currentRelease:$current,manifestValid:$manifestValid,commitTrusted:$trusted,
          releaseAuditApproved:$releaseAuditApproved,releaseAudit:$releaseAudit,
          dependencyImageManifestValid:$imageManifestValid,dependencyImagesLocked:$locked,
          buildBaseManifestValid:$buildBaseManifestValid,
          envMode:$envMode,authEnabled:$auth,localhostBypass:$bypass,dockerSocketMounted:$socket,
          routerPrivateBridge:$routerBridge,routerCredentialReference:$routerCredentialReference,
          pathsSafe:$pathsSafe,service:$service,healthy:$healthy,
          secure:($compose and $rootless and $current and $manifestValid and $trusted and $releaseAuditApproved and $locked and $buildBaseManifestValid and
            $envMode=="600" and $auth and ($bypass|not) and ($socket|not) and $routerBridge and
            $routerCredentialReference and $pathsSafe),
          issues:([if ($podman|not) then {severity:"error",component:"odysseus",code:"podman-missing"} else empty end,
            if ($current|not) then {severity:"error",component:"odysseus",code:"odysseus-not-installed"} else empty end,
            if ($trusted|not) then {severity:"error",component:"odysseus",code:"odysseus-commit-untrusted"} else empty end,
            if ($releaseAudit.manifestValid|not) then {severity:"error",component:"odysseus",code:"odysseus-release-audit-invalid"} else empty end,
            if ($releaseAudit.approvedForDeploy|not) then {severity:"error",component:"odysseus",code:"odysseus-release-unapproved"} else empty end,
            if ($releaseAudit.baseImagesPinned|not) then {severity:"error",component:"odysseus",code:"odysseus-base-images-unpinned"} else empty end,
            if ($releaseAudit.pythonDependenciesLocked|not) then {severity:"error",component:"odysseus",code:"odysseus-python-dependencies-unlocked"} else empty end,
            if ($releaseAudit.semanticAudit|not) then {severity:"error",component:"odysseus",code:"odysseus-semantic-audit-incomplete"} else empty end,
            if $releaseAudit.shellExecutionSurface then {severity:"warning",component:"odysseus",code:"odysseus-shell-execution-surface"} else empty end,
            if ($imageManifestValid|not) then {severity:"error",component:"odysseus",code:"dependency-image-manifest-untrusted"} else empty end,
            if ($buildBaseManifestValid|not) then {severity:"error",component:"odysseus",code:"odysseus-build-base-untrusted"} else empty end,
            if ($locked|not) then {severity:"error",component:"odysseus",code:"dependency-images-unlocked"} else empty end,
            if ($routerBridge|not) then {severity:"warning",component:"9router",code:"router-bridge-unavailable"} else empty end,
            if ($routerCredentialReference|not) then {severity:"error",component:"9router",code:"router-credential-reference-unavailable"} else empty end,
            if ($pathsSafe|not) then {severity:"error",component:"odysseus",code:"odysseus-path-unsafe"} else empty end]),secretsRedacted:true}'
}

plan_odysseus() {
    local status doctor deployment_allowed=false release_gate=false proposed="" proposed_tree="" proposed_trusted=false release_audited=false images_approved=false build_base_approved=false
    status="$(status_json)"
    doctor="$(doctor_odysseus)"
    proposed="$(remote_sha 2>/dev/null || true)"
    commit_allowlisted "$proposed" && proposed_trusted=true
    proposed_tree="$(trusted_tree_for_commit "$proposed")"
    release_audit_approved "$proposed" "$proposed_tree" && release_audited=true
    trusted_images_valid && images_approved=true
    trusted_build_base_valid && build_base_approved=true
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && release_gate=true
    [ "$release_gate" = true ] && [ "$proposed_trusted" = true ] && [ "$release_audited" = true ] && [ "$images_approved" = true ] && [ "$build_base_approved" = true ] && deployment_allowed=true
    jq -cn --argjson status "$status" --argjson doctor "$doctor" --arg proposedCommit "$proposed" \
        --argjson proposedCommitTrusted "$proposed_trusted" --argjson releaseGate "$release_gate" \
        --argjson releaseAuditApproved "$release_audited" --argjson dependencyImagesApproved "$images_approved" --argjson buildBaseApproved "$build_base_approved" --argjson deploymentAllowed "$deployment_allowed" \
        '{schemaVersion:1,id:"odysseus",mode:"read-only-plan",releaseGate:$releaseGate,
          deploymentAllowed:$deploymentAllowed,proposedCommit:$proposedCommit,proposedCommitTrusted:$proposedCommitTrusted,
          releaseAuditApproved:$releaseAuditApproved,dependencyImagesApproved:$dependencyImagesApproved,
          buildBaseApproved:$buildBaseApproved,
          ready:$status.ready,status:$status,doctor:$doctor,
          phases:["verify immutable commit allowlist and release audit","pin build base and Python dependency graph",
            "complete semantic security audit","verify rootless runtime and resource budget",
            "generate secret references","resolve all images to digests","stage release transactionally",
            "validate compose without starting services","request explicit operator confirmation",
            "start and prove authenticated readiness","record rollback manifest"],
          blockers:(([if ($releaseGate|not) then "roadmap-host-deployment-blocked" else empty end,
            if ($proposedCommitTrusted|not) then "upstream-commit-untrusted" else empty end] +
            [if ($releaseAuditApproved|not) then "odysseus-release-audit-unapproved" else empty end] +
            [if ($dependencyImagesApproved|not) then "dependency-images-unapproved" else empty end] +
            [if ($buildBaseApproved|not) then "odysseus-build-base-unapproved" else empty end] +
            [$doctor.issues[]?.code]) | unique),secretsRedacted:true}'
}

require_runtime_provenance() {
    status_json | jq -e '.configured == true and .provenance.commitTrusted == true and
      .provenance.releaseAuditApproved == true and
      .provenance.buildBaseManifestValid == true and
      .provenance.dependencyImageManifestValid == true and .provenance.dependencyImagesLocked == true' \
      >/dev/null || {
        pz_error "Odysseus runtime blocked: release or dependency image provenance is invalid"
        return 69
    }
}

# shellcheck disable=SC2317
# PXA-008 keeps workspace access behind its request-bound grant gate.
open_ui() {
    odysseus_usage_blocked
    return 69
    curl -fsS --max-time 2 "$ENDPOINT" >/dev/null 2>&1 || {
        pz_error "Odysseus is not healthy; run: pz ai odysseus doctor"
        return 69
    }
    xdg-open "$ENDPOINT" >/dev/null 2>&1 &
    pz_info "Odysseus opened: $ENDPOINT"
}

case "$ACTION" in
    install|setup|provision|update|upgrade|start|restart|open|dashboard)
        odysseus_usage_blocked
        exit 69 ;;
    status) status_json ;;
    check|check-update) check_update ;;
    stop) systemctl --user disable --now "$SERVICE" ;;
    logs) "$COMPOSE_WRAPPER" logs --tail "${1:-150}" ;;
    backup) backup_data ;;
    doctor|health) doctor_odysseus ;;
    plan|dry-run|diagnose) plan_odysseus ;;
    credentials-path) printf '%s\n' "$ENV_FILE" ;;
    *) pz_error "usage: pz ai odysseus (status|plan|install|start|stop|restart|open|logs|check-update|update|backup|doctor|credentials-path)"; exit 2 ;;
esac
