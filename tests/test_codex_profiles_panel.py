from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
import json
from PySide6.QtCore import QObject, Signal, QEvent
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QDialog

from linux.ai.codex_profiles import CodexProfiles
from linux.ui_native.codex_profiles_panel import CodexProfilesPanel, CodexProfileDialog


class Runner(QObject):
    completed = Signal(object)


@pytest.fixture
def panel(tmp_path, monkeypatch):
    app = QApplication.instance() or QApplication([])
    for key, folder in (("HOME", "home"), ("XDG_DATA_HOME", "data"),
                        ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state")):
        monkeypatch.setenv(key, str(tmp_path / folder))
    manager = CodexProfiles()
    a = manager.add("Conta pessoal A", "verde")
    b = manager.add("Conta trabalho B", "roxo")
    runner = Runner()
    panel = CodexProfilesPanel(runner, hidden=False)
    yield panel, manager, a, b, app
    panel.close()
    panel.deleteLater()
    app.sendPostedEvents(None, QEvent.DeferredDelete)


def test_each_button_dispatches_its_own_profile_without_switching_accounts(panel):
    widget, _manager, a, b, _app = panel
    actions = []
    widget.action_requested.connect(actions.append)
    for row in (a, b):
        button = next(button for button in widget.findChildren(QPushButton, "codexProfileDesktop")
                      if button.property("profileId") == row["id"])
        button.click()
    assert actions[0].args == ("ai", "codex-profiles", "--redacted", "open", a["id"], "--surface", "desktop")
    assert actions[1].args == ("ai", "codex-profiles", "--redacted", "open", b["id"], "--surface", "desktop")
    assert all(not action.elevated for action in actions)


def test_privacy_hides_labels_and_ids_and_archived_profile_only_offers_restore(panel):
    widget, manager, a, b, app = panel
    manager.archive(a["id"])
    widget.set_hidden(True)
    app.sendPostedEvents(None, QEvent.DeferredDelete)
    labels = " ".join(label.text() for label in widget.findChildren(QLabel))
    assert a["label"] not in labels and b["label"] not in labels
    assert a["id"] not in labels and b["id"] not in labels
    assert widget.findChild(QPushButton, "restoreCodexProfile") is not None
    assert not any(button.property("profileId") == a["id"]
                   for button in widget.findChildren(QPushButton, "codexProfileDesktop"))
    assert all(not button.isEnabled() for button in widget.findChildren(QPushButton, "codexProfileWeb"))


def test_add_profile_collects_only_visual_metadata(panel):
    widget, _manager, _a, _b, _app = panel
    actions = []
    widget.action_requested.connect(actions.append)
    def accept(dialog):
        dialog.label.setText("Conta C")
        dialog.color.setCurrentIndex(dialog.color.findData("laranja"))
        return QDialog.Accepted
    with patch.object(CodexProfileDialog, "exec", accept):
        widget.findChild(QPushButton, "addCodexProfile").click()
    assert actions[0].args == ("ai", "codex-profiles", "--redacted", "add", "--metadata-stdin")
    assert "Conta C" not in " ".join(actions[0].args)
    values = widget.consume_action_values(actions[0])
    assert json.loads(values["codex_metadata"]) == {"label": "Conta C", "color": "laranja"}
    assert actions[0].mutable and not actions[0].elevated


def test_panel_fits_steamdeck_width_without_hidden_controls(panel):
    widget, _manager, _a, _b, app = panel
    widget.resize(560, 1000)
    widget.show()
    app.processEvents()
    assert widget.minimumSizeHint().width() <= 560
    for button in widget.findChildren(QPushButton):
        assert button.geometry().width() > 0



def test_cleanup_buttons_exclude_primary_and_dispatch_real_dry_run(panel):
    widget, manager, a, b, app = panel
    manager.archive(a["id"])
    widget.refresh()
    app.sendPostedEvents(None, QEvent.DeferredDelete)
    actions = []
    widget.action_requested.connect(actions.append)
    buttons = widget.findChildren(QPushButton, "deleteCodexProfile")
    assert {button.property("profileId") for button in buttons} == {a["id"], b["id"]}
    buttons[0].click()
    action = actions[-1]
    assert action.args[-3:-1] == ("remove", "--id")
    assert action.preview_args == (*action.args, "--dry-run")
    assert action.mutable and not action.elevated
    widget.findChild(QPushButton, "clearCustomCodexProfiles").click()
    assert actions[-1].args[-2:] == ("remove", "--all-custom")
    assert actions[-1].preview_args == (*actions[-1].args, "--dry-run")
    with patch.object(manager, "_removal_plan", side_effect=lambda row: {"row": row, "paths": []}):
        manager.remove(all_custom=True)
    widget.refresh()
    app.sendPostedEvents(None, QEvent.DeferredDelete)
    assert not widget.findChildren(QPushButton, "deleteCodexProfile")
    assert not widget.findChild(QPushButton, "clearCustomCodexProfiles").isEnabled()



def test_primary_icon_first_and_picker_excludes_used_colors(panel):
    widget, manager, a, b, app = panel
    badges = widget.findChildren(QLabel, "codexProfileBadge")
    assert badges[0].property("profileId") == "current"
    assert all(not badge.pixmap().isNull() for badge in badges)
    dialog = CodexProfileDialog(widget, unavailable={"azul", a["color"], b["color"]})
    available = {dialog.color.itemData(i) for i in range(dialog.color.count())}
    assert not available & {"azul", a["color"], b["color"]}
    primary = CodexProfileDialog(widget, manager.get("current"))
    assert primary.color.count() == 1 and not primary.color.isEnabled()
    primary.close()
    dialog.close()



def test_panel_and_logo_work_when_optional_qtsvg_module_is_unavailable(panel):
    import subprocess
    import sys
    code = """
import sys
sys.modules['PySide6.QtSvg'] = None
from PySide6.QtWidgets import QApplication
from linux.ui_native.codex_profiles_panel import _icon_pixmap
from linux.ai.codex_profiles import CodexProfiles
app = QApplication([])
m = CodexProfiles()
image = _icon_pixmap(m.icon_svg(m.get('current')), 128).toImage()
assert image.pixelColor(64, 30).alpha() > 0
assert image.pixelColor(0, 0).alpha() == 0
assert image.pixelColor(52, 64).alpha() == 0
"""
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
