"""LUX-018 — a ajuda do pz descreve os atalhos que o produto instala."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_help_names_the_real_hotkeys():
    text = (ROOT / "linux" / "pz").read_text(encoding="utf-8")
    installer = (ROOT / "linux" / "steamdeck" / "install-hotkeys.sh").read_text(encoding="utf-8")
    assert "super + shift + F8" in installer
    assert "Meta+Shift+F1..F8" in text
    assert "Ctrl+Alt+F1" not in text
