"""Render real inventory observations in the themed public inventory dialog.

Run with isolated HOME/XDG. Backend observations supplied by the caller; no
Windows starts, disk mutation or privilege action is dispatched by this probe.
"""
from pathlib import Path
import json
import sys
from unittest.mock import patch

root = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(root))
from PySide6.QtCore import Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialog, QLabel, QPushButton, QScrollArea
from linux.ui_native.app import apply_theme
from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.image_manager_dialog import ImageManagerDialog, _PzReader

app = QApplication([])
apply_theme(app, sys.argv[2])
payload = json.loads(Path(sys.argv[3]).read_text())
observations = {e["id"]: e.get("integrity", {}) for e in payload["instances"]}
failure = []

def read(self, request_id, args, *, timeout_ms):
    if request_id == "vm-inventory":
        QTimer.singleShot(0, lambda: self.finished_ok.emit(request_id, json.dumps(payload)))
    else:
        assert args[:3] == ["windows-vm", "provision", "integrity"]
        assert "--guest-files" in args
        QTimer.singleShot(50, lambda: self.finished_ok.emit(request_id, json.dumps(observations[request_id])))

with patch.object(_PzReader, "run", read):
    dialog = ImageManagerDialog(root, CommandRunner(root), {a.id: a for a in build_catalog(root)})
    dialog.resize(800, min(600, app.primaryScreen().availableGeometry().height()))
    dialog.show()
    app.processEvents()
    def interact():
        modal = dialog.findChild(QDialog, "windowsVmInventoryDialog")
        try:
            check = modal.findChild(QPushButton, "windowsVmIntegrityCheck")
            assert check.isEnabled() and check.isVisible()
            QTest.mouseClick(check, Qt.LeftButton)
            assert not check.isEnabled()
            def finish():
                try:
                    assert check.isEnabled()
                    assert any("Estrutura e arquivos essenciais verificados" in lab.text()
                               for lab in modal.findChildren(QLabel))
                    for button in modal.findChildren(QPushButton):
                        if button.isVisible():
                            assert modal.contentsRect().contains(button.mapTo(modal, button.rect().bottomRight())), button.text()
                    for area in modal.findChildren(QScrollArea):
                        assert area.horizontalScrollBar().maximum() == 0
                    assert dialog.pending_action() is None
                    assert modal.width() <= 800
                    assert modal.height() <= app.primaryScreen().availableGeometry().height()
                    assert modal.grab().save(sys.argv[4])
                    print(json.dumps({"theme": sys.argv[2], "size": [modal.width(), modal.height()],
                                      "parentSize": [dialog.width(), dialog.height()], "publicCheck": True,
                                      "noHorizontalOverflow": True}))
                except BaseException as exc:
                    failure.append(exc)
                finally:
                    modal.reject()
            QTimer.singleShot(300, finish)
        except BaseException as exc:
            failure.append(exc)
            modal.reject()
    QTimer.singleShot(50, interact)
    QTest.mouseClick(dialog.vms_button, Qt.LeftButton)
    dialog.close()
    if failure:
        raise failure[0]
