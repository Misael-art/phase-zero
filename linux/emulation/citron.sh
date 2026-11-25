#!/usr/bin/env bash
# citron.sh - install/manage Citron Switch emulator AppImage
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
CITRON_APP_NAME="${PZ_CITRON_APPIMAGE_NAME:-citron.AppImage}"
CITRON_APP="$PZ_APPLICATIONS_DIR/$CITRON_APP_NAME"
CITRON_LINK="$PZ_APPLICATIONS_DIR/Citron.AppImage"
CITRON_WRAPPER="$PZ_LOCAL_BIN/phasezero-citron"
CITRON_DESKTOP="$PZ_DESKTOP_DIR/phasezero-citron.desktop"
CITRON_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/citron"
CITRON_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/citron"
CITRON_KEYS="$CITRON_SHARE/keys"
CITRON_FIRMWARE="$CITRON_SHARE/nand/system/Contents/registered"

resolve_citron_url() {
    curl -fsSL "$PZ_CITRON_RELEASE_API" |
        jq -r '[.assets[] | objects | select(.name? | test("linux-x86_64\\.AppImage$")) | select(.name? | test("_v3") | not) | .browser_download_url] | first // empty'
}

resolve_citron_name() {
    local url
    url="$(resolve_citron_url)"
    [ -n "$url" ] && basename "$url" || echo "citron.AppImage"
}

write_citron_wrapper() {
    bash "$PZ_ROOT/linux/emulation/performance.sh" apply >/dev/null
    pz_emulation_write_file "$CITRON_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$CITRON_LINK"
performance="$PZ_LOCAL_BIN/phasezero-emulation-launch"
if [ -x "\$performance" ]; then
    exec "\$performance" switch -- "\$app" "\$@"
fi
if command -v gamemoderun >/dev/null 2>&1; then
    exec env MANGOHUD=1 gamemoderun "\$app" "\$@"
fi
exec env MANGOHUD=1 "\$app" "\$@"
EOF
}

write_citron_desktop() {
    pz_emulation_write_file "$CITRON_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Citron
Comment=Nintendo Switch emulator launcher managed by PhaseZero
Exec=$CITRON_WRAPPER %f
Terminal=false
Categories=Game;Emulator;
MimeType=application/x-nx-nsp;application/x-nx-xci;
EOF
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
}

configure_citron_dirs() {
    [ -L "$CITRON_KEYS" ] && rm -f "$CITRON_KEYS"
    [ -L "$CITRON_FIRMWARE" ] && rm -f "$CITRON_FIRMWARE"
    install -d "$CITRON_SHARE" "$CITRON_CONFIG" "$CITRON_KEYS" "$CITRON_FIRMWARE"
    jq -n \
        --arg root "$PZ_EMULATION_ROOT" \
        --arg keys "$PZ_EMULATION_ROOT/firmware/switch/keys" \
        --arg firmware "$PZ_EMULATION_ROOT/firmware/switch/firmware" \
        --arg saves "$PZ_EMULATION_ROOT/saves/switch" \
        --arg nand "$PZ_EMULATION_ROOT/state/switch/nand" \
        '{root: $root, keys: $keys, firmware: $firmware, saves: $saves, nand: $nand, policy: "user-owned-local-content-only"}' \
        > "$PZ_EMULATION_STATE/citron-layout.json"
}

sync_citron_user_content() {
    local central_keys="$PZ_EMULATION_ROOT/firmware/switch/keys"
    local central_fw="$PZ_EMULATION_ROOT/firmware/switch/firmware"
    local ryujinx r_keys r_fw
    ryujinx=$(pz_emulation_switch_ryujinx_paths)

    install -d "$(dirname "$CITRON_KEYS")" "$(dirname "$CITRON_FIRMWARE")"
    if pz_emulation_user_link "$CITRON_KEYS" || pz_emulation_user_link "$CITRON_FIRMWARE"; then
        pz_info "Citron: chaves/firmware apontam para uma pasta escolhida pelo usuário; preservado"
        return 0
    fi
    if [ -L "$CITRON_KEYS" ] || { [ -d "$CITRON_KEYS" ] && [ -z "$(ls -A "$CITRON_KEYS" 2>/dev/null)" ]; }; then
        rm -rf "$CITRON_KEYS"
    fi
    if [ -L "$CITRON_FIRMWARE" ] || { [ -d "$CITRON_FIRMWARE" ] && [ -z "$(ls -A "$CITRON_FIRMWARE" 2>/dev/null)" ]; }; then
        rm -rf "$CITRON_FIRMWARE"
    fi

    # Priority 1: the central store (firmware/switch/{keys,firmware}). Link to it
    # when it actually has content so every emulator shares one source of truth.
    if [ -f "$central_keys/prod.keys" ]; then
        ln -sfn "$central_keys" "$CITRON_KEYS"
        pz_info "Citron keys → central store"
        if [ -d "$central_fw" ] && [ -n "$(find "$central_fw" -maxdepth 1 -name '*.nca' -print -quit 2>/dev/null)" ]; then
            ln -sfn "$central_fw" "$CITRON_FIRMWARE"
            pz_info "Citron firmware → central store"
        else
            install -d "$CITRON_FIRMWARE"
        fi
        return 0
    fi

    # Priority 2: Ryujinx's own keys/firmware (when the central store is empty).
    if [ "$ryujinx" != "null" ]; then
        r_keys=$(jq -r '.keys // empty' <<< "$ryujinx")
        r_fw=$(jq -r '.firmware // empty' <<< "$ryujinx")
        if [ -n "$r_keys" ] && [ -f "$r_keys/prod.keys" ]; then
            ln -sfn "$r_keys" "$CITRON_KEYS"
            pz_info "Citron keys → symlink to Ryujinx"
        else
            install -d "$CITRON_KEYS"
        fi
        if [ -n "$r_fw" ]; then
            ln -sfn "$r_fw" "$CITRON_FIRMWARE"
            pz_info "Citron firmware → symlink to Ryujinx"
        else
            install -d "$CITRON_FIRMWARE"
        fi
        return 0
    fi

    # Priority 3: nothing to link to — leave empty dirs (emulator will prompt).
    install -d "$CITRON_KEYS" "$CITRON_FIRMWARE"
    return 0
}

install_citron() {
    if pz_emulation_foreign_install Citron "$PZ_EMULATION_STATE/citron.json" \
        --bin citron --appimage 'citron*.AppImage' --desktop-exec citron; then
        return 0
    fi
    local url name
    pz_emulation_ensure_layout
    configure_citron_dirs

    url="$(resolve_citron_url)"
    [ -n "$url" ] || { pz_error "Citron indisponível: a fonte oficial de releases não respondeu ($PZ_CITRON_RELEASE_API). Nada foi instalado; Eden é a alternativa gerenciada para Switch."; return 1; }

    name="$(basename "$url")"
    CITRON_APP="$PZ_APPLICATIONS_DIR/$name"

    pz_info "downloading Citron AppImage: $url"
    pz_emulation_download "$url" "$CITRON_APP"

    pz_emulation_safe_link "$CITRON_APP" "$CITRON_LINK"
    write_citron_wrapper
    write_citron_desktop
    sync_citron_user_content
    jq -n \
        --arg url "$url" \
        --arg name "$name" \
        --arg app "$CITRON_APP" \
        --arg sha256 "$(pz_emulation_sha256_or_empty "$CITRON_APP")" \
        --arg installedAt "$(date -Iseconds)" \
        '{source: $url, appImageName: $name, appImage: $app, sha256: $sha256, installedAt: $installedAt}' \
        > "$PZ_EMULATION_STATE/citron.json"
    pz_info "Citron installed: $CITRON_APP"
}

integrate_with_emudeck() {
    local emudeck_home="$HOME/.config/EmuDeck"
    [ -d "$emudeck_home" ] || { pz_info "EmuDeck not found, skipping integration"; return 0; }

    local emudeck_backend="$emudeck_home/backend"
    local toolsPath="$HOME/Emulation/tools"
    local storagePath="$HOME/Emulation/storage"
    local savesPath="$HOME/Emulation/saves"
    local biosPath="$HOME/Emulation/bios"
    local romsPath="$HOME/Emulation/roms"

    if [ -f "$emudeck_home/settings.sh" ]; then
        source "$emudeck_home/settings.sh" 2>/dev/null || true
    fi

    pz_info "integrating Citron with EmuDeck"

    sync_citron_user_content

    install -d "$toolsPath/launchers" 2>/dev/null || true
    if [ -f "$emudeck_backend/tools/launchers/citron.sh" ]; then
        cp "$emudeck_backend/tools/launchers/citron.sh" "$toolsPath/launchers/citron.sh"
        chmod +x "$toolsPath/launchers/citron.sh"
    fi

    if [ -d "$emudeck_backend/configs/citron/config" ]; then
        mkdir -p "$CITRON_CONFIG"
        rsync -a "$emudeck_backend/configs/citron/config/." "$CITRON_CONFIG/" 2>/dev/null || cp -r "$emudeck_backend/configs/citron/config/." "$CITRON_CONFIG/" 2>/dev/null || true
    fi
    if [ -d "$emudeck_backend/configs/citron/data" ]; then
        mkdir -p "$CITRON_SHARE"
        rsync -a "$emudeck_backend/configs/citron/data/." "$CITRON_SHARE/" 2>/dev/null || cp -r "$emudeck_backend/configs/citron/data/." "$CITRON_SHARE/" 2>/dev/null || true
    fi

    local config_file="$CITRON_CONFIG/qt-config.ini"
    if [ -f "$config_file" ]; then
        sed -i "s|^dump_directory=.*|dump_directory=${storagePath}/citron/dump|" "$config_file"
        sed -i "s|^load_directory=.*|load_directory=${storagePath}/citron/load|" "$config_file"
        sed -i "s|^nand_directory=.*|nand_directory=${storagePath}/citron/nand|" "$config_file"
        sed -i "s|^sdmc_directory=.*|sdmc_directory=${storagePath}/citron/sdmc|" "$config_file"
        sed -i "s|^tas_directory=.*|tas_directory=${storagePath}/citron/tas|" "$config_file"
        sed -i "s|^dump_directory\\\\default=.*|dump_directory\\\\default=false|" "$config_file"
        sed -i "s|^load_directory\\\\default=.*|load_directory\\\\default=false|" "$config_file"
        sed -i "s|^nand_directory\\\\default=.*|nand_directory\\\\default=false|" "$config_file"
        sed -i "s|^sdmc_directory\\\\default=.*|sdmc_directory\\\\default=false|" "$config_file"
        sed -i "s|^tas_directory\\\\default=.*|tas_directory\\\\default=false|" "$config_file"
        sed -i "s|^Paths\\\\gamedirs\\\\4\\\\path=.*|Paths\\\\gamedirs\\\\4\\\\path=${romsPath}/switch|" "$config_file"
        sed -i "s|^Screenshots\\\\screenshot_path=.*|Screenshots\\\\screenshot_path=${storagePath}/citron/screenshots|" "$config_file"
    fi

    mkdir -p "${storagePath}/citron/dump" \
             "${storagePath}/citron/load" \
             "${storagePath}/citron/sdmc" \
             "${storagePath}/citron/nand" \
             "${storagePath}/citron/screenshots" \
             "${storagePath}/citron/tas"

    mkdir -p "${savesPath}/citron" \
             "${storagePath}/citron/nand/user/save" \
             "${storagePath}/citron/nand/system/save/8000000000000010/su/avators"
    ln -snf "${storagePath}/citron/nand/user/save/" "${savesPath}/citron/saves" 2>/dev/null || true
    ln -snf "${storagePath}/citron/nand/system/save/8000000000000010/su/avators/" "${savesPath}/citron/profiles" 2>/dev/null || true
    mkdir -p "${biosPath}/citron"
    ln -snf "${CITRON_SHARE}/keys/" "${biosPath}/citron/keys" 2>/dev/null || true
    ln -snf "${CITRON_SHARE}/nand/system/Contents/registered/" "${biosPath}/citron/firmware" 2>/dev/null || true

    local es_rules="$emudeck_backend/configs/emulationstation/custom_systems/es_find_rules.xml"
    if [ -f "$es_rules" ] && ! grep -q '<emulator name="CITRON">' "$es_rules" 2>/dev/null; then
        if command -v xmlstarlet >/dev/null 2>&1; then
            # shellcheck disable=SC2016 # xmlstarlet --var literal/reference, not shell expansion
            xmlstarlet ed -S --inplace \
                -s '/ruleList' -t elem -n 'emulator' \
                --var newEmu '$prev' \
                -i '$newEmu' -t attr -n 'name' -v 'CITRON' \
                -s '$newEmu' -t elem -n 'rule' \
                --var newRule '$prev' \
                -i '$newRule' -t attr -n 'type' -v 'staticpath' \
                -s '$newRule' -t elem -n 'entry' -v "${toolsPath}/launchers/citron.sh" \
                "$es_rules" 2>/dev/null || true
        else
            sed -i "/<\/ruleList>/i\\
    <emulator name=\"CITRON\">\\
        <rule type=\"staticpath\">\\
            <entry>${toolsPath}/launchers/citron.sh</entry>\\
        </rule>\\
    </emulator>" "$es_rules"
        fi
    fi

    local srm_parsers="$emudeck_backend/configs/steam-rom-manager/userData/parsers/optional"
    if [ -d "$srm_parsers" ] && [ ! -f "$srm_parsers/nintendo_switch_citron.json" ]; then
        cp "$emudeck_backend/configs/steam-rom-manager/userData/parsers/optional/nintendo_switch_citron.json" \
           "$srm_parsers/nintendo_switch_citron.json" 2>/dev/null || true
    fi

    local alt_emu_dir="$emudeck_backend/roms_alt_emus/switch/citron"
    if [ ! -f "$alt_emu_dir/metadata.txt" ]; then
        mkdir -p "$alt_emu_dir"
        cat > "$alt_emu_dir/metadata.txt" << ALTEOF
collection: Nintendo Switch (Citron)
shortname: switch
extensions: nca, NCA, nro, NRO, nso, NSO, nsp, NSP, xci, XCI
launch: /bin/bash ${toolsPath}/launchers/citron.sh -f -g '{file.path}'
ALTEOF
    fi

    if [ -f "$emudeck_home/settings.json" ] && command -v jq >/dev/null 2>&1; then
        local tmp
        # shellcheck disable=SC2119 # mktemp default template
        tmp="$(pz_tempfile)"
        if ! jq '.android.overwriteConfigEmus.citron.status = true' "$emudeck_home/settings.json" > "$tmp" 2>/dev/null || ! mv "$tmp" "$emudeck_home/settings.json"; then
            rm -f "$tmp"
        fi
    fi

    pz_info "Citron integrated with EmuDeck"
}

dry_run_citron() {
    local name
    name="$(resolve_citron_name 2>/dev/null || echo "citron.AppImage")"
    cat <<EOF
Citron dry-run
  release API: $PZ_CITRON_RELEASE_API
  appimage:    $PZ_APPLICATIONS_DIR/$name
  link:        $CITRON_LINK
  wrapper:     $CITRON_WRAPPER
  desktop:     $CITRON_DESKTOP
  emudeck:     $([ -d "$HOME/.config/EmuDeck" ] && echo "found at $HOME/.config/EmuDeck" || echo "not installed")
EOF
}

status_citron() {
    local emudeck_installed=false emudeck_integrated=false
    local status_app="$CITRON_APP"
    if [ ! -f "$status_app" ] && [ -e "$CITRON_LINK" ]; then
        status_app="$(readlink -f "$CITRON_LINK" 2>/dev/null || echo "$CITRON_LINK")"
    fi
    if [ -d "$HOME/.config/EmuDeck" ]; then
        emudeck_installed=true
        local s
        s="$(jq -r '.android.overwriteConfigEmus.citron.status // false' "$HOME/.config/EmuDeck/settings.json" 2>/dev/null || echo false)"
        [ "$s" = "true" ] && emudeck_integrated=true
    fi
    jq -n \
        --arg url "$PZ_CITRON_RELEASE_API" \
        --arg app "$status_app" \
        --arg link "$CITRON_LINK" \
        --arg wrapper "$CITRON_WRAPPER" \
        --arg desktop "$CITRON_DESKTOP" \
        --arg share "$CITRON_SHARE" \
        --arg keys "$CITRON_KEYS" \
        --arg firmware "$CITRON_FIRMWARE" \
        --arg sha256 "$(pz_emulation_sha256_or_empty "$status_app")" \
        --argjson installed "$([ -x "$CITRON_LINK" ] && echo true || echo false)" \
        --argjson linkInstalled "$([ -x "$CITRON_LINK" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$CITRON_WRAPPER" ] && echo true || echo false)" \
        --argjson desktopInstalled "$([ -f "$CITRON_DESKTOP" ] && echo true || echo false)" \
        --argjson emudeckInstalled "$emudeck_installed" \
        --argjson emudeckIntegrated "$emudeck_integrated" \
        '{source: $url, appImage: $app, link: $link, wrapper: $wrapper, desktop: $desktop, dataDir: $share, keysDir: $keys, firmwareDir: $firmware, sha256: $sha256, installed: $installed, linkInstalled: $linkInstalled, wrapperInstalled: $wrapperInstalled, desktopInstalled: $desktopInstalled, emudeckInstalled: $emudeckInstalled, emudeckIntegrated: $emudeckIntegrated}'
}

open_citron() {
    [ -x "$CITRON_WRAPPER" ] || install_citron
    nohup "$CITRON_WRAPPER" >/dev/null 2>&1 &
    pz_info "Citron launched"
}

case "$ACTION" in
    install|update) install_citron; integrate_with_emudeck ;;
    configure) pz_emulation_ensure_layout; configure_citron_dirs; sync_citron_user_content ;;
    integrate) integrate_with_emudeck ;;
    dry-run|plan) dry_run_citron ;;
    status) status_citron ;;
    open|launch) open_citron ;;
    *) pz_error "usage: citron.sh (install|update|configure|integrate|dry-run|status|open)"; exit 1 ;;
esac
