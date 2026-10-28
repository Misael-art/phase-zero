"""Steam Deck input safety net: one input method, defer to a game session,
and detect a desktop left stuck in gamepad mode."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(script: str, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(ROOT / script), *args], capture_output=True, text=True,
                          env={**os.environ, **env}, timeout=60, check=False)


def input_status(tmp_path: Path, state: dict | None) -> dict:
    state_dir = tmp_path / "retrofe"
    state_dir.mkdir(exist_ok=True)
    if state is not None:
        (state_dir / "steam-desktop-session.json").write_text(json.dumps(state))
    result = run("linux/steamdeck/input-restore.sh", "status", env={
        "PZ_RETROFE_STATE_DIR": str(state_dir), "PZ_RETROFE_ROOT": str(tmp_path),
        "XDG_DATA_HOME": str(tmp_path / "data"),
    })
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def test_desktop_mode_when_no_game_session(tmp_path):
    status = input_status(tmp_path, None)
    assert status["mode"] == "desktop" and status["ok"]


def test_live_game_keeps_gamepad_profile_on_purpose(tmp_path):
    status = input_status(tmp_path, {"owners": {"1": {"pid": os.getpid(), "children": []}}})
    assert status["mode"] == "game" and status["ok"]


def test_dead_owner_with_pending_profile_is_stuck(tmp_path):
    status = input_status(tmp_path, {"owners": {"1": {"pid": 999999999, "children": []}}})
    assert status["mode"] == "stuck" and not status["ok"]


def test_restore_waits_for_a_running_game(tmp_path):
    state_dir = tmp_path / "retrofe"
    state_dir.mkdir()
    (state_dir / "steam-desktop-session.json").write_text(
        json.dumps({"owners": {"1": {"pid": os.getpid(), "children": []}}}))
    result = run("linux/steamdeck/input-restore.sh", "restore",
                 env={"PZ_RETROFE_STATE_DIR": str(state_dir), "PZ_RETROFE_ROOT": str(tmp_path)})
    assert result.returncode == 0
    assert "jogo ainda ativo" in result.stderr + result.stdout


def test_controller_desktop_defers_to_game_session(tmp_path):
    session = tmp_path / "session.json"
    session.write_text("{}")
    script = (f'source "{ROOT}/linux/steamdeck/controller-desktop.sh" status >/dev/null; '
              'conflicting_session')
    result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30,
                            env={**os.environ, "PZ_RETROFE_SESSION_FILE": str(session)})
    assert result.stdout.strip().splitlines()[-1] == "retrofe-game-session"


def test_competing_input_method_autostart_is_hidden_and_restorable(tmp_path):
    system = tmp_path / "xdg-autostart"
    system.mkdir()
    (system / "org.fcitx.Fcitx5.desktop").write_text("[Desktop Entry]\nExec=fcitx5\n")
    env = {"PZ_XDG_AUTOSTART_DIRS": str(system), "XDG_CONFIG_HOME": str(tmp_path / "config"),
           "PATH": f"{tmp_path}/bin:{os.environ['PATH']}"}
    (tmp_path / "bin").mkdir()
    for tool in ("pkill",):
        stub = tmp_path / "bin" / tool
        stub.write_text("#!/bin/sh\nexit 1\n")
        stub.chmod(0o755)
    body = (f'source "{ROOT}/linux/lib/common.sh"; source "{ROOT}/linux/steamdeck/input-actions.sh"; '
            'steamdeck_disable_competing_ims; echo "left=$(steamdeck_vkbd_competing_ims)"; '
            'steamdeck_restore_competing_ims')
    result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, timeout=30,
                            env={**os.environ, **env})
    assert "left=" in result.stdout and "left=org" not in result.stdout, result.stdout + result.stderr
    assert not (tmp_path / "config/autostart/org.fcitx.Fcitx5.desktop").exists()
