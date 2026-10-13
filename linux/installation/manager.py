from __future__ import annotations

import json
import os
import pwd
import shutil
import subprocess
import tarfile
import time
from pathlib import Path

from linux.capabilities import state
from . import SCHEMA

APP_ID = "io.phasezero.ControlCenter"
PACKAGE = "phasezero-control-center"
SYSTEM_ROOTS = (Path("/usr/lib/phasezero"), Path("/usr/lib64/phasezero"))


class InstallationError(RuntimeError):
    pass


def _run(command: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InstallationError(f"falha executando {command[0]}: {exc}") from exc


def _target_account() -> tuple[str, int, int, Path]:
    user = os.environ.get("PZ_TARGET_USER") or os.environ.get("SUDO_USER") or ""
    if not user and os.environ.get("PKEXEC_UID", "").isdigit():
        try:
            row = pwd.getpwuid(int(os.environ["PKEXEC_UID"]))
            return row.pw_name, row.pw_uid, row.pw_gid, Path(row.pw_dir)
        except KeyError:
            pass
    if user and user != "root":
        row = pwd.getpwnam(user)
        return row.pw_name, row.pw_uid, row.pw_gid, Path(row.pw_dir)
    row = pwd.getpwuid(os.getuid())
    return row.pw_name, row.pw_uid, row.pw_gid, Path(row.pw_dir)


def _data_home(home: Path) -> Path:
    """XDG data dir of the TARGET account, not of the caller.

    `pz` runs elevated through sudo/pkexec (the admin bridge), where
    XDG_DATA_HOME still points at the invoking account — root's, usually.
    Honour the variable only while it belongs to the same home the target
    account resolves to; otherwise derive it from that home, so the user
    channel is looked up where it actually lives.
    """
    declared = os.environ.get("XDG_DATA_HOME") or ""
    if declared:
        caller_home = os.environ.get("HOME") or ""
        if caller_home and Path(caller_home) == home:
            return Path(declared)
    return home / ".local/share"


def _version(path: Path) -> str:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return str(value.get("version", "unknown"))
    except (OSError, json.JSONDecodeError, TypeError):
        return "unknown"


def _native_package() -> dict:
    if shutil.which("pacman"):
        result = _run(["pacman", "-Q", PACKAGE])
        if result.returncode == 0:
            version = result.stdout.strip().rsplit(" ", 1)[-1]
            verify = _run(["pacman", "-Qkk", PACKAGE], timeout=60)
            altered = len({
                line.split(": ", 2)[2].rsplit(" (", 1)[0]
                for line in verify.stderr.splitlines()
                if line.startswith(f"warning: {PACKAGE}: ") and " (" in line
            })
            return {"installed": True, "manager": "pacman", "version": version, "alteredFiles": altered}
    if shutil.which("dpkg-query"):
        result = _run(["dpkg-query", "-W", "-f=${Version}", PACKAGE])
        if result.returncode == 0:
            return {"installed": True, "manager": "apt", "version": result.stdout.strip(), "alteredFiles": None}
    if shutil.which("rpm"):
        result = _run(["rpm", "-q", "--qf", "%{VERSION}-%{RELEASE}", PACKAGE])
        if result.returncode == 0:
            return {"installed": True, "manager": "rpm", "version": result.stdout.strip(), "alteredFiles": None}
    return {"installed": False, "manager": "", "version": "", "alteredFiles": 0}


def _flatpak(scope: str) -> dict:
    if not shutil.which("flatpak"):
        return {"installed": False, "scope": scope, "version": ""}
    result = _run(["flatpak", f"--{scope}", "info", "--show-version", APP_ID])
    return {
        "installed": result.returncode == 0,
        "scope": scope,
        "version": result.stdout.strip() if result.returncode == 0 else "",
    }


def status() -> dict:
    _user, _uid, _gid, home = _target_account()
    user_base = _data_home(home) / "phasezero"
    current = user_base / "current"
    user_version = _version(current / "version.json") if current.exists() else ""
    native = _native_package()
    flatpaks = [_flatpak("user"), _flatpak("system")]
    roots = []
    seen_root_objects: dict[tuple[int, int], str] = {}
    for root in SYSTEM_ROOTS:
        identity: tuple[int, int] | None = None
        if root.exists():
            try:
                stat = root.stat()
                identity = (stat.st_dev, stat.st_ino)
            except OSError:
                pass
        alias_of = seen_root_objects.get(identity) if identity else None
        if identity and not alias_of:
            seen_root_objects[identity] = str(root)
        roots.append({
            "path": str(root),
            "exists": root.exists(),
            "version": _version(root / "version.json") if root.exists() else "",
            "aliasOf": alias_of or "",
        })
    channels = []
    if user_version:
        channels.append("user")
    if native["installed"]:
        channels.append("native")
    channels.extend(f"flatpak-{item['scope']}" for item in flatpaks if item["installed"])
    conflicts = []
    if len(channels) > 1:
        conflicts.append("múltiplos canais instalados: " + ", ".join(channels))
    if native.get("alteredFiles"):
        conflicts.append(f"pacote nativo possui {native['alteredFiles']} arquivos alterados")
    existing_roots = [root for root in roots if root["exists"] and not root["aliasOf"]]
    if len(existing_roots) > 1:
        conflicts.append("raízes de sistema duplicadas: " + ", ".join(root["path"] for root in existing_roots))
    user_command = home / ".local/bin/phasezero-control-center"
    command = str(user_command) if user_command.is_file() and os.access(user_command, os.X_OK) else (shutil.which("phasezero-control-center") or "")
    return {
        "schema": SCHEMA,
        "status": "conflict" if conflicts else "ok",
        "recommendedChannel": "user",
        "activeChannels": channels,
        "user": {"installed": bool(user_version), "version": user_version, "root": str(current.resolve()) if current.exists() else ""},
        "native": native,
        "flatpaks": flatpaks,
        "systemRoots": roots,
        "conflicts": conflicts,
        "command": command,
    }


def create_plan(channel: str = "user") -> dict:
    if channel != "user":
        raise InstallationError("somente canal canônico 'user' é suportado nesta migração")
    current = status()
    if not current["user"]["installed"]:
        raise InstallationError("instale primeiro a versão de usuário verificada")
    actions = []
    if current["native"]["installed"]:
        actions.append({"kind": "remove-native-package", "manager": current["native"]["manager"], "package": PACKAGE})
    for item in current["flatpaks"]:
        if item["installed"]:
            actions.append({"kind": "remove-flatpak", "scope": item["scope"], "appId": APP_ID})
    for root in current["systemRoots"]:
        if root["exists"] and not root.get("aliasOf"):
            actions.append({"kind": "backup-remove-system-root", "path": root["path"]})
    actions.append({"kind": "prune-retention"})
    plan_id = state.new_id("install-plan")
    record = {
        "schema": SCHEMA,
        "kind": "installation-plan",
        "id": plan_id,
        "createdAt": int(time.time()),
        "channel": channel,
        "before": current,
        "actions": actions,
        "confirmToken": state.token(),
        "status": "ready",
    }
    state.save("installation-plans", plan_id, record)
    return record


def _flatpak_command(scope: str, *args: str) -> list[str]:
    command = ["flatpak", f"--{scope}", *args]
    if os.geteuid() != 0 or scope == "system":
        return command
    user, _uid, _gid, home = _target_account()
    return ["runuser", "-u", user, "--", "env", f"HOME={home}", *command]


def _remove_native(manager: str) -> tuple[int, str]:
    if manager == "pacman":
        command = ["pacman", "-R", "--noconfirm", PACKAGE]
    elif manager == "apt":
        command = ["apt-get", "remove", "-y", PACKAGE]
    elif manager == "rpm":
        command = [shutil.which("dnf") or "dnf", "remove", "-y", PACKAGE]
    else:
        raise InstallationError(f"gerenciador nativo desconhecido: {manager}")
    result = _run(command, timeout=600)
    return result.returncode, (result.stdout + result.stderr)[-8000:]


def _backup_root(root: Path, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = backup_dir / f"{root.as_posix().strip('/').replace('/', '_')}-{int(time.time())}.tar.gz"
    with tarfile.open(destination, "w:gz") as archive:
        archive.add(root, arcname=root.as_posix().lstrip("/"), recursive=True)
    user, uid, gid, _home = _target_account()
    if os.geteuid() == 0:
        # mkdir(parents=True) may create the installation parent as root.  The
        # target user must retain access to plans, operations, and backups.
        installation_dir = backup_dir.parent
        os.chown(installation_dir, uid, gid)
        os.chmod(installation_dir, 0o700)
        os.chown(destination, uid, gid)
        os.chown(backup_dir, uid, gid)
    os.chmod(destination, 0o600)
    return destination


def prune() -> dict:
    _user, _uid, _gid, home = _target_account()
    removed: list[str] = []

    def keep_newest(directory: Path, keep: int, pattern: str = "*") -> None:
        if not directory.exists():
            return
        items = sorted(directory.glob(pattern), key=lambda path: path.stat().st_mtime, reverse=True)
        for item in items[keep:]:
            if item.is_dir() and not item.is_symlink():
                shutil.rmtree(item)
            else:
                item.unlink(missing_ok=True)
            removed.append(str(item))

    base = home / ".local/share/phasezero"
    current = (base / "current").resolve() if (base / "current").exists() else None
    releases = sorted((base / "releases").glob("*"), key=lambda path: path.stat().st_mtime, reverse=True) if (base / "releases").exists() else []
    for item in releases[3:]:
        if current and item.resolve() == current:
            continue
        shutil.rmtree(item)
        removed.append(str(item))
    keep_newest(base / "backups", 3)
    keep_newest(home / ".local/state/phasezero/control-center/results", 250, "*.json")
    keep_newest(home / ".local/state/phasezero/operations", 100, "*.json")
    backup_groups = (
        home / ".local/state/phasezero/backups/ai-mcp",
        home / ".local/state/phasezero/ai/backups/agent-compat",
        home / ".local/state/phasezero/ai/backups/legacy-codex",
    )
    for backup_group in backup_groups:
        if not backup_group.exists():
            continue
        groups: dict[str, list[Path]] = {}
        for item in backup_group.glob("*.bak.*"):
            groups.setdefault(item.name.split(".bak.", 1)[0], []).append(item)
        for items in groups.values():
            for item in sorted(items, key=lambda path: path.stat().st_mtime, reverse=True)[5:]:
                item.unlink(missing_ok=True)
                removed.append(str(item))
    return {"schema": SCHEMA, "status": "complete", "removedCount": len(removed), "removed": removed[:100]}


def apply(plan_id: str, confirmation: str) -> dict:
    if os.geteuid() != 0:
        raise InstallationError("convergência requer execução pela admin bridge")
    plan = state.load("installation-plans", plan_id)
    if plan.get("schema") != SCHEMA or plan.get("kind") != "installation-plan":
        raise InstallationError("plano incompatível")
    if int(time.time()) - int(plan.get("createdAt", 0)) > 24 * 60 * 60:
        raise InstallationError("plano expirado; gere novo diagnóstico")
    if confirmation != plan.get("confirmToken"):
        raise InstallationError("token de confirmação inválido")
    allowed_roots = {str(path) for path in SYSTEM_ROOTS}
    for action in plan.get("actions", ()):
        kind = action.get("kind")
        if kind == "remove-native-package":
            if action.get("package") != PACKAGE or action.get("manager") not in {"pacman", "apt", "rpm"}:
                raise InstallationError("ação nativa adulterada no plano")
        elif kind == "remove-flatpak":
            if action.get("appId") != APP_ID or action.get("scope") not in {"user", "system"}:
                raise InstallationError("ação Flatpak adulterada no plano")
        elif kind == "backup-remove-system-root":
            if action.get("path") not in allowed_roots:
                raise InstallationError("raiz de sistema adulterada no plano")
        elif kind != "prune-retention":
            raise InstallationError("tipo de ação desconhecido no plano")
    _user, _uid, _gid, home = _target_account()
    backup_dir = home / ".local/state/phasezero/installation/backups"
    results = []
    # Back up every system root before package removal can delete any content.
    for action in plan["actions"]:
        if action["kind"] == "backup-remove-system-root":
            root = Path(action["path"])
            if root.exists():
                backup = _backup_root(root, backup_dir)
                results.append({"kind": "backup", "path": str(root), "backup": str(backup), "ok": True})
    for action in plan["actions"]:
        kind = action["kind"]
        if kind == "remove-native-package":
            code, output = _remove_native(action["manager"])
            results.append({"kind": kind, "ok": code == 0, "exitCode": code, "output": output})
            if code != 0:
                raise InstallationError("remoção do pacote nativo falhou; backups preservados")
        elif kind == "remove-flatpak":
            result = _run(_flatpak_command(action["scope"], "uninstall", "-y", action["appId"]), timeout=600)
            results.append({"kind": kind, "scope": action["scope"], "ok": result.returncode == 0})
            if result.returncode != 0:
                raise InstallationError(f"remoção Flatpak {action['scope']} falhou")
        elif kind == "backup-remove-system-root":
            root = Path(action["path"])
            if root.exists():
                shutil.rmtree(root)
            results.append({"kind": "remove-system-root", "path": str(root), "ok": not root.exists()})
        elif kind == "prune-retention":
            results.append({"kind": kind, **prune()})
    after = status()
    ok = after["activeChannels"] == ["user"] and not any(root["exists"] for root in after["systemRoots"])
    record = {
        "schema": SCHEMA,
        "kind": "installation-operation",
        "id": state.new_id("install-operation"),
        "planId": plan_id,
        "status": "complete" if ok else "failed",
        "results": results,
        "after": after,
    }
    state.save("installation-operations", record["id"], record)
    if not ok:
        raise InstallationError("verificação pós-convergência falhou")
    return record
