#!/usr/bin/env python3
"""Quota-aware per-task routing configurator for PhaseZero/9Router.

Read-only by default. Builds a redacted inventory from the real 9Router API,
applies hard health/capability/quota filters, scores models per task and
policy, and materializes ONLY the PhaseZero-managed combos:

  phasezero-code
  phasezero-analysis
  phasezero-plan

Never touches `Default`, `claude-Combo_Cleude` or user combos. Bonsai stays
a separate explicit experimental route and is never added to 9Router.

State lives under XDG user-local paths with 0700/0600 permissions:

  config : $XDG_CONFIG_HOME/phasezero/ai-routing/config.json
  state  : $XDG_DATA_HOME/phasezero/ai-routing/state.json
  ops    : $XDG_DATA_HOME/phasezero/ai-routing/operations/<id>/manifest.json

No token, API key, header, prompt, response or raw upstream error is ever
persisted or printed. All output is redacted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1
DEFAULT_PORT = 20128
DEFAULT_BASE = f"http://127.0.0.1:{DEFAULT_PORT}"
DEFAULT_RESERVE = 0.10
DEFAULT_WEIGHTS = {
    "fit": 35,
    "quality": 25,
    "quota": 20,
    "reliability": 10,
    "cost": 5,
    "latency": 5,
}
MAX_CHAIN = 5


def _contract_connection_id(provider: str, source_id: object) -> str:
    """Match opaque IDs emitted by account_adapters.router_provider_accounts."""
    if not isinstance(source_id, (str, int)) or not str(source_id).strip():
        source_id = "default"
    digest = hashlib.sha256(f"{provider}:{source_id}".encode("utf-8")).hexdigest()[:24]
    return f"connection:acct:{provider}:{digest}"


def _grant_value(grant: object, attribute: str, key: str, default: object = None) -> object:
    if isinstance(grant, dict):
        return grant.get(key, default)
    return getattr(grant, attribute, default)


def _granted_connection_for_scope(
    grant: object, consumer_id: str, required_scope: str,
) -> str:
    """Return only a structurally valid, explicitly consented active grant."""
    connection_id = _grant_value(grant, "connection_id", "connectionId", "")
    enabled = _grant_value(grant, "enabled", "enabled", False)
    scopes = _grant_value(grant, "scopes", "scopes", ())
    consented_at = _grant_value(grant, "consented_at", "consentedAt", "")
    revoked_at = _grant_value(grant, "revoked_at", "revokedAt", "")
    if (
        _grant_value(grant, "consumer_id", "consumerId", "") != consumer_id
        or type(enabled) is not bool or not enabled
        or not isinstance(connection_id, str) or not connection_id.strip()
        or not isinstance(scopes, (list, tuple))
        or any(not isinstance(scope, str) or not scope.strip() for scope in scopes)
        or required_scope not in scopes
        or not isinstance(consented_at, str) or not consented_at
        or not isinstance(revoked_at, str) or revoked_at
    ):
        return ""
    try:
        consent_timestamp = datetime.fromisoformat(consented_at.replace("Z", "+00:00"))
    except ValueError:
        return ""
    if consent_timestamp.tzinfo is None:
        return ""
    return connection_id

# Curated per-task priorities. Real inventory, health, quota, cooldown and
# capabilities always win over these lists.
CURATED_PRIORITIES: dict[str, list[str]] = {
    "code": [
        "cx/gpt-5.6-sol",
        "cc/claude-opus-5",
        "cc/claude-sonnet-5",
        "cx/gpt-5.6-terra",
        "kimi/kimi-for-coding",
        "glm/glm-5.2",
        "xai/grok-code-fast-1",
    ],
    "analysis": [
        "cc/claude-fable-5",
        "cc/claude-opus-5",
        "cx/gpt-5.6-sol-review",
        "cx/gpt-5.6-terra-review",
        "kimi/kimi-k3",
        "glm/glm-5.2",
    ],
    "plan": [
        "cc/claude-opus-5",
        "cc/claude-fable-5",
        "cx/gpt-5.6-sol",
        "cc/claude-sonnet-5",
        "cx/gpt-5.6-terra",
        "kimi/kimi-k3",
        "glm/glm-5.2",
    ],
}

# Task -> required capabilities (from /v1/models capabilities).
TASK_CAPABILITIES: dict[str, list[str]] = {
    "code": ["tools", "reasoning"],
    "analysis": ["tools", "reasoning"],
    "plan": ["tools", "reasoning"],
}

POLICIES: dict[str, dict] = {
    "quality": {
        "weights": {"fit": 35, "quality": 40, "quota": 10, "reliability": 10, "cost": 0, "latency": 5},
        "reserve": 0.05,
        "requireKnownQuota": False,
    },
    "balanced": {
        "weights": dict(DEFAULT_WEIGHTS),
        "reserve": DEFAULT_RESERVE,
        "requireKnownQuota": False,
    },
    "save-quota": {
        "weights": {"fit": 25, "quality": 10, "quota": 45, "reliability": 10, "cost": 5, "latency": 5},
        "reserve": 0.25,
        "requireKnownQuota": True,
    },
    "privacy": {
        "weights": {"fit": 35, "quality": 25, "quota": 15, "reliability": 10, "cost": 5, "latency": 10},
        "reserve": DEFAULT_RESERVE,
        "requireKnownQuota": False,
        "localBoost": 1.15,
        "oauthPenalty": 0.85,
    },
}

QUOTA_CONFIDENCE = {"known": 1.0, "unknown": 0.4, "unavailable": 0.15}
ERROR_WEIGHT = {401: 0.15, 403: 0.15, 429: 0.4, 400: 0.6}
ERROR_ACTIVE_WINDOW = 6 * 3600  # seconds
COOLDOWN_FIELDS = {"backoffLevel", "cooldownUntil", "cooldownEndsAt"}

# Compared against key.lower(): keep every entry lowercase (camelCase entries
# here never matched, so lastError/errorMessage leaked raw upstream bodies).
REDACT_KEYS = {
    "apikey", "key", "secret", "token", "email", "password", "passwd",
    "authorization", "headers", "lasterror", "lasterrorat", "errormessage",
    "accesskey", "refreshtoken",
}
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

TASKS = ("code", "analysis", "plan")
CLIENTS = ("claude", "opencode")
POLICY_NAMES = tuple(POLICIES)

PROVIDER_BY_PREFIX = {
    "cc": "claude", "cx": "codex", "glm": "glm", "kimi": "kimi",
    "openai": "openai", "xai": "xai", "mmf": "mmf", "opencode": "opencode",
}


def model_provider(model_id: str) -> str:
    prefix = model_id.split("/", 1)[0] if "/" in model_id else model_id
    return PROVIDER_BY_PREFIX.get(prefix, prefix)


class RedactionError(Exception):
    pass


def _redact(value, depth: int = 0):
    if depth > 12:
        return "<redacted>"
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            key = str(k)
            if not isinstance(v, bool) and (
                    key.lower() in REDACT_KEYS or "token" in key.lower() or "secret" in key.lower()):
                out[key] = "<redacted>"
            else:
                out[key] = _redact(v, depth + 1)
        return out
    if isinstance(value, list):
        return [_redact(v, depth + 1) for v in value]
    if isinstance(value, str) and EMAIL_RE.search(value):
        # Connection names are often the account e-mail.
        value = EMAIL_RE.sub("<email>", value)
    if isinstance(value, str) and len(value) > 256:
        return value[:128] + "...<truncated>"
    return value


def redact(obj):
    return _redact(obj)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def is_loopback_address(addr: str) -> bool:
    host = (addr or "").rsplit(":", 1)[0].strip("[]")
    return host in ("127.0.0.1", "::1", "localhost")


def utc_from_iso(value) -> float:
    if not value:
        return 0.0
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return dt.timestamp()
    except (ValueError, TypeError):
        return 0.0


def normalize_id(model_id: str) -> str:
    """Map curated names (display or short) to catalog ids."""
    return (model_id or "").strip().strip('"')


def model_short(model_id: str) -> str:
    return normalize_id(model_id).split("/", 1)[-1]


# ---------------------------------------------------------------------------
# Paths and configuration
# ---------------------------------------------------------------------------

def xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))


def xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))


def config_dir() -> Path:
    return xdg_config_home() / "phasezero" / "ai-routing"


def state_dir() -> Path:
    return xdg_data_home() / "phasezero" / "ai-routing"


def config_path() -> Path:
    return config_dir() / "config.json"


def state_path() -> Path:
    return state_dir() / "state.json"


def ops_root() -> Path:
    return state_dir() / "operations"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private(path: Path, payload: str) -> None:
    ensure_private_dir(path.parent)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(payload, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def opencode_config_path() -> Path:
    return xdg_config_home() / "opencode" / "opencode.json"


def _load_opencode_manager():
    """Import opencode_9router_manager lazily (best-effort, sibling module).

    The sibling module does ``import claude_code_manager`` (also a sibling), so
    the ai/ dir must be importable; insert it on sys.path for this load only.
    """
    try:
        import importlib.util
        ai_dir = str(Path(__file__).resolve().parent)
        if ai_dir not in sys.path:
            sys.path.insert(0, ai_dir)
        path = Path(ai_dir) / "opencode_9router_manager.py"
        spec = importlib.util.spec_from_file_location("pz_opencode_9router_manager", path)
        if spec and spec.loader:
            module = importlib.util.module_from_spec(spec)
            sys.modules["pz_opencode_9router_manager"] = module
            spec.loader.exec_module(module)
            return module
    except Exception:
        pass
    return None


def refresh_opencode_catalog(client: R9Client, backup_dir: Path | None = None) -> dict:
    """Ask the OpenCode manager to sync; preserve config if grant binding blocks it.

    When the manager updates a catalog, ``backup_dir`` stores prior bytes for
    rollback. Grant enforcement failures remain explicit and non-fatal to the
    independent 9Router combo operation.
    """
    path = opencode_config_path()
    result: dict = {
        "present": path.is_file(),
        "path": str(path),
        "updated": False,
        "beforeBackup": None,
        "models": [],
        "skipped": False,
        "reason": None,
        "secretsRedacted": True,
    }
    if not path.is_file():
        result["skipped"] = True
        result["reason"] = "opencode.json absent"
        return result
    module = _load_opencode_manager()
    if module is None:
        result["skipped"] = True
        result["reason"] = "opencode_9router_manager unavailable"
        return result
    try:
        manager = module.OpenCodeManager()
        before_bytes = path.read_bytes()
        sync = manager.sync_catalog(dry_run=False)
        result["updated"] = bool(sync.get("updated"))
        result["models"] = sync.get("models", [])
        if result["updated"] and backup_dir is not None and before_bytes != path.read_bytes():
            ensure_private_dir(backup_dir)
            backup = backup_dir / "opencode.json.before"
            backup.write_bytes(before_bytes)
            os.chmod(backup, 0o600)
            result["beforeBackup"] = str(backup)
    except Exception as exc:  # catalog sync must never abort an apply
        result["skipped"] = True
        if "connection-grant-not-enforceable" in str(exc):
            result["reason"] = "OpenCode sync blocked until account-bound grants are enforceable"
            result["blockedReason"] = "connection-grant-not-enforceable"
        else:
            result["reason"] = "sync failed"
        result["error"] = str(exc) if not str(exc) else "sync error"
    return result


class Config:
    """Validated, versioned routing configuration."""

    def __init__(self, data: dict, path: Path):
        self.path = path
        self.data = data

    @classmethod
    def load(cls, path: Path | None = None, create: bool = True) -> "Config":
        path = path or config_path()
        if not path.exists():
            if not create:
                return cls(cls._defaults(), path)
            data = cls._defaults()
            cfg = cls(data, path)
            cfg.save()
            return cfg
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raise RedactionError(f"invalid routing config at {path}")
        data.setdefault("schemaVersion", SCHEMA_VERSION)
        merged = cls._defaults()
        merged.update(data)
        if merged["schemaVersion"] != SCHEMA_VERSION:
            raise RedactionError(f"unsupported routing config schemaVersion {merged['schemaVersion']}")
        return cls(merged, path)

    @staticmethod
    def _defaults() -> dict:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "weights": dict(DEFAULT_WEIGHTS),
            "quotaReserve": DEFAULT_RESERVE,
            "policies": POLICIES,
            "tasks": {t: {"capabilities": TASK_CAPABILITIES[t], "priorities": CURATED_PRIORITIES[t]} for t in TASKS},
            "bonsai": {"experimental": True, "autoFallback": False},
        }

    def save(self) -> None:
        write_private(self.path, json.dumps(self.data, indent=2) + "\n")

    def weights(self, policy: str) -> dict:
        if policy in self.data.get("policies", {}):
            return dict(self.data["policies"][policy].get("weights", self.data.get("weights", DEFAULT_WEIGHTS)))
        return dict(self.data.get("weights", DEFAULT_WEIGHTS))

    def reserve(self, policy: str) -> float:
        if policy in self.data.get("policies", {}):
            return float(self.data["policies"][policy].get("reserve", self.data.get("quotaReserve", DEFAULT_RESERVE)))
        return float(self.data.get("quotaReserve", DEFAULT_RESERVE))

    def require_known_quota(self, policy: str) -> bool:
        return bool(self.data.get("policies", {}).get(policy, {}).get("requireKnownQuota", False))

    def priorities(self, task: str) -> list[str]:
        return [normalize_id(x) for x in self.data.get("tasks", {}).get(task, {}).get("priorities", [])]

    def capabilities(self, task: str) -> list[str]:
        return list(self.data.get("tasks", {}).get(task, {}).get("capabilities", TASK_CAPABILITIES.get(task, [])))

    def policy_extra(self, policy: str, key: str, default=None):
        return self.data.get("policies", {}).get(policy, {}).get(key, default)

    def validate_weights(self) -> None:
        for policy in POLICY_NAMES:
            weights = self.weights(policy)
            total = sum(float(v) for v in weights.values())
            if abs(total - 100.0) > 0.01:
                raise RedactionError(f"policy '{policy}' weights must sum to 100 (got {total})")
            for name in DEFAULT_WEIGHTS:
                if name not in weights:
                    raise RedactionError(f"policy '{policy}' missing weight '{name}'")


# ---------------------------------------------------------------------------
# 9Router client (real local API, never invented formats)
# ---------------------------------------------------------------------------

class R9Client:
    def __init__(self, base_url: str | None = None, data_dir: Path | None = None,
                 api_key: str | None = None):
        self.base = (base_url or os.environ.get("PZ_9ROUTER_BASE_URL") or DEFAULT_BASE).rstrip("/")
        self.data_dir = data_dir or Path(os.environ.get("PZ_9ROUTER_DATA_DIR", str(Path.home() / ".9router")))
        self._token: str | None = None
        self._api_key = api_key

    # -- auth ---------------------------------------------------------------
    def cli_token(self) -> str:
        if self._token:
            return self._token
        machine = self.data_dir / "machine-id"
        secret = self.data_dir / "auth" / "cli-secret"
        if not machine.exists() or not secret.exists():
            raise RedactionError("9Router CLI authentication unavailable")
        m = machine.read_text(encoding="utf-8").strip()
        s = secret.read_text(encoding="utf-8").strip()
        self._token = hashlib.sha256((m + "9r-cli-auth" + s).encode()).hexdigest()[:16]
        return self._token

    def api_key(self) -> str:
        if self._api_key:
            return self._api_key
        env_var = os.environ.get("PHASEZERO_9ROUTER_ENV", "")
        env_file = Path(env_var) if env_var else xdg_config_home() / "phasezero" / "ai-proxies" / "9router.env"
        if env_file.exists():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                if line.startswith("PHASEZERO_9ROUTER_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
        raise RedactionError("9Router API key unavailable")

    def request(self, method: str, path: str, payload: dict | None = None, timeout: int = 8):
        url = self.base + path
        headers = {"x-9r-cli-token": self.cli_token(), "Content-Type": "application/json"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                if not body:
                    return {}
                return json.loads(body.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            raise RedactionError(f"9Router {method} {path} -> HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RedactionError(f"9Router {method} {path} unreachable") from exc

    def get(self, path: str, timeout: int = 8):
        return self.request("GET", path, timeout=timeout)

    # -- inventory ----------------------------------------------------------
    def providers(self) -> list[dict]:
        data = self.get("/api/providers")
        return list(data.get("connections", []))

    def combos(self) -> list[dict]:
        data = self.get("/api/combos")
        return list(data.get("combos", []))

    def availability(self) -> list[dict]:
        data = self.get("/api/models/availability")
        return list(data.get("models", []))

    def usage_stats(self) -> dict:
        try:
            return self.get("/api/usage/stats")
        except RedactionError:
            return {}

    def usage_connection(self, connection_id: str) -> dict:
        try:
            return self.get(f"/api/usage/{connection_id}")
        except RedactionError:
            return {"_unavailable": True}

    def models(self) -> list[dict]:
        """Authenticated read of /v1/models (server-side catalog)."""
        url = self.base + "/v1/models"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.api_key()}"})
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise RedactionError(f"/v1/models -> HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RedactionError("/v1/models unreachable") from exc
        return list(data.get("data", []))

    def health(self) -> bool:
        try:
            with urllib.request.urlopen(self.base + "/api/health", timeout=3) as resp:
                return resp.status == 200
        except (urllib.error.URLError, TimeoutError, OSError):
            return False


# ---------------------------------------------------------------------------
# Inventory assembly (redacted)
# ---------------------------------------------------------------------------

@dataclass
class Connection:
    id: str
    provider: str
    name: str
    auth_type: str
    is_active: bool
    test_status: str
    error_code: int | None
    last_error_at: float
    backoff_level: int
    model_locks: dict
    quota: dict = field(default_factory=dict)
    quota_state: str = "unavailable"
    quota_confidence: float = 0.0


@dataclass
class ModelInfo:
    id: str
    provider: str
    owned_by: str
    capabilities: dict
    connections: list[str] = field(default_factory=list)


def classify_connection(conn: dict) -> Connection:
    code = conn.get("errorCode")
    try:
        code = int(code) if code not in (None, "", "null") else None
    except (TypeError, ValueError):
        code = None
    status = str(conn.get("testStatus") or "unknown").lower()
    return Connection(
        id=str(conn.get("id", "")),
        provider=str(conn.get("provider", "")),
        name=str(conn.get("name") or conn.get("displayName") or conn.get("email") or ""),
        auth_type=str(conn.get("authType") or "unknown"),
        is_active=bool(conn.get("isActive", True)),
        test_status=status,
        error_code=code,
        last_error_at=utc_from_iso(conn.get("lastErrorAt")),
        backoff_level=int(conn.get("backoffLevel") or 0),
        model_locks={k: utc_from_iso(v) for k, v in conn.items() if str(k).startswith("modelLock_")},
    )


def ready_statuses() -> set:
    return {"active", "ok", "ready", "healthy", "9router"}


def parse_quota(payload: dict, *, observed_at: str | None = None) -> tuple[str, dict, float]:
    """Return redacted quota plus explicit provenance and local observation time.

    Values inferred from used/total stay in separate estimate fields and never
    become observed quota or routing-filter input.
    """
    observed_at = _quota_timestamp(observed_at) or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    provenance = {"source": "9router_usage_api", "observedAt": observed_at}
    if payload.get("_unavailable"):
        return "unavailable", {**provenance, "error": "unavailable"}, QUOTA_CONFIDENCE["unavailable"]
    if isinstance(payload.get("quotas"), dict) and payload["quotas"]:
        buckets = []
        observed_values = False
        for name, bucket in payload["quotas"].items():
            if not isinstance(bucket, dict):
                continue
            used = _quota_number(bucket.get("used"))
            total = _quota_number(bucket.get("total"))
            remaining = _quota_number(bucket.get("remaining"))
            pct = _quota_number(bucket.get("remainingPercentage"), percentage=True)
            observed_values = observed_values or remaining is not None or pct is not None
            estimate_pct = None
            if pct is None and total is not None and total > 0 and used is not None and used <= total:
                estimate_pct = round((1 - used / total) * 100, 1)
            dimension = bucket.get("dimension")
            if not isinstance(dimension, str) or not dimension.strip():
                dimension = name if isinstance(name, str) and name.strip() else "unknown"
            unit = bucket.get("unit")
            if not isinstance(unit, str) or not unit.strip():
                unit = "unknown"
            reset_at = _quota_timestamp(bucket.get("resetAt"))
            buckets.append({
                "name": str(name),
                "dimension": dimension,
                "unit": unit,
                "used": used,
                "total": total,
                "remaining": remaining,
                "remainingPercentage": pct,
                "estimatedRemainingPercentage": estimate_pct,
                "resetAt": reset_at,
                "unlimited": bucket.get("unlimited") is True,
            })
        if buckets:
            state = "known" if observed_values else "unknown"
            return state, {**provenance, "plan": payload.get("plan"), "buckets": buckets}, QUOTA_CONFIDENCE[state]
    message = str(payload.get("message") or "")
    if "not implemented" in message.lower() or "not available" in message.lower():
        return "unknown", {**provenance, "error": "not_implemented"}, QUOTA_CONFIDENCE["unknown"]
    return "unavailable", {**provenance, "error": "unavailable"}, QUOTA_CONFIDENCE["unavailable"]


def _quota_number(value: object, *, percentage: bool = False) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        if not math.isfinite(value):
            return None
    except (OverflowError, TypeError):
        return None
    if value < 0 or (percentage and value > 100):
        return None
    return value


def _quota_timestamp(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return value if parsed.tzinfo is not None else None


def quota_remaining_pct(quota: dict) -> float | None:
    buckets = quota.get("buckets") if isinstance(quota, dict) else None
    if not isinstance(buckets, list):
        return None
    values = [
        float(value)
        for bucket in buckets if isinstance(bucket, dict)
        if (value := _quota_number(bucket.get("remainingPercentage"), percentage=True)) is not None
    ]
    return min(values) if values else None


def quota_reset_at(quota: dict) -> str | None:
    buckets = quota.get("buckets") if isinstance(quota, dict) else None
    if not isinstance(buckets, list):
        return None
    resets = [
        reset
        for bucket in buckets if isinstance(bucket, dict)
        if (reset := _quota_timestamp(bucket.get("resetAt"))) is not None
    ]
    return min(resets) if resets else None


def build_inventory(client: R9Client, refresh_quota: bool = False) -> dict:
    """Assemble redacted inventory from the real local API."""
    providers = client.providers()
    availability = client.availability()
    models = client.models()
    usage = client.usage_stats()

    conns: list[Connection] = []
    for conn in providers:
        c = classify_connection(conn)
        if refresh_quota:
            try:
                payload = client.usage_connection(c.id)
            except Exception:
                # Quota is optional evidence. A partial probe failure must not
                # remove the provider/account row from the inventory.
                payload = {"_unavailable": True}
            c.quota_state, c.quota, c.quota_confidence = parse_quota(payload)
        conns.append(c)

    model_map: dict[str, ModelInfo] = {}
    for m in models:
        mid = str(m.get("id", ""))
        if not mid:
            continue
        caps = m.get("capabilities") if isinstance(m.get("capabilities"), dict) else {}
        model_map[mid] = ModelInfo(
            id=mid,
            provider=str(m.get("owned_by") or ""),
            owned_by=str(m.get("owned_by") or ""),
            capabilities=caps,
        )
    # provider attribution by prefix (cc/ -> claude, cx/ -> codex, ...)
    for mid, info in model_map.items():
        wanted = model_provider(mid)
        for c in conns:
            if c.provider == wanted:
                info.connections.append(c.id)

    # availability status per (connection, model)
    avail_by_conn: dict[str, dict[str, dict]] = {}
    for a in availability:
        cid = str(a.get("connectionId") or "")
        model = str(a.get("model") or "")
        if cid:
            avail_by_conn.setdefault(cid, {})[model] = a

    now = time.time()
    statuses: dict[str, dict] = {}
    for c in conns:
        state, reason = "unknown", []
        if not c.is_active:
            state, reason = "disabled", ["connection disabled"]
        elif c.test_status in {"unavailable", "error", "failed", "invalid"}:
            state, reason = "unavailable", [f"testStatus={c.test_status}"]
        elif c.test_status not in ready_statuses():
            state, reason = "unknown", [f"testStatus={c.test_status}"]
        else:
            state, reason = "ready", []
        if c.error_code in (401, 403, 429):
            error_age = now - c.last_error_at
            if 0 <= error_age < ERROR_ACTIVE_WINDOW:
                state = "unavailable"
                reason.append(f"active HTTP {c.error_code}")
            else:
                # Preserve a safe classification after the active window
                # expires. Raw provider errors/accounts stay redacted, while
                # operators can still understand why testStatus is degraded.
                reason.append(f"last HTTP {c.error_code}")
        if c.backoff_level > 0:
            reason.append(f"backoff={c.backoff_level}")
        if state == "ready" and c.backoff_level > 0:
            state = "cooldown"
            reason[-1] = f"cooldown backoff={c.backoff_level}"
        statuses[c.id] = {"state": state, "reason": reason}

    return {
        "schemaVersion": SCHEMA_VERSION,
        "collectedAt": now_iso(),
        "health": client.health(),
        "models": [
            {
                "id": m.id,
                "capabilities": redact(m.capabilities),
                "connections": m.connections,
            }
            for m in model_map.values()
        ],
        "connections": [
            {
                "id": c.id,
                "provider": c.provider,
                "name": "<redacted>" if c.name else "",
                "authType": c.auth_type,
                "isActive": c.is_active,
                "testStatus": c.test_status,
                "errorCode": c.error_code,
                "backoffLevel": c.backoff_level,
                "modelLocks": {k: v for k, v in c.model_locks.items() if v > now} if c.model_locks else {},
                "status": statuses.get(c.id, {}),
                "quota": c.quota,
                "quotaState": c.quota_state,
                "quotaConfidence": c.quota_confidence,
            }
            for c in conns
        ],
        "availability": redact(availability),
        "providerAvailability": provider_availability(statuses),
        "usage": {"totalRequests": usage.get("totalRequests"), "totalCost": usage.get("totalCost")},
        "secretsRedacted": True,
    }


def provider_availability(statuses: dict) -> dict:
    """`health` only says the gateway answers; this says whether anything
    behind it can serve (it stayed true with 12 of 15 connections down)."""
    states = [entry.get("state") for entry in statuses.values()]
    total = len(states)
    ready = sum(1 for state in states if state in ("ready", "cooldown"))
    unavailable = sum(1 for state in states if state == "unavailable")
    if total == 0 or ready == 0:
        state = "down"
    elif unavailable:
        state = "degraded"
    else:
        state = "ok"
    return {"state": state, "ready": ready, "unavailable": unavailable, "total": total}


# ---------------------------------------------------------------------------
# Filtering and scoring
# ---------------------------------------------------------------------------

@dataclass
class Candidate:
    model_id: str
    provider: str
    fit: float
    quality: float
    quota: float
    quota_state: str
    quota_confidence: float
    reliability: float
    cost: float
    latency: float
    score: float
    justifications: list[str] = field(default_factory=list)
    chain_position: int = 0


def _rank_score(priorities: list[str], model_id: str, base: float = 0.3) -> float:
    for i, pid in enumerate(priorities):
        if pid == model_id or model_short(pid) == model_short(model_id):
            return max(0.0, 1.0 - i * 0.15)
    return base


def _cost_score(stats: dict, provider: str) -> float:
    by_provider = stats.get("byProvider") if isinstance(stats, dict) else {}
    entry = by_provider.get(provider) if isinstance(by_provider, dict) else None
    if not isinstance(entry, dict):
        return 0.5
    cost = entry.get("cost")
    requests = entry.get("requests") or 0
    if not isinstance(cost, (int, float)) or requests <= 0:
        return 0.5
    per_req = cost / requests
    # cheap <= $0.005/req -> 1.0 ; expensive >= $0.05/req -> 0.0
    return max(0.0, min(1.0, 1.0 - (per_req - 0.005) / 0.045))


def recommend(client: R9Client, config: Config, inventory: dict, task: str, policy: str,
              *, consumer_id: str | None = None, grants: list | tuple = (),
              required_scope: str = "inference") -> dict:
    """Score every eligible model and return an ordered recommendation chain."""
    if task not in TASKS:
        raise RedactionError(f"unknown task '{task}' (expected {', '.join(TASKS)})")
    if policy not in POLICY_NAMES:
        raise RedactionError(f"unknown policy '{policy}' (expected {', '.join(POLICY_NAMES)})")
    config.validate_weights()

    weights = config.weights(policy)
    reserve = config.reserve(policy)
    require_known = config.require_known_quota(policy)
    priorities = config.priorities(task)
    required_caps = config.capabilities(task)
    local_boost = config.policy_extra(policy, "localBoost", 1.0)
    oauth_penalty = config.policy_extra(policy, "oauthPenalty", 1.0)

    grant_exclusions: list[dict] = []
    inventory_connections = inventory["connections"]
    if consumer_id is not None:
        granted_ids = {
            connection_id for grant in grants
            if (connection_id := _granted_connection_for_scope(
                grant, consumer_id, required_scope,
            ))
        }
        eligible_connections = []
        for connection in inventory_connections:
            connection_id = _contract_connection_id(
                str(connection.get("provider") or ""), connection.get("id"))
            if connection_id in granted_ids:
                eligible_connections.append(connection)
            else:
                grant_exclusions.append({"connection": "<redacted>",
                                         "reason": f"no active grant for consumer {consumer_id}"})
        inventory_connections = eligible_connections

    conns = {c["id"]: c for c in inventory_connections}
    models = {m["id"]: m for m in inventory["models"]}
    usage = inventory.get("usage", {})
    now = time.time()

    excluded: list[dict] = grant_exclusions
    candidates: list[Candidate] = []

    for mid, m in models.items():
        caps = m.get("capabilities") or {}
        lacks = [cap for cap in required_caps if not caps.get(cap)]
        if lacks:
            excluded.append({"model": mid, "reason": f"missing capabilities: {', '.join(lacks)}"})
            continue

        eligible_conns = []
        for cid in m.get("connections", []):
            c = conns.get(cid)
            if not c:
                continue
            status = (c.get("status") or {}).get("state", "unknown")
            if not c.get("isActive"):
                excluded.append({"model": mid, "reason": f"connection {cid} disabled"})
                continue
            if status in ("unavailable", "disabled"):
                excluded.append({"model": mid, "reason": f"connection {cid} {status}"})
                continue
            locks = c.get("modelLocks") or {}
            lock_key = next((k for k in locks if model_short(k.rsplit("_", 1)[-1]) == model_short(mid)), None)
            if lock_key:
                excluded.append({"model": mid, "reason": f"model on cooldown ({lock_key})"})
                continue
            if c.get("errorCode") in (401, 403, 429):
                excluded.append({"model": mid, "reason": f"active HTTP {c.get('errorCode')}"})
                continue
            if c.get("backoffLevel", 0) > 0:
                excluded.append({"model": mid, "reason": "connection cooldown/backoff"})
                continue
            quota_state = c.get("quotaState", "unavailable")
            if quota_state == "known":
                pct = quota_remaining_pct(c.get("quota") or {})
                if pct is not None and pct <= reserve * 100:
                    excluded.append({"model": mid, "reason": f"quota {pct:.0f}% <= reserve {reserve*100:.0f}%"})
                    continue
            elif require_known and quota_state != "known":
                excluded.append({"model": mid, "reason": f"policy {policy} requires known quota (state={quota_state})"})
                continue
            eligible_conns.append(c)

        if not eligible_conns:
            excluded.append({"model": mid, "reason": "no ready connection"})
            continue

        # -- scores ---------------------------------------------------------
        fit = _rank_score(priorities, mid)
        quality = _rank_score(priorities, mid, base=0.2)
        quota_states = [c.get("quotaState", "unavailable") for c in eligible_conns]
        quota_confidence = max(QUOTA_CONFIDENCE.get(s, 0.15) for s in quota_states)
        best_pct = None
        for c in eligible_conns:
            if c.get("quotaState") == "known":
                pct = quota_remaining_pct(c.get("quota") or {})
                best_pct = pct if best_pct is None else max(best_pct, pct or 0)
        if best_pct is not None:
            quota = max(0.0, min(1.0, best_pct / 100.0))
        else:
            quota = 0.5 * quota_confidence

        errors = [c.get("errorCode") for c in eligible_conns if c.get("errorCode") in (400, 401, 403, 429)]
        reliability = 1.0 if not errors else min(ERROR_WEIGHT.get(e, 0.6) for e in errors)

        provider = m.get("provider") or (mid.split("/", 1)[0] if "/" in mid else "")
        cost = _cost_score(usage, provider)
        latency = 0.5  # no full request logs; documented neutral

        multiplier = 1.0
        is_local = any(c.get("authType") == "api-key" for c in eligible_conns) and any(
            c.get("provider") in ("mimo", "opencode") for c in eligible_conns)
        if is_local:
            multiplier *= local_boost
        if any(c.get("authType") == "oauth" for c in eligible_conns):
            multiplier *= oauth_penalty

        total = sum(float(weights[k]) for k in ("fit", "quality", "quota", "reliability", "cost", "latency"))
        score = (
            float(weights["fit"]) * fit
            + float(weights["quality"]) * quality
            + float(weights["quota"]) * quota
            + float(weights["reliability"]) * reliability
            + float(weights["cost"]) * cost
            + float(weights["latency"]) * latency
        ) / total * multiplier

        just = [
            f"fit={fit:.2f} (curated rank)" if fit > 0.3 else "fit=base (uncurated model)",
            f"quality={quality:.2f}",
            f"quota={quota:.2f} (state={quota_states[0]}, confidence={quota_confidence:.2f})",
            f"reliability={reliability:.2f}",
        ]
        candidates.append(Candidate(
            model_id=mid, provider=provider, fit=fit, quality=quality,
            quota=quota, quota_state=quota_states[0], quota_confidence=quota_confidence,
            reliability=reliability, cost=cost, latency=latency,
            score=round(score, 4), justifications=just,
        ))

    candidates.sort(key=lambda c: c.score, reverse=True)
    for i, cand in enumerate(candidates[:MAX_CHAIN]):
        cand.chain_position = i + 1

    return {
        "schemaVersion": SCHEMA_VERSION,
        "task": task,
        "policy": policy,
        "policyWeights": weights,
        "quotaReserve": reserve,
        "generatedAt": now_iso(),
        "recommendation": [c.__dict__ for c in candidates[:MAX_CHAIN]],
        "eligibleCount": len(candidates),
        "excludedCount": len(excluded),
        "excluded": excluded[:50],
        "secretsRedacted": True,
    }


def recommendation_chain(recommendation: dict) -> list[str]:
    return [c["model_id"] for c in recommendation.get("recommendation", [])]


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def save_state(inventory: dict, recommendation: dict, policy: str, task: str,
               weights: dict, manifest: str | None = None) -> Path:
    state = {
        "schemaVersion": SCHEMA_VERSION,
        "collectedAt": inventory.get("collectedAt"),
        "health": inventory.get("health"),
        "inventory": {
            "connections": [
                {
                    "id": c["id"], "provider": c["provider"], "name": c["name"],
                    "isActive": c["isActive"], "testStatus": c["testStatus"],
                    "errorCode": c["errorCode"], "status": c["status"],
                    "quota": c["quota"], "quotaState": c["quotaState"],
                    "quotaConfidence": c["quotaConfidence"],
                }
                for c in inventory.get("connections", [])
            ],
            "modelsCount": len(inventory.get("models", [])),
            "models": [
                {"id": m["id"], "capabilities": m.get("capabilities", {}), "connections": m.get("connections", [])}
                for m in inventory.get("models", [])
            ],
        },
        "lastRecommendation": recommendation,
        "policy": policy,
        "task": task,
        "weights": weights,
        "manifest": manifest,
        "secretsRedacted": True,
    }
    write_private(state_path(), json.dumps(state, indent=2) + "\n")
    return state_path()


def load_state() -> dict:
    path = state_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def state_is_stale(max_age: int = 300) -> bool:
    state = load_state()
    collected = state.get("collectedAt")
    if not collected:
        return True
    age = time.time() - utc_from_iso(collected)
    return age > max_age


# ---------------------------------------------------------------------------
# Managed combos (transactional apply / rollback)
# ---------------------------------------------------------------------------

MANAGED_COMBOS = ("phasezero-code", "phasezero-analysis", "phasezero-plan")


class ComboManager:
    def __init__(self, client: R9Client):
        self.client = client

    def list_combos(self) -> list[dict]:
        return self.client.combos()

    def combo_by_name(self, name: str) -> dict | None:
        for combo in self.list_combos():
            if combo.get("name") == name:
                return combo
        return None

    def managed_combos(self) -> dict[str, dict]:
        out = {}
        for name in MANAGED_COMBOS:
            combo = self.combo_by_name(name)
            if combo:
                out[name] = combo
        return out

    def upsert_combo(self, name: str, models: list[str]) -> dict:
        existing = self.combo_by_name(name)
        payload = {"name": name, "models": models}
        if existing:
            result = self.client.request("PUT", f"/api/combos/{existing['id']}", payload)
        else:
            result = self.client.request("POST", "/api/combos", payload)
        return result

    def _upsert_with_check(self, name: str, models: list[str]) -> dict:
        result = self.client.combos()
        existing = next((c for c in result if c.get("name") == name), None)
        payload = {"name": name, "models": models}
        if existing:
            return self.client.request("PUT", f"/api/combos/{existing['id']}", payload)
        return self.client.request("POST", "/api/combos", payload)

def combo_models_match(combo: dict | None, models: list[str]) -> bool:
    if not combo:
        return False
    return list(combo.get("models", [])) == list(models)


def request_scoped_grants_enforced() -> bool:
    """Return whether 9Router can bind every inference request to one grant.

    Current combo/model routes cannot pin an account and may fail over to
    sibling connections. Mutations stay blocked until a supported API and an
    integration test prove request-scoped account enforcement.
    """
    return False


def blocked_apply_result(task: str, policy: str) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "status": "blocked",
        "blockedReason": "connection-grant-not-enforceable",
        "message": (
            "Aplicação bloqueada: 9Router não vincula cada requisição a uma conexão "
            "autorizada e pode usar outra conta ou fallback pago. Nenhum combo foi alterado."
        ),
        "task": task,
        "policy": policy,
        "dryRun": False,
        "applied": False,
        "changes": {},
        "secretsRedacted": True,
    }


def apply_plan(client: R9Client, config: Config, task: str, policy: str,
               dry_run: bool = False, assume_yes: bool = False, override: dict | None = None) -> dict:
    """Preview route combos; block mutation until request grants can be enforced."""
    if not dry_run and not request_scoped_grants_enforced():
        return blocked_apply_result(task, policy)

    manager = ComboManager(client)
    inventory = build_inventory(client, refresh_quota=True)
    reco = recommend(client, config, inventory, task, policy)
    if override:
        reco["recommendation"] = override
        reco["overrideApplied"] = True
    chain = recommendation_chain(reco)
    if not chain:
        raise RedactionError("no eligible model to materialize")

    managed = MANAGED_COMBOS
    # phasezero-<task> gets this plan; every other managed combo is reconciled
    # with its own task plan inside the same transaction (self-healing).
    desired: dict[str, list[str]] = {}
    for name in managed:
        other_task = name[len("phasezero-"):]
        if other_task == task and override:
            desired[name] = chain
        elif other_task == task:
            desired[name] = chain
        else:
            other_inv = build_inventory(client, refresh_quota=True)
            other_reco = recommend(client, config, other_inv, other_task, policy)
            other_chain = recommendation_chain(other_reco)
            desired[name] = other_chain or None

    current = {c["name"]: c for c in client.combos() if c.get("name") in managed}
    changes = {
        name: models for name, models in desired.items()
        if models is not None and not combo_models_match(current.get(name), models)
    }

    result: dict = {
        "schemaVersion": SCHEMA_VERSION,
        "task": task,
        "policy": policy,
        "dryRun": dry_run,
        "chain": chain,
        "changes": {name: {"from": (current.get(name) or {}).get("models", []), "to": models}
                    for name, models in changes.items()},
        "unchanged": [name for name in managed if name not in changes],
        "secretsRedacted": True,
    }
    if dry_run:
        result["applied"] = False
        return result

    if changes and not assume_yes:
        # interactive confirmation
        print(json.dumps(redact(result), indent=2))
        try:
            answer = input("Apply these PhaseZero-managed combo changes? [y/N] ")
        except EOFError:
            answer = "n"
        if answer.strip().lower() not in ("y", "yes"):
            result["applied"] = False
            result["aborted"] = True
            return result

    # transactional manifest with byte-level backups
    if changes:
        op_id = f"apply-{datetime.now().strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"
        op_dir = ops_root() / op_id
        manifest = {
            "schemaVersion": SCHEMA_VERSION,
            "id": op_id,
            "createdAt": now_iso(),
            "kind": "routing-apply",
            "task": task,
            "policy": policy,
            "combos": {},
            "stateBefore": None,
            "secretsRedacted": True,
        }
        for name, models in changes.items():
            before = current.get(name)
            manifest["combos"][name] = {
                "id": before["id"] if before else None,
                "modelsBefore": before["models"] if before else [],
                "modelsAfter": models,
            }
        state_path_now = state_path()
        if state_path_now.exists():
            manifest["stateBefore"] = state_path_now.read_text(encoding="utf-8")
        manifest["statePath"] = str(state_path_now)

        applied: dict[str, dict] = {}
        try:
            for name, models in changes.items():
                applied[name] = manager._upsert_with_check(name, models)
        except RedactionError:
            # roll back whatever was applied
            rollback_manifest_apply(client, manifest)
            raise
        manifest["applied"] = applied
        manifest["stateAfter"] = state_path_now.read_text(encoding="utf-8") if state_path_now.exists() else None

        # Last mile: propagate new/changed combos to the opencode model catalog
        # so they appear in the opencode picker. Byte backup lives inside the
        # manifest dir for rollback; failure is non-fatal (never aborts apply).
        catalog = refresh_opencode_catalog(client, backup_dir=op_dir)
        manifest["opencodeCatalogBefore"] = catalog.get("beforeBackup")
        result["opencodeCatalog"] = catalog
        manifest["opencodeCatalog"] = catalog

        write_private(op_dir / "manifest.json", json.dumps(manifest, indent=2) + "\n")
        result["manifest"] = str(op_dir / "manifest.json")
        result["applied"] = True
    else:
        result["applied"] = True
        result["manifest"] = None
        result["note"] = "combos already match plan (idempotent)"
        # Even when combos did not change, the opencode catalog may be stale
        # relative to the live combo set; reconcile it without a manifest.
        result["opencodeCatalog"] = refresh_opencode_catalog(client)

    save_state(inventory, reco, policy, task, config.weights(policy), result.get("manifest"))
    return result


def rollback_manifest_apply(client: R9Client, manifest: dict) -> None:
    """Byte-level restore of combos recorded in a manifest."""
    for name, entry in manifest.get("combos", {}).items():
        combo_id = entry.get("id")
        before = entry.get("modelsBefore") or []
        if combo_id:
            client.request("PUT", f"/api/combos/{combo_id}", {"name": name, "models": before})
        elif before:
            client.request("POST", "/api/combos", {"name": name, "models": before})
        else:
            # combo was created by the apply; remove it on rollback
            current = next((c for c in client.combos() if c.get("name") == name), None)
            if current:
                client.request("DELETE", f"/api/combos/{current['id']}")


def rollback(client: R9Client, manifest_path: str, force: bool = False) -> dict:
    path = Path(manifest_path).expanduser()
    if not path.exists():
        raise RedactionError(f"manifest not found: {manifest_path}")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("kind") != "routing-apply":
        raise RedactionError(f"not a routing-apply manifest: {manifest_path}")

    current = {c["name"]: c for c in client.combos()}
    for name, entry in manifest.get("combos", {}).items():
        combo = current.get(name)
        if combo and list(combo.get("models", [])) != entry.get("modelsAfter", []):
            if not force:
                raise RedactionError(
                    f"combo '{name}' changed after apply; pass --force to override")
        if combo is None and entry.get("modelsAfter"):
            if not force:
                raise RedactionError(
                    f"combo '{name}' was removed after apply; pass --force to override")

    rollback_manifest_apply(client, manifest)

    # restore state file bytes
    state_before = manifest.get("stateBefore")
    if state_before is not None:
        write_private(state_path(), state_before)

    # restore opencode.json bytes (last-mile catalog sync)
    opencode_restored = False
    backup = manifest.get("opencodeCatalogBefore")
    if backup:
        backup_path = Path(backup)
        target = opencode_config_path()
        if backup_path.exists() and target.parent.is_dir():
            tmp = target.with_name(target.name + ".tmp")
            tmp.write_bytes(backup_path.read_bytes())
            os.chmod(tmp, 0o600)
            os.replace(tmp, target)
            os.chmod(target, 0o600)
            opencode_restored = True

    return {
        "schemaVersion": SCHEMA_VERSION,
        "manifest": str(path),
        "restoredCombos": list(manifest.get("combos", {}).keys()),
        "stateRestored": state_before is not None,
        "opencodeCatalogRestored": opencode_restored,
        "force": force,
        "secretsRedacted": True,
    }


# ---------------------------------------------------------------------------
# Child process launch (route + credential only)
# ---------------------------------------------------------------------------

def child_env(client: R9Client) -> dict:
    """Environment for the child: route and credential only."""
    env = dict(os.environ)
    env.pop("ANTHROPIC_API_KEY", None)
    env.pop("ANTHROPIC_AUTH_TOKEN", None)
    env.pop("ANTHROPIC_BASE_URL", None)
    env.pop("OPENAI_API_KEY", None)
    env.pop("OPENAI_BASE_URL", None)
    env["ANTHROPIC_BASE_URL"] = client.base + "/v1"
    env["ANTHROPIC_AUTH_TOKEN"] = client.api_key()
    env["OPENAI_BASE_URL"] = client.base + "/v1"
    env["OPENAI_API_KEY"] = client.api_key()
    return env


def run_client(client: R9Client, config: Config, task: str, client_name: str, args: list[str]) -> int:
    if client_name not in CLIENTS:
        raise RedactionError(f"unknown client '{client_name}' (expected {', '.join(CLIENTS)})")
    # 9Router combos and model IDs cannot pin one consumer to one connection.
    # Launching a client here could therefore use another account or fall back
    # to a paid provider even when a grant exists. Keep generic route management
    # available, but fail closed for consumer session launch until upstream
    # exposes an enforceable account-bound selection mechanism.
    raise RedactionError(
        "consumer session launch is disabled: 9Router cannot enforce a connection grant; "
        "no client process was started"
    )


# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

def verify(client: R9Client, config: Config, live: bool = False) -> dict:
    problems: list[dict] = []
    inventory = build_inventory(client, refresh_quota=False)
    checks: dict = {}

    checks["health"] = client.health()
    if not checks["health"]:
        problems.append({"id": "health", "severity": "error", "component": "9router"})

    models = client.models()
    checks["modelsCount"] = len(models)
    if not models:
        problems.append({"id": "models", "severity": "error", "component": "v1/models"})

    combos = {c["name"]: c for c in client.combos()}
    checks["combos"] = {name: list(c.get("models", [])) for name, c in combos.items() if name in MANAGED_COMBOS}
    checks["userCombosPreserved"] = all(name in combos for name in ("Default", "claude-Combo_Cleude"))
    if not checks["userCombosPreserved"]:
        problems.append({"id": "user-combos", "severity": "error", "component": "combos"})

    reco_by_task = {t: recommendation_chain(recommend(client, config, inventory, t, "balanced"))
                    for t in TASKS}
    checks["planMatches"] = all(
        list(combos.get(name, {}).get("models", [])) == reco_by_task[name[len("phasezero-"):]][:MAX_CHAIN]
        for name in MANAGED_COMBOS if name in combos
    )
    if not checks["planMatches"]:
        problems.append({"id": "plan-mismatch", "severity": "warn", "component": "combos"})

    checks["secretsRedacted"] = "secretsRedacted" in inventory and inventory["secretsRedacted"]

    bonsai_combo = any(
        model_provider(m) == "bonsai" for c in client.combos() for m in c.get("models", []))
    checks["bonsaiIsolated"] = not bonsai_combo
    if bonsai_combo:
        problems.append({"id": "bonsai-in-router", "severity": "error", "component": "bonsai"})

    if live:
        try:
            checks["liveModels"] = len(client.models()) > 0
        except RedactionError as exc:
            checks["liveModels"] = False
            problems.append({"id": "live-models", "severity": "error", "component": "live", "detail": str(exc)})

    checks["verdict"] = "healthy" if not any(p["severity"] == "error" for p in problems) else "degraded"
    checks["problems"] = problems
    return redact({**checks, "schemaVersion": SCHEMA_VERSION, "secretsRedacted": True})


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_json(obj) -> None:
    print(json.dumps(redact(obj), indent=2, ensure_ascii=False))


def cmd_status(args) -> int:
    try:
        return _cmd_status_impl(args)
    except RedactionError as exc:
        # 9Router ausente/sem chave é estado acionável, não falha de leitura.
        _print_json({
            "schemaVersion": SCHEMA_VERSION,
            "state": "needs-config",
            "summary": "9Router ainda não foi configurado.",
            "detail": str(exc),
            "nextAction": "linux/pz ai routing inventory",
            "secretsRedacted": True,
        })
        return 0


def _cmd_status_impl(args) -> int:
    cached = args.cached
    client = R9Client()
    if cached:
        state = load_state()
        if not state:
            print(json.dumps({"schemaVersion": SCHEMA_VERSION, "cached": False,
                              "error": "no cached state; run `pz ai routing inventory` first",
                              "secretsRedacted": True}, indent=2))
            return 1
        stale = state_is_stale()
        out = {
            "schemaVersion": SCHEMA_VERSION,
            "cached": True,
            "stale": stale,
            "collectedAt": state.get("collectedAt"),
            "health": state.get("health"),
            "connections": state.get("inventory", {}).get("connections", []),
            "modelsCount": state.get("inventory", {}).get("modelsCount"),
            "lastRecommendation": state.get("lastRecommendation"),
            "manifest": state.get("manifest"),
            "secretsRedacted": True,
        }
        _print_json(out)
        return 0
    inventory = build_inventory(client, refresh_quota=False)
    _print_json(inventory)
    return 0


def cmd_inventory(args) -> int:
    client = R9Client()
    inventory = build_inventory(client, refresh_quota=args.refresh_quota)
    previous = load_state()
    if not args.refresh_quota:
        # preserve last known quota when not explicitly refreshed
        prev_by_id = {c["id"]: c for c in previous.get("inventory", {}).get("connections", [])}
        for c in inventory["connections"]:
            prev = prev_by_id.get(c["id"])
            if prev and prev.get("quotaState") != "unavailable":
                c["quota"] = prev["quota"]
                c["quotaState"] = prev["quotaState"]
                c["quotaConfidence"] = prev["quotaConfidence"]
    save_state(inventory, previous.get("lastRecommendation", {}),
               previous.get("policy", "balanced"), previous.get("task", "code"),
               previous.get("weights", DEFAULT_WEIGHTS), previous.get("manifest"))
    if args.json:
        _print_json(inventory)
    else:
        _print_summary(inventory)
    return 0


def _print_summary(inventory: dict) -> None:
    by_state: dict[str, int] = {}
    quota: dict[str, int] = {}
    for c in inventory["connections"]:
        st = (c.get("status") or {}).get("state", "unknown")
        by_state[st] = by_state.get(st, 0) + 1
        qs = c.get("quotaState", "unavailable")
        quota[qs] = quota.get(qs, 0) + 1
    print(f"9Router health: {'ok' if inventory['health'] else 'down'}")
    print(f"models in /v1/models: {len(inventory['models'])}")
    print(f"connections: {len(inventory['connections'])} "
          f"states={dict(sorted(by_state.items()))}")
    print(f"quota states: {dict(sorted(quota.items()))}")
    for c in inventory["connections"]:
        st = (c.get("status") or {}).get("state", "unknown")
        qs = c.get("quotaState", "unavailable")
        pct = quota_remaining_pct(c.get("quota") or {})
        extra = f" {pct:.0f}%" if pct is not None else ""
        print(f"  {c['provider']:<10} {st:<12} quota={qs}{extra} conf={c.get('quotaConfidence', 0):.2f}")


def cmd_recommend(args) -> int:
    config = Config.load(create=False)
    client = R9Client()
    if args.refresh:
        inventory = build_inventory(client, refresh_quota=True)
        save_state(inventory, {}, "balanced", args.task, config.weights("balanced"))
    else:
        inventory = load_state().get("inventory") or build_inventory(client, refresh_quota=args.refresh_quota)
    reco = recommend(client, config, inventory, args.task, args.policy)
    if args.json:
        _print_json(reco)
    else:
        print(f"task={args.task} policy={args.policy}")
        for cand in reco["recommendation"]:
            print(f"  #{cand['chain_position']} {cand['model_id']:<28} score={cand['score']:.3f} "
                  f"quota={cand['quota_state']} ({cand['quota']:.2f})")
        print(f"eligible={reco['eligibleCount']} excluded={reco['excludedCount']}")
    return 0


def cmd_plan(args) -> int:
    config = Config.load(create=False)
    client = R9Client()
    inventory = build_inventory(client, refresh_quota=args.refresh_quota)
    reco = recommend(client, config, inventory, args.task, args.policy)
    chain = recommendation_chain(reco)
    out = {
        "schemaVersion": SCHEMA_VERSION,
        "task": args.task,
        "policy": args.policy,
        "client": args.client,
        "chain": chain,
        "env": {
            "ANTHROPIC_BASE_URL": client.base + "/v1",
            "ANTHROPIC_AUTH_TOKEN": "<from 9router.env>",
            "OPENAI_BASE_URL": client.base + "/v1",
            "OPENAI_API_KEY": "<from 9router.env>",
        },
        "combo": f"phasezero-{args.task}",
        "justifications": reco["recommendation"][0]["justifications"] if reco["recommendation"] else [],
        "secretsRedacted": True,
    }
    _print_json(out)
    return 0


def cmd_apply(args) -> int:
    if not args.dry_run and not request_scoped_grants_enforced():
        _print_json(blocked_apply_result(args.task, args.policy))
        return 2

    config = Config.load(create=not args.dry_run)
    client = R9Client()
    override = None
    if getattr(args, "chain", None):
        override = [
            {"model_id": model_short(x) if "/" not in x else x,
             "provider": (x.split("/", 1)[0] if "/" in x else ""),
             "fit": 0.0, "quality": 0.0, "quota": 0.0, "quota_state": "override",
             "quota_confidence": 0.0, "reliability": 0.0, "cost": 0.0, "latency": 0.0,
             "score": 1.0, "justifications": ["manual order override"], "chain_position": i + 1}
            for i, x in enumerate(args.chain.split(","))
        ]
    result = apply_plan(client, config, args.task, args.policy,
                        dry_run=args.dry_run, assume_yes=args.yes, override=override)
    _print_json(result)
    return 2 if result.get("status") == "blocked" else 0


def cmd_run(args) -> int:
    config = Config.load()
    client = R9Client()
    return run_client(client, config, args.task, args.client, args.args)


def cmd_rollback(args) -> int:
    client = R9Client()
    result = rollback(client, args.manifest, force=args.force)
    _print_json(result)
    return 0


def cmd_verify(args) -> int:
    config = Config.load(create=False)
    client = R9Client()
    result = verify(client, config, live=args.live)
    _print_json(result)
    return 0


def cmd_refresh(args) -> int:
    """Explicit quota refresh (safe for a 5-10 min scheduler)."""
    client = R9Client()
    inventory = build_inventory(client, refresh_quota=True)
    state = load_state()
    save_state(inventory, state.get("lastRecommendation", {}),
               state.get("policy", "balanced"), state.get("task", "code"),
               state.get("weights", DEFAULT_WEIGHTS), state.get("manifest"))
    _print_json({"schemaVersion": SCHEMA_VERSION, "refreshedAt": inventory["collectedAt"],
                 "health": inventory["health"], "secretsRedacted": True})
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pz ai routing", description="Quota-aware task routing configurator")
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="Redacted routing status (fast cached view)")
    p_status.add_argument("--cached", action="store_true", help="read cached state only")
    p_status.add_argument("--json", action="store_true")
    p_status.set_defaults(func=cmd_status)

    p_inv = sub.add_parser("inventory", help="Collect redacted inventory from 9Router")
    p_inv.add_argument("--refresh-quota", action="store_true", help="query per-connection quota")
    p_inv.add_argument("--json", action="store_true")
    p_inv.set_defaults(func=cmd_inventory)

    p_rec = sub.add_parser("recommend", help="Recommend a model chain for a task/policy")
    p_rec.add_argument("--task", choices=TASKS, required=True)
    p_rec.add_argument("--policy", choices=POLICY_NAMES, default="balanced")
    p_rec.add_argument("--refresh-quota", action="store_true")
    p_rec.add_argument("--refresh", action="store_true", help="refresh inventory+quota and persist state")
    p_rec.add_argument("--json", action="store_true")
    p_rec.set_defaults(func=cmd_recommend)

    p_plan = sub.add_parser("plan", help="Show route plan (env + combo) without mutating")
    p_plan.add_argument("--task", choices=TASKS, required=True)
    p_plan.add_argument("--client", choices=CLIENTS, default="claude")
    p_plan.add_argument("--policy", choices=POLICY_NAMES, default="balanced")
    p_plan.add_argument("--refresh-quota", action="store_true")
    p_plan.add_argument("--json", action="store_true", help="accepted for catalog compatibility")
    p_plan.set_defaults(func=cmd_plan)

    p_apply = sub.add_parser(
        "apply",
        help="Blocked until each request enforces one granted connection; --dry-run previews only",
    )
    p_apply.add_argument("--task", choices=TASKS, required=True)
    p_apply.add_argument("--policy", choices=POLICY_NAMES, default="balanced")
    p_apply.add_argument("--dry-run", action="store_true", help="no files, no combos, no state")
    p_apply.add_argument("--yes", action="store_true", help="skip interactive confirmation")
    p_apply.add_argument("--chain", help="comma-separated model ids overriding the recommendation order")
    p_apply.set_defaults(func=cmd_apply)

    p_run = sub.add_parser("run", help="Blocked until consumer-scoped connection grants are enforceable")
    p_run.add_argument("task", choices=TASKS)
    p_run.add_argument("--client", choices=CLIENTS, required=True)
    p_run.add_argument("--", dest="args", nargs=argparse.REMAINDER, default=[])
    p_run.set_defaults(func=cmd_run)

    p_rb = sub.add_parser("rollback", help="Restore combos and state from a manifest")
    p_rb.add_argument("manifest")
    p_rb.add_argument("--force", action="store_true")
    p_rb.set_defaults(func=cmd_rollback)

    p_ver = sub.add_parser("verify", help="Verify combos/plan/redaction (--live for live probes)")
    p_ver.add_argument("--live", action="store_true")
    p_ver.set_defaults(func=cmd_verify)

    p_ref = sub.add_parser("refresh", help="Refresh inventory+quota and persist state (scheduler-safe)")
    p_ref.set_defaults(func=cmd_refresh)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except RedactionError as exc:
        print(f"routing error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
