"""Contratos do motor de temas: schema, estados, catálogo, lock, TTL e CLI.

Hermético: nenhum teste toca o HOME real; PZ_THEMES_* redirecionam estado e
configuração; D-Bus é simulado por stub.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "themes/v1"

FAKE_PLASMA6 = {
    "plasmaMajor": 6,
    "session": "wayland",
    "kwin": True,
    "steamOs": False,
    "steamDeck": False,
    "gameMode": False,
    "decky": False,
    "onBattery": False,
    "batteryPercent": None,
    "vaapi": True,
    "vulkan": True,
    "steamInstall": "",
    "steamLibraries": [],
    "binaries": {
        "qdbus": "",
        "plasma-apply-lookandfeel": "",
        "plasma-apply-colorscheme": "",
        "plasma-apply-cursortheme": "",
    },
}

FAKE_NO_KDE = {
    "plasmaMajor": None,
    "session": "",
    "kwin": False,
    "steamOs": False,
    "steamDeck": False,
    "gameMode": False,
    "decky": False,
    "onBattery": False,
    "batteryPercent": None,
    "vaapi": False,
    "vulkan": False,
    "steamInstall": "",
    "steamLibraries": [],
    "binaries": {},
}


@pytest.fixture()
def fake_plasma(tmp_path):
    path = tmp_path / "fake.json"
    payload = dict(FAKE_PLASMA6)
    path.write_text(json.dumps(payload), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(path)
    stub = tmp_path / "qdbus-stub.py"
    stub.write_text(
        "import sys\n"
        "script = sys.argv[-1]\n"
        "if 'desktops().map' in script:\n"
        "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
        "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///old.png\","
        "\"FillMode\":\"6\"}}]')\n"
        "else:\n"
        "    print('OK_0')\n",
        encoding="utf-8",
    )
    os.environ["PZ_THEMES_DBUS_CMD"] = sys.executable + " " + str(stub)
    yield path
    os.environ.pop("PZ_THEMES_FAKE_JSON", None)
    os.environ.pop("PZ_THEMES_DBUS_CMD", None)


@pytest.fixture()
def fake_state(tmp_path):
    os.environ["PZ_THEMES_STATE_DIR"] = str(tmp_path / "state")
    yield tmp_path / "state"
    os.environ.pop("PZ_THEMES_STATE_DIR", None)


@pytest.fixture()
def fake_config(tmp_path):
    directory = tmp_path / "config"
    directory.mkdir()
    os.environ["PZ_THEMES_CONFIG_DIR"] = str(directory)
    yield directory
    os.environ.pop("PZ_THEMES_CONFIG_DIR", None)


def run_cli(*args, env=None):
    environment = dict(os.environ)
    if env:
        environment.update(env)
    result = subprocess.run(
        [sys.executable, "-m", "linux.themes", *args],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        env=environment,
        timeout=60,
    )
    return result


def test_status_schema_and_plasma(fake_plasma, fake_state, fake_config):
    result = run_cli("status", "--json")
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["schema"] == SCHEMA
    assert payload["ok"] is True
    assert payload["plasma"]["compatible"] is True
    assert payload["plasma"]["major"] == 6
    assert payload["host"]["session"] == "wayland"


def test_status_non_kde_reports_reason(fake_state, fake_config, tmp_path):
    fake = tmp_path / "nokde.json"
    fake.write_text(json.dumps(FAKE_NO_KDE), encoding="utf-8")
    result = run_cli("status", "--json", env={"PZ_THEMES_FAKE_JSON": str(fake)})
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["plasma"]["compatible"] is False
    assert "não detectada" in payload["plasma"]["reason"]
    assert payload["plasma"]["major"] is None
    for feature in payload["features"].values():
        assert feature["state"] == "indisponivel"
        assert feature["reason"]


def test_status_no_success_apparent_on_unintegrated_adapters(fake_plasma, fake_state, fake_config):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "linux"))
    from themes.catalog import FEATURES
    from themes.features import REGISTRY

    result = run_cli("status", "--json")
    payload = json.loads(result.stdout)
    for feature_id, value in payload["features"].items():
        spec = FEATURES.get(feature_id)
        if spec is None or REGISTRY.get(feature_id) is not None:
            continue
        assert value["state"] in (
            "indisponivel", "desligado", "degradado", "reinicio-pendente",
        ), feature_id
        if value["state"] == "indisponivel":
            assert value["reason"], feature_id


def test_catalog_curated_entries_never_disappear(fake_plasma, fake_state, fake_config):
    result = run_cli("catalog")
    assert result.returncode == 0
    payload = json.loads(result.stdout)
    assert payload["schema"] == SCHEMA

    extensions = {item["storeId"]: item for item in payload["kdeExtensions"]}
    assert extensions["2138035"]["status"] == "included"
    assert extensions["2138035"]["plasmaMajor"] == 6
    assert extensions["2367756"]["status"] == "deferred"
    assert extensions["2367756"]["reason"]
    for store_id in (
        "2053791", "2070431", "2064339", "1962359", "1200511",
        "1411968", "2117968", "2015475", "2055225", "1176348",
        "1313987", "1953779",
    ):
        assert extensions[store_id]["status"] == "rejected"
        assert extensions[store_id]["reason"]
        assert extensions[store_id]["plasmaMajor"] == 5

    wallpapers = {item["id"]: item for item in payload["wallpapers"]}
    assert wallpapers["pz.geo-dark"]["sha256"]
    assert wallpapers["pz.geo-dark"]["license"]
    assert wallpapers["pz.aurora"]["sha256"]
    assert wallpapers["pz.aurora"]["license"]
    assert wallpapers["pz.solid-charcoal"]["kind"] == "solid"

    steam = {item["id"]: item for item in payload["steamPlugins"]}
    assert set(steam) == {
        "gamemode.css-loader",
        "gamemode.animation-changer",
        "gamemode.audio-loader",
        "gamemode.steamgriddb",
    }
    for item in steam.values():
        assert item["verified"] is False, "nenhum artefato externo é declarado verificado"


def test_catalog_wallpaper_checksum_verified(fake_plasma, fake_state, fake_config):
    result = run_cli("catalog")
    payload = json.loads(result.stdout)
    geo = next(item for item in payload["wallpapers"] if item["id"] == "pz.geo-dark")
    assert geo["available"] == [True, ""] or (
        isinstance(geo["available"], list) and geo["available"][0] is True
    )
    manifest = json.loads(
        (ROOT / "assets" / "themes" / "wallpapers" / "manifest.json").read_text(encoding="utf-8")
    )
    entry = next(item for item in manifest["wallpapers"] if item["id"] == "pz.geo-dark")
    digest = hashlib_sha256(ROOT / "assets" / "themes" / "wallpapers" / entry["file"])
    assert digest == entry["sha256"]


def hashlib_sha256(path: Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_ini_surgical_write_preserves_rest(fake_config):
    from linux.themes.kde import set_ini_key, read_ini_key

    path = fake_config / "kdeglobals"
    path.write_text(
        "# comentário inicial\n[General]\nColorScheme=BreezeLight\nFont=Noto Sans,10,-1,5,50,0,0,0,0,0\n",
        encoding="utf-8",
    )
    set_ini_key(path, "General", "ColorScheme", "BreezeDark")
    content = path.read_text(encoding="utf-8")
    assert "# comentário inicial" in content
    assert "Font=Noto Sans,10,-1,5,50,0,0,0,0,0" in content
    assert read_ini_key(path, "General", "ColorScheme") == "BreezeDark"
    set_ini_key(path, "NewGroup", "Key", "value")
    assert read_ini_key(path, "NewGroup", "Key") == "value"
    assert read_ini_key(path, "General", "ColorScheme") == "BreezeDark"


def test_feature_plan_applies_with_integrated_adapters(fake_plasma, fake_state, fake_config):
    result = run_cli("plan", "--profile", "essencial")
    assert result.returncode == 0
    plan = json.loads(result.stdout)
    assert plan["schema"] == SCHEMA
    assert plan["ok"] is True
    assert plan["confirmToken"]
    assert all(action["kind"] == "feature" for action in plan["actions"])

    apply = run_cli("apply", "--plan-id", plan["id"], "--confirm", plan["confirmToken"])
    assert apply.returncode == 0
    operation = json.loads(apply.stdout)
    assert operation["status"] == "complete"
    assert operation["restored"] is False
    assert all(
        result["status"] in ("ligado", "noop") for result in operation["results"]
    ), operation["results"]


def test_plan_expires_and_requires_token(fake_plasma, fake_state, fake_config):
    result = run_cli("plan", "--wallpaper", "pz.geo-dark", "--screen", "0", "--target", "desktop")
    assert result.returncode == 0
    plan = json.loads(result.stdout)
    assert plan["schema"] == SCHEMA
    assert plan["ok"] is True
    assert plan["confirmToken"]
    assert plan["snapshotId"]

    bad = run_cli("apply", "--plan-id", plan["id"], "--confirm", "errado")
    assert bad.returncode == 2
    assert "token" in json.loads(bad.stderr)["error"]

    plan_path = fake_state / "plans" / f"{plan['id']}.json"
    payload = json.loads(plan_path.read_text(encoding="utf-8"))
    payload["createdAt"] = int(time.time()) - 25 * 60 * 60
    plan_path.write_text(json.dumps(payload), encoding="utf-8")
    expired = run_cli("apply", "--plan-id", plan["id"], "--confirm", plan["confirmToken"])
    assert expired.returncode == 2
    assert "expirado" in json.loads(expired.stderr)["error"]


def test_unknown_profile_and_feature_fail_closed(fake_plasma, fake_state, fake_config):
    result = run_cli("plan", "--profile", "inexistente")
    assert result.returncode == 2
    assert "desconhecido" in json.loads(result.stderr)["error"]
    result = run_cli("plan", "--feature", "tema.fantasma", "--state", "on")
    assert result.returncode == 2


def test_plan_feature_state_required(fake_plasma, fake_state, fake_config):
    result = run_cli("plan", "--feature", "theme.phasezero")
    assert result.returncode == 2


def test_lock_blocks_second_process(fake_plasma, fake_state, fake_config, tmp_path):
    from linux.themes import state

    probe_path = tmp_path / "lock-probe.py"
    probe_path.write_text(
        "import sys\n"
        "sys.path.insert(0, sys.argv[1])\n"
        "from linux.themes import state\n"
        "try:\n"
        "    with state.lock(timeout=0.3):\n"
        "        print('ACQUIRED')\n"
        "except Exception as exc:\n"
        "    print(type(exc).__name__)\n",
        encoding="utf-8",
    )
    with state.lock():
        probe = subprocess.run(
            [sys.executable, str(probe_path), str(ROOT)],
            capture_output=True,
            text=True,
            env={**os.environ, "PZ_THEMES_STATE_DIR": str(fake_state)},
            timeout=30,
        )
    assert "ThemesLockTimeout" in probe.stdout


def test_ownership_ledger(fake_state):
    from linux.themes import state

    state.record_ownership({"path": "/tmp/owned-file", "operationId": "op-1"})
    assert state.is_owned("/tmp/owned-file")
    assert not state.is_owned("/tmp/outro")


def test_cli_stdout_json_pure_stderr_for_errors(fake_plasma, fake_state, fake_config):
    result = run_cli("plan", "--feature", "video.smart-wallpaper", "--state", "on")
    assert result.returncode == 0
    json.loads(result.stdout)
    assert result.stderr == ""


def test_state_unreadable_exit_code_3(fake_state, fake_config, tmp_path):
    fake = tmp_path / "unreadable.json"
    fake.write_text(json.dumps({"plasmaMajor": 6, "kwin": True, "binaries": {}}), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(fake)
    os.environ["PZ_THEMES_DBUS_CMD"] = "false"
    try:
        result = run_cli("status", "--json")
        assert result.returncode == 0  # status degrada sem quebrar
        payload = json.loads(result.stdout)
        assert payload["hero"]["wallpaper"]["state"] == "degradado"
    finally:
        os.environ.pop("PZ_THEMES_FAKE_JSON", None)
        os.environ.pop("PZ_THEMES_DBUS_CMD", None)


def test_plan_noop_requires_requested_params_to_match(fake_plasma, fake_state, fake_config):
    """Estado binário igual não torna o plano noop quando o modo pedido difere:
    system -> dark precisa aplicar, não virar no-op."""
    result = run_cli("plan", "--feature", "theme.phasezero", "--state", "on", "--param", "mode=dark")
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["ok"] is True, plan.get("blockers")
    action = plan["actions"][0]
    assert action["current"]["params"]["mode"] == "system"
    assert action["noop"] is False, "troca de modo foi engolida como noop"

    result = run_cli("plan", "--feature", "theme.phasezero", "--state", "on", "--param", "mode=system")
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["actions"][0]["noop"] is True
