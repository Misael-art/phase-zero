#!/usr/bin/env bash
# media.sh - manage canonical emulation media across consumers
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/emulation/common.sh"
source "$PZ_ROOT/linux/lib/json-envelope.sh"

PZ_JSON=false
PZ_APPLY=false
args=()
for arg in "$@"; do
    case "$arg" in
        --json) PZ_JSON=true ;;
        --apply) PZ_APPLY=true ;;
        *) args+=("$arg") ;;
    esac
done

ACTION="${args[0]:-status}"
PZ_MEDIA_ROOT="$PZ_EMULATION_ROOT/tools/downloaded_media"
PZ_STEAMGRID_ROOT="$PZ_EMULATION_ROOT/media/steamgrid"
PZ_MEDIA_INDEX="$PZ_EMULATION_ROOT/media/index/media-index.json"
PZ_MEDIA_INDEX_DIR="$PZ_EMULATION_ROOT/media/index"
PZ_MEDIA_INDEX_TOOL="$PZ_ROOT/linux/emulation/media-index.py"
PZ_SCAN_SAFE_ROOT="$PZ_EMULATION_ROOT/.phasezero/scan-safe/roms"
PZ_SCAN_SAFE_SWITCH="$PZ_SCAN_SAFE_ROOT/switch"
PZ_MEDIA_GAMELIST_TOOL="$PZ_ROOT/linux/emulation/media-gamelist.py"
PZ_RETRODECK_ROOT="$(pz_retrodeck_root)"
PZ_RETRODECK_FLATPAK_ESDE_SETTINGS="${PZ_RETRODECK_FLATPAK_ESDE_SETTINGS:-$HOME/.var/app/net.retrodeck.retrodeck/config/ES-DE/settings/es_settings.xml}"
PZ_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
PZ_XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
PZ_XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

pz_media_esde_types() {
    cat <<TYPES
3dboxes
backcovers
covers
custom
fanart
manuals
marquees
miximages
physicalmedia
screenshots
titlescreens
videos
TYPES
}

pz_media_compat_aliases() {
    cat <<ALIASES
cover|covers
box2dfront|covers
box2dback|backcovers
miximage|miximages
ALIASES
}

pz_media_index_init() {
    install -d "$PZ_MEDIA_INDEX_DIR"
    if [ ! -f "$PZ_MEDIA_INDEX" ]; then
        jq -n '{version: 1, generated: "", systems: {}, stats: {roms_indexed: 0, media_files: 0}}' > "$PZ_MEDIA_INDEX"
    fi
}

pz_media_esde_settings() {
    pz_media_esde_settings_paths | head -n 1
}

pz_media_esde_settings_paths() {
    local path
    {
        pz_retrodeck_esde_settings
        for path in \
        "$PZ_RETRODECK_ROOT/ES-DE/settings/es_settings.xml" \
        "$HOME/ES-DE/settings/es_settings.xml" \
        "$HOME/.emulationstation/es_settings.xml" \
        "$PZ_XDG_CONFIG_HOME/emulationstation/es_settings.xml"; do
            [ -f "$path" ] && printf '%s\n' "$path"
        done
    } | awk '!seen[$0]++'
}

pz_media_get_esde_string() {
    local file="$1" name="$2"
    sed -n 's|.*<string name="'"$name"'" value="\([^"]*\)".*|\1|p' "$file" 2>/dev/null | head -n 1
}

pz_media_set_esde_string() {
    local file="$1" name="$2" value="$3"
    local current
    current="$(pz_media_get_esde_string "$file" "$name")"
    [ "$current" = "$value" ] && return 0

    if grep -q 'name="'"$name"'"' "$file" 2>/dev/null; then
        if command -v xmlstarlet &>/dev/null && \
            xmlstarlet ed -L -u '//string[@name="'"$name"'"]/@value' -v "$value" "$file" 2>/dev/null; then
            return 0
        fi
        sed -i 's|<string name="'"$name"'" value="[^"]*"|<string name="'"$name"'" value="'"$value"'"|g' "$file"
    elif grep -q '</config>' "$file" 2>/dev/null; then
        sed -i '/<\/config>/i\    <string name="'"$name"'" value="'"$value"'" />' "$file"
    else
        printf '    <string name="%s" value="%s" />\n' "$name" "$value" >> "$file"
    fi
}

pz_media_retrodeck_esde_media_dir() {
    pz_retrodeck_path downloaded_media_path ES-DE/downloaded_media
}

pz_media_is_retrodeck_esde_settings() {
    local file="$1"
    case "$file" in
        "$HOME/.var/app/$PZ_RETRODECK_APP_ID/"*) return 0 ;;
        *) return 1 ;;
    esac
}

pz_media_expected_esde_media() {
    local file="$1"
    if pz_media_is_retrodeck_esde_settings "$file"; then
        pz_media_retrodeck_esde_media_dir
    else
        printf '%s\n' "$PZ_MEDIA_ROOT"
    fi
}

pz_media_expected_esde_roms() {
    local file="$1"
    if pz_media_is_retrodeck_esde_settings "$file"; then
        pz_retrodeck_path roms_path roms
    else
        printf '%s/roms\n' "$PZ_EMULATION_ROOT"
    fi
}

pz_media_link_retrodeck() {
    local media_path status files=0 backup
    media_path="$(pz_media_retrodeck_esde_media_dir)"
    status="$(pz_media_link_status "$PZ_MEDIA_ROOT" "$media_path")"
    [ "$status" = "linked" ] && return 0

    install -d "$PZ_MEDIA_ROOT" "$PZ_EMULATION_ROOT/.phasezero/backups"
    backup="$PZ_EMULATION_ROOT/.phasezero/backups/retrodeck-downloaded_media-$(date +%s)-$$"
    case "$status" in
        dir)
            files="$(pz_emulation_count_files "$media_path")"
            if [ "$files" -gt 0 ]; then
                pz_info "migrating RetroDECK downloaded_media: $files file(s)"
                if command -v rsync >/dev/null 2>&1; then
                    rsync --ignore-existing -a "$media_path/" "$PZ_MEDIA_ROOT/"
                else
                    cp -an "$media_path/." "$PZ_MEDIA_ROOT/"
                fi
            fi
            install -d "$backup"
            mv "$media_path" "$backup/original"
            pz_info "backup: $backup/original"
            ;;
        wrong-link|file)
            install -d "$backup"
            mv "$media_path" "$backup/original"
            pz_warn "noncanonical RetroDECK downloaded_media backed up"
            ;;
    esac
    install -d "$(dirname "$media_path")"
    ln -s "$PZ_MEDIA_ROOT" "$media_path"
    pz_info "linked RetroDECK downloaded_media -> $PZ_MEDIA_ROOT"
}

pz_media_srm_settings_path() {
    local srm_settings="$PZ_XDG_CONFIG_HOME/steam-rom-manager/userData/userSettings.json"
    [ -f "$srm_settings" ] && echo "$srm_settings" || echo ""
}

pz_media_ignored_rom_dirs() {
    # Documentation/reference list of Switch subfolders excluded from rom
    # scanning. The live exclusion uses noload.txt markers (applied to every
    # immediate subdir of roms/switch) + the scan-safe symlink view, so this
    # list is advisory — keep it aligned with the real folder names.
    cat <<DIRS
Nintendo Switch (Update)
Nintendo Switch (DLC)
Torrent
Mods
Firmware
_backup
DIRS
}

pz_media_switch_primary_file() {
    local path="$1" name lower title_id
    name="$(basename "$path")"
    lower="${name,,}"
    case "$lower" in
        *"[dlc"*|*"_dlc"*|*" dlc"*|*"[update"*|*"_update"*|*" update"*) return 1 ;;
    esac
    title_id="$(printf '%s\n' "$name" | sed -n 's/.*\[\([[:xdigit:]]\{16\}\)\].*/\1/p' | tail -n 1)"
    if [ -n "$title_id" ] && [ "${title_id: -3}" != "000" ]; then
        return 1
    fi
    return 0
}

pz_media_switch_candidate_files() {
    local sysdir="$1"
    find "$sysdir" -type f \
        \( -iname '*.nsp' -o -iname '*.nsz' -o -iname '*.xci' -o -iname '*.nro' \) \
        -print0 2>/dev/null | sort -z
}

pz_media_switch_primary_files() {
    local sysdir="$1" path
    while IFS= read -r -d '' path; do
        [ "$(dirname "$path")" = "$sysdir" ] || continue
        pz_media_switch_primary_file "$path" && printf '%s\0' "$path"
    done < <(pz_media_switch_candidate_files "$sysdir")
}

pz_media_steam_aux_dir() {
    local name="${1,,}"
    case "$name" in
        .phasezero*|media|metadata|tools|cache|caches|patches|updates|update|dlc|mods|saves|screenshots|videos|covers|manuals|backups|temp|tmp|lost+found)
            return 0
            ;;
        *) return 1 ;;
    esac
}

pz_media_ignored_rom_paths() {
    local sysdir="$1" sys path rel dir
    sys="$(pz_media_system_name "$sysdir")"
    case "$sys" in
        switch)
            while IFS= read -r -d '' path; do
                if [ "$(dirname "$path")" != "$sysdir" ] || ! pz_media_switch_primary_file "$path"; then
                    rel="${path#"$sysdir"/}"
                    printf '%s\n' "$rel"
                fi
            done < <(pz_media_switch_candidate_files "$sysdir")
            ;;
        steam)
            while IFS= read -r -d '' dir; do
                pz_media_steam_aux_dir "$(basename "$dir")" && printf '%s\n' "$(basename "$dir")"
            done < <(find "$sysdir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
            find "$sysdir" -mindepth 3 -type f \
                \( -iname '*.sh' -o -iname '*.desktop' -o -iname '*.exe' -o -iname '*.zip' \) \
                -printf '%P\n' 2>/dev/null
            ;;
        xbox360)
            for dir in patches content cache cache0 cache1; do
                [ -e "$sysdir/$dir" ] && printf '%s\n' "$dir"
            done
            ;;
        ps3)
            [ -e "$sysdir/pkg" ] && printf '%s\n' "pkg"
            ;;
        ps4)
            for dir in pkg dlc updates update patches cache; do
                [ -e "$sysdir/$dir" ] && printf '%s\n' "$dir"
            done
            ;;
    esac
    return 0
}

pz_media_system_dirs() {
    find "$PZ_EMULATION_ROOT/roms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

pz_media_system_name() {
    local path="$1"
    basename "$path"
}

pz_media_emit_file_entry() {
    local sysdir="$1" path="$2" stem rel
    stem="$(basename "${path%.*}")"
    rel="${path#"$sysdir"/}"
    printf '%s\t%s\tfile\n' "$stem" "$rel"
}

pz_media_rom_entries() {
    local sysdir="$1" sys path dir stem rel marker
    sys="$(pz_media_system_name "$sysdir")"
    case "$sys" in
        switch)
            while IFS= read -r -d '' path; do
                pz_media_emit_file_entry "$sysdir" "$path"
            done < <(pz_media_switch_primary_files "$sysdir")
            ;;
        steam)
            while IFS= read -r -d '' dir; do
                stem="$(basename "$dir")"
                pz_media_steam_aux_dir "$stem" && continue
                printf '%s\t%s\tfolder\n' "$stem" "$stem"
            done < <(find "$sysdir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
            ;;
        xbox360)
            dir="$sysdir/roms"
            [ -d "$dir" ] || return 0
            while IFS= read -r -d '' path; do
                pz_media_emit_file_entry "$sysdir" "$path"
            done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \
                \( -iname '*.iso' -o -iname '*.xex' -o -iname '*.zar' \) -print0 2>/dev/null | sort -z)
            while IFS= read -r -d '' path; do
                marker="$(find "$path" -maxdepth 3 -type f -iname 'default.xex' -print -quit 2>/dev/null)"
                [ -n "$marker" ] || continue
                stem="$(basename "$path")"
                rel="${path#"$sysdir"/}"
                printf '%s\t%s\tfolder\n' "$stem" "$rel"
            done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d ! -iname xbla -print0 2>/dev/null | sort -z)
            ;;
        ps3)
            while IFS= read -r -d '' path; do
                pz_media_emit_file_entry "$sysdir" "$path"
            done < <(find "$sysdir" -mindepth 1 -maxdepth 1 -type f \
                \( -iname '*.iso' -o -iname '*.chd' \) -print0 2>/dev/null | sort -z)
            while IFS= read -r -d '' path; do
                if [ -f "$path/PS3_GAME/PARAM.SFO" ] || [ -f "$path/PS3_GAME/USRDIR/EBOOT.BIN" ]; then
                    stem="$(basename "$path")"
                    printf '%s\t%s\tfolder\n' "$stem" "$stem"
                fi
            done < <(find "$sysdir" -mindepth 1 -maxdepth 1 -type d ! -iname pkg -print0 2>/dev/null | sort -z)
            ;;
        ps4)
            if [ -d "$sysdir/shortcuts" ]; then
                while IFS= read -r -d '' path; do
                    pz_media_emit_file_entry "$sysdir" "$path"
                done < <(find "$sysdir/shortcuts" -mindepth 1 -maxdepth 1 -type f -iname '*.desktop' -print0 2>/dev/null | sort -z)
            fi
            while IFS= read -r -d '' path; do
                if [ -f "$path/eboot.bin" ] || [ -f "$path/sce_sys/param.sfo" ]; then
                    stem="$(basename "$path")"
                    printf '%s\t%s\tfolder\n' "$stem" "$stem"
                fi
            done < <(find "$sysdir" -mindepth 1 -maxdepth 1 -type d ! -iname shortcuts ! -iname pkg -print0 2>/dev/null | sort -z)
            ;;
        *)
            find "$sysdir" \
                -type d -exec test -e '{}/noload.txt' \; -prune -o \
                -type f \( -iname '*.chd' -o -iname '*.iso' -o -iname '*.bin' -o -iname '*.cue' -o -iname '*.rvz' -o -iname '*.gcm' -o -iname '*.wbfs' -o -iname '*.wux' -o -iname '*.nds' -o -iname '*.gba' -o -iname '*.gb' -o -iname '*.gbc' -o -iname '*.nes' -o -iname '*.sfc' -o -iname '*.smc' -o -iname '*.n64' -o -iname '*.z64' -o -iname '*.v64' -o -iname '*.psv' -o -iname '*.pbp' -o -iname '*.7z' -o -iname '*.zip' -o -iname '*.m3u' \) \
                -print0 2>/dev/null |
                while IFS= read -r -d '' path; do
                    pz_media_emit_file_entry "$sysdir" "$path"
                done
            ;;
    esac
}

pz_media_write_noload() {
    local dir="$1"
    local marker="$dir/noload.txt"
    [ -d "$dir" ] || return 0
    [ -e "$marker" ] && return 0
    printf '%s\n' "Managed by PhaseZero: skip auxiliary subtree during ES-DE scans." > "$marker"
}

pz_media_apply_scan_markers() {
    local root="$PZ_EMULATION_ROOT/roms" dir
    # Heal stale markers: a noload.txt sitting directly in a system root
    # (roms/<system>/noload.txt) makes ES-DE skip the ENTIRE system ("Not
    # populating system ... as a noload.txt file is present"). The marker is only
    # ever meant for auxiliary SUBtrees, so remove any that landed on a system
    # root (e.g. a legacy switch-root marker that hid all Switch games).
    find "$root" -mindepth 2 -maxdepth 2 -name noload.txt -delete 2>/dev/null || true
    if [ -d "$root/switch" ]; then
        while IFS= read -r -d '' dir; do pz_media_write_noload "$dir"; done \
            < <(find "$root/switch" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
    if [ -d "$root/steam" ]; then
        while IFS= read -r -d '' dir; do
            pz_media_steam_aux_dir "$(basename "$dir")" && pz_media_write_noload "$dir"
        done < <(find "$root/steam" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
        while IFS= read -r -d '' dir; do pz_media_write_noload "$dir"; done \
            < <(find "$root/steam" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)
    fi
    for dir in \
        "$root/xbox360/patches" "$root/xbox360/content" "$root/xbox360/cache" \
        "$root/xbox360/cache0" "$root/xbox360/cache1" "$root/ps3/pkg" \
        "$root/ps4/pkg" "$root/ps4/dlc" "$root/ps4/updates" \
        "$root/ps4/update" "$root/ps4/patches" "$root/ps4/cache"; do
        pz_media_write_noload "$dir"
    done
}

pz_media_build_switch_view() {
    local source="$PZ_EMULATION_ROOT/roms/switch" tmp path count=0
    install -d "$PZ_SCAN_SAFE_ROOT"
    tmp="$PZ_SCAN_SAFE_ROOT/.switch.$$"
    rm -rf "$tmp"
    install -d "$tmp"
    if [ -d "$source" ]; then
        while IFS= read -r -d '' path; do
            ln -s "$path" "$tmp/$(basename "$path")"
            count=$((count + 1))
        done < <(pz_media_switch_primary_files "$source")
    fi
    printf '%s\n' "Managed by PhaseZero. Generated; do not add ROMs here." > "$tmp/.phasezero-managed"
    rm -rf "$PZ_SCAN_SAFE_SWITCH"
    mv "$tmp" "$PZ_SCAN_SAFE_SWITCH"
    pz_info "Switch scan-safe view: $count primary game(s)"
}

pz_media_ryujinx_configs() {
    local path
    for path in \
        "$PZ_XDG_CONFIG_HOME/Ryujinx/Config.json" \
        "$PZ_XDG_CONFIG_HOME/ryujinx/Config.json" \
        "$HOME/.var/app/org.ryujinx.Ryujinx/config/Ryujinx/Config.json"; do
        [ -f "$path" ] && printf '%s\n' "$path"
    done | awk '!seen[$0]++'
}

pz_media_configure_ryujinx() {
    local config tmp source="$PZ_EMULATION_ROOT/roms/switch"
    while IFS= read -r config; do
        [ -n "$config" ] || continue
        jq -e '.game_dirs | type == "array"' "$config" >/dev/null 2>&1 || {
            pz_warn "Ryujinx config ignored; invalid game_dirs: $config"
            continue
        }
        # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
        tmp="$(pz_tempfile)"
        jq --arg source "$source" --arg view "$PZ_SCAN_SAFE_SWITCH" \
            '.game_dirs = (((.game_dirs // []) |
                map(select(. == $view or ((startswith($source + "/") | not) and . != $source))) |
                map(select((ascii_downcase | test("/(nintendo switch \\(update\\)|nintendo switch \\(dlc\\)|mods?|firmware|_backup|torrent)(/|$)")) | not))
            ) + [$view] | unique)' \
            "$config" > "$tmp"
        if ! cmp -s "$config" "$tmp"; then
            cp "$config" "$config.phasezero.bak"
            mv "$tmp" "$config"
            pz_info "Ryujinx game_dirs -> $PZ_SCAN_SAFE_SWITCH"
        else
            rm -f "$tmp"
        fi
    done < <(pz_media_ryujinx_configs)
}

pz_media_esde_gamelists() {
    local path
    for path in \
        "$HOME/ES-DE/gamelists/switch/gamelist.xml" \
        "$HOME/.emulationstation/gamelists/switch/gamelist.xml" \
        "$PZ_XDG_CONFIG_HOME/emulationstation/gamelists/switch/gamelist.xml" \
        "$PZ_EMULATION_ROOT/metadata/gamelists/switch/gamelist.xml" \
        "$PZ_RETRODECK_ROOT/ES-DE/gamelists/switch/gamelist.xml"; do
        [ -f "$path" ] && printf '%s\n' "$path"
    done | awk '!seen[$0]++'
}

pz_media_apply_esde_exclusions() {
    local sysdir="$PZ_EMULATION_ROOT/roms/switch" ignored gamelist changed error_log
    [ -d "$sysdir" ] || return 0
    [ -f "$PZ_MEDIA_GAMELIST_TOOL" ] || return 0
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    ignored="$(pz_tempfile)"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    error_log="$(pz_tempfile)"
    pz_media_ignored_rom_paths "$sysdir" > "$ignored"
    while IFS= read -r gamelist; do
        [ -n "$gamelist" ] || continue
        if ! changed="$(python3 "$PZ_MEDIA_GAMELIST_TOOL" --gamelist "$gamelist" --ignored-file "$ignored" 2>"$error_log")"; then
            pz_warn "ES-DE gamelist invalid; exclusions skipped: $gamelist"
            continue
        fi
        [ "${changed:-0}" -gt 0 ] && pz_info "ES-DE excluded $changed auxiliary Switch entry(s): $gamelist"
    done < <(pz_media_esde_gamelists)
    rm -f "$ignored" "$error_log"
}

pz_media_prepare_scan_policy() {
    pz_media_apply_scan_markers
    pz_media_build_switch_view
    pz_media_configure_ryujinx
    pz_media_apply_esde_exclusions
}

pz_media_abort_if_scanner_running() {
    [ "${PZ_EMULATION_FORCE_APPLY:-0}" = "1" ] && return 0
    local running
    running="$(pgrep -a -f '(/| )(Ryujinx|ryujinx|steam-rom-manager|Steam-ROM-Manager)( |$)' 2>/dev/null || true)"
    if [ -n "$running" ]; then
        pz_error "media scanner running; close Ryujinx/Steam ROM Manager before apply/repair or set PZ_EMULATION_FORCE_APPLY=1"
        printf '%s\n' "$running" >&2
        return 2
    fi
}

pz_media_emulator_links() {
    cat <<LINKS
duckstation|covers|$PZ_MEDIA_ROOT/psx/covers|$PZ_XDG_DATA_HOME/duckstation/covers
duckstation|screenshots|$PZ_MEDIA_ROOT/psx/screenshots|$PZ_XDG_DATA_HOME/duckstation/screenshots
pcsx2|covers|$PZ_MEDIA_ROOT/ps2/covers|$PZ_EMULATION_ROOT/storage/pcsx2/covers
pcsx2|screenshots|$PZ_MEDIA_ROOT/ps2/screenshots|$PZ_EMULATION_ROOT/storage/pcsx2/snaps
dolphin|covers|$PZ_MEDIA_ROOT/dolphin/covers|$PZ_XDG_CACHE_HOME/dolphin-emu/GameCovers
dolphin|screenshots|$PZ_MEDIA_ROOT/dolphin/screenshots|$PZ_XDG_DATA_HOME/dolphin-emu/ScreenShots
retroarch|thumbnails|$PZ_MEDIA_ROOT/retroarch/thumbnails|$PZ_XDG_CONFIG_HOME/retroarch/thumbnails
ppsspp|screenshots|$PZ_MEDIA_ROOT/psp/screenshots|$PZ_XDG_CONFIG_HOME/ppsspp/PSP/SCREENSHOT
rpcs3|screenshots|$PZ_MEDIA_ROOT/ps3/screenshots|$PZ_XDG_CONFIG_HOME/rpcs3/screenshots
LINKS
    # Flatpak emulators store config under ~/.var/app/<id>/... instead of the
    # native XDG paths above, so their media dirs were never linked to canonical
    # (e.g. flatpak RetroArch showed no box art while ES-DE/frontends had media).
    if [ -d "$HOME/.var/app/org.libretro.RetroArch/config/retroarch" ]; then
        printf 'retroarch|thumbnails|%s|%s\n' \
            "$PZ_MEDIA_ROOT/retroarch/thumbnails" \
            "$HOME/.var/app/org.libretro.RetroArch/config/retroarch/thumbnails"
    fi
    if [ -d "$HOME/.var/app/org.duckstation.DuckStation/config/duckstation" ]; then
        printf 'duckstation|covers|%s|%s\n' \
            "$PZ_MEDIA_ROOT/psx/covers" \
            "$HOME/.var/app/org.duckstation.DuckStation/config/duckstation/covers"
    fi
    if [ -d "$HOME/.var/app/net.pcsx2.PCSX2/config/PCSX2" ]; then
        printf 'pcsx2|covers|%s|%s\n' \
            "$PZ_MEDIA_ROOT/ps2/covers" \
            "$HOME/.var/app/net.pcsx2.PCSX2/config/PCSX2/covers"
    fi
}

pz_media_link_status() {
    local target="$1" link="$2"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
        echo "linked"
    elif [ -L "$link" ]; then
        echo "wrong-link"
    elif [ -d "$link" ]; then
        echo "dir"
    elif [ -e "$link" ]; then
        echo "file"
    else
        echo "missing"
    fi
}

pz_media_link_dir() {
    local owner="$1" kind="$2" target="$3" link="$4" mode="${5:-apply}"
    install -d "$target" "$PZ_EMULATION_ROOT/.phasezero/backups"
    local status; status="$(pz_media_link_status "$target" "$link")"
    case "$status" in
        linked)
            return 0
            ;;
        dir)
            local has_content=false
            [ "$(find "$link" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ] && has_content=true
            if $has_content; then
                pz_info "migrating $owner $kind media -> canonical..."
                rsync --ignore-existing -a "$link/" "$target/"
            fi
            local safe_owner safe_kind bak
            safe_owner="$(echo "$owner" | tr -c 'A-Za-z0-9_.-' '_')"
            safe_kind="$(echo "$kind" | tr -c 'A-Za-z0-9_.-' '_')"
            bak="$PZ_EMULATION_ROOT/.phasezero/backups/media-${safe_owner}-${safe_kind}-$(date +%s)"
            install -d "$bak"
            mv "$link" "$bak/original"
            pz_info "backed up $owner $kind media -> $bak"
            ;;
        wrong-link|file)
            local bak="$PZ_EMULATION_ROOT/.phasezero/backups/media-${owner}-${kind}-$(date +%s)"
            install -d "$bak"
            mv "$link" "$bak/original"
            pz_warn "backed up noncanonical $owner $kind path -> $bak"
            ;;
    esac
    install -d "$(dirname "$link")"
    ln -sfn "$target" "$link"
    pz_info "$mode $owner $kind media -> $target"
}

pz_media_apply_emulator_links() {
    local owner kind target link
    while IFS='|' read -r owner kind target link; do
        [ -z "$owner" ] && continue
        pz_media_link_dir "$owner" "$kind" "$target" "$link" "linked"
    done < <(pz_media_emulator_links)
}

pz_media_print_emulator_link_status() {
    local owner kind target link status
    while IFS='|' read -r owner kind target link; do
        [ -z "$owner" ] && continue
        status="$(pz_media_link_status "$target" "$link")"
        printf "  %-12s %-12s %-10s -> %s\n" "$owner" "$kind" "[$status]" "$target"
    done < <(pz_media_emulator_links)
}

pz_media_find_esde_media() {
    local sys="$1" stem="$2"
    local mdir="$PZ_MEDIA_ROOT/$sys"
    local result="{}"
    [ -d "$mdir" ] || { echo "$result"; return 0; }
    for type in $(pz_media_esde_types); do
        local tdir="$mdir/$type"
        [ -d "$tdir" ] || continue
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$(basename "$f")")
        done < <(find "$tdir" -maxdepth 1 -type f -iname "${stem}.*" -print0 2>/dev/null)
        if [ "${#files[@]}" -gt 0 ]; then
            local arr; arr="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
            result="$(echo "$result" | jq --arg t "$type" --argjson v "$arr" '. + {($t): $v}')"
        fi
    done
    echo "$result"
}

pz_media_find_steamgrid_media() {
    local sys="$1" stem="$2"
    local sdir="$PZ_STEAMGRID_ROOT/$sys"
    local result="{}"
    [ -d "$sdir" ] || { echo "$result"; return 0; }
    for type in grid hero logo icon; do
        local tdir="$sdir/$type"
        [ -d "$tdir" ] || continue
        local files=()
        while IFS= read -r -d '' f; do
            files+=("$(basename "$f")")
        done < <(find "$tdir" -maxdepth 1 -type f -iname "${stem}.*" -print0 2>/dev/null)
        if [ "${#files[@]}" -gt 0 ]; then
            local arr; arr="$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)"
            result="$(echo "$result" | jq --arg t "$type" --argjson v "$arr" '. + {($t): $v}')"
        fi
    done
    echo "$result"
}

cmd_status() {
    local ret=0
    echo "=== Emulation Media Status ==="

    local dm_count=0
    [ -d "$PZ_MEDIA_ROOT" ] && dm_count="$(find "$PZ_MEDIA_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "  downloaded_media: $dm_count files"

    local sg_count=0
    [ -d "$PZ_STEAMGRID_ROOT" ] && sg_count="$(find "$PZ_STEAMGRID_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "  steamgrid media: $sg_count files"

    local index_exists=false
    [ -f "$PZ_MEDIA_INDEX" ] && index_exists=true
    echo "  media-index.json: $index_exists"

    local switch_games=0 switch_view_games=0
    [ -d "$PZ_EMULATION_ROOT/roms/switch" ] && \
        switch_games="$(pz_media_switch_primary_files "$PZ_EMULATION_ROOT/roms/switch" | tr -cd '\0' | wc -c | tr -d ' ')"
    [ -d "$PZ_SCAN_SAFE_SWITCH" ] && \
        switch_view_games="$(find "$PZ_SCAN_SAFE_SWITCH" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Switch scan-safe view: $switch_view_games/$switch_games primary games"
    [ "$switch_view_games" -ne "$switch_games" ] && ret=1

    local ryujinx_config ryujinx_found=false
    while IFS= read -r ryujinx_config; do
        [ -n "$ryujinx_config" ] || continue
        ryujinx_found=true
        if jq -e --arg view "$PZ_SCAN_SAFE_SWITCH" --arg source "$PZ_EMULATION_ROOT/roms/switch" \
            '(.game_dirs | index($view)) != null and ((.game_dirs | index($source)) == null)' \
            "$ryujinx_config" >/dev/null 2>&1; then
            echo "  Ryujinx game dir: scan-safe ($ryujinx_config)"
        else
            echo "  Ryujinx game dir: raw/unmanaged ($ryujinx_config)"
            ret=1
        fi
    done < <(pz_media_ryujinx_configs)
    $ryujinx_found || echo "  Ryujinx config: not found"

    local esde_found=false esde_config
    while IFS= read -r esde_config; do
        [ -z "$esde_config" ] && continue
        esde_found=true
        local current_media current_rom expected_media expected_rom
        current_media="$(pz_media_get_esde_string "$esde_config" "MediaDirectory")"
        current_rom="$(pz_media_get_esde_string "$esde_config" "ROMDirectory")"
        expected_media="$(pz_media_expected_esde_media "$esde_config")"
        expected_rom="$(pz_media_expected_esde_roms "$esde_config")"
        if [ "$current_media" = "$expected_media" ]; then
            echo "  ES-DE media dir: correctly exposed [$expected_media] ($esde_config)"
        elif [ -n "$current_media" ]; then
            echo "  ES-DE media dir: [$current_media] expected [$expected_media] ($esde_config)"
            ret=1
        else
            echo "  ES-DE media dir: not set in config ($esde_config)"
            ret=1
        fi
        if [ "$current_rom" = "$expected_rom" ]; then
            echo "  ES-DE ROM dir: correctly exposed [$expected_rom] ($esde_config)"
        elif [ -n "$current_rom" ]; then
            echo "  ES-DE ROM dir: [$current_rom] expected [$expected_rom] ($esde_config)"
            ret=1
        else
            echo "  ES-DE ROM dir: not set in config ($esde_config)"
            ret=1
        fi
    done < <(pz_media_esde_settings_paths)
    if ! $esde_found; then
        echo "  ES-DE settings: not found"
    fi

    echo "  compat aliases:"
    while IFS='|' read -r alias target; do
        [ -z "$alias" ] && continue
        for sys_dir in "$PZ_MEDIA_ROOT"/*/; do
            [ -d "$sys_dir" ] || continue
            sys_dir="${sys_dir%/}"
            local tdir="$sys_dir/$target"
            [ -d "$tdir" ] || continue
            local alias_path="$sys_dir/$alias"
            if [ -L "$alias_path" ] && [ "$(readlink "$alias_path")" = "$tdir" ]; then
                printf "    %-20s -> %s (ok)\n" "$(basename "$sys_dir")/$alias" "$target"
            elif [ -e "$alias_path" ]; then
                printf "    %-20s -> %s (exists, not symlink - conflict)\n" "$(basename "$sys_dir")/$alias" "$target"
                ret=1
            fi
        done
    done < <(pz_media_compat_aliases)

    local srm_settings; srm_settings="$(pz_media_srm_settings_path)"
    if [ -n "$srm_settings" ]; then
        local srm_media=""
        srm_media="$(jq -r '.environmentVariables.localImagesDirectory // ""' "$srm_settings" 2>/dev/null || true)"
        if [ "$srm_media" = "$PZ_STEAMGRID_ROOT" ]; then
            echo "  SRM localImagesDirectory: correctly pointed"
        elif [ -n "$srm_media" ]; then
            echo "  SRM localImagesDirectory: $srm_media (not canonical)"
            ret=1
        else
            echo "  SRM localImagesDirectory: not set"
        fi
    fi

    echo "  emulator media links:"
    pz_media_print_emulator_link_status

    local retrodeck_media retrodeck_media_status
    retrodeck_media="$(pz_media_retrodeck_esde_media_dir)"
    retrodeck_media_status="$(pz_media_link_status "$PZ_MEDIA_ROOT" "$retrodeck_media")"
    echo "  RetroDECK downloaded_media: [$retrodeck_media_status] $retrodeck_media -> $PZ_MEDIA_ROOT"
    [ "$retrodeck_media_status" != "linked" ] && ret=1

    # Drift is a reported state, not a tool failure (text mode now matches the
    # --json envelope, which already returns 0). The plan command heals it.
    if [ "$ret" -ne 0 ]; then
        echo "  next: run 'pz emulation media apply --plan' to converge divergent paths"
    fi
    return 0
}

cmd_index() {
    echo "=== Media Index ==="
    pz_media_index_init
    [ -f "$PZ_MEDIA_INDEX_TOOL" ] || {
        pz_error "media index tool missing: $PZ_MEDIA_INDEX_TOOL"
        return 1
    }

    local records ignored output sys_dir sys stem relative_path entry_kind ignored_count
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    records="$(pz_tempfile)"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    ignored="$(pz_tempfile)"
    # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
    output="$(pz_tempfile)"

    while IFS= read -r sys_dir; do
        [ -n "$sys_dir" ] || continue
        sys="$(pz_media_system_name "$sys_dir")"
        ignored_count="$(pz_media_ignored_rom_paths "$sys_dir" | sed '/^$/d' | wc -l | tr -d ' ')"
        printf '%s\0%s\0' "$sys" "$ignored_count" >> "$ignored"
        while IFS=$'\t' read -r stem relative_path entry_kind; do
            [ -n "$stem" ] || continue
            printf '%s\0%s\0%s\0%s\0' "$sys" "$stem" "$relative_path" "$entry_kind" >> "$records"
        done < <(pz_media_rom_entries "$sys_dir" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2)
    done < <(pz_media_system_dirs)

    python3 "$PZ_MEDIA_INDEX_TOOL" \
        --records "$records" \
        --ignored "$ignored" \
        --media-root "$PZ_MEDIA_ROOT" \
        --steamgrid-root "$PZ_STEAMGRID_ROOT" \
        --output "$output"
    jq empty "$output"
    mv "$output" "$PZ_MEDIA_INDEX"
    rm -f "$records" "$ignored"

    local total_roms total_ignored total_media
    total_roms="$(jq -r '.stats.roms_indexed' "$PZ_MEDIA_INDEX")"
    total_ignored="$(jq -r '.stats.roms_ignored' "$PZ_MEDIA_INDEX")"
    total_media="$(jq -r '.stats.media_files' "$PZ_MEDIA_INDEX")"
    pz_info "index written: $PZ_MEDIA_INDEX ($total_roms games, $total_ignored ignored, $total_media media files)"
}

cmd_plan() {
    echo "=== Media Plan (dry-run) ==="
    echo "  rebuild Switch scan-safe view: $PZ_SCAN_SAFE_SWITCH"
    echo "  mark auxiliary ES-DE/RetroDECK subtrees with noload.txt"
    echo "  exclude Switch updates/DLC from ES-DE multi-scraper"
    while IFS= read -r ryujinx_config; do
        [ -n "$ryujinx_config" ] && echo "  point Ryujinx game_dirs to scan-safe view: $ryujinx_config"
    done < <(pz_media_ryujinx_configs)

    if [ ! -d "$PZ_MEDIA_ROOT" ]; then
        echo "  create downloaded_media: $PZ_MEDIA_ROOT"
    else
        local dc; dc="$(find "$PZ_MEDIA_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
        echo "  existing downloaded_media: $dc files"
    fi

    if [ ! -d "$PZ_STEAMGRID_ROOT" ]; then
        echo "  create steamgrid: $PZ_STEAMGRID_ROOT"
    fi

    echo "  compat aliases:"
    while IFS='|' read -r alias target; do
        [ -z "$alias" ] && continue
        for sys_dir in "$PZ_MEDIA_ROOT"/*/; do
            [ -d "$sys_dir" ] || continue
            sys_dir="${sys_dir%/}"
            local tdir="$sys_dir/$target"
            if [ -d "$tdir" ]; then
                local ap="$sys_dir/$alias"
                if [ -L "$ap" ] && [ "$(readlink "$ap")" = "$tdir" ]; then
                    :  # already correct
                elif [ -e "$ap" ]; then
                    echo "    conflict: $(basename "$sys_dir")/$alias exists (not symlink)"
                else
                    echo "    symlink $(basename "$sys_dir")/$alias -> $target"
                fi
            fi
        done
    done < <(pz_media_compat_aliases)

    echo "  emulator media links:"
    local owner kind target link status
    while IFS='|' read -r owner kind target link; do
        [ -z "$owner" ] && continue
        status="$(pz_media_link_status "$target" "$link")"
        case "$status" in
            linked) echo "    ok: $owner/$kind -> $target" ;;
            dir)    echo "    migrate and link: $owner/$kind -> $target" ;;
            *)      echo "    link: $owner/$kind -> $target" ;;
        esac
    done < <(pz_media_emulator_links)

    local esde_config
    while IFS= read -r esde_config; do
        [ -z "$esde_config" ] && continue
        local current_media current_rom expected_media expected_rom
        current_media="$(pz_media_get_esde_string "$esde_config" "MediaDirectory")"
        current_rom="$(pz_media_get_esde_string "$esde_config" "ROMDirectory")"
        expected_media="$(pz_media_expected_esde_media "$esde_config")"
        expected_rom="$(pz_media_expected_esde_roms "$esde_config")"
        if [ "$current_media" != "$expected_media" ]; then
            echo "  update ES-DE MediaDirectory: $expected_media ($esde_config)"
        fi
        if [ "$current_rom" != "$expected_rom" ]; then
            echo "  update ES-DE ROMDirectory: $expected_rom ($esde_config)"
        fi
    done < <(pz_media_esde_settings_paths)

    local retrodeck_media; retrodeck_media="$(pz_media_retrodeck_esde_media_dir)"
    if [ -n "$retrodeck_media" ]; then
        if [ -L "$retrodeck_media" ] && [ "$(readlink "$retrodeck_media")" = "$PZ_MEDIA_ROOT" ]; then
            echo "  ok: RetroDECK ES-DE downloaded_media linked to canonical"
        else
            echo "  link RetroDECK ES-DE downloaded_media -> canonical"
        fi
    fi

    local srm_settings; srm_settings="$(pz_media_srm_settings_path)"
    if [ -n "$srm_settings" ]; then
        local srm_current=""
        srm_current="$(jq -r '.environmentVariables.localImagesDirectory // ""' "$srm_settings" 2>/dev/null || true)"
        if [ "$srm_current" != "$PZ_STEAMGRID_ROOT" ]; then
            echo "  set SRM localImagesDirectory: $PZ_STEAMGRID_ROOT"
        fi
    fi

    if [ -f "$PZ_MEDIA_INDEX" ]; then
        local age; age=$(($(date +%s) - $(stat -c %Y "$PZ_MEDIA_INDEX" 2>/dev/null || echo 0)))
        echo "  media-index.json exists ($((age / 86400))d old)"
    else
        echo "  create media-index.json"
    fi
}

cmd_apply() {
    pz_emulation_abort_if_frontend_running
    pz_media_abort_if_scanner_running
    install -d "$PZ_MEDIA_ROOT" "$PZ_STEAMGRID_ROOT"
    pz_media_prepare_scan_policy

    pz_info "creating compat alias symlinks..."
    while IFS='|' read -r alias target; do
        [ -z "$alias" ] && continue
        for sys_dir in "$PZ_MEDIA_ROOT"/*/; do
            [ -d "$sys_dir" ] || continue
            sys_dir="${sys_dir%/}"
            local tdir="$sys_dir/$target"
            [ -d "$tdir" ] || continue
            local ap="$sys_dir/$alias"
            if [ -L "$ap" ] && [ "$(readlink "$ap")" = "$tdir" ]; then
                continue
            fi
            if [ -e "$ap" ] && [ ! -L "$ap" ]; then
                local bak="$PZ_EMULATION_ROOT/.phasezero/backups/media-$(basename "$sys_dir")-${alias}-$(date +%s)"
                cp -a "$ap" "$bak"
                pz_warn "backed up existing $(basename "$sys_dir")/$alias -> $bak"
            fi
            rm -f "$ap"
            ln -sf "$tdir" "$ap"
            pz_info "symlink $(basename "$sys_dir")/$alias -> $target"
        done
    done < <(pz_media_compat_aliases)

    pz_media_apply_emulator_links

    local esde_config
    while IFS= read -r esde_config; do
        [ -z "$esde_config" ] && continue
        pz_media_set_esde_string "$esde_config" "MediaDirectory" "$(pz_media_expected_esde_media "$esde_config")"
        pz_media_set_esde_string "$esde_config" "ROMDirectory" "$(pz_media_expected_esde_roms "$esde_config")"
        pz_info "updated ES-DE paths: $esde_config"
    done < <(pz_media_esde_settings_paths)

    pz_media_link_retrodeck

    local srm_settings; srm_settings="$(pz_media_srm_settings_path)"
    if [ -n "$srm_settings" ] && [ -f "$srm_settings" ]; then
        local tmp
        # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
        tmp="$(pz_tempfile)"
        jq --arg sg "$PZ_STEAMGRID_ROOT" \
            '(.environmentVariables.localImagesDirectory) //= $sg | if .environmentVariables.localImagesDirectory != $sg then .environmentVariables.localImagesDirectory = $sg else . end' \
            "$srm_settings" > "$tmp" && mv "$tmp" "$srm_settings"
        pz_info "set SRM localImagesDirectory: $PZ_STEAMGRID_ROOT"
    fi

    cmd_index
    pz_info "media apply complete"
}

cmd_repair() {
    pz_emulation_abort_if_frontend_running
    pz_media_abort_if_scanner_running
    pz_info "repairing media paths..."
    pz_media_prepare_scan_policy

    if [ ! -f "$PZ_MEDIA_INDEX" ]; then
        cmd_index
    fi

    while IFS='|' read -r alias target; do
        [ -z "$alias" ] && continue
        for sys_dir in "$PZ_MEDIA_ROOT"/*/; do
            [ -d "$sys_dir" ] || continue
            sys_dir="${sys_dir%/}"
            local tdir="$sys_dir/$target"
            [ -d "$tdir" ] || continue
            local ap="$sys_dir/$alias"
            if [ -L "$ap" ] && [ "$(readlink "$ap")" = "$tdir" ]; then
                continue
            fi
            rm -f "$ap"
            ln -sf "$tdir" "$ap"
            pz_info "repaired symlink $(basename "$sys_dir")/$alias -> $target"
        done
    done < <(pz_media_compat_aliases)

    pz_media_apply_emulator_links

    local esde_config
    while IFS= read -r esde_config; do
        [ -z "$esde_config" ] && continue
        pz_media_set_esde_string "$esde_config" "MediaDirectory" "$(pz_media_expected_esde_media "$esde_config")"
        pz_media_set_esde_string "$esde_config" "ROMDirectory" "$(pz_media_expected_esde_roms "$esde_config")"
        pz_info "repaired ES-DE paths: $esde_config"
    done < <(pz_media_esde_settings_paths)

    pz_media_link_retrodeck

    local srm_settings; srm_settings="$(pz_media_srm_settings_path)"
    if [ -n "$srm_settings" ] && [ -f "$srm_settings" ]; then
        local tmp
        # shellcheck disable=SC2119 # intentional no-arg call: mktemp default template
        tmp="$(pz_tempfile)"
        jq --arg sg "$PZ_STEAMGRID_ROOT" \
            'if .environmentVariables.localImagesDirectory != $sg then .environmentVariables.localImagesDirectory = $sg else . end' \
            "$srm_settings" > "$tmp" && mv "$tmp" "$srm_settings"
        pz_info "repaired SRM localImagesDirectory"
    fi

    pz_info "media repair complete"
}

cmd_prepare_scan() {
    pz_emulation_abort_if_frontend_running
    pz_media_abort_if_scanner_running
    pz_media_prepare_scan_policy
    cmd_index
    pz_info "scan policy ready"
}

cmd_status_json() {
    pz_json_envelope_start "emulation" "ok"

    local dm_count=0 sg_count=0
    [ -d "$PZ_MEDIA_ROOT" ] && dm_count="$(find "$PZ_MEDIA_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
    [ -d "$PZ_STEAMGRID_ROOT" ] && sg_count="$(find "$PZ_STEAMGRID_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"

    local index_exists=false
    [ -f "$PZ_MEDIA_INDEX" ] && index_exists=true

    pz_json_append_check "media.downloaded_media" "ok" "$dm_count files"
    pz_json_append_check "media.steamgrid" "ok" "$sg_count files"
    pz_json_append_check "media.index" "ok" "exists=$index_exists"
    local switch_games=0 switch_view_games=0 scan_status="ok"
    [ -d "$PZ_EMULATION_ROOT/roms/switch" ] && \
        switch_games="$(pz_media_switch_primary_files "$PZ_EMULATION_ROOT/roms/switch" | tr -cd '\0' | wc -c | tr -d ' ')"
    [ -d "$PZ_SCAN_SAFE_SWITCH" ] && \
        switch_view_games="$(find "$PZ_SCAN_SAFE_SWITCH" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
    [ "$switch_view_games" -ne "$switch_games" ] && scan_status="warn"
    pz_json_append_check "media.scan_safe.switch" "$scan_status" \
        "view=$PZ_SCAN_SAFE_SWITCH primary=$switch_games linked=$switch_view_games"
    local emulator_mismatch=false
    while IFS='|' read -r owner kind target link; do
        [ -z "$owner" ] && continue
        local link_status; link_status="$(pz_media_link_status "$target" "$link")"
        local check_status="ok"
        [ "$link_status" != "linked" ] && check_status="warn"
        [ "$link_status" != "linked" ] && emulator_mismatch=true
        pz_json_append_check "media.emulator.$owner.$kind" "$check_status" "$link_status -> $target"
    done < <(pz_media_emulator_links)

    local esde_found=false esde_mismatch=false esde_i=0 esde_config
    while IFS= read -r esde_config; do
        [ -z "$esde_config" ] && continue
        esde_found=true
        esde_i=$((esde_i + 1))
        local current_media current_rom expected_media expected_rom esde_status
        current_media="$(pz_media_get_esde_string "$esde_config" "MediaDirectory")"
        current_rom="$(pz_media_get_esde_string "$esde_config" "ROMDirectory")"
        expected_media="$(pz_media_expected_esde_media "$esde_config")"
        expected_rom="$(pz_media_expected_esde_roms "$esde_config")"
        esde_status="ok"
        if [ "$current_media" != "$expected_media" ] || [ "$current_rom" != "$expected_rom" ]; then
            esde_status="warn"
            esde_mismatch=true
        fi
        pz_json_append_check "media.esde.$esde_i" "$esde_status" \
            "path=$esde_config MediaDirectory=$current_media expectedMedia=$expected_media ROMDirectory=$current_rom expectedROM=$expected_rom"
    done < <(pz_media_esde_settings_paths)
    if ! $esde_found; then
        pz_json_append_check "media.esde" "warn" "ES-DE settings not found"
        esde_mismatch=true
    fi

    local retrodeck_media retrodeck_media_status
    retrodeck_media="$(pz_media_retrodeck_esde_media_dir)"
    retrodeck_media_status="$(pz_media_link_status "$PZ_MEDIA_ROOT" "$retrodeck_media")"
    pz_json_append_check "media.retrodeck.downloaded_media" \
        "$([ "$retrodeck_media_status" = "linked" ] && echo ok || echo warn)" \
        "$retrodeck_media_status consumer=$retrodeck_media canonical=$PZ_MEDIA_ROOT"
    [ "$retrodeck_media_status" != "linked" ] && esde_mismatch=true

    local srm_settings; srm_settings="$(pz_media_srm_settings_path)"
    if [ -n "$srm_settings" ] && [ -f "$srm_settings" ]; then
        local srm_media
        srm_media="$(jq -r '.environmentVariables.localImagesDirectory // ""' "$srm_settings" 2>/dev/null || true)"
        pz_json_append_check "media.srm" "$([ "$srm_media" = "$PZ_STEAMGRID_ROOT" ] && echo "ok" || echo "warn")" "localImagesDirectory=$srm_media"
    fi

    local overall="ok"
    [ "$dm_count" -eq 0 ] && overall="warn"
    ! $index_exists && overall="warn"
    [ "$scan_status" != "ok" ] && overall="warn"
    $esde_mismatch && overall="warn"
    $emulator_mismatch && overall="warn"

    pz_json_append_action "emulation.media.index" "Indexar mídia" false
    pz_json_append_action "emulation.media.plan" "Ver plano" false
    pz_json_append_action "emulation.media.apply" "Aplicar mídia canônica" true

    PZ_JSON_STATUS="$overall"
    [ "$overall" != "ok" ] && PZ_JSON_OK=false
    pz_json_envelope_end
}

cmd_clean() {
    # Detect media files whose rom no longer exists (orphaned) and move them to
    # a dated backup dir under .phasezero/backups. Dry-run by default; pass
    # --apply to actually move. Never deletes in place.
    cmd_index >/dev/null 2>&1 || cmd_index >/dev/null
    local orphaned count
    orphaned="$(jq -r '.orphanedMedia[]?.path // empty' "$PZ_MEDIA_INDEX" 2>/dev/null || true)"
    count="$(printf '%s\n' "$orphaned" | sed '/^$/d' | wc -l | tr -d ' ')"

    if $PZ_JSON; then
        jq '{orphaned: (.stats.orphaned_media // 0), files: (.orphanedMedia // [])}' "$PZ_MEDIA_INDEX"
        return 0
    fi

    echo "=== Media Clean ==="
    echo "orphaned media files: $count"
    if [ "$count" -eq 0 ]; then
        echo "nothing to clean"
        return 0
    fi
    # Show up to 20 sample paths. Avoid a `head -N` in a pipe: under
    # `set -o pipefail` head closing early surfaces as SIGPIPE (exit 141) and
    # aborts the whole script before the move loop runs.
    local shown=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf '  %s\n' "$path"
        shown=$((shown + 1))
        [ "$shown" -ge 20 ] && break
    done <<< "$orphaned"
    [ "$count" -gt 20 ] && echo "  ... and $((count - 20)) more"

    if ! $PZ_APPLY; then
        echo "(dry-run; pass --apply to move orphaned media to backup)"
        return 0
    fi

    local backup_dir stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup_dir="$PZ_EMULATION_ROOT/.phasezero/backups/orphaned-media-$stamp"
    install -d "$backup_dir"
    local moved=0 path rel dest
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -f "$path" ] || continue
        # Preserve a relative path under the backup dir so files can be restored.
        case "$path" in
            "$PZ_MEDIA_ROOT"/*) rel="downloaded_media/${path#"$PZ_MEDIA_ROOT"/}" ;;
            "$PZ_STEAMGRID_ROOT"/*) rel="steamgrid/${path#"$PZ_STEAMGRID_ROOT"/}" ;;
            *) rel="misc/$(basename "$path")" ;;
        esac
        dest="$backup_dir/$rel"
        install -d "$(dirname "$dest")"
        if mv -f "$path" "$dest" 2>/dev/null; then
            moved=$((moved + 1))
        fi
    done <<< "$orphaned"
    pz_info "moved $moved orphaned media file(s) to $backup_dir"
    echo "moved: $moved -> $backup_dir"
    echo "to restore: cp -a $backup_dir/* <original-tree>"
}

case "$ACTION" in
    status) if $PZ_JSON; then cmd_status_json; else cmd_status; fi ;;
    index)  cmd_index ;;
    plan)   cmd_plan ;;
    apply)  cmd_apply ;;
    repair) cmd_repair ;;
    clean|cleanup|prune) cmd_clean ;;
    prepare-scan|scan-policy) cmd_prepare_scan ;;
    *)
        pz_error "usage: media.sh (status|index|plan|apply|repair|clean [--apply]|prepare-scan)"
        exit 1
        ;;
esac
