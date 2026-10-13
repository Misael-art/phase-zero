"""Catálogo avaliado do motor de temas.

Fontes de verdade:
- Features e perfis: declarados aqui (chaves KDE documentadas).
- Wallpapers PhaseZero: `assets/themes/wallpapers/manifest.json` com licença e
  SHA-256 (nunca catálogo sem checksum).
- Extensões KDE Store: itens incluídos, adiados e recusados permanecem listados
  com motivo — nada some silenciosamente.
- Plugins Steam Gaming Mode: metadados declarados; artefato fixado só quando
  verificado (`verified=true` com versão/commit e SHA-256).
"""

from __future__ import annotations

import json
from pathlib import Path

from .models import ExtensionSpec, FeatureSpec, ProfileSpec, SteamPluginSpec, WallpaperSpec

PZ_ROOT = Path(__file__).resolve().parents[2]

FEATURES: dict[str, FeatureSpec] = {
    # --- Aparência -----------------------------------------------------
    "theme.phasezero": FeatureSpec(
        id="theme.phasezero",
        title="Tema PhaseZero",
        description=(
            "Tema interno PhaseZero: Sistema, Escuro, Claro e Alto contraste. "
            "Persistência em interface/theme; o botão da barra superior usa a mesma fonte de verdade."
        ),
        section="aparência",
        kind="kde-config",
        params=("mode",),
        # dark/light/highcontrast apply a colourscheme and a look-and-feel,
        # which rewrite the same files theme.kde declares; snapshotting only
        # theme.conf left every other disturbed file outside rollback reach.
        config_keys=(
            "phasezero/theme.conf:[interface]/theme",
            "kdeglobals:[KDE]/LookAndFeelPackage",
            "kdeglobals:[General]/ColorScheme",
            "plasmarc:[Theme]/name",
            "kcminputrc:[Mouse]/cursorTheme",
            "kwinrc:[Effect-blur]/BlurStrength",
            "ksplashrc:[KSplash]/Theme",
            "gtkrc:[Settings]/gtk-theme-name",
            "gtkrc-2.0:[Settings]/gtk-theme-name",
            "Trolltech.conf:[Qt]/style",
        ),
        default_state="desligado",
        default_params={"mode": "system"},
    ),
    "theme.kde": FeatureSpec(
        id="theme.kde",
        title="Tema KDE global",
        description="Tema global (Look and Feel) do Plasma.",
        section="aparência",
        kind="kde-config",
        params=("package",),
        # The snapshot scope is derived from these entries, so they have to name
        # every file the apply can disturb, not just the one that identifies the
        # setting. plasma-apply-lookandfeel rewrites all of these in one go;
        # declaring only plasmarc meant a failed apply restored that single file
        # and left the rest - including the look-and-feel id itself and the
        # colour scheme - as the half-applied theme had left them.
        config_keys=(
            "kdeglobals:[KDE]/LookAndFeelPackage",
            "plasmarc:[Theme]/name",
            "kcminputrc:[Mouse]/cursorTheme",
            "kwinrc:[Effect-blur]/BlurStrength",
            "ksplashrc:[KSplash]/Theme",
            "gtkrc:[Settings]/gtk-theme-name",
            "gtkrc-2.0:[Settings]/gtk-theme-name",
            "Trolltech.conf:[Qt]/style",
        ),
        default_params={"package": "org.kde.breeze.desktop"},
    ),
    "theme.colorscheme": FeatureSpec(
        id="theme.colorscheme",
        title="Esquema de cores",
        description="Esquema de cores do Plasma (kdeglobals [General] ColorScheme).",
        section="aparência",
        kind="kde-config",
        params=("name",),
        config_keys=("kdeglobals:[General]/ColorScheme",),
        default_params={"name": "BreezeLight"},
    ),
    "theme.icons": FeatureSpec(
        id="theme.icons",
        title="Ícones",
        description="Tema de ícones do desktop (kdeglobals [Icons] Theme).",
        section="aparência",
        kind="kde-config",
        params=("name",),
        config_keys=("kdeglobals:[Icons]/Theme",),
        default_params={"name": "breeze"},
    ),
    "theme.cursor": FeatureSpec(
        id="theme.cursor",
        title="Cursor",
        description="Tema e tamanho do cursor (kcminputrc [Mouse]).",
        section="aparência",
        kind="kde-config",
        params=("name", "size"),
        config_keys=("kcminputrc:[Mouse]/cursorTheme", "kcminputrc:[Mouse]/cursorSize"),
        default_params={"name": "breeze_cursors", "size": 24},
    ),
    "theme.accent": FeatureSpec(
        id="theme.accent",
        title="Cor de destaque",
        description=(
            "Cor de destaque derivada do wallpaper (modo auto, exige leitura da imagem) "
            "ou cor explícita (modo color). Persiste em kdeglobals [General] AccentColor."
        ),
        section="aparência",
        kind="kde-config",
        params=("mode", "color"),
        config_keys=(
            "kdeglobals:[General]/AccentColor",
            "phasezero/theme.conf:[accent]/color",
        ),
        default_params={"mode": "auto", "color": ""},
    ),
    "theme.auto-dark": FeatureSpec(
        id="theme.auto-dark",
        title="Claro/escuro automático",
        description=(
            "Segue a alternância automática do Plasma (requer Plasma 6.1+). "
            "Chave declarada conforme documentação do KDE (kdeglobals [KDE] ColorScheme)."
        ),
        section="aparência",
        kind="kde-config",
        params=("darkScheme",),
        # Plasma reads the active scheme from [General]; the [KDE] group was
        # written and verified by this feature but consulted by nothing.
        config_keys=("kdeglobals:[General]/ColorScheme",),
        key_verified=False,
        default_params={"darkScheme": "BreezeDark"},
    ),
    "theme.night-color": FeatureSpec(
        id="theme.night-color",
        title="Night Color",
        description="Filtro de luz noturna do KWin (kwinrc [NightColor]).",
        section="aparência",
        kind="kde-config",
        params=("temperature",),
        config_keys=("kwinrc:[NightColor]/Active", "kwinrc:[NightColor]/Mode", "kwinrc:[NightColor]/TemperatureNight"),
        default_params={"temperature": 3500},
    ),
    # --- Acessibilidade -------------------------------------------------
    "access.text-size": FeatureSpec(
        id="access.text-size",
        title="Texto maior",
        description="Escala a fonte do desktop via forceFontDPI (96 DPI = 100%).",
        section="acessibilidade",
        kind="kde-config",
        params=("percent",),
        config_keys=("kdeglobals:[General]/forceFontDPI",),
        default_params={"percent": 100},
    ),
    "access.reduce-motion": FeatureSpec(
        id="access.reduce-motion",
        title="Movimento reduzido",
        description="Reduz animações do KWin e do Plasma (kwinrc ReduceMotion + AnimationDurationFactor).",
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kwinrc:[KWin]/ReduceMotion", "kdeglobals:[KDE]/AnimationDurationFactor"),
        default_state="desligado",
    ),
    "access.locate-cursor": FeatureSpec(
        id="access.locate-cursor",
        title="Localizar cursor",
        description=(
            "Destaque visual da posição do cursor (chave KWin declarada; segurança garantida "
            "por snapshot e rollback byte a byte)."
        ),
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kwinrc:[KWin]/CursorSearchEnabled",),
        key_verified=False,
    ),
    "access.zoom": FeatureSpec(
        id="access.zoom",
        title="Zoom",
        description=(
            "Efeito de zoom do KWin (kwinrc [Effect-zoom]). O efeito builtin "
            "já vem carregado; a ativação no dia a dia é pelo atalho de teclado."
        ),
        section="acessibilidade",
        kind="kde-config",
        key_verified=False,
        config_keys=("kwinrc:[Effect-zoom]/Enabled",),
    ),
    "access.colorblind": FeatureSpec(
        id="access.colorblind",
        title="Correção de daltonismo",
        description=(
            "Filtro de daltonismo do KWin (kwinrc [Effect-colorblind]). "
            "Exige o plugin do efeito instalado; sem ele o recurso é indisponível."
        ),
        section="acessibilidade",
        kind="kde-config",
        params=("type",),
        key_verified=False,
        config_keys=("kwinrc:[Effect-colorblind]/Enabled", "kwinrc:[Effect-colorblind]/Type"),
        default_params={"type": "deuteranopia"},
    ),
    "access.visual-alert": FeatureSpec(
        id="access.visual-alert",
        title="Alerta visual",
        description="Alerta visual no lugar do sino (kaccessrc [Bell] VisibleBell).",
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kaccessrc:[Bell]/VisibleBell",),
        key_verified=False,
    ),
    "access.screen-reader": FeatureSpec(
        id="access.screen-reader",
        title="Leitor de tela",
        description=(
            "Inicia o Orca (leitor de tela padrão KDE) como processo do usuário; "
            "rollback encerra somente o processo iniciado pelo PhaseZero."
        ),
        section="acessibilidade",
        kind="process",
        risk="elevated",
        requires=("access.text-size",),
    ),
    "access.sticky-keys": FeatureSpec(
        id="access.sticky-keys",
        title="Teclas aderentes",
        description="Teclas aderentes do daemon de acessibilidade KDE (kaccessrc [Keyboard]).",
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kaccessrc:[Keyboard]/StickyKeys",),
        key_verified=False,
        invasive=True,
    ),
    "access.slow-keys": FeatureSpec(
        id="access.slow-keys",
        title="Teclas lentas",
        description="Teclas lentas do daemon de acessibilidade KDE (kaccessrc [Keyboard]).",
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kaccessrc:[Keyboard]/SlowKeys",),
        key_verified=False,
        invasive=True,
    ),
    "access.bounce-keys": FeatureSpec(
        id="access.bounce-keys",
        title="Teclas de repercussão",
        description="Teclas de repercussão do daemon de acessibilidade KDE (kaccessrc [Keyboard]).",
        section="acessibilidade",
        kind="kde-config",
        config_keys=("kaccessrc:[Keyboard]/BounceKeys",),
        key_verified=False,
        invasive=True,
    ),
    # --- Vídeo -----------------------------------------------------------
    "video.wallpaper-engine": FeatureSpec(
        id="video.wallpaper-engine",
        title="Wallpaper Engine",
        description=(
            "Plugin nativo do Plasma (com.github.catsout.wallpaperEngineKde) para papéis de "
            "parede animados da Steam Workshop. Requer o pacote "
            "plasma6-wallpapers-wallpaper-engine-git e uma pasta de conteúdo já baixada; "
            "o PhaseZero não baixa nem contorna a assinatura da Steam."
        ),
        section="vídeo",
        kind="plasma-dbus",
        plasma_major=6,
        invasive=True,
        risk="elevated",
        params=("steamLibrary", "wallpaperId"),
        # A running animated wallpaper is a continuous GPU cost, so it is never
        # turned on implicitly; the containment is snapshotted byte-level like
        # any other wallpaper change.
        config_keys=("plasma-org.kde.plasma.desktop-appletsrc:[Containments]/wallpaperPlugin",),
        restart_required=False,
    ),
    "video.smart-wallpaper": FeatureSpec(
        id="video.smart-wallpaper",
        title="Vídeo de fundo",
        description=(
            "Smart Video Wallpaper Reborn como extensão opcional e fixada: áudio desligado, "
            "arquivos locais, pausas por bateria/jogo/fullscreen/VM/bloqueio/suspend e "
            "watchdog de crashes do Plasma."
        ),
        section="vídeo",
        kind="plasma-dbus",
        plasma_major=6,
        invasive=True,
        risk="elevated",
        params=("file",),
        requires=("wallpaper.image",),
        restart_required=True,
    ),
    # --- Energia adaptativa ---------------------------------------------
    "power.adaptive": FeatureSpec(
        id="power.adaptive",
        title="Energia adaptativa",
        description=(
            "Reduz animações e pausa vídeo de fundo na bateria; restaura na tomada. "
            "Estado reflete pausado-bateria/pausado-jogo."
        ),
        section="vídeo",
        kind="internal",
        # O apply grava estes dois arquivos; sem declará-los o snapshot sai
        # vazio e o rollback de um plano falho não devolve o
        # AnimationDurationFactor do usuário.
        config_keys=(
            "phasezero/theme.conf:[power]/adaptive",
            "kdeglobals:[KDE]/AnimationDurationFactor",
        ),
        default_state="desligado",
    ),
    # --- Wallpaper -------------------------------------------------------
    "wallpaper.image": FeatureSpec(
        id="wallpaper.image",
        title="Wallpaper estático",
        description="Imagem estática por monitor via API D-Bus do Plasma.",
        section="wallpaper",
        kind="plasma-dbus",
    ),
    "wallpaper.solid": FeatureSpec(
        id="wallpaper.solid",
        title="Cor sólida",
        description="Cor sólida por monitor via API D-Bus do Plasma.",
        section="wallpaper",
        kind="plasma-dbus",
    ),
    "wallpaper.slideshow": FeatureSpec(
        id="wallpaper.slideshow",
        title="Slideshow local",
        description="Slideshow de imagens locais com intervalo e ordem, por monitor.",
        section="wallpaper",
        kind="plasma-dbus",
        params=("dir", "interval"),
        default_params={"dir": "", "interval": 3600},
    ),
    "wallpaper.potd": FeatureSpec(
        id="wallpaper.potd",
        title="Picture of the Day",
        description="POTD opt-in com aviso de rede e cache com checksum.",
        section="wallpaper",
        kind="plasma-dbus",
        network=True,
        invasive=True,
    ),
}

PROFILES: dict[str, ProfileSpec] = {
    "essencial": ProfileSpec(
        id="essencial",
        title="Essencial",
        description=(
            "Segue o sistema, texto 110%, foco reforçado (localizar cursor), movimento "
            "reduzido e wallpaper estático. Nenhum recurso invasivo é ativado."
        ),
        audience="leigo",
        features={
            "theme.phasezero": {"state": "ligado", "params": {"mode": "system"}},
            "access.text-size": {"state": "ligado", "params": {"percent": 110}},
            "access.locate-cursor": {"state": "ligado"},
            "access.reduce-motion": {"state": "ligado"},
        },
        wallpaper={"kind": "static"},
    ),
    "steam-deck": ProfileSpec(
        id="steam-deck",
        title="Steam Deck",
        description=(
            "Escuro, texto 115%, controles maiores (cursor) e animações somente na tomada "
            "(energia adaptativa)."
        ),
        audience="steamdeck",
        features={
            "theme.phasezero": {"state": "ligado", "params": {"mode": "dark"}},
            "access.text-size": {"state": "ligado", "params": {"percent": 115}},
            "theme.cursor": {"state": "ligado", "params": {"name": "breeze_cursors", "size": 32}},
            "power.adaptive": {"state": "ligado"},
        },
        wallpaper={"kind": "static"},
    ),
    "gamer": ProfileSpec(
        id="gamer",
        title="Gamer",
        description=(
            "Escuro, efeitos reduzidos (blur e movimento) e animações pausadas durante jogos."
        ),
        audience="gamer",
        features={
            "theme.phasezero": {"state": "ligado", "params": {"mode": "dark"}},
            "access.reduce-motion": {"state": "ligado"},
            "power.pause-on-game": {"state": "ligado"},
        },
        wallpaper={"kind": "static"},
    ),
    "desenvolvedor": ProfileSpec(
        id="desenvolvedor",
        title="Desenvolvedor",
        description=(
            "Escuro, densidade normal e extensões avançadas opcionais (nunca ativadas por padrão)."
        ),
        audience="dev",
        features={
            "theme.phasezero": {"state": "ligado", "params": {"mode": "dark"}},
        },
        wallpaper={"kind": "static"},
    ),
}

# "power.pause-on-game" é derivado (não exposto como feature isolada); existe
# como alvo de perfil e é implementado pela energia adaptativa em modo jogo.
FEATURES["power.pause-on-game"] = FeatureSpec(
    id="power.pause-on-game",
    title="Pausa durante jogos",
    description="Pausa animações e vídeo de fundo quando o Steam Gaming Mode está ativo.",
    section="vídeo",
    kind="internal",
    config_keys=(
        "phasezero/theme.conf:[power]/pause-on-game",
        "kdeglobals:[KDE]/AnimationDurationFactor",
    ),
    default_state="desligado",
)

QUICK_ENVIRONMENTS: dict[str, dict] = {
    "foco": {
        "title": "Foco",
        "description": "Distrações mínimas: movimento reduzido, alerta visual e vídeo pausado.",
        "features": {
            "access.reduce-motion": {"state": "ligado"},
            "access.visual-alert": {"state": "ligado"},
            "video.smart-wallpaper": {"state": "desligado"},
        },
    },
    "relaxar": {
        "title": "Relaxar",
        "description": "Night Color quente e texto ligeiramente maior.",
        "features": {
            "theme.night-color": {"state": "ligado", "params": {"temperature": 3500}},
            "access.text-size": {"state": "ligado", "params": {"percent": 105}},
            "access.reduce-motion": {"state": "desligado"},
        },
    },
    "gamer": {
        "title": "Gamer",
        "description": "Perfil Gamer aplicado imediatamente.",
        "profile": "gamer",
    },
    "bateria-oled": {
        "title": "Bateria/OLED",
        "description": "Escuro + energia adaptativa para economizar OLED em bateria.",
        "features": {
            "theme.phasezero": {"state": "ligado", "params": {"mode": "dark"}},
            "power.adaptive": {"state": "ligado"},
        },
    },
}

KDE_EXTENSIONS: list[ExtensionSpec] = [
    ExtensionSpec(
        id="kde-2138035-temp-desktops",
        store_id="2138035",
        title="Temporary Virtual Desktops",
        plasma_major=6,
        status="included",
        reason="Extensão avançada Plasma 6; ativação opcional e nunca automática.",
        substitute="",
        license="GPL-2.0-or-later",
        risk="normal",
    ),
    ExtensionSpec(
        id="kde-2367756-ente-auth",
        store_id="2367756",
        title="krunner-ente-auth (TOTP/segredos)",
        plasma_major=6,
        status="deferred",
        reason="Guarda segredos TOTP; exige auditoria de armazenamento e revisão de segurança antes de integrar.",
        substitute="",
        risk="high",
    ),
]

_REJECTED_PLASMA5 = (
    ("2053791", "Loja de plugins (versão Plasma 5)"),
    ("2070431", "Loja de plugins (versão Plasma 5)"),
    ("2064339", "Loja de plugins (versão Plasma 5)"),
    ("1962359", "Loja de plugins (versão Plasma 5)"),
    ("1200511", "Loja de plugins (versão Plasma 5)"),
    ("1411968", "Loja de plugins (versão Plasma 5)"),
    ("2117968", "Loja de plugins (versão Plasma 5)"),
    ("2015475", "Loja de plugins (versão Plasma 5)"),
    ("2055225", "Loja de plugins (versão Plasma 5)"),
    ("1176348", "Loja de plugins (versão Plasma 5)"),
    ("1313987", "Loja de plugins (versão Plasma 5)"),
    ("1953779", "Loja de plugins (versão Plasma 5)"),
)

for _store_id, _label in _REJECTED_PLASMA5:
    KDE_EXTENSIONS.append(
        ExtensionSpec(
            id=f"kde-{_store_id}-rejected",
            store_id=_store_id,
            title=f"{_label} (#{_store_id})",
            plasma_major=5,
            status="rejected",
            reason="Versão listada requer Plasma 5; a plataforma-alvo do PhaseZero é Plasma 6.",
            substitute="equivalente nativo do Plasma 6 ainda não catalogado",
            risk="normal",
        )
    )

STEAM_PLUGINS: list[SteamPluginSpec] = [
    SteamPluginSpec(
        id="gamemode.css-loader",
        title="CSS Loader",
        decky_plugin="CSSLoader",
        license="MIT",
        source_url="https://github.com/suchmememanyskill/CSSLoader-Desktop",
        pinned_version="",
        verified=False,
        risk="normal",
    ),
    SteamPluginSpec(
        id="gamemode.animation-changer",
        title="Animation Changer",
        decky_plugin="AnimationChanger",
        license="MIT",
        source_url="https://github.com/suchmememanyskill/AnimationChanger",
        pinned_version="",
        verified=False,
        risk="normal",
    ),
    SteamPluginSpec(
        id="gamemode.audio-loader",
        title="Audio Loader",
        decky_plugin="AudioLoader",
        license="MIT",
        source_url="https://github.com/suchmememanyskill/AudioLoader",
        pinned_version="",
        verified=False,
        risk="normal",
    ),
    SteamPluginSpec(
        id="gamemode.steamgriddb",
        title="SteamGridDB",
        decky_plugin="SteamGridDB",
        license="",
        source_url="https://github.com/SteamGridDB/steamgriddb-decky",
        pinned_version="",
        verified=False,
        risk="normal",
    ),
]

_WALLPAPER_MANIFEST = PZ_ROOT / "assets" / "themes" / "wallpapers" / "manifest.json"


def load_wallpapers() -> list[WallpaperSpec]:
    """Carrega o catálogo de wallpapers do manifest (licença + SHA-256 obrigatórios)."""
    if not _WALLPAPER_MANIFEST.exists():
        return []
    try:
        payload = json.loads(_WALLPAPER_MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    items: list[WallpaperSpec] = []
    for entry in payload.get("wallpapers", ()):
        kind = str(entry.get("kind", "image"))
        if kind == "image" and (not entry.get("sha256") or not entry.get("license")):
            continue
        if kind != "image" and not entry.get("license"):
            continue
        items.append(
            WallpaperSpec(
                id=str(entry["id"]),
                title=str(entry.get("title", entry["id"])),
                kind=str(entry.get("kind", "image")),
                file=str(entry.get("file", "")),
                sha256=str(entry["sha256"]),
                license=str(entry["license"]),
                color=str(entry.get("color", "")),
                source=str(entry.get("source", "bundled")),
                network=bool(entry.get("network", False)),
            )
        )
    return items


def wallpaper_by_id(wallpaper_id: str) -> WallpaperSpec | None:
    for wallpaper in load_wallpapers():
        if wallpaper.id == wallpaper_id:
            return wallpaper
    return None


def feature_by_id(feature_id: str) -> FeatureSpec | None:
    return FEATURES.get(feature_id)


def profile_by_id(profile_id: str) -> ProfileSpec | None:
    return PROFILES.get(profile_id)
