from __future__ import annotations

import json
import os
import pwd
import secrets
import time
from pathlib import Path


def _target_identity() -> tuple[int, int] | None:
    user = os.environ.get("PZ_TARGET_USER") or os.environ.get("SUDO_USER") or ""
    if not user and os.environ.get("PKEXEC_UID", "").isdigit():
        try:
            record = pwd.getpwuid(int(os.environ["PKEXEC_UID"]))
            return record.pw_uid, record.pw_gid
        except KeyError:
            return None
    if user and user != "root":
        try:
            record = pwd.getpwnam(user)
            return record.pw_uid, record.pw_gid
        except KeyError:
            return None
    return None


def _secure_owner(path: Path) -> None:
    identity = _target_identity()
    if identity is not None and os.geteuid() == 0:
        os.chown(path, *identity)


def _target_home() -> Path:
    override = os.environ.get("PZ_CAPABILITIES_STATE_DIR")
    if override:
        return Path(override).expanduser()
    user = os.environ.get("PZ_TARGET_USER") or os.environ.get("SUDO_USER") or ""
    if not user and os.environ.get("PKEXEC_UID", "").isdigit():
        try:
            user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
        except KeyError:
            user = ""
    if user and user != "root":
        return Path(pwd.getpwnam(user).pw_dir) / ".local" / "state" / "phasezero" / "capabilities"
    xdg = os.environ.get("XDG_STATE_HOME")
    return Path(xdg) / "phasezero" / "capabilities" if xdg else Path.home() / ".local" / "state" / "phasezero" / "capabilities"


def root() -> Path:
    path = _target_home()
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    _secure_owner(path)
    return path


def new_id(prefix: str) -> str:
    return f"{prefix}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(4)}"


def token() -> str:
    return secrets.token_hex(12)


def save(kind: str, record_id: str, payload: dict) -> Path:
    directory = root() / kind
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    _secure_owner(directory)
    path = directory / f"{record_id}.json"
    temporary = path.with_suffix(".json.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
        _secure_owner(path)
        limits = {"plans": 50, "operations": 100, "rollbacks": 100}
        retained = sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
        for obsolete in retained[limits.get(kind, 100):]:
            obsolete.unlink(missing_ok=True)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return path


def list_records(kind: str) -> list[dict]:
    """Registros de um tipo, do mais recente para o mais antigo.

    Arquivo ilegível ou corrompido é ignorado em vez de derrubar a leitura:
    o histórico é evidência auxiliar, não pode bloquear uma remoção.
    """
    directory = root() / kind
    if not directory.is_dir():
        return []
    records: list[dict] = []
    for path in sorted(directory.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if isinstance(payload, dict):
            records.append(payload)
    return records


def load(kind: str, record_id: str) -> dict:
    if "/" in record_id or "\\" in record_id or ".." in record_id:
        raise ValueError("ID inválido")
    path = root() / kind / f"{record_id}.json"
    return json.loads(path.read_text(encoding="utf-8"))
