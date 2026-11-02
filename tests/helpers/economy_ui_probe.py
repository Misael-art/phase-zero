"""Visible efficiency journey: pointer, keyboard, themes, scales and viewports."""
from pathlib import Path
import json
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QScrollArea
from linux.ui_native.app import apply_theme
from linux.ui_native.main_window import MainWindow
from linux.ui_native.status_loader import StatusLoader

root = Path(__file__).resolve().parents[2]
QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
app = QApplication([])
apply_theme(app, sys.argv[1])
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"), \
     patch("linux.ui_native.pages.homelab.HomelabPage.refresh_hosts", lambda _self: None), \
     patch("linux.ui_native.pages.homelab.HomelabPage.refresh_apps", lambda _self: None):
    window = MainWindow(root)
page = window.registry.page_for("IA & Dev")
page.reload = lambda: None
page.action_requested.disconnect(window.request_action)
page.action_selected.disconnect(window.inspect_action)
selected = []
page.action_requested.connect(selected.append)
window.show_category("IA & Dev")
card = page.economy_card
card.update_status({"ok": True, "project": "/fixture/project", "rtk": {"installed": True},
    "agents": [{"id": "codex", "label": "Codex", "profile": "basic", "configured": True,
                "memory": {"connected": True}}], "measurements": {"codex": {"reductionPercent": 35.5}}})
window.show()
window.raise_()
window.activateWindow()
app.processEvents()
scroll = page.findChild(QScrollArea)
checks = []
for size in ((800, 600), (1280, 800)):
    window.resize(*size)
    app.processEvents()
    QTest.qWait(30)
    assert (window.width(), window.height()) == size, (size, window.width(), window.height(), app.devicePixelRatio())
    for button in (card.apply, card.reset, card.measure, card.refresh, card.import_usage, card.review):
        scroll.ensureWidgetVisible(button, 8, 8)
        app.processEvents()
        assert scroll.horizontalScrollBar().maximum() == 0
        rect = QRect(button.mapToGlobal(QPoint(0, 0)), button.size())
        viewport = QRect(scroll.viewport().mapToGlobal(QPoint(0, 0)), scroll.viewport().size())
        assert viewport.contains(rect), button.text()
        if app.platformName() == "xcb":
            assert QApplication.widgetAt(rect.center()) is button, button.text()
    scroll.ensureWidgetVisible(card.apply, 8, 8)
    card.apply.setFocus()
    app.processEvents()
    assert app.focusWidget() is card.apply
    QTest.keyClick(card.apply, Qt.Key_Space)
    assert selected[-1].id == "ai.tokens-apply"
    assert "/fixture/project" in selected[-1].preview_args
    checks.append({"size": size, "overflow": False, "keyboard": True, "pointer": True})
scroll.verticalScrollBar().setValue(card.mapTo(scroll.widget(), QPoint(0, 0)).y() - 4)
app.processEvents()
assert window.grab().save(sys.argv[2])
print(json.dumps({"theme": sys.argv[1], "scale": app.devicePixelRatio(), "checks": checks}))
window.close()
