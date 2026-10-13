"""Models versionados do motor de temas.

Dataclasses puras, sem lógica de I/O. A serialização pública usa os mesmos
nomes de campo em camelCase dos documentos `themes/v1`.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class FeatureSpec:
    """Uma capacidade configurável (aparência, acessibilidade, vídeo...)."""

    id: str
    title: str
    description: str
    section: str  # aparência | desktop | acessibilidade | wallpaper | vídeo | gamemode
    kind: str  # kde-config | plasma-dbus | file-managed | decky-plugin
    plasma_major: int = 6
    invasive: bool = False  # jamais liga em perfil padrão
    risk: str = "normal"  # normal | elevated | high
    requires: tuple[str, ...] = ()
    optional: bool = False
    network: bool = False
    params: tuple[str, ...] = ()
    config_keys: tuple[str, ...] = ()
    key_verified: bool = True  # False quando a chave oficial é declarada, não confirmada no código-fonte KDE
    default_state: str = "desligado"
    default_params: dict = field(default_factory=dict)
    restart_required: bool = False


@dataclass(frozen=True)
class ProfileSpec:
    """Perfil declarativo aplicado via botão `Aplicar`, nunca toggle."""

    id: str
    title: str
    description: str
    audience: str  # leigo | steamdeck | gamer | dev
    features: dict = field(default_factory=dict)  # feature_id -> {"state": ..., "params": {...}}
    wallpaper: dict = field(default_factory=dict)  # {"kind": "static", "param": ...}


@dataclass(frozen=True)
class WallpaperSpec:
    """Item do catálogo PhaseZero de wallpapers (licença + SHA-256)."""

    id: str
    title: str
    kind: str  # image | solid | slideshow | potd
    file: str = ""
    sha256: str = ""
    license: str = ""
    color: str = ""
    source: str = "bundled"
    network: bool = False


@dataclass(frozen=True)
class ExtensionSpec:
    """Item do catálogo avaliado de extensões KDE Store."""

    id: str
    store_id: str
    title: str
    plasma_major: int
    status: str  # included | deferred | rejected
    reason: str = ""
    substitute: str = ""
    license: str = ""
    source_url: str = ""
    sha256: str = ""
    risk: str = "normal"


@dataclass(frozen=True)
class SteamPluginSpec:
    """Extensão do Steam Gaming Mode (decky loader)."""

    id: str
    title: str
    decky_plugin: str  # nome em plugin.json do decky
    license: str = ""
    source_url: str = ""
    pinned_version: str = ""
    verified: bool = False
    risk: str = "normal"


@dataclass(frozen=True)
class WallpaperTarget:
    """Identidade de um monitor para operações de wallpaper."""

    screen: str
    target: str  # desktop | lock
