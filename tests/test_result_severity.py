"""LUX-003 — severidade nunca pinta falha como aviso."""
from __future__ import annotations

import pytest

from linux.ui_native.result_parser import (
    is_failure_report, is_pending_report, restart_required, severity_for,
)


@pytest.mark.parametrize("payload", [
    {"state": "failed", "nextAction": "pz repair"},
    {"state": "timeout"},
    {"state": "blocked", "nextAction": "x"},
    {"state": "unhealthy"},
    {"status": "failed", "nextAction": "x"},
    {"status": "error", "resumable": False, "nextAction": "x"},
])
def test_failure_state_with_nonzero_exit_is_error(payload):
    assert is_pending_report(payload) is False
    assert severity_for(payload, 1, mutable=True) == "error"


@pytest.mark.parametrize("payload", [
    {"state": "needs-config"},
    {"state": "needs-login", "nextAction": "pz ai login"},
    {"resumable": True},
    {"nextAction": "linux/pz server homelab repair"},
])
def test_pending_state_with_nonzero_exit_is_warning(payload):
    assert severity_for(payload, 1, mutable=True) == "warning"


def test_requires_restart_is_not_a_failure():
    payload = {"status": "requiresRestart"}
    assert severity_for(payload, 0, mutable=True) == "warning"
    assert restart_required(payload) is True
    assert restart_required({"status": "ok"}) is False


def test_ok_false_mutable_is_error():
    assert severity_for({"ok": False}, 0, mutable=True) == "error"


@pytest.mark.parametrize("status", ["failed", "failure", "error", "blocked", "manualAction"])
def test_zero_exit_structured_failure_is_not_success(status):
    from linux.ui_native.models import OperationResult

    payload = {"kind": "operation", "status": status}
    result = OperationResult(
        action_id="capability.profile.development-web-js", command=["pz"],
        preview=False, exit_code=0, started_at="", finished_at="",
        stdout="", stderr="", parsed=payload,
    )

    assert is_failure_report(payload) is True
    assert result.ok is False
    assert severity_for(payload, 0) == "error"


def test_result_dialog_titles_restart(qapp_offscreen=None):
    from PySide6.QtWidgets import QApplication
    from linux.ui_native.models import OperationResult
    from linux.ui_native.widgets import ResultDialog

    QApplication.instance() or QApplication([])
    result = OperationResult(
        action_id="x", command=["pz"], preview=False, exit_code=0,
        started_at="", finished_at="", stdout="", stderr="",
        parsed={"status": "requiresRestart"},
    )
    dialog = ResultDialog(result, "", severity="warning")
    assert dialog.windowTitle() == "Reinício necessário"
