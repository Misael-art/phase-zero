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
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"), \
     patch("linux.ui_native.pages.homelab.HomelabPage.refresh_hosts", lambda _self: None):
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
window.raise_()
window.activateWindow()
window.show_category("IA & Dev")
app.processEvents()
page._on_status_ready("ai.deepseek-harness-status", "", {
    "state": "installed", "installed": True, "runtimeState": "stopped",
    "memoryBudget": "sufficient", "installedVersion": "fixture",
})
card = page.harness_card
assert card is not None
assert "Instalar → Conectar → Escolher pasta → Verificar → Abrir → Parar" in page.findChild(QLabel, "deepseekHarnessJourney").text()
assert "não limita rede nem processos" in page.findChild(QLabel, "deepseekHarnessBoundary").text()
assert not page.findChild(QLabel, "deepseekHarnessAdvanced").isVisibleTo(page)
scroll = page.findChild(QScrollArea)
assert scroll is not None
install = page._harness_buttons["install"]
start = page._harness_buttons["start"]
open_button = page._harness_buttons["open"]
stop = page._harness_buttons["stop"]
doctor = page._harness_buttons["doctor"]
buttons = (start, doctor)
assert all(button is not None and button.isEnabled() for button in buttons)
assert install.isHidden() and open_button.isHidden() and not stop.isEnabled()
assert [button.accessibleName() for button in buttons] == ["Conectar / escolher pasta", "Verificar"]

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
        if app.platformName() == "xcb":
            assert QApplication.widgetAt(rect.center()) is button, "Pointer must reach the visible control"
    assert scroll.horizontalScrollBar().maximum() == 0, f"{sys.argv[1]} {width}x{height}: horizontal overflow"
    start.setFocus()
    app.processEvents()
    assert app.focusWidget() is start, "Start control must receive keyboard focus"
    QTest.keyClick(start, Qt.Key_Tab)
    assert app.focusWidget() is doctor, "Tab skips hidden and disabled controls"
    QTest.keyClick(start, Qt.Key_Space)
    app.processEvents()
    assert selected and selected[-1].id == "ai.deepseek-harness-start"

page.set_advanced_mode(True)
assert page.findChild(QLabel, "deepseekHarnessAdvanced").isVisibleTo(page)
for name in ("Plan", "Update", "Uninstall"):
    button = page._harness_buttons[name.lower()]
    scroll.ensureWidgetVisible(button, 8, 8)
    app.processEvents()
    assert button.isVisible() and button.isEnabled()
page.set_advanced_mode(False)
scroll.ensureWidgetVisible(page.harness_state, 8, 8)
app.processEvents()
assert window.grab().save(sys.argv[2])
window.close()
