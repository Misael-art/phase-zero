import importlib.util
from pathlib import Path
from unittest.mock import patch
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("repairs", ROOT / "linux/repairs/manager.py")
repairs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repairs)


def test_install_shortcuts_is_idempotent_and_never_runs_repair(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    with patch.object(repairs.Path, "home", return_value=tmp_path), patch.object(repairs.shutil, "which", return_value=None), patch.object(repairs.subprocess, "run", side_effect=AssertionError("install cannot execute")):
        first = repairs.install_shortcuts()
        assert first == repairs.install_shortcuts()
    for directory in (tmp_path / "Desktop", tmp_path / "data/applications"):
        entries = list(directory.glob("*.desktop"))
        assert len(entries) == 2
        for entry in entries:
            text = entry.read_text()
            assert " --confirm" in text
            assert str(ROOT / "linux/repairs/manager.py") in text
            assert " --yes" not in text


def test_repairs_never_run_without_explicit_confirmation(monkeypatch):
    monkeypatch.setattr("sys.argv", ["manager", "run", "microfone"])
    with patch.object(repairs, "status", return_value={"microfone": {"available": True}}), patch.object(repairs.subprocess, "run", side_effect=AssertionError("no repair")):
        assert repairs.main() == 2


def test_unmanaged_desktop_is_preserved(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    directory = tmp_path / "data/applications"
    directory.mkdir(parents=True)
    target = directory / "phasezero-reparo-microfone.desktop"
    target.write_text("user work")
    import pytest
    with patch.object(repairs.Path, "home", return_value=tmp_path), patch.object(repairs.shutil, "which", return_value=None), pytest.raises(RuntimeError, match="preservado"):
        repairs.install_shortcuts()
    assert target.read_text() == "user work"


def test_microphone_refuses_unobserved_capture_profile(tmp_path, monkeypatch):
    binary = tmp_path / "bin"
    binary.mkdir()
    pactl = binary / "pactl"
    pactl.write_text("#!/bin/sh\nprintf '%s' '[{\"name\":\"output-only\",\"profiles\":{\"off\":{\"sources\":0,\"available\":true}}}]'\n")
    pactl.chmod(0o755)
    monkeypatch.setenv("PATH", str(binary) + ":/usr/bin:/bin")
    monkeypatch.setenv("PZ_REPAIR_NONINTERACTIVE", "1")
    result = subprocess.run(["bash", str(ROOT / "linux/repairs/reparo-microfone.sh")], text=True, capture_output=True)
    assert result.returncode == 69
    assert "Nenhum perfil de captura disponível" in result.stdout
