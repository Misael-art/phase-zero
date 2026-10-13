"""Detection and installation of optional dependencies.

Installing system packages is a privileged, hard-to-reverse action, so it
follows the same shape as the rest of PhaseZero: report first, act only on an
explicit request, and never guess a package name for a distribution we have not
been told about.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

from .catalog import DEPENDENCIES, DepSpec

SCHEMA = "deps/v1"

# Package manager per distro family, with the flags that make it usable from a
# script: no prompts, no reinstall of what is already there.
INSTALLERS: dict[str, list[str]] = {
    "arch": ["pacman", "-S", "--needed", "--noconfirm"],
    "debian": ["apt-get", "install", "-y", "--no-install-recommends"],
    "fedora": ["dnf", "install", "-y"],
    "suse": ["zypper", "--non-interactive", "install"],
}


class DepsError(RuntimeError):
    pass


def distro_family() -> str:
    """Family id used to pick a package name and an installer.

    ID_LIKE is consulted because derivatives (BigLinux, Manjaro, Mint, ...)
    carry their own ID while packaging like their parent.
    """
    override = os.environ.get("PZ_DEPS_DISTRO_FAMILY", "").strip()
    if override:
        return override
    release = Path(os.environ.get("PZ_DEPS_OS_RELEASE", "/etc/os-release"))
    fields: dict[str, str] = {}
    try:
        for line in release.read_text(encoding="utf-8", errors="replace").splitlines():
            key, _, value = line.partition("=")
            if key:
                fields[key.strip()] = value.strip().strip('"')
    except OSError:
        return "unknown"
    candidates = [fields.get("ID", "")] + fields.get("ID_LIKE", "").split()
    for candidate in candidates:
        token = candidate.strip().lower()
        if token in ("arch", "archlinux"):
            return "arch"
        if token in ("debian", "ubuntu"):
            return "debian"
        if token in ("fedora", "rhel", "centos"):
            return "fedora"
        if token in ("suse", "opensuse", "sles"):
            return "suse"
    return "unknown"


def _present(spec: DepSpec) -> bool:
    if spec.probe == "python":
        try:
            return importlib.util.find_spec(spec.probe_target) is not None
        except (ImportError, ValueError):
            return False
    if spec.probe == "binary":
        return shutil.which(spec.probe_target) is not None
    if spec.probe == "path":
        return Path(spec.probe_target).exists()
    raise DepsError(f"probe desconhecido: {spec.probe}")


# AUR helpers, in preference order. AUR packages must never go through
# pacman -S, and helpers must never run elevated (yay refuses root).
AUR_HELPERS = ("yay", "paru")


def aur_helper() -> str:
    for helper in AUR_HELPERS:
        if shutil.which(helper):
            return helper
    return ""


def inspect(dep_id: str) -> dict:
    spec = DEPENDENCIES.get(dep_id)
    if spec is None:
        raise DepsError(f"dependência desconhecida: {dep_id}")
    family = distro_family()
    package = spec.packages.get(family, "")
    provider = spec.providers.get(family, "official")
    present = _present(spec)
    entry = {
        "id": spec.id,
        "title": spec.title,
        "present": present,
        "degrades": spec.degrades,
        "package": package,
        "provider": provider,
        "requiredBy": list(spec.required_by),
        "family": family,
    }
    if present:
        entry["installable"] = False
        entry["reason"] = ""
        return entry
    # Absent and we know neither the package nor the installer: say so instead
    # of offering a button that cannot work.
    if not package:
        entry["installable"] = False
        entry["reason"] = f"pacote desconhecido para a distribuição ({family}); instale manualmente"
    elif family not in INSTALLERS:
        entry["installable"] = False
        entry["reason"] = f"gerenciador de pacotes desconhecido para {family}"
    elif provider == "aur" and not aur_helper():
        # PZ-AUD-026: an AUR package without a helper is not installable;
        # offering `pacman -S pkg-git` would fail on a clean host.
        entry["installable"] = False
        entry["reason"] = (
            "pacote AUR sem helper instalado (yay/paru); "
            "instale um helper ou o pacote manualmente"
        )
    else:
        entry["installable"] = True
        entry["reason"] = ""
        if provider == "aur":
            entry["command"] = f"{aur_helper()} -S --needed --noconfirm {package}"
        else:
            entry["command"] = " ".join([*INSTALLERS[family], package])
    return entry


def status() -> dict:
    entries = [inspect(dep_id) for dep_id in DEPENDENCIES]
    missing = [e for e in entries if not e["present"]]
    return {
        "schema": SCHEMA,
        "family": distro_family(),
        "dependencies": entries,
        "missingCount": len(missing),
        # Only what a button could actually fix; the rest needs a human.
        "installable": [e["id"] for e in missing if e.get("installable")],
    }


def install(dep_ids: list[str], *, runner=None) -> dict:
    """Installs the named dependencies. `runner` receives the argv list."""
    if not dep_ids:
        raise DepsError("informe ao menos uma dependência")
    family = distro_family()
    installer = INSTALLERS.get(family)
    if installer is None:
        raise DepsError(f"gerenciador de pacotes desconhecido para {family}")

    packages: list[str] = []
    aur_packages: list[str] = []
    skipped: list[dict] = []
    for dep_id in dep_ids:
        entry = inspect(dep_id)
        if entry["present"]:
            skipped.append({"id": dep_id, "reason": "já instalada"})
            continue
        if not entry.get("installable"):
            skipped.append({"id": dep_id, "reason": entry["reason"]})
            continue
        if entry.get("provider") == "aur":
            aur_packages.append(entry["package"])
        else:
            packages.append(entry["package"])

    output_parts: list[str] = []
    code = 0
    if packages:
        argv = [*installer, *packages]
        run = runner or _default_runner
        code, output = run(argv)
        output_parts.append(output)
    if aur_packages:
        # PZ-AUD-026: AUR helpers run as the user, never elevated.
        helper = aur_helper()
        if not helper:
            for dep_id in dep_ids:
                if inspect(dep_id).get("provider") == "aur" and not _present(DEPENDENCIES[dep_id]):
                    skipped.append({"id": dep_id, "reason": "helper AUR ausente na hora de instalar"})
            aur_packages = []
        else:
            aur_argv = [helper, "-S", "--needed", "--noconfirm", *aur_packages]
            proc = subprocess.run(aur_argv, capture_output=True, text=True, timeout=1800)
            output_parts.append((proc.stdout or "") + (proc.stderr or ""))
            if proc.returncode != 0:
                code = proc.returncode
    # Re-probe rather than trusting the package manager's exit code: a package
    # can install and still not provide what we probe for.
    verified = [dep_id for dep_id in dep_ids if dep_id not in {s["id"] for s in skipped} and _present(DEPENDENCIES[dep_id])]
    unresolved = [
        dep_id
        for dep_id in dep_ids
        if dep_id not in {s["id"] for s in skipped} and dep_id not in verified
    ]
    output = "\n".join(output_parts)
    if not packages and not aur_packages:
        return {
            "schema": SCHEMA,
            "status": "noop",
            "installed": [],
            "unresolved": unresolved,
            "skipped": skipped,
            "command": "",
            "exitCode": code,
            "output": output[-2000:],
        }
    commands = []
    if packages:
        commands.append(" ".join([*installer, *packages]))
    if aur_packages:
        commands.append(f"{aur_helper()} -S --needed --noconfirm {' '.join(aur_packages)}")
    return {
        "schema": SCHEMA,
        "status": "complete" if code == 0 and not unresolved else "failed",
        "installed": verified,
        "unresolved": unresolved,
        "skipped": skipped,
        "command": " && ".join(commands),
        "exitCode": code,
        "output": output[-2000:],
    }


def _default_runner(argv: list[str]) -> tuple[int, str]:
    """Elevates through the admin bridge the rest of the product already uses."""
    bridge = shutil.which("phasezero-admin") or shutil.which("bigsudo")
    if os.geteuid() == 0:
        command = argv
    elif bridge:
        command = [bridge, *argv]
    else:
        raise DepsError(
            "sem admin bridge para elevar privilégio; instale com: linux/pz ai setup admin"
        )
    proc = subprocess.run(command, capture_output=True, text=True, timeout=1800)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
