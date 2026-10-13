from __future__ import annotations

import inspect
import json
import re
import shutil
import ssl
import threading
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPSHandler, Request, build_opener

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in __import__("sys").path:
    __import__("sys").path.insert(0, str(ROOT))

from linux.server.homelab_web import (  # noqa: E402
    HomelabWeb,
    confirmation_phrase,
    password_reason,
    serve,
)

STRONG = "correct-horse-9x"


@pytest.fixture
def web(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_WEB_STATE", str(tmp_path / "web"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    calls: list[list[str]] = []

    def invoker(argv):
        calls.append(list(argv))
        return 0, json.dumps({"schemaVersion": "1", "ok": True, "argv": argv}), ""

    boxed = HomelabWeb(
        state_dir=tmp_path / "web",
        invoker=invoker,
        bind="127.0.0.1",
        port=0,
    )
    boxed.calls = calls  # type: ignore[attr-defined]
    return boxed


def _opener(tls: bool, cert: Path | None = None):
    handlers = []
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_REQUIRED
        assert cert is not None
        ctx.load_verify_locations(cafile=str(cert))
        handlers.append(HTTPSHandler(context=ctx))
    return build_opener(*handlers)


def _session_id(cookies: list[str]) -> str:
    for item in cookies:
        if "pzhl_session=" in item:
            return item.split("pzhl_session=", 1)[1].split(";", 1)[0]
    return ""


def _login(opener, base: str, user: str = "alice", password: str = STRONG):
    req = Request(f"{base}/login", headers={"Accept": "application/json"})
    with opener.open(req, timeout=3) as resp:
        challenge = json.loads(resp.read().decode())
    csrf = challenge["csrf"]
    req = Request(
        f"{base}/login",
        data=json.dumps({"user": user, "password": password, "csrf": csrf}).encode(),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with opener.open(req, timeout=3) as resp:
        body = json.loads(resp.read().decode())
        cookies = resp.headers.get_all("Set-Cookie") or []
    return body, cookies, _session_id(cookies)


def test_bind_wan_without_lan_opt_in_stays_loopback(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_WEB_BIND", "0.0.0.0")
    boxed = HomelabWeb(
        state_dir=tmp_path / "bind",
        invoker=lambda argv: (0, "{}", ""),
        bind="0.0.0.0",
        port=0,
    )
    assert boxed.bind == "127.0.0.1"
    boxed.set_lan_bind(True)
    assert boxed.resolve_bind("0.0.0.0") == "0.0.0.0"


def test_web_bind_port_in_use_fails_closed(web, tmp_path):
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        other = HomelabWeb(
            state_dir=tmp_path / "web-other",
            invoker=lambda argv: (0, "{}", ""),
            bind="127.0.0.1",
            port=port,
        )
        with pytest.raises(OSError):
            serve(other, tls=False)
    finally:
        httpd.shutdown()


def test_weak_password_rejected(web):
    result = web.add_user("alice", "123")
    assert result["ok"] is False
    assert "short" in result["error"]
    result = web.add_user("alice", "alicealicealice")
    assert result["ok"] is False
    result = web.add_user("alice", "password123")
    assert result["ok"] is False
    assert web.users() == []
    assert password_reason("bob", STRONG) is None
    ok = web.add_user("alice", STRONG)
    assert ok["ok"] is True
    stored = web.users()[0]["hash"]
    assert stored != STRONG
    assert STRONG not in stored
    assert stored.startswith("$argon2id$") or stored.startswith("scrypt$")


def test_signup_without_users_refused(web):
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        opener = _opener(False)
        req = Request(
            f"http://127.0.0.1:{port}/signup",
            data=b'{"user":"alice","password":"correct-horse-9x"}',
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with pytest.raises(HTTPError) as err:
            opener.open(req, timeout=3)
        assert err.value.code == 403
        req = Request(f"http://127.0.0.1:{port}/login", headers={"Accept": "application/json"})
        with opener.open(req, timeout=3) as resp:
            challenge = json.loads(resp.read().decode())
        req = Request(
            f"http://127.0.0.1:{port}/login",
            data=json.dumps(
                {"user": "alice", "password": STRONG, "csrf": challenge["csrf"]}
            ).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with pytest.raises(HTTPError) as err:
            opener.open(req, timeout=3)
        assert err.value.code == 403
        body = json.loads(err.value.read().decode())
        assert "CLI" in body["error"]
    finally:
        httpd.shutdown()


def test_login_without_csrf_is_403(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        opener = _opener(False)
        req = Request(
            f"http://127.0.0.1:{port}/login",
            data=json.dumps({"user": "alice", "password": STRONG}).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with pytest.raises(HTTPError) as err:
            opener.open(req, timeout=3)
        assert err.value.code == 403
        body = json.loads(err.value.read().decode())
        assert "csrf" in body["error"]
    finally:
        httpd.shutdown()


def test_cookie_flags_secure_httponly_samesite(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        opener = _opener(False)
        _body, cookies, _sid = _login(opener, f"http://127.0.0.1:{port}")
        joined = " ".join(cookies)
        assert cookies, "login must Set-Cookie"
        assert "Secure" in joined
        assert "HttpOnly" in joined
        assert "SameSite=Strict" in joined
        assert "pzhl_session=" in joined
    finally:
        httpd.shutdown()


def test_restore_without_confirm_does_not_apply(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        base = f"http://127.0.0.1:{port}"
        opener = _opener(False)
        body, _cookies, sid = _login(opener, base)
        csrf = body["csrf"]
        req = Request(
            f"{base}/api/restore/apply",
            data=json.dumps({"source": "/tmp/bk1", "csrf": csrf}).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-CSRF-Token": csrf,
                "Cookie": f"pzhl_session={sid}",
            },
        )
        with pytest.raises(HTTPError) as err:
            opener.open(req, timeout=3)
        assert err.value.code == 403
        assert web.calls == []
        assert all("--yes" not in c for c in web.calls)
    finally:
        httpd.shutdown()


def test_restore_never_passes_yes(web):
    result = web.run_command("restore.apply", {"source": "/tmp/bk1", "yes": "1", "confirm": "x"})
    assert result["ok"] is False
    assert "yes" in result["error"]
    assert web.calls == []
    phrase = confirmation_phrase("/tmp/bk1")
    result = web.run_command("restore.apply", {"source": "/tmp/bk1", "confirm": phrase})
    assert result["ok"] is True
    assert web.calls
    assert "--yes" not in web.calls[-1]
    assert "--confirm-file" in web.calls[-1]


def test_login_action_logout(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        base = f"http://127.0.0.1:{port}"
        opener = _opener(False)
        body, _cookies, sid = _login(opener, base)
        csrf = body["csrf"]
        cookie = f"pzhl_session={sid}"
        req = Request(f"{base}/api/status", headers={"Cookie": cookie})
        with opener.open(req, timeout=3) as resp:
            status = json.loads(resp.read().decode())
        assert status["ok"] is True
        assert status["bind"] == "127.0.0.1"
        req = Request(
            f"{base}/api/apps/enable",
            data=json.dumps({"app": "vaultwarden", "csrf": csrf}).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-CSRF-Token": csrf,
                "Cookie": cookie,
            },
        )
        with opener.open(req, timeout=3) as resp:
            enabled = json.loads(resp.read().decode())
        assert enabled["ok"] is True
        req = Request(
            f"{base}/logout",
            data=json.dumps({"csrf": csrf}).encode(),
            method="POST",
            headers={"Content-Type": "application/json", "Cookie": cookie},
        )
        with opener.open(req, timeout=3) as resp:
            assert json.loads(resp.read().decode())["ok"] is True
        with pytest.raises(HTTPError) as err:
            opener.open(Request(f"{base}/api/status", headers={"Cookie": cookie}), timeout=3)
        assert err.value.code == 403
    finally:
        httpd.shutdown()


def test_hash_never_in_html_or_audit(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        opener = _opener(False)
        req = Request(f"http://127.0.0.1:{port}/login")
        with opener.open(req, timeout=3) as resp:
            page = resp.read().decode()
        stored = web.users()[0]["hash"]
        assert stored not in page
        assert STRONG not in page
        _login(opener, f"http://127.0.0.1:{port}")
        audit = (web.state_dir / "audit.log").read_text(encoding="utf-8")
        assert stored not in audit
        assert STRONG not in audit
    finally:
        httpd.shutdown()


def test_source_has_no_upnp_docker_sock_or_yes():
    src = inspect.getsource(HomelabWeb)
    assert "upnp" not in src.lower()
    assert "docker.sock" not in src
    assert "shell=False" in src
    assert "shell=True" not in src
    assert '"--yes"' not in src or "forbidden" in src


@pytest.mark.skipif(not shutil.which("openssl"), reason="openssl missing")
def test_https_login_sets_secure_cookie(web):
    web.add_user("alice", STRONG)
    cert, _key = web.ensure_tls_cert()
    httpd = serve(web, tls=True)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        opener = _opener(True, cert)
        body, cookies, _sid = _login(opener, f"https://127.0.0.1:{port}")
        assert body["ok"] is True
        joined = " ".join(cookies)
        assert "Secure" in joined
        assert "HttpOnly" in joined
        assert "SameSite=Strict" in joined
    finally:
        httpd.shutdown()


def test_mutation_without_csrf_after_login_is_403(web):
    web.add_user("alice", STRONG)
    httpd = serve(web, tls=False)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        port = httpd.server_address[1]
        base = f"http://127.0.0.1:{port}"
        opener = _opener(False)
        _body, _cookies, sid = _login(opener, base)
        req = Request(
            f"{base}/api/apps/enable",
            data=json.dumps({"app": "vaultwarden"}).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Cookie": f"pzhl_session={sid}",
            },
        )
        with pytest.raises(HTTPError) as err:
            opener.open(req, timeout=3)
        assert err.value.code == 403
    finally:
        httpd.shutdown()


def test_cli_user_add_password_file(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_WEB_STATE", str(tmp_path / "web"))
    pw = tmp_path / "pw.txt"
    pw.write_text(STRONG + "\n", encoding="utf-8")
    from linux.server import homelab_web as mod

    rc = mod._cli(["user", "add", "alice", "--password-file", str(pw), "--json"])
    assert rc == 0
    boxed = HomelabWeb(state_dir=tmp_path / "web")
    assert boxed.users()[0]["name"] == "alice"
    weak = tmp_path / "weak.txt"
    weak.write_text("123\n", encoding="utf-8")
    rc = mod._cli(["user", "add", "bob", "--password-file", str(weak), "--json"])
    assert rc != 0


def test_confirmation_phrase_binds_source():
    assert confirmation_phrase("/backups/bk1") == "RESTAURAR bk1"
    assert re.fullmatch(r"RESTAURAR [\w.-]+", confirmation_phrase("/x/y"))


def test_enable_starts_unit_and_guides_first_account(tmp_path, monkeypatch):
    """PZ-AUD-015: enable provisions AND starts; first account is guided."""
    monkeypatch.setenv("PZ_HOMELAB_WEB_STATE", str(tmp_path / "web"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_HOMELAB_WEB_UNIT_DIR", str(tmp_path / "units"))
    from linux.server import homelab_web as mod

    calls = []
    monkeypatch.setattr(mod, "_systemctl", lambda *a: (calls.append(a) or (0, "")))
    monkeypatch.setattr(mod, "_loginctl", lambda *a: (0, "Linger=yes"))
    monkeypatch.setattr(mod, "_probe_https", lambda host, port: True)
    dashboard = mod.HomelabWeb(state_dir=tmp_path / "web2", bind="127.0.0.1", port=17443)
    payload = dashboard.enable()
    assert ("daemon-reload",) in calls
    assert ("enable", "--now", "phasezero-homelab-web.service") in calls
    assert payload["systemdStarted"] is True
    assert payload["httpsReachable"] is True
    assert payload["ok"] is True
    assert "user add" in (payload["nextAction"] or "")
    assert (tmp_path / "units" / "phasezero-homelab-web.service").is_file()


def test_enable_reports_failed_start_honestly(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_HOMELAB_WEB_STATE", str(tmp_path / "web"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_HOMELAB_WEB_UNIT_DIR", str(tmp_path / "units"))
    from linux.server import homelab_web as mod

    monkeypatch.setattr(mod, "_systemctl", lambda *a: (1, "no bus"))
    monkeypatch.setattr(mod, "_loginctl", lambda *a: (1, "no loginctl"))
    dashboard = mod.HomelabWeb(state_dir=tmp_path / "web3", bind="127.0.0.1", port=17443)
    payload = dashboard.enable()
    assert payload["systemdStarted"] is False
    assert payload["ok"] is False
    assert payload["linger"]["active"] is False
