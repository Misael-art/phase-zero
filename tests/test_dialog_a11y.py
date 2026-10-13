"""LUX-025 — piso de acessibilidade também nos diálogos."""
from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QAbstractButton, QApplication, QComboBox, QLineEdit

from linux.ui_native.a11y import accessible_label
from linux.ui_native.catalog import build_catalog
from tests.test_dialog_fit import _factories

ROOT = Path(__file__).resolve().parents[1]
INTERACTIVE = (QAbstractButton, QComboBox, QLineEdit)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def by_id():
    return {a.id: a for a in build_catalog(ROOT)}


def test_every_dialog_control_has_an_accessible_name(qapp, by_id):
    mute: list[str] = []
    with patch("linux.ui_native.boot_selector.load_dynamic_boot_choices", return_value=()):
        for name, make in _factories(by_id).items():
            dialog = make()
            dialog.show()
            qapp.processEvents()
            widgets = [w for kind in INTERACTIVE for w in dialog.findChildren(kind)]
            for widget in widgets:
                if widget.isVisible() and not accessible_label(widget):
                    mute.append(f"{name}:{type(widget).__name__}:{widget.objectName()}")
            dialog.close()
    assert mute == []


def test_high_risk_preview_focuses_the_confirmation_field(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog
    from tests.test_dialog_fit import _result

    action = by_id["waydroid.boot.next-reboot"]
    dialog = PreviewDialog(_result(action.id), action)
    dialog.show()
    qapp.processEvents()
    dialog.activateWindow()
    assert dialog.confirmation.hasFocus() or dialog.focusWidget() is dialog.confirmation
    dialog.close()


def test_tab_order_reaches_confirm_after_the_field(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog
    from tests.test_dialog_fit import _result

    action = by_id["waydroid.boot.next-reboot"]
    dialog = PreviewDialog(_result(action.id), action)
    dialog.show()
    qapp.processEvents()
    # Tab a partir do campo CONFIRMAR vai direto ao botão que ele libera.
    dialog.confirmation.setText("CONFIRMAR")
    widget = dialog.confirmation.nextInFocusChain()
    while widget is not None and not (widget.focusPolicy() & widget.focusPolicy().TabFocus and widget.isEnabled() and widget.isVisible()):
        widget = widget.nextInFocusChain()
    assert widget is dialog.confirm
    dialog.close()
