"""Metadata-only projection of the canonical wallet and managed consumers.

Never looks up a secret, scans process arguments or infers provider validity
from local registration. No secondary inventory is persisted.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from hashlib import sha256

from .credential_vault import CredentialEntry, CredentialVault


@dataclass(frozen=True)
class CredentialUse:
    account_id: str
    consumer: str = "DeepSeek Harness"
    state: str = "unknown"
    project: str = ""
    process_id: int | None = None
    observed_at: str = ""

    @property
    def running(self) -> bool:
        return self.state in {"running", "starting-or-unhealthy"} and self.process_id is not None


def display_id(entry: CredentialEntry) -> str:
    # A UI identifier, never a key fragment or a native secure-store reference.
    return "KEY-" + sha256(entry.account_id.encode("ascii")).hexdigest()[:12].upper()


def stored_days(entry: CredentialEntry, now: datetime | None = None) -> int:
    stored = datetime.fromisoformat(entry.stored_at.replace("Z", "+00:00"))
    return max(0, ((now or datetime.now(timezone.utc)) - stored).days)


def needs_review(entry: CredentialEntry, now: datetime | None = None) -> bool:
    # Local reminder only; age does not mean compromised, invalid or expired.
    return entry.state == "pending" or stored_days(entry, now) >= 90


def observe_managed_uses() -> tuple[CredentialUse, ...]:
    from . import deepseek_harness_manager as harness

    if not harness.state_file().exists():
        return ()
    payload = harness.status_payload()
    identity = payload.get("apiCredentialId")
    if payload.get("authRoute") != "api" or not isinstance(identity, str) or not identity:
        return ()
    pid = payload.get("processId")
    return (CredentialUse(
        identity, state=str(payload.get("runtimeState", "unknown")),
        project=str(payload.get("requestedWorkspace", "")),
        process_id=pid if type(pid) is int and pid > 0 else None,
        observed_at=str(payload.get("observedAt", "")),
    ),)


def remove_local_credential(vault: CredentialVault, account_id: str) -> bool:
    entry = next((entry for entry in vault.entries if entry.account_id == account_id), None)
    if entry is None:
        return False
    if entry.provider.strip().casefold() == "deepseek":
        from .deepseek_harness_manager import revoke_wallet_use
        return revoke_wallet_use(account_id, lambda: vault.remove(account_id))
    return vault.remove(account_id)
