#!/usr/bin/env bash
# Stable dispatcher for PhaseZero KDE launchers. Never prints secret values.
set -euo pipefail

APP_ID="${1:-}"
shift 2>/dev/null || true

find_pz() {
    local candidate
    for candidate in \
        "${PZ_KDE_PZ_BIN:-}" \
        /usr/lib/phasezero/linux/pz \
        "$HOME/.local/share/phasezero/current/linux/pz" \
        /mnt/sdcard/Projects/PhaseZero/linux/pz; do
        [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

PZ_BIN="$(find_pz || true)"

show_message() {
    local kind="$1" title="$2" message="$3"
    if command -v kdialog >/dev/null 2>&1; then
        case "$kind" in
            error) kdialog --title "$title" --error "$message" ;;
            sorry) kdialog --title "$title" --sorry "$message" ;;
            *) kdialog --title "$title" --msgbox "$message" ;;
        esac
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$message"
    else
        printf '%s: %s\n' "$title" "$message" >&2
    fi
}

fail() {
    show_message sorry "PhaseZero" "$1"
    return 69
}

require_pz() {
    [ -n "$PZ_BIN" ] || fail "Runtime PhaseZero não encontrado. Reinstale o PhaseZero Control Center."
}

pz_root() {
    dirname "$(dirname "$PZ_BIN")"
}

hotkey_action() {
    local action="$1" root script
    require_pz || return
    root="$(pz_root)"
    script="$root/linux/steamdeck/hotkey-actions.sh"
    [ -f "$script" ] || fail "Ação Steam Deck indisponível no runtime instalado."
    exec bash "$script" "$action"
}

terminal_run() {
    if command -v konsole >/dev/null 2>&1; then
        exec konsole --hold -e "$@"
    elif command -v xterm >/dev/null 2>&1; then
        exec xterm -hold -e "$@"
    fi
    exec "$@"
}

launch_port_steam() {
    local steamzero
    steamzero="$(command -v steamzero 2>/dev/null || true)"
    [ -n "$steamzero" ] || [ ! -x /usr/local/bin/steamzero ] || steamzero=/usr/local/bin/steamzero
    [ -n "$steamzero" ] || fail "Port_Steam Control Center não está instalado."
    exec "$steamzero" desktop ui
}

launch_control_center() {
    local control_center
    control_center="$(command -v phasezero-control-center 2>/dev/null || true)"
    [ -n "$control_center" ] || [ ! -x /usr/bin/phasezero-control-center ] || control_center=/usr/bin/phasezero-control-center
    [ -n "$control_center" ] || fail "PhaseZero Control Center não está instalado."
    exec "$control_center"
}

launch_9router() {
    local status
    require_pz || return
    status="$("$PZ_BIN" ai 9router status 2>/dev/null || true)"
    jq -e '.installed == true' <<< "$status" >/dev/null 2>&1 || fail "9Router não está instalado."
    if ! jq -e '.healthy == true' <<< "$status" >/dev/null 2>&1; then
        "$PZ_BIN" ai 9router start >/dev/null 2>&1 || fail "9Router instalado, mas não iniciou. Abra a Central PhaseZero para diagnóstico."
    fi
    exec "$PZ_BIN" ai 9router dashboard
}

launch_windows_vm() {
    local status
    require_pz || return
    status="$("$PZ_BIN" windows-vm status --json 2>/dev/null || true)"
    jq -e '.health.readyToLaunch == true' <<< "$status" >/dev/null 2>&1 ||
        fail "Windows VM não está pronta para iniciar. Abra a Central PhaseZero para ver o bloqueio."
    exec "$PZ_BIN" windows-vm launch --fullscreen
}

reboot_windows_vm() {
    local status
    require_pz || return
    status="$("$PZ_BIN" windows-vm status --json 2>/dev/null || true)"
    jq -e '.health.bootDirectReady == true' <<< "$status" >/dev/null 2>&1 ||
        fail "Boot direto Windows não está pronto. Reboot recusado para evitar tela quebrada."
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title "PhaseZero — Windows VM" --warningyesno \
            "Reiniciar agora e entrar uma vez no Windows VM?" || return 0
    else
        fail "Confirmação gráfica indisponível. Use a Central PhaseZero."
    fi
    exec "$PZ_BIN" windows-vm boot next-reboot
}

reboot_steamos() {
    require_pz || return
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title "PhaseZero — SteamOS Plus" --warningyesno \
            "Reiniciar agora e entrar uma vez no SteamOS Plus?" || return 0
    else
        fail "Confirmação gráfica indisponível. Use a Central PhaseZero."
    fi
    exec "$PZ_BIN" steamdeck boot next-reboot
}

launch_odysseus() {
    local status
    require_pz || return
    status="$("$PZ_BIN" ai odysseus status 2>/dev/null || true)"
    jq -e '.installed == true and .healthy == true' <<< "$status" >/dev/null 2>&1 ||
        fail "Odysseus indisponível. Política deste host mantém workloads Homelab desativados."
    exec "$PZ_BIN" ai odysseus open
}

launch_hermes() {
    command -v hermes >/dev/null 2>&1 ||
        fail "Hermes não instalado. Política deste host proíbe implantar este workload antes da validação Homelab."
    terminal_run hermes
}

launch_ollama() {
    command -v ollama >/dev/null 2>&1 ||
        fail "Ollama não instalado. Política deste host proíbe implantar este workload antes da validação Homelab."
    terminal_run ollama list
}

proxy_id() {
    case "$1" in
        proxy-kimi) printf 'kimiproxy\n' ;;
        proxy-qwen) printf 'qwenproxy\n' ;;
        proxy-deepseek) printf 'deepsproxy\n' ;;
        proxy-mimo) printf 'mimo-ai-proxy\n' ;;
        proxy-antigravity) printf 'antigravity-proxy\n' ;;
        proxy-antigravity-adapter) printf 'antigravity-openai-adapter\n' ;;
        proxy-ollie) printf 'ollieproxy\n' ;;
        proxy-unlimited) printf 'unlimited-ai-proxy\n' ;;
        *) return 1 ;;
    esac
}

launch_proxy() {
    local id="$1" proxy status row web_status kind port
    require_pz || return
    proxy="$(proxy_id "$id")" || fail "Proxy desconhecido."
    status="$("$PZ_BIN" ai proxies detailed-status 2>/dev/null || true)"
    row="$(jq -c --arg id "$proxy" '.proxies[]? | select(.id == $id)' <<< "$status" 2>/dev/null || true)"
    [ -n "$row" ] || fail "Estado do proxy não pôde ser lido."
    jq -e '.installed == true' <<< "$row" >/dev/null 2>&1 ||
        fail "$proxy não instalado. Instalação automática recusada: distribuição upstream ainda não possui allowlist de hashes."
    web_status="$(jq -r '.webValidation.status // "unknown"' <<< "$row")"
    kind="$(jq -r '.webValidation.kind // "unknown"' <<< "$row")"
    port="$(jq -r '.port // 0' <<< "$row")"
    case "$web_status" in
        missing-credentials)
            fail "$proxy precisa de credenciais. Configure-as pela Central PhaseZero; nenhum segredo é aberto no atalho."
            ;;
        ready-for-login|needs-login|session-present)
            "$PZ_BIN" ai proxies login "$proxy" || fail "Fluxo de login de $proxy não abriu."
            show_message info "PhaseZero — $proxy" "Conclua o login na janela do navegador. O serviço reinicia automaticamente."
            return 0
            ;;
    esac
    "$PZ_BIN" ai proxies start "$proxy" >/dev/null 2>&1 || fail "$proxy instalado, mas o serviço não iniciou."
    if [ "$port" -gt 0 ]; then
        show_message info "PhaseZero — $proxy" "Proxy ativo em http://127.0.0.1:$port/v1"
    else
        show_message info "PhaseZero — $proxy" "Proxy ativo."
    fi
    [ "$kind" != "browser-session" ] || return 0
}

case "$APP_ID" in
    control-center) launch_control_center ;;
    port-steam) launch_port_steam ;;
    9router) launch_9router ;;
    windows-vm) launch_windows_vm ;;
    reboot-windows-vm) reboot_windows_vm ;;
    reboot-steamos) reboot_steamos ;;
    deck-handheld) hotkey_action handheld ;;
    deck-monitor) hotkey_action docked-monitor ;;
    deck-tv) hotkey_action docked-tv ;;
    deck-desktop) hotkey_action dev ;;
    steam-gamepad) hotkey_action console ;;
    keyboard) hotkey_action keyboard ;;
    voice) hotkey_action voice ;;
    shortcuts) hotkey_action cheatsheet ;;
    odysseus) launch_odysseus ;;
    hermes) launch_hermes ;;
    ollama) launch_ollama ;;
    proxy-*) launch_proxy "$APP_ID" ;;
    *) fail "Aplicativo PhaseZero desconhecido: ${APP_ID:-vazio}" ;;
esac
