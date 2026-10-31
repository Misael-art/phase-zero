#!/usr/bin/env bash
# input-restore.sh - never leave the Deck without trackpad, keyboard or
# button shortcuts after a game.
#
# During a game a frontend (RetroFE) swaps Steam's Desktop controller profile
# for a gamepad profile and suspends KDE global shortcuts. Its own guardian
# restores both when the game ends. This is the independent safety net:
#
#   status   JSON view of every piece the desktop needs
#   restore  ask the frontend's recovery to finish, then re-check the desktop
#            pieces PhaseZero owns (KWin keyboard, terminal watcher)
#   install-launcher  touch-friendly "Restaurar controles" entry; the
#            touchscreen keeps working even when every controller map is gone
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
RETROFE_STATE_DIR="${PZ_RETROFE_STATE_DIR:-$STATE_HOME/retrofe/input-session}"
RETROFE_STEAM_STATE="$RETROFE_STATE_DIR/steam-desktop-session.json"
RETROFE_GUARD_STATE="$RETROFE_STATE_DIR/kde-global-shortcut-guard.json"
RECOVERY_UNIT="retrofe-input-recovery.service"
TERMINAL_UNIT="phasezero-terminal-keyboard.service"
LAUNCHER_PATH="${XDG_DATA_HOME:-$HOME/.local/share}/applications/phasezero-input-restore.desktop"

# The frontend root comes from its recovery unit, so a moved install is found
# without configuration. PZ_RETROFE_ROOT overrides.
retrofe_root() {
    if [ -n "${PZ_RETROFE_ROOT:-}" ]; then printf '%s\n' "$PZ_RETROFE_ROOT"; return 0; fi
    local exec_line
    exec_line="$(systemctl --user cat "$RECOVERY_UNIT" 2>/dev/null | grep '^ExecStart=' | tail -1 || true)"
    if [[ "$exec_line" =~ \"--root\"\ \"([^\"]+)\" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    [ -d "$HOME/emulation/frontend/RetroFE" ] && printf '%s\n' "$HOME/emulation/frontend/RetroFE"
    return 0
}

steam_input_tool() {
    local root; root="$(retrofe_root)"
    [ -n "$root" ] && [ -f "$root/Tools/launchers/retrofe/steam-input.py" ] &&
        printf '%s\n' "$root/Tools/launchers/retrofe/steam-input.py"
    return 0
}

unit_state() { systemctl --user is-active "$1" 2>/dev/null || true; }

# KWin exposes no "enabled" D-Bus property; kwinrc is the source of truth.
kwin_keyboard_enabled() {
    command -v kreadconfig6 >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
    local value
    value="$(kreadconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled 2>/dev/null || true)"
    printf '%s\n' "${value:-unset}"
}

# Owners recorded in the frontend state that are still alive mean a game is
# running and the gamepad profile is expected, not stuck.
game_session_alive() {
    local lease
    lease="$(python3 "$DIR/desktop_session.py" lease)" || return 2
    jq -e '.active == true or .externalGameActive == true' <<<"$lease" >/dev/null
}

input_status() {
    local steam_pending=false guard_pending=false game=false stuck=false lease_error=false health
    [ -f "$RETROFE_STEAM_STATE" ] && steam_pending=true
    [ -f "$RETROFE_GUARD_STATE" ] && guard_pending=true
    if game_session_alive; then game=true
    elif [ "$?" -eq 2 ]; then lease_error=true
    fi
    if { $steam_pending || $guard_pending; } && ! $game; then stuck=true; fi
    health="$(python3 "$DIR/desktop_session.py" health)" || health='null'
    jq -n \
        --argjson health "$health" --argjson leaseError "$lease_error" \
        --argjson steamPending "$steam_pending" --argjson guardPending "$guard_pending" \
        --argjson game "$game" --argjson stuck "$stuck" \
        --arg recovery "$(unit_state "$RECOVERY_UNIT")" \
        --arg terminal "$(unit_state "$TERMINAL_UNIT")" \
        --arg kwinKeyboard "$(kwin_keyboard_enabled)" \
        --arg root "$(retrofe_root)" \
        --argjson launcher "$([ -f "$LAUNCHER_PATH" ] && echo true || echo false)" \
        ' (($health.keyboard.available == "true") and
            ($health.touchscreen != "missing") and
            (all($health.devices[]?; .enabled == "true")) and
            ($health.audio != null)) as $ready | {
            tool: "steamdeck-input",
            mode: (if $game then "game" elif $stuck then "stuck" else "desktop" end),
            ok: (($stuck | not) and ($leaseError | not) and $ready),
            ownershipRecovered: (($stuck | not) and ($leaseError | not)),
            desktopReady: $ready,
            health: $health,
            leaseError: $leaseError,
            gameSessionAlive: $game,
            steamGamepadProfilePending: $steamPending,
            kdeShortcutsSuspended: $guardPending,
            frontendRecovery: {unit: $recovery, root: (if $root == "" then null else $root end)},
            terminalKeyboardWatcher: $terminal,
            kwinVirtualKeyboardEnabled: $kwinKeyboard,
            restoreLauncher: $launcher
        }'
}

notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send --app-name=PhaseZero "$@" >/dev/null 2>&1 || true
}

input_restore() {
    local tool errors=0 lease
    lease="$(python3 "$DIR/desktop_session.py" lease)" || {
        pz_warn "estado de sessão ilegível; recuperação preservada para diagnóstico"
        return 1
    }
    if jq -e '.active or .externalGameActive' <<<"$lease" >/dev/null && [ "${1:-}" != "--force" ]; then
        pz_warn "jogo ainda ativo; o perfil de controle volta ao Desktop quando ele fechar (use --force para restaurar já)"
        return 0
    fi
    # Restore local controls before any potentially slow Steam API operation.
    python3 "$DIR/desktop_session.py" reconcile || errors=$((errors + 1))
    tool="$(steam_input_tool)"
    if [ -n "$tool" ]; then
        if python3 "$tool" --root "$(retrofe_root)" session-recover; then
            pz_info "frontend: perfil Desktop do Steam e atalhos KDE restaurados"
        else
            pz_warn "frontend: recuperação ainda pendente (Steam fechado ou controle desconectado?)"
            errors=$((errors + 1))
        fi
        # Restart the frontend guardian so it keeps retrying after us.
        [ "$(unit_state "$RECOVERY_UNIT")" = active ] || systemctl --user restart "$RECOVERY_UNIT" 2>/dev/null || true
    fi
    if systemctl --user cat "$TERMINAL_UNIT" >/dev/null 2>&1 && [ "$(unit_state "$TERMINAL_UNIT")" != active ]; then
        systemctl --user restart "$TERMINAL_UNIT" >/dev/null 2>&1 && pz_info "watcher do teclado no terminal religado" || true
    fi
    if [ "$errors" -eq 0 ] && input_status | jq -e '.ok' >/dev/null; then
        if [ "${1:-}" != --background ]; then
            notify "Configuração do desktop restaurada" "Teste teclado, ponteiro, áudio e microfone."
        fi
        return 0
    fi
    if [ "${1:-}" != --background ]; then
        notify --urgency=critical "Restauração incompleta" "Consulte pz steamdeck input status. Estado anterior preservado."
    fi
    return 1
}

install_launcher() {
    mkdir -p "$(dirname "$LAUNCHER_PATH")"
    cat > "$LAUNCHER_PATH" <<EOF
[Desktop Entry]
Type=Application
Name=Restaurar controles
Comment=Volta trackpad, teclado e atalhos do Desktop se ficarem no modo jogo
Exec="$PZ_ROOT/linux/pz" steamdeck input restore --force
Icon=input-gaming
Terminal=false
Categories=Settings;
X-PhaseZero-Managed=input-restore
EOF
    pz_info "atalho touch instalado: $LAUNCHER_PATH"
}

case "${1:-status}" in
    status) input_status ;;
    restore|recover) shift; input_restore "$@" ;;
    install-launcher) install_launcher ;;
    install)
        tool="$(steam_input_tool)"
        [ -z "$tool" ] || python3 "$tool" --root "$(retrofe_root)" session-recovery-ensure
        exec python3 "$DIR/desktop_session.py" install
        ;;
    watch|reconcile) exec python3 "$DIR/desktop_session.py" "$1" ;;
    *) printf 'usage: input-restore.sh (status|restore [--force]|install|watch|reconcile|install-launcher)\n' >&2; exit 2 ;;
esac
