"""Single answer to "does this app already exist on the host, by any channel?"

Installers (profiles, capabilities, AppImage/desktop scripts) ask before
installing so PhaseZero never stacks a second copy of an app the host already
has from pacman/AUR, a meta-package, a system or user Flatpak, an upstream
script or an AppImage.

CLI (used by the Bash installers):
    python3 -m linux.capabilities.presence pacman NAME
    python3 -m linux.capabilities.presence flatpak APP_ID
Exit 0 and prints "<canal>\\t<evidência>" when an EQUIVALENT is present.
Exit 1 when nothing equivalent exists, or when the exact same package/app is
already installed (the package manager's own --needed handles that case).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

HERE = Path(__file__).resolve().parent


def c_env() -> dict[str, str]:
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    env["LANG"] = "C"
    env["LANGUAGE"] = ""
    return env


@dataclass
class Group:
    id: str
    pacman: set[str] = field(default_factory=set)
    flatpak: set[str] = field(default_factory=set)
    bins: list[str] = field(default_factory=list)


@lru_cache(maxsize=1)
def groups() -> tuple[Group, ...]:
    from .catalog import CAPABILITIES, PRESENCE_BINARIES

    by_id: dict[str, Group] = {}
    for capability in CAPABILITIES:
        group = by_id.setdefault(capability.id, Group(capability.id))
        for source in capability.sources:
            if source.kind == "flatpak":
                group.flatpak.add(source.name)
            elif "arch" in source.distros:
                group.pacman.add(source.name)
        group.bins.extend(PRESENCE_BINARIES.get(capability.id, ()))
    data = json.loads((HERE / "equivalents.json").read_text(encoding="utf-8"))
    for capability_id, extra in data.get("extend", {}).items():
        group = by_id.setdefault(capability_id, Group(capability_id))
        group.pacman.update(extra.get("pacman", ()))
        group.flatpak.update(extra.get("flatpak", ()))
        group.bins.extend(extra.get("bin", ()))
    for raw in data.get("groups", ()):
        group = by_id.setdefault(str(raw["id"]), Group(str(raw["id"])))
        group.pacman.update(raw.get("pacman", ()))
        group.flatpak.update(raw.get("flatpak", ()))
        group.bins.extend(raw.get("bin", ()))
    return tuple(by_id.values())


def _run(command: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=20,
                              check=False, env=c_env())
    except (OSError, subprocess.TimeoutExpired):
        return None


def pacman_exact(name: str) -> bool:
    if not shutil.which("pacman"):
        return False
    result = _run(["pacman", "-Qq", "--", name])
    return bool(result and result.returncode == 0)


def pacman_satisfied(name: str) -> bool:
    """True when an installed package provides NAME (resolves `provides`)."""
    if not shutil.which("pacman"):
        return False
    result = _run(["pacman", "-T", name])
    return bool(result and result.returncode == 0)


def flatpak_scopes(app_id: str) -> list[str]:
    if not shutil.which("flatpak"):
        return []
    found = []
    for scope in ("--user", "--system"):
        result = _run(["flatpak", "info", scope, app_id])
        if result and result.returncode == 0:
            found.append(scope.lstrip("-"))
    return found


def search_path() -> str:
    home = Path.home()
    dirs = [entry for entry in os.environ.get("PATH", "").split(os.pathsep) if entry]
    dirs += ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/opt/bin",
             "/var/lib/snapd/snap/bin", str(home / ".local/bin"), str(home / "bin"),
             str(home / ".nix-profile/bin"), str(home / ".cargo/bin")]
    return os.pathsep.join(dict.fromkeys(dirs))


def live_executable(path: str) -> bool:
    """False for launcher scripts whose every `exec /abs/target` is gone, and
    for PhaseZero's own managed launchers (they are not a foreign install)."""
    candidate = Path(path)
    try:
        if candidate.stat().st_size > 65536:
            return True
        with candidate.open("rb") as handle:
            if handle.read(2) != b"#!":
                return True
        text = candidate.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    if "PhaseZero managed" in text:
        return False
    targets = re.findall(r"^\s*exec\s+(?:-a\s+\S+\s+)?[\"']?(/[^\s\"']+)", text, re.MULTILINE)
    return not targets or any(Path(target).exists() for target in targets)


def binary_presence(names: list[str]) -> str | None:
    path = search_path()
    for name in names:
        found = shutil.which(name, path=path)
        if found and live_executable(found):
            return found
    return None


def equivalent(kind: str, name: str) -> tuple[str, str] | None:
    """Equivalent install of KIND/NAME from another channel, or None."""
    if kind == "pacman":
        if pacman_exact(name):
            return None
        if pacman_satisfied(name):
            return ("pacman", f"pacote que fornece {name}")
    elif kind == "flatpak":
        if "user" in flatpak_scopes(name):
            return None
        if flatpak_scopes(name):
            return ("flatpak", f"{name} (sistema)")
    else:
        raise ValueError(f"tipo desconhecido: {kind}")
    for group in groups():
        members = group.pacman if kind == "pacman" else group.flatpak
        if name not in members:
            continue
        for other in sorted(group.pacman - ({name} if kind == "pacman" else set())):
            if pacman_exact(other) or pacman_satisfied(other):
                return ("pacman", other)
        for other in sorted(group.flatpak - ({name} if kind == "flatpak" else set())):
            scopes = flatpak_scopes(other)
            if scopes:
                return ("flatpak", f"{other} ({scopes[0]})")
        found = binary_presence(group.bins)
        if found:
            return ("programa", found)
    return None


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in {"pacman", "flatpak"}:
        print("uso: python3 -m linux.capabilities.presence (pacman|flatpak) NOME", file=sys.stderr)
        return 2
    hit = equivalent(argv[0], argv[1])
    if hit is None:
        return 1
    print(f"{hit[0]}\t{hit[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
