from __future__ import annotations

import datetime as dt
import json
import urllib.error
from pathlib import Path

import pytest

from linux.ai import quota_meter as qm

NOW = dt.datetime(2026, 10, 31, 12, 0, tzinfo=dt.timezone.utc)


def rollout(home: Path, limits: dict, name: str = "rollout-a.jsonl") -> None:
    folder = home / "sessions/2026/10/31"
    folder.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps({"timestamp": "2026-10-31T11:00:00Z", "type": "event_msg",
                         "payload": {"type": "token_count", "rate_limits": limits}})]
    (folder / name).write_text("\n".join(lines) + "\n")


def codex_limits(primary=None, secondary=None):
    return {"limit_id": "codex", "primary": primary, "secondary": secondary, "plan_type": "plus"}


@pytest.fixture
def env(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    return {"HOME": str(home), "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"), "XDG_DATA_HOME": str(home / ".local/share")}


def test_codex_meter_is_regressive_and_uses_the_tightest_window(env):
    home = Path(env["HOME"]) / ".codex"
    reset_week = int((NOW + dt.timedelta(days=3)).timestamp())
    reset_5h = int((NOW + dt.timedelta(hours=2)).timestamp())
    rollout(home, codex_limits({"used_percent": 30.0, "window_minutes": 300, "resets_at": reset_5h},
                               {"used_percent": 75.0, "window_minutes": 10080,
                                "resets_at": reset_week}))
    # A premium record without windows must not hide the codex one.
    rollout(home, {"limit_id": "premium", "primary": None, "secondary": None}, "rollout-b.jsonl")

    meters = qm.codex_meters(env, NOW)

    main = next(item for item in meters if item["id"] == "codex:current")
    assert main["remaining"] == 25 and main["color"] == "#2563eb" and main["plan"] == "Plus"
    assert {w["name"]: w["remaining"] for w in main["windows"]} == {"5 horas": 70, "semanal": 25}
    assert main["resetsAt"].startswith("2026-11-03")


def test_expired_window_requires_new_observation(env):
    home = Path(env["HOME"]) / ".codex"
    past = int((NOW - dt.timedelta(minutes=5)).timestamp())
    rollout(home, codex_limits({"used_percent": 100.0, "window_minutes": 300, "resets_at": past}))
    item = next(m for m in qm.codex_meters(env, NOW) if m["id"] == "codex:current")
    assert item["remaining"] is None and item["freshness"] == "expired"
    assert "observação vencida" in qm.describe(item, NOW)
    rollout(home, codex_limits({"used_percent": 5, "resets_at": int((NOW + dt.timedelta(hours=2)).timestamp())}))
    assert qm.codex_meters(env, NOW)[0]["remaining"] == 95


def test_claude_meter_reads_usage_without_leaking_the_token(env):
    config = Path(env["HOME"]) / ".claude"
    config.mkdir()
    (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": "secret-token", "expiresAt": 9_999_999_999_000, "subscriptionType": "pro"}}))
    seen = {}

    def fetch(url, headers):
        if url == qm.CLAUDE_PROFILE_URL:
            return {"organization": {"organization_type": "claude_pro"}}
        seen.update(url=url, auth=headers["Authorization"])
        return {"five_hour": {"utilization": 40.0, "resets_at": "2026-10-31T15:00:00+00:00"},
                "seven_day": {"utilization": 90.0, "resets_at": "2026-11-02T03:00:00+00:00"}}

    item = qm.claude_meter(env, NOW, fetch, use_cache=False)

    assert seen["url"] == qm.CLAUDE_USAGE_URL and seen["auth"] == "Bearer secret-token"
    assert item["remaining"] == 10 and item["plan"] == "Pro" and item["error"] is None
    assert "secret-token" not in json.dumps(item)
    assert "secret-token" not in qm.cache_file(env).read_text()
    assert qm.cache_file(env).stat().st_mode & 0o777 == 0o600


def test_claude_http_failure_is_reported_not_guessed(env):
    config = Path(env["HOME"]) / ".claude"
    config.mkdir()
    (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": "t", "expiresAt": 9_999_999_999_000}}))

    def fetch(url, headers):
        raise urllib.error.HTTPError(url, 401, "no", {}, None)

    item = qm.claude_meter(env, NOW, fetch, use_cache=False)
    assert item["remaining"] is None and "401" in item["error"]


def test_grok_shows_only_configured_renewal(env):
    grok = Path(env["HOME"]) / ".grok"
    grok.mkdir()
    (grok / "auth.json").write_text("{}")
    assert qm.grok_meter(env, NOW)["resetsAt"] is None

    qm.set_renewal(env, "grok", 31)
    item = qm.grok_meter(env, NOW)
    assert item["remaining"] is None and "não expõe" in item["error"]
    assert qm.parse_time(item["resetsAt"]) > NOW
    with pytest.raises(ValueError):
        qm.set_renewal(env, "grok", 0)


def test_next_monthly_clamps_short_months():
    feb = dt.datetime(2027, 2, 10, tzinfo=dt.timezone.utc)
    assert qm.next_monthly(31, feb).day in (28, 29)


def test_countdown_text():
    assert qm.countdown(None, NOW) == "renovação desconhecida"
    assert qm.countdown((NOW - dt.timedelta(seconds=1)).isoformat(), NOW) == "reset passado; aguardando nova observação"
    assert "em 2h 30min" in qm.countdown((NOW + dt.timedelta(hours=2, minutes=30)).isoformat(), NOW)
    assert "em 3d 0h" in qm.countdown((NOW + dt.timedelta(days=3)).isoformat(), NOW)


def test_autostart_install_and_remove_are_managed(env):
    result = qm.install(env)
    entry = Path(result["autostart"])
    assert "quota_meter.py tray" in entry.read_text()
    assert qm.remove(env)["removed"] is True and not entry.exists()
    entry.write_text("[Desktop Entry]\nName=user own\n")
    assert qm.remove(env)["removed"] is False and entry.exists()


def test_tray_icon_renders(env):
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication
    QApplication.instance() or QApplication([])
    for value in (100, 42, 5, None):
        icon = qm.render_icon({"color": "#15803d", "remaining": value})
        assert not icon.isNull()


def fake_id_token(auth: dict) -> str:
    import base64
    body = base64.urlsafe_b64encode(json.dumps({"https://api.openai.com/auth": auth}).encode())
    return "e30." + body.decode().rstrip("=") + ".sig"


def test_level_bands_follow_the_requested_colours():
    assert [qm.level(v) for v in (100, 61, 60, 21, 20, 1, 0, None)] == [
        "green", "green", "yellow", "yellow", "red", "red", "red", None]


def test_codex_meter_reports_plan_and_paid_until(env):
    home = Path(env["HOME"]) / ".codex"
    rollout(home, codex_limits({"used_percent": 50.0, "window_minutes": 300,
                                "resets_at": int((NOW + dt.timedelta(hours=1)).timestamp())}))
    (home / "auth.json").write_text(json.dumps({"tokens": {"id_token": fake_id_token({
        "chatgpt_plan_type": "pro", "chatgpt_subscription_active_until": "2026-11-16T16:38:59+00:00"})}}))
    item = next(m for m in qm.codex_meters(env, NOW) if m["id"] == "codex:current")
    assert item["plan"] == "Pro" and item["level"] == "yellow"
    assert item["subscriptionUntil"] == "2026-11-16T16:38:59+00:00"
    text = qm.describe(item, NOW)
    assert "plano Pro" in text and "assinatura paga até 16/11/2026" in text and "🟡" in text
    assert "id_token" not in json.dumps(item) and "e30." not in json.dumps(item)


def test_codex_web_meter_counts_web_turns_and_never_invents_a_limit(env):
    root = Path(env["XDG_DATA_HOME"]) / "phasezero/chatgpt-web"
    home = root / "codex-home"
    folder = home / "sessions/2026/10/31"
    folder.mkdir(parents=True)
    (home / "config.toml").write_text("")
    (root / "state.json").write_text(json.dumps({"schemaVersion": 1, "optIn": {"at": "x"}}))
    turns = [("2026-10-31T11:00:00Z", "chatgpt-web/gpt-6-sol"),
             ("2026-10-31T01:00:00Z", "chatgpt-web/gpt-6-sol"),
             ("2026-10-31T11:30:00Z", "gpt-6.1-sol")]
    (folder / "rollout-w.jsonl").write_text("".join(
        json.dumps({"timestamp": t, "type": "turn_context", "payload": {"model": m}}) + "\n"
        for t, m in turns))
    meters = qm.web_meters(env, NOW)
    assert len(meters) == 1
    item = meters[0]
    assert item["remaining"] is None and item["webTurns"] == {"3h": 1, "24h": 2}
    assert "não informa" in item["error"]


def test_claude_plan_and_estimated_renewal(env):
    config = Path(env["HOME"]) / ".claude"
    config.mkdir()
    (config / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
        "accessToken": "t", "expiresAt": 9_999_999_999_000, "subscriptionType": "pro"}}))

    def fetch(url, headers):
        if url == qm.CLAUDE_PROFILE_URL:
            return {"organization": {"organization_type": "claude_max",
                                     "subscription_status": "active",
                                     "subscription_created_at": "2026-03-29T14:47:50Z"}}
        return {"seven_day": {"utilization": 10.0, "resets_at": "2026-11-02T03:00:00+00:00"}}

    item = qm.claude_meter(env, NOW, fetch, use_cache=False)
    assert item["plan"] == "Max" and item["level"] == "green"
    assert item["subscriptionEstimated"] is True
    assert item["subscriptionUntil"].startswith("2026-11-29")
    assert "renova (estimado) 29/11/2026" in qm.describe(item, NOW)


def credential(env, token, **metadata):
    path = Path(env['HOME']) / '.claude/.credentials.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps({'claudeAiOauth': {'accessToken': token,
                    'expiresAt': 9_999_999_999_000, **metadata}}))
    return path


def test_claude_account_cache_rotation_org_logout_and_same_account(env):
    path = credential(env, 'fixture-A', organizationUuid='org-A')
    calls = []

    def fetch(url, headers):
        calls.append(url)
        is_a = headers['Authorization'].endswith('fixture-A')
        if url == qm.CLAUDE_PROFILE_URL:
            return {'organization': {'organization_type': 'max' if is_a else 'pro'}}
        return {'five_hour': {'utilization': 10 if is_a else 95,
                             'resets_at': (NOW + dt.timedelta(hours=2)).isoformat()}}

    assert qm.claude_meter(env, NOW, fetch)['remaining'] == 90
    assert qm.claude_meter(env, NOW, fetch)['plan'] == 'Max'
    assert len(calls) == 2
    credential(env, 'fixture-B', organizationUuid='org-B')
    b = qm.claude_meter(env, NOW, fetch)
    assert b['remaining'] == 5 and b['plan'] == 'Pro' and len(calls) == 4
    credential(env, 'fixture-B', organizationUuid='org-C')
    qm.claude_meter(env, NOW, fetch)
    assert len(calls) == 6
    for cache in qm.cache_file(env).parent.glob('quota-meter-claude*.json'):
        assert 'fixture-' not in cache.read_text()
    path.unlink()
    assert qm.claude_meter(env, NOW, fetch) is None
    assert not qm.cache_file(env).exists()


@pytest.mark.parametrize('failure', ['expired', 'network'])
def test_claude_cache_never_masks_expiry_or_failed_refresh(env, failure):
    credential(env, 'fixture-A')

    def fetch(url, headers):
        return ({'organization': {'organization_type': 'max'}} if url == qm.CLAUDE_PROFILE_URL
                else {'five_hour': {'utilization': 10, 'resets_at': (NOW + dt.timedelta(hours=2)).isoformat()}})

    qm.claude_meter(env, NOW, fetch)
    if failure == 'expired':
        credential(env, 'fixture-A', expiresAt=int((NOW - dt.timedelta(seconds=1)).timestamp()*1000))
        later = NOW
    else:
        later = NOW + dt.timedelta(seconds=qm.CLAUDE_CACHE_SECONDS + 1)

    def unavailable(*args):
        if failure == 'expired':
            pytest.fail('expired credential must not query network')
        raise OSError('simulated offline')

    result = qm.claude_meter(env, later, unavailable)
    assert result['remaining'] is None and result['error']
    assert result.get('plan') is None and not qm.cache_file(env).exists()


def test_expired_window_invalidates_aggregate_even_with_fresh_weekly_window():
    item = qm.meter('x', 'x', 'codex', '#fff', [
        qm.window('5h', 95, (NOW-dt.timedelta(days=2)).isoformat(), NOW),
        qm.window('week', 10, (NOW+dt.timedelta(days=1)).isoformat(), NOW)])
    assert item['remaining'] is None and item['level'] is None


def test_profile_failure_drops_old_plan_and_org_metadata_invalidates_cache(env):
    credential(env, 'fixture')
    assert qm.claude_profile(env, 'fixture', NOW, lambda *_: {
        'organization': {'organization_type': 'max'}}, True)['plan'] == 'Max'
    account = Path(env['HOME']) / '.claude.json'
    account.write_text(json.dumps({'oauthAccount': {'organizationUuid': 'new-org'}}))
    calls = []

    def fail(*args):
        calls.append(1)
        raise OSError('offline')

    assert qm.claude_profile(env, 'fixture', NOW, fail, True) == {}
    assert calls == [1]
    assert not qm.cache_file(env).with_name('quota-meter-claude-profile.json').exists()
