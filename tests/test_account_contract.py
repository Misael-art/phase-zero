from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ai.account_contract import (  # noqa: E402
    Account, Connection, Evidence, Quota, collect_evidence, public_account, redacted_summary,
)
from linux.ai.account_adapters import (  # noqa: E402
    adapt_account_sources, claude_code_account, proxy_auth_account, router_provider_accounts,
)


def test_credential_session_service_and_quota_are_independent():
    found = Evidence("yes", "local-file", "2026-09-24T10:00:00Z")
    unknown = Evidence(error="timeout")
    connection = Connection("c1", "opaque-1", "adapter", "local", True,
                            credential=found, session=unknown, service=found,
                            access=found, quota=Quota("messages", "messages"))
    assert connection.credential.state == "yes"
    assert connection.session.state == "unknown"
    assert connection.quota.display == "não informada"
    assert not connection.usable
    assert Connection(**{**connection.__dict__, "session": Evidence("no", error="unauthorized")}).session.state == "no"
    assert Connection(**{**connection.__dict__, "session": Evidence("no", error="expired")}).session.error == "expired"
    with pytest.raises(ValueError):
        Evidence("no", error="timeout")


def test_expired_positive_evidence_cannot_make_connection_usable():
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    expired_at = now.replace(year=2000).isoformat()
    future_at = now.replace(year=2999).isoformat()
    positive = Evidence("yes", "provider-check", expires_at=future_at)
    expired = Evidence("yes", "provider-check", expires_at=expired_at)
    connection = Connection(
        "c-expired", "a-expired", "adapter", "local", True,
        credential=positive, session=expired, service=positive, access=positive,
    )

    assert positive.effective_state == "yes"
    assert expired.is_expired
    assert expired.effective_state == "no"
    assert not connection.usable


def test_local_quota_estimate_does_not_block_connection_but_official_zero_does():
    positive = Evidence("yes", "provider-check")
    base = Connection(
        "connection", "account", "adapter", "local", True,
        credential=positive, session=positive, service=positive, access=positive,
    )
    local_zero = Quota("requests", "requests", remaining=0, source="local_estimate")
    official_zero = Quota("requests", "requests", remaining=0, source="official")
    official_unknown = Quota("requests", "requests", source="official")

    assert Connection(**{**base.__dict__, "quota": local_zero}).usable
    assert not Connection(**{**base.__dict__, "quota": official_zero}).usable
    assert Connection(**{**base.__dict__, "quota": official_unknown}).usable


def test_evidence_timestamps_require_iso_timezone():
    evidence = Evidence(
        "yes", "provider-check", "2026-09-25T06:00:00Z",
        "2026-09-25T06:00:01+00:00", "2026-09-26T06:00:00Z",
    )
    assert evidence.verified_at.endswith("+00:00")
    for field in ("observed_at", "verified_at", "expires_at"):
        values = {field: "tomorrow"}
        if field == "verified_at":
            values["observed_at"] = "2026-09-25T06:00:00Z"
        with pytest.raises(ValueError, match=f"invalid evidence {field}"):
            Evidence(**values)
        values[field] = "2026-09-25T06:00:00"
        with pytest.raises(ValueError, match="timezone required"):
            Evidence(**values)


def test_quota_requires_dimension_unit_and_valid_timestamps():
    observed = "2026-09-25T06:00:00Z"
    quota = Quota(
        "requests", "calls", remaining=4, total=10, source="official",
        observed_at=observed, reset_at="2026-09-26T06:00:00Z",
    )
    assert quota.display == "4 calls restantes"
    assert quota.observed_at == observed
    with pytest.raises(ValueError, match="dimension and unit"):
        Quota("", "calls")
    with pytest.raises(ValueError, match="invalid quota observed_at"):
        Quota("requests", "calls", observed_at="not-a-time")
    with pytest.raises(ValueError, match="timezone required"):
        Quota("requests", "calls", observed_at="2026-09-25T06:00:00")
    with pytest.raises(ValueError, match="invalid quota reset_at"):
        Quota("requests", "calls", reset_at="tomorrow")
    for value in (True, "4", float("nan"), float("inf")):
        with pytest.raises(ValueError, match="invalid quota remaining"):
            Quota("requests", "calls", remaining=value, source="official")


def test_private_identity_stays_out_of_redacted_export():
    account = Account("opaque-1", "example", "Trabalho", display_name="Nome Privado",
                      avatar_ref="cache:avatar", secret_ref="keyring:opaque-1")
    assert public_account(account)["displayName"] == "Nome Privado"
    summary = redacted_summary((Connection("c1", account.account_id, "adapter", "local"),))
    assert "Nome Privado" not in str(summary)
    assert "opaque-1" not in str(summary)
    assert "keyring" not in str(summary)


def test_credential_reference_accepts_only_opaque_store_handles():
    assert Account("opaque-2", "example", "Work",
                   secret_ref="secret-service:phasezero/openai/workspace-1").secret_ref
    for value in ("Bearer live-secret", "sk-example", "keyring:", "secret:token=live"):
        with pytest.raises(ValueError, match="opaque secure-store reference"):
            Account("opaque-2", "example", "Work", secret_ref=value)


def test_global_deadline_keeps_partial_result_and_cancels_late_probe():
    cancelled = False

    async def fast():
        return Evidence("yes", "explicit-check", "2026-09-24T10:00:00Z",
                        "2026-09-24T10:00:00Z")

    async def slow():
        nonlocal cancelled
        try:
            await asyncio.sleep(1)
        except asyncio.CancelledError:
            cancelled = True
            raise
        return Evidence("yes")

    result = asyncio.run(collect_evidence({"fast": fast, "slow": slow}, deadline_s=0.01))
    assert result["fast"].state == "yes"
    assert result["slow"].state == "unknown"
    assert result["slow"].error == "timeout"
    assert cancelled


def test_global_deadline_does_not_wait_for_probe_that_delays_cancellation():
    async def scenario():
        release = asyncio.Event()
        cancellation_seen = asyncio.Event()

        async def slow_to_cancel():
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                cancellation_seen.set()
                await release.wait()
                raise

        task = asyncio.create_task(collect_evidence(
            {"slow": slow_to_cancel}, deadline_s=0.01,
        ))
        done, _pending = await asyncio.wait({task}, timeout=0.05)
        release.set()
        result = await task
        return task in done, cancellation_seen.is_set(), result

    returned_before_release, cancelled, result = asyncio.run(scenario())
    assert returned_before_release
    assert cancelled
    assert result["slow"].error == "timeout"


def test_claude_adapter_keeps_credential_unknown_and_session_explicit():
    found = claude_code_account({"auth": {"loggedIn": True, "apiProvider": "firstParty"}})
    assert found is not None
    account, connection = found
    assert connection.session.state == "yes"
    assert connection.credential.state == "unknown"
    assert connection.access.state == connection.service.state == "unknown"
    assert account.account_id.startswith("acct:claude:")

    expired = claude_code_account({"auth": {"loggedIn": False, "expired": True}})
    rejected = claude_code_account({"auth": {"loggedIn": False, "httpStatus": 401}})
    timeout = claude_code_account({"auth": {"loggedIn": False, "probeStatus": "timeout"}})
    unavailable = claude_code_account({"auth": {"loggedIn": False, "probeStatus": "backend-unavailable"}})
    assert expired is not None and expired[1].session.error == "expired"
    assert rejected is not None and rejected[1].session.error == "unauthorized"
    assert timeout is not None and timeout[1].session.error == "timeout"
    assert timeout[1].session.state == "unknown"
    assert unavailable is not None and unavailable[1].session.error == "backend-unavailable"


def test_proxy_adapter_distinguishes_artifact_from_live_session():
    present = proxy_auth_account({
        "id": "qwenproxy", "label": "Private Browser Profile",
        "webValidation": {"status": "session-present"}, "service": "active",
    })
    expired = proxy_auth_account({
        "id": "kimiproxy", "credentialStatus": "present", "sessionStatus": "expired",
    })
    unauthorized = proxy_auth_account({
        "id": "deepsproxy", "credentialStatus": "present", "sessionStatus": "401",
    })
    unavailable = proxy_auth_account({
        "id": "mimo-ai-proxy", "credentialStatus": "backend-unavailable",
    })
    saved_artifact = proxy_auth_account({
        "id": "qwenproxy", "credentialStatus": "present", "sessionStatus": "present",
    })
    assert present is not None
    assert present[1].credential.state == "yes"
    assert present[1].session.state == "unknown"
    assert present[1].service.state == "yes"
    assert expired is not None and expired[1].session.error == "expired"
    assert unauthorized is not None and unauthorized[1].session.error == "unauthorized"
    assert unavailable is not None
    assert unavailable[1].credential.state == "unknown"
    assert unavailable[1].credential.error == "backend-unavailable"
    assert saved_artifact is not None
    assert saved_artifact[1].credential.state == "yes"
    assert saved_artifact[1].session.state == "unknown"


def test_router_provider_adapter_uses_opaque_ids_and_never_infers_credentials():
    rows = router_provider_accounts({"connections": [{
        "id": "db-opaque-73", "provider": "openai", "name": "Private Person",
        "active": True, "status": "success",
    }]})
    assert len(rows) == 1
    account, connection = rows[0]
    assert "db-opaque-73" not in account.account_id
    assert connection.enabled
    assert connection.access.state == "yes"
    assert connection.credential.state == connection.session.state == "unknown"
    summary = redacted_summary((connection,))
    assert "Private Person" not in str(summary)
    assert account.account_id not in str(summary)


def test_account_source_adapter_joins_supported_sources_without_faking_missing_ones():
    results = adapt_account_sources({
        "claude": {"claude": {"auth": {"loggedIn": True, "apiProvider": "firstParty"}}},
        "proxies": [{"id": "qwenproxy", "apiKeyConfigured": True}],
        "routerProviders": {"connections": [{
            "id": "router-id", "provider": "openai", "name": "Private Name",
            "active": True, "status": "success",
        }]},
    })
    assert len(results) == 3
    assert len({account.account_id for account, _ in results}) == 3
    exported = redacted_summary(tuple(connection for _, connection in results))
    assert exported["total"] == 3
    assert "Private Name" not in str(exported)
    assert all(account.account_id not in str(exported) for account, _ in results)
    assert adapt_account_sources({"claude": {"error": "backend-unavailable"}}) == ()


def test_account_source_adapter_preserves_each_probe_observation_time():
    observed_at = {
        "claude": "2026-09-25T11:00:00+00:00",
        "proxies": "2026-09-25T11:01:00+00:00",
        "routerProviders": "2026-09-25T11:02:00+00:00",
        "routerHealth": "2026-09-25T11:03:00+00:00",
    }
    results = adapt_account_sources(
        {
            "claude": {"auth": {"loggedIn": True, "apiProvider": "firstParty"}},
            "proxies": [{
                "id": "qwenproxy", "credentialStatus": "present",
                "sessionStatus": "authenticated", "service": "active",
            }],
            "routerProviders": {"connections": [{
                "id": "router-id", "provider": "openai", "active": True, "status": "success",
            }]},
        },
        observed_at_by_source=observed_at,
        router_health=Evidence("yes", "9router-health", observed_at["routerHealth"]),
    )
    by_adapter = {connection.adapter_id: connection for _account, connection in results}

    assert by_adapter["claude-code-auth-status"].session.observed_at == observed_at["claude"]
    proxy = by_adapter["proxy-auth-status"]
    assert {proxy.credential.observed_at, proxy.session.observed_at, proxy.service.observed_at} == {
        observed_at["proxies"]
    }
    router = by_adapter["9router-provider-status"]
    assert router.access.observed_at == observed_at["routerProviders"]
    assert router.service.observed_at == observed_at["routerHealth"]
