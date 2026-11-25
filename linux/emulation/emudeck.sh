#!/usr/bin/env bash
# emudeck.sh - install/manage EmuDeck AppImage launcher
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
EMUDECK_APP="$PZ_APPLICATIONS_DIR/EmuDeck.AppImage"
EMUDECK_PHASEZERO_DESKTOP="$PZ_DESKTOP_DIR/phasezero-emudeck.desktop"
EMUDECK_WRAPPER="$PZ_LOCAL_BIN/phasezero-emudeck"

resolve_emudeck_url() {
    pz_emulation_release_appimage_url "$PZ_EMUDECK_RELEASE_API"
}

emudeck_desktop_dir() {
    local dir=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    if [ -z "$dir" ] || [ "$dir" = "$HOME" ]; then
        if [ -d "$HOME/Área de trabalho" ]; then
            dir="$HOME/Área de trabalho"
        elif [ -d "$HOME/Área de Trabalho" ]; then
            dir="$HOME/Área de Trabalho"
        else
            dir="$HOME/Desktop"
        fi
    fi
    printf '%s\n' "$dir"
}

emudeck_steamdeck_desktop_target() {
    if [ -n "${PZ_EMUDECK_DESKTOP_PATH:-}" ]; then
        printf '%s\n' "$PZ_EMUDECK_DESKTOP_PATH"
    else
        printf '%s/EmuDeck.desktop\n' "$(emudeck_desktop_dir)"
    fi
}

emudeck_steamdeck_desktop_candidates() {
    {
        [ -n "${PZ_EMUDECK_DESKTOP_PATH:-}" ] && printf '%s\n' "$PZ_EMUDECK_DESKTOP_PATH"
        printf '%s\n' "$(emudeck_steamdeck_desktop_target)"
        printf '%s\n' "$HOME/Desktop/EmuDeck.desktop"
        printf '%s\n' "$HOME/Área de trabalho/EmuDeck.desktop"
        printf '%s\n' "$HOME/Área de Trabalho/EmuDeck.desktop"
        printf '%s\n' "$HOME/Downloads/EmuDeck.desktop"
    } | awk 'NF && !seen[$0]++'
}

emudeck_desktop_valid() {
    local desktop="$1"
    [ -f "$desktop" ] || return 1
    grep -Eq '^[[:space:]]*\[Desktop Entry\]' "$desktop" || return 1
    grep -Eq '^[[:space:]]*Exec=' "$desktop" || return 1
    grep -Eiq 'EmuDeck|emudeck|dragoonDorise/EmuDeck|EmuDeck\.AppImage|install\.sh' "$desktop" || return 1
}

emudeck_resolve_steamdeck_desktop() {
    local candidate
    while IFS= read -r candidate; do
        [ -z "$candidate" ] && continue
        if emudeck_desktop_valid "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(emudeck_steamdeck_desktop_candidates)
    return 1
}

normalize_steamdeck_desktop() {
    local desktop="$1" tmp
    [ -f "$desktop" ] || return 0
    if ! grep -Eq '^[[:space:]]+(\[Desktop Entry\]|[A-Za-z0-9_.-]+(\[[^]]+\])?=)' "$desktop"; then
        return 0
    fi
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    tmp="$(pz_tempfile)"
    sed -E \
        -e 's/^[[:space:]]+(\[Desktop Entry\])/\1/' \
        -e 's/^[[:space:]]+([A-Za-z0-9_.-]+(\[[^]]+\])?=)/\1/' \
        "$desktop" > "$tmp"
    if ! emudeck_desktop_valid "$tmp"; then
        rm -f "$tmp"
        pz_warn "EmuDeck.desktop normalization skipped; validation failed: $desktop"
        return 0
    fi
    pz_backup_file "$desktop" user >/dev/null
    install -m 0755 "$tmp" "$desktop"
    rm -f "$tmp"
    pz_info "normalized Steam Deck EmuDeck.desktop: $desktop"
}

install_steamdeck_desktop() {
    local target tmp source=""
    if source="$(emudeck_resolve_steamdeck_desktop 2>/dev/null)"; then
        normalize_steamdeck_desktop "$source"
        pz_info "Steam Deck EmuDeck.desktop already present: $source"
        printf '%s\n' "$source"
        return 0
    fi

    target="$(emudeck_steamdeck_desktop_target)"
    install -d "$(dirname "$target")"
    tmp="${target}.tmp.$$"
    rm -f "$tmp"
    pz_info "downloading official Steam Deck EmuDeck.desktop"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$PZ_EMUDECK_STEAMDECK_DESKTOP_URL"
    if ! emudeck_desktop_valid "$tmp"; then
        rm -f "$tmp"
        pz_error "downloaded EmuDeck.desktop failed validation: $PZ_EMUDECK_STEAMDECK_DESKTOP_URL"
        return 1
    fi
    pz_backup_file "$target" user >/dev/null
    install -m 0755 "$tmp" "$target"
    rm -f "$tmp"
    normalize_steamdeck_desktop "$target"
    pz_info "installed Steam Deck EmuDeck.desktop: $target"
    printf '%s\n' "$target"
}

write_appimage_wrapper() {
    pz_emulation_write_file "$EMUDECK_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$EMUDECK_APP" "\$@"
EOF
}

write_steamdeck_wrapper() {
    local desktop="$1"
    pz_emulation_write_file "$EMUDECK_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
desktop="$desktop"
[ -f "\$desktop" ] || { echo "EmuDeck.desktop missing: \$desktop" >&2; exit 1; }
if command -v kioclient6 >/dev/null 2>&1; then
    exec kioclient6 exec "\$desktop"
fi
if command -v kioclient5 >/dev/null 2>&1; then
    exec kioclient5 exec "\$desktop"
fi
if command -v kioclient >/dev/null 2>&1; then
    exec kioclient exec "\$desktop"
fi
if command -v gio >/dev/null 2>&1; then
    exec gio launch "\$desktop" "\$@"
fi
exec xdg-open "\$desktop"
EOF
}

write_phasezero_desktop() {
    local comment="$1"
    pz_emulation_write_file "$EMUDECK_PHASEZERO_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=EmuDeck (PhaseZero)
Comment=$comment
Exec=$EMUDECK_WRAPPER
Terminal=false
Icon=$PZ_EMULATION_ROOT/media/icons/phasezero/emulator.svg
Categories=Game;Emulator;
StartupNotify=false
X-PhaseZero-Managed=true
EOF
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1
    fi
}

install_emudeck_appimage() {
    if pz_emulation_foreign_install EmuDeck "$PZ_EMULATION_STATE/emudeck.json" \
        --appimage 'EmuDeck*.AppImage' --desktop-exec EmuDeck.AppImage; then
        return 0
    fi
    local url
    pz_emulation_ensure_layout
    url="$(resolve_emudeck_url)"
    [ -n "$url" ] || { pz_error "could not resolve EmuDeck AppImage URL from $PZ_EMUDECK_RELEASE_API"; return 1; }

    pz_info "downloading EmuDeck AppImage"
    pz_emulation_download "$url" "$EMUDECK_APP"
    write_appimage_wrapper
    write_phasezero_desktop "Configure EmuDeck through PhaseZero AppImage launcher"
    jq -n --arg url "$url" --arg app "$EMUDECK_APP" --arg installedAt "$(date -Iseconds)" \
        '{hostClass: "linux-pc", launcherKind: "appimage", source: $url, appImage: $app, installedAt: $installedAt}' > "$PZ_EMULATION_STATE/emudeck.json"
    pz_info "EmuDeck installed: $EMUDECK_APP"
}

install_emudeck_steamdeck() {
    local desktop
    pz_emulation_ensure_layout
    desktop="$(install_steamdeck_desktop | awk 'NF { line = $0 } END { print line }')"
    [ -n "$desktop" ] || { pz_error "could not resolve Steam Deck EmuDeck.desktop"; return 1; }
    write_steamdeck_wrapper "$desktop"
    write_phasezero_desktop "Open the Steam Deck EmuDeck desktop launcher through PhaseZero"
    jq -n \
        --arg desktop "$desktop" \
        --arg app "$EMUDECK_APP" \
        --arg url "$PZ_EMUDECK_STEAMDECK_DESKTOP_URL" \
        --arg installedAt "$(date -Iseconds)" \
        --argjson appImageInstalled "$([ -x "$EMUDECK_APP" ] && echo true || echo false)" \
        '{hostClass: "steam-deck", launcherKind: "steamdeck-desktop", steamDeckDesktop: $desktop, steamDeckDesktopSource: $url, appImage: $app, appImageInstalled: $appImageInstalled, installedAt: $installedAt}' > "$PZ_EMULATION_STATE/emudeck.json"
    if [ -x "$EMUDECK_APP" ]; then
        pz_info "Steam Deck EmuDeck launcher installed: $desktop (AppImage present)"
    else
        pz_warn "Steam Deck EmuDeck.desktop installed; launch it to complete EmuDeck interactive setup"
    fi
}

install_emudeck() {
    if [ "$(pz_emulation_host_class)" = "steam-deck" ]; then
        install_emudeck_steamdeck
    else
        install_emudeck_appimage
    fi
}

dry_run_emudeck() {
    local host_class target selected_kind selected_path
    host_class="$(pz_emulation_host_class)"
    target="$(emudeck_steamdeck_desktop_target)"
    if [ "$host_class" = "steam-deck" ]; then
        selected_kind="steamdeck-desktop"
        selected_path="$(emudeck_resolve_steamdeck_desktop 2>/dev/null || printf '%s' "$target")"
    else
        selected_kind="appimage"
        selected_path="$EMUDECK_APP"
    fi
    cat <<EOF
EmuDeck dry-run
  host class:  $host_class
  launcher:    $selected_kind
  selected:    $selected_path
  release API: $PZ_EMUDECK_RELEASE_API
  deck desktop URL: $PZ_EMUDECK_STEAMDECK_DESKTOP_URL
  deck desktop target: $target
  appimage:    $EMUDECK_APP
  wrapper:     $EMUDECK_WRAPPER
  desktop:     $EMUDECK_PHASEZERO_DESKTOP
  layout:      $PZ_EMULATION_ROOT
EOF
}

status_emudeck() {
    local host_class steamdeck_desktop target selected_kind selected_path selected_installed host_json
    host_class="$(pz_emulation_host_class)"
    target="$(emudeck_steamdeck_desktop_target)"
    steamdeck_desktop="$(emudeck_resolve_steamdeck_desktop 2>/dev/null || true)"
    host_json="$(pz_emulation_host_json_args)"
    if [ "$host_class" = "steam-deck" ]; then
        selected_kind="steamdeck-desktop"
        selected_path="${steamdeck_desktop:-$target}"
        [ -f "$selected_path" ] && emudeck_desktop_valid "$selected_path" && selected_installed=true || selected_installed=false
    else
        selected_kind="appimage"
        selected_path="$EMUDECK_APP"
        [ -x "$selected_path" ] && selected_installed=true || selected_installed=false
    fi
    jq -n \
        --argjson host "$host_json" \
        --arg releaseApi "$PZ_EMUDECK_RELEASE_API" \
        --arg steamDeckDesktopUrl "$PZ_EMUDECK_STEAMDECK_DESKTOP_URL" \
        --arg app "$EMUDECK_APP" \
        --arg wrapper "$EMUDECK_WRAPPER" \
        --arg desktop "$selected_path" \
        --arg phasezeroDesktop "$EMUDECK_PHASEZERO_DESKTOP" \
        --arg steamDeckDesktop "${steamdeck_desktop:-}" \
        --arg steamDeckDesktopTarget "$target" \
        --arg launcherKind "$selected_kind" \
        --arg launcherPath "$selected_path" \
        --argjson installed "$selected_installed" \
        --argjson appImageInstalled "$([ -x "$EMUDECK_APP" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$EMUDECK_WRAPPER" ] && echo true || echo false)" \
        --argjson desktopInstalled "$([ -f "$selected_path" ] && emudeck_desktop_valid "$selected_path" && echo true || echo false)" \
        --argjson phasezeroDesktopInstalled "$([ -f "$EMUDECK_PHASEZERO_DESKTOP" ] && echo true || echo false)" \
        --argjson steamDeckDesktopInstalled "$([ -n "$steamdeck_desktop" ] && [ -f "$steamdeck_desktop" ] && echo true || echo false)" \
        '{
            host: $host,
            releaseApi: $releaseApi,
            steamDeckDesktopUrl: $steamDeckDesktopUrl,
            appImage: $app,
            wrapper: $wrapper,
            desktop: $desktop,
            phasezeroDesktop: $phasezeroDesktop,
            installed: $installed,
            appImageInstalled: $appImageInstalled,
            wrapperInstalled: $wrapperInstalled,
            desktopInstalled: $desktopInstalled,
            phasezeroDesktopInstalled: $phasezeroDesktopInstalled,
            steamDeckDesktop: {
                path: $steamDeckDesktop,
                target: $steamDeckDesktopTarget,
                installed: $steamDeckDesktopInstalled
            },
            launcher: {
                kind: $launcherKind,
                path: $launcherPath,
                installed: $installed
            }
        }'
}

open_emudeck() {
    [ -x "$EMUDECK_WRAPPER" ] || install_emudeck
    nohup "$EMUDECK_WRAPPER" >/dev/null 2>&1 &
    pz_info "EmuDeck launched"
}

case "$ACTION" in
    install) install_emudeck ;;
    dry-run|plan) dry_run_emudeck ;;
    status) status_emudeck ;;
    open|launch) open_emudeck ;;
    *) pz_error "usage: emudeck.sh (install|dry-run|status|open)"; exit 1 ;;
esac
