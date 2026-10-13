"""LUX-024 — Perfis: recomendado primeiro, sem largura fixa."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_recommended_first_and_no_fixed_width(qapp):
    from linux.ui_native.pages.profiles import ProfilesPage

    catalog = build_catalog(ROOT)
    actions = [a for a in catalog if a.category == "Perfis"]
    page = ProfilesPage(ROOT, CommandRunner(ROOT), actions, {a.id: a for a in catalog})
    page.build()
    assert page.combo.itemData(0) == "profile.safe-base"
    assert "recomendado" in page.combo.itemText(0)
    assert page.combo.minimumWidth() < 400
    assert page.combo.minimumSizeHint().width() < 400
    assert page.install_btn.text() == "Ver o que instala"
