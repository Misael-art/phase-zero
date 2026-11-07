#!/usr/bin/env python3
"""Bounded diagnostics/recovery for the existing, explicitly enabled Web bridge.

No inference probes, credential changes, request replay, account/model fallback,
downloads or host-wide network/process operations occur in a monitor cycle.
"""
from __future__ import annotations

import datetime as dt
import configparser
import hashlib
import json
import os
from pathlib import Path
import re
import time
import tomllib


MARKER = "# PhaseZero ChatGPT Web recovery\n"


def classify_error(message: str, status: int | None = None, code: str = "") -> str:
    text = (code + " " + message).casefold()
    if any(x in text for x in ("model_version_unavailable", "could not be selected and verified")):
        return "model-compatibility"
    if any(x in text for x in ("usage_limit", "insufficient_quota", "hit your usage limit")):
        return "quota-exhausted"
    if status == 429 or any(x in text for x in ("rate_limit", "too many requests")):
        return "rate-limited"
    if status == 401 or any(x in text for x in ("session has expired", "login required", "unauthorized")):
        return "login-required"
    if status == 403 or "permission_denied" in text:
        return "permission-required"
    if any(x in text for x in ("err_internet_disconnected", "enotfound", "err_network_changed")):
        return "network-unavailable"
    if status in (502, 503, 504) or any(x in text for x in ("overloaded", "temporarily unavailable")):
        return "upstream-unavailable"
    return "unclassified-error"


def decisions(observation: dict) -> dict:
    """Pure policy: repairs require ownership, idle execution and resource margin."""
    if not observation.get("optIn"):
        return {"state": "off", "actions": []}
    if observation.get("integrity") == "mismatch" or not observation.get("policyValid", True):
        return {"state": "configuration-conflict", "actions": []}
    if not observation.get("isolationOk", True):
        return {"state": "isolation-conflict", "actions": []}
    if not observation.get("resourcesOk", True):
        return {"state": "waiting-for-resources", "actions": []}
    if observation.get("starting"):
        return {"state": "waiting-for-startup", "actions": []}
    actions = []
    if observation.get("launcherActive") and not observation.get("compatActive"):
        actions.append("restore-composer")
    if observation.get("shortcutsMissing"):
        actions.append("restore-shortcuts")
    if observation.get("autostartMissing"):
        actions.append("restore-login-entry")
    failure = observation.get("failure")
    if failure == "model-compatibility" and "restore-composer" not in actions:
        actions.append("restore-composer")
    external_failure = failure in {"rate-limited", "quota-exhausted", "login-required", "permission-required",
                                  "network-unavailable", "upstream-unavailable", "unclassified-error"}
    if observation.get("busy") is not False:
        return {"state": failure if external_failure else "waiting-for-idle", "actions": actions}
    if not observation.get("launcherActive"):
        actions.append("start-launcher")
    elif (not observation.get("daemonListening") or observation.get("orphanTunnels")
          or (observation.get("tunnelReady") is False and not external_failure)):
        actions.append("restart-backend")
    if not observation.get("routeActive"):
        actions.append("restore-route")
    # A previous remote limit must not strand a later local crash. Restore only
    # proven local infrastructure; an offline tunnel alone can be a network fault.
    return {"state": failure if external_failure else "repairable" if actions else "ready", "actions": actions}


def resource_margin() -> bool:
    try:
        memory = Path("/proc/meminfo").read_text()
        available = int(re.search(r"(?m)^MemAvailable:\s+(\d+)", memory)[1])
        for name, threshold in (("memory", 5), ("io", 10)):
            text = Path(f"/proc/pressure/{name}").read_text()
            if float(re.search(r"full avg10=([\d.]+)", text)[1]) >= threshold:
                return False
        return available >= 1024 * 1024
    except (OSError, ValueError, TypeError):
        return False


def recent_events(path: Path) -> dict:
    """Read bounded metadata, retaining neither prompts nor upstream log messages."""
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, 2)
            stream.seek(max(0, size - 256 * 1024))
            lines = stream.read().splitlines()
        failure = None
        success = None
        active = set()
        for line in lines:
            try:
                row = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(row, dict):
                continue
            detail = row.get("detail") or {}
            if not isinstance(detail, dict):
                continue
            value = str(detail.get("line") or detail.get("message") or "")
            stamp = row.get("at") if isinstance(row.get("at"), str) else None
            event = row.get("event")
            if event in {"runtime.daemon_started", "runtime.daemon_exited", "runtime.active_turns_cancelled"}:
                active.clear()
            trace = detail.get("traceId")
            if isinstance(trace, str) and re.fullmatch(r"[a-f0-9]+", trace):
                if event == "browser.turn_started":
                    active.add(trace)
                elif event == "browser.turn_ended":
                    active.discard(trace)
            match = re.search(r"browser turn ([a-f0-9]+) stage=browser_page started", value)
            if match:
                active.add(match[1])
            match = re.search(r'"traceId":"([a-f0-9]+)"', value)
            if match and ("broker_retired" in value or "browser_settled" in value):
                active.discard(match[1])
                if '"outcome":"final"' in value:
                    success = stamp
            match = re.search(r"browser turn ([a-f0-9]+) stage=\S+ failed", value)
            if match:
                active.discard(match[1])
                failure = {"kind": classify_error(value), "at": stamp}
            if event == "runtime.startup_failed":
                failure = {"kind": "backend-startup", "at": stamp}
        if failure and success and success > (failure.get("at") or ""):
            failure = None
        return {"failure": failure, "lastSuccessfulWebTurnAt": success, "busy": bool(active)}
    except OSError:
        return {"failure": None, "lastSuccessfulWebTurnAt": None, "busy": None}


class Recovery:
    def __init__(self, bridge):
        self.bridge = bridge
        self.paths = bridge.paths
        self.record = self.paths.root / "recovery-state.json"
        suffix = self.paths.unit_name.removesuffix(".service") + "-health"
        config = self.paths.autostart_dir.parent
        self.service = config / "systemd/user" / (suffix + ".service")
        self.timer = self.service.with_suffix(".timer")
        self.wrapper = self.paths.autostart_bin / "chatgpt-web-recovery.sh"
        self.target = self.paths.autostart_bin / "chatgpt-web-recovery.target"

    def read(self) -> dict:
        if self.record.is_symlink():
            raise RuntimeError("registro do monitor é symlink; preservado")
        try:
            result = json.loads(self.record.read_text())
            return result if isinstance(result, dict) else {}
        except (OSError, ValueError):
            return {}

    def write(self, value: dict) -> None:
        if self.record.is_symlink() or (self.record.exists() and self.record.stat().st_uid != os.getuid()):
            raise RuntimeError("registro do monitor não pertence ao perfil; preservado")
        self.bridge.write_recovery_file(self.record, json.dumps(value, indent=2) + "\n")

    def observe(self, deep=False) -> dict:
        b = self.bridge
        events = recent_events(self.paths.launcher_data / "logs/launcher.jsonl")
        active = b.launcher_active()
        login = b.session_present(self.paths.launcher_data)
        failure = (events.get("failure") or {}).get("kind")
        if login is False:
            failure = "login-required"
        key = b.key_status(b.load_state())
        if (b.upstream_config() or {}).get("mode") == "full" and key.get("state") in {"absent", "rotation-overdue"}:
            failure = "permission-required"
        isolation = b.isolation()
        shortcuts = b.shortcuts_status()
        autostart = b.autostart_status()
        config_text = b._config_text()
        try:
            model = tomllib.loads(config_text).get("model")
        except ValueError:
            model = None
        observation = {
            "optIn": bool(b.load_state().get("optIn")),
            "model": model,
            "launcherActive": active, "compatActive": b.compat_active(),
            "daemonListening": b.runner.port_in_use(self.paths.port),
            "routeActive": b.route_status().get("active") is True,
            "policyValid": not b.policy_violations(config_text),
            "isolationOk": not isolation.get("unmanagedLaunchers") and not isolation.get("upstreamAutostartEntry")
                           and isolation.get("launcherAutostartSetting") is not True,
            "orphanTunnels": isolation.get("orphanTunnels", []),
            "shortcutsMissing": shortcuts["state"] == "inconsistent",
            "autostartMissing": autostart["state"] == "inconsistent",
            "busy": events["busy"] if active else False,
            "resourcesOk": resource_margin(), "failure": failure,
            "failureAt": (events.get("failure") or {}).get("at"),
            "lastSuccessfulWebTurnAt": events["lastSuccessfulWebTurnAt"],
            "nativeCodexQuotaIsWebQuota": False,
        }
        observation["starting"] = False
        if active and not observation["daemonListening"]:
            owners = [p["pid"] for p in b.launcher_processes() if p.get("managed")]
            ages = []
            try:
                uptime = float(Path("/proc/uptime").read_text().split()[0])
                for pid in owners:
                    ticks = b.runner.process_start_ticks(pid)
                    if ticks.isdigit():
                        ages.append(uptime - int(ticks) / os.sysconf("SC_CLK_TCK"))
            except (OSError, ValueError):
                pass
            observation["starting"] = not owners or bool(ages and min(ages) < 45)
        if (b.upstream_config() or {}).get("mode") == "full":
            observation["tunnelReady"] = b.tunnel_ready()
        if deep:
            package = b.package_state()
            observation["integrity"] = ("verified" if package.get("state") == "verified"
                                         and package.get("unpacked") == "verified" else "mismatch")
            if (b.upstream_config() or {}).get("mode") == "full":
                observation["tunnelReady"] = b.tunnel_ready()
                observation["connectorReady"] = b.connector_status().get("ok")
                if observation["connectorReady"] is False:
                    observation["failure"] = "permission-required"
        return observation

    def status(self, deep=False) -> dict:
        observation = self.observe(deep)
        return {"schemaVersion": 1, "monitorEnabled": bool(self.bridge.load_state().get("recovery", {}).get("enabled")),
                "observation": observation, "plan": decisions(observation), "lastCycle": self.read()}

    def entries(self) -> dict:
        unit = (MARKER + "[Unit]\nDescription=PhaseZero Codex Web health and recovery\n"
                "After=graphical-session.target\n\n[Service]\nType=oneshot\n"
                f'ExecStart="{str(self.wrapper).replace("%", "%%")}"\n'
                "TimeoutStartSec=90\nNice=10\nMemoryMax=256M\n")
        timer = (MARKER + "[Unit]\nDescription=PhaseZero Codex Web health timer\n\n[Timer]\n"
                 "OnBootSec=90\nOnUnitInactiveSec=60\nAccuracySec=10\nRandomizedDelaySec=10\n"
                 "\n[Install]\nWantedBy=timers.target\n")
        wrapper = self.bridge.wrapper_text("monitoramento e autorreparo", self.target.name,
                                           "monitor indisponível", "pz ai chatgpt-web recovery enable", "recovery cycle")
        return {self.service: unit, self.timer: timer, self.wrapper: wrapper,
                self.target: self.bridge.autostart_target_text()}

    def enable(self) -> dict:
        b = self.bridge
        b.require_opt_in(b.load_state())
        state = b.load_state()
        old = state.get("recovery", {}).get("files", {})
        entries = self.entries()
        for path, content in entries.items():
            if path.is_symlink():
                raise RuntimeError("arquivo do monitor é symlink; preservado")
            if path.exists() and path.read_text() != content and hashlib.sha256(path.read_bytes()).hexdigest() != old.get(str(path)):
                raise RuntimeError("monitor alterado fora do gerenciador; preservado")
        b.install_managed_entrypoint()
        for path, content in entries.items():
            b.write_recovery_file(path, content, 0o755 if path == self.wrapper else 0o600)
        state["recovery"] = {"enabled": True, "files": {str(p): hashlib.sha256(c.encode()).hexdigest() for p, c in entries.items()}}
        b.save_state(state)
        for args in (["systemctl", "--user", "daemon-reload"],
                     ["systemctl", "--user", "enable", "--now", self.timer.name]):
            code, _, _ = b.runner.run(args, timeout=30)
            if code:
                raise RuntimeError("systemd não confirmou ativação do monitor")
        return {"enabled": True, "timer": self.timer.name, "intervalSeconds": 60}

    def disable(self) -> dict:
        state = self.bridge.load_state()
        self.bridge.runner.run(["systemctl", "--user", "disable", "--now", self.timer.name], timeout=30)
        state.setdefault("recovery", {})["enabled"] = False
        self.bridge.save_state(state)
        return {"enabled": False}

    def restore_account_shortcuts(self) -> bool:
        """Repair only a proven account launcher, using its intact sibling copy."""
        if self.bridge.load_state().get("accountShortcuts") != "codex-profiles":
            return self.bridge.restore_shortcuts()
        if self.bridge.load_state().get("accountShortcutsRemoved"):
            return False
        base = (self.paths.root.parent if self.paths.instance else
                self.paths.root.parent / "ai-accounts/codex-profiles/primary")
        wrapper = base / "open-web.sh"
        if wrapper.is_symlink() or not wrapper.is_file():
            return False
        name = (f"phasezero-codex-{self.paths.instance}-web.desktop" if self.paths.instance
                else "phasezero-chatgpt-web.desktop")
        paths = [self.paths.applications / name, self.bridge.user_desktop_dir() / name]

        def values(path):
            if path.is_symlink() or not path.is_file():
                return None
            try:
                parser = configparser.ConfigParser(interpolation=None, strict=True)
                parser.read_string(path.read_text())
                entry = dict(parser["Desktop Entry"])
                expected = f'"{wrapper}"'
                if (entry.get("exec") != expected or entry.get("icon") != str(base / "account-web.svg")
                        or entry.get("type") != "Application" or entry.get("terminal") != "false"
                        or len(parser.sections()) != 1):
                    return None
                return entry
            except (OSError, configparser.Error, KeyError):
                return None

        original = next((p for p in paths if (v := values(p)) and
                         v.get("x-phasezero-managed") == "codex-profiles"), None)
        if original is None:
            return False
        source = values(original)
        changed = False
        for path in paths:
            if path == original or path.is_symlink():
                continue
            if not path.exists():
                # Never create a desktop directory just to repair a menu entry.
                if path.parent.is_dir():
                    self.bridge.write_recovery_file(path, original.read_text(), 0o755)
                    changed = True
                continue
            other = values(path)
            if (other and other.get("x-phasezero-managed") == "true"
                    and all(other.get(k) == source.get(k) for k in ("name", "exec", "icon"))):
                before = path.read_text()
                backup = self.paths.journal / ("shortcut-owner-" + hashlib.sha256(before.encode()).hexdigest() + ".desktop")
                self.bridge.write_recovery_file(backup, before)
                self.bridge.write_recovery_file(path, before.replace("X-PhaseZero-Managed=true\n",
                                                 "X-PhaseZero-Managed=codex-profiles\n", 1), 0o755)
                changed = True
        return changed

    def apply(self, automatic=False) -> dict:
        b = self.bridge
        if automatic and not b.load_state().get("recovery", {}).get("enabled"):
            return {"state": "off", "actions": []}
        with b.maintenance() as available:
            if not available:
                return {"state": "maintenance-busy", "actions": []}
            observation = self.observe()
            plan = decisions(observation)
            record = self.read()
            now = time.time()
            if now < record.get("nextAttemptAt", 0):
                return {"state": "cooldown", "actions": [], "nextAttemptAt": record["nextAttemptAt"]}
            attempts = record.get("restartAttempts", [])
            attempts = [t for t in attempts if now - t < 600]
            repaired_failure = record.get("repairedFailureAt")
            if (observation.get("failure") == "model-compatibility" and observation.get("failureAt")
                    and repaired_failure == observation["failureAt"]):
                plan = {"state": "awaiting-validation", "actions": []}
            record = {"observedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "state": plan["state"],
                      "actions": [], "restartAttempts": attempts, "nextAttemptAt": 0,
                      "repairedFailureAt": repaired_failure, "observation": observation,
                      "lastNotification": record.get("lastNotification", {})}
            try:
                package_verified = False
                for action in plan["actions"]:
                    if automatic and not b.load_state().get("recovery", {}).get("enabled"):
                        record["state"] = "off"
                        break
                    if len(attempts) >= 3:
                        record["state"] = "circuit-open"
                        break
                    if action in {"start-launcher", "restart-backend", "restore-route"} and not package_verified:
                        # Recheck immutable executable content once per repair batch.
                        package = b.package_state()
                        package_verified = package.get("state") == "verified" and package.get("unpacked") == "verified"
                        if not package_verified:
                            record["state"] = "configuration-conflict"
                            break
                    # Persist intent/budget before any mutation, including failure/timeout.
                    attempts.append(now)
                    record.update(restartAttempts=attempts, pendingAction=action,
                                  nextAttemptAt=now + min(600, 60 * 2 ** len(attempts)))
                    self.write(record)
                    if action == "restore-composer":
                        b.ensure_dom_compat(restart=True)
                    elif action == "restore-shortcuts":
                        self.restore_account_shortcuts()
                    elif action == "restore-login-entry":
                        b.restore_autostart()
                    elif action == "start-launcher":
                        b.launch()
                    elif action == "restart-backend":
                        # The desktop stays open. Never replay a user's request.
                        if not any(p.get("managed") for p in b.launcher_processes()):
                            record["state"] = "isolation-conflict"
                            break
                        code, _, _ = b.runner.run(["systemctl", "--user", "restart", self.paths.unit_name], timeout=60)
                        if code:
                            raise RuntimeError("reinício do backend não confirmado")
                    elif action == "restore-route":
                        b.route_enable()
                    record["actions"].append(action)
                    record.pop("pendingAction", None)
                if record["actions"]:
                    if any(a in record["actions"] for a in ("start-launcher", "restart-backend")):
                        b._wait(lambda: b.runner.port_in_use(self.paths.port), 35,
                                "backend ainda indisponível", "recovery-timeout")
                    after = self.observe()
                    record["after"] = after
                    record["state"] = decisions(after)["state"]
                    if "restore-composer" in record["actions"] and observation.get("failureAt"):
                        record.update(repairedFailureAt=observation["failureAt"], state="awaiting-validation")
            except Exception as error:
                record.update(state="repair-failed", errorCode=getattr(error, "code", type(error).__name__))
            if record["state"] not in {"ready", "off"}:
                record["nextAttemptAt"] = max(record["nextAttemptAt"], now + 60)
            notices = {"login-required": "Renove o login no ChatGPT pelo launcher desta conta.",
                       "permission-required": "Confira a permissão do conector ou o prazo da chave pelo PhaseZero.",
                       "circuit-open": "Reparos pausados após falhas repetidas. Abra Diagnosticar no PhaseZero.",
                       "configuration-conflict": "Configuração diferente da gerenciada; preservada. Abra Diagnosticar no PhaseZero."}
            notice = record["lastNotification"]
            if record["state"] in notices and now - notice.get(record["state"], 0) >= 1800:
                b.runner.notify("Codex Web — ação necessária", notices[record["state"]])
                notice[record["state"]] = now
            self.write(record)
            return record
