from __future__ import annotations

from .models import CapabilitySpec, Compatibility, SourceSpec
from .platform import HostFacts


GROUPS = {
    "gaming": "Gaming e streaming",
    "hardware": "Hardware e drivers",
    "health": "Saúde e desempenho",
    "development": "Desenvolvimento",
    "security": "Segurança e privacidade",
    "backup": "Backup e nuvem",
    "creative": "Criação e produtividade",
    "administration": "Administração",
    "education": "Educação",
}


def _sources(
    packages: dict[str, str] | None = None,
    flatpak: str = "",
) -> tuple[SourceSpec, ...]:
    values = [
        SourceSpec("package", name, (family,))
        for family, name in (packages or {}).items() if name
    ]
    if flatpak:
        values.append(SourceSpec("flatpak", flatpak, remote="flathub"))
    return tuple(values)


def _c(
    capability_id: str,
    title: str,
    description: str,
    group: str,
    *,
    packages: dict[str, str] | None = None,
    flatpak: str = "",
    requires: tuple[str, ...] = (),
    conflicts: tuple[str, ...] = (),
    gpu: tuple[str, ...] = (),
    desktops: tuple[str, ...] = (),
    reboot: str = "no",
    risk: str = "normal",
    immutable: str = "supported",
    license: str = "upstream",
    keywords: tuple[str, ...] = (),
    mode: str = "",
) -> CapabilitySpec:
    return CapabilitySpec(
        id=capability_id,
        title=title,
        description=description,
        group=group,
        sources=_sources(packages, flatpak),
        compatibility=Compatibility(
            gpu=gpu, desktops=desktops, immutable=immutable,
        ),
        requires=requires,
        conflicts=conflicts,
        reboot=reboot,
        risk=risk,
        license=license,
        keywords=keywords,
        mode=mode,
    )


CAPABILITIES: tuple[CapabilitySpec, ...] = (
    # Gaming and streaming
    _c("gaming.gamescope", "Gamescope", "Microcompositor para sessões e jogos.", "gaming", packages={"arch": "gamescope", "debian": "gamescope", "fedora": "gamescope", "suse": "gamescope"}),
    _c("gaming.gamemode", "GameMode", "Perfis temporários de desempenho por jogo.", "gaming", packages={"arch": "gamemode", "debian": "gamemode", "fedora": "gamemode", "suse": "gamemode"}),
    _c("gaming.mangohud", "MangoHud", "Overlay local de desempenho e frame pacing.", "gaming", packages={"arch": "mangohud", "debian": "mangohud", "fedora": "mangohud", "suse": "MangoHud"}),
    _c("gaming.goverlay", "GOverlay", "Interface para MangoHud e ferramentas Vulkan.", "gaming", packages={"arch": "goverlay", "debian": "goverlay", "fedora": "goverlay"}, flatpak="io.github.benjamimgois.goverlay", requires=("gaming.mangohud",)),
    _c("gaming.gpu-recorder", "GPU Screen Recorder", "Gravação eficiente de jogos e desktop.", "gaming", flatpak="com.dec05eba.gpu_screen_recorder", gpu=("amd", "intel", "nvidia")),
    _c("gaming.sunshine", "Sunshine", "Servidor local para streaming de jogos.", "gaming", flatpak="dev.lizardbyte.app.Sunshine"),
    _c("gaming.moonlight", "Moonlight", "Cliente de streaming GameStream/Sunshine.", "gaming", packages={"arch": "moonlight-qt", "debian": "moonlight-qt"}, flatpak="com.moonlight_stream.Moonlight"),
    _c("gaming.wivrn", "WiVRn", "Streaming OpenXR para headsets VR.", "gaming", flatpak="io.github.wivrn.wivrn", reboot="recommended"),
    _c("gaming.protonplus", "ProtonPlus", "Gerencia versões Proton/Wine-GE.", "gaming", flatpak="com.vysp3r.ProtonPlus"),
    _c("gaming.protontricks", "Protontricks", "Gerencia componentes Winetricks por prefixo Steam.", "gaming", packages={"arch": "protontricks", "debian": "protontricks", "fedora": "protontricks"}, flatpak="com.github.Matoking.protontricks"),
    _c("gaming.bottles", "Bottles", "Prefixos Wine isolados e reproduzíveis.", "gaming", flatpak="com.usebottles.bottles"),
    _c("gaming.prism", "Prism Launcher", "Launcher livre para Minecraft Java.", "gaming", packages={"arch": "prismlauncher", "debian": "prismlauncher", "fedora": "prismlauncher"}, flatpak="org.prismlauncher.PrismLauncher"),
    _c("gaming.lutris", "Lutris", "Biblioteca e launchers para jogos Linux/Wine.", "gaming", packages={"arch": "lutris", "debian": "lutris", "fedora": "lutris", "suse": "lutris"}, flatpak="net.lutris.Lutris"),
    _c("gaming.heroic", "Heroic Games Launcher", "Bibliotecas Epic, GOG e Amazon.", "gaming", flatpak="com.heroicgameslauncher.hgl"),
    _c("gaming.steam", "Steam", "Cliente Steam e Gamepad UI.", "gaming", packages={"arch": "steam", "debian": "steam-installer", "fedora": "steam"}, flatpak="com.valvesoftware.Steam"),

    # Hardware and driver-facing utilities. Kernel drivers stay explicit/high-risk.
    _c("hardware.openrgb", "OpenRGB", "Controle unificado de iluminação RGB.", "hardware", packages={"arch": "openrgb", "debian": "openrgb", "fedora": "openrgb"}, flatpak="org.openrgb.OpenRGB", risk="elevated"),
    _c("hardware.piper", "Piper", "Configuração de mouses compatíveis com libratbag.", "hardware", packages={"arch": "piper", "debian": "piper", "fedora": "piper", "suse": "piper"}, flatpak="org.freedesktop.Piper"),
    _c("hardware.solaar", "Solaar", "Gerenciamento de dispositivos Logitech Unifying/Bolt.", "hardware", packages={"arch": "solaar", "debian": "solaar", "fedora": "solaar", "suse": "solaar"}, flatpak="io.github.pwr_solaar.solaar"),
    _c("hardware.input-remapper", "Input Remapper", "Remapeamento de teclado, mouse e controles.", "hardware", packages={"debian": "input-remapper", "fedora": "input-remapper"}, risk="elevated", reboot="recommended"),
    _c("hardware.oversteer", "Oversteer", "Configuração de volantes no Linux.", "hardware", packages={"arch": "oversteer", "debian": "oversteer", "fedora": "oversteer"}, flatpak="io.github.berarma.Oversteer"),
    _c("hardware.lact", "LACT", "Controle e telemetria de GPU AMD/Intel/NVIDIA.", "hardware", packages={"arch": "lact", "fedora": "lact"}, flatpak="io.github.ilya_zlobintsev.LACT", gpu=("amd", "intel", "nvidia"), risk="elevated"),
    _c("hardware.cpu-x", "CPU-X", "Informações detalhadas de CPU, placa e memória.", "hardware", packages={"arch": "cpu-x", "debian": "cpu-x", "fedora": "cpu-x", "suse": "CPU-X"}, flatpak="io.github.thetumultuousunicornofdarkness.cpu-x"),
    _c("hardware.qdiskinfo", "QDiskInfo", "Saúde SMART e informações de armazenamento.", "hardware", packages={"arch": "qdiskinfo", "debian": "qdiskinfo", "fedora": "qdiskinfo"}, flatpak="io.github.rokups.QDiskInfo"),
    _c("hardware.f3", "F3", "Detecta capacidade falsa em cartões e pendrives.", "hardware", packages={"arch": "f3", "debian": "f3", "fedora": "f3", "suse": "f3"}),
    _c("hardware.xpadneo", "Xpadneo", "Driver Bluetooth avançado para controles Xbox.", "hardware", packages={"debian": "xpadneo-dkms", "fedora": "xpadneo"}, risk="high", reboot="required", immutable="blocked"),
    _c("hardware.rocm", "ROCm", "Runtime de computação AMD.", "hardware", packages={"arch": "rocm-core", "debian": "rocm", "fedora": "rocm-runtime"}, gpu=("amd",), risk="elevated", reboot="recommended", immutable="layered"),
    _c("hardware.intel-compute", "Intel Compute Runtime", "OpenCL e Level Zero para GPUs Intel.", "hardware", packages={"arch": "intel-compute-runtime", "debian": "intel-opencl-icd", "fedora": "intel-compute-runtime"}, gpu=("intel",), reboot="recommended"),

    # Health and security foundations
    _c("health.zram", "ZRAM Generator", "Swap comprimido gerenciado por systemd.", "health", packages={"arch": "zram-generator", "debian": "systemd-zram-generator", "fedora": "zram-generator", "suse": "systemd-zram-service"}, risk="elevated", reboot="recommended", immutable="layered"),
    _c("health.earlyoom", "EarlyOOM", "Proteção contra congelamentos por falta de memória.", "health", packages={"arch": "earlyoom", "debian": "earlyoom", "fedora": "earlyoom", "suse": "earlyoom"}, risk="elevated"),
    _c("health.ananicy", "Ananicy Cpp", "Prioridades automáticas por aplicação.", "health", packages={"arch": "ananicy-cpp", "debian": "ananicy-cpp", "fedora": "ananicy-cpp"}, risk="elevated"),
    _c("health.btrfs-assistant", "Btrfs Assistant", "Snapshots, scrub e manutenção Btrfs.", "health", packages={"arch": "btrfs-assistant", "debian": "btrfs-assistant", "fedora": "btrfs-assistant"}),
    _c("health.iwd", "iNet Wireless Daemon", "Backend Wi-Fi moderno e enxuto.", "health", packages={"arch": "iwd", "debian": "iwd", "fedora": "iwd", "suse": "iwd"}, risk="high", reboot="recommended", conflicts=("health.wpa-supplicant",)),
    _c("health.wpa-supplicant", "wpa_supplicant", "Backend Wi-Fi compatível com NetworkManager.", "health", packages={"arch": "wpa_supplicant", "debian": "wpasupplicant", "fedora": "wpa_supplicant", "suse": "wpa_supplicant"}, risk="high", reboot="recommended", conflicts=("health.iwd",)),
    _c("security.apparmor", "AppArmor", "Confinamento por perfis de aplicação.", "security", packages={"arch": "apparmor", "debian": "apparmor", "fedora": "apparmor", "suse": "apparmor-parser"}, risk="elevated", reboot="recommended", immutable="layered"),
    _c("security.ufw", "UFW", "Firewall local com política simples.", "security", packages={"arch": "ufw", "debian": "ufw", "fedora": "ufw", "suse": "ufw"}, risk="high"),
    _c("security.flatseal", "Flatseal", "Auditoria e edição de permissões Flatpak.", "security", flatpak="com.github.tchx84.Flatseal"),
    _c("security.bitwarden", "Bitwarden", "Cofre de senhas multiplataforma.", "security", flatpak="com.bitwarden.desktop"),
    _c("security.keepassxc", "KeePassXC", "Cofre local KeePass com integração desktop.", "security", packages={"arch": "keepassxc", "debian": "keepassxc", "fedora": "keepassxc", "suse": "keepassxc"}, flatpak="org.keepassxc.KeePassXC"),
    _c("security.cryptomator", "Cryptomator", "Criptografia de arquivos para nuvem.", "security", flatpak="org.cryptomator.Cryptomator"),
    _c("security.wireguard", "WireGuard", "VPN moderna integrada ao kernel.", "security", packages={"arch": "wireguard-tools", "debian": "wireguard-tools", "fedora": "wireguard-tools", "suse": "wireguard-tools"}, risk="elevated"),
    _c("security.librewolf", "LibreWolf", "Firefox com defaults de privacidade.", "security", flatpak="io.gitlab.librewolf-community"),
    _c("security.brave", "Brave", "Navegador Chromium com bloqueios integrados.", "security", flatpak="com.brave.Browser"),

    # Backup/cloud
    _c("backup.pika", "Pika Backup", "Backups Borg simples e agendáveis.", "backup", flatpak="org.gnome.World.PikaBackup"),
    _c("backup.rclone", "Rclone", "Sincronização com provedores de nuvem.", "backup", packages={"arch": "rclone", "debian": "rclone", "fedora": "rclone", "suse": "rclone"}),
    _c("backup.sirikali", "SiriKali", "Interface para volumes criptografados.", "backup", packages={"arch": "sirikali", "debian": "sirikali", "fedora": "sirikali", "suse": "sirikali"}, flatpak="io.github.mhogomchungu.sirikali"),

    # Development
    _c("development.docker", "Docker", "Engine e CLI para containers.", "development", packages={"arch": "docker", "debian": "docker.io", "fedora": "moby-engine", "suse": "docker"}, risk="elevated", reboot="recommended", immutable="layered"),
    _c("development.docker-compose", "Docker Compose", "Orquestração multi-container (plugin compose).", "development", packages={"arch": "docker-compose", "debian": "docker-compose-plugin", "fedora": "docker-compose-plugin", "suse": "docker-compose"}, requires=("development.docker",), risk="elevated", immutable="layered"),
    _c("development.virt-manager", "Virt-Manager", "Gerenciamento gráfico de libvirt/QEMU.", "development", packages={"arch": "virt-manager", "debian": "virt-manager", "fedora": "virt-manager", "suse": "virt-manager"}),
    _c("development.kind", "Kind", "Clusters Kubernetes locais em containers.", "development", packages={"arch": "kind", "debian": "kind", "fedora": "kind"}, requires=("development.docker",)),
    _c("development.nodejs", "Node.js", "Runtime JavaScript para projetos web e ferramentas de desenvolvimento.", "development", packages={"arch": "nodejs", "debian": "nodejs", "fedora": "nodejs", "suse": "nodejs"}, keywords=("javascript", "typescript", "web", "js", "ts")),
    _c("development.rust", "Rust", "Compilador rustc e gerenciador Cargo para projetos Rust.", "development", packages={"arch": "rust", "debian": "cargo", "fedora": "cargo", "suse": "rust"}, keywords=("rustc", "cargo", "rust-lang")),
    _c("development.cpp", "Compilador C/C++", "Toolchain GCC para compilar projetos C e C++.", "development", packages={"arch": "gcc", "debian": "g++", "fedora": "gcc-c++", "suse": "gcc-c++"}, keywords=("c", "c++", "cpp", "gcc", "g++")),
    _c("development.dotnet", ".NET SDK", "SDK moderno da plataforma .NET.", "development", packages={"arch": "dotnet-sdk", "debian": "dotnet-sdk-8.0", "fedora": "dotnet-sdk-8.0", "suse": "dotnet-sdk-8.0"}),
    _c("development.jdk", "OpenJDK", "JDK livre para Java e ferramentas JVM.", "development", packages={"arch": "jdk-openjdk", "debian": "default-jdk", "fedora": "java-latest-openjdk-devel", "suse": "java-devel"}),
    _c("development.maven", "Maven", "Build e dependências Java.", "development", packages={"arch": "maven", "debian": "maven", "fedora": "maven", "suse": "maven"}, requires=("development.jdk",)),
    _c("development.mise", "Mise", "Gerenciador de runtimes e ferramentas por projeto.", "development", packages={"arch": "mise", "fedora": "mise"}),
    _c("development.pyenv", "Pyenv", "Versões isoladas do Python.", "development", packages={"arch": "pyenv", "debian": "pyenv", "fedora": "pyenv"}),
    _c("development.pnpm", "pnpm", "Gerenciador eficiente de pacotes Node.", "development", packages={"arch": "pnpm", "debian": "node-pnpm", "fedora": "pnpm"}, requires=("development.nodejs",)),
    _c("development.k6", "k6", "Testes de carga reproduzíveis.", "development", packages={"debian": "k6", "fedora": "k6"}),
    _c("development.httpie", "HTTPie", "Cliente HTTP amigável para terminal.", "development", packages={"arch": "httpie", "debian": "httpie", "fedora": "httpie", "suse": "httpie"}),
    _c("development.postman", "Postman", "Cliente e coleções de APIs.", "development", flatpak="com.getpostman.Postman"),
    _c("development.neovim", "Neovim", "Editor modal extensível.", "development", packages={"arch": "neovim", "debian": "neovim", "fedora": "neovim", "suse": "neovim"}),
    _c("development.vscode", "Visual Studio Code", "IDE generalista com extensões.", "development", flatpak="com.visualstudio.code"),
    _c("development.vscodium", "VSCodium", "Build comunitário do VS Code.", "development", flatpak="com.vscodium.codium"),
    _c("development.godot", "Godot Engine", "Engine livre para jogos 2D/3D.", "development", packages={"arch": "godot", "debian": "godot3", "fedora": "godot"}, flatpak="org.godotengine.Godot"),

    # Creative/productivity
    _c("creative.blender", "Blender", "Modelagem, animação e renderização 3D.", "creative", flatpak="org.blender.Blender"),
    _c("creative.gimp", "GIMP", "Edição de imagens raster.", "creative", packages={"arch": "gimp", "debian": "gimp", "fedora": "gimp", "suse": "gimp"}, flatpak="org.gimp.GIMP"),
    _c("creative.krita", "Krita", "Pintura digital e ilustração.", "creative", packages={"arch": "krita", "debian": "krita", "fedora": "krita", "suse": "krita"}, flatpak="org.kde.krita"),
    _c("creative.kdenlive", "Kdenlive", "Edição de vídeo não linear.", "creative", packages={"arch": "kdenlive", "debian": "kdenlive", "fedora": "kdenlive", "suse": "kdenlive"}, flatpak="org.kde.kdenlive"),
    _c("creative.inkscape", "Inkscape", "Ilustração vetorial SVG.", "creative", packages={"arch": "inkscape", "debian": "inkscape", "fedora": "inkscape", "suse": "inkscape"}, flatpak="org.inkscape.Inkscape"),
    _c("creative.freecad", "FreeCAD", "CAD paramétrico e engenharia.", "creative", packages={"arch": "freecad", "debian": "freecad", "fedora": "freecad", "suse": "FreeCAD"}, flatpak="org.freecad.FreeCAD"),
    _c("creative.kicad", "KiCad", "Projeto eletrônico e PCB.", "creative", packages={"arch": "kicad", "debian": "kicad", "fedora": "kicad", "suse": "kicad"}, flatpak="org.kicad.KiCad"),
    _c("creative.audacity", "Audacity", "Edição e gravação de áudio.", "creative", packages={"arch": "audacity", "debian": "audacity", "fedora": "audacity", "suse": "audacity"}, flatpak="org.audacityteam.Audacity"),
    _c("creative.darktable", "Darktable", "Fluxo RAW para fotografia.", "creative", packages={"arch": "darktable", "debian": "darktable", "fedora": "darktable", "suse": "darktable"}, flatpak="org.darktable.Darktable"),
    _c("creative.libreoffice", "LibreOffice", "Suíte de escritório livre.", "creative", packages={"arch": "libreoffice-fresh", "debian": "libreoffice", "fedora": "libreoffice", "suse": "libreoffice"}, flatpak="org.libreoffice.LibreOffice"),
    _c("creative.obsidian", "Obsidian", "Notas e conhecimento em Markdown.", "creative", flatpak="md.obsidian.Obsidian"),

    # Administration
    _c("administration.cockpit", "Cockpit", "Administração web do host.", "administration", packages={"arch": "cockpit", "debian": "cockpit", "fedora": "cockpit", "suse": "cockpit"}, risk="elevated"),
    _c("administration.tailscale", "Tailscale", "Rede mesh WireGuard gerenciada.", "administration", packages={"arch": "tailscale", "debian": "tailscale", "fedora": "tailscale", "suse": "tailscale"}, risk="elevated"),
    _c("administration.zerotier", "ZeroTier", "Rede virtual peer-to-peer.", "administration", packages={"arch": "zerotier-one", "debian": "zerotier-one", "fedora": "zerotier-one", "suse": "zerotier-one"}, risk="elevated"),
    _c("administration.topgrade", "Topgrade", "Orquestra atualizações de múltiplos ecossistemas.", "administration", packages={"arch": "topgrade", "debian": "topgrade", "fedora": "topgrade"}, risk="elevated"),

    # Education
    _c("education.gcompris", "GCompris", "Atividades educacionais para crianças.", "education", packages={"arch": "gcompris-qt", "debian": "gcompris-qt", "fedora": "gcompris-qt", "suse": "gcompris-qt"}, flatpak="org.kde.gcompris"),
    _c("education.stellarium", "Stellarium", "Planetário 3D e astronomia.", "education", packages={"arch": "stellarium", "debian": "stellarium", "fedora": "stellarium", "suse": "stellarium"}, flatpak="org.stellarium.Stellarium"),
    _c("education.kalzium", "Kalzium", "Tabela periódica e química.", "education", packages={"arch": "kalzium", "debian": "kalzium", "fedora": "kalzium", "suse": "kalzium"}, flatpak="org.kde.kalzium"),
    _c("education.kolibri", "Kolibri", "Plataforma educacional offline.", "education", packages={"debian": "kolibri", "fedora": "kolibri"}, flatpak="org.learningequality.Kolibri"),
)


BY_ID = {capability.id: capability for capability in CAPABILITIES}

PROFILES: dict[str, tuple[str, ...]] = {
    "development-web-js": ("development.nodejs", "development.pnpm"),
    "development-python": ("development.pyenv",),
    "development-rust": ("development.rust",),
    "development-c-cpp": ("development.cpp",),
    "development-java": ("development.maven",),
    "development-dotnet": ("development.dotnet",),
    "gaming-core": ("gaming.gamescope", "gaming.gamemode", "gaming.mangohud", "gaming.goverlay", "gaming.protonplus", "gaming.protontricks"),
    "game-streaming": ("gaming.sunshine", "gaming.moonlight", "gaming.gpu-recorder"),
    "hardware-tools": ("hardware.openrgb", "hardware.piper", "hardware.solaar", "hardware.lact", "hardware.cpu-x", "hardware.qdiskinfo", "hardware.f3"),
    "system-health": ("health.zram", "health.earlyoom", "health.ananicy", "health.btrfs-assistant"),
    "developer": ("development.docker", "development.virt-manager", "development.dotnet", "development.jdk", "development.maven", "development.httpie", "development.neovim", "development.vscode"),
    "security": ("security.apparmor", "security.ufw", "security.flatseal", "security.bitwarden", "security.keepassxc", "security.cryptomator", "security.wireguard"),
    "backup": ("backup.pika", "backup.rclone", "backup.sirikali"),
    "creative": tuple(capability.id for capability in CAPABILITIES if capability.group == "creative"),
    "administration": tuple(capability.id for capability in CAPABILITIES if capability.group == "administration"),
    "education": tuple(capability.id for capability in CAPABILITIES if capability.group == "education"),
}
PROFILES["full-workstation"] = tuple(
    dict.fromkeys(
        capability_id
        for profile in ("gaming-core", "hardware-tools", "system-health", "developer", "security", "backup", "creative", "administration")
        for capability_id in PROFILES[profile]
    )
)


# Perfis com curadoria manual. Os perfis que apenas espelham um grupo inteiro
# ("creative", "administration", "education", "full-workstation") ficam de fora:
# pertencer a eles não é recomendação, é só existir no catálogo.
CURATED_PROFILES = (
    "development-web-js", "development-python", "development-rust",
    "development-c-cpp", "development-java",
    "development-dotnet",
    "gaming-core", "game-streaming", "hardware-tools",
    "system-health", "developer", "security", "backup",
)

RECOMMENDED_IDS = frozenset(
    capability_id
    for profile in CURATED_PROFILES
    for capability_id in PROFILES[profile]
)


def mode_for(capability: CapabilitySpec) -> str:
    """recommended | opt-in | advanced — como a UI deve apresentar o item.

    Derivado de dados que já existem (risco, reboot, perfis curados) em vez de
    uma lista paralela que envelheceria em silêncio. `spec.mode` sobrepõe.
    """
    if capability.mode:
        return capability.mode
    if capability.risk in {"elevated", "high"} or capability.reboot == "required":
        return "advanced"
    if capability.id in RECOMMENDED_IDS:
        return "recommended"
    return "opt-in"


# Como cada mecanismo é desfeito, para a UI exibir o selo certo.
ROLLBACK_LABELS = {
    "package-remove": "Remoção pelo gerenciador de pacotes",
    "flatpak-uninstall": "Desinstalação do Flatpak",
    "service-disable": "Desativação do serviço systemd",
}


def rollback_kinds(
    capability: CapabilitySpec,
    source: SourceSpec | None,
    *,
    has_recipe: bool = False,
) -> tuple[str, ...]:
    """Mecanismos que o motor sabe reverter para esta capability.

    Reflete o que `rollback_operation` de fato executa. Se a lista vier vazia,
    não há reversão automática — e a UI precisa dizer isso, não presumir.
    """
    kinds: list[str] = []
    if has_recipe:
        kinds.append("service-disable")
    if source is not None:
        kinds.append("flatpak-uninstall" if source.kind == "flatpak" else "package-remove")
    return tuple(kinds)


def validate_catalog() -> None:
    if len(BY_ID) != len(CAPABILITIES):
        raise ValueError("IDs duplicados no catálogo de capabilities")
    for capability in CAPABILITIES:
        capability.validate()
        for dependency in capability.requires:
            if dependency not in BY_ID:
                raise ValueError(f"dependência desconhecida: {capability.id} -> {dependency}")


def compatibility(capability: CapabilitySpec, facts: HostFacts) -> tuple[bool, str]:
    rule = capability.compatibility
    if facts.platform != "linux":
        return False, "disponível somente no Linux"
    if facts.container and rule.container == "blocked":
        return False, "bloqueado dentro de container"
    if rule.distros and facts.distro not in rule.distros and not set(rule.distros).intersection(facts.distro_like):
        return False, f"requer distribuição: {', '.join(rule.distros)}"
    if facts.immutable and rule.immutable == "blocked":
        return False, "não suportado em sistema imutável"
    if rule.gpu and not set(rule.gpu).intersection(facts.gpus):
        return False, "hardware GPU incompatível ou não detectado"
    if rule.desktops and facts.desktop not in rule.desktops:
        return False, f"requer desktop: {', '.join(rule.desktops)}"
    if rule.sessions and facts.session not in rule.sessions:
        return False, f"requer sessão: {', '.join(rule.sessions)}"
    if rule.init and facts.init not in rule.init:
        return False, f"requer init: {', '.join(rule.init)}"
    return True, ""


def sources_for(capability: CapabilitySpec, facts: HostFacts) -> tuple[SourceSpec, ...]:
    # Native signed repository first; Flatpak is portable fallback.
    native = tuple(
        source for source in capability.sources
        if source.kind == "package" and facts.package_family in source.distros
    )
    flatpak = tuple(
        source for source in capability.sources
        if source.kind == "flatpak" and facts.flatpak and facts.flathub
    )
    return (*native, *flatpak)


def source_for(capability: CapabilitySpec, facts: HostFacts) -> SourceSpec | None:
    candidates = sources_for(capability, facts)
    return candidates[0] if candidates else None


validate_catalog()
