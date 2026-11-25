"""Visible Qt memory journey probe: theme, scale, viewport and keyboard."""
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
page.memory_card.update_status({"installed": True, "service": "active", "keyConfigured": True,
    "version": "3.3.1", "automatic": True, "recoveryExported": False,
    "scopes": [{"id": "fixture", "project": "PhaseZero"}], "devices": [],
    "curation": {"id": "f" * 32, "findings": 2, "provider": "Codex", "model": "gpt-6-astra"},
    "github": {"repository": "fixture/private"}, "availableProjects": [],
    "sync": {"targets": [{"id": "github", "state": "current", "lastBackup": {"verifiedAt": "2026-11-01 23:16 UTC"}}]}})
window.show()
window.raise_()
window.activateWindow()
app.processEvents()
scroll = page.findChild(QScrollArea)
card = page.memory_card
receipt = []
for size in ((800, 600), (1280, 800)):
    window.resize(*size)
    app.processEvents()
    assert window.width() <= size[0] and window.height() <= size[1], (size, window.size())
    for advanced in (False, True):
        page.set_advanced_mode(advanced)
        app.processEvents()
        QTest.qWait(30)
        app.processEvents()
        assert scroll.horizontalScrollBar().maximum() == 0, "memory journey horizontal overflow"
        for name in ("sync", "repair", "curate", "curate-apply", "github", "key-export") + (("settings", "restore") if advanced else ()):
            button = card.buttons[name]
            scroll.ensureWidgetVisible(button, 8, 8)
            app.processEvents()
            rect = QRect(button.mapToGlobal(QPoint(0, 0)), button.size())
            viewport = QRect(scroll.viewport().mapToGlobal(QPoint(0, 0)), scroll.viewport().size())
            if not viewport.contains(rect):
                window.grab().save(sys.argv[2])
                print({"name": name, "button": rect.getRect(), "viewport": viewport.getRect(), "scroll": scroll.verticalScrollBar().value(), "size": size, "advanced": advanced})
            assert viewport.contains(rect), f"{name} outside visible viewport"
            assert button.isVisibleTo(page) and not button.visibleRegion().isEmpty()
            if app.platformName() == "xcb":
                assert QApplication.widgetAt(rect.center()) is button, f"{name} pointer blocked"
        receipt.append({"size": (window.width(), window.height()), "advanced": advanced, "overflow": False})
    sync = card.buttons["sync"]
    scroll.ensureWidgetVisible(sync, 8, 8)
    sync.setFocus()
    app.processEvents()
    assert app.focusWidget() is sync
    QTest.keyClick(sync, Qt.Key_Space)
    assert selected[-1].id == "ai.memory-sync"
    review = card.buttons["curate-apply"]
    scroll.ensureWidgetVisible(review, 8, 8)
    review.setFocus()
    QTest.keyClick(review, Qt.Key_Space)
    assert selected[-1].id == "ai.memory-curate-apply"
page.set_advanced_mode(False)
scroll.ensureWidgetVisible(card.state, 8, 8)
app.processEvents()
assert window.grab().save(sys.argv[2])
print(json.dumps({"theme": sys.argv[1], "devicePixelRatio": app.devicePixelRatio(), "checks": receipt}))
window.close()
