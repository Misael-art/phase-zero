"""Regressão: o switch pintado precisa alternar onde o usuário clica.

`SwitchControl` é um QCheckBox com `paintEvent` próprio que desenha rótulo e
trilho ao longo de toda a largura, com o trilho encostado na borda direita.
O hit rect padrão do QCheckBox cobre apenas o indicador nativo (à esquerda,
que não é pintado), então clicar no switch visível não alternava nada em
Temas, Serviços, Windows VM e no toggle "Modo avançado" do cabeçalho.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PySide6.QtCore import QPoint, Qt
from PySide6.QtWidgets import QApplication


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def _switch(app):
    from linux.ui_native.widgets import SwitchControl

    switch = SwitchControl()
    switch.resize(switch.sizeHint())
    return switch


def test_click_on_painted_track_toggles(app):
    from PySide6.QtTest import QTest

    switch = _switch(app)
    # Centro do trilho: o paintEvent o desenha em (width - 44, ..., 44, 24).
    track_center = QPoint(switch.width() - 22, switch.height() // 2)
    assert not switch.isChecked()
    QTest.mouseClick(switch, Qt.LeftButton, Qt.NoModifier, track_center)
    assert switch.isChecked(), "clique no trilho pintado precisa alternar o switch"


def test_click_anywhere_in_widget_toggles(app):
    from PySide6.QtTest import QTest

    switch = _switch(app)
    for x in (2, switch.width() // 2, switch.width() - 1):
        switch.setChecked(False)
        QTest.mouseClick(
            switch, Qt.LeftButton, Qt.NoModifier, QPoint(x, switch.height() // 2)
        )
        assert switch.isChecked(), f"clique em x={x} precisa alternar o switch"


def test_hit_button_covers_full_rect(app):
    switch = _switch(app)
    assert switch.hitButton(QPoint(switch.width() - 1, switch.height() - 1))
    assert not switch.hitButton(QPoint(switch.width() + 10, 0))
