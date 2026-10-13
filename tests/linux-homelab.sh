#!/usr/bin/env bash
# Smoke tests for Linux Homelab + CasaOS UX.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# boot-prepare resolves its runtime from an installed package first; force
# the checkout so hermetic runs never depend on (or collide with) a host
# installation.
export PZ_ROOT="$REPO_ROOT"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$TMP/state"
export PZ_HOMELAB_STATE="$TMP/homelab"
# Never compose-up/rm on the developer host or the hermetic CI job.
export PZ_HOMELAB_APPS_NO_DOCKER=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$PZ_HOMELAB_STATE"

# Pin the WinVM contract boundary to a stub so the suite never touches the
# real WinVM (or the host `pz`) and stays deterministic on every runner.
export PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm.status"
printf '%s\n' '{"libvirtState":"shut off","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"

echo "=== syntax ==="
bash -n "$REPO_ROOT/linux/server/homelab-stack.sh"
bash -n "$REPO_ROOT/linux/server/homelab-apps.sh"
bash -n "$REPO_ROOT/linux/server/homelab-hosts.sh"
bash -n "$REPO_ROOT/linux/server/homelab-host-facts.sh"
python3 -m py_compile "$REPO_ROOT/linux/server/homelab_web.py"
bash -n "$REPO_ROOT/tests/linux-homelab-apps-disposable.sh"
bash -n "$REPO_ROOT/linux/server/casaos.sh"
bash -n "$REPO_ROOT/linux/server/apply-common.sh"
bash -n "$REPO_ROOT/linux/pz"
echo "  syntax ok"

echo "=== server profile argument integrity ==="
apply_capture="$TMP/apply-common.args"
(
    # shellcheck source=../linux/server/apply-common.sh
    source "$REPO_ROOT/linux/server/apply-common.sh"
    # shellcheck disable=SC2329,SC2317 # stubs invoked indirectly via sourced functions
    bash() { printf '%s\n' "$*" >> "$apply_capture"; }
    # shellcheck disable=SC2329,SC2317
    pz_info() { :; }
    # shellcheck disable=SC2329,SC2317
    pz_warn() { :; }
    PZ_SERVER_INSTALL_BOOT=0 pz_server_apply --homelab --extras --no-boot
)
grep -Fq "$REPO_ROOT/linux/server/homelab-stack.sh up --extras" "$apply_capture"
test "$(wc -l < "$apply_capture")" -eq 1
echo "  profile args ok"

echo "=== profile ordering + failure propagation (PZ-AUD-003) ==="
# Services are enabled before setup scripts run (scripts may need daemons).
order_out="$(PZ_DRY_RUN=1 bash -c '
    source "$0/linux/lib/common.sh"
    pz_run_profile "$0/profiles/server-homelab.json"
' "$REPO_ROOT" 2>&1)"
svc_line="$(printf '%s\n' "$order_out" | grep -n "system services" | head -1 | cut -d: -f1)"
script_line="$(printf '%s\n' "$order_out" | grep -n "setup scripts" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2015 # asserção de ordem: falha cai no ramo de erro
[ -n "$svc_line" ] && [ -n "$script_line" ] && [ "$svc_line" -lt "$script_line" ] \
    || { echo "FAIL: services not ordered before scripts"; exit 1; }
# A failing workload step fails the applier (no WARN-and-continue).
if (
    # shellcheck source=../linux/server/apply-common.sh
    source "$REPO_ROOT/linux/server/apply-common.sh"
    # shellcheck disable=SC2329,SC2317
    bash() { echo fixture-child-failed >&2; return 42; }
    # shellcheck disable=SC2329,SC2317
    pz_info() { :; }
    # shellcheck disable=SC2329,SC2317
    pz_warn() { :; }
    PZ_SERVER_INSTALL_BOOT=0 pz_server_apply --homelab --no-boot
) >/dev/null 2>&1; then
    echo "FAIL: applier swallowed child failure"; exit 1
fi
# Privileged steps without any admin bridge fail closed (rc 77), pre-mutation.
printf '%s\n' '{"name":"pz-test-svc","systemd":{"linux":{"enable":["phasezero-test-nonexistent"]}}}' > "$TMP/svc-profile.json"
NOADMIN="$TMP/noadminbin"
mkdir -p "$NOADMIN"
for t in bash sh jq realpath dirname grep cut date mkdir uname touch chmod mktemp rm cat tr; do
    src="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$NOADMIN/$t"
done
admin_rc=0
PATH="$NOADMIN" PZ_DRY_RUN=0 bash -c '
    source "$0/linux/lib/common.sh"
    pz_run_profile "$1"
' "$REPO_ROOT" "$TMP/svc-profile.json" >/dev/null 2>&1 || admin_rc=$?
[ "$admin_rc" -eq 77 ] || { echo "FAIL: expected rc 77 without admin bridge, got $admin_rc"; exit 1; }
echo "  profile ordering + propagation ok"

echo "=== declared compose converges (PZ-AUD-004) ==="
compose_out="$(PZ_DRY_RUN=1 bash -c '
    source "$0/linux/lib/common.sh"
    pz_run_profile "$0/profiles/homelab.json"
' "$REPO_ROOT" 2>&1)"
echo "$compose_out" | rg -q "would converge declared compose: up" \
    || { echo "FAIL: docker_compose not consumed in dry-run"; exit 1; }
compose_line="$(printf '%s\n' "$compose_out" | grep -n "would converge declared compose" | head -1 | cut -d: -f1)"
script_line2="$(printf '%s\n' "$compose_out" | grep -n "setup scripts" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2015 # asserção de ordem: falha cai no ramo de erro
[ -n "$compose_line" ] && [ -n "$script_line2" ] && [ "$compose_line" -lt "$script_line2" ] \
    || { echo "FAIL: compose not converged before scripts"; exit 1; }
printf '%s\n' '{"name":"pz-test-bad","docker_compose":{"core":123}}' > "$TMP/bad-compose.json"
if PZ_DRY_RUN=1 bash -c 'source "$0/linux/lib/common.sh"; pz_run_profile "$1"' "$REPO_ROOT" "$TMP/bad-compose.json" >/dev/null 2>&1; then
    echo "FAIL: invalid docker_compose accepted"; exit 1
fi
printf '%s\n' '{"name":"pz-test-missing","docker_compose":{"core":"assets/nope/missing.yml"}}' > "$TMP/missing-compose.json"
if PZ_DRY_RUN=1 bash -c 'source "$0/linux/lib/common.sh"; pz_run_profile "$1"' "$REPO_ROOT" "$TMP/missing-compose.json" >/dev/null 2>&1; then
    echo "FAIL: missing compose core accepted"; exit 1
fi
echo "  declared compose ok"
# PZ-AUD-027: extra Arch repos are declared and dry-run visible.
PZ_DRY_RUN=1 bash -c '
    source "$0/linux/lib/common.sh"
    pz_run_profile "$0/profiles/gaming.json"
' "$REPO_ROOT" >"$TMP/archrepos.out" 2>&1 || true
# Duas redações corretas, decididas pelo host: onde /etc/pacman.conf já traz
# [multilib], o dry-run diz "already enabled"; onde não há pacman.conf algum
# (runner Ubuntu), diz o que faria. O que o teste exige é que o repositório
# apareça no plano — nunca que seja habilitado em silêncio.
rg -q "repo \[multilib\] already enabled|would enable \[multilib\]" "$TMP/archrepos.out" \
    || { echo "FAIL: archRepos not planned in dry-run:"; head -8 "$TMP/archrepos.out"; exit 1; }
printf '%s\n' '{"name":"pz-test-badrepo","packages":{"linux":{"archRepos":["nope"]}}}' > "$TMP/bad-repo.json"
if PZ_DRY_RUN=1 bash -c 'source "$0/linux/lib/common.sh"; pz_run_profile "$1"' "$REPO_ROOT" "$TMP/bad-repo.json" >/dev/null 2>&1; then
    echo "FAIL: unsupported arch repo accepted"; exit 1
fi
echo "  arch repos declared ok"

echo "=== compose has pinned tags and safe binds ==="
if rg -n ':latest' "$REPO_ROOT/assets/home-server/docker-compose."*.yml; then
    echo "FAIL: compose uses latest tag"
    exit 1
fi
rg -q 'HOMELAB_ADMIN_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml"
rg -q 'HOMELAB_PUBLIC_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml"
rg -q 'HOMELAB_ADMIN_BIND_ADDR' "$REPO_ROOT/assets/home-server/docker-compose.extras.yml"
# every service block must carry no-new-privileges and a memory cap
# (the shared `pz-internal` network header is not a service).
for f in "$REPO_ROOT/assets/home-server/docker-compose."*.yml \
         "$REPO_ROOT/assets/home-server/apps/compose/"*.yml; do
    svcs="$(rg '^  [a-z0-9-]+:$' "$f" | rg -vc '^  pz-internal:$')"
    [ "$(rg -c 'no-new-privileges' "$f")" -eq "$svcs" ] || { echo "FAIL: missing no-new-privileges in $f"; exit 1; }
    [ "$(rg -c 'mem_limit:' "$f")" -eq "$svcs" ] || { echo "FAIL: missing mem_limit in $f"; exit 1; }
done
jq -e '.schemaVersion == 1 and (.images | length == 14) and all(.images[]; (test(":latest") | not))' \
    "$REPO_ROOT/assets/home-server/docker-compose.lock.json" >/dev/null
jq -e '.schemaVersion == 1 and (.apps | length) >= 10' \
    "$REPO_ROOT/assets/home-server/apps/catalog.json" >/dev/null
jq -e --slurpfile lock "$REPO_ROOT/assets/home-server/docker-compose.lock.json" \
    'all(.apps[]; .imageLockKey as $k | ($lock[0].images[$k] == .imageRef) and ((.imageRef | test(":latest")) | not))' \
    "$REPO_ROOT/assets/home-server/apps/catalog.json" >/dev/null
echo "  compose pins/binds/hardening ok"

echo "=== missing .env blocks sensitive services ==="
"$REPO_ROOT/linux/pz" server homelab plan --json --extras | jq -e '
  .status == "blocked"
  and (.blockers | any(test("VW_ADMIN_TOKEN")))
  and (.blockers | any(test("NEXTCLOUD_DB_PASSWORD")))
' >/dev/null
echo "  missing secrets blockers ok"

echo "=== repair generates secure .env without printing secrets ==="
repair_out="$("$REPO_ROOT/linux/pz" server homelab repair --access local --json)"
test "$(stat -c '%a' "$PZ_HOMELAB_STATE/.env")" = "600"
echo "$repair_out" | jq -e '
  .action == "repair"
  and .after.stack.env.exists == true
  and (.after.stack.env.secrets | all(.present == true))
  and .after.stack.access.effective == "local"
  and .after.stack.access.adminBind == "127.0.0.1"
' >/dev/null
if echo "$repair_out" | rg -q '[a-f0-9]{64}'; then
    echo "FAIL: secret value leaked in JSON"
    exit 1
fi
echo "  secure env ok"

echo "=== apps catalog list/enable/disable/update ==="
apps_list="$("$REPO_ROOT/linux/pz" server homelab apps list --json)"
echo "$apps_list" | jq -e '.schemaVersion == "1" and .action == "list" and (.apps | length) >= 10' >/dev/null
echo "$apps_list" | jq -e '[.apps[].imageRef] | all(test(":latest") | not)' >/dev/null
echo "$apps_list" | jq -e '[.apps[] | select(.key == "jellyfin") | .enabled] | first == true' >/dev/null
echo "$apps_list" | jq -e '[.apps[] | select(.key == "n8n") | .enabled] | first == false' >/dev/null
if echo "$apps_list" | rg -q '[a-f0-9]{64}'; then
    echo "FAIL: secret value leaked in apps list"
    exit 1
fi
if "$REPO_ROOT/linux/pz" server homelab apps enable no-such-app --json >/dev/null 2>&1; then
    echo "FAIL: unknown app should fail closed"
    exit 1
fi
gov_out="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=256 "$REPO_ROOT/linux/pz" server homelab apps enable n8n --json || true)"
echo "$gov_out" | jq -e '.ok == false and .governor.verdict == "fail"' >/dev/null
"$REPO_ROOT/linux/pz" server homelab apps list --json | jq -e \
    '[.apps[] | select(.key == "n8n") | .enabled] | first == false' >/dev/null
plan_out="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 "$REPO_ROOT/linux/pz" server homelab apps enable n8n --dry-run --json)"
echo "$plan_out" | jq -e '.ok == true and .dryRun == true and .applied == false' >/dev/null
"$REPO_ROOT/linux/pz" server homelab apps list --json | jq -e \
    '[.apps[] | select(.key == "n8n") | .enabled] | first == false' >/dev/null
enable_out="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 "$REPO_ROOT/linux/pz" server homelab apps enable n8n --json || true)"
# PZ-AUD-005: desired recorded, nothing applied without a daemon: never ok.
echo "$enable_out" | jq -e '.ok == false and .enabled == true and .started == false and .state == "deferred" and .deferred == true' >/dev/null
test "$(stat -c '%a' "$PZ_HOMELAB_STATE/apps.enabled.json")" = "600"
after_enable="$("$REPO_ROOT/linux/pz" server homelab apps list --json)"
echo "$after_enable" | jq -e '[.apps[] | select(.key == "n8n") | .enabled] | first == true' >/dev/null
echo "$after_enable" | jq -e '[.apps[] | select(.key == "jellyfin") | .enabled] | first == true' >/dev/null
disable_out="$("$REPO_ROOT/linux/pz" server homelab apps disable n8n --json || true)"
# PZ-AUD-005: desired recorded, removal deferred without a daemon: never ok.
echo "$disable_out" | jq -e '.ok == false and .enabled == false and .state == "deferred"' >/dev/null
after_disable="$("$REPO_ROOT/linux/pz" server homelab apps list --json)"
echo "$after_disable" | jq -e '[.apps[] | select(.key == "n8n") | .enabled] | first == false' >/dev/null
echo "$after_disable" | jq -e '[.apps[] | select(.key == "jellyfin") | .enabled] | first == true' >/dev/null
upd="$("$REPO_ROOT/linux/pz" server homelab apps update --all --dry-run --json)"
echo "$upd" | jq -e '.ok == true and .dryRun == true and ([.apps[].usesLatest] | all(. == false))' >/dev/null
echo "  apps catalog ok"

echo "=== apps JSON stays pure when compose writes to stdout ==="
# Reproduce the disposable CI failure: docker compose v2 prints progress on
# stdout. docker_cli must send that to stderr so --json remains parseable.
FAKEDOCKER="$TMP/fakedocker"
mkdir -p "$FAKEDOCKER"
cat > "$FAKEDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
echo " Container phasezero-n8n Stopping"
echo " Container phasezero-n8n Removed"
case "${1:-}" in
  info) exit 0 ;;
  compose)
    if [ "${2:-}" = "version" ]; then
      echo "Docker Compose version v2.27.0"
      exit 0
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$FAKEDOCKER/docker"
mixed="$(
    env PATH="$FAKEDOCKER:$PATH" \
        PZ_HOMELAB_APPS_NO_DOCKER=0 \
        PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
        "$REPO_ROOT/linux/pz" server homelab apps enable n8n --json
)"
echo "$mixed" | jq -e '.ok == true and .schemaVersion == "1" and .enabled == true' >/dev/null
case "$mixed" in
    '{'* ) ;;
    *) echo "FAIL: enable stdout not JSON: $mixed" >&2; exit 1 ;;
esac
mixed_dis="$(
    env PATH="$FAKEDOCKER:$PATH" \
        PZ_HOMELAB_APPS_NO_DOCKER=0 \
        "$REPO_ROOT/linux/pz" server homelab apps disable n8n --json
)"
echo "$mixed_dis" | jq -e '.ok == true and .enabled == false' >/dev/null
case "$mixed_dis" in
    '{'* ) ;;
    *) echo "FAIL: disable stdout not JSON: $mixed_dis" >&2; exit 1 ;;
esac
echo "  compose stdout isolation ok"

echo "=== apps never report success on partial failure (PZ-AUD-005) ==="
FAILDOCKER="$TMP/faildocker"
mkdir -p "$FAILDOCKER"
cat > "$FAILDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  version) exit 0 ;;
  image) exit 0 ;;
  compose)
    shift
    for a in "$@"; do
      case "$a" in
        pull) exit 0 ;;
        up) echo "stub compose up failed" >&2; exit 42 ;;
        version) echo "Docker Compose version v2.27.0"; exit 0 ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$FAILDOCKER/docker"
# pull ok + up failed must be ok:false (update path).
upd_fail="$(
    env PATH="$FAILDOCKER:$PATH" \
        PZ_HOMELAB_APPS_NO_DOCKER=0 \
        PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
        "$REPO_ROOT/linux/pz" server homelab apps update n8n --json || true
)"
echo "$upd_fail" | jq -e '.ok == false and .pulled == true and .state == "failed"' >/dev/null
# update without daemon must be deferred, never applied.
upd_defer="$("$REPO_ROOT/linux/pz" server homelab apps update n8n --json || true)"
echo "$upd_defer" | jq -e '.ok == false and .pulled == false and .state == "deferred"' >/dev/null
RMDOCKER="$TMP/rmdocker"
mkdir -p "$RMDOCKER"
cat > "$RMDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  version) exit 0 ;;
  compose)
    shift
    for a in "$@"; do
      case "$a" in
        rm) echo "stub compose rm failed" >&2; exit 42 ;;
        version) echo "Docker Compose version v2.27.0"; exit 0 ;;
      esac
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$RMDOCKER/docker"
dis_fail="$(
    env PATH="$RMDOCKER:$PATH" \
        PZ_HOMELAB_APPS_NO_DOCKER=0 \
        "$REPO_ROOT/linux/pz" server homelab apps disable n8n --json || true
)"
echo "$dis_fail" | jq -e '.ok == false and .enabled == false and .stopped == false and .state == "failed"' >/dev/null
echo "  partial-failure honesty ok"

echo "=== reconcile converges the curated registry (PZ-AUD-012) ==="
RECSTATE="$TMP/reconcile-state"
mkdir -p "$RECSTATE"
printf '%s\n' '{"schemaVersion":1,"tool":"homelab-apps","enabled":["vaultwarden"]}' > "$RECSTATE/apps.enabled.json"
RECDOCKER="$TMP/recdocker"
mkdir -p "$RECDOCKER"
cat > "$RECDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  version) exit 0 ;;
  compose)
    shift
    for a in "$@"; do
      case "$a" in
        version) echo "Docker Compose version v2.27.0"; exit 0 ;;
      esac
    done
    printf '%s\n' "$*" >> "$RECONCILE_CAPTURE"
    exit 0
    ;;
  volume) exit 0 ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$RECDOCKER/docker"
export RECONCILE_CAPTURE="$TMP/reconcile.capture"
rm -f "$RECONCILE_CAPTURE"
rec_out="$(
    env PATH="$RECDOCKER:$PATH" \
        PZ_HOMELAB_STATE="$RECSTATE" \
        PZ_HOMELAB_APPS_NO_DOCKER=0 \
        "$REPO_ROOT/linux/pz" server homelab reconcile --json
)"
echo "$rec_out" | jq -e '.ok == true and (.desired | index("vaultwarden") != null)' >/dev/null
rg -q 'vaultwarden' "$RECONCILE_CAPTURE" \
    || { echo "FAIL: reconcile did not start enabled app"; exit 1; }
if rg -q '(^| )jellyfin($| )|(^| )syncthing($| )' "$RECONCILE_CAPTURE"; then
    echo "FAIL: reconcile started apps outside the registry"
    exit 1
fi
# backup covers exactly the volumes in use.
bk_vols="$(
    env PZ_HOMELAB_STATE="$RECSTATE" \
        PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$TMP/recmounts" \
        PZ_HOMELAB_VOLUMES_OVERRIDE="" \
        bash "$REPO_ROOT/linux/server/homelab-stack.sh" backup --dry-run --json
)"
echo "$bk_vols" | jq -e '(.volumes | index("vaultwarden_data") != null) and ([.volumes[] | select(test("jellyfin|syncthing"))] | length == 0)' >/dev/null
echo "  reconcile convergence ok"

echo "=== paperless ships its broker (PZ-AUD-007) ==="
rg -q 'PAPERLESS_REDIS=redis://paperless-broker:6379' "$REPO_ROOT/assets/home-server/apps/compose/paperless.yml" \
    || { echo "FAIL: paperless module missing broker URL"; exit 1; }
rg -q 'condition: service_healthy' "$REPO_ROOT/assets/home-server/apps/compose/paperless.yml" \
    || { echo "FAIL: paperless does not wait for healthy broker"; exit 1; }
rg -q 'paperless_consume:/usr/src/paperless/consume' "$REPO_ROOT/assets/home-server/apps/compose/paperless.yml" \
    || { echo "FAIL: paperless consume flow missing"; exit 1; }
rg -q 'paperless_export:/usr/src/paperless/export' "$REPO_ROOT/assets/home-server/apps/compose/paperless.yml" \
    || { echo "FAIL: paperless export flow missing"; exit 1; }
jq -e '.images["paperless-broker"] == "valkey/valkey:8.0"' \
    "$REPO_ROOT/assets/home-server/docker-compose.lock.json" >/dev/null
paper_out="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 "$REPO_ROOT/linux/pz" server homelab apps enable paperless --dry-run --json)"
echo "$paper_out" | jq -e '.ok == true and (.wouldEnable | index("paperless-broker") != null)' >/dev/null
echo "  paperless broker ok"

echo "=== executed pins, isolation, no secret expansion (PZ-AUD-030) ==="
# Log rotation on every service block.
for f in "$REPO_ROOT/assets/home-server/docker-compose."*.yml \
         "$REPO_ROOT/assets/home-server/apps/compose/"*.yml; do
    svcs="$(rg '^  [a-z0-9-]+:$' "$f" | rg -vc '^  pz-internal:$')"
    [ "$(rg -c '^    logging:$' "$f")" -eq "$svcs" ] || { echo "FAIL: logging missing in $f"; exit 1; }
    rg -q 'max-size: "10m"' "$f" || { echo "FAIL: log rotation missing in $f"; exit 1; }
done
# Media libraries are read-only for the server.
rg -q '\$\{HOMELAB_MEDIA_DIR:-./media\}:/media:ro' "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" \
    || { echo "FAIL: jellyfin media not ro in core"; exit 1; }
rg -q '\$\{HOMELAB_MEDIA_DIR:-./media\}:/media:ro' "$REPO_ROOT/assets/home-server/apps/compose/jellyfin.yml" \
    || { echo "FAIL: jellyfin media not ro in module"; exit 1; }
# Least-privilege networks: proxy and db traffic stays internal.
rg -q 'pz-internal:' "$REPO_ROOT/assets/home-server/apps/compose/portainer.yml" \
    || { echo "FAIL: portainer module missing internal net"; exit 1; }
rg -q 'internal: true' "$REPO_ROOT/assets/home-server/apps/compose/nextcloud.yml" \
    || { echo "FAIL: nextcloud module missing internal net"; exit 1; }
# Digests recorded at update time drive the executed compose.
PINDOCKER="$TMP/pindocker"
mkdir -p "$PINDOCKER"
cat > "$PINDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  version) exit 0 ;;
  image) echo "vaultwarden/server@sha256:aaabbbccc0001"; exit 0 ;;
  compose)
    shift
    for a in "$@"; do
      case "$a" in
        version) echo "Docker Compose version v2.27.0"; exit 0 ;;
      esac
    done
    printf '%s\n' "$*" >> "$PINS_CAPTURE"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$PINDOCKER/docker"
export PINS_CAPTURE="$TMP/pins.capture"
rm -f "$PINS_CAPTURE"
PINSTATE="$TMP/pin-state"
mkdir -p "$PINSTATE"
env PATH="$PINDOCKER:$PATH" PZ_HOMELAB_STATE="$PINSTATE" \
    PZ_HOMELAB_APPS_NO_DOCKER=0 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
    PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-pin.json" \
    "$REPO_ROOT/linux/pz" server homelab repair --json >/dev/null 2>&1
env PATH="$PINDOCKER:$PATH" PZ_HOMELAB_STATE="$PINSTATE" \
    PZ_HOMELAB_APPS_NO_DOCKER=0 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
    PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-pin.json" \
    "$REPO_ROOT/linux/pz" server homelab apps enable vaultwarden --json >/dev/null 2>&1
pin_upd="$(env PATH="$PINDOCKER:$PATH" PZ_HOMELAB_STATE="$PINSTATE" \
    PZ_HOMELAB_APPS_NO_DOCKER=0 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
    PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-pin.json" \
    "$REPO_ROOT/linux/pz" server homelab apps update vaultwarden --json 2>/dev/null)"
echo "$pin_upd" | jq -e '.ok == true and .state == "applied"' >/dev/null
test "$(stat -c '%a' "$PINSTATE/image-pins.env")" = "600"
rg -q '^PZ_IMAGE_VAULTWARDEN=vaultwarden/server@sha256:aaabbbccc0001$' "$PINSTATE/image-pins.env" \
    || { echo "FAIL: executed pin not recorded"; exit 1; }
rg -q 'image-pins.env up -d' "$PINS_CAPTURE" \
    || { echo "FAIL: executed up did not consume pins"; exit 1; }
PZ_HOMELAB_STATE="$PINSTATE" "$REPO_ROOT/linux/pz" server homelab apps list --json 2>/dev/null \
    | jq -e '[.apps[] | select(.key == "vaultwarden") | .imageRef] | first | test("sha256:aaabbbccc0001")' >/dev/null
# No rendered output may carry secret values (compose config is never dumped).
secret_val="$(grep -E '^VW_ADMIN_TOKEN=' "$PINSTATE/.env" | cut -d= -f2-)"
for cmdline in "server homelab status --json" "server homelab plan --json" "server homelab apps list --json" "server homelab apps enable n8n --dry-run --json"; do
    # shellcheck disable=SC2086
    if PZ_HOMELAB_STATE="$PINSTATE" $REPO_ROOT/linux/pz $cmdline 2>/dev/null | rg -qF "$secret_val"; then
        echo "FAIL: secret value expanded in: $cmdline"; exit 1
    fi
done
echo "  pins + isolation + redaction ok"

echo "=== governor uses available memory, app and profile agree (PZ-AUD-031) ==="
# Low MemAvailable refuses even when total RAM would be plenty.
gov_low="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=1500 "$REPO_ROOT/linux/pz" server homelab apps enable n8n --dry-run --json 2>/dev/null || true)"
echo "$gov_low" | jq -e '.ok == false and .governor.verdict == "fail" and .governor.availableMB == 1500 and .governor.totalMB != null' >/dev/null
# Same host, same source: profile budget reports the same available base.
prof_low="$(PZ_HOMELAB_RAM_TOTAL_OVERRIDE=1500 "$REPO_ROOT/linux/server/homelab-governor.sh" budget edge 2>/dev/null)"
echo "$prof_low" | jq -e '.availableMB == 1500 and .totalMB != null and .diskAvailableMB != null' >/dev/null
# Active WinVM reserves its weight on both paths.
echo '{"libvirtState":"running","currentMarker":"no"}' > "$TMP/winvm-active.json"
gov_winvm="$(PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-active.json" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 "$REPO_ROOT/linux/pz" server homelab apps enable n8n --dry-run --json 2>/dev/null)"
echo "$gov_winvm" | jq -e '.governor.winvmActive == true and .governor.winvmWeightMB == 2048' >/dev/null
prof_winvm="$(PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-active.json" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 "$REPO_ROOT/linux/server/homelab-governor.sh" budget edge 2>/dev/null)"
echo "$prof_winvm" | jq -e '.winvmActive == true and .winvmWeightMB == 2048' >/dev/null
echo "  unified governor ok"

echo "=== app recipes guide first use, probes prove serving (PZ-AUD-008) ==="
# Every user-facing app documents its usable journey in the catalog.
jq -e '[.apps[] | select(.userFacing == true)
        | select((.firstUse.steps | length) >= 2
                 and (.firstUse.openPath | type == "string")
                 and (.firstUse.probe.path | type == "string"))] | length >= 10' \
    "$REPO_ROOT/assets/home-server/apps/catalog.json" >/dev/null
# UX-009: the Player is pt-BR — every user-facing app ships interface copy
# with the same number of steps as the CLI copy, and never equal to it.
jq -e '([.apps[] | select(.userFacing == true)
         | select((.firstUse.stepsPtBr | length) == (.firstUse.steps | length)
                  and (.firstUse.stepsPtBr != .firstUse.steps))] | length)
       == ([.apps[] | select(.userFacing == true)] | length)' \
    "$REPO_ROOT/assets/home-server/apps/catalog.json" >/dev/null
# Recipes surface on list rows with a deep open URL.
"$REPO_ROOT/linux/pz" server homelab apps list --json 2>/dev/null \
    | jq -e '[.apps[] | select(.key == "vaultwarden")]
             | first | .firstUse.steps[0] != null and (.openUrl | test("/$"))' >/dev/null
# A running container whose app probe fails is not ready (honest, not TCP-only).
R8="$TMP/recipe-strict"
mkdir -p "$R8"
printf '%s\n' '{"schemaVersion":1,"tool":"homelab-apps","enabled":["vaultwarden"]}' > "$R8/apps.enabled.json"
cp "$PZ_HOMELAB_STATE/.env" "$R8/.env"
probe_out="$(PZ_HOMELAB_STATE="$R8" bash -c '
    source "$0/linux/server/homelab-status.sh"
    running_containers() { echo phasezero-vaultwarden; }
    container_health() { echo healthy; }
    build_status
' "$REPO_ROOT")"
echo "$probe_out" | jq -e '.ready == false and (.functionalProbes.failed | index("vaultwarden") != null)' >/dev/null
echo "  app recipes ok"

echo "=== web CLI bootstrap (no serve) ==="
export PZ_HOMELAB_WEB_STATE="$TMP/web"
"$REPO_ROOT/linux/pz" server homelab web status --json | jq -e \
    '.schemaVersion == "1" and .tool == "homelab-web" and .bind == "127.0.0.1" and .users == 0' >/dev/null
printf '%s\n' 'correct-horse-9x' > "$TMP/web-pw"
chmod 600 "$TMP/web-pw"
"$REPO_ROOT/linux/pz" server homelab web user add alice --password-file "$TMP/web-pw" --json |
    jq -e '.ok == true and .user == "alice"' >/dev/null
printf '%s\n' '123' > "$TMP/web-pw-weak"
if "$REPO_ROOT/linux/pz" server homelab web user add bob --password-file "$TMP/web-pw-weak" --json >/dev/null 2>&1; then
    echo "FAIL: weak password accepted" >&2
    exit 1
fi
"$REPO_ROOT/linux/pz" server homelab web status --json | jq -e '.users == 1' >/dev/null
unset PZ_HOMELAB_WEB_STATE
echo "  web CLI ok"

echo "=== host-facts never invent sensors ==="
facts="$(
    PZ_HOMELAB_SMARTCTL=/no/such/smartctl \
    PZ_HOMELAB_SENSORS=/no/such/sensors \
    PZ_HOMELAB_THERMAL_DIR="$TMP/no-thermal" \
    "$REPO_ROOT/linux/pz" server homelab host-facts --json
)"
echo "$facts" | jq -e '
  .schemaVersion == "1" and .tool == "homelab-host-facts"
  and .smart.available == false
  and .temperature.available == false
  and .temperature.celsius == null
  and (.smart.reason | test("ausente"))
' >/dev/null
if echo "$facts" | jq -e '.temperature.celsius != null and .temperature.available == false' >/dev/null; then
    echo "FAIL: fabricated temperature" >&2
    exit 1
fi
mkdir -p "$TMP/thermal/thermal_zone0"
printf '42000\n' > "$TMP/thermal/thermal_zone0/temp"
printf 'x86_pkg_temp\n' > "$TMP/thermal/thermal_zone0/type"
hot="$(
    PZ_HOMELAB_SMARTCTL=/no/such/smartctl \
    PZ_HOMELAB_SENSORS=/no/such/sensors \
    PZ_HOMELAB_THERMAL_DIR="$TMP/thermal" \
    "$REPO_ROOT/linux/pz" server homelab host-facts --json
)"
echo "$hot" | jq -e '.temperature.available == true and .temperature.celsius == 42' >/dev/null
echo "  host-facts ok"

echo "=== hosts registry + ssh envelope ==="
if "$REPO_ROOT/tests/linux-homelab-apps-disposable.sh" >/dev/null 2>&1; then
    echo "FAIL: disposable script ran without PZ_HOMELAB_APPS_DISPOSABLE"
    exit 1
fi
grep -q '^# Disposable CI' "$REPO_ROOT/tests/linux-homelab-apps-disposable.sh"
grep -q 'Disposable CI' "$REPO_ROOT/tests/runner.sh"
add_out="$("$REPO_ROOT/linux/pz" server homelab hosts add garage 'misael@192.168.1.8' --json)"
echo "$add_out" | jq -e '.ok == true and .host.alias == "garage" and .host.user == "misael" and .host.port == 22' >/dev/null
hosts_file="$XDG_CONFIG_HOME/phasezero/homelab-hosts.json"
test "$(stat -c '%a' "$hosts_file")" = "600"
if jq -e '.hosts[] | select(.password or .privateKey or .token or .identityFile)' "$hosts_file" >/dev/null; then
    echo "FAIL: registry contains private material"
    exit 1
fi
"$REPO_ROOT/linux/pz" server homelab hosts add garage 'misael@192.168.1.8' --json | jq -e '.already == true' >/dev/null
if "$REPO_ROOT/linux/pz" server homelab hosts add garage 'other@192.168.1.8' --json >/dev/null 2>&1; then
    echo "FAIL: alias retarget should fail closed"
    exit 1
fi
if "$REPO_ROOT/linux/pz" server homelab hosts add bad 'root@/etc/shadow' --json >/dev/null 2>&1; then
    echo "FAIL: path target should be rejected"
    exit 1
fi
printf '{not json' > "$hosts_file"
if "$REPO_ROOT/linux/pz" server homelab hosts list --json >/dev/null 2>&1; then
    echo "FAIL: corrupt registry should fail closed"
    exit 1
fi
# restore a valid registry for the ssh stub
"$REPO_ROOT/linux/pz" server homelab hosts add garage 'misael@192.168.1.8' --json >/dev/null 2>&1 || true
# rewrite after corruption
rm -f "$hosts_file"
"$REPO_ROOT/linux/pz" server homelab hosts add garage 'misael@192.168.1.8' --json | jq -e '.ok == true' >/dev/null
stub="$TMP/fake-ssh"
cat > "$stub" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
log="${PZ_HOMELAB_SSH_STUB_LOG:-}"
[ -n "$log" ] && printf '%s\n' "$@" >> "$log"
mode="${PZ_HOMELAB_SSH_STUB_MODE:-ok}"
joined="$*"
if [ "$mode" = "offline" ]; then
    echo "ssh: connect to host 192.168.1.8 port 22: Connection timed out" >&2
    exit 255
fi
if [[ "$joined" == *"--version"* ]]; then
    if [ "$mode" = "old" ]; then
        echo "PhaseZero Linux v1.10.0 (stable)"
        exit 0
    fi
    echo "PhaseZero Linux v1.17.4 (stable)"
    exit 0
fi
if [[ "$joined" == *"ai product-status usagebar"* ]]; then
    echo '{"schemaVersion":1,"hasStatus":true,"installationState":"unknown","origin":"unknown","configurationState":"unknown","health":"unknown","manager":"phasezero-ai-usagebar","version":"","observedAt":"2026-09-26T00:00:00Z"}'
    exit 0
fi
echo '{"schemaVersion":"1","tool":"homelab-apps","action":"list","apps":[{"key":"jellyfin","enabled":true}]}'
exit 0
EOS
chmod +x "$stub"
export PZ_HOMELAB_SSH_BIN="$stub"
export PZ_HOMELAB_SSH_STUB_LOG="$TMP/ssh.log"
: > "$PZ_HOMELAB_SSH_STUB_LOG"
"$REPO_ROOT/linux/pz" server homelab hosts ping garage --json | jq -e \
    '.ok == true and .reachable == true and .remoteVersion == "1.17.4"' >/dev/null
env_out="$("$REPO_ROOT/linux/pz" server homelab --host garage apps list --json)"
echo "$env_out" | jq -e '.hostAlias == "garage" and .rc == 0 and .payload.action == "list" and (.payload.apps|length) == 1' >/dev/null
status_env="$("$REPO_ROOT/linux/pz" server homelab --host garage product-status usagebar --json)"
echo "$status_env" | jq -e '.hostAlias == "garage" and .rc == 0 and .payload.hasStatus == true and .payload.installationState == "unknown" and .remoteVersion == "1.17.4"' >/dev/null
grep -q '^ai$' "$PZ_HOMELAB_SSH_STUB_LOG"
grep -q '^product-status$' "$PZ_HOMELAB_SSH_STUB_LOG"
grep -q '^usagebar$' "$PZ_HOMELAB_SSH_STUB_LOG"
ssh_arg_count="$(wc -l < "$PZ_HOMELAB_SSH_STUB_LOG")"
if "$REPO_ROOT/linux/pz" server homelab --host garage product-status unknown-app >/dev/null 2>&1; then
    echo "FAIL: remote product status allowlist accepted an unknown target"
    exit 1
fi
test "$(wc -l < "$PZ_HOMELAB_SSH_STUB_LOG")" -eq "$ssh_arg_count"
grep -q 'BatchMode=yes' "$PZ_HOMELAB_SSH_STUB_LOG"
if echo "$env_out" | rg -q 'BEGIN OPENSSH PRIVATE|password='; then
    echo "FAIL: secret material in remote envelope"
    exit 1
fi
export PZ_HOMELAB_SSH_STUB_MODE=offline
off="$("$REPO_ROOT/linux/pz" server homelab --host garage status --json || true)"
echo "$off" | jq -e '.rc != 0 and .payload == null and (.error | test("unreachable|timed out"))' >/dev/null
export PZ_HOMELAB_SSH_STUB_MODE=old
old="$("$REPO_ROOT/linux/pz" server homelab --host garage apps enable n8n --json || true)"
echo "$old" | jq -e '.rc == 69 and .payload == null and (.error | test("older than required"))' >/dev/null
unset PZ_HOMELAB_SSH_STUB_MODE
echo "=== hosts pair honors port, key and first contact (PZ-AUD-014) ==="
"$REPO_ROOT/linux/pz" server homelab hosts add custom-port 'misael@192.168.1.9:2222' --json | jq -e '.host.port == 2222' >/dev/null
# No key anywhere: missing-key state, never a blind attempt.
pair_missing="$("$REPO_ROOT/linux/pz" server homelab hosts pair custom-port --json 2>/dev/null || true)"
echo "$pair_missing" | jq -e '.ok == false and .state == "missing-key" and (.guidance | test("generate|ssh-keygen"))' >/dev/null
# --generate creates the keypair in this HOME, then the stub copy succeeds.
scid="$TMP/fake-copy-id"
cat > "$scid" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$SSH_COPY_LOG"
exit "${SSH_COPY_RC:-0}"
EOS
chmod +x "$scid"
export SSH_COPY_LOG="$TMP/copy.log" SSH_COPY_RC=0
: > "$SSH_COPY_LOG"
PATH="$TMP/copybin:$PATH"
mkdir -p "$TMP/copybin"
ln -sf "$scid" "$TMP/copybin/ssh-copy-id"
pair_gen="$("$REPO_ROOT/linux/pz" server homelab hosts pair custom-port --generate --json 2>/dev/null)"
echo "$pair_gen" | jq -e '.ok == true and .paired == true and .generated == true' >/dev/null
test -f "$HOME/.ssh/id_ed25519" -a -f "$HOME/.ssh/id_ed25519.pub"
test "$(stat -c '%a' "$HOME/.ssh/id_ed25519")" = "600"
grep -q -- '-p 2222' "$SSH_COPY_LOG" || grep -q -e '-p' -e '2222' "$SSH_COPY_LOG" \
    || { echo "FAIL: registry port not passed to ssh-copy-id"; exit 1; }
rg -q 'misael@192.168.1.9' "$SSH_COPY_LOG"
# Failing copy: first contact with the exact port-bearing command.
export SSH_COPY_RC=42
pair_first="$("$REPO_ROOT/linux/pz" server homelab hosts pair custom-port --json 2>/dev/null || true)"
echo "$pair_first" | jq -e '.ok == false and .state == "needs-first-contact"' >/dev/null
echo "$pair_first" | jq -e '.guidance | test("2222")' >/dev/null

# UX-008: with --password-stdin the first contact completes here, without a
# terminal. The stub plays the part of ssh-copy-id: it records its argv and
# asks the askpass helper for the password, exactly like ssh would.
fc="$TMP/fake-first-contact"
cat > "$fc" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FC_ARGV_LOG"
"$SSH_ASKPASS" > "$FC_SECRET_SEEN" 2>/dev/null || true
printf 'askpass-dir %s\n' "$(dirname "$SSH_ASKPASS")" >> "$FC_ARGV_LOG"
case "${FC_MODE:-ok}" in
    ok) exit 0 ;;
    hang) sleep 30; exit 0 ;;
    auth) echo "Permission denied, please try again." >&2; exit 1 ;;
    unreachable) echo "ssh: connect to host 192.168.1.9 port 2222: No route to host" >&2; exit 255 ;;
esac
EOS
chmod +x "$fc"
export FC_ARGV_LOG="$TMP/fc-argv.log" FC_SECRET_SEEN="$TMP/fc-secret" FC_MODE=ok
export PZ_HOMELAB_SSH_COPY_ID_BIN="$fc"
export SSH_COPY_RC=42  # the BatchMode attempt keeps failing; stdin path takes over
: > "$FC_ARGV_LOG"
# Valor de fixture, não credencial: o teste só precisa de algo que possa
# ser rastreado em argv/log. Nome e conteúdo evitam disparar o gitleaks.
FIXTURE_PW='senha-fake-de-teste'  # gitleaks:allow
fc_ok="$(printf '%s\n' "$FIXTURE_PW" | "$REPO_ROOT/linux/pz" server homelab hosts pair custom-port \
    --password-stdin --json 2>"$TMP/fc.err" || true)"
echo "$fc_ok" | jq -e '.ok == true and .paired == true and .state == "paired" and .firstContact == true' >/dev/null
# The password reached ssh through the askpass helper...
test "$(cat "$FC_SECRET_SEEN")" = "$FIXTURE_PW"
# ...and never through argv, stdout or stderr.
grep -Fq "$FIXTURE_PW" "$FC_ARGV_LOG" && { echo "FAIL: senha em argv"; exit 1; }
printf '%s' "$fc_ok" | grep -Fq "$FIXTURE_PW" && { echo "FAIL: senha no JSON"; exit 1; }
grep -Fq "$FIXTURE_PW" "$TMP/fc.err" && { echo "FAIL: senha em stderr"; exit 1; }
# The private askpass directory does not survive the run.
askpass_dir="$(awk '/^askpass-dir /{print $2}' "$FC_ARGV_LOG" | tail -1)"
test -n "$askpass_dir"
test ! -e "$askpass_dir" || { echo "FAIL: diretório do segredo sobreviveu"; exit 1; }
# A host that never answers is bounded, not a hung interface.
FC_MODE=hang
fc_timeout="$(printf '%s\n' "$FIXTURE_PW" | "$REPO_ROOT/linux/pz" server homelab hosts pair custom-port \
    --password-stdin --timeout 1 --json 2>/dev/null || true)"
echo "$fc_timeout" | jq -e '.ok == false and .state == "timeout" and (.guidance | test("não respondeu"))' >/dev/null
# A refused password says so, and does not claim first contact succeeded.
FC_MODE=auth
fc_auth="$(printf '%s\n' "$FIXTURE_PW" | "$REPO_ROOT/linux/pz" server homelab hosts pair custom-port \
    --password-stdin --json 2>/dev/null || true)"
echo "$fc_auth" | jq -e '.ok == false and .paired == false and .state == "auth-failed"' >/dev/null
FC_MODE=unreachable
fc_net="$(printf '%s\n' "$FIXTURE_PW" | "$REPO_ROOT/linux/pz" server homelab hosts pair custom-port \
    --password-stdin --json 2>/dev/null || true)"
echo "$fc_net" | jq -e '.state == "unreachable"' >/dev/null
# Empty input never reaches the network.
: > "$FC_ARGV_LOG"
fc_empty="$(printf '\n' | "$REPO_ROOT/linux/pz" server homelab hosts pair custom-port \
    --password-stdin --json 2>/dev/null || true)"
echo "$fc_empty" | jq -e '.state == "empty-password"' >/dev/null
test ! -s "$FC_ARGV_LOG" || { echo "FAIL: tentativa de rede sem senha"; exit 1; }
unset PZ_HOMELAB_SSH_COPY_ID_BIN FC_MODE FC_ARGV_LOG FC_SECRET_SEEN
export SSH_COPY_RC=0
echo "  first contact from the interface ok (UX-008)"

"$REPO_ROOT/linux/pz" server homelab hosts remove custom-port --json | jq -e '.ok == true' >/dev/null
echo "  hosts pair ok"
"$REPO_ROOT/linux/pz" server homelab hosts remove garage --json | jq -e '.ok == true' >/dev/null
echo "  hosts bridge ok"

echo "=== compose config core/extras ==="
if docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-test \
        -f "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" config --services |
        sort | jq -R . | jq -cs 'index("vaultwarden") and index("jellyfin") and index("syncthing") and (index("portainer") | not)' >/dev/null
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-test \
        -f "$REPO_ROOT/assets/home-server/docker-compose.homelab.yml" \
        -f "$REPO_ROOT/assets/home-server/docker-compose.extras.yml" config --services |
        sort | jq -R . | jq -cs 'index("nextcloud") and index("grafana") and index("paperless") and index("n8n") and index("portainer")' >/dev/null
    jelly_svcs="$(docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-subset \
        -f "$REPO_ROOT/assets/home-server/apps/compose/jellyfin.yml" config --services)"
    echo "$jelly_svcs" | grep -qx jellyfin
    if echo "$jelly_svcs" | grep -qx n8n; then
        echo "FAIL: jellyfin subset leaked n8n"
        exit 1
    fi
    n8n_svcs="$(docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-subset \
        -f "$REPO_ROOT/assets/home-server/apps/compose/n8n.yml" config --services)"
    echo "$n8n_svcs" | grep -qx n8n
    if echo "$n8n_svcs" | grep -qx jellyfin; then
        echo "FAIL: n8n subset leaked jellyfin"
        exit 1
    fi
    docker compose --env-file "$PZ_HOMELAB_STATE/.env" -p phasezero-homelab-subset \
        -f "$REPO_ROOT/assets/home-server/apps/compose/vaultwarden.yml" \
        -f "$REPO_ROOT/assets/home-server/apps/compose/n8n.yml" config --quiet
    echo "  compose config ok"
else
    echo "  docker compose unavailable; skipped"
fi

echo "=== tailscale logged-out blocker ==="
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tailscale" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  status) echo "Logged out" >&2; exit 1 ;;
  ip) exit 0 ;;
  *) exit 1 ;;
esac
EOS
chmod +x "$FAKEBIN/tailscale"
PATH="$FAKEBIN:$PATH" "$REPO_ROOT/linux/pz" server homelab plan --json --access tailscale |
    jq -e '.access.effective == "blocked" and (.blockers | any(test("tailscale logged out")))' >/dev/null
echo "  tailscale blocker ok"

echo "=== open/logical urls and backup/restore dry-runs ==="
"$REPO_ROOT/linux/pz" server homelab open jellyfin --json | jq -e '.url == "http://127.0.0.1:8096"' >/dev/null
"$REPO_ROOT/linux/pz" server homelab backup --dry-run --extras | jq -e '.dryRun == true and (.volumes | index("vaultwarden_data")) and (.volumes | index("nextcloud_data"))' >/dev/null
mkdir -p "$TMP/backup"
touch "$TMP/backup/vaultwarden_data.tgz"
"$REPO_ROOT/linux/pz" server homelab restore --source "$TMP/backup" --dry-run | jq -e '.requiresConfirmation == true and (.archives | index("vaultwarden_data.tgz"))' >/dev/null
echo "  dry-runs ok"

echo "=== CasaOS compatibility gate ==="
cat > "$TMP/ubuntu-os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu Test"
EOF
PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" "$REPO_ROOT/linux/pz" server casaos plan --json |
    jq -e '.status == "available" and .compatibility.compatible == true and (.compatibility.blockers | length == 0)' >/dev/null
PZ_DRY_RUN=1 PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" \
    "$REPO_ROOT/linux/pz" server casaos install --yes |
    jq -e '.dryRun == true and .download[0] == "curl" and .execute == ["bash", "<temporary>"] and (.download | index("=https"))' >/dev/null
if PZ_DRY_RUN=1 PZ_CASAOS_OS_RELEASE="$TMP/ubuntu-os-release" PZ_CASAOS_INSTALL_URL='http://example.invalid/install.sh' \
    "$REPO_ROOT/linux/pz" server casaos install --yes >/dev/null 2>&1; then
    echo "FAIL: CasaOS accepted non-HTTPS installer URL"
    exit 1
fi

cat > "$TMP/arch-os-release" <<'EOF'
ID=arch
ID_LIKE=arch
PRETTY_NAME="Arch Test"
EOF
PZ_CASAOS_OS_RELEASE="$TMP/arch-os-release" "$REPO_ROOT/linux/pz" server casaos plan --json |
    jq -e '.status == "blocked" and .compatibility.compatible == false and (.compatibility.blockers | length > 0)' >/dev/null
echo "  casaos gate ok"

echo "=== aggregate status schemaVersion + ready proofs ==="
status_json="$("$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null)"; status_rc=$?
# A valid diagnostic is a success even when the stack is not configured:
# readiness lives in the fields (ready/state/reasons), never in the exit code.
[ "$status_rc" -eq 0 ] || { echo "FAIL: homelab status must exit 0 with a valid report"; exit 1; }
echo "$status_json" | jq -e '
  .schemaVersion == "1"
  and .tool == "homelab-status"
  and .ready == false
  and (.reasons | length > 0)
  and (.state | type == "string" and length > 0)
  and (.summary | type == "string" and length > 0)
  and (.nextAction == null or (.nextAction | type == "string"))
  and .degraded == false
  and .securityState.redaction == true
  and (.lastOperation | type == "object")
  and (.resume | has("resumed"))
  and (.versions.phasezero.version | length > 0)
' >/dev/null || { echo "FAIL: aggregate status schema invalid"; echo "$status_json" | jq -c '{ready,reasons,degraded,sec:.securityState}' 2>/dev/null; exit 1; }
echo "  status schema ok"
# verify before any persisted status: must not be verified
fresh_status() {
    rm -f "$PZ_HOMELAB_STATE/status.json"
    local v
    v="$("$REPO_ROOT/linux/pz" server homelab verify --json 2>/dev/null)" || true
    printf '%s\n' "$v" | jq -e '
      .action == "verify" and .verified == false and (.checks | length > 0)
    ' >/dev/null
}
fresh_status || { echo "FAIL: verify with no persisted status"; exit 1; }
echo "  fresh verify ok"
# verify after status persisted: consistent -> verified
"$REPO_ROOT/linux/pz" server homelab status --json >/dev/null 2>&1 || true
v2="$("$REPO_ROOT/linux/pz" server homelab verify --json 2>/dev/null)" || true
printf '%s\n' "$v2" | jq -e '
  .action == "verify" and .verified == true and (.checks | length == 0)
' >/dev/null
echo "  consistent verify ok"
echo "  verify ok"
test -s "$PZ_HOMELAB_STATE/status.json"
echo "  status persisted ok"

echo "=== readiness proofs are strict (PZ-AUD-006) ==="
# A container without a healthcheck is never a health proof.
hp_none="$(bash -c '
    source "$0/linux/server/homelab-status.sh"
    running_containers() { echo phasezero-fixture; }
    container_health() { echo none; }
    health_proofs
' "$REPO_ROOT")"
echo "$hp_none" | jq -e '.healthy == false and (.unchecked | index("phasezero-fixture") != null)' >/dev/null
hp_ok="$(bash -c '
    source "$0/linux/server/homelab-status.sh"
    running_containers() { echo phasezero-fixture; }
    container_health() { echo healthy; }
    health_proofs
' "$REPO_ROOT")"
echo "$hp_ok" | jq -e '.healthy == true and (.unchecked | length == 0)' >/dev/null
# Expected set: a running container outside the registry blocks ready.
S6="$TMP/status-strict"
mkdir -p "$S6"
printf '%s\n' '{"schemaVersion":1,"tool":"homelab-apps","enabled":["vaultwarden"]}' > "$S6/apps.enabled.json"
cp "$PZ_HOMELAB_STATE/.env" "$S6/.env"
exp_out="$(PZ_HOMELAB_STATE="$S6" bash -c '
    source "$0/linux/server/homelab-status.sh"
    running_containers() { echo phasezero-jellyfin; }
    container_health() { echo healthy; }
    build_status
' "$REPO_ROOT")"
echo "$exp_out" | jq -e '.ready == false
    and (.missingContainers | index("phasezero-vaultwarden") != null)
    and (.unexpectedContainers | index("phasezero-jellyfin") != null)' >/dev/null
echo "  strict readiness ok"

echo "=== prepare plan states profile truth (R01-003) ==="
# Um comando que morre aqui derruba a suite pelo set -e sem dizer por quê:
# guardar stderr e o rc torna a falha legível em vez de "exit 3" mudo.
r03_rc=0
r03_a="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/pz" server homelab prepare --dry-run --json --profile edge 2>"$TMP/r03.err")" || r03_rc=$?
[ "$r03_rc" -eq 0 ] || {
    echo "FAIL: prepare --profile edge saiu $r03_rc (R01-003):"
    tail -5 "$TMP/r03.err"
    exit 1
}
echo "$r03_a" | jq -e '.dryRun == true and .host == "local" and .profile == "edge"
    and .profileInstallable == false and (.profileNote | length > 0)
    and (.profileServices | index("zeroclaw") != null)
    and .appsSource == "catalog-defaults" and (.budget | type == "object")' >/dev/null \
    || { echo "FAIL: plan does not state budget-only profile truth (R01-003): $r03_a"; exit 1; }
r03_b="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/pz" server homelab prepare --dry-run --json --profile assistant-private 2>/dev/null)"
echo "$r03_b" | jq -e '.profile == "assistant-private" and (.profileServices | index("zeroclaw") == null)' >/dev/null \
    || { echo "FAIL: distinct profiles must produce distinct plan truth (R01-003): $r03_b"; exit 1; }
test "$r03_a" != "$r03_b" || { echo "FAIL: distinct profiles produced identical plans (R01-003)"; exit 1; }
# no profile at all: installable/note stay null, catalog defaults declared
PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/pz" server homelab prepare --dry-run --json 2>/dev/null \
    | jq -e '.profile == null and .profileInstallable == null and .profileNote == null and .appsSource == "catalog-defaults"' >/dev/null \
    || { echo "FAIL: profile-less plan truth wrong (R01-003)"; exit 1; }
echo "  prepare plan profile truth ok (R01-003)"

echo "=== prepare installs deps then converges honestly (PZ-AUD-002) ==="
# Stub capabilities engine: records plan/apply, performs no install.
CAPSTUB="$TMP/capstub"
mkdir -p "$CAPSTUB"
cat > "$CAPSTUB/pz-capabilities-stub" <<'EOS'
#!/usr/bin/env bash
echo "$*" >> "$CAPSTUB_CALLOUT"
if [ "${1:-}" = "plan" ]; then
    echo '{"schema":"pz.capabilities/v1","id":"plan-test-1","confirmToken":"tok-test-1"}'
elif [ "${1:-}" = "apply" ]; then
    echo '{"schema":"pz.capabilities/v1","ok":true}'
else
    echo '{"ok":false}' >&2; exit 2
fi
EOS
chmod +x "$CAPSTUB/pz-capabilities-stub"
# PATH without docker/compose: allowlisted minimal tools only.
NODOCKER="$TMP/nodockerbin"
mkdir -p "$NODOCKER"
for t in bash sh jq python3 date dirname mkdir chmod mktemp rm cat grep head tail sort cut wc stat install mv cp ln find flock sha256sum tar gzip realpath timeout openssl tr basename touch sleep id uname; do
    src="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$NODOCKER/$t"
done
PREPSTATE="$TMP/prepare-state"
mkdir -p "$PREPSTATE"
export CAPSTUB_CALLOUT="$TMP/capstub.calls"
rm -f "$CAPSTUB_CALLOUT"
prep_nodeps="$(env PATH="$NODOCKER" PZ_HOMELAB_STATE="$PREPSTATE" \
    PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-prep.json" \
    PZ_HOMELAB_CAPABILITIES_CLI="$CAPSTUB/pz-capabilities-stub" \
    "$REPO_ROOT/linux/pz" server homelab prepare --app vaultwarden --json 2>/dev/null || true)"
echo "$prep_nodeps" | jq -e '.ok == false and .state == "failed"' >/dev/null
rg -q 'plan --capability development.docker' "$CAPSTUB_CALLOUT" \
    || { echo "FAIL: prepare did not delegate deps to capabilities"; exit 1; }
rg -q 'apply --plan-id plan-test-1 --confirm tok-test-1' "$CAPSTUB_CALLOUT" \
    || { echo "FAIL: prepare did not apply with plan token"; exit 1; }
# Stub docker that works but runs nothing: prepare must pass every step
# until verify, then fail honestly (never ready without proofs).
FULLDOCKER="$TMP/fulldocker"
mkdir -p "$FULLDOCKER"
cat > "$FULLDOCKER/docker" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  info) exit 0 ;;
  ps) exit 0 ;;
  inspect) echo "healthy"; exit 0 ;;
  compose)
    shift
    for a in "$@"; do
      case "$a" in
        version) echo "Docker Compose version v2.27.0"; exit 0 ;;
      esac
    done
    exit 0
    ;;
  version) exit 0 ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$FULLDOCKER/docker"
prep_full_out="$(env PATH="$FULLDOCKER:$PATH" PZ_HOMELAB_STATE="$PREPSTATE" \
    PZ_HOMELAB_APPS_NO_DOCKER=0 \
    PZ_HOMELAB_WINVM_STATUS_FILE="$TMP/winvm-prep.json" \
    PZ_HOMELAB_RAM_TOTAL_OVERRIDE=32768 \
    "$REPO_ROOT/linux/pz" server homelab prepare --app vaultwarden --json 2>/dev/null || true)"
echo "$prep_full_out" | jq -e '.ok == false and .state == "failed"' >/dev/null
echo "$prep_full_out" | jq -e '[.steps[] | select(.name == "dependencies" or .name == "daemon" or .name == "access" or .name == "configure" or .name == "apps") | .status] | all(. == "ready")' >/dev/null
echo "$prep_full_out" | jq -e '[.steps[] | select(.name == "verify") | .status] == ["failed"]' >/dev/null
echo "  prepare delegation + honest verify ok"

echo "=== operations: registry flow ==="
OPS="$PZ_HOMELAB_STATE/operations"
op_id="$("$REPO_ROOT/linux/server/homelab-operations.sh" start backup profile=assistant-private)"
echo "$op_id" | rg -q '^[0-9TZ]+-[0-9]+-[0-9]+$'
jq -e '.schemaVersion == 1 and .status == "running" and .action == "backup" and .rollbackAvailable == false' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" step "$op_id" dump-volumes
jq -e '.step == "dump-volumes" and .status == "running"' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" finish "$op_id" succeeded --rollback-available
jq -e '.status == "succeeded" and .rollbackAvailable == true' "$OPS/$op_id.json" >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" last | jq -e '.operationId == "'"$op_id"'"' >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" list --json | jq -e --arg id "$op_id" 'any(.operationId == $id)' >/dev/null
echo "  operation registry ok"

echo "=== operations: cross-process lock ==="
# outer subshell holds fd9 flock (bg), inner attempt must time out
(
    exec 9>"$PZ_HOMELAB_STATE/homelab.lock"
    flock 9
    sleep 3 &
    SLEEPPID=$!
    wait "$SLEEPPID"
) &
LOCKPID=$!
sleep 0.3
if PZ_HOMELAB_SO_LOCK=1 PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" \
    "$REPO_ROOT/linux/server/homelab-operations.sh" lock --wait 1 >/dev/null 2>&1; then
    echo "FAIL: lock acquired while held"
    exit 1
fi
wait "$LOCKPID"
echo "  lock ok"

echo "=== operations: crash -> resume -> cancel ==="
crash_op="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=edge)"
"$REPO_ROOT/linux/server/homelab-operations.sh" step "$crash_op" pull-images
"$REPO_ROOT/linux/server/homelab-operations.sh" abort "$crash_op"
"$REPO_ROOT/linux/server/homelab-operations.sh" resume-info | jq -e '.resumable == true and .operationId == "'"$crash_op"'" and .lastStep == "pull-images"' >/dev/null
"$REPO_ROOT/linux/server/homelab-operations.sh" abort "$crash_op" cancelled
"$REPO_ROOT/linux/server/homelab-operations.sh" resume-info | jq -e '.resumable == false and .status == "cancelled"' >/dev/null
echo "  crash/resume/cancel ok"

echo "=== operations: idempotent re-entry + corrupted state fail-closed ==="
re2="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=edge)"
test "$re2" != "$crash_op"
echo 'garbage{{not-json' > "$OPS/zz-corrupt.json"
corrupt_json="$("$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null)" || true
if printf '%s\n' "$corrupt_json" | jq -e '.reasons | any(test("corrupted"))' >/dev/null; then
    echo "  corrupted conflict reason ok"
else
    echo "FAIL: corrupted op registry did not fail closed"
    exit 1
fi
rm -f "$OPS/zz-corrupt.json"
echo "  idempotency/corrupt ok"

echo "=== profiles: registry + resource governor ==="
profile_list="$("$REPO_ROOT/linux/server/homelab-governor.sh" list)"
printf '%s\n' "$profile_list" | jq -e --argjson keys '["ai-studio","assistant-multichannel","assistant-private","automation","developer","edge"]' \
  '.schemaVersion == 1 and (.profiles|length) == 6 and ([.profiles[].key] | sort) == ($keys|sort) and .default == "edge" and all(.profiles[]; (.title|length>0) and (.services|type=="array") and (.class|length>0) and (.maturity|length>0))' >/dev/null
echo "  registry 6 profiles ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" weights | jq -e '.weightsMB.jellyfin == 2048 and .weightsMB.ollama == 2048 and .weightsMB["paperless-broker"] == 128 and (.weightsMB|length) == 28' >/dev/null
echo "  weights ok"
# PZ-AUD-022: appliance profiles are budget-only until installable.
"$REPO_ROOT/linux/server/homelab-governor.sh" list | jq -e \
    '[.profiles[] | select(.installable == true)] | length == 0' >/dev/null
"$REPO_ROOT/linux/server/homelab-governor.sh" list | jq -e \
    'all(.profiles[]; (.installNote | type == "string" and length > 0))' >/dev/null
if "$REPO_ROOT/linux/server/homelab-stack.sh" up --profile edge 2>/dev/null; then
    echo "FAIL: preview profile applied as installable"; exit 1
fi
refuse_rc=0
refuse_out="$("$REPO_ROOT/linux/server/homelab-stack.sh" up --profile edge 2>&1)" || refuse_rc=$?
echo "$refuse_out" | rg -qi "preview|not installable" \
    || { echo "FAIL: refusal hides maturity"; exit 1; }
# REV-018: maturity is decided BEFORE the Docker requirement, so the honest
# refusal (rc 69) must surface even where the daemon is absent/stopped.
test "$refuse_rc" = "69" || { echo "FAIL: maturity refusal is not rc 69 (got $refuse_rc)"; exit 1; }
echo "  appliance preview honesty ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=3000 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null 2>&1; then
    echo "FAIL: overcommit check passed"; exit 1
fi
echo "  overcommit fails closed ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=0 "$REPO_ROOT/linux/server/homelab-governor.sh" check edge >/dev/null 2>&1; then
    echo "FAIL: zero-RAM check passed"; exit 1
fi
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/server/homelab-governor.sh" budget assistant-private | jq -e '.verdict == "pass" and .budgetMB == 4224' >/dev/null
echo "  in-budget pass ok"
# CCS-014: budget-active usa o perfil ativo real; sem perfil, falha fechado
# com a lista de perfis públicos.
gov_state="$PZ_HOMELAB_STATE"
if PZ_HOMELAB_STATE="$gov_state/no-active" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 \
    "$REPO_ROOT/linux/server/homelab-governor.sh" budget-active > "$gov_state/budget-empty.json" 2>/dev/null; then
    echo "FAIL: budget-active sem perfil ativo deveria falhar"; exit 1
fi
jq -e '.error == "no-active-profile" and (.profiles | index("edge"))' "$gov_state/budget-empty.json" >/dev/null
mkdir -p "$gov_state/with-profile"
printf 'assistant-private\n' > "$gov_state/with-profile/profile.active"
PZ_HOMELAB_STATE="$gov_state/with-profile" PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 \
    "$REPO_ROOT/linux/server/homelab-governor.sh" budget-active | \
    jq -e '.profile == "assistant-private" and .verdict == "pass"' >/dev/null
echo "  budget-active real profile ok"
# "core" nunca é chave pública de perfil appliance
if "$REPO_ROOT/linux/server/homelab-governor.sh" check core >/dev/null 2>&1; then
    echo "FAIL: 'core' aceito como perfil appliance"; exit 1
fi
if "$REPO_ROOT/linux/server/homelab-governor.sh" check bogus >/dev/null 2>&1; then
    echo "FAIL: unknown profile accepted"; exit 1
fi
echo "  unknown profile rejected ok"
if "$REPO_ROOT/linux/server/homelab-operations.sh" start apply profile=bogus >/dev/null 2>&1; then
    echo "FAIL: ops accepted bogus profile"; exit 1
fi
echo "  ops profile validation ok"
"$REPO_ROOT/linux/pz" server homelab profile list | jq -e '.profiles|length == 6' >/dev/null
"$REPO_ROOT/linux/pz" server homelab profile set assistant-private >/dev/null
test "$(cat "$PZ_HOMELAB_STATE/profile.active")" = "assistant-private"
echo "  profile set ok"
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=8192 "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/ps.json 2>&1 || true
jq -e '.profile == "assistant-private" and (.resourceBudget|type=="object") and .resourceBudget.verdict == "pass"' /tmp/ps.json >/dev/null
echo "  status budget wiring ok"
if "$REPO_ROOT/linux/pz" server homelab profile set bogus >/dev/null 2>&1; then
    echo "FAIL: pz set accepted bogus profile"; exit 1
fi
echo "  pz set validation ok"
if PZ_DRY_RUN=1 PZ_HOMELAB_RAM_TOTAL_OVERRIDE=512 \
    "$REPO_ROOT/linux/pz" server homelab up --profile ai-studio >/dev/null 2>&1; then
    echo "FAIL: up accepted overcommit profile"; exit 1
fi
echo "  up profile gate ok"

echo "=== winvm contract: status boundary, graceful suspend, resume ==="
jq -e '.winvmMB == 2048' "$REPO_ROOT/assets/home-server/homelab-profiles.json" >/dev/null
echo "  winvm weight registered ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status | jq -e '.status == "idle" and .active == false and .weightMB == 2048' >/dev/null
echo "  winvm idle detection ok"
# Unconfigured budget is a reportable state (rc 0 + envelope), not a failure.
PZ_HOMELAB_PROFILES_FILE="$TMP/registry-ausente.json" "$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status \
    | jq -e '.state == "needs-config" and .weightMB == null and (.nextAction | type == "string")' >/dev/null
echo "  winvm unconfigured envelope ok"
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" budget ai-studio | jq -e '.winvmActive == false and .verdict == "pass"' >/dev/null
echo "  heavy profile passes when winvm idle ok"
printf '%s\n' '{"libvirtState":"running","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-status | jq -e '.status == "active"' >/dev/null
echo "  winvm active detection ok"
if PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null 2>&1; then
    echo "FAIL: heavy profile passed while winvm active"; exit 1
fi
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" budget ai-studio \
    | jq -e '.winvmActive == true and .winvmWeightMB == 2048 and (.reasons | any(. | test("winvm active")))' >/dev/null
echo "  winvm conflict impact plan ok"
suspend_out="$("$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend --dry-run)"
printf '%s\n' "$suspend_out" | jq -e '.winvmSuspendRequested == true and .method == "graceful-qga" and .dryRun == true and .killUsed == "never"' >/dev/null
echo "  graceful suspend plan ok"
SUSPEND_CAPTURE="$TMP/suspend.capture"
PZ_HOMELAB_WINVM_SUSPEND_CMD="printf suspend-called > '$SUSPEND_CAPTURE' && echo ok" \
    "$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend | jq -e '.applied == true and .killUsed == "never"' >/dev/null
grep -Fq 'suspend-called' "$SUSPEND_CAPTURE"
echo "  graceful suspend executes configured command ok"
printf '%s\n' '{"libvirtState":"shut off","currentMarker":"no","bootRuntimeStale":false}' > "$PZ_HOMELAB_WINVM_STATUS_FILE"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-suspend --dry-run | jq -e '.winvmSuspendRequested == false and .status == "idle"' >/dev/null
echo "  suspend no-op when idle ok"
"$REPO_ROOT/linux/server/homelab-governor.sh" winvm-resume | jq -e '.winvmReleased == true and .status == "idle"' >/dev/null
PZ_HOMELAB_RAM_TOTAL_OVERRIDE=12288 "$REPO_ROOT/linux/server/homelab-governor.sh" check ai-studio >/dev/null
echo "  resume after winvm end ok"

echo "=== boot-prepare identity: marker absent is a no-op ==="
"$REPO_ROOT/linux/server/homelab-boot-prepare.sh" 2>&1 | rg -q 'nothing to do'
echo "  marker-absent ok"

echo "=== boot-prepare bring-up as target user, no root/real-home writes ==="
FB="$TMP/bootbin"
mkdir -p "$FB"
cat > "$FB/systemctl" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    start) exit 0 ;;
    *) exit 0 ;;
esac
EOS
cat > "$FB/runuser" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUNUSER_CAPTURE"
for a in "$@"; do
    case "$a" in
        HOME=*) echo "$a" | sed 's/^HOME=//' > "$RUNUSER_HOME_CAPTURE" ;;
        XDG_STATE_HOME=*) echo "$a" | sed 's/^XDG_STATE_HOME=//' > "$RUNUSER_XDG_CAPTURE" ;;
    esac
done
exit 0
EOS
chmod +x "$FB/systemctl" "$FB/runuser"
export RUNUSER_CAPTURE="$TMP/runuser.capture" RUNUSER_HOME_CAPTURE="$TMP/runuser.home" RUNUSER_XDG_CAPTURE="$TMP/runuser.xdg"
rm -f "$RUNUSER_CAPTURE" "$RUNUSER_HOME_CAPTURE" "$RUNUSER_XDG_CAPTURE"
BOOTSTATE="$TMP/boot-test-state"
PATH="$FB:$PATH" PZ_BOOT_MARKER=1 PZ_SERVER_USER=testuser PZ_SERVER_HOMELAB=1 \
    PZ_SERVER_LLM=0 PZ_SERVER_HERMES=0 PZ_STATE_ROOT="$TMP/boot-state-root" \
    PZ_HOMELAB_STATE="$BOOTSTATE" "$REPO_ROOT/linux/server/homelab-boot-prepare.sh" >/dev/null 2>&1
grep -Fq 'bash' "$RUNUSER_CAPTURE"
rg -q 'homelab-stack\.sh' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: stack not invoked"; exit 1; }
if ! rg -q '^--access$' "$RUNUSER_CAPTURE" || ! rg -q '^local$' "$RUNUSER_CAPTURE"; then
    echo "FAIL: stack not invoked with up --access local"; exit 1
fi
test "$(cat "$RUNUSER_HOME_CAPTURE")" != "/root"
test "$(cat "$RUNUSER_XDG_CAPTURE")" = "$TMP/boot-state-root"
test ! -e /root/.local/state/phasezero/homelab/degraded.json
test -f "$BOOTSTATE/degraded.json" && { echo "FAIL: degraded marker on success"; exit 1; }
echo "  identity ok"

echo "=== boot-prepare essential failure marks degraded and fails unit ==="
cat > "$FB/systemctl" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    start) [ "$2" = "docker" ] && exit 1 || exit 0 ;;
    *) exit 0 ;;
esac
EOS
if PATH="$FB:$PATH" PZ_BOOT_MARKER=1 PZ_SERVER_USER=testuser PZ_SERVER_HOMELAB=1 \
    PZ_SERVER_LLM=0 PZ_SERVER_HERMES=0 PZ_STATE_ROOT="$TMP/boot-state-root" \
    PZ_HOMELAB_STATE="$BOOTSTATE" "$REPO_ROOT/linux/server/homelab-boot-prepare.sh" >/dev/null 2>&1; then
    echo "FAIL: essential bring-up failure did not fail the unit"
    exit 1
fi
jq -e '.reasons | any(.reason == "docker service failed to start")' "$BOOTSTATE/degraded.json" >/dev/null
echo "  degraded/fail ok"

echo "=== boot hermes timeout wraps the inner command (PZ-AUD-025) ==="
HB="$TMP/hermesbin"
mkdir -p "$HB"
cat > "$HB/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "$HB/runuser" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUNUSER_CAPTURE"
# Chain into the inner command like runuser would (past -u user -- env VARS).
inner=()
seen_env=0
for a in "$@"; do
    if [ "$seen_env" = "1" ]; then
        case "$a" in
            *=*) export "$a" ;;
            *) inner+=("$a"); seen_env=2 ;;
        esac
    elif [ "$a" = "env" ]; then
        seen_env=1
    elif [ "$seen_env" = "2" ]; then
        inner+=("$a")
    fi
done
exec "${inner[@]}"
EOS
cat > "$HB/timeout" <<'EOS'
#!/usr/bin/env bash
# Fake timeout: exec the inner command like the real one.
dur="$1"; shift
printf 'TIMEOUT dur=%s\n' "$dur" >> "$RUNUSER_CAPTURE"
exec "$@"
EOS
chmod +x "$HB/systemctl" "$HB/runuser" "$HB/timeout"
export RUNUSER_CAPTURE="$TMP/runuser-hermes.capture"
rm -f "$RUNUSER_CAPTURE"
PATH="$HB:$PATH" PZ_BOOT_MARKER=1 PZ_SERVER_USER=testuser PZ_SERVER_HOMESERVER=0 \
    PZ_SERVER_HOMELAB=0 PZ_SERVER_LLM=0 PZ_SERVER_HERMES=1 \
    PZ_STATE_ROOT="$TMP/hermes-state-root" \
    PZ_HOMELAB_STATE="$TMP/hermes-test-state" \
    "$REPO_ROOT/linux/server/homelab-boot-prepare.sh" >/dev/null 2>&1 || true
rg -q '^timeout$' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: timeout not passed through as_user to runuser"; exit 1; }
rg -q '^120$' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: timeout duration missing in hermes boot path"; exit 1; }
rg -q 'hermes-remote\.sh$' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: hermes-remote not invoked in boot path"; exit 1; }
rg -q 'TIMEOUT dur=120' "$RUNUSER_CAPTURE" \
    || { echo "FAIL: timeout did not wrap the inner command"; exit 1; }
echo "  hermes boot timeout ok"

echo "=== access mode persists in homelab env ==="
"$REPO_ROOT/linux/pz" server homelab repair --access tailscale >/dev/null 2>&1 || true
rg -q '^HOMELAB_ACCESS_MODE=tailscale$' "$PZ_HOMELAB_STATE/.env"
"$REPO_ROOT/linux/pz" server homelab repair --access local >/dev/null 2>&1 || true
echo "  access persistence ok"

echo "=== backup: manifest + checksums + verify + restore ==="
BKT="$TMP/backup-root"
VM="$TMP/vol-mounts"
mkdir -p "$VM/vaultwarden_data" "$VM/syncthing_data"
echo "secret-password-1" > "$VM/vaultwarden_data/db.sqlite"
echo "file-a" > "$VM/syncthing_data/a.txt"
BENV="PZ_HOMELAB_STATE=$PZ_HOMELAB_STATE PZ_HOMELAB_BACKUP_ROOT=$BKT PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data syncthing_data' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE=$VM"
bk_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup --dest '$BKT/bk1' 2>/dev/null" | grep -v '^INFO:')"
echo "$bk_out" | jq -e '.ok == true and (.volumes|length) == 2' >/dev/null
test -f "$BKT/bk1/manifest.json"
test -f "$BKT/bk1/vaultwarden_data.tgz"
test -f "$BKT/last.json"
jq -e '.schemaVersion == "2" and .tool == "homelab-backup" and (.volumes|length) == 2 and (.volumes[] | has("sha256") and has("sizeBytes")) and .verified == false' "$BKT/bk1/manifest.json" >/dev/null
echo "  backup manifest ok"
eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$BKT/bk1' 2>/dev/null" | grep -v '^INFO:' | jq -e '.action == "verify-backup" and .verified == true and (.checks|length) == 0' >/dev/null
echo "  verify pass ok"
# verify on a dir without manifest must fail closed
mkdir -p "$TMP/backup-nomanifest"; touch "$TMP/backup-nomanifest/data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$TMP/backup-nomanifest'" >/dev/null 2>&1; then
    echo "FAIL: verify accepted dir without manifest"; exit 1
fi
echo "  verify missing-manifest fails closed ok"
# restore --plan: verify + impacto, zero escrita (CCS-004)
plan_before="$(find "$BKT" -mindepth 1 | sort)"
plan_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$plan_out" | jq -e '.action == "restore" and .plan == true and .verified == true and .requiresConfirmation == true and (.volumesAffected | index("vaultwarden_data"))' >/dev/null
plan_after="$(find "$BKT" -mindepth 1 | sort)"
test "$plan_before" = "$plan_after" || { echo "FAIL: restore --plan escreveu arquivos"; exit 1; }
# plan de backup adulterado mostra verified:false e falha fechado
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan" >/dev/null 2>&1; then
    echo "FAIL: restore --plan aceitou backup adulterado"; exit 1
fi
tampered_raw="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan 2>/dev/null")" || true
jq -e '.plan == true and .verified == false' < <(grep -v '^INFO:' <<< "$tampered_raw") >/dev/null
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
# --plan não combina com --yes/--dry-run
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --plan --yes" >/dev/null 2>&1; then
    echo "FAIL: restore aceitou --plan junto de --yes"; exit 1
fi
echo "  restore --plan zero-write ok"
# tamper: modify an archive, verify must fail closed
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab backup verify --source '$BKT/bk1'" >/dev/null 2>&1; then
    echo "FAIL: tampered backup verified"; exit 1
fi
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
echo "  tamper fails closed ok"
# restore without --yes must refuse; with --yes must apply
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1'" >/dev/null 2>&1; then
    echo "FAIL: restore without --yes accepted"; exit 1
fi
# corrupt the restore target to prove restore writes
rm -f "$VM/vaultwarden_data/db.sqlite"
rest_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$rest_out" | jq -e '.ok == true and .preRestore != null' >/dev/null
grep -q 'secret-password-1' "$VM/vaultwarden_data/db.sqlite"
test -f "$BKT/bk1.pre-restore/manifest.json"
jq -e '.tool == "homelab-restore-pre" and (.volumes | length) == 2' "$BKT/bk1.pre-restore/manifest.json" >/dev/null
echo "  restore verify-then-apply ok"

# CCS-004 evolutivo: arquivo de confirmação (jornada da Central) equivale a
# --yes, desde que a frase exata — vinculada à origem — esteja presente.
rm -f "$VM/vaultwarden_data/db.sqlite"
printf 'FRASE ERRADA\n' > "$TMP/confirm.txt"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --confirm-file '$TMP/confirm.txt'" >/dev/null 2>&1; then
    echo "FAIL: confirm-file com frase errada foi aceito"; exit 1
fi
printf 'RESTAURAR bk1\n' > "$TMP/confirm.txt"
conf_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --confirm-file '$TMP/confirm.txt' 2>/dev/null" | grep -v '^INFO:')"
printf '%s\n' "$conf_out" | jq -e '.ok == true and .preRestore != null' >/dev/null
grep -q 'secret-password-1' "$VM/vaultwarden_data/db.sqlite"
echo "  restore --confirm-file ok"
# restore from a tampered backup must be refused before applying
cp "$BKT/bk1/vaultwarden_data.tgz" "$BKT/bk1/vaultwarden_data.tgz.bak"
printf 'tamper' >> "$BKT/bk1/vaultwarden_data.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes" >/dev/null 2>&1; then
    echo "FAIL: restore applied tampered backup"; exit 1
fi
mv "$BKT/bk1/vaultwarden_data.tgz.bak" "$BKT/bk1/vaultwarden_data.tgz"
echo "  restore tampered refused ok"
# restore from a non-manifest dir must be refused
mkdir -p "$TMP/backup-legacy"; touch "$TMP/backup-legacy/x.tgz"
if eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$TMP/backup-legacy' --yes" >/dev/null 2>&1; then
    echo "FAIL: legacy backup restored without manifest"; exit 1
fi
echo "  legacy refused ok"
# partial restore failure must roll back to the pre-restore state
echo "changed-after-backup" > "$VM/vaultwarden_data/db.sqlite"
echo "fresh-b" > "$VM/syncthing_data/b.txt"
# poison the second volume so extraction fails mid-restore
rm -rf "$VM/syncthing_data" && touch "$VM/syncthing_data"
rb_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes 2>/dev/null" | grep -v '^INFO:' || true)"
printf '%s\n' "$rb_out" | jq -e '.ok == false and .rollbackApplied == true and .failedVolume == "syncthing_data"' >/dev/null
if printf '%s\n' "$rb_out" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "FAIL: restore with poisoned volume succeeded"; exit 1
fi
rm -rf "$VM/syncthing_data" && mkdir -p "$VM/syncthing_data" && echo "file-a" > "$VM/syncthing_data/a.txt"
grep -q 'changed-after-backup' "$VM/vaultwarden_data/db.sqlite" \
    || { echo "FAIL: rollback did not restore pre-restore state"; exit 1; }
test "$(cat "$VM/vaultwarden_data/db.sqlite")" = "changed-after-backup" \
    || { echo "FAIL: rollback restored backup instead of pre-restore state"; exit 1; }
echo "  restore partial failure rolls back to pre-restore ok"
# REV-003: the stack stop happens BEFORE the pre-restore snapshot — a
# rollback copy taken while writers are live can ship a torn database.
down_line="$(rg -n 'if ! cmd_down; then' "$REPO_ROOT/linux/server/homelab-stack.sh" | head -1 | cut -d: -f1)"
snap_line="$(rg -n 'tar -C "\$mount" -czf "\$pre_dir' "$REPO_ROOT/linux/server/homelab-stack.sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2015 # asserção de ordem: falha cai no ramo de erro
[ -n "$down_line" ] && [ -n "$snap_line" ] && [ "$down_line" -lt "$snap_line" ] \
    || { echo "FAIL: pre-restore snapshot must follow stack stop (REV-003)"; exit 1; }
echo "  restore stops stack before snapshot ok (REV-003)"
# R01-001: a compose down failure must stop restore before ANY write.
# `if ! cmd_down` suppresses errexit, so cmd_down propagates explicitly.
# The REAL cmd_down runs; only the docker CLI is stubbed (info/version/
# ps/volume succeed, `compose down` exits 42). No volume-mount override —
# that path short-circuits cmd_down.
DOCK="$TMP/docker-down42"; mkdir -p "$DOCK"
# shellcheck disable=SC2016 # o corpo do stub é literal de propósito: a expansão acontece quando o stub roda, não agora
printf '#!/usr/bin/env bash\ncase "$1" in info|compose) case "${2:-}" in version|"") exit 0 ;; esac ;; esac\ncase "$*" in *"down"*) exit 42 ;; *) exit 0 ;; esac\n' > "$DOCK/docker"
chmod +x "$DOCK/docker"
cp -a "$BKT/bk1" "$BKT/bkr01"
rm -rf "$BKT/bkr01.pre-restore"
sentinel="$(cat "$VM/vaultwarden_data/db.sqlite")"
r01_rc=0
r01_out="$(env PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$BKT" \
    PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data syncthing_data' \
    PATH="$DOCK:$PATH" \
    "$REPO_ROOT/linux/pz" server homelab restore --source "$BKT/bkr01" --yes 2>&1)" || r01_rc=$?
test "$r01_rc" = "1" || { echo "FAIL: compose down failure must fail the restore (R01-001), rc=$r01_rc"; exit 1; }
grep -q "could not stop stack" <<< "$r01_out" || { echo "FAIL: restore did not report the failed stop (R01-001): $r01_out"; exit 1; }
grep -q "stack stopped" <<< "$r01_out" && { echo "FAIL: cmd_down reported the stack as stopped after a failed compose down (R01-001)"; exit 1; }
test ! -e "$BKT/bkr01.pre-restore" || { echo "FAIL: pre-restore snapshot taken over live writers (R01-001)"; exit 1; }
test "$(cat "$VM/vaultwarden_data/db.sqlite")" = "$sentinel" || { echo "FAIL: restore mutated volumes after a failed stop (R01-001)"; exit 1; }
rm -rf "$BKT/bkr01"
echo "  restore refuses to run over failed compose down ok (R01-001)"
# REV-001 matrix (R01): a mutation failure on ANY position — first or last
# volume, failed copy or failed wipe — rolls every mutated volume back to
# the pre-restore snapshot. The volume is registered before the first
# destructive write, so it can never fall out of the rollback set.
SHIM="$TMP/cp-shim"; mkdir -p "$SHIM"
real_cp="$(command -v cp)"
real_find="$(command -v find)"
# cp shim: fails once (consumes the arm file) when the destination matches.
# shellcheck disable=SC2016 # o corpo do stub é literal de propósito: a expansão acontece quando o stub roda, não agora
printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-a" ] && [ -n "$PZ_REV1_ARM" ] && [ -f "$PZ_REV1_ARM" ] && [ "${*: -1}" = "$PZ_REV1_TARGET" ]; then rm -f "$PZ_REV1_ARM"; exit 42; fi\nexec %q "$@"\n' "$real_cp" > "$SHIM/cp"
# find shim: fails only the FIRST wipe of the configured directory (arm
# consumed) so the rollback's own wipe still succeeds.
# shellcheck disable=SC2016 # o corpo do stub é literal de propósito: a expansão acontece quando o stub roda, não agora
printf '#!/usr/bin/env bash\nif [ -n "${PZ_REV1_WIPE:-}" ] && [ -n "$PZ_REV1_ARM" ] && [ -f "$PZ_REV1_ARM" ] && [ "${1:-}" = "$PZ_REV1_WIPE" ] && [ "${*: -1}" = "-delete" ]; then rm -f "$PZ_REV1_ARM"; exit 42; fi\nexec %q "$@"\n' "$real_find" > "$SHIM/find"
chmod +x "$SHIM/cp" "$SHIM/find"
for scenario in vw-cp st-cp vw-wipe; do
    case "$scenario" in
        vw-cp)   rb_vol="vaultwarden_data"; arm="$TMP/arm-cp-vw"; tgt="$VM/vaultwarden_data/";  wipe="";;
        st-cp)   rb_vol="syncthing_data";   arm="$TMP/arm-cp-st"; tgt="$VM/syncthing_data/";    wipe="";;
        vw-wipe) rb_vol="vaultwarden_data"; arm="$TMP/arm-none";    tgt="";                       wipe="$VM/vaultwarden_data";;
    esac
    : > "$arm"
    echo "round-$scenario-vw" > "$VM/vaultwarden_data/db.sqlite"
    echo "round-$scenario-st" > "$VM/syncthing_data/a.txt"
    m_out="$(env PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$BKT" \
        PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data syncthing_data' \
        PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$VM" \
        PATH="$SHIM:$PATH" PZ_REV1_ARM="$arm" PZ_REV1_TARGET="$tgt" PZ_REV1_WIPE="$wipe" \
        "$REPO_ROOT/linux/pz" server homelab restore --source "$BKT/bk1" --yes 2>/dev/null | grep -v '^INFO:' || true)"
    printf '%s\n' "$m_out" | jq -e --arg v "$rb_vol" '.ok == false and .failedVolume == $v and .rollbackApplied == true and .recoveryRequired == false and .rolledBack != null' >/dev/null \
        || { echo "FAIL: matrix scenario $scenario wrong output (REV-001/R01): $m_out"; exit 1; }
    test "$(cat "$VM/vaultwarden_data/db.sqlite")" = "round-$scenario-vw" \
        || { echo "FAIL: scenario $scenario lost vaultwarden pre-restore bytes (REV-001/R01)"; exit 1; }
    test "$(cat "$VM/syncthing_data/a.txt")" = "round-$scenario-st" \
        || { echo "FAIL: scenario $scenario lost syncthing pre-restore bytes (REV-001/R01)"; exit 1; }
done
echo "  restore failed mutation rolls back at every position ok (REV-001 matrix)"
# REV-001: when even the rollback cannot complete, the result says
# recovery-required instead of claiming rollbackApplied:true.
# shellcheck disable=SC2016 # o corpo do stub é literal de propósito: a expansão acontece quando o stub roda, não agora
printf '#!/usr/bin/env bash\nif [ "${*: -1}" = "$PZ_REV1_TARGET" ]; then exit 42; fi\nexec %q "$@"\n' "$real_cp" > "$SHIM/cp"
rev2_out="$(env PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$BKT" \
    PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data syncthing_data' \
    PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$VM" \
    PATH="$SHIM:$PATH" PZ_REV1_TARGET="$VM/vaultwarden_data/" \
    "$REPO_ROOT/linux/pz" server homelab restore --source "$BKT/bk1" --yes 2>/dev/null | grep -v '^INFO:' || true)"
printf '%s\n' "$rev2_out" | jq -e '.ok == false and .rollbackApplied == false and .recoveryRequired == true and (.rollbackFailed | index("vaultwarden_data") != null) and .nextAction != null' >/dev/null \
    || { echo "FAIL: failed rollback not reported as recovery-required (REV-001): $rev2_out"; exit 1; }
rm -rf "$VM/vaultwarden_data" && mkdir -p "$VM/vaultwarden_data"
echo "  restore failed rollback reports recovery-required ok (REV-001)"
# REV-002: sqlite volumes are hot-backed up from the LIVE mount through the
# sqlite3 backup API; a concurrent writer cannot tear the backup, stale
# WAL/SHM sidecars never ship, and a restored database passes integrity.
if command -v sqlite3 >/dev/null 2>&1; then
    REV2="$TMP/rev2-mount"; rm -rf "$REV2"; mkdir -p "$REV2/rev2_vol"
    sqlite3 "$REV2/rev2_vol/data.db" "PRAGMA journal_mode=WAL; CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);" >/dev/null
    for i in 1 2 3; do sqlite3 "$REV2/rev2_vol/data.db" "INSERT INTO t(v) VALUES ('seed-$i');"; done
    rm -f "$TMP/rev2-stop"
    (
        i=0
        while [ ! -e "$TMP/rev2-stop" ]; do
            sqlite3 "$REV2/rev2_vol/data.db" "INSERT INTO t(v) VALUES ('w-$i');" 2>/dev/null || true
            i=$((i + 1))
            sleep 0.02
        done
    ) &
    rev2_writer=$!
    rev2_err="$TMP/rev2-backup.stderr"
    rev2_out="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$TMP/rev2-bk" \
        PZ_HOMELAB_VOLUMES_OVERRIDE='rev2_vol' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$REV2" \
        "$REPO_ROOT/linux/pz" server homelab backup --dest "$TMP/rev2-bk/bk" 2>"$rev2_err" | grep -v '^INFO:' || true)"
    touch "$TMP/rev2-stop"
    wait "$rev2_writer" 2>/dev/null || true
    echo "$rev2_out" | jq -e '.ok == true and .consistent == true and .volumes[0].consistent == true and .volumes[0].method == "staged-tar+sqlite-live-hotbackup" and .volumes[0].reason == null' >/dev/null \
        || { echo "FAIL: sqlite backup not consistent live hot-backup (REV-002): $rev2_out"; cat "$rev2_err"; exit 1; }
    REV2R="$TMP/rev2-restore"; rm -rf "$REV2R"; mkdir -p "$REV2R"
    PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_VOLUMES_OVERRIDE='rev2_vol' \
        PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$REV2R" \
        "$REPO_ROOT/linux/pz" server homelab restore --source "$TMP/rev2-bk/bk" --yes >/dev/null 2>&1
    test ! -e "$REV2R/rev2_vol/data.db-wal" || { echo "FAIL: stale WAL shipped with hot backup (REV-002)"; exit 1; }
    test ! -e "$REV2R/rev2_vol/data.db-shm" || { echo "FAIL: stale SHM shipped with hot backup (REV-002)"; exit 1; }
    test "$(sqlite3 "$REV2R/rev2_vol/data.db" 'PRAGMA integrity_check;' 2>/dev/null)" = "ok" \
        || { echo "FAIL: restored sqlite failed integrity_check (REV-002)"; exit 1; }
    test "$(sqlite3 "$REV2R/rev2_vol/data.db" 'SELECT count(*) FROM t;' 2>/dev/null)" -ge 3 \
        || { echo "FAIL: restored sqlite lost seed rows (REV-002)"; exit 1; }
    echo "  sqlite live hot-backup under concurrent writer ok (REV-002)"
else
    echo "  SKIP REV-002 (sqlite3 unavailable)"
fi
# R01-004: the consistency reason reaches manifest + result — nothing rides
# on a side variable that the $(...) command substitution would discard.
R04="$TMP/rev4-pg"; rm -rf "$R04"; mkdir -p "$R04/rev4_vol"
echo 16 > "$R04/rev4_vol/PG_VERSION"
r04_out="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$TMP/rev4-bk" \
    PZ_HOMELAB_VOLUMES_OVERRIDE='rev4_vol' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$R04" \
    "$REPO_ROOT/linux/pz" server homelab backup --dest "$TMP/rev4-bk/bk" 2>/dev/null | grep -v '^INFO:' || true)"
echo "$r04_out" | jq -e '.ok == true and .consistent == false and .volumes[0].consistent == false and (.volumes[0].reason | length > 0) and (.volumes[0].reason | test("server database"))' >/dev/null \
    || { echo "FAIL: server-engine reason missing from backup result (R01-004): $r04_out"; exit 1; }
jq -e '.volumes[0].consistent == false and (.volumes[0].reason | length > 0)' "$TMP/rev4-bk/bk/manifest.json" >/dev/null \
    || { echo "FAIL: server-engine reason missing from manifest (R01-004)"; exit 1; }
echo "  backup reason survives subshell ok (R01-004)"
# R01-005: the real Prometheus TSDB layout (wal/ + chunks_head/ + block
# dirs with index/chunks) is never classified consistent by a live copy.
R05="$TMP/rev5-tsdb"; rm -rf "$R05"; mkdir -p "$R05/rev5_vol/wal" "$R05/rev5_vol/chunks_head" "$R05/rev5_vol/01ABC/chunks"
: > "$R05/rev5_vol/01ABC/index"
: > "$R05/rev5_vol/01ABC/meta.json"
r05_out="$(PZ_HOMELAB_STATE="$PZ_HOMELAB_STATE" PZ_HOMELAB_BACKUP_ROOT="$TMP/rev5-bk" \
    PZ_HOMELAB_VOLUMES_OVERRIDE='rev5_vol' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE="$R05" \
    "$REPO_ROOT/linux/pz" server homelab backup --dest "$TMP/rev5-bk/bk" 2>/dev/null | grep -v '^INFO:' || true)"
echo "$r05_out" | jq -e '.ok == true and .consistent == false and .volumes[0].consistent == false and (.volumes[0].reason | test("TSDB"))' >/dev/null \
    || { echo "FAIL: real TSDB layout classified consistent (R01-005): $r05_out"; exit 1; }
echo "  real TSDB layout fails conservative ok (R01-005)"
# PZ-AUD-009: empty set fails closed; explicit --allow-empty records emptiness.
# (A single space keeps the override active while selecting zero volumes.)
if eval "$BENV PZ_HOMELAB_VOLUMES_OVERRIDE=' ' '$REPO_ROOT/linux/pz' server homelab backup --dest '$TMP/empty-refused'" >/dev/null 2>&1; then
    echo "FAIL: empty backup accepted without --allow-empty"; exit 1
fi
empty_out="$(eval "$BENV PZ_HOMELAB_VOLUMES_OVERRIDE=' ' '$REPO_ROOT/linux/pz' server homelab backup --dest '$TMP/empty-ok' --allow-empty 2>/dev/null" | grep -v '^INFO:')"
echo "$empty_out" | jq -e '.ok == true and .empty == true and (.volumes|length) == 0' >/dev/null
# PZ-AUD-009: a missing required volume fails closed with the name listed.
if eval "PZ_HOMELAB_STATE=$PZ_HOMELAB_STATE PZ_HOMELAB_BACKUP_ROOT=$BKT PZ_HOMELAB_VOLUMES_OVERRIDE='vaultwarden_data vol_missing_nope' PZ_HOMELAB_VOLUME_MOUNT_OVERRIDE=$VM '$REPO_ROOT/linux/pz' server homelab backup --dest '$TMP/missing-refused'" >/dev/null 2>&1; then
    echo "FAIL: backup with missing volume succeeded"; exit 1
fi
test ! -f "$TMP/missing-refused/manifest.json" || { echo "FAIL: manifest written for incomplete backup"; exit 1; }
echo "  backup empty/missing fail closed ok"
# PZ-AUD-010: extra archives outside the manifest are never applied, and
# files created after the backup are removed (exact state).
echo "posterior-data" > "$VM/vaultwarden_data/posterior.txt"
echo "EVIL" > "$TMP/evil.txt"
tar -C "$TMP" -czf "$BKT/bk1/evil_extra.tgz" evil.txt 2>/dev/null
rm -f "$VM/vaultwarden_data/db.sqlite"
exact_out="$(eval "$BENV '$REPO_ROOT/linux/pz' server homelab restore --source '$BKT/bk1' --yes 2>/dev/null" | grep -v '^INFO:')"
echo "$exact_out" | jq -e '.ok == true' >/dev/null
test ! -e "$VM/evil_extra" || { echo "FAIL: extra archive applied"; exit 1; }
test ! -e "$VM/vaultwarden_data/posterior.txt" || { echo "FAIL: post-backup file survived restore"; exit 1; }
grep -q 'secret-password-1' "$VM/vaultwarden_data/db.sqlite"
rm -f "$BKT/bk1/evil_extra.tgz"
echo "  restore ignores extras and converges exact state ok"
# status surfaces lastBackup + verified
PZ_HOMELAB_BACKUP_ROOT="$BKT" "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/bkst.json 2>&1 || true
jq -e '.backupState.backups == ["bk1"] and .backupState.lastBackup.latest != null and .backupState.verified == false' /tmp/bkst.json >/dev/null
echo "  status backup state ok"

echo "=== ai policy broker + hardened adapters ==="
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.conservative == true and (.deniedActions | index("ollama-pull")) and (.deniedActions | index("hermes-install"))' >/dev/null
echo "  policy conservative default ok"
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check ollama-pull | jq -e '.allow == false' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check openclaw-install version=0.9.4 | jq -e '.allow == true' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check hermes-install | jq -e '.allow == false' >/dev/null
hcksum="$(printf 'a%.0s' {1..64})"
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$hcksum" | jq -e '.allow == true' >/dev/null
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check codex-install | jq -e '.allow == true' >/dev/null
echo "  broker action checks ok"
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" set permissive >/dev/null
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.mode == "permissive" and .conservative == false' >/dev/null
echo "  policy set ok"
# invalid mode must be rejected and leave the current mode untouched
if PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" set bogus >/dev/null 2>&1; then
    echo "FAIL: broker accepted bogus mode"; exit 1
fi
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" status | jq -e '.mode == "permissive"' >/dev/null
echo "  policy invalid mode rejected ok"
# unknown action must fail closed (deny), never allow
PZ_AI_STATE="$TMP/ai-state" PZ_AI_POLICY_MODE=conservative \
    "$REPO_ROOT/linux/server/ai-policy-broker.sh" check mystery-action | jq -e '.allow == false and (.reasons | length) == 1' >/dev/null
echo "  policy unknown action denied ok"
# hardened adapters: no latest, no auto-pull, no unchecksummed remotes, pinned tags
if rg -q 'openclaw@latest|@openai/codex@latest' "$REPO_ROOT/linux/ai/setup-openclaw.sh" "$REPO_ROOT/linux/ai/setup-codex.sh"; then
    echo "FAIL: versionless install found in openclaw/codex setup"; exit 1
fi
if rg -q 'ollama pull llama3.1|nohup ollama pull' "$REPO_ROOT/linux/ai/setup-ollama.sh"; then
    echo "FAIL: auto-pull found in ollama setup"; exit 1
fi
if rg -q 'PZ_HERMES_INSTALL_SHA256' "$REPO_ROOT/linux/ai/setup-hermes.sh"; then
    echo "FAIL: arbitrary Hermes installer checksum bypass found"; exit 1
fi
rg -q 'PZ_HERMES_ACCEPT_UNAUDITED_COMMIT' "$REPO_ROOT/linux/ai/setup-hermes.sh"
rg -q 'hermes-distribution-audit.json' "$REPO_ROOT/linux/ai/setup-hermes.sh"
if rg -q -- '--network host' "$REPO_ROOT/linux/ai/setup-memory.sh"; then
    echo "FAIL: --network host found in setup-memory"; exit 1
fi
if rg -q 'ai-memory:latest' "$REPO_ROOT/linux/ai/setup-memory.sh"; then
    echo "FAIL: ai-memory:latest found in setup-memory"; exit 1
fi
rg -q 'AI_MEMORY_VERSION=.*1\.31\.1' "$REPO_ROOT/linux/ai/setup-memory.sh"
rg -q 'AI_MEMORY_SHA256_X86_64=' "$REPO_ROOT/linux/ai/setup-memory.sh"
rg -q 'install_native_release' "$REPO_ROOT/linux/ai/setup-memory.sh"
echo "  adapters hardened ok"
# status now carries a real policy
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/pz" server homelab status --json >/tmp/pol.json 2>&1 || true
jq -e '.securityState.policyActive == false and .securityState.policy.mode == "permissive"' /tmp/pol.json >/dev/null
echo "  status policy wiring ok"
# PZ-AUD-023: install policy must not pose as execution sandbox.
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" status \
    | jq -e '.scope == "install-policy" and .executionEnforced == false' >/dev/null
PZ_AI_STATE="$TMP/ai-state" "$REPO_ROOT/linux/server/ai-policy-broker.sh" check ollama-pull \
    | jq -e '.scope == "install-policy" and .executionEnforced == false' >/dev/null
"$REPO_ROOT/linux/pz" server homelab status --json 2>/dev/null \
    | jq -e '.securityState.scope == "install-policy" and .securityState.executionEnforced == false' >/dev/null
echo "  install-policy scope ok"

echo "=== Homelab smoke ok ==="
