#!/usr/bin/env bash
# tray.sh - PhaseZero system tray for Steam Deck desktop mode (yad-based).
# Left click toggles the shortcut cheat-sheet overlay; the menu exposes the
# virtual keyboard toggle, voice typing and the cheat-sheet, so everything
# works without a physical keyboard.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
TRAY_PIDFILE="$STATE_DIR/tray.pid"
SHEET_PIDFILE="$STATE_DIR/cheatsheet.pid"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
HOTKEY="bash $DIR/hotkey-actions.sh"

pid_alive() {
    local pidfile="$1" pid
    [ -f "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

tray_menu() {
    printf '%s' \
        "Tabela de atalhos (Meta+Shift+F7)!$HOTKEY cheatsheet!input-keyboard" \
        "|Teclado virtual (Meta+Shift+F4)!$HOTKEY keyboard!input-keyboard-virtual" \
        "|Ditado por voz (Meta+Shift+F8)!$HOTKEY voice!audio-input-microphone" \
        "|Sair!bash $DIR/tray.sh stop!application-exit"
}

tray_start() {
    if ! command -v yad >/dev/null 2>&1; then
        pz_error "yad missing; install it with: sudo pacman -S yad"
        return 1
    fi
    if pid_alive "$TRAY_PIDFILE"; then
        pz_info "tray already running (pid $(cat "$TRAY_PIDFILE"))"
        return 0
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would start PhaseZero tray"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    # yad's tray mode is X11-only; on Wayland it runs via XWayland and the
    # icon reaches Plasma through xembedsniproxy.
    GDK_BACKEND=x11 nohup yad --notification \
        --image="input-keyboard-virtual" \
        --text="PhaseZero — atalhos, teclado e voz do Deck" \
        --command="bash $DIR/tray.sh cheatsheet" \
        --menu="$(tray_menu)" >/dev/null 2>&1 &
    echo "$!" > "$TRAY_PIDFILE"
    disown 2>/dev/null || true
    pz_info "tray started (pid $(cat "$TRAY_PIDFILE"))"
}

tray_stop() {
    local stopped=1
    if pid_alive "$TRAY_PIDFILE"; then
        kill "$(cat "$TRAY_PIDFILE")" 2>/dev/null || true
        stopped=0
    fi
    rm -f "$TRAY_PIDFILE"
    [ "$stopped" -eq 0 ] && pz_info "tray stopped"
    return 0
}

cheatsheet_toggle() {
    if pid_alive "$SHEET_PIDFILE"; then
        kill "$(cat "$SHEET_PIDFILE")" 2>/dev/null || true
        rm -f "$SHEET_PIDFILE"
        return 0
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would show shortcut cheat-sheet overlay"
        return 0
    fi

    mkdir -p "$STATE_DIR"
    nohup yad --list \
        --title="Atalhos PhaseZero" \
        --window-icon="input-keyboard" \
        --undecorated --on-top --center --skip-taskbar --close-on-unfocus \
        --width=560 --height=380 \
        --button="Fechar":0 \
        --column="Atalho" --column="Ação" \
        "Meta+Shift+F1" "Modo Handheld" \
        "Meta+Shift+F2" "Modo Docked Monitor" \
        "Meta+Shift+F3" "Modo Docked TV" \
        "Meta+Shift+F4" "Teclado virtual (ativar/desativar)" \
        "Meta+Shift+F5" "Steam Gamepad UI" \
        "Meta+Shift+F6" "Sessão desktop/dev" \
        "Meta+Shift+F7" "Esta tabela de atalhos" \
        "Meta+Shift+F8" "Ditado por voz (falar para digitar)" \
        "Meta+Shift+F9" "Visão geral das atividades" >/dev/null 2>&1 &
    echo "$!" > "$SHEET_PIDFILE"
    disown 2>/dev/null || true
}

tray_autostart_install() {
    local entry="$AUTOSTART_DIR/phasezero-tray.desktop"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would write $entry"
        return 0
    fi
    pz_write_managed_file "$entry" <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Tray
Comment=Atalhos, teclado virtual e ditado por voz do Steam Deck
Exec=bash $DIR/tray.sh start
Icon=input-keyboard-virtual
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
}

tray_status() {
    jq -n \
        --argjson running "$(pid_alive "$TRAY_PIDFILE" && echo true || echo false)" \
        --argjson cheatsheet "$(pid_alive "$SHEET_PIDFILE" && echo true || echo false)" \
        --argjson autostart "$([ -f "$AUTOSTART_DIR/phasezero-tray.desktop" ] && echo true || echo false)" \
        --argjson yad "$(command -v yad >/dev/null 2>&1 && echo true || echo false)" \
        '{tool: "phasezero-tray", yad: $yad, running: $running, cheatsheetVisible: $cheatsheet, autostart: $autostart}'
}

case "${1:-status}" in
    start) tray_start ;;
    stop) tray_stop ;;
    restart) tray_stop; tray_start ;;
    install) tray_autostart_install; tray_start ;;
    cheatsheet) cheatsheet_toggle ;;
    status) tray_status ;;
    dry-run) PZ_DRY_RUN=1 tray_start; PZ_DRY_RUN=1 tray_autostart_install ;;
    *) pz_error "usage: tray.sh (start|stop|restart|install|cheatsheet|status|dry-run)"; exit 1 ;;
esac
