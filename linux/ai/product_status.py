#!/usr/bin/env python3
"""Read-only, product-scoped status adapters for legacy AI managers."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
_MANAGERS = {
    "ai-memory": ("memory", "phasezero-ai-memory"),
    "usagebar": ("usagebar", "phasezero-ai-usagebar"),
    "claude-desktop": ("desktop", "phasezero-ai-desktop"),
    "codex-desktop": ("desktop", "phasezero-ai-desktop"),
    "qwen-code-desktop": ("desktop", "phasezero-ai-desktop"),
}


def _observed_at() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _unknown(manager: str, *, has_status: bool = False) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "hasStatus": has_status,
        "installationState": "unknown",
        "origin": "unknown",
        "configurationState": "unknown",
        "health": "unknown",
        "manager": manager,
        "observedAt": _observed_at(),
        **({} if has_status else {"error": "status_probe_unavailable"}),
    }


def _read_manager_status(kind: str) -> dict[str, Any] | None:
    scripts = {
        "memory": ROOT / "linux/ai/setup-memory.sh",
        "usagebar": ROOT / "linux/ai/setup-usagebar.sh",
        "desktop": ROOT / "linux/ai/desktop-apps.sh",
    }
    action = "status"
    try:
        completed = subprocess.run(
            ["bash", str(scripts[kind]), action],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    try:
        payload = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError):
        return None
    return payload if isinstance(payload, dict) else None


def _memory_origin(payload: dict[str, Any]) -> str:
    binary = payload.get("commandPath")
    if not isinstance(binary, str) or not binary:
        return "unknown"
    try:
        binary_path = Path(binary).expanduser().resolve(strict=True)
    except OSError:
        return "unknown"

    home = Path(os.environ.get("HOME", str(Path.home())))
    state_home = Path(os.environ.get("XDG_STATE_HOME", str(home / ".local/state")))
    manifest_path = state_home / "phasezero/ai/ai-memory-install.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        managed_path = Path(str(manifest.get("path", ""))).expanduser().resolve(strict=True)
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        manifest = {}
        managed_path = None
    current_version = payload.get("version")
    recorded_version = manifest.get("version")
    if (
        managed_path == binary_path
        and isinstance(current_version, str) and current_version
        and isinstance(recorded_version, str) and recorded_version
        and recorded_version in current_version
    ):
        return "phasezero"

    local_bin = Path(os.environ.get("PZ_LOCAL_BIN", str(home / ".local/bin"))) / "ai-memory"
    try:
        if binary_path == local_bin.expanduser().resolve(strict=False):
            return "unknown"
    except OSError:
        return "unknown"
    return "external"


def _base(
    manager: str,
    *,
    installation: str = "unknown",
    origin: str = "unknown",
    configuration: str = "unknown",
    health: str = "unknown",
    version: Any = "",
    launchable: bool = False,
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "hasStatus": True,
        "installationState": installation,
        "origin": origin,
        "configurationState": configuration,
        "health": health,
        "manager": manager,
        "version": version if isinstance(version, str) else "",
        "launchable": launchable,
        "observedAt": _observed_at(),
    }


def _is_executable_file(value: Any) -> bool:
    if not isinstance(value, str) or not value:
        return False
    path = Path(value).expanduser()
    return path.is_file() and os.access(path, os.X_OK)


def normalize_payload(app_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Project a manager's aggregate response onto one product's evidence."""
    kind, manager = _MANAGERS[app_id]
    if kind == "memory":
        installed = payload.get("installed")
        installation = "present" if installed is True else "absent" if installed is False else "unknown"
        configured = payload.get("configuredMarker")
        integrations = payload.get("integrations")
        integrations_ok = integrations.get("ok") if isinstance(integrations, dict) else None
        configuration = (
            "ready" if configured is True and integrations_ok is True else
            "needed" if configured is False else "unknown"
        )
        reachable = payload.get("serverReachable")
        health = "online" if reachable is True else "offline" if reachable is False else "unknown"
        return _base(
            manager,
            installation=installation,
            origin=_memory_origin(payload) if installed is True else "unknown",
            configuration=configuration,
            health=health,
            version=payload.get("version"),
        )

    if kind == "usagebar":
        available = payload.get("available")
        installation = "present" if available is True else "absent" if available is False else "unknown"
        config_path = payload.get("configPath")
        marker_found = False
        if isinstance(config_path, str) and config_path:
            try:
                with Path(config_path).open("r", encoding="utf-8", errors="replace") as config:
                    marker_found = "PhaseZero managed ai-usagebar config" in config.readline()
            except OSError:
                marker_found = False
        config_exists = payload.get("configExists")
        configuration = (
            "ready" if marker_found else
            "needed" if config_exists is False else "unknown"
        )
        return _base(
            manager,
            installation=installation,
            configuration=configuration,
            version=payload.get("version"),
        )

    record_key = {
        "claude-desktop": "claudeDesktop",
        "codex-desktop": "codexDesktop",
        "qwen-code-desktop": "qwenCodeDesktop",
    }[app_id]
    record = payload.get(record_key)
    if not isinstance(record, dict):
        return _unknown(manager)
    if app_id == "claude-desktop":
        installed = record.get("installed")
        version = record.get("version")
        configuration = (
            "ready" if installed is True and record.get("launcherOk") is True
            and record.get("desktopEntryOk") is True else "unknown"
        )
        launchable = configuration == "ready"
    elif app_id == "qwen-code-desktop":
        installed = record.get("installed")
        version = record.get("version")
        launcher = record.get("launcher")
        binary = record.get("binary")
        launcher_ok = _is_executable_file(launcher)
        binary_ok = _is_executable_file(binary)
        configuration = (
            "ready" if installed is True and launcher_ok and binary_ok else "unknown"
        )
        launchable = configuration == "ready"
    else:
        # Codex update state records a version, not package ownership or health.
        installed = None
        version = record.get("installedVersion")
        configuration = "unknown"
        launchable = False

    # The desktop manager only inventories its own Claude/Qwen directories.
    # A negative managed-path check cannot prove absence of external installs.
    installation = "present" if installed is True else "unknown"
    origin = "phasezero" if installed is True else "unknown"
    return _base(
        manager,
        installation=installation,
        origin=origin,
        configuration=configuration,
        version=version,
        launchable=launchable,
    )


def product_status(app_id: str) -> dict[str, Any]:
    kind, manager = _MANAGERS[app_id]
    payload = _read_manager_status(kind)
    return normalize_payload(app_id, payload) if payload is not None else _unknown(manager)


def main(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0] not in _MANAGERS:
        print(json.dumps({"error": "unknown_product_status_target"}, separators=(",", ":")))
        return 2
    print(json.dumps(product_status(argv[0]), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
