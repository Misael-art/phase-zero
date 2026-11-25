"""Diagnóstico que encontra problemas é resultado, não falha do PhaseZero."""
from __future__ import annotations

from pathlib import Path

import pytest

from linux.ui_native.health_models import health_summary, parse_health_checks
from linux.ui_native.models import ActionSpec, OperationResult
from linux.ui_native.operation_ledger import OperationLedger
from linux.ui_native.status_loader import report_outcome

CHECKS = [
    "[PASS] MEM01: Total RAM >= 4GB — 14GB",
    "[WARN] DISK__mnt_BIGLIVE: /mnt/BIGLIVE usage — 89% used",
    "[FAIL] CPU01: CPU temperature — 96°C (critical 105°C)",
    "[INFO] SVC_docker: docker running — not installed (optional)",
]
DOCTOR_STDOUT = "=== Summary ===\nResults JSON:\n[\n" + ",\n".join(
    f'  "{line}"' for line in CHECKS
) + "\n]\n"


@pytest.fixture
def qapp():
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def _doctor_action() -> ActionSpec:
    return ActionSpec(
        id="system.doctor.system",
        category="Visão geral",
        title="Saúde do sistema",
        description="Checagem rápida",
        args=("doctor", "--scope", "system"),
        icon="dialog-information",
        mutable=False,
    )


def test_status_loader_accepts_check_list_with_nonzero_exit():
    outcome, parsed, message = report_outcome(DOCTOR_STDOUT, "", 1)
    assert outcome == "ready"
    assert message == ""
    assert len(parse_health_checks(parsed)) == 4


def test_status_loader_still_fails_without_report():
    outcome, parsed, _ = report_outcome("", "boom", 1)
    assert outcome == "failed"
    assert parsed is None


def test_ledger_marks_read_only_findings_as_attention(tmp_path: Path):
    ledger = OperationLedger(tmp_path / "operations")
    ledger.begin(_doctor_action(), preview=False)
    ledger.finish(exit_code=1, findings=True)
    record = OperationLedger(tmp_path / "operations").records()[0]
    assert record["status"] == "attention"
    assert record["resumable"] is False


def test_ledger_keeps_failed_without_findings(tmp_path: Path):
    ledger = OperationLedger(tmp_path / "operations")
    ledger.begin(_doctor_action(), preview=False)
    ledger.finish(exit_code=1)
    assert OperationLedger(tmp_path / "operations").records()[0]["status"] == "failed"


def test_friendly_copy_for_disk_temperature_and_services():
    checks = {check.check_id: check for check in parse_health_checks(CHECKS)}
    assert checks["DISK__mnt_BIGLIVE"].title == "Espaço livre em /mnt/BIGLIVE"
    assert checks["DISK__mnt_BIGLIVE"].detail == "89% ocupado"
    assert checks["CPU01"].title == "Temperatura do processador"
    assert "105 °C" in checks["CPU01"].detail
    assert checks["SVC_docker"].detail == "não instalado (opcional)"
    assert not checks["SVC_docker"].needs_attention


def test_summary_names_counts_in_plain_words():
    assert health_summary(parse_health_checks(CHECKS)) == (
        "Encontramos 1 erro e 1 aviso. Veja abaixo o que revisar; nada foi alterado."
    )
    assert health_summary(parse_health_checks(CHECKS[:1])).startswith("Tudo certo")


def test_result_dialog_lists_what_to_review(qapp):
    from PySide6.QtWidgets import QLabel

    from linux.ui_native.result_parser import parse_json_output
    from linux.ui_native.widgets import ResultDialog

    result = OperationResult(
        action_id="system.doctor.system",
        command=["linux/pz", "doctor", "--scope", "system"],
        preview=False,
        exit_code=1,
        started_at="2026-11-24T00:00:00Z",
        finished_at="2026-11-24T00:00:01Z",
        stdout=DOCTOR_STDOUT,
        stderr="",
        parsed=parse_json_output(DOCTOR_STDOUT),
    )
    dialog = ResultDialog(result, DOCTOR_STDOUT, severity="warning")
    assert dialog.windowTitle() == "Diagnóstico concluído"
    labels = " | ".join(label.text() for label in dialog.findChildren(QLabel))
    assert "Encontramos 1 erro e 1 aviso" in labels
    assert "O que revisar" in labels
    assert "Temperatura do processador" in labels
    assert "Espaço livre em /mnt/BIGLIVE" in labels
    # Informativo não aparece como item a revisar.
    assert "Docker (aplicativos em contêiner)" not in labels
    assert "Informativos" in labels
