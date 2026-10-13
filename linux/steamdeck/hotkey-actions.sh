#!/usr/bin/env bash
# hotkey-actions.sh - run a PhaseZero desktop-mode hotkey action with
# discreet on-screen feedback. Desktop entries, KDE global shortcuts and the
# tray menu all dispatch through here so the user always sees what fired.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"
# shellcheck source=./osd.sh
source "$DIR/osd.sh"

PZ_BIN="$PZ_ROOT/linux/pz"

keyboard_visible_now() {
    # A leftover onboard/wvkbd process is not an open keyboard on Wayland.
    bash "$DIR/input-actions.sh" status 2>/dev/null |
        jq -e '.open.effective == true or .kde.visible == true' >/dev/null 2>&1
}

run_keyboard_toggle() {
    local was_open=false
    keyboard_visible_now && was_open=true
    bash "$DIR/input-actions.sh" keyboard || true
    if keyboard_visible_now; then
        pz_osd_show "input-keyboard-virtual-on" "Teclado virtual aberto"
    elif [ "$was_open" = true ]; then
        pz_osd_show "input-keyboard-virtual-off" "Teclado virtual fechado"
    else
        pz_osd_show "input-keyboard-virtual-off" "Teclado virtual não abriu"
    fi
}

ACTION="${1:-}"
shift || true

case "$ACTION" in
    handheld)
        pz_osd_show "computer-symbolic" "Meta+Shift+F1 — Aplicando modo Handheld…"
        exec "$PZ_BIN" steamdeck handheld
        ;;
    docked-monitor)
        pz_osd_show "video-display" "Meta+Shift+F2 — Aplicando modo Docked Monitor…"
        exec "$PZ_BIN" steamdeck docked-monitor
        ;;
    docked-tv)
        pz_osd_show "video-television" "Meta+Shift+F3 — Aplicando modo Docked TV…"
        exec "$PZ_BIN" steamdeck docked-tv
        ;;
    keyboard)
        run_keyboard_toggle
        ;;
    console)
        pz_osd_show "applications-games" "Meta+Shift+F5 — Abrindo Steam Gamepad UI…"
        exec "$PZ_BIN" steamdeck console
        ;;
    dev)
        pz_osd_show "utilities-terminal" "Meta+Shift+F6 — Sessão desktop/dev"
        exec "$PZ_BIN" steamdeck dev
        ;;
    cheatsheet)
        exec bash "$DIR/tray.sh" cheatsheet
        ;;
    voice)
        exec bash "$DIR/voice-typing.sh" toggle
        ;;
    overview)
        # KWin already owns Meta+W for the Overview effect; going through its
        # D-Bus entry means the controller binding and the keyboard shortcut
        # trigger the same thing even if the user rebinds the key.
        pz_osd_show "view-presentation" "Meta+Shift+F9 — Visão geral das atividades"
        if command -v qdbus6 >/dev/null 2>&1; then
            exec qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.toggleEffect overview
        fi
        pz_error "qdbus6 ausente; não consegui alternar a visão geral"
        exit 1
        ;;
    controller-reverted)
        # The revert timer calls this. Without it the daemon just vanishes and
        # the map looks broken rather than withdrawn.
        pz_osd_show "input-gamepad" "Mapa do controle revertido (não confirmado). Rode: pz steamdeck controller start"
        ;;
    *)
        pz_error "usage: hotkey-actions.sh (handheld|docked-monitor|docked-tv|keyboard|console|dev|cheatsheet|voice|overview|controller-reverted)"
        exit 1
        ;;
esac
