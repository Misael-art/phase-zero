from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.ai_dev import AiDevPage
from linux.ui_native.pages.memory import STATUS_ID
from linux.ui_native.status_loader import StatusLoader
from linux.ui_native.widgets import ParameterDialog

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def page(monkeypatch):
    app = QApplication.instance() or QApplication([])
    monkeypatch.setattr(StatusLoader, "fetch", lambda *_a: None)
    catalog = build_catalog(ROOT)
    page = AiDevPage(ROOT, CommandRunner(ROOT), [a for a in catalog if a.category == "IA & Dev"],
                     by_id={a.id: a for a in catalog})
    page.build()
    yield page
    page.close()
    page.deleteLater()
    app.processEvents()


def test_unknown_state_cannot_mutate(page):
    assert page.memory_card.buttons["portability-status"].isEnabled()
    assert not page.memory_card.buttons["install"].isEnabled()
    assert not page.memory_card.buttons["sync"].isEnabled()


def test_installed_memory_uses_manual_sync_and_reflects_verified_backup(page):
    page._on_status_ready(STATUS_ID, "", {"installed": True, "service": "active", "keyConfigured": True,
        "automatic": True, "scopes": [{"project": "PhaseZero"}], "github": {"repository": "owner/private"},
        "sync": {"targets": [{"id": "github", "state": "current", "lastBackup": {"verifiedAt": "2026-11-01"}}]}})
    card = page.memory_card
    assert card.buttons["sync"].isEnabled()
    assert card.buttons["install"].isHidden()
    assert "2026-11-01" in card.targets.text()
    assert "PhaseZero" in card.details.text()
    requested = []
    page.action_requested.connect(requested.append)
    card.buttons["sync"].click()
    assert requested[0].id == "ai.memory-sync"
    page.block_while_running(True)
    card.update_status({"installed": True, "service": "active", "keyConfigured": True, "github": {}})
    assert not any(button.isEnabled() for button in card.buttons.values())


def test_failed_status_clears_readiness_and_backup_success_is_not_invented(page):
    page._on_status_failed(STATUS_ID, "timeout")
    assert not page.memory_card.buttons["repair"].isEnabled()
    page._on_status_ready(STATUS_ID, "", {"installed": True, "service": "active", "github": {"repository": "o/r"}})
    assert "ainda não" in page.memory_card.targets.text()
    assert not page.memory_card.buttons["sync"].isEnabled()


def test_locked_vault_status_never_claims_sync_current(page):
    page._on_status_ready(STATUS_ID, "", {"installed": True, "service": "active", "keyConfigured": True,
        "automatic": True, "github": {"repository": "owner/private"},
        "sync": {"state": "waiting-unlock", "synchronized": False,
                 "targets": [{"id": "github", "state": "waiting-unlock",
                              "lastBackup": {"verifiedAt": "2026-11-01"}}]}})
    assert "aguardando desbloqueio" in page.memory_card.state.text()
    assert "desbloqueie cofre" in page.memory_card.targets.text()
    assert "2026-11-01" in page.memory_card.targets.text()


def test_secret_parameters_never_reach_argv_and_restore_requires_plan(page):
    for name in ("key-export", "key-import"):
        action = page.by_id["ai.memory-" + name]
        assert action.stdin_parameter == "passphrase"
        assert "secret-value" not in action.resolved_args(values={"path": "/fixture/key.gpg", "passphrase": "secret-value"})
    restore = page.by_id["ai.memory-restore"]
    assert "restore-plan" in restore.preview_args
    assert restore.risk == "high"


def test_recovery_uses_save_dialog_for_new_file(page, monkeypatch, tmp_path):
    target = tmp_path / "recovery.gpg"
    monkeypatch.setattr("linux.ui_native.widgets.QFileDialog.getSaveFileName", lambda *_a: (str(target), "OpenPGP"))
    dialog = ParameterDialog(page.by_id["ai.memory-key-export"])
    assert page.by_id["ai.memory-key-export"].parameters[0].kind == "save-file"
    dialog._browse("save-file", dialog._fields["path"])
    assert dialog.values()["path"] == str(target)
    assert not target.exists()
    dialog.close()
