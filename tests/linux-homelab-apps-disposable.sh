#!/usr/bin/env bash
# Disposable CI: enable vaultwarden → HTTP health → disable, neighbours untouched.
#
# Refuses to run on a developer host. Set PZ_HOMELAB_APPS_DISPOSABLE=1 and pin
# PZ_HOMELAB_STATE to a runner temp directory. Never pulls :latest.
set -euo pipefail

if [ "${PZ_HOMELAB_APPS_DISPOSABLE:-0}" != "1" ]; then
    echo "refusing: set PZ_HOMELAB_APPS_DISPOSABLE=1 (CI disposable only)" >&2
    exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${PZ_HOMELAB_STATE:-}"
case "$STATE" in
    /tmp/*|"${RUNNER_TEMP:-/does-not-exist}"/*) ;;
    *)
        echo "refusing: PZ_HOMELAB_STATE must be under /tmp or RUNNER_TEMP (got ${STATE:-empty})" >&2
        exit 2
        ;;
esac

export PZ_ROOT="$REPO_ROOT"
export PZ_HOMELAB_STATE="$STATE"
export PZ_HOMELAB_PROJECT="${PZ_HOMELAB_PROJECT:-pzhlapps$$}"
export PZ_HOMELAB_RAM_TOTAL_OVERRIDE="${PZ_HOMELAB_RAM_TOTAL_OVERRIDE:-32768}"
unset PZ_HOMELAB_APPS_NO_DOCKER || true

IMAGE="$(jq -r '.images.vaultwarden' "$REPO_ROOT/assets/home-server/docker-compose.lock.json")"
case "$IMAGE" in
    *:latest|latest|"")
        echo "FAIL: vaultwarden image is not pinned: $IMAGE" >&2
        exit 1
        ;;
esac

mkdir -p "$PZ_HOMELAB_STATE"
cleanup() {
    docker rm -f phasezero-vaultwarden >/dev/null 2>&1 || true
    docker compose -p "$PZ_HOMELAB_PROJECT" \
        --env-file "$PZ_HOMELAB_STATE/.env" \
        -f "$REPO_ROOT/assets/home-server/apps/compose/vaultwarden.yml" \
        down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== pull pinned vaultwarden ==="
docker pull -q "$IMAGE" >/dev/null
echo "  pulled $IMAGE"

echo "=== repair secrets ==="
"$REPO_ROOT/linux/pz" server homelab repair --access local --json >/dev/null
test -f "$PZ_HOMELAB_STATE/.env"

echo "=== enable vaultwarden ==="
en="$("$REPO_ROOT/linux/pz" server homelab apps enable vaultwarden --json)"
echo "$en" | jq -e '.ok == true and .started == true and .enabled == true' >/dev/null

echo "=== isolation: neighbours not started ==="
names="$(docker ps --filter "name=phasezero-" --format '{{.Names}}')"
if ! echo "$names" | grep -qx phasezero-vaultwarden; then
    echo "FAIL: vaultwarden not running: $names" >&2
    exit 1
fi
if echo "$names" | grep -Eqx 'phasezero-(jellyfin|syncthing|uptime-kuma|n8n|portainer)'; then
    echo "FAIL: neighbour started: $names" >&2
    exit 1
fi
count="$(echo "$names" | grep -c . || true)"
test "$count" -eq 1

echo "=== health ==="
ok=0
i=0
while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8222/ || true)"
    case "$code" in
        2*|3*) ok=1; break ;;
    esac
    sleep 2
done
test "$ok" = "1" || { echo "FAIL: vaultwarden never became healthy (last HTTP $code)" >&2; exit 1; }
echo "  healthy HTTP $code"

echo "=== disable vaultwarden ==="
dis="$("$REPO_ROOT/linux/pz" server homelab apps disable vaultwarden --json)"
echo "$dis" | jq -e '.ok == true and .enabled == false' >/dev/null
sleep 1
if docker ps --filter "name=phasezero-vaultwarden" --format '{{.Names}}' | grep -q .; then
    echo "FAIL: vaultwarden still running after disable" >&2
    exit 1
fi
if docker ps --filter "name=phasezero-" --format '{{.Names}}' | grep -q .; then
    echo "FAIL: leftover phasezero containers after disable" >&2
    exit 1
fi
"$REPO_ROOT/linux/pz" server homelab apps list --json | jq -e \
    '[.apps[] | select(.key == "vaultwarden") | .enabled] | first == false' >/dev/null
"$REPO_ROOT/linux/pz" server homelab apps list --json | jq -e \
    '[.apps[] | select(.key == "jellyfin") | .running] | first == false' >/dev/null
echo "=== disposable apps isolate ok ==="
