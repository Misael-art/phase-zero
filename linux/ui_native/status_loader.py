from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QTimer, Signal
from shiboken6 import isValid

from .models import ActionSpec, ProductInstance
from .product_inventory import (
    instances_from_capability_status,
    instances_from_status_payload,
    status_action_matches_app,
)
from .result_parser import parse_json_output

_SECRET_PATTERNS = (
    (r"(?i)(token|secret|password|api[_-]?key)\s*[:=]\s*\S+", r"\1=[REDACTED]"),
    (r"(?:sk-|ghp_|github_pat_)[A-Za-z0-9_-]{16,}", "[REDACTED]"),
)


def redact(text: str) -> str:
    import re

    for pattern, replacement in _SECRET_PATTERNS:
        text = re.sub(pattern, replacement, text)
    return text


def report_outcome(stdout: str, stderr: str, exit_code: int) -> tuple[str, object, str]:
    """Decide whether a finished status run produced a usable report.

    Returns ("ready", parsed, "") when the command reported state as JSON —
    even with a non-zero exit code, because readiness lives in the payload —
    and ("failed", None, message) when there is no report to show.
    """
    parsed = parse_json_output(stdout)
    if isinstance(parsed, dict) and parsed:
        return "ready", parsed, ""
    if exit_code != 0:
        detail = redact(stderr.strip())[:500]
        return "failed", None, f"exit code {exit_code}" + (f": {detail}" if detail else "")
    return "ready", parsed, ""

_DEFAULT_TIMEOUT_MS = 15_000
_REMOTE_PRODUCT_STATUS_SLUGS = {
    "app.ai-memory": "ai-memory",
    "app.usagebar": "usagebar",
    "app.claude-desktop": "claude-desktop",
    "app.codex-desktop": "codex-desktop",
    "app.qwen-code-desktop": "qwen-code-desktop",
}
_HOST_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_HOST_ID = re.compile(r"^hlh-[0-9a-f]{12}$")
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
_ACTION_TIMEOUT_MS = {
    # Windows status includes bounded libvirt, Samba, disk and boot probes.
    # Slower storage/daemon recovery can legitimately exceed the generic UI
    # budget without meaning that the VM state is unavailable.
    "windows.status": 45_000,
}


def remote_product_status_slug(action: ActionSpec, app_id: str) -> str | None:
    """Return a fixed read-only remote route only for reviewed product probes."""
    slug = _REMOTE_PRODUCT_STATUS_SLUGS.get(app_id)
    if (
        slug is None or action.mutable
        or tuple(action.status_args) != ("ai", "product-status", slug)
    ):
        return None
    return slug


def validate_remote_product_status(payload: object, expected_alias: str) -> dict[str, object]:
    """Unwrap only a successful JSON envelope for the selected Homelab alias."""
    if (
        not isinstance(payload, dict) or not isinstance(expected_alias, str)
        or not _HOST_ALIAS.fullmatch(expected_alias)
    ):
        raise ValueError("remote status envelope unavailable")
    schema_version = payload.get("schemaVersion")
    if (
        not ((type(schema_version) is str and schema_version == "1")
             or (type(schema_version) is int and schema_version == 1))
        or payload.get("tool") != "homelab-hosts"
        or payload.get("action") != "exec"
        or payload.get("hostAlias") != expected_alias
        or type(payload.get("rc")) is not int
        or payload.get("rc") != 0
        or not isinstance(payload.get("remoteVersion"), str)
        or _VERSION.fullmatch(str(payload.get("remoteVersion"))) is None
        or not isinstance(payload.get("payload"), dict)
    ):
        raise ValueError("remote status did not match selected Homelab host")
    return payload["payload"]


class StatusLoader(QObject):
    """Fetches status for read-only actions asynchronously via QProcess.

    Unlike CommandRunner, this runs multiple status commands in parallel
    (read-only, non-blocking) and does not use the operation panel.
    """

    status_ready = Signal(str, str, object)  # (action_id, stdout, parsed_result)
    status_failed = Signal(str, str)          # (action_id, error_message)
    product_instances_ready = Signal(str, object)  # (action_id, tuple[ProductInstance, ...])

    def __init__(self, root: Path, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self.root = root
        self._processes: dict[str, QProcess] = {}
        self._product_contexts: dict[str, tuple[str, str, str, str, str | None]] = {}

    def _pz_path(self) -> Path:
        return self.root / "linux" / "pz"

    def fetch(self, action_id: str, args: list[str]) -> None:
        """Start fetching status for the given action. Idempotent per action_id."""
        if action_id in self._processes:
            return  # already fetching
        pz = str(self._pz_path())
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        process.setProgram(pz)
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.finished.connect(
            lambda code, _status, aid=action_id: self._on_finished(aid, code, process)
        )
        process.errorOccurred.connect(
            lambda err, aid=action_id: self._on_error(aid, err, process)
        )
        self._processes[action_id] = process
        process.start()
        # Safety timeout remains bounded, but complex aggregate probes receive
        # an explicit budget instead of being reported as unavailable at 15s.
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(lambda: self._on_timeout(action_id, process))
        timer.start(self.timeout_ms(action_id))
        process.setProperty("timeout_timer", timer)

    def fetch_action(self, action: ActionSpec) -> None:
        """Fetch status using the action's explicit read-only status contract."""
        args = action.status_args or action.args
        if any(token.startswith("{") and token.endswith("}") for token in args):
            self.status_failed.emit(action.id, "status requires parameters")
            return
        self.fetch(action.id, list(args))

    def fetch_product_status(
        self,
        action: ActionSpec,
        *,
        app_id: str,
        host_id: str,
        scope: str,
        instance_key: str = "default",
        remote_alias: str | None = None,
    ) -> None:
        """Fetch a read-only status action and publish normalized instance state."""
        if action.mutable:
            self.status_failed.emit(action.id, "product status requires a read-only action")
            return
        if not app_id.startswith("app.") or not host_id or not scope or not instance_key:
            self.status_failed.emit(action.id, "invalid product status context")
            return
        if not status_action_matches_app(action, app_id):
            self.status_failed.emit(action.id, "status action does not match product context")
            return
        if not action.status_args:
            self.status_failed.emit(action.id, "product status requires explicit read-only arguments")
            return
        if remote_alias is None and host_id != "local":
            self.status_failed.emit(
                action.id, "remote product status requires a host-bound executor",
            )
            return
        args = action.status_args
        if any(token.startswith("{") and token.endswith("}") for token in args):
            self.status_failed.emit(action.id, "status requires parameters")
            return
        if remote_alias is not None:
            slug = remote_product_status_slug(action, app_id)
            expected_host_id = (
                "hlh-" + hashlib.sha256(remote_alias.encode("utf-8")).hexdigest()[:12]
                if isinstance(remote_alias, str) else ""
            )
            if (
                not isinstance(host_id, str) or not _HOST_ID.fullmatch(host_id)
                or not isinstance(remote_alias, str)
                or not _HOST_ALIAS.fullmatch(remote_alias) or slug is None
                or host_id != expected_host_id
            ):
                self.status_failed.emit(action.id, "no allowlisted remote product status route")
                return
            args = ["server", "homelab", "--host", remote_alias, "product-status", slug]
        # Selection can change while a previous host/account probe is active.
        # Cancel it before replacing context so late output cannot be relabeled.
        if action.id in self._processes or action.id in self._product_contexts:
            self.cancel(action.id)
        self._product_contexts[action.id] = (app_id, host_id, scope, instance_key, remote_alias)
        self.fetch(action.id, list(args))

    def product_instances_from_result(
        self, action_id: str, payload: object,
    ) -> tuple[ProductInstance, ...]:
        """Normalize one status response using context registered at fetch time."""
        context = self._product_contexts.pop(action_id, None)
        if context is None:
            return ()
        app_id, host_id, scope, instance_key, _remote_alias = context
        if not isinstance(payload, dict):
            return ()
        if isinstance(payload.get("capabilities"), list):
            return tuple(
                instance for instance in instances_from_capability_status(
                    payload, host_id=host_id, scope=scope,
                )
                if instance.app_id == app_id
            )
        return instances_from_status_payload(
            payload, app_id=app_id, host_id=host_id, scope=scope,
            instance_key=instance_key,
        )

    def cancel(self, action_id: str) -> None:
        self._product_contexts.pop(action_id, None)
        process = self._processes.pop(action_id, None)
        if process is not None and isValid(process) and process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)

    def cancel_all(self) -> None:
        for action_id in list(self._processes.keys()):
            self.cancel(action_id)

    def running(self, action_id: str) -> bool:
        return action_id in self._processes

    @staticmethod
    def timeout_ms(action_id: str) -> int:
        return _ACTION_TIMEOUT_MS.get(action_id, _DEFAULT_TIMEOUT_MS)

    def _on_finished(self, action_id: str, exit_code: int, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return  # already handled by timeout/error
        stdout = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace")
        stderr = bytes(process.readAllStandardError().data()).decode("utf-8", errors="replace")
        self._cleanup_process(action_id, process)
        outcome, parsed, message = report_outcome(stdout, stderr, exit_code)
        if outcome == "ready":
            context = self._product_contexts.get(action_id)
            remote_alias = context[4] if context is not None else None
            if remote_alias is not None:
                try:
                    parsed = validate_remote_product_status(parsed, remote_alias)
                    stdout = json.dumps(parsed, separators=(",", ":"))
                except ValueError as exc:
                    self._product_contexts.pop(action_id, None)
                    self.status_failed.emit(action_id, str(exc))
                    return
            instances = self.product_instances_from_result(action_id, parsed)
            if instances:
                self.product_instances_ready.emit(action_id, instances)
            self.status_ready.emit(action_id, stdout, parsed)
        else:
            self._product_contexts.pop(action_id, None)
            self.status_failed.emit(action_id, message)

    def _on_error(self, action_id: str, error: QProcess.ProcessError, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return
        if error == QProcess.FailedToStart:
            self._cleanup_process(action_id, process)
            self._product_contexts.pop(action_id, None)
            self.status_failed.emit(action_id, "failed to start")

    def _on_timeout(self, action_id: str, process: QProcess) -> None:
        if action_id not in self._processes or not isValid(process):
            return
        if process.state() != QProcess.NotRunning:
            process.kill()
            process.waitForFinished(1000)
        self._cleanup_process(action_id, process)
        self._product_contexts.pop(action_id, None)
        self.status_failed.emit(action_id, "timed out")

    def _cleanup_process(self, action_id: str, process: QProcess | None) -> None:
        timer = process.property("timeout_timer") if process is not None and isValid(process) else None
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        self._processes.pop(action_id, None)
        if process is not None and isValid(process):
            process.deleteLater()
