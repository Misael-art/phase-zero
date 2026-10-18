import importlib.util
import os
from pathlib import Path
import time
from unittest.mock import Mock, patch
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("terminal_repair", ROOT / "linux/repairs/terminal.py")
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)


def fixture(base, number):
    path = base / f"pytest-{number}"
    path.mkdir(parents=True)
    (path / "data").write_bytes(b"fixture")
    return path


def age(path):
    for child in [*path.rglob("*"), path]:
        if not child.is_symlink():
            os.utime(child, (time.time() - 7200,) * 2)


def test_plan_preserves_current_active_recent_unknown_lock_and_live_pid(tmp_path):
    base = tmp_path / "pytest-of-user"
    for index in range(1, 8):
        path = fixture(base, index)
        age(path)
    (base / "pytest-current").symlink_to(base / "pytest-7")
    (base / "pytest-2/.lock").write_text(str(os.getpid()))
    (base / "pytest-3/.lock").write_text("")
    age(base / "pytest-2"); age(base / "pytest-3")
    os.utime(base / "pytest-4/data", None)
    (base / "pytest-6").rename(base / "other")
    (base / "pytest-6").symlink_to(base / "other")
    selected = terminal.candidates(base, {"pytest-5"})
    assert [path.name for path, _ in selected] == ["pytest-1"]


def test_archive_keeps_verified_copy_and_only_removes_inactive_origin(tmp_path):
    source = fixture(tmp_path / "source", 1)
    before = terminal.snapshot(source)
    backup = tmp_path / "backup"; backup.mkdir()
    with patch.object(terminal, "references", return_value=set()):
        terminal.archive(source, before, backup)
    assert not source.exists()
    assert (backup / "pytest-1/data").read_bytes() == b"fixture"


def test_archive_changed_source_preserved(tmp_path):
    source = fixture(tmp_path / "source", 1)
    before = terminal.snapshot(source)
    (source / "data").write_text("modified")
    with pytest.raises(RuntimeError, match="mudou"):
        terminal.archive(source, before, tmp_path / "backup")
    assert source.exists()


def test_archive_active_origin_preserved(tmp_path):
    source = fixture(tmp_path / "source", 1)
    backup = tmp_path / "backup"; backup.mkdir()
    with patch.object(terminal, "references", return_value={"pytest-1"}), pytest.raises(RuntimeError, match="em uso"):
        terminal.archive(source, terminal.snapshot(source), backup)
    assert source.exists()
    assert (backup / "pytest-1/data").exists()


def test_tree_symlink_preserved_without_following_or_deleting_target(tmp_path):
    source = fixture(tmp_path / "source", 1)
    external = tmp_path / "external"; external.mkdir()
    (external / "valuable").write_text("preserve")
    (source / "escape").symlink_to(external)
    backup = tmp_path / "backup"; backup.mkdir()
    with patch.object(terminal, "references", return_value=set()):
        terminal.archive(source, terminal.snapshot(source), backup)
    assert (external / "valuable").read_text() == "preserve"
    assert (backup / "pytest-1/escape").is_symlink()


def test_configuration_idempotent_and_no_service_restart(tmp_path):
    home = tmp_path / "home"; home.mkdir()
    profile = home / ".bashrc"; profile.write_text("export KEEP_ME=yes\n")
    backup = tmp_path / "backup"; backup.mkdir()
    temp = home / ".cache/phasezero/agent-tmp"
    with patch.object(terminal.subprocess, "run", return_value=Mock(returncode=0)) as run:
        terminal.configure(home, temp, backup)
        before = profile.read_bytes(), profile.stat().st_mtime_ns
        terminal.configure(home, temp, backup)
    assert before == (profile.read_bytes(), profile.stat().st_mtime_ns)
    assert profile.read_text().startswith("export KEEP_ME=yes")
    assert profile.read_text().count("export TMPDIR=") == 1
    assert 'export PYTEST_DEBUG_TEMPROOT="$TMPDIR/pytest"' in profile.read_text()
    assert all(call.args[0][:3] == ["systemctl", "--user", "set-environment"] for call in run.call_args_list)
    assert "restart" not in str(run.call_args_list)


def test_no_repair_without_explicit_confirmation(monkeypatch):
    monkeypatch.setattr("sys.argv", ["terminal.py", "repair"])
    with patch.object(terminal, "repair", side_effect=AssertionError("no repair")):
        assert terminal.main() == 1


def test_atomic_rejects_symlink(tmp_path):
    original = tmp_path / "original"; original.write_text("user data")
    link = tmp_path / "link"; link.symlink_to(original)
    with pytest.raises(RuntimeError, match="symlink"):
        terminal.atomic(link, "replacement")
    assert original.read_text() == "user data"


def test_copy_failure_preserves_origin(tmp_path):
    source = fixture(tmp_path / "source", 1)
    backup = tmp_path / "backup"; backup.mkdir()
    with patch.object(terminal.shutil, "copytree", side_effect=OSError("disk full")), pytest.raises(OSError):
        terminal.archive(source, terminal.snapshot(source), backup)
    assert (source / "data").read_bytes() == b"fixture"


def test_admin_scan_requires_explicit_uid_and_root(monkeypatch):
    monkeypatch.setattr("sys.argv", ["terminal.py", "scan-references", "--uid", str(os.getuid())])
    with patch.object(terminal.os, "getuid", return_value=1000), patch.object(terminal, "references", side_effect=AssertionError("no scan")):
        assert terminal.main() == 1
