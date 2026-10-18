#!/usr/bin/env python3
"""On-demand host repair entrypoints. Installation never executes a repair."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REPAIRS = {"microfone": ("Reparar microfone", "audio-input-microphone"), "entrada": ("Reparar entrada", "input-touchpad")}


def install_shortcuts():
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share"))
    result = subprocess.run(["xdg-user-dir", "DESKTOP"], text=True, capture_output=True, check=False) if shutil.which("xdg-user-dir") else None
    desktop = Path(result.stdout.strip()) if result and result.returncode == 0 and result.stdout.strip() else home / "Desktop"
    if desktop == home or not desktop.is_absolute():
        raise RuntimeError("Diretório de área de trabalho inválido")
    for key, (label, icon) in REPAIRS.items():
        for directory in (data / "applications", desktop):
            directory.mkdir(parents=True, exist_ok=True)
            target = directory / ("phasezero-reparo-" + key + ".desktop")
            content = ("[Desktop Entry]\nType=Application\nName=" + label + "\nIcon=" + icon +
                       '\nExec=python3 "' + str(ROOT / "linux/repairs/manager.py") + '" run ' + key +
                       " --confirm\nTerminal=false\nCategories=System;Utility;\nX-PhaseZero-Managed=true\n")
            if target.is_symlink():
                raise RuntimeError("Atalho symlink preservado: " + str(target))
            if target.exists() and "X-PhaseZero-Managed=true" not in target.read_text():
                raise RuntimeError("Atalho não gerenciado preservado: " + str(target))
            if target.is_file() and target.read_text() == content and target.stat().st_mode & 0o777 == 0o755:
                continue
            fd, staging = tempfile.mkstemp(prefix=".phasezero-repair-", dir=directory)
            try:
                with os.fdopen(fd, "w") as handle:
                    handle.write(content)
                    os.fchmod(handle.fileno(), 0o755)
                os.replace(staging, target)
            finally:
                Path(staging).unlink(missing_ok=True)
    return {"installed": True, "automaticRepair": False, "desktop": str(desktop)}


def status():
    return {"schemaVersion": 1, "automaticRepair": False,
            "microfone": {"available": bool(shutil.which("pactl") and shutil.which("systemctl"))},
            "entrada": {"available": Path("/sys/devices/platform/AMDI0010:01").is_dir(), "adminRequired": True}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "status", "run"), default="status", nargs="?")
    parser.add_argument("repair", choices=REPAIRS, nargs="?")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--yes", action="store_true")
    args = parser.parse_args()
    if args.action == "install":
        print(json.dumps(install_shortcuts())); return 0
    observed = status()
    if args.action == "status":
        print(json.dumps(observed)); return 0
    if not args.repair:
        parser.error("Selecione microfone ou entrada")
    if not observed[args.repair]["available"]:
        print("Reparo indisponível: hardware ou dependência ausente", file=__import__("sys").stderr); return 69
    message = ("Reparo sob demanda pode interromper áudio." if args.repair == "microfone" else
               "Reparo sob demanda pode interromper touch e controles; exige autorização administrativa.")
    if not args.yes:
        if not args.confirm or not shutil.which("kdialog"):
            print(message + " Execute com --confirm (gráfico) ou --yes."); return 2
        if subprocess.run(["kdialog", "--yesno", message + " Executar agora?"], check=False).returncode:
            return 1
    return subprocess.run(["bash", str(ROOT / ("linux/repairs/reparo-" + args.repair + ".sh"))], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
