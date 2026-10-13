#!/usr/bin/env bash
# input-actions.sh - SteamOS-like input/session actions for Linux desktops
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$DIR/common.sh"

steamdeck_has_graphical_session() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]
}

steamdeck_run_detached() {
    local label="$1"
    shift

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would start $label: $*"
        return 0
    fi

    nohup "$@" >/dev/null 2>&1 &
    local pid="$!"
    disown "$pid" 2>/dev/null || true
    pz_info "started $label (pid $pid)"
}

steamdeck_steam_running() {
    pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1
}

steamdeck_pid_is_kwin_managed() {
    # maliit-keyboard spawned by kwin_wayland is the KDE input method client;
    # killing it never shows a keyboard, KWin just respawns it.
    local pid="$1" ppid parent_comm
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] || return 1
    parent_comm="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ')"
    case "$parent_comm" in
        kwin_wayland*) return 0 ;;
    esac
    return 1
}

steamdeck_kde_virtual_keyboard_supported() {
    command -v qdbus6 >/dev/null 2>&1 || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard >/dev/null 2>&1 || return 1
}

# jq --argjson aborts on anything that is not valid JSON, so a probe that
# returns an empty string or a stray word takes the whole status command down
# with it. Every probed value passes through here before reaching jq.
steamdeck_bool() {
    case "${1:-}" in
        true|True|TRUE|1|yes) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

steamdeck_kde_virtual_keyboard_prop() {
    local prop="$1"
    steamdeck_kde_virtual_keyboard_supported || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Get \
        org.kde.kwin.VirtualKeyboard "$prop" 2>/dev/null | tail -1
}

steamdeck_maliit_desktop_file() {
    local desktop
    for desktop in \
        /usr/share/applications/com.github.maliit.keyboard.desktop \
        /usr/share/applications/org.maliit.keyboard.desktop; do
        if [ -f "$desktop" ]; then
            printf '%s\n' "$desktop"
            return 0
        fi
    done
    return 1
}

steamdeck_configure_virtual_keyboard() {
    local method current_enabled current_method kwinrc
    method="$(steamdeck_maliit_desktop_file || true)"

    if ! command -v kwriteconfig6 >/dev/null 2>&1; then
        pz_warn "kwriteconfig6 missing; KDE virtual keyboard config skipped"
        return 0
    fi

    kwinrc="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would enable KDE virtual keyboard in $kwinrc"
        [ -n "$method" ] && pz_info "dry-run: would set KDE input method to $method"
        steamdeck_ensure_terminal_keyboard
        return 0
    fi

    pz_backup_file "$kwinrc" user >/dev/null

    kwriteconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled true
    if [ -n "$method" ]; then
        # shellcheck disable=SC2016 # kwriteconfig6 key syntax is literal
        kwriteconfig6 --file kwinrc --group Wayland --key 'InputMethod[$e]' --delete >/dev/null 2>&1 || true
        # shellcheck disable=SC2016 # kwriteconfig6 key syntax is literal
        kwriteconfig6 --file kwinrc --group Wayland --key 'InputMethod\x5b$e\x5d' --delete >/dev/null 2>&1 || true
        kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "$method"
    else
        pz_warn "Maliit desktop file missing; install maliit-keyboard for KDE on-screen keyboard"
    fi

    if steamdeck_kde_virtual_keyboard_supported; then
        qdbus6 org.kde.KWin /VirtualKeyboard \
            org.freedesktop.DBus.Properties.Set \
            org.kde.kwin.VirtualKeyboard enabled true >/dev/null 2>&1 || true
        qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    fi

    current_enabled="$(kreadconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled 2>/dev/null || true)"
    current_method="$(kreadconfig6 --file kwinrc --group Wayland --key InputMethod 2>/dev/null || true)"
    pz_info "KDE virtual keyboard configured: enabled=${current_enabled:-unknown} inputMethod=${current_method:-unknown}"

    steamdeck_ensure_terminal_keyboard
}

steamdeck_kde_deactivate_virtual_keyboard() {
    steamdeck_kde_virtual_keyboard_supported || return 1
    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Set \
        org.kde.kwin.VirtualKeyboard active false >/dev/null 2>&1 || return 1
    pz_info "KDE virtual keyboard deactivated"
}

steamdeck_kde_open_virtual_keyboard() {
    local available visible active
    steamdeck_kde_virtual_keyboard_supported || return 1
    steamdeck_configure_virtual_keyboard

    available="$(steamdeck_kde_virtual_keyboard_prop available || echo false)"
    [ "$available" = "true" ] || return 1

    qdbus6 org.kde.KWin /VirtualKeyboard \
        org.kde.kwin.VirtualKeyboard.forceActivate >/dev/null 2>&1 || return 1

    sleep 0.2
    visible="$(steamdeck_kde_virtual_keyboard_prop visible || echo false)"
    active="$(steamdeck_kde_virtual_keyboard_prop active || echo false)"
    if [ "$visible" = "true" ]; then
        pz_info "virtual keyboard requested via KDE/KWin"
        return 0
    fi

    if [ "$active" = "true" ]; then
        # Maliit only surfaces for clients that request text-input; terminals
        # never do, so drop the half-active state before falling back.
        pz_warn "KDE virtual keyboard active but not visible; trying fallback"
        steamdeck_kde_deactivate_virtual_keyboard >/dev/null 2>&1 || true
    fi

    return 1
}

steamdeck_admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

steamdeck_install_wvkbd_aur() {
    local expected_pkgbuild="70d2d552cac5ce440e167753e93c16e7026878efb4532645187fa029a3d9f188"
    local stage pkgdir actual package package_name package_version
    command -v yay >/dev/null 2>&1 || return 1
    command -v makepkg >/dev/null 2>&1 || return 1
    stage="$(mktemp -d)"
    if ! (cd "$stage" && yay -G wvkbd >/dev/null); then
        rm -rf "$stage"
        pz_warn "could not acquire wvkbd PKGBUILD"
        return 1
    fi
    pkgdir="$stage/wvkbd"
    actual="$(sha256sum "$pkgdir/PKGBUILD" 2>/dev/null | awk '{print $1}')"
    if [ "$actual" != "$expected_pkgbuild" ]; then
        rm -rf "$stage"
        pz_warn "wvkbd PKGBUILD changed; refusing unreviewed AUR build"
        return 1
    fi
    steamdeck_admin_run pacman -S --needed --noconfirm scdoc >/dev/null || {
        rm -rf "$stage"
        return 1
    }
    if ! (cd "$pkgdir" && makepkg --cleanbuild --noconfirm >/dev/null); then
        rm -rf "$stage"
        pz_warn "wvkbd user build failed"
        return 1
    fi
    package="$(find "$pkgdir" -maxdepth 1 -type f -name 'wvkbd-*.pkg.tar*' ! -name '*.sig' -print -quit)"
    [ -n "$package" ] || { rm -rf "$stage"; pz_warn "wvkbd package artifact missing"; return 1; }
    package_name="$(pacman -Qp "$package" 2>/dev/null | awk '{print $1}')"
    package_version="$(pacman -Qp "$package" 2>/dev/null | awk '{print $2}')"
    if [ "$package_name" != "wvkbd" ] || [ "$package_version" != "0.20-1" ]; then
        rm -rf "$stage"
        pz_warn "wvkbd package identity mismatch"
        return 1
    fi
    if ! steamdeck_admin_run pacman -U --noconfirm "$package"; then
        rm -rf "$stage"
        return 1
    fi
    rm -rf "$stage"
    command -v wvkbd-mobintl >/dev/null 2>&1
}

steamdeck_ensure_terminal_keyboard() {
    # KWin/Maliit never shows for terminal apps (no text-input protocol), so a
    # standalone keyboard is required for typing into Konsole & co. KWin does
    # not expose wlroots' virtual_keyboard_manager to wvkbd; use Onboard there.
    local candidate
    if steamdeck_kde_virtual_keyboard_supported; then
        candidate=onboard
        command -v "$candidate" >/dev/null 2>&1 && return 0
    else
        for candidate in wvkbd-mobintl wvkbd onboard; do
            command -v "$candidate" >/dev/null 2>&1 && return 0
        done
    fi

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        if steamdeck_kde_virtual_keyboard_supported; then
            pz_info "dry-run: would install onboard (KDE terminal-capable virtual keyboard)"
        else
            pz_info "dry-run: would install wvkbd (terminal-capable virtual keyboard)"
        fi
        return 0
    fi

    if ! command -v pacman >/dev/null 2>&1; then
        pz_warn "no terminal-capable virtual keyboard found"
        return 0
    fi

    if steamdeck_kde_virtual_keyboard_supported; then
        pz_info "installing onboard (KDE terminal-capable virtual keyboard)"
        if steamdeck_admin_run pacman -S --needed --noconfirm onboard; then
            pz_info "onboard installed"
        else
            pz_warn "could not install onboard; virtual keyboard remains degraded"
        fi
        return 0
    fi

    for candidate in wvkbd-mobintl wvkbd onboard; do
        command -v "$candidate" >/dev/null 2>&1 && return 0
    done

    pz_info "installing wvkbd (terminal-capable virtual keyboard)"
    if pacman -Si wvkbd >/dev/null 2>&1 &&
        steamdeck_admin_run pacman -S --needed --noconfirm wvkbd; then
        pz_info "wvkbd installed"
    elif steamdeck_install_wvkbd_aur; then
        pz_info "wvkbd installed from reviewed AUR recipe"
    else
        pz_warn "could not install reviewed wvkbd package; virtual keyboard remains degraded"
    fi
}

steamdeck_stop_virtual_keyboard() {
    local stopped=0
    local name pid
    for name in wvkbd-mobintl wvkbd onboard; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            pkill -x "$name" >/dev/null 2>&1 || true
            pz_info "stopped virtual keyboard: $name"
            stopped=1
        fi
    done

    # only standalone maliit instances; the KWin-managed one must stay alive
    for pid in $(pgrep -x maliit-keyboard 2>/dev/null); do
        if ! steamdeck_pid_is_kwin_managed "$pid"; then
            kill "$pid" >/dev/null 2>&1 || true
            pz_info "stopped standalone maliit-keyboard (pid $pid)"
            stopped=1
        fi
    done

    [ "$stopped" -eq 1 ]
}

steamdeck_request_steam_keyboard() {
    command -v steam >/dev/null 2>&1 || return 1
    steamdeck_steam_running || return 1
    steam steam://open/keyboard >/dev/null 2>&1 && {
        pz_info "virtual keyboard requested via Steam"
        return 0
    }
    return 1
}

steamdeck_start_keyboard_binary() {
    local candidate pid
    local -a candidates=(wvkbd-mobintl wvkbd onboard maliit-keyboard)
    steamdeck_kde_virtual_keyboard_supported && candidates=(onboard)
    for candidate in "${candidates[@]}"; do
        command -v "$candidate" >/dev/null 2>&1 || continue

        # standalone maliit is pointless under KWin: the compositor already
        # manages its own instance via the input-method protocol
        if [ "$candidate" = "maliit-keyboard" ] && steamdeck_kde_virtual_keyboard_supported; then
            continue
        fi

        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would start virtual keyboard: $candidate"
            return 0
        fi

        nohup "$candidate" >/dev/null 2>&1 &
        pid="$!"
        disown "$pid" 2>/dev/null || true
        sleep 0.4
        if kill -0 "$pid" 2>/dev/null; then
            pz_info "started virtual keyboard: $candidate (pid $pid)"
            return 0
        fi
        pz_warn "$candidate exited immediately (compositor may not support it); trying next"
    done

    pz_error "no working virtual keyboard found. install wvkbd, onboard, or maliit-keyboard."
    return 1
}

steamdeck_open_virtual_keyboard() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for virtual keyboard"
        return 1
    }

    steamdeck_kde_open_virtual_keyboard && return 0
    steamdeck_request_steam_keyboard && return 0
    steamdeck_start_keyboard_binary
}

steamdeck_toggle_virtual_keyboard() {
    if steamdeck_kde_virtual_keyboard_supported &&
        [ "$(steamdeck_kde_virtual_keyboard_prop visible || echo false)" = "true" ]; then
        steamdeck_kde_deactivate_virtual_keyboard && return 0
    fi
    steamdeck_stop_virtual_keyboard && return 0
    steamdeck_open_virtual_keyboard
}

steamdeck_virtual_keyboard_status() {
    local provider="none" kde_supported=false kde_available=false kde_enabled=false kde_visible=false kde_active=false method=""
    local fallback="" fallback_running=false ready=false
    if steamdeck_kde_virtual_keyboard_supported; then
        provider="kde-kwin"
        kde_supported=true
        # `|| echo false` only covers a non-zero exit. The D-Bus query also
        # succeeds with empty output when no KDE session owns the property,
        # which fed an empty string to --argjson and aborted the whole status
        # command. Anything that is not a literal boolean becomes false.
        kde_available="$(steamdeck_bool "$(steamdeck_kde_virtual_keyboard_prop available || true)")"
        kde_enabled="$(steamdeck_bool "$(steamdeck_kde_virtual_keyboard_prop enabled || true)")"
        kde_visible="$(steamdeck_bool "$(steamdeck_kde_virtual_keyboard_prop visible || true)")"
        kde_active="$(steamdeck_bool "$(steamdeck_kde_virtual_keyboard_prop active || true)")"
        method="$(kreadconfig6 --file kwinrc --group Wayland --key InputMethod 2>/dev/null || true)"
    elif command -v wvkbd-mobintl >/dev/null 2>&1; then
        provider="wvkbd-mobintl"
    elif command -v wvkbd >/dev/null 2>&1; then
        provider="wvkbd"
    elif command -v onboard >/dev/null 2>&1; then
        provider="onboard"
    elif command -v maliit-keyboard >/dev/null 2>&1; then
        provider="maliit-keyboard"
    fi
    if steamdeck_kde_virtual_keyboard_supported && command -v onboard >/dev/null 2>&1; then
        fallback="onboard"
    elif ! steamdeck_kde_virtual_keyboard_supported; then
        for fallback in wvkbd-mobintl wvkbd onboard; do
            command -v "$fallback" >/dev/null 2>&1 && break
            fallback=""
        done
    fi
    [ -n "$fallback" ] && pgrep -x "$fallback" >/dev/null 2>&1 && fallback_running=true
    if [ "$kde_available" = true ] && [ -n "$fallback" ]; then
        ready=true
    elif [ "$kde_supported" = false ] && [ -n "$fallback" ]; then
        ready=true
    fi

    jq -n \
        --arg provider "$provider" \
        --arg fallback "$fallback" \
        --arg inputMethod "$method" \
        --argjson kdeSupported "$kde_supported" \
        --argjson kdeAvailable "$kde_available" \
        --argjson kdeEnabled "$kde_enabled" \
        --argjson kdeVisible "$kde_visible" \
        --argjson kdeActive "$kde_active" \
        --argjson maliit "$([ -n "$(steamdeck_maliit_desktop_file || true)" ] && echo true || echo false)" \
        --argjson fallbackRunning "$fallback_running" \
        --argjson ready "$ready" \
        '{
            provider: $provider,
            ready: $ready,
            kde: {
                supported: $kdeSupported,
                available: $kdeAvailable,
                enabled: $kdeEnabled,
                visible: $kdeVisible,
                active: $kdeActive,
                inputMethod: $inputMethod
            },
            fallback: {command:$fallback, running:$fallbackRunning},
            maliitDesktopFile: $maliit
        }'
}

steamdeck_launch_steam_gamepad_ui() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for Steam Gamepad UI"
        return 1
    }

    if ! command -v steam >/dev/null 2>&1; then
        pz_error "steam not installed"
        return 1
    fi

    bash "$DIR/plugins.sh" enable-cef-debug >/dev/null 2>&1 || true

    if steamdeck_steam_running; then
        steam steam://open/bigpicture >/dev/null 2>&1 && {
            pz_info "Steam Big Picture requested"
            return 0
        }
    fi

    steamdeck_run_detached "Steam Gamepad UI" steam -gamepadui
}

steamdeck_start_console_session() {
    local mode="${1:-auto}"
    if [ "$mode" = "auto" ]; then
        mode="$(steamdeck_detect_mode)"
    fi

    steamdeck_apply_mode "$mode"
    steamdeck_launch_steam_gamepad_ui
}

steamdeck_start_dev_session() {
    local mode="${1:-docked-monitor}"
    if [ "$mode" != "none" ]; then
        steamdeck_apply_mode "$mode"
    fi

    pz_info "desktop/dev session ready"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-keyboard}" in
        keyboard|virtual-keyboard|toggle|toggle-keyboard) steamdeck_toggle_virtual_keyboard ;;
        open|show|open-keyboard) steamdeck_open_virtual_keyboard ;;
        close|hide|close-keyboard)
            steamdeck_kde_deactivate_virtual_keyboard >/dev/null 2>&1 || true
            steamdeck_stop_virtual_keyboard || true
            ;;
        configure|install|repair|configure-keyboard|install-keyboard) steamdeck_configure_virtual_keyboard ;;
        status|status-keyboard) steamdeck_virtual_keyboard_status ;;
        console) steamdeck_start_console_session "${2:-auto}" ;;
        dev|desktop) steamdeck_start_dev_session "${2:-docked-monitor}" ;;
        *) pz_error "usage: input-actions.sh (keyboard|open|close|configure|status|console|dev)"; exit 1 ;;
    esac
fi
