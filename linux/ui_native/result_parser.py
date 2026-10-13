from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def parse_json_output(text: str) -> Any:
    stripped = text.strip()
    if not stripped:
        return None
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    decoder = json.JSONDecoder()
    candidates: list[tuple[int, int, Any]] = []
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            value, consumed = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        candidates.append((index + consumed, -index, value))
    if not candidates:
        return None
    # Prefer final complete JSON value. For nested values ending at same byte,
    # prefer earliest start, which is the outer envelope.
    return max(candidates, key=lambda item: (item[0], item[1]))[2]


def _has_output(value: Any) -> bool:
    if isinstance(value, dict):
        return bool(value)
    if isinstance(value, list):
        return bool(value)
    if isinstance(value, str):
        return bool(value.strip())
    return value is not None


# Statuses that mean "valid report, action pending on the user/environment"
# rather than "the tool failed".
_RESUMABLE_STATUSES = {
    "warn", "warning", "degraded", "needsinstall", "needsrepair",
    "needs-login", "needslogin", "needs-credentials", "needscredentials",
    "gui-required", "guirequired",
}

# LUX-003: envelopes cujo estado diz que a operação falhou. Um nextAction ou
# resumable junto não transforma falha em "pendente".
_FAILURE_STATES = {
    "error", "failed", "failure", "fail", "blocked", "timeout", "timed-out",
    "unhealthy", "crashed", "aborted", "manualaction",
}


def is_failure_report(value: Any) -> bool:
    """Whether a structured result's top-level status is a failure."""
    if not isinstance(value, dict):
        return False
    return str(value.get("status", "")).strip().casefold() in _FAILURE_STATES


def restart_required(value: Any) -> bool:
    """True when the payload asks for a reboot to finish (not a failure)."""
    if not isinstance(value, dict):
        return False
    return str(value.get("status", "")).casefold().replace("-", "") == "requiresrestart"


def is_pending_report(value: Any) -> bool:
    """True when the payload is a valid diagnostic saying work is pending.

    Readiness/state lives in these payloads (homelab ``state``, AI proxies
    ``resumable``, legacy ``status`` warnings); a run that produced one did its
    job even with a non-zero exit code.
    """
    if not isinstance(value, dict) or not value:
        return False
    for key in ("state", "status"):
        if str(value.get(key, "")).strip().casefold() in _FAILURE_STATES:
            return False
    if value.get("resumable") is True:
        return True
    state = value.get("state")
    if isinstance(state, str) and state.strip():
        return True
    if str(value.get("status", "")).casefold() in _RESUMABLE_STATUSES:
        return True
    next_action = value.get("nextAction")
    return isinstance(next_action, str) and bool(next_action.strip())


def guidance(value: Any) -> dict[str, Any]:
    """Unified orientation fields across backend envelope dialects.

    Backends emit either ``next`` (legacy AI proxies) or ``nextAction``
    (homelab/ledger), plus optional ``summary`` and ``reasons``. Consumers
    render whatever this returns without caring which dialect produced it.
    """
    out: dict[str, Any] = {"summary": None, "next_action": None, "reasons": []}
    if not isinstance(value, dict):
        return out
    summary = value.get("summary") or value.get("message")
    if isinstance(summary, str) and summary.strip():
        out["summary"] = summary.strip()
    nxt = value.get("nextAction") or value.get("next")
    if isinstance(nxt, str) and nxt.strip():
        out["next_action"] = nxt.strip()
    reasons = value.get("reasons")
    if isinstance(reasons, list):
        out["reasons"] = [str(item) for item in reasons[:6]]
    return out


def severity_for(value: Any, exit_code: int, *, mutable: bool = True, has_output: bool | None = None) -> str:
    if exit_code != 0:
        if is_pending_report(value):
            return "warning"
        if mutable:
            return "error"
        if has_output is None:
            has_output = _has_output(value)
        return "warning" if has_output else "error"
    if not isinstance(value, dict):
        return "success"
    if restart_required(value):
        return "warning"
    if is_failure_report(value):
        return "error"
    status = str(value.get("status", "")).casefold()
    if status in {
        "warn", "warning", "degraded", "needsinstall", "needsrepair",
        "needs-login", "needslogin", "needs-credentials", "needscredentials",
        "gui-required", "guirequired",
    }:
        return "warning"
    # Payloads cujo veredito é só "ok" (verify, rescue-wallpaper) saem do
    # motor com exit 0; ok:false aqui é falha, não sucesso. Planos bloqueados
    # carregam "blockers" e são resultado, não erro (mesmo contrato do _emit).
    if value.get("ok") is False and "blockers" not in value:
        return "error" if mutable else "warning"
    return "success"


def load_result(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("result root must be object")
    return value
