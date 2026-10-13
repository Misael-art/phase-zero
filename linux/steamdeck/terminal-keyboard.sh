#!/usr/bin/env bash
# terminal-keyboard.sh - show the KWin touch keyboard when a finger lands
# on a terminal. VTE does not request the input panel, so a touch in
# Ashyterm never reaches forceActivate. This watcher only reads the
# touchscreen. It does not grab the device and it never closes the panel.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_NAME="phasezero-terminal-keyboard.service"

terminal_keyboard_is_terminal() {
    local class
    class="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    case "$class" in
        *ashyterm*|org.kde.konsole|konsole|kitty|yakuake) return 0 ;;
        *) return 1 ;;
    esac
}

# PROP=2 is INPUT_PROP_DIRECT, the touchscreen. The UNKNOWN sibling and the
# SCController nodes stay out. PZ_INPUT_DEVICES_FILE replaces /proc for tests.
terminal_keyboard_pick_device() {
    local file="${PZ_INPUT_DEVICES_FILE:-/proc/bus/input/devices}"
    [ -r "$file" ] || return 1
    awk '
        function flush() {
            if (name ~ /^SCController/) { reset(); return }
            if (event == "" || prop != 2) { reset(); return }
            score = 100
            if (name ~ /UNKNOWN/) score -= 40
            if (phys ~ /^i2c-/) score += 10
            if (score > best) { best = score; winner = event }
            reset()
        }
        function reset() { name = ""; phys = ""; event = ""; prop = -1 }
        BEGIN { best = -1; reset() }
        NF == 0 { flush(); next }
        /^N: Name=/ {
            name = $0
            sub(/^N: Name="/, "", name)
            sub(/"$/, "", name)
        }
        /^P: Phys=/ { phys = $0; sub(/^P: Phys=/, "", phys) }
        /^H: Handlers=/ {
            if (match($0, /event[0-9]+/)) event = substr($0, RSTART, RLENGTH)
        }
        /^B: PROP=/ {
            prop = $2
            sub(/^PROP=/, "", prop)
            prop += 0
        }
        END { flush(); if (winner != "") printf "/dev/input/%s\n", winner }
    ' "$file"
}

terminal_keyboard_focused_class() {
    if [ -n "${PZ_TERMINAL_KEYBOARD_CLASS+x}" ]; then
        printf '%s\n' "$PZ_TERMINAL_KEYBOARD_CLASS"
        return 0
    fi
    command -v kdotool >/dev/null 2>&1 || return 1
    kdotool getactivewindow getwindowclassname 2>/dev/null | tail -n 1
}

terminal_keyboard_panel_visible() {
    if [ -n "${PZ_TERMINAL_KEYBOARD_VISIBLE+x}" ]; then
        [ "$PZ_TERMINAL_KEYBOARD_VISIBLE" = true ]
        return
    fi
    local qdbus="${PZ_QDBUS6:-qdbus6}"
    local visible
    visible="$("$qdbus" org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Get \
        org.kde.kwin.VirtualKeyboard visible 2>/dev/null | tail -n 1 || true)"
    [ "$visible" = true ]
}

terminal_keyboard_request_open() {
    if [ -n "${PZ_TERMINAL_KEYBOARD_OPEN_CMD:-}" ]; then
        "$PZ_TERMINAL_KEYBOARD_OPEN_CMD"
        return
    fi
    bash "$DIR/input-actions.sh" open
}

terminal_keyboard_on_down() {
    local now class stamp_file last
    now="$(date +%s%3N 2>/dev/null || date +%s)"
    stamp_file="${PZ_TERMINAL_KEYBOARD_STAMP:-${XDG_RUNTIME_DIR:-/tmp}/phasezero-terminal-keyboard.stamp}"
    if [ -f "$stamp_file" ]; then
        last="$(cat "$stamp_file" 2>/dev/null || echo 0)"
        if [ "$((now - last))" -lt "${PZ_TERMINAL_KEYBOARD_DEBOUNCE_MS:-800}" ]; then
            return 0
        fi
    fi
    class="$(terminal_keyboard_focused_class || true)"
    terminal_keyboard_is_terminal "$class" || return 0
    if terminal_keyboard_panel_visible; then
        return 0
    fi
    printf '%s\n' "$now" >"$stamp_file"
    terminal_keyboard_request_open || true
}

# Prints one "down" line per finger press. The node stays shared:
# open is O_RDONLY and this process never claims the device.
terminal_keyboard_read_downs() {
    local device="$1"
    python3 - "$device" <<'PY'
import os
import struct
import sys

path = sys.argv[1]
# 64-bit input_event on this kernel: two 8-byte time fields, then HHi.
fmt = "16xHHi"
size = struct.calcsize(fmt)
BTN_TOUCH = 330
EV_KEY = 1
fd = os.open(path, os.O_RDONLY)
try:
    while True:
        data = os.read(fd, size)
        if not data:
            break
        if len(data) < size:
            break
        typ, code, value = struct.unpack(fmt, data[:size])
        if typ == EV_KEY and code == BTN_TOUCH and value == 1:
            print("down", flush=True)
finally:
    os.close(fd)
PY
}

terminal_keyboard_loop() {
    local device="$1" line
    # pipefail makes a dead reader fail the service so systemd restarts it.
    # A normal end-of-file (the hermetic fixture) still exits 0.
    terminal_keyboard_read_downs "$device" | while IFS= read -r line; do
        [ "$line" = down ] || continue
        terminal_keyboard_on_down
    done
}

terminal_keyboard_unit() {
    cat <<EOF
[Unit]
Description=PhaseZero touch keyboard for terminals
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/bin/bash $DIR/terminal-keyboard.sh watch
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF
}

terminal_keyboard_unit_dir() {
    printf '%s\n' "${PZ_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
}

systemd_user_ready() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user show --property=Version >/dev/null 2>&1
}

cmd_persist_status() {
    local enabled active unit
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\n'
        return 0
    fi
    unit="$(terminal_keyboard_unit_dir)/$UNIT_NAME"
    if [ ! -f "$unit" ]; then
        printf 'state=desligado\nreason=padrão do Deck é ligado; ainda não está nesta sessão\n'
        return 0
    fi
    enabled="$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)"
    active="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
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
    local dir unit
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\nmutated=0\n'
        return 1
    fi
    if systemctl --user is-enabled --quiet "$UNIT_NAME" \
        && systemctl --user is-active --quiet "$UNIT_NAME"; then
        printf 'state=ligado\nmutated=0\n'
        return 0
    fi
    dir="$(terminal_keyboard_unit_dir)"
    unit="$dir/$UNIT_NAME"
    mkdir -p "$dir"
    terminal_keyboard_unit >"$unit"
    systemctl --user daemon-reload
    if ! systemctl --user enable --now "$UNIT_NAME"; then
        if systemctl --user is-enabled --quiet "$UNIT_NAME"; then
            printf 'state=degradado\nreason=habilitado no login, mas parado agora\nmutated=0\n'
            return 1
        fi
        printf 'state=indisponivel\nreason=não consegui ligar o teclado no terminal\nmutated=0\n'
        return 1
    fi
    printf 'state=ligado\nmutated=1\n'
}

cmd_persist_off() {
    if ! systemd_user_ready; then
        printf 'state=indisponivel\nreason=systemd do usuário ausente\nmutated=0\n'
        return 1
    fi
    if ! systemctl --user disable --now "$UNIT_NAME"; then
        printf 'state=indisponivel\nreason=não consegui desligar o teclado no terminal\nmutated=0\n'
        return 1
    fi
    printf 'state=desligado\nmutated=1\n'
}

cmd_install() {
    local dir unit
    dir="$(terminal_keyboard_unit_dir)"
    unit="$dir/$UNIT_NAME"
    if [ "${PZ_DRY_RUN:-0}" = 1 ]; then
        printf 'dry-run: would write %s\n' "$unit"
        return 0
    fi
    mkdir -p "$dir"
    terminal_keyboard_unit >"$unit"
    if [ "${PZ_TERMINAL_KEYBOARD_APPLY_SYSTEMD:-0}" != 1 ]; then
        printf 'wrote %s\n' "$unit"
        return 0
    fi
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT_NAME"
}

cmd="${1:-watch}"
case "$cmd" in
    is-terminal)
        terminal_keyboard_is_terminal "${2:-}"
        ;;
    pick-device)
        terminal_keyboard_pick_device
        ;;
    drain|watch)
        device="${2:-${PZ_TOUCH_DEVICE:-}}"
        if [ -z "$device" ]; then
            device="$(terminal_keyboard_pick_device)" || {
                printf 'no touchscreen\n' >&2
                exit 1
            }
        fi
        [ -n "$device" ] || { printf 'no touchscreen\n' >&2; exit 1; }
        terminal_keyboard_loop "$device"
        ;;
    install|dry-run)
        [ "$cmd" = dry-run ] && PZ_DRY_RUN=1
        cmd_install
        ;;
    persist-on) cmd_persist_on ;;
    persist-off) cmd_persist_off ;;
    persist-status) cmd_persist_status ;;
    *)
        printf 'usage: terminal-keyboard.sh (watch|drain|pick-device|is-terminal|install|dry-run|persist-on|persist-off|persist-status)\n' >&2
        exit 1
        ;;
esac
