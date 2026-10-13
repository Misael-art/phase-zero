from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .result_parser import is_failure_report


@dataclass(frozen=True)
class ActionParameter:
    name: str
    label: str
    kind: str = "text"
    required: bool = True
    choices: tuple[str, ...] = field(default_factory=tuple)
    placeholder: str = ""


@dataclass(frozen=True)
class ActionSpec:
    id: str
    category: str
    title: str
    description: str
    args: tuple[str, ...]
    icon: str
    mutable: bool = False
    preview_args: tuple[str, ...] | None = None
    elevated: bool = False
    badge: str = ""
    input_label: str = ""
    input_kind: str = ""
    keywords: tuple[str, ...] = field(default_factory=tuple)
    group: str = "Geral"
    visibility: str = "standard"
    platforms: tuple[str, ...] = ("linux",)
    risk: str = "normal"
    status_args: tuple[str, ...] | None = None
    parameters: tuple[ActionParameter, ...] = field(default_factory=tuple)
    preview_bindings: tuple[tuple[str, str], ...] = field(default_factory=tuple)
    result_view: str = "auto"
    # Name of the parameter whose value is written to the process stdin instead
    # of argv. Secrets must never reach a command line: argv is world-readable
    # through /proc and lands in the runner's own echoed command display.
    stdin_parameter: str = ""
    # Restore previews need the passphrase to verify/decrypt the bundle before
    # any mutation. The value still travels only through stdin.
    stdin_on_preview: bool = False
    # LUX-001: what the user is told will change when the preview is only a
    # state read. Mandatory for high-risk actions without a real plan.
    impact: str = ""
    # "" = infer from preview_args; "plan" or "state" force the kind.
    preview_kind_override: str = ""
    # LUX-022: per-action timeout in seconds (0 = runner default by kind).
    timeout_s: int = 0

    @property
    def preview_kind(self) -> str:
        """``plan`` when the preview simulates the change, else ``state``."""
        if self.preview_kind_override:
            return self.preview_kind_override
        text = " ".join(self.preview_args or ())
        if any(marker in text for marker in ("dry-run", "plan", "preview")):
            return "plan"
        return "state"

    def resolved_args(
        self,
        value: str = "",
        *,
        preview: bool = False,
        values: dict[str, str] | None = None,
    ) -> list[str]:
        source = self.preview_args if preview and self.preview_args is not None else self.args
        resolved_values = dict(values or {})
        if value:
            resolved_values.setdefault("input", value)
        output: list[str] = []
        for token in source:
            if token.startswith("{") and token.endswith("}"):
                name = token[1:-1]
                # A stdin-bound parameter is deliberately absent from argv; its
                # placeholder must never survive into the command line either.
                if name == self.stdin_parameter:
                    continue
                output.append(resolved_values.get(name, token))
            else:
                output.append(token)
        return output

    @property
    def parameter_names(self) -> tuple[str, ...]:
        names = [parameter.name for parameter in self.parameters]
        names.extend(name for name, _key in self.preview_bindings)
        if self.input_kind and "input" not in names:
            names.append("input")
        return tuple(names)

    @property
    def searchable_text(self) -> str:
        return " ".join(
            (self.title, self.description, self.category, self.badge, *self.args, *self.keywords)
        ).casefold()

    @property
    def variant(self) -> str:
        """Visual weight of the primary button: danger / primary / secondary."""
        if self.badge in {"Alto risco", "Resgate"}:
            return "danger"
        if self.mutable:
            return "primary"
        return "secondary"

    @property
    def state(self) -> str:
        """Semantic colour of the badge chip (EmuDeck-style status colours)."""
        mapping = {
            "Alto risco": "error",
            "Resgate": "error",
            "Reparo": "warning",
            "Requer ISO": "warning",
            "Reversível": "success",
            "Protegido": "success",
            "Seguro": "success",
        }
        if self.badge in mapping:
            return mapping[self.badge]
        if self.elevated:
            return "warning"
        return "info"


@dataclass(frozen=True)
class ProductInstance:
    """One observed installation or service, never an installation instruction.

    ``origin=unknown`` is required for package probes that cannot distinguish
    PhaseZero-owned files from software installed outside PhaseZero.
    """

    instance_id: str
    app_id: str
    host_id: str
    scope: str
    manager: str = "unknown"
    version: str = ""
    installation: str = "unknown"  # present | absent | unknown
    origin: str = "unknown"  # phasezero | external | unknown
    configuration: str = "unknown"  # ready | needed | unknown
    health: str = "unknown"  # online | offline | failed | unknown
    observed_at: str = ""
    details: str = ""
    usage_blocked: bool = False
    blocked_reason: str = ""
    launchable: bool = False

    def __post_init__(self) -> None:
        if (
            not self.instance_id or not self.app_id.startswith("app.")
            or not self.host_id or not self.scope
        ):
            raise ValueError("product instance needs stable ID, app ID and host ID")
        if self.installation not in {"present", "absent", "unknown"}:
            raise ValueError("invalid installation state")
        if self.origin not in {"phasezero", "external", "unknown"}:
            raise ValueError("invalid installation origin")
        if self.configuration not in {"ready", "needed", "unknown"}:
            raise ValueError("invalid configuration state")
        if self.health not in {"online", "offline", "failed", "unknown"}:
            raise ValueError("invalid health state")
        if type(self.usage_blocked) is not bool:
            raise ValueError("invalid usage permission state")
        if type(self.launchable) is not bool:
            raise ValueError("invalid launchability state")
        if self.launchable and (self.installation != "present" or self.configuration != "ready"):
            raise ValueError("launchable instance needs installed, configured app")
        if not isinstance(self.blocked_reason, str):
            raise ValueError("invalid usage block reason")
        if self.origin == "external" and self.installation != "present":
            raise ValueError("external installation must be present")

    @property
    def next_action(self) -> str:
        if self.installation == "absent":
            return "prepare"
        if self.installation == "unknown":
            return "verify"
        if self.configuration == "needed":
            return "configure"
        if self.launchable and self.configuration == "ready" and self.health == "unknown":
            return "open"
        if self.configuration == "unknown" or self.health == "unknown":
            return "verify"
        if self.health in {"offline", "failed"}:
            return "resolve"
        return "open"

    @property
    def ready(self) -> bool:
        return self.next_action == "open" and not self.usage_blocked

    def to_dict(self) -> dict[str, str | bool | int]:
        return {
            "schemaVersion": 1,
            "instanceId": self.instance_id,
            "appId": self.app_id,
            "hostId": self.host_id,
            "scope": self.scope,
            "manager": self.manager,
            "version": self.version,
            "installation": self.installation,
            "origin": self.origin,
            "configuration": self.configuration,
            "health": self.health,
            "observedAt": self.observed_at,
            "usageBlocked": self.usage_blocked,
            "blockedReason": self.blocked_reason,
            "launchable": self.launchable,
            "nextAction": self.next_action,
            "ready": self.ready,
        }


@dataclass
class OperationResult:
    action_id: str
    command: list[str]
    preview: bool
    exit_code: int
    started_at: str
    finished_at: str
    stdout: str
    stderr: str
    parsed: Any = None
    result_path: Path | None = None
    operation_id: str = ""
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        if self.exit_code != 0:
            return False
        if isinstance(self.parsed, dict) and self.parsed.get("ok") is False:
            return False
        if is_failure_report(self.parsed):
            return False
        return True

    @property
    def severity(self) -> str:
        return "success" if self.exit_code == 0 else "error"

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "operationId": self.operation_id,
            "action": self.action_id,
            "command": self.command,
            "preview": self.preview,
            "ok": self.ok,
            "exitCode": self.exit_code,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "result": self.parsed,
        }
