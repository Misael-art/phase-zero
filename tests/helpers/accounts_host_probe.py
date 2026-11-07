"""Opt-in host smoke: owned dummy OS-vault key and existing real Harness.

Run only with private XDG/PZ_DSH_ROOT directories and an installed runtime.
Does not log in, send inference or touch the operator's registry/processes.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import socket
import sys
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from PySide6.QtCore import QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialog, QMessageBox, QPushButton

from linux.ai import deepseek_harness_manager as harness
from linux.ai.credential_vault import CredentialVault, credential_vault_path
from linux.ui_native.main_window import MainWindow
from linux.ui_native.pages.accounts import AddApiCredentialDialog
from linux.ui_native.status_loader import StatusLoader


source = Path(sys.argv[1]).resolve(strict=True)
receipt = Path(sys.argv[2])
test_root = receipt.parent.resolve(strict=True)
for name in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "PZ_DSH_ROOT"):
    assert Path(os.environ[name]).resolve().is_relative_to(test_root), f"{name} must be isolated"
assert not source.is_relative_to(test_root)
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    os.environ["PZ_DSH_PORT"] = str(probe.getsockname()[1])
runtime = harness.install_root() / "existing-runtime-probe"
runtime.mkdir(parents=True, mode=0o700)
for component in ("node", "app"):
    (runtime / component).symlink_to(source / component, target_is_directory=True)
pins = harness._read_pins()
harness._atomic_json(harness.active_file(), {
    "schemaVersion": 1, "version": pins["harness"]["version"],
    "nodeVersion": pins["node"]["version"], "runtimePath": runtime.name,
})
workspace = test_root / "project"
workspace.mkdir(mode=0o700)
app = QApplication([])
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"), \
        patch("linux.ui_native.pages.homelab.HomelabPage.refresh_hosts", lambda _self: None), \
        patch("linux.ui_native.pages.linux_hub.LinuxHubPage.reload", lambda _self: None):
    window = MainWindow(Path(__file__).resolve().parents[2], initial_category="Contas e conexões")
window.show()
page = window.registry.page_for("Contas e conexões")
assert page.credential_vault is not None and not page.credential_vault.entries
entry = None
record = {"schemaVersion": 1, "nativeVault": False, "realHarness": False, "managedUsage": False,
          "revokedUse": False, "stoppedBeforeRemoval": False, "nativeDeletion": False, "inferenceSent": False}


def wait_operation():
    deadline = time.monotonic() + 20
    while page._credential_busy and time.monotonic() < deadline:
        QTest.qWait(20)
    assert not page._credential_busy, "credential operation timed out"


def fill_owned_key():
    dialog = app.activeModalWidget()
    assert isinstance(dialog, AddApiCredentialDialog)
    dialog.provider.setText("deepseek")
    dialog.nickname.setText("PhaseZero owned host probe")
    dialog.secret.setText("pz-owned-invalid-test-" + secrets.token_hex(24))
    dialog.findChild(QPushButton, "saveApiCredential").click()


try:
    QTimer.singleShot(80, fill_owned_key)
    page.findChild(QPushButton, "registerApiCredential").click()
    wait_operation()
    entry, = page.credential_vault.entries
    assert entry.state == "active"
    record["nativeVault"] = True
    started = harness.start(str(workspace), "api", credential_id=entry.account_id)
    assert started["runtimeState"] == "running"
    record["realHarness"] = True
    record["harnessVersion"] = started["installedVersion"]
    page.findChild(QPushButton, "observeCredentialUses").click()
    wait_operation()
    use, = page._credential_uses
    assert use.account_id == entry.account_id and use.running and use.project == str(workspace)
    record["managedUsage"] = True
    page.credential_manager.table.cellWidget(0, 6).click()
    QTest.qWait(80)

    def confirm_owned_action():
        dialog = app.activeModalWidget()
        assert isinstance(dialog, QMessageBox)
        dialog.button(QMessageBox.Yes).click()

    QTimer.singleShot(80, confirm_owned_action)
    page.findChild(QPushButton, "revokeApiCredentialUse").click()
    wait_operation()
    assert harness.status_payload()["runtimeState"] == "stopped"
    assert page.credential_vault.entries == (entry,)
    assert harness.status_payload()["apiCredentialId"] == ""
    record["revokedUse"] = True
    # Explicitly select the same owned key again to exercise removal while live.
    assert harness.start(str(workspace), "api", credential_id=entry.account_id)["runtimeState"] == "running"
    QTest.qWait(80)
    QTimer.singleShot(80, confirm_owned_action)
    page.findChild(QPushButton, "removeApiCredential").click()
    wait_operation()
    assert not page.credential_vault.entries
    assert harness.status_payload()["runtimeState"] == "stopped"
    record["stoppedBeforeRemoval"] = True
    assert page.credential_vault.secret_store.lookup(entry.secret_ref) is None
    record["nativeDeletion"] = True
    assert not CredentialVault(credential_vault_path()).entries
finally:
    # Scoped to the fixture root checked above; never stop a production manager.
    try:
        harness._stop_supervisor()
        if entry and any(item.account_id == entry.account_id for item in page.credential_vault.entries):
            page.credential_vault.remove(entry.account_id)
    finally:
        window.close()
        window.deleteLater()
        QTest.qWait(80)
        receipt.write_text(json.dumps(record, indent=2) + "\n")
        receipt.chmod(0o600)
print("owned native-vault / real-Harness journey passed")
