#!/usr/bin/env bash
# controller-desktop.sh - drive the KDE Plasma desktop with the Deck controller.
#
# The kernel's hid-steam driver ships "lizard mode", which already emits a
# mouse from the right trackpad and a few keys. That is all it emits: ABXY,
# the back paddles and the shoulder chords carry nothing, so a desktop map
# needs a userspace mapper. sc-controller opens the native Valve HID device
# and re-emits through uinput, which is why it can reach controls that never
# appear on the evdev nodes lizard mode publishes.
#
# Taking that device over switches lizard mode off (the driver re-asserts the
# unlizard command on an interval). If the daemon then dies with the profile
# half-applied, a Deck with no keyboard attached has no working pointer left.
# Every start therefore arms a revert timer that stops the daemon unless
# `confirm` runs first.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

PROFILE_NAME="${PZ_CONTROLLER_PROFILE_NAME:-PhaseZero-Desktop}"
PROFILE_SRC="$DIR/profiles/$PROFILE_NAME.sccprofile"
SCC_CONFIG_DIR="${PZ_SCC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/scc}"
PROFILE_DIR="$SCC_CONFIG_DIR/profiles"
PROFILE_DEST="$PROFILE_DIR/$PROFILE_NAME.sccprofile"
# 90s was not enough to pick the Deck up, try a dozen bindings and get back
# to a terminal; the map reverted mid-test and looked broken.
REVERT_SECONDS="${PZ_CONTROLLER_REVERT_SECONDS:-300}"
REVERT_PIDFILE="$SCC_CONFIG_DIR/phasezero-revert.pid"
DAEMON_PIDFILE="$SCC_CONFIG_DIR/daemon.pid"
SYSTEMD_USER_DIR="${PZ_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
SERVICE_NAME="phasezero-controller-desktop.service"
SERVICE_PATH="$SYSTEMD_USER_DIR/$SERVICE_NAME"
# Per-application compatibility layer (controller_apps.py): swaps in a derived
# profile while an application with different shortcuts has focus.
APPS_HELPER="$DIR/controller_apps.py"
APPS_SERVICE_NAME="phasezero-controller-apps.service"
APPS_SERVICE_PATH="$SYSTEMD_USER_DIR/$APPS_SERVICE_NAME"

# Overridable so the suite can exercise the missing-mapper path without
# uninstalling the package on the machine running the tests.
scc_daemon_bin() {
    if [ -n "${PZ_SCC_DAEMON_BIN+x}" ]; then
        printf '%s\n' "$PZ_SCC_DAEMON_BIN"
        return 0
    fi
    command -v scc-daemon 2>/dev/null
}

controller_present() {
    local dev vendor product
    for dev in "${PZ_CONTROLLER_SYSFS_ROOT:-/sys/bus/usb/devices}"/*; do
        vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
        product="$(cat "$dev/idProduct" 2>/dev/null || true)"
        [ "$vendor" = "28de" ] && [ "$product" = "1205" ] && return 0
    done
    return 1
}

# Steam Input claims the same device and expects to own it. Two mappers on one
# controller produce doubled input, not a merged map, so the desktop profile
# stays out of the way whenever Steam or a gamescope session is up.
conflicting_session() {
    pgrep -x steam >/dev/null 2>&1 && { printf 'steam\n'; return 0; }
    pgrep -f steamwebhelper >/dev/null 2>&1 && { printf 'steam\n'; return 0; }
    pgrep -x gamescope >/dev/null 2>&1 && { printf 'gamescope\n'; return 0; }
    return 1
}

# sc-controller writes its own pidfile; trust that over a process-name match.
# `pgrep -f scc-daemon` also matches any shell whose command line merely
# mentions the string - including this script's own helpers - so it reports a
# daemon that is not there. The socket alone is no better: it survives the
# process that created it.
daemon_pid() {
    local pid
    [ -f "$DAEMON_PIDFILE" ] || return 1
    pid="$(cat "$DAEMON_PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

# Under systemd the daemon runs with --foreground and never writes the pidfile,
# so the pidfile alone reports "stopped" for a perfectly healthy service.
service_active() {
    systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

daemon_running() { service_active || daemon_pid >/dev/null 2>&1; }

# Nothing in sc-controller starts the daemon at login, and the package ships
# no autostart either. Without a unit the map survives exactly one session and
# disappears on the next boot, which reads from the outside as "installed but
# not working" - there is no error anywhere, the controller simply goes back to
# lizard mode.
service_unit() {
    cat <<EOF
[Unit]
Description=PhaseZero Deck controller desktop map
After=graphical-session.target
# PartOf stops this unit whenever the graphical session stops. The Install
# section has to name the same target, or the pairing is one-way: a session
# that bounces - Plasma restarting takes it down for a few seconds - stops the
# map and never brings it back, and nothing reports an error. Observed on a
# real Deck: graphical-session.target went inactive at 09:46:42 and active
# again at 09:47:00; the map died with it and stayed dead for eleven hours.
PartOf=graphical-session.target
# The daemon has exited 0 on its own after losing the controller. on-failure
# treats that as a normal end and leaves the Deck without a pointer, so every
# exit has to be retried. StartLimit keeps a genuinely broken profile from
# looping forever instead.
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$(scc_daemon_bin) --foreground $PROFILE_DEST start
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
}

# The switcher only makes sense while the map runs: BindsTo stops it with the
# map (including the revert timer), and WantedBy on the map's unit starts it
# whenever the map starts once it is enabled.
apps_service_unit() {
    cat <<EOF
[Unit]
Description=PhaseZero Deck controller per-application compatibility
After=$SERVICE_NAME
BindsTo=$SERVICE_NAME

[Service]
Type=simple
ExecStart=/usr/bin/env python3 $APPS_HELPER watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=$SERVICE_NAME
EOF
}

# kdotool is what reads the focused window on KWin Wayland; without it the
# switcher would only ever see "no window" and the layer silently does nothing.
apps_switcher_available() {
    command -v kdotool >/dev/null 2>&1
}

install_service() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: escreveria $SERVICE_PATH e $APPS_SERVICE_PATH"
        return 0
    fi
    install -d "$SYSTEMD_USER_DIR"
    printf '%s\n' "$(service_unit)" >"$SERVICE_PATH"
    printf '%s\n' "$(apps_service_unit)" >"$APPS_SERVICE_PATH"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    pz_info "unit instalada: $SERVICE_PATH"
}

install_profile() {
    local content
    [ -f "$PROFILE_SRC" ] || { pz_error "perfil ausente: $PROFILE_SRC"; return 1; }
    # The shell() bindings need an absolute path, and the repo can live
    # anywhere (/usr/lib/phasezero when packaged, a checkout when developing).
    content="$(sed "s|PZ_ROOT|$PZ_ROOT|g" "$PROFILE_SRC")"

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: escreveria $PROFILE_DEST"
        return 0
    fi

    install -d "$PROFILE_DIR"
    pz_backup_file "$PROFILE_DEST" user >/dev/null 2>&1 || true
    printf '%s\n' "$content" >"$PROFILE_DEST"
    pz_info "perfil instalado: $PROFILE_DEST"
    install_app_profiles
}

# Derived from the installed desktop profile, so they carry the same PZ_ROOT
# substitution and pick up any desktop change on the next start.
install_app_profiles() {
    local report
    if ! report="$(python3 "$APPS_HELPER" generate --base "$PROFILE_DEST" --out-dir "$PROFILE_DIR" 2>&1)"; then
        pz_warn "perfis por aplicativo não gerados: $report"
        return 0
    fi
    pz_info "perfis por aplicativo: $(jq -r '[.profiles[].profile] | join(", ")' <<<"$report" 2>/dev/null || echo '?')"
    jq -r '.notes[]?' <<<"$report" 2>/dev/null | while IFS= read -r note; do
        [ -n "$note" ] && pz_warn "$note"
    done
    return 0
}

arm_revert() {
    [ "${PZ_DRY_RUN:-0}" = "1" ] && return 0
    [ "$REVERT_SECONDS" -gt 0 ] 2>/dev/null || return 0
    local revert_skip_systemctl=0
    [ "${PZ_CONTROLLER_REVERT_SKIP_SYSTEMCTL:-0}" = 1 ] && revert_skip_systemctl=1
    # setsid detaches the timer from this shell; a plain background subshell
    # dies with the terminal that ran `start`, taking the safety net with it.
    #
    # The timer kills the daemon by its recorded pid, never by pattern. A
    # pattern kill matches this very timer, whose own command line contains the
    # daemon name - it would take itself down before reverting anything, which
    # is exactly how the first version failed.
    #
    # $! after setsid is the wrapper, which exits as soon as it forks, so the
    # timer records its own pid from inside the child.
    setsid bash -c "
        printf '%s\n' \"\$\$\" >'$REVERT_PIDFILE'
        sleep $REVERT_SECONDS
        # confirm removes the pidfile; its absence means the operator came
        # back and kept the profile.
        [ -f '$REVERT_PIDFILE' ] || exit 0
        # systemctl --user always talks to the real user manager. A sandboxed
        # HOME does not redirect it, so the test suite sets this and only the
        # recorded pid is stopped.
        if [ $revert_skip_systemctl != 1 ]; then
            systemctl --user stop '$SERVICE_NAME' >/dev/null 2>&1 || true
        fi
        if [ -f '$DAEMON_PIDFILE' ]; then
            kill \"\$(cat '$DAEMON_PIDFILE' 2>/dev/null)\" >/dev/null 2>&1 || true
        fi
        rm -f '$REVERT_PIDFILE'
        # A silent revert is how this looked like a broken map: the daemon went
        # away mid-test and nothing said so.
        bash '$DIR/hotkey-actions.sh' controller-reverted >/dev/null 2>&1 || true
    " >/dev/null 2>&1 &
    # Give the child a moment to claim the pidfile so `status` and `confirm`
    # never read the wrapper pid.
    sleep 0.3
    pz_warn "reversão automática em ${REVERT_SECONDS}s; rode 'pz steamdeck controller confirm' para manter"
}

cmd_start() {
    local conflict bin
    bin="$(scc_daemon_bin)" || true

    # A dry run reports intent, so it must work on a machine that has neither
    # the mapper nor a controller attached - which is every CI runner. Only a
    # real start insists on both.
    if [ "${PZ_DRY_RUN:-0}" != "1" ]; then
        [ -n "$bin" ] || { pz_error "sc-controller ausente; instale o pacote sc-controller"; return 1; }
        if conflict="$(conflicting_session)"; then
            pz_error "$conflict está ativo e também mapeia o controle; feche antes de aplicar o perfil desktop"
            return 1
        fi
        controller_present || { pz_error "controle do Deck (28de:1205) não encontrado"; return 1; }
    else
        [ -n "$bin" ] || pz_warn "dry-run: sc-controller ausente; um start real falharia aqui"
        conflict="$(conflicting_session || true)"
        [ -n "$conflict" ] && pz_warn "dry-run: $conflict ativo; um start real seria recusado"
        controller_present || pz_warn "dry-run: controle do Deck não encontrado"
    fi

    install_profile || return 1
    install_service || return 1

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: iniciaria $SERVICE_NAME com $PROFILE_NAME"
        return 0
    fi

    # Run through systemd rather than launching the daemon directly: the unit
    # is what makes the map come back after a reboot, and starting it by hand
    # would leave the two paths able to disagree.
    if systemctl --user start "$SERVICE_NAME" >/dev/null 2>&1; then
        sleep 3
        # systemd reports "active" during a restart loop, so a started unit is
        # not the same as a working one. Claiming success here without looking
        # is how a crash-looping service passed for a live map.
        if ! service_active || [ "$(systemctl --user show -p NRestarts --value "$SERVICE_NAME" 2>/dev/null || echo 0)" -gt 0 ]; then
            pz_error "$SERVICE_NAME não estabilizou; veja: journalctl --user -u $SERVICE_NAME"
            systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            return 1
        fi
    else
        pz_warn "systemd --user indisponível; iniciando o daemon direto (não sobrevive ao reboot)"
        "$bin" "$PROFILE_DEST" start >/dev/null 2>&1 || true
        sleep 1
    fi
    start_app_switcher
    arm_revert
    pz_info "perfil desktop ativo"
}

start_app_switcher() {
    if ! apps_switcher_available; then
        pz_warn "kdotool ausente: sem troca automática por aplicativo (Ashyterm usa o mapa desktop)"
        return 0
    fi
    systemctl --user start "$APPS_SERVICE_NAME" >/dev/null 2>&1 ||
        pz_warn "não consegui iniciar $APPS_SERVICE_NAME; aplicativos usam o mapa desktop"
}

cmd_confirm() {
    if [ -f "$REVERT_PIDFILE" ]; then
        local pid
        pid="$(cat "$REVERT_PIDFILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi
        rm -f "$REVERT_PIDFILE"
        pz_info "reversão automática cancelada"
    else
        pz_info "nenhuma reversão pendente"
    fi
    # Persisting is the whole point of confirm. Without the enable the map
    # works until the session ends and then quietly stops existing.
    if [ "${PZ_DRY_RUN:-0}" != "1" ] && [ -f "$SERVICE_PATH" ]; then
        # enable only adds the link for the target the unit names today; it
        # never removes the one an older unit left behind. A host upgraded
        # from the default.target version keeps both, so the unit starts
        # outside the graphical session too. Drop the old links first.
        systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        if systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1; then
            pz_info "perfil mantido e habilitado no login"
        else
            pz_warn "não consegui habilitar $SERVICE_NAME; o perfil não voltará após reboot"
        fi
        if [ -f "$APPS_SERVICE_PATH" ] && apps_switcher_available; then
            systemctl --user enable "$APPS_SERVICE_NAME" >/dev/null 2>&1 ||
                pz_warn "não consegui habilitar $APPS_SERVICE_NAME; a troca por aplicativo não voltará após reboot"
        fi
    fi
}

cmd_stop() {
    rm -f "$REVERT_PIDFILE"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: pararia scc-daemon"
        return 0
    fi
    local pid
    systemctl --user disable --now "$APPS_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    scc-daemon stop >/dev/null 2>&1 || true
    # `scc-daemon stop` reports success even when it finds no pidfile, so it
    # cannot be the only step. Fall back to the recorded pid, not a pattern.
    if pid="$(daemon_pid)"; then
        kill "$pid" >/dev/null 2>&1 || true
    fi
    # This used to claim lizard mode came back. It does not: taking the
    # controller detaches it from hid-steam, and releasing it leaves the
    # firmware with the mouse and keyboard emulation still switched off. A
    # Deck that lost the daemon was measured with the gamepad node alone
    # (event/js, no mouse handler) for eleven hours - no pointer at all, and
    # no error anywhere. Say what actually happens and how to get out of it.
    pz_info "perfil desktop desativado; o controle não volta ao lizard mode sozinho"
    pz_info "para recuperar o ponteiro: pz steamdeck controller start"
}

# systemd --user is the real user manager. A missing binary or a dead bus is
# "indisponível", not a guess that the map is off.
systemd_user_ready() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show --property=Version >/dev/null 2>&1
}

# Theme toggles call these. They must not arm the revert timer, must not
# rewrite a profile that already exists, and must not start the apps unit.
# `start` still owns that heavier path.
cmd_persist_status() {
    local enabled active
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\n'
        return 0
    fi
    if [ ! -f "$SERVICE_PATH" ]; then
        printf 'state=desligado\nreason=padrão do Deck é ligado; ainda não está nesta sessão\n'
        return 0
    fi
    enabled="$(systemctl --user is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    active="$(systemctl --user is-active "$SERVICE_NAME" 2>/dev/null || true)"
    case "$enabled" in
        enabled|enabled-runtime|alias|indirect|generated|linked|linked-runtime)
            if [ "$active" = "active" ]; then
                printf 'state=ligado\n'
            else
                printf 'state=degradado\nreason=habilitado no login, mas parado agora\n'
            fi
            ;;
        *)
            printf 'state=desligado\nreason=padrão do Deck é ligado; desligado por escolha\n'
            ;;
    esac
}

cmd_persist_on() {
    local bin conflict was_enabled=0 was_active=0 restarts
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        printf 'state=ligado\nmutated=0\n'
        pz_info "dry-run: persistiria $SERVICE_NAME sem timer e sem reescrever perfil existente"
        return 0
    fi
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\nmutated=0\n'
        return 1
    fi
    # Already the product default. Do not rewrite the unit or the profile of
    # a map that is running: daemon-reload does not restart it, but a later
    # rollback must not be handed a reason to stop it.
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" \
        && systemctl --user is-active --quiet "$SERVICE_NAME"; then
        printf 'state=ligado\nmutated=0\n'
        return 0
    fi
    bin="$(scc_daemon_bin)" || true
    if [ -z "$bin" ]; then
        printf 'state=indisponivel\nreason=sc-controller ausente\nmutated=0\n'
        pz_error "sc-controller ausente; instale o pacote sc-controller"
        return 1
    fi
    if conflict="$(conflicting_session)"; then
        printf 'state=indisponivel\nreason=%s está ativo; o mapa não liga junto\nmutated=0\n' "$conflict"
        pz_error "$conflict está ativo e também mapeia o controle; feche antes de ligar o mapa"
        return 1
    fi
    if ! controller_present; then
        printf 'state=indisponivel\nreason=controle do Deck não encontrado\nmutated=0\n'
        pz_error "controle do Deck (28de:1205) não encontrado"
        return 1
    fi
    systemctl --user is-enabled --quiet "$SERVICE_NAME" && was_enabled=1
    systemctl --user is-active --quiet "$SERVICE_NAME" && was_active=1
    if [ ! -f "$PROFILE_DEST" ]; then
        install_profile || {
            printf 'state=indisponivel\nreason=perfil desktop ausente\nmutated=0\n'
            return 1
        }
    fi
    install_service || {
        printf 'state=indisponivel\nreason=não consegui instalar a unit\nmutated=0\n'
        return 1
    }
    if ! systemctl --user enable --now "$SERVICE_NAME"; then
        printf 'state=indisponivel\nreason=não consegui ligar o mapa\nmutated=0\n'
        return 1
    fi
    if [ "$was_active" != 1 ]; then
        sleep "${PZ_CONTROLLER_PERSIST_SETTLE:-3}"
        restarts="$(systemctl --user show -p NRestarts --value "$SERVICE_NAME" 2>/dev/null || echo 0)"
        if ! service_active || [ "${restarts:-0}" -gt 0 ]; then
            if [ "$was_enabled" = 1 ]; then
                systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            else
                systemctl --user disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            fi
            printf 'state=degradado\nreason=o mapa não estabilizou\nmutated=0\n'
            pz_error "$SERVICE_NAME não estabilizou"
            return 1
        fi
    fi
    printf 'state=ligado\nmutated=1\n'
    pz_info "mapa do controle ligado no login; sem timer de reversão"
}

cmd_persist_off() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        printf 'state=desligado\nmutated=0\n'
        pz_info "dry-run: desabilitaria só $SERVICE_NAME"
        return 0
    fi
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\nmutated=0\n'
        return 1
    fi
    # This unit only. The apps unit, scc-daemon stop and a pid kill stay on
    # the explicit `stop` path. Lizard mode still does not return.
    if ! systemctl --user disable --now "$SERVICE_NAME"; then
        printf 'state=indisponivel\nreason=não consegui desligar o mapa\nmutated=0\n'
        return 1
    fi
    printf 'state=desligado\nmutated=1\n'
    pz_info "mapa do controle desligado; o ponteiro do firmware não volta sozinho"
}

cmd_status() {
    local conflict=""
    conflict="$(conflicting_session || true)"
    local enabled="false"
    systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 && enabled="true"
    local app_profiles="[]" switcher="false"
    app_profiles="$(python3 "$APPS_HELPER" list 2>/dev/null | jq -r '.[] | "\(.app)\t\(.profile)"' 2>/dev/null |
        while IFS=$'\t' read -r app profile; do
            installed=false
            [ -f "$PROFILE_DIR/$profile.sccprofile" ] && installed=true
            printf '{"app":"%s","profile":"%s","installed":%s}\n' "$app" "$profile" "$installed"
        done | jq -sc . 2>/dev/null || echo '[]')"
    [ -n "$app_profiles" ] || app_profiles="[]"
    systemctl --user is-active --quiet "$APPS_SERVICE_NAME" 2>/dev/null && switcher="true"
    printf '{"profile":"%s","profileInstalled":%s,"serviceInstalled":%s,"enabledAtLogin":%s,"controllerPresent":%s,"daemonRunning":%s,"conflictingSession":"%s","revertPending":%s,"appProfiles":%s,"appSwitcherActive":%s}\n' \
        "$PROFILE_NAME" \
        "$([ -f "$PROFILE_DEST" ] && echo true || echo false)" \
        "$([ -f "$SERVICE_PATH" ] && echo true || echo false)" \
        "$enabled" \
        "$(controller_present && echo true || echo false)" \
        "$(daemon_running && echo true || echo false)" \
        "$conflict" \
        "$([ -f "$REVERT_PIDFILE" ] && echo true || echo false)" \
        "$app_profiles" \
        "$switcher"
}

case "${1:-status}" in
    start|install|apply) cmd_start ;;
    confirm|keep)        cmd_confirm ;;
    stop|disable)        cmd_stop ;;
    status)              cmd_status ;;
    dry-run)             PZ_DRY_RUN=1 cmd_start ;;
    persist-on)          cmd_persist_on ;;
    persist-off)         cmd_persist_off ;;
    persist-status)      cmd_persist_status ;;
    *)
        pz_error "usage: controller-desktop.sh (start|confirm|stop|status|dry-run|persist-on|persist-off|persist-status)"
        exit 1
        ;;
esac
