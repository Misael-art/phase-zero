from __future__ import annotations

import configparser
import json
import os
from pathlib import Path

import pytest

from linux import cloud_drive


@pytest.fixture
def manager(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.delenv("XDG_RUNTIME_DIR", raising=False)
    monkeypatch.setattr(cloud_drive, "mounted_paths", dict)
    drive = cloud_drive.CloudDrive()
    drive.rclone = "rclone"
    drive.sockets = Path("/proc/self/phasezero-drive-fixture")
    return drive


def authorize_two(manager, monkeypatch, tmp_path):
    client_file = tmp_path / "google.json"
    client_file.write_text(json.dumps({"installed": {
        "client_id": "fixture.apps.googleusercontent.com", "client_secret": "desktop-fixture",
    }}))
    scopes = []

    def authorize(config):
        settings = configparser.ConfigParser()
        settings.read(config)
        scopes.append(settings["drive"]["scope"])
        assert config.stat().st_mode & 0o777 == 0o600

    identities = iter([("first", "leitura@example.invalid"), ("second", "edicao@example.invalid")])
    monkeypatch.setattr(manager, "complete_oauth", authorize)
    monkeypatch.setattr(cloud_drive, "account_identity", lambda _: next(identities))
    with manager.transaction():
        manager.set_client(str(client_file))
        reader = manager.authorize(None, False)["id"]
        writer = manager.authorize(None, True)["id"]
    assert scopes == ["drive.readonly", "drive"]
    return reader, writer


def test_authorization_scope_reopen_and_wrong_account_renewal(manager, monkeypatch, tmp_path):
    reader, writer = authorize_two(manager, monkeypatch, tmp_path)
    local = tmp_path / "Drive editável"
    with manager.transaction():
        mount = manager.add(writer, "folder_1", ["parent_folder"], "Projetos", str(local))["id"]
        restricted = manager.add(writer, "", [], "Arquivo", str(tmp_path / "Arquivo"), read_only=True)["id"]
        with pytest.raises(cloud_drive.DriveError, match="Remova as pastas"):
            manager.disconnect(writer)
    reopened = cloud_drive.CloudDrive()
    status = reopened.status()
    assert [row["email"] for row in status["accounts"]] == ["leitura@example.invalid", "edicao@example.invalid"]
    assert status["mounts"][0]["local"] == str(local)
    assert status["mounts"][0]["state"] == "unmounted"
    assert {row["id"]: row["write"] for row in status["mounts"]} == {mount: True, restricted: False}
    assert not local.exists()
    assert not {"identity", "client_secret", "token"} & status["accounts"][0].keys()
    old = manager.conf(reader).read_bytes()
    monkeypatch.setattr(cloud_drive, "account_identity", lambda _: ("other", "outra@example.invalid"))
    with manager.transaction(), pytest.raises(cloud_drive.DriveError, match="diferente"):
        manager.authorize(reader, False)
    assert old == manager.conf(reader).read_bytes()
    assert list(manager.config.glob("oauth-*")) == []
    assert manager.status()["mounts"][0]["id"] == mount


def test_cancelled_authorization_does_not_publish_account(manager, monkeypatch, tmp_path):
    reader, _ = authorize_two(manager, monkeypatch, tmp_path)

    def cancel(_config):
        raise KeyboardInterrupt

    old = manager.conf(reader).read_bytes()
    monkeypatch.setattr(manager, "complete_oauth", cancel)
    with manager.transaction(), pytest.raises(KeyboardInterrupt):
        manager.authorize(reader, False)
    assert manager.conf(reader).read_bytes() == old
    assert list(manager.config.glob("oauth-*")) == []
    assert len(manager.status()["accounts"]) == 2


def test_nonempty_symlink_and_overlapping_local_paths_are_rejected(manager, monkeypatch, tmp_path):
    reader, _ = authorize_two(manager, monkeypatch, tmp_path)
    target = tmp_path / "disco"
    target.mkdir()
    (target / "dados").write_text("preservar")
    link = tmp_path / "link"
    link.symlink_to(target)
    with manager.transaction():
        for destination, message in ((target, "pasta vazia"), (link, "links simbólicos")):
            with pytest.raises(cloud_drive.DriveError, match=message):
                manager.add(reader, "", [], "Meu Drive", str(destination))
        planned = tmp_path / "Montagem"
        manager.add(reader, "ABC", [], "Conta 1", str(planned))
        with pytest.raises(cloud_drive.DriveError, match="se sobrepõe"):
            manager.add(reader, "DEF", [], "Conta 2", str(planned / "Aninhada"))
    assert (target / "dados").read_text() == "preservar"


def test_unmount_only_controls_owned_fuse_and_waits_for_writeback(manager, monkeypatch, tmp_path):
    _, writer = authorize_two(manager, monkeypatch, tmp_path)
    local = tmp_path / "montagem"
    local.mkdir()
    mount = manager.add(writer, "", [], "Meu Drive", str(local))["id"]
    manager.fusermount = "/usr/bin/fusermount3"
    active = {local: ("fuse.rclone", "manual", {f"user_id={os.getuid()}"})}
    monkeypatch.setattr(cloud_drive, "mounted_paths", lambda: active)
    with pytest.raises(cloud_drive.DriveError, match="não controla"):
        manager.unmount(mount)
    active[local] = ("fuse.rclone", f"phasezero-drive-{mount}", {f"user_id={os.getuid()}"})
    transfers = {"uploadsQueued": 1, "uploadsInProgress": 0, "erroredFiles": 0}
    monkeypatch.setattr(manager, "run", lambda *args, **kwargs: json.dumps({"inUse": 1, "diskCache": transfers}))

    def detach(argv, **_):
        assert argv[1:] == ["-u", "--", str(local)]
        active.clear()
        return type("Result", (), {"returncode": 0})()

    monkeypatch.setattr(cloud_drive.subprocess, "run", detach)
    with pytest.raises(cloud_drive.DriveError, match="envios pendentes"):
        manager.unmount(mount)
    assert local in active
    transfers["uploadsQueued"] = 0
    assert manager.unmount(mount) == {"pending": False}
    assert not active


def test_dirty_cache_blocks_removing_mount_and_disconnecting_account(manager, monkeypatch, tmp_path):
    _, writer = authorize_two(manager, monkeypatch, tmp_path)
    local = tmp_path / "mount"
    mount = manager.add(writer, "", [], "Meu Drive", str(local))["id"]
    metadata = manager.state / mount / "vfsMeta" / "drive" / "document"
    metadata.parent.mkdir(parents=True)
    metadata.write_text('{"Dirty": true}')
    with manager.transaction():
        with pytest.raises(cloud_drive.DriveError, match="contém gravações"):
            manager.remove(mount)
        with pytest.raises(cloud_drive.DriveError, match="Remova as pastas"):
            manager.disconnect(writer)
        assert metadata.exists()
        metadata.write_text('{"Dirty": false}')
        manager.remove(mount)
        manager.disconnect(writer)
    assert not metadata.exists()
    assert not manager.conf(writer).exists()


def test_cli_status_does_not_create_storage(manager, capsys, monkeypatch):
    monkeypatch.setattr(cloud_drive.os, "geteuid", lambda: 1000)
    assert cloud_drive.main(["status"]) == 0
    assert json.loads(capsys.readouterr().out)["accounts"] == []
    assert not manager.state.exists()
    assert not manager.config.exists()


def test_resource_journey_browses_and_reopens_a_mounted_folder(monkeypatch, tmp_path):
    from PySide6.QtCore import QTimer, Qt
    from PySide6.QtTest import QTest
    from PySide6.QtWidgets import QApplication

    from linux.ui_native import cloud_drive_panel as ui
    from linux.ui_native.catalog import build_catalog
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.pages.workspace import ResourcesPage

    app = QApplication.instance() or QApplication([])
    root = Path(__file__).resolve().parents[1]
    account = {"id": "a" * 16, "email": "drive@example.invalid", "write": False, "configured": True}
    mount_id = "b" * 16
    local = str(tmp_path / "Pasta local")
    state = {"ok": True, "clientConfigured": True, "rclone": True, "fuse": True,
             "accounts": [account], "mounts": []}
    calls = []

    def dispatch(_commands, args, callback):
        calls.append(args)
        match args:
            case ["status"]:
                result = state
            case ["folders", _, "--folder="]:
                result = {"ok": True, "folders": [{"id": "projects", "name": "Projetos"}]}
            case ["folders", _, "--folder=projects"]:
                result = {"ok": True, "folders": []}
            case ["add", _, "--folder=projects", "--label=Projetos", path]:
                assert path == f"--local={local}"
                state["mounts"].append(
                    {"id": mount_id, "account": account["id"], "label": "Projetos", "local": local,
                     "state": "unmounted"}
                )
                result = {"ok": True, "id": mount_id}
            case ["mount", _]:
                state["mounts"][0]["state"] = "mounted"
                result = {"ok": True}
            case ["unmount", _]:
                state["mounts"][0]["state"] = "unmounted"
                result = {"ok": True}
            case _:
                raise AssertionError(args)
        callback(result)

    monkeypatch.setattr(ui.DriveCommands, "start", dispatch)
    opened = []
    monkeypatch.setattr(ui.QDesktopServices, "openUrl", lambda url: opened.append(url.toLocalFile()) or True)
    actions = [action for action in build_catalog(root) if action.category == "Recursos"]
    page = ResourcesPage(root, CommandRunner(root), actions)
    page.build()
    page.resize(570, 540)
    page.show()
    next(button for button in page.rail.buttons if button.text() == "Backup e nuvem").click()
    app.processEvents()
    panel = page.findChild(ui.CloudDrivePanel)
    assert panel.add.isEnabled()
    assert page.stack.currentWidget().horizontalScrollBar().maximum() == 0

    def choose():
        setup = panel.findChild(ui.FolderSetup)
        setup.folders.setFocus()
        setup.folders.setCurrentRow(0)
        QTest.keyClick(setup.folders, Qt.Key.Key_Return)
        setup.local.setText(local)
        QTest.mouseClick(setup.save_button, Qt.MouseButton.LeftButton)

    QTimer.singleShot(0, choose)
    QTest.mouseClick(panel.add, Qt.MouseButton.LeftButton)
    assert panel.mounts.currentItem().text() == "Projetos · Montada · drive@example.invalid"
    assert calls[-2:] == [["mount", mount_id], ["status"]]
    page.hide()
    page.show()
    app.processEvents()
    assert panel.change_mount.text() == "Desmontar"
    panel.open.click()
    assert opened == [local]
    panel.change_mount.click()
    assert panel.mounts.currentItem().text() == "Projetos · Desmontada · drive@example.invalid"
    page.close()
