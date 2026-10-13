"""Tests for the PhaseZero quota-aware task routing configurator.

Every test runs against a fake 9Router (stdlib http.server) with an isolated
HOME/XDG sandbox. No real host state is touched.
"""
from __future__ import annotations

import hashlib
import json
import os
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from linux.ai.account_contract import Grant

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "linux" / "ai"))

import routing_manager as rm  # noqa: E402

MACHINE_ID = "test-machine"
CLI_SECRET = "test-cli-secret"
API_KEY = "test-api-key-000"


def cli_token() -> str:
    return hashlib.sha256((MACHINE_ID + "9r-cli-auth" + CLI_SECRET).encode()).hexdigest()[:16]


def _mk_model(model_id, owned_by, caps: dict | None = None) -> dict:
    return {
        "id": model_id, "object": "model", "owned_by": owned_by,
        "capabilities": caps or {"vision": False, "pdf": False, "audioInput": False,
                                 "videoInput": False, "imageOutput": False, "audioOutput": False,
                                 "search": True, "tools": True, "reasoning": True,
                                 "thinkingFormat": None, "contextWindow": 200000, "maxOutput": 128000},
    }


class FakeR9:
    """In-memory fake 9Router with real HTTP endpoints and failure injection."""

    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        (data_dir / "auth").mkdir(parents=True, exist_ok=True)
        (data_dir / "machine-id").write_text(MACHINE_ID)
        (data_dir / "auth" / "cli-secret").write_text(CLI_SECRET)
        self.fail: dict[str, tuple[int, str]] = {}
        self.fail_after: dict[str, int] = {}
        self.combos: list[dict] = [
            {"id": "c-default", "name": "Default", "kind": None,
             "models": ["cc/claude-opus-4-8", "cc/claude-sonnet-5"],
             "createdAt": "2026-07-24T00:00:00.000Z", "updatedAt": "2026-07-24T00:00:00.000Z"},
            {"id": "c-cleude", "name": "claude-Combo_Cleude", "kind": None,
             "models": ["cc/claude-opus-4-8", "cc/claude-sonnet-5", "cx/gpt-5.6-terra-review"],
             "createdAt": "2026-07-24T00:00:00.000Z", "updatedAt": "2026-07-24T00:00:00.000Z"},
        ]
        self.connections: list[dict] = [
            {"id": "conn-claude", "provider": "claude", "authType": "oauth", "name": "Account 1",
             "email": "person@example.com", "isActive": True, "testStatus": "unavailable",
             "errorCode": 429, "backoffLevel": 15,
             "lastErrorAt": "2026-08-01T15:26:18.000Z",
             "modelLock_claude-fable-5": "2099-08-01T00:00:00.000Z"},
            {"id": "conn-codex-plus", "provider": "codex", "authType": "oauth", "name": "plus",
             "isActive": True, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-codex-free", "provider": "codex", "authType": "oauth", "name": "free",
             "isActive": True, "testStatus": "unavailable", "errorCode": 400, "backoffLevel": 0},
            {"id": "conn-codex-team", "provider": "codex", "authType": "oauth", "name": "team",
             "isActive": True, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-codex-disabled", "provider": "codex", "authType": "oauth", "name": "off",
             "isActive": False, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-glm", "provider": "glm", "authType": "api-key", "name": "glm",
             "isActive": True, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-kimi", "provider": "kimi", "authType": "api-key", "name": "kimi",
             "isActive": True, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-xai", "provider": "xai", "authType": "api-key", "name": "xai",
             "isActive": True, "testStatus": "active", "errorCode": None, "backoffLevel": 0},
            {"id": "conn-openai", "provider": "openai", "authType": "api-key", "name": "openai",
             "isActive": True, "testStatus": "unavailable", "errorCode": 429, "backoffLevel": 2},
        ]
        self.usage: dict[str, dict] = {
            "conn-claude": {"message": "Claude connected. Usage API requires admin permissions."},
            "conn-codex-plus": {"plan": "plus", "quotas": {"session": {
                "used": 1, "total": 100, "remaining": 99, "remainingPercentage": 99,
                "resetAt": "2026-08-08T00:00:00.000Z", "unlimited": False}}},
            "conn-codex-free": {"plan": "free", "limitReached": True, "quotas": {"session": {
                "used": 100, "total": 100, "remaining": 0, "remainingPercentage": 0,
                "resetAt": "2026-08-27T00:00:00.000Z", "unlimited": False}}},
            "conn-codex-team": {"plan": "team", "quotas": {"session": {
                "used": 74, "total": 100, "remaining": 26, "remainingPercentage": 26,
                "resetAt": "2026-08-08T00:00:00.000Z", "unlimited": False}}},
            "conn-glm": {"plan": "Lite", "quotas": {"session": {
                "used": 27, "total": 100, "remaining": 73, "remainingPercentage": 73,
                "resetAt": "2026-08-06T00:00:00.000Z", "unlimited": False}}},
            "conn-kimi": {"plan": "Moderato", "quotas": {"Weekly": {
                "used": 20, "total": 100, "remaining": 80, "remainingPercentage": 80,
                "resetAt": "2026-08-02T00:00:00.000Z", "unlimited": False},
                "Ratelimit": {"used": 0, "total": 100, "remainingPercentage": 100,
                              "resetAt": "2026-08-01T00:00:00.000Z", "unlimited": False}}},
            "conn-xai": {"message": "Usage API not implemented for xai"},
            "conn-openai": {"message": "Usage not available for this connection"},
            "conn-codex-disabled": {"message": "Usage not available for this connection"},
        }
        self.models = [
            _mk_model("cc/claude-opus-5", "cc"),
            _mk_model("cc/claude-fable-5", "cc"),
            _mk_model("cc/claude-sonnet-5", "cc"),
            _mk_model("cx/gpt-5.6-sol", "cx"),
            _mk_model("cx/gpt-5.6-terra", "cx"),
            _mk_model("cx/gpt-5.6-sol-review", "cx"),
            _mk_model("cx/gpt-5.6-terra-review", "cx"),
            _mk_model("kimi/kimi-for-coding", "kimi"),
            _mk_model("kimi/kimi-k3", "kimi"),
            _mk_model("glm/glm-5.2", "glm"),
            _mk_model("xai/grok-code-fast-1", "xai"),
            _mk_model("openai/gpt-4o", "openai", caps={"tools": True, "reasoning": False}),
        ]
        self.availability = [
            {"provider": "claude", "model": "__all", "status": "unavailable",
             "connectionId": "conn-claude", "connectionName": "Account 1",
             "lastError": "[429]: rate_limit_error"},
            {"provider": "codex", "model": "__all", "status": "unavailable",
             "connectionId": "conn-codex-free", "connectionName": "free",
             "lastError": "[400]: bad request"},
        ]
        self.stats = {"totalRequests": 100, "totalCost": 2.5, "byProvider": {}}

    # -- HTTP plumbing ------------------------------------------------------
    def server(self) -> ThreadingHTTPServer:
        handler = self._make_handler()
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # Keep the thread reachable so the fixture can join it: a daemon thread
        # left running holds the listening socket and shows up as an orphan
        # process at job teardown.
        self._thread = thread
        # serve_forever needs a moment to enter its loop. On a loaded runner the
        # client can otherwise connect before the loop is polling and see the
        # connection refused, which surfaces as "/v1/models unreachable".
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", server.server_port), timeout=0.5):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("fake R9 server never accepted a connection")
        return server

    def _make_handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # silence
                pass

            def _read_body(self) -> dict:
                length = int(self.headers.get("Content-Length") or 0)
                if not length:
                    return {}
                return json.loads(self.rfile.read(length).decode("utf-8"))

            def _send(self, code: int, payload: object) -> None:
                body = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _authed(self) -> bool:
                token = self.headers.get("x-9r-cli-token")
                return token == cli_token()

            def _bearer_ok(self) -> bool:
                return self.headers.get("Authorization") == f"Bearer {API_KEY}"

            def do_GET(self):
                path = self.path.split("?")[0]
                is_models = path == "/v1/models"
                if path == "/api/health":
                    return self._send(200, {"ok": True})
                if is_models:
                    if not self._bearer_ok():
                        return self._send(401, {"error": "Unauthorized"})
                elif not self._authed():
                    return self._send(401, {"error": "Unauthorized"})
                if path in fake.fail:
                    return self._send(*fake.fail[path])
                if path == "/api/providers":
                    return self._send(200, {"connections": fake.connections})
                if path == "/api/combos":
                    return self._send(200, {"combos": fake.combos})
                if path == "/api/models/availability":
                    return self._send(200, {"models": fake.availability})
                if path == "/api/usage/stats":
                    return self._send(200, fake.stats)
                if path.startswith("/api/usage/"):
                    cid = path.rsplit("/", 1)[-1]
                    return self._send(200, fake.usage.get(cid, {"message": "unknown"}))
                if path == "/v1/models":
                    return self._send(200, {"data": fake.models})
                return self._send(404, {"error": "not found"})

            def do_POST(self):
                if not self._authed():
                    return self._send(401, {"error": "Unauthorized"})
                if self.path == "/api/combos":
                    if "/api/combos" in fake.fail:
                        return self._send(*fake.fail["/api/combos"])
                    payload = self._read_body()
                    combo = {"id": f"c-{len(fake.combos) + 1}", "name": payload["name"],
                             "kind": None, "models": payload["models"],
                             "createdAt": "2026-08-01T00:00:00.000Z",
                             "updatedAt": "2026-08-01T00:00:00.000Z"}
                    fake.combos.append(combo)
                    return self._send(201, combo)
                return self._send(404, {"error": "not found"})

            def do_PUT(self):
                if not self._authed():
                    return self._send(401, {"error": "Unauthorized"})
                if self.path.startswith("/api/combos/"):
                    cid = self.path.rsplit("/", 1)[-1]
                    if f"/api/combos/{cid}" in fake.fail:
                        return self._send(*fake.fail[f"/api/combos/{cid}"])
                    payload = self._read_body()
                    for combo in fake.combos:
                        if combo["id"] == cid:
                            combo["models"] = payload["models"]
                            combo["updatedAt"] = "2026-08-01T00:00:00.000Z"
                            return self._send(200, combo)
                    return self._send(404, {"error": "combo not found"})
                return self._send(404, {"error": "not found"})

            def do_DELETE(self):
                if not self._authed():
                    return self._send(401, {"error": "Unauthorized"})
                if self.path.startswith("/api/combos/"):
                    cid = self.path.rsplit("/", 1)[-1]
                    fake.combos = [c for c in fake.combos if c["id"] != cid]
                    return self._send(200, {"ok": True})
                return self._send(404, {"error": "not found"})

        return Handler


@pytest.fixture()
def fake(tmp_path: Path):
    data_dir = tmp_path / "r9data"
    fake = FakeR9(data_dir)
    server = fake.server()
    try:
        yield fake, f"http://127.0.0.1:{server.server_port}"
    finally:
        # shutdown() only stops the serve_forever loop; without server_close()
        # the listening socket survives every test in the module and the worker
        # is still holding it when pytest exits.
        server.shutdown()
        server.server_close()
        thread = getattr(fake, "_thread", None)
        if thread is not None:
            thread.join(timeout=5)


@pytest.fixture()
def sandbox(tmp_path: Path, monkeypatch):
    """Isolated XDG home + env wiring for module-level tests."""
    home = tmp_path / "home"
    home.mkdir()
    env_file = tmp_path / "env" / "9router.env"
    env_file.parent.mkdir(parents=True)
    env_file.write_text(f'PHASEZERO_9ROUTER_API_KEY={API_KEY}\n')
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("PHASEZERO_9ROUTER_ENV", str(env_file))
    monkeypatch.setenv("PZ_9ROUTER_DATA_DIR", str(tmp_path / "r9data"))
    return tmp_path, env_file


@pytest.fixture()
def client(fake):
    fake_obj, base = fake
    return rm.R9Client(base_url=base, data_dir=fake_obj.data_dir)


@pytest.fixture()
def config(sandbox):
    return rm.Config.load()


@pytest.fixture()
def transaction_gate_for_legacy_tests(monkeypatch):
    # Exercise combo transaction mechanics in the fake server only. This does
    # not prove PXA-008 request binding; production gate remains false.
    monkeypatch.setattr(rm, "request_scoped_grants_enforced", lambda: True)


def _fresh_inventory(client) -> dict:
    return rm.build_inventory(client, refresh_quota=True)


def _client_for(fake, base: str) -> rm.R9Client:
    fake_obj, _base = fake
    return rm.R9Client(base_url=base, data_dir=fake_obj.data_dir, api_key=API_KEY)


# ---------------------------------------------------------------------------
# Inventory and quota classification
# ---------------------------------------------------------------------------

def test_quota_states_known_unknown_unavailable(fake):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    by_provider = {c["provider"]: c for c in inv["connections"]}
    assert by_provider["glm"]["quotaState"] == "known"
    assert by_provider["glm"]["quotaConfidence"] == 1.0
    assert rm.quota_remaining_pct(by_provider["glm"]["quota"]) == 73
    assert by_provider["xai"]["quotaState"] == "unknown"
    assert by_provider["xai"]["quotaConfidence"] == 0.4
    assert by_provider["claude"]["quotaState"] == "unavailable"
    assert by_provider["claude"]["quotaConfidence"] == 0.15
    assert inv["secretsRedacted"] is True


def test_quota_reset_and_min_bucket(fake):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    kimi = next(c for c in inv["connections"] if c["provider"] == "kimi")
    assert rm.quota_remaining_pct(kimi["quota"]) == 80
    # earliest reset wins (Ratelimit resets before Weekly)
    assert rm.quota_reset_at(kimi["quota"]) == "2026-08-01T00:00:00.000Z"


def test_quota_provenance_and_estimate_are_separate():
    state, quota, _confidence = rm.parse_quota({
        "quotas": {"session": {"used": 25, "total": 100}},
    }, observed_at="2026-09-24T12:00:00Z")
    assert state == "unknown"
    assert quota["source"] == "9router_usage_api"
    assert quota["observedAt"] == "2026-09-24T12:00:00Z"
    bucket = quota["buckets"][0]
    assert bucket["dimension"] == "session"
    assert bucket["unit"] == "unknown"
    assert bucket["remaining"] is None
    assert bucket["remainingPercentage"] is None
    assert bucket["estimatedRemainingPercentage"] == 75
    assert rm.quota_remaining_pct(quota) is None


def test_quota_parser_rejects_invalid_numbers_and_reset_time():
    state, quota, _confidence = rm.parse_quota({
        "quotas": {"session": {
            "used": 25, "total": 100, "remaining": float("nan"),
            "remainingPercentage": True, "unit": "calls",
            "resetAt": "not-a-time", "unlimited": "false",
        }},
    }, observed_at="2026-09-25T06:00:00Z")
    bucket = quota["buckets"][0]
    assert state == "unknown"
    assert bucket["remaining"] is None
    assert bucket["remainingPercentage"] is None
    assert bucket["estimatedRemainingPercentage"] == 75
    assert bucket["resetAt"] is None
    assert bucket["unlimited"] is False
    assert rm.quota_remaining_pct(quota) is None
    assert rm.quota_remaining_pct({"buckets": [
        {"remainingPercentage": True},
        {"remainingPercentage": float("nan")},
        {"remainingPercentage": 101},
    ]}) is None
    assert rm.quota_reset_at({"buckets": [
        {"resetAt": "tomorrow"}, {"resetAt": "2026-09-25T06:00:00"},
    ]}) is None

    invalid_estimate = rm.parse_quota({
        "quotas": {"session": {"used": True, "total": 100}},
    })[1]["buckets"][0]
    assert invalid_estimate["estimatedRemainingPercentage"] is None
    malformed_time = rm.parse_quota({"message": "Usage not available"}, observed_at="tomorrow")[1]
    parsed_time = datetime.fromisoformat(malformed_time["observedAt"].replace("Z", "+00:00"))
    assert parsed_time.tzinfo is not None


def test_quota_probe_exception_preserves_connection_rows(fake, monkeypatch):
    _fake, base = fake
    client = _client_for(fake, base)
    monkeypatch.setattr(client, "usage_connection", lambda _connection_id: (_ for _ in ()).throw(TimeoutError()))
    inventory = rm.build_inventory(client, refresh_quota=True)
    assert len(inventory["connections"]) == len(client.providers())
    assert all(c["quotaState"] == "unavailable" for c in inventory["connections"])
    assert all(c["quota"]["error"] == "unavailable" for c in inventory["connections"])


def test_cooldown_and_error_classification(fake):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    claude = next(c for c in inv["connections"] if c["id"] == "conn-claude")
    assert claude["status"]["state"] == "unavailable"
    assert any("429" in r for r in claude["status"]["reason"])
    assert "modelLock_claude-fable-5" in claude["modelLocks"]
    disabled = next(c for c in inv["connections"] if c["id"] == "conn-codex-disabled")
    assert disabled["status"]["state"] == "disabled"


def test_models_capabilities_and_attribution(fake):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    by_id = {m["id"]: m for m in inv["models"]}
    assert "conn-claude" in by_id["cc/claude-opus-5"]["connections"]
    assert "conn-codex-plus" in by_id["cx/gpt-5.6-sol"]["connections"]
    assert "conn-codex-plus" not in by_id["cc/claude-opus-5"]["connections"]
    assert by_id["openai/gpt-4o"]["capabilities"]["reasoning"] is False


# ---------------------------------------------------------------------------
# Recommendation filters
# ---------------------------------------------------------------------------

def test_recommend_code_chain_and_health_wins(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    reco = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    chain = rm.recommendation_chain(reco)
    # Claude curated #2 is excluded by the real 429 gate
    assert chain[0] == "cx/gpt-5.6-sol"
    assert "cc/claude-opus-5" not in chain
    assert "cx/gpt-5.6-terra" in chain


def test_consumer_grants_filter_routes_and_never_fallback(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    inv = _fresh_inventory(client)

    denied = rm.recommend(client, config, inv, "code", "balanced",
                          consumer_id="app.claude-code")
    assert denied["recommendation"] == []
    assert denied["eligibleCount"] == 0
    assert any("no active grant" in item["reason"] for item in denied["excluded"])

    grant = Grant("grant-test", rm._contract_connection_id("codex", "conn-codex-plus"),
                  "app.claude-code", ("inference",), enabled=True,
                  consented_at="2026-09-25T00:00:00Z")
    wrong_scope = Grant("grant-read", grant.connection_id, "app.claude-code",
                        ("status",), enabled=True, consented_at=grant.consented_at)
    scope_denied = rm.recommend(client, config, inv, "code", "balanced",
                                consumer_id="app.claude-code", grants=(wrong_scope,))
    assert scope_denied["recommendation"] == []
    allowed = rm.recommend(client, config, inv, "code", "balanced",
                           consumer_id="app.claude-code", grants=(grant,))
    chain = rm.recommendation_chain(allowed)
    assert chain
    assert all(model_id.startswith("cx/") for model_id in chain)

    malformed_grants = (
        {
            "connectionId": grant.connection_id,
            "consumerId": "app.claude-code",
            "scopes": ["inference"],
            "enabled": "false",
            "consentedAt": grant.consented_at,
        },
        {
            "connectionId": grant.connection_id,
            "consumerId": "app.claude-code",
            "scopes": ["inference"],
            "enabled": 1,
            "consentedAt": grant.consented_at,
        },
        {
            "connectionId": grant.connection_id,
            "consumerId": "app.claude-code",
            "scopes": "inference",
            "enabled": True,
            "consentedAt": grant.consented_at,
        },
        {
            "connectionId": grant.connection_id,
            "consumerId": "app.claude-code",
            "scopes": ["inference"],
            "enabled": True,
            "consentedAt": "not-a-time",
        },
    )
    for malformed in malformed_grants:
        rejected = rm.recommend(
            client, config, inv, "code", "balanced",
            consumer_id="app.claude-code", grants=(malformed,),
        )
        assert rejected["recommendation"] == []


@pytest.mark.parametrize("client_name", ("claude", "opencode"))
def test_client_launch_fails_closed_until_router_can_enforce_connection_grants(
    client_name, config, monkeypatch, capsys,
):
    def unexpected(*_args, **_kwargs):
        raise AssertionError("blocked launch must not inspect providers or start a process")

    monkeypatch.setattr(rm.Config, "load", lambda **_kwargs: config)
    monkeypatch.setattr(rm, "R9Client", object)
    monkeypatch.setattr(rm, "build_inventory", unexpected)
    monkeypatch.setattr(rm.subprocess, "call", unexpected)
    assert rm.main(["run", "code", "--client", client_name]) == 1
    assert "cannot enforce a connection grant" in capsys.readouterr().err


def test_save_quota_requires_known_quota(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    balanced = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    # xai has unknown quota: allowed under balanced (low confidence, never 100%),
    # excluded under save-quota where known quota is required
    assert not any("requires known quota" in e["reason"] for e in balanced["excluded"])
    save = rm.recommend(_client_for(fake, base), config, inv, "code", "save-quota")
    assert any(e["model"] == "xai/grok-code-fast-1" and "requires known quota" in e["reason"]
               for e in save["excluded"])


def test_unknown_quota_never_full_confidence(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    reco = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    for cand in reco["recommendation"]:
        assert cand["quota_confidence"] <= 0.4 or cand["quota_state"] == "known"


def test_insufficient_capabilities_excluded(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    reco = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    ids = {c["model_id"] for c in reco["recommendation"]}
    assert "openai/gpt-4o" not in ids
    assert any("missing capabilities" in e["reason"] for e in reco["excluded"])


def test_removed_model_not_offered(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    inv = _fresh_inventory(client)
    original = rm.R9Client.models
    rm.R9Client.models = lambda self: []  # noqa: B023
    try:
        inv2 = _fresh_inventory(client)
        assert inv2["models"] == []
        reco = rm.recommend(client, config, inv2, "code", "balanced")
        assert rm.recommendation_chain(reco) == []
    finally:
        rm.R9Client.models = original


def test_multiple_accounts_uses_ready_one(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    codex = [c for c in inv["connections"] if c["provider"] == "codex"]
    assert any(c["status"]["state"] == "ready" for c in codex)
    reco = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    chain = rm.recommendation_chain(reco)
    assert chain[0] == "cx/gpt-5.6-sol"


def test_disabled_connection_excluded(fake, config):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    reco = rm.recommend(_client_for(fake, base), config, inv, "code", "balanced")
    # cx models still eligible via plus/team accounts; disabled account alone not enough
    assert reco["eligibleCount"] > 0


def test_weights_must_sum_100(fake, config, sandbox):
    cfg = rm.Config.load()
    cfg.data["policies"]["balanced"]["weights"] = {"fit": 10, "quality": 10, "quota": 10,
                                                   "reliability": 10, "cost": 10, "latency": 10}
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    with pytest.raises(rm.RedactionError):
        rm.recommend(_client_for(fake, base), cfg, inv, "code", "balanced")


# ---------------------------------------------------------------------------
# Apply / idempotency / transactional behavior
# ---------------------------------------------------------------------------

def test_route_apply_mutation_blocks_before_contacting_9router():
    class ForbiddenClient:
        def __getattr__(self, name):
            pytest.fail(f"route apply contacted 9Router through {name}")

    result = rm.apply_plan(
        ForbiddenClient(), config=None, task="code", policy="balanced", assume_yes=True,
    )

    assert result["status"] == "blocked"
    assert result["blockedReason"] == "connection-grant-not-enforceable"
    assert result["applied"] is False
    assert result["changes"] == {}
    assert result["secretsRedacted"] is True


def test_route_apply_cli_blocks_before_loading_config_or_router(monkeypatch, capsys):
    from types import SimpleNamespace

    monkeypatch.setattr(
        rm.Config, "load",
        lambda **_kwargs: pytest.fail("mutating apply loaded/created router config"),
    )
    monkeypatch.setattr(
        rm, "R9Client", lambda: pytest.fail("mutating apply contacted router"),
    )

    code = rm.cmd_apply(SimpleNamespace(
        task="code", policy="balanced", dry_run=False, yes=True, chain=None,
    ))
    payload = json.loads(capsys.readouterr().out)

    assert code != 0
    assert payload["status"] == "blocked"
    assert payload["blockedReason"] == "connection-grant-not-enforceable"
    assert payload["applied"] is False


def test_apply_creates_only_phasezero_combos(fake, config, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    before = {c["name"]: list(c["models"]) for c in client.combos()}
    result = rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    assert result["applied"] is True
    after = {c["name"]: list(c["models"]) for c in client.combos()}
    assert set(after) == set(before) | {"phasezero-code", "phasezero-analysis", "phasezero-plan"}
    assert after["Default"] == before["Default"]
    assert after["claude-Combo_Cleude"] == before["claude-Combo_Cleude"]
    assert after["phasezero-code"][0] == "cx/gpt-5.6-sol"
    assert after["phasezero-analysis"][0] == "cx/gpt-5.6-sol-review"
    assert after["phasezero-plan"][0] == "cx/gpt-5.6-sol"


def test_apply_idempotent_second_run_no_manifest(fake, config, sandbox, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    ops_before = sorted(p.name for p in (rm.ops_root() / "..").iterdir() if p.is_dir())
    result2 = rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    assert result2["applied"] is True
    assert result2["manifest"] is None
    assert "combos already match plan" in result2.get("note", "")


def test_dry_run_leaves_no_trace(fake, config, sandbox, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data2"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config2"))
    _fake, base = fake
    client = _client_for(fake, base)
    before = {c["name"]: list(c["models"]) for c in client.combos()}
    result = rm.apply_plan(client, config, "code", "balanced", dry_run=True)
    assert result["dryRun"] is True
    assert result["applied"] is False
    after = {c["name"]: list(c["models"]) for c in client.combos()}
    assert after == before
    assert not (tmp_path / "data2").exists()
    assert not (tmp_path / "config2").exists()


def test_apply_failure_midway_rolls_back(fake, config, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    # pre-create code+analysis with wrong models so the apply PUTs them;
    # fail the SECOND upsert (PUT /api/combos/c-2) -> first must be rolled back
    client.request("POST", "/api/combos", {"name": "phasezero-code",
                                           "models": ["stale-model"]})
    client.request("POST", "/api/combos", {"name": "phasezero-analysis",
                                           "models": ["stale-model"]})
    before = {c["name"]: list(c["models"]) for c in client.combos()}
    analysis_id = next(
        c["id"] for c in client.combos() if c["name"] == "phasezero-analysis")
    _fake.fail[f"/api/combos/{analysis_id}"] = (500, {"error": "boom"})
    with pytest.raises(rm.RedactionError):
        rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    after = {c["name"]: list(c["models"]) for c in client.combos()}
    assert set(after) == set(before)
    assert after["phasezero-code"] == ["stale-model"]
    assert after["phasezero-analysis"] == ["stale-model"]
    assert after["Default"] == before["Default"]


def test_rollback_restores_bytes_and_state(fake, config, sandbox, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    # pre-existing combo (stale models) so the apply PUTs it and rollback can restore bytes
    client.request("POST", "/api/combos", {"name": "phasezero-code",
                                           "models": ["stale-model"]})
    rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    manifest_path = sorted((rm.ops_root()).glob("*/manifest.json"))[-1]
    manifest = json.loads(Path(manifest_path).read_text())
    assert manifest["combos"]["phasezero-code"]["modelsBefore"] == ["stale-model"]
    # simulate external removal: rollback cannot restore a vanished combo id
    combo = next(c for c in client.combos() if c["name"] == "phasezero-code")
    client.request("DELETE", f"/api/combos/{combo['id']}")
    with pytest.raises(rm.RedactionError):
        rm.rollback(client, str(manifest_path), force=True)
    after = {c["name"]: list(c["models"]) for c in client.combos()}
    assert "phasezero-code" not in after


def test_rollback_refuses_drift_without_force(fake, config, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    client.request("POST", "/api/combos", {"name": "phasezero-code",
                                           "models": ["stale-model"]})
    rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    manifest_path = sorted((rm.ops_root()).glob("*/manifest.json"))[-1]
    manifest = json.loads(Path(manifest_path).read_text())
    combo = next(c for c in client.combos() if c["name"] == "phasezero-code")
    client.request("PUT", f"/api/combos/{combo['id']}", {"name": "phasezero-code",
                                                         "models": ["someone-else"]})
    with pytest.raises(rm.RedactionError):
        rm.rollback(client, str(manifest_path))
    result = rm.rollback(client, str(manifest_path), force=True)
    assert "phasezero-code" in result["restoredCombos"]
    after = {c["name"]: list(c["models"]) for c in client.combos()}
    assert after["phasezero-code"] != ["someone-else"]
    assert after["phasezero-code"] == ["stale-model"]


def test_apply_never_syncs_opencode_catalog_without_account_bound_grant(
    fake, config, sandbox, monkeypatch, transaction_gate_for_legacy_tests,
):
    _fake, base = fake
    client = _client_for(fake, base)
    # opencode.json present with stale model list
    opencode_path = rm.opencode_config_path()
    opencode_path.parent.mkdir(parents=True, exist_ok=True)
    opencode_path.write_text(
        json.dumps({"model": "9router/Default",
                    "provider": {"9router": {"models": {"Default": {"name": "Default"}}}}}),
        encoding="utf-8",
    )
    # combo set known via env fixture (avoids shelling out to 9router-manager)
    combo_names = ["Default", "claude-Combo_Cleude", "phasezero-code",
                   "phasezero-analysis", "phasezero-plan"]
    monkeypatch.setenv("PZ_OPENCODE_ROUTER_COMBOS_JSON", json.dumps({"combos": combo_names}))

    before = opencode_path.read_bytes()
    result = rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    catalog = result["opencodeCatalog"]
    assert catalog["skipped"] is True
    assert catalog["updated"] is False
    assert catalog.get("blockedReason") == "connection-grant-not-enforceable", catalog
    assert opencode_path.read_bytes() == before
    manifest = json.loads(Path(result["manifest"]).read_text(encoding="utf-8"))
    assert manifest["opencodeCatalogBefore"] is None


def test_rollback_leaves_opencode_catalog_unchanged_when_sync_was_blocked(
    fake, config, sandbox, monkeypatch, transaction_gate_for_legacy_tests,
):
    _fake, base = fake
    client = _client_for(fake, base)
    opencode_path = rm.opencode_config_path()
    opencode_path.parent.mkdir(parents=True, exist_ok=True)
    before_bytes = b'{"model":"9router/Default","provider":{"9router":{"models":{"Default":{"name":"Default"}}}}}\n'
    opencode_path.write_bytes(before_bytes)
    monkeypatch.setenv("PZ_OPENCODE_ROUTER_COMBOS_JSON",
                       json.dumps({"combos": ["Default", "phasezero-code", "phasezero-analysis", "phasezero-plan"]}))

    result = rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    assert result["opencodeCatalog"].get("blockedReason") == "connection-grant-not-enforceable", result["opencodeCatalog"]
    assert opencode_path.read_bytes() == before_bytes
    rb = rm.rollback(client, result["manifest"], force=True)
    assert rb["opencodeCatalogRestored"] is False
    assert opencode_path.read_bytes() == before_bytes


def test_apply_skips_opencode_sync_when_config_absent(fake, config, sandbox, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    result = rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    assert result["opencodeCatalog"]["skipped"] is True
    assert result["opencodeCatalog"]["reason"] == "opencode.json absent"


def test_chain_override_applies_manual_order(fake, config, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    override = [
        {"model_id": "cx/gpt-5.6-terra", "provider": "cx", "fit": 0, "quality": 0, "quota": 0,
         "quota_state": "override", "quota_confidence": 0, "reliability": 0, "cost": 0,
         "latency": 0, "score": 1.0, "justifications": ["manual"], "chain_position": 1},
    ]
    result = rm.apply_plan(client, config, "code", "balanced", assume_yes=True, override=override)
    assert result["chain"] == ["cx/gpt-5.6-terra"]


# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------

def test_output_redacts_accounts_and_errors(fake):
    _fake, base = fake
    inv = _fresh_inventory(_client_for(fake, base))
    dump = json.dumps(inv)
    assert "person@example.com" not in dump
    assert "test-api-key" not in dump
    claude = next(c for c in inv["connections"] if c["id"] == "conn-claude")
    assert claude["name"] == "<redacted>"
    assert "lastError" not in claude
    assert "429" in json.dumps(claude["status"]["reason"])  # classified, not raw


def test_state_and_manifest_redacted(fake, config, sandbox, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    state = rm.load_state()
    assert state.get("secretsRedacted") is True
    assert "person@example.com" not in json.dumps(state)
    manifest = json.loads(sorted((rm.ops_root()).glob("*/manifest.json"))[-1].read_text())
    assert manifest.get("secretsRedacted") is True
    assert "test-api-key" not in json.dumps(manifest)


def test_file_permissions_private(fake, config, sandbox, transaction_gate_for_legacy_tests):
    _fake, base = fake
    client = _client_for(fake, base)
    rm.apply_plan(client, config, "code", "balanced", assume_yes=True)
    assert (rm.state_dir().stat().st_mode & 0o777) == 0o700
    assert (rm.state_path().stat().st_mode & 0o777) == 0o600
    for manifest in (rm.ops_root()).glob("*/manifest.json"):
        assert (manifest.stat().st_mode & 0o777) == 0o600


# ---------------------------------------------------------------------------
# Plans and clients
# ---------------------------------------------------------------------------

def test_plan_claude_and_opencode_route_only(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    inv = _fresh_inventory(client)
    reco = rm.recommend(client, config, inv, "code", "balanced")
    chain = rm.recommendation_chain(reco)
    assert chain
    env = rm.child_env(client)
    assert env["ANTHROPIC_BASE_URL"] == base + "/v1"
    assert env["ANTHROPIC_AUTH_TOKEN"] == API_KEY
    assert env["OPENAI_BASE_URL"] == base + "/v1"
    assert "ANTHROPIC_API_KEY" not in env


def test_bonsai_never_in_router(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    inv = _fresh_inventory(client)
    assert not any(c["provider"] == "bonsai" for c in inv["connections"])
    ver = rm.verify(client, config)
    assert ver["bonsaiIsolated"] is True
    managed = rm.MANAGED_COMBOS
    assert all("bonsai" not in name for name in managed)


def test_verify_healthy_and_plan_match(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    ver = rm.verify(client, config)
    assert ver["verdict"] == "healthy"
    assert ver["userCombosPreserved"] is True
    assert ver["secretsRedacted"] is True


def test_verify_live_probe(fake, config):
    _fake, base = fake
    client = _client_for(fake, base)
    ver = rm.verify(client, config, live=True)
    assert ver["liveModels"] is True


# ---------------------------------------------------------------------------
# CLI end-to-end (subprocess, isolated env)
# ---------------------------------------------------------------------------

def _run_cli(sandbox, fake, *args, env_extra=None):
    tmp, env_file = sandbox
    _fake, base = fake
    env = dict(os.environ)
    env.update({
        "HOME": str(tmp / "home"),
        "XDG_CONFIG_HOME": str(tmp / "config"),
        "XDG_DATA_HOME": str(tmp / "data"),
        "PHASEZERO_9ROUTER_ENV": str(env_file),
        "PZ_9ROUTER_DATA_DIR": str(tmp / "r9data"),
        "PZ_9ROUTER_BASE_URL": base,
    })
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [sys.executable, str(ROOT / "linux" / "ai" / "routing_manager.py"), *args],
        capture_output=True, text=True, env=env, timeout=60)
    return proc


def test_pz_dispatch_routing_status(sandbox, fake):
    """`pz ai routing ...` must forward to routing_manager.py verbatim."""
    tmp, env_file = sandbox
    _fake, base = fake
    env = dict(os.environ)
    env.update({
        "HOME": str(tmp / "home"),
        "XDG_CONFIG_HOME": str(tmp / "config"),
        "XDG_DATA_HOME": str(tmp / "data"),
        "PHASEZERO_9ROUTER_ENV": str(env_file),
        "PZ_9ROUTER_DATA_DIR": str(tmp / "r9data"),
        "PZ_9ROUTER_BASE_URL": base,
        "PZ_WORKSPACE_ROOT": str(tmp / "workspace"),
    })
    proc = subprocess.run(
        [str(ROOT / "linux" / "pz"), "ai", "routing", "status", "--json"],
        capture_output=True, text=True, env=env, timeout=60)
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["health"] is True
    assert len(data["models"]) == 12


def test_cli_status_and_inventory(sandbox, fake):
    proc = _run_cli(sandbox, fake, "status", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["health"] is True
    assert data["secretsRedacted"] is True
    assert "person@example.com" not in proc.stdout

    proc = _run_cli(sandbox, fake, "inventory", "--refresh-quota", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    states = {c["quotaState"] for c in data["connections"]}
    assert {"known", "unknown", "unavailable"} <= states


def test_cli_recommend_all_policies(sandbox, fake):
    for task in ("code", "analysis", "plan"):
        for policy in ("quality", "balanced", "save-quota", "privacy"):
            proc = _run_cli(sandbox, fake, "recommend", "--task", task,
                            "--policy", policy, "--refresh", "--json")
            assert proc.returncode == 0, proc.stderr
            data = json.loads(proc.stdout)
            assert data["task"] == task and data["policy"] == policy
            assert data["secretsRedacted"] is True


def test_cli_apply_dry_run_no_trace(sandbox, fake):
    proc = _run_cli(sandbox, fake, "apply", "--task", "code", "--dry-run")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["dryRun"] is True
    assert not (sandbox[0] / "data").exists()
    assert not (sandbox[0] / "config").exists()


def test_cli_apply_blocks_global_routes_until_grants_bind_each_request(sandbox, fake):
    fake_obj, _base = fake
    combos_before = [dict(combo) for combo in fake_obj.combos]
    proc = _run_cli(sandbox, fake, "apply", "--task", "code", "--yes")
    assert proc.returncode == 2, proc.stderr
    data = json.loads(proc.stdout)
    assert data["status"] == "blocked"
    assert data["blockedReason"] == "connection-grant-not-enforceable"
    assert data["applied"] is False
    assert fake_obj.combos == combos_before
    assert not (sandbox[0] / "data").exists()
    assert not (sandbox[0] / "config").exists()


def test_cli_verify(sandbox, fake):
    proc = _run_cli(sandbox, fake, "verify", "--live")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["verdict"] == "healthy"


def test_cli_plan_accepts_json_flag(sandbox, fake):
    proc = _run_cli(sandbox, fake, "plan", "--task", "code", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["task"] == "code"
    assert data["chain"][0] == "cx/gpt-5.6-sol"


def test_cli_status_cached_before_any_state(sandbox, fake):
    proc = _run_cli(sandbox, fake, "status", "--cached")
    assert proc.returncode == 1
    data = json.loads(proc.stdout)
    assert data["cached"] is False


def test_status_reports_provider_availability_and_redacts_errors(sandbox, fake):
    # AISR-014: health stayed true with most providers down, and lastError /
    # connectionName leaked upstream bodies and the account e-mail.
    RM = rm

    assert RM.provider_availability({}) == {"state": "down", "ready": 0, "unavailable": 0, "total": 0}
    mixed = {"a": {"state": "ready"}, "b": {"state": "unavailable"}, "c": {"state": "unknown"}}
    assert RM.provider_availability(mixed)["state"] == "degraded"
    assert RM.provider_availability({"a": {"state": "unavailable"}})["state"] == "down"
    assert RM.provider_availability({"a": {"state": "cooldown"}})["state"] == "ok"

    redacted = RM.redact({"connectionName": "someone@example.com", "lastError": "[401]: raw body",
                          "errorMessage": "raw", "nested": [{"apiKey": "sk-1"}]})
    assert redacted["connectionName"] == "<email>"
    assert redacted["lastError"] == "<redacted>"
    assert redacted["errorMessage"] == "<redacted>"
    assert redacted["nested"][0]["apiKey"] == "<redacted>"

    proc = _run_cli(sandbox, fake, "status", "--json")
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["health"] is True
    assert data["providerAvailability"]["state"] in ("ok", "degraded", "down")
    assert data["providerAvailability"]["total"] == len(data["connections"])
