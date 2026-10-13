from __future__ import annotations

import io
import json
import tarfile
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.installation import manager
from linux.installation.manager import InstallationError
from linux.installation.self_update import _safe_extract, _version_tuple


def account(home: Path):
    return ("tester", 1000, 1000, home)


def test_status_reports_channel_and_root_conflicts(tmp_path, monkeypatch):
    home = tmp_path / "home"
    current = home / ".local/share/phasezero/current"
    current.mkdir(parents=True)
    (current / "version.json").write_text('{"version":"2.0.0"}', encoding="utf-8")
    root_a = tmp_path / "usr-lib"
    root_b = tmp_path / "usr-lib64"
    for root in (root_a, root_b):
        root.mkdir()
        (root / "version.json").write_text('{"version":"1.0.0"}', encoding="utf-8")
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    monkeypatch.setattr(manager, "SYSTEM_ROOTS", (root_a, root_b))
    monkeypatch.setattr(manager, "_native_package", lambda: {
        "installed": True, "manager": "pacman", "version": "1.0.0-1", "alteredFiles": 4,
    })
    monkeypatch.setattr(manager, "_flatpak", lambda scope: {
        "installed": scope == "user", "scope": scope, "version": "2.0.0" if scope == "user" else "",
    })
    monkeypatch.setattr(manager.shutil, "which", lambda _command: None)
    payload = manager.status()
    assert payload["status"] == "conflict"
    assert payload["activeChannels"] == ["user", "native", "flatpak-user"]
    assert len(payload["conflicts"]) == 3
    assert payload["command"] == ""


def test_status_ignores_caller_xdg_data_home_when_elevated(tmp_path, monkeypatch):
    """Elevated runs must inspect the target account, not the caller's.

    sudo/pkexec keep XDG_DATA_HOME pointing at the invoking account, so
    honouring it blindly hides a user install that is really there.
    """
    home = tmp_path / "home"
    current = home / ".local/share/phasezero/current"
    current.mkdir(parents=True)
    (current / "version.json").write_text('{"version":"2.0.0"}', encoding="utf-8")
    monkeypatch.setenv("HOME", "/root")
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "root-data"))
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    monkeypatch.setattr(manager, "SYSTEM_ROOTS", ())
    monkeypatch.setattr(manager, "_native_package", lambda: {
        "installed": False, "manager": "", "version": "", "alteredFiles": 0,
    })
    monkeypatch.setattr(manager, "_flatpak", lambda scope: {
        "installed": False, "scope": scope, "version": "",
    })
    monkeypatch.setattr(manager.shutil, "which", lambda _command: None)
    payload = manager.status()
    assert payload["activeChannels"] == ["user"]
    assert payload["user"] == {
        "installed": True, "version": "2.0.0", "root": str(current.resolve()),
    }


def test_status_honours_xdg_data_home_of_the_running_account(tmp_path, monkeypatch):
    home = tmp_path / "home"
    data_home = tmp_path / "custom-data"
    current = data_home / "phasezero/current"
    current.mkdir(parents=True)
    (current / "version.json").write_text('{"version":"3.1.0"}', encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_DATA_HOME", str(data_home))
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    monkeypatch.setattr(manager, "SYSTEM_ROOTS", ())
    monkeypatch.setattr(manager, "_native_package", lambda: {
        "installed": False, "manager": "", "version": "", "alteredFiles": 0,
    })
    monkeypatch.setattr(manager, "_flatpak", lambda scope: {
        "installed": False, "scope": scope, "version": "",
    })
    monkeypatch.setattr(manager.shutil, "which", lambda _command: None)
    assert manager.status()["user"]["version"] == "3.1.0"


def test_status_prefers_target_user_launcher_when_root_path_cannot_see_it(tmp_path, monkeypatch):
    home = tmp_path / "home"
    current = home / ".local/share/phasezero/current"
    current.mkdir(parents=True)
    (current / "version.json").write_text('{"version":"2.0.0"}', encoding="utf-8")
    launcher = home / ".local/bin/phasezero-control-center"
    launcher.parent.mkdir(parents=True)
    launcher.write_text("#!/bin/sh\n", encoding="utf-8")
    launcher.chmod(0o755)
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    monkeypatch.setattr(manager, "_native_package", lambda: {
        "installed": False, "manager": "", "version": "", "alteredFiles": 0,
    })
    monkeypatch.setattr(manager, "_flatpak", lambda scope: {
        "installed": False, "scope": scope, "version": "",
    })
    monkeypatch.setattr(manager, "SYSTEM_ROOTS", ())
    monkeypatch.setattr(manager.shutil, "which", lambda _command: None)
    assert manager.status()["command"] == str(launcher)


def test_status_deduplicates_system_root_aliases(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    root = tmp_path / "usr-lib"
    root.mkdir()
    (root / "version.json").write_text('{"version":"2.0.0"}', encoding="utf-8")
    alias = tmp_path / "usr-lib64"
    alias.symlink_to(root, target_is_directory=True)
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    monkeypatch.setattr(manager, "SYSTEM_ROOTS", (root, alias))
    monkeypatch.setattr(manager, "_native_package", lambda: {
        "installed": False, "manager": "", "version": "", "alteredFiles": 0,
    })
    monkeypatch.setattr(manager, "_flatpak", lambda scope: {
        "installed": False, "scope": scope, "version": "",
    })
    monkeypatch.setattr(manager.shutil, "which", lambda _command: None)
    payload = manager.status()
    assert payload["status"] == "ok"
    assert payload["systemRoots"][1]["aliasOf"] == str(root)


def test_plan_is_private_and_never_removes_user_channel(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(manager, "status", lambda: {
        "user": {"installed": True, "version": "2.0.0"},
        "native": {"installed": True, "manager": "pacman"},
        "flatpaks": [{"installed": True, "scope": "user"}],
        "systemRoots": [{"exists": True, "path": "/usr/lib/phasezero"}],
    })
    plan = manager.create_plan()
    assert all(action.get("kind") != "remove-user" for action in plan["actions"])
    record = tmp_path / "state/installation-plans" / f"{plan['id']}.json"
    assert record.stat().st_mode & 0o777 == 0o600


def test_elevated_apply_rejects_tampered_root(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(manager.os, "geteuid", lambda: 0)
    plan = {
        "schema": manager.SCHEMA,
        "kind": "installation-plan",
        "id": "plan-tampered",
        "createdAt": int(manager.time.time()),
        "confirmToken": "token",
        "actions": [{"kind": "backup-remove-system-root", "path": "/home"}],
    }
    from linux.capabilities import state

    state.save("installation-plans", plan["id"], plan)
    with pytest.raises(InstallationError, match="adulterada"):
        manager.apply(plan["id"], "token")


def test_prune_keeps_bounded_history_per_category(tmp_path, monkeypatch):
    home = tmp_path / "home"
    monkeypatch.setattr(manager, "_target_account", lambda: account(home))
    releases = home / ".local/share/phasezero/releases"
    backups = home / ".local/share/phasezero/backups"
    results = home / ".local/state/phasezero/control-center/results"
    mcp = home / ".local/state/phasezero/backups/ai-mcp"
    agent_compat = home / ".local/state/phasezero/ai/backups/agent-compat"
    for directory in (releases, backups, results, mcp, agent_compat):
        directory.mkdir(parents=True)
    for index in range(7):
        (releases / str(index)).mkdir()
        (backups / str(index)).mkdir()
    for index in range(260):
        (results / f"{index:03}.json").write_text("{}", encoding="utf-8")
    for index in range(9):
        (mcp / f"config.bak.{index:03}").write_text("x", encoding="utf-8")
        (agent_compat / f"AGENTS.md.bak.{index:03}").write_text("x", encoding="utf-8")
    payload = manager.prune()
    assert payload["removedCount"] > 0
    assert len(list(releases.iterdir())) == 3
    assert len(list(backups.iterdir())) == 3
    assert len(list(results.iterdir())) == 250
    assert len(list(mcp.iterdir())) == 5
    assert len(list(agent_compat.iterdir())) == 5


def test_safe_source_extract_rejects_links_and_traversal(tmp_path):
    archive = tmp_path / "bad.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        link = tarfile.TarInfo("PhaseZero/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "/etc/passwd"
        output.addfile(link)
    with pytest.raises(InstallationError, match="inseguro"):
        _safe_extract(archive, tmp_path / "extract")


def test_semver_comparison_never_downgrades():
    assert _version_tuple("1.7.1") > _version_tuple("1.7.0")
    assert not (_version_tuple("1.7.0") > _version_tuple("1.7.1"))
