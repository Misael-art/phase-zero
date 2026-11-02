import io
import json
from pathlib import Path
import subprocess
import tarfile

import pytest

from linux.ai import memory_manager as memory


class Vault:
    def __init__(self):
        self.values = {}

    def store(self, reference, value):
        self.values[reference] = value

    def lookup(self, reference):
        return self.values.get(reference)


@pytest.fixture
def manager(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    for name, path in {"HOME": home, "XDG_CONFIG_HOME": home / ".config",
                       "XDG_STATE_HOME": home / ".local/state", "AI_MEMORY_DATA_DIR": home / "memory",
                       "GNUPGHOME": home / ".gnupg"}.items():
        monkeypatch.setenv(name, str(path))
    (home / ".gnupg").mkdir(mode=0o700)
    monkeypatch.setenv("AI_MEMORY_BIN", "/bin/echo")
    result = memory.Manager(vault=Vault())
    result.initialize()
    yield result
    subprocess.run(["gpgconf", "--kill", "gpg-agent"], check=False, capture_output=True)


def scope_files(manager, tmp_path):
    directory = tmp_path / "pages"
    (directory / "decisions").mkdir(parents=True)
    page = directory / "decisions/one.md"
    page.write_text("---\nsource_host: host-original\nregistered_at: 2026-01-02T03:04:05Z\n---\n# Knowledge\n")
    scope = {"id": "a" * 64, "workspace": "default", "project": "same-name",
             "families": ["decisions"], "directory": directory, "provenance": {}}
    manager.config["scopes"] = [{k: v for k, v in scope.items() if k not in {"directory", "provenance"}}]
    manager.save()
    return scope, page


def test_key_is_only_in_os_vault_and_status_does_not_decrypt(manager, monkeypatch):
    value = manager.password()
    assert value not in manager.config_path.read_text()
    monkeypatch.setattr(manager.vault, "lookup", lambda _: pytest.fail("read-only status opened vault"))
    monkeypatch.setattr(memory, "run", lambda *a, **k: subprocess.CompletedProcess([], 0, b"active", b""))
    monkeypatch.setattr(memory, "urlopen", lambda *_a, **_k: (_ for _ in ()).throw(OSError("fixture offline")))
    assert manager.status()["keyConfigured"] is True


def test_encrypted_snapshot_preserves_body_and_rejects_wrong_key(manager, tmp_path):
    scope, page = scope_files(manager, tmp_path)
    stage = tmp_path / "stage"
    stage.mkdir()
    blob, manifest = manager.snapshot("knowledge", stage, scope=scope, files=[page])
    assert b"host-original" not in blob.read_bytes()
    root, verified = manager.verify(blob, tmp_path / "read")
    assert (root / "payload/decisions/one.md").read_bytes() == page.read_bytes()
    assert verified["sourceHost"]["id"] == manager.config["hostId"]
    assert verified["createdAt"] == manifest["createdAt"]
    manager.vault.store(manager.config["keyRef"], "another-secret-that-cannot-decrypt")
    with pytest.raises(memory.MemoryError):
        manager.verify(blob, tmp_path / "wrong-key")


@pytest.mark.parametrize("name,kind", [("../escape", "file"), ("/absolute", "file"),
                                     ("payload/link", "symlink"), ("payload/hard", "hardlink"),
                                     ("C:/escape", "file"), ("payload\\escape", "file")])
def test_archive_validates_before_any_extraction(tmp_path, name, kind):
    archive = tmp_path / "invalid.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        good = tarfile.TarInfo("good")
        good.size = 1
        tar.addfile(good, io.BytesIO(b"x"))
        bad = tarfile.TarInfo(name)
        if kind == "symlink":
            bad.type = tarfile.SYMTYPE
            bad.linkname = "../../escape"
        elif kind == "hardlink":
            bad.type = tarfile.LNKTYPE
            bad.linkname = "good"
        tar.addfile(bad)
    with pytest.raises(memory.MemoryError):
        memory.unpack(archive, tmp_path / "output")
    assert not (tmp_path / "output/good").exists()


def test_atomic_write_refuses_symlink_ancestor(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    link = tmp_path / "link"
    link.symlink_to(real, target_is_directory=True)
    with pytest.raises(memory.MemoryError):
        memory.atomic(link / "file", b"danger")
    assert not (real / "file").exists()


def test_lock_does_not_delete_another_workers_lock(tmp_path):
    path = tmp_path / "worker.lock"
    with memory.locked(path):
        with pytest.raises(memory.MemoryError, match="operation-busy"):
            with memory.locked(path):
                pytest.fail("concurrent writer")
    with memory.locked(path):
        assert path.exists()


def test_device_publish_preserves_exclusive_files_and_detects_corruption(manager, tmp_path, monkeypatch):
    mount = tmp_path / "usb"
    mount.mkdir()
    monkeypatch.setattr(manager, "volumes", lambda: [{"id": "volume-uuid", "path": str(mount)}])
    device = manager.device_enroll(str(mount))["device"]
    root = manager.device_root(device)
    exclusive = root / "knowledge/other-host/only-copy.txt"
    exclusive.parent.mkdir(parents=True)
    exclusive.write_text("keep")
    blob = tmp_path / "object.gpg"
    blob.write_bytes(b"opaque-encrypted-fixture")
    manager.device_publish(device, blob, "backup")
    assert exclusive.read_text() == "keep"
    destination = root / "backup" / manager.config["hostId"]
    pointer = json.loads((destination / "latest.json").read_text())
    object_path = destination / (pointer["sha256"] + ".gpg")
    assert object_path.read_bytes() == blob.read_bytes()
    before = (destination / "latest.json").read_bytes()
    object_path.write_bytes(b"damaged")
    with pytest.raises(memory.MemoryError, match="damaged"):
        manager.device_publish(device, blob, "backup")


def test_unchanged_knowledge_does_not_evict_meaningful_device_versions(manager, tmp_path, monkeypatch):
    mount = tmp_path / "usb"
    mount.mkdir()
    monkeypatch.setattr(manager, "volumes", lambda: [{"id": "volume-id", "path": str(mount)}])
    device = manager.device_enroll(str(mount))["device"]
    first = tmp_path / "first.gpg"
    first.write_bytes(b"first-randomized-ciphertext")
    scope = {"id": "a" * 64}
    manager.device_publish(device, first, "knowledge", scope, "same-plaintext-hash")
    directory = manager.device_root(device) / "knowledge" / manager.config["hostId"] / scope["id"]
    pointer = (directory / "latest.json").read_bytes()
    second = tmp_path / "second.gpg"
    second.write_bytes(b"second-randomized-ciphertext-same-content")
    assert manager.device_publish(device, second, "knowledge", scope, "same-plaintext-hash") == "unchanged"
    assert len(list(directory.glob("*.gpg"))) == 1
    assert (directory / "latest.json").read_bytes() == pointer


def test_device_identity_change_and_unplug_cannot_publish(manager, tmp_path, monkeypatch):
    mount = tmp_path / "usb"
    mount.mkdir()
    volumes = [{"id": "a", "path": str(mount)}]
    monkeypatch.setattr(manager, "volumes", lambda: volumes)
    device = manager.device_enroll(str(mount))["device"]
    volumes[0]["id"] = "b"
    with pytest.raises(memory.MemoryError, match="offline"):
        manager.device_root(device)


def test_github_refuses_public_repo_and_changed_identity(manager, monkeypatch):
    config = {"repository": "owner/memory", "repositoryId": 4}
    for payload in ({"id": 4, "private": False}, {"id": 5, "private": True}):
        monkeypatch.setattr(manager, "gh", lambda *_args, **_kwargs: payload)
        with pytest.raises(memory.MemoryError, match="identity-or-privacy"):
            manager.github_validate(config)


def test_same_github_key_does_not_clone_host_identity(manager, tmp_path):
    host_id = manager.config["hostId"]
    key = manager.password()
    key_path = tmp_path / "recovery.gpg"
    manager.recovery("key-export", key_path, "long recovery passphrase")
    manager.config["hostId"] = "second-host"
    manager.config["memoryId"] = "new-memory"
    manager.vault.store(manager.config["keyRef"], "other-secret")
    manager.recovery("key-import", key_path, "long recovery passphrase")
    assert manager.config["hostId"] == "second-host"
    assert manager.config["hostId"] != host_id
    assert manager.password() == key


def test_import_refuses_foreign_scope_before_companion(manager, tmp_path, monkeypatch):
    scope, page = scope_files(manager, tmp_path)
    stage = tmp_path / "snapshot"
    stage.mkdir()
    blob, _ = manager.snapshot("knowledge", stage, scope=scope, files=[page])
    monkeypatch.setattr(manager, "companion_run", lambda *_a, **_k: pytest.fail("foreign import"))
    with pytest.raises(memory.MemoryError, match="scope"):
        manager.import_knowledge(blob, {**scope, "id": "b" * 64}, manager.config["hostId"], tmp_path / "import")


def test_conflict_stops_apply_and_reports_failure(manager, tmp_path, monkeypatch):
    manager.config["github"] = {"repository": "owner/memory"}
    def fail(*_args, **_kwargs):
        raise memory.MemoryError("knowledge-conflict-review-required")
    monkeypatch.setattr(manager, "github_pull", fail)
    monkeypatch.setattr(manager, "export_knowledge", lambda *_a: pytest.fail("export after failed pull"))
    encrypted = tmp_path / "backup.gpg"
    encrypted.write_bytes(b"encrypted-snapshot-fixture")
    monkeypatch.setattr(manager, "snapshot", lambda *_a: (encrypted, {}))
    monkeypatch.setattr(manager, "github_backup", lambda *_a: {"verifiedAt": memory.now()})
    result = manager.sync()
    assert not result["ok"]
    assert result["targets"][0]["state"] == "knowledge-conflict-review-required"
    assert result["targets"][0]["lastBackup"]["verifiedAt"]
    assert json.loads((manager.state / "last-run.json").read_text())["ok"] is False


def test_no_automatic_work_when_paused(manager, monkeypatch):
    monkeypatch.setattr(manager, "password", lambda: pytest.fail("paused worker opened vault"))
    assert manager.sync(automatic=True)["state"] == "paused"


def test_github_backoff_avoids_automatic_retry_but_manual_sync_bypasses_it(manager, monkeypatch):
    manager.config.update(automatic=True, github={"repository": "owner/memory"})
    memory.write_json(manager.state / "last-run.json", {"targets": [{"id": "github", "ok": False,
        "state": "command-failed:gh:1", "retryAfter": "2099-01-01T00:00:00+00:00", "lastBackup": None}]})
    calls = []
    def unavailable(*_args, **_kwargs):
        calls.append("network")
        raise memory.MemoryError("command-failed:gh:1")
    monkeypatch.setattr(manager, "github_pull", unavailable)
    monkeypatch.setattr(manager, "snapshot", unavailable)
    automatic = manager.sync(automatic=True)
    assert not calls
    assert automatic["targets"][0]["state"] == "retry-pending"
    manager.sync()
    assert calls


def test_scope_identity_uses_remote_not_project_basename(manager, tmp_path, monkeypatch):
    path = tmp_path / "checkout"
    path.mkdir()
    monkeypatch.setattr(manager, "native", lambda *_a, **_k: subprocess.CompletedProcess([], 0, json.dumps([
        {"workspace_name": "default", "project_name": name, "project_id": name}
        for name in ("same-name", "renamed", "another-repository")]).encode(), b""))
    monkeypatch.setattr(memory, "run", lambda *_a, **_k: subprocess.CompletedProcess([], 0, b"git@github.com:owner/repo.git\n", b""))
    first = manager.add_scope("same-name", "default", str(path), "decisions")
    monkeypatch.setattr(memory, "run", lambda *_a, **_k: subprocess.CompletedProcess([], 0, b"https://github.com/owner/repo.git\n", b""))
    with pytest.raises(memory.MemoryError, match="already-enrolled"):
        manager.add_scope("renamed", "default", str(path), "decisions")
    monkeypatch.setattr(memory, "run", lambda *_a, **_k: subprocess.CompletedProcess([], 0, b"https://github.com/other/repo.git\n", b""))
    assert manager.add_scope("another-repository", "default", str(path), "decisions")["scopeId"] != first["scopeId"]
    with pytest.raises(memory.MemoryError, match="already-bound"):
        manager.add_scope("same-name", "default", str(path), "decisions", identity="d" * 64)


def test_unknown_git_servers_preserve_path_case_and_do_not_infer_transport_aliases():
    assert memory.remote_identity("https://example.org/team/Repo.git") != memory.remote_identity("https://example.org/team/repo.git")
    assert memory.remote_identity("git@example.org:team/repo.git") != memory.remote_identity("https://example.org/team/repo.git")
    assert memory.remote_identity("git@github.com:Owner/Repo.git") == memory.remote_identity("https://github.com/owner/repo.git")


def test_non_git_project_can_use_explicit_portable_identity(manager, tmp_path, monkeypatch):
    monkeypatch.setattr(manager, "native", lambda *_a, **_k: subprocess.CompletedProcess([], 0, json.dumps([
        {"workspace_name": "default", "project_name": "local", "project_id": "local-id"}]).encode(), b""))
    result = manager.add_scope("local", "default", str(tmp_path), "notes", identity="b" * 64)
    assert result["scopeId"] == "b" * 64


def test_state_read_does_not_create_installation_or_config(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    manager = memory.Manager(vault=Vault())
    assert not manager.config
    assert not manager.config_path.exists()


def test_failed_native_restore_rolls_back_before_restarting_service(manager, tmp_path, monkeypatch):
    unit = manager.config_home / "systemd/user/ai-memory.service"
    unit.parent.mkdir(parents=True)
    unit.write_text(f'[Service]\nExecStart="/bin/echo" --data-dir "{manager.data}" serve\n')
    manager.data.mkdir()
    (manager.data / "raw").mkdir()
    (manager.data / "raw/original").write_text("preserve")
    root = tmp_path / "restore-source"
    (root / "payload/raw").mkdir(parents=True)
    (root / "payload/raw/new").write_text("restored ledger")
    events = []
    def fake_run(args, **kwargs):
        events.append(" ".join(map(str, args)))
        return subprocess.CompletedProcess(args, 0, str(unit).encode() if "show" in args else b"active", b"")
    def native(*args, **kwargs):
        events.append(args[0])
        if args[0] == "backup":
            Path(args[2]).write_text("pre-backup")
        elif args[0] == "restore" and "restore-source" in str(args[2]):
            raise memory.MemoryError("fixture native restore rejected snapshot")
        return subprocess.CompletedProcess([], 0, b"", b"")
    monkeypatch.setattr(memory, "run", fake_run)
    monkeypatch.setattr(manager, "native", native)
    with pytest.raises(memory.MemoryError, match="rejected"):
        memory.restore_native(manager, root, {"rawIncluded": True})
    assert events.index("backup") < events.index("systemctl --user stop ai-memory.service") < events.index("restore")
    assert events.count("restore") == 2
    assert events[-1] == "systemctl --user start ai-memory.service"
    assert (manager.data / "raw/original").read_text() == "preserve"
    assert not (manager.data / "raw/new").exists()


def test_restore_refuses_another_data_directories_service(manager, tmp_path, monkeypatch):
    unit = manager.config_home / "systemd/user/ai-memory.service"
    unit.parent.mkdir(parents=True)
    unit.write_text('ExecStart=/bin/echo --data-dir /unrelated/store serve\n')
    calls = []
    def fake_run(args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, str(unit).encode() if "show" in args else b"active", b"")
    monkeypatch.setattr(memory, "run", fake_run)
    monkeypatch.setattr(manager, "native", lambda *_a, **_k: pytest.fail("unrelated store backup"))
    with pytest.raises(memory.MemoryError, match="directory-mismatch"):
        memory.restore_native(manager, tmp_path, {})
    assert not any("stop" in args for args in calls)


def test_scheduling_escapes_paths_and_updates_cadence_without_secrets(manager, tmp_path, monkeypatch):
    monkeypatch.setattr(memory, "ROOT", tmp_path / "installed-runtime")
    monkeypatch.setattr(memory, "run", lambda *a, **k: subprocess.CompletedProcess([], 0, b"", b""))
    manager.config["intervalMinutes"] = 30
    manager.schedule(True)
    timer = manager.config_home / "systemd/user/phasezero-ai-memory-sync.timer"
    assert "OnUnitActiveSec=30min" in timer.read_text()
    assert manager.password() not in timer.read_text()
    assert memory.unit_quote('/path/with spaces/"100%') == '"/path/with spaces/\\"100%%"'
    with pytest.raises(memory.MemoryError):
        manager.settings(0, 24, 7)


def test_unattended_transport_refuses_cleartext_remote_auth(manager, monkeypatch):
    monkeypatch.setenv("AI_MEMORY_SERVER_URL", "http://192.0.2.1:49374")
    with pytest.raises(memory.MemoryError, match="https"):
        manager.client_environment()
