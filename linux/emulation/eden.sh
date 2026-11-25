#!/usr/bin/env bash
# eden.sh - install/manage Eden Steam Deck AppImage launcher
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"

ACTION="${1:-status}"
EDEN_APP="$PZ_APPLICATIONS_DIR/$PZ_EDEN_APPIMAGE_NAME"
EDEN_LINK="$PZ_APPLICATIONS_DIR/Eden.AppImage"
EDEN_WRAPPER="$PZ_LOCAL_BIN/phasezero-eden"
EDEN_DESKTOP="$PZ_DESKTOP_DIR/phasezero-eden.desktop"
EDEN_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/eden"
EDEN_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/eden"
EDEN_KEYS="$EDEN_SHARE/keys"
EDEN_FIRMWARE="$EDEN_SHARE/nand/system/Contents/registered"

write_eden_wrapper() {
    bash "$PZ_ROOT/linux/emulation/performance.sh" apply >/dev/null
    pz_emulation_write_file "$EDEN_WRAPPER" 0755 <<EOF
#!/usr/bin/env bash
set -euo pipefail
app="$EDEN_LINK"
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

write_eden_desktop() {
    pz_emulation_write_file "$EDEN_DESKTOP" 0644 <<EOF
[Desktop Entry]
Type=Application
Name=Eden
Comment=Nintendo Switch emulator launcher managed by PhaseZero
Exec=$EDEN_WRAPPER %f
Terminal=false
Categories=Game;Emulator;
MimeType=application/x-nx-nsp;application/x-nx-xci;
EOF
    if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$PZ_DESKTOP_DIR" >/dev/null 2>&1 || true; fi
}

configure_eden_dirs() {
    [ -L "$EDEN_KEYS" ] && rm -f "$EDEN_KEYS"
    [ -L "$EDEN_FIRMWARE" ] && rm -f "$EDEN_FIRMWARE"
    install -d "$EDEN_SHARE" "$EDEN_CONFIG" "$EDEN_KEYS" "$EDEN_FIRMWARE"
    jq -n \
        --arg root "$PZ_EMULATION_ROOT" \
        --arg keys "$PZ_EMULATION_ROOT/firmware/switch/keys" \
        --arg firmware "$PZ_EMULATION_ROOT/firmware/switch/firmware" \
        --arg saves "$PZ_EMULATION_ROOT/saves/switch" \
        --arg nand "$PZ_EMULATION_ROOT/state/switch/nand" \
        '{root: $root, keys: $keys, firmware: $firmware, saves: $saves, nand: $nand, policy: "user-owned-local-content-only"}' \
        > "$PZ_EMULATION_STATE/eden-layout.json"
}

sync_eden_user_content() {
    local central_keys="$PZ_EMULATION_ROOT/firmware/switch/keys"
    local central_fw="$PZ_EMULATION_ROOT/firmware/switch/firmware"
    local ryujinx r_keys r_fw
    ryujinx=$(pz_emulation_switch_ryujinx_paths)

    install -d "$(dirname "$EDEN_KEYS")" "$(dirname "$EDEN_FIRMWARE")"
    if pz_emulation_user_link "$EDEN_KEYS" || pz_emulation_user_link "$EDEN_FIRMWARE"; then
        pz_info "Eden: chaves/firmware apontam para uma pasta escolhida pelo usuário; preservado"
        return 0
    fi
    # Clear any pre-existing keys/firmware path (symlink OR empty dir) so the
    # link below replaces it in place instead of creating a nested symlink.
    if [ -L "$EDEN_KEYS" ] || { [ -d "$EDEN_KEYS" ] && [ -z "$(ls -A "$EDEN_KEYS" 2>/dev/null)" ]; }; then
        rm -rf "$EDEN_KEYS"
    fi
    if [ -L "$EDEN_FIRMWARE" ] || { [ -d "$EDEN_FIRMWARE" ] && [ -z "$(ls -A "$EDEN_FIRMWARE" 2>/dev/null)" ]; }; then
        rm -rf "$EDEN_FIRMWARE"
    fi

    # Priority 1: the central store (firmware/switch/{keys,firmware}).
    if [ -f "$central_keys/prod.keys" ]; then
        ln -sfn "$central_keys" "$EDEN_KEYS"
        pz_info "Eden keys → central store"
        if [ -d "$central_fw" ] && [ -n "$(find "$central_fw" -maxdepth 1 -name '*.nca' -print -quit 2>/dev/null)" ]; then
            ln -sfn "$central_fw" "$EDEN_FIRMWARE"
            pz_info "Eden firmware → central store"
        else
            install -d "$EDEN_FIRMWARE"
        fi
        return 0
    fi

    # Priority 2: Ryujinx's own keys/firmware.
    if [ "$ryujinx" != "null" ]; then
        r_keys=$(jq -r '.keys // empty' <<< "$ryujinx")
        r_fw=$(jq -r '.firmware // empty' <<< "$ryujinx")
        if [ -n "$r_keys" ] && [ -f "$r_keys/prod.keys" ]; then
            ln -sfn "$r_keys" "$EDEN_KEYS"
            pz_info "Eden keys → symlink to Ryujinx"
        else
            install -d "$EDEN_KEYS"
        fi
        if [ -n "$r_fw" ]; then
            ln -sfn "$r_fw" "$EDEN_FIRMWARE"
            pz_info "Eden firmware → symlink to Ryujinx"
        else
            install -d "$EDEN_FIRMWARE"
        fi
        return 0
    fi

    install -d "$EDEN_KEYS" "$EDEN_FIRMWARE"
    return 0
}

install_eden() {
    if pz_emulation_foreign_install Eden "$PZ_EMULATION_STATE/eden.json" \
        --bin eden --flatpak dev.eden_emu.eden --appimage 'Eden*.AppImage' --desktop-exec eden; then
        return 0
    fi
    pz_emulation_ensure_layout
    configure_eden_dirs

    if [ -f "$EDEN_APP" ] && command -v zsync >/dev/null 2>&1; then
        pz_info "updating Eden via zsync"
        zsync -q -o "$EDEN_APP" "$PZ_EDEN_ZSYNC_URL"
        chmod +x "$EDEN_APP"
    else
        pz_info "downloading Eden AppImage: $PZ_EDEN_APPIMAGE_URL"
        pz_emulation_download "$PZ_EDEN_APPIMAGE_URL" "$EDEN_APP"
    fi

    pz_emulation_safe_link "$EDEN_APP" "$EDEN_LINK"
    write_eden_wrapper
    write_eden_desktop
    sync_eden_user_content
    jq -n \
        --arg version "$PZ_EDEN_VERSION" \
        --arg app "$EDEN_APP" \
        --arg url "$PZ_EDEN_APPIMAGE_URL" \
        --arg zsync "$PZ_EDEN_ZSYNC_URL" \
        --arg sha256 "$(pz_emulation_sha256_or_empty "$EDEN_APP")" \
        --arg installedAt "$(date -Iseconds)" \
        '{version: $version, appImage: $app, source: $url, zsync: $zsync, sha256: $sha256, installedAt: $installedAt}' \
        > "$PZ_EMULATION_STATE/eden.json"
    pz_info "Eden installed: $EDEN_APP"
}

dry_run_eden() {
    cat <<EOF
Eden dry-run
  version:    $PZ_EDEN_VERSION
  url:        $PZ_EDEN_APPIMAGE_URL
  zsync:      $PZ_EDEN_ZSYNC_URL
  appimage:   $EDEN_APP
  link:       $EDEN_LINK
  wrapper:    $EDEN_WRAPPER
  desktop:    $EDEN_DESKTOP
  emudeck:    $([ -d "$HOME/.config/EmuDeck" ] && echo "found at $HOME/.config/EmuDeck" || echo "not installed")
EOF
}

status_eden() {
    local emudeck_installed=false emudeck_integrated=false
    if [ -d "$HOME/.config/EmuDeck" ]; then
        emudeck_installed=true
        local eden_status
        eden_status="$(jq -r '.android.overwriteConfigEmus.eden.status // false' "$HOME/.config/EmuDeck/settings.json" 2>/dev/null || echo false)"
        [ "$eden_status" = "true" ] && emudeck_integrated=true
    fi
    jq -n \
        --arg version "$PZ_EDEN_VERSION" \
        --arg url "$PZ_EDEN_APPIMAGE_URL" \
        --arg app "$EDEN_APP" \
        --arg link "$EDEN_LINK" \
        --arg wrapper "$EDEN_WRAPPER" \
        --arg desktop "$EDEN_DESKTOP" \
        --arg share "$EDEN_SHARE" \
        --arg keys "$EDEN_KEYS" \
        --arg firmware "$EDEN_FIRMWARE" \
        --arg sha256 "$(pz_emulation_sha256_or_empty "$EDEN_APP")" \
        --argjson installed "$([ -x "$EDEN_APP" ] && echo true || echo false)" \
        --argjson linkInstalled "$([ -x "$EDEN_LINK" ] && echo true || echo false)" \
        --argjson wrapperInstalled "$([ -x "$EDEN_WRAPPER" ] && echo true || echo false)" \
        --argjson desktopInstalled "$([ -f "$EDEN_DESKTOP" ] && echo true || echo false)" \
        --argjson emudeckInstalled "$emudeck_installed" \
        --argjson emudeckIntegrated "$emudeck_integrated" \
        '{version: $version, source: $url, appImage: $app, link: $link, wrapper: $wrapper, desktop: $desktop, dataDir: $share, keysDir: $keys, firmwareDir: $firmware, sha256: $sha256, installed: $installed, linkInstalled: $linkInstalled, wrapperInstalled: $wrapperInstalled, desktopInstalled: $desktopInstalled, emudeckInstalled: $emudeckInstalled, emudeckIntegrated: $emudeckIntegrated}'
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

    pz_info "integrating Eden with EmuDeck"

    sync_eden_user_content

    install -d "$toolsPath/launchers" 2>/dev/null || true
    if [ -f "$emudeck_backend/tools/launchers/eden.sh" ]; then
        cp "$emudeck_backend/tools/launchers/eden.sh" "$toolsPath/launchers/eden.sh"
        chmod +x "$toolsPath/launchers/eden.sh"
    fi

    if [ -d "$emudeck_backend/configs/eden/config" ]; then
        mkdir -p "$EDEN_CONFIG"
        rsync -a "$emudeck_backend/configs/eden/config/." "$EDEN_CONFIG/" 2>/dev/null || cp -r "$emudeck_backend/configs/eden/config/." "$EDEN_CONFIG/" 2>/dev/null || true
    fi
    if [ -d "$emudeck_backend/configs/eden/data" ]; then
        mkdir -p "$EDEN_SHARE"
        rsync -a "$emudeck_backend/configs/eden/data/." "$EDEN_SHARE/" 2>/dev/null || cp -r "$emudeck_backend/configs/eden/data/." "$EDEN_SHARE/" 2>/dev/null || true
    fi

    local config_file="$EDEN_CONFIG/qt-config.ini"
    if [ -f "$config_file" ]; then
        sed -i "s|^dump_directory=.*|dump_directory=${storagePath}/eden/dump|" "$config_file"
        sed -i "s|^load_directory=.*|load_directory=${storagePath}/eden/load|" "$config_file"
        sed -i "s|^nand_directory=.*|nand_directory=${storagePath}/eden/nand|" "$config_file"
        sed -i "s|^sdmc_directory=.*|sdmc_directory=${storagePath}/eden/sdmc|" "$config_file"
        sed -i "s|^tas_directory=.*|tas_directory=${storagePath}/eden/tas|" "$config_file"
        sed -i "s|^dump_directory\\\\default=.*|dump_directory\\\\default=false|" "$config_file"
        sed -i "s|^load_directory\\\\default=.*|load_directory\\\\default=false|" "$config_file"
        sed -i "s|^nand_directory\\\\default=.*|nand_directory\\\\default=false|" "$config_file"
        sed -i "s|^sdmc_directory\\\\default=.*|sdmc_directory\\\\default=false|" "$config_file"
        sed -i "s|^tas_directory\\\\default=.*|tas_directory\\\\default=false|" "$config_file"
        sed -i "s|^Paths\\\\gamedirs\\\\4\\\\path=.*|Paths\\\\gamedirs\\\\4\\\\path=${romsPath}/switch|" "$config_file"
        sed -i "s|^Screenshots\\\\screenshot_path=.*|Screenshots\\\\screenshot_path=${storagePath}/eden/screenshots|" "$config_file"
    fi

    mkdir -p "${storagePath}/eden/dump" \
             "${storagePath}/eden/load" \
             "${storagePath}/eden/sdmc" \
             "${storagePath}/eden/nand" \
             "${storagePath}/eden/screenshots" \
             "${storagePath}/eden/tas"

    mkdir -p "${savesPath}/eden" \
             "${storagePath}/eden/nand/user/save" \
             "${storagePath}/eden/nand/system/save/8000000000000010/su/avators"
    ln -snf "${storagePath}/eden/nand/user/save/" "${savesPath}/eden/saves" 2>/dev/null || true
    ln -snf "${storagePath}/eden/nand/system/save/8000000000000010/su/avators/" "${savesPath}/eden/profiles" 2>/dev/null || true
    mkdir -p "${biosPath}/eden"
    ln -snf "${EDEN_SHARE}/keys/" "${biosPath}/eden/keys" 2>/dev/null || true
    ln -snf "${EDEN_SHARE}/nand/system/Contents/registered/" "${biosPath}/eden/firmware" 2>/dev/null || true

    local es_rules="$emudeck_backend/configs/emulationstation/custom_systems/es_find_rules.xml"
    if [ -f "$es_rules" ] && ! grep -q '<emulator name="EDEN">' "$es_rules" 2>/dev/null; then
        if command -v xmlstarlet >/dev/null 2>&1; then
            # shellcheck disable=SC2016 # literal XPath var refs for xmlstarlet ed
            xmlstarlet ed -S --inplace \
                -s '/ruleList' -t elem -n 'emulator' \
                --var newEmu '$prev' \
                -i '$newEmu' -t attr -n 'name' -v 'EDEN' \
                -s '$newEmu' -t elem -n 'rule' \
                --var newRule '$prev' \
                -i '$newRule' -t attr -n 'type' -v 'staticpath' \
                -s '$newRule' -t elem -n 'entry' -v "${toolsPath}/launchers/eden.sh" \
                "$es_rules" 2>/dev/null || true
        else
            sed -i "/<\/ruleList>/i\\
    <emulator name=\"EDEN\">\\
        <rule type=\"staticpath\">\\
            <entry>${toolsPath}/launchers/eden.sh</entry>\\
        </rule>\\
    </emulator>" "$es_rules"
        fi
    fi

    local srm_parsers="$emudeck_backend/configs/steam-rom-manager/userData/parsers/optional"
    if [ -d "$srm_parsers" ] && [ ! -f "$srm_parsers/nintendo_switch_eden.json" ]; then
        cat > "$srm_parsers/nintendo_switch_eden.json" << 'PARSER_EOF'
{
  "parserType": "Glob",
  "configTitle": "Nintendo Switch - Eden",
  "steamDirectory": "${steamdirglobal}",
  "romDirectory": "${romsdirglobal}/switch",
  "executableArgs": "vblank_mode=0 %command% -f -g \"${filePath}\"",
  "executableModifier": "\"${exePath}\"",
  "startInDirectory": "",
  "titleModifier": "${fuzzyTitle}",
  "imageProviders": ["sgdb", "steamCDN"],
  "onlineImageQueries": "${fuzzyTitle}",
  "imagePool": "${fuzzyTitle}",
  "userAccounts": { "specifiedAccounts": ["Global"] },
  "disabled": false,
  "executable": {
    "path": "__LAUNCHER_PATH__",
    "shortcutPassthrough": false,
    "appendArgsToExecutable": false
  },
  "parserInputs": {
    "glob": "${title}@(.nro|.NRO|.nsp|.NSP|.xci|.XCI)"
  },
  "titleFromVariable": {
    "limitToGroups": "",
    "caseInsensitiveVariables": false,
    "skipFileIfVariableWasNotFound": false
  },
  "fuzzyMatch": {
    "replaceDiacritics": true,
    "removeCharacters": true,
    "removeBrackets": true
  },
  "controllers": {
    "ps4": null, "ps5": null, "xbox360": null, "xboxone": null,
    "switch_joycon_left": null, "switch_joycon_right": null,
    "switch_pro": null, "neptune": null
  },
  "imageProviderAPIs": {
    "sgdb": {
      "nsfw": false, "humor": false,
      "styles": [], "stylesHero": [], "stylesLogo": [], "stylesIcon": [],
      "imageMotionTypes": ["static"]
    }
  },
  "defaultImage": { "tall": "", "long": "", "hero": "", "logo": "", "icon": "" },
  "localImages": { "tall": "", "long": "", "hero": "", "logo": "", "icon": "" },
  "steamInputEnabled": "1",
  "drmProtect": false,
  "steamCategories": ["Nintendo Switch - Eden"]
}
PARSER_EOF
        sed -i "s|__LAUNCHER_PATH__|${toolsPath}/launchers/eden.sh|g" "$srm_parsers/nintendo_switch_eden.json" 2>/dev/null || true
    fi

    local alt_emu_dir="$emudeck_backend/roms_alt_emus/switch/eden"
    if [ ! -f "$alt_emu_dir/metadata.txt" ]; then
        mkdir -p "$alt_emu_dir"
        cat > "$alt_emu_dir/metadata.txt" << ALTEOF
collection: Nintendo Switch (Eden)
shortname: switch
extensions: nca, NCA, nro, NRO, nso, NSO, nsp, NSP, xci, XCI
launch: /bin/bash ${toolsPath}/launchers/eden.sh -f -g '{file.path}'
ALTEOF
    fi

    if [ -f "$emudeck_home/settings.json" ] && command -v jq >/dev/null 2>&1; then
        local tmp
        # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
        tmp="$(pz_tempfile)"
        if jq '.android.overwriteConfigEmus.eden.status = true' "$emudeck_home/settings.json" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$emudeck_home/settings.json" || rm -f "$tmp"
        else
            rm -f "$tmp"
        fi
    fi

    pz_info "Eden integrated with EmuDeck"
}

open_eden() {
    [ -x "$EDEN_WRAPPER" ] || install_eden
    nohup "$EDEN_WRAPPER" >/dev/null 2>&1 &
    pz_info "Eden launched"
}

case "$ACTION" in
    install|update) install_eden; integrate_with_emudeck ;;
    configure) pz_emulation_ensure_layout; configure_eden_dirs; sync_eden_user_content ;;
    integrate) integrate_with_emudeck ;;
    dry-run|plan) dry_run_eden ;;
    status) status_eden ;;
    open|launch) open_eden ;;
    *) pz_error "usage: eden.sh (install|update|configure|integrate|dry-run|status|open)"; exit 1 ;;
esac
