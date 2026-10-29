#!/usr/bin/env python3
"""Backend of `pz steamdeck input`: preserve desktop preferences across sessions.

No input grabs, device unbinds, service restarts or privileged writes. The
frontend's existing lease is the authority for temporary controller ownership.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

UNIT = "phasezero-input-restore.service"
HERE = Path(__file__).resolve().parent


def config_dir():
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "phasezero"


def state_dir():
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "phasezero/desktop-session"


def run(*args, timeout=8):
    try:
        return subprocess.run(list(args), capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL, env={**os.environ, "LC_ALL": "C"}, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return subprocess.CompletedProcess(args, 1, "", str(exc))


def read(path):
    if path.is_symlink():
        raise RuntimeError(f"Symlink preservado: {path}")
    if not path.exists():
        return None
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise RuntimeError(f"Estado inválido preservado: {path}")
    return value


def write(path, data):
    if path.is_symlink():
        raise RuntimeError(f"Symlink preservado: {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".desktop-session-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, indent=2, ensure_ascii=False)
            out.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def process_alive(owner):
    """A PID alone is not an identity, especially after reboot."""
    try:
        pid = int(owner["pid"])
        if pid <= 1 or str(owner["boot_id"]) != Path("/proc/sys/kernel/random/boot_id").read_text().strip():
            return False
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return fields[0] != "Z" and str(owner["start_ticks"]) == fields[19]
    except (OSError, KeyError, ValueError, TypeError, IndexError):
        return False


def lease_status(directory=None):
    directory = directory or Path(os.environ.get("PZ_RETROFE_STATE_DIR",
        str(Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "retrofe/input-session")))
    pending, live = [], False
    for name in ("steam-desktop-session.json", "kde-global-shortcut-guard.json"):
        value = read(directory / name)
        if value is None:
            continue
        if not isinstance(value, dict) or not isinstance(value.get("owners", {}), dict):
            raise RuntimeError(f"Estado de sessão inválido: {name}")
        pending.append(name)
        for key, owner in value.get("owners", {}).items():
            owner = {"pid": key, **owner}
            live |= process_alive(owner) or any(process_alive(c) for c in owner.get("children", []))
    return {"active": live, "pending": pending}


def other_game_active(proc_root=None):
    """Avoid restoring preferences over an unmanaged game or gaming session."""
    known = {"RetroFE", "retroarch", "dolphin-emu", "pcsx2-qt", "flycast", "rpcs3", "gamescope",
             "ES-DE", "emulationstatio", "quiver-launcher"}
    proc_root = proc_root or Path(os.environ.get("PZ_INPUT_PROC_ROOT", "/proc"))
    for proc in proc_root.iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if proc.stat().st_uid != os.getuid():
                continue
            if (proc / "stat").read_text().rsplit(")", 1)[1].split()[0] == "Z":
                continue
            if (proc / "comm").read_text().strip() in known:
                return True
            env = dict(v.split(b"=", 1) for v in (proc / "environ").read_bytes().split(b"\0") if b"=" in v)
            app = env.get(b"SteamGameId") or env.get(b"SteamAppId")
            if app and app not in {b"0", b"413080"}:
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def audio_list(kind):
    result = run("pactl", "-f", "json", "list", kind)
    if result.returncode:
        raise RuntimeError(f"PipeWire/Pulse indisponível: {kind}")
    return json.loads(result.stdout)


def audio_snapshot():
    cards = audio_list("cards")
    endpoints = {}
    for kind in ("sinks", "sources"):
        endpoints[kind] = {item["name"]: {
            "mute": item["mute"],
            "volume": [v["value"] for v in item["volume"].values()],
        } for item in audio_list(kind) if kind == "sinks" or not item.get("monitor_source")}
    return {"profiles": {c["name"]: c["active_profile"] for c in cards},
            "endpoints": endpoints,
            "defaults": {kind: run("pactl", f"get-default-{kind}").stdout.strip() for kind in ("sink", "source")}}


def restore_audio(saved):
    errors = []
    cards = {c["name"]: c for c in audio_list("cards")}
    expected_stems = [name.removeprefix("alsa_card.") for name, profile in saved.get("profiles", {}).items()
                      if profile != "off" and name in cards]
    for name, profile in saved.get("profiles", {}).items():
        card = cards.get(name)
        if profile == "off" or not card or card["active_profile"] == profile:
            continue
        if not card.get("profiles", {}).get(profile, {}).get("available"):
            errors.append(f"perfil indisponível: {name}/{profile}")
            continue
        if run("pactl", "set-card-profile", name, profile).returncode:
            errors.append(f"perfil: {name}")
    # Graph creation after a profile change is asynchronous. Retry on next tick.
    for plural, singular in (("sinks", "sink"), ("sources", "source")):
        current = {item["name"]: item for item in audio_list(plural)}
        for name, values in saved.get("endpoints", {}).get(plural, {}).items():
            if name not in current:
                if any(stem in name for stem in expected_stems):
                    errors.append(f"aguardando fonte/saída: {name}")
                continue  # Unplugged dock/USB audio must not block internal audio.
            now = current[name]
            if [v["value"] for v in now["volume"].values()] != values["volume"]:
                if run("pactl", f"set-{singular}-volume", name, *map(str, values["volume"])).returncode:
                    errors.append(f"volume: {name}")
            if now["mute"] != values["mute"]:
                if run("pactl", f"set-{singular}-mute", name, "1" if values["mute"] else "0").returncode:
                    errors.append(f"mute: {name}")
        default = saved.get("defaults", {}).get(singular)
        if default in current and run("pactl", f"get-default-{singular}").stdout.strip() != default:
            if run("pactl", f"set-default-{singular}", default).returncode:
                errors.append(f"entrada/saída padrão: {default}")
    return errors


def properties(path, interface):
    result = run("qdbus6", "org.kde.KWin", path, "org.freedesktop.DBus.Properties.GetAll", interface)
    if result.returncode:
        return {}
    return dict(line.split(": ", 1) for line in result.stdout.splitlines() if ": " in line)


def protected_devices():
    result = run("qdbus6", "org.kde.KWin", "/org/kde/KWin/InputDevice",
                 "org.freedesktop.DBus.Properties.Get", "org.kde.KWin.InputDeviceManager", "devicesSysNames")
    devices = []
    for event in result.stdout.splitlines():
        if not re.fullmatch(r"event\d+", event.strip()):
            continue
        path = "/org/kde/KWin/InputDevice/" + event.strip()
        props = properties(path, "org.kde.KWin.InputDevice")
        if any(props.get(key) == "true" for key in ("keyboard", "pointer", "touch", "touchpad")):
            devices.append({"path": path, "name": props.get("name", event), "enabled": props.get("enabled"),
                            "touchpad": props.get("touchpad"),
                            "disableEventsOnExternalMouse": props.get("disableEventsOnExternalMouse")})
    return devices


def protect_input():
    errors = []
    for device in protected_devices():
        # Never disable, grab, remap, unbind or change calibration of any device.
        for key, value in (("enabled", "true"),):
            if device.get(key) == "false" and run("qdbus6", "org.kde.KWin", device["path"],
                "org.freedesktop.DBus.Properties.Set", "org.kde.KWin.InputDevice", key, value).returncode:
                errors.append(device["name"])
        if device.get("touchpad") == "true" and device.get("disableEventsOnExternalMouse") == "true":
            if run("qdbus6", "org.kde.KWin", device["path"], "org.freedesktop.DBus.Properties.Set",
                   "org.kde.KWin.InputDevice", "disableEventsOnExternalMouse", "false").returncode:
                errors.append(device["name"] + ": external-mouse suppression")
    return errors


def keyboard_restore():
    errors = []
    # NonMouseInput: automatic opening follows touchscreen input, never a
    # physical mouse/trackpad. Explicit keyboard shortcuts remain available.
    for key, value in (("VirtualKeyboardEnabled", "true"), ("VirtualKeyboardMode", "1")):
        current = run("kreadconfig6", "--file", "kwinrc", "--group", "Wayland", "--key", key).stdout.strip()
        if current != value and run("kwriteconfig6", "--notify", "--file", "kwinrc", "--group", "Wayland",
                                    "--key", key, value).returncode:
            errors.append(key)
    props = properties("/VirtualKeyboard", "org.kde.kwin.VirtualKeyboard")
    if props.get("mode") != "1":
        if run("qdbus6", "org.kde.KWin", "/VirtualKeyboard", "org.freedesktop.DBus.Properties.Set",
               "org.kde.kwin.VirtualKeyboard", "mode", "1").returncode:
            errors.append("keyboard-mode")
    if props.get("available") != "true":
        result = run("bash", str(HERE / "input-actions.sh"), "configure", timeout=20)
        if result.returncode:
            errors.append("keyboard-provider")
    return errors


def reconcile():
    errors = protect_input()
    errors.extend(keyboard_restore())
    lease = lease_status()
    if lease["active"] or other_game_active():
        return {"ok": not errors, "mode": "game", "errors": errors}
    saved = read(state_dir() / "preferences.json")
    if saved:
        errors.extend(restore_audio(saved["audio"]))
    return {"ok": not errors, "mode": "desktop", "errors": errors}


def health():
    keyboard = properties("/VirtualKeyboard", "org.kde.kwin.VirtualKeyboard")
    devices = protected_devices()
    text = Path("/proc/bus/input/devices").read_text()
    deck = "Steam Deck" in text
    touch = "FTS3528" in text
    try:
        audio = audio_snapshot()
    except (RuntimeError, ValueError):
        audio = None
    return {"keyboard": keyboard, "devices": devices, "audio": audio,
            "touchscreen": "present" if touch else "missing" if deck else "not-applicable",
            "physicalUsbInput": "not-observed" if not any(
                "Vendor=28de" not in block and "Bus=0003" in block and ("mouse" in block or "Handlers=kbd" in block or " kbd " in block)
                for block in text.split("\n\n")) else "observed",
            "preferencesRegistered": (state_dir() / "preferences.json").is_file()}


def capture_preferences():
    value = {"schema_version": 1, "audio": audio_snapshot()}
    path = state_dir() / "preferences.json"
    previous = read(path)
    if previous:
        old = previous["audio"]
        # A disappearing internal card/PCM is an audio failure, not a new
        # preference. Preserve the healthy baseline through PipeWire rebuilds.
        for name, profile in old.get("profiles", {}).items():
            if "acp5x" in name and profile != "off" and value["audio"]["profiles"].get(name, "off") == "off":
                raise RuntimeError("Placa interna indisponível; preferências anteriores preservadas.")
        value["audio"]["profiles"] = {**old.get("profiles", {}), **value["audio"]["profiles"]}
        for kind in ("sinks", "sources"):
            value["audio"]["endpoints"][kind] = {
                **old.get("endpoints", {}).get(kind, {}), **value["audio"]["endpoints"].get(kind, {})}
    if previous != value:
        write(path, value)


def install():
    if lease_status()["active"] or other_game_active():
        raise RuntimeError("Encerre jogo/frontend antes de registrar preferências do desktop.")
    directory = config_dir()
    path = directory / "desktop-session.json"
    unit = directory.parent / "systemd/user" / UNIT
    if unit.is_symlink() or (unit.exists() and "X-PhaseZero-Managed" not in unit.read_text()):
        raise RuntimeError("Unit pessoal/symlink preservada.")
    previous = read(path)
    if previous and (previous.get("managed_by") != "phasezero-input" or previous.get("schema_version") != 1):
        raise RuntimeError("Configuração pessoal preservada.")
    write(path, {"schema_version": 1, "managed_by": "phasezero-input",
                 "command": [sys.executable, str(Path(__file__).resolve())]})
    if not (state_dir() / "preferences.json").exists():
        capture_preferences()
    unit.parent.mkdir(parents=True, exist_ok=True)
    quote = lambda value: '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'
    unit.write_text("# X-PhaseZero-Managed=input-restore\n[Unit]\nDescription=PhaseZero desktop input and audio recovery\n"
                    "After=graphical-session.target pipewire-pulse.service wireplumber.service biglinux-microphone.service\n"
                    "PartOf=graphical-session.target\n"
                    "StartLimitIntervalSec=0\n[Service]\nType=simple\nExecStart=" + quote(sys.executable) + " " +
                    quote(Path(__file__).resolve()) + " watch\nUMask=0077\nRestart=always\nRestartSec=5\n"
                    "[Install]\nWantedBy=graphical-session.target\n")
    for args in (("daemon-reload",), ("enable", "--now", UNIT)):
        result = run("systemctl", "--user", *args, timeout=20)
        if result.returncode:
            raise RuntimeError(result.stderr or "Falha ao habilitar recuperação no login.")
    return {"ok": True, "unit": UNIT}


def watch():
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / "guardian.lock"
    if path.is_symlink():
        raise RuntimeError("Lock symlink preservado.")
    with path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        restoring, previous_game, last_error = True, False, None
        while True:
            try:
                errors = protect_input() + keyboard_restore()
                if errors:
                    raise RuntimeError(", ".join(errors))
                active = lease_status()["active"] or other_game_active()
                if previous_game and not active:
                    restoring = True
                if not active:
                    if restoring:
                        # Steam's existing independent guardian owns its API.
                        # Local input/audio must never wait for that API.
                        result = reconcile()
                        if not result["ok"]:
                            raise RuntimeError(", ".join(result["errors"]))
                        restoring = False
                    else:
                        # User adjustments in desktop become the next pre-game baseline.
                        # Do not continuously force an old mute/volume preference.
                        capture_preferences()
                previous_game, last_error = active, None
            except (OSError, ValueError, RuntimeError) as exc:
                restoring = True
                if str(exc) != last_error:
                    print(f"Recuperação pendente: {exc}", flush=True)
                    last_error = str(exc)
            time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("lease", "health", "reconcile", "install", "watch", "capture"))
    action = parser.parse_args().action
    try:
        if action == "watch":
            watch()
            return 0
        actions = {"lease": lambda: {**lease_status(), "externalGameActive": other_game_active()}, "health": health, "install": install,
                   "reconcile": reconcile, "capture": capture_preferences}
        value = actions[action]()
        print(json.dumps(value, ensure_ascii=False))
        return 1 if isinstance(value, dict) and value.get("ok") is False else 0
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
