#!/usr/bin/env bash
# install-mode-watcher.sh - install/manage dynamic Steam Deck mode watcher user service
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-install}"
DRY_RUN=0
[ "$ACTION" = "dry-run" ] && DRY_RUN=1

SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_NAME="phasezero-steamdeck-mode-watcher.service"
UNIT_PATH="$SYSTEMD_USER_DIR/$UNIT_NAME"
DROPIN_DIR="$SYSTEMD_USER_DIR/$UNIT_NAME.d"
PZ_BIN="$PZ_ROOT/linux/pz"

mode_watcher_unit() {
    cat <<EOF
[Unit]
Description=PhaseZero Steam Deck mode watcher
Documentation=https://github.com/Misael-art/phase-zero
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$PZ_BIN steamdeck watch
Environment=PZ_STEAMDECK_POLL_SECONDS=5
Environment=PZ_STEAMDECK_STABLE_SAMPLES=2
Environment=PZ_STEAMDECK_COOLDOWN_SECONDS=10
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
}

write_unit() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $UNIT_PATH"
        return 0
    fi

    install -d "$SYSTEMD_USER_DIR"
    pz_backup_file "$UNIT_PATH" user >/dev/null
    mode_watcher_unit > "$UNIT_PATH"
    systemctl --user daemon-reload
    pz_info "wrote $UNIT_PATH"
}

install_unit() {
    write_unit
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would leave $UNIT_NAME installed but not started"
        return 0
    fi
    pz_info "installed $UNIT_NAME (not started)"
}

enable_unit() {
    write_unit
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would enable and start $UNIT_NAME"
        return 0
    fi
    systemctl --user enable --now "$UNIT_NAME"
    pz_info "enabled and started $UNIT_NAME"
}

status_unit() {
    echo "unit: $UNIT_PATH"
    if [ -f "$UNIT_PATH" ]; then
        grep -E '^(ExecStart|Environment)=' "$UNIT_PATH" || true
    else
        echo "missing"
    fi
    if [ -d "$DROPIN_DIR" ]; then
        grep -hE '^(Environment)=' "$DROPIN_DIR"/*.conf 2>/dev/null || true
    fi
    systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true
    systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true
}

case "$ACTION" in
    install|dry-run) install_unit ;;
    enable) enable_unit ;;
    start) systemctl --user start "$UNIT_NAME" ;;
    stop) systemctl --user stop "$UNIT_NAME" ;;
    restart) systemctl --user restart "$UNIT_NAME" ;;
    status) status_unit ;;
    *) pz_error "usage: install-mode-watcher.sh (install|dry-run|enable|start|stop|restart|status)"; exit 1 ;;
esac
