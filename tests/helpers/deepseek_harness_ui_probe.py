"""Isolated theme, viewport, and keyboard check for the public Harness card."""
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from PySide6.QtCore import Qt, QRect, QPoint
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QFrame, QLabel, QScrollArea, QPushButton
from linux.ui_native.app import apply_theme
from linux.ui_native.main_window import MainWindow
from linux.ui_native.status_loader import StatusLoader

root = Path(__file__).resolve().parents[2]
app = QApplication([])
apply_theme(app, sys.argv[1])
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"):
    window = MainWindow(root)
page = window.registry.page_for("IA & Dev")
assert page is not None
page.reload = lambda: None
page.action_requested.disconnect(window.request_action)
page.action_selected.disconnect(window.inspect_action)
selected = []
page.action_requested.connect(selected.append)
page.action_selected.connect(selected.append)
page.set_advanced_mode(False)
window.resize(800, 600)
window.show()
window.show_category("IA & Dev")
app.processEvents()
page._on_status_ready("private.deepseek-harness.status", "", {
    "state": "running", "authRoute": "api", "workspace": "/tmp/fixture-workspace",
    "quota": "unknown", "balance": "unknown", "memoryBudget": "insufficient",
})
assert "rota api" in page.harness_state.text()
assert "Confirme a pasta /tmp/fixture-workspace" in page.harness_state.text()
assert "cota e saldo continuam desconhecidos" in page.harness_state.text()
assert "memória abaixo de 2 GiB" in page.harness_state.text()

card = page.findChild(QFrame, "deepseekHarnessCard")
assert card is not None
assert "Instalar → Conectar → Escolher pasta → Verificar → Abrir → Parar" in page.findChild(QLabel, "deepseekHarnessJourney").text()
assert "não limita rede nem processos" in page.findChild(QLabel, "deepseekHarnessBoundary").text()
assert page.findChild(QLabel, "deepseekHarnessAdvanced").isHidden()
scroll = page.findChild(QScrollArea)
assert scroll is not None
install = page.findChild(QPushButton, "deepseekHarnessInstall")
start = page.findChild(QPushButton, "deepseekHarnessStart")
open_button = page.findChild(QPushButton, "deepseekHarnessOpen")
stop = page.findChild(QPushButton, "deepseekHarnessStop")
doctor = page.findChild(QPushButton, "deepseekHarnessDoctor")
buttons = (install, start, open_button, stop, doctor)
assert all(button is not None and button.isEnabled() for button in buttons)
assert [button.accessibleName() for button in buttons] == ["Instalar", "Conectar / escolher pasta", "Abrir", "Parar", "Verificar"]

for width, height in ((800, 600), (1280, 800)):
    window.resize(width, height)
    app.processEvents()
    assert (window.width(), window.height()) == (width, height)
    for button in buttons:
        scroll.ensureWidgetVisible(button, 8, 8)
        app.processEvents()
        rect = QRect(button.mapToGlobal(QPoint(0, 0)), button.size())
        viewport = QRect(scroll.viewport().mapToGlobal(QPoint(0, 0)), scroll.viewport().size())
        assert button.isVisible() and not button.visibleRegion().isEmpty()
        assert viewport.contains(rect), f"{sys.argv[1]} {width}x{height}: {button.objectName()} outside viewport"
    assert scroll.horizontalScrollBar().maximum() == 0, f"{sys.argv[1]} {width}x{height}: horizontal overflow"
    install.setFocus()
    QTest.keyClick(install, Qt.Key_Tab)
    assert app.focusWidget() is start, "Tab order must follow install -> connect"
    QTest.keyClick(start, Qt.Key_Space)
    app.processEvents()
    assert selected and selected[-1].id == "ai.deepseek-harness-start"

page.set_advanced_mode(True)
assert not page.findChild(QLabel, "deepseekHarnessAdvanced").isHidden()
page.set_advanced_mode(False)
assert window.grab().save(sys.argv[2])
window.close()
