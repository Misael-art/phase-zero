from __future__ import annotations

import argparse
import json
import os
import re
import secrets
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import ActionSpec
from .platform import secure_directory, secure_file, state_dir


ACTIVE_STATES = {"starting", "previewing", "running", "cancelling"}
TERMINAL_STATES = {"succeeded", "failed", "cancelled", "interrupted"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _safe_action_id(action_id: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]", "-", action_id).strip(".-") or "operation"


def _read_record(path: Path) -> dict[str, Any] | None:
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


class OperationLedger:
    """Private, redacted lifecycle ledger for Control Center operations.

    It records progress and terminal state only. Commands, stdout, parameter
    values and credentials stay in the existing bounded result envelope.
    """

    def __init__(self, root: Path | None = None) -> None:
        self.root = root or (state_dir() / "operations")
        self.current_path: Path | None = None
        self.current: dict[str, Any] | None = None

    def _write(self, path: Path, record: dict[str, Any]) -> None:
        secure_file(path, json.dumps(record, ensure_ascii=False, indent=2) + "\n")

    def begin(self, action: ActionSpec, *, preview: bool) -> str:
        now = utc_now()
        operation_id = (
            f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-"
            f"{os.getpid()}-{secrets.token_hex(3)}-{_safe_action_id(action.id)}"
        )
        operation_dir = secure_directory(self.root / operation_id)
        record = {
            "schemaVersion": 1,
            "operationId": operation_id,
            "ownerPid": os.getpid(),
            "actionId": action.id,
            "title": action.title,
            "category": action.category,
            "mutable": action.mutable,
            "preview": preview,
            "status": "previewing" if preview else "starting",
            "progress": 0,
            "startedAt": now,
            "updatedAt": now,
            "finishedAt": None,
            "exitCode": None,
            "resultPath": None,
            "resumable": False,
            "resumeMode": None,
            "nextAction": None,
            "secretsRedacted": True,
        }
        path = operation_dir / "operation.json"
        self._write(path, record)
        self.current_path = path
        self.current = record
        return operation_id

    def update(self, *, status: str | None = None, progress: int | None = None) -> None:
        if self.current_path is None or self.current is None:
            return
        if status:
            self.current["status"] = status
        if progress is not None:
            self.current["progress"] = max(0, min(100, int(progress)))
        self.current["updatedAt"] = utc_now()
        self._write(self.current_path, self.current)

    def finish(
        self,
        *,
        exit_code: int,
        result_path: Path | None = None,
        cancelled: bool = False,
    ) -> None:
        if self.current_path is None or self.current is None:
            return
        now = utc_now()
        status = "cancelled" if cancelled else "succeeded" if exit_code == 0 else "failed"
        self.current.update({
            "status": status,
            "progress": 100 if status == "succeeded" else self.current.get("progress", 0),
            "updatedAt": now,
            "finishedAt": now,
            "exitCode": int(exit_code),
            "resultPath": str(result_path) if result_path else None,
            "resumable": status in {"failed", "cancelled"}
            and bool(self.current.get("mutable"))
            and not bool(self.current.get("preview")),
            "resumeMode": "retry-with-confirmation"
            if status in {"failed", "cancelled"}
            and self.current.get("mutable")
            and not self.current.get("preview") else None,
            "nextAction": self.current.get("actionId")
            if status in {"failed", "cancelled"}
            and self.current.get("mutable")
            and not self.current.get("preview") else None,
        })
        self._write(self.current_path, self.current)
        self.current_path = None
        self.current = None

    def recover_interrupted(self, *, force: bool = False) -> int:
        recovered = 0
        for path in sorted(self.root.glob("*/operation.json")) if self.root.exists() else []:
            record = _read_record(path)
            if record is None or record.get("status") not in ACTIVE_STATES:
                continue
            owner_pid = record.get("ownerPid")
            if not force and isinstance(owner_pid, int) and owner_pid > 0:
                try:
                    os.kill(owner_pid, 0)
                except OSError:
                    pass
                else:
                    continue
            now = utc_now()
            mutable = bool(record.get("mutable")) and not bool(record.get("preview"))
            record.update({
                "status": "interrupted",
                "updatedAt": now,
                "finishedAt": now,
                "resumable": mutable,
                "resumeMode": "retry-with-confirmation" if mutable else None,
                "nextAction": record.get("actionId") if mutable else None,
                "recoveryReason": "control-center-exited-before-terminal-state",
                "secretsRedacted": True,
            })
            self._write(path, record)
            recovered += 1
        return recovered

    def records(self, *, limit: int = 100) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for path in sorted(self.root.glob("*/operation.json"), reverse=True) if self.root.exists() else []:
            record = _read_record(path)
            if record is not None:
                rows.append(record)
            if len(rows) >= limit:
                break
        return rows


def status_payload(ledger: OperationLedger, *, limit: int = 100) -> dict[str, Any]:
    operations = ledger.records(limit=limit)
    latest = operations[0] if operations else None
    counts: dict[str, int] = {}
    for operation in operations:
        state = str(operation.get("status") or "unknown")
        counts[state] = counts.get(state, 0) + 1
    return {
        "schemaVersion": 1,
        "latest": latest,
        "summary": {
            "total": len(operations),
            "active": sum(counts.get(state, 0) for state in ACTIVE_STATES),
            "needsAttention": counts.get("failed", 0) + counts.get("interrupted", 0),
            "byStatus": counts,
        },
        "secretsRedacted": True,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PhaseZero operation ledger")
    parser.add_argument("command", choices=("status", "list", "resume-info"), nargs="?", default="status")
    parser.add_argument("--limit", type=int, default=100)
    args = parser.parse_args(argv)
    ledger = OperationLedger()
    payload = status_payload(ledger, limit=max(1, min(args.limit, 250)))
    if args.command == "list":
        payload["operations"] = ledger.records(limit=max(1, min(args.limit, 250)))
    elif args.command == "resume-info":
        candidate = next(
            (row for row in ledger.records(limit=250) if row.get("resumable") is True),
            None,
        )
        payload = {
            "schemaVersion": 1,
            "resumable": candidate is not None,
            "operation": candidate,
            "safety": "retry-with-confirmation" if candidate else "none",
            "secretsRedacted": True,
        }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
