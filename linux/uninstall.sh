#!/usr/bin/env bash
# uninstall.sh - remove tudo que o PhaseZero instalou/configurou no host do usuário,
# restaurando o estado padrão do OS. Preserva SEMPRE ~/Emulation.
#
# Segurança:
#   - dry-run por padrão; exclusão real exige: --apply --confirm PHASEZERO-WIPE
#   - guarda absoluta: nenhum alvo pode estar dentro de $PRESERVE (~/Emulation),
#     nem ser $HOME, "/", "" ou fora de $HOME.
#   - itens que exigem root (GRUB, /usr/local, systemd de sistema, bridge TDP,
#     flatpak overrides de sistema) NÃO são apagados aqui; são impressos como
#     comandos `sudo` para o usuário executar num terminal autenticado.
#
# Tiers:
#   (padrão)      estado/config/unidades/wrappers/launchers gerenciados pelo PhaseZero
#   --emulators   também remove AppImages de emuladores e plugins Decky instalados
#                 pelo PhaseZero (NÃO toca em ~/Emulation)
#   --all         padrão + --emulators
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PRESERVE="$HOME/Emulation"
APPLY=0
CONFIRM=""
WITH_EMULATORS=0
CONFIRM_TOKEN="PHASEZERO-WIPE"

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --dry-run|-n) APPLY=0 ;;
        --confirm=*) CONFIRM="${arg#*=}" ;;
        --confirm) : ;;                 # forma "--confirm TOKEN" tratada abaixo
        --emulators) WITH_EMULATORS=1 ;;
        --all) WITH_EMULATORS=1 ;;
        PHASEZERO-WIPE) CONFIRM="$arg" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
            exit 0 ;;
        *) pz_warn "flag desconhecida ignorada: $arg" ;;
    esac
done

REMOVED=0
SKIPPED=0
BYTES_PLAN=0

# --- guarda de segurança: alvo removível? ---------------------------------
is_safe_target() {
    local t="$1" real
    [ -n "$t" ] || return 1
    real="$(realpath -m -- "$t" 2>/dev/null || printf '%s' "$t")"
    case "$real" in
        "" | "/" | "$HOME" ) return 1 ;;
    esac
    # deve estar sob $HOME
    case "$real" in
        "$HOME"/*) ;;
        *) return 1 ;;
    esac
    # nunca sob ~/Emulation
    case "$real/" in
        "$PRESERVE"/*) return 1 ;;
    esac
    [ "$real" = "$PRESERVE" ] && return 1
    return 0
}

# --- remove um caminho (arquivo/dir) com dry-run --------------------------
rm_path() {
    local t="$1" real sz
    real="$(realpath -m -- "$t" 2>/dev/null || printf '%s' "$t")"
    [ -e "$real" ] || [ -L "$real" ] || return 0
    if ! is_safe_target "$real"; then
        pz_warn "PROTEGIDO (ignorado): $real"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    sz="$(du -sb "$real" 2>/dev/null | awk 'NR==1{print $1; exit}')" || true
    [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
    BYTES_PLAN=$((BYTES_PLAN + sz))
    if [ "$APPLY" = 1 ]; then
        rm -rf -- "$real"
        printf '  removido   %s\n' "$real"
    else
        printf '  [dry] rm   %s  (%s)\n' "$real" "$(numfmt --to=iec "${sz:-0}" 2>/dev/null || echo "${sz}B")"
    fi
    REMOVED=$((REMOVED + 1))
}

# --- unidades systemd --user do PhaseZero ---------------------------------
remove_user_units() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    [ -d "$dir" ] || return 0
    printf '\n== systemd --user (unidades PhaseZero) ==\n'
    shopt -s nullglob
    local unit base
    # parar/desabilitar unidades vivas
    for unit in "$dir"/phasezero-*.service "$dir"/phasezero-*.timer \
                "$dir"/phasezero-9router*.service "$dir"/phasezero-9router*.timer \
                "$dir"/phasezero-codexbar-health.*; do
        base="$(basename "$unit")"
        case "$base" in *.bak*|*.d) continue ;; esac
        if [ "$APPLY" = 1 ]; then
            systemctl --user disable --now "$base" >/dev/null 2>&1 || true
        else
            printf '  [dry] disable --now %s\n' "$base"
        fi
    done
    # remover arquivos de unidade + backups + drop-ins
    for unit in "$dir"/phasezero-*; do
        rm_path "$unit"
    done
    shopt -u nullglob
    if [ "$APPLY" = 1 ]; then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
}

# --- diretórios de estado/config/dados gerenciados ------------------------
remove_managed_dirs() {
    printf '\n== estado / config / dados PhaseZero ==\n'
    local d
    for d in \
        "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/phasezero" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/phasezero" \
        "$HOME/.9router" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/codexbar" \
        "$HOME/.codexbar" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/ai-usagebar" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/ai-memory" ; do
        rm_path "$d"
    done
}

# --- wrappers e binários em ~/.local/bin ----------------------------------
remove_bin_wrappers() {
    local bin="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
    [ -d "$bin" ] || return 0
    printf '\n== wrappers ~/.local/bin ==\n'
    shopt -s nullglob
    local f
    for f in "$bin"/phasezero-* "$bin"/9router; do
        rm_path "$f"
    done
    shopt -u nullglob
}

# --- configs de apps que apontavam para o 9Router removido ----------------
# O OpenCode recusa o config inteiro se um {file:} sumir; sem isso, remover o
# 9Router (opcional) derruba o OpenCode junto.
heal_dependent_configs() {
    printf '\n== configs dependentes do 9Router ==\n'
    if [ "$APPLY" = 1 ]; then
        python3 "$PZ_ROOT/linux/ai/opencode_9router_manager.py" heal >/dev/null 2>&1 ||
            printf 'aviso: falha ao reparar OpenCode; rode: pz ai opencode heal\n'
    else
        printf 'reparar providers quebrados do OpenCode (pz ai opencode heal)\n'
    fi
}

# --- launchers .desktop gerenciados ---------------------------------------
remove_desktop_launchers() {
    printf '\n== launchers .desktop PhaseZero ==\n'
    local apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    shopt -s nullglob
    local f
    for f in "$apps"/phasezero-*.desktop; do
        rm_path "$f"
    done
    # desktops do usuário criados pelo PhaseZero (marcados)
    local desk
    for desk in "$HOME/Área de trabalho" "$HOME/Desktop"; do
        [ -d "$desk" ] || continue
        for f in "$desk"/*.desktop; do
            grep -qiE 'phasezero|X-PhaseZero' "$f" 2>/dev/null && rm_path "$f"
        done
    done
    shopt -u nullglob
}

# --- arquivos de config totalmente gerenciados pelo PhaseZero -------------
remove_managed_marked_files() {
    printf '\n== arquivos de config marcados _managedBy=phasezero ==\n'
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    [ -d "$cfg" ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # só remove arquivos INTEIROS gerenciados; evita ~/Emulation por definição
        rm_path "$f"
    done < <(grep -rlZ '"_managedBy"[[:space:]]*:[[:space:]]*"phasezero"' "$cfg" 2>/dev/null | tr '\0' '\n')
}

# --- emuladores AppImage + plugins Decky (opt-in) -------------------------
remove_emulators() {
    printf '\n== emuladores AppImage + plugins Decky (--emulators) ==\n'
    printf '  (ROMs/saves em ~/Emulation permanecem intocados)\n'
    local apps="$HOME/Applications" f name
    shopt -s nullglob
    for f in "$apps"/*.AppImage "$apps"/*.AppImage.bak.*; do
        name="$(basename "$f")"
        case "$name" in
            EmuDeck*|Eden*|Citron*|citron_*|azahar*|Cemu*|DuckStation*|ES-DE*|Hydra*|RPCS3*|Ryujinx*|Vita3K*|shadPS4*|BigPEmu*)
                rm_path "$f" ;;
        esac
    done
    # plugins Decky instalados pelo PhaseZero
    local plug="$HOME/homebrew/plugins"
    for f in "$plug"/PowerTools "$plug"/SDH-CssLoader "$plug"/SDH-AnimationChanger; do
        rm_path "$f"
    done
    shopt -u nullglob
}

# --- itens que exigem root (apenas imprime comandos) ----------------------
print_root_items() {
    printf '\n== ITENS ROOT — rode você num terminal autenticado ==\n'
    cat <<EOF
  sudo linux/pz steamdeck boot remove        # entrada GRUB console SteamOS
  sudo linux/pz windows-vm boot remove        # entrada GRUB Windows VM
  sudo linux/pz waydroid boot remove          # entrada GRUB Waydroid
  sudo linux/pz server boot remove            # entrada GRUB homelab
  sudo linux/pz steamdeck privileged remove   # bridge root TDP/GPU + polkit
  sudo rm -rf /usr/local/lib/phasezero        # helpers de sistema
  sudo flatpak override --reset               # overrides flatpak de sistema (se aplicados)
  # OS-slim: se aplicado, reverta com: sudo linux/pz server slim restore
EOF
}

# --------------------------------------------------------------------------
main() {
    printf 'PhaseZero — desinstalação do host\n'
    printf 'Preservado SEMPRE: %s\n' "$PRESERVE"
    if [ "$APPLY" = 1 ]; then
        if [ "$CONFIRM" != "$CONFIRM_TOKEN" ]; then
            pz_error "exclusão real exige: --apply --confirm $CONFIRM_TOKEN"
            exit 2
        fi
        [ -d "$PRESERVE" ] || pz_warn "aviso: $PRESERVE não existe neste host"
        printf 'MODO: APLICAR (exclusão real)\n'
    else
        printf 'MODO: DRY-RUN (nada será removido). Para aplicar: --apply --confirm %s\n' "$CONFIRM_TOKEN"
    fi

    # limpeza limpa via verbos próprios dos módulos (idempotente, quando disponível)
    if [ "$APPLY" = 1 ]; then
        bash "$PZ_ROOT/linux/ai/setup-codexbar.sh" watchdog remove >/dev/null 2>&1 || true
        bash "$PZ_ROOT/linux/ai/setup-codexbar.sh" remove          >/dev/null 2>&1 || true
    fi

    remove_user_units
    remove_managed_dirs
    remove_bin_wrappers
    heal_dependent_configs
    remove_desktop_launchers
    remove_managed_marked_files
    [ "$WITH_EMULATORS" = 1 ] && remove_emulators
    print_root_items

    printf '\n== resumo ==\n'
    printf '  alvos %s: %d   protegidos/ignorados: %d\n' \
        "$([ "$APPLY" = 1 ] && echo removidos || echo planejados)" "$REMOVED" "$SKIPPED"
    printf '  espaço %s: %s\n' \
        "$([ "$APPLY" = 1 ] && echo liberado || echo a liberar)" \
        "$(numfmt --to=iec "$BYTES_PLAN" 2>/dev/null || echo "${BYTES_PLAN}B")"
    if [ "$APPLY" = 0 ]; then
        printf '\nRevise a lista acima. Se estiver correta, execute:\n'
        printf '  linux/uninstall.sh --apply --confirm %s%s\n' "$CONFIRM_TOKEN" \
            "$([ "$WITH_EMULATORS" = 1 ] && echo ' --emulators' || echo '')"
    fi
}

main
