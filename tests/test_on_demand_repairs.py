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
        before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in tmp_path.rglob("*.desktop")}
        assert first == repairs.install_shortcuts()
        after = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in tmp_path.rglob("*.desktop")}
        assert before == after
    for directory in (tmp_path / "Desktop", tmp_path / "data/applications"):
        entries = list(directory.glob("*.desktop"))
        assert len(entries) == 3
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


def test_shortcut_symlink_cannot_overwrite_another_file(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    directory = tmp_path / "data/applications"
    directory.mkdir(parents=True)
    victim = tmp_path / "valuable"
    victim.write_text("X-PhaseZero-Managed=true\nkeep")
    (directory / "phasezero-reparo-microfone.desktop").symlink_to(victim)
    import pytest
    with patch.object(repairs.Path, "home", return_value=tmp_path), patch.object(repairs.shutil, "which", return_value=None), pytest.raises(RuntimeError, match="symlink preservado"):
        repairs.install_shortcuts()
    assert victim.read_text() == "X-PhaseZero-Managed=true\nkeep"


def test_microphone_prefers_ucm_profile_that_enables_internal_mic(tmp_path, monkeypatch):
    binary = tmp_path / "bin"
    binary.mkdir()
    pactl = binary / "pactl"
    pactl.write_text('''#!/bin/sh
case "$*" in
  "-f json list cards") echo '[{"name":"alsa_card.acp5x","active_profile":"pro-audio","profiles":{"pro-audio":{"sources":1,"available":true,"priority":1},"HiFi (Mic, Speaker)":{"sources":1,"available":true,"priority":8300}}}]' ;;
  "list short sources") echo alsa_input.internal ;;
  "info") echo 'Default Source: mic-biglinux' ;;
  *) printf '%s\\n' "$*" >> "$AUDIO_CALLS" ;;
esac
''')
    pactl.chmod(0o755)
    monkeypatch.setenv("PATH", str(binary) + ":/usr/bin:/bin")
    monkeypatch.setenv("PZ_REPAIR_NONINTERACTIVE", "1")
    monkeypatch.setenv("AUDIO_CALLS", str(tmp_path / "calls"))
    result = subprocess.run(["bash", str(ROOT / "linux/repairs/reparo-microfone.sh")], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (tmp_path / "calls").read_text().strip() == 'set-card-profile alsa_card.acp5x HiFi (Mic, Speaker)'


def test_touch_repair_help_never_invokes_admin_bridge(tmp_path, monkeypatch):
    binary = tmp_path / "bin"
    binary.mkdir()
    for name in ("phasezero-admin", "bigsudo"):
        target = binary / name
        target.write_text('#!/bin/sh\necho unexpected-admin >> "$ADMIN_CALLS"\nexit 77\n')
        target.chmod(0o755)
    monkeypatch.setenv("PATH", str(binary) + ":/usr/bin:/bin")
    marker = tmp_path / "admin-calls"
    monkeypatch.setenv("ADMIN_CALLS", str(marker))
    result = subprocess.run(["bash", str(ROOT / "linux/repairs/reparo-entrada.sh"), "--help"], text=True, capture_output=True)
    assert result.returncode == 0
    assert "usage:" in result.stdout
    assert not marker.exists()
