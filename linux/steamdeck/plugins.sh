#!/usr/bin/env bash
# plugins.sh - Decky Loader and curated SteamOS plugin automation
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift 2>/dev/null || true

PZ_DECKY_HOME="${PZ_DECKY_HOME:-$HOME/homebrew}"
PZ_DECKY_PLUGINS_DIR="${PZ_DECKY_PLUGINS_DIR:-$PZ_DECKY_HOME/plugins}"
PZ_DECKY_THEMES_DIR="${PZ_DECKY_THEMES_DIR:-$PZ_DECKY_HOME/themes}"
PZ_DECKY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/phasezero/decky"
PZ_DECKY_SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PZ_DECKY_CHANNEL="${PZ_DECKY_CHANNEL:-release}"
PZ_DECKY_FORCE="${PZ_DECKY_FORCE:-0}"
PZ_DECKY_INSTALL_MODE="${PZ_DECKY_INSTALL_MODE:-auto}"
PZ_STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
PZ_DECKBREW_STORE_URL="${PZ_DECKBREW_STORE_URL:-https://plugins.deckbrew.xyz/plugins}"
PZ_DECKBREW_CDN_URL="${PZ_DECKBREW_CDN_URL:-https://cdn.tzatzikiweeb.moe/file/steam-deck-homebrew/versions}"

cmd_path() { command -v "$1" 2>/dev/null || true; }

bool_cmd() {
    command -v "$1" >/dev/null 2>&1 && echo true || echo false
}

service_state() {
    local scope="$1"
    case "$scope" in
        system) systemctl is-active plugin_loader.service 2>/dev/null || true ;;
        user)   systemctl --user is-active plugin_loader.service 2>/dev/null || true ;;
        *)      echo unknown ;;
    esac
}

service_enabled() {
    local scope="$1"
    case "$scope" in
        system) systemctl is-enabled plugin_loader.service 2>/dev/null || true ;;
        user)   systemctl --user is-enabled plugin_loader.service 2>/dev/null || true ;;
        *)      echo unknown ;;
    esac
}

decky_installed_bool() {
    if [ -x "$PZ_DECKY_HOME/services/PluginLoader" ] ||
        [ -f "/etc/systemd/system/plugin_loader.service" ] ||
        [ -f "$PZ_DECKY_SYSTEMD_USER_DIR/plugin_loader.service" ]; then
        echo true
    else
        echo false
    fi
}

decky_service_active_bool() {
    if [ "$(service_state system)" = "active" ] || [ "$(service_state user)" = "active" ]; then
        echo true
    else
        echo false
    fi
}

steam_cef_debug_bool() {
    if [ -e "$HOME/.steam/steam/.cef-enable-remote-debugging" ] ||
        [ -e "$PZ_STEAM_ROOT/.cef-enable-remote-debugging" ]; then
        echo true
    else
        echo false
    fi
}

decky_privileged_service_bool() {
    [ "$(service_state system)" = "active" ] && echo true || echo false
}

decky_dual_service_conflict_bool() {
    if [ "$(service_state system)" = "active" ] && [ "$(service_state user)" = "active" ]; then
        echo true
    else
        echo false
    fi
}

phasezero_tdp_bridge_bool() {
    local helper="/usr/local/lib/phasezero/steamdeck-privileged-control"
    [ -x "$helper" ] &&
        command -v sudo >/dev/null 2>&1 &&
        sudo -n "$helper" status >/dev/null 2>&1 &&
        echo true || echo false
}

lossless_scaling_installed_bool() {
    if find "$HOME/.steam/steam/steamapps" "$PZ_STEAM_ROOT/steamapps" \
        -maxdepth 1 -name 'appmanifest_993090.acf' -type f 2>/dev/null | grep -q .; then
        echo true
    else
        echo false
    fi
}

port_busy_bool() {
    local port="$1"
    if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
        echo true
    else
        echo false
    fi
}

steam_cef_port_bool() { port_busy_bool 8080; }
decky_port_bool() { port_busy_bool 1337; }

# Wait for Decky's websocket on :1337 to come up. The loader service can be
# "enabled" a few seconds before it actually listens, so store installs via WS
# silently fail and only succeed on a later retry. Mirrors prepare_steam_ui's
# CEF :8080 wait. Override the budget with PZ_DECKY_READY_TIMEOUT.
wait_decky_ready() {
    local budget="${PZ_DECKY_READY_TIMEOUT:-30}" i
    if [ "$(decky_port_bool)" = true ]; then
        return 0
    fi
    pz_info "waiting up to ${budget}s for Decky loader (:1337)..."
    for i in $(seq 1 "$budget"); do
        if [ "$(decky_port_bool)" = true ]; then
            pz_info "Decky loader ready on :1337 (after ${i}s)"
            return 0
        fi
        sleep 1
    done
    pz_warn "Decky loader did not listen on :1337 within ${budget}s; WS installs may fall back to zip"
    return 1
}

# Real conflict = :8080 held by a process that is NOT Steam's CEF (steamwebhelper).
# Steam's CSS Loader / Decky attach to Steam over :8080, so a squatter there (e.g.
# an AI proxy defaulting to 8080) silently breaks CSS Loader with the health-check
# "Cannot connect to host 127.0.0.1:8080" seen in its logs.
steam_cef_conflict_bool() {
    command -v ss >/dev/null 2>&1 || { echo false; return; }
    local owners
    owners="$(ss -ltnp "sport = :8080" 2>/dev/null | grep ':8080' || true)"
    [ -n "$owners" ] || { echo false; return; }
    if printf '%s' "$owners" | grep -qiE 'steamwebhelper|"steam"|/steam'; then
        echo false
    else
        echo true
    fi
}

plugin_catalog() {
    cat <<'EOF'
PowerTools|PowerTools|PowerTools|database|https://gitlab.com/NGnius/PowerTools||PowerTools|TDP, SMT, CPU/GPU power controls; needs privileged Decky service for full plugin control.
SDH-CssLoader|CSS Loader|SDH-CssLoader|database|https://github.com/DeckThemes/SDH-CssLoader|DeckThemes/SDH-CssLoader|SDH-CssLoader,SDH-CSSLoader,CSSLoader,CssLoader|Themes and CSS customization.
SDH-AnimationChanger|Animation Changer|SDH-AnimationChanger|database|https://github.com/TheLogicMaster/SDH-AnimationChanger||SDH-AnimationChanger,AnimationChanger|Boot/suspend animation customization.
SDH-AudioLoader|Audio Loader|SDH-AudioLoader|database|https://github.com/DeckThemes/SDH-AudioLoader||SDH-AudioLoader,AudioLoader|Steam UI sound pack customization.
protondb-decky|ProtonDB Badges|protondb-decky|database|https://github.com/OMGDuke/protondb-decky||protondb-decky,ProtonDBBadges|Compatibility badges in library.
hltb-for-deck|HLTB for Deck|hltb-for-deck|database|https://github.com/SDH-Stewardship/hltb-for-deck||hltb-for-deck,HLTB-for-Deck|HowLongToBeat estimates in game pages.
decky-steamgriddb|SteamGridDB|decky-steamgriddb|database|https://github.com/SteamGridDB/decky-steamgriddb||decky-steamgriddb,SteamGridDB|Artwork management from Game Mode.
decky-storage-cleaner|Storage Cleaner|decky-storage-cleaner|database|https://github.com/mcarlucci/decky-storage-cleaner||decky-storage-cleaner,StorageCleaner|Shader/compatdata cleanup from Game Mode.
decky-game-settings|Deck Settings|Deck Settings|database|https://github.com/DeckSettings/decky-game-settings||decky-game-settings,DeckSettings|Community settings reference.
Bluetooth|Bluetooth|Bluetooth|database|https://github.com/Outpox/Bluetooth||Bluetooth|Bluetooth quick settings from Decky.
vibrantDeck|vibrantDeck|vibrantDeck|database|https://github.com/libvibrant/vibrantDeck||vibrantDeck|Display vibrance/saturation controls.
EmuDecky|EmuDecky|EmuDecky|database|https://github.com/EmuDeck/EmuDecky||EmuDecky|EmuDeck integration in Game Mode.
decky-autoflatpaks|AutoFlatpaks|decky-autoflatpaks|database|https://github.com/jurassicplayer/decky-autoflatpaks||decky-autoflatpaks,AutoFlatpaks|Flatpak update UX from Game Mode.
decky-ludusavi|Ludusavi|decky-ludusavi|database|https://github.com/GedasFX/decky-ludusavi||decky-ludusavi,Ludusavi|Save backup integration.
decky-wine-cellar|Wine Cellar|decky-wine-cellar|database|https://github.com/FlashyReese/decky-wine-cellar||decky-wine-cellar,WineCellar|Wine/Proton management helper.
decky-lsfg-vk|Decky LSFG-VK|decky-lsfg-vk|database|https://github.com/xXJSONDeruloXx/decky-lsfg-vk|xXJSONDeruloXx/decky-lsfg-vk|decky-lsfg-vk,Decky.LSFG-VK,Decky-LSFG-VK|Requires Lossless Scaling Steam app and per-game launch option.
NonSteamLaunchers|NonSteamLaunchers|NonSteamLaunchers|unsupported|https://github.com/moraroy/NonSteamLaunchersDecky||NonSteamLaunchers,NonSteamLaunchersDecky|No packaged Decky artifact is currently published; incomplete source snapshots are quarantined. Use PhaseZero non-Steam launcher integration.
EOF
}

theme_catalog() {
    cat <<'EOF'
phasezero|PhaseZero SteamOS Plus|local||Safe built-in theme scaffold for CSS Loader.
obsidian|Obsidian|github-dir|EMERALD0874/Steam-Deck-Themes:Obsidian|AMOLED-like dark theme.
round|Round|github-dir|EMERALD0874/Steam-Deck-Themes:Round|Rounded Deck UI elements.
centered-home|Centered-Home|github-dir|EMERALD0874/Steam-Deck-Themes:Centered-Home|Centered home carousel layout.
galactic|Galactic|github-dir|EMERALD0874/Steam-Deck-Themes:Galactic|Visual Steam Deck theme.
phantom|Phantom|github-dir|EMERALD0874/Steam-Deck-Themes:Phantom|Visual Steam Deck theme.
EOF
}

release_asset_regex() {
    case "$1" in
        SDH-CssLoader) echo 'SDH-CSSLoader-Decky[.]zip$' ;;
        decky-lsfg-vk) echo 'Decky[.]LSFG-VK[.]zip$|decky-lsfg-vk[.]zip$' ;;
        unifideck) echo 'unifideck.*[.]zip$' ;;
        *) echo '[.]zip$' ;;
    esac
}

plugin_path_by_candidates() {
    # shellcheck disable=SC2178 # candidates is a comma-separated string, not array
    local candidates="$1" dir base candidate name id display
    [ -d "$PZ_DECKY_PLUGINS_DIR" ] || return 0
    # shellcheck disable=SC2128 # candidates is a string, not array
    IFS=',' read -r -a candidate_array <<< "$candidates"

    for candidate in "${candidate_array[@]}"; do
        [ -z "$candidate" ] && continue
        if [ -d "$PZ_DECKY_PLUGINS_DIR/$candidate" ]; then
            echo "$PZ_DECKY_PLUGINS_DIR/$candidate"
            return 0
        fi
    done

    while IFS= read -r dir; do
        base="$(basename "$dir")"
        for candidate in "${candidate_array[@]}"; do
            [ -z "$candidate" ] && continue
            if [ "${base,,}" = "${candidate,,}" ]; then
                echo "$dir"
                return 0
            fi
        done
        if [ -f "$dir/plugin.json" ] && command -v jq >/dev/null 2>&1; then
            name="$(jq -r '.name // empty' "$dir/plugin.json" 2>/dev/null || true)"
            id="$(jq -r '.id // empty' "$dir/plugin.json" 2>/dev/null || true)"
            display="$(jq -r '.display_name // .displayName // empty' "$dir/plugin.json" 2>/dev/null || true)"
            for candidate in "${candidate_array[@]}"; do
                [ -z "$candidate" ] && continue
                if [ "${name,,}" = "${candidate,,}" ] || [ "${id,,}" = "${candidate,,}" ] || [ "${display,,}" = "${candidate,,}" ]; then
                    echo "$dir"
                    return 0
                fi
            done
        fi
    done < <(find "$PZ_DECKY_PLUGINS_DIR" -maxdepth 1 -mindepth 1 -type d \
        ! -name '.phasezero-*' ! -name '*.bak.*' 2>/dev/null | sort)
}

plugin_version() {
    local path="$1"
    if [ -f "$path/plugin.json" ]; then
        if jq -r '.version // empty' "$path/plugin.json" 2>/dev/null | grep -v '^$' >/dev/null; then
            return 0
        fi
    fi
    [ -f "$path/package.json" ] || return 0
    jq -r '.version // empty' "$path/package.json" 2>/dev/null || true
}

plugin_health_json() {
    local id="$1" path="$2" ok=true issue="" backend
    if [ -z "$path" ] || [ ! -d "$path" ]; then
        ok=false
        issue="plugin directory missing"
    elif [ ! -f "$path/plugin.json" ]; then
        ok=false
        issue="plugin.json missing"
    elif ! jq -e 'type == "object" and ((.name // .id // "") | type == "string" and length > 0)' \
        "$path/plugin.json" >/dev/null 2>&1; then
        ok=false
        issue="plugin.json invalid"
    elif [ ! -f "$path/dist/index.js" ] || [ ! -s "$path/dist/index.js" ] || [ ! -r "$path/dist/index.js" ]; then
        ok=false
        issue="frontend bundle missing or empty: dist/index.js"
    fi

    if [ "$ok" = true ] && [ "$id" = "PowerTools" ]; then
        backend="$path/bin/backend"
        if [ ! -x "$backend" ]; then
            ok=false
            issue="PowerTools backend missing; reinstall from Decky Store package or run privileged plugin repair"
        fi
    fi

    jq -n --argjson ok "$ok" --arg issue "$issue" '{ok: $ok, issue: $issue}'
}

plugin_frontend_reachable_json() {
    local path="$1" name encoded status
    if [ "${PZ_DECKY_RUNTIME_PROBE:-1}" != 1 ] || [ -z "$path" ] || \
        [ ! -f "$path/plugin.json" ] || [ "$(decky_port_bool)" != true ]; then
        echo null
        return 0
    fi
    name="$(jq -er '.name | select(type == "string" and length > 0)' "$path/plugin.json" 2>/dev/null || true)"
    [ -n "$name" ] || { echo false; return 0; }
    encoded="$(jq -rn --arg value "$name" '$value | @uri')"
    status="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 \
        "http://127.0.0.1:1337/plugins/$encoded/dist/index.js" 2>/dev/null || true)"
    [ "$status" = 200 ] && echo true || echo false
}

plugins_json() {
    local arr="[]" id display store mode homepage repo candidates note path installed version health healthy health_issue frontend_reachable requires_lossless lossless_ready privileged_required privileged_ready installable
    while IFS='|' read -r id display store mode homepage repo candidates note; do
        [ -z "$id" ] && continue
        path="$(plugin_path_by_candidates "$candidates" || true)"
        installed=false
        [ -n "$path" ] && installed=true
        version=""
        [ -n "$path" ] && version="$(plugin_version "$path")"
        health="$(plugin_health_json "$id" "$path")"
        healthy="$(jq -r '.ok' <<< "$health")"
        health_issue="$(jq -r '.issue' <<< "$health")"
        frontend_reachable="$(plugin_frontend_reachable_json "$path")"
        requires_lossless=false
        lossless_ready=true
        if [ "$id" = "decky-lsfg-vk" ]; then
            requires_lossless=true
            lossless_ready="$(lossless_scaling_installed_bool)"
        fi
        privileged_required=false
        privileged_ready=true
        if [ "$id" = "PowerTools" ]; then
            privileged_required=true
            privileged_ready="$(decky_privileged_service_bool)"
        fi
        installable=true
        [ "$mode" = "unsupported" ] && installable=false
        arr="$(jq \
            --arg id "$id" \
            --arg displayName "$display" \
            --arg storeName "$store" \
            --arg mode "$mode" \
            --arg homepage "$homepage" \
            --arg repo "$repo" \
            --arg candidates "$candidates" \
            --arg note "$note" \
            --arg path "$path" \
            --arg version "$version" \
            --arg healthIssue "$health_issue" \
            --argjson installed "$installed" \
            --argjson healthy "$healthy" \
            --argjson frontendReachable "$frontend_reachable" \
            --argjson requiresLossless "$requires_lossless" \
            --argjson losslessReady "$lossless_ready" \
            --argjson privilegedRequired "$privileged_required" \
            --argjson privilegedReady "$privileged_ready" \
            --argjson installable "$installable" \
            '. += [{
                id: $id,
                displayName: $displayName,
                storeName: $storeName,
                installMode: $mode,
                homepage: $homepage,
                repo: $repo,
                candidates: ($candidates | split(",")),
                installed: $installed,
                healthy: $healthy,
                frontendReachable: $frontendReachable,
                healthIssue: $healthIssue,
                path: $path,
                version: $version,
                requiresLosslessScaling: $requiresLossless,
                losslessScalingReady: $losslessReady,
                requiresPrivilegedDecky: $privilegedRequired,
                privilegedDeckyReady: $privilegedReady,
                installable: $installable,
                note: $note
            }]' <<< "$arr")"
    done < <(plugin_catalog)
    printf '%s\n' "$arr"
}

themes_json() {
    local arr="[]" id display mode source note path installed version
    while IFS='|' read -r id display mode source note; do
        [ -z "$id" ] && continue
        path="$PZ_DECKY_THEMES_DIR/$display"
        installed=false
        [ -d "$path" ] && installed=true
        version=""
        [ -f "$path/theme.json" ] && version="$(jq -r '.version // empty' "$path/theme.json" 2>/dev/null || true)"
        arr="$(jq \
            --arg id "$id" \
            --arg displayName "$display" \
            --arg mode "$mode" \
            --arg source "$source" \
            --arg note "$note" \
            --arg path "$path" \
            --arg version "$version" \
            --argjson installed "$installed" \
            '. += [{
                id: $id,
                displayName: $displayName,
                installMode: $mode,
                source: $source,
                installed: $installed,
                path: $path,
                version: $version,
                note: $note
            }]' <<< "$arr")"
    done < <(theme_catalog)
    printf '%s\n' "$arr"
}

status_json() {
    local plugins themes powertools_ready css_installed animation_installed plugins_ready
    plugins="$(plugins_json)"
    themes="$(themes_json)"
    powertools_ready="$(jq -r '[.[] | select(.id == "PowerTools" and .installed == true and .healthy == true)] | length > 0' <<< "$plugins")"
    css_installed="$(jq -r '[.[] | select(.id == "SDH-CssLoader" and .installed == true)] | length > 0' <<< "$plugins")"
    animation_installed="$(jq -r '[.[] | select(.id == "SDH-AnimationChanger" and .installed == true)] | length > 0' <<< "$plugins")"
    plugins_ready="$(jq -r '[.[] | select(.installable == true)] | all(.installed and .healthy and (.frontendReachable != false))' <<< "$plugins")"
    jq -n \
        --arg deckyHome "$PZ_DECKY_HOME" \
        --arg pluginsDir "$PZ_DECKY_PLUGINS_DIR" \
        --arg themesDir "$PZ_DECKY_THEMES_DIR" \
        --arg cacheDir "$PZ_DECKY_CACHE" \
        --arg channel "$PZ_DECKY_CHANNEL" \
        --arg steam "$(cmd_path steam)" \
        --arg curl "$(cmd_path curl)" \
        --arg jqPath "$(cmd_path jq)" \
        --arg unzip "$(cmd_path unzip)" \
        --arg git "$(cmd_path git)" \
        --arg systemServiceState "$(service_state system)" \
        --arg systemServiceEnabled "$(service_enabled system)" \
        --arg userServiceState "$(service_state user)" \
        --arg userServiceEnabled "$(service_enabled user)" \
        --argjson installed "$(decky_installed_bool)" \
        --argjson serviceActive "$(decky_service_active_bool)" \
        --argjson cefDebug "$(steam_cef_debug_bool)" \
        --argjson pluginDirExists "$([ -d "$PZ_DECKY_PLUGINS_DIR" ] && echo true || echo false)" \
        --argjson pluginDirWritable "$([ -w "$PZ_DECKY_PLUGINS_DIR" ] && echo true || echo false)" \
        --argjson steamCefPort "$(steam_cef_port_bool)" \
        --argjson steamCefConflict "$(steam_cef_conflict_bool)" \
        --argjson deckyPort "$(decky_port_bool)" \
        --argjson dualServiceConflict "$(decky_dual_service_conflict_bool)" \
        --argjson losslessScalingInstalled "$(lossless_scaling_installed_bool)" \
        --argjson privilegedService "$(decky_privileged_service_bool)" \
        --argjson phasezeroTdpBridge "$(phasezero_tdp_bridge_bool)" \
        --argjson powerToolsReady "$powertools_ready" \
        --argjson cssLoaderInstalled "$css_installed" \
        --argjson animationChangerInstalled "$animation_installed" \
        --argjson pluginsReady "$plugins_ready" \
        --argjson plugins "$plugins" \
        --argjson themes "$themes" \
        '{
            decky: {
                installed: $installed,
                homebrewDir: $deckyHome,
                pluginsDir: $pluginsDir,
                themesDir: $themesDir,
                cacheDir: $cacheDir,
                channel: $channel,
                service: {
                    active: $serviceActive,
                    privilegedSystemServiceActive: $privilegedService,
                    dualServiceConflict: $dualServiceConflict,
                    system: {state: $systemServiceState, enabled: $systemServiceEnabled},
                    user: {state: $userServiceState, enabled: $userServiceEnabled}
                },
                cefRemoteDebuggingEnabled: $cefDebug,
                pluginDirExists: $pluginDirExists,
                pluginDirWritable: $pluginDirWritable,
                ports: {
                    steamCef8080Listening: $steamCefPort,
                    decky1337Listening: $deckyPort
                },
                portConflicts: {port8080: $steamCefConflict, port1337: false}
            },
            bigPicture: {
                command: "steam -gamepadui -steamos3",
                deckyMenu: "Quick Access Menu -> plug icon",
                ready: ($installed and $serviceActive)
            },
            prerequisites: {
                steam: $steam,
                curl: $curl,
                jq: $jqPath,
                unzip: $unzip,
                git: $git,
                losslessScalingSteamAppInstalled: $losslessScalingInstalled
            },
            steamDeckExperience: {
                tdpPluginReady: ($powerToolsReady and $privilegedService),
                tdpFallbackReady: $phasezeroTdpBridge,
                themePluginReady: $cssLoaderInstalled,
                animationPluginReady: $animationChangerInstalled,
                curatedPluginsReady: $pluginsReady,
                steamUiDebugReady: ($cefDebug and $steamCefPort),
                deckyMenuReady: ($installed and $serviceActive and $cefDebug and $deckyPort and $steamCefPort and ($dualServiceConflict | not))
            },
            desiredPlugins: $plugins,
            desiredThemes: $themes
        }'
}

require_cmds() {
    local missing=() dep
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        pz_error "missing dependencies: ${missing[*]}"
        return 1
    fi
}

decky_installer_url() {
    case "$PZ_DECKY_CHANNEL" in
        prerelease|pre-release|preview) echo "https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_prerelease.sh" ;;
        release|stable|"") echo "https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/install_release.sh" ;;
        *) pz_error "unknown PZ_DECKY_CHANNEL: $PZ_DECKY_CHANNEL"; return 1 ;;
    esac
}

ensure_plugin_dirs() {
    install -d "$PZ_DECKY_PLUGINS_DIR" "$PZ_DECKY_THEMES_DIR" "$PZ_DECKY_CACHE"
}

migrate_legacy_plugin_backups() {
    local backup_dir path target
    [ -d "$PZ_DECKY_PLUGINS_DIR" ] || return 0
    backup_dir="$PZ_DECKY_HOME/plugin-backups"
    while IFS= read -r -d '' path; do
        if [ ! -w "$PZ_DECKY_PLUGINS_DIR" ] && [ "$EUID" -ne 0 ]; then
            pz_warn "legacy plugin backup remains loadable; elevated repair required: $path"
            return 1
        fi
        install -d "$backup_dir"
        target="$backup_dir/$(basename "$path").migrated.$(date +%Y%m%d%H%M%S).$$"
        mv "$path" "$target"
        pz_info "moved legacy plugin backup outside loader path: $target"
    done < <(find "$PZ_DECKY_PLUGINS_DIR" -maxdepth 1 -mindepth 1 -type d -name '*.bak.*' -print0 2>/dev/null)
}

enable_cef_debug() {
    local path
    for path in \
        "$HOME/.steam/steam/.cef-enable-remote-debugging" \
        "$PZ_STEAM_ROOT/.cef-enable-remote-debugging" \
        "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/.cef-enable-remote-debugging"; do
        [ -d "$(dirname "$path")" ] || continue
        touch "$path"
        pz_info "CEF remote debugging enabled: $path"
    done
}

repair_permissions() {
    local path
    for path in "$PZ_DECKY_PLUGINS_DIR" "$PZ_DECKY_THEMES_DIR"; do
        [ -e "$path" ] || continue
        if [ -w "$path" ]; then
            continue
        fi
        pz_warn "not writable: $path"
        pz_warn "use Decky websocket install or: linux/pz steamdeck plugins repair-plugins-privileged"
    done
}

disable_decky_user_fallback() {
    local unit="$PZ_DECKY_SYSTEMD_USER_DIR/plugin_loader.service"
    [ -f "$unit" ] || [ "$(service_state user)" = "active" ] || return 0
    if timeout 20s systemctl --user disable --now plugin_loader.service >/dev/null 2>&1; then
        pz_info "disabled Decky user fallback; privileged system service is authoritative"
    else
        systemctl --user kill plugin_loader.service >/dev/null 2>&1 || true
        systemctl --user stop plugin_loader.service >/dev/null 2>&1 || true
        systemctl --user disable plugin_loader.service >/dev/null 2>&1 || true
        systemctl --user reset-failed plugin_loader.service >/dev/null 2>&1 || true
        if [ "$(service_state user)" = "active" ]; then
            pz_warn "could not disable Decky user fallback"
            pz_warn "run: systemctl --user disable --now plugin_loader.service"
        else
            pz_info "killed and disabled Decky user fallback after timeout"
        fi
    fi
}

reconcile_decky_services() {
    if [ "$(service_state system)" = "active" ] || [ "$(service_enabled system)" = "enabled" ]; then
        disable_decky_user_fallback
    fi
}

deckbrew_plugin_json() {
    local aliases
    aliases="$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')"
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 "$PZ_DECKBREW_STORE_URL" |
        jq -c --argjson aliases "$aliases" '
            .[]
            | select(.name as $name | any($aliases[]; . == $name or (ascii_downcase == ($name | ascii_downcase))))
        ' |
        head -1 |
        head -c 1048576
}

validate_zip_archive() {
    local zip="$1"
    require_cmds python3
    python3 - "$zip" <<'PY'
import os
import stat
import sys
import zipfile
from pathlib import PurePosixPath

archive = sys.argv[1]
max_entries = int(os.environ.get("PZ_DECKY_ZIP_MAX_ENTRIES", "20000"))
max_file = int(os.environ.get("PZ_DECKY_ZIP_MAX_FILE_BYTES", str(256 * 1024 * 1024)))
max_total = int(os.environ.get("PZ_DECKY_ZIP_MAX_TOTAL_BYTES", str(512 * 1024 * 1024)))

try:
    with zipfile.ZipFile(archive) as handle:
        entries = handle.infolist()
        if not entries or len(entries) > max_entries:
            raise ValueError(f"invalid archive entry count: {len(entries)}")
        total = 0
        for entry in entries:
            raw = entry.filename
            normalized = raw.replace("\\", "/")
            path = PurePosixPath(normalized)
            if (
                not raw
                or raw.startswith(("/", "\\"))
                or "\x00" in raw
                or len(raw) > 1024
                or (len(raw) >= 2 and raw[1] == ":")
                or any(part in ("", ".", "..") for part in path.parts)
            ):
                raise ValueError(f"unsafe archive path: {raw!r}")
            mode = (entry.external_attr >> 16) & 0xFFFF
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError(f"unsupported archive entry type: {raw!r}")
            if entry.flag_bits & 0x1:
                raise ValueError(f"encrypted archive entry: {raw!r}")
            if entry.file_size > max_file:
                raise ValueError(f"archive entry too large: {raw!r}")
            total += entry.file_size
            if total > max_total:
                raise ValueError("archive expands beyond configured limit")
            if entry.compress_size and entry.file_size / entry.compress_size > 1000:
                raise ValueError(f"suspicious compression ratio: {raw!r}")
        corrupt = handle.testzip()
        if corrupt:
            raise ValueError(f"archive CRC failure: {corrupt!r}")
except (OSError, ValueError, zipfile.BadZipFile) as exc:
    print(f"unsafe or invalid Decky package: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

find_packaged_plugin_root() {
    local extracted="$1" bundle root found=""
    while IFS= read -r -d '' bundle; do
        root="${bundle%/dist/index.js}"
        [ -f "$root/plugin.json" ] || continue
        if [ -n "$found" ] && [ "$found" != "$root" ]; then
            pz_error "multiple Decky plugin roots found in package"
            return 1
        fi
        found="$root"
    done < <(find "$extracted" -maxdepth 8 -type f -path '*/dist/index.js' -print0 2>/dev/null)
    [ -n "$found" ] || {
        pz_error "complete Decky package not found (plugin.json + dist/index.js required)"
        return 1
    }
    printf '%s\n' "$found"
}

safe_download_url() {
    case "$1" in
        https://*) return 0 ;;
        *) return 1 ;;
    esac
}

download_remote_binaries_for_plugin() {
    local plugin_dir="$1" package_json bin_dir name url hash target partial got_hash
    package_json="$plugin_dir/package.json"
    [ -f "$package_json" ] || return 0
    if ! jq -e '.remote_binary and (.remote_binary | length > 0)' "$package_json" >/dev/null 2>&1; then
        return 0
    fi

    require_cmds jq curl sha256sum
    bin_dir="$plugin_dir/bin"
    install -d "$bin_dir"
    while IFS=$'\t' read -r name url hash; do
        if [ -z "$name" ] || [ -z "$url" ] || [ -z "$hash" ]; then
            continue
        fi
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
            pz_error "unsafe remote binary name: $name"
            return 1
        }
        safe_download_url "$url" || {
            pz_error "remote binary URL must use HTTPS: $name"
            return 1
        }
        [[ "$hash" =~ ^[A-Fa-f0-9]{64}$ ]] || {
            pz_error "invalid remote binary checksum: $name"
            return 1
        }
        target="$bin_dir/$name"
        partial="$target.part.$$"
        pz_info "downloading plugin binary: $(basename "$plugin_dir")/$name"
        curl -fL --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 268435456 -o "$partial" "$url"
        got_hash="$(sha256sum "$partial" | awk '{print $1}')"
        if [ "$got_hash" != "$hash" ]; then
            rm -f "$partial"
            pz_error "remote binary checksum mismatch: $name"
            return 1
        fi
        mv "$partial" "$target"
        chmod +x "$target"
    done < <(jq -r '.remote_binary[] | [.name, .url, .sha256hash] | @tsv' "$package_json")
}

install_decky_loader() {
    local url script
    url="$(decky_installer_url)"
    if [ "$(decky_installed_bool)" = true ] && [ "$PZ_DECKY_FORCE" != "1" ]; then
        pz_info "Decky Loader already detected"
        enable_cef_debug
        reconcile_decky_services
        return 0
    fi
    require_cmds curl sh
    install -d "$PZ_DECKY_CACHE"
    script="$PZ_DECKY_CACHE/$(basename "$url")"
    pz_info "downloading Decky installer: $url"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$script" "$url"
    chmod +x "$script"
    enable_cef_debug

    if [ "$PZ_DECKY_INSTALL_MODE" = "user" ]; then
        install_decky_user_loader
        return $?
    fi

    if [ "$EUID" -eq 0 ]; then
        pz_info "running Decky installer as root ($PZ_DECKY_CHANNEL)"
        SUDO_USER="${SUDO_USER:-$USER}" sh "$script"
    elif pz_can_sudo_noninteractive; then
        pz_info "running Decky installer via sudo -n ($PZ_DECKY_CHANNEL)"
        sudo -n env SUDO_USER="$USER" USER="$USER" sh "$script"
    else
        pz_warn "sudo unavailable non-interactively; installing user-service fallback"
        pz_warn "PowerTools TDP plugin needs privileged system Decky service for full control"
        install_decky_user_loader
    fi
    reconcile_decky_services
}

install_decky_loader_privileged() {
    local url script
    url="$(decky_installer_url)"
    require_cmds curl sh
    install -d "$PZ_DECKY_CACHE"
    script="$PZ_DECKY_CACHE/$(basename "$url")"
    curl -fsSL --retry 3 --connect-timeout 15 -o "$script" "$url"
    chmod +x "$script"
    enable_cef_debug
    if [ "$EUID" -eq 0 ]; then
        SUDO_USER="${SUDO_USER:-$USER}" sh "$script"
    elif command -v pkexec >/dev/null 2>&1 && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
        pkexec env SUDO_USER="$USER" USER="$USER" HOME="$HOME" sh "$script"
    elif command -v sudo >/dev/null 2>&1; then
        sudo env SUDO_USER="$USER" USER="$USER" HOME="$HOME" sh "$script"
    else
        pz_error "privileged Decky install requires pkexec or sudo"
        return 1
    fi
    reconcile_decky_services
}

install_decky_user_loader() {
    local release download version service
    if [ "$(service_state system)" = "active" ] || [ "$(service_enabled system)" = "enabled" ]; then
        pz_info "privileged Decky service detected; skipping user fallback"
        disable_decky_user_fallback
        return 0
    fi
    require_cmds curl jq
    ensure_plugin_dirs
    install -d "$PZ_DECKY_HOME/services" "$PZ_DECKY_SYSTEMD_USER_DIR"
    release="$(curl -fsSL 'https://api.github.com/repos/SteamDeckHomebrew/decky-loader/releases' | jq -r 'first(.[] | select(.prerelease == false))')"
    version="$(jq -r '.tag_name' <<< "$release")"
    download="$(jq -r '.assets[].browser_download_url | select(endswith("PluginLoader"))' <<< "$release" | head -1)"
    [ -n "$download" ] || { pz_error "PluginLoader asset not found"; return 1; }
    pz_info "downloading Decky PluginLoader $version"
    curl -fL --retry 3 --connect-timeout 15 -o "$PZ_DECKY_HOME/services/PluginLoader" "$download"
    chmod +x "$PZ_DECKY_HOME/services/PluginLoader"
    printf '%s\n' "$version" > "$PZ_DECKY_HOME/services/.loader.version"
    service="$PZ_DECKY_SYSTEMD_USER_DIR/plugin_loader.service"
    cat > "$service" <<EOF
[Unit]
Description=SteamDeck Plugin Loader (PhaseZero user fallback)
After=network-online.target graphical-session.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=3
ExecStart=$PZ_DECKY_HOME/services/PluginLoader
WorkingDirectory=$PZ_DECKY_HOME/services
Environment=PLUGIN_PATH=$PZ_DECKY_PLUGINS_DIR
Environment=UNPRIVILEGED_PATH=$PZ_DECKY_HOME
Environment=PRIVILEGED_PATH=$PZ_DECKY_HOME
Environment=LOG_LEVEL=INFO

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now plugin_loader.service
    pz_info "Decky user fallback service enabled: $service"
}

github_latest_asset() {
    local repo="$1" regex="$2"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
        jq -r --arg regex "$regex" '
            .assets[]
            | select(.name | test($regex; "i"))
            | [.name, .browser_download_url]
            | @tsv
        ' | head -1
}

database_archive_asset() {
    local plugin="$1" meta html repo sha
    meta="$(curl -fsSL "https://api.github.com/repos/SteamDeckHomebrew/decky-plugin-database/contents/plugins/$plugin?ref=main")"
    html="$(jq -r '.html_url // empty' <<< "$meta")"
    repo="$(jq -r '.submodule_git_url // empty' <<< "$meta")"
    sha="$(jq -r '.sha // empty' <<< "$meta")"
    case "$html" in
        https://github.com/*/tree/*)
            sha="${html##*/tree/}"
            repo="${repo%.git}"
            echo "${plugin}.decky-database.zip	${repo}/archive/${sha}.zip"
            ;;
        "")
            repo="${repo%.git}"
            if [[ "$repo" == https://github.com/* ]] && [ -n "$sha" ]; then
                echo "${plugin}.decky-database.zip	${repo}/archive/${sha}.zip"
            elif [[ "$repo" == https://gitlab.com/* ]] && [ -n "$sha" ]; then
                local base
                base="$(basename "$repo")"
                echo "${plugin}.decky-database.zip	${repo}/-/archive/${sha}/${base}-${sha}.zip"
            else
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

install_zip_plugin() (
    local id="$1" zip="$2" target_name="$3" tmp stage_dir staged_plugin plugin_root target backup="" backup_dir health
    require_cmds unzip jq python3 || return 1
    ensure_plugin_dirs || return 1
    [[ "$target_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        pz_error "unsafe plugin target name: $target_name"
        return 1
    }
    if [ ! -w "$PZ_DECKY_PLUGINS_DIR" ] && [ "$EUID" -ne 0 ]; then
        pz_warn "plugin dir is not writable: $PZ_DECKY_PLUGINS_DIR"
        return 1
    fi
    tmp="$(mktemp -d)" || return 1
    stage_dir="$(mktemp -d "$PZ_DECKY_PLUGINS_DIR/.phasezero-install.XXXXXX")" || {
        rm -rf "$tmp"
        return 1
    }
    trap 'rm -rf "$tmp" "$stage_dir"' EXIT
    validate_zip_archive "$zip" || return 1
    unzip -q -- "$zip" -d "$tmp" || return 1
    if find "$tmp" -type l -print -quit | grep -q .; then
        pz_error "Decky package contains symbolic links"
        return 1
    fi
    if ! plugin_root="$(find_packaged_plugin_root "$tmp")"; then
        return 1
    fi
    staged_plugin="$stage_dir/$target_name"
    install -d "$staged_plugin" || return 1
    cp -a "$plugin_root"/. "$staged_plugin"/ || return 1
    download_remote_binaries_for_plugin "$staged_plugin" || return 1
    health="$(plugin_health_json "$id" "$staged_plugin")" || return 1
    if [ "$(jq -r '.ok' <<< "$health")" != true ]; then
        pz_error "$id package failed validation: $(jq -r '.issue' <<< "$health")"
        return 1
    fi
    target="$PZ_DECKY_PLUGINS_DIR/$target_name"
    if [ -e "$target" ] || [ -L "$target" ]; then
        backup_dir="$PZ_DECKY_HOME/plugin-backups"
        install -d "$backup_dir" || return 1
        backup="$backup_dir/${target_name}.bak.$(date +%Y%m%d%H%M%S).$$"
        if ! mv "$target" "$backup"; then
            pz_warn "could not backup plugin: $target"
            return 1
        fi
        pz_info "backup plugin: $backup"
    fi
    if ! mv "$staged_plugin" "$target"; then
        pz_error "could not activate plugin: $target"
        if [ -n "$backup" ] && [ ! -e "$target" ]; then
            mv "$backup" "$target" || pz_error "automatic rollback failed: $backup -> $target"
        fi
        return 1
    fi
    pz_info "installed Decky plugin: $id -> $target"
)

install_store_plugin_via_decky() {
    local artifact="$1" name="$2" version="$3" hash="$4" client="$PZ_ROOT/linux/steamdeck/decky-ws-client.py"
    [ "$(decky_port_bool)" = true ] || return 1
    python3 - <<'PY' >/dev/null 2>&1 || return 1
import aiohttp
PY
    pz_info "installing $name through Decky Loader websocket"
    python3 "$client" install-plugin --artifact "$artifact" --name "$name" --version "$version" --hash "$hash"
}

wait_plugin_healthy() {
    local id="$1" candidates="$2" budget="${PZ_DECKY_PLUGIN_READY_TIMEOUT:-20}" i path health
    for ((i = 1; i <= budget; i++)); do
        path="$(plugin_path_by_candidates "$candidates" || true)"
        health="$(plugin_health_json "$id" "$path")"
        if [ "$(jq -r '.ok' <<< "$health")" = true ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

install_store_plugin() {
    local id="$1" store="$2" display="$3" candidates="$4" entry store_name version safe_version hash artifact zip partial got_hash
    require_cmds curl jq sha256sum unzip
    entry="$(deckbrew_plugin_json "$store" "$display" "$id" || true)"
    if [ -z "$entry" ]; then
        pz_warn "$id: Deckbrew store entry not found"
        return 1
    fi
    store_name="$(jq -r '.name // empty' <<< "$entry")"
    version="$(jq -r '.versions[0].name // empty' <<< "$entry")"
    hash="$(jq -r '.versions[0].hash // empty' <<< "$entry")"
    artifact="$(jq -r '.versions[0].artifact // empty' <<< "$entry")"
    if [ -z "$version" ] || ! [[ "$hash" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        pz_warn "$id: Deckbrew version/hash invalid"
        return 1
    fi
    if [ -z "$artifact" ] || [ "$artifact" = "null" ] || ! safe_download_url "$artifact"; then
        artifact="$PZ_DECKBREW_CDN_URL/$hash.zip"
    fi
    safe_download_url "$artifact" || {
        pz_warn "$id: Deckbrew package URL must use HTTPS"
        return 1
    }
    install -d "$PZ_DECKY_CACHE"
    safe_version="${version//[^A-Za-z0-9._-]/_}"
    zip="$PZ_DECKY_CACHE/${id}-${safe_version}.deckbrew.zip"
    partial="$zip.part.$$"
    pz_info "downloading $id from Deckbrew store: $version"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 268435456 -o "$partial" "$artifact"; then
        rm -f "$partial"
        return 1
    fi
    mv "$partial" "$zip"
    got_hash="$(sha256sum "$zip" | awk '{print $1}')"
    if [ "$got_hash" != "$hash" ]; then
        rm -f "$zip"
        pz_warn "$id: Deckbrew package checksum mismatch"
        return 1
    fi
    if [ "$EUID" -ne 0 ] && [ "${PZ_DECKY_STORE_VIA_WS:-1}" = "1" ] && install_store_plugin_via_decky "file://$zip" "$store_name" "$version" "$hash"; then
        if wait_plugin_healthy "$id" "$candidates"; then
            pz_info "installed and verified Decky store plugin through loader: $store_name $version"
            return 0
        fi
        pz_warn "$id: Decky Loader reported success but installed package did not become healthy"
    fi
    install_zip_plugin "$id" "$zip" "${candidates%%,*}"
}

install_release_zip_plugin() {
    local id="$1" repo="$2" candidates="$3" regex asset_name asset_url zip target_name
    regex="$(release_asset_regex "$id")"
    IFS=$'\t' read -r asset_name asset_url < <(github_latest_asset "$repo" "$regex")
    if [ -z "${asset_url:-}" ]; then
        pz_warn "$id: release ZIP not found; use Decky store/developer ZIP install"
        return 1
    fi
    safe_download_url "$asset_url" || { pz_warn "$id: release package URL must use HTTPS"; return 1; }
    install -d "$PZ_DECKY_CACHE"
    zip="$PZ_DECKY_CACHE/$asset_name"
    pz_info "downloading $id: $asset_name"
    curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 268435456 -o "$zip" "$asset_url"
    target_name="${candidates%%,*}"
    install_zip_plugin "$id" "$zip" "$target_name"
}

install_database_plugin() {
    local id="$1" candidates="$2" asset_name asset_url zip target_name
    IFS=$'\t' read -r asset_name asset_url < <(database_archive_asset "$id" || true)
    if [ -z "${asset_url:-}" ]; then
        pz_warn "$id: packaged Decky artifact unavailable"
        return 1
    fi
    safe_download_url "$asset_url" || {
        pz_warn "$id: Decky database archive URL must use HTTPS"
        return 1
    }
    install -d "$PZ_DECKY_CACHE"
    zip="$PZ_DECKY_CACHE/$asset_name"
    pz_info "downloading $id from Decky plugin database"
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 --max-filesize 268435456 -o "$zip.part.$$" "$asset_url"; then
        rm -f "$zip.part.$$"
        pz_warn "$id: packaged archive download failed"
        return 1
    fi
    mv "$zip.part.$$" "$zip"
    target_name="${candidates%%,*}"
    install_zip_plugin "$id" "$zip" "$target_name"
}

quarantine_broken_plugin() {
    local id="$1" candidates="$2" path health disabled_dir target
    path="$(plugin_path_by_candidates "$candidates" || true)"
    [ -n "$path" ] || return 0
    health="$(plugin_health_json "$id" "$path")"
    [ "$(jq -r '.ok' <<< "$health")" != true ] || return 0
    case "$path" in
        "$PZ_DECKY_PLUGINS_DIR"/*) ;;
        *) pz_error "refusing to quarantine path outside plugin directory: $path"; return 1 ;;
    esac
    if [ ! -w "$PZ_DECKY_PLUGINS_DIR" ] && [ "$EUID" -ne 0 ]; then
        pz_warn "$id cannot be quarantined without elevated write access: $path"
        return 1
    fi
    disabled_dir="$PZ_DECKY_HOME/disabled-plugins"
    install -d "$disabled_dir"
    target="$disabled_dir/$(basename "$path").disabled.$(date +%Y%m%d%H%M%S).$$"
    mv "$path" "$target"
    pz_warn "quarantined incomplete Decky plugin: $id -> $target"
}

install_catalog_plugin() {
    local id="$1" store="$2" display="$3" mode="$4" repo="$5" candidates="$6"
    case "$mode" in
        database)
            if install_store_plugin "$id" "$store" "$display" "$candidates"; then
                return 0
            fi
            if [ ! -w "$PZ_DECKY_PLUGINS_DIR" ] && [ "$EUID" -ne 0 ]; then
                pz_warn "$id: direct packaged fallback skipped; plugin dir is not writable"
                pz_warn "run: linux/pz steamdeck plugins install-plugin-privileged $id"
                return 1
            fi
            install_database_plugin "$id" "$candidates"
            ;;
        zip)
            install_release_zip_plugin "$id" "$repo" "$candidates"
            ;;
        store)
            install_store_plugin "$id" "$store" "$display" "$candidates"
            ;;
        unsupported)
            pz_error "$id: no verified packaged Decky artifact is available"
            return 1
            ;;
        *)
            pz_warn "$id: unknown install mode $mode"
            return 1
            ;;
    esac
}

install_curated_plugins() {
    local id display store mode homepage repo candidates note path health healthy failures=0
    require_cmds curl jq
    ensure_plugin_dirs
    repair_permissions
    # Store installs go through Decky's websocket on :1337. Wait for it so the
    # first run after a loader install does not silently fail and only succeed
    # on a later retry (the intermittent CSS Loader symptom).
    wait_decky_ready || true
    while IFS='|' read -r id display store mode homepage repo candidates note; do
        [ -z "$id" ] && continue
        path="$(plugin_path_by_candidates "$candidates" || true)"
        health="$(plugin_health_json "$id" "$path")"
        healthy="$(jq -r '.ok' <<< "$health")"
        if [ "$mode" = "unsupported" ]; then
            if [ -n "$path" ] && [ "$healthy" != true ]; then
                quarantine_broken_plugin "$id" "$candidates" || failures=$((failures + 1))
            else
                pz_info "$display skipped: no verified packaged Decky artifact available"
            fi
            continue
        fi
        if [ -n "$path" ] && [ "$healthy" = true ] && [ "$PZ_DECKY_FORCE" != "1" ]; then
            pz_info "$display already installed: $path"
            continue
        fi
        if [ -n "$path" ] && [ "$healthy" != true ]; then
            pz_warn "$display incomplete: $(jq -r '.issue' <<< "$health")"
        fi
        if [ -n "$path" ] && [ ! -w "$(dirname "$path")" ] && [ "$EUID" -ne 0 ] && [ "$(decky_port_bool)" != true ]; then
            pz_warn "$display cannot be repaired without elevated write access: $path"
            pz_warn "run: linux/pz steamdeck plugins install-plugin-privileged $id"
            continue
        fi
        case "$mode" in
            zip|database|store) install_catalog_plugin "$id" "$store" "$display" "$mode" "$repo" "$candidates" || failures=$((failures + 1)) ;;
            *)
                pz_warn "$display: unknown install mode $mode"
                ;;
        esac
    done < <(plugin_catalog)
    if [ "$failures" -ne 0 ]; then
        pz_warn "$failures curated plugin(s) failed; status will show remaining gaps"
        return 1
    fi
}

install_one_plugin() {
    local requested="${1:-}" id display store mode homepage repo candidates note
    [ -n "$requested" ] || { pz_error "usage: plugins.sh install-plugin <id|store-name>"; return 1; }
    while IFS='|' read -r id display store mode homepage repo candidates note; do
        [ -z "$id" ] && continue
        if [ "$requested" = "$id" ] || [ "$requested" = "$store" ] || [ "${requested,,}" = "${display,,}" ]; then
            install_catalog_plugin "$id" "$store" "$display" "$mode" "$repo" "$candidates"
            return $?
        fi
    done < <(plugin_catalog)
    pz_error "unknown plugin: $requested"
    return 1
}

install_one_plugin_privileged() {
    local requested="${1:-}"
    [ -n "$requested" ] || { pz_error "usage: plugins.sh install-plugin-privileged <id|store-name>"; return 1; }
    enable_cef_debug
    if [ "$EUID" -eq 0 ]; then
        PZ_DECKY_FORCE=1 PZ_DECKY_STORE_VIA_WS=0 install_one_plugin "$requested"
    else
        pz_admin_run env HOME="$HOME" USER="$USER" PZ_DECKY_FORCE=1 PZ_DECKY_STORE_VIA_WS=0 \
            bash "$0" install-plugin "$requested"
    fi
    restart_decky_loader
}

install_curated_plugins_privileged() {
    enable_cef_debug
    if [ "$EUID" -eq 0 ]; then
        PZ_DECKY_FORCE=1 PZ_DECKY_STORE_VIA_WS=0 install_curated_plugins
    else
        pz_admin_run env HOME="$HOME" USER="$USER" PZ_DECKY_FORCE=1 PZ_DECKY_STORE_VIA_WS=0 \
            bash "$0" install-plugins
    fi
    restart_decky_loader
}

repair_broken_plugins() {
    local id display store mode homepage repo candidates note path health failures=0 repaired=0
    require_cmds curl jq
    ensure_plugin_dirs
    while IFS='|' read -r id display store mode homepage repo candidates note; do
        [ -n "$id" ] || continue
        path="$(plugin_path_by_candidates "$candidates" || true)"
        [ -n "$path" ] || continue
        health="$(plugin_health_json "$id" "$path")"
        [ "$(jq -r '.ok' <<< "$health")" != true ] || continue
        pz_warn "$display incomplete: $(jq -r '.issue' <<< "$health")"
        if [ "$mode" = "unsupported" ]; then
            quarantine_broken_plugin "$id" "$candidates" || failures=$((failures + 1))
        elif install_catalog_plugin "$id" "$store" "$display" "$mode" "$repo" "$candidates"; then
            repaired=$((repaired + 1))
        else
            failures=$((failures + 1))
        fi
    done < <(plugin_catalog)
    pz_info "Decky repair completed: $repaired package(s) replaced, $failures failure(s)"
    [ "$failures" -eq 0 ]
}

repair_broken_plugins_privileged() {
    local result=0
    enable_cef_debug
    if [ "$EUID" -eq 0 ]; then
        PZ_DECKY_STORE_VIA_WS=0 repair_broken_plugins || result=1
    else
        pz_admin_run env HOME="$HOME" USER="$USER" PZ_DECKY_STORE_VIA_WS=0 \
            bash "$0" repair-broken || result=1
    fi
    restart_decky_loader
    return "$result"
}

phasezero_theme_content() {
    local kind="$1"
    case "$kind" in
        json)
            cat <<'EOF'
{
  "name": "PhaseZero SteamOS Plus",
  "description": "Conservative SteamOS-like polish for BigLinux/Steam Deck sessions.",
  "author": "PhaseZero",
  "version": "1.0.0",
  "manifest_version": 6,
  "inject": {
    "shared.css": ["SP", "MainMenu", "QuickAccess", "notificationtoasts.*"]
  },
  "target": "System-Wide"
}
EOF
            ;;
        css)
            cat <<'EOF'
:root {
  --phasezero-focus: #66c0f4;
  --phasezero-bg: #0e141b;
}

.gamepadui_BasicHome_3LYP1.gamepadui_OpaqueBackground_b084m,
.gamepadhome_TabbedContent_cE1Sa {
  background-color: var(--phasezero-bg);
}

.gpfocus,
.gpfocuswithin {
  outline-color: var(--phasezero-focus);
}
EOF
            ;;
    esac
}

install_phasezero_theme() {
    local dir="$PZ_DECKY_THEMES_DIR/PhaseZero SteamOS Plus"
    ensure_plugin_dirs
    install -d "$dir"
    phasezero_theme_content json > "$dir/theme.json"
    phasezero_theme_content css > "$dir/shared.css"
    pz_info "installed CSS Loader theme: $dir"
}

migrate_legacy_theme_resources() {
    local legacy="$PZ_DECKY_THEMES_DIR/resources" backup
    [ -d "$legacy" ] || return 0
    [ ! -f "$legacy/theme.json" ] || return 0
    backup="$PZ_DECKY_HOME/theme-resources-backups/resources.$(date +%Y%m%d%H%M%S).$$"
    install -d "$(dirname "$backup")"
    mv "$legacy" "$backup"
    pz_info "moved non-theme resources outside CSS Loader scan path: $backup"
}

install_github_dir_theme() {
    local display="$1" source="$2" repo subdir zip tmp root
    repo="${source%%:*}"
    subdir="${source#*:}"
    if [ -z "$repo" ] || [ -z "$subdir" ]; then
        pz_error "invalid theme source: $source"
        return 1
    fi
    require_cmds curl unzip
    ensure_plugin_dirs
    install -d "$PZ_DECKY_CACHE/themes"
    zip="$PZ_DECKY_CACHE/themes/${repo//\//-}.zip"
    tmp="$(mktemp -d)"
    curl -fL --retry 3 --connect-timeout 15 -o "$zip" "https://github.com/$repo/archive/refs/heads/main.zip"
    validate_zip_archive "$zip" || { rm -rf "$tmp"; return 1; }
    unzip -q "$zip" -d "$tmp"
    root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -d "$root/$subdir" ] || { rm -rf "$tmp"; pz_error "theme dir not found in archive: $subdir"; return 1; }
    rm -rf "${PZ_DECKY_THEMES_DIR:?}/$display"
    cp -a "$root/$subdir" "$PZ_DECKY_THEMES_DIR/$display"
    rm -rf "$tmp"
    pz_info "installed CSS Loader theme: $display"
}

install_theme() {
    local requested="${1:-phasezero}" id display mode source note
    while IFS='|' read -r id display mode source note; do
        [ "$requested" = "$id" ] || [ "${requested,,}" = "${display,,}" ] || continue
        case "$mode" in
            local) install_phasezero_theme ;;
            github-dir) install_github_dir_theme "$display" "$source" ;;
            *) pz_error "unknown theme install mode: $mode"; return 1 ;;
        esac
        return 0
    done < <(theme_catalog)
    pz_error "unknown theme: $requested"
    return 1
}

install_curated_themes() {
    local id failures=0
    migrate_legacy_theme_resources
    for id in phasezero obsidian round centered-home; do
        install_theme "$id" || failures=$((failures + 1))
    done
    [ "$failures" -eq 0 ] || pz_warn "$failures theme(s) failed; CSS Loader theme manager can install them later"
    return 0
}

restart_decky_loader() {
    reconcile_decky_services
    # A non-Steam process squatting :8080 (e.g. an AI proxy) breaks CSS Loader
    # and other CEF-attached plugins after a Decky restart. Surface it so the
    # user knows plugins will keep failing until the squatter is gone.
    if [ "$(steam_cef_conflict_bool)" = true ]; then
        pz_warn "port 8080 is held by a non-Steam process; CSS Loader will fail until it is freed"
        pz_warn "stop the squatter (often an AI proxy) or run: linux/pz ai proxy status"
    fi
    if [ "$(service_state system)" != "" ] && [ "$(service_state system)" != "unknown" ]; then
        if pz_admin_run systemctl restart plugin_loader.service 2>/dev/null; then
            pz_info "restarted system plugin_loader.service"
            wait_decky_ready || true
            return 0
        fi
    fi
    if [ "$(service_state system)" = "active" ]; then
        pz_info "system plugin_loader.service already active"
        wait_decky_ready || true
        return 0
    fi
    if systemctl --user list-unit-files plugin_loader.service >/dev/null 2>&1; then
        systemctl --user restart plugin_loader.service 2>/dev/null && {
            pz_info "restarted user plugin_loader.service"
            wait_decky_ready || true
            return 0
        }
    fi
    pz_warn "Decky restart skipped; reboot or Return to Gaming Mode if plugins do not appear"
}

prepare_steam_ui() {
    local restart="${1:-no}" i budget="${PZ_STEAM_READY_TIMEOUT:-180}" unit="phasezero-steam-bootstrap.service"
    enable_cef_debug
    reconcile_decky_services
    if [ "$(steam_cef_port_bool)" = true ]; then
        pz_info "Steam CEF debug port already listening"
        return 0
    fi

    if pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1; then
        if [ "$restart" != "restart" ] && [ "${PZ_DECKY_RESTART_STEAM:-0}" != "1" ]; then
            pz_warn "Steam is running without CEF debug port; restart Steam/Gamepad UI required"
            pz_warn "run: PZ_DECKY_RESTART_STEAM=1 linux/pz steamdeck plugins prepare-ui"
            return 0
        fi
        pz_info "shutting down Steam so CEF debug marker can take effect"
        steam -shutdown >/dev/null 2>&1 || true
        sleep 5
    fi

    if command -v steam >/dev/null 2>&1; then
        if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
            systemctl --user stop "$unit" >/dev/null 2>&1 || true
            systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
            systemd-run --user --unit="${unit%.service}" --collect --service-type=exec \
                --working-directory="$HOME" steam -gamepadui -steamos3 -cef-enable-debugging >/dev/null
        else
            setsid -f steam -gamepadui -steamos3 -cef-enable-debugging >/dev/null 2>&1
        fi
        pz_info "waiting up to ${budget}s for Steam CEF; client updates may delay first start"
        for ((i = 1; i <= budget; i++)); do
            if [ "$(steam_cef_port_bool)" = true ]; then
                pz_info "Steam Gamepad UI ready with CEF debug after ${i}s"
                return 0
            fi
            sleep 1
        done
        if pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1; then
            pz_warn "Steam started, but CEF debug port 8080 is not listening after ${budget}s"
            pz_warn "verify Steam Gamepad UI is visible; then run: linux/pz steamdeck plugins status"
        else
            pz_warn "Steam Gamepad UI did not stay running"
            pz_warn "run manually to inspect errors: steam -gamepadui -steamos3 -cef-enable-debugging"
        fi
    else
        pz_warn "steam command missing"
    fi
}

dry_run_plan() {
    cat <<EOF
PhaseZero Decky plugins dry-run
  Decky Loader: install/reinstall via official decky-installer $PZ_DECKY_CHANNEL script
  Plugin dir: $PZ_DECKY_PLUGINS_DIR
  Permissions: verify plugin/theme dirs are writable
  CEF debug: enable ~/.steam/steam/.cef-enable-remote-debugging
  Plugins: install curated set from Decky plugin database where possible
  Store packages: require checksum-verified Deckbrew package/CDN; never install raw source trees
  TDP plugin: PowerTools, requires privileged system Decky service for full control
  TDP fallback: PhaseZero privileged ryzenadj bridge
  Themes: CSS Loader + PhaseZero/Obsidian/Round/Centered-Home under $PZ_DECKY_THEMES_DIR
  Big Picture: launch with steam -gamepadui -steamos3, then open Quick Access Menu -> plug icon
EOF
}

print_guide() {
    cat <<EOF
PhaseZero Decky plugin guide

Commands:
  linux/pz steamdeck plugins status
  linux/pz steamdeck plugins install
  linux/pz steamdeck plugins install-decky-privileged
  linux/pz steamdeck plugins install-plugins-privileged
  linux/pz steamdeck plugins install-plugin PowerTools
  linux/pz steamdeck plugins install-plugin-privileged PowerTools
  linux/pz steamdeck plugins repair
  linux/pz steamdeck plugins restart
  linux/pz steamdeck plugins prepare-ui
  linux/pz steamdeck plugins theme list
  linux/pz steamdeck plugins theme install phasezero

Big Picture path:
  1. Start Steam Gamepad UI: steam -gamepadui -steamos3
  2. Open Quick Access Menu.
  3. Select plug icon.
  4. Open Store.
  5. Verify: PowerTools, CSS Loader, Animation Changer, ProtonDB, HLTB, SteamGridDB.
  6. CSS Loader -> Manage Themes -> enable PhaseZero/Obsidian/Round as desired.

Notes:
  PowerTools: needs privileged system Decky service for plugin-side TDP/SMT controls.
  PowerTools repair: use install-plugin-privileged when backend is missing.
  PhaseZero TDP fallback: sudo linux/steamdeck/install-privileged-controls.sh install.
  Decky LSFG-VK: requires Lossless Scaling Steam app and launch option ~/lsfg %command%.
  NonSteamLaunchers: no verified Decky bundle currently published; incomplete snapshots are quarantined.
  Alternative: use PhaseZero non-Steam launcher integration.
  CSS Loader: themes live under $PZ_DECKY_THEMES_DIR.
EOF
}

install_all() {
    install_decky_loader
    wait_decky_ready || true
    install_curated_plugins
    install_curated_themes
    reconcile_decky_services
    restart_decky_loader
    print_guide
}

repair_all() {
    local result=0
    ensure_plugin_dirs
    enable_cef_debug
    reconcile_decky_services
    repair_permissions
    migrate_legacy_plugin_backups || result=1
    migrate_legacy_theme_resources || result=1
    repair_broken_plugins || result=1
    restart_decky_loader
    status_json
    return "$result"
}

theme_action() {
    local sub="${1:-status}" arg="${2:-}"
    case "$sub" in
        status|json) themes_json ;;
        list) theme_catalog ;;
        install) install_theme "${arg:-phasezero}" ;;
        install-curated|apply) install_curated_themes ;;
        *) pz_error "usage: plugins.sh theme (status|list|install <id>|install-curated)"; return 1 ;;
    esac
}

if [ "${PZ_DECKY_LIB_ONLY:-0}" = "1" ]; then
    if [ "${BASH_SOURCE[0]}" != "$0" ]; then
        return 0
    fi
    exit 0
fi

case "$ACTION" in
    status|json) status_json ;;
    dry-run|plan) dry_run_plan ;;
    install|setup) install_all ;;
    plugins|install-plugins) install_curated_plugins ;;
    install-plugins-privileged) install_curated_plugins_privileged ;;
    repair-plugins-privileged|repair-broken-privileged) repair_broken_plugins_privileged ;;
    install-plugin) install_one_plugin "${1:-}" ;;
    install-plugin-privileged|repair-plugin-privileged) install_one_plugin_privileged "${1:-}" ;;
    theme|themes) theme_action "${1:-status}" "${2:-}" ;;
    install-themes) install_curated_themes ;;
    cef|enable-cef-debug) enable_cef_debug ;;
    prepare-ui|prepare-steam-ui) prepare_steam_ui "${1:-no}" ;;
    install-decky-privileged|privileged|system-install) install_decky_loader_privileged ;;
    decky|install-decky) install_decky_loader ;;
    repair) repair_all ;;
    repair-broken) repair_broken_plugins ;;
    restart|reload) restart_decky_loader ;;
    guide|help) print_guide ;;
    *) pz_error "usage: plugins.sh (status|dry-run|install|install-decky|install-decky-privileged|install-plugins|install-plugins-privileged|repair-plugins-privileged|install-plugin|install-plugin-privileged|install-themes|theme|enable-cef-debug|prepare-ui|repair|restart|guide)"; exit 1 ;;
esac
