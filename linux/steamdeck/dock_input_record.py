#!/usr/bin/env python3
"""Passive recorder for input state across dock / undock (LUX-033).

The report is that after the Deck leaves the dock the touch screen stops
working as a pointer in KDE. Nobody has captured the moment. Asking the user
to run a probe right then does not work: the pointer is the thing that is
gone. This recorder waits for the external connector to change by itself and
writes what it sees, so the evidence exists the next time it happens.

It only reads. It opens evdev nodes shared and non-blocking, never grabs
them, never restarts the controller map or KWin, and writes nothing outside
its own state directory.

Two things are recorded per transition, because they answer different
questions:

* a ``state`` record straight away: which connectors are connected, whether
  the touch screen and the SCController nodes still exist, what KWin says
  about each (enabled, output it is mapped to) and the controller unit.
* a ``sample`` record after a listening window: how many kernel events each
  node produced. Events with a dead pointer put the fault above the kernel.
  No events prove nothing - maybe nobody touched the screen.
"""
from __future__ import annotations

import argparse
import json
import os
import select
import struct
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = 1
EVENT_FORMAT = "16xHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)
EV_KEY, EV_REL, EV_ABS = 1, 2, 3
INPUT_PROP_DIRECT = 0x2
MAX_RECORDS = 400
CONTROLLER_UNIT = "phasezero-controller-desktop.service"


def state_dir() -> Path:
    override = os.environ.get("PZ_DOCK_RECORD_DIR")
    if override:
        return Path(override)
    root = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(root) / "phasezero" / "dock-input"


def drm_root() -> Path:
    return Path(os.environ.get("PZ_DRM_ROOT", "/sys/class/drm"))


def read_connectors() -> dict[str, dict[str, str]]:
    """Connector name -> status/enabled, as the kernel reports them."""
    result: dict[str, dict[str, str]] = {}
    root = drm_root()
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return result
    for entry in entries:
        status_file = entry / "status"
        if not status_file.is_file():
            continue
        # card1-eDP-1 -> eDP-1
        name = entry.name.split("-", 1)[1] if "-" in entry.name else entry.name
        result[name] = {
            "status": _read_text(status_file),
            "enabled": _read_text(entry / "enabled"),
        }
    return result


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return "unknown"


def external_connected(connectors: dict[str, dict[str, str]]) -> bool:
    return any(
        info["status"] == "connected"
        for name, info in connectors.items()
        if not name.startswith(("eDP", "LVDS", "DSI", "Writeback"))
    )


def read_input_devices() -> list[dict[str, object]]:
    path = Path(os.environ.get("PZ_INPUT_DEVICES_FILE", "/proc/bus/input/devices"))
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    devices = []
    for block in text.split("\n\n"):
        name = ""
        event = ""
        direct = False
        for line in block.splitlines():
            if line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("H: Handlers="):
                for token in line.split("=", 1)[1].split():
                    if token.startswith("event") and token[5:].isdigit():
                        event = token
            elif line.startswith("B: PROP="):
                try:
                    direct = bool(int(line.split("=", 1)[1].split()[-1], 16) & INPUT_PROP_DIRECT)
                except ValueError:
                    direct = False
        if name and event:
            devices.append({"name": name, "event": event, "direct": direct})
    return devices


def pick_devices(devices: list[dict[str, object]]) -> dict[str, dict[str, object] | None]:
    """The three nodes the incident is about. None when the node is gone."""
    picked: dict[str, dict[str, object] | None] = {
        "touchscreen": None,
        "sccMouse": None,
        "sccKeyboard": None,
    }
    for device in devices:
        name = device["name"]
        # The panel registers several nodes under almost the same name. Only
        # the one flagged INPUT_PROP_DIRECT carries touch contacts.
        if picked["touchscreen"] is None and device.get("direct"):
            picked["touchscreen"] = device
        elif name == "SCController Mouse":
            picked["sccMouse"] = device
        elif name == "SCController Keyboard":
            picked["sccKeyboard"] = device
    return picked


def kwin_properties(event: str) -> dict[str, object]:
    """What KWin holds for one evdev node. Empty when it cannot be asked."""
    qdbus = os.environ.get("PZ_QDBUS6", "qdbus6")
    result: dict[str, object] = {}
    for prop in ("enabled", "outputName", "touch", "pointer"):
        try:
            done = subprocess.run(
                [
                    qdbus, "org.kde.KWin", f"/org/kde/KWin/InputDevice/{event}",
                    "org.freedesktop.DBus.Properties.Get", "org.kde.KWin.InputDevice", prop,
                ],
                capture_output=True, text=True, timeout=2, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return {}
        if done.returncode != 0:
            return {}
        value = done.stdout.strip().splitlines()[-1] if done.stdout.strip() else ""
        result[prop] = {"true": True, "false": False}.get(value, value)
    return result


def controller_service() -> dict[str, str]:
    systemctl = os.environ.get("PZ_SYSTEMCTL", "systemctl")
    try:
        done = subprocess.run(
            [systemctl, "--user", "show", CONTROLLER_UNIT,
             "-p", "ActiveState", "-p", "NRestarts", "-p", "MainPID", "--no-pager"],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {}
    values = {}
    for line in done.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def collect_state(reason: str) -> dict[str, object]:
    connectors = read_connectors()
    picked = pick_devices(read_input_devices())
    devices: dict[str, object] = {}
    for role, device in picked.items():
        if device is None:
            devices[role] = {"present": False}
        else:
            devices[role] = {
                "present": True,
                "name": device["name"],
                "event": device["event"],
                "kwin": kwin_properties(str(device["event"])),
            }
    return {
        "schema": SCHEMA,
        "kind": "state",
        "at": _now(),
        "reason": reason,
        "docked": external_connected(connectors),
        "connectors": connectors,
        "devices": devices,
        "controllerService": controller_service(),
        "session": {
            "id": os.environ.get("XDG_SESSION_ID") or None,
            "desktop": os.environ.get("XDG_CURRENT_DESKTOP") or None,
            "type": os.environ.get("XDG_SESSION_TYPE") or None,
        },
        "mutated": False,
        "grabbed": False,
    }


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def count_events(paths: dict[str, str], seconds: float) -> dict[str, dict[str, object]]:
    """Count kernel events per node without grabbing. Missing node is recorded."""
    opened: dict[int, str] = {}
    result: dict[str, dict[str, object]] = {}
    for role, path in paths.items():
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            result[role] = {"opened": False, "errno": exc.errno, "events": None}
            continue
        opened[fd] = role
        result[role] = {"opened": True, "errno": None, "events": 0}
    end = time.monotonic() + seconds
    try:
        while opened and time.monotonic() < end:
            remain = end - time.monotonic()
            ready, _, _ = select.select(list(opened), [], [], max(0.0, min(0.2, remain)))
            for fd in ready:
                if fd not in opened:
                    continue
                role = opened[fd]
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    # ENODEV: the node went away while we listened.
                    result[role]["errno"] = exc.errno
                    os.close(fd)
                    del opened[fd]
                    continue
                if not data:
                    # End of stream: nothing more will come from this node.
                    os.close(fd)
                    del opened[fd]
                    continue
                for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                    kind, _code, _value = struct.unpack_from(EVENT_FORMAT, data, offset)
                    if kind in (EV_KEY, EV_REL, EV_ABS):
                        result[role]["events"] = int(result[role]["events"] or 0) + 1
    finally:
        for fd in opened:
            os.close(fd)
    return result


def collect_sample(state: dict[str, object], seconds: float) -> dict[str, object]:
    dev_root = Path(os.environ.get("PZ_INPUT_DEV_ROOT", "/dev/input"))
    paths = {}
    devices = state["devices"]
    assert isinstance(devices, dict)
    for role in ("touchscreen", "sccMouse"):
        info = devices.get(role)
        if isinstance(info, dict) and info.get("present"):
            paths[role] = str(dev_root / str(info["event"]))
    return {
        "schema": SCHEMA,
        "kind": "sample",
        "at": _now(),
        "afterStateAt": state["at"],
        "docked": state["docked"],
        "seconds": seconds,
        "nodes": count_events(paths, seconds) if seconds > 0 else {},
        "grabbed": False,
    }


def append_record(record: dict[str, object]) -> Path:
    directory = state_dir()
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    path = directory / "records.jsonl"
    lines: list[str] = []
    if path.is_file():
        lines = path.read_text(encoding="utf-8").splitlines()
    lines.append(json.dumps(record, ensure_ascii=False, sort_keys=True))
    # Bounded: a flapping connector must not fill the disk.
    lines = lines[-MAX_RECORDS:]
    tmp = path.with_suffix(".jsonl.tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return path


def load_records() -> list[dict[str, object]]:
    path = state_dir() / "records.jsonl"
    records = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return records
    for line in lines:
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


def judge(before: dict[str, object] | None, after: dict[str, object],
          sample: dict[str, object] | None) -> dict[str, dict[str, str]]:
    """One finding per input path. Says "not-proven" unless the record shows it."""
    findings = {}
    connectors = after.get("connectors") or {}
    assert isinstance(connectors, dict)
    connected = {name for name, info in connectors.items() if info.get("status") == "connected"}
    devices = after.get("devices") or {}
    assert isinstance(devices, dict)
    nodes = (sample or {}).get("nodes") or {}
    assert isinstance(nodes, dict)
    for role in ("touchscreen", "sccMouse"):
        info = devices.get(role) or {}
        was = ((before or {}).get("devices") or {}).get(role) or {}  # type: ignore[union-attr]
        if not info.get("present"):
            if was.get("present"):
                findings[role] = {"finding": "node-gone", "detail": "the kernel node existed before the transition and is gone after it"}
            else:
                findings[role] = {"finding": "node-absent", "detail": "no kernel node before or after"}
            continue
        kwin = info.get("kwin") or {}
        if kwin.get("enabled") is False:
            findings[role] = {"finding": "kwin-disabled", "detail": "node exists but KWin has the device disabled"}
            continue
        output = kwin.get("outputName") or ""
        if output and output not in connected:
            findings[role] = {"finding": "mapped-to-missing-output", "detail": f"KWin maps the device to {output}, which is not connected"}
            continue
        node = nodes.get(role) or {}
        events = node.get("events")
        if isinstance(events, int) and events > 0:
            findings[role] = {"finding": "kernel-events-arrive", "detail": f"{events} events after the transition; a dead pointer is above the kernel"}
        elif node.get("opened") is False:
            findings[role] = {"finding": "not-proven", "detail": f"could not open the node (errno {node.get('errno')})"}
        else:
            findings[role] = {"finding": "not-proven", "detail": "node and KWin look normal and no event was seen in the window"}
    return findings


def build_report(records: list[dict[str, object]]) -> dict[str, object]:
    transitions = []
    previous: dict[str, object] | None = None
    for index, record in enumerate(records):
        if record.get("kind") != "state":
            continue
        if record.get("reason") == "transition":
            sample = None
            for later in records[index + 1:]:
                if later.get("kind") == "sample" and later.get("afterStateAt") == record.get("at"):
                    sample = later
                    break
                if later.get("kind") == "state":
                    break
            transitions.append({
                "at": record.get("at"),
                "direction": "dock" if record.get("docked") else "undock",
                "sampled": sample is not None,
                "findings": judge(previous, record, sample),
            })
        previous = record
    return {
        "schema": SCHEMA,
        "records": len(records),
        "transitions": transitions,
        "undocks": sum(1 for item in transitions if item["direction"] == "undock"),
    }


def cmd_once(_args: argparse.Namespace) -> int:
    state = collect_state("manual")
    append_record(state)
    print(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    state = collect_state("start")
    append_record(state)
    docked = bool(state["docked"])
    cycles = 0
    while args.max_transitions is None or cycles < args.max_transitions:
        time.sleep(args.interval)
        now_docked = external_connected(read_connectors())
        if now_docked == docked:
            continue
        docked = now_docked
        cycles += 1
        # KWin needs a moment to re-evaluate outputs; reading at once would
        # record the old mapping and call it the new one.
        time.sleep(args.settle)
        state = collect_state("transition")
        append_record(state)
        append_record(collect_sample(state, args.sample_seconds))
    return 0


def cmd_report(_args: argparse.Namespace) -> int:
    print(json.dumps(build_report(load_records()), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("once", help="record the current state once").set_defaults(func=cmd_once)
    watch = sub.add_parser("watch", help="record every dock/undock until stopped")
    watch.add_argument("--interval", type=float, default=1.0)
    watch.add_argument("--settle", type=float, default=3.0)
    watch.add_argument("--sample-seconds", type=float, default=45.0)
    watch.add_argument("--max-transitions", type=int, default=None)
    watch.set_defaults(func=cmd_watch)
    sub.add_parser("report", help="summarise recorded transitions").set_defaults(func=cmd_report)
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
