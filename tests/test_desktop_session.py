"""Desktop safety regressions. No live audio, D-Bus, evdev or services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("desktop_session", ROOT / "linux/steamdeck/desktop_session.py")
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)


def test_keyboard_recovery_keeps_automatic_opening_touch_only():
    saved = {"VirtualKeyboardEnabled": "true", "VirtualKeyboardMode": "2"}
    runtime = {"available": "true", "mode": "2"}
    calls = []

    def run(*args, **kwargs):
        calls.append(args)
        if args[0] == "kreadconfig6":
            return subprocess.CompletedProcess(args, 0, saved[args[-1]], "")
        if args[0] == "kwriteconfig6":
            saved[args[-2]] = args[-1]
        if args[0] == "qdbus6" and args[-2] == "mode":
            runtime["mode"] = args[-1]
        return subprocess.CompletedProcess(args, 0, "", "")

    with patch.object(desktop, "run", run), patch.object(desktop, "properties", side_effect=lambda *args: dict(runtime)), \
         patch.object(desktop, "protected_devices", return_value=[TOUCHSCREEN, DECK_KEYS]):
        assert desktop.keyboard_restore() == []
        assert saved["VirtualKeyboardMode"] == "1" and runtime["mode"] == "1"
        assert desktop.keyboard_restore() == []
    assert sum(args[0] == "kwriteconfig6" for args in calls) == 1
    assert sum(args[0] == "qdbus6" for args in calls) == 1
    assert not any("forceActivate" in args for args in calls)


TOUCHSCREEN = {"name": "FTS3528:00 2808:1015", "enabled": "true", "touch": "true", "vendor": "10248"}
DECK_KEYS = {"name": "Valve Software Steam Deck Controller", "enabled": "true",
             "alphaNumericKeyboard": "true", "vendor": "10462"}
INTERNAL_I8042 = {"name": "AT Translated Set 2 keyboard", "enabled": "true",
                  "alphaNumericKeyboard": "true", "vendor": "1"}
USB_KEYBOARD = {"name": "Dock keyboard", "enabled": "true", "alphaNumericKeyboard": "true", "vendor": "1133"}


def test_keyboard_opens_on_click_when_trackpads_are_the_only_way_to_type():
    # FTS absent: Deck controller and the i8042 stub are not typing keyboards.
    assert desktop.keyboard_target_mode([DECK_KEYS, INTERNAL_I8042]) == "2"
    assert desktop.keyboard_target_mode([DECK_KEYS, INTERNAL_I8042, USB_KEYBOARD]) == "1"
    assert desktop.keyboard_target_mode([DECK_KEYS, TOUCHSCREEN]) == "1"
    assert desktop.keyboard_target_mode([DECK_KEYS, {**TOUCHSCREEN, "enabled": "false"}]) == "2"
    assert desktop.keyboard_target_mode([DECK_KEYS, {**USB_KEYBOARD, "enabled": "false"}]) == "2"


def test_games_keep_keyboard_touch_only_and_unknown_state_is_preserved():
    assert desktop.keyboard_target_mode([DECK_KEYS], game=True) == "1"
    assert desktop.keyboard_target_mode([]) is None
    saved = {"VirtualKeyboardEnabled": "true", "VirtualKeyboardMode": "2"}
    calls = []

    def run(*args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, saved.get(args[-1], ""), "")

    with patch.object(desktop, "run", run), patch.object(desktop, "protected_devices", return_value=[]), \
         patch.object(desktop, "properties", return_value={"available": "true", "mode": "2"}):
        assert desktop.keyboard_restore() == []
    assert not any(args[0] in ("kwriteconfig6", "qdbus6") for args in calls)


def test_watcher_switches_keyboard_to_click_mode_in_desktop_and_back_for_games():
    saved = {"VirtualKeyboardEnabled": "true", "VirtualKeyboardMode": "1"}
    runtime = {"available": "true", "mode": "1"}

    def run(*args, **kwargs):
        if args[0] == "kreadconfig6":
            return subprocess.CompletedProcess(args, 0, saved[args[-1]], "")
        if args[0] == "kwriteconfig6":
            saved[args[-2]] = args[-1]
        if args[0] == "qdbus6" and args[-2] == "mode":
            runtime["mode"] = args[-1]
        return subprocess.CompletedProcess(args, 0, "", "")

    with patch.object(desktop, "run", run), patch.object(desktop, "properties", side_effect=lambda *a: dict(runtime)), \
         patch.object(desktop, "protected_devices", return_value=[DECK_KEYS, INTERNAL_I8042]):
        assert desktop.keyboard_restore() == []
        assert runtime["mode"] == saved["VirtualKeyboardMode"] == "2"
        assert desktop.keyboard_restore(game=True) == []
        assert runtime["mode"] == saved["VirtualKeyboardMode"] == "1"


def test_reused_pid_from_previous_boot_cannot_hold_desktop_in_game_mode(tmp_path):
    ticks = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()[19]
    owner = {"pid": os.getpid(), "start_ticks": ticks, "boot_id": "previous-boot"}
    (tmp_path / "steam-desktop-session.json").write_text(json.dumps({"owners": {str(os.getpid()): owner}}))
    assert desktop.lease_status(tmp_path)["active"] is False
    owner["boot_id"] = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    (tmp_path / "steam-desktop-session.json").write_text(json.dumps({"owners": {str(os.getpid()): owner}}))
    assert desktop.lease_status(tmp_path)["active"] is True
    owner["start_ticks"] = "wrong-start"
    (tmp_path / "steam-desktop-session.json").write_text(json.dumps({"owners": {str(os.getpid()): owner}}))
    assert desktop.lease_status(tmp_path)["active"] is False


def test_emulator_child_keeps_lease_after_launcher_exits(tmp_path):
    ticks = Path(f"/proc/{os.getpid()}/stat").read_text().rsplit(")", 1)[1].split()[19]
    child = {"pid": os.getpid(), "start_ticks": ticks,
             "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}
    (tmp_path / "steam-desktop-session.json").write_text(json.dumps({"owners": {"1": {"children": [child]}}}))
    assert desktop.lease_status(tmp_path)["active"]


def test_invalid_or_symlink_lease_is_not_assumed_inactive(tmp_path):
    state = tmp_path / "steam-desktop-session.json"
    state.write_text('{"owners": []}')
    with pytest.raises(RuntimeError):
        desktop.lease_status(tmp_path)
    state.unlink()
    state.symlink_to(tmp_path / "valuable")
    with pytest.raises(RuntimeError):
        desktop.lease_status(tmp_path)


def test_peripherals_reenabled_even_during_game_without_audio_restore():
    calls = []
    with patch.object(desktop, "protect_input", side_effect=lambda: calls.append("protect-usb") or []), \
         patch.object(desktop, "lease_status", return_value={"active": True}), \
         patch.object(desktop, "restore_audio", side_effect=AssertionError("game owns audio")), \
         patch.object(desktop, "keyboard_restore", return_value=[]):
        assert desktop.reconcile() == {"ok": True, "mode": "game", "errors": []}
    assert calls == ["protect-usb"]


def test_disabled_usb_keyboard_is_enabled_without_remapping():
    calls = []
    def run(*args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, "", "")
    with patch.object(desktop, "protected_devices", return_value=[{
        "path": "/org/kde/KWin/InputDevice/event22", "name": "USB Keyboard", "enabled": "false"}]), \
         patch.object(desktop, "run", run):
        assert desktop.protect_input() == []
    assert len(calls) == 1
    assert calls[0][-2:] == ("enabled", "true")


def test_manual_input_request_does_not_restore_audio_or_change_keyboard_mode():
    with patch.object(desktop, "protect_input", return_value=[]) as protect, \
         patch.object(desktop, "restore_audio", side_effect=AssertionError("audio is outside this request")), \
         patch.object(desktop, "audio_snapshot", side_effect=AssertionError("no audio capture")), \
         patch.object(desktop, "keyboard_restore", side_effect=AssertionError("keyboard mode is outside input enabling")):
        assert desktop.reconcile_input() == {"schema_version":1,"ok":True,"scope":"input","errors":[]}
    protect.assert_called_once()


def test_manual_input_failure_is_reported_without_broad_recovery():
    with patch.object(desktop, "protect_input", return_value=["device unavailable"]):
        result = desktop.reconcile_input()
    assert result["ok"] is False and result["errors"] == ["device unavailable"]


def test_touch_auth_requires_visible_keyboard_before_root_and_restores_mode(tmp_path):
    runtime={"available":"true","mode":"1","visible":"false","activeClientSupportsTextInput":"true"}
    calls=[]
    def run(*args, **kwargs):
        calls.append(args)
        if args[-2:]==("mode","2"): runtime["mode"]="2"
        if args[-2:]==("mode","1"): runtime["mode"]="1"
        if args[-1].endswith("forceActivate"): runtime["visible"]="true"
        return subprocess.CompletedProcess(args,0,"","")
    def privileged(args, **kwargs):
        assert runtime["mode"]=="2" and runtime["visible"]=="true"
        assert desktop.keyboard_restore()==[], "Watcher must yield instead of hiding the auth keyboard"
        runtime["visible"]="false"  # Authentication dialog takes focus.
        end=time.monotonic()+2
        while runtime["visible"]!="true" and time.monotonic()<end: time.sleep(.02)
        assert runtime["visible"]=="true"
        return subprocess.CompletedProcess(args,126,"","Autenticação cancelada")
    with patch.object(desktop,"state_dir",return_value=tmp_path), patch.object(desktop,"run",run), \
         patch.object(desktop,"properties",side_effect=lambda *args:dict(runtime)), \
         patch.object(desktop.subprocess,"run",privileged):
        result=desktop.recover_touch()
    assert not result["ok"] and "cancelada" in result["errors"][0]
    assert runtime["mode"]=="1"
    assert sum(call[-1].endswith("forceActivate") for call in calls)>=2


def test_unusable_virtual_keyboard_never_requests_authentication(tmp_path):
    with patch.object(desktop,"state_dir",return_value=tmp_path), \
         patch.object(desktop,"properties",return_value={"available":"false","mode":"1"}), \
         patch.object(desktop.subprocess,"run",side_effect=AssertionError("must not request root")):
        result=desktop.recover_touch()
    assert not result["ok"] and "autenticação não solicitada" in result["errors"][0]


def test_touch_timeout_keeps_uncertainty_and_restores_temporary_keyboard(tmp_path):
    runtime={"available":"true","mode":"1","visible":"true"}
    def run(*args, **kwargs):
        if args[-2]=="mode": runtime["mode"]=args[-1]
        return subprocess.CompletedProcess(args,0,"","")
    with patch.object(desktop,"state_dir",return_value=tmp_path), patch.object(desktop,"run",run), \
         patch.object(desktop,"properties",side_effect=lambda *args:dict(runtime)), \
         patch.object(desktop.subprocess,"run",side_effect=subprocess.TimeoutExpired("helper",110)):
        with pytest.raises(subprocess.TimeoutExpired): desktop.recover_touch()
    assert runtime["mode"]=="1"


def test_audio_profile_and_preferences_restored_by_stable_names_not_numeric_ids():
    calls = []
    card = {"name": "alsa_card.deck", "active_profile": "off", "profiles": {"HiFi": {"available": True}}}
    endpoint = {"name": "alsa_output.deck.speaker", "mute": True, "volume": {"left": {"value": 0}}}
    saved = {"profiles": {card["name"]: "HiFi"}, "endpoints": {
        "sinks": {endpoint["name"]: {"mute": False, "volume": [25000]}}}, "defaults": {"sink": endpoint["name"]}}
    def run(*args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, "unavailable-hdmi", "")
    with patch.object(desktop, "audio_list", side_effect=lambda kind: [card] if kind == "cards" else [endpoint] if kind == "sinks" else []), \
         patch.object(desktop, "run", run):
        assert desktop.restore_audio(saved) == []
    assert ("pactl", "set-card-profile", "alsa_card.deck", "HiFi") in calls
    assert ("pactl", "set-sink-volume", endpoint["name"], "25000") in calls
    assert ("pactl", "set-sink-mute", endpoint["name"], "0") in calls
    assert ("pactl", "set-default-sink", endpoint["name"]) in calls


def test_async_profile_graph_preserves_retry_instead_of_claiming_success():
    saved = {"profiles": {"alsa_card.deck": "HiFi"}, "endpoints": {"sources": {
        "alsa_input.deck.mic": {"mute": False, "volume": [65536]}}}}
    card = {"name": "alsa_card.deck", "active_profile": "off", "profiles": {"HiFi": {"available": True}}}
    with patch.object(desktop, "audio_list", side_effect=lambda kind: [card] if kind == "cards" else []), \
         patch.object(desktop, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
        assert "aguardando" in desktop.restore_audio(saved)[0]


def test_capture_preserves_intentional_desktop_mute(tmp_path):
    snapshot = {"profiles": {}, "endpoints": {"sinks": {"speaker": {"mute": True, "volume": [0]}}, "sources": {}}}
    with patch.object(desktop, "state_dir", return_value=tmp_path), patch.object(desktop, "audio_snapshot", return_value=snapshot):
        desktop.capture_preferences()
    assert json.loads((tmp_path / "preferences.json").read_text())["audio"] == snapshot


def test_symlink_preferences_never_overwrite_target(tmp_path):
    valuable = tmp_path / "valuable"
    valuable.write_text("preserve")
    (tmp_path / "preferences.json").symlink_to(valuable)
    with pytest.raises(RuntimeError):
        desktop.write(tmp_path / "preferences.json", {})
    assert valuable.read_text() == "preserve"


def test_login_mapper_yields_to_steam_and_recovers_after_it_exits(tmp_path):
    binary = tmp_path / "bin"
    binary.mkdir()
    config = tmp_path / "scc"
    (config / "profiles").mkdir(parents=True)
    (config / "profiles/PhaseZero-Desktop.sccprofile").write_text("{}")
    device = tmp_path / "usb/deck"
    device.mkdir(parents=True)
    (device / "idVendor").write_text("28de")
    (device / "idProduct").write_text("1205")
    flag = tmp_path / "steam-active"
    events = tmp_path / "mapper.log"
    (binary / "pgrep").write_text('#!/bin/sh\ntest -e "$STEAM_FLAG" && test "$2" = steam\n')
    mapper = binary / "mapper"
    mapper.write_text('#!/bin/sh\necho "start $$" >> "$MAPPER_LOG"\ntrap \'echo "stop $$" >> "$MAPPER_LOG"; exit 0\' TERM INT\nwhile :; do sleep .1; done\n')
    for path in binary.iterdir():
        path.chmod(0o755)
    env = {**os.environ, "PATH": str(binary) + ":/usr/bin:/bin", "PZ_SCC_CONFIG_DIR": str(config),
           "PZ_SCC_DAEMON_BIN": str(mapper), "PZ_CONTROLLER_SYSFS_ROOT": str(tmp_path / "usb"),
           "PZ_RETROFE_STATE_DIR": str(tmp_path / "retrofe"),
           "PZ_RETROFE_SESSION_FILE": str(tmp_path / "retrofe/steam-desktop-session.json"),
           "STEAM_FLAG": str(flag), "MAPPER_LOG": str(events)}
    proc = subprocess.Popen(["bash", str(ROOT / "linux/steamdeck/controller-desktop.sh"), "supervise"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def wait_for(text, count=1):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if events.exists() and events.read_text().count(text) >= count:
                return
            time.sleep(.05)
        raise AssertionError(events.read_text() if events.exists() else "mapper did not start")
    try:
        wait_for("start")
        flag.touch()
        wait_for("stop")
        flag.unlink()
        wait_for("start", 2)
    finally:
        proc.terminate()
        proc.communicate(timeout=5)
    wait_for("stop", 2)
    mapper.write_text("#!/bin/sh\nexit 42\n")
    failed = subprocess.run(["bash", str(ROOT / "linux/steamdeck/controller-desktop.sh"), "supervise"], env=env,
                            capture_output=True, text=True, timeout=5)
    assert failed.returncode == 1
    assert "unbound variable" not in failed.stderr


def test_guardian_restores_after_boot_and_last_game_then_tracks_user_preferences(tmp_path):
    calls = []
    with patch.object(desktop, "state_dir", return_value=tmp_path), \
         patch.object(desktop, "lease_status", side_effect=[{"active": v} for v in [False, True, True, False, False]]), \
         patch.object(desktop, "other_game_active", return_value=False), \
         patch.object(desktop, "reconcile", side_effect=lambda: calls.append("restore") or {"ok": True}), \
         patch.object(desktop, "capture_preferences", side_effect=lambda: calls.append("capture")), \
         patch.object(desktop, "protect_input", return_value=[]), \
         patch.object(desktop, "keyboard_restore", return_value=[]), \
         patch.object(desktop.time, "sleep", side_effect=[None, None, None, None, StopIteration]):
        with pytest.raises(StopIteration):
            desktop.watch()
    assert calls == ["restore", "restore", "capture"]


def test_failed_startup_restore_cannot_overwrite_healthy_preferences(tmp_path):
    with patch.object(desktop, "state_dir", return_value=tmp_path), \
         patch.object(desktop, "lease_status", return_value={"active": False}), \
         patch.object(desktop, "other_game_active", return_value=False), \
         patch.object(desktop, "reconcile", return_value={"ok": False, "errors": ["audio unavailable"]}), \
         patch.object(desktop, "capture_preferences", side_effect=AssertionError("must keep baseline")), \
         patch.object(desktop, "protect_input", return_value=[]), \
         patch.object(desktop, "keyboard_restore", return_value=[]), \
         patch.object(desktop.time, "sleep", side_effect=StopIteration):
        with pytest.raises(StopIteration):
            desktop.watch()


def test_dead_emulator_process_does_not_block_desktop_restoration(tmp_path):
    process = tmp_path / "12345"
    process.mkdir()
    (process / "comm").write_text("RetroFE")
    (process / "stat").write_text("12345 (RetroFE) Z 1 0 0")
    assert not desktop.other_game_active(tmp_path)
    (process / "stat").write_text("12345 (RetroFE) S 1 0 0")
    assert desktop.other_game_active(tmp_path)


def test_pcm_still_missing_after_profile_change_remains_pending():
    saved = {"profiles": {"alsa_card.deck": "HiFi"}, "endpoints": {"sources": {
        "alsa_input.deck.mic": {"mute": False, "volume": [65536]}}}}
    card = {"name": "alsa_card.deck", "active_profile": "HiFi", "profiles": {"HiFi": {"available": True}}}
    with patch.object(desktop, "audio_list", side_effect=lambda kind: [card] if kind == "cards" else []):
        assert "aguardando" in desktop.restore_audio(saved)[0]


def test_missing_internal_card_cannot_replace_healthy_baseline(tmp_path):
    original = {"schema_version": 1, "audio": {"profiles": {"alsa_card.acp5x": "HiFi"}, "endpoints": {}}}
    desktop.write(tmp_path / "preferences.json", original)
    with patch.object(desktop, "state_dir", return_value=tmp_path), \
         patch.object(desktop, "audio_snapshot", return_value={"profiles": {}, "endpoints": {}}):
        with pytest.raises(RuntimeError):
            desktop.capture_preferences()
    assert json.loads((tmp_path / "preferences.json").read_text()) == original


def test_audio_snapshot_includes_speakers_with_monitor_sources_but_excludes_loopback_mics():
    sink = {"name": "speaker", "monitor_source": "speaker.monitor", "mute": False,
            "volume": {"left": {"value": 25000}}}
    mic = {"name": "mic", "monitor_source": "", "mute": False, "volume": {"mono": {"value": 65536}}}
    monitor = {**mic, "name": "speaker.monitor", "monitor_source": "speaker"}
    def audio(kind):
        return [sink] if kind == "sinks" else [mic, monitor] if kind == "sources" else []
    with patch.object(desktop, "audio_list", side_effect=audio), \
         patch.object(desktop, "run", return_value=subprocess.CompletedProcess([], 0, "speaker\n", "")):
        saved = desktop.audio_snapshot()
    assert saved["endpoints"]["sinks"] == {"speaker": {"mute": False, "volume": [25000]}}
    assert saved["endpoints"]["sources"] == {"mic": {"mute": False, "volume": [65536]}}
