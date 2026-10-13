"""Read-only adapters from existing AI status responses to account contracts.

Adapters preserve unknowns. They never inspect or return credential contents;
identity stays on the private UI model, while ``redacted_summary`` owns exports.
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping

from .account_contract import Account, Connection, Evidence


def _opaque_id(provider: str, source_id: object) -> str:
    """Build stable non-identifying IDs from provider-owned record IDs only."""
    if not isinstance(source_id, (str, int)) or not str(source_id).strip():
        source_id = "default"
    digest = hashlib.sha256(f"{provider}:{source_id}".encode("utf-8")).hexdigest()[:24]
    return f"acct:{provider}:{digest}"


def router_provider_connection_id(provider: str, source_id: object) -> str:
    """Stable contract ID used to match a 9Router record to its grant."""
    return f"connection:{_opaque_id(provider, source_id)}"


def _evidence_from_status(
    value: object, *, source: str, observed_at: str = "", present_is_positive: bool = True,
) -> Evidence:
    """Map explicit auth result markers; do not turn transport failure into no."""
    if isinstance(value, bool):
        return Evidence("yes" if value else "no", source, observed_at)
    if not isinstance(value, str):
        return Evidence(source=source, observed_at=observed_at)
    status = value.strip().lower()
    if status == "present" and not present_is_positive:
        return Evidence(source=source, observed_at=observed_at)
    if status in {"yes", "present", "authenticated", "valid", "ok", "success", "200"}:
        return Evidence("yes", source, observed_at)
    if status in {"no", "missing", "absent", "logged-out", "unauthenticated"}:
        return Evidence("no", source, observed_at)
    if status in {"expired", "token-expired"}:
        return Evidence("no", source, observed_at, error="expired")
    if status in {"401", "unauthorized", "http-401"}:
        return Evidence("no", source, observed_at, error="unauthorized")
    if status in {"timeout", "timed-out"}:
        return Evidence(source=source, observed_at=observed_at, error="timeout")
    if status in {"backend-unavailable", "missing-backend"}:
        return Evidence(source=source, observed_at=observed_at, error="backend-unavailable")
    if status in {"network", "network-error"}:
        return Evidence(source=source, observed_at=observed_at, error="network")
    return Evidence(source=source, observed_at=observed_at)


def _service_evidence(value: object, *, observed_at: str = "") -> Evidence:
    if value is True or (isinstance(value, str) and value.strip().lower() in {"active", "online"}):
        return Evidence("yes", "proxy-service-status", observed_at)
    if value is False or (isinstance(value, str) and value.strip().lower() in {"inactive", "offline"}):
        return Evidence("no", "proxy-service-status", observed_at)
    return Evidence(source="proxy-service-status", observed_at=observed_at)


def claude_code_account(
    payload: object, *, host_id: str = "local", observed_at: str = "",
) -> tuple[Account, Connection] | None:
    """Adapt ``claude auth status --json`` projection without exposing tokens.

    The CLI reports session validity, but does not report credential bytes or a
    separate credential-presence fact. Credential evidence therefore stays
    unknown even when a session is logged in.
    """
    if not isinstance(payload, Mapping):
        return None
    auth = payload.get("auth")
    if not isinstance(auth, Mapping):
        claude = payload.get("claude")
        auth = claude.get("auth") if isinstance(claude, Mapping) else None
    if not isinstance(auth, Mapping):
        return None
    account_id = _opaque_id("claude", "first-party")
    logged_in = auth.get("loggedIn")
    auth_error = auth.get("error")
    probe_status = auth.get("probeStatus")
    if probe_status == "timeout":
        session = Evidence(source="claude-auth-status", observed_at=observed_at, error="timeout")
    elif probe_status == "backend-unavailable":
        session = Evidence(source="claude-auth-status", observed_at=observed_at,
                           error="backend-unavailable")
    elif probe_status is not None and probe_status != "ok":
        session = Evidence(source="claude-auth-status", observed_at=observed_at)
    elif auth.get("expired") is True:
        session = Evidence("no", "claude-auth-status", observed_at, error="expired")
    elif auth.get("httpStatus") == 401 or (
        isinstance(auth_error, str) and auth_error in {"401", "unauthorized"}
    ):
        session = Evidence("no", "claude-auth-status", observed_at, error="unauthorized")
    elif isinstance(auth_error, str) and auth_error in {"timeout", "backend-unavailable", "network"}:
        session = Evidence(source="claude-auth-status", observed_at=observed_at, error=auth_error)
    elif isinstance(logged_in, bool):
        session = Evidence("yes" if logged_in else "no", "claude-auth-status", observed_at)
    else:
        session = Evidence(source="claude-auth-status", observed_at=observed_at)
    account = Account(
        account_id=account_id,
        provider=str(auth.get("apiProvider") or "claude-first-party"),
        nickname="Claude account",
    )
    connection = Connection(
        connection_id=f"connection:{account_id}",
        account_id=account_id,
        adapter_id="claude-code-auth-status",
        instance_id=f"{host_id}:local:app.claude-code",
        credential=Evidence(source="claude-auth-status", observed_at=observed_at),
        session=session,
    )
    return account, connection


def proxy_auth_account(
    payload: object, *, host_id: str = "local", observed_at: str = "",
) -> tuple[Account, Connection] | None:
    """Adapt one proxy auth row without treating a saved login marker as live."""
    if not isinstance(payload, Mapping):
        return None
    proxy_id = payload.get("id")
    if not isinstance(proxy_id, str) or not proxy_id.strip():
        return None
    provider = f"proxy:{proxy_id}"
    account_id = _opaque_id(provider, payload.get("accountId", "default"))
    web = payload.get("webValidation")
    web = web if isinstance(web, Mapping) else {}
    web_status = web.get("status")
    credential_status = payload.get("credentialStatus")
    if credential_status is None:
        api_key_configured = payload.get("apiKeyConfigured")
        if isinstance(api_key_configured, bool):
            credential_status = api_key_configured
        elif isinstance(web_status, str) and web_status in {"authenticated", "session-present"}:
            credential_status = "present"
        elif web_status == "missing-credentials":
            credential_status = "missing"
    credential = _evidence_from_status(
        credential_status, source="proxy-session-artifact", observed_at=observed_at,
    )
    session_status = payload.get("sessionStatus")
    session = _evidence_from_status(
        session_status, source="proxy-session-check", observed_at=observed_at,
        present_is_positive=False,
    )
    service = _service_evidence(payload.get("service"), observed_at=observed_at)
    account = Account(
        account_id=account_id,
        provider=provider,
        nickname=(payload["label"].strip()
                  if isinstance(payload.get("label"), str) and payload["label"].strip()
                  else proxy_id),
    )
    connection = Connection(
        connection_id=f"connection:{account_id}",
        account_id=account_id,
        adapter_id="proxy-auth-status",
        instance_id=f"{host_id}:local:app.{proxy_id}",
        credential=credential,
        session=session,
        service=service,
    )
    return account, connection


def router_provider_accounts(
    payload: object,
    *,
    host_id: str = "local",
    router_health: Evidence | None = None,
    observed_at: str = "",
) -> tuple[tuple[Account, Connection], ...]:
    """Adapt redacted 9Router provider records; never infer session or grants.

    The manager exposes opaque provider record IDs, labels, an enabled flag and
    a test status. Provider credentials are never present in this response.
    """
    if not isinstance(payload, Mapping):
        return ()
    rows = payload.get("connections", payload.get("providers"))
    if not isinstance(rows, list):
        return ()
    results: list[tuple[Account, Connection]] = []
    for row in rows:
        if not isinstance(row, Mapping):
            continue
        provider = row.get("provider", row.get("providerId"))
        if not isinstance(provider, str) or not provider.strip():
            continue
        account_id = _opaque_id(provider, row.get("id"))
        label = row.get("name", row.get("displayName"))
        account = Account(
            account_id=account_id,
            provider=provider,
            nickname=label.strip() if isinstance(label, str) and label.strip() else provider,
        )
        result = row.get("status", row.get("testStatus"))
        access = _evidence_from_status(result, source="9router-provider-test", observed_at=observed_at)
        if access.state == "no" and access.error == "none":
            # An inactive/failed provider test is not enough to diagnose bad auth.
            access = Evidence(source="9router-provider-test", observed_at=observed_at)
        connection = Connection(
            connection_id=router_provider_connection_id(provider, row.get("id")),
            account_id=account_id,
            adapter_id="9router-provider-status",
            instance_id=f"{host_id}:host:app.9router",
            enabled=row.get("active") is True,
            credential=Evidence(source="9router-provider-status", observed_at=observed_at),
            session=Evidence(source="9router-provider-status", observed_at=observed_at),
            service=router_health or Evidence(source="9router-health", observed_at=observed_at),
            access=access,
        )
        results.append((account, connection))
    return tuple(results)


def adapt_account_sources(
    sources: Mapping[str, object],
    *,
    host_id: str = "local",
    router_health: Evidence | None = None,
    observed_at: str = "",
    observed_at_by_source: Mapping[str, str] | None = None,
) -> tuple[tuple[Account, Connection], ...]:
    """Join independently probed status payloads without inventing missing rows.

    Expected keys are ``claude``, ``proxies`` and ``routerProviders``. Absent
    or malformed sources contribute no accounts; callers retain probe outcomes
    separately so unavailable never looks like an empty account list.
    ``observed_at_by_source`` records each probe's local response time;
    ``observed_at`` remains a compatibility fallback for existing callers.
    """
    results: list[tuple[Account, Connection]] = []
    source_times = observed_at_by_source or {}
    claude = claude_code_account(
        sources.get("claude"), host_id=host_id,
        observed_at=source_times.get("claude", observed_at),
    )
    if claude is not None:
        results.append(claude)
    proxies = sources.get("proxies")
    if isinstance(proxies, list):
        for proxy in proxies:
            adapted = proxy_auth_account(
                proxy, host_id=host_id,
                observed_at=source_times.get("proxies", observed_at),
            )
            if adapted is not None:
                results.append(adapted)
    results.extend(router_provider_accounts(
        sources.get("routerProviders"), host_id=host_id,
        router_health=router_health,
        observed_at=source_times.get("routerProviders", observed_at),
    ))
    account_ids = [account.account_id for account, _ in results]
    if len(set(account_ids)) != len(account_ids):
        raise ValueError("account adapters produced duplicate opaque IDs")
    return tuple(results)
