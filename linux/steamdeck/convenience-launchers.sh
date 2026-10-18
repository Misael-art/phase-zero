#!/usr/bin/env bash
# Install SteamOS-style Return, Windows VM and Waydroid convenience launchers.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
BIN_DIR="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

write_launchers() {
    python3 "$PZ_ROOT/linux/repairs/manager.py" install
    local old_selector
    install -d "$BIN_DIR" "$APP_DIR"
    pz_write_managed_file "$BIN_DIR/phasezero-return" user <<EOF
#!/usr/bin/env bash
exec "$PZ_ROOT/linux/steamdeck/os-session-select.sh" desktop
EOF
    chmod +x "$BIN_DIR/phasezero-return"
    pz_write_managed_file "$BIN_DIR/phasezero-boot-selector" user <<EOF
#!/usr/bin/env bash
exec "$PZ_ROOT/linux/pz" boot selector "\$@"
EOF
    chmod +x "$BIN_DIR/phasezero-boot-selector"
    pz_write_managed_file "$BIN_DIR/phasezero-windows-vm" user <<EOF
#!/usr/bin/env bash
exec "$PZ_ROOT/linux/pz" windows-vm launch --fullscreen "\$@"
EOF
    chmod +x "$BIN_DIR/phasezero-windows-vm"
    pz_write_managed_file "$BIN_DIR/phasezero-waydroid" user <<EOF
#!/usr/bin/env bash
exec "$PZ_ROOT/linux/pz" waydroid launch "\$@"
EOF
    chmod +x "$BIN_DIR/phasezero-waydroid"

    for row in \
        "Return to Gaming Mode|Return to SteamOS/Gamepad UI|phasezero-return|steamdeck-gaming-return|Game;" \
        "Boot Selector|Choose next PhaseZero boot before reboot|phasezero-boot-selector|system-reboot|Game;System;" \
        "Windows VM|Launch Windows VM in fullscreen|phasezero-windows-vm|computer|Game;System;" \
        "Waydroid|Launch Android session|phasezero-waydroid|phone|Game;System;"; do
        IFS='|' read -r name comment command icon categories <<< "$row"
        file="$(tr '[:upper:] ' '[:lower:]-' <<< "$name")"
        pz_write_managed_file "$APP_DIR/phasezero-$file.desktop" user <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$BIN_DIR/$command
Icon=$icon
Terminal=false
Categories=$categories
StartupNotify=false
X-PhaseZero-Managed=true
EOF
    done
    old_selector="$APP_DIR/phasezero-phasezero-boot-selector.desktop"
    if [ -f "$old_selector" ] && grep -Fq 'X-PhaseZero-Managed=true' "$old_selector"; then
        rm -f "$old_selector"
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
    pz_info "SteamOS convenience launchers installed"
}

status() {
    jq -n \
        --arg return "$BIN_DIR/phasezero-return" \
        --arg selector "$BIN_DIR/phasezero-boot-selector" \
        --arg windows "$BIN_DIR/phasezero-windows-vm" \
        --arg waydroid "$BIN_DIR/phasezero-waydroid" \
        --argjson ready "$([ -x "$BIN_DIR/phasezero-return" ] && [ -x "$BIN_DIR/phasezero-boot-selector" ] && [ -x "$BIN_DIR/phasezero-windows-vm" ] && [ -x "$BIN_DIR/phasezero-waydroid" ] && echo true || echo false)" \
        '{ready:$ready,return:$return,bootSelector:$selector,windowsVm:$windows,waydroid:$waydroid}'
}

case "$ACTION" in
    install|repair|apply) write_launchers ;;
    status) status ;;
    plan|dry-run) echo "write Return, Boot Selector, Windows VM and Waydroid wrappers/desktops under $HOME" ;;
    *) pz_error "usage: convenience-launchers.sh (status|plan|install)"; exit 2 ;;
esac
