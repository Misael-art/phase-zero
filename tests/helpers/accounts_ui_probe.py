"""Isolated native-UI journey and screenshots; no operator credentials/probes."""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from PySide6.QtCore import Qt, QPoint, QRect
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QCheckBox, QLabel, QPushButton, QScrollArea

from linux.ai.account_adapters import router_provider_accounts
from linux.ai.account_contract import Evidence, Quota
from linux.ai.credential_inventory import CredentialUse
from linux.ai.credential_vault import CredentialVault
from linux.ui_native.app import apply_theme
from linux.ui_native.main_window import MainWindow
from linux.ui_native.status_loader import StatusLoader


class MetadataFixtureStore:
    def store(self, *_args):
        pass

    def lookup(self, *_args):
        raise AssertionError("UI inventory must not look up a key")


root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
app = QApplication([])
apply_theme(app, sys.argv[1])
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"), \
        patch("linux.ui_native.pages.homelab.HomelabPage.refresh_hosts", lambda _self: None), \
        patch("linux.ui_native.pages.linux_hub.LinuxHubPage.reload", lambda _self: None):
    window = MainWindow(root, initial_category="Contas e conexões")
page = window.registry.page_for("Contas e conexões")
vault = CredentialVault(output / "wallet/credentials.json", MetadataFixtureStore())
if not vault.entries:
    vault.add("DeepSeek", "Harness · desenvolvimento", "fixture-placeholder-one")
    vault.add("OpenAI", "Integração · homologação", "fixture-placeholder-two")
    vault.add("Anthropic", "Equipe · processamento", "fixture-placeholder-three")
page.credential_vault = vault
entries = tuple(replace(entry, stored_at="2026-01-02T09:00:00Z") if entry.provider == "OpenAI" else entry for entry in vault.entries)
deepseek = next(entry for entry in entries if entry.provider == "DeepSeek")
page._credential_uses = (CredentialUse(deepseek.account_id, state="running", project="/projetos/exemplo", process_id=4321,
                                      observed_at="2026-11-07T12:00:00Z"),)
page._usage_observation = "Amostra visual · dados controlados de teste."
page._outcomes = {source: "ok" for source in ("claude", "proxies", "router-providers", "router-status")}
account, connection = router_provider_accounts({"connections": [{"id": "controlled-account", "provider": "Anthropic", "name": "Equipe · processamento", "active": True}]})[0]
page._accounts = ((account, replace(connection, session=Evidence("yes", "controlled-test", "2026-11-07T12:00:00Z"),
                                  quota=Quota("messages", "mensagens", 120, 500, reset_at="2026-12-01T00:00:00Z", source="official", observed_at="2026-11-07T12:00:00Z"))),)
page.summary.setText("Amostra visual · dados controlados de teste")
page._render_cards()
page._render_credentials()
window.resize(1280, 800)
window.show()
window.raise_()
window.activateWindow()
QTest.qWait(100)
QTest.qWait(80)
assert window.grab().save(str(output / "contas.png"))
page.findChild(QPushButton, "openCredentialManager").click()
panel = page.credential_manager
# Keep the artificially aged entry only in this visual fixture.
panel.set_entries(entries)
QTest.qWait(80)
assert window.grab().save(str(output / "chaves.png"))
panel.provider.setCurrentIndex(panel.provider.findData("DeepSeek"))
panel.table.cellWidget(0, 6).click()
QTest.qWait(80)
assert window.grab().save(str(output / "detalhes.png"))

for width, height in ((800, 600), (1280, 800)):
    window.resize(width, height)
    QTest.qWait(80)
    scroll = page._views.currentWidget()
    assert isinstance(scroll, QScrollArea)
    assert scroll.horizontalScrollBar().maximum() == 0, f"{width}: wallet overflow"
    assert panel.table.horizontalScrollBar().maximum() == 0, f"{width}: list overflow"
    for name in ("closeCredentialDetails", "replaceApiCredential", "removeApiCredential"):
        button = panel.findChild(QPushButton, name)
        scroll.ensureWidgetVisible(button, 8, 8)
        QTest.qWait(80)
        rect = QRect(button.mapToGlobal(QPoint()), button.size())
        viewport = QRect(scroll.viewport().mapToGlobal(QPoint()), scroll.viewport().size())
        assert button.isEnabled() and viewport.contains(rect), f"{width}: {name} unreachable; rect={rect}, viewport={viewport}, detail={panel.detail.geometry()}, minimum={panel.detail.minimumSize()}, hint={panel.details.sizeHint()}, hfw={panel.details.totalHeightForWidth(400)}"
        button.setFocus()
        assert app.focusWidget() is button, f"{width}: {name} cannot focus"
    panel.close_details()
    QTest.qWait(80)
    assert scroll.horizontalScrollBar().maximum() == 0
    panel.table.cellWidget(0, 6).click()
    QTest.qWait(80)

page.findChild(QCheckBox, "hideAccountIdentity").setChecked(True)
QTest.qWait(80)
visible = " ".join(label.text() for label in panel.findChildren(QLabel) if label.isVisible())
assert "Harness · desenvolvimento" not in visible
assert "/projetos/exemplo" not in visible
page._close_credential_manager()
QTest.qWait(80)
assert page._views.currentIndex() == 0
open_button = page.findChild(QPushButton, "openCredentialManager")
QTest.keyClick(open_button, Qt.Key_Space)
assert page._views.currentIndex() == 1 and not panel.selected_id
window.close()
window.deleteLater()
QTest.qWait(80)
print(f"native accounts journey passed: {sys.argv[1]}")
