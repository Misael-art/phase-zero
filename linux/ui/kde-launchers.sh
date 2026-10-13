#!/usr/bin/env bash
# Install and verify the organized PhaseZero KDE application set.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
ICON_DIR="$ICON_ROOT/scalable/apps"
ICON_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/icon-cache.kcache"
ICON_CACHE_REPAIR_MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/kde-launchers/hicolor-cache-v2"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
WRAPPER="$LOCAL_BIN/phasezero-kde-launch"
SOURCE_WRAPPER="$PZ_ROOT/linux/ui/kde-launch.sh"
SOURCE_ICONS="$PZ_ROOT/assets/icons/hicolor/scalable/apps"
MANAGED_PZ="${PZ_KDE_PZ_BIN:-/usr/lib/phasezero/linux/pz}"
LEGACY_INCOMPLETE_HICOLOR_INDEX_SHA256="3e1bb1e899b61b7e2fa8ca690341c403e0084e9ac9d8f2bbaa6b5f462eabe9ed"

remove_legacy_incomplete_icon_index() {
    local index="$ICON_ROOT/index.theme" actual="" backup="" previous=""
    if [ -f "$index" ]; then
        actual="$(sha256sum "$index" | awk '{print $1}')"
    elif previous="$(pz_backup_latest "$index" 2>/dev/null)"; then
        actual="$(sha256sum "$previous" | awk '{print $1}')"
    fi
    [ "$actual" = "$LEGACY_INCOMPLETE_HICOLOR_INDEX_SHA256" ] || return 0

    if [ -f "$index" ]; then
        backup="$(pz_backup_file "$index" user)"
        rm -f -- "$index"
        ledger_record \
            --module kde-launchers \
            --action remove-incomplete-hicolor-index \
            --modified "$index" \
            --backup "$backup" \
            --scope user \
            --reversible true \
            --rollback-cmd "cp -p -- $(printf '%q' "$backup") $(printf '%q' "$index")"
        pz_info "removed legacy incomplete hicolor index: $index"
    fi

    [ -e "$ICON_CACHE_REPAIR_MARKER" ] && return 0
    if [ -f "$ICON_CACHE" ]; then
        backup="$(pz_backup_file "$ICON_CACHE" user)"
        rm -f -- "$ICON_CACHE"
        ledger_record \
            --module kde-launchers \
            --action invalidate-stale-plasma-icon-cache \
            --modified "$ICON_CACHE" \
            --backup "$backup" \
            --scope user \
            --reversible true \
            --rollback-cmd "cp -p -- $(printf '%q' "$backup") $(printf '%q' "$ICON_CACHE")"
        pz_info "invalidated stale Plasma icon cache: $ICON_CACHE"
    fi
    mkdir -p "$(dirname "$ICON_CACHE_REPAIR_MARKER")"
    printf '%s\n' "$LEGACY_INCOMPLETE_HICOLOR_INDEX_SHA256" > "$ICON_CACHE_REPAIR_MARKER"
    chmod 0600 "$ICON_CACHE_REPAIR_MARKER"
    PZ_ICON_CACHE_REPAIRED=1
}

launcher_rows() {
    cat <<'EOF'
control-center|io.phasezero.ControlCenter.desktop|PhaseZero Control Center|Auditoria, instalação e recuperação|io.phasezero.ControlCenter|system.tools|
port-steam|phasezero-port-steam.desktop|Port_Steam Control Center|Central de jogos, emulação e Steam Deck|phasezero-port-steam|games.frontends|
9router|phasezero-9router.desktop|9Router Dashboard|Roteamento de IA PhaseZero|phasezero-9router|web.ai|
windows-vm|phasezero-windows-vm.desktop|Windows VM|Iniciar Windows virtual em tela cheia|phasezero-windows-vm|system.machines|
reboot-windows-vm|phasezero-reboot-windows-vm.desktop|Reiniciar no Windows VM|Boot único protegido para Windows VM|phasezero-windows-reboot|system.boot|
reboot-steamos|phasezero-reboot-steamos-plus.desktop|Reiniciar no SteamOS Plus|Boot único protegido para SteamOS Plus|system-reboot|system.boot|
deck-handheld|phasezero-steamdeck-handheld.desktop|Steam Deck — Modo portátil|Aplicar perfil da tela integrada|phasezero-deck-handheld|system.steamdeck|Meta+Shift+F1
deck-monitor|phasezero-steamdeck-docked-monitor.desktop|Steam Deck — Monitor|Aplicar perfil dock com monitor|phasezero-deck-monitor|system.steamdeck|Meta+Shift+F2
deck-tv|phasezero-steamdeck-docked-tv.desktop|Steam Deck — TV|Aplicar perfil dock para televisão|phasezero-deck-tv|system.steamdeck|Meta+Shift+F3
keyboard|phasezero-virtual-keyboard.desktop|Teclado virtual|Mostrar ou ocultar teclado na tela|phasezero-keyboard|system.steamdeck|Meta+Shift+F4
steam-gamepad|phasezero-steam-gamepad-ui.desktop|Steam — Interface para controle|Abrir Steam Gamepad UI|phasezero-steam-gamepad|system.steamdeck|Meta+Shift+F5
deck-desktop|phasezero-steamdeck-dev.desktop|Steam Deck — Modo desktop|Aplicar sessão desktop e desenvolvimento|phasezero-deck-desktop|system.steamdeck|Meta+Shift+F6
shortcuts|phasezero-shortcut-cheatsheet.desktop|Atalhos PhaseZero|Mostrar tabela de atalhos|phasezero-shortcuts|system.tools|Meta+Shift+F7
voice|phasezero-voice-typing.desktop|Digitação por voz|Gravar, transcrever localmente e digitar|phasezero-voice|system.tools|Meta+Shift+F8
odysseus|phasezero-odysseus.desktop|Odysseus|Workspace de IA gerenciado|phasezero-odysseus|web.ai|
hermes|phasezero-hermes.desktop|Hermes|Agente Hermes gerenciado|phasezero-hermes|web.ai|
ollama|phasezero-ollama.desktop|Ollama|Modelos locais gerenciados|phasezero-ollama|web.ai|
proxy-kimi|phasezero-proxy-kimi.desktop|Proxy Kimi|Proxy OpenAI compatível para Kimi|phasezero-proxy-kimi|web.ai|
proxy-qwen|phasezero-proxy-qwen.desktop|Proxy Qwen|Proxy OpenAI compatível para Qwen|phasezero-proxy-qwen|web.ai|
proxy-deepseek|phasezero-proxy-deepseek.desktop|Proxy DeepSeek|Proxy OpenAI compatível para DeepSeek|phasezero-proxy-deepseek|web.ai|
proxy-mimo|phasezero-proxy-mimo.desktop|Proxy MiMo|Proxy OpenAI compatível para MiMo|phasezero-proxy-mimo|web.ai|
proxy-antigravity|phasezero-proxy-antigravity.desktop|Proxy Antigravity|Serviço Antigravity local|phasezero-proxy-generic|web.ai|
proxy-antigravity-adapter|phasezero-proxy-antigravity-adapter.desktop|Adaptador Antigravity OpenAI|Adaptador OpenAI local|phasezero-proxy-generic|web.ai|
proxy-ollie|phasezero-proxy-ollie.desktop|OllieProxy|Proxy local Ollie|phasezero-proxy-generic|web.ai|
proxy-unlimited|phasezero-proxy-unlimited.desktop|Unlimited AI Proxy|Proxy local OpenAI compatível|phasezero-proxy-generic|web.ai|
EOF
}

icon_names() {
    launcher_rows | awk -F'|' '{print $5}' | sort -u
}

desktop_body() {
    local id="$1" name="$2" comment="$3" icon="$4" shortcut="$5"
    cat <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=$comment
Exec=$WRAPPER $id
TryExec=$WRAPPER
Icon=$icon
Terminal=false
Categories=X-PhaseZero;
StartupNotify=false
${shortcut:+X-KDE-Shortcuts=$shortcut}
EOF
}

install_all() {
    local id file name comment icon group shortcut source target
    install -d "$APP_DIR" "$ICON_DIR" "$LOCAL_BIN"
    [ -x "$SOURCE_WRAPPER" ] || chmod +x "$SOURCE_WRAPPER"
    pz_write_managed_file "$WRAPPER" user < "$SOURCE_WRAPPER"
    chmod 0755 "$WRAPPER"
    # hicolor already has a complete system index. A local partial index shadows
    # it and makes native icons stored in 16x16..1024x1024 disappear in KDE.
    # Remove only the exact legacy PhaseZero file; preserve any user-owned index.
    remove_legacy_incomplete_icon_index
    while IFS= read -r icon; do
        if [ "$icon" = "io.phasezero.ControlCenter" ]; then
            source="$PZ_ROOT/packaging/linux/io.phasezero.ControlCenter.svg"
        else
            source="$SOURCE_ICONS/$icon.svg"
        fi
        target="$ICON_DIR/$icon.svg"
        [ -f "$source" ] || { pz_error "missing launcher icon: $source"; return 1; }
        pz_write_managed_file "$target" user < "$source"
        chmod 0644 "$target"
    done < <(icon_names)
    while IFS='|' read -r id file name comment icon group shortcut; do
        [ -n "$id" ] || continue
        desktop_body "$id" "$name" "$comment" "$icon" "$shortcut" |
            pz_desktop_write_entry "$APP_DIR/$file" "$group"
        chmod 0644 "$APP_DIR/$file"
    done < <(launcher_rows)
    # SteamZero ships its own system launcher. The PhaseZero alias has the
    # clearer Port_Steam name and dedicated icon; a user override hides only
    # the duplicate menu entry without touching /usr/local or SteamZero files.
    if [ -f /usr/local/share/applications/org.steamzero.SteamZero.desktop ] ||
        command -v steamzero >/dev/null 2>&1; then
        pz_write_managed_file "$APP_DIR/org.steamzero.SteamZero.desktop" user <<EOF
[Desktop Entry]
Type=Application
Name=SteamZero
Exec=/usr/local/bin/steamzero desktop ui
Icon=phasezero-port-steam
Terminal=false
NoDisplay=true
Categories=X-PhaseZero;
X-PhaseZero-Managed=true
X-PhaseZero-MenuGroup=games.frontends
X-PhaseZero-SuppressedBy=phasezero-port-steam.desktop
EOF
    fi
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 &&
        gtk-update-icon-cache --force --ignore-theme-index "$ICON_ROOT" >/dev/null 2>&1 || true
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        if [ "${PZ_ICON_CACHE_REPAIRED:-0}" = "1" ]; then
            kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
        else
            kbuildsycoca6 >/dev/null 2>&1 || true
        fi
    fi
    pz_info "PhaseZero KDE launchers installed"
}

backend_state() {
    local id="$1" status="" proxy="" row="" web_status=""
    case "$id" in
        control-center)
            if command -v phasezero-control-center >/dev/null 2>&1 || [ -x /usr/bin/phasezero-control-center ]; then
                echo ready
            else
                echo not-installed
            fi
            ;;
        port-steam)
            if command -v steamzero >/dev/null 2>&1 || [ -x /usr/local/bin/steamzero ]; then
                echo ready
            else
                echo not-installed
            fi
            ;;
        9router)
            status="$("$MANAGED_PZ" ai 9router status 2>/dev/null || true)"
            jq -e '.healthy == true' <<< "$status" >/dev/null 2>&1 && echo ready || echo degraded
            ;;
        windows-vm)
            status="$("$MANAGED_PZ" windows-vm status --json 2>/dev/null || true)"
            jq -e '.health.readyToLaunch == true' <<< "$status" >/dev/null 2>&1 && echo ready || echo blocked
            ;;
        reboot-windows-vm)
            status="$("$MANAGED_PZ" windows-vm status --json 2>/dev/null || true)"
            jq -e '.health.bootDirectReady == true' <<< "$status" >/dev/null 2>&1 && echo ready || echo blocked
            ;;
        reboot-steamos) echo ready ;;
        deck-*|steam-gamepad|shortcuts) echo ready ;;
        keyboard)
            status="$("$MANAGED_PZ" steamdeck keyboard status 2>/dev/null || true)"
            if jq -e '.ready == true' <<< "$status" >/dev/null 2>&1 ||
                { jq -e '.kde.available == true' <<< "$status" >/dev/null 2>&1 && command -v onboard >/dev/null 2>&1; }; then
                echo ready
            else
                echo degraded
            fi
            ;;
        voice)
            status="$(bash "$(dirname "$(dirname "$MANAGED_PZ")")/linux/steamdeck/voice-typing.sh" status 2>/dev/null || true)"
            jq -e '.whisper != "" and .whisper != null and .modelPresent == true and .recorder == true' <<< "$status" >/dev/null 2>&1 && echo ready || echo degraded
            ;;
        odysseus|hermes|ollama) echo blocked-policy ;;
        proxy-*)
            case "$id" in
                proxy-kimi) proxy=kimiproxy ;;
                proxy-qwen) proxy=qwenproxy ;;
                proxy-deepseek) proxy=deepsproxy ;;
                proxy-mimo) proxy=mimo-ai-proxy ;;
                proxy-antigravity) proxy=antigravity-proxy ;;
                proxy-antigravity-adapter) proxy=antigravity-openai-adapter ;;
                proxy-ollie) proxy=ollieproxy ;;
                proxy-unlimited) proxy=unlimited-ai-proxy ;;
            esac
            status="$("$MANAGED_PZ" ai proxies detailed-status 2>/dev/null || true)"
            row="$(jq -c --arg id "$proxy" '.proxies[]? | select(.id == $id)' <<< "$status" 2>/dev/null || true)"
            if ! jq -e '.installed == true' <<< "$row" >/dev/null 2>&1; then
                echo not-installed
            else
                web_status="$(jq -r '.webValidation.status // "unknown"' <<< "$row")"
                case "$web_status" in
                    authenticated|configured|not-required) echo ready ;;
                    *) echo "$web_status" ;;
                esac
            fi
            ;;
        *) echo unknown ;;
    esac
}

status_json() {
    local first=true id file name comment icon group shortcut desktop icon_file state launcher_ok icon_ok desktop_ok
    printf '{"schemaVersion":1,"items":['
    while IFS='|' read -r id file name comment icon group shortcut; do
        [ -n "$id" ] || continue
        desktop="$APP_DIR/$file"; icon_file="$ICON_DIR/$icon.svg"
        launcher_ok=false; icon_ok=false; desktop_ok=false
        [ -x "$WRAPPER" ] && launcher_ok=true
        [ -s "$icon_file" ] && icon_ok=true
        if [ -s "$desktop" ] && grep -qx "Icon=$icon" "$desktop" &&
            grep -qx "X-PhaseZero-MenuGroup=$group" "$desktop"; then desktop_ok=true; fi
        state="$(backend_state "$id")"
        $first || printf ','; first=false
        jq -cn --arg id "$id" --arg name "$name" --arg desktop "$desktop" --arg icon "$icon_file" \
            --arg backend "$state" --argjson launcher "$launcher_ok" --argjson iconOk "$icon_ok" --argjson desktopOk "$desktop_ok" \
            '{id:$id,name:$name,desktop:$desktop,icon:$icon,launcherReady:$launcher,desktopReady:$desktopOk,iconReady:$iconOk,backend:$backend}'
    done < <(launcher_rows)
    printf ']}'
}

verify_all() {
    local payload
    payload="$(status_json)"
    jq '. + {ready:([.items[] | select((.launcherReady and .desktopReady and .iconReady) | not)] | length == 0),summary:{total:(.items|length),launcherReady:([.items[]|select(.launcherReady)]|length),desktopReady:([.items[]|select(.desktopReady)]|length),iconReady:([.items[]|select(.iconReady)]|length),backendReady:([.items[]|select(.backend=="ready")]|length),blockedPolicy:([.items[]|select(.backend=="blocked-policy")]|length),notInstalled:([.items[]|select(.backend=="not-installed")]|length)}}' <<< "$payload"
}

case "$ACTION" in
    install|apply|repair) install_all ;;
    status|verify) verify_all ;;
    plan|dry-run) launcher_rows ;;
    *) pz_error "usage: kde-launchers.sh (plan|install|status|verify)"; exit 2 ;;
esac
