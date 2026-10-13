#!/usr/bin/env bash
# install-hotkeys.sh - install SteamOS-like keyboard shortcuts on Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-install}"
DRY_RUN=0
[ "$ACTION" = "dry-run" ] && DRY_RUN=1

PZ_BIN="$PZ_ROOT/linux/pz"
HOTKEY_BIN="bash $PZ_ROOT/linux/steamdeck/hotkey-actions.sh"
SXHKD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sxhkd"
SWHKD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/swhkd"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
KGLOBALSHORTCUTSRC="${XDG_CONFIG_HOME:-$HOME/.config}/kglobalshortcutsrc"

write_managed_file() {
    local path="$1"
    local content="$2"
    local dir
    dir="$(dirname "$path")"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $path"
        return 0
    fi

    install -d "$dir"
    pz_backup_file "$path" user >/dev/null
    printf '%s\n' "$content" > "$path"
    pz_info "wrote $path"
}

sxhkd_config() {
    cat <<EOF
# PhaseZero Steam Deck Linux hotkeys
# Meta+Shift+Fn: Ctrl+Alt+Fn is VT switching on Wayland/xkb and plain
# Meta+Fn collides with KWin defaults.

super + shift + F1
    $HOTKEY_BIN handheld

super + shift + F2
    $HOTKEY_BIN docked-monitor

super + shift + F3
    $HOTKEY_BIN docked-tv

super + shift + F4
    $HOTKEY_BIN keyboard

super + shift + F5
    $HOTKEY_BIN console

super + shift + F6
    $HOTKEY_BIN dev

super + shift + F7
    $HOTKEY_BIN cheatsheet

super + shift + F8
    $HOTKEY_BIN voice

super + shift + F9
    $HOTKEY_BIN overview
EOF
}

swhkd_config() {
    cat <<EOF
# PhaseZero Steam Deck Linux hotkeys
# Wayland compositors may require compositor-native shortcut binding.

super + shift + f1
    $HOTKEY_BIN handheld

super + shift + f2
    $HOTKEY_BIN docked-monitor

super + shift + f3
    $HOTKEY_BIN docked-tv

super + shift + f4
    $HOTKEY_BIN keyboard

super + shift + f5
    $HOTKEY_BIN console

super + shift + f6
    $HOTKEY_BIN dev

super + shift + f7
    $HOTKEY_BIN cheatsheet

super + shift + f8
    $HOTKEY_BIN voice

super + shift + f9
    $HOTKEY_BIN overview
EOF
}

sxhkd_service() {
    cat <<EOF
[Unit]
Description=PhaseZero Steam Deck hotkeys
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/sxhkd -c %h/.config/sxhkd/sxhkdrc
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

desktop_entry() {
    local name="$1"
    local exec_line="$2"
    local comment="$3"
    local shortcut="${4:-}"
    local terminal="${5:-false}"
    cat <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$exec_line
Terminal=$terminal
Categories=Game;Utility;
${shortcut:+X-KDE-Shortcuts=$shortcut}
EOF
}

boot_reboot_exec() {
    if command -v pkexec >/dev/null 2>&1; then
        printf 'pkexec bash %s/linux/steamdeck/install-steamos-boot.sh next-reboot\n' "$PZ_ROOT"
    else
        printf '%s steamdeck boot next-reboot\n' "$PZ_BIN"
    fi
}

install_desktop_entries() {
    local boot_exec boot_terminal="false"
    boot_exec="$(boot_reboot_exec)"
    command -v pkexec >/dev/null 2>&1 || boot_terminal="true"

    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-handheld.desktop" \
        "$(desktop_entry "PhaseZero Handheld Mode" "$HOTKEY_BIN handheld" "Apply Steam Deck handheld mode" "Meta+Shift+F1")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-docked-monitor.desktop" \
        "$(desktop_entry "PhaseZero Docked Monitor Mode" "$HOTKEY_BIN docked-monitor" "Apply Steam Deck docked monitor mode" "Meta+Shift+F2")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-docked-tv.desktop" \
        "$(desktop_entry "PhaseZero Docked TV Mode" "$HOTKEY_BIN docked-tv" "Apply Steam Deck docked TV mode" "Meta+Shift+F3")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-virtual-keyboard.desktop" \
        "$(desktop_entry "PhaseZero Virtual Keyboard" "$HOTKEY_BIN keyboard" "Toggle virtual keyboard" "Meta+Shift+F4")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steam-gamepad-ui.desktop" \
        "$(desktop_entry "PhaseZero Steam Gamepad UI" "$HOTKEY_BIN console" "Launch Steam Gamepad UI" "Meta+Shift+F5")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-steamdeck-dev.desktop" \
        "$(desktop_entry "PhaseZero Desktop Dev Session" "$HOTKEY_BIN dev" "Apply desktop/dev Steam Deck session" "Meta+Shift+F6")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-shortcut-cheatsheet.desktop" \
        "$(desktop_entry "PhaseZero Shortcut Cheat Sheet" "$HOTKEY_BIN cheatsheet" "Toggle the shortcut overlay table" "Meta+Shift+F7")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-voice-typing.desktop" \
        "$(desktop_entry "PhaseZero Voice Typing" "$HOTKEY_BIN voice" "Speak-to-type into the focused window" "Meta+Shift+F8")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-activities-overview.desktop" \
        "$(desktop_entry "PhaseZero Activities Overview" "$HOTKEY_BIN overview" "Toggle the KWin activities overview" "Meta+Shift+F9")"
    write_managed_file "$APPLICATIONS_DIR/phasezero-reboot-steamos-plus.desktop" \
        "$(desktop_entry "PhaseZero Reboot to SteamOS Plus" "$boot_exec" "Set one-shot GRUB boot to SteamOS Plus and reboot" "" "$boot_terminal")"
}

install_sxhkd_service() {
    write_managed_file "$SYSTEMD_USER_DIR/phasezero-steamdeck-hotkeys.service" "$(sxhkd_service)"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would enable user service phasezero-steamdeck-hotkeys.service if sxhkd exists"
        return 0
    fi

    if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        # sxhkd is X11-only: on Wayland it never sees global key events, so an
        # "active" service would just mislead diagnostics. KDE-native
        # shortcuts are the authoritative path there.
        systemctl --user disable --now phasezero-steamdeck-hotkeys.service >/dev/null 2>&1 || true
        pz_info "Wayland session: sxhkd service skipped (KDE-native shortcuts are used)"
        return 0
    fi

    if command -v sxhkd >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now phasezero-steamdeck-hotkeys.service
        pz_info "enabled phasezero-steamdeck-hotkeys.service"
    else
        pz_warn "sxhkd not installed; configs written, service not enabled"
    fi
}

is_kde_session() {
    case "${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}:${KDE_SESSION_VERSION:-}" in
        *KDE*|*plasma*|*:*:6|*:*:5) return 0 ;;
        *) return 1 ;;
    esac
}

kde_write_shortcut() {
    local desktop_file="$1"
    local shortcut="$2"
    local name="$3"
    local keycode="$4"

    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would bind KDE shortcut $shortcut -> $desktop_file"
        return 0
    fi

    kwriteconfig6 --file kglobalshortcutsrc \
        --group services \
        --group "$desktop_file" \
        --key _launch \
        "$shortcut,none,$name"

    kwriteconfig6 --file kglobalshortcutsrc \
        --group services \
        --group "$desktop_file" \
        --key _k_friendly_name \
        "$name"

    # The rc file alone is not enough: KWin only grabs keys registered through
    # the live KGlobalAccel API (restarting kglobalacceld loses its in-memory
    # state and can wipe fresh rc entries, so never kquitapp it).
    command -v gdbus >/dev/null 2>&1 || {
        pz_warn "gdbus missing; $shortcut only active after re-login"
        return 0
    }
    gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.doRegister \
        "['$desktop_file','_launch','$name','$name']" >/dev/null 2>&1 || true
    if gdbus call --session --dest org.kde.kglobalaccel --object-path /kglobalaccel \
        --method org.kde.KGlobalAccel.setShortcut \
        "['$desktop_file','_launch','$name','$name']" "[$keycode]" 4 2>/dev/null |
        grep -q "$keycode"; then
        pz_info "KDE shortcut active: $shortcut -> $desktop_file"
    else
        pz_warn "KDE shortcut $shortcut rejected (conflict?) for $desktop_file"
    fi
}

kde_session_usable() {
    command -v kwriteconfig6 >/dev/null 2>&1 || return 1
    is_kde_session && return 0
    # env sniffing fails under SSH/cron; the running daemon is the real signal
    command -v qdbus6 >/dev/null 2>&1 &&
        qdbus6 org.kde.kglobalaccel /kglobalaccel org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1
}

# Shortcut scheme: Meta+Shift+F1..F9.
# Ctrl+Alt+Fn is unusable on Wayland (xkb turns it into XF86Switch_VT_n) and
# plain Meta+Fn collides with KWin defaults (Overview, ExposeClass, ...).
# Verified free on Plasma 6.6. Qt keycodes: Meta|Shift|Fn = 318767152 + n - 1.
kde_write_all_shortcuts() {
    kde_write_shortcut "phasezero-steamdeck-handheld.desktop" "Meta+Shift+F1" "PhaseZero Handheld Mode" 318767152
    kde_write_shortcut "phasezero-steamdeck-docked-monitor.desktop" "Meta+Shift+F2" "PhaseZero Docked Monitor Mode" 318767153
    kde_write_shortcut "phasezero-steamdeck-docked-tv.desktop" "Meta+Shift+F3" "PhaseZero Docked TV Mode" 318767154
    kde_write_shortcut "phasezero-virtual-keyboard.desktop" "Meta+Shift+F4" "PhaseZero Virtual Keyboard" 318767155
    kde_write_shortcut "phasezero-steam-gamepad-ui.desktop" "Meta+Shift+F5" "PhaseZero Steam Gamepad UI" 318767156
    kde_write_shortcut "phasezero-steamdeck-dev.desktop" "Meta+Shift+F6" "PhaseZero Desktop Dev Session" 318767157
    kde_write_shortcut "phasezero-shortcut-cheatsheet.desktop" "Meta+Shift+F7" "PhaseZero Shortcut Cheat Sheet" 318767158
    kde_write_shortcut "phasezero-voice-typing.desktop" "Meta+Shift+F8" "PhaseZero Voice Typing" 318767159
    kde_write_shortcut "phasezero-activities-overview.desktop" "Meta+Shift+F9" "PhaseZero Activities Overview" 318767160
}

verify_kde_shortcuts() {
    local registered entry missing_count=0
    command -v qdbus6 >/dev/null 2>&1 || {
        pz_warn "qdbus6 missing; cannot verify kglobalaccel registration"
        return 0
    }
    registered="$(qdbus6 --literal org.kde.kglobalaccel /kglobalaccel \
        org.kde.KGlobalAccel.allMainComponents 2>/dev/null |
        grep -o 'phasezero[a-z-]*\.desktop' | sort -u)"

    for entry in \
        phasezero-steamdeck-handheld.desktop \
        phasezero-steamdeck-docked-monitor.desktop \
        phasezero-steamdeck-docked-tv.desktop \
        phasezero-virtual-keyboard.desktop \
        phasezero-steam-gamepad-ui.desktop \
        phasezero-steamdeck-dev.desktop \
        phasezero-shortcut-cheatsheet.desktop \
        phasezero-voice-typing.desktop \
        phasezero-activities-overview.desktop; do
        if printf '%s\n' "$registered" | grep -qx "$entry"; then
            pz_info "kglobalaccel OK: $entry"
        else
            pz_warn "kglobalaccel MISSING: $entry"
            missing_count=1
        fi
    done
    return "$missing_count"
}

install_kde_shortcuts() {
    if ! kde_session_usable; then
        pz_info "KDE native shortcuts skipped"
        return 0
    fi

    if [ "$DRY_RUN" = "1" ]; then
        kde_write_all_shortcuts
        pz_info "dry-run: would restart kglobalaccel and verify registration"
        return 0
    fi

    pz_backup_file "$KGLOBALSHORTCUTSRC" user >/dev/null

    # sycoca must know the fresh desktop entries before the service component
    # can resolve their Exec lines
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 >/dev/null 2>&1
    fi

    kde_write_all_shortcuts

    if verify_kde_shortcuts; then
        pz_info "KDE native shortcuts installed and registered"
    else
        pz_warn "KDE native shortcuts written but not all registered; re-run 'hotkeys verify' after re-login"
    fi
}

print_status() {
    echo "PhaseZero SteamOS UX status"
    echo "pz: $PZ_BIN"
    echo "sxhkd config: $SXHKD_DIR/sxhkdrc"
    echo "swhkd config: $SWHKD_DIR/swhkdrc"
    echo "desktop entries: $APPLICATIONS_DIR/phasezero-*.desktop"
    echo "KDE shortcuts: $KGLOBALSHORTCUTSRC"
    if command -v sxhkd >/dev/null 2>&1; then
        systemctl --user is-active phasezero-steamdeck-hotkeys.service 2>/dev/null || true
    else
        echo "sxhkd missing"
    fi
    if is_kde_session && [ -f "$KGLOBALSHORTCUTSRC" ]; then
        grep -A2 -E '^\[services\]\[phasezero-' "$KGLOBALSHORTCUTSRC" 2>/dev/null || true
    fi
    verify_kde_shortcuts || true
    bash "$PZ_ROOT/linux/steamdeck/tray.sh" status 2>/dev/null || true
    bash "$PZ_ROOT/linux/steamdeck/voice-typing.sh" status 2>/dev/null || true
}

install_hotkeys() {
    write_managed_file "$SXHKD_DIR/sxhkdrc" "$(sxhkd_config)"
    write_managed_file "$SWHKD_DIR/swhkdrc" "$(swhkd_config)"
    install_desktop_entries
    PZ_DRY_RUN="$DRY_RUN" bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" configure || pz_warn "virtual keyboard configuration failed"
    install_sxhkd_service
    install_kde_shortcuts
    PZ_DRY_RUN="$DRY_RUN" bash "$PZ_ROOT/linux/steamdeck/tray.sh" install || pz_warn "tray install failed"
    if [ "${PZ_SKIP_VOICE:-0}" != "1" ]; then
        PZ_DRY_RUN="$DRY_RUN" bash "$PZ_ROOT/linux/steamdeck/voice-typing.sh" setup || pz_warn "voice typing setup incomplete"
    fi
    pz_info "SteamOS-like hotkeys installed"
}

case "$ACTION" in
    install|dry-run) install_hotkeys ;;
    status) print_status ;;
    verify) verify_kde_shortcuts ;;
    *) pz_error "usage: install-hotkeys.sh (install|dry-run|status|verify)"; exit 1 ;;
esac
