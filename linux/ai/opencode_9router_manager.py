#!/usr/bin/env python3
"""Read-only OpenCode diagnostics; managed 9Router use fails closed without grant binding."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import claude_code_manager as cc
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import claude_code_manager as cc


SCHEMA_VERSION = 1
CONNECTION_GRANT_BLOCKED_REASON = "connection-grant-not-enforceable"
CONNECTION_GRANT_BLOCKER = (
    "connection-grant-not-enforceable: OpenCode 9Router use is blocked; "
    "the consumer grant cannot bind each request "
    "to the selected account; no route configuration or client process was started."
)
ROUTE_ENV_KEYS = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
}


def parse_jsonc(text: str) -> dict[str, Any]:
    output: list[str] = []
    index = 0
    in_string = False
    escaped = False
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == "/" and following == "/":
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            continue
        if char == "/" and following == "*":
            index += 2
            while index + 1 < len(text) and text[index : index + 2] != "*/":
                index += 1
            index += 2
            continue
        output.append(char)
        index += 1
    cleaned = re.sub(r",\s*([}\]])", r"\1", "".join(output))
    value = json.loads(cleaned or "{}")
    if not isinstance(value, dict):
        raise RuntimeError("OpenCode configuration root must be an object")
    return value


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


class OpenCodeManager:
    def __init__(self) -> None:
        self.home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().absolute()
        self.xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", self.home / ".config"))
        self.xdg_data = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local/share"))
        self.config_dir = self.xdg_config / "opencode"
        self.config = self.config_dir / "opencode.json"
        self.legacy_config = self.config_dir / "opencode.jsonc"
        self.router_env = Path(
            os.environ.get("PZ_9ROUTER_ENV_FILE", self.xdg_config / "phasezero/ai-proxies/9router.env")
        )
        self.router_key = self.xdg_config / "phasezero/ai-proxies/9router.key"
        self.router_settings = self.xdg_config / "phasezero/9router/settings.json"
        self.data_root = Path(
            os.environ.get("PZ_OPENCODE_ROUTE_ROOT", self.xdg_data / "opencode-route-installer")
        )
        self.repo_root = Path(__file__).resolve().parents[2]
        self.setup_script = self.repo_root / "linux/ai/setup-opencode.sh"
        self.router_manager = self.repo_root / "linux/ai/9router-manager.sh"

    @staticmethod
    def _read_config(path: Path) -> dict[str, Any]:
        if not path.is_file():
            return {}
        try:
            return parse_jsonc(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"invalid OpenCode JSON/JSONC: {path}: {exc}") from exc

    def _router_token(self) -> str:
        if not self.router_env.is_file():
            raise RuntimeError(f"9Router environment missing: {self.router_env}")
        for line in self.router_env.read_text(encoding="utf-8", errors="replace").splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() == "PHASEZERO_9ROUTER_API_KEY" and value.strip():
                return value.strip().strip("'\"")
        raise RuntimeError("9Router API token missing")

    def _desktop_version(self) -> str:
        pacman = cc.command_path("pacman")
        if not pacman:
            return ""
        rc, out, _ = cc.run_capture([pacman, "-Q", "opencode-desktop-bin"], timeout=8)
        match = re.search(r"(\d+\.\d+\.\d+)", out) if rc == 0 else None
        return match.group(1) if match else ""

    def _cli_info(self) -> dict[str, Any]:
        binary = cc.command_path("opencode")
        version = ""
        if binary:
            rc, out, _ = cc.run_capture([binary, "--version"], timeout=10)
            match = re.search(r"(\d+\.\d+\.\d+)", out) if rc == 0 else None
            version = match.group(1) if match else ""
        return {"installed": bool(binary), "path": binary, "version": version}

    def _router_status(self) -> dict[str, Any]:
        fixture = os.environ.get("PZ_OPENCODE_ROUTER_STATUS_JSON")
        if fixture:
            try:
                value = json.loads(fixture)
                return value if isinstance(value, dict) else {}
            except json.JSONDecodeError:
                return {}
        if not self.router_manager.is_file():
            return {}
        rc, out, _ = cc.run_capture(["bash", str(self.router_manager), "status"], timeout=20)
        if rc != 0:
            return {}
        try:
            value = json.loads(out)
            return value if isinstance(value, dict) else {}
        except json.JSONDecodeError:
            return {}

    def _models(self, current: dict[str, Any]) -> list[str]:
        names = set()
        provider = current.get("provider", {}).get("9router", {}) if isinstance(current.get("provider"), dict) else {}
        if isinstance(provider, dict) and isinstance(provider.get("models"), dict):
            names.update(str(name) for name in provider["models"])
        names.add("Default")
        try:
            settings = json.loads(self.router_settings.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            settings = {}
        active = settings.get("activeCombo") or settings.get("model")
        if isinstance(active, str) and active:
            names.add(active)
        # Expose every 9Router combo (incl. phasezero-*) so the opencode model
        # picker offers them; the live combo set is the source of truth.
        names.update(name for name in self._combo_names() if isinstance(name, str) and name)
        return sorted(names)

    def _combo_names(self) -> list[str]:
        """Return current 9Router combo names; env fixture wins for tests."""
        fixture = os.environ.get("PZ_OPENCODE_ROUTER_COMBOS_JSON")
        if fixture:
            try:
                value = json.loads(fixture)
            except json.JSONDecodeError:
                return []
            data = value.get("combos") or value.get("names") or []
            return [c if isinstance(c, str) else c.get("name", "")
                    for c in data if (isinstance(c, str) or isinstance(c, dict))]
        status = self._router_status()
        combos = status.get("combos", {}) if isinstance(status, dict) else {}
        return list(combos.get("names") or []) if isinstance(combos, dict) else []

    def _catalog_in_sync(self, current_config: dict[str, Any]) -> bool:
        """True when opencode provider models cover every 9Router combo."""
        provider = current_config.get("provider", {}).get("9router", {}) if isinstance(current_config.get("provider"), dict) else {}
        configured = set(provider.get("models", {}).keys()) if isinstance(provider, dict) and isinstance(provider.get("models"), dict) else set()
        return set(self._combo_names()).issubset(configured)

    def _active_route_model(self, state: dict[str, Any]) -> str:
        try:
            settings = json.loads(self.router_settings.read_text(encoding="utf-8"))
            active = settings.get("activeCombo") or settings.get("model")
            if active in state["configuration"]["models"]:
                return f"9router/{active}"
        except (OSError, json.JSONDecodeError):
            pass
        return "9router/Default"

    def status(self) -> dict[str, Any]:
        cli = self._cli_info()
        desktop = self._desktop_version()
        config_error = None
        try:
            value = self._read_config(self.config)
        except RuntimeError as exc:
            value = {}
            config_error = str(exc)
        provider = value.get("provider", {}).get("9router", {}) if isinstance(value.get("provider"), dict) else {}
        options = provider.get("options", {}) if isinstance(provider, dict) else {}
        api_key_ref = options.get("apiKey") if isinstance(options, dict) else None
        key_mode = stat.S_IMODE(self.router_key.stat().st_mode) if self.router_key.is_file() else None
        router = self._router_status()
        listener = router.get("listener", {}) if isinstance(router.get("listener"), dict) else {}
        in_sync = not desktop or cli["version"] == desktop
        configured = bool(
            isinstance(provider, dict)
            and options.get("baseURL") == "http://127.0.0.1:20128/v1"
            and api_key_ref == f"{{file:{self.router_key}}}"
        )
        return {
            "schemaVersion": SCHEMA_VERSION,
            "tool": "opencode-9router",
            "route": "9router",
            "cli": cli,
            "desktop": {"installed": bool(desktop), "version": desktop},
            "inSync": in_sync,
            "configuration": {
                "path": str(self.config),
                "present": self.config.is_file(),
                "legacyPresent": self.legacy_config.is_file(),
                "error": config_error,
                "configured": configured,
                "model": value.get("model"),
                "models": sorted(provider.get("models", {}).keys()) if isinstance(provider, dict) and isinstance(provider.get("models"), dict) else [],
                "routerCombos": self._combo_names(),
                "catalogInSync": self._catalog_in_sync(value),
                "embeddedSecret": bool(api_key_ref and not str(api_key_ref).startswith("{file:")),
            },
            "credential": {
                "path": str(self.router_key),
                "present": self.router_key.is_file(),
                "mode": f"{key_mode:04o}" if key_mode is not None else None,
                "secure": key_mode == 0o600,
            },
            "router": {
                "healthy": bool(router.get("healthy")),
                "loopbackOnly": bool(listener.get("loopbackOnly", router.get("loopbackOnly"))),
                "endpoint": "http://127.0.0.1:20128/v1",
            },
            "executionSupported": False,
            "executionBlockedReason": CONNECTION_GRANT_BLOCKED_REASON,
            "bonsaiDirectSupported": False,
            "secretsRedacted": True,
        }

    def _sync_cli(self) -> None:
        if os.environ.get("PZ_OPENCODE_SKIP_SYNC") == "1":
            return
        proc = subprocess.run(["bash", str(self.setup_script), "sync"], check=False, timeout=300)
        if proc.returncode != 0:
            raise RuntimeError("OpenCode CLI/Desktop version alignment failed")

    def install(self, dry_run: bool = False, yes: bool = False) -> dict[str, Any]:
        blocked = {
            "schemaVersion": SCHEMA_VERSION,
            "status": "blocked",
            "ok": False,
            "dryRun": dry_run,
            "blockedReason": CONNECTION_GRANT_BLOCKED_REASON,
            "blockers": [CONNECTION_GRANT_BLOCKER],
            "plannedActions": [],
            "secretsRedacted": True,
        }
        if dry_run:
            return blocked
        raise RuntimeError(CONNECTION_GRANT_BLOCKER)

    def sync_catalog(self, dry_run: bool = False) -> dict[str, Any]:
        blocked = {
            "schemaVersion": SCHEMA_VERSION,
            "status": "blocked",
            "ok": False,
            "dryRun": dry_run,
            "blockedReason": CONNECTION_GRANT_BLOCKED_REASON,
            "blockers": [CONNECTION_GRANT_BLOCKER],
            "updated": False,
            "secretsRedacted": True,
        }
        if dry_run:
            return blocked
        raise RuntimeError(CONNECTION_GRANT_BLOCKER)

    def verify(self, live: bool = False) -> dict[str, Any]:
        state = self.status()
        ok = bool(
            state["cli"]["installed"]
            and state["inSync"]
            and state["configuration"]["configured"]
            and not state["configuration"]["embeddedSecret"]
            and state["credential"]["secure"]
            and state["router"]["healthy"]
            and state["router"]["loopbackOnly"]
        )
        live_result: dict[str, Any] = {"requested": live, "passed": None}
        if live:
            return {
                "schemaVersion": SCHEMA_VERSION,
                "ok": False,
                "configurationOk": ok,
                "blockedReason": CONNECTION_GRANT_BLOCKED_REASON,
                "state": state,
                "live": {
                    "requested": True,
                    "passed": None,
                    "blockedReason": CONNECTION_GRANT_BLOCKED_REASON,
                },
                "secretsRedacted": True,
            }
        return {
            "schemaVersion": SCHEMA_VERSION,
            "ok": ok,
            "configurationOk": ok,
            "blockedReason": CONNECTION_GRANT_BLOCKED_REASON,
            "executionSupported": False,
            "state": state,
            "live": live_result,
            "secretsRedacted": True,
        }

    def run(self, route: str | None, args: list[str]) -> int:
        selected = route or os.environ.get("BONSAI_ROUTE") or "9router"
        if selected in {"direct", "bonsai"}:
            raise RuntimeError(
                "BONSAI_ROUTE=direct is unsupported in OpenCode; use the local route "
                "or run Bonsai through Claude Code"
            )
        if selected not in {"9router", "proxy"}:
            raise RuntimeError("OpenCode route must be 9router")
        raise RuntimeError(CONNECTION_GRANT_BLOCKER)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pz ai opencode")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("status")
    install = sub.add_parser("install", aliases=["configure", "repair"])
    install.add_argument("--dry-run", action="store_true")
    install.add_argument("--yes", action="store_true")
    verify = sub.add_parser("verify")
    verify.add_argument("--live", action="store_true")
    sync = sub.add_parser("sync", aliases=["sync-catalog"])
    sync.add_argument("--dry-run", action="store_true")
    run = sub.add_parser("run")
    run.add_argument("--route", choices=("9router", "direct"))
    run.add_argument("args", nargs="*")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("manifest")
    rollback.add_argument("--force", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        manager = OpenCodeManager()
        command = args.command or "status"
        if command == "status":
            result = manager.status()
        elif command in {"install", "configure", "repair"}:
            result = manager.install(args.dry_run, args.yes)
        elif command == "verify":
            result = manager.verify(args.live)
        elif command in {"sync", "sync-catalog"}:
            result = manager.sync_catalog(args.dry_run)
        elif command == "run":
            route_args = args.args[1:] if args.args and args.args[0] == "--" else args.args
            return manager.run(args.route, route_args)
        elif command == "rollback":
            result = cc.restore_manifest(Path(args.manifest), args.force)
        else:
            parser.error(f"unknown command: {command}")
            return 2
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("ok", True) else 1
    except (RuntimeError, OSError, json.JSONDecodeError) as exc:
        print(
            json.dumps(
                {"schemaVersion": SCHEMA_VERSION, "status": "error", "error": str(exc), "secretsRedacted": True},
                indent=2,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
