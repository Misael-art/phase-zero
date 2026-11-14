#!/usr/bin/env python3
"""Bounded crash diagnostics and reversible ICC/journal configuration.

Never changes boot arguments, loads a driver, or restarts a graphical session.
Only creates two owned drop-ins; existing configuration is never overwritten.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


OWNER = "phasezero-host-stability-v1"
DROPINS = {
    "etc/systemd/user/plasma-big-apply-icc.service.d/60-phasezero-no-greeter.conf":
        "# X-PhaseZero-Managed=" + OWNER + "\n[Unit]\nConditionUser=!sddm\n",
    "etc/systemd/journald.conf.d/60-phasezero-stability.conf":
        "# X-PhaseZero-Managed=" + OWNER +
        "\n[Journal]\nStorage=persistent\nSystemMaxUse=150M\nSyncIntervalSec=60s\n",
}
STATE = "var/lib/phasezero/repairs/stability/state.json"
VENDOR = "usr/lib/systemd/user/plasma-big-apply-icc.service"
JOURNAL_COMMAND = ["systemctl", "restart", "systemd-journald.service"]


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def observed(path):
    try:
        with Path(path).open() as stream:
            value = stream.read(131073)
        if len(value) > 131072:
            raise ValueError("leitura excede limite")
        return {"state": "ok", "value": value.strip()}
    except (OSError, ValueError) as exc:
        return {"state": "unknown", "reason": str(exc)}


def journal_settings(runner=subprocess.run):
    try:
        result = runner(["systemd-analyze", "cat-config", "systemd/journald.conf"],
                        capture_output=True, text=True, timeout=10, check=False)
        if result.returncode:
            raise RuntimeError("configuração efetiva indisponível")
        values, section = {}, ""
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("["):
                section = line
            elif section == "[Journal]" and "=" in line and not line.startswith(("#", ";")):
                key, value = line.split("=", 1)
                if key.strip() in {"Storage", "SystemMaxUse", "SyncIntervalSec"}:
                    values[key.strip()] = value.strip()
        return {"state": "ok", "values": values}
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        return {"state": "unknown", "reason": str(exc)}


def status(root=Path("/"), runner=subprocess.run):
    root = Path(root)
    cmdline = observed(root / "proc/cmdline")
    flags = cmdline.get("value", "").split() if cmdline["state"] == "ok" else None
    config = {}
    try:
        with gzip.open(root / "proc/config.gz", "rt") as stream:
            for line in stream.read(1024 * 1024).splitlines():
                for key in ("CONFIG_EFI_VARS_PSTORE_DEFAULT_DISABLE", "CONFIG_PSTORE_CONSOLE"):
                    if line.startswith(key + "=") or line == "# " + key + " is not set":
                        config[key] = line.split("=", 1)[1] if "=" in line else "n"
    except (OSError, EOFError):
        pass
    try:
        space = os.statvfs(root / "sys/firmware/efi/efivars")
        nvram = {"state": "ok", "availableBytes": space.f_bavail * space.f_frsize,
                 "totalBytes": space.f_blocks * space.f_frsize}
    except OSError as exc:
        nvram = {"state": "unknown", "reason": str(exc)}
    return {"schemaVersion": 1, "owner": OWNER, "mode": "read-only",
            "bootId": observed(root / "proc/sys/kernel/random/boot_id"),
            "iccVendor": observed(root / VENDOR),
            "dropins": {name: observed(root / name) for name in DROPINS},
            "journal": journal_settings(runner),
            "kernel": {"diagnosticDisablers": ([x for x in flags if x in {
                "nowatchdog", "nosoftlockup", "nomce", "tsc=nowatchdog"}]
                if flags is not None else None), "config": config,
                "watchdogs": {name: observed(root / "proc/sys/kernel" / name)
                              for name in ("watchdog", "nmi_watchdog", "soft_watchdog")}},
            "pstore": {"backend": observed(root / "sys/module/pstore/parameters/backend"),
                       "efiDisabled": observed(root / "sys/module/efi_pstore/parameters/pstore_disable"),
                       "efiVariables": nvram},
            "stabilityProven": False}


def plan(root=Path("/"), runner=subprocess.run):
    result = status(root, runner)
    result.update({"action": "plan", "changes": [
        {"path": "/" + path, "content": content, "previous": "must be absent"}
        for path, content in DROPINS.items()],
        "activation": "Restart only systemd-journald; ICC exclusion loads at next natural greeter login.",
        "rollback": "pz repair stability rollback --yes; remove only unchanged owned drop-ins.",
        "captureGates": [
            "EFI variable capacity and firmware compatibility must be established before enabling pstore.",
            "EFI partition free space does not measure EFI variable capacity.",
            "A backend alone cannot capture every silent lockup or power loss.",
            "Boot/watchdog/MCE changes require a recovery window and original boot entry.",
            "Kernel capture is not enabled by this repair; no panic or reboot test.",
            "Folego owns passive host samples; SteamZero owns Gamescope session instrumentation.",
        ]})
    return result


def secure_parent(root, path, create=False):
    """Reject links, other owners and writable ancestors of privileged writes."""
    current = root
    for part in path.parent.relative_to(root).parts:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if not create:
                raise RuntimeError("Diretório ausente: " + str(current))
            current.mkdir(mode=0o755)
            current.chmod(0o755)
            info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise RuntimeError("Diretório inseguro preservado: " + str(current))


def existing(root, path):
    secure_parent(root, path)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or info.st_mode & 0o022 or info.st_size > 32768):
        raise RuntimeError("Arquivo pessoal/inseguro preservado: " + str(path))
    return path.read_text()


def atomic(root, path, content, *, replace=False, mode=0o600):
    secure_parent(root, path, create=True)
    if replace:
        existing(root, path)
    fd, name = tempfile.mkstemp(prefix=".phasezero-stability-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(name, path)
        else:
            os.link(name, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(name).unlink(missing_ok=True)


@contextmanager
def transaction(root):
    path = root / STATE
    secure_parent(root, path, create=True)
    path.parent.chmod(0o700)
    fd = os.open(path.parent / "repair.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise RuntimeError("Trava insegura preservada")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def read_state(root):
    raw = existing(root, root / STATE)
    if raw is None:
        return None
    value = json.loads(raw)
    if (not isinstance(value, dict) or value.get("owner") != OWNER or value.get("schemaVersion") != 1
            or value.get("previous") != "absent" or value.get("phase") not in {
                "prepared", "active", "configuration-blocked", "activation-pending",
                "activation-unknown", "rollback-pending", "rolled-back"}
            or value.get("files") != {p: digest(c) for p, c in DROPINS.items()}):
        raise RuntimeError("Estado desconhecido preservado")
    return value


def record(root, value, phase):
    value["phase"] = phase
    atomic(root, root / STATE, json.dumps(value, indent=2) + "\n", replace=True)


def activate(root, state, phase, runner):
    record(root, state, "activation-pending")
    try:
        result = runner(JOURNAL_COMMAND, capture_output=True, text=True, timeout=30, check=False)
        if result.returncode:
            raise RuntimeError("Reinício do journal retornou falha; conferir antes de repetir")
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        record(root, state, "activation-unknown")
        return {"ok": False, "state": "activation-unknown", "reason": str(exc),
                "next": "Verifique systemd-journald ou execute rollback explícito; não repetir às cegas."}
    record(root, state, phase)
    return {"ok": True, "state": phase, "changed": True, "stabilityProven": False,
            "iccPhysicalCheck": "Next natural greeter login; normal user profile must remain intact."}


def apply(root=Path("/"), runner=subprocess.run):
    root = Path(root)
    vendor = observed(root / VENDOR)
    if vendor.get("state") != "ok" or "ExecStart=icc_profile_apply enable" not in vendor["value"]:
        raise RuntimeError("Unit ICC esperada ausente/desconhecida; aplicação recusada")
    with transaction(root):
        state = read_state(root)
        for name, content in DROPINS.items():
            target = root / name
            secure_parent(root, target, create=True)
            raw = existing(root, target)
            if raw is not None and (state is None or raw != content):
                raise RuntimeError("Configuração preexistente/modificada preservada: " + name)
        if state and state["phase"] == "active":
            if any(existing(root, root / p) != c for p, c in DROPINS.items()):
                raise RuntimeError("Configuração aplicada mudou; conferir antes de repetir")
            return {"ok": True, "state": "active", "changed": False, "stabilityProven": False}
        if state and state["phase"] != "rolled-back":
            raise RuntimeError("Operação anterior incompleta; verificar ou reverter antes de repetir")
        before = journal_settings(runner).get("values", {})
        cap = re.fullmatch(r"([0-9]+)([KMGT]?)", before.get("SystemMaxUse", ""))
        interval = re.fullmatch(r"([0-9]+)(s|min|m|h)", before.get("SyncIntervalSec", ""))
        if (not cap or int(cap[1]) * 1024 ** {"": 0, "K": 1, "M": 2, "G": 3, "T": 4}[cap[2]] > 150 * 1024 ** 2
                or not interval or int(interval[1]) * {"s": 1, "m": 60, "min": 60, "h": 3600}[interval[2]] < 60):
            raise RuntimeError("Retenção/sync existentes desconhecidos ou mais fortes; configuração preservada")
        if any(existing(root, root / p) is not None for p in DROPINS):
            raise RuntimeError("Configuração preexistente preservada")
        state = {"schemaVersion": 1, "owner": OWNER, "id": str(uuid.uuid4()),
                 "createdAt": datetime.now(timezone.utc).isoformat(),
                 "files": {p: digest(c) for p, c in DROPINS.items()}, "previous": "absent"}
        record(root, state, "prepared")
        for name, content in DROPINS.items():
            atomic(root, root / name, content, mode=0o644)
        effective = journal_settings(runner)
        expected = {"Storage": "persistent", "SystemMaxUse": "150M", "SyncIntervalSec": "60s"}
        if effective.get("values") != expected:
            record(root, state, "configuration-blocked")
            raise RuntimeError("Outra configuração prevalece ou leitura indisponível; reverter e revisar")
        return activate(root, state, "active", runner)


def rollback(root=Path("/"), runner=subprocess.run):
    root = Path(root)
    with transaction(root):
        state = read_state(root)
        if state is None:
            raise RuntimeError("Sem recibo de propriedade; nenhuma configuração removida")
        present = []
        for name, content in DROPINS.items():
            target = root / name
            raw = existing(root, target)
            if raw is not None:
                if raw != content:
                    raise RuntimeError("Configuração mudou; reversão recusada: " + name)
                present.append(target)
        if state["phase"] == "rolled-back" and not present:
            return {"ok": True, "state": "rolled-back", "changed": False}
        record(root, state, "rollback-pending")
        for target in present:
            target.unlink()
            directory = os.open(target.parent, os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        return activate(root, state, "rolled-back", runner)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "plan", "apply", "rollback"), default="status", nargs="?")
    parser.add_argument("--yes", action="store_true", help="Confirmar mudanças mostradas pelo plano")
    parser.add_argument("--json", action="store_true", help="Saída JSON (também padrão)")
    args = parser.parse_args(argv)
    try:
        if args.action in {"status", "plan"}:
            value = status() if args.action == "status" else plan()
        else:
            if not args.yes:
                print("Consulte pz repair stability plan; aplicação/reversão exige --yes.", file=sys.stderr)
                return 2
            if os.geteuid() != 0:
                bridge = shutil.which("phasezero-admin") or shutil.which("bigsudo")
                if not bridge:
                    raise RuntimeError("Ponte admin ausente: execute linux/pz ai setup admin")
                return subprocess.run([bridge, sys.executable, str(Path(__file__).resolve()),
                                       args.action, "--yes"], check=False).returncode
            value = apply() if args.action == "apply" else rollback()
        print(json.dumps(value, ensure_ascii=False))
        return 0 if value.get("ok", True) else 1
    except (OSError, ValueError, RuntimeError) as exc:
        print(json.dumps({"ok": False, "state": "blocked", "reason": str(exc)}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
