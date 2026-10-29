#!/usr/bin/env bash
# Recover only the Deck touchscreen. Never reset USB or Valve HID ownership.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
I2CBUS=/sys/devices/platform/AMDI0010:01
TOUCH=/sys/bus/i2c/devices/i2c-FTS3528:00
case "${1:-}" in
    --help|-h) echo 'usage: reparo-entrada.sh [--status|--persist] (admin only for repair)'; exit 0 ;;
    ''|--status|--persist|--root) ;;
    *) echo 'Argumento desconhecido; use --help.' >&2; exit 2 ;;
esac
if [ "${1:-}" = --status ]; then
    printf 'bus=%s\n' "$(cat "$I2CBUS/power/runtime_status" 2>/dev/null || echo missing)"
    if [ -L "$TOUCH/driver" ]; then echo driver=bound; else echo driver=missing; fi
    if grep -q 'FTS3528' /proc/bus/input/devices; then echo node=present; else echo node=missing; fi
    exit 0
fi
if [ "${1:-}" = "--root" ]; then
    [ "$EUID" = 0 ] || exit 77
    case "${2:-}" in ''|--persist) ;; *) exit 2 ;; esac
    [ "$(cat /sys/devices/virtual/dmi/id/product_name)" = Jupiter ] || exit 69
    [ -d "$I2CBUS" ] && [ -e "$TOUCH" ] || exit 69
    printf on > "$I2CBUS/power/control"
    # Boot timeout can leave the I2C device without a HID child. Retry exactly
    # that device; no bus unbind, USB reset or controller firmware transition.
    if [ ! -L "$TOUCH/driver" ]; then
        printf '%s' i2c-FTS3528:00 > /sys/bus/i2c/drivers_probe
    fi
    udevadm settle --timeout=10
    grep -q 'FTS3528' /proc/bus/input/devices || { echo 'Touchscreen ainda ausente; diagnóstico de hardware pendente.' >&2; exit 1; }
    if [ "${2:-}" = --persist ]; then
        for pair in '80-phasezero-touchscreen.rules:/etc/udev/rules.d/80-phasezero-touchscreen.rules' \
                    'phasezero-touchscreen-recovery.service:/etc/systemd/system/phasezero-touchscreen-recovery.service'; do
            source_name="${pair%%:*}"
            target="${pair#*:}"
            if [ -L "$target" ] || { [ -f "$target" ] && ! grep -q X-PhaseZero-Managed "$target"; }; then
                echo "Arquivo pessoal/symlink preservado: $target" >&2
                exit 1
            fi
            if [ -f "$target" ] && ! cmp -s "$DIR/$source_name" "$target"; then
                # shellcheck source=../lib/common.sh
                source "$DIR/../lib/common.sh"
                pz_backup_file "$target" root >/dev/null
            fi
            install -m 644 "$DIR/$source_name" "$target"
        done
        udevadm control --reload-rules
        systemctl daemon-reload
        systemctl enable phasezero-touchscreen-recovery.service
    fi
    echo 'Touchscreen detectado; teste toque físico para confirmar.'
    exit 0
fi
[ -d "$I2CBUS" ] || { echo "Hardware Steam Deck ausente" >&2; exit 69; }
if command -v phasezero-admin >/dev/null; then
    bridge=phasezero-admin
elif command -v bigsudo >/dev/null; then
    bridge=bigsudo
else
    echo 'Ponte admin ausente: execute linux/pz ai setup admin' >&2
    exit 69
fi
exec "$bridge" bash "$DIR/reparo-entrada.sh" --root "${1:-}"
