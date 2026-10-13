"""LUX-030..032 — textos que leitores de tela anunciam."""
from __future__ import annotations

import unicodedata
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.models import OperationResult

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _result():
    return OperationResult(
        action_id="x", command=["pz"], preview=True, exit_code=0,
        started_at="", finished_at="", stdout="{}", stderr="", parsed={},
    )


def test_state_icon_is_announced_in_portuguese(qapp):
    from linux.ui_native.widgets import ResultDialog

    dialog = ResultDialog(_result(), "", severity="success")
    names = [label.accessibleName() for label in dialog.findChildren(QLabel) if label.accessibleName()]
    assert "Estado: concluído" in names
    assert not any("success" in name for name in names)


def test_copy_button_says_what_it_copies(qapp):
    from linux.ui_native.widgets import PreviewDialog

    dialog = PreviewDialog(_result())
    texts = [b.text() for b in dialog.findChildren(QPushButton)]
    assert "Copiar detalhes técnicos" in texts and "Copiar saída" not in texts


def test_welcome_title_has_no_emoji(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    from linux.ui_native.pages.dashboard import DashboardPage

    page = DashboardPage(ROOT, CommandRunner(ROOT), [], by_id={})
    page.build()
    title = next(l for l in page.findChildren(QLabel) if l.objectName() == "welcomeTitle")
    assert not any(unicodedata.category(ch) == "So" for ch in title.text())
