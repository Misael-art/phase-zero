from __future__ import annotations

import re
from dataclasses import dataclass
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
