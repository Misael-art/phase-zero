"""PXA-006 account evidence contract. No credential material belongs here.

Adapters may populate this contract only from explicit evidence. A local file,
an HTTP timeout and a backend that could not start all mean different things.
The existing redacted auth registry remains a separate v1 summary.
"""

from __future__ import annotations

import asyncio
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Awaitable, Callable


STATES = frozenset({"yes", "no", "unknown"})
ERRORS = frozenset({"none", "expired", "unauthorized", "timeout", "backend-unavailable", "network", "unknown"})


@dataclass(frozen=True)
class Evidence:
    state: str = "unknown"
    source: str = "unknown"
    observed_at: str = ""
    verified_at: str = ""
    expires_at: str = ""
    error: str = "none"

    def __post_init__(self) -> None:
        if self.state not in STATES or self.error not in ERRORS:
            raise ValueError("invalid account evidence")
        if self.verified_at and not self.observed_at:
            raise ValueError("verified evidence needs observation time")
        for name, value in (
            ("observed_at", self.observed_at),
            ("verified_at", self.verified_at),
            ("expires_at", self.expires_at),
        ):
            if value:
                try:
                    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                except (AttributeError, TypeError, ValueError) as exc:
                    raise ValueError(f"invalid evidence {name}") from exc
                if parsed.tzinfo is None:
                    raise ValueError(f"invalid evidence {name}: timezone required")
        if self.error in {"timeout", "backend-unavailable", "network", "unknown"} and self.state != "unknown":
            raise ValueError("probe failure cannot prove a negative state")

    @property
    def is_expired(self) -> bool:
        if self.error == "expired":
            return True
        if not self.expires_at:
            return False
        expires = datetime.fromisoformat(self.expires_at.replace("Z", "+00:00"))
        return expires.astimezone(timezone.utc) <= datetime.now(timezone.utc)

    @property
    def effective_state(self) -> str:
        return "no" if self.is_expired else self.state


@dataclass(frozen=True)
class Quota:
    dimension: str
    unit: str
    remaining: float | None = None
    total: float | None = None
    reset_at: str = ""
    source: str = "unknown"  # official | local_estimate | unknown
    observed_at: str = ""

    def __post_init__(self) -> None:
        if (
            not isinstance(self.dimension, str) or not self.dimension.strip()
            or not isinstance(self.unit, str) or not self.unit.strip()
        ):
            raise ValueError("quota requires dimension and unit")
        if self.source not in {"official", "local_estimate", "unknown"}:
            raise ValueError("invalid quota source")
        for name, value in (("observed_at", self.observed_at), ("reset_at", self.reset_at)):
            if value:
                try:
                    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                except (AttributeError, TypeError, ValueError) as exc:
                    raise ValueError(f"invalid quota {name}") from exc
                if parsed.tzinfo is None:
                    raise ValueError(f"invalid quota {name}: timezone required")
        for name, value in (("remaining", self.remaining), ("total", self.total)):
            if value is None:
                continue
            try:
                finite = math.isfinite(value)
            except (TypeError, OverflowError):
                finite = False
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not finite:
                raise ValueError(f"invalid quota {name}")
            if value < 0:
                raise ValueError(f"negative quota {name}")
        if self.source == "unknown" and (self.remaining is not None or self.total is not None):
            raise ValueError("unknown quota cannot invent numbers")

    @property
    def display(self) -> str:
        return "não informada" if self.remaining is None else f"{self.remaining:g} {self.unit} restantes"


@dataclass(frozen=True)
class Account:
    account_id: str
    provider: str
    nickname: str
    workspace: str = ""
    display_name: str = ""
    avatar_ref: str = ""
    secret_ref: str = ""

    def __post_init__(self) -> None:
        if not self.account_id or not self.provider or not self.nickname:
            raise ValueError("account requires opaque ID, provider and nickname")
        if self.secret_ref:
            scheme, separator, reference = self.secret_ref.partition(":")
            if (
                not separator or scheme not in {"keyring", "secret-service", "wincred", "provider-store"}
                or not re.fullmatch(r"[A-Za-z0-9._/-]{1,160}", reference)
            ):
                raise ValueError("secret_ref must be an opaque secure-store reference")


@dataclass(frozen=True)
class Connection:
    connection_id: str
    account_id: str
    adapter_id: str
    instance_id: str
    enabled: bool = False
    credential: Evidence = field(default_factory=Evidence)
    session: Evidence = field(default_factory=Evidence)
    service: Evidence = field(default_factory=Evidence)
    access: Evidence = field(default_factory=Evidence)
    quota: Quota | None = None

    @property
    def usable(self) -> bool:
        evidence_ready = (
            self.enabled
            and self.credential.effective_state == "yes"
            and self.session.effective_state == "yes"
            and self.service.effective_state == "yes"
            and self.access.effective_state == "yes"
        )
        quota_exhausted = (
            self.quota is not None
            and self.quota.source == "official"
            and self.quota.remaining == 0
        )
        return evidence_ready and not quota_exhausted


@dataclass(frozen=True)
class Grant:
    grant_id: str
    connection_id: str
    consumer_id: str
    scopes: tuple[str, ...]
    enabled: bool = False
    consented_at: str = ""
    revoked_at: str = ""


def public_account(account: Account) -> dict[str, object]:
    """Private UI projection. Diagnostic exports must use redacted_summary."""
    return {"accountId": account.account_id, "provider": account.provider,
            "nickname": account.nickname, "workspace": account.workspace,
            "displayName": account.display_name, "avatarRef": account.avatar_ref}


def redacted_summary(connections: tuple[Connection, ...]) -> dict[str, object]:
    """No identity, avatar, secret reference or per-account ID in logs/exports."""
    return {"schemaVersion": 2, "total": len(connections),
            "enabled": sum(connection.enabled for connection in connections),
            "usable": sum(connection.usable for connection in connections),
            "secretsRedacted": True}


Probe = Callable[[], Awaitable[Evidence]]


def _consume_probe_completion(task: asyncio.Task[Evidence]) -> None:
    """Retrieve late task exceptions after the bounded collector has returned."""
    if not task.cancelled():
        try:
            task.exception()
        except Exception:
            pass


async def collect_evidence(probes: dict[str, Probe], *, deadline_s: float = 10.0) -> dict[str, Evidence]:
    """Bound aggregate latency; late probes never overwrite a newer selection.

    Callers keep their own selection generation and only apply the returned
    snapshot if it still matches. Probe implementations must cooperate with
    cancellation; subprocess adapters must terminate child processes.
    """
    if deadline_s <= 0:
        raise ValueError("deadline must be positive")
    async def run(probe: Probe) -> Evidence:
        try:
            value = await probe()
            return value if isinstance(value, Evidence) else Evidence(error="unknown")
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            return Evidence(error="timeout")
        except OSError:
            return Evidence(error="backend-unavailable")
        except Exception:
            return Evidence(error="unknown")

    tasks = {key: asyncio.create_task(run(probe)) for key, probe in probes.items()}
    try:
        done, pending = await asyncio.wait(tasks.values(), timeout=deadline_s)
        for task in pending:
            task.cancel()
        if pending:
            # Give cooperative probes one loop turn to stop. Never await them
            # without a bound: a probe may delay or suppress cancellation.
            await asyncio.sleep(0)
        return {key: (task.result() if task in done and not task.cancelled() else Evidence(error="timeout"))
                for key, task in tasks.items()}
    finally:
        for task in tasks.values():
            if not task.done():
                task.cancel()
                task.add_done_callback(_consume_probe_completion)
