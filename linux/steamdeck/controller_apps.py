#!/usr/bin/env python3
"""Per-application compatibility layer for the Deck desktop controller map.

The desktop profile sends the shortcuts most KDE/Qt applications share: L1/R1
are Ctrl+Shift+Tab / Ctrl+Tab. Some applications bind different keys for the
same job. Ashyterm (BigCommunity's GTK4 terminal) switches tabs with
Ctrl+Page_Up / Ctrl+Page_Down and lets Ctrl+Tab reach the shell, so on the
shoulders the desktop map did nothing visible there.

Two pieces fix that without touching the application:

* ``generate`` derives one sc-controller profile per known application from
  the desktop profile, replacing only the bindings whose job the application
  does with another shortcut. The shortcuts come from the application's own
  effective configuration (defaults merged with the user's overrides), read at
  generation time, so a user who rebinds "next tab" in Ashyterm gets that key.
* ``watch`` follows the focused window (``kdotool`` works on KWin Wayland) and
  asks the running daemon to switch profiles when focus crosses an
  application boundary. It never restarts the daemon and never writes to the
  application's configuration.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

DESKTOP_PROFILE = "PhaseZero-Desktop"


@dataclass(frozen=True)
class AppCompat:
    key: str
    title: str
    window_classes: tuple[str, ...]
    profile: str
    settings_path: str
    settings_key: str
    # Default accelerators of the application (GTK notation).
    defaults: dict[str, str]
    # controller button -> (application action, human name)
    bindings: dict[str, tuple[str, str]] = field(default_factory=dict)


APPS: tuple[AppCompat, ...] = (
    AppCompat(
        key="ashyterm",
        title="Ashyterm",
        window_classes=("org.communitybig.ashyterm", "ashyterm"),
        profile="PhaseZero-Ashyterm",
        settings_path="ashyterm/settings.json",
        settings_key="shortcuts",
        # ashyterm/settings/config.py, DEFAULT_SETTINGS["shortcuts"].
        defaults={
            "previous-tab": "<Control>Page_Up",
            "next-tab": "<Control>Page_Down",
        },
        bindings={
            "LB": ("previous-tab", "Aba anterior"),
            "RB": ("next-tab", "Proxima aba"),
        },
    ),
)

_MODIFIERS = {
    "control": "KEY_LEFTCTRL",
    "ctrl": "KEY_LEFTCTRL",
    "primary": "KEY_LEFTCTRL",
    "shift": "KEY_LEFTSHIFT",
    "alt": "KEY_LEFTALT",
    "mod1": "KEY_LEFTALT",
    "super": "KEY_LEFTMETA",
    "meta": "KEY_LEFTMETA",
}

_KEYS = {
    "page_up": "KEY_PAGEUP",
    "prior": "KEY_PAGEUP",
    "page_down": "KEY_PAGEDOWN",
    "next": "KEY_PAGEDOWN",
    "tab": "KEY_TAB",
    "iso_left_tab": "KEY_TAB",
    "return": "KEY_ENTER",
    "escape": "KEY_ESC",
    "backspace": "KEY_BACKSPACE",
    "space": "KEY_SPACE",
    "comma": "KEY_COMMA",
    "period": "KEY_DOT",
    "equal": "KEY_EQUAL",
    "minus": "KEY_MINUS",
    "plus": "KEY_KPPLUS",
    "left": "KEY_LEFT",
    "right": "KEY_RIGHT",
    "up": "KEY_UP",
    "down": "KEY_DOWN",
    "home": "KEY_HOME",
    "end": "KEY_END",
    "insert": "KEY_INSERT",
    "delete": "KEY_DELETE",
}


def accel_to_scc(accel: str) -> str | None:
    """Translate a GTK accelerator ("<Control>Page_Up") to an scc action.

    Returns None for an empty (disabled) or unknown accelerator; the caller
    keeps the desktop binding rather than emitting a guess.
    """
    text = (accel or "").strip()
    if not text:
        return None
    keys: list[str] = []
    while text.startswith("<"):
        end = text.find(">")
        if end < 0:
            return None
        modifier = _MODIFIERS.get(text[1:end].casefold())
        if modifier is None:
            return None
        if modifier not in keys:
            keys.append(modifier)
        text = text[end + 1:]
    name = text.strip()
    if not name:
        return None
    lowered = name.casefold()
    if lowered in _KEYS:
        key = _KEYS[lowered]
    elif len(name) == 1 and name.isalnum():
        key = f"KEY_{name.upper()}"
    elif lowered.startswith("f") and lowered[1:].isdigit() and 1 <= int(lowered[1:]) <= 24:
        key = f"KEY_F{int(lowered[1:])}"
    else:
        return None
    keys.append(key)
    return " and ".join(f"button(Keys.{item})" for item in keys)


def config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def effective_shortcuts(app: AppCompat) -> dict[str, str]:
    """Application defaults merged with the user's overrides (read-only)."""
    shortcuts = dict(app.defaults)
    path = config_home() / app.settings_path
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return shortcuts
    user = data.get(app.settings_key) if isinstance(data, dict) else None
    if isinstance(user, dict):
        for action in app.defaults:
            if action in user and isinstance(user[action], str):
                shortcuts[action] = user[action]
    return shortcuts


def build_profile(base: dict, app: AppCompat) -> tuple[dict, list[str]]:
    """Desktop profile with the application's bindings swapped in."""
    profile = copy.deepcopy(base)
    buttons = profile.setdefault("buttons", {})
    shortcuts = effective_shortcuts(app)
    notes: list[str] = []
    for button, (action, name) in app.bindings.items():
        scc_action = accel_to_scc(shortcuts.get(action, ""))
        if scc_action is None:
            notes.append(f"{app.title}: '{action}' sem atalho utilizável; {button} mantém o mapa desktop")
            continue
        buttons[button] = {"action": scc_action, "name": f"{name} ({app.title})"}
    return profile, notes


def generate(base_path: Path, out_dir: Path) -> dict:
    base = json.loads(base_path.read_text(encoding="utf-8"))
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {"profiles": [], "notes": []}
    for app in APPS:
        profile, notes = build_profile(base, app)
        target = out_dir / f"{app.profile}.sccprofile"
        target.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        report["profiles"].append({"app": app.key, "profile": app.profile, "path": str(target)})
        report["notes"].extend(notes)
    return report


def profile_for_class(window_class: str) -> str:
    lowered = (window_class or "").strip().casefold()
    for app in APPS:
        if lowered in {name.casefold() for name in app.window_classes}:
            return app.profile
    return DESKTOP_PROFILE


# Fixed argv, resolved through PATH (tests put stubs first on PATH). The
# environment never chooses what gets executed.
ACTIVE_WINDOW_ARGV = ("kdotool", "getactivewindow", "getwindowclassname")
SET_PROFILE_ARGV = ("scc", "set-profile")
KNOWN_PROFILES = frozenset({DESKTOP_PROFILE, *(app.profile for app in APPS)})


def active_window_class() -> str:
    """Class of the focused window, or "" when it cannot be read."""
    try:
        proc = subprocess.run(
            list(ACTIVE_WINDOW_ARGV), capture_output=True, text=True, timeout=2, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return proc.stdout.strip().splitlines()[-1] if proc.returncode == 0 and proc.stdout.strip() else ""


def set_profile(profile: str) -> bool:
    # Only names from the table reach the daemon.
    if profile not in KNOWN_PROFILES:
        return False
    try:
        proc = subprocess.run(
            [*SET_PROFILE_ARGV, profile], capture_output=True, text=True, timeout=5, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def watch(interval: float, once: bool = False) -> int:
    """Switch profiles as focus moves. Unreadable focus changes nothing."""
    current = ""
    while True:
        window_class = active_window_class()
        if window_class:
            wanted = profile_for_class(window_class)
            if wanted != current and set_profile(wanted):
                print(f"perfil: {wanted} ({window_class})", flush=True)
                current = wanted
        if once:
            return 0
        time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate", help="gera os perfis por aplicativo")
    gen.add_argument("--base", required=True, type=Path)
    gen.add_argument("--out-dir", required=True, type=Path)
    run = sub.add_parser("watch", help="troca o perfil conforme a janela em foco")
    run.add_argument("--interval", type=float, default=0.5)
    run.add_argument("--once", action="store_true")
    sub.add_parser("list", help="aplicativos com camada de compatibilidade")
    args = parser.parse_args(argv)
    if args.command == "generate":
        print(json.dumps(generate(args.base, args.out_dir), ensure_ascii=False))
        return 0
    if args.command == "watch":
        return watch(args.interval, args.once)
    print(json.dumps([
        {"app": app.key, "title": app.title, "profile": app.profile,
         "windowClasses": list(app.window_classes), "shortcuts": effective_shortcuts(app)}
        for app in APPS
    ], ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
