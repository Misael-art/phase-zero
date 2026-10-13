from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ai.account_contract import Connection  # noqa: E402
from linux.ai.grants import GrantError, GrantLedger  # noqa: E402
from linux.ai.account_adapters import router_provider_accounts  # noqa: E402


def test_grants_require_compatibility_and_explicit_consent(tmp_path):
    ledger = GrantLedger(tmp_path / "state" / "grants.json")
    connection = Connection("opaque-connection", "opaque-account", "claude-auth",
                            "local:claude", enabled=True)
    support = {"app.claude-code": {"claude-auth": ("session",)}}

    with pytest.raises(GrantError, match="consent"):
        ledger.grant(connection, "app.claude-code", ("session",),
                     support=support, consented=False)
    with pytest.raises(GrantError, match="does not support"):
        ledger.grant(connection, "app.opencode", ("session",),
                     support=support, consented=True)
    with pytest.raises(GrantError, match="requested scopes"):
        ledger.grant(connection, "app.claude-code", ("cookies",),
                     support=support, consented=True)

    disabled = Connection("disabled-connection", "opaque-account", "claude-auth",
                          "local:claude", enabled=False)
    with pytest.raises(GrantError, match="connection is disabled"):
        ledger.grant(disabled, "app.claude-code", ("session",),
                     support=support, consented=True)


def test_grant_revoke_are_idempotent_and_scoped_to_consumer(tmp_path):
    path = tmp_path / "state" / "grants.json"
    ledger = GrantLedger(path)
    connection = Connection("opaque-connection", "opaque-account", "claude-auth",
                            "local:claude", enabled=True)
    support = {"app.claude-code": {"claude-auth": ("session", "models")}}
    first = ledger.grant(connection, "app.claude-code", ("session",),
                         support=support, consented=True)
    again = ledger.grant(connection, "app.claude-code", ("session",),
                         support=support, consented=True)
    assert first == again
    assert ledger.for_consumer("app.claude-code") == (first,)
    assert ledger.for_consumer("app.opencode") == ()

    revoked = ledger.revoke(first.grant_id)
    assert revoked is not None and not revoked.enabled and revoked.revoked_at
    assert ledger.revoke(first.grant_id) == revoked
    assert ledger.for_consumer("app.claude-code") == ()

    loaded = GrantLedger(path)
    assert loaded.for_consumer("app.claude-code") == ()
    payload = json.loads(path.read_text())
    assert "secret_ref" not in str(payload) and "opaque-account" not in str(payload)
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700


def test_revoked_grant_requires_new_explicit_consent():
    ledger = GrantLedger()
    connection = Connection("c", "a", "adapter", "instance", enabled=True)
    support = {"consumer": {"adapter": ("read",)}}
    first = ledger.grant(connection, "consumer", ("read",),
                         support=support, consented=True)
    ledger.revoke(first.grant_id)
    reauthorized = ledger.grant(connection, "consumer", ("read",),
                                support=support, consented=True)
    assert reauthorized.enabled
    assert reauthorized.grant_id == first.grant_id
    assert reauthorized.consented_at
    assert not reauthorized.revoked_at


def test_router_account_adapter_and_routing_share_opaque_grant_id():
    from linux.ai.routing_manager import _contract_connection_id

    rows = {"connections": [{"id": "record-7", "provider": "codex"}]}
    adapted = router_provider_accounts(rows)
    assert len(adapted) == 1
    _, connection = adapted[0]
    assert connection.connection_id == _contract_connection_id("codex", "record-7")


def _write_enabled_grant(path: Path) -> None:
    ledger = GrantLedger(path)
    connection = Connection("connection", "account", "adapter", "local", enabled=True)
    ledger.grant(
        connection, "consumer", ("inference",),
        support={"consumer": {"adapter": ("inference",)}}, consented=True,
    )


@pytest.mark.parametrize("enabled_value", ["false", 1, None])
def test_grant_ledger_rejects_non_boolean_enabled_state(tmp_path, enabled_value):
    path = tmp_path / "state" / "grants.json"
    _write_enabled_grant(path)
    payload = json.loads(path.read_text())
    payload["grants"][0]["enabled"] = enabled_value
    path.write_text(json.dumps(payload))

    with pytest.raises(GrantError, match="enabled"):
        GrantLedger(path)


@pytest.mark.parametrize("payload", [
    [],
    {"schemaVersion": True, "grants": []},
    {"schemaVersion": 1, "grants": [None]},
    {"schemaVersion": 1, "grants": [{}]},
])
def test_grant_ledger_rejects_malformed_json_shapes(tmp_path, payload):
    path = tmp_path / "state" / "grants.json"
    path.parent.mkdir()
    path.write_text(json.dumps(payload))

    with pytest.raises(GrantError):
        GrantLedger(path)
