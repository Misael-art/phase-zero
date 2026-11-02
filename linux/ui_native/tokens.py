from __future__ import annotations

import re
from dataclasses import dataclass, replace
from pathlib import Path

STYLE_DIR = Path(__file__).resolve().parent
QSS_PATH = STYLE_DIR / "theme.qss"
_PLACEHOLDER_RE = re.compile(r"\{\{(\w+)\}\}")


@dataclass(frozen=True)
class ThemeTokens:
    """Single source of truth for all visual design values."""

    # Cores semânticas — backgrounds
    bg: str
    surface: str
    surface_alt: str
    surface_inset: str
    surface_header: str
    surface_input: str
    surface_hero: str
    surface_hero_alt: str
    surface_selected: str
    surface_pressed: str
    surface_disabled: str
    # Cores semânticas — borders
    border: str
    border_subtle: str
    border_divider: str
    border_strong: str
    accent_border: str
    # Texto
    text: str
    text_strong: str
    text_dim: str
    text_muted: str
    text_log: str
    # LUX-010: navegação lateral tem pares próprios (o hover/checked do tema
    # claro usava on_accent branco sobre lilás claro: 1.2:1).
    sidebar_active_text: str
    sidebar_hover_text: str
    section_label: str
    # Accent
    accent: str
    accent_hover: str
    accent_pressed: str
    on_accent: str
    # UX-011: anel de foco. Separado do accent porque precisa de 3:1 contra
    # a superfície do próprio controle (WCAG 1.4.11) sem clarear a marca —
    # clarear o accent derrubaria o texto branco sobre ele abaixo de 4.5.
    focus_ring: str
    # Estados (foreground, bg, border para cada)
    success: str
    success_bg: str
    success_border: str
    warning: str
    warning_bg: str
    warning_border: str
    error: str
    error_bg: str
    error_border: str
    info: str
    info_bg: str
    info_border: str
    # Danger button variants
    danger: str
    danger_hover: str
    danger_disabled_bg: str
    danger_disabled_border: str
    # Skeleton
    skeleton_base: str
    skeleton_shimmer: str
    # Log
    log_bg: str
    # Spacing escala (4px base)
    space_xs: int
    space_sm: int
    space_md: int
    space_lg: int
    space_xl: int
    # Tipografia
    font_ui: str
    font_mono: str
    text_xs: int
    text_sm: int
    text_base: int
    text_lg: int
    text_xl: int
    text_2xl: int
    # Raio
    radius_sm: int
    radius_md: int
    radius_lg: int
    # Shadow
    shadow_alpha: int
    # Transition
    transition: str


DARK = ThemeTokens(
    # backgrounds
    bg="#1e1e2e",
    surface="#2a2a3c",
    surface_alt="#32324a",
    surface_inset="#191926",
    surface_header="#232336",
    surface_input="#252536",
    surface_hero="#2d2747",
    surface_hero_alt="#352c55",
    surface_selected="#2b2444",
    surface_pressed="#2f2f40",
    surface_disabled="#262636",
    # borders
    border="#3a3a4c",
    border_subtle="#33334a",
    border_divider="#2e2e44",
    border_strong="#45455c",
    accent_border="#4a3d7a",
    # text
    text="#f2f2f7",
    text_strong="#f4f4fa",
    text_dim="#a0a0b0",
    text_muted="#6a6a82",
    text_log="#cfcfe0",
    sidebar_active_text="#ffffff",
    sidebar_hover_text="#ffffff",
    section_label="#a0a0b0",
    # accent
    accent="#7c4dff",
    accent_hover="#8f66ff",
    focus_ring="#a48cff",
    accent_pressed="#6a3ce6",
    on_accent="#ffffff",
    # states
    success="#7cb342",
    success_bg="#2c3a1f",
    success_border="#4d6b2c",
    warning="#ff9800",
    warning_bg="#3d2f16",
    warning_border="#7a5a20",
    error="#f26d6d",
    error_bg="#3d1f1f",
    error_border="#7a2e2e",
    info="#7c4dff",
    info_bg="#2c2547",
    info_border="#4a3d7a",
    # danger
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#2c2230",
    danger_disabled_border="#4a2f3a",
    # skeleton
    skeleton_base="#2e2e42",
    skeleton_shimmer="#3a3a52",
    # log
    log_bg="#15151f",
    # spacing
    space_xs=4,
    space_sm=8,
    space_md=12,
    space_lg=18,
    space_xl=24,
    # typography
    font_ui='"Inter", "Noto Sans", "Segoe UI", sans-serif',
    font_mono='"JetBrains Mono", "Cascadia Code", monospace',
    text_xs=11,
    text_sm=11,
    text_base=13,
    text_lg=15,
    text_xl=18,
    text_2xl=26,
    # radius
    radius_sm=8,
    radius_md=11,
    radius_lg=16,
    # shadow
    shadow_alpha=110,
    # transition
    transition="150ms ease",
)


LIGHT = ThemeTokens(
    # backgrounds
    bg="#f1f1f6",
    surface="#ffffff",
    surface_alt="#eeeef6",
    surface_inset="#e8e8f0",
    surface_header="#ffffff",
    surface_input="#ffffff",
    surface_hero="#ece7fb",
    surface_hero_alt="#e0d7f7",
    surface_selected="#ece7fb",
    surface_pressed="#e8e8f0",
    surface_disabled="#f4f4f8",
    # borders
    border="#d0d0dc",
    border_subtle="#e0e0ea",
    border_divider="#d8d8e2",
    border_strong="#c6c6d4",
    accent_border="#c9bdf0",
    # text
    text="#1c1c26",
    text_strong="#1a1a24",
    text_dim="#5a5a68",
    text_muted="#8a8a98",
    text_log="#2a2a36",
    sidebar_active_text="#1a1a24",
    sidebar_hover_text="#1a1a24",
    section_label="#5a5a68",
    # accent (brand kept identical)
    accent="#7c4dff",
    accent_hover="#9166ff",
    focus_ring="#6a3ae0",
    accent_pressed="#6a3ce6",
    on_accent="#ffffff",
    # states
    success="#2e7d32",
    success_bg="#e8f5e9",
    success_border="#a5d6a7",
    warning="#8a5000",
    warning_bg="#fff4e5",
    warning_border="#ffcc80",
    error="#c62828",
    error_bg="#fdecea",
    error_border="#f5c5c5",
    info="#7c4dff",
    info_bg="#f3eeff",
    info_border="#d4ccf5",
    # danger
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#f4f4f8",
    danger_disabled_border="#e0e0ea",
    # skeleton
    skeleton_base="#e0e0ea",
    skeleton_shimmer="#f0f0f6",
    # log
    log_bg="#f6f6fa",
    # spacing (idêntico)
    space_xs=4,
    space_sm=8,
    space_md=12,
    space_lg=18,
    space_xl=24,
    # typography (idêntico)
    font_ui='"Inter", "Noto Sans", "Segoe UI", sans-serif',
    font_mono='"JetBrains Mono", "Cascadia Code", monospace',
    text_xs=11,
    text_sm=11,
    text_base=13,
    text_lg=15,
    text_xl=18,
    text_2xl=26,
    # radius (idêntico)
    radius_sm=8,
    radius_md=11,
    radius_lg=16,
    # shadow (mais leve no light)
    shadow_alpha=60,
    # transition (idêntico)
    transition="150ms ease",
)


# Paletas de consoles antigos. Cores-fonte aproximadas dos gabinetes e
# logos; superfícies, bordas e estados derivados para manter o gate de
# contraste (a11y.CONTRAST_PAIRS). Espaçamento/tipografia vêm da base.

SNES = replace(
    LIGHT,
    bg="#e6e3e5",
    surface="#f4f2f3",
    surface_alt="#d6d2d4",
    surface_inset="#dedadc",
    surface_header="#f4f2f3",
    surface_input="#f4f2f3",
    surface_hero="#ddddf3",
    surface_hero_alt="#cccbeb",
    surface_selected="#ddddf3",
    surface_pressed="#d6d2d4",
    surface_disabled="#edeaec",
    border="#b2b4b2",
    border_subtle="#c7c7c6",
    border_divider="#cccccc",
    border_strong="#707372",
    accent_border="#8b83c4",
    text="#1e1f21",
    text_strong="#1e1f21",
    text_log="#1e1f21",
    sidebar_active_text="#1e1f21",
    sidebar_hover_text="#1e1f21",
    accent="#4f43ae",
    accent_hover="#473c9d",
    accent_pressed="#433994",
    on_accent="#ffffff",
    success_bg="#dcefe3",
    warning_bg="#f6e7c4",
    error_bg="#fdecea",
    info_bg="#ddddf3",
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#edeaec",
    danger_disabled_border="#c7c7c6",
    skeleton_base="#d6d2d4",
    skeleton_shimmer="#c4c3c3",
    log_bg="#dedadc",
    text_dim="#54585a",
    section_label="#54585a",
    text_muted="#808284",
    focus_ring="#4f43ae",
    success="#19683a",
    success_border="#7aac8e",
    warning="#7a5200",
    warning_border="#b89c62",
    error="#af251d",
    error_border="#d68884",
    info="#4f43ae",
    info_border="#8b83c4",
)

SFC = replace(
    LIGHT,
    bg="#e2e1dc",
    surface="#f1f0ec",
    surface_alt="#c8c7c2",
    surface_inset="#d5d4cf",
    surface_header="#f1f0ec",
    surface_input="#f1f0ec",
    surface_hero="#dce3f8",
    surface_hero_alt="#c9d4f4",
    surface_selected="#dce3f8",
    surface_pressed="#c8c7c2",
    surface_disabled="#eae8e4",
    border="#aeada8",
    border_subtle="#c3c2bd",
    border_divider="#c8c7c2",
    border_strong="#7a7a7a",
    accent_border="#7e95d7",
    text="#1f1f1f",
    text_strong="#1f1f1f",
    text_log="#1f1f1f",
    sidebar_active_text="#1f1f1f",
    sidebar_hover_text="#1f1f1f",
    accent="#3b63d4",
    accent_hover="#3559bf",
    accent_pressed="#3254b4",
    on_accent="#ffffff",
    success_bg="#ddefd9",
    warning_bg="#fbf1c4",
    error_bg="#fdecea",
    info_bg="#dce3f8",
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#eae8e4",
    danger_disabled_border="#c3c2bd",
    skeleton_base="#c8c7c2",
    skeleton_shimmer="#bbbab5",
    log_bg="#d5d4cf",
    text_dim="#535353",
    section_label="#535353",
    text_muted="#7e7e7c",
    focus_ring="#375dc7",
    success="#225e24",
    success_border="#80a67e",
    warning="#645000",
    warning_border="#b0a062",
    error="#9e211a",
    error_border="#ce8682",
    info="#2d4ca3",
    info_border="#7e95d7",
)

MEGADRIVE = replace(
    DARK,
    bg="#0d0d0d",
    surface="#1a1a1a",
    surface_alt="#262626",
    surface_inset="#090909",
    surface_header="#1a1a1a",
    surface_input="#090909",
    surface_hero="#3a1517",
    surface_hero_alt="#4d1619",
    surface_selected="#3a1517",
    surface_pressed="#262626",
    surface_disabled="#141414",
    border="#383838",
    border_subtle="#272727",
    border_divider="#222222",
    border_strong="#6e6e6e",
    accent_border="#86181c",
    text="#f2f2f2",
    text_strong="#f2f2f2",
    text_log="#f2f2f2",
    sidebar_active_text="#f2f2f2",
    sidebar_hover_text="#f2f2f2",
    accent="#d61f26",
    accent_hover="#c11c22",
    accent_pressed="#b61a20",
    on_accent="#ffffff",
    success_bg="#1d3329",
    warning_bg="#3a2f1a",
    error_bg="#3d1f1f",
    info_bg="#3a1517",
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#141414",
    danger_disabled_border="#272727",
    skeleton_base="#262626",
    skeleton_shimmer="#2f2f2f",
    log_bg="#090909",
    text_dim="#b5b5b5",
    section_label="#b5b5b5",
    text_muted="#838383",
    focus_ring="#ff6b70",
    success="#77d6a3",
    success_border="#4a8466",
    warning="#f4c26a",
    warning_border="#977842",
    error="#ff8a8a",
    error_border="#9e5454",
    info="#ff6b70",
    info_border="#86181c",
)

MASTERSYSTEM = replace(
    DARK,
    bg="#0f0f0f",
    surface="#1b1b1b",
    surface_alt="#2a2a2a",
    surface_inset="#0a0a0a",
    surface_header="#1b1b1b",
    surface_input="#0a0a0a",
    surface_hero="#3a1618",
    surface_hero_alt="#4d171a",
    surface_selected="#3a1618",
    surface_pressed="#2a2a2a",
    surface_disabled="#151515",
    border="#3a3a3a",
    border_subtle="#292929",
    border_divider="#242424",
    border_strong="#707070",
    accent_border="#86191d",
    text="#eaeaea",
    text_strong="#eaeaea",
    text_log="#eaeaea",
    sidebar_active_text="#eaeaea",
    sidebar_hover_text="#eaeaea",
    accent="#d62027",
    accent_hover="#c11d23",
    accent_pressed="#b61b21",
    on_accent="#ffffff",
    success_bg="#1d3329",
    warning_bg="#3a2f1a",
    error_bg="#3d1f1f",
    info_bg="#3a1618",
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#151515",
    danger_disabled_border="#292929",
    skeleton_base="#2a2a2a",
    skeleton_shimmer="#323232",
    log_bg="#0a0a0a",
    text_dim="#b3b3b3",
    section_label="#b3b3b3",
    text_muted="#828282",
    focus_ring="#ff6e72",
    success="#77d6a3",
    success_border="#4a8466",
    warning="#f4c26a",
    warning_border="#977842",
    error="#ff8a8a",
    error_border="#9e5454",
    info="#ff6e72",
    info_border="#86191d",
)

PCENGINE = replace(
    LIGHT,
    bg="#f2f2ee",
    surface="#fffffc",
    surface_alt="#d8d8d4",
    surface_inset="#e5e5e1",
    surface_header="#fffffc",
    surface_input="#fffffc",
    surface_hero="#fbe3da",
    surface_hero_alt="#f7cfc5",
    surface_selected="#fbe3da",
    surface_pressed="#d8d8d4",
    surface_disabled="#f8f8f5",
    border="#c4c4bf",
    border_subtle="#d6d6d2",
    border_divider="#dbdbd6",
    border_strong="#858580",
    accent_border="#e1847b",
    text="#1e1e1e",
    text_strong="#1e1e1e",
    text_log="#1e1e1e",
    sidebar_active_text="#1e1e1e",
    sidebar_hover_text="#1e1e1e",
    accent="#d63a2e",
    accent_hover="#c13429",
    accent_pressed="#b63127",
    on_accent="#ffffff",
    success_bg="#dcefe3",
    warning_bg="#f6e7c4",
    error_bg="#fdecea",
    info_bg="#fbe3da",
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#f8f8f5",
    danger_disabled_border="#d6d6d2",
    skeleton_base="#d8d8d4",
    skeleton_shimmer="#cececa",
    log_bg="#e5e5e1",
    text_dim="#5e5e5e",
    section_label="#5e5e5e",
    text_muted="#8a8a89",
    focus_ring="#b8291f",
    success="#1a6c3d",
    success_border="#7bae90",
    warning="#7a5200",
    warning_border="#b89c62",
    error="#b3261e",
    error_border="#d88984",
    info="#b4281e",
    info_border="#e1847b",
)

TURBOGRAFX = replace(
    DARK,
    bg="#111111",
    surface="#202020",
    surface_alt="#2c2c2c",
    surface_inset="#0c0c0c",
    surface_header="#202020",
    surface_input="#0c0c0c",
    surface_hero="#3b2015",
    surface_hero_alt="#512717",
    surface_selected="#3b2015",
    surface_pressed="#2c2c2c",
    surface_disabled="#181818",
    border="#4a4a4a",
    border_subtle="#333333",
    border_divider="#2e2e2e",
    border_strong="#767676",
    accent_border="#973d1f",
    text="#f2f2f2",
    text_strong="#f2f2f2",
    text_log="#f2f2f2",
    sidebar_active_text="#f2f2f2",
    sidebar_hover_text="#f2f2f2",
    accent="#f05a28",
    accent_hover="#f26a3e",
    accent_pressed="#cc4c22",
    on_accent="#111111",
    success_bg="#1d3329",
    warning_bg="#3a2f1a",
    error_bg="#3d1f1f",
    info_bg="#3b2015",
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#181818",
    danger_disabled_border="#333333",
    skeleton_base="#2c2c2c",
    skeleton_shimmer="#3b3b3b",
    log_bg="#0c0c0c",
    text_dim="#b8b8b8",
    section_label="#b8b8b8",
    text_muted="#868686",
    focus_ring="#f16131",
    success="#77d6a3",
    success_border="#4a8466",
    warning="#f4c26a",
    warning_border="#977842",
    error="#ff8a8a",
    error_border="#9e5454",
    info="#f26739",
    info_border="#973d1f",
)

NES = replace(
    LIGHT,
    bg="#d6d6d6",
    surface="#e8e8e8",
    surface_alt="#c6c6c6",
    surface_inset="#cecece",
    surface_header="#e8e8e8",
    surface_input="#e8e8e8",
    surface_hero="#f3d0d3",
    surface_hero_alt="#f1b7bc",
    surface_selected="#f3d0d3",
    surface_pressed="#c6c6c6",
    surface_disabled="#dfdfdf",
    border="#a8a8a8",
    border_subtle="#bababa",
    border_divider="#bfbfbf",
    border_strong="#6b6b6b",
    accent_border="#e05660",
    text="#1f1f1f",
    text_strong="#1f1f1f",
    text_log="#1f1f1f",
    sidebar_active_text="#1f1f1f",
    sidebar_hover_text="#1f1f1f",
    accent="#e60012",
    accent_hover="#cf0010",
    accent_pressed="#c4000f",
    on_accent="#ffffff",
    success_bg="#dcefe3",
    warning_bg="#f6e7c4",
    error_bg="#fdecea",
    info_bg="#f3d0d3",
    danger="#c62828",
    danger_hover="#d32f2f",
    danger_disabled_bg="#dfdfdf",
    danger_disabled_border="#bababa",
    skeleton_base="#c6c6c6",
    skeleton_shimmer="#b7b7b7",
    log_bg="#cecece",
    text_dim="#4f4f4f",
    section_label="#4f4f4f",
    text_muted="#787878",
    focus_ring="#b5000e",
    success="#175e35",
    success_border="#7aa68c",
    warning="#704b00",
    warning_border="#b39962",
    error="#9e211a",
    error_border="#ce8682",
    info="#aa000d",
    info_border="#e05660",
)

PS2 = replace(
    DARK,
    bg="#0a0a0a",
    surface="#1c1c1c",
    surface_alt="#262626",
    surface_inset="#070707",
    surface_header="#1c1c1c",
    surface_input="#070707",
    surface_hero="#13204a",
    surface_hero_alt="#152760",
    surface_selected="#13204a",
    surface_pressed="#262626",
    surface_disabled="#131313",
    border="#333333",
    border_subtle="#232323",
    border_divider="#1e1e1e",
    border_strong="#6c6c6c",
    accent_border="#1a3b9d",
    text="#f2f2f2",
    text_strong="#f2f2f2",
    text_log="#f2f2f2",
    sidebar_active_text="#f2f2f2",
    sidebar_hover_text="#f2f2f2",
    accent="#245cff",
    accent_hover="#2053e6",
    accent_pressed="#1f4ed9",
    on_accent="#ffffff",
    success_bg="#1d3329",
    warning_bg="#3a2f1a",
    error_bg="#3d1f1f",
    info_bg="#13204a",
    danger="#e53935",
    danger_hover="#ef5350",
    danger_disabled_bg="#131313",
    danger_disabled_border="#232323",
    skeleton_base="#262626",
    skeleton_shimmer="#2c2c2c",
    log_bg="#070707",
    text_dim="#b3b3b3",
    section_label="#b3b3b3",
    text_muted="#808080",
    focus_ring="#7fa2ff",
    success="#77d6a3",
    success_border="#4a8466",
    warning="#f4c26a",
    warning_border="#977842",
    error="#ff8a8a",
    error_border="#9e5454",
    info="#7fa2ff",
    info_border="#1a3b9d",
)


# id -> (rótulo, tokens). "dark"/"light" são os temas originais da marca.
THEMES: dict[str, tuple[str, ThemeTokens]] = {
    "dark": ("Escuro PhaseZero", DARK),
    "light": ("Claro PhaseZero", LIGHT),
    "snes": ("SNES", SNES),
    "sfc": ("Super Famicom", SFC),
    "megadrive": ("Mega Drive", MEGADRIVE),
    "mastersystem": ("Master System III", MASTERSYSTEM),
    "pcengine": ("PC Engine", PCENGINE),
    "turbografx": ("TurboGrafx-16", TURBOGRAFX),
    "nes": ("NES", NES),
    "ps2": ("PlayStation 2", PS2),
}


def tokens_for(theme: str) -> ThemeTokens:
    """Tokens de um id de tema; id desconhecido cai no escuro."""
    return THEMES.get(theme, ("", DARK))[1]


def is_light(tokens: ThemeTokens) -> bool:
    values = [int(tokens.bg[index:index + 2], 16) for index in (1, 3, 5)]
    return sum(values) / 3 > 127


def font_scale(point_size: float, base: float = 10.0) -> float:
    """LUX-020: grow type with the desktop font; never shrink below design."""
    if point_size <= 0:
        return 1.0
    return max(1.0, min(2.0, point_size / base))


def render_qss(tokens: ThemeTokens, scale: float = 1.0) -> str:
    """Read theme.qss and substitute every {{token}} placeholder.

    ``scale`` multiplies the ``text_*`` sizes (desktop font preference).
    """
    text = QSS_PATH.read_text(encoding="utf-8")

    def _sub(match: re.Match[str]) -> str:
        name = match.group(1)
        value = getattr(tokens, name)
        if name.startswith("text_") and isinstance(value, int):
            return str(round(value * scale))
        return str(value)

    return _PLACEHOLDER_RE.sub(_sub, text)
