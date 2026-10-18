#!/usr/bin/env bash
# On-demand Steam Deck input recovery. No session exit or reboot.
set -euo pipefail
I2CBUS=/sys/devices/platform/AMDI0010:01
if [ "${1:-}" = "--root" ]; then
    [ "$EUID" = 0 ] || exit 77
    [ -d "$I2CBUS" ] || exit 69
    printf on > "$I2CBUS/power/control"
    for path in /sys/bus/hid/devices/0018:2808:* /sys/bus/hid/devices/0003:28DE:1205.*; do
        [ -e "$path" ] || continue
        dev="${path##*/}"
        if [ -e "$path/driver/unbind" ]; then
            printf '%s' "$dev" > "$path/driver/unbind"
            sleep 1
            printf '%s' "$dev" > /sys/bus/hid/drivers_probe
        fi
    done
    udevadm settle --timeout=10
    exit 0
fi
[ -d "$I2CBUS" ] || { echo "Hardware Steam Deck ausente" >&2; exit 69; }
command -v phasezero-admin >/dev/null || { echo "Ponte admin ausente: execute linux/pz ai setup admin" >&2; exit 69; }
phasezero-admin bash "$(readlink -f "${BASH_SOURCE[0]}")" --root
status=$(cat "$I2CBUS/power/runtime_status")
nodes=$(grep -cE 'FTS3528|Steam Deck' /proc/bus/input/devices || true)
[ "$status" = active ] && [ "$nodes" -ge 2 ] || { echo "Reparo não confirmado; consulte diagnóstico de entrada" >&2; exit 1; }
echo "Barramento ativo e nós presentes; teste toque e controles para confirmar resposta."
if command -v kdialog >/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    kdialog --passivepopup "Drivers de entrada reassociados. Teste toque e trackpads." 8
fi
