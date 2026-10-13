#!/usr/bin/env python3
"""Homelab web dashboard: HTTPS, local users, session+CSRF. No docker.sock, no --yes."""
from __future__ import annotations

import hashlib
import html
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

SCHEMA = "1"
DEFAULT_PORT = 17443
SESSION_TTL_SEC = 4 * 3600
LOGIN_CSRF_TTL_SEC = 15 * 60
RATE_WINDOW_SEC = 60
AUTH_FAIL_MAX = 5
CMD_TIMEOUT_SEC = 30
COOKIE = "pzhl_session"
WEAK_PASSWORDS = frozenset(
    {
        "password",
        "password123",
        "12345678",
        "123456789012",
        "qwertyuiop",
        "homelab",
        "phasezero",
        "admin",
        "admin123456",
        "letmein",
        "passw0rd",
        "changeme",
        "correcthorsebatterystaple",
    }
)

Invoker = Callable[[list[str]], tuple[int, str, str]]


def _systemctl(*args: str) -> tuple[int, str]:
    # PZ-AUD-015 seam: user-scope systemd only, monkeypatched in tests.
    try:
        proc = subprocess.run(
            ["systemctl", "--user", *args],
            capture_output=True, text=True, timeout=30, shell=False, check=False,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)


def _loginctl(*args: str) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["loginctl", *args],
            capture_output=True, text=True, timeout=30, shell=False, check=False,
        )
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)


def _probe_https(host: str, port: int, timeout: float = 2.0) -> bool:
    import http.client

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        conn = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
        conn.request("GET", "/login")
        resp = conn.getresponse()
        conn.close()
        return resp.status < 500
    except (OSError, ssl.SSLError, http.client.HTTPException):
        return False


def _state_dir() -> Path:
    override = os.environ.get("PZ_HOMELAB_WEB_STATE")
    if override:
        return Path(override)
    xdg = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(xdg) / "phasezero" / "homelab-web"


def _hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _now() -> float:
    return time.time()


def _atomic_write(path: Path, data: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(data, encoding="utf-8")
    os.chmod(tmp, mode)
    tmp.replace(path)


def _safe_arg(value: str) -> bool:
    if not value or len(value) > 256:
        return False
    if any(ch in value for ch in " \t\n;|&$`<>(){}[]\\\"'"):
        return False
    return True


def password_reason(name: str, password: str) -> str | None:
    if len(password) < 12:
        return "password too short (min 12)"
    if password.lower() == name.lower():
        return "password must not match username"
    if password.lower() in WEAK_PASSWORDS:
        return "password too common"
    classes = 0
    if any(c.islower() for c in password):
        classes += 1
    if any(c.isupper() for c in password):
        classes += 1
    if any(c.isdigit() for c in password):
        classes += 1
    if any(not c.isalnum() for c in password):
        classes += 1
    if classes < 2 and len(password) < 16:
        return "password needs mixed classes or 16+ chars"
    return None


def _hash_password(password: str) -> str:
    try:
        from argon2 import PasswordHasher

        return PasswordHasher().hash(password)
    except ImportError:
        salt = secrets.token_bytes(16)
        dk = hashlib.scrypt(
            password.encode("utf-8"),
            salt=salt,
            n=2**14,
            r=8,
            p=1,
            dklen=32,
        )
        return f"scrypt$16384$8$1${salt.hex()}${dk.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    if not stored or not password:
        return False
    if stored.startswith("$argon2"):
        try:
            from argon2 import PasswordHasher

            PasswordHasher().verify(stored, password)
            return True
        except Exception:
            return False
    if stored.startswith("scrypt$"):
        try:
            _kind, n_s, r_s, p_s, salt_hex, dk_hex = stored.split("$", 5)
            n, r, p = int(n_s), int(r_s), int(p_s)
            salt = bytes.fromhex(salt_hex)
            expected = bytes.fromhex(dk_hex)
            dk = hashlib.scrypt(
                password.encode("utf-8"),
                salt=salt,
                n=n,
                r=r,
                p=p,
                dklen=len(expected),
            )
            return secrets.compare_digest(dk, expected)
        except (ValueError, TypeError):
            return False
    return False


def confirmation_phrase(source: str) -> str:
    return f"RESTAURAR {Path(source).name}"


class HomelabWeb:
    def __init__(
        self,
        state_dir: Path | None = None,
        pz_bin: str | None = None,
        invoker: Invoker | None = None,
        bind: str = "127.0.0.1",
        port: int = DEFAULT_PORT,
    ) -> None:
        self.state_dir = state_dir or _state_dir()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.state_dir, 0o700)
        self.pz_bin = pz_bin or os.environ.get(
            "PZ_HOMELAB_PZ_BIN",
            str(Path(__file__).resolve().parents[2] / "linux" / "pz"),
        )
        self.invoker = invoker or self._default_invoker
        requested = os.environ.get("PZ_HOMELAB_WEB_BIND", bind)
        self.bind = self.resolve_bind(requested)
        self.port = int(os.environ.get("PZ_HOMELAB_WEB_PORT", str(port)))
        self._auth_fails: dict[str, list[float]] = {}

    def _path(self, name: str) -> Path:
        return self.state_dir / name

    def _load_json(self, name: str, default: dict) -> dict:
        path = self._path(name)
        if not path.is_file():
            return dict(default)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return dict(default)
        return data if isinstance(data, dict) else dict(default)

    def _save_json(self, name: str, data: dict) -> None:
        _atomic_write(self._path(name), json.dumps(data, indent=2) + "\n")

    def audit(self, action: str, result: str, peer: str = "") -> None:
        line = json.dumps(
            {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "action": action,
                "result": result,
                "peer": peer,
            },
            separators=(",", ":"),
        )
        log = self._path("audit.log")
        with log.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
        os.chmod(log, 0o600)

    def resolve_bind(self, requested: str) -> str:
        cfg = self._load_json("config.json", {})
        lan = bool(cfg.get("lanBind"))
        want = (requested or "127.0.0.1").strip()
        if want in {"0.0.0.0", "::", "[::]"} and not lan:
            return "127.0.0.1"
        return want or "127.0.0.1"

    def set_lan_bind(self, enabled: bool) -> None:
        cfg = self._load_json("config.json", {"schemaVersion": SCHEMA})
        cfg["lanBind"] = bool(enabled)
        cfg["schemaVersion"] = SCHEMA
        self._save_json("config.json", cfg)
        self.bind = self.resolve_bind(os.environ.get("PZ_HOMELAB_WEB_BIND", self.bind))

    def users(self) -> list[dict]:
        data = self._load_json("users.json", {"schemaVersion": SCHEMA, "users": []})
        items = data.get("users") or []
        return [u for u in items if isinstance(u, dict)]

    def add_user(self, name: str, password: str) -> dict[str, Any]:
        name = (name or "").strip()
        if not name or not name.replace("-", "").replace("_", "").isalnum():
            return {"ok": False, "error": "invalid username", "code": 400}
        reason = password_reason(name, password)
        if reason:
            self.audit("user.add", "denied-weak")
            return {"ok": False, "error": reason, "code": 400}
        items = self.users()
        if any(u.get("name") == name for u in items):
            return {"ok": False, "error": "user exists", "code": 409}
        items.append(
            {
                "name": name,
                "hash": _hash_password(password),
                "createdAt": _now(),
            }
        )
        self._save_json("users.json", {"schemaVersion": SCHEMA, "users": items})
        self.audit("user.add", "ok")
        return {"ok": True, "user": name, "schemaVersion": SCHEMA}

    def remove_user(self, name: str) -> dict[str, Any]:
        items = [u for u in self.users() if u.get("name") != name]
        self._save_json("users.json", {"schemaVersion": SCHEMA, "users": items})
        self.audit("user.remove", "ok")
        return {"ok": True, "user": name, "schemaVersion": SCHEMA}

    def set_password(self, name: str, password: str) -> dict[str, Any]:
        reason = password_reason(name, password)
        if reason:
            self.audit("user.password", "denied-weak")
            return {"ok": False, "error": reason, "code": 400}
        items = self.users()
        found = False
        for user in items:
            if user.get("name") == name:
                user["hash"] = _hash_password(password)
                found = True
        if not found:
            return {"ok": False, "error": "unknown user", "code": 404}
        self._save_json("users.json", {"schemaVersion": SCHEMA, "users": items})
        self.audit("user.password", "ok")
        return {"ok": True, "user": name, "schemaVersion": SCHEMA}

    def issue_login_csrf(self) -> str:
        token = secrets.token_urlsafe(24)
        self._save_json(
            "login-csrf.json",
            {
                "schemaVersion": SCHEMA,
                "tokenHash": _hash(token),
                "expiresAt": _now() + LOGIN_CSRF_TTL_SEC,
            },
        )
        return token

    def consume_login_csrf(self, token: str) -> bool:
        rec = self._load_json("login-csrf.json", {})
        if not rec or _now() > float(rec.get("expiresAt") or 0):
            return False
        if _hash(token or "") != rec.get("tokenHash"):
            return False
        rec["expiresAt"] = 0
        self._save_json("login-csrf.json", rec)
        return True

    def authenticate(self, name: str, password: str, peer: str = "") -> str | None:
        items = self.users()
        if not items:
            self.audit("login", "denied-no-users", peer)
            return None
        for user in items:
            if user.get("name") == name and _verify_password(password, str(user.get("hash") or "")):
                sid = secrets.token_urlsafe(32)
                csrf = secrets.token_urlsafe(24)
                sessions = self._load_json(
                    "sessions.json", {"schemaVersion": SCHEMA, "sessions": []}
                )
                sessions.setdefault("sessions", []).append(
                    {
                        "idHash": _hash(sid),
                        "user": name,
                        "csrf": csrf,
                        "createdAt": _now(),
                        "expiresAt": _now() + SESSION_TTL_SEC,
                    }
                )
                self._save_json("sessions.json", sessions)
                self.audit("login", "ok", peer)
                return sid
        self.audit("login", "denied-credentials", peer)
        return None

    def session_record(self, sid: str | None) -> dict | None:
        if not sid:
            return None
        digest = _hash(sid)
        now = _now()
        sessions = self._load_json("sessions.json", {"sessions": []})
        for item in sessions.get("sessions") or []:
            if item.get("idHash") == digest and now <= float(item.get("expiresAt") or 0):
                return item
        return None

    def csrf_for(self, sid: str | None) -> str | None:
        rec = self.session_record(sid)
        if not rec:
            return None
        return str(rec.get("csrf") or "") or None

    def logout(self, sid: str | None, peer: str = "") -> bool:
        if not sid:
            return False
        digest = _hash(sid)
        sessions = self._load_json("sessions.json", {"sessions": []})
        items = list(sessions.get("sessions") or [])
        kept = [s for s in items if s.get("idHash") != digest]
        sessions["sessions"] = kept
        self._save_json("sessions.json", sessions)
        self.audit("logout", "ok" if len(kept) != len(items) else "noop", peer)
        return len(kept) != len(items)

    def rate_limited(self, peer: str) -> bool:
        now = _now()
        hits = [t for t in self._auth_fails.get(peer, []) if now - t < RATE_WINDOW_SEC]
        hits.append(now)
        self._auth_fails[peer] = hits
        return len(hits) > AUTH_FAIL_MAX

    def ensure_tls_cert(self) -> tuple[Path, Path]:
        cert = self._path("cert.pem")
        key = self._path("key.pem")
        if cert.is_file() and key.is_file():
            return cert, key
        openssl = shutil.which("openssl")
        if not openssl:
            raise RuntimeError("openssl missing; cannot mint TLS cert")
        subprocess.run(
            [
                openssl, "req", "-x509", "-newkey", "rsa:2048", "-sha256",
                "-days", "365", "-nodes",
                "-keyout", str(key), "-out", str(cert),
                "-subj", "/CN=phasezero-homelab",
            ],
            check=True,
            capture_output=True,
            text=True,
            shell=False,
        )
        os.chmod(cert, 0o600)
        os.chmod(key, 0o600)
        return cert, key

    def write_user_unit(self) -> Path:
        python = sys.executable or "/usr/bin/python3"
        script = str(Path(__file__).resolve())
        body = (
            "[Unit]\n"
            "Description=PhaseZero Homelab web dashboard (user)\n"
            "Documentation=file:docs/adr/0004-homelab-web-dashboard.md\n"
            "After=network-online.target\n"
            "\n"
            "[Service]\n"
            "Type=simple\n"
            f"ExecStart={python} {script} serve\n"
            f"Environment=PZ_HOMELAB_WEB_STATE={self.state_dir}\n"
            "Restart=on-failure\n"
            "RestartSec=3\n"
            "NoNewPrivileges=true\n"
            "PrivateTmp=true\n"
            "\n"
            "[Install]\n"
            "WantedBy=default.target\n"
        )
        template = self._path("phasezero-homelab-web.service")
        _atomic_write(template, body, 0o644)
        # PZ-AUD-015: enable --now needs the unit on the user bus path.
        unit_dir = os.environ.get("PZ_HOMELAB_WEB_UNIT_DIR")
        if unit_dir:
            dest_dir = Path(unit_dir)
        else:
            xdg = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
            dest_dir = Path(xdg) / "systemd" / "user"
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / "phasezero-homelab-web.service"
        _atomic_write(dest, body, 0o644)
        return dest

    def dashboard_url(self) -> str:
        host = "127.0.0.1" if self.bind in {"0.0.0.0", "::", "[::]"} else self.bind
        return f"https://{host}:{self.port}/"

    def status(self) -> dict[str, Any]:
        rc, _ = _systemctl("is-active", "--quiet", "phasezero-homelab-web.service")
        return {
            "schemaVersion": SCHEMA,
            "tool": "homelab-web",
            "bind": self.bind,
            "port": self.port,
            "url": self.dashboard_url(),
            "users": len(self.users()),
            "unitActive": rc == 0,
            "lanBind": bool(self._load_json("config.json", {}).get("lanBind")),
        }

    def start(self, unit_name: str = "phasezero-homelab-web.service") -> dict[str, Any]:
        # PZ-AUD-015: daemon-reload + enable --now + active proof.
        _systemctl("daemon-reload")
        rc, out = _systemctl("enable", "--now", unit_name)
        if rc != 0:
            return {"started": False, "detail": (out.strip() or "systemctl enable failed")[:300]}
        for _ in range(10):
            rc, _ = _systemctl("is-active", "--quiet", unit_name)
            if rc == 0:
                return {"started": True, "detail": "unit active"}
            time.sleep(1)
        return {"started": False, "detail": "unit not active after enable"}

    def ensure_linger(self) -> dict[str, Any]:
        user = os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        rc, out = _loginctl("show-user", user, "-p", "Linger") if user else (127, "no user")
        if rc == 0 and "Linger=yes" in out:
            return {"active": True, "detail": "linger already on"}
        rc2, out2 = _loginctl("enable-linger", user) if user else (127, "no user")
        if rc2 == 0:
            return {"active": True, "detail": "linger enabled"}
        return {
            "active": False,
            "detail": ((out2.strip() or out.strip() or "linger not granted")[:300]),
            "nextAction": "run once with privilege: loginctl enable-linger $USER (else the dashboard stops at logout)",
        }

    def enable(self) -> dict[str, Any]:
        # PZ-AUD-015: enable provisions AND starts; the first account is
        # still created by the operator over a protected channel, guided
        # by nextAction — never auto-created with a default password.
        self.ensure_tls_cert()
        unit = self.write_user_unit()
        started = self.start()
        linger = self.ensure_linger()
        https = _probe_https("127.0.0.1", self.port) if started["started"] else False
        users = len(self.users())
        ok = bool(started["started"] and https)
        if users == 0:
            next_action = (
                None if not ok else
                "create the first account now: pz server homelab web user add <name> --password-file PATH"
            )
        else:
            next_action = None if ok else "check startDetail, then open the dashboard URL"
        return {
            **self.status(),
            "action": "enable",
            "ok": ok,
            "unitPath": str(unit),
            "systemdStarted": bool(started["started"]),
            "startDetail": started["detail"],
            "linger": linger,
            "httpsReachable": https,
            "nextAction": next_action,
        }

    def _default_invoker(self, argv: list[str]) -> tuple[int, str, str]:
        proc = subprocess.run(
            [self.pz_bin, *argv],
            capture_output=True,
            text=True,
            timeout=CMD_TIMEOUT_SEC,
            shell=False,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def run_command(self, name: str, args: dict[str, str] | None, peer: str = "") -> dict[str, Any]:
        allow = {
            "status": ["server", "homelab", "status", "--json"],
            "apps.list": ["server", "homelab", "apps", "list", "--json"],
            "apps.enable": ["server", "homelab", "apps", "enable", "{app}", "--json"],
            "apps.disable": ["server", "homelab", "apps", "disable", "{app}", "--json"],
            "backup": ["server", "homelab", "backup", "--json"],
            "logs": ["server", "homelab", "logs", "--json"],
            "restore.plan": ["server", "homelab", "restore", "--source", "{source}", "--plan"],
            "restore.apply": [
                "server",
                "homelab",
                "restore",
                "--source",
                "{source}",
                "--confirm-file",
                "{confirmFile}",
            ],
        }
        if name not in allow:
            self.audit(name, "denied-allowlist", peer)
            return {"ok": False, "error": "command not in allowlist", "code": 403}
        incoming = dict(args or {})
        if name.startswith("restore") and incoming.get("yes"):
            self.audit(name, "denied-yes", peer)
            return {"ok": False, "error": "restore --yes is forbidden", "code": 403}
        if name == "restore.apply":
            source = incoming.get("source") or ""
            confirm = incoming.get("confirm") or ""
            if not source or confirm != confirmation_phrase(source):
                self.audit(name, "denied-confirm", peer)
                return {"ok": False, "error": "confirmation required", "code": 403}
            phrase = confirmation_phrase(source)
            confirm_path = self._path(f"confirm-{Path(source).name}.txt")
            _atomic_write(confirm_path, phrase + "\n")
            incoming["confirmFile"] = str(confirm_path)
        template = list(allow[name])
        argv: list[str] = []
        for part in template:
            if part.startswith("{") and part.endswith("}"):
                key = part[1:-1]
                value = incoming.get(key, "")
                if not value or (key != "confirmFile" and not _safe_arg(value)):
                    if key == "confirmFile" and value:
                        argv.append(value)
                        continue
                    self.audit(name, "denied-arg", peer)
                    return {"ok": False, "error": f"invalid argument: {key}", "code": 400}
                argv.append(value)
            else:
                argv.append(part)
        if "--yes" in argv:
            self.audit(name, "denied-yes", peer)
            return {"ok": False, "error": "restore --yes is forbidden", "code": 403}
        rc, stdout, stderr = self.invoker(argv)
        self.audit(name, "ok" if rc == 0 else "pz-error", peer)
        payload: Any = None
        try:
            payload = json.loads(stdout) if stdout.strip().startswith("{") else None
        except json.JSONDecodeError:
            payload = None
        return {
            "ok": rc == 0,
            "code": 200 if rc == 0 else 502,
            "rc": rc,
            "payload": payload,
            "error": None if rc == 0 else (stderr.strip().splitlines() or ["pz failed"])[-1],
        }


def _json_bytes(payload: dict) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


class WebHTTPServer(ThreadingHTTPServer):
    web: HomelabWeb


def _handler_for(web: HomelabWeb):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt: str, *args: Any) -> None:
            return

        def _peer(self) -> str:
            return self.client_address[0] if self.client_address else "unknown"

        def _read_body(self) -> dict:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 8192:
                return {}
            raw = self.rfile.read(length)
            ctype = (self.headers.get("Content-Type") or "").lower()
            if "json" in ctype:
                try:
                    data = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return {}
                return data if isinstance(data, dict) else {}
            qs = parse_qs(raw.decode("utf-8", "replace"), keep_blank_values=True)
            return {k: v[-1] for k, v in qs.items()}

        def _sid(self) -> str | None:
            raw = self.headers.get("Cookie") or ""
            jar = SimpleCookie()
            try:
                jar.load(raw)
            except (ValueError, KeyError):
                return None
            morsel = jar.get(COOKIE)
            if not morsel:
                return None
            value = morsel.value.strip()
            return value or None

        def _security_headers(self) -> None:
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'self'; frame-ancestors 'none'",
            )
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")

        def _send(
            self,
            code: int,
            payload: dict | None = None,
            body: bytes | None = None,
            content_type: str = "application/json",
            session_id: str | None = None,
            clear_session: bool = False,
        ) -> None:
            if body is None:
                body = _json_bytes(payload or {})
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self._security_headers()
            if session_id:
                self.send_header(
                    "Set-Cookie",
                    f"{COOKIE}={session_id}; Path=/; Max-Age={SESSION_TTL_SEC}; "
                    "Secure; HttpOnly; SameSite=Strict",
                )
            if clear_session:
                self.send_header(
                    "Set-Cookie",
                    f"{COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict",
                )
            self.end_headers()
            self.wfile.write(body)

        def _login_html(self, csrf: str, message: str = "") -> bytes:
            note = html.escape(message)
            token = html.escape(csrf)
            return (
                "<!DOCTYPE html><html lang=\"pt-BR\"><head>"
                "<meta charset=\"utf-8\"><title>Homelab</title>"
                "<meta http-equiv=\"Content-Security-Policy\" "
                "content=\"default-src 'self'; frame-ancestors 'none'\">"
                "</head><body>"
                f"<p>{note}</p>"
                "<form method=\"post\" action=\"/login\">"
                f"<input type=\"hidden\" name=\"csrf\" value=\"{token}\">"
                "<input name=\"user\" autocomplete=\"username\">"
                "<input name=\"password\" type=\"password\" autocomplete=\"current-password\">"
                "<button type=\"submit\">Entrar</button></form>"
                "<p>Primeira conta nasce só no CLI: pz server homelab web user add</p>"
                "</body></html>"
            ).encode("utf-8")

        def do_GET(self) -> None:  # noqa: N802
            path = urlparse(self.path).path
            accept = (self.headers.get("Accept") or "").lower()
            if path in {"/login", "/"}:
                sid = self._sid()
                rec = web.session_record(sid)
                if rec and path == "/":
                    csrf = html.escape(str(rec.get("csrf") or ""))
                    user = html.escape(str(rec.get("user") or ""))
                    page = (
                        "<!DOCTYPE html><html lang=\"pt-BR\"><head>"
                        "<meta charset=\"utf-8\"><title>Homelab</title>"
                        "<meta http-equiv=\"Content-Security-Policy\" "
                        "content=\"default-src 'self'; frame-ancestors 'none'\">"
                        "</head><body>"
                        f"<p>Homelab · {user}</p>"
                        f"<form method=\"post\" action=\"/logout\">"
                        f"<input type=\"hidden\" name=\"csrf\" value=\"{csrf}\">"
                        "<button type=\"submit\">Sair</button></form>"
                        "</body></html>"
                    ).encode("utf-8")
                    self._send(200, body=page, content_type="text/html; charset=utf-8")
                    return
                csrf = web.issue_login_csrf()
                users_exist = bool(web.users())
                msg = (
                    ""
                    if users_exist
                    else "Nenhum utilizador. Bootstrap só via CLI/Player."
                )
                if "application/json" in accept:
                    self._send(
                        200,
                        {
                            "ok": True,
                            "csrf": csrf,
                            "usersExist": users_exist,
                            "signup": False,
                        },
                    )
                    return
                self._send(
                    200,
                    body=self._login_html(csrf, msg),
                    content_type="text/html; charset=utf-8",
                )
                return
            if path == "/api/status":
                rec = web.session_record(self._sid())
                if not rec:
                    self._send(403, {"ok": False, "error": "missing session"})
                    return
                result = web.run_command("status", {}, self._peer())
                self._send(int(result.get("code") or 200), {"ok": True, **web.status(), "payload": result.get("payload")})
                return
            self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            peer = self._peer()
            path = urlparse(self.path).path
            body = self._read_body()
            if path == "/signup":
                web.audit("signup", "denied-bootstrap", peer)
                self._send(403, {"ok": False, "error": "signup disabled; bootstrap via CLI"})
                return
            if path == "/login":
                if web.rate_limited(peer):
                    self._send(429, {"ok": False, "error": "rate limited"})
                    return
                csrf = str(body.get("csrf") or "")
                if not web.consume_login_csrf(csrf):
                    self._send(403, {"ok": False, "error": "csrf required"})
                    return
                if not web.users():
                    self._send(403, {"ok": False, "error": "no users; bootstrap via CLI"})
                    return
                name = str(body.get("user") or "")
                password = str(body.get("password") or "")
                sid = web.authenticate(name, password, peer)
                if not sid:
                    self._send(401, {"ok": False, "error": "unauthorized"})
                    return
                rec = web.session_record(sid)
                self._send(
                    200,
                    {
                        "ok": True,
                        "user": name,
                        "csrf": rec.get("csrf") if rec else None,
                    },
                    session_id=sid,
                )
                return
            rec = web.session_record(self._sid())
            if not rec:
                self._send(403, {"ok": False, "error": "missing session"})
                return
            csrf = str(body.get("csrf") or self.headers.get("X-CSRF-Token") or "")
            if not csrf or csrf != rec.get("csrf"):
                self._send(403, {"ok": False, "error": "csrf required"})
                return
            if path == "/logout":
                web.logout(self._sid(), peer)
                self._send(200, {"ok": True}, clear_session=True)
                return
            mapping = {
                "/api/apps/enable": ("apps.enable", "app"),
                "/api/apps/disable": ("apps.disable", "app"),
                "/api/backup": ("backup", None),
                "/api/logs": ("logs", None),
                "/api/restore/plan": ("restore.plan", "source"),
                "/api/restore/apply": ("restore.apply", "source"),
            }
            if path not in mapping:
                self._send(404, {"ok": False, "error": "not found"})
                return
            name, key = mapping[path]
            args = {k: str(v) for k, v in body.items() if k != "csrf"}
            if key and key not in args:
                args[key] = str(body.get(key) or "")
            result = web.run_command(name, args, peer)
            self._send(int(result.get("code") or 400), result)

    return Handler


def serve(web: HomelabWeb, tls: bool = True) -> ThreadingHTTPServer:
    httpd = WebHTTPServer((web.bind, web.port), _handler_for(web))
    httpd.web = web
    web.port = int(httpd.server_address[1])
    if tls:
        cert, key = web.ensure_tls_cert()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert), str(key))
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    return httpd


def _read_password_file(args: list[str]) -> str:
    if "--password-file" not in args:
        return ""
    idx = args.index("--password-file")
    path = args[idx + 1] if idx + 1 < len(args) else ""
    if not path:
        return ""
    try:
        return Path(path).read_text(encoding="utf-8").rstrip("\n")
    except OSError:
        return ""


def _cli(argv: list[str]) -> int:
    args = [a for a in argv if a != "--json"]
    action = args[0] if args else "status"
    web = HomelabWeb()
    if action == "status":
        print(json.dumps(web.status(), separators=(",", ":")))
        return 0
    if action == "enable":
        payload = web.enable()
        print(json.dumps(payload, separators=(",", ":")))
        return 0
    if action == "disable":
        unit = web._path("phasezero-homelab-web.service")
        if unit.exists():
            unit.unlink()
        print(json.dumps({"schemaVersion": SCHEMA, "action": "disable", "ok": True}))
        return 0
    if action == "user":
        sub = args[1] if len(args) > 1 else ""
        name = args[2] if len(args) > 2 else ""
        if sub == "add":
            password = _read_password_file(args)
            result = web.add_user(name, password)
        elif sub == "remove":
            result = web.remove_user(name)
        elif sub == "password":
            password = _read_password_file(args)
            result = web.set_password(name, password)
        else:
            print("usage: homelab_web.py user (add|remove|password) <name> [--password-file PATH]", file=sys.stderr)
            return 2
        print(json.dumps(result, separators=(",", ":")))
        return 0 if result.get("ok") else 1
    if action == "lan-bind":
        enabled = args[1] if len(args) > 1 else "off"
        web.set_lan_bind(enabled in {"on", "true", "1"})
        print(json.dumps({**web.status(), "action": "lan-bind"}))
        return 0
    if action == "serve":
        web.ensure_tls_cert()
        httpd = serve(web, tls=True)
        httpd.serve_forever()
        return 0
    print(
        "usage: homelab_web.py (status|enable|disable|user|lan-bind|serve) [--json]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
