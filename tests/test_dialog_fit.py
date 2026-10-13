"""LUX-012 — diálogos cabem na tela lógica do Steam Deck a 150% e 200%."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QRect
from PySide6.QtWidgets import QApplication, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import OperationResult

ROOT = Path(__file__).resolve().parents[1]
SCREENS = {"deck-150": QRect(0, 0, 853, 533), "deck-200": QRect(0, 0, 640, 400)}


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def by_id():
    return {a.id: a for a in build_catalog(ROOT)}


def _result(action_id="x"):
    return OperationResult(
        action_id=action_id, command=["pz"], preview=True, exit_code=0,
        started_at="", finished_at="", stdout="{}", stderr="", parsed={},
    )


def _factories(by_id):
    from linux.ui_native import boot_selector
    from linux.ui_native.widgets import ParameterDialog, PreviewDialog, ProgressDialog, ResultDialog
    from linux.ui_native.windows_install_dialog import WindowsInstallDialog

    high = by_id["waydroid.boot.next-reboot"]
    param = next(a for a in by_id.values() if a.parameters)
    return {
        "preview-high": lambda: PreviewDialog(_result(high.id), high),
        "result": lambda: ResultDialog(_result(), "texto\n" * 200, severity="success"),
        "progress": lambda: ProgressDialog("Instalar", "pz install"),
        "parameter": lambda: ParameterDialog(param),
        "windows-install": lambda: WindowsInstallDialog(),
        "boot-selector": lambda: boot_selector.BootSelectorWindow(ROOT, smoke_test=True),
    }


@pytest.mark.parametrize("screen", sorted(SCREENS))
def test_dialogs_fit_and_keep_actions_visible(qapp, by_id, screen):
    area = SCREENS[screen]
    with patch("linux.ui_native.widgets.available_geometry", return_value=area), patch(
        "linux.ui_native.boot_selector.load_dynamic_boot_choices", return_value=()
    ):
        for name, make in _factories(by_id).items():
            dialog = make()
            dialog.show()
            qapp.processEvents()
            assert dialog.width() <= area.width(), (name, dialog.width())
            assert dialog.height() <= area.height(), (name, dialog.height())
            rect = dialog.rect()
            buttons = [b for b in dialog.findChildren(QPushButton) if b.isVisible()]
            assert buttons, name
            for button in buttons:
                if button.parent() is not None and button.parent().objectName() == "dialogBody":
                    continue
                top_left = button.mapTo(dialog, button.rect().topLeft())
                bottom_right = button.mapTo(dialog, button.rect().bottomRight())
                assert rect.contains(top_left) and rect.contains(bottom_right), (name, button.text())
            dialog.close()
