#!/usr/bin/env bash
# desktop.sh - lançadores .desktop do PhaseZero: agrupamento e anti-duplicação
#
# Dois contratos que esta lib existe para garantir:
#
# 1. ATALHO NUNCA FICA SOLTO NO MENU. Todo .desktop criado pelo PhaseZero é
#    marcado na ORIGEM com `X-PhaseZero-Managed=true` + `X-PhaseZero-MenuGroup`.
#    `linux/ui/menu.py` recolhe tudo que carrega essa marca para dentro da raiz
#    única "PhaseZero" e troca `Categories` por `X-PhaseZero;`, tirando a
#    entrada das categorias globais (Jogos, Desenvolvimento, ...).
#    Antes disso a marcação só era aplicada no `menu apply`, então qualquer
#    instalação nova soltava entrada no menu até alguém rodar o apply à mão.
#
# 2. APP JÁ INSTALADO NÃO É DUPLICADO. `pz_app_already_installed` procura o
#    app em todas as fontes que o usuário pode ter usado (pacman, flatpak,
#    binário no PATH, AppImage, .desktop de terceiro) antes de o PhaseZero
#    criar a própria versão.
set -euo pipefail

[ -n "${PZ_DESKTOP_SH_LOADED:-}" ] && return 0
PZ_DESKTOP_SH_LOADED=1

# Pasta de lançadores .desktop. Nome próprio: PZ_APPLICATIONS_DIR é a pasta
# de AppImages (~/Applications) no restante do projeto; reutilizar o nome
# aqui fazia a emulação baixar AppImages para dentro do menu.
PZ_DESKTOP_ENTRIES_DIR="${PZ_DESKTOP_ENTRIES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}"
PZ_MENU_DIRTY_FLAG="${PZ_MENU_DIRTY_FLAG:-$PZ_STATE/desktop-menu/dirty}"

# --- 1. agrupamento --------------------------------------------------------

# Grupos aceitos por linux/ui/menu.py (GROUPS). Manter em sincronia: um grupo
# desconhecido faz a entrada cair em `system.tools` em vez de falhar.
PZ_MENU_GROUPS="games.library games.frontends games.emulators games.tools \
web.communication web.media web.ai web.cloud web.productivity \
system.steamdeck system.boot system.machines system.tools"

pz_menu_group_valid() {
    case " $PZ_MENU_GROUPS " in *" ${1:-} "*) return 0 ;; *) return 1 ;; esac
}

# Sinaliza que o menu saiu de sincronia. `pz ui menu sync` usa isso para
# reagrupar sem precisar reescrever o menu inteiro a cada instalação.
pz_menu_mark_dirty() {
    [ "${PZ_DRY_RUN:-0}" = "1" ] && return 0
    pz_state_init
    mkdir -p "$(dirname "$PZ_MENU_DIRTY_FLAG")"
    printf '%s\n' "$(date -Iseconds)" > "$PZ_MENU_DIRTY_FLAG"
}

pz_menu_is_dirty() { [ -f "$PZ_MENU_DIRTY_FLAG" ]; }

pz_menu_clear_dirty() { rm -f "$PZ_MENU_DIRTY_FLAG"; }

# pz_desktop_write_entry <path> <menu-group> [scope]
#
# Lê o corpo do .desktop de stdin, carimba as marcas de gerenciamento e grava
# via pz_write_managed_file (que registra no ledger e faz backup central).
#
#   phasezero_desktop_body | pz_desktop_write_entry "$APPS/claude-desktop.desktop" web.ai
pz_desktop_write_entry() {
    local path="${1:-}" group="${2:-system.tools}" scope="${3:-user}" body
    [ -n "$path" ] || { pz_error "pz_desktop_write_entry: path vazio"; return 2; }
    pz_menu_group_valid "$group" || {
        pz_warn "grupo de menu desconhecido: $group (usando system.tools)"
        group="system.tools"
    }
    body="$(cat)"

    # remove marcas anteriores para a reescrita ser idempotente
    body="$(printf '%s\n' "$body" | grep -v '^X-PhaseZero-Managed=' \
        | grep -v '^X-PhaseZero-MenuGroup=' || true)"

    printf '%s\nX-PhaseZero-Managed=true\nX-PhaseZero-MenuGroup=%s\n' "$body" "$group" \
        | pz_write_managed_file "$path" "$scope"
    pz_menu_mark_dirty
}

# --- 2. anti-duplicação ----------------------------------------------------

# Normaliza um Exec para comparação: remove %U/%f, resolve o binário.
pz_desktop_normalize_exec() {
    local raw="${1:-}" first
    # shellcheck disable=SC2086
    set -- $raw
    for first in "$@"; do
        case "$first" in
            %*) continue ;;
            env|nohup|setsid) continue ;;
            *=*) continue ;;
            *) break ;;
        esac
    done
    first="${1:-}"
    [ -n "$first" ] || { printf '\n'; return 0; }
    basename -- "$first"
}

# .desktop de TERCEIRO (não gerenciado pelo PhaseZero) que já lança este app.
# Imprime o caminho do primeiro encontrado; vazio quando não há.
pz_desktop_find_foreign() {
    local name="${1:-}" exec_hint="${2:-}" dir file values entry_name entry_exec
    local -a dirs=()
    dirs+=("$PZ_DESKTOP_ENTRIES_DIR")
    dirs+=("/usr/share/applications")
    dirs+=("/var/lib/flatpak/exports/share/applications")
    dirs+=("${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/exports/share/applications")

    for dir in "${dirs[@]}"; do
        [ -d "$dir" ] || continue
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            # entradas nossas não contam como duplicata de nós mesmos
            grep -q '^X-PhaseZero-Managed=true' "$file" 2>/dev/null && continue
            case "$(basename "$file")" in phasezero-*|phz-*|io.phasezero.*) continue ;; esac

            entry_name="$(awk -F= '/^Name=/{print $2; exit}' "$file" 2>/dev/null || true)"
            entry_exec="$(awk -F= '/^Exec=/{sub(/^Exec=/,""); print; exit}' "$file" 2>/dev/null || true)"
            entry_exec="$(pz_desktop_normalize_exec "$entry_exec")"

            if [ -n "$name" ] && [ "${entry_name,,}" = "${name,,}" ]; then
                printf '%s\n' "$file"
                return 0
            fi
            if [ -n "$exec_hint" ] && [ -n "$entry_exec" ] \
                && [ "${entry_exec,,}" = "${exec_hint,,}" ]; then
                printf '%s\n' "$file"
                return 0
            fi
        done < <(find "$dir" -maxdepth 1 -type f -name '*.desktop' 2>/dev/null || true)
    done
    return 1
}

# pz_app_already_installed --name NOME [--bin BIN] [--pacman PKG] [--flatpak ID]
#                          [--appimage PADRÃO] [--desktop-exec EXEC]
#
# Imprime "<fonte>\t<evidência>" e retorna 0 quando o app JÁ existe no host por
# qualquer via. Retorna 1 quando não achou nada.
#
# A ordem importa: fontes de pacote primeiro (mais confiáveis), .desktop de
# terceiro por último (mais sujeito a falso positivo por nome).
pz_app_already_installed() {
    local name="" bin="" pkg="" flatpak_id="" appimage="" desktop_exec=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)         name="${2:-}"; shift 2 ;;
            --bin)          bin="${2:-}"; shift 2 ;;
            --pacman)       pkg="${2:-}"; shift 2 ;;
            --flatpak)      flatpak_id="${2:-}"; shift 2 ;;
            --appimage)     appimage="${2:-}"; shift 2 ;;
            --desktop-exec) desktop_exec="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -n "$pkg" ] && command -v pacman >/dev/null 2>&1; then
        # -T resolve `provides` (ex.: claude-desktop-bin fornece claude-desktop).
        if LC_ALL=C pacman -T "$pkg" >/dev/null 2>&1; then
            printf 'pacman\t%s\n' "$pkg"
            return 0
        fi
    fi

    if [ -n "$flatpak_id" ] && command -v flatpak >/dev/null 2>&1; then
        if flatpak info "$flatpak_id" >/dev/null 2>&1; then
            printf 'flatpak\t%s\n' "$flatpak_id"
            return 0
        fi
    fi

    if [ -n "$bin" ]; then
        local resolved
        resolved="$(command -v "$bin" 2>/dev/null || true)"
        # Nosso wrapper, ou um lançador cujo alvo sumiu, não é instalação de
        # terceiro (presence.live_executable aplica a mesma regra).
        case "$resolved" in
            "") ;;
            *"/.local/bin/phasezero-"*) ;;
            *)
                if PYTHONPATH="$PZ_ROOT" python3 -c 'import sys; from linux.capabilities.presence import live_executable as l; sys.exit(0 if l(sys.argv[1]) else 1)' "$resolved" 2>/dev/null; then
                    printf 'binary\t%s\n' "$resolved"; return 0
                fi
                ;;
        esac
    fi

    if [ -n "$appimage" ]; then
        local found
        found="$(find "$HOME/Applications" "$HOME/AppImages" "$HOME/.local/bin" "$HOME/.local/opt" \
            -maxdepth 2 -type f -iname "$appimage" 2>/dev/null | head -1 || true)"
        if [ -n "$found" ]; then
            printf 'appimage\t%s\n' "$found"
            return 0
        fi
    fi

    if [ -n "$name" ] || [ -n "$desktop_exec" ]; then
        local foreign
        if foreign="$(pz_desktop_find_foreign "$name" "$desktop_exec")"; then
            printf 'desktop\t%s\n' "$foreign"
            return 0
        fi
    fi

    return 1
}

# Açúcar para os instaladores: decide e já reporta.
# Retorna 0 = pode instalar. Retorna 3 = já existe, pule.
# PZ_ALLOW_DUPLICATE=1 força a instalação assumindo a duplicata.
pz_app_install_guard() {
    local hit source evidence
    if ! hit="$(pz_app_already_installed "$@")"; then
        return 0
    fi
    source="${hit%%$'\t'*}"
    evidence="${hit#*$'\t'}"
    if [ "${PZ_ALLOW_DUPLICATE:-0}" = "1" ]; then
        pz_warn "PZ_ALLOW_DUPLICATE=1: instalando mesmo já existindo via $source ($evidence)"
        return 0
    fi
    pz_info "já instalado via $source ($evidence); pulando para não duplicar"
    return 3
}
