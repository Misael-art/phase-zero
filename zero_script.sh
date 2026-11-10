#!/usr/bin/env bash
# PhaseZero Zero Script — bootstrap host from zero to PhaseZero + AI proxies.
set -euo pipefail

VERSION="1.0.0"
SELF="$(realpath "${BASH_SOURCE[0]}")"
PZ_REPO="${PZ_REPO:-https://github.com/Misael-art/phase-zero.git}"
PZ_DIR="${PZ_DIR:-$HOME/PhaseZero}"
DRY_RUN=0
SKIP_DEPS=0
SKIP_CLONE=0
SKIP_PROXIES=0
SKIP_START=0
SKIP_ADMIN_BRIDGE=0
SKIP_MEMORY=0
SKIP_OLLAMA=0
SKIP_DOCKER=0
SKIP_MCP=0
YES=0

RED=; GREEN=; YELLOW=; BLUE=; BOLD=; RESET=
if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[0m')
fi

log_info()  { printf '%s\n' "${GREEN}INFO:${RESET}  $*"; }
log_warn()  { printf '%s\n' "${YELLOW}WARN:${RESET}  $*"; }
log_error() { printf '%s\n' "${RED}ERROR:${RESET} $*"; }
log_step()  { printf '\n%s\n' "${BLUE}${BOLD}==>${RESET}${BOLD} $*${RESET}"; }
log_cmd()   { printf '  %s\n' "${YELLOW}\$${RESET} $*"; }

run() {
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "$@"
        return 0
    fi
    "$@"
}

sudo_run() {
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "sudo $*"
        return 0
    fi
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        log_error "sudo required but not available. Run as root or install sudo."
        exit 1
    fi
}

prompt_yes() {
    local msg="$1"
    [ "$YES" = 1 ] && return 0
    printf '%s [S/n] ' "$msg"
    read -r resp
    case "${resp,,}" in
        ""|s|sim|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

detect_distro() {
    local id like=""
    if [ -f /etc/os-release ]; then
        id="$(grep -oP '^ID=(\K\w+)' /etc/os-release 2>/dev/null || true)"
        like="$(grep -oP '^ID_LIKE=(\K\w+)' /etc/os-release 2>/dev/null || true)"
    fi
    case "$id" in
        arch|archarm|biglinux) echo "arch"; return ;;
        debian|ubuntu|linuxmint|pop) echo "debian"; return ;;
        fedora) echo "fedora"; return ;;
        opensuse*|suse) echo "suse"; return ;;
    esac
    case "$like" in
        arch) echo "arch"; return ;;
        debian) echo "debian"; return ;;
        fedora) echo "fedora"; return ;;
        suse) echo "suse"; return ;;
    esac
    echo "unknown"
}

install_system_deps() {
    local distro="$1"
    log_step "Instalando dependencias do sistema (${distro})..."

    case "$distro" in
        arch)
            local pkgs=(
                pyside6 jq nodejs npm git curl go
                base-devel python xdg-utils perl
                openssh ca-certificates
            )
            log_info "pacman packages: ${pkgs[*]}"
            if command -v pacman >/dev/null 2>&1; then
                for pkg in "${pkgs[@]}"; do
                    pacman -Qi "$pkg" >/dev/null 2>&1 && continue
                    log_info "installing $pkg..."
                    run sudo pacman -S --needed --noconfirm "$pkg"
                done
            else
                log_error "pacman not found on arch-based distro."
                exit 1
            fi
            ;;

        debian)
            log_info "updating apt cache..."
            run sudo apt update -qq 2>/dev/null || true
            local pkgs=(
                python3-pyside6.qtwidgets jq nodejs npm
                git curl golang build-essential python3
                python3-pip python3-venv xdg-utils
                openssh-client ca-certificates
            )
            log_info "apt packages: ${pkgs[*]}"
            for pkg in "${pkgs[@]}"; do
                dpkg -s "$pkg" >/dev/null 2>&1 && continue
                log_info "installing $pkg..."
                run sudo apt install -y "$pkg"
            done
            ;;

        fedora)
            local pkgs=(
                python3-pyside6 jq nodejs npm git curl
                golang @development-tools python3 python3-pip
                xdg-utils openssh ca-certificates perl
            )
            log_info "dnf packages: ${pkgs[*]}"
            for pkg in "${pkgs[@]}"; do
                rpm -q "$pkg" >/dev/null 2>&1 && continue
                log_info "installing $pkg..."
                run sudo dnf install -y "$pkg"
            done
            ;;

        suse)
            local pkgs=(
                python3-pyside6 jq nodejs npm git curl
                go python3 python3-pip xdg-utils openssh
                ca-certificates perl
            )
            log_info "zypper packages: ${pkgs[*]}"
            for pkg in "${pkgs[@]}"; do
                rpm -q "$pkg" >/dev/null 2>&1 && continue
                log_info "installing $pkg..."
                run sudo zypper install -y "$pkg"
            done
            ;;

        *)
            log_error "Distro '$distro' nao suportada automaticamente."
            log_info "Instale manualmente: python3, PySide6, jq, nodejs, npm, git, curl, go, make, gcc, xdg-utils, openssh, perl, ca-certificates"
            exit 1
            ;;
    esac
}

ensure_pyside6() {
    log_step "Verificando PySide6..."
    if python3 -c 'import PySide6' >/dev/null 2>&1; then
        log_info "PySide6 OK ($(python3 -c 'import PySide6; print(PySide6.__version__)'))"
        return 0
    fi
    log_warn "PySide6 nao encontrado mesmo apos instalacao via pacote."
    log_info "Tentando pip install como fallback..."
    if command -v pip3 >/dev/null 2>&1; then
        run pip3 install PySide6 --break-system-packages 2>/dev/null || \
        run pip3 install PySide6 2>/dev/null || true
    fi
    if python3 -c 'import PySide6' >/dev/null 2>&1; then
        log_info "PySide6 instalado via pip."
    else
        log_warn "PySide6 ainda ausente. A UI nativa nao funcionara."
        log_info "Tente: sudo pacman -S pyside6 (Arch) / sudo apt install python3-pyside6.qtwidgets (Debian)"
    fi
}

ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    log_step "Instalando jq..."
    case "$DISTRO" in
        arch)   run sudo pacman -S --needed --noconfirm jq ;;
        debian) run sudo apt install -y jq ;;
        fedora) run sudo dnf install -y jq ;;
        suse)   run sudo zypper install -y jq ;;
    esac
}

clone_phasezero() {
    log_step "Clonando/atualizando PhaseZero..."
    if [ -d "$PZ_DIR/.git" ]; then
        log_info "Repositorio ja existe em $PZ_DIR"
        if prompt_yes "Atualizar?"; then
            log_info "Atualizando..."
            run git -C "$PZ_DIR" fetch --depth=1 origin
            run git -C "$PZ_DIR" reset --hard origin/main
            log_info "Atualizado para $(git -C "$PZ_DIR" rev-parse --short HEAD)."
        fi
    else
        log_info "Clonando $PZ_REPO para $PZ_DIR..."
        run git clone --depth=1 "$PZ_REPO" "$PZ_DIR"
        log_info "Clonado $(git -C "$PZ_DIR" rev-parse --short HEAD)."
    fi
}

install_pz_manual() {
    local local_bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local app_dir="$data_home/applications"
    local icon_dir="$data_home/icons/hicolor/scalable/apps"

    run mkdir -p "$local_bin" "$app_dir" "$icon_dir"

    run ln -sf "$PZ_DIR/linux/pz" "$local_bin/pz"

    local cc_launcher="$local_bin/phasezero-control-center"
    if [ ! -f "$cc_launcher" ]; then
        run install -m 0755 /dev/stdin "$cc_launcher" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
exec "$ROOT/linux/ui/native.sh" "$@"
SCRIPT
    fi

    if [ ! -f "$app_dir/io.phasezero.ControlCenter.desktop" ]; then
        cat > /tmp/pz-desktop << EOF
[Desktop Entry]
Type=Application
Name=PhaseZero
Comment=Central de Controle PhaseZero
Exec=$cc_launcher
Icon=io.phasezero.ControlCenter
Categories=System;Utility;
Terminal=false
EOF
        run install -m 0644 /tmp/pz-desktop "$app_dir/io.phasezero.ControlCenter.desktop"
    fi

    if [ ! -f "$icon_dir/io.phasezero.ControlCenter.svg" ]; then
        local icon_src="$PZ_DIR/packaging/linux/io.phasezero.ControlCenter.svg"
        [ -f "$icon_src" ] && run cp "$icon_src" "$icon_dir/io.phasezero.ControlCenter.svg"
    fi

    run update-desktop-database "$app_dir" 2>/dev/null || true
    log_info "Instalacao manual concluida."
}

install_pz_ui() {
    log_step "Instalando PhaseZero UI para o usuario..."
    local install_script="$PZ_DIR/packaging/linux/install-user.sh"
    if [ ! -f "$install_script" ]; then
        log_error "install-user.sh nao encontrado em $install_script"
        return 1
    fi
    run env PZ_ALLOW_DIRTY_SOURCE=1 bash "$install_script" || {
        log_warn "install-user.sh falhou (provalvemente repositorio sujo). Criando instalacao manual..."
        install_pz_manual
    }

    local local_bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local pz_link="$local_bin/pz"
    if [ ! -L "$pz_link" ] && [ ! -f "$pz_link" ]; then
        log_info "Criando symlink: $pz_link -> $PZ_DIR/linux/pz"
        run mkdir -p "$local_bin"
        run ln -sf "$PZ_DIR/linux/pz" "$pz_link"
        log_info "Comando 'pz' disponivel em PATH (adicione $local_bin ao PATH se necessario)."
    fi
    log_info "PhaseZero UI instalada. Acesse pelo menu de aplicativos ou terminal: phasezero-control-center"
}

install_docker() {
    log_step "Verificando Docker/Podman..."
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker OK ($(docker --version 2>/dev/null || echo version desconhecida))"
        return 0
    fi
    if command -v podman >/dev/null 2>&1; then
        log_info "Podman OK ($(podman --version 2>/dev/null || echo version desconhecida))"
        return 0
    fi
    log_info "Docker e Podman ausentes. Instalando Docker via gerenciador de pacotes..."
    local distro="$1"
    case "$distro" in
        arch)
            run sudo pacman -S --needed --noconfirm docker
            run sudo systemctl enable --now docker 2>/dev/null || true
            run sudo usermod -aG docker "$USER" 2>/dev/null || true
            ;;
        debian)
            run sudo apt install -y docker.io
            run sudo systemctl enable --now docker 2>/dev/null || true
            run sudo usermod -aG docker "$USER" 2>/dev/null || true
            ;;
        fedora)
            run sudo dnf install -y docker
            run sudo systemctl enable --now docker 2>/dev/null || true
            run sudo usermod -aG docker "$USER" 2>/dev/null || true
            ;;
        suse)
            run sudo zypper install -y docker
            run sudo systemctl enable --now docker 2>/dev/null || true
            run sudo usermod -aG docker "$USER" 2>/dev/null || true
            ;;
    esac
    log_info "Docker instalado. (Re-login para usar docker sem sudo.)"
}

install_admin_bridge() {
    log_step "Configurando ponte de admin (phasezero-admin / bigsudo)..."
    local script="$PZ_DIR/linux/ai/setup-admin-bridge.sh"
    if [ ! -f "$script" ]; then
        log_warn "setup-admin-bridge.sh nao encontrado em $script"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "bash $script setup"
        return 0
    fi
    bash "$script" setup || log_warn "admin-bridge falhou; continuando (nao critico)"
    log_info "Ponte de admin configurada."
}

install_ollama() {
    log_step "Instalando/configurando Ollama..."
    local script="$PZ_DIR/linux/ai/setup-ollama.sh"
    if [ ! -f "$script" ]; then
        log_warn "setup-ollama.sh nao encontrado em $script"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "bash $script"
        return 0
    fi
    bash "$script" || log_warn "ollama setup falhou; continuando"
    log_info "Ollama configurado."
}

install_ai_memory_step() {
    log_step "Instalando/configurando ai-memory (memoria persistente)..."
    local script="$PZ_DIR/linux/ai/setup-memory.sh"
    if [ ! -f "$script" ]; then
        log_warn "setup-memory.sh nao encontrado em $script"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "bash $script setup"
        return 0
    fi
    bash "$script" setup || log_warn "ai-memory setup falhou; continuando"
    log_info "ai-memory configurado."
}

sync_mcp_servers() {
    log_step "Sincronizando servidores MCP para todos os agentes..."
    local script="$PZ_DIR/linux/ai/mcp-manager.sh"
    if [ ! -f "$script" ]; then
        log_warn "mcp-manager.sh nao encontrado em $script"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "bash $script sync all"
        return 0
    fi
    bash "$script" sync all || log_warn "MCP sync falhou; continuando"
    log_info "MCP servers sincronizados."
}

install_proxies() {
    log_step "Instalando suite de proxies IA..."
    local proxy_script="$PZ_DIR/linux/ai/proxy-suite.sh"
    if [ ! -f "$proxy_script" ]; then
        log_error "proxy-suite.sh nao encontrado em $proxy_script"
        log_info "Certifique-se de que o repositorio foi clonado corretamente."
        exit 1
    fi

    log_info "Instalando proxies (PZ_NO_IDES=1 para evitar configurar IDEs ausentes)..."
    run env PZ_NO_IDES=1 bash "$proxy_script" install all
    log_info "Proxies instalados."
}

configure_ides_step() {
    local proxy_script="$PZ_DIR/linux/ai/proxy-suite.sh"
    log_step "Integrando proxies com IDEs..."
    if prompt_yes "IDEs (VS Code, Cursor, OpenCode, ZCode, Continue) ja estao instaladas?"; then
        run bash "$proxy_script" configure-ides
        log_info "IDEs configuradas."
    else
        log_info "Pulando. Execute depois quando as IDEs estiverem instaladas:"
        log_cmd "linux/pz ai proxies configure-ides"
    fi
}

start_proxies() {
    log_step "Iniciando servicos dos proxies..."
    if [ "$DRY_RUN" = 1 ]; then
        log_cmd "bash $PZ_DIR/linux/ai/proxy-suite.sh start all"
        return 0
    fi

    if ! systemctl --user daemon-reload 2>/dev/null; then
        log_warn "systemd user mode indisponivel. Pule --skip-start ou execute em um ambiente com systemd."
        return 0
    fi

    run bash "$PZ_DIR/linux/ai/proxy-suite.sh" start all
    log_info "Proxies iniciados."

    log_info "Aguardando servicos ficarem prontos..."
    sleep 3
    bash "$PZ_DIR/linux/ai/proxy-suite.sh" status | jq -c '.[] | {id, service}' 2>/dev/null || true
}

print_next_steps() {
    cat <<EOF

${BOLD}${GREEN}============================================${RESET}
${BOLD}${GREEN}  PhaseZero pronto para uso!${RESET}
${BOLD}${GREEN}============================================${RESET}

${BOLD}Componentes instalados:${RESET}
  Proxies IA: Kimi (3010), Qwen (3011), DeepSeek (3012), Mimo (3013)
  9Router (20128), Antigravity (8081/8090), Ollie (3002), Unlimited (8787)
  Ponte admin: phasezero-admin + bigsudo
  Memoria persistente: ai-memory (localhost:49374)
  MCP servers: sincronizados com agentes detectados
  Ollama + modelos: llama3.1, gemma3
  Docker/Podman: runtime de containers

${BOLD}Comandos uteis:${RESET}

  # Abrir a UI nativa (ja instalada no sistema):
  phasezero-control-center
  # ou via pz CLI:
  pz ui native

  # Fazer login OAuth nos proxies de browser:
  linux/pz ai proxies login kimiproxy    # Abre Chromium para login Kimi
  linux/pz ai proxies login qwenproxy    # Abre Chromium para login Qwen
  linux/pz ai proxies login deepsproxy   # Abre Chromium para login DeepSeek

  # Configurar tokens manuais do Mimo:
  ${EDITOR:-vi} ~/.config/phasezero/ai-proxies/mimo-ai-proxy.env

  # Ver status de autenticacao:
  linux/pz ai proxies auth

  # Ver status geral:
  linux/pz ai proxies status

  # Gateway de roteamento:
  linux/pz ai 9router dashboard

  # Integrar proxies com IDEs (se ainda nao fez):
  linux/pz ai proxies configure-ides

  # Gerenciar MCP servers:
  linux/pz ai mcp sync

  # Gerenciar memoria ai-memory:
  linux/pz ai memory status

  # Verificar atualizacoes:
  linux/pz updates check

${BOLD}Memoria persistente (ai-memory):${RESET}
  # Status do servico:
  systemctl --user status ai-memory
  # Logs:
  journalctl --user -u ai-memory -f
  # Testar conectividade:
  curl -s http://127.0.0.1:49374/health

${BOLD}MCP servers:${RESET}
  # Re-sincronizar para todos os agentes:
  linux/ai/mcp-manager.sh sync all
  # Ver status dos MCP instalados:
  linux/ai/mcp-manager.sh status

${BOLD}Ollama:${RESET}
  # Listar modelos baixados:
  ollama list
  # Puxar modelo adicional:
  ollama pull qwen2.5-coder:1.5b

${BOLD}Ponte admin:${RESET}
  # Ver status:
  linux/ai/setup-admin-bridge.sh status

${BOLD}Docker:${RESET}
  # Docker:
  docker --version
  # Podman (se preferir sem daemon):
  podman --version

${BOLD}Documentacao:${RESET}
  docs/linux-ai-proxies.md
  docs/ai-routing-workspace.md
  docs/ai-tools.md
EOF
}

usage() {
    cat <<EOF
PhaseZero Zero Script v${VERSION}
Prepara o host para executar o PhaseZero e sua suite de proxies IA.

Uso: ./zero_script.sh [opcoes]

Opcoes:
  --dry-run          Mostra comandos sem executar
  --dir PATH         Diretorio do repositorio PhaseZero (padrao: \$PZ_DIR)
  --repo URL         URL do repositorio (padrao: \$PZ_REPO)
  --skip-deps        Pula instalacao de pacotes do sistema
  --skip-clone       Pula clone/atualizacao do repositorio
  --skip-proxies     Pula instalacao dos proxies
  --skip-admin-bridge Pula configuracao do phasezero-admin/bigsudo
  --skip-memory      Pula instalacao do ai-memory
  --skip-ollama      Pula instalacao do Ollama
  --skip-docker      Pula instalacao do Docker
  --skip-mcp         Pula sincronizacao dos MCP servers
  --skip-start       Pula inicio dos servicos
  --minimal          So etapas essenciais (equivalente a --skip-admin-bridge --skip-memory --skip-ollama --skip-docker --skip-mcp)
  --full             Todas as etapas (padrao)
  --yes, -y          Nao perguntar confirmacoes
  --help, -h         Mostra esta mensagem

Uso tipico:
  curl -fsSL https://raw.githubusercontent.com/Misael-art/phase-zero/main/zero_script.sh | bash
  # ou apos clonar:
  ./zero_script.sh
EOF
    exit 0
}

main() {
    local DISTRO

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --dir) PZ_DIR="$2"; shift 2 ;;
            --dir=*) PZ_DIR="${1#*=}"; shift ;;
            --repo) PZ_REPO="$2"; shift 2 ;;
            --repo=*) PZ_REPO="${1#*=}"; shift ;;
            --skip-deps) SKIP_DEPS=1; shift ;;
            --skip-clone) SKIP_CLONE=1; shift ;;
            --skip-proxies) SKIP_PROXIES=1; shift ;;
            --skip-admin-bridge) SKIP_ADMIN_BRIDGE=1; shift ;;
            --skip-memory) SKIP_MEMORY=1; shift ;;
            --skip-ollama) SKIP_OLLAMA=1; shift ;;
            --skip-docker) SKIP_DOCKER=1; shift ;;
            --skip-mcp) SKIP_MCP=1; shift ;;
            --skip-start) SKIP_START=1; shift ;;
            --minimal)
                SKIP_ADMIN_BRIDGE=1; SKIP_MEMORY=1; SKIP_OLLAMA=1
                SKIP_DOCKER=1; SKIP_MCP=1; shift
                ;;
            --full) shift ;;
            --yes|-y) YES=1; shift ;;
            --help|-h) usage ;;
            *) log_error "opcao desconhecida: $1"; usage ;;
        esac
    done

    printf '%s\n' "${BOLD}PhaseZero Zero Script v${VERSION}${RESET}"
    printf '%s\n' "${BOLD}${BLUE}============================================${RESET}"

    [ "$DRY_RUN" = 1 ] && log_info "${YELLOW}*** MODO DRY-RUN — nenhum comando sera executado ***${RESET}"

    DISTRO="$(detect_distro)"
    log_info "Distro detectada: ${BOLD}$DISTRO${RESET}"

    if [ "$DISTRO" = "unknown" ]; then
        log_warn "Distro nao reconhecida. Tentando continuar com deteccao generica."
    fi

    if [ "$SKIP_DEPS" = 0 ]; then
        install_system_deps "$DISTRO"
        ensure_pyside6
    else
        log_info "Pulando instalacao de dependencias (--skip-deps)."
    fi

    if [ "$SKIP_CLONE" = 0 ]; then
        clone_phasezero
    else
        log_info "Pulando clone (--skip-clone)."
    fi

    if [ -d "$PZ_DIR" ]; then
        install_pz_ui
    fi

    if [ "$SKIP_PROXIES" = 0 ] && [ -d "$PZ_DIR" ]; then
        install_proxies
        configure_ides_step
    elif [ "$SKIP_PROXIES" = 0 ]; then
        log_warn "Repositorio PhaseZero nao encontrado em $PZ_DIR. Pula instalacao de proxies."
    else
        log_info "Pulando instalacao de proxies (--skip-proxies)."
    fi

    if [ -d "$PZ_DIR" ]; then
        if [ "$SKIP_DOCKER" = 0 ]; then
            install_docker "$DISTRO"
        else
            log_info "Pulando Docker (--skip-docker)."
        fi

        if [ "$SKIP_ADMIN_BRIDGE" = 0 ]; then
            ensure_jq
            install_admin_bridge
        else
            log_info "Pulando admin-bridge (--skip-admin-bridge)."
        fi

        if [ "$SKIP_OLLAMA" = 0 ]; then
            install_ollama
        else
            log_info "Pulando Ollama (--skip-ollama)."
        fi

        if [ "$SKIP_MEMORY" = 0 ]; then
            ensure_jq
            install_ai_memory_step
        else
            log_info "Pulando ai-memory (--skip-memory)."
        fi

        if [ "$SKIP_MCP" = 0 ]; then
            ensure_jq
            sync_mcp_servers
        else
            log_info "Pulando MCP servers (--skip-mcp)."
        fi
    fi

    if [ "$SKIP_START" = 0 ] && [ -d "$PZ_DIR" ] && [ "$SKIP_PROXIES" = 0 ]; then
        start_proxies
    else
        log_info "Pulando inicio dos servicos."
    fi

    if [ "$DRY_RUN" = 1 ]; then
        printf '\n%s\n' "${YELLOW}*** DRY-RUN COMPLETO — nenhuma alteracao foi feita ***${RESET}"
    fi

    print_next_steps
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
