from __future__ import annotations

import json

import pytest

pytest.importorskip("PySide6")
from PySide6.QtWidgets import QApplication

from linux.ui_native import vibe_code
from linux.ui_native.vibe_apps import AppEntry, Shortcut, desktop_available


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_select_launch_and_resume_project_without_shell(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    project = tmp_path / "projeto com espaços ; $(echo ignorado)"
    project.mkdir()
    monkeypatch.setattr(vibe_code.QFileDialog, "getExistingDirectory", lambda *_: str(project))
    monkeypatch.setattr(vibe_code.shutil, "which", lambda name: f"/mock/{name}")
    calls = []

    def launch(*args):
        calls.append(args)
        return True, 42

    monkeypatch.setattr(vibe_code.QProcess, "startDetached", launch)
    first = vibe_code.VibeCodeDialog()
    assert not first.open_editor.isEnabled()
    first.choose_folder.click()
    assert first.open_editor.isEnabled()
    assert calls == []
    first.editor.setCurrentIndex(1)
    first.open_editor.click()
    first.project_tools[0].click()
    assert calls == [
        ("/mock/codium", [str(project)], str(project)),
        ("/usr/bin/env", [f"PWD={project}", "/mock/konsole", "--separate", "--workdir", str(project)], str(project)),
    ]
    assert first.state.stat().st_mode & 0o777 == 0o600
    first.close()
    reopened = vibe_code.VibeCodeDialog()
    assert reopened.project == project
    assert reopened.editor.currentData() == "codium"


def test_project_disappears_after_selection_and_can_be_replaced(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    project = tmp_path / "disco desmontado"
    project.mkdir()
    dialog = vibe_code.VibeCodeDialog()
    monkeypatch.setattr(vibe_code.QFileDialog, "getExistingDirectory", lambda *_: str(project))
    dialog.choose_folder.click()
    project.rmdir()
    dialog.open_editor.click()
    assert not dialog.open_editor.isEnabled()
    assert "Pasta indisponível" in dialog.status.text()
    assert json.loads(dialog.state.read_text())["folder"] == str(project)
    other = tmp_path / "outro"
    other.mkdir()
    monkeypatch.setattr(vibe_code.QFileDialog, "getExistingDirectory", lambda *_: str(other))
    dialog.choose_folder.click()
    assert dialog.project == other
    assert dialog.open_editor.isEnabled()
    assert not dialog.status.text()


def test_invalid_state_and_unavailable_tool_leave_launcher_usable(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    state = vibe_code.state_dir() / "vibe-code.json"
    state.parent.mkdir(parents=True)
    state.write_text("[]")
    dialog = vibe_code.VibeCodeDialog()
    assert "Não foi possível ler" in dialog.status.text()
    monkeypatch.setattr(vibe_code.QFileDialog, "getExistingDirectory", lambda *_: str(tmp_path))
    dialog.choose_folder.click()
    monkeypatch.setattr(vibe_code.shutil, "which", lambda _name: None)
    dialog.open_editor.click()
    assert "indisponível" in dialog.status.text()
    assert dialog.choose_folder.isEnabled()
    assert dialog.project == tmp_path


def test_autostart_owns_only_its_plasma_entry(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    desktop = tmp_path / "data/applications" / vibe_code.DESKTOP_ENTRY
    desktop.parent.mkdir(parents=True)
    desktop.write_text("[Desktop Entry]\nExec=/fixture --vibe-code\nX-PhaseZero-Managed=true\n")
    dialog = vibe_code.VibeCodeDialog()
    assert not dialog.autostart.isChecked()
    dialog.autostart.click()
    assert "OnlyShowIn=KDE;" in dialog.autostart_path.read_text()
    assert vibe_code.AUTOSTART_MARKER in dialog.autostart_path.read_text()
    dialog.close()
    reopened = vibe_code.VibeCodeDialog()
    assert reopened.autostart.isChecked()
    reopened.autostart.click()
    assert not reopened.autostart_path.exists()
    reopened.autostart_path.write_text("existing custom entry\n")
    reopened.autostart.click()
    assert not reopened.autostart.isChecked()
    assert reopened.autostart_path.read_text() == "existing custom entry\n"


def test_preview_uses_desktop_browser_without_a_project(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    dialog = vibe_code.VibeCodeDialog()
    seen = []
    monkeypatch.setattr(vibe_code.QDesktopServices, "openUrl", lambda url: seen.append(url.toString()) or True)
    monkeypatch.setattr(vibe_code.QInputDialog, "getText", lambda *_: ("file:///etc/passwd", True))
    dialog._open_browser()
    assert seen == []
    assert "endereço completo" in dialog.status.text()
    monkeypatch.setattr(vibe_code.QInputDialog, "getText", lambda *_: ("http://localhost:9012/", True))
    dialog._open_browser()
    assert seen == ["http://localhost:9012/"]


def test_app_menu_search_and_click_use_the_installed_launcher(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    calls = []

    class DesktopEntry:
        def get_icon(self):
            return None

        def launch(self, files, context):
            calls.append((files, context))
            return True

    desktop = AppEntry(Shortcut("Codex Desktop", "Aplicativo principal"), DesktopEntry())
    missing = AppEntry(Shortcut("Claude Desktop", "Aplicativo principal", product="app.claude-desktop"))
    monkeypatch.setattr(vibe_code, "read_apps", lambda: ([desktop, missing], [], True))
    dialog = vibe_code.VibeCodeDialog()
    assert calls == []
    dialog.tabs.setCurrentIndex(1)
    dialog.search.setText("codex")
    assert dialog.app_list.count() == 1
    dialog.app_action.click()
    assert calls == [([], None)]
    assert "Codex Desktop" in dialog.status.text()
    products = []
    dialog.product_requested.connect(products.append)
    dialog.search.setText("claude")
    dialog.app_action.click()
    assert products == ["app.claude-desktop"]


def test_desktop_probe_accepts_quoted_executable(tmp_path):
    executable = tmp_path / "atalho com espaços"
    executable.touch(mode=0o755)

    class DesktopEntry:
        def get_executable(self):
            return f'"{executable}"'

        def get_commandline(self):
            return f'"{executable}" --journey grok-build'

    assert desktop_available(DesktopEntry())
    executable.unlink()
    assert not desktop_available(DesktopEntry())
