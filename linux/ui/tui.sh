#!/usr/bin/env bash
# tui.sh - PhaseZero UI terminal fallback (whiptail-based)
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PZ_TUI_BACKTITLE="PhaseZero Linux v$(jq -r '.version // "?"' "$PZ_ROOT/version.json" 2>/dev/null || echo "?")"

pz_tui_height() {
    tput lines 2>/dev/null || echo 24
}

pz_tui_width() {
    tput cols 2>/dev/null || echo 80
}

pz_tui_menu() {
    local title="$1" text="$2" ht mn
    ht="$(pz_tui_height)"
    mn=$((ht - 8))
    [ "$mn" -lt 5 ] && mn=5
    shift 2
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "$title" \
        --menu "$text" \
        "$((ht - 6))" "$((80))" "$mn" \
        "$@"
}

pz_tui_msgbox() {
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "$1" \
        --msgbox "$2" \
        "$(( $(pz_tui_height) - 4 ))" "$((80))"
}

pz_tui_yesno() {
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "$1" \
        --yesno "$2" \
        "$(( $(pz_tui_height) - 4 ))" "$((80))"
}

pz_tui_infobox() {
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "$1" \
        --infobox "$2" \
        "$(( $(pz_tui_height) - 4 ))" "$((80))"
}

pz_tui_run() {
    local cmd="$*"
    pz_tui_infobox "Executando..." "$cmd" &
    local pid=$!
    bash -c "$cmd" 2>&1 || true
    kill "$pid" 2>/dev/null || true
}

pz_tui_show_output() {
    local title="$1" tmp rc=0
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    shift 1
    "$@" > "$tmp" 2>&1 || rc=$?
    # LUX-017: the result line is never hidden behind `|| true`.
    if [ "$rc" -eq 0 ]; then
        printf '\n✔ concluído\n' >> "$tmp"
    else
        printf '\n✖ falhou (código %s)\n' "$rc" >> "$tmp"
    fi
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "$title" \
        --textbox "$tmp" \
        "$(( $(pz_tui_height) - 4 ))" "$((80))"
    rm -f "$tmp"
}
main_menu() {
    while true; do
        choice=$(pz_tui_menu "Painel Principal" "Selecione um módulo:" \
            "overview"     "Visão geral do sistema" \
            "steamdeck"    "Steam Deck - modo, hotkeys, boot" \
            "emulation"    "Emulação - conteúdo, mídia, emuladores" \
            "ai"           "IA - Codex, Claude, Ollama, MCP" \
            "profiles"     "Perfis de instalação" \
            "doctor"       "Diagnóstico e reparos" \
            "exit"         "Sair" 3>&2 2>&1 1>&3) || true
        [ -z "$choice" ] && break
        case "$choice" in
            overview)     overview_menu ;;
            steamdeck)    steamdeck_menu ;;
            emulation)    emulation_menu ;;
            ai)           ai_menu ;;
            profiles)     profiles_menu ;;
            doctor)       doctor_menu ;;
            exit)         break ;;
        esac
    done
}

overview_menu() {
    pz_tui_show_output "Diagnóstico do Sistema" bash "$PZ_ROOT/linux/audit/doctor.sh"
}

steamdeck_menu() {
    # LUX-017: a TUI é somente leitura. Mudanças passam pela Central
    # (prévia, confirmação e registro): `pz ui`.
    while true; do
        choice=$(pz_tui_menu "Steam Deck" "Consultar estado (somente leitura):" \
            "status"       "Ver status atual" \
            "kb-status"    "Status do teclado virtual" \
            "decky-status" "Status Decky/plugins" \
            "boot-status"  "Status boot GRUB SteamOS" \
            "apply"        "Aplicar mudanças…" \
            "back"         "Voltar" 3>&2 2>&1 1>&3) || true
        [ -z "$choice" ] && break
        case "$choice" in
            status)  pz_tui_show_output "Status Steam Deck" bash "$PZ_ROOT/linux/steamdeck/status.sh" ;;
            kb-status) pz_tui_show_output "Teclado Virtual" "$PZ_ROOT/linux/pz" steamdeck keyboard status ;;
            decky-status) pz_tui_show_output "Decky/plugins" bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status ;;
            boot-status) pz_tui_show_output "Boot SteamOS" bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status ;;
            apply)   pz_tui_apply_hint ;;
            back)    break ;;
        esac
    done
}
emulation_menu() {
    while true; do
        choice=$(pz_tui_menu "Emulação" "Consultar estado e planos (somente leitura):" \
            "retrodeck-status" "Status ecossistema RetroDECK" \
            "shared-status" "Status conteúdo compartilhado" \
            "shared-plan"   "Plano conteúdo compartilhado" \
            "media-status"  "Status mídia" \
            "pc-status"     "Status jogos PC" \
            "pc-plan"       "Plano jogos PC" \
            "perf-status"   "Status performance Switch/PS3/PS4" \
            "emudeck"       "Status EmuDeck" \
            "srm"           "Status Steam ROM Manager" \
            "fixes"         "Reparos amigáveis disponíveis" \
            "layout"        "Ver layout de diretórios" \
            "apply"         "Aplicar mudanças…" \
            "back"          "Voltar" 3>&2 2>&1 1>&3) || true
        [ -z "$choice" ] && break
        case "$choice" in
            retrodeck-status) pz_tui_show_output "RetroDECK" bash "$PZ_ROOT/linux/emulation/retrodeck.sh" status ;;
            shared-status) pz_tui_show_output "Conteúdo Compartilhado" bash "$PZ_ROOT/linux/emulation/shared-content.sh" status ;;
            shared-plan)   pz_tui_show_output "Plano de Compartilhamento" bash "$PZ_ROOT/linux/emulation/shared-content.sh" plan ;;
            media-status)  pz_tui_show_output "Status Mídia" bash "$PZ_ROOT/linux/emulation/media.sh" status ;;
            pc-status)     pz_tui_show_output "Jogos PC" bash "$PZ_ROOT/linux/emulation/pc-games.sh" status ;;
            pc-plan)       pz_tui_show_output "Plano Jogos PC" bash "$PZ_ROOT/linux/emulation/pc-games.sh" plan ;;
            perf-status)   pz_tui_show_output "Performance Emuladores" bash "$PZ_ROOT/linux/emulation/performance.sh" status ;;
            emudeck)       pz_tui_show_output "Status EmuDeck" bash "$PZ_ROOT/linux/emulation/emudeck.sh" status ;;
            srm)           pz_tui_show_output "Status SRM" bash "$PZ_ROOT/linux/emulation/srm.sh" status ;;
            fixes)         pz_tui_show_output "Reparos Amigáveis" bash "$PZ_ROOT/linux/emulation/fixes.sh" list ;;
            layout)        pz_tui_show_output "Layout de Diretórios" bash "$PZ_ROOT/linux/emulation/bios.sh" layout ;;
            apply)         pz_tui_apply_hint ;;
            back) break ;;
        esac
    done
}

pz_tui_apply_hint() {
    pz_tui_msgbox "Aplicar mudanças" "O terminal só consulta estado.

Para instalar, reparar ou mudar o sistema use a Central:
  pz ui

Lá cada ação mostra o que vai mudar, pede confirmação e fica registrada em Resultados."
}
ai_menu() {
    while true; do
        choice=$(pz_tui_menu "Inteligência Artificial" "Ferramentas de IA:" \
            "status"       "Status IA" \
            "mcp-status"   "Status MCP" \
            "back"         "Voltar" 3>&2 2>&1 1>&3) || true
        [ -z "$choice" ] && break
        case "$choice" in
            status)    pz_tui_show_output "Status IA" bash "$PZ_ROOT/linux/ai/status.sh" ;;
            mcp-status) pz_tui_show_output "Status MCP" bash "$PZ_ROOT/linux/ai/mcp-manager.sh" status ;;
            back) break ;;
        esac
    done
}

profiles_menu() {
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    echo "Perfis disponíveis:" > "$tmp"
    for f in "$PZ_ROOT/profiles"/*.json; do
        local name; name="$(basename "$f" .json)"
        local desc; desc="$(jq -r '.description // "sem descrição"' "$f")"
        echo "  $name: $desc" >> "$tmp"
    done
    whiptail --backtitle "$PZ_TUI_BACKTITLE" \
        --title "Perfis" \
        --textbox "$tmp" \
        "$(( $(pz_tui_height) - 4 ))" "$((80))"
    rm -f "$tmp"
}

doctor_menu() {
    while true; do
        choice=$(pz_tui_menu "Diagnóstico" "Ferramentas de diagnóstico:" \
            "doctor"        "Diagnóstico completo" \
            "repair-plan"   "Plano de reparo" \
            "support"       "Gerar bundle de suporte" \
            "back"          "Voltar" 3>&2 2>&1 1>&3) || true
        [ -z "$choice" ] && break
        case "$choice" in
            doctor)      pz_tui_show_output "Diagnóstico" bash "$PZ_ROOT/linux/audit/doctor.sh" ;;
            repair-plan) pz_tui_show_output "Plano de Reparo" bash "$PZ_ROOT/linux/audit/repair-plan.sh" ;;
            support)     pz_tui_show_output "Bundle de Suporte" bash "$PZ_ROOT/linux/audit/support-bundle.sh" ;;
            back) break ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Verify whiptail available
    if ! command -v whiptail &>/dev/null; then
        pz_error "whiptail not found. Install with: sudo pacman -S libnewt"
        exit 1
    fi
    main_menu
fi
