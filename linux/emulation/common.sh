#!/usr/bin/env bash
# common.sh - shared helpers for Linux emulation setup
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PZ_EMULATION_ROOT="${PZ_EMULATION_ROOT:-$HOME/Emulation}"
PZ_APPLICATIONS_DIR="${PZ_APPLICATIONS_DIR:-$HOME/Applications}"
PZ_LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
PZ_DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
PZ_EMULATION_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/emulation"

pz_ini_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    install -d "$(dirname "$file")"
    [ -f "$file" ] || printf '[%s]\n' "$section" > "$file"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { active=0; section_seen=0; wrote=0 }
        $0 == "[" section "]" { active=1; section_seen=1; print; next }
        /^\[/ {
            if (active && !wrote) { print key " = " value; wrote=1 }
            active=0; print; next
        }
        active && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!wrote) { print key " = " value; wrote=1 }
            next
        }
        { print }
        END {
            if (!section_seen) print "[" section "]"
            if (!wrote) print key " = " value
        }
    ' "$file" > "$tmp"
    if [ -f "$file" ]; then
        cp "$file" "$file.phasezero.bak" 2>/dev/null || true
    fi
    mv "$tmp" "$file"
}

PZ_EDEN_VERSION="${PZ_EDEN_VERSION:-v0.2.1}"
PZ_EDEN_APPIMAGE_NAME="Eden-Linux-${PZ_EDEN_VERSION}-steamdeck-clang-pgo.AppImage"
PZ_EDEN_APPIMAGE_URL="${PZ_EDEN_APPIMAGE_URL:-https://stable.eden-emu.dev/${PZ_EDEN_VERSION}/$PZ_EDEN_APPIMAGE_NAME}"
PZ_EDEN_ZSYNC_URL="${PZ_EDEN_ZSYNC_URL:-https://stable.eden-emu.dev/${PZ_EDEN_VERSION}/Eden-Linux-steamdeck-clang-pgo.AppImage.zsync}"
PZ_CITRON_RELEASE_API="${PZ_CITRON_RELEASE_API:-https://api.github.com/repos/citron-neo/emulator/releases/latest}"
PZ_EMUDECK_RELEASE_API="${PZ_EMUDECK_RELEASE_API:-https://api.github.com/repos/EmuDeck/emudeck-electron/releases/latest}"
PZ_EMUDECK_STEAMDECK_DESKTOP_URL="${PZ_EMUDECK_STEAMDECK_DESKTOP_URL:-https://raw.githubusercontent.com/EmuDeck/EmuDeckWebsite/main/EmuDeck.desktop}"
PZ_RETRODECK_APP_ID="${PZ_RETRODECK_APP_ID:-net.retrodeck.retrodeck}"
PZ_RETRODECK_MANIFEST="${PZ_RETRODECK_MANIFEST:-$HOME/.var/app/$PZ_RETRODECK_APP_ID/config/retrodeck/retrodeck.json}"
if [ -n "${PZ_RETRODECK_ROOT+x}" ]; then
    PZ_RETRODECK_ROOT_EXPLICIT=1
else
    PZ_RETRODECK_ROOT_EXPLICIT=0
fi

pz_emulation_read_dmi() {
    local name="$1" dmi_dir="${PZ_EMULATION_DMI_DIR:-/sys/devices/virtual/dmi/id}"
    [ -f "$dmi_dir/$name" ] || return 0
    tr -d '\000' < "$dmi_dir/$name" 2>/dev/null | head -n 1
}

pz_emulation_is_steam_deck_hardware() {
    case "${PZ_EMULATION_HOST_CLASS:-}" in
        steam-deck|steamdeck) return 0 ;;
        linux-pc|pc|generic) return 1 ;;
    esac

    local product product_version sys_vendor board_name board_vendor chassis_type haystack
    product="$(pz_emulation_read_dmi product_name)"
    product_version="$(pz_emulation_read_dmi product_version)"
    sys_vendor="$(pz_emulation_read_dmi sys_vendor)"
    board_name="$(pz_emulation_read_dmi board_name)"
    board_vendor="$(pz_emulation_read_dmi board_vendor)"
    chassis_type="$(pz_emulation_read_dmi chassis_type)"
    haystack="${product} ${product_version} ${sys_vendor} ${board_name} ${board_vendor}"

    if printf '%s\n' "$haystack" | grep -Eqi '(^|[^A-Za-z0-9])(steam deck|jupiter|galileo|sephiroth)([^A-Za-z0-9]|$)'; then
        return 0
    fi
    if printf '%s\n' "$sys_vendor $board_vendor" | grep -qi 'valve' &&
        printf '%s\n' "$product $board_name $product_version" | grep -Eqi 'steam|deck|jupiter|galileo|sephiroth'; then
        return 0
    fi
    if printf '%s\n' "$sys_vendor $board_vendor" | grep -qi 'valve' && [ "$chassis_type" = "8" ]; then
        return 0
    fi
    return 1
}

pz_emulation_host_class() {
    if pz_emulation_is_steam_deck_hardware; then
        echo "steam-deck"
    else
        echo "linux-pc"
    fi
}

pz_emulation_host_json_args() {
    local product product_version sys_vendor board_name board_vendor chassis_type host_class
    product="$(pz_emulation_read_dmi product_name)"
    product_version="$(pz_emulation_read_dmi product_version)"
    sys_vendor="$(pz_emulation_read_dmi sys_vendor)"
    board_name="$(pz_emulation_read_dmi board_name)"
    board_vendor="$(pz_emulation_read_dmi board_vendor)"
    chassis_type="$(pz_emulation_read_dmi chassis_type)"
    host_class="$(pz_emulation_host_class)"

    jq -n \
        --arg class "$host_class" \
        --arg productName "$product" \
        --arg productVersion "$product_version" \
        --arg sysVendor "$sys_vendor" \
        --arg boardName "$board_name" \
        --arg boardVendor "$board_vendor" \
        --arg chassisType "$chassis_type" \
        --argjson steamDeckHardware "$([ "$host_class" = "steam-deck" ] && echo true || echo false)" \
        '{
            class: $class,
            steamDeckHardware: $steamDeckHardware,
            dmi: {
                productName: $productName,
                productVersion: $productVersion,
                sysVendor: $sysVendor,
                boardName: $boardName,
                boardVendor: $boardVendor,
                chassisType: $chassisType
            }
        }'
}

pz_retrodeck_manifest_valid() {
    [ -f "$PZ_RETRODECK_MANIFEST" ] && jq -e '.paths | type == "object"' "$PZ_RETRODECK_MANIFEST" >/dev/null 2>&1
}

pz_retrodeck_manifest_value() {
    local key="$1"
    pz_retrodeck_manifest_valid || return 0
    jq -r --arg key "$key" '.paths[$key] // empty' "$PZ_RETRODECK_MANIFEST"
}

pz_retrodeck_root() {
    if [ "$PZ_RETRODECK_ROOT_EXPLICIT" = "1" ]; then
        printf '%s\n' "$PZ_RETRODECK_ROOT"
        return 0
    fi
    local configured
    configured="$(pz_retrodeck_manifest_value rd_home_path)"
    printf '%s\n' "${configured:-$HOME/retrodeck}"
}

pz_retrodeck_path() {
    local manifest_key="$1" fallback_relative="$2"
    if [ "$PZ_RETRODECK_ROOT_EXPLICIT" = "0" ]; then
        local configured
        configured="$(pz_retrodeck_manifest_value "$manifest_key")"
        if [ -n "$configured" ]; then
            printf '%s\n' "$configured"
            return 0
        fi
    fi
    printf '%s/%s\n' "$(pz_retrodeck_root)" "$fallback_relative"
}

pz_retrodeck_esde_settings() {
    local path
    {
        for path in \
            "${PZ_RETRODECK_FLATPAK_ESDE_SETTINGS:-}" \
            "$HOME/.var/app/$PZ_RETRODECK_APP_ID/config/ES-DE/settings/es_settings.xml" \
            "$HOME/.var/app/$PZ_RETRODECK_APP_ID/config/emulationstation/.emulationstation/es_settings.xml"; do
            [ -n "$path" ] && [ -f "$path" ] && printf '%s\n' "$path"
        done
        true
    } | awk '!seen[$0]++'
}

pz_emulation_layout_dirs() {
    cat <<EOF
$PZ_EMULATION_ROOT
$PZ_EMULATION_ROOT/bios
$PZ_EMULATION_ROOT/roms
$PZ_EMULATION_ROOT/roms/switch
$PZ_EMULATION_ROOT/roms/switch/nsp
$PZ_EMULATION_ROOT/roms/psx
$PZ_EMULATION_ROOT/roms/ps2
$PZ_EMULATION_ROOT/roms/ps3
$PZ_EMULATION_ROOT/roms/ps3/pkg
$PZ_EMULATION_ROOT/roms/ps4
$PZ_EMULATION_ROOT/roms/ps4/shortcuts
$PZ_EMULATION_ROOT/roms/psp
$PZ_EMULATION_ROOT/roms/gc
$PZ_EMULATION_ROOT/roms/wii
$PZ_EMULATION_ROOT/roms/wiiu
$PZ_EMULATION_ROOT/roms/n64
$PZ_EMULATION_ROOT/roms/snes
$PZ_EMULATION_ROOT/roms/nes
$PZ_EMULATION_ROOT/roms/gba
$PZ_EMULATION_ROOT/roms/gb
$PZ_EMULATION_ROOT/saves
$PZ_EMULATION_ROOT/saves/switch
$PZ_EMULATION_ROOT/saves/ps4
$PZ_EMULATION_ROOT/states
$PZ_EMULATION_ROOT/state
$PZ_EMULATION_ROOT/state/switch/nand
$PZ_EMULATION_ROOT/cache
$PZ_EMULATION_ROOT/cache/switch
$PZ_EMULATION_ROOT/cache/ps4
$PZ_EMULATION_ROOT/storage
$PZ_EMULATION_ROOT/storage/pcsx2
$PZ_EMULATION_ROOT/storage/rpcs3
$PZ_EMULATION_ROOT/storage/shadps4
$PZ_EMULATION_ROOT/mods
$PZ_EMULATION_ROOT/mods/switch
$PZ_EMULATION_ROOT/mods/ps4
$PZ_EMULATION_ROOT/cheats
$PZ_EMULATION_ROOT/patches
$PZ_EMULATION_ROOT/shaders
$PZ_EMULATION_ROOT/screenshots
$PZ_EMULATION_ROOT/videos
$PZ_EMULATION_ROOT/borders
$PZ_EMULATION_ROOT/themes
$PZ_EMULATION_ROOT/texture_packs
$PZ_EMULATION_ROOT/tools/downloaded_media
$PZ_EMULATION_ROOT/tools/launchers
$PZ_EMULATION_ROOT/tools/launchers/Roms
$PZ_EMULATION_ROOT/tools/launchers/emulators
$PZ_EMULATION_ROOT/tools/launchers/frontends
$PZ_EMULATION_ROOT/tools/pc-games
$PZ_EMULATION_ROOT/tools/pc-games/launchers
$PZ_EMULATION_ROOT/tools/pc-games/desktops
$PZ_EMULATION_ROOT/media/steamgrid
$PZ_EMULATION_ROOT/media/index
$PZ_EMULATION_ROOT/.phasezero/backups
$PZ_EMULATION_ROOT/metadata
$PZ_EMULATION_ROOT/metadata/gamelists
$PZ_EMULATION_ROOT/metadata/gamelists/frontends
$PZ_EMULATION_ROOT/metadata/gamelists/steam
$PZ_EMULATION_ROOT/metadata/pc-games
$PZ_EMULATION_ROOT/metadata/frontends
$PZ_EMULATION_ROOT/metadata/switch
$PZ_EMULATION_ROOT/metadata/switch/nsz-conversions
$PZ_EMULATION_ROOT/storage/pc-prefixes
$PZ_EMULATION_ROOT/firmware
$PZ_EMULATION_ROOT/firmware/ps3
$PZ_EMULATION_ROOT/firmware/ps4
$PZ_EMULATION_ROOT/firmware/switch/keys
$PZ_EMULATION_ROOT/firmware/switch/firmware
$PZ_APPLICATIONS_DIR
$PZ_LOCAL_BIN
$PZ_DESKTOP_DIR
$PZ_EMULATION_STATE
EOF
}

pz_emulation_ensure_layout() {
    local dir
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        install -d "$dir"
    done < <(pz_emulation_layout_dirs)
    pz_emulation_consolidate_aliases
    pz_info "emulation layout ready: $PZ_EMULATION_ROOT"
}

# Compatibility aliases for the Emulation tree. Several consumers (EmuDeck,
# RetroDECK, older scripts) reference slightly different top-level names than
# the canonical layout. Rather than let duplicate real directories accumulate,
# point the alternate names at the canonical location via symlink.
pz_emulation_consolidate_aliases() {
    # Each entry: <canonical> <alias>  -> ln -sfn canonical alias
    # Note: state/ and states/ are BOTH canonical and kept as real dirs (state/
    # holds switch/nand; states/ is the RetroDECK save-state tree) — no alias.
    local entries=(
        "$PZ_EMULATION_ROOT/texture_packs|$PZ_EMULATION_ROOT/texturepacks"
        "$PZ_EMULATION_ROOT/texture_packs|$PZ_EMULATION_ROOT/hdpacks"
        "$PZ_EMULATION_ROOT/firmware/switch/keys|$PZ_EMULATION_ROOT/keys"
    )
    local canonical alias entry
    for entry in "${entries[@]}"; do
        canonical="${entry%%|*}"
        alias="${entry##*|}"
        if [ -z "$canonical" ] || [ -z "$alias" ]; then
            continue
        fi
        [ "$canonical" = "$alias" ] && continue
        # Skip if the alias is already a symlink pointing at the canonical target.
        if [ -L "$alias" ] && [ "$(readlink -f "$alias")" = "$(readlink -f "$canonical")" ]; then
            continue
        fi
        # Only convert when the alias is absent or an empty dir; never clobber
        # a real (populated) directory the user may rely on.
        if [ -e "$alias" ] && [ ! -L "$alias" ]; then
            local count
            count="$(find "$alias" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
            if [ "$count" -eq 0 ]; then
                rmdir "$alias" 2>/dev/null || true
            else
                continue
            fi
        fi
        ln -sfn "$canonical" "$alias" 2>/dev/null || true
    done
}

pz_emulation_write_file() {
    local path="$1" mode="${2:-0644}" dir tmp
    dir="$(dirname "$path")"
    install -d "$dir"
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    cat > "$tmp"
    pz_backup_file "$path" user >/dev/null
    install -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
    pz_info "wrote $path"
}

pz_emulation_download() {
    local url="$1" target="$2" tmp
    tmp="${target}.tmp.$$"
    rm -f "$tmp"
    curl -L --fail --retry 3 --connect-timeout 15 -o "$tmp" "$url"
    chmod +x "$tmp"
    mv "$tmp" "$target"
}

pz_emulation_remote_source() {
    case "$1" in
        http://*|https://*|git://*|ssh://*|git@*) return 0 ;;
        *) return 1 ;;
    esac
}

pz_emulation_blocked_source_reason() {
    case "$1" in
        *github.com/Abdess/retrobios*|*github.com/THZoria/NX_Firmware*|*edenemulators.com/eden-prod-keys*)
            echo "third-party BIOS/firmware/keys downloads are blocked; import only local dumps from hardware you own"
            return 0
            ;;
    esac
    return 1
}

pz_emulation_require_local_source() {
    local source="$1" reason
    reason="$(pz_emulation_blocked_source_reason "$source" 2>/dev/null || true)"
    if [ -n "$reason" ]; then
        pz_error "blocked source: $source ($reason)"
        return 3
    fi
    if pz_emulation_remote_source "$source"; then
        pz_error "remote BIOS/firmware/key source blocked: $source"
        return 3
    fi
    [ -e "$source" ] || { pz_error "source not found: $source"; return 1; }
}

pz_emulation_copy_source() {
    local source="$1" dest="$2"
    install -d "$dest"
    if [ -d "$source" ]; then
        find "$source" -mindepth 1 -maxdepth 1 -exec cp -a {} "$dest"/ \;
    else
        cp -a "$source" "$dest"/
    fi
}

pz_emulation_count_files() {
    local dir="$1"
    [ -d "$dir" ] || { echo 0; return 0; }
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

pz_emulation_active_frontends() {
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
        $2 == "ES-DE" ||
        $2 == "es-de" ||
        $2 == "retrodeck" ||
        $2 == "retrodeck.sh" ||
        $2 == "emulationstation" {
            sub(/^[[:space:]]+/, "")
            print
        }
    ' || true
}

pz_emulation_abort_if_frontend_running() {
    [ "${PZ_EMULATION_FORCE_APPLY:-0}" = "1" ] && return 0
    local running
    running="$(pz_emulation_active_frontends)"
    if [ -n "$running" ]; then
        pz_error "emulation frontend running; close ES-DE/RetroDECK before apply/repair or set PZ_EMULATION_FORCE_APPLY=1"
        printf '%s\n' "$running" >&2
        return 2
    fi
}

pz_emulation_sha256_or_empty() {
    local path="$1"
    [ -f "$path" ] || return 0
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
}

pz_emulation_status_json() {
    local emudeck_app="$PZ_APPLICATIONS_DIR/EmuDeck.AppImage"
    local eden_app="$PZ_APPLICATIONS_DIR/$PZ_EDEN_APPIMAGE_NAME"
    local eden_link="$PZ_APPLICATIONS_DIR/Eden.AppImage"
    local hydra_app="$PZ_APPLICATIONS_DIR/Hydra.AppImage"
    local hydra_policy="$PZ_EMULATION_STATE/hydra-policy.json"
    local srm_app="$PZ_EMULATION_ROOT/tools/Steam-ROM-Manager.AppImage"
    local srm_launcher="$PZ_EMULATION_ROOT/tools/launchers/srm/steamrommanager.sh"
    local srm_settings="${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userSettings.json"
    local srm_configs="${XDG_CONFIG_HOME:-$HOME/.config}/steam-rom-manager/userData/userConfigurations.json"
    local hydra_classic_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json"
    local hydra_emulators_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json"
    local bios_count switch_key_count switch_fw_count hydra_emulators_count hydra_classic_enabled srm_configured emudeck_status
    bios_count="$(pz_emulation_count_files "$PZ_EMULATION_ROOT/bios")"
    hydra_emulators_count=0
    hydra_classic_enabled=false
    srm_configured=false
    emudeck_status="$(bash "$PZ_ROOT/linux/emulation/emudeck.sh" status 2>/dev/null || echo '{}')"
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$emudeck_status"; then
        emudeck_status='{}'
    fi
    if [ -f "$hydra_emulators_config" ] && jq empty "$hydra_emulators_config" >/dev/null 2>&1; then
        hydra_emulators_count="$(jq 'length' "$hydra_emulators_config")"
    fi
    if [ -f "$hydra_classic_config" ] && jq -e '.displayClassicContent == true and .enableRetroUIFeatures == true' "$hydra_classic_config" >/dev/null 2>&1; then
        hydra_classic_enabled=true
    fi
    if [ -f "$srm_settings" ] && [ -f "$srm_configs" ] && jq -e --arg steam "${STEAM_ROOT:-$HOME/.local/share/Steam}" --arg roms "$PZ_EMULATION_ROOT/roms" '.environmentVariables.steamDirectory == $steam and .environmentVariables.romsDirectory == $roms' "$srm_settings" >/dev/null 2>&1; then
        srm_configured=true
    fi
    if [ -d "$PZ_EMULATION_ROOT/firmware/switch/keys" ]; then
        switch_key_count="$(find "$PZ_EMULATION_ROOT/firmware/switch/keys" -maxdepth 1 -type f \( -name 'prod.keys' -o -name 'title.keys' \) 2>/dev/null | wc -l | tr -d ' ')"
    else
        switch_key_count=0
    fi
    switch_fw_count="$(pz_emulation_count_files "$PZ_EMULATION_ROOT/firmware/switch/firmware")"
    jq -n \
        --arg root "$PZ_EMULATION_ROOT" \
        --arg appDir "$PZ_APPLICATIONS_DIR" \
        --arg emudeck "$emudeck_app" \
        --arg eden "$eden_app" \
        --arg edenLink "$eden_link" \
        --arg edenSha "$(pz_emulation_sha256_or_empty "$eden_app")" \
        --arg hydra "$hydra_app" \
        --arg hydraPolicy "$hydra_policy" \
        --arg srmApp "$srm_app" \
        --arg srmLauncher "$srm_launcher" \
        --arg srmSettings "$srm_settings" \
        --arg srmConfigs "$srm_configs" \
        --arg hydraClassicConfig "$hydra_classic_config" \
        --arg hydraEmulatorsConfig "$hydra_emulators_config" \
        --argjson emudeckStatus "$emudeck_status" \
        --argjson emudeckInstalled "$([ -x "$emudeck_app" ] && echo true || echo false)" \
        --argjson edenInstalled "$([ -x "$eden_app" ] && echo true || echo false)" \
        --argjson edenLinkInstalled "$([ -x "$eden_link" ] && echo true || echo false)" \
        --argjson hydraInstalled "$([ -x "$hydra_app" ] && echo true || echo false)" \
        --argjson hydraPolicyInstalled "$([ -f "$hydra_policy" ] && echo true || echo false)" \
        --argjson srmInstalled "$({ [ -f "$srm_app" ] || [ -f "$srm_launcher" ]; } && echo true || echo false)" \
        --argjson srmConfigured "$srm_configured" \
        --argjson hydraClassicEnabled "$hydra_classic_enabled" \
        --argjson hydraEmulatorsConfigured "$hydra_emulators_count" \
        --argjson biosCount "$bios_count" \
        --argjson switchKeyCount "$switch_key_count" \
        --argjson switchFirmwareCount "$switch_fw_count" \
        '{
            root: $root,
            applicationsDir: $appDir,
            emudeck: ({ appImage: $emudeck, appImageInstalled: $emudeckInstalled, installed: $emudeckInstalled } + $emudeckStatus),
            eden: { appImage: $eden, link: $edenLink, installed: $edenInstalled, linkInstalled: $edenLinkInstalled, sha256: $edenSha },
            hydra: { appImage: $hydra, installed: $hydraInstalled, policy: $hydraPolicy, policyInstalled: $hydraPolicyInstalled, classicConfig: $hydraClassicConfig, classicEnabled: $hydraClassicEnabled, emulatorsConfig: $hydraEmulatorsConfig, emulatorsConfigured: $hydraEmulatorsConfigured },
            srm: { appImage: $srmApp, launcher: $srmLauncher, settings: $srmSettings, configurations: $srmConfigs, installed: $srmInstalled, configured: $srmConfigured },
            userContent: {
                biosFileCount: $biosCount,
                switchKeyFileCount: $switchKeyCount,
                switchFirmwareFileCount: $switchFirmwareCount,
                policy: "local-user-owned-import-only"
            }
        }'
}

pz_emulation_switch_ryujinx_paths() {
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local keys_dir="$data_home/Ryujinx/keys"
    local firmware_dir="$data_home/Ryujinx/bis/system/Contents/registered"
    local has_keys=false has_firmware=false

    if [ -f "$keys_dir/prod.keys" ] || [ -f "$keys_dir/title.keys" ]; then has_keys=true; fi
    if [ -d "$firmware_dir" ] && find "$firmware_dir" -maxdepth 1 -type f -name '*.nca' 2>/dev/null | grep -q .; then has_firmware=true; fi

    if ! $has_keys && ! $has_firmware; then echo null; return 0; fi

    jq -n \
        --arg keys "$keys_dir" \
        --arg firmware "$firmware_dir" \
        --argjson hasKeys "$has_keys" \
        --argjson hasFirmware "$has_firmware" \
        '{
            keys: (if $hasKeys then $keys else null end),
            firmware: (if $hasFirmware then $firmware else null end),
            hasKeys: $hasKeys,
            hasFirmware: $hasFirmware
        }'
}

pz_emulation_print_blocked_sources() {
    cat <<'EOF'
Blocked by PhaseZero:
  https://github.com/Abdess/retrobios.git
  https://github.com/THZoria/NX_Firmware.git
  https://edenemulators.com/eden-prod-keys/

Reason:
  BIOS, console firmware, prod.keys/title.keys, ROMs, updates and DLC are user-owned content.
  PhaseZero imports local dumps only. It never downloads or redistributes those files.

Allowed:
  linux/pz emulation bios import /path/to/local/bios-dump
  linux/pz emulation switch import-keys /path/to/local/switch-keys
  linux/pz emulation switch import-firmware /path/to/local/switch-firmware
EOF
}

# --- coexistência com instalações de terceiros ------------------------------

# Retorna 0 (pule a instalação) quando o app já existe por outro canal e não
# foi o PhaseZero que o instalou (sem arquivo de estado próprio).
pz_emulation_foreign_install() {
    local label="$1" state="$2" hit=""
    shift 2
    [ -f "$state" ] && return 1
    [ "${PZ_ALLOW_DUPLICATE:-0}" = "1" ] && return 1
    hit="$(pz_app_already_installed "$@")" || return 1
    pz_info "$label já instalado fora do PhaseZero (${hit//$'\t'/: }); usando a instalação existente"
    return 0
}

# ln -sfn que não apaga um arquivo real de outro instalador (EmuDeck também
# usa ~/Applications/Eden.AppImage, por exemplo).
pz_emulation_safe_link() {
    local source="$1" link="$2"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        pz_warn "$link é um arquivo de outra instalação; mantido sem alteração"
        return 0
    fi
    ln -sfn "$source" "$link"
}

# Verdadeiro quando o caminho de chaves/firmware é um link do usuário para um
# local próprio com conteúdo: o PhaseZero não troca a escolha dele.
pz_emulation_user_link() {
    local path="$1" target central="$PZ_EMULATION_ROOT/firmware/switch"
    [ -L "$path" ] || return 1
    target="$(readlink -f "$path" 2>/dev/null || true)"
    [ -n "$target" ] && [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ] || return 1
    case "$target" in
        "$(readlink -f "$central" 2>/dev/null || echo "$central")"/*) return 1 ;;
        *[Rr]yujinx*) return 1 ;;
    esac
    return 0
}

# URL do AppImage de um release do GitHub para a arquitetura DESTE host.
# Releases com várias arquiteturas listam arm64 antes de x86_64; pegar o
# primeiro baixava um binário que não executa (EmuDeck 2.7.1).
pz_emulation_release_appimage_url() {
    local api="$1" arch other
    case "$(uname -m)" in
        x86_64|amd64) arch='x86_64|amd64|x64'; other='arm64|aarch64|armhf|armv7' ;;
        aarch64|arm64) arch='arm64|aarch64'; other='x86_64|amd64|x64|armhf|armv7' ;;
        *) arch='.'; other='^$' ;;
    esac
    curl -fsSL "$api" | jq -r --arg arch "$arch" --arg other "$other" '
        [.assets[]? | select(.name | test("AppImage$"))] as $all
        | ([$all[] | select(.name | test($arch; "i"))] + [$all[] | select(.name | test($other; "i") | not)])
        | map(.browser_download_url) | first // empty'
}
