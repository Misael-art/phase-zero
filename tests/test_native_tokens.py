from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys_path_prepend = str(ROOT)

import sys

if sys_path_prepend not in sys.path:
    sys.path.insert(0, sys_path_prepend)

from linux.ui_native.tokens import DARK, LIGHT, ThemeTokens, render_qss


def test_dark_and_light_have_same_fields():
    dark_fields = {f.name for f in __import__("dataclasses").fields(DARK)}
    light_fields = {f.name for f in __import__("dataclasses").fields(LIGHT)}
    assert dark_fields == light_fields


def test_render_qss_dark_has_no_placeholders():
    qss = render_qss(DARK)
    assert "{{" not in qss
    assert "}}" not in qss


def test_render_qss_light_has_no_placeholders():
    qss = render_qss(LIGHT)
    assert "{{" not in qss
    assert "}}" not in qss


def test_render_qss_preserves_accent():
    assert DARK.accent == "#7c4dff"
    assert LIGHT.accent == "#7c4dff"
    assert "#7c4dff" in render_qss(DARK)
    assert "#7c4dff" in render_qss(LIGHT)


def test_every_placeholder_resolves():
    """Every {{token}} in theme.qss must map to a ThemeTokens field."""
    qss_raw = (ROOT / "linux" / "ui_native" / "theme.qss").read_text(encoding="utf-8")
    placeholders = set(re.findall(r"\{\{(\w+)\}\}", qss_raw))
    field_names = {f.name for f in __import__("dataclasses").fields(ThemeTokens)}
    missing = placeholders - field_names
    assert not missing, f"Placeholders without token field: {missing}"


def test_qss_has_no_literal_hex_colors():
    qss_raw = (ROOT / "linux" / "ui_native" / "theme.qss").read_text(encoding="utf-8")
    assert not re.findall(r"#[0-9a-fA-F]{3,8}\b", qss_raw)


def _luminance(color: str) -> float:
    values = [int(color[index:index + 2], 16) / 255 for index in (1, 3, 5)]
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in values]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def _contrast(foreground: str, background: str) -> float:
    high, low = sorted((_luminance(foreground), _luminance(background)), reverse=True)
    return (high + 0.05) / (low + 0.05)


def test_core_text_pairs_meet_wcag_aa():
    for tokens in (DARK, LIGHT):
        assert _contrast(tokens.text, tokens.bg) >= 4.5
        assert _contrast(tokens.text_dim, tokens.bg) >= 4.5
        assert _contrast(tokens.on_accent, tokens.accent) >= 4.5


def test_app_apply_theme_uses_tokens():
    """apply_theme should set stylesheet from render_qss, not regex-rewrite."""
    import linux.ui_native.app as app_mod
    # stylesheet() must delegate to render_qss, not contain the old replacements dict
    source = Path(app_mod.__file__).read_text(encoding="utf-8")
    # The old regex-rewrite had a 'replacements = {' block — must be gone.
    assert "replacements = {" not in source
    assert "from .tokens import" in source or "from linux.ui_native.tokens import" in source


def test_type_scales_with_desktop_font_and_floor_is_readable():
    """LUX-020: texto cresce com a fonte do sistema; mínimo de 11px."""
    import re
    from linux.ui_native.tokens import font_scale

    assert DARK.text_xs >= 11 and LIGHT.text_xs >= 11
    assert font_scale(10) == 1.0
    assert font_scale(8) == 1.0
    assert font_scale(12) == 1.2
    base = render_qss(DARK)
    big = render_qss(DARK, font_scale(15))
    assert f"font-size: {DARK.text_base}px" in base
    assert f"font-size: {round(DARK.text_base * 1.5)}px" in big
    assert re.findall(r"#[0-9a-f]{6}", base) == re.findall(r"#[0-9a-f]{6}", big)
