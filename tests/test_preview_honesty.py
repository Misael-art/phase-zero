"""LUX-001 — prévia de estado não se passa por simulação."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import ActionSpec, OperationResult

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def by_id():
    return {action.id: action for action in build_catalog(ROOT)}


def _result(action):
    return OperationResult(
        action_id=action.id, command=["pz"], preview=True, exit_code=0,
        started_at="", finished_at="", stdout="{}", stderr="", parsed={},
    )


def _texts(dialog):
    return " ".join(label.text() for label in dialog.findChildren(QLabel))


def test_every_high_risk_action_has_plan_or_impact(by_id):
    missing = [
        action.id for action in by_id.values()
        if action.mutable and action.risk == "high"
        and action.preview_kind != "plan" and not action.impact
    ]
    assert missing == []


def test_preview_kind_inference(by_id):
    assert by_id["waydroid.boot.next-reboot"].preview_kind == "state"
    assert by_id["host.wipe"].preview_kind == "plan"
    assert by_id["waydroid.shares.enable"].preview_kind == "plan"


def test_state_preview_never_claims_simulation(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.boot.next-reboot"]
    dialog = PreviewDialog(_result(action), action)
    text = _texts(dialog)
    assert "Preview concluído" not in text
    assert "não simula" in text
    assert "REINICIA o computador" in text
    # impacto aparece antes do campo CONFIRMAR
    assert dialog.body.indexOf(dialog.impact_label) < dialog.body.indexOf(dialog.confirmation)


def test_plan_preview_keeps_plan_copy(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    dialog = PreviewDialog(_result(action), action)
    assert "Preview concluído" in _texts(dialog)
    assert not hasattr(dialog, "impact_label")


def test_blocked_preview_explains_why(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    result = _result(action)
    result.parsed = {"blockers": ["Waydroid não está instalado"]}
    dialog = PreviewDialog(result, action)
    text = _texts(dialog)
    assert dialog.windowTitle() == "Não é seguro aplicar agora"
    assert "Preview concluído" not in text
    assert "Waydroid não está instalado" in text
    assert not dialog.confirm.isEnabled()
    assert dialog.blocked_reason.text()


def test_failed_preview_is_not_called_complete(qapp, by_id):
    from linux.ui_native.widgets import PreviewDialog

    action = by_id["waydroid.shares.enable"]
    result = _result(action)
    result.exit_code = 1
    result.parsed = None
    dialog = PreviewDialog(result, action)
    assert "Preview concluído" not in _texts(dialog)
    assert "falhou" in _texts(dialog)


def test_capability_plan_space_is_visible_before_apply(qapp):
    from linux.ui_native.widgets import PreviewDialog

    action = ActionSpec(
        id="capability.profile.development-web-js", category="Desenvolvimento",
        title="Preparar Web JS", description="", args=("capabilities", "apply"),
        icon="system-run", mutable=True,
        preview_args=("capabilities", "plan", "--profile", "development-web-js"),
    )
    result = OperationResult(
        action_id=action.id, command=["linux/pz", "capabilities", "plan"],
        preview=True, exit_code=0, started_at="", finished_at="", stdout="{}",
        stderr="", parsed={
            "schema": "pz.capabilities/v1", "kind": "plan", "status": "ready",
            "space": {
                "status": "partial", "estimateCompleteness": "resolved-local-package-indexes",
                "targets": {"system": {
                    "downloadBytes": 2 * 1024 * 1024,
                    "installedBytes": 8 * 1024 * 1024,
                    "availableBytes": 20 * 1024 * 1024 * 1024,
                }},
            },
        },
    )
    dialog = PreviewDialog(result, action, advanced_mode=False)
    text = _texts(dialog)
    assert "Espaço estimado antes da alteração" in text
    assert "Sistema: baixar 2.0 MiB · instalação 8.0 MiB · livre 20.0 GiB" in text
    assert "índices locais" in text
    assert dialog.technical.isHidden()


def test_capability_plan_discloses_lower_bound_in_normal_preview(qapp):
    from linux.ui_native.widgets import PreviewDialog

    result = _result(ActionSpec(
        id="capability.plan.test", category="Desenvolvimento", title="Plano",
        description="", args=("capabilities", "apply"), icon="system-run",
        mutable=True, preview_args=("capabilities", "plan", "--capability", "x"),
    ))
    result.parsed = {
        "kind": "plan", "status": "ready",
        "space": {
            "estimateCompleteness": "direct-packages-lower-bound",
            "targets": {"system": {
                "downloadBytes": 100, "installedBytes": 400, "availableBytes": 900,
            }},
        },
    }
    dialog = PreviewDialog(result)
    assert "Estimativa parcial" in _texts(dialog)
    assert "dependências transitivas" in _texts(dialog)


def test_capability_conflict_and_space_both_appear_before_confirmation(qapp):
    from linux.ui_native.widgets import PreviewDialog

    result = OperationResult(
        action_id="capability.plan.test", command=["linux/pz", "capabilities", "plan"],
        preview=True, exit_code=0, started_at="", finished_at="", stdout="{}",
        stderr="", parsed={
            "kind": "plan", "status": "blocked", "ok": False,
            "blockers": ["conflito instalado: iwd requer remoção manual"],
            "space": {
                "estimateCompleteness": "direct-packages-lower-bound",
                "targets": {"system": {
                    "downloadBytes": 100, "installedBytes": 400, "availableBytes": 900,
                }},
            },
        },
    )
    dialog = PreviewDialog(result)
    text = _texts(dialog)
    assert "conflito instalado" in text
    assert "Espaço estimado antes da alteração" in text
    assert not dialog.confirm.isEnabled()
