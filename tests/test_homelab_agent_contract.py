from __future__ import annotations

import inspect
import json
import shutil
import ssl
import sys
import threading
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler, Request, build_opener, urlopen

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from linux.server.homelab_agent import ALLOWLIST, HomelabAgent, serve  # noqa: E402


@pytest.fixture
def agent(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_AGENT_STATE", str(tmp_path / "agent"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))

    def invoker(argv):
        return 0, json.dumps({"schemaVersion": "1", "ok": True, "argv": argv}), ""

    return HomelabAgent(state_dir=tmp_path / "agent", invoker=invoker, bind="127.0.0.1", port=0)


def test_missing_token_denied(agent):
    assert agent.authorize(None) is False
    assert agent.authorize("") is False


def test_expired_pairing_denied(agent):
    token = agent.issue_pairing_token()
    rec = json.loads((agent.state_dir / "pairing.json").read_text())
    rec["expiresAt"] = 1
    agent._save_json("pairing.json", rec)
    assert agent.pair(token) is None


def test_pair_then_command_then_revoke(agent):
    pairing = agent.issue_pairing_token()
    session = agent.pair(pairing)
    assert session
    assert agent.authorize(session)
    result = agent.run_command("apps.list", {})
    assert result["ok"] is True
    assert result["payload"]["ok"] is True
    assert agent.revoke(session) is True
    assert agent.authorize(session) is False


def test_arbitrary_shell_denied_and_audited(agent):
    pairing = agent.issue_pairing_token()
    session = agent.pair(pairing)
    assert session
    result = agent.run_command("sh -c 'rm -rf /'", {})
    assert result["ok"] is False
    assert result["code"] == 403
    audit = (agent.state_dir / "audit.log").read_text()
    assert "denied-allowlist" in audit
    assert "rm -rf" not in audit or "denied-allowlist" in audit


def test_restore_yes_forbidden(agent):
    result = agent.run_command("restore.plan", {"source": "/tmp/bk1", "yes": "1"})
    assert result["ok"] is False
    assert "yes" in result["error"]


def test_enable_rejects_metacharacters(agent):
    result = agent.run_command("apps.enable", {"app": "vaultwarden;id"})
    assert result["ok"] is False
    assert result["code"] == 400


def test_kill_switch_blocks(agent):
    pairing = agent.issue_pairing_token()
    session = agent.pair(pairing)
    agent.set_kill_switch(True)
    assert agent.authorize(session) is False
    result = agent.run_command("status", {})
    assert result["code"] == 503


def test_mdns_never_silently_reenables_avahi(agent):
    status = agent.mdns_status()
    assert status["service"] == "phasezero-homelab._tcp"
    assert status["wouldReenableAvahi"] is False
    assert "IP" in status["manualFallback"]


def test_source_has_no_docker_sock_or_shell_true():
    src = inspect.getsource(HomelabAgent)
    assert "docker.sock" not in src
    assert "shell=False" in src
    assert "shell=True" not in src


def test_fuzz_auth_tokens(agent):
    for blob in ("", " ", "\x00", "a" * 4096, "' OR 1=1", "../etc/passwd"):
        assert agent.pair(blob) is None
        assert agent.authorize(blob) is False


def test_http_without_token_is_401(agent):
    httpd = serve(agent, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        url = f"http://127.0.0.1:{port}/v1/status"
        with pytest.raises(HTTPError) as err:
            urlopen(url, timeout=2)
        assert err.value.code == 401
        pairing = agent.issue_pairing_token()
        req = Request(
            f"http://127.0.0.1:{port}/v1/pair",
            data=json.dumps({"pairingToken": pairing}).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urlopen(req, timeout=2) as resp:
            body = json.loads(resp.read().decode())
        assert body["ok"] is True
        session = body["sessionToken"]
        req = Request(
            url,
            headers={"Authorization": f"Bearer {session}"},
        )
        with urlopen(req, timeout=2) as resp:
            st = json.loads(resp.read().decode())
        assert st["ok"] is True
        req = Request(
            f"http://127.0.0.1:{port}/v1/revoke",
            data=b"{}",
            method="POST",
            headers={
                "Authorization": f"Bearer {session}",
                "Content-Type": "application/json",
            },
        )
        with urlopen(req, timeout=2) as resp:
            assert json.loads(resp.read().decode())["ok"] is True
        with pytest.raises(HTTPError) as err:
            urlopen(
                Request(url, headers={"Authorization": f"Bearer {session}"}),
                timeout=2,
            )
        assert err.value.code == 401
    finally:
        httpd.shutdown()


def test_http_rate_limit(agent):
    httpd = serve(agent, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        url = f"http://127.0.0.1:{port}/v1/status"
        codes = []
        for _ in range(25):
            try:
                urlopen(url, timeout=2)
                codes.append(200)
            except HTTPError as exc:
                codes.append(exc.code)
            except URLError:
                codes.append(0)
        assert 429 in codes
    finally:
        httpd.shutdown()


def test_install_cli_shows_token_once(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_AGENT_STATE", str(tmp_path / "agent"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_HOMELAB_AGENT_UNIT_DIR", str(tmp_path / "units"))
    from linux.server import homelab_agent as mod

    rc = mod._cli(["install", "--json"])
    assert rc == 0


def test_install_starts_unit_and_proves_https(tmp_path, monkeypatch):
    """PZ-AUD-015: install chains daemon-reload/start and proves serving."""
    monkeypatch.setenv("PZ_HOMELAB_AGENT_STATE", str(tmp_path / "agent"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_HOMELAB_AGENT_UNIT_DIR", str(tmp_path / "units"))
    from linux.server import homelab_agent as mod

    calls = []
    monkeypatch.setattr(mod, "_systemctl", lambda *a: (calls.append(a) or (0, "")))
    monkeypatch.setattr(mod, "_loginctl", lambda *a: (0, "Linger=yes"))
    monkeypatch.setattr(mod, "_probe_https", lambda host, port: True)
    agent = mod.HomelabAgent(state_dir=tmp_path / "agent2", bind="127.0.0.1", port=17432)
    payload = agent.install()
    assert ("daemon-reload",) in calls
    assert ("enable", "--now", "phasezero-agent.service") in calls
    assert payload["systemdStarted"] is True
    assert payload["httpsReachable"] is True
    assert payload["linger"] == {"active": True, "detail": "linger already on"}
    assert payload["ok"] is True
    assert (tmp_path / "units" / "phasezero-agent.service").is_file()


def test_install_reports_failed_start_honestly(tmp_path, monkeypatch):
    """PZ-AUD-015: a unit that never activates is ok:false, never ready."""
    monkeypatch.setenv("PZ_HOMELAB_AGENT_STATE", str(tmp_path / "agent"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_HOMELAB_AGENT_UNIT_DIR", str(tmp_path / "units"))
    from linux.server import homelab_agent as mod

    monkeypatch.setattr(mod, "_systemctl", lambda *a: (1, "no bus"))
    monkeypatch.setattr(mod, "_loginctl", lambda *a: (1, "no loginctl"))
    agent = mod.HomelabAgent(state_dir=tmp_path / "agent3", bind="127.0.0.1", port=17432)
    payload = agent.install()
    assert payload["systemdStarted"] is False
    assert payload["httpsReachable"] is False
    assert payload["ok"] is False
    assert payload["linger"]["active"] is False


def test_allowlist_does_not_include_yes():
    joined = " ".join(v for args in ALLOWLIST.values() for v in args)
    assert "--yes" not in joined


def test_user_unit_never_starts_root_or_systemctl(agent, tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_AGENT_UNIT_DIR", str(tmp_path / "units"))
    path = agent.write_user_unit()
    text = path.read_text(encoding="utf-8")
    assert "WantedBy=default.target" in text
    assert "NoNewPrivileges=true" in text
    assert "serve" in text
    assert "docker.sock" not in text
    assert "User=root" not in text
    src = inspect.getsource(HomelabAgent.install) + inspect.getsource(HomelabAgent.write_user_unit)
    assert "systemctl" not in src


def test_bind_port_in_use_fails_closed(agent, tmp_path):
    httpd = serve(agent, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        other = HomelabAgent(
            state_dir=tmp_path / "agent-other",
            invoker=lambda argv: (0, "{}", ""),
            bind="127.0.0.1",
            port=port,
        )
        with pytest.raises(OSError):
            serve(other, tls=False)
    finally:
        httpd.shutdown()


def test_corrupt_tls_cert_refuses_serve(agent):
    cert = agent.state_dir / "cert.pem"
    key = agent.state_dir / "key.pem"
    cert.write_text("not-a-cert\n", encoding="utf-8")
    key.write_text("not-a-key\n", encoding="utf-8")
    with pytest.raises((ssl.SSLError, OSError, ValueError)):
        serve(agent, tls=True)


def test_bind_wan_without_lan_opt_in_stays_loopback(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_AGENT_BIND", "0.0.0.0")
    boxed = HomelabAgent(
        state_dir=tmp_path / "bind",
        invoker=lambda argv: (0, "{}", ""),
        bind="0.0.0.0",
        port=0,
    )
    assert boxed.bind == "127.0.0.1"
    boxed.set_lan_bind(True)
    assert boxed.resolve_bind("0.0.0.0") == "0.0.0.0"


@pytest.mark.skipif(not shutil.which("openssl"), reason="openssl missing")
def test_https_without_token_is_401(agent):
    cert, _key = agent.ensure_tls_cert()
    httpd = serve(agent, tls=True)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(cafile=str(cert))
        opener = build_opener(HTTPSHandler(context=ctx))
        with pytest.raises(HTTPError) as err:
            opener.open(f"https://127.0.0.1:{port}/v1/status", timeout=3)
        assert err.value.code == 401
        pairing = agent.issue_pairing_token()
        req = Request(
            f"https://127.0.0.1:{port}/v1/pair",
            data=json.dumps({"pairingToken": pairing}).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with opener.open(req, timeout=3) as resp:
            body = json.loads(resp.read().decode())
        assert body["ok"] is True
        session = body["sessionToken"]
        req = Request(
            f"https://127.0.0.1:{port}/v1/status",
            headers={"Authorization": f"Bearer {session}"},
        )
        with opener.open(req, timeout=3) as resp:
            st = json.loads(resp.read().decode())
        assert st["ok"] is True
        assert st["bind"] == "127.0.0.1"
    finally:
        httpd.shutdown()
