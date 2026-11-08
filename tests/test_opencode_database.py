import shutil
import sqlite3
import subprocess

import pytest

from linux.ai import opencode_database as owner


def database(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr(owner.shutil, "which", lambda command: "/fixture/fuser")
    path = tmp_path / "opencode.db"
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE messages (text TEXT)")
    db.execute("INSERT INTO messages VALUES ('preserved conversation')")
    db.commit()
    db.close()
    return path


def test_consistent_backup_uses_central_store_and_leaves_legacy_untouched(tmp_path, monkeypatch):
    path = database(tmp_path, monkeypatch)
    legacy = path.with_name(path.name + ".pz-bak")
    legacy.write_bytes(b"old backup")
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[0] == "cp":
            # Test the SQLite/retention contract without assuming CI has COW.
            shutil.copy2(command[-2], command[-1])
        return subprocess.CompletedProcess(command, 1 if command[0] == "fuser" else 0)

    monkeypatch.setattr(owner.subprocess, "run", run)
    target = owner.backup_database(path)
    with sqlite3.connect(target) as backup:
        assert backup.execute("SELECT text FROM messages").fetchone() == ("preserved conversation",)
    assert legacy.read_bytes() == b"old backup"
    assert target.parent.parent == tmp_path / "state/phasezero/backups"
    assert target.stat().st_mode & 0o777 == 0o600
    assert "--reflink=always" in commands[-1]


def test_busy_database_blocks_before_copy(tmp_path, monkeypatch):
    path = database(tmp_path, monkeypatch)
    monkeypatch.setattr(owner.subprocess, "run", lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0))
    with pytest.raises(ValueError, match="Feche OpenCode"):
        owner.backup_database(path)
    assert not (tmp_path / "state").exists()


def test_no_physical_copy_retry_after_reflink_failure(tmp_path, monkeypatch):
    path = database(tmp_path, monkeypatch)
    commands = []

    def run(command, **kwargs):
        commands.append(command)
        if command[0] == "cp":
            raise subprocess.CalledProcessError(1, command)
        return subprocess.CompletedProcess(command, 1)

    monkeypatch.setattr(owner.subprocess, "run", run)
    with pytest.raises(subprocess.CalledProcessError):
        owner.backup_database(path)
    assert len(commands) == 2
    assert not list((tmp_path / "state").rglob("*.bak.*"))
    with sqlite3.connect(path) as original:
        assert original.execute("SELECT COUNT(*) FROM messages").fetchone() == (1,)
