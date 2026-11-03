#!/usr/bin/env bash
# Unified PhaseZero application and host-update inventory.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
ACTION="${1:-check}"
shift 2>/dev/null || true
STATE_DIR="$PZ_STATE/app-updates"
STATE_FILE="$STATE_DIR/latest.json"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE="phasezero-app-update-check.service"
TIMER="phasezero-app-update-check.timer"

safe_json() {
    local output="$1"; shift
    if timeout 90 "$@" > "$output" 2>/dev/null && jq -e . "$output" >/dev/null 2>&1; then return 0; fi
    # shellcheck disable=SC2094 # intentional: read parent dir from path, write to file
    jq -n --arg component "$(basename "$output" .json)" '{status:"unavailable",component:$component}' > "$output"
}

host_updates() {
    local output="$1" list count=0
    list="$(pz_tempfile)"
    if command -v checkupdates >/dev/null 2>&1; then
        checkupdates > "$list" 2>/dev/null || [ "$?" -eq 2 ] || true
        count="$(awk 'NF {count++} END {print count+0}' "$list")"
        jq -Rn --argjson count "$count" '[inputs | split(" ") | {package:.[0],current:.[1],candidate:.[3]}] as $items | {manager:"pacman",pending:$count,packages:$items,applyPolicy:"explicit-admin-pacman-Syu"}' < "$list" > "$output"
    else
        jq -n '{manager:"unknown",pending:null,packages:[],applyPolicy:"distribution-native-explicit"}' > "$output"
    fi
    rm -f "$list"
}

check_all() (
    local work payload update_count codex_failed codex_ready codex_mismatch codex_unverified
    work="$(pz_tempfile -d)"; trap 'rm -rf "$work"' EXIT
    safe_json "$work/core.json" env PYTHONPATH="$PZ_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m linux.installation.update_cli check &
    safe_json "$work/install.json" env PYTHONPATH="$PZ_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m linux.installation status &
    safe_json "$work/9router.json" bash "$PZ_ROOT/linux/ai/9router-manager.sh" check-update &
    safe_json "$work/odysseus.json" bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" check-update &
    safe_json "$work/desktop.json" bash "$PZ_ROOT/linux/ai/desktop-apps.sh" status &
    safe_json "$work/codex.json" bash "$PZ_ROOT/linux/ai/setup-codex.sh" status &
    safe_json "$work/windows.json" bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" status &
    host_updates "$work/host.json" &
    wait
    payload="$(jq -n \
        --slurpfile core "$work/core.json" --slurpfile installation "$work/install.json" \
        --slurpfile router "$work/9router.json" --slurpfile odysseus "$work/odysseus.json" \
        --slurpfile desktop "$work/desktop.json" --slurpfile codex "$work/codex.json" --slurpfile windows "$work/windows.json" --slurpfile host "$work/host.json" \
        '{schemaVersion:1,checkedAt:(now|todateiso8601),components:{phasezero:$core[0],installation:$installation[0],"9router":$router[0],odysseus:$odysseus[0],desktopApps:$desktop[0],codex:$codex[0],windowsFrontends:$windows[0],host:$host[0]},policy:{automaticApply:false,userApps:"verified-explicit",host:"admin-full-upgrade-only",partialArchUpgrades:false}}')"
    update_count="$(jq '[.components.phasezero.updateAvailable,.components["9router"].updateAvailable,.components.odysseus.updateAvailable] | map(select(.==true)) | length' <<< "$payload")"
    codex_failed="$(jq -r '.components.desktopApps.codexDesktop.updateStatus == "failed"' <<< "$payload")"
    codex_ready="$(jq -r '.components.desktopApps.codexDesktop.updateStatus == "ready_to_install"' <<< "$payload")"
    codex_mismatch="$(jq -r '.components.codex.requiresAttention == true' <<< "$payload")"
    codex_unverified="$(jq -r '.components.codex.installed == true and .components.codex.coherent == null' <<< "$payload")"
    jq --argjson count "$update_count" --argjson codexFailed "$codex_failed" --argjson codexReady "$codex_ready" --argjson codexMismatch "$codex_mismatch" --argjson codexUnverified "$codex_unverified" \
        '.summary={verifiedAppUpdates:$count,hostUpdates:(.components.host.pending // null),codexUpdateFailed:$codexFailed,codexDesktopReady:$codexReady,codexMismatch:$codexMismatch,codexUnverified:$codexUnverified,requiresAttention:($count>0 or $codexFailed or $codexReady or $codexMismatch or $codexUnverified or ((.components.host.pending // 0)>0) or ((.components.installation.native.alteredFiles // 0)>0))}' <<< "$payload"
)

write_state() {
    install -d -m 0700 "$STATE_DIR"
    local tmp
    tmp="$(pz_tempfile)"
    check_all > "$tmp"
    install -m 0600 "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    if command -v notify-send >/dev/null 2>&1 && jq -e '.summary.requiresAttention==true' "$STATE_FILE" >/dev/null; then
        notify-send -a PhaseZero "Atualizações PhaseZero" "Atualizações ou reparos disponíveis. Abra o Centro de Controle."
    fi
    cat "$STATE_FILE"
}

install_timer() {
    install -d "$SYSTEMD_USER_DIR"
    pz_write_managed_file "$SYSTEMD_USER_DIR/$SERVICE" user <<EOF
[Unit]
Description=PhaseZero verified app and host update check
After=network-online.target

[Service]
Type=oneshot
ExecStart=$HOME/.local/share/phasezero/current/linux/updates/app-updates.sh check-state
EOF
    pz_write_managed_file "$SYSTEMD_USER_DIR/$TIMER" user <<EOF
[Unit]
Description=Daily PhaseZero application update check

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER"
    jq -cn --arg timer "$TIMER" '{status:"complete",timer:$timer,automaticApply:false}'
}

apply_one() {
    local target="${1:-}"
    case "$target" in
        9router) bash "$PZ_ROOT/linux/ai/9router-manager.sh" update ;;
        odysseus) bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" update ;;
        codex) bash "$PZ_ROOT/linux/ai/setup-codex.sh" update ;;
        qwen-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-qwen ;;
        claude-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" install-claude ;;
        codex-desktop) bash "$PZ_ROOT/linux/ai/desktop-apps.sh" apply-codex ;;
        windows-frontends) bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" setup ;;
        phasezero) pz_error "use: pz self-update plan; then confirmed apply"; return 2 ;;
        host) pz_error "Arch host update remains explicit: phasezero-admin pacman -Syu"; return 2 ;;
        *) pz_error "usage: pz updates apply (9router|odysseus|codex|qwen-desktop|claude-desktop|codex-desktop|windows-frontends)"; return 2 ;;
    esac
}

case "$ACTION" in
    check|status) check_all ;;
    check-state) write_state >/dev/null ;;
    latest) if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else check_all; fi ;;
    apply|update) apply_one "${1:-}" ;;
    install-service|install-timer) install_timer ;;
    timer-status) systemctl --user status "$TIMER" --no-pager ;;
    *) pz_error "usage: pz updates (check|latest|apply <component>|install-service|timer-status)"; exit 2 ;;
esac
