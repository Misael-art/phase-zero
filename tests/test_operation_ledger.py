from __future__ import annotations

import json
from pathlib import Path

from linux.ui_native.models import ActionSpec
from linux.ui_native.operation_ledger import OperationLedger, status_payload


def action(*, mutable: bool = True) -> ActionSpec:
    return ActionSpec(
        id="ai.test-operation",
        category="IA & Dev",
        title="Operação de teste",
        description="Teste",
        args=("ai", "status"),
        icon="applications-development",
        mutable=mutable,
        preview_args=("ai", "status") if mutable else None,
    )


def test_ledger_persists_redacted_lifecycle(tmp_path: Path) -> None:
    ledger = OperationLedger(tmp_path / "operations")
    operation_id = ledger.begin(action(), preview=False)
    ledger.update(status="running", progress=42)
    result_path = tmp_path / "result.json"
    ledger.finish(exit_code=0, result_path=result_path)

    path = tmp_path / "operations" / operation_id / "operation.json"
    saved = json.loads(path.read_text(encoding="utf-8"))
    assert saved["status"] == "succeeded"
    assert saved["progress"] == 100
    assert saved["resultPath"] == str(result_path)
    assert saved["secretsRedacted"] is True
    assert "command" not in saved and "stdout" not in saved
    assert path.stat().st_mode & 0o777 == 0o600


def test_stale_mutation_becomes_retryable_interruption(tmp_path: Path) -> None:
    root = tmp_path / "operations"
    first = OperationLedger(root)
    operation_id = first.begin(action(), preview=False)
    first.update(status="running", progress=18)

    recovered = OperationLedger(root)
    assert recovered.recover_interrupted(force=True) == 1
    record = recovered.records()[0]
    assert record["operationId"] == operation_id
    assert record["status"] == "interrupted"
    assert record["resumable"] is True
    assert record["resumeMode"] == "retry-with-confirmation"
    assert record["nextAction"] == "ai.test-operation"


def test_preview_interruption_is_not_retryable(tmp_path: Path) -> None:
    root = tmp_path / "operations"
    first = OperationLedger(root)
    first.begin(action(), preview=True)
    assert OperationLedger(root).recover_interrupted(force=True) == 1
    record = OperationLedger(root).records()[0]
    assert record["status"] == "interrupted"
    assert record["resumable"] is False
    assert record["nextAction"] is None


def test_status_payload_counts_attention(tmp_path: Path) -> None:
    root = tmp_path / "operations"
    failed = OperationLedger(root)
    failed.begin(action(), preview=False)
    failed.finish(exit_code=1)
    success = OperationLedger(root)
    success.begin(action(mutable=False), preview=False)
    success.finish(exit_code=0)
    payload = status_payload(OperationLedger(root))
    assert payload["summary"]["total"] == 2
    assert payload["summary"]["needsAttention"] == 1
    assert payload["summary"]["byStatus"] == {"succeeded": 1, "failed": 1}
    assert payload["secretsRedacted"] is True
