from __future__ import annotations

import json
import re
from dataclasses import replace
from pathlib import Path

from .graphics_profiles import provision_graphics_options
from .models import ActionParameter, ActionSpec
from .platform import current_platform

CATEGORIES = (
    ("Visão geral", "view-dashboard", "Saúde, auditoria e suporte"),
    ("Perfis", "package-x-generic", "Instalações completas"),
    ("Linux", "distributor-logo", "Apps, serviços e otimizações do sistema"),
    ("Steam Deck", "input-gaming", "Modos, controles e SteamOS UX"),
    ("Windows VM", "computer", "QEMU/KVM e boot direto"),
    ("Waydroid", "phone", "Android, reparo e kiosk"),
    ("Servidor", "network-server", "Serviços deste computador: LLM local e Hermes"),
    ("Homelab", "folder-remote", "Stack home-server e outros computadores da casa"),
    ("Emulação", "applications-games", "Emuladores, mídia e integrações"),
    ("Boot Direto", "system-reboot", "GRUB, recuperação e próxima sessão"),
    ("Flatpak", "system-software-install", "Remotes, overrides e compatibilidade"),
    ("Recursos", "preferences-plugin", "Gaming, hardware, saúde e workstation"),
    ("Desenvolvimento", "applications-development", "Preparar ambientes de projeto"),
    ("Contas e conexões", "avatar-default", "Contas, sessões e acesso por aplicativo"),
    ("IA & Dev", "applications-development", "OpenCode, Claude, MCPs e agentes"),
    ("Proxies IA", "network-server", "Status de proxies e sessões; uso aguarda grants por requisição"),
    ("Roteamento IA", "network-transmit-receive", "Rotas por tarefa, política e cota"),
    ("Aplicativos", "applications-other", "Web apps, jogos e menus do desktop"),
    ("Ajustes", "preferences-system", "Gaming, navegador e desenvolvimento"),
    ("Temas", "preferences-desktop-theme", "Tema, acessibilidade e conforto visual"),
    ("Resultados", "text-x-log", "Histórico local de operações"),
)

# Technical AI surfaces keep their legacy page IDs but live under the AI home.
NESTED_CATEGORY_PARENTS = {
    "Proxies IA": "IA & Dev",
    "Roteamento IA": "IA & Dev",
}
NESTED_CATEGORIES = tuple(NESTED_CATEGORY_PARENTS)

# The dashboard "home" pseudo-category (Welcome back screen).
DASHBOARD = ("Início", "go-home", "Bem-vindo de volta ao PhaseZero")

# Sidebar sections group categories by context (EmuDeck-style grouping).
SIDEBAR_GROUPS = (
    ("Ações rápidas", ("Início", "Visão geral", "Linux", "Perfis")),
    ("Plataformas", ("Steam Deck", "Windows VM", "Waydroid", "Servidor", "Homelab", "Emulação")),
    ("Sistema", ("Boot Direto", "Flatpak", "Recursos", "Ajustes")),
    ("Desenvolvimento", ("Desenvolvimento",)),
    ("Inteligência artificial", ("IA & Dev",)),
    ("Contas e conexões", ("Contas e conexões",)),
    ("Desktop", ("Aplicativos", "Temas")),
    ("Histórico", ("Resultados",)),
)

# Curated dashboard cards: hero "Quick actions" and quieter "Tools & stuff".
DASHBOARD_QUICK = ("system.doctor", "profile.safe-base", "emulation.setup", "ai.status")
DASHBOARD_TOOLS = (
    "boot.selector",
    "steamdeck.status",
    "ai.opencode-free",
    "emulation.controllers",
    "flatpak.audit",
    "server.status",
)

# Automated provisioning exposes only profiles explicitly enabled by the
# versioned backend contract. Experimental profiles retain separate plan-only
# actions and can never drift into the installer selector.
WINDOWS_VM_GRAPHICS_OPTIONS: tuple[tuple[str, str, str], ...] = provision_graphics_options()


def _a(
    action_id: str,
    category: str,
    title: str,
    description: str,
    args: tuple[str, ...],
    icon: str,
    *,
    mutable: bool = False,
    preview: tuple[str, ...] | None = None,
    elevated: bool = False,
    badge: str = "",
    input_label: str = "",
    input_kind: str = "",
    keywords: tuple[str, ...] = (),
    group: str = "",
    visibility: str = "",
    platforms: tuple[str, ...] = ("linux",),
    risk: str = "",
    parameters: tuple[ActionParameter, ...] = (),
    preview_bindings: tuple[tuple[str, str], ...] = (),
    result_view: str = "auto",
    stdin_parameter: str = "",
    stdin_on_preview: bool = False,
    status_args: tuple[str, ...] | None = None,
) -> ActionSpec:
    if mutable and preview is None:
        raise ValueError(f"mutable action lacks safe preview: {action_id}")
    family = action_id.split(".", 1)[0]
    inferred_group = group or {
        "system": "Saúde e suporte",
        "profile": "Instalação",
        "steamdeck": "SteamOS",
        "windows": "Windows VM",
        "waydroid": "Android",
        "server": "Serviços",
        "emulation": "Emulação",
        "boot": "Boot e recuperação",
        "flatpak": "Aplicativos",
        "capability": "Recursos",
        "ai": "IA e agentes",
        "desktop": "Desktop",
        "tune": "Ajustes",
    }.get(family, "Geral")
    inferred_risk = risk or ("high" if badge in {"Alto risco", "Resgate"} else "elevated" if elevated else "normal")
    inferred_visibility = visibility or ("advanced" if inferred_risk in {"high", "elevated"} else "standard")
    inferred_parameters = parameters
    if input_kind and not inferred_parameters:
        inferred_parameters = (ActionParameter("input", input_label or "Entrada", input_kind),)
    return ActionSpec(
        id=action_id,
        category=category,
        title=title,
        description=description,
        args=args,
        icon=icon,
        mutable=mutable,
        preview_args=preview,
        elevated=elevated,
        badge=badge,
        input_label=input_label,
        input_kind=input_kind,
        keywords=keywords,
        group=inferred_group,
        visibility=inferred_visibility,
        platforms=platforms,
        risk=inferred_risk,
        status_args=status_args or (preview if mutable else args),
        parameters=inferred_parameters,
        preview_bindings=preview_bindings,
        result_view=result_view,
        stdin_parameter=stdin_parameter,
        stdin_on_preview=stdin_on_preview,
    )


def _p(
    name: str,
    label: str,
    kind: str = "text",
    *,
    required: bool = True,
    choices: tuple[str, ...] = (),
    placeholder: str = "",
) -> ActionParameter:
    return ActionParameter(name, label, kind, required, choices, placeholder)


# LUX-001: high-risk actions whose preview only reads state must say, in the
# confirmation itself, what applying will do. Actions whose preview command is
# itself a plan are listed as "plan" overrides.
HIGH_RISK_IMPACT: dict[str, str] = {
    "system.deps.install": "Instala pacotes do sistema com privilégio de administrador. A lista exibida é o estado atual das dependências, não uma simulação.",
    "windows.provision.cancel": "Interrompe a instalação do Windows em andamento. O disco fica preservado para retomar depois.",
    "windows.provision.discard": "Apaga os arquivos temporários da instalação cancelada. Não dá para retomar essa instalação depois.",
    "windows.guest-login.auto": "O Windows passa a entrar sem pedir senha. Quem ligar a VM acessa a área de trabalho direto.",
    "windows.guest-login.password": "Desliga o autologin e troca a senha da conta do Windows pela que você informar.",
    "waydroid.boot.next-reboot": "Agenda o Android como próximo boot e REINICIA o computador imediatamente. Trabalho não salvo em outros apps será perdido.",
    "boot.efi": "Grava um carregador EFI de reserva na partição de boot. Um erro aqui pode exigir o cartão de resgate do GRUB para voltar a iniciar.",
    "ai.omo.uninstall": "Remove o plugin OMO do OpenCode. Configurações dele deixam de ser aplicadas.",
    "ai.secrets.rotate": "Gera chaves novas para os provedores de IA gerenciados. Apps que usam as chaves antigas precisam ser reabertos.",
    "ai.codexbar.plasmoid-remove": "Faz backup do layout do Plasma e remove o KodexBar dos painéis e o pacote do widget.",
}
PREVIEW_KIND_OVERRIDES: dict[str, str] = {
    # `pz host wipe` sem --apply é o plano do wipe.
    "host.wipe": "plan",
}


def _with_impact(action: ActionSpec) -> ActionSpec:
    impact = HIGH_RISK_IMPACT.get(action.id, action.impact)
    kind = PREVIEW_KIND_OVERRIDES.get(action.id, action.preview_kind_override)
    if impact == action.impact and kind == action.preview_kind_override:
        return action
    return replace(action, impact=impact, preview_kind_override=kind)


def build_catalog(root: Path, platform_name: str | None = None) -> list[ActionSpec]:
    actions: list[ActionSpec] = [
        _a("system.doctor", "Visão geral", "Diagnóstico completo", "Audita host, boot, jogos, IA e integrações.", ("doctor",), "dialog-information", badge="Seguro"),
        # CCS-016: a Visão geral usa o escopo system (rápido); o completo
        # continua disponível na busca.
        _a("system.doctor.system", "Visão geral", "Saúde do sistema", "Checagem rápida de host e serviços sem auditar subsystemas opcionais.", ("doctor", "--scope", "system"), "dialog-information", badge="JSON", group="Saúde e suporte", visibility="advanced", keywords=("saúde", "rápido")),
        # Optional dependencies: what is missing, what that costs, and a way to
        # fix it without leaving the app. Install is privileged and separate
        # from the report so nothing is installed by merely looking.
        _a("system.deps.status", "Visão geral", "Dependências opcionais",
           "Mostra o que falta e qual serviço fica degradado sem isso.",
           ("deps", "status", "--json"), "package-x-generic",
           badge="JSON", group="Saúde e suporte", result_view="auto",
           keywords=("dependência", "pacote", "faltando", "pillow")),
        _a("system.deps.install", "Visão geral", "Instalar dependências ausentes",
           "Instala os pacotes que faltam usando o gerenciador da sua distribuição.",
           ("deps", "install", "{ids}", "--confirm"), "system-software-install",
           mutable=True, preview=("deps", "status", "--json"), elevated=True,
           parameters=(
               _p("ids", "Dependências (separadas por espaço)", placeholder="pillow"),
           ),
           badge="Requer admin", risk="high", group="Saúde e suporte",
           keywords=("dependência", "instalar", "pacote")),
        _a("system.repair-plan", "Visão geral", "Plano de reparo", "Gera recomendações sem alterar sistema.", ("repair-plan",), "document-properties", badge="Seguro"),
        _a("system.support-bundle", "Visão geral", "Bundle de suporte", "Coleta logs sanitizados para diagnóstico.", ("support-bundle",), "folder-download", mutable=True, preview=("support-bundle", "--plan"), badge="Coleta"),
        _a("system.version", "Visão geral", "Versão PhaseZero", "Mostra versão e canal instalados.", ("version",), "help-about"),
        _a("system.installation.status", "Visão geral", "Canais instalados", "Audita versões user, pacote nativo, Flatpak e raízes órfãs.", ("installation", "status"), "system-search", badge="JSON", group="Instalação PhaseZero", visibility="primary", result_view="table"),
        _a(
            "system.installation.converge", "Visão geral", "Convergir instalação",
            "Preserva backup e mantém somente o canal de usuário verificado.",
            ("installation", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
            "system-software-update", mutable=True,
            preview=("installation", "plan", "--channel", "user"),
            preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
            elevated=True, badge="Alto risco", risk="high", group="Instalação PhaseZero",
            visibility="advanced", result_view="table",
        ),
        _a("system.installation.prune", "Visão geral", "Aplicar retenção", "Mantém releases, resultados e backups recentes dentro dos limites.", ("installation", "prune"), "edit-clear", mutable=True, preview=("installation", "status"), badge="Reversível", group="Instalação PhaseZero", visibility="advanced"),
        _a("system.self-update.check", "Visão geral", "Verificar atualização", "Consulta release oficial sem instalar.", ("self-update", "check"), "system-software-update", group="Instalação PhaseZero", visibility="primary"),
        _a(
            "system.self-update.apply", "Visão geral", "Atualizar PhaseZero",
            "Baixa source bundle oficial, verifica dois SHA-256 e troca release atomicamente.",
            ("self-update", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
            "system-software-update", mutable=True, preview=("self-update", "plan"),
            preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
            badge="Protegido", group="Instalação PhaseZero", visibility="primary",
        ),
    ]

    profile_meta = {
        "safe-base": ("Base segura", "Essenciais para uso diário.", "Seguro"),
        "dev-ai": ("Dev + IA", "Toolchain Python, Node, Rust, agentes e modelos. Uso Hermes aguarda grants aplicados por requisição.", "Dev"),
        "gaming": ("Gaming", "Steam, Heroic, Lutris e telemetria local.", "Jogos"),
        "steamdeck-linux": ("Steam Deck Linux", "UX SteamOS, hotkeys e Gamepad UI.", "Recomendado"),
        "windows-vm-linux": ("Windows VM", "QEMU/KVM, OVMF, TPM e compartilhamentos.", "VM"),
        "waydroid-linux": ("Waydroid Linux", "Android container e sessão kiosk.", "Android"),
        "emulation-linux": ("Emulação Linux", "EmuDeck, frontends e layout compartilhado.", "Emulação"),
        "homelab": ("Homelab", "Docker, mídia, nuvem e monitoramento.", "Servidor"),
        "server-llm": ("Servidor LLM", "Ollama local + boot enxuto reversível.", "Servidor"),
        "server-homelab": ("Servidor Homelab", "Instalação de SO servidor: Docker + Tailscale (eixo install, distinto dos perfis appliance).", "Servidor"),
        "server-homelab-hermes": ("Homelab + Hermes", "Servidor caseiro com atuação remota Hermes.", "Servidor"),
        "server-llm-hermes": ("LLM + Hermes", "LLM local + Hermes remoto, SO enxuto.", "Servidor"),
        "server-llm-homelab": ("LLM + Homelab", "LLM local + servidor caseiro, SO enxuto.", "Servidor"),
        "server-llm-homelab-hermes": ("Servidor completo", "LLM + homelab + Hermes combinados.", "Servidor"),
        "full-workstation": ("Workstation completa", "Composição ampla; opt-in explícito.", "Abrangente"),
    }
    for profile_file in sorted((root / "profiles").glob("*.json")):
        profile = profile_file.stem
        title, description, badge = profile_meta.get(profile, (profile, "Perfil PhaseZero.", "Perfil"))
        actions.append(
            _a(
                f"profile.{profile}",
                "Perfis",
                title,
                description,
                ("install", profile),
                "package-x-generic",
                mutable=True,
                preview=("install", profile, "--dry-run"),
                badge=badge,
                keywords=(profile,),
            )
        )

    actions.extend(
        [
            _a("steamdeck.status", "Steam Deck", "Status geral", "Estado consolidado do modo Steam Deck.", ("steamdeck", "status"), "input-gaming", badge="JSON"),
            _a("steamdeck.detect", "Steam Deck", "Detectar modo", "Detecta portátil, dock TV ou monitor.", ("steamdeck", "detect"), "video-display"),
            _a("steamdeck.handheld", "Steam Deck", "Modo portátil", "Aplica perfil portátil.", ("steamdeck", "handheld"), "input-gaming", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.docked-tv", "Steam Deck", "Dock TV", "Aplica perfil TV e controles.", ("steamdeck", "docked-tv"), "video-display", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.docked-monitor", "Steam Deck", "Dock monitor", "Aplica perfil desktop externo.", ("steamdeck", "docked-monitor"), "computer", mutable=True, preview=("steamdeck", "detect"), badge="Sessão"),
            _a("steamdeck.keyboard.toggle", "Steam Deck", "Teclado virtual", "Alterna teclado Steam/KDE.", ("steamdeck", "keyboard"), "input-keyboard", mutable=True, preview=("steamdeck", "keyboard", "status")),
            _a("steamdeck.keyboard.repair", "Steam Deck", "Reparar teclado", "Prefere o Plasma Keyboard quando ele existe e preserva uma escolha explícita válida.", ("steamdeck", "keyboard", "repair"), "input-keyboard", mutable=True, preview=("steamdeck", "keyboard", "status"), badge="Reparo"),
            _a("steamdeck.console", "Steam Deck", "Abrir console", "Inicia Steam Gamepad UI.", ("steamdeck", "console", "auto"), "applications-games", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.desktop", "Steam Deck", "Abrir desktop", "Inicia sessão dev/desktop.", ("steamdeck", "dev", "docked-monitor"), "user-desktop", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.hotkeys", "Steam Deck", "Instalar hotkeys", "Instala Meta+Shift+F1…F8 e ações SteamOS.", ("steamdeck", "hotkeys", "install"), "preferences-desktop-keyboard-shortcuts", mutable=True, preview=("steamdeck", "status")),
            _a("steamdeck.watcher", "Steam Deck", "Assistente de dock", "Detecta quando o Steam Deck é encaixado na base e aplica o modo certo sozinho.", ("steamdeck", "watcher", "install"), "system-run", mutable=True, preview=("steamdeck", "watcher", "status")),
            _a("steamdeck.watcher.enable", "Steam Deck", "Ligar watcher", "Habilita e inicia o modo automático já instalado.", ("steamdeck", "watcher", "enable"), "system-run", mutable=True, preview=("steamdeck", "watcher", "status")),
            _a("steamdeck.privileged", "Steam Deck", "Controles TDP (admin)", "Instala bridge privilegiado para TDP/GPU; pede senha de admin.", ("steamdeck", "privileged", "install"), "security-high", mutable=True, preview=("steamdeck", "privileged", "status"), elevated=True, badge="Requer admin", visibility="primary"),
            _a("steamdeck.boot", "Steam Deck", "Boot Game Mode (admin)", "Instala entrada GRUB do Gamepad UI; pede senha de admin.", ("steamdeck", "boot", "install"), "system-reboot", mutable=True, preview=("steamdeck", "boot", "status"), elevated=True, badge="Requer admin", visibility="primary"),
            _a("steamdeck.plugins", "Steam Deck", "Instalar Decky", "Decky Loader e plugins curados.", ("steamdeck", "plugins", "install"), "application-x-addon", mutable=True, preview=("steamdeck", "plugins", "dry-run"), badge="Plugins"),
            _a("steamdeck.plugins.repair", "Steam Deck", "Reparar Decky", "Restaura loader e plugins.", ("steamdeck", "plugins", "repair"), "tools-check-spelling", mutable=True, preview=("steamdeck", "plugins", "dry-run"), badge="Reparo"),
            _a("steamdeck.launch-options", "Steam Deck", "Launch options", "Lista presets para jogos Steam.", ("steamdeck", "launch-options"), "document-properties"),
            _a("steamdeck.runtime", "Steam Deck", "Diagnóstico runtime", "Analisa runtime Steam e bibliotecas.", ("steamdeck", "runtime-diagnose"), "utilities-terminal"),
            _a("steamdeck.removable", "Steam Deck", "USB automático (admin)", "Auto-mount USB; ignora enquanto a Windows VM roda; pede senha de admin.", ("steamdeck", "removable", "install"), "drive-removable-media", mutable=True, preview=("steamdeck", "removable", "status"), elevated=True, badge="Requer admin", visibility="primary"),
            _a("steamdeck.display", "Steam Deck", "Detectar display", "Detecta perfil de tela e resolução do Game Mode sem alterar nada.", ("steamdeck", "display", "detect"), "video-display", badge="Seguro", keywords=("gamescope", "resolução", "oled")),
        ]
    )

    actions.extend(
        [
            _a("windows.status", "Windows VM", "Status Windows VM", "Estado KVM, disco, domínio e boot.", ("windows-vm", "status"), "computer", badge="JSON"),
            _a("windows.discover", "Windows VM", "Descobrir instalações", "Procura discos Windows existentes.", ("windows-vm", "discover", "--json"), "drive-harddisk"),
            _a("windows.plan", "Windows VM", "Planejar instalação", "Prévia com ISO selecionada.", ("windows-vm", "plan", "--iso", "{input}"), "document-properties", input_label="Selecione ISO do Windows", input_kind="file"),
            _a("windows.install", "Windows VM", "Instalar Windows VM", "Cria disco, domínio e launchers.", ("windows-vm", "install", "--iso", "{input}"), "system-software-install", mutable=True, preview=("windows-vm", "plan", "--iso", "{input}"), input_label="Selecione ISO do Windows", input_kind="file", badge="Requer ISO", visibility="advanced"),
            _a("windows.adopt", "Windows VM", "Adotar disco Windows", "Integra instalação existente.", ("windows-vm", "adopt", "--disk", "{input}"), "drive-harddisk", mutable=True, preview=("windows-vm", "discover", "--json"), input_label="Selecione disco qcow2/raw", input_kind="file"),
            _a("windows.vm.remove", "Windows VM", "Remover VM criada", "Move a VM criada pelo PhaseZero para a lixeira; boot direto permanece separado.", ("windows-vm", "remove", "--yes", "--json"), "edit-delete", mutable=True, preview=("windows-vm", "remove", "--dry-run", "--json"), badge="Alto risco", risk="high", visibility="advanced"),
            _a("windows.optimize", "Windows VM", "Otimizar host", "Ajustes temporários para QEMU.", ("windows-vm", "optimize"), "preferences-system-performance", mutable=True, preview=("windows-vm", "status")),
            _a("windows.shares.enable", "Windows VM", "Ativar arquivos compartilhados", "Publica somente pastas gerenciadas para o Windows.", ("windows-vm", "shares", "install"), "folder-remote", mutable=True, preview=("windows-vm", "shares", "dry-run"), elevated=True, badge="Reversível"),
            _a("windows.shares.disable", "Windows VM", "Desativar arquivos compartilhados", "Remove compartilhamentos gerenciados; arquivos permanecem no host.", ("windows-vm", "shares", "remove"), "folder-remote", mutable=True, preview=("windows-vm", "status"), elevated=True, badge="Reversível"),
            _a("windows.graphics.enable", "Windows VM", "Ativar aceleração de vídeo", "Aplica VirtIO GL quando o host atende aos requisitos.", ("windows-vm", "graphics", "apply", "--profile", "virtio-gl", "--experimental", "--yes"), "video-display", mutable=True, preview=("windows-vm", "graphics", "plan", "--profile", "virtio-gl", "--json"), badge="Reversível"),
            _a("windows.graphics.disable", "Windows VM", "Usar vídeo compatível", "Retorna ao perfil gráfico estável QXL/SPICE.", ("windows-vm", "graphics", "apply", "--profile", "compat"), "video-display", mutable=True, preview=("windows-vm", "graphics", "plan", "--profile", "compat", "--json"), badge="Reversível"),
            _a("windows.usb.enable", "Windows VM", "Ativar dispositivos USB", "Instala regra restrita a dispositivos externos da sessão ativa.", ("windows-vm", "usb-access", "install"), "drive-removable-media-usb", mutable=True, preview=("windows-vm", "usb-access", "dry-run"), elevated=True, badge="Reversível"),
            _a("windows.usb.disable", "Windows VM", "Desativar dispositivos USB", "Remove somente a regra USB gerenciada pelo PhaseZero.", ("windows-vm", "usb-access", "remove"), "drive-removable-media-usb", mutable=True, preview=("windows-vm", "usb-access", "status"), elevated=True, badge="Reversível"),
            _a("windows.launch", "Windows VM", "Abrir Windows", "Inicia VM configurada em tela cheia.", ("windows-vm", "launch", "--fullscreen"), "media-playback-start", mutable=True, preview=("windows-vm", "status")),
            _a("windows.guest-login.shutdown", "Windows VM", "Desligar Windows", "Solicita desligamento seguro pelo agente do Windows.", ("windows-vm", "guest-login", "shutdown", "--json"), "media-playback-stop", mutable=True, preview=("windows-vm", "guest-login", "status", "--json"), badge="Reversível"),
            _a("windows.graphics.doctor", "Windows VM", "Diagnóstico gráfico", "Saúde consolidada de KVM, GPU, perfil, runtime e VFIO.", ("windows-vm", "graphics", "doctor", "--json"), "tools-report-bug", badge="JSON"),
            _a("windows.graphics.status", "Windows VM", "GPU status", "GPU, render nodes, IOMMU e perfis gráficos elegíveis.", ("windows-vm", "graphics", "status", "--json"), "video-display", badge="JSON"),
            _a("windows.graphics.plan-gl", "Windows VM", "Plano VirtIO GL", "Valida caminho GL experimental sem alterar a VM.", ("windows-vm", "graphics", "plan", "--profile", "virtio-gl", "--json"), "video-display", badge="Seguro"),
            _a("windows.graphics.test-gl", "Windows VM", "Validar comando GL", "Gera lançamento QEMU VirtIO GL completo em dry-run.", ("windows-vm", "launch", "--dry-run", "--raw-qemu", "--graphics", "virtio-gl", "--experimental", "--no-optimize"), "system-run", badge="Seguro"),
            _a("windows.graphics.plan-venus", "Windows VM", "Ver plano Venus", "Somente plano; instalação bloqueada. Mostra pré-requisitos e limites do Vulkan experimental no Steam Deck.", ("windows-vm", "graphics", "plan", "--profile", "virtio-venus", "--json"), "video-display", badge="Experimental", visibility="advanced"),
            _a("windows.graphics.plan-vfio", "Windows VM", "Plano VFIO", "Valida GPU, áudio e grupos IOMMU; não vincula drivers.", ("windows-vm", "graphics", "plan", "--profile", "vfio-looking-glass", "--pci-devices", "{input}", "--json"), "video-display", badge="Seguro", input_label="Dispositivos PCI (GPU, áudio)", input_kind="text"),
            _a("windows.graphics.compat", "Windows VM", "Restaurar gráfico compatível", "Define QXL/SPICE ou VirtIO VGA como perfil estável.", ("windows-vm", "graphics", "apply", "--profile", "compat"), "edit-undo", mutable=True, preview=("windows-vm", "graphics", "plan", "--profile", "compat", "--json"), badge="Reversível"),
            _a("windows.graphics.runtime-status", "Windows VM", "Status do runtime gráfico", "Compara byte a byte a sessão instalada com as fontes atuais.", ("windows-vm", "graphics", "runtime", "status", "--json"), "system-search", badge="JSON"),
            _a("windows.graphics.runtime-install", "Windows VM", "Atualizar runtime gráfico", "Sincroniza somente sessão e runtime Windows; cria backup e não toca GRUB.", ("windows-vm", "graphics", "runtime", "install", "--json"), "system-software-update", mutable=True, preview=("windows-vm", "graphics", "runtime", "install", "--dry-run", "--json"), elevated=True, badge="Reparo"),
            _a("windows.graphics.runtime-rollback", "Windows VM", "Reverter runtime gráfico", "Restaura backup anterior da sessão gráfica Windows.", ("windows-vm", "graphics", "runtime", "rollback", "--backup", "latest", "--json"), "edit-undo", mutable=True, preview=("windows-vm", "graphics", "runtime", "rollback", "--backup", "latest", "--dry-run", "--json"), elevated=True, badge="Reversível"),
            _a("windows.graphics.guest-guide", "Windows VM", "Guia guest", "Checklist de drivers gráficos no Windows guest.", ("windows-vm", "graphics", "guest-guide"), "help-contents"),
            _a("windows.apps.status", "Windows VM", "Status WinBoat/WinPodX", "Audita AppImages, Podman, KVM, RDP e concorrência.", ("windows-vm", "apps", "status"), "computer", badge="JSON"),
            _a("windows.apps.setup", "Windows VM", "Instalar WinBoat + WinPodX", "Instala releases oficiais verificadas e perfil Steam Deck.", ("windows-vm", "apps", "setup"), "system-software-install", mutable=True, preview=("windows-vm", "apps", "status"), badge="Podman"),
            _a("windows.apps.configure", "Windows VM", "Configurar Podman Windows", "Aplica recursos, RDP, compartilhamento e política de um guest.", ("windows-vm", "apps", "configure"), "preferences-system", mutable=True, preview=("windows-vm", "apps", "status"), badge="Reversível"),
            _a("windows.boot.status-json", "Windows VM", "Boot status (JSON)", "Estado do boot em JSON para consumo programático.", ("windows-vm", "boot", "status", "--json"), "dialog-information", badge="JSON", visibility="advanced"),
            _a("windows.boot.install", "Windows VM", "Instalar boot direto (Windows)", "Entrada GRUB para Windows VM.", ("windows-vm", "boot", "install"), "system-reboot", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),
            _a("windows.boot.dock.enable", "Windows VM", "Adicionar entrada GRUB Windows (Dock)", "Cria a entrada dedicada que inicia a VM sempre no monitor da dock.", ("windows-vm", "boot", "install", "--dock-entry"), "video-display", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),
            _a("windows.boot.dock.disable", "Windows VM", "Remover entrada GRUB Windows (Dock)", "Remove a entrada dedicada do monitor da dock.", ("windows-vm", "boot", "install", "--no-dock-entry"), "video-display", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),
            _a("windows.boot.next", "Windows VM", "Próximo boot Windows", "Agenda uma sessão Windows VM.", ("windows-vm", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("windows-vm", "boot", "status"), elevated=True),

            # Provision commands
            _a("windows.media.inspect", "Windows VM", "Inspecionar ISO", "Valida ISO, SHA-256, arquitetura e listas edições disponíveis.", ("windows-vm", "media", "inspect", "--iso", "{input}"), "media-optical", input_label="Selecione ISO do Windows", input_kind="file", badge="JSON"),
            _a("windows.images.manage", "Windows VM", "Gerenciar imagens", "Lista ISOs registradas, mostra edições por índice e abre player/boot/GRUB.", ("windows-vm", "images", "manage"), "media-optical", badge="Gestão"),
            _a("windows.provision.preflight", "Windows VM", "Pré-verificação do host", "Verifica swtpm, virtio-win, KVM, OVMF e recursos antes do plano.", ("windows-vm", "preflight", "--json"), "dialog-information", badge="JSON"),
            _a("windows.provision.plan", "Windows VM", "Planejar instalação automática", "Gera plano completo de instalação e otimização.", ("windows-vm", "provision", "plan", "--iso", "{input}", "--image-index", "{image_index}", "--graphics", "{graphics}", "--guest-login", "{guest_login}", "--json"), "document-properties", badge="Seguro", parameters=(
                _p("input", "Selecione ISO do Windows", kind="file"),
                _p("graphics", "Aceleração gráfica", "choice", choices=tuple(v for v, _, _ in WINDOWS_VM_GRAPHICS_OPTIONS), placeholder="compat"),
                _p("image_index", "Índice da edição Windows", placeholder="1"),
                _p("guest_login", "Login no Windows", "choice", choices=("auto", "password"), placeholder="auto"),
            )),
            _a("windows.provision.start", "Windows VM", "Instalar e otimizar Windows", "Executa instalação completa: setup, drivers, tweaks, snapshot.", ("windows-vm", "provision", "start", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--json"), "system-software-install", mutable=True, preview=("windows-vm", "provision", "plan", "--iso", "{input}", "--json"), preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken"), ("input", "iso.path")), badge="Alto risco", risk="high"),
            _a("windows.provision.status", "Windows VM", "Status da instalação", "Estado atual da operação de provisionamento.", ("windows-vm", "provision", "status", "--operation-id", "{operation_id}", "--json"), "dialog-information", parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),), badge="JSON"),
            _a("windows.provision.watch", "Windows VM", "Acompanhar instalação", "Monitora progresso em tempo real do worker.", ("windows-vm", "provision", "watch", "--operation-id", "{operation_id}"), "media-playback-start", parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),)),
            _a("windows.provision.resume", "Windows VM", "Retomar instalação", "Retoma instalação interrompida do último checkpoint.", ("windows-vm", "provision", "resume", "--operation-id", "{operation_id}"), "media-skip-forward", mutable=True, preview=("windows-vm", "provision", "status", "--operation-id", "{operation_id}", "--json"), parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),), badge="Reparo"),
            _a("windows.provision.cancel", "Windows VM", "Cancelar instalação", "Cancela operação ativa; preserva disco para retomada.", ("windows-vm", "provision", "cancel", "--operation-id", "{operation_id}"), "media-playback-stop", mutable=True, preview=("windows-vm", "provision", "status", "--operation-id", "{operation_id}", "--json"), parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),), badge="Alto risco", risk="high"),
            _a("windows.provision.discard", "Windows VM", "Descartar instalação", "Remove staging e libera recursos da instalação cancelada.", ("windows-vm", "provision", "cancel", "--operation-id", "{operation_id}", "--remove-staging"), "edit-delete", mutable=True, preview=("windows-vm", "provision", "status", "--operation-id", "{operation_id}", "--json"), parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),), badge="Alto risco", risk="high", visibility="advanced"),

            # Player flow (janela dedicada)
            _a("windows.provision.player", "Windows VM", "Preparar Windows e reiniciar",
               "Orquestra plano, provisão, boot e reboot em janela dedicada.",
               ("--internal-player",), "system-reboot",
               mutable=True, elevated=False,
               preview=("windows-vm", "provision", "plan", "--iso", "{input}", "--guest-login", "{guest_login}", "--json"),
               preview_bindings=(("input", "iso.path"),),
               input_label="Selecione ISO do Windows",
               input_kind="file",
               parameters=(
                   _p("graphics", "Aceleração gráfica", "choice",
                      choices=tuple(v for v, _, _ in WINDOWS_VM_GRAPHICS_OPTIONS),
                      placeholder="compat"),
                   _p("image_index", "Índice da edição Windows", placeholder="1"),
                   _p("guest_login", "Login no Windows", "choice",
                      choices=("auto", "password"), placeholder="auto"),
               ),
               badge="Alto risco", risk="high"),
            # Post-install login policy. The provisioning actions above only set
            # this while installing; changing it afterwards previously required
            # the CLI. This is the PhaseZero-driven equivalent of clearing or
            # ticking the password box in netplwiz.
            _a("windows.guest-login.status", "Windows VM", "Login do Windows: estado",
               "Mostra se o Windows entra sozinho ou exige senha, e se foi verificado.",
               ("windows-vm", "guest-login", "status", "--json"), "dialog-password",
               badge="JSON", group="Windows VM", result_view="auto",
               keywords=("autologin", "senha", "netplwiz", "login")),
            _a("windows.guest-login.auto", "Windows VM", "Entrar sem senha (autologin)",
               "Windows entra direto na área de trabalho. A senha da conta é gerada e guardada no LSA, nunca em registro.",
               ("windows-vm", "guest-login", "apply", "--mode", "auto", "--json"),
               "system-log-out", mutable=True,
               preview=("windows-vm", "guest-login", "status", "--json"),
               badge="Requer VM ligada", risk="high", group="Windows VM",
               keywords=("autologin", "sem senha", "netplwiz")),
            _a("windows.guest-login.password", "Windows VM", "Exigir senha ao entrar",
               "Desliga o autologin e define a senha da conta. A senha vai pela entrada padrão, nunca pela linha de comando.",
               # No {password} placeholder: a stdin-bound secret has no argv
               # position at all, and a placeholder here would be serialised
               # verbatim into the static action catalog.
               ("windows-vm", "guest-login", "apply", "--mode", "password",
                "--password-stdin", "--json"),
               "dialog-password", mutable=True,
               preview=("windows-vm", "guest-login", "status", "--json"),
               parameters=(
                   _p("password", "Nova senha do Windows", "secret",
                      placeholder="mín. 14 caracteres"),
               ),
               stdin_parameter="password",
               badge="Requer VM ligada", risk="high", group="Windows VM",
               keywords=("senha", "netplwiz", "exigir senha", "login")),
        ]
    )

    actions.extend(
        [
            _a("waydroid.status", "Waydroid", "Status Waydroid", "Container, imagens, binder e sessão.", ("waydroid", "status", "--json"), "phone", badge="JSON"),
            _a("waydroid.plan", "Waydroid", "Plano Waydroid", "Prévia de instalação e kiosk.", ("waydroid", "plan"), "document-properties"),
            _a("waydroid.install", "Waydroid", "Instalar Waydroid", "Configura container e launchers.", ("waydroid", "install"), "system-software-install", mutable=True, preview=("waydroid", "plan"), elevated=True),
            _a("waydroid.repair", "Waydroid", "Reparar Waydroid", "Repara host, serviços e sessão.", ("waydroid", "repair"), "tools-check-spelling", mutable=True, preview=("waydroid", "plan"), elevated=True),
            _a("waydroid.launch", "Waydroid", "Abrir Waydroid", "Inicia sessão otimizada.", ("waydroid", "launch"), "media-playback-start", mutable=True, preview=("waydroid", "status", "--json")),
            _a("waydroid.stop", "Waydroid", "Parar Waydroid", "Encerra a sessão Android e preserva aplicativos e dados.", ("waydroid", "stop", "--json"), "media-playback-stop", mutable=True, preview=("waydroid", "status", "--json"), badge="Reversível"),
            _a("waydroid.boot.install", "Waydroid", "Instalar boot direto (Android)", "Entrada GRUB para sessão Android.", ("waydroid", "boot", "install"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True),
            _a("waydroid.boot.next", "Waydroid", "Próximo boot Android", "Agenda a sessão Waydroid para o próximo boot; NÃO reinicia agora.", ("waydroid", "boot", "next"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True),
            _a("waydroid.boot.next-reboot", "Waydroid", "Reiniciar no Android agora", "Agenda o Waydroid e REINICIA o host imediatamente.", ("waydroid", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True, badge="Alto risco", risk="high", visibility="advanced"),
            _a("waydroid.host-access", "Waydroid", "Acesso host → Android", "Link para o armazenamento interno do Waydroid.", ("waydroid", "host-access", "link"), "folder-remote", mutable=True, preview=("waydroid", "host-access", "status")),
            _a("waydroid.host-access.remove", "Waydroid", "Remover acesso aos arquivos", "Remove somente o link gerenciado para o armazenamento Android.", ("waydroid", "host-access", "unlink"), "folder-remote", mutable=True, preview=("waydroid", "host-access", "status"), badge="Reversível"),
            _a("waydroid.shares.enable", "Waydroid", "Pastas do host no Android", "Compartilha pastas pessoais e mídias via LXC, sem o barramento USB.", ("waydroid", "shares", "install", "--groups", "folders"), "folder-remote", mutable=True, preview=("waydroid", "shares", "dry-run", "--groups", "folders"), elevated=True, badge="Reversível"),
            _a("waydroid.shares.disable", "Waydroid", "Remover pastas do Android", "Para de compartilhar as pastas do host; dados Android permanecem.", ("waydroid", "shares", "remove", "--groups", "folders"), "folder-remote", mutable=True, preview=("waydroid", "shares", "status"), elevated=True, badge="Reversível"),
            _a("waydroid.usb.enable", "Waydroid", "USB no Android", "Expõe somente o barramento USB ao container Android.", ("waydroid", "shares", "install", "--groups", "usb"), "drive-removable-media-usb", mutable=True, preview=("waydroid", "shares", "dry-run", "--groups", "usb"), elevated=True, badge="Reversível"),
            _a("waydroid.usb.disable", "Waydroid", "Sem USB no Android", "Remove só o barramento USB; pastas compartilhadas permanecem.", ("waydroid", "shares", "remove", "--groups", "usb"), "drive-removable-media-usb", mutable=True, preview=("waydroid", "shares", "status"), elevated=True, badge="Reversível"),
            _a("waydroid.boot.remove", "Waydroid", "Remover boot direto Android", "Remove somente a entrada de boot gerenciada.", ("waydroid", "boot", "remove"), "system-reboot", mutable=True, preview=("waydroid", "boot", "status"), elevated=True, badge="Reversível"),
        ]
    )
    actions.append(
        _a("windows.host-access", "Windows VM", "Acesso host → disco VM", "Monta o disco da VM no host (libguestfs).", ("windows-vm", "host-access", "mount"), "drive-harddisk", mutable=True, preview=("windows-vm", "host-access", "status")),
    )

    actions.extend(
        [
            _a("homelab.status", "Homelab", "Status da stack", "Apps, perfil ativo, orçamento e política AI.", ("server", "homelab", "status", "--json"), "folder-remote", badge="JSON", keywords=("homelab", "jellyfin", "vaultwarden")),
            _a("homelab.profiles", "Homelab", "Perfis e pesos", "Perfis appliance (edge, assistant-*): só orçamento de RAM e pesos; o compose continua core/extras.", ("server", "homelab", "profile", "list"), "folder-documents", badge="JSON", keywords=("perfil", "weights")),
            _a("homelab.budget", "Homelab", "Orçamento do perfil ativo", "MiB do governor para o perfil ativo da stack (headroom de 20%); perfis appliance são orçamento de RAM, não mudam o compose.", ("server", "homelab", "governor", "budget-active"), "preferences-system-performance", badge="Seguro", keywords=("governor", "budget", "ram")),
            _a("homelab.backup", "Homelab", "Backup verificado", "manifest.json + sha256 por volume nomeado.", ("server", "homelab", "backup"), "document-save", mutable=True, preview=("server", "homelab", "backup", "--dry-run"), badge="Backup"),
            _a("homelab.verify", "Homelab", "Verificar backup", "Recomputa sha256; falha fechado se adulterado.", ("server", "homelab", "backup", "verify", "--source", "{input}"), "document-edit-verify", mutable=True, preview=("server", "homelab", "status"), input_label="Selecione pasta de backup Homelab", input_kind="path", badge="Verificação"),
            _a("homelab.restore", "Homelab", "Restaurar backup (plano)", "Verifica o backup e mostra o impacto; aplicar exige confirmação explícita na CLI (--yes).", ("server", "homelab", "restore", "--source", "{input}", "--plan"), "document-revert", input_label="Selecione pasta de backup Homelab", input_kind="path", badge="Verificação", keywords=("restaurar", "backup", "resgate")),
            _a("homelab.policy", "Homelab", "Política AI", "Broker conservative/permissive e ações negadas.", ("ai", "policy", "status"), "dialog-password", badge="JSON", keywords=("policy", "broker", "ollama", "hermes")),
            _a("homelab.hosts", "Homelab", "Hosts pareados", "Computadores remotos registrados, pareamento e ponte SSH.", ("server", "homelab", "hosts", "list", "--json"), "folder-remote", badge="JSON", keywords=("host", "remoto", "parear", "ssh")),
        ]
    )

    actions.extend(
        [
            _a("server.status", "Servidor", "Status servidor", "LLM local, homelab e entrada GRUB.", ("server", "status"), "network-server", badge="JSON"),
            _a("server.llm", "Servidor", "Instalar LLM local", "Ollama como servidor (opcional LAN).", ("server", "llm", "install"), "applications-science", mutable=True, preview=("server", "llm", "status")),
            _a("server.homelab.status", "Servidor", "Status Homelab", "Docker, Tailscale, secrets, apps, portas e volumes.", ("server", "homelab", "status", "--json"), "server-database", badge="JSON", keywords=("homelab", "portainer", "casaos")),
            _a("server.homelab.plan", "Servidor", "Plano Homelab", "Mostra blockers e próximos passos sem alterar sistema.", ("server", "homelab", "plan"), "document-properties", badge="Seguro", keywords=("homelab", "secrets")),
            _a("server.homelab.repair", "Servidor", "Preparar Homelab", "Gera .env seguro, secrets locais e valida compose.", ("server", "homelab", "repair"), "tools-check-spelling", mutable=True, preview=("server", "homelab", "plan"), badge="Reparo"),
            _a("server.homelab.up", "Servidor", "Subir homelab local", "Stack Docker local-only: mídia, cofre, monitor.", ("server", "homelab", "up", "--access", "local"), "server-database", mutable=True, preview=("server", "homelab", "plan", "--access", "local"), badge="Docker"),
            _a("server.homelab.up-tailscale", "Servidor", "Subir via Tailscale", "Expõe apps no IP Tailscale quando autenticado.", ("server", "homelab", "up", "--access", "tailscale"), "network-server", mutable=True, preview=("server", "homelab", "plan", "--access", "tailscale"), badge="Docker"),
            _a("server.homelab.up-extras", "Servidor", "Subir extras Homelab", "Nextcloud, Grafana, Prometheus, Paperless e n8n.", ("server", "homelab", "up", "--extras", "--access", "tailscale"), "server-database", mutable=True, preview=("server", "homelab", "plan", "--extras", "--access", "tailscale"), badge="Pesado"),
            _a("server.homelab.down", "Servidor", "Parar homelab", "Encerra a stack (volumes preservados).", ("server", "homelab", "down"), "media-playback-stop", mutable=True, preview=("server", "homelab", "status")),
            _a("server.homelab.open-portainer", "Servidor", "Abrir Portainer", "Dashboard Docker local.", ("server", "homelab", "open", "portainer"), "utilities-system-monitor", keywords=("portainer",)),
            _a("server.homelab.open-jellyfin", "Servidor", "Abrir Jellyfin", "Biblioteca de mídia.", ("server", "homelab", "open", "jellyfin"), "applications-multimedia", keywords=("jellyfin",)),
            _a("server.homelab.open-vaultwarden", "Servidor", "Abrir Vaultwarden", "Cofre Bitwarden compatível.", ("server", "homelab", "open", "vaultwarden"), "dialog-password", keywords=("vaultwarden", "bitwarden")),
            _a("server.homelab.open-kuma", "Servidor", "Abrir Uptime Kuma", "Monitoramento de serviços.", ("server", "homelab", "open", "uptime-kuma"), "utilities-system-monitor", keywords=("uptime", "kuma")),
            _a("server.homelab.logs", "Servidor", "Logs Portainer", "Mostra logs recentes do dashboard Docker.", ("server", "homelab", "logs", "portainer"), "text-x-log", keywords=("logs",)),
            _a("server.homelab.update", "Servidor", "Atualizar Homelab", "Backup antes de pull/up com tags fixas.", ("server", "homelab", "update"), "system-software-update", mutable=True, preview=("server", "homelab", "update", "--dry-run"), badge="Backup"),
            _a("server.homelab.tailscale", "Servidor", "Autenticar Tailscale", "Prepara acesso remoto privado para o Homelab.", ("server", "homelab", "tailscale"), "network-vpn", mutable=True, preview=("server", "homelab", "plan", "--access", "tailscale"), elevated=True),
            _a("server.casaos.status", "Servidor", "Status CasaOS", "Detecta instalação e compatibilidade.", ("server", "casaos", "status"), "network-server", badge="JSON", keywords=("casaos", "zimaos")),
            _a("server.casaos.plan", "Servidor", "Plano CasaOS", "Mostra bloqueios antes de qualquer install.", ("server", "casaos", "plan"), "document-properties", badge="Seguro", keywords=("casaos", "zimaos")),
            _a("server.casaos.install", "Servidor", "Instalar CasaOS", "Opt-in Linux compatível; bloqueia Steam Deck/Arch.", ("server", "casaos", "install", "--yes"), "system-software-install", mutable=True, preview=("server", "casaos", "plan"), elevated=True, badge="Alto risco", keywords=("casaos", "zimaos")),
            _a("server.hermes", "Servidor", "Configurar Hermes", "Atuação remota via Tailscale.", ("server", "hermes", "setup"), "network-transmit-receive", mutable=True, preview=("server", "hermes", "status")),
            _a("server.slim", "Servidor", "Enxugar SO", "Desliga serviços de desktop (reversível).", ("server", "slim", "apply"), "preferences-system-performance", mutable=True, preview=("server", "slim", "status"), elevated=True, badge="Reversível"),
            _a("server.slim.restore", "Servidor", "Reverter enxugamento", "Restaura serviços desligados.", ("server", "slim", "restore"), "edit-undo", mutable=True, preview=("server", "slim", "status"), elevated=True),
            _a("server.boot.install", "Servidor", "Instalar boot Homelab", "Entrada GRUB headless enxuta.", ("server", "boot", "install", "--llm", "--homelab"), "system-reboot", mutable=True, preview=("server", "boot", "dry-run", "--llm", "--homelab"), elevated=True),
            _a("server.boot.next", "Servidor", "Próximo boot Homelab", "Agenda sessão servidor headless.", ("server", "boot", "next-reboot"), "system-reboot", mutable=True, preview=("server", "boot", "status"), elevated=True),
        ]
    )

    emu_rows = [
        ("status", "Status emulação", "Estado atual da stack e componentes instalados.", ("emulation", "status"), None),
        ("setup", "Setup completo", "Stack completa de emulação.", ("emulation", "setup", "install"), ("emulation", "setup", "dry-run")),
        ("layout", "Criar layout", "Pastas compartilhadas de ROMs, BIOS e saves.", ("emulation", "layout"), ("emulation", "status")),
        ("emudeck", "Instalar EmuDeck", "Launcher AppImage e integração.", ("emulation", "emudeck", "install"), ("emulation", "emudeck", "dry-run")),
        ("eden", "Instalar Eden", "Emulador Switch AppImage.", ("emulation", "eden", "install"), ("emulation", "eden", "dry-run")),
        ("citron", "Instalar Citron", "Emulador Switch AppImage.", ("emulation", "citron", "install"), ("emulation", "citron", "dry-run")),
        ("hydra", "Instalar Hydra", "Hydra Classic e atalho SteamOS.", ("emulation", "hydra", "install"), ("emulation", "hydra", "dry-run")),
        ("srm", "Configurar SRM", "Paths e parsers Steam ROM Manager.", ("emulation", "srm", "configure"), ("emulation", "srm", "dry-run")),
        ("retrodeck", "Integrar RetroDECK", "Compartilha ROMs, BIOS, saves e mídia.", ("emulation", "retrodeck", "integrate"), ("emulation", "retrodeck", "plan")),
        ("shared", "Aplicar conteúdo compartilhado", "Links e cópias seguras entre frontends.", ("emulation", "shared", "apply"), ("emulation", "shared", "plan")),
        ("media", "Aplicar mídia canônica", "Normaliza capas e metadados.", ("emulation", "media", "apply"), ("emulation", "media", "plan")),
        ("media-clean", "Limpar mídia órfã", "Move capas de ROMs removidas para backup.", ("emulation", "media", "clean", "--apply"), ("emulation", "media", "clean")),
        ("pc-games", "Reparar jogos PC", "Integra Heroic, Hydra, SRM e ES-DE.", ("emulation", "pc-games", "repair"), ("emulation", "pc-games", "plan")),
        ("shortcuts", "Reparar atalhos", "Remove duplicatas e corrige AppImages.", ("emulation", "shortcuts", "repair"), ("emulation", "shortcuts", "plan")),
        ("launchbox-install", "Instalar LaunchBox 13.5", "Instalação limpa, transacional e isolada.", ("emulation", "launchbox", "install-clean"), ("emulation", "launchbox", "status")),
        ("launchbox-sync", "Sincronizar LaunchBox", "Reconstrói biblioteca usando ROMs e mídia do ES-DE.", ("emulation", "launchbox", "import-esde"), ("emulation", "launchbox", "status")),
        ("launchbox-verify", "Verificar LaunchBox", "Valida executáveis, XML, capas e contagens.", ("emulation", "launchbox", "verify"), ("emulation", "launchbox", "status")),
        ("bigbox-test", "Testar Big Box", "Confirma janela visível e imagem não preta.", ("emulation", "launchbox", "verify", "--real"), ("emulation", "launchbox", "status")),
        ("controllers", "Controles Steam Deck", "Perfil de gamepad para Ryujinx e RPCS3.", ("emulation", "controllers", "apply"), ("emulation", "controllers", "status")),
        ("frontends", "Reparar frontends", "Switcher BigBox, Steam, ES-DE e Heroic.", ("emulation", "frontends", "repair"), ("emulation", "frontends", "plan")),
        ("performance", "Aplicar performance", "Perfis adaptativos Switch/PS3/PS4.", ("emulation", "performance", "apply"), ("emulation", "performance", "plan")),
        (
            "rom-optimize", "Otimizar ROMs", "CHD/RVZ/CSO/NSZ/ZIP por plataforma.",
            ("emulation", "rom-optimize", "{input}"),
            ("emulation", "rom-optimize", "{input}", "--dry-run", "--json"),
        ),
        ("dualscreen", "Tela dupla Deck+TV", "Roteia 2 telas (3DS/Wii U/DS) p/ TV+Deck (Desktop Mode).", ("emulation", "dualscreen", "apply", "all"), ("emulation", "dualscreen", "detect")),
        ("lsfg", "Preparar LSFG", "Instala layer Vulkan verificada.", ("emulation", "performance", "prepare-lsfg"), ("emulation", "performance", "status")),
        ("lua", "Instalar Lua", "Lua, LuaJIT e LuaRocks.", ("emulation", "lua", "install"), ("emulation", "lua", "dry-run")),
        ("steam-tools", "Instalar Steam tools", "Ferramentas auxiliares e backups.", ("emulation", "steam-tools", "install"), ("emulation", "steam-tools", "dry-run")),
        ("heroic", "Reparar Heroic", "Defaults, biblioteca e menu KDE.", ("emulation", "heroic", "repair"), ("emulation", "heroic", "plan")),
        ("doctor", "Diagnóstico emulação", "Verificação profunda: configurações, integrações e integridade de ROMs/BIOS.", ("emulation", "doctor", "--json"), None),
        ("fixes", "Reparos amigáveis", "Lista correções disponíveis.", ("emulation", "fixes", "list"), None),
        ("optimizers", "Aplicar configs por jogo", "14 perfis DuckStation, PCSX2 e Dolphin.", ("emulation", "optimizer", "apply-all"), ("emulation", "optimizer", "plan")),
    ]
    for key, title, description, args, preview in emu_rows:
        actions.append(
            _a(
                f"emulation.{key}",
                "Emulação",
                title,
                description,
                args,
                "applications-games",
                mutable=preview is not None,
                preview=preview,
                badge="Prévia" if preview else "",
                input_label="Selecione a biblioteca de ROMs" if key == "rom-optimize" else "",
                input_kind="path" if key == "rom-optimize" else "",
            )
        )
    actions.extend(
        [
            _a(
                "emulation.library.scan", "Emulação", "Analisar biblioteca",
                "Varredura somente leitura da biblioteca canônica.",
                ("emulation", "library", "scan", "--scope", "library", "--json"),
                "system-search", badge="Somente leitura", group="Biblioteca de jogos",
                result_view="table",
            ),
            _a(
                "emulation.library.plan", "Emulação", "Criar plano da biblioteca",
                "Gera plano seguro a partir de uma análise salva.",
                ("emulation", "library", "plan", "--scan-id", "{scan_id}", "--json"),
                "document-preview", group="Biblioteca de jogos",
                parameters=(_p("scan_id", "ID da análise", placeholder="scan-…"),),
                result_view="table",
            ),
            _a(
                "emulation.library.apply", "Emulação", "Aplicar plano da biblioteca",
                "Executa ações verificadas com staging; preserva originais.",
                ("emulation", "library", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--json"),
                "media-playback-start", mutable=True,
                preview=("emulation", "library", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--dry-run", "--json"),
                badge="Reversível", group="Biblioteca de jogos",
                parameters=(
                    _p("plan_id", "ID do plano", placeholder="plan-…"),
                    _p("confirm", "Token de confirmação", placeholder="Gerado pelo plano"),
                ),
            ),
            _a(
                "emulation.library.verify", "Emulação", "Validar instalação",
                "Confere hashes e estrutura após execução.",
                ("emulation", "library", "verify", "--operation-id", "{operation_id}", "--json"),
                "task-complete", group="Biblioteca de jogos",
                parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),),
            ),
            _a(
                "emulation.library.rollback", "Emulação", "Reverter instalação",
                "Remove somente destinos criados pela operação; preserva origens.",
                ("emulation", "library", "rollback", "--operation-id", "{operation_id}", "--json"),
                "edit-undo", mutable=True,
                preview=("emulation", "library", "verify", "--operation-id", "{operation_id}", "--json"),
                badge="Reversível", group="Biblioteca de jogos", visibility="advanced",
                parameters=(_p("operation_id", "ID da operação", placeholder="op-…"),),
            ),
            _a("emulation.bios", "Emulação", "Importar BIOS", "Importa BIOS obtida legalmente.", ("emulation", "bios", "import", "{input}"), "folder-open", mutable=True, preview=("emulation", "bios", "status"), input_label="Selecione pasta/arquivo BIOS", input_kind="path", badge="Arquivo local"),
            _a("emulation.keys", "Emulação", "Importar Switch keys", "Importa keys próprias.", ("emulation", "switch", "import-keys", "{input}"), "dialog-password", mutable=True, preview=("emulation", "status"), input_label="Selecione prod.keys", input_kind="file", badge="Arquivo local"),
            _a("emulation.firmware", "Emulação", "Importar firmware", "Importa firmware próprio.", ("emulation", "switch", "import-firmware", "{input}"), "folder-open", mutable=True, preview=("emulation", "status"), input_label="Selecione firmware", input_kind="path", badge="Arquivo local"),
            _a("emulation.nsz", "Emulação", "Converter NSZ", "Conversão atômica NSZ → NSP.", ("emulation", "nsz", "convert", "{input}"), "document-export", mutable=True, preview=("emulation", "nsz", "plan", "{input}"), input_label="Selecione NSZ ou pasta", input_kind="path"),
            _a("emulation.ps3-game", "Emulação", "Importar jogo PS3", "Importa pasta de jogo (dump próprio) para a biblioteca PS3.", ("emulation", "ps3", "import-game", "{input}"), "folder-open", mutable=True, preview=("emulation", "ps3", "dry-run"), input_label="Selecione dump PS3", input_kind="path"),
        ]
    )

    actions.extend(
        [
            _a("boot.status", "Boot Direto", "Status boot", "Audita GRUB, ESP e entradas PhaseZero.", ("boot", "status"), "system-reboot"),
            _a("boot.selector", "Boot Direto", "Seletor visual", "Escolhe próxima sessão antes do reboot.", ("boot", "selector"), "view-list-icons"),
            _a("boot.menu", "Boot Direto", "Abrir menu texto", "Lista escolhas de próxima sessão.", ("boot", "menu"), "view-list-icons"),
            _a("boot.safe-menu", "Boot Direto", "Instalar menu seguro", "Mantém GRUB visível com timeout.", ("boot", "install-safe-menu"), "security-high", mutable=True, preview=("boot", "safe-menu", "dry-run"), elevated=True, badge="Protegido"),
            _a("boot.card", "Boot Direto", "Cartão de recuperação", "Mostra comandos de resgate deste host.", ("boot", "card"), "help-browser"),
            _a("boot.install-card", "Boot Direto", "Salvar cartão", "Grava cartão no host e ESP.", ("boot", "install-card"), "document-save", mutable=True, preview=("boot", "card"), elevated=True),
            _a("boot.efi", "Boot Direto", "Instalar EFI fallback", "Instala EFI standalone por UUID.", ("boot", "install-efi-fallback", "--fallback"), "drive-harddisk", mutable=True, preview=("boot", "status"), elevated=True, badge="Alto risco"),
            _a("boot.normal", "Boot Direto", "Próximo: Linux normal", "Agenda boot normal.", ("boot", "choose", "normal"), "system-reboot", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.steamos", "Boot Direto", "Próximo: SteamOS", "Agenda Steam Gamepad UI.", ("boot", "choose", "steamos"), "input-gaming", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.windows", "Boot Direto", "Próximo: Windows VM", "Agenda Windows virtualizado.", ("boot", "choose", "windows"), "computer", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.waydroid", "Boot Direto", "Próximo: Waydroid", "Agenda Android kiosk.", ("boot", "choose", "waydroid"), "phone", mutable=True, preview=("boot", "status"), elevated=True),
            _a("boot.emergency", "Boot Direto", "Próximo: emergência", "Agenda rescue.target.", ("boot", "emergency-shell", "next"), "dialog-warning", mutable=True, preview=("boot", "emergency-shell", "dry-run"), elevated=True, badge="Resgate"),
            _a("boot.iso.status", "Boot Direto", "ISOs registradas", "Lista perfis, hashes e disponibilidade para loopback.", ("boot", "iso", "status", "--json"), "media-optical", badge="JSON"),
            _a("boot.iso.add", "Boot Direto", "Registrar ISO", "Detecta perfil conhecido e gera entrada GRUB por UUID.", ("boot", "iso", "add", "{input}", "--profile=auto"), "list-add", mutable=True, preview=("boot", "iso", "add", "{input}", "--profile=auto", "--dry-run"), elevated=True, parameters=(_p("input", "Selecione imagem ISO", "file"),), badge="Protegido"),
            _a("boot.usb.discover", "Boot Direto", "Descobrir mídias EFI", "Lista USB/SD removíveis sem alterar GRUB.", ("boot", "usb", "discover", "--json"), "drive-removable-media", badge="JSON"),
            _a("boot.usb.add", "Boot Direto", "Registrar mídia EFI", "Valida BOOTX64.EFI e registra partição removível por UUID.", ("boot", "usb", "add", "{input}"), "list-add", mutable=True, preview=("boot", "usb", "add", "{input}", "--dry-run"), elevated=True, parameters=(_p("input", "Partição ou ponto de montagem", "path"),), badge="Protegido"),
            _a("boot.grubfm.status", "Boot Direto", "Status explorador ISO", "Audita payload grubfm local, Secure Boot e hash.", ("boot", "grubfm", "status", "--json"), "folder-open", badge="Experimental"),
            _a("boot.grubfm.install", "Boot Direto", "Instalar explorador ISO", "Instala grubfm local verificado; upstream arquivado.", ("boot", "grubfm", "install", "--source={source}", "--sha256={sha256}"), "system-software-install", mutable=True, preview=("boot", "grubfm", "install", "--source={source}", "--sha256={sha256}", "--dry-run"), elevated=True, parameters=(_p("source", "Arquivo grubfmx64.efi", "file"), _p("sha256", "SHA-256 esperado")), badge="Alto risco", risk="high", visibility="advanced"),
            _a("boot.grubfm.remove", "Boot Direto", "Remover explorador ISO", "Remove somente payload e entrada grubfm gerenciados.", ("boot", "grubfm", "remove"), "edit-delete", mutable=True, preview=("boot", "grubfm", "remove", "--dry-run"), elevated=True, badge="Experimental", visibility="advanced"),
        ]
    )

    actions.extend(
        [
            _a("flatpak.status", "Flatpak", "Status Flatpak", "Estado da instalação e remotes.", ("flatpak", "status"), "system-software-install"),
            _a("flatpak.audit", "Flatpak", "Auditar permissões e fontes", "Conflitos de fontes (remotes), permissões globais (overrides) e runtime.", ("flatpak", "audit"), "system-search"),
            _a("flatpak.repair", "Flatpak", "Reparar Flatpak", "Corrige conflitos detectados.", ("flatpak", "audit", "--repair"), "tools-check-spelling", mutable=True, preview=("flatpak", "audit")),
            _a("flatpak.remotes", "Flatpak", "Fontes de aplicativos (remotes)", "Repositórios de onde os aplicativos Flatpak vêm.", ("flatpak", "remotes"), "network-server"),
            _a("flatpak.steamdeck", "Flatpak", "Compatibilidade Steam Deck", "Overrides e runtimes gaming.", ("flatpak", "steamdeck-compat"), "input-gaming", mutable=True, preview=("flatpak", "audit")),
            _a("flatpak.rollback", "Flatpak", "Rollback", "Reverte alterações PhaseZero.", ("flatpak", "rollback"), "edit-undo", mutable=True, preview=("flatpak", "audit"), badge="Reversível"),
        ]
    )

    ai_rows = [
        ("status", "Status IA", "Stack local e agentes.", ("ai", "status"), None),
        ("doctor", "Diagnóstico dos conectores", "Audita as integrações MCP — o que liga os agentes a ferramentas e memória.", ("ai", "doctor"), None),
        ("repair", "Reparar MCPs e IDEs", "Repara integrações seguras.", ("ai", "repair"), ("ai", "doctor")),
        ("desktop", "Reparar apps desktop", "Claude/Codex e atualizadores.", ("ai", "desktop", "repair"), ("ai", "desktop", "status")),
        ("compat", "Preparar agentes de IA", "Instala regras de comportamento, acelerador de comandos e memória nos agentes suportados.", ("ai", "compat", "setup"), ("ai", "compat", "status")),
        ("admin", "Admin bridge", "Instala phasezero-admin/bigsudo.", ("ai", "setup", "admin"), ("ai", "admin", "status")),
        ("opencode-status", "OpenCode + 9Router", "Audita versões, configuração canônica, segredo por arquivo e listener loopback.", ("ai", "opencode", "status"), None),
        ("opencode-install", "Configurar OpenCode + 9Router", "Mescla configuração e aplica provider local com rollback.", ("ai", "opencode", "install", "--yes"), ("ai", "opencode", "install", "--dry-run")),
        ("opencode-verify", "Verificar OpenCode + 9Router", "Confere configuração local; execução gerenciada aguarda vínculo de conta por requisição.", ("ai", "opencode", "verify"), None),
        ("opencode", "Alinhar versão OpenCode", "Alinha CLI e desktop.", ("ai", "opencode", "sync"), ("ai", "opencode", "version-status")),
        ("opencode-free", "Modelo free OpenCode", "Corrige 'Interrompido' com modelo free (deepseek-flash).", ("ai", "opencode", "free-model"), ("ai", "opencode", "status")),
        ("omo", "Instalar OMO", "Plugin oh-my-openagent.", ("ai", "omo", "setup"), ("ai", "omo", "status")),
        ("memory", "Instalar ai-memory", "Memória persistente de agentes.", ("ai", "setup", "memory"), ("ai", "status")),
        ("ollama", "Instalar Ollama", "Runtime local de modelos.", ("ai", "setup", "ollama"), ("ai", "status")),
        ("webui", "Uso bloqueado — Open WebUI", "Não instala nem inicia um cliente que pode usar credenciais sem grant por requisição.", ("ai", "setup", "webui"), ("ai", "webui", "status")),
        ("webui-status", "Status Open WebUI", "Container e resposta HTTP local, sem alterar o serviço.", ("ai", "webui", "status"), None),
        ("webui-open", "Uso bloqueado — Open WebUI", "Não abre interface que pode enviar inferência sem grant por requisição.", ("ai", "webui", "open"), None),
        ("usagebar", "Instalar UsageBar", "Uso de provedores no painel.", ("ai", "setup", "usagebar"), ("ai", "status")),
        ("codexbar-status", "Status CodexBar", "CLI, configuração, autenticação e widget opcional.", ("ai", "codexbar", "status"), None),
        ("codexbar-health", "Saúde CodexBar", "Valida integridade e uso dos providers sem alterar o KDE.", ("ai", "codexbar", "health"), None),
        ("codexbar-setup", "Configurar CodexBar", "Instala somente CLI/config; plasmoid permanece opt-in.", ("ai", "codexbar", "setup"), ("ai", "codexbar", "status")),
        ("codexbar-auth", "Autenticar CodexBar", "Detecta sessões Codex/Claude sem exibir credenciais.", ("ai", "codexbar", "auth", "--provider", "all"), ("ai", "codexbar", "status")),
        ("codexbar-repair", "Reparar CodexBar", "Repara CLI/config sem instalar ou atualizar QML no Plasma.", ("ai", "codexbar", "repair"), ("ai", "codexbar", "health")),
        ("ides", "Configurar IDEs (agentes)", "Integra agents (OpenCode, Codex, Claude) nas IDEs/editor.", ("ai", "setup", "ides"), ("ai", "status")),
        ("mcp-sync", "Sincronizar MCPs", "Sincroniza defaults seguros.", ("ai", "mcp", "sync", "all"), ("ai", "mcp", "status")),
        ("claude-status", "Claude + Bonsai", "Audita OAuth, rotas isoladas, hooks e conflitos com proxies.", ("ai", "claude", "status"), None),
        ("claude-install", "Reparar Claude + Bonsai", "Aplica instalação transacional com backup e rollback automático.", ("ai", "claude", "install", "--yes"), ("ai", "claude", "install", "--dry-run")),
        ("claude-verify", "Verificar rotas Claude", "Valida assinatura, Bonsai e 9Router sem expor credenciais.", ("ai", "claude", "verify"), None),
        ("bonsai-diagnose", "Atualizar diagnóstico Bonsai", "Consulta atualização npm e histórico do provedor; não testa login nem inicia inferência.", ("ai", "claude", "bonsai-probe"), None),
        ("claude-bonsai-login", "Login Bonsai", "Abre terminal privado para autenticação explícita; não inicia inferência nem registra códigos no painel.", ("ai", "claude", "login", "bonsai", "--terminal"), ("ai", "claude", "bonsai-status")),
        ("9router-status", "Status 9Router", "Serviço, providers, combos e watchdog.", ("ai", "9router", "status"), None),
        ("9router-tui", "Abrir painel técnico do 9Router", "Abre a tela técnica avançada; para o dia a dia use os cards acima.", ("ai", "9router", "tui"), None),
        ("9router-repair", "Reparar 9Router", "Migra units para caminhos estáveis e valida serviço, bridge e watchdog.", ("ai", "9router", "repair"), ("ai", "9router", "status")),
        ("9router-install", "Instalar 9Router", "Instala gateway local, segredo, serviço e watchdog.", ("ai", "9router", "install"), ("ai", "9router", "status")),
        ("9router-dashboard", "Dashboard 9Router bloqueado", "Testes de provider podem enviar inferência fora do ledger de grants e consumir cota.", ("ai", "9router", "dashboard"), None),
        ("9router-test", "Testar 9Router", "Valida saúde e /v1/models; chat de inferência bloqueado até grant por requisição.", ("ai", "9router", "test"), None),
        ("9router-secrets", "Importação de credenciais bloqueada", "Não copia credenciais para o 9Router sem referência segura e grant por requisição.", ("ai", "9router", "provider", "sync-secrets"), ("ai", "9router", "provider", "status")),
        ("9router-combos", "Combos com fallback bloqueados", "Não cria, sincroniza ou ativa combos sem grant por requisição e política de fallback comprovada.", ("ai", "9router", "combo", "sync"), ("ai", "9router", "combo", "list")),
        ("9router-usage", "Uso e resiliência", "Tokens, latência, custo e falhas coletados pelo 9Router.", ("ai", "9router", "usage"), None),
        ("9router-client", "Uso de clientes 9Router bloqueado", "Status de configuração apenas; lançamento de clientes aguarda enforcement de grants por requisição.", ("ai", "9router", "client", "status"), None),
        ("9router-check", "Verificar update 9Router", "Compara versão e exige integrity publicada.", ("ai", "9router", "check-update"), None),
        ("9router-update", "Atualizar 9Router", "Valida integrity npm, troca atomicamente e reverte se a saúde falhar.", ("ai", "9router", "update"), ("ai", "9router", "check-update")),
        ("9router-doctor", "Doctor 9Router", "Audita bind, permissões, serviço e watchdog passivo.", ("ai", "9router", "doctor"), None),
        ("odysseus-status", "Status Odysseus", "Workspace IA agnóstico fixado em commit oficial.", ("ai", "odysseus", "status"), None),
        ("odysseus-install", "Implantação Odysseus bloqueada", "Não implanta nem inicia workspace enquanto inferência não exigir grant por requisição.", ("ai", "odysseus", "install"), ("ai", "odysseus", "plan")),
        ("odysseus-open", "Uso Odysseus bloqueado", "Workspace encaminha inferência à credencial compartilhada do 9Router sem grant por requisição.", ("ai", "odysseus", "open"), None),
        ("odysseus-check", "Verificar update Odysseus", "Compara commit fixado com branch oficial protegida.", ("ai", "odysseus", "check-update"), None),
        ("odysseus-update", "Update Odysseus bloqueado", "Não reinicia workspace enquanto inferência não exigir grant por requisição.", ("ai", "odysseus", "update"), ("ai", "odysseus", "check-update")),
        ("odysseus-backup", "Backup Odysseus", "Arquiva dados persistentes com SHA-256.", ("ai", "odysseus", "backup"), ("ai", "odysseus", "status")),
        ("odysseus-doctor", "Doctor Odysseus", "Audita containers, endpoint e credenciais sem alterar nada.", ("ai", "odysseus", "doctor"), None),
        ("hermes-status", "Status Hermes", "Configuração, saúde e bloqueio de uso sem revelar segredos.", ("ai", "hermes", "status"), None),
        ("hermes-doctor", "Doctor Hermes", "Audita integridade, política, grants e acesso remoto sem alterar nada.", ("ai", "hermes", "doctor"), None),
        ("workspaces-doctor", "Diagnóstico Hermes + Odysseus", "Auditoria read-only e redigida da jornada completa.", ("ai", "workspaces", "doctor"), None),
        ("workspaces-plan", "Plano Hermes + Odysseus", "Mostra fases, bloqueios e próxima ação segura sem implantar workloads.", ("ai", "workspaces", "plan"), None),
        ("operations-status", "Operações persistentes", "Estado redigido de operações concluídas, falhas e interrupções recuperáveis.", ("ai", "operations", "status"), None),
        ("drift-status", "Cópias instaladas × repositório", "Mostra scripts de runtime que ficaram para trás do repositório (correções ainda não ativas).", ("ai", "drift", "status"), None),
        ("drift-sync", "Atualizar cópias instaladas", "Reinstala as cópias de runtime divergentes a partir do repositório.", ("ai", "drift", "sync"), ("ai", "drift", "sync", "--dry-run")),
        ("operations-resume", "Retomada segura", "Mostra a última operação que pode ser repetida com nova confirmação.", ("ai", "operations", "resume-info"), None),
        ("updates-status", "Atualizações PhaseZero", "Inventário único de apps, host e falhas de atualização.", ("updates", "check"), None),
        ("updates-timer", "Verificação diária", "Ativa timer check-only; aplicação permanece explícita.", ("updates", "install-service"), ("updates", "latest")),
    ]
    for key, title, description, args, preview in ai_rows:
        actions.append(
            _a(
                f"ai.{key}",
                "IA & Dev",
                title,
                description,
                args,
                "applications-development",
                mutable=preview is not None,
                preview=preview,
                badge="Prévia" if preview else "",
            )
        )

    # CCS-019: OmniRoute visível e rotulado como experimental; o 9Router
    # segue sendo o router público da Central. Exatamente um card.
    actions.append(
        _a(
            "ai.omniroute-status",
            "IA & Dev",
            "Status OmniRoute (experimental)",
            "Status somente leitura; uso bloqueado até grants por requisição. 9Router segue como router público da Central.",
            ("ai", "omniroute", "status"),
            "network-workgroup",
            badge="Experimental",
            keywords=("omniroute", "router", "experimental"),
        )
    )

    actions.append(
        _a(
            "ai.claude-rollback",
            "IA & Dev",
            "Rollback Claude + Bonsai",
            "Restaura arquivos e serviços registrados por um manifesto cc-installer.",
            ("ai", "claude", "rollback", "{input}"),
            "edit-undo",
            mutable=True,
            preview=("ai", "claude", "status"),
            input_label="Selecione manifest.json",
            input_kind="file",
            badge="Reversível",
        )
    )
    actions.append(
        _a(
            "ai.opencode-rollback",
            "IA & Dev",
            "Rollback OpenCode + 9Router",
            "Restaura configurações e referência de segredo registradas no manifesto.",
            ("ai", "opencode", "rollback", "{input}"),
            "edit-undo",
            mutable=True,
            preview=("ai", "opencode", "status"),
            input_label="Selecione manifest.json",
            input_kind="file",
            badge="Reversível",
        )
    )
    actions.append(
        _a(
            "ai.claude-bonsai-run",
            "IA & Dev",
            "Executar Claude via Bonsai",
            "Seleciona projeto revisado; Bonsai pede consentimento e usa autenticação externa isolada.",
            ("ai", "claude", "run", "bonsai", "--cwd", "{input}"),
            "system-run",
            mutable=True,
            preview=("ai", "claude", "preflight", "bonsai", "--cwd", "{input}"),
            input_label="Selecione projeto revisado para snapshot/upload",
            input_kind="path",
            badge="Upload com consentimento",
        )
    )

    # Proxy health/auth can be inspected, but inference stays disabled until
    # account grants are enforced by each request and fallback is rejected.
    proxy_rows = [
        ("proxies-ensure-kimi", "Uso bloqueado — Kimi", "Bloqueado até grant por conexão aplicado em cada requisição; não instala, inicia nem configura consumidores.", ("ai", "proxies", "ensure", "kimiproxy"), ("ai", "proxies", "ensure", "kimiproxy", "--dry-run"), ""),
        ("proxies-ensure-qwen", "Uso bloqueado — Qwen", "Bloqueado até grant por conexão aplicado em cada requisição; não instala, inicia nem configura consumidores.", ("ai", "proxies", "ensure", "qwenproxy"), ("ai", "proxies", "ensure", "qwenproxy", "--dry-run"), ""),
        ("proxies-ensure-deeps", "Uso bloqueado — DeepSeek", "Bloqueado até grant por conexão aplicado em cada requisição; não instala, inicia nem configura consumidores.", ("ai", "proxies", "ensure", "deepsproxy"), ("ai", "proxies", "ensure", "deepsproxy", "--dry-run"), ""),
        ("proxies-ensure-mimo", "Uso bloqueado — MiMo", "Bloqueado até grant por conexão aplicado em cada requisição; não grava chave na rota legada nem configura consumidores.", ("ai", "proxies", "ensure", "mimo-ai-proxy"), ("ai", "proxies", "ensure", "mimo-ai-proxy", "--dry-run"), ""),
        ("proxies-ensure-all", "Uso bloqueado — todos os proxies", "Bloqueado até grant por conexão aplicado em cada requisição; nenhuma IDE é habilitada.", ("ai", "proxies", "ensure", "all"), ("ai", "proxies", "ensure", "all", "--dry-run"), ""),
        ("proxies-open-kimi", "Uso no OpenCode bloqueado — Kimi", "Não abre o OpenCode nem envia inferência sem grant por conexão aplicado por requisição.", ("ai", "proxies", "open", "kimiproxy"), None, ""),
        ("proxies-open-qwen", "Uso no OpenCode bloqueado — Qwen", "Não abre o OpenCode nem envia inferência sem grant por conexão aplicado por requisição.", ("ai", "proxies", "open", "qwenproxy"), None, ""),
        ("proxies-open-deeps", "Uso no OpenCode bloqueado — DeepSeek", "Não abre o OpenCode nem envia inferência sem grant por conexão aplicado por requisição.", ("ai", "proxies", "open", "deepsproxy"), None, ""),
        ("proxies-open-mimo", "Uso no OpenCode bloqueado — MiMo", "Não abre o OpenCode nem envia inferência sem grant por conexão aplicado por requisição.", ("ai", "proxies", "open", "mimo-ai-proxy"), None, ""),
        ("proxies-open-studio-mimo", "Abrir API Service Xiaomi", "Abre o portal oficial para criar uma chave da API MiMo.", ("ai", "proxies", "open-studio"), None, ""),
        ("proxies-ides", "Uso por IDE bloqueado", "Não configura OpenCode, Continue ou ZCode sem grant por conexão aplicado a cada requisição.", ("ai", "proxies", "configure-ides"), ("ai", "proxies", "status"), ""),
        ("proxies-stop-kimi", "Parar Kimi", "Para phasezero-kimiproxy.", ("ai", "proxies", "stop", "kimiproxy"), ("ai", "proxies", "status"), ""),
        ("proxies-stop-qwen", "Parar Qwen", "Para phasezero-qwenproxy.", ("ai", "proxies", "stop", "qwenproxy"), ("ai", "proxies", "status"), ""),
        ("proxies-stop-deeps", "Parar DeepSeek", "Para phasezero-deepsproxy.", ("ai", "proxies", "stop", "deepsproxy"), ("ai", "proxies", "status"), ""),
        ("proxies-stop-mimo", "Parar Mimo", "Para phasezero-mimo-ai-proxy.", ("ai", "proxies", "stop", "mimo-ai-proxy"), ("ai", "proxies", "status"), ""),
        ("proxies-stop-all", "Parar todos os proxies", "Desabilita e para os serviços de usuário.", ("ai", "proxies", "stop", "all"), ("ai", "proxies", "status"), "advanced"),
        ("proxies", "Plano do catálogo legado", "Mostra snapshots aprovados e integrações bloqueadas sem baixar código.", ("ai", "proxies", "plan", "all"), None, "advanced"),
        ("proxies-auth", "Auth proxies IA", "Status redigido de login/sessão.", ("ai", "proxies", "auth", "all"), None, "advanced"),
        ("proxies-provenance", "Procedência dos proxies", "Verifica repositório, commit, árvore, licença, lockfiles e alterações locais; não substitui auditoria semântica.", ("ai", "proxies", "provenance", "all"), None, ""),
        ("auth-registry", "Autenticação central", "Contas, sessões, providers e workspaces sem nomes, e-mails ou segredos.", ("ai", "auth", "status"), None, ""),
        ("auth-doctor", "Diagnosticar autenticação", "Prioriza integrações essenciais e próximas ações sem revelar credenciais.", ("ai", "auth", "doctor"), None, "advanced"),
        ("proxies-login-kimi", "Login Kimi", "Abre Chromium visível e salva sessão local; não testa inferência nem inicia o serviço.", ("ai", "proxies", "login", "kimiproxy"), ("ai", "proxies", "auth", "kimiproxy"), "advanced"),
        ("proxies-login-qwen", "Login Qwen", "Abre fluxo manual de browser e salva sessão local; não testa inferência nem inicia o serviço.", ("ai", "proxies", "login", "qwenproxy"), ("ai", "proxies", "auth", "qwenproxy"), "advanced"),
        ("proxies-login-deeps", "Login DeepSeek", "Abre Chromium visível e salva sessão local; não testa inferência nem inicia o serviço.", ("ai", "proxies", "login", "deepsproxy"), ("ai", "proxies", "auth", "deepsproxy"), "advanced"),
        ("proxies-login-all", "Login em todos", "Abre browser para Kimi, Qwen e DeepSeek; login não inicia serviços nem autoriza IDEs.", ("ai", "proxies", "login", "all"), ("ai", "proxies", "auth", "all"), "advanced"),
        ("proxies-test", "Teste de inferência bloqueado", "Probe de modelos/chat bloqueado até grant por conexão aplicado a cada requisição.", ("ai", "proxies", "test"), None, "advanced"),
        ("proxies-start-all", "Inicialização bloqueada", "Serviços de inferência não iniciam antes do enforcement de grants por requisição.", ("ai", "proxies", "start", "all"), ("ai", "proxies", "status"), "advanced"),
        ("proxies-start-kimi", "Inicialização bloqueada — Kimi", "O serviço Kimi não inicia antes do enforcement de grants por requisição.", ("ai", "proxies", "start", "kimiproxy"), ("ai", "proxies", "status"), "advanced"),
        ("proxies-start-qwen", "Inicialização bloqueada — Qwen", "O serviço Qwen não inicia antes do enforcement de grants por requisição.", ("ai", "proxies", "start", "qwenproxy"), ("ai", "proxies", "status"), "advanced"),
        ("proxies-start-deeps", "Inicialização bloqueada — DeepSeek", "O serviço DeepSeek não inicia antes do enforcement de grants por requisição.", ("ai", "proxies", "start", "deepsproxy"), ("ai", "proxies", "status"), "advanced"),
        ("proxies-start-mimo", "Inicialização bloqueada — MiMo", "O serviço MiMo não inicia antes do enforcement de grants por requisição.", ("ai", "proxies", "start", "mimo-ai-proxy"), ("ai", "proxies", "status"), "advanced"),
    ]
    for key, title, description, args, preview, visibility in proxy_rows:
        actions.append(
            _a(
                f"ai.{key}",
                "Proxies IA",
                title,
                description,
                args,
                "network-server",
                mutable=preview is not None,
                preview=preview,
                badge="Prévia" if preview else "",
                visibility=visibility,
            )
        )

    # Product detail gets a scoped probe normalized by the suite for one exact
    # proxy; unapproved or modified checkouts never claim PhaseZero ownership.
    for token, proxy_id, title in (
        ("kimi", "kimiproxy", "Status Kimi"),
        ("qwen", "qwenproxy", "Status Qwen"),
        ("deeps", "deepsproxy", "Status DeepSeek"),
        ("mimo", "mimo-ai-proxy", "Status MiMo"),
    ):
        args = ("ai", "proxies", "product-status", proxy_id)
        actions.append(_a(
            f"ai.proxies-{token}-status", "Proxies IA", title,
            "Consulta instalação, origem aprovada, sessão e serviço deste proxy.",
            args, "system-search", badge="JSON", visibility="advanced",
            status_args=args,
        ))

    # These tools lack a capability-backed probe. Keep detail status scoped to
    # one product and normalize manager evidence without claiming ownership
    # when the source cannot prove it.
    for action_id, app_id, title in (
        ("ai.memory-status", "ai-memory", "Status ai-memory"),
        ("ai.usagebar-status", "usagebar", "Status UsageBar"),
        ("ai.desktop.claude.status", "claude-desktop", "Status Claude Desktop"),
        ("ai.desktop.codex.status", "codex-desktop", "Status Codex Desktop"),
        ("ai.desktop.qwen.status", "qwen-code-desktop", "Status Qwen Code Desktop"),
    ):
        args = ("ai", "product-status", app_id)
        actions.append(_a(
            action_id, "IA & Dev", title,
            "Consulta estado read-only deste app e preserva origem desconhecida.",
            args, "system-search", badge="JSON", visibility="advanced",
            status_args=args,
        ))
    actions.append(
        _a(
            "ai.proxies-credentials-mimo",
            "Proxies IA",
            "Salvar chave MiMo bloqueado",
            "Rota legada bloqueada: não valida, salva ou liga a chave a consumidores antes do grant por requisição.",
            ("ai", "proxies", "set-credentials", "mimo-ai-proxy"),
            "dialog-password",
            mutable=True,
            preview=("ai", "proxies", "auth", "mimo-ai-proxy"),
            stdin_parameter="credentials",
            parameters=(_p("credentials", "Chave oficial MiMo", "secret"),),
        )
    )

    for area, title, description in [
        ("browser", "Hardening navegador", "Privacidade e segurança."),
        ("gaming", "Ajustes gaming", "Performance e latência."),
        ("dev", "Ajustes dev", "Toolchain e limites do host."),
    ]:
        actions.append(
            _a(
                f"tune.{area}",
                "Ajustes",
                title,
                description,
                ("tune", area),
                "preferences-system",
                mutable=True,
                preview=("tune", area, "--dry-run"),
                # Estado real da área: sem isto o status seria um dry-run do
                # apply, que descreve intenção e não o que está no host.
                status_args=("tune", area, "status"),
                badge="Sistema",
            )
        )

    # Manutenção: higiene do host (ledger, backups centralizados, pegada).
    # "Remover pegada" é destrutivo e só aparece no painel avançado; o preview
    # sem --apply é a ação padrão, coerente com dry-run-by-default.
    actions.extend(
        [
            _a(
                "host.status",
                "Ajustes",
                "Higiene do host",
                "Pegada do PhaseZero: ledger, backups e paths removíveis.",
                ("host", "status"),
                "drive-harddisk",
                group="Manutenção",
                keywords=("ledger", "backup", "pegada", "higiene", "limpeza"),
            ),
            _a(
                "host.backups.list",
                "Ajustes",
                "Backups centralizados",
                "Lista os backups guardados no namespace PhaseZero.",
                ("host", "backups", "list"),
                "document-save",
                group="Manutenção",
                keywords=("backup", "restaurar"),
            ),
            _a(
                "host.backups.migrate",
                "Ajustes",
                "Migrar backups legados",
                "Move .bak antigos de junto dos arquivos para o store central.",
                ("host", "backups", "migrate", "--apply"),
                "folder-sync",
                mutable=True,
                preview=("host", "backups", "migrate"),
                group="Manutenção",
                keywords=("backup", "legado", "migrar", "limpeza"),
            ),
            _a(
                "host.prune",
                "Ajustes",
                "Podar backups e logs",
                "Mantém apenas os backups recentes. Não desinstala nada.",
                ("host", "prune"),
                "edit-clear",
                mutable=True,
                preview=("host", "status"),
                group="Manutenção",
                keywords=("poda", "prune", "espaço", "limpeza"),
            ),
            _a(
                "host.wipe",
                "Ajustes",
                "Remover pegada do PhaseZero",
                "Remove tudo que o ledger registra. Preserva ~/Emulation.",
                ("host", "wipe", "--apply", "--confirm", "PHASEZERO-WIPE"),
                "edit-delete",
                mutable=True,
                preview=("host", "wipe"),
                badge="Alto risco",
                group="Manutenção",
                visibility="advanced",
                keywords=("desinstalar", "wipe", "remover", "limpar"),
            ),
        ]
    )

    # Public CLI variants not promoted as primary flows. They remain fully
    # discoverable in the contextual Advanced panel for their category.
    actions.extend(
        [
            _a("steamdeck.keyboard.status", "Steam Deck", "Status do teclado", "Provider e configuração do teclado virtual.", ("steamdeck", "keyboard", "status"), "input-keyboard", visibility="advanced"),
            _a("steamdeck.watcher.status", "Steam Deck", "Status do watcher", "Estado do serviço de detecção de dock.", ("steamdeck", "watcher", "status"), "system-run", visibility="advanced"),
            _a("steamdeck.privileged.status", "Steam Deck", "Status privilegiado", "Estado da bridge TDP/GPU.", ("steamdeck", "privileged", "status"), "security-high", visibility="advanced"),
            _a("steamdeck.boot.status", "Steam Deck", "Status do boot SteamOS", "Audita entrada e sessão SteamOS.", ("steamdeck", "boot", "status"), "system-reboot", visibility="advanced"),
            _a("steamdeck.plugins.status", "Steam Deck", "Status Decky", "Saúde de loader, CEF e plugins.", ("steamdeck", "plugins", "status"), "application-x-addon", visibility="advanced"),
            _a("steamdeck.conveniences", "Steam Deck", "Instalar conveniências", "Atalhos Return, Windows VM e Waydroid.", ("steamdeck", "conveniences", "install"), "applications-system", mutable=True, preview=("steamdeck", "conveniences", "plan"), visibility="advanced"),
            _a("steamdeck.removable.status", "Steam Deck", "Status de removíveis", "Audita auto-mount USB.", ("steamdeck", "removable", "status"), "drive-removable-media", visibility="advanced"),
            _a("steamdeck.display.status", "Steam Deck", "Status do display", "Audita TV/monitor para Game Mode.", ("steamdeck", "display", "status"), "video-display", visibility="advanced"),

            _a("windows.host-access.status", "Windows VM", "Status acesso ao disco", "Estado da montagem host→guest.", ("windows-vm", "host-access", "status"), "drive-harddisk", visibility="advanced"),
            _a("windows.host-access.unmount", "Windows VM", "Desmontar disco da VM", "Desmonta acesso host antes de iniciar Windows.", ("windows-vm", "host-access", "unmount"), "media-eject", mutable=True, preview=("windows-vm", "host-access", "status"), visibility="advanced"),
            _a("windows.boot.status", "Windows VM", "Status boot Windows", "Audita entrada de boot direto.", ("windows-vm", "boot", "status"), "system-reboot", visibility="advanced"),

            _a("waydroid.host.status", "Waydroid", "Status armazenamento Android", "Estado do link host→Android.", ("waydroid", "host-access", "status"), "folder-open", visibility="advanced"),
            _a("waydroid.host.unlink", "Waydroid", "Desvincular armazenamento", "Remove link host→Android sem apagar dados.", ("waydroid", "host-access", "unlink"), "edit-unlink", mutable=True, preview=("waydroid", "host-access", "status"), visibility="advanced"),
            _a("waydroid.boot.status", "Waydroid", "Status boot Waydroid", "Audita entrada de boot Android.", ("waydroid", "boot", "status"), "system-reboot", visibility="advanced"),

            _a("server.llm.status", "Servidor", "Status LLM", "Estado do Ollama e exposição de rede.", ("server", "llm", "status"), "network-server", visibility="advanced"),
            _a("server.llm.expose", "Servidor", "Expor LLM na LAN", "Habilita acesso LAN ao LLM local.", ("server", "llm", "expose-lan"), "network-wired", mutable=True, preview=("server", "llm", "status"), visibility="advanced"),
            _a("server.llm.restore", "Servidor", "Restaurar LLM local", "Remove exposição e restaura defaults.", ("server", "llm", "restore"), "edit-undo", mutable=True, preview=("server", "llm", "status"), visibility="advanced"),
            _a("server.hermes.status", "Servidor", "Status Hermes", "Estado da atuação remota.", ("server", "hermes", "status"), "network-transmit-receive", visibility="advanced"),
            _a("server.hermes.start", "Servidor", "Uso Hermes remoto bloqueado", "Não inicia agente remoto sem grant PhaseZero vinculado a cada requisição.", ("server", "hermes", "start"), "media-playback-start", mutable=True, preview=("server", "hermes", "status"), visibility="advanced"),
            _a("server.slim.status", "Servidor", "Status modo enxuto", "Serviços afetados pelo slimming.", ("server", "slim", "status"), "preferences-system-performance", visibility="advanced"),
            _a("server.boot.status", "Servidor", "Status boot servidor", "Audita entrada headless.", ("server", "boot", "status"), "system-reboot", visibility="advanced"),
            _a("server.boot.remove", "Servidor", "Remover boot servidor", "Remove entrada GRUB headless.", ("server", "boot", "remove"), "edit-delete", mutable=True, preview=("server", "boot", "status"), elevated=True, visibility="advanced"),

            _a("emulation.eden-integrate", "Emulação", "Integrar Eden", "Integra Eden com ES-DE, SRM e paths.", ("emulation", "eden", "integrate"), "applications-games", mutable=True, preview=("emulation", "eden", "dry-run"), visibility="advanced"),
            _a("emulation.citron-integrate", "Emulação", "Integrar Citron", "Integra Citron com ES-DE, SRM e paths.", ("emulation", "citron", "integrate"), "applications-games", mutable=True, preview=("emulation", "citron", "dry-run"), visibility="advanced"),
            _a("emulation.hydra-configure", "Emulação", "Configurar Hydra", "Configura Hydra Classic e emuladores.", ("emulation", "hydra", "configure"), "applications-games", mutable=True, preview=("emulation", "hydra", "status"), visibility="advanced"),
            _a("emulation.ps1", "Emulação", "Configurar PlayStation 1", "Configura paths DuckStation.", ("emulation", "ps1", "configure"), "applications-games", mutable=True, preview=("emulation", "status"), visibility="advanced"),
            _a("emulation.ps2", "Emulação", "Configurar PlayStation 2", "Configura paths PCSX2.", ("emulation", "ps2", "configure"), "applications-games", mutable=True, preview=("emulation", "status"), visibility="advanced"),
            _a("emulation.ps3-pkg", "Emulação", "Importar PKG PS3", "Instala pacote PKG (jogo ou loja) no PS3.", ("emulation", "ps3", "import-pkg", "{input}"), "package-x-generic", mutable=True, preview=("emulation", "ps3", "dry-run"), parameters=(_p("input", "Selecione PKG PS3", "file"),), visibility="advanced"),
            _a("emulation.ps3-rap", "Emulação", "Importar RAP PS3", "Importa licença RAP para ativar um PKG instalado.", ("emulation", "ps3", "import-rap", "{input}"), "dialog-password", mutable=True, preview=("emulation", "ps3", "dry-run"), parameters=(_p("input", "Selecione RAP", "file"),), visibility="advanced"),
            _a("emulation.performance.status", "Emulação", "Status performance", "Audita perfis adaptativos.", ("emulation", "performance", "status"), "utilities-system-monitor", visibility="advanced"),
            _a("emulation.dualscreen.status", "Emulação", "Detectar telas", "Detecta Deck e display externo.", ("emulation", "dualscreen", "detect"), "video-display", visibility="advanced"),
            _a("emulation.lua.status", "Emulação", "Status Lua", "Audita Lua, LuaJIT e LuaRocks.", ("emulation", "lua", "status"), "utilities-terminal", visibility="advanced"),
            _a("emulation.steam-tools.status", "Emulação", "Status Steam tools", "Audita ferramentas auxiliares Steam.", ("emulation", "steam-tools", "status"), "applications-games", visibility="advanced"),
            _a("emulation.retrodeck.status", "Emulação", "Status RetroDECK", "Audita ecossistema compartilhado.", ("emulation", "retrodeck", "status"), "applications-games", visibility="advanced"),
            _a("emulation.retrodeck.plan", "Emulação", "Plano RetroDECK", "Prévia de migrações e links.", ("emulation", "retrodeck", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.retrodeck.repair", "Emulação", "Reparar RetroDECK", "Repara links do ecossistema.", ("emulation", "retrodeck", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "retrodeck", "plan"), visibility="advanced"),
            _a("emulation.shared.status", "Emulação", "Status conteúdo compartilhado", "Audita ROMs, saves e BIOS.", ("emulation", "shared", "status"), "folder-sync", visibility="advanced"),
            _a("emulation.shared.plan", "Emulação", "Plano conteúdo compartilhado", "Prévia de links e cópias.", ("emulation", "shared", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.shared.repair", "Emulação", "Reparar conteúdo compartilhado", "Repara links entre consumidores.", ("emulation", "shared", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "shared", "plan"), visibility="advanced"),
            _a("emulation.media.status", "Emulação", "Status de mídia", "Audita capas e metadados.", ("emulation", "media", "status"), "image-x-generic", visibility="advanced"),
            _a("emulation.media.index", "Emulação", "Indexar mídia", "Reconstrói media-index.json.", ("emulation", "media", "index"), "view-refresh", mutable=True, preview=("emulation", "media", "status"), visibility="advanced"),
            _a("emulation.media.plan", "Emulação", "Plano de mídia", "Prévia de canonicalização.", ("emulation", "media", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.media.repair", "Emulação", "Reparar mídia", "Repara paths de mídia.", ("emulation", "media", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "media", "plan"), visibility="advanced"),
            _a("emulation.pc-games.status", "Emulação", "Status jogos PC", "Audita jogos locais e Steam.", ("emulation", "pc-games", "status"), "applications-games", visibility="advanced"),
            _a("emulation.pc-games.plan", "Emulação", "Plano jogos PC", "Prévia de launchers.", ("emulation", "pc-games", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.shortcuts.status", "Emulação", "Status atalhos", "Audita launchers AppImage.", ("emulation", "shortcuts", "status"), "application-x-desktop", visibility="advanced"),
            _a("emulation.shortcuts.plan", "Emulação", "Plano atalhos", "Prévia de limpeza de launchers.", ("emulation", "shortcuts", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.launchbox.status", "Emulação", "Status LaunchBox", "Audita integração Wine.", ("emulation", "launchbox", "status"), "applications-games", visibility="advanced"),
            _a("emulation.launchbox.plan", "Emulação", "Plano LaunchBox", "Prévia de bridges ROM/mídia.", ("emulation", "launchbox", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.launchbox.repair", "Emulação", "Reparar LaunchBox", "Repara Wine, ROMs e mídia.", ("emulation", "launchbox", "repair"), "tools-check-spelling", mutable=True, preview=("emulation", "launchbox", "plan"), visibility="advanced"),
            _a("emulation.controllers.status", "Emulação", "Status controles", "Audita perfis Ryujinx/RPCS3.", ("emulation", "controllers", "status"), "input-gaming", visibility="advanced"),
            _a("emulation.frontends.status", "Emulação", "Status frontends", "Audita switcher de frontends.", ("emulation", "frontends", "status"), "view-grid", visibility="advanced"),
            _a("emulation.frontends.plan", "Emulação", "Plano frontends", "Prévia da integração cruzada.", ("emulation", "frontends", "plan"), "document-properties", visibility="advanced"),
            _a("emulation.nsz.status", "Emulação", "Status NSZ", "Audita conversor, keys e espaço.", ("emulation", "nsz", "status"), "document-export", visibility="advanced"),
            _a("emulation.nsz.plan", "Emulação", "Plano NSZ", "Prévia de conversão para arquivo ou pasta.", ("emulation", "nsz", "plan", "{input}"), "document-properties", parameters=(_p("input", "Selecione NSZ ou pasta", "path"),), visibility="advanced"),
            _a("emulation.nsz.install", "Emulação", "Instalar NSZ", "Instala conversor fixado para usuário.", ("emulation", "nsz", "install"), "system-software-install", mutable=True, preview=("emulation", "nsz", "status"), visibility="advanced"),
            _a("emulation.nsz.apply", "Emulação", "Converter todos NSZ", "Converte, deduplica e limpa fontes verificadas.", ("emulation", "nsz", "apply", "--yes"), "document-export", mutable=True, preview=("emulation", "nsz", "plan"), risk="high", visibility="advanced"),
            _a("emulation.optimizer.status", "Emulação", "Status configs por jogo", "Lista configurações documentadas.", ("emulation", "optimizer", "status"), "preferences-system-gaming", visibility="advanced"),

            _a("flatpak.remote.add", "Flatpak", "Adicionar remote", "Adiciona repositório Flatpak.", ("flatpak", "remote", "add", "{name}", "{url}"), "list-add", mutable=True, preview=("flatpak", "remotes"), parameters=(_p("name", "Nome do remote"), _p("url", "URL do remote", "text", placeholder="https://…")), visibility="advanced"),
            _a("flatpak.remote.remove", "Flatpak", "Remover remote", "Remove repositório Flatpak.", ("flatpak", "remote", "remove", "{name}"), "list-remove", mutable=True, preview=("flatpak", "remotes"), parameters=(_p("name", "Nome do remote"),), visibility="advanced"),
            _a("flatpak.overrides.apply", "Flatpak", "Aplicar overrides globais", "Aplica overrides gaming ao usuário.", ("flatpak", "overrides", "apply", "--global"), "preferences-system", mutable=True, preview=("flatpak", "audit"), visibility="advanced"),
            _a("flatpak.overrides.remove", "Flatpak", "Remover overrides globais", "Remove overrides PhaseZero.", ("flatpak", "overrides", "remove", "--global"), "edit-undo", mutable=True, preview=("flatpak", "audit"), visibility="advanced"),

            _a("ai.desktop.status", "IA & Dev", "Status apps IA", "Audita Claude/Qwen/Codex desktop.", ("ai", "desktop", "status"), "applications-development", visibility="advanced"),
            _a("ai.desktop.claude", "IA & Dev", "Instalar Claude Desktop", "Instala app oficial para usuário.", ("ai", "desktop", "install-claude"), "system-software-install", mutable=True, preview=("ai", "desktop", "status"), visibility="advanced"),
            _a("ai.desktop.qwen", "IA & Dev", "Instalar Qwen Code Desktop", "Instala AppImage oficial verificada para usuário.", ("ai", "desktop", "install-qwen"), "system-software-install", mutable=True, preview=("ai", "desktop", "status"), visibility="advanced"),
            _a("ai.desktop.codex", "IA & Dev", "Reparar Codex Desktop", "Repara atualização local falha.", ("ai", "desktop", "repair-codex"), "tools-check-spelling", mutable=True, preview=("ai", "desktop", "status"), visibility="advanced"),
            _a("ai.token-economy", "IA & Dev", "Economia de tokens", "Audita contexto e runtime de agentes.", ("ai", "token-economy", "status"), "utilities-system-monitor", visibility="advanced"),
            _a("ai.admin.status", "IA & Dev", "Status admin bridge", "Audita elevação PhaseZero.", ("ai", "admin", "status"), "security-high", visibility="advanced"),
            _a("ai.omo.status", "IA & Dev", "Status OMO", "Audita oh-my-openagent.", ("ai", "omo", "status"), "applications-development", visibility="advanced"),
            _a("ai.omo.doctor", "IA & Dev", "Diagnóstico OMO", "Diagnostica plugin OpenCode.", ("ai", "omo", "doctor"), "system-search", visibility="advanced"),
            _a("ai.omo.enable", "IA & Dev", "Ativar OMO", "Ativa plugin OpenCode.", ("ai", "omo", "enable"), "media-playback-start", mutable=True, preview=("ai", "omo", "status"), visibility="advanced"),
            _a("ai.omo.disable", "IA & Dev", "Desativar OMO", "Desativa plugin sem remover.", ("ai", "omo", "disable"), "media-playback-pause", mutable=True, preview=("ai", "omo", "status"), visibility="advanced"),
            _a("ai.omo.uninstall", "IA & Dev", "Remover OMO", "Remove plugin OpenCode.", ("ai", "omo", "uninstall"), "edit-delete", mutable=True, preview=("ai", "omo", "status"), risk="high", visibility="advanced"),
            _a("ai.opencode.local", "IA & Dev", "Modelo local OpenCode", "Configura modelo Ollama local.", ("ai", "opencode", "local-model"), "applications-development", mutable=True, preview=("ai", "opencode", "status"), visibility="advanced"),
            _a("ai.opencode.hook", "IA & Dev", "Instalar hook OpenCode", "Instala sincronização automática.", ("ai", "opencode", "install-hook"), "system-run", mutable=True, preview=("ai", "opencode", "status"), visibility="advanced"),
            _a("ai.secrets.rotate", "IA & Dev", "Rotacionar secrets IA", "Rotaciona chaves gerenciadas sem exibi-las.", ("ai", "secrets", "rotate"), "dialog-password", mutable=True, preview=("ai", "status"), risk="high", visibility="advanced"),
            _a(
                "ai.backup.export", "IA & Dev", "Exportar memória e acessos",
                "Cria pacote AES-256 com ai-memory e allowlist de chaves. Exclui cookies e perfis de navegador.",
                ("ai", "backup", "create", "--include-credentials", "--passphrase-stdin"),
                "document-save", mutable=True,
                preview=("ai", "backup", "plan", "--include-credentials"),
                parameters=(_p("passphrase", "Senha do pacote", "secret", placeholder="mínimo 12 caracteres"),),
                stdin_parameter="passphrase", badge="Protegido", visibility="primary",
            ),
            _a(
                "ai.backup.verify", "IA & Dev", "Verificar backup de IA",
                "Descriptografa em área temporária e valida manifesto e SHA-256 sem restaurar.",
                ("ai", "backup", "verify", "--bundle", "{bundle}", "--passphrase-stdin"),
                "document-preview",
                parameters=(
                    _p("bundle", "Pacote criptografado", "file"),
                    _p("passphrase", "Senha do pacote", "secret"),
                ),
                stdin_parameter="passphrase", badge="Seguro", visibility="primary",
            ),
            _a(
                "ai.backup.restore", "IA & Dev", "Restaurar memória e acessos",
                "Verifica o pacote, mostra destinos, faz pré-backup e aplica com rollback.",
                ("ai", "backup", "restore", "--bundle", "{bundle}", "--passphrase-stdin", "--confirm", "RESTORE"),
                "document-revert", mutable=True,
                preview=("ai", "backup", "restore", "--plan", "--bundle", "{bundle}", "--passphrase-stdin"),
                parameters=(
                    _p("bundle", "Pacote criptografado", "file"),
                    _p("passphrase", "Senha do pacote", "secret"),
                ),
                stdin_parameter="passphrase", stdin_on_preview=True,
                badge="Reversível", risk="high", visibility="advanced",
            ),
            _a("ai.mcp.status", "IA & Dev", "Status MCP", "Audita servidores MCP.", ("ai", "mcp", "status"), "network-server", visibility="advanced"),
            _a("ai.mcp.list", "IA & Dev", "Listar MCPs", "Lista servidores instalados.", ("ai", "mcp", "list"), "view-list-details", visibility="advanced"),
            _a("ai.mcp.install", "IA & Dev", "Instalar MCP", "Instala servidor MCP pelo identificador.", ("ai", "mcp", "install", "{server}"), "system-software-install", mutable=True, preview=("ai", "mcp", "status"), parameters=(_p("server", "Servidor MCP"),), visibility="advanced"),
            _a("ai.mcp.repair", "IA & Dev", "Reparar MCPs", "Remove quebrados e reinstala defaults seguros.", ("ai", "mcp", "repair", "all"), "tools-check-spelling", mutable=True, preview=("ai", "mcp", "status"), visibility="advanced"),
            _a("ai.proxies.status", "Proxies IA", "Status proxies IA", "Audita suite OpenAI-compatible.", ("ai", "proxies", "status"), "network-server", visibility="advanced"),
            _a("ai.proxies.detailed-status", "Proxies IA", "Status consolidado", "Instalação, serviços, autenticação e IDEs em um JSON.", ("ai", "proxies", "detailed-status"), "system-search", badge="JSON", visibility="advanced"),
            _a("ai.proxies.restart-one", "Proxies IA", "Reinício bloqueado", "Não reinicia proxy consumidor até grant aplicado por requisição.", ("ai", "proxies", "restart", "{proxy}"), "view-refresh", mutable=True, preview=("ai", "proxies", "status"), parameters=(_p("proxy", "Proxy", "choice", choices=("all", "kimiproxy", "qwenproxy", "deepsproxy", "mimo-ai-proxy")),), visibility="advanced"),
            _a("ai.proxies.test-one", "Proxies IA", "Probe bloqueado", "Não envia inferência de probe até grant aplicado por requisição.", ("ai", "proxies", "test", "{proxy}"), "network-server", parameters=(_p("proxy", "Proxy", "choice", choices=("kimiproxy", "qwenproxy", "deepsproxy", "mimo-ai-proxy", "9router")),), visibility="advanced"),
            _a("ai.9router.provider-status", "IA & Dev", "Providers 9Router", "Lista conexões sem revelar chaves.", ("ai", "9router", "provider", "status"), "network-server", visibility="advanced"),
            _a("ai.9router.combo-list", "IA & Dev", "Combos 9Router", "Lista cadeias de fallback ativas.", ("ai", "9router", "combo", "list"), "view-list-details", visibility="advanced"),
            _a("ai.9router.watchdog-install", "IA & Dev", "Ativar watchdog 9Router", "Coleta saúde passiva e telemetria resumida a cada dez minutos.", ("ai", "9router", "watchdog", "install"), "appointment-new", mutable=True, preview=("ai", "9router", "status"), visibility="advanced"),
            _a("ai.codexbar.watchdog-install", "IA & Dev", "Ativar watchdog CodexBar", "Ativa verificação horária sem tocar no Plasma.", ("ai", "codexbar", "watchdog", "install"), "appointment-new", mutable=True, preview=("ai", "codexbar", "watchdog", "status"), visibility="advanced"),
            _a("ai.codexbar.watchdog-remove", "IA & Dev", "Desativar watchdog CodexBar", "Remove timer de saúde CodexBar.", ("ai", "codexbar", "watchdog", "remove"), "appointment-missed", mutable=True, preview=("ai", "codexbar", "watchdog", "status"), visibility="advanced"),
            _a("ai.codexbar.plasmoid-remove", "IA & Dev", "Remover KodexBar do Plasma", "Faz backup do layout, remove instâncias via DBus e desinstala pacote QML.", ("ai", "codexbar", "plasmoid-remove"), "edit-delete", mutable=True, preview=("ai", "codexbar", "status"), risk="high", visibility="advanced"),
            _a("ai.setup.tool", "IA & Dev", "Instalar ferramenta IA", "Executa setup disponível; consumidores sem grant por requisição ficam fora da seleção.", ("ai", "setup", "{tool}"), "system-software-install", mutable=True, preview=("ai", "status"), parameters=(_p("tool", "Ferramenta", "choice", choices=("codex", "ollama", "claude", "desktop", "opencode", "omo", "memory", "admin", "rtk", "caveman", "headroom", "compat", "ides", "ide-apps", "usagebar", "codexbar", "all")),), visibility="advanced"),
            _a("ai.mcp.sync-target", "IA & Dev", "Sincronizar MCP por cliente", "Sincroniza servidores seguros no cliente escolhido.", ("ai", "mcp", "sync", "{target}"), "folder-sync", mutable=True, preview=("ai", "mcp", "status"), parameters=(_p("target", "Cliente", "choice", choices=("all", "codex", "claude", "opencode", "vscode")),), visibility="advanced"),
            _a("ai.proxies.install-one", "Proxies IA", "Instalar proxy específico", "Instala ou atualiza um proxy da suite.", ("ai", "proxies", "install", "{proxy}"), "network-server", mutable=True, preview=("ai", "proxies", "status"), parameters=(_p("proxy", "Proxy", "choice", choices=("all", "kimiproxy", "qwenproxy", "deepsproxy", "9router")),), visibility="advanced"),

            _a("desktop.webapps.status", "Aplicativos", "Status web apps", "Lista launchers web instalados.", ("webapp", "status"), "applications-internet", visibility="standard"),
            _a("desktop.menu.scan", "Aplicativos", "Analisar menu PhaseZero", "Inventaria launchers, duplicatas e raízes legadas sem alterar o desktop.", ("ui", "menu", "scan", "--json"), "system-search", group="Menu PhaseZero", result_view="table", visibility="primary"),
            _a("desktop.menu.plan", "Aplicativos", "Prévia da organização", "Mostra a árvore única PhaseZero e entradas que serão consolidadas.", ("ui", "menu", "plan", "--json"), "document-preview", group="Menu PhaseZero", result_view="table", visibility="primary"),
            _a("desktop.menu.apply", "Aplicativos", "Organizar menu PhaseZero", "Cria uma raiz PhaseZero, consolida submenus e registra rollback.", ("ui", "menu", "apply", "--json"), "view-list-tree", mutable=True, preview=("ui", "menu", "plan", "--json"), badge="Reversível", group="Menu PhaseZero", visibility="primary"),
            _a("desktop.menu.rollback", "Aplicativos", "Restaurar menu anterior", "Restaura menus e diretórios do último ledger privado.", ("ui", "menu", "rollback", "--json"), "edit-undo", mutable=True, preview=("ui", "menu", "scan", "--json"), badge="Reversível", group="Menu PhaseZero", visibility="advanced"),
            _a("desktop.webapps.install", "Aplicativos", "Instalar web app", "Cria launcher isolado para serviço web.", ("webapp", "install", "{slug}"), "applications-internet", mutable=True, preview=("webapp", "status"), parameters=(_p("slug", "Identificador do web app"),), visibility="standard"),
            _a("desktop.webapps.all", "Aplicativos", "Instalar todos web apps", "Instala catálogo completo de launchers.", ("webapp", "install-all"), "applications-internet", mutable=True, preview=("webapp", "status"), visibility="advanced"),
            _a("desktop.games.status", "Aplicativos", "Status menu de jogos", "Lista jogos e emuladores detectados.", ("games", "status"), "applications-games", visibility="standard"),
            _a("desktop.games.scan", "Aplicativos", "Escanear jogos", "Detecta jogos, frontends e emuladores.", ("games", "scan"), "system-search", visibility="standard"),
            _a("desktop.games.install", "Aplicativos", "Instalar menus de jogos", "Cria launchers para itens detectados.", ("games", "install-all"), "applications-games", mutable=True, preview=("games", "status"), visibility="standard"),
        ]
    )

    # Capability expansion inspired by LinuxToys concepts, reimplemented as a
    # signed-repository/Flatpak-only plan/apply/verify/rollback contract.
    from linux.capabilities.catalog import CAPABILITIES, GROUPS, PROFILES

    actions.extend(
        [
            _a(
                "capability.detect", "Recursos", "Compatibilidade do host",
                "Detecta distribuição, imutabilidade, GPU, sessão e providers confiáveis.",
                ("capabilities", "detect"), "system-search",
                group="Visão geral", visibility="primary", result_view="table",
            ),
            _a(
                "capability.status", "Recursos", "Estado dos recursos",
                "Mostra disponibilidade e instalação no host atual.",
                ("capabilities", "status"), "view-list-details",
                group="Visão geral", visibility="primary", result_view="table",
            ),
            _a(
                "capability.profiles", "Recursos", "Perfis disponíveis",
                "Lista composições prontas por jornada.",
                ("capabilities", "profiles"), "view-list-tree",
                group="Visão geral", visibility="standard", result_view="table",
            ),
            _a(
                "capability.manifest.plan", "Recursos", "Planejar manifesto",
                "Valida manifesto JSON versionado sem executar alterações.",
                ("capabilities", "plan", "--manifest", "{manifest}"),
                "document-preview", group="Perfis prontos", visibility="standard",
                parameters=(_p("manifest", "Manifesto JSON", "file"),), result_view="table",
            ),
            _a(
                "capability.apply", "Recursos", "Aplicar plano confirmado",
                "Revalida fontes e aplica o plano pelo ID e token gerados.",
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "system-software-install", mutable=True,
                preview=("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}", "--dry-run"),
                elevated=True, badge="Protegido", group="Operação e recuperação",
                visibility="standard", result_view="table",
                parameters=(
                    _p("plan_id", "ID do plano", placeholder="plan-…"),
                    _p("confirm", "Token de confirmação", placeholder="Gerado pelo plano"),
                ),
            ),
            _a(
                "capability.verify", "Recursos", "Verificar operação",
                "Confirma que cada recurso instalado pela operação continua presente.",
                ("capabilities", "verify", "--operation-id", "{operation_id}"),
                "dialog-ok", group="Operação e recuperação", visibility="standard",
                parameters=(_p("operation_id", "ID da operação", placeholder="operation-…"),),
                result_view="table",
            ),
            _a(
                "capability.rollback", "Recursos", "Reverter operação",
                "Remove somente recursos instalados pela operação; preserva preexistentes.",
                ("capabilities", "rollback", "--operation-id", "{operation_id}", "--confirm", "{confirm}"),
                "edit-undo", mutable=True,
                preview=("capabilities", "rollback", "--operation-id", "{operation_id}", "--confirm", "{confirm}", "--dry-run"),
                elevated=True, badge="Reversível", group="Operação e recuperação",
                visibility="advanced", result_view="table",
                parameters=(
                    _p("operation_id", "ID da operação", placeholder="operation-…"),
                    _p("confirm", "Token de rollback", placeholder="Gerado pela operação"),
                ),
            ),
        ]
    )
    for profile_id, capability_ids in PROFILES.items():
        actions.append(
            _a(
                f"capability.profile.{profile_id}", "Recursos",
                profile_id.replace("-", " ").title(),
                f"Cria plano seguro para {len(capability_ids)} recursos; nada é instalado nesta etapa.",
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "document-preview", mutable=True,
                preview=("capabilities", "plan", "--profile", profile_id),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                elevated=True, badge="Protegido", group="Perfis prontos", visibility="primary",
                keywords=(profile_id, "perfil", "workstation"), result_view="table",
            )
        )
    for capability in CAPABILITIES:
        actions.append(
            _a(
                f"capability.plan.{capability.id}", "Recursos", capability.title,
                capability.description,
                ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "document-preview", mutable=True,
                preview=("capabilities", "plan", "--capability", capability.id),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                elevated=True, group=GROUPS[capability.group],
                visibility="advanced" if capability.risk == "high" else "standard",
                risk=capability.risk, badge="Plano seguro",
                keywords=(capability.id, capability.group, *capability.keywords),
                result_view="table",
            )
        )

    # Dedicated "Roteamento IA" page: per-task routes driven by 9Router
    # inventory, quota and policy (linux/ai/routing_manager.py).
    routing_rows = [
        ("routing-status", "Status Roteamento IA", "Inventário redigido: saúde, estados e cotas.", ("ai", "routing", "status", "--json"), None),
        ("routing-inventory", "Atualizar cotas", "Coleta inventário e quota por conexão (estado cacheado).", ("ai", "routing", "inventory", "--refresh-quota", "--json"), None),
        ("routing-recommend-code", "Recomendar rota — Código", "Cadeia de fallback para escrever código.", ("ai", "routing", "recommend", "--task", "code", "--json"), None),
        ("routing-recommend-analysis", "Recomendar rota — Análise", "Cadeia de fallback para análise/revisão.", ("ai", "routing", "recommend", "--task", "analysis", "--json"), None),
        ("routing-recommend-plan", "Recomendar rota — Plano", "Cadeia de fallback para planejamento.", ("ai", "routing", "recommend", "--task", "plan", "--json"), None),
        ("routing-plan", "Plano Código · Equilibrado (diff)", "Mostra combo alvo e variáveis de ambiente, sem mutar.", ("ai", "routing", "plan", "--task", "code", "--client", "claude"), None),
        ("routing-apply-all", "Aplicar 3 rotas · Equilibrado", "Materializa os três combos phasezero-* com uma política global e transação única.", ("ai", "routing", "apply", "--task", "code", "--policy", "balanced", "--yes"), ("ai", "routing", "apply", "--task", "code", "--policy", "balanced", "--dry-run")),
        ("routing-verify", "Verificar roteamento", "Valida combos vs plano, redação e isolamento Bonsai.", ("ai", "routing", "verify"), None),
        ("routing-refresh", "Refresh automático de cotas", "Atualização explícita de quota (scheduler 5–10 min).", ("ai", "routing", "refresh"), None),
    ]
    for key, title, description, args, preview in routing_rows:
        actions.append(
            _a(
                f"ai.{key}",
                "Roteamento IA",
                title,
                description,
                args,
                "network-transmit-receive",
                mutable=preview is not None,
                preview=preview,
                badge="Prévia" if preview else "",
            )
        )
    # "Temas" page: appearance + accessibility with plan/preview/apply
    # bindings (the CLI emits {id, confirmToken}; apply consumes both).
    _themes_features = (
        ("theme.phasezero", "Tema PhaseZero", "Tema padrão com persistência no PhaseZero."),
        ("theme.kde", "Tema global KDE", "Look and feel do Plasma."),
        ("theme.colorscheme", "Esquema de cores", "Colorscheme ativo do KDE."),
        ("theme.icons", "Ícones", "Tema de ícones do KDE."),
        ("theme.cursor", "Cursor", "Tema e tamanho do cursor."),
        ("theme.accent", "Cor de destaque", "Accent color extraído do wallpaper ou explícito."),
        ("theme.auto-dark", "Alternância claro/escuro", "Esquema escuro automático do KDE."),
        ("theme.night-color", "Night Color", "Luz noturna por horário."),
        ("access.text-size", "Texto maior", "Escala de texto em percentual (50–300)."),
        ("access.reduce-motion", "Movimento reduzido", "Reduz animações do KWin e do KDE."),
        ("access.locate-cursor", "Localizar cursor", "Busca visual do cursor ao digitar."),
        ("access.zoom", "Zoom", "Efeito de zoom do KWin."),
        ("access.colorblind", "Filtro de daltonismo", "Correção protanopia/deuteranopia/tritanopia/achromatopsia."),
        ("access.visual-alert", "Alerta visual", "Sino visível em vez de beep."),
        ("access.screen-reader", "Leitor de tela", "Orca iniciado na sessão."),
        ("access.sticky-keys", "Teclas aderentes", "Modificadores permanecem pressionados."),
        ("access.slow-keys", "Teclas lentas", "Aceita teclas mantidas por um instante."),
        ("access.bounce-keys", "Teclas de repercussão", "Ignora toques repetidos."),
        ("power.adaptive", "Animações adaptativas", "Pausa animações em bateria."),
        ("power.pause-on-game", "Pausar em jogos", "Pausa animações durante Game Mode."),
        (
            "desktop.controller",
            "Mapa do controle",
            "O controle vira mouse e teclado neste desktop. Vem ligado. "
            "Desligar para o mapa; o ponteiro do firmware não volta sozinho. "
            "Ligar de novo recusa enquanto o Steam ou o gamescope estiver aberto.",
        ),
        (
            "desktop.terminal-keyboard",
            "Teclado no terminal",
            "Um toque na tela abre o teclado quando o Ashyterm, o Konsole, o kitty "
            "ou o Yakuake está em foco. Vem ligado. Desligar só tira esse toque; "
            "o teclado do Steam+X continua.",
        ),
    )
    for feature_id, title, description in _themes_features:
        for state, state_label in (("on", "Ativar"), ("off", "Desativar")):
            actions.append(
                _a(
                    f"themes.feature.{feature_id}.{state}",
                    "Temas",
                    f"{title} — {state_label}",
                    description,
                    ("themes", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                    "preferences-desktop-theme",
                    mutable=True,
                    preview=("themes", "plan", "--feature", feature_id, "--state", state),
                    preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                    badge="Prévia" if state == "on" else "Reversível",
                    keywords=(feature_id, state),
                )
            )
    _themes_profiles = (
        ("essencial", "Perfil Essencial", "Segue o sistema, texto 110%, foco reforçado e movimento reduzido."),
        ("steam-deck", "Perfil Steam Deck", "Game Mode, botões acessíveis e pausa de animações em jogos."),
        ("gamer", "Perfil Gamer", "Conforto visual e redução de distração durante partidas."),
        ("desenvolvedor", "Perfil Desenvolvedor", "Alto contraste, texto maior e leitor de tela opcional."),
    )
    for profile_id, title, description in _themes_profiles:
        actions.append(
            _a(
                f"themes.profile.{profile_id}",
                "Temas",
                title,
                description,
                ("themes", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "package-x-generic",
                mutable=True,
                preview=("themes", "plan", "--profile", profile_id),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                badge="Prévia",
                keywords=(profile_id,),
            )
        )
    _themes_wallpapers = (
        ("pz.geo-dark", "PhaseZero Geo (escuro)", "Wallpaper vetorial CC0 do PhaseZero."),
        ("pz.aurora", "PhaseZero Aurora", "Wallpaper vetorial CC0 do PhaseZero."),
        ("pz.solid-charcoal", "PhaseZero Carvão (sólido)", "Cor sólida com visual discreto."),
    )
    for wallpaper_id, title, description in _themes_wallpapers:
        actions.append(
            _a(
                f"themes.wallpaper.{wallpaper_id}",
                "Temas",
                title,
                description,
                ("themes", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
                "image-x-generic",
                mutable=True,
                preview=("themes", "plan", "--wallpaper", wallpaper_id, "--screen", "0", "--target", "desktop"),
                preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
                badge="Prévia",
                keywords=(wallpaper_id, "wallpaper"),
            )
        )
    actions.extend(
        [
            _a("themes.status", "Temas", "Status de temas", "Estado efetivo da sessão: features, Plasma, bateria e wallpapers.", ("themes", "status"), "preferences-desktop-theme", badge="JSON", group="Temas", visibility="primary", status_args=("themes", "status")),
            _a("themes.catalog", "Temas", "Catálogo avaliado", "Features, perfis, wallpapers, extensões KDE e plugins Steam.", ("themes", "catalog"), "view-list-tree", badge="JSON", group="Temas"),
            _a("themes.history", "Temas", "Histórico de operações", "Últimas operações e rollbacks aplicados.", ("themes", "history"), "document-edit-history", badge="JSON", group="Temas"),
            _a("themes.undo", "Temas", "Desfazer última alteração", "Restaura o snapshot mais recente byte a byte.", ("themes", "rollback"), "edit-undo", mutable=True, preview=("themes", "history"), badge="Reversível", group="Temas"),
            _a("themes.rescue-wallpaper", "Temas", "Restaurar wallpaper (crash)", "Restaura wallpaper estático após crash do Plasma.", ("themes", "rescue-wallpaper"), "view-refresh", badge="Recuperação", group="Temas"),
        ]
    )
    actions.append(
        _a(
            "ai.routing-rollback",
            "Roteamento IA",
            "Rollback Roteamento IA",
            "Restaura combos e estado registrados por um manifesto routing-apply.",
            ("ai", "routing", "rollback", "{input}"),
            "edit-undo",
            mutable=True,
            preview=("ai", "routing", "verify"),
            input_label="Selecione manifest.json",
            input_kind="file",
            badge="Reversível",
        )
    )

    actions = [_with_impact(action) for action in actions]
    validate_catalog(actions)
    selected_platform = current_platform(platform_name)
    return [action for action in actions if selected_platform in action.platforms]


def validate_catalog(actions: list[ActionSpec]) -> None:
    ids = [item.id for item in actions]
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate action id in native UI catalog")
    categories = {row[0] for row in CATEGORIES}
    for item in actions:
        if item.category not in categories:
            raise ValueError(f"unknown category for {item.id}: {item.category}")
        if item.visibility not in {"primary", "standard", "advanced"}:
            raise ValueError(f"invalid visibility for {item.id}: {item.visibility}")
        if item.risk not in {"normal", "elevated", "high"}:
            raise ValueError(f"invalid risk for {item.id}: {item.risk}")
        if item.mutable and item.preview_args is None:
            raise ValueError(f"mutable action lacks preview: {item.id}")
        if item.mutable and item.risk == "high" and item.preview_kind != "plan" and not item.impact:
            raise ValueError(f"high-risk action needs a plan preview or impact text: {item.id}")
        if not item.platforms:
            raise ValueError(f"action lacks platform: {item.id}")
        names = item.parameter_names
        if len(names) != len(set(names)):
            raise ValueError(f"duplicate parameter for {item.id}")
        placeholders = {
            match.group(1)
            for token in (*item.args, *(item.preview_args or ()))
            for match in [re.fullmatch(r"\{([A-Za-z0-9_-]+)\}", token)]
            if match
        }
        missing = placeholders - set(names)
        if missing:
            raise ValueError(f"action {item.id} lacks parameters: {sorted(missing)}")


def catalog_manifest(root: Path, platform_name: str | None = None) -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "categories": [row[0] for row in CATEGORIES],
        "actions": [
            {
                "id": item.id,
                "category": item.category,
                "title": item.title,
                "description": item.description,
                "args": list(item.args),
                "previewArgs": list(item.preview_args) if item.preview_args else None,
                "statusArgs": list(item.status_args) if item.status_args else None,
                "mutable": item.mutable,
                "elevated": item.elevated,
                "group": item.group,
                "visibility": item.visibility,
                "platforms": list(item.platforms),
                "risk": item.risk,
                "resultView": item.result_view,
                "stdinOnPreview": item.stdin_on_preview,
                "parameters": [
                    {
                        "name": parameter.name,
                        "label": parameter.label,
                        "kind": parameter.kind,
                        "required": parameter.required,
                        "choices": list(parameter.choices),
                        "placeholder": parameter.placeholder,
                    }
                    for parameter in item.parameters
                ],
                "previewBindings": [
                    {"parameter": parameter, "resultKey": result_key}
                    for parameter, result_key in item.preview_bindings
                ],
            }
            for item in build_catalog(root, platform_name)
        ],
    }


def write_manifest(root: Path, destination: Path) -> None:
    destination.write_text(json.dumps(catalog_manifest(root), ensure_ascii=False, indent=2) + "\n")
