from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess

import pytest

from linux.ai import grok_build as grok

ROOT = Path(__file__).resolve().parents[1]


def test_install_validates_before_activation_and_adopts_without_replacing(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("PATH", "/usr/bin")
    artifact = tmp_path / "official"
    binary = b"#!/bin/sh\nprintf 'grok 1.2.3 (fixture) [stable]\\n'\n"
    monkeypatch.setattr(grok, "PIN", {"version": "1.2.3", "size": len(binary),
                                    "sha256": hashlib.sha256(binary).hexdigest()})
    artifact.write_bytes(binary.replace(b"fixture", b"invalid"))
    with pytest.raises(grok.GrokError, match="SHA-256"):
        grok.install(artifact)
    assert grok.find_grok() is None
    assert not list((tmp_path / ".grok/downloads").glob(".phasezero-grok-*"))

    artifact.write_bytes(binary)
    assert grok.install(artifact)["state"] == "installed"
    assert grok.version(grok.find_grok()) == "1.2.3"
    artifact.unlink()
    assert grok.install(artifact)["state"] == "already-installed"


def test_untrusted_updater_state_fails_closed(monkeypatch):
    monkeypatch.setattr(grok, "status", lambda: {"installed": True, "version": "1.2.3", "executable": "/grok"})
    monkeypatch.setattr(grok, "run_grok", lambda *_: '{"currentVersion":"1.2.3","latestVersion":"https://other","updateAvailable":true}')
    with pytest.raises(grok.GrokError, match="inconclusivo"):
        grok.check()


@pytest.mark.parametrize(("size", "mode"), [(0, "manual"), (70_000_001, "manual"), (70_000_000, "upstream")])
def test_update_size_policy(monkeypatch, size, mode):
    monkeypatch.setattr(grok, "check", lambda: {"installed": True, "channel": "stable",
                                               "updateAvailable": True, "latestVersion": "1.2.4"})
    monkeypatch.setattr(grok.platform, "machine", lambda: "x86_64")

    class Head:
        headers = {"Content-Length": str(size)}

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

    def head_only(request, timeout):
        assert request.get_method() == "HEAD"
        assert request.full_url == "https://x.ai/cli/grok-1.2.4-linux-x86_64"
        return Head()

    monkeypatch.setattr(grok, "urlopen", head_only)
    assert grok.update_plan()["downloadMode"] == mode
    if mode == "manual":
        monkeypatch.setattr(grok, "run_grok", lambda *_: pytest.fail("automatic download attempted"))
        assert grok.update()["state"] == "manual-download-required"


def test_managed_shortcuts_group_and_preserve_other_owner(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "share"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    launcher = tmp_path / "test control center"
    launcher.write_text("#!/bin/sh\nexit 0\n")
    launcher.chmod(0o755)
    command = ["bash", str(ROOT / "linux/ai/agent-shortcuts.sh"), str(launcher)]
    subprocess.run(command, check=True, capture_output=True)
    menu = (tmp_path / "config/menus/applications-merged/phasezero.menu").read_text()
    targets = tmp_path / "share/applications"
    for name in ("deepseek-harness", "grok-build"):
        entry = targets / f"phasezero-{name}.desktop"
        assert entry.name in menu
        assert f'Exec="{launcher}" --journey {name}' in entry.read_text()
        assert "X-PhaseZero-MenuGroup=web.ai" in entry.read_text()
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    assert '"applied": false' in result.stdout
    entry.write_text("[Desktop Entry]\nName=Existing shortcut\n")
    assert subprocess.run(command, capture_output=True).returncode
    assert "Existing shortcut" in entry.read_text()
