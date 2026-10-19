from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

import pytest

from linux.ai import chatgpt_project_mcp_manager as module


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    return root


def test_install_is_private_pinned_and_never_stages_a_key(repo: Path, tmp_path: Path,
                                                           monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    binary = b"verified fixture binary"
    monkeypatch.setattr(module, "BINARY_SHA256", hashlib.sha256(binary).hexdigest())
    monkeypatch.setattr(manager, "_active", lambda: False)
    monkeypatch.setattr(manager, "_install_binary", lambda: module._atomic(manager.binary,
                                                                          binary, 0o700))

    result = manager.install(str(repo), "tunnel_" + "a" * 32)

    assert result["installed"] and result["repo"] == str(repo)
    assert manager.server.read_bytes() == Path(module.__file__).with_name(
        "chatgpt_project_mcp.py").read_bytes()
    assert manager.manager.read_bytes() == Path(module.__file__).read_bytes()
    assert json.loads(manager.config.read_text())["serverSha256"] == module._digest(manager.server)
    assert manager.home.stat().st_mode & 0o777 == 0o700
    assert manager.server.stat().st_mode & 0o777 == 0o600
    assert manager.binary.stat().st_mode & 0o777 == 0o700
    assert not manager.runtime.exists()

    with pytest.raises(module.ManagerError, match="outro repositório/túnel"):
        manager.install(str(repo), "tunnel_" + "b" * 32)


def test_start_uses_secret_file_not_argv_and_stop_removes_it(repo: Path, tmp_path: Path,
                                                              monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    binary = b"verified fixture binary"
    monkeypatch.setattr(module, "BINARY_SHA256", hashlib.sha256(binary).hexdigest())
    monkeypatch.setattr(manager, "_active", lambda: False)
    monkeypatch.setattr(manager, "_install_binary", lambda: module._atomic(manager.binary,
                                                                          binary, 0o700))
    manager.install(str(repo), "tunnel_" + "a" * 32)

    class Vault:
        def lookup(self, reference):
            assert reference == "vault-ref"
            return "synthetic-runtime-secret"

    class Bridge:
        def load_state(self):
            return {"runtimeKey": {"ref": "vault-ref"}}

        def key_status(self, state):
            return {"state": "stored"}

        def secret_store(self):
            return Vault()

    monkeypatch.setattr(manager, "_bridge", lambda: Bridge())
    commands = []
    active = False

    def run(args, timeout=30):
        nonlocal active
        commands.append(args)
        if args[0] == "systemd-run":
            active = True
        if args[:3] == ["systemctl", "--user", "stop"]:
            active = False
        return subprocess.CompletedProcess(args, 0, "", "")

    monkeypatch.setattr(manager, "_run", run)
    monkeypatch.setattr(manager, "_active", lambda: active)
    monkeypatch.setattr(manager, "status", lambda: {"tunnelReady": active, "active": active})

    assert manager.start()["tunnelReady"] is True
    key = manager.runtime / "runtime-key"
    assert key.is_file() and key.stat().st_mode & 0o777 == 0o600
    assert all("synthetic-runtime-secret" not in " ".join(args) for args in commands)
    assert any("file:" + str(key) in args for args in commands)
    assert manager.stop() == {"active": False, "tunnelReady": False,
                              "runtimeKeyStaged": False}
    assert not key.exists()


def test_start_rejects_modified_server_before_retrieving_secret(repo: Path, tmp_path: Path,
                                                                 monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    binary = b"verified fixture binary"
    monkeypatch.setattr(module, "BINARY_SHA256", hashlib.sha256(binary).hexdigest())
    monkeypatch.setattr(manager, "_active", lambda: False)
    monkeypatch.setattr(manager, "_install_binary", lambda: module._atomic(manager.binary,
                                                                          binary, 0o700))
    manager.install(str(repo), "tunnel_" + "a" * 32)
    manager.server.write_text("tampered")
    monkeypatch.setattr(manager, "_bridge", lambda: pytest.fail("secret must not be retrieved"))

    with pytest.raises(module.ManagerError, match="servidor ausente ou alterado"):
        manager.start()
    assert not manager.runtime.exists()


def test_malformed_config_fails_without_starting_or_reading_secret(
        repo: Path, tmp_path: Path, monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    manager.home.mkdir()
    manager.config.write_text(json.dumps({"tunnelId": "tunnel_" + "a" * 32,
                                          "repo": "relative/path", "serverSha256": "invalid"}))
    monkeypatch.setattr(manager, "_active", lambda: False)
    monkeypatch.setattr(manager, "_bridge", lambda: pytest.fail("secret must not be retrieved"))

    with pytest.raises(module.ManagerError, match="configuração do projeto inválida"):
        manager.start()


def test_status_requires_both_tool_classes_from_current_tunnel_session(
        repo: Path, tmp_path: Path, monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    binary = b"verified fixture binary"
    monkeypatch.setattr(module, "BINARY_SHA256", hashlib.sha256(binary).hexdigest())
    monkeypatch.setattr(manager, "_active", lambda: True)
    module._atomic(manager.binary, binary, 0o700)
    module._atomic(manager.server, Path(module.__file__).with_name(
        "chatgpt_project_mcp.py").read_bytes())
    module._atomic(manager.config, json.dumps({
        "repo": str(repo), "tunnelId": "tunnel_" + "a" * 32,
        "serverSha256": module._digest(manager.server),
    }).encode())
    manager.runtime.mkdir(parents=True)
    (manager.runtime / "health.url").write_text("http://127.0.0.1:12345")

    class Ready:
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return None

    monkeypatch.setattr(module.urllib.request, "urlopen", lambda *args, **kwargs: Ready())
    proof = manager.runtime / "proof.json"
    module._atomic(proof, b'{"read":true}')
    assert manager.status()["toolCallProven"] is False
    module._atomic(proof, b'{"read":true,"write":true}')
    assert manager.status()["toolCallProven"] is True
    proof.chmod(0o644)
    assert manager.status()["toolCallProven"] is False


def test_key_recovers_from_kde_when_default_secret_service_has_no_item(
        tmp_path: Path, monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")

    class Vault:
        def lookup(self, reference):
            assert reference == "vault-ref"
            return None

    class Bridge:
        def load_state(self):
            return {"runtimeKey": {"ref": "vault-ref"}}

        def key_status(self, state):
            return {"state": "stored"}

        def secret_store(self):
            return Vault()

    monkeypatch.setattr(manager, "_bridge", lambda: Bridge())
    monkeypatch.setattr(module, "_kde_secret_lookup", lambda reference:
                        "recovered-secret" if reference == "vault-ref" else None)

    key = manager._key()
    assert key.read_text() == "recovered-secret"
    assert key.stat().st_mode & 0o777 == 0o600


def test_autostart_uses_stable_manager_retries_vault_and_preserves_foreign_entry(
        repo: Path, tmp_path: Path, monkeypatch) -> None:
    manager = module.Manager(tmp_path / "data", tmp_path / "run", tmp_path / "autostart")
    binary = b"verified fixture binary"
    monkeypatch.setattr(module, "BINARY_SHA256", hashlib.sha256(binary).hexdigest())
    monkeypatch.setattr(manager, "_active", lambda: False)
    monkeypatch.setattr(manager, "_install_binary", lambda: module._atomic(manager.binary,
                                                                          binary, 0o700))
    manager.install(str(repo), "tunnel_" + "a" * 32)

    assert manager.autostart_status()["state"] == "off"
    assert manager.autostart_enable()["state"] == "enabled"
    entry = manager.autostart.read_text()
    assert str(manager.manager) in entry
    assert "autostart-run" in entry
    assert "tunnel_" not in entry and "sk-" not in entry
    assert manager.autostart.stat().st_mode & 0o777 == 0o600

    attempts = []

    def start():
        attempts.append(1)
        if len(attempts) < 3:
            raise module.ManagerError("chave indisponível nos cofres GNOME/KDE")
        return {"tunnelReady": True}

    monkeypatch.setattr(manager, "start", start)
    monkeypatch.setattr(module.time, "sleep", lambda seconds: None)
    assert manager.autostart_run()["tunnelReady"] is True
    assert len(attempts) == 3
    assert manager.autostart_disable()["state"] == "off"

    manager.autostart.write_text("[Desktop Entry]\nExec=foreign\n")
    with pytest.raises(module.ManagerError, match="alterada"):
        manager.autostart_enable()
    with pytest.raises(module.ManagerError, match="alterada"):
        manager.autostart_disable()
    assert "foreign" in manager.autostart.read_text()
