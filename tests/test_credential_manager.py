from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import subprocess
import sys

import pytest
from PySide6.QtCore import QCoreApplication, QEvent, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QScrollArea

from linux.ai.credential_inventory import CredentialUse
from linux.ai.credential_vault import CredentialVault
from linux.ui_native.credential_manager import CredentialManager
from tests.test_credential_inventory import Store


@pytest.fixture
def wallet_ui(tmp_path):
    app = QApplication.instance() or QApplication([])
    vault = CredentialVault(tmp_path / "wallet/credentials.json", Store())
    one = vault.add("deepseek", "Development", "controlled-one")
    two = replace(vault.add("openai", "Old project", "controlled-two"), stored_at="2020-01-01T00:00:00Z")
    three = replace(vault.add("anthropic", "Pending", "controlled-three"), state="pending")
    scroll = QScrollArea()
    scroll.setWidgetResizable(True)
    panel = CredentialManager()
    scroll.setWidget(panel)
    scroll.resize(1280, 800)
    panel.set_entries((one, two, three))
    panel.set_uses((CredentialUse(one.account_id, state="running", project="/private/project", process_id=123,
                                  observed_at="2026-11-07T12:00:00Z"),), "Consulta local concluída.")
    scroll.show()
    app.processEvents()
    yield app, scroll, panel, (one, two, three)
    scroll.close()
    scroll.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)


def test_search_filters_sort_and_unknown_states(wallet_ui):
    app, scroll, panel, entries = wallet_ui
    assert panel.table.rowCount() == 3
    assert "1 com processo ativo" in panel.totals.text()
    panel.search.setText("Old project")
    assert panel.table.rowCount() == 1
    assert "Revisar cadastro" in panel.table.cellWidget(0, 2).text()
    assert "Validade desconhecida" in panel.table.cellWidget(0, 2).text()
    panel.search.clear()
    panel.provider.setCurrentIndex(panel.provider.findData("deepseek"))
    assert panel.table.rowCount() == 1
    assert "DeepSeek Harness" in panel.table.cellWidget(0, 4).text()
    panel.provider.setCurrentIndex(0)
    panel.situation.setCurrentIndex(panel.situation.findData("pending"))
    assert panel.table.rowCount() == 1
    assert "Gravação pendente" in panel.table.cellWidget(0, 2).text()
    panel.search.setText("no match")
    assert panel.table.rowCount() == 0
    assert panel.empty.isVisible()


def test_details_privacy_actions_and_reopening(wallet_ui):
    app, scroll, panel, entries = wallet_ui
    panel.provider.setCurrentIndex(panel.provider.findData("deepseek"))
    panel.table.cellWidget(0, 6).click()
    assert panel.selected_id == entries[0].account_id
    assert panel.detail.isVisible()


    assert panel.findChild(QPushButton, "revokeApiCredentialUse").isEnabled()
    assert "/private/project" in " ".join(label.text() for label in panel.detail.findChildren(QLabel))
    revoked = []
    panel.revoke_requested.connect(revoked.append)
    panel.findChild(QPushButton, "revokeApiCredentialUse").click()
    assert revoked == [entries[0].account_id]
    panel.set_entries(entries, hidden=True)
    QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)
    visible_text = " ".join(label.text() for label in panel.findChildren(QLabel) if label.isVisible())
    assert "Development" not in visible_text
    assert "/private/project" not in visible_text
    assert "KEY-" not in visible_text
    assert not panel.search.isEnabled()
    panel.close_details()
    assert not panel.selected_id and not panel.detail.isVisible()
    panel.set_entries(entries, hidden=False)
    panel.table.cellWidget(0, 6).click()
    assert panel.detail.isVisible()


def test_filter_closes_detail_of_a_different_key(wallet_ui):
    app, scroll, panel, entries = wallet_ui
    panel.provider.setCurrentIndex(panel.provider.findData("deepseek"))
    panel.table.cellWidget(0, 6).click()
    assert panel.selected_id == entries[0].account_id
    panel.provider.setCurrentIndex(panel.provider.findData("openai"))
    assert panel.selected_id == ""
    assert not panel.detail.isVisible()


@pytest.mark.parametrize("width,height", [(800, 600), (1280, 800)])
def test_narrow_and_wide_list_keep_all_actions_reachable(wallet_ui, width, height):
    app, scroll, panel, entries = wallet_ui
    scroll.resize(width, height)
    app.processEvents()
    assert scroll.horizontalScrollBar().maximum() == 0
    assert panel.table.horizontalScrollBar().maximum() == 0
    panel.provider.setCurrentIndex(panel.provider.findData("deepseek"))
    manage = panel.table.cellWidget(0, 6)
    manage.setFocus()
    QTest.keyClick(manage, Qt.Key_Space)
    app.processEvents()
    assert panel.detail.isVisible()
    assert scroll.horizontalScrollBar().maximum() == 0
    assert panel.table.horizontalScrollBar().maximum() == 0
    close = panel.findChild(QPushButton, "closeCredentialDetails")
    close.setFocus()
    QTest.keyClick(close, Qt.Key_Space)
    assert not panel.detail.isVisible()


@pytest.mark.parametrize("theme", ["dark", "light"])
@pytest.mark.parametrize("scale", ["1", "1.5", "2"])
def test_native_accounts_journey_themes_and_scales(tmp_path, theme, scale):
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", QT_SCALE_FACTOR=scale,
               XDG_DATA_HOME=str(tmp_path / "data"), XDG_CONFIG_HOME=str(tmp_path / "config"),
               XDG_STATE_HOME=str(tmp_path / "state"), PZ_DSH_ROOT=str(tmp_path / "harness"))
    helper = Path(__file__).parent / "helpers/accounts_ui_probe.py"
    result = subprocess.run([sys.executable, str(helper), theme, str(tmp_path / "evidence")],
                            env=env, text=True, capture_output=True, timeout=45)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "native accounts journey passed" in result.stdout
