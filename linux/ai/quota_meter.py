#!/usr/bin/env python3
"""quota_meter.py - remaining plan quota (100% -> 0%) and renewal time per AI account.

Sources, all local or first-party:
- Codex (every PhaseZero profile): the newest `rate_limits` record Codex itself
  writes into its rollout sessions. Nothing is requested from the network.
- Claude (Code CLI and Desktop share the claude.ai account): the OAuth usage
  endpoint Claude Code uses for `/usage`. The token is read, never refreshed,
  logged or written anywhere.
- Grok: the CLI does not expose plan limits, so only the renewal date the user
  configured is shown; the meter is reported as unavailable, never guessed.

Commands: status [--json] | tray | install | remove | set-renewal <provider> --day N
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import hashlib
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
CLAUDE_PROFILE_CACHE_SECONDS = 6 * 3600
WEB_COUNT_HOURS = (3, 24)
# Remaining-quota colour bands: >60 green, 21-60 yellow, <=20 red (0 included).
LEVEL_COLORS = {"green": "#16a34a", "yellow": "#eab308", "red": "#dc2626"}
LEVEL_MARKS = {"green": "🟢", "yellow": "🟡", "red": "🔴", None: "⚪"}
PLAN_NAMES = {"free": "Free", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
              "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu",
              "claude_pro": "Pro", "claude_max": "Max", "max": "Max", "claude_team": "Team",
              "claude_enterprise": "Enterprise"}
CLAUDE_COLOR = "#d97757"
GROK_COLOR = "#9ca3af"
CLAUDE_CACHE_SECONDS = 300
REFRESH_SECONDS = 60
ROLLOUT_SCAN_LIMIT = 40
AUTOSTART_NAME = "phasezero-quota-meter.desktop"


def env_path(env: dict[str, str], name: str, fallback: str) -> Path:
    home = Path(env.get("HOME") or Path.home())
    return Path(env.get(name) or home / fallback)


def config_file(env: dict[str, str]) -> Path:
    return env_path(env, "XDG_CONFIG_HOME", ".config") / "phasezero/quota-meter.json"


def cache_file(env: dict[str, str]) -> Path:
    return env_path(env, "XDG_CACHE_HOME", ".cache") / "phasezero/quota-meter-claude.json"


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_private(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def parse_time(value: Any) -> dt.datetime | None:
    if isinstance(value, (int, float)) and value > 0:
        return dt.datetime.fromtimestamp(value, dt.timezone.utc)
    if isinstance(value, str) and value:
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
    return None


def level(value: int | None) -> str | None:
    if value is None:
        return None
    return "green" if value > 60 else "yellow" if value > 20 else "red"


def plan_name(value: Any) -> str | None:
    if not value:
        return None
    return PLAN_NAMES.get(str(value).lower(), str(value).replace("_", " ").title())


def subscription_claims(auth_file: Path) -> dict[str, Any]:
    """Plan and paid-until dates from the ChatGPT id_token claims; the token itself is dropped."""
    data = load_json(auth_file)
    token = ((data or {}).get("tokens") or {}).get("id_token") if isinstance(data, dict) else None
    if not isinstance(token, str) or token.count(".") != 2:
        return {}
    try:
        part = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (ValueError, TypeError):
        return {}
    auth = claims.get("https://api.openai.com/auth") if isinstance(claims, dict) else None
    if not isinstance(auth, dict):
        return {}
    return {"plan": plan_name(auth.get("chatgpt_plan_type")),
            "subscriptionUntil": auth.get("chatgpt_subscription_active_until"),
            "subscriptionCheckedAt": auth.get("chatgpt_subscription_last_checked")}


def remaining(used: Any) -> int | None:
    if not isinstance(used, (int, float)):
        return None
    return max(0, min(100, round(100 - float(used))))


def window(name: str, used: Any, resets: Any, now: dt.datetime) -> dict[str, Any] | None:
    left = remaining(used)
    reset_at = parse_time(resets)
    if left is None:
        return None
    expired = bool(reset_at and reset_at <= now)
    return {"name": name, "remaining": None if expired else left,
            "observedRemaining": left, "freshness": "expired" if expired else "observed",
            "resetsAt": reset_at.isoformat() if reset_at else None,
            "resetElapsed": expired}


def meter(meter_id: str, label: str, provider: str, color: str, windows: list[dict[str, Any]],
          **extra: Any) -> dict[str, Any]:
    windows = [item for item in windows if item]
    # The tightest window is the one that blocks the next request.
    known = [item for item in windows if item["remaining"] is not None]
    expired = any(item.get("freshness") == "expired" for item in windows)
    tight = min(known, key=lambda item: item["remaining"]) if known and not expired else None
    value = tight["remaining"] if tight else None
    for item in windows:
        item["level"] = level(item["remaining"])
    return {"id": meter_id, "label": label, "provider": provider, "color": color,
            "remaining": value, "level": level(value),
            "resetsAt": tight["resetsAt"] if tight else extra.pop("resetsAt", None),
            "windows": windows, "freshness": "expired" if expired else "observed" if tight else "unknown", **extra}


# ---- Codex -----------------------------------------------------------------

def last_rate_limits(codex_home: Path) -> tuple[dict[str, Any] | None, float | None]:
    sessions = codex_home / "sessions"
    try:
        files = sorted(sessions.glob("*/*/*/rollout-*.jsonl"), key=lambda p: p.stat().st_mtime,
                       reverse=True)[:ROLLOUT_SCAN_LIMIT]
    except OSError:
        return None, None
    for path in files:
        found = None
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if '"rate_limits"' not in line or '"codex"' not in line:
                        continue
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    limits = (record.get("payload") or {}).get("rate_limits")
                    if isinstance(limits, dict) and limits.get("limit_id") == "codex" and (
                            limits.get("primary") or limits.get("secondary")):
                        found = (limits, parse_time(record.get("timestamp")))
        except OSError:
            continue
        if found:
            seen = found[1].timestamp() if found[1] else path.stat().st_mtime
            return found[0], seen
    return None, None


def codex_meters(env: dict[str, str], now: dt.datetime) -> list[dict[str, Any]]:
    try:
        from linux.ai.codex_profiles import COLORS, CodexProfiles
        profiles = CodexProfiles(env=env)
        rows = [dict(profiles._current), *(row for row in profiles.rows() if not row.get("archived"))]
    except Exception as error:  # profiles unavailable: fall back to the native home only
        rows, profiles, COLORS = [], None, {}
        home = env_path(env, "CODEX_HOME", ".codex")
        if home.is_dir():
            rows = [{"id": "current", "label": "Principal", "color": "azul", "_home": home}]
        if not rows:
            return [meter("codex:error", "Codex", "codex", "#2563eb", [], error=str(error))]
    result = []
    for row in rows:
        home = row.get("_home") or (profiles.native_home(row) if profiles else None)
        if not home or not Path(home).is_dir():
            continue
        limits, seen = last_rate_limits(Path(home))
        windows = []
        if limits:
            for key, name in (("primary", "principal"), ("secondary", "secundária")):
                item = limits.get(key)
                if isinstance(item, dict):
                    minutes = item.get("window_minutes")
                    label = {300: "5 horas", 10080: "semanal"}.get(minutes, name)
                    windows.append(window(label, item.get("used_percent"), item.get("resets_at"), now))
        claims = subscription_claims(Path(home) / "auth.json")
        result.append(meter(
            f"codex:{row['id']}", f"Codex · {row.get('label') or row['id']}", "codex",
            COLORS.get(row.get("color"), "#2563eb"), windows,
            plan=claims.get("plan") or plan_name((limits or {}).get("plan_type")),
            subscriptionUntil=claims.get("subscriptionUntil"),
            subscriptionCheckedAt=claims.get("subscriptionCheckedAt"),
            source="codex-rollout-rate-limits",
            seenAt=dt.datetime.fromtimestamp(seen, dt.timezone.utc).isoformat() if seen else None,
            error=None if limits else "sem registro de limite; use esta conta uma vez"))
    return result


# ---- Codex Web (ChatGPT Web route) -------------------------------------------

def web_turns(codex_home: Path, now: dt.datetime) -> dict[int, int]:
    """Count turns sent through the chatgpt-web model; ChatGPT Web exposes no limit."""
    counts = {hours: 0 for hours in WEB_COUNT_HOURS}
    horizon = now - dt.timedelta(hours=max(WEB_COUNT_HOURS))
    for path in (codex_home / "sessions").glob("*/*/*/rollout-*.jsonl"):
        try:
            if dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc) < horizon:
                continue
            with path.open(encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if '"turn_context"' not in line or "chatgpt-web/" not in line:
                        continue
                    try:
                        record = json.loads(line)
                    except ValueError:
                        continue
                    if not str((record.get("payload") or {}).get("model", "")).startswith("chatgpt-web/"):
                        continue
                    stamp = parse_time(record.get("timestamp"))
                    for hours in WEB_COUNT_HOURS:
                        if stamp and now - stamp <= dt.timedelta(hours=hours):
                            counts[hours] += 1
        except OSError:
            continue
    return counts


def web_meters(env: dict[str, str], now: dt.datetime) -> list[dict[str, Any]]:
    data = env_path(env, "XDG_DATA_HOME", ".local/share")
    try:
        from linux.ai.codex_profiles import COLORS, CodexProfiles
        profiles = CodexProfiles(env=env)
        rows = [dict(profiles._current), *(row for row in profiles.rows() if not row.get("archived"))]
    except Exception:
        rows, profiles, COLORS = [dict(id="current", label="Principal", color="azul")], None, {}
    result = []
    for row in rows:
        root = (data / "phasezero/chatgpt-web" if row["id"] == "current"
                else data / "phasezero/codex" / row["id"] / "web")
        state = load_json(root / "state.json")
        home = root / "codex-home"
        if not isinstance(state, dict) or not state.get("optIn") or not (home / "config.toml").is_file():
            continue
        counts = web_turns(home, now)
        claims = subscription_claims(home / "auth.json")
        result.append(meter(
            f"codex-web:{row['id']}", f"Codex Web · {row.get('label') or row['id']}", "codex-web",
            COLORS.get(row.get("color"), "#2563eb"), [],
            plan=claims.get("plan"), subscriptionUntil=claims.get("subscriptionUntil"),
            subscriptionCheckedAt=claims.get("subscriptionCheckedAt"),
            webTurns={f"{hours}h": count for hours, count in counts.items()},
            error="o ChatGPT Web não informa o limite restante; contagem de mensagens Web enviadas: "
                  + ", ".join(f"{count} nas últimas {hours}h" for hours, count in counts.items())))
    return result


# ---- Claude ----------------------------------------------------------------

def next_anniversary(start: dt.datetime, now: dt.datetime) -> dt.datetime:
    year, month = now.year, now.month
    for _ in range(3):
        last = (dt.date(year + month // 12, month % 12 + 1, 1) - dt.timedelta(days=1)).day
        candidate = start.replace(year=year, month=month, day=min(start.day, last))
        if candidate > now:
            return candidate
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return candidate


def claude_cache_identity(env: dict[str, str], token: str) -> str:
    """Conservative scope: credential rotation, account/org metadata and config location.

    A token digest is an invalidation key, never an authentication credential.
    """
    config = Path(env.get("CLAUDE_CONFIG_DIR") or Path(env.get("HOME") or Path.home()) / ".claude")
    credentials = load_json(config / ".credentials.json")
    # Include all credential metadata so organization/account changes invalidate both caches.
    account = load_json(config.with_suffix(".json"))
    account = account.get("oauthAccount") if isinstance(account, dict) else None
    material = json.dumps([str(config.resolve()), token, credentials, account], sort_keys=True)
    return hashlib.sha256(material.encode()).hexdigest()


def clear_claude_cache(env: dict[str, str]) -> None:
    for path in (cache_file(env), cache_file(env).with_name("quota-meter-claude-profile.json")):
        path.unlink(missing_ok=True)


def claude_profile(env: dict[str, str], token: str, now: dt.datetime,
                   fetch: Callable[[str, dict[str, str]], Any] | None,
                   use_cache: bool) -> dict[str, Any]:
    path = cache_file(env).with_name("quota-meter-claude-profile.json")
    identity = claude_cache_identity(env, token)
    cached = load_json(path) if use_cache else None
    if (isinstance(cached, dict) and cached.get("identity") == identity
            and 0 <= now.timestamp() - cached.get("at", 0) < CLAUDE_PROFILE_CACHE_SECONDS):
        return cached.get("profile") or {}
    headers = {"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20",
               "User-Agent": "PhaseZero-quota-meter"}
    try:
        payload = (fetch or http_json)(CLAUDE_PROFILE_URL, headers)
    except (OSError, ValueError):
        path.unlink(missing_ok=True)
        return {}
    org = (payload or {}).get("organization") if isinstance(payload, dict) else None
    org = org if isinstance(org, dict) else {}
    profile = {"plan": plan_name(org.get("organization_type")),
               "status": org.get("subscription_status"),
               "createdAt": org.get("subscription_created_at")}
    write_private(path, {"at": now.timestamp(), "identity": identity, "profile": profile})
    return profile


def claude_meter(env: dict[str, str], now: dt.datetime,
                 fetch: Callable[[str, dict[str, str]], Any] | None = None,
                 use_cache: bool = True) -> dict[str, Any] | None:
    config_dir = Path(env.get("CLAUDE_CONFIG_DIR") or Path(env.get("HOME") or Path.home()) / ".claude")
    credentials = load_json(config_dir / ".credentials.json")
    oauth = (credentials or {}).get("claudeAiOauth") if isinstance(credentials, dict) else None
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        clear_claude_cache(env)
        return None
    expires = oauth.get("expiresAt")
    if isinstance(expires, (int, float)) and expires / 1000 <= now.timestamp():
        clear_claude_cache(env)
        return meter("claude:default", "Claude (Code + Desktop)", "claude", CLAUDE_COLOR, [],
                     error="login do Claude expirado; abra o Claude Code para renovar")
    identity = claude_cache_identity(env, oauth["accessToken"])
    plan = oauth.get("subscriptionType")
    cached = load_json(cache_file(env)) if use_cache else None
    payload = None
    if isinstance(cached, dict) and cached.get("identity") != identity:
        clear_claude_cache(env)
        cached = None
    if isinstance(cached, dict) and 0 <= now.timestamp() - cached.get("at", 0) < CLAUDE_CACHE_SECONDS:
        payload = cached.get("usage")
    error = None
    if payload is None:
        headers = {"Authorization": f"Bearer {oauth['accessToken']}",
                   "anthropic-beta": "oauth-2025-04-20", "User-Agent": "PhaseZero-quota-meter"}
        try:
            payload = (fetch or http_json)(CLAUDE_USAGE_URL, headers)
            if not isinstance(payload, dict):
                raise ValueError("invalid usage response")
            cached = {"at": now.timestamp(), "identity": identity, "usage": payload}
            write_private(cache_file(env), cached)
        except urllib.error.HTTPError as failure:
            error = f"Anthropic respondeu HTTP {failure.code}"
        except (OSError, ValueError) as failure:
            error = f"uso indisponível: {failure.__class__.__name__}"
        if error:
            clear_claude_cache(env)
            payload = None
    windows = []
    if isinstance(payload, dict):
        for key, label in (("five_hour", "5 horas"), ("seven_day", "semanal"),
                           ("seven_day_opus", "semanal Opus"), ("seven_day_sonnet", "semanal Sonnet")):
            item = payload.get(key)
            if isinstance(item, dict):
                windows.append(window(label, item.get("utilization"), item.get("resets_at"), now))
    profile = claude_profile(env, oauth["accessToken"], now, fetch, use_cache) if not error else {}
    created = parse_time(profile.get("createdAt"))
    # Anthropic exposes no paid-until date; monthly billing renews on the signup day.
    renewal = next_anniversary(created, now).isoformat() if created and profile.get(
        "status") in (None, "active") else None
    return meter("claude:default", "Claude (Code + Desktop)", "claude", CLAUDE_COLOR, windows,
                 plan=(profile.get("plan") or plan_name(plan)) if not error else None, subscriptionUntil=renewal,
                 subscriptionEstimated=bool(renewal), subscriptionStatus=profile.get("status"),
                 seenAt=dt.datetime.fromtimestamp((cached or {}).get("at", now.timestamp()), dt.timezone.utc).isoformat() if payload else None,
                 source="anthropic-oauth-usage", error=error)


def http_json(url: str, headers: dict[str, str]) -> Any:
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read(1024 * 1024))


# ---- Grok ------------------------------------------------------------------

def next_monthly(day: int, now: dt.datetime) -> dt.datetime:
    local = now.astimezone()
    year, month = local.year, local.month
    for _ in range(2):
        last = (dt.date(year + month // 12, month % 12 + 1, 1) - dt.timedelta(days=1)).day
        candidate = local.replace(year=year, month=month, day=min(day, last), hour=0, minute=0,
                                  second=0, microsecond=0)
        if candidate > local:
            return candidate
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return candidate


def grok_meter(env: dict[str, str], now: dt.datetime) -> dict[str, Any] | None:
    home = Path(env.get("HOME") or Path.home())
    if not (home / ".grok/auth.json").is_file():
        return None
    settings = (load_json(config_file(env)) or {}).get("grok") or {}
    day = settings.get("renewalDay")
    resets = next_monthly(day, now).isoformat() if isinstance(day, int) and 1 <= day <= 31 else None
    return meter("grok:default", "Grok", "grok", GROK_COLOR, [], resetsAt=resets,
                 error="o Grok não expõe o limite do plano; só a renovação configurada"
                       + ("" if resets else " (defina com `pz ai quota set-renewal grok --day N`)"))


def collect(env: dict[str, str] | None = None, now: dt.datetime | None = None,
            fetch: Callable[[str, dict[str, str]], Any] | None = None) -> list[dict[str, Any]]:
    env = dict(os.environ if env is None else env)
    now = now or dt.datetime.now(dt.timezone.utc)
    meters = codex_meters(env, now) + web_meters(env, now)
    for item in (claude_meter(env, now, fetch), grok_meter(env, now)):
        if item:
            meters.append(item)
    return meters


# ---- text ------------------------------------------------------------------

def countdown(target: str | None, now: dt.datetime) -> str:
    moment = parse_time(target)
    if not moment:
        return "renovação desconhecida"
    seconds = int((moment - now).total_seconds())
    if seconds <= 0:
        return "reset passado; aguardando nova observação"
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    span = f"{days}d {hours}h" if days else (f"{hours}h {minutes:02d}min" if hours else f"{minutes}min")
    return f"renova {moment.astimezone():%d/%m %H:%M} (em {span})"


def subscription_text(item: dict[str, Any]) -> str | None:
    parts = []
    if item.get("plan"):
        parts.append(f"plano {item['plan']}")
    until = parse_time(item.get("subscriptionUntil"))
    if until:
        word = "renova (estimado)" if item.get("subscriptionEstimated") else "assinatura paga até"
        text = f"{word} {until.astimezone():%d/%m/%Y %H:%M}"
        checked = parse_time(item.get("subscriptionCheckedAt"))
        if until < dt.datetime.now(dt.timezone.utc):
            text += (f" (dado de {checked.astimezone():%d/%m}; " if checked else " (dado antigo; ") \
                + "abra esta conta para atualizar)"
        parts.append(text)
    return " · ".join(parts) or None


def describe(item: dict[str, Any], now: dt.datetime) -> str:
    head = f"{item['remaining']}% restante" if item.get("remaining") is not None else "limite n/d"
    mark = LEVEL_MARKS[item.get("level")]
    lines = [f"{mark} {item['label']}: {head} · {countdown(item.get('resetsAt'), now)}"]
    sub = subscription_text(item)
    if sub:
        lines.append(f"  {sub}")
    if item.get("seenAt"):
        lines.append(f"  observado: {item['seenAt']}")
    if item.get("source"):
        lines.append(f"  origem: {item['source']}")
    for win in item.get("windows", []):
        lines.append(f"  {LEVEL_MARKS[win.get('level')]} {win['name']}: "
                     f"{str(win['remaining']) + '%' if win['remaining'] is not None else 'n/d (observação vencida)'} · "
                     f"{countdown(win.get('resetsAt'), now)}")
    if item.get("error"):
        lines.append(f"  ⚠ {item['error']}")
    return "\n".join(lines)


# ---- tray ------------------------------------------------------------------

def render_icon(item: dict[str, Any]):  # pragma: no cover - exercised through the tray test
    from PySide6.QtCore import QRectF, Qt
    from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPen, QPixmap
    size = 64
    pixmap = QPixmap(size, size)
    pixmap.fill(Qt.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.Antialiasing)
    color = QColor(item["color"])
    value = item.get("remaining")
    painter.setPen(QPen(QColor(128, 128, 128, 110), 7))
    ring = QRectF(5, 5, size - 10, size - 10)
    painter.drawEllipse(ring)
    if value is not None:
        band = QColor(LEVEL_COLORS[level(value)])
        painter.setPen(QPen(band, 7, Qt.SolidLine, Qt.RoundCap))
        painter.drawArc(ring, 90 * 16, int(-360 * 16 * value / 100))
    painter.setPen(Qt.NoPen)
    painter.setBrush(color)
    painter.drawEllipse(QRectF(14, 14, size - 28, size - 28))
    font = QFont()
    font.setBold(True)
    font.setPixelSize(19 if value is not None and value >= 100 else 22)
    painter.setFont(font)
    painter.setPen(QColor("#ffffff"))
    painter.drawText(pixmap.rect(), Qt.AlignCenter, "?" if value is None else str(value))
    painter.end()
    return QIcon(pixmap)


def run_tray(env: dict[str, str]) -> int:  # pragma: no cover - needs a desktop session
    from PySide6.QtCore import QTimer
    from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon
    app = QApplication.instance() or QApplication(sys.argv[:1])
    app.setApplicationName("PhaseZero Quota")
    app.setQuitOnLastWindowClosed(False)
    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("bandeja do sistema indisponível", file=sys.stderr)
        return 1
    if tray_pid(env) not in (None, os.getpid()):
        print("medidores já estão na bandeja", file=sys.stderr)
        return 0
    pid_file(env).parent.mkdir(parents=True, exist_ok=True)
    pid_file(env).write_text(str(os.getpid()))
    import signal
    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    # Let Python handle SIGTERM while the Qt loop runs.
    heartbeat = QTimer()
    heartbeat.timeout.connect(lambda: None)
    heartbeat.start(500)
    from linux.ai.quota_tray import TrayCollector
    collector = TrayCollector(env, app)
    app.aboutToQuit.connect(collector.close)
    icons: dict[str, QSystemTrayIcon] = {}

    def refresh() -> None:
        collector.refresh()

    def display(items: list[dict[str, Any]]) -> None:
        now = dt.datetime.now(dt.timezone.utc)
        seen = set()
        for item in items:
            seen.add(item["id"])
            tray = icons.get(item["id"])
            if tray is None:
                tray = QSystemTrayIcon()
                menu = QMenu()
                menu.addAction("Atualizar agora", refresh)
                menu.addSeparator()
                menu.addAction("Fechar medidores", app.quit)
                tray.setContextMenu(menu)
                tray._menu = menu  # keep a reference
                tray.activated.connect(lambda _reason, t=tray: t.showMessage(
                    "PhaseZero", t.toolTip(), QSystemTrayIcon.Information, 8000))
                icons[item["id"]] = tray
            tray.setIcon(render_icon(item))
            tray.setToolTip(describe(item, now))
            tray.show()
        for key in [key for key in icons if key not in seen]:
            icons.pop(key).hide()

    def failed(message: str) -> None:
        for tray in icons.values():
            tray.setIcon(render_icon({"color": "#888888", "remaining": None}))
            tray.setToolTip(message)

    collector.ready.connect(display)
    collector.failed.connect(failed)
    refresh()
    timer = QTimer()
    timer.timeout.connect(refresh)
    timer.start(REFRESH_SECONDS * 1000)
    try:
        return app.exec()
    finally:
        collector.close()
        if tray_pid(env) == os.getpid():
            pid_file(env).unlink(missing_ok=True)


# ---- install ---------------------------------------------------------------

def pid_file(env: dict[str, str]) -> Path:
    runtime = env.get("XDG_RUNTIME_DIR")
    base = Path(runtime) if runtime else env_path(env, "XDG_CACHE_HOME", ".cache") / "phasezero"
    return base / "phasezero-quota-meter.pid"


def tray_pid(env: dict[str, str]) -> int | None:
    """PID of the running tray, only when /proc confirms it is this script."""
    try:
        pid = int(pid_file(env).read_text().strip())
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    except (OSError, ValueError):
        return None
    return pid if b"tray" in cmdline and any(part.endswith(b"quota_meter.py") for part in cmdline) else None


def tray_state(env: dict[str, str]) -> dict[str, Any]:
    target = autostart_path(env)
    managed = target.is_file() and "X-PhaseZero-Managed=quota-meter" in target.read_text()
    return {"autostart": managed, "running": tray_pid(env) is not None}


def start_tray(env: dict[str, str]) -> bool:
    if tray_pid(env) is not None or not (env.get("WAYLAND_DISPLAY") or env.get("DISPLAY")):
        return False
    import subprocess
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "tray"], env=env,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    return True


def stop_tray(env: dict[str, str]) -> bool:
    import signal
    pid = tray_pid(env)
    if pid is None:
        return False
    os.kill(pid, signal.SIGTERM)
    for _ in range(30):
        if tray_pid(env) is None:
            break
        time.sleep(0.1)
    pid_file(env).unlink(missing_ok=True)
    return True


def autostart_path(env: dict[str, str]) -> Path:
    return env_path(env, "XDG_CONFIG_HOME", ".config") / "autostart" / AUTOSTART_NAME


def install(env: dict[str, str]) -> dict[str, Any]:
    target = autostart_path(env)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "[Desktop Entry]\nType=Application\nName=PhaseZero medidor de franquia\n"
        "Comment=Franquia restante e renovação de Codex, Claude e Grok na bandeja\n"
        f"Exec=/usr/bin/env python3 {Path(__file__).resolve()} tray\n"
        "Icon=utilities-system-monitor\nX-GNOME-Autostart-enabled=true\n"
        "X-PhaseZero-Managed=quota-meter\n", encoding="utf-8")
    started = start_tray(env)
    return {"autostart": str(target), "installed": True, "started": started, "tray": tray_state(env)}


def remove(env: dict[str, str]) -> dict[str, Any]:
    target = autostart_path(env)
    managed = target.is_file() and "X-PhaseZero-Managed=quota-meter" in target.read_text()
    if managed:
        target.unlink()
    stopped = stop_tray(env)
    return {"autostart": str(target), "removed": managed, "stopped": stopped, "tray": tray_state(env)}


def set_renewal(env: dict[str, str], provider: str, day: int) -> dict[str, Any]:
    if not 1 <= day <= 31:
        raise ValueError("dia deve estar entre 1 e 31")
    path = config_file(env)
    data = load_json(path) if path.exists() else {}
    if not isinstance(data, dict):
        raise ValueError(f"{path} ilegível; nada alterado")
    data.setdefault(provider, {})["renewalDay"] = day
    write_private(path, data)
    return {"provider": provider, "renewalDay": day,
            "next": next_monthly(day, dt.datetime.now(dt.timezone.utc)).isoformat()}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pz ai quota", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command")
    status = sub.add_parser("status")
    status.add_argument("--json", action="store_true")
    sub.add_parser("tray")
    sub.add_parser("install")
    sub.add_parser("remove")
    renewal = sub.add_parser("set-renewal")
    renewal.add_argument("provider", choices=("grok",))
    renewal.add_argument("--day", type=int, required=True)
    args = parser.parse_args(argv)
    env = dict(os.environ)
    command = args.command or "status"
    try:
        if command == "tray":
            return run_tray(env)
        if command == "install":
            result: Any = install(env)
        elif command == "remove":
            result = remove(env)
        elif command == "set-renewal":
            result = set_renewal(env, args.provider, args.day)
        else:
            now = dt.datetime.now(dt.timezone.utc)
            items = collect(env, now)
            if not getattr(args, "json", False):
                print("\n".join(describe(item, now) for item in items))
                return 0
            result = {"schemaVersion": 1, "checkedAt": now.isoformat(), "meters": items,
                      "tray": tray_state(env)}
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
