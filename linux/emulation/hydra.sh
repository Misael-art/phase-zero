#!/usr/bin/env bash
# hydra.sh - install/manage Hydra launcher integration for SteamOS-like Linux
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
HYDRA_RELEASE_API="${PZ_HYDRA_RELEASE_API:-https://api.github.com/repos/hydralauncher/hydra/releases/latest}"
HYDRA_APP="$PZ_APPLICATIONS_DIR/Hydra.AppImage"
HYDRA_WRAPPER="$PZ_LOCAL_BIN/phasezero-hydra"
HYDRA_STEAMOS_WRAPPER="$PZ_LOCAL_BIN/phasezero-hydra-steamos"
HYDRA_DESKTOP="$PZ_DESKTOP_DIR/phasezero-hydra.desktop"
HYDRA_POLICY="$PZ_EMULATION_STATE/hydra-policy.json"
HYDRA_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher"
HYDRA_CLASSIC_CONFIG="$HYDRA_CONFIG_DIR/config.json"
HYDRA_EMULATORS_CONFIG="$HYDRA_CONFIG_DIR/emulators_config.json"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"

resolve_hydra_url() {
    pz_emulation_release_appimage_url "$HYDRA_RELEASE_API"
}

write_hydra_policy() {
    install -d "$PZ_EMULATION_STATE"
    jq -n \
        --arg emulationRoot "$PZ_EMULATION_ROOT" \
        --arg steamRoot "$STEAM_ROOT" \
        --arg downloads "$HOME/Games/Hydra" \
        '{
            emulationRoot: $emulationRoot,
            steamRoot: $steamRoot,
            suggestedLibraryRoot: $downloads,
            contentPolicy: "user-owned-games-only",
            blockedActions: [
                "configure-repack-download-sources",
                "import-torrent-provider-lists",
                "download-cracks-or-bypasses"
            ],
            integration: {
                desktopLauncher: true,
                steamShortcut: true,
                gamescopeWrapper: true,
                mangohud: true,
                gamemode: true
            }
        }' > "$HYDRA_POLICY"
    pz_info "wrote $HYDRA_POLICY"
}

hydra_running() {
    pgrep -f 'Hydra.AppImage|hydralauncher|phasezero-hydra' >/dev/null 2>&1
}

merge_hydra_classic_config() {
    local force="${1:-0}" tmp
    if hydra_running && [ "$force" != "1" ]; then
        pz_warn "Hydra running; skipped direct config write. Close Hydra or run: linux/pz emulation hydra force-classic-config"
        return 0
    fi
    install -d "$HYDRA_CONFIG_DIR"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$HYDRA_CLASSIC_CONFIG" ] && jq empty "$HYDRA_CLASSIC_CONFIG" >/dev/null 2>&1; then
        jq '.displayClassicContent = true
            | .enableRetroUIFeatures = true
            | .phasezeroManaged = true
            | .phasezeroPolicy = "user-owned-games-only"' "$HYDRA_CLASSIC_CONFIG" > "$tmp"
    else
        jq -n '{
            displayClassicContent: true,
            enableRetroUIFeatures: true,
            phasezeroManaged: true,
            phasezeroPolicy: "user-owned-games-only"
        }' > "$tmp"
    fi
    pz_backup_file "$HYDRA_CLASSIC_CONFIG" user >/dev/null
    install -m 0644 "$tmp" "$HYDRA_CLASSIC_CONFIG"
    rm -f "$tmp"
    pz_info "Hydra Classic config written: $HYDRA_CLASSIC_CONFIG"
}

find_first_executable() {
    local candidate
    for candidate in "$@"; do
        [ -z "$candidate" ] && continue
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

hydra_emulator_entries_json() {
    local duckstation pcsx2 rpcs3
    duckstation="$(find_first_executable duckstation-qt duckstation "$PZ_APPLICATIONS_DIR/DuckStation.AppImage" || true)"
    pcsx2="$(find_first_executable pcsx2-qt pcsx2 "$PZ_APPLICATIONS_DIR/pcsx2-Qt.AppImage" "$PZ_APPLICATIONS_DIR/PCSX2.AppImage" || true)"
    rpcs3="$(find_first_executable rpcs3 "$PZ_APPLICATIONS_DIR/rpcs3.AppImage" "$PZ_APPLICATIONS_DIR/RPCS3.AppImage" || true)"
    jq -n \
        --arg duckstation "$duckstation" \
        --arg pcsx2 "$pcsx2" \
        --arg rpcs3 "$rpcs3" \
        --arg ps1 "$PZ_EMULATION_ROOT/roms/psx" \
        --arg ps2 "$PZ_EMULATION_ROOT/roms/ps2" \
        --arg ps3 "$PZ_EMULATION_ROOT/roms/ps3" \
        '[
            {
                systemKey: "playstation1",
                emulator_name: "DuckStation",
                executable_path: $duckstation,
                roms_directory: $ps1,
                default_flags: "-batch -fullscreen"
            },
            {
                systemKey: "playstation2",
                emulator_name: "PCSX2-Qt",
                executable_path: $pcsx2,
                roms_directory: $ps2,
                default_flags: "-fullscreen -batch"
            },
            {
                systemKey: "playstation3",
                emulator_name: "RPCS3",
                executable_path: $rpcs3,
                roms_directory: $ps3,
                default_flags: "--no-gui"
            }
        ] | map(select(.executable_path != ""))'
}

merge_hydra_emulators_config() {
    local force="${1:-0}" tmp entries
    if hydra_running && [ "$force" != "1" ]; then
        pz_warn "Hydra running; skipped emulator config write. Close Hydra or run: linux/pz emulation hydra force-classic-config"
        return 0
    fi
    install -d "$HYDRA_CONFIG_DIR"
    entries="$(hydra_emulator_entries_json)"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$HYDRA_EMULATORS_CONFIG" ] && jq empty "$HYDRA_EMULATORS_CONFIG" >/dev/null 2>&1; then
        cp "$HYDRA_EMULATORS_CONFIG" "$tmp"
    else
        printf '{}\n' > "$tmp"
    fi
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        local system_key emulator_name executable_path roms_directory default_flags next
        system_key="$(jq -r '.systemKey' <<< "$entry")"
        emulator_name="$(jq -r '.emulator_name' <<< "$entry")"
        executable_path="$(jq -r '.executable_path' <<< "$entry")"
        roms_directory="$(jq -r '.roms_directory' <<< "$entry")"
        default_flags="$(jq -r '.default_flags' <<< "$entry")"
        # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
        next="$(pz_tempfile)"
        jq \
            --arg key "$system_key" \
            --arg name "$emulator_name" \
            --arg exe "$executable_path" \
            --arg roms "$roms_directory" \
            --arg flags "$default_flags" \
            '.[$key] = {
                enabled: true,
                emulator_name: $name,
                executable_path: $exe,
                roms_directory: $roms,
                default_flags: $flags
            }' "$tmp" > "$next"
        mv "$next" "$tmp"
    done < <(jq -c '.[]' <<< "$entries")
    pz_backup_file "$HYDRA_EMULATORS_CONFIG" user >/dev/null
    install -m 0644 "$tmp" "$HYDRA_EMULATORS_CONFIG"
    rm -f "$tmp"
    pz_info "Hydra emulator config written: $HYDRA_EMULATORS_CONFIG"
}

configure_hydra_classic() {
    local force="${1:-0}"
    merge_hydra_classic_config "$force"
    merge_hydra_emulators_config "$force"
    write_hydra_policy
}

write_hydra_wrappers() {
    pz_emulation_write_file "$HYDRA_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$HYDRA_APP"
export GDK_BACKEND="\${GDK_BACKEND:-x11}"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="\${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$STEAM_ROOT}"
export STEAM_COMPAT_DATA_PATH="\${STEAM_COMPAT_DATA_PATH:-$STEAM_ROOT/steamapps/compatdata/phasezero-hydra}"
if command -v gamemoderun >/dev/null 2>&1; then
    exec env MANGOHUD=1 gamemoderun "\$app" "\$@"
fi
exec env MANGOHUD=1 "\$app" "\$@"
EOF

    pz_emulation_write_file "$HYDRA_STEAMOS_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
launcher="$HYDRA_WRAPPER"
if [ "\${PZ_HYDRA_FORCE_GAMESCOPE:-0}" = "1" ] && command -v gamescope >/dev/null 2>&1; then
    exec gamescope -f -w 1280 -h 800 -W 1280 -H 800 --mangoapp -- "\$launcher" "\$@"
fi
exec "\$launcher" "\$@"
EOF
}

write_hydra_desktop() {
    pz_emulation_write_file "$HYDRA_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Hydra
Comment=Hydra launcher managed by PhaseZero
Exec=$HYDRA_STEAMOS_WRAPPER
Terminal=false
Categories=Game;
EOF
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
}

install_hydra() {
    if pz_emulation_foreign_install Hydra "$PZ_EMULATION_STATE/hydra.json" \
        --bin hydralauncher --appimage 'Hydra*.AppImage' --desktop-exec hydralauncher; then
        return 0
    fi
    local url
    pz_emulation_ensure_layout
    url="$(resolve_hydra_url)"
    [ -n "$url" ] || { pz_error "could not resolve Hydra AppImage URL from $HYDRA_RELEASE_API"; return 1; }
    pz_info "downloading Hydra AppImage"
    pz_emulation_download "$url" "$HYDRA_APP"
    write_hydra_wrappers
    write_hydra_desktop
    configure_hydra_classic
    add_steam_shortcut || pz_warn "Steam shortcut not written; close Steam and rerun: linux/pz emulation hydra steam-shortcut"
    jq -n --arg url "$url" --arg app "$HYDRA_APP" --arg installedAt "$(date -Iseconds)" \
        '{source: $url, appImage: $app, installedAt: $installedAt}' > "$PZ_EMULATION_STATE/hydra.json"
    pz_info "Hydra installed: $HYDRA_APP"
}

add_steam_shortcut() {
    python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" add \
        --steam-root "$STEAM_ROOT" \
        --app-name "Hydra" \
        --exe "$HYDRA_STEAMOS_WRAPPER" \
        --start-dir "$(dirname "$HYDRA_STEAMOS_WRAPPER")" \
        --icon "$HYDRA_APP" \
        --tag PhaseZero \
        --tag SteamOS \
        --tag Hydra
}

status_hydra_shortcut() {
    python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" status \
        --steam-root "$STEAM_ROOT" \
        --app-name "Hydra" >/dev/null 2>&1
}

status_hydra() {
    local classic_config=false emulators_config=false emulators_count=0
    [ -f "$HYDRA_CLASSIC_CONFIG" ] && classic_config=true
    [ -f "$HYDRA_EMULATORS_CONFIG" ] && emulators_config=true
    if [ -f "$HYDRA_EMULATORS_CONFIG" ] && jq empty "$HYDRA_EMULATORS_CONFIG" >/dev/null 2>&1; then
        emulators_count="$(jq 'length' "$HYDRA_EMULATORS_CONFIG")"
    fi
    jq -n \
        --arg releaseApi "$HYDRA_RELEASE_API" \
        --arg app "$HYDRA_APP" \
        --arg wrapper "$HYDRA_WRAPPER" \
        --arg steamosWrapper "$HYDRA_STEAMOS_WRAPPER" \
        --arg desktop "$HYDRA_DESKTOP" \
        --arg policy "$HYDRA_POLICY" \
        --arg classicConfig "$HYDRA_CLASSIC_CONFIG" \
        --arg emulatorsConfig "$HYDRA_EMULATORS_CONFIG" \
        --arg steamRoot "$STEAM_ROOT" \
        --argjson installed "$([ -x "$HYDRA_APP" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$HYDRA_WRAPPER" ] && echo true || echo false)" \
        --argjson desktopInstalled "$([ -f "$HYDRA_DESKTOP" ] && echo true || echo false)" \
        --argjson policyInstalled "$([ -f "$HYDRA_POLICY" ] && echo true || echo false)" \
        --argjson classicConfigInstalled "$classic_config" \
        --argjson emulatorsConfigInstalled "$emulators_config" \
        --argjson emulatorsConfigured "$emulators_count" \
        --argjson steamShortcutInstalled "$(status_hydra_shortcut && echo true || echo false)" \
        '{releaseApi: $releaseApi, appImage: $app, wrapper: $wrapper, steamosWrapper: $steamosWrapper, desktop: $desktop, policy: $policy, classicConfig: $classicConfig, emulatorsConfig: $emulatorsConfig, steamRoot: $steamRoot, installed: $installed, wrapperInstalled: $wrapperInstalled, desktopInstalled: $desktopInstalled, policyInstalled: $policyInstalled, classicConfigInstalled: $classicConfigInstalled, emulatorsConfigInstalled: $emulatorsConfigInstalled, emulatorsConfigured: $emulatorsConfigured, steamShortcutInstalled: $steamShortcutInstalled}'
}

dry_run_hydra() {
    cat <<EOF
Hydra dry-run
  release API: $HYDRA_RELEASE_API
  appimage:    $HYDRA_APP
  wrapper:     $HYDRA_WRAPPER
  steamos:     $HYDRA_STEAMOS_WRAPPER
  desktop:     $HYDRA_DESKTOP
  steam root:  $STEAM_ROOT
  policy:      user-owned-games-only; no provider/repack/torrent source import
  classic:     $HYDRA_CLASSIC_CONFIG
  emulators:   $HYDRA_EMULATORS_CONFIG
EOF
}

print_hydra_sources_policy() {
    cat <<EOF
Hydra download sources policy
  status: blocked
  reason: PhaseZero does not add game/ROM/PKG/RAP torrent, repack, crack, bypass, or third-party download providers.

Allowed local-owned flows:
  linux/pz emulation ps3 import-game /path/to/local/ps3-dump
  linux/pz emulation ps3 import-firmware /path/to/local/PS3UPDAT.PUP
  linux/pz emulation ps3 import-pkg /path/to/local/pkg-or-folder
  linux/pz emulation ps3 import-rap /path/to/local/rap-or-folder
  linux/pz emulation srm configure
  linux/pz emulation hydra force-classic-config

Hydra may still show an empty "download sources" filter. That is expected.
EOF
}

open_hydra() {
    [ -x "$HYDRA_STEAMOS_WRAPPER" ] || install_hydra
    nohup "$HYDRA_STEAMOS_WRAPPER" >/dev/null 2>&1 &
    pz_info "Hydra launched"
}

case "$ACTION" in
    install|update) install_hydra ;;
    configure|integrate) pz_emulation_ensure_layout; write_hydra_wrappers; write_hydra_desktop; configure_hydra_classic ;;
    classic-config|emulators-config) configure_hydra_classic ;;
    force-classic-config) configure_hydra_classic 1 ;;
    sources|download-sources) print_hydra_sources_policy ;;
    steam-shortcut) add_steam_shortcut ;;
    dry-run|plan) dry_run_hydra ;;
    status) status_hydra ;;
    open|launch) open_hydra ;;
    *) pz_error "usage: hydra.sh (install|update|configure|classic-config|emulators-config|force-classic-config|sources|steam-shortcut|dry-run|status|open)"; exit 1 ;;
esac
