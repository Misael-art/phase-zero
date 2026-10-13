"""Camada de compatibilidade por aplicativo do mapa do controle (Ashyterm)."""
from __future__ import annotations

import json
import os
import stat
from pathlib import Path

import pytest

from linux.steamdeck import controller_apps as ca

ROOT = Path(__file__).resolve().parents[1]
DESKTOP = ROOT / "linux" / "steamdeck" / "profiles" / "PhaseZero-Desktop.sccprofile"
ASHY = next(app for app in ca.APPS if app.key == "ashyterm")


@pytest.fixture
def config(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    return tmp_path


@pytest.mark.parametrize("accel,expected", [
    ("<Control>Page_Up", "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_PAGEUP)"),
    ("<Control>Page_Down", "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_PAGEDOWN)"),
    ("<Control><Shift>t", "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_LEFTSHIFT) and button(Keys.KEY_T)"),
    ("<Primary><Alt>F5", "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_LEFTALT) and button(Keys.KEY_F5)"),
    ("<Control>Tab", "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_TAB)"),
])
def test_gtk_accelerators_become_scc_actions(accel, expected):
    assert ca.accel_to_scc(accel) == expected


@pytest.mark.parametrize("accel", ["", "   ", "<Hyper>x", "<Control>", "<Control>dead_acute"])
def test_disabled_or_unknown_accelerators_are_refused(accel):
    assert ca.accel_to_scc(accel) is None


def test_ashyterm_defaults_move_tabs_with_page_keys(config):
    base = json.loads(DESKTOP.read_text(encoding="utf-8"))
    profile, notes = ca.build_profile(base, ASHY)
    assert notes == []
    assert profile["buttons"]["LB"]["action"] == "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_PAGEUP)"
    assert profile["buttons"]["RB"]["action"] == "button(Keys.KEY_LEFTCTRL) and button(Keys.KEY_PAGEDOWN)"
    # Só as abas mudam: todo o resto é o mapa desktop, intacto.
    for button, binding in base["buttons"].items():
        if button not in {"LB", "RB"}:
            assert profile["buttons"][button] == binding
    for key in ("pad_left", "pad_right", "trigger_left", "trigger_right", "dpad", "lstick", "rstick"):
        assert profile[key] == base[key]
    # O desktop não foi alterado por referência.
    assert "PAGEUP" not in base["buttons"]["LB"]["action"]


def test_user_overrides_in_ashyterm_settings_win(config):
    settings = config / "ashyterm" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"shortcuts": {"next-tab": "<Alt>Right", "copy": "<Control>c"}}))
    base = json.loads(DESKTOP.read_text(encoding="utf-8"))
    profile, _notes = ca.build_profile(base, ASHY)
    assert profile["buttons"]["RB"]["action"] == "button(Keys.KEY_LEFTALT) and button(Keys.KEY_RIGHT)"
    assert "PAGEUP" in profile["buttons"]["LB"]["action"]  # sem override: padrão


def test_disabled_shortcut_keeps_desktop_binding_and_says_so(config):
    settings = config / "ashyterm" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({"shortcuts": {"previous-tab": ""}}))
    base = json.loads(DESKTOP.read_text(encoding="utf-8"))
    profile, notes = ca.build_profile(base, ASHY)
    assert profile["buttons"]["LB"] == base["buttons"]["LB"]
    assert notes and "previous-tab" in notes[0]


def test_unreadable_settings_fall_back_to_defaults(config):
    settings = config / "ashyterm" / "settings.json"
    settings.parent.mkdir(parents=True)
    settings.write_text("{quebrado")
    assert ca.effective_shortcuts(ASHY)["next-tab"] == "<Control>Page_Down"


def test_generate_writes_one_profile_per_app(config, tmp_path):
    out = tmp_path / "profiles"
    report = ca.generate(DESKTOP, out)
    target = out / "PhaseZero-Ashyterm.sccprofile"
    assert target.is_file()
    assert json.loads(target.read_text())["buttons"]["RB"]["name"].endswith("(Ashyterm)")
    assert report["profiles"][0]["profile"] == "PhaseZero-Ashyterm"


@pytest.mark.parametrize("window_class,profile", [
    ("org.communitybig.ashyterm", "PhaseZero-Ashyterm"),
    ("ORG.communitybig.Ashyterm", "PhaseZero-Ashyterm"),
    ("org.kde.konsole", "PhaseZero-Desktop"),
    ("", "PhaseZero-Desktop"),
])
def test_focus_class_picks_profile(window_class, profile):
    assert ca.profile_for_class(window_class) == profile


def _stubs(tmp_path: Path, monkeypatch, *, kdotool: str, scc: str) -> None:
    """Fake kdotool/scc first on PATH: the module runs fixed argv only."""
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    for name, body in (("kdotool", kdotool), ("scc", scc)):
        path = bindir / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ.get('PATH', '')}")


def test_watch_switches_only_when_focus_crosses_an_app(tmp_path, monkeypatch):
    focus = tmp_path / "focus"
    calls = tmp_path / "calls"
    _stubs(tmp_path, monkeypatch, kdotool=f"cat {focus}", scc=f'echo "$2" >> {calls}')
    sequence = ["org.communitybig.ashyterm", "org.communitybig.ashyterm", "org.kde.dolphin", ""]
    seen: list[str] = []
    current = ""
    for window in sequence:
        focus.write_text(window)
        # Mesmo laço do watch(), um passo por vez, com estado preservado.
        window_class = ca.active_window_class()
        if window_class:
            wanted = ca.profile_for_class(window_class)
            if wanted != current and ca.set_profile(wanted):
                current = wanted
        seen.append(current)
    assert calls.read_text().split() == ["PhaseZero-Ashyterm", "PhaseZero-Desktop"]
    # Foco ilegível (string vazia) não troca nada.
    assert seen[-1] == "PhaseZero-Desktop"


def test_watch_once_runs_the_fixed_commands(tmp_path, monkeypatch):
    calls = tmp_path / "calls"
    _stubs(tmp_path, monkeypatch, kdotool="echo org.communitybig.ashyterm",
           scc=f'echo "$1 $2" >> {calls}')
    assert ca.watch(0.01, once=True) == 0
    assert calls.read_text().strip() == "set-profile PhaseZero-Ashyterm"


def test_failed_switch_is_reported_so_the_next_tick_retries(tmp_path, monkeypatch):
    _stubs(tmp_path, monkeypatch, kdotool="echo x", scc="exit 1")
    assert ca.set_profile("PhaseZero-Ashyterm") is False


def test_unknown_profile_never_reaches_the_daemon(tmp_path, monkeypatch):
    calls = tmp_path / "calls"
    _stubs(tmp_path, monkeypatch, kdotool="echo x", scc=f'echo "$2" >> {calls}')
    assert ca.set_profile("../../evil") is False
    assert not calls.exists()


def test_environment_cannot_choose_the_executable(tmp_path, monkeypatch):
    marker = tmp_path / "ran"
    monkeypatch.setenv("PZ_ACTIVE_WINDOW_CMD", f"touch {marker}")
    monkeypatch.setenv("PZ_SCC_SET_PROFILE_CMD", f"touch {marker}")
    _stubs(tmp_path, monkeypatch, kdotool="echo org.kde.dolphin", scc="exit 0")
    ca.active_window_class()
    ca.set_profile("PhaseZero-Desktop")
    assert not marker.exists()
