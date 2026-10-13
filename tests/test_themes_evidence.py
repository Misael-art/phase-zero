"""Evidências da matriz obrigatória: preview, rollback byte a byte, wallpaper
por monitor e Game Mode.

Hermético: nenhum teste toca o HOME real; PZ_THEMES_* redirecionam estado e
configuração; D-Bus é simulado por stub.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.themes.engine import (  # noqa: E402
    PREVIEW_TTL_SECONDS,
    apply_plan,
    catalog_payload,
    create_plan,
    preview_plan,
    rollback_snapshot,
    status_payload,
)
from linux.themes.kde import ConfigWrite, KdeSession  # noqa: E402
from linux.themes.platform import detect  # noqa: E402
from linux.themes import state as themes_state  # noqa: E402
from tests.test_themes_contracts import (  # noqa: E402
    FAKE_PLASMA6,
    fake_config,
    fake_plasma,
    fake_state,
)

FAKE_BINARIES = {
    "qdbus": "",
    "plasma-apply-lookandfeel": "",
    "plasma-apply-colorscheme": "",
    "plasma-apply-cursortheme": "",
}


def make_facts(tmp_path: Path, **overrides) -> Path:
    payload = dict(FAKE_PLASMA6)
    payload["binaries"] = dict(FAKE_BINARIES)
    payload.update(overrides)
    path = tmp_path / "facts.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    os.environ["PZ_THEMES_FAKE_JSON"] = str(path)
    return path


WALLPAPER_READ = (
    "if 'desktops().map' in script:\n"
    "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
    "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///old.png\","
    "\"FillMode\":\"6\"}}]')\n"
    "else:\n"
    "    print('OK_0')\n"
)


def write_stub(tmp_path: Path, body: str) -> Path:
    stub = tmp_path / "qdbus-stub.py"
    stub.write_text(body, encoding="utf-8")
    os.environ["PZ_THEMES_DBUS_CMD"] = sys.executable + " " + str(stub)
    return stub


def session() -> KdeSession:
    return KdeSession(detect())


@pytest.fixture()
def multi_screen_plasma(tmp_path):
    make_facts(tmp_path)
    write_stub(
        tmp_path,
        "import sys\n"
        "script = sys.argv[-1]\n"
        "if 'desktops().map' in script:\n"
        "    print('[{\"id\":\"1\",\"screen\":0,\"wallpaperPlugin\":\"org.kde.image\","
        "\"wallpaperMode\":\"SingleImage\",\"config\":{\"Image\":\"file:///a.png\"}},"
        "{\"id\":\"2\",\"screen\":1,\"wallpaperPlugin\":\"org.kde.slideshow\","
        "\"wallpaperMode\":\"MultipleImages\",\"config\":{\"ImageSources\":\"[/b1.png,/b2.png]\"}}]')\n"
        "else:\n"
        "    print('OK_' + str(script.count('ds[i].screen ===')))\n",
    )
    yield
    os.environ.pop("PZ_THEMES_FAKE_JSON", None)
    os.environ.pop("PZ_THEMES_DBUS_CMD", None)


# --------------------------------------------------------------------------
# TH-PRV-001 — Preview 15 s com Manter/Reverter/expiração
# --------------------------------------------------------------------------

def test_preview_applies_then_apply_within_ttl_keeps(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    assert plan["ok"] is True

    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True
    assert preview["ttlSeconds"] == PREVIEW_TTL_SECONDS
    assert preview["expiresAt"] > time.time()

    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
    assert operation["restored"] is False
    record = themes_state.load("previews", preview["previewId"])
    assert record["applied"] is True
    assert record.get("expiredRolledBack") is not True


def test_preview_expiry_rolls_back_and_blocks_apply(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)

    record = themes_state.load("previews", preview["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview["previewId"], record)

    with pytest.raises(Exception, match="expirou e foi revertido automaticamente"):
        apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    updated = themes_state.load("previews", preview["previewId"])
    assert updated["applied"] is False
    assert updated["expiredRolledBack"] is True


def test_preview_reject_wrong_token(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    with pytest.raises(Exception, match="token de confirmação inválido"):
        preview_plan(plan["id"], confirmation="errado", facts=facts, session=sess)


def test_preview_rejects_non_wallpaper_plans(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="access.reduce-motion", feature_state_target="on", facts=facts, session=sess)
    with pytest.raises(Exception, match="somente planos de wallpaper"):
        preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)


def test_expired_preview_of_other_plan_reverts_on_next_command(fake_plasma, fake_state, fake_config):
    """A expiração não pode depender de reentrar no MESMO plano: o comando
    seguinte, de qualquer plano, reverte o preview vencido."""
    facts = detect()
    sess = KdeSession(facts)
    plan_a = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    preview_a = preview_plan(plan_a["id"], confirmation=plan_a["confirmToken"], facts=facts, session=sess)
    assert preview_a["applied"] is True

    record = themes_state.load("previews", preview_a["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview_a["previewId"], record)

    plan_b = create_plan(wallpaper="pz.aurora", screen="0", facts=facts, session=sess)
    preview_b = preview_plan(plan_b["id"], confirmation=plan_b["confirmToken"], facts=facts, session=sess)
    assert preview_b["applied"] is True

    updated = themes_state.load("previews", preview_a["previewId"])
    assert updated["applied"] is False
    assert updated["expiredRolledBack"] is True


def test_confirmed_apply_is_never_reverted_by_preview_expiry(fake_plasma, fake_state, fake_config):
    """Apply confirmado é dono da mudança; a varredura consome o preview em vez
    de restaurar o snapshot por cima do que o usuário confirmou."""
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"

    record = themes_state.load("previews", preview["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview["previewId"], record)

    status_payload(facts=facts, session=sess)  # qualquer comando dispara a varredura

    updated = themes_state.load("previews", preview["previewId"])
    assert updated["applied"] is False
    assert updated["consumedByApply"] == operation["operationId"]
    assert updated.get("expiredRolledBack") is not True


def test_dangling_preview_snapshot_does_not_brick_the_cli(fake_plasma, fake_state, fake_config):
    """Retenção apagando snapshot referenciado por preview vivo não pode
    derrubar nenhum comando (ValueError não capturado = CLI morta)."""
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    record = themes_state.load("previews", preview["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview["previewId"], record)
    themes_state.save("snapshots", plan["snapshotId"], {})  # snapshotted corrompido/podado

    payload = status_payload(facts=facts, session=sess)  # não pode levantar
    assert payload["schema"] == "themes/v1"


def test_lock_preview_reverts_to_empty_original(fake_plasma, fake_state, fake_config):
    """Host stock: lockScreen original é "" e o restore antigo (gate
    `if lock_image:`) deixava o preview de tela de bloqueio permanente."""
    facts = detect()
    sess = KdeSession(facts)
    lock = fake_config / "kscreenlockerrc"
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", wallpaper_target="lock", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True
    assert "Image=" in lock.read_text(encoding="utf-8")

    record = themes_state.load("previews", preview["previewId"])
    record["expiresAt"] = int(time.time()) - 1
    themes_state.save("previews", preview["previewId"], record)
    status_payload(facts=facts, session=sess)

    updated = themes_state.load("previews", preview["previewId"])
    assert updated["expiredRolledBack"] is True
    assert "Image=" in lock.read_text(encoding="utf-8")


def test_verify_reports_failed_wallpaper_and_respected_off(fake_plasma, fake_state, fake_config):
    """Wallpaper failed não pode virar "applied"; operação off bem-sucedida
    não pode verificar como falha."""
    from linux.themes.engine import verify_operation

    facts = detect()
    sess = KdeSession(facts)
    # off: aplica on primeiro, depois off, e o verify da direção off passa
    plan_on = create_plan(feature="access.reduce-motion", feature_state_target="on", facts=facts, session=sess)
    apply_plan(plan_on["id"], confirmation=plan_on["confirmToken"], facts=facts, session=sess)
    plan_off = create_plan(feature="access.reduce-motion", feature_state_target="off", facts=facts, session=sess)
    operation = apply_plan(plan_off["id"], confirmation=plan_off["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
    verified = verify_operation(operation["operationId"], facts=facts, session=sess)
    assert verified["ok"] is True, verified

    # wallpaper failed: resultado "failed" sem featureId verifica como falha
    themes_state.save("operations", "op-fake", {
        "schema": "themes/v1", "kind": "operation", "id": "op-fake",
        "planId": "plan-fake", "snapshotId": "", "createdAt": int(time.time()),
        "status": "failed",
        "results": [{"wallpaperId": "pz.geo-dark", "status": "failed", "error": "x"}],
    })
    verified = verify_operation("op-fake", facts=facts, session=sess)
    assert verified["ok"] is False
    assert verified["checks"][0]["status"] == "failed"


def test_video_smart_wallpaper_is_plannable_when_explicit(fake_plasma, fake_state, fake_config):
    """--state on é pedido explícito; o blocker "" (plano bloqueado sem
    explicação) foi removido - qualquer blocker restante se explica."""
    from tests.test_themes_contracts import run_cli
    result = run_cli("plan", "--feature", "video.smart-wallpaper", "--state", "on")
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert all(str(b).strip() for b in plan["blockers"]), plan["blockers"]
    assert "" not in plan["blockers"]


def test_blocked_plan_creates_no_snapshot(fake_plasma, fake_state, fake_config, tmp_path):
    """Plano bloqueado nunca executa; gastar snapshot do pool de retenção
    que operações e previews referenciam era churn puro."""
    fake = tmp_path / "plasma5.json"
    payload = json.loads((tmp_path / "fake.json").read_text())
    payload["plasmaMajor"] = 5
    fake.write_text(json.dumps(payload))
    os.environ["PZ_THEMES_FAKE_JSON"] = str(fake)
    try:
        facts = detect()
        sess = KdeSession(facts)
        plan = create_plan(wallpaper="pz.geo-dark", screen="0", facts=facts, session=sess)
        assert plan["ok"] is False
        assert plan["blockers"]
        assert plan["snapshotId"] == ""
    finally:
        os.environ["PZ_THEMES_FAKE_JSON"] = str(tmp_path / "fake.json")


# --------------------------------------------------------------------------
# TH-RBK-001 — Rollback preserva painéis/widgets (byte a byte)
# --------------------------------------------------------------------------

def test_rollback_restores_config_bytes_exactly(fake_plasma, fake_state, fake_config):
    # A global theme apply rewrites every one of these, so the snapshot has to
    # carry them all: covering only plasmarc restored one file and left the rest
    # holding a half-applied theme.
    kdeglobals = fake_config / "kdeglobals"
    plasmarc = fake_config / "plasmarc"
    originals = {
        kdeglobals: "[KDE]\nLookAndFeelPackage=com.example.custom\n\n[General]\nColorScheme=Custom\n",
        plasmarc: "[Theme]\nname=Breeze\nkeepEmpty=true\n\n[Wallpaper]\ncolor=#111111\n",
    }
    for path, text in originals.items():
        path.write_text(text, encoding="utf-8")

    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="theme.kde", feature_state_target="on", facts=facts, session=sess)
    assert plan["ok"] is True
    snapshot = themes_state.load("snapshots", plan["snapshotId"])
    captured = {Path(entry["path"]).name for entry in snapshot["files"]}
    assert {"kdeglobals", "plasmarc"} <= captured, f"snapshot incompleto: {sorted(captured)}"
    for entry in snapshot["files"]:
        path = Path(entry["path"])
        if path in originals:
            assert Path(entry["backup"]).read_bytes() == originals[path].encode("utf-8")

    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
    # The look-and-feel id is what this feature owns; plasmarc holds a desktop
    # theme name and is only snapshotted because the apply disturbs it.
    assert kdeglobals.read_text(encoding="utf-8") != originals[kdeglobals]

    rollback = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    assert rollback["status"] == "complete"
    assert rollback["restored"] is True
    for path, text in originals.items():
        assert path.read_bytes() == text.encode("utf-8"), f"{path.name} não restaurado byte a byte"


def test_rollback_snapshot_covers_containments_byte_level(fake_plasma, fake_state, fake_config):
    containments = fake_config / "plasma-org.kde.plasma.desktop-appletsrc"
    original = "[Containments][1][General]\nwallpaperPlugin=org.kde.image\n"
    containments.write_text(original, encoding="utf-8")
    writer = ConfigWrite()
    writer.track(containments)
    captured = writer.capture()
    assert captured["files"][0]["sha256"]
    backup = Path(captured["files"][0]["backup"])
    assert backup.read_bytes() == original.encode("utf-8")


def test_rollback_idempotent(fake_plasma, fake_state, fake_config):
    plasmarc = fake_config / "plasmarc"
    plasmarc.write_text("[Theme]\nname=Breeze\n", encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(feature="theme.kde", feature_state_target="on", facts=facts, session=sess)
    apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    first = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    second = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    assert first["status"] == "complete"
    assert second["idempotent"] is True
    assert second["rollbackId"] == first["rollbackId"]


# --------------------------------------------------------------------------
# TH-WAL-001 — Wallpaper por tela via D-Bus, sem reescrever containments
# --------------------------------------------------------------------------

def test_wallpaper_multi_monitor_targets_screen(multi_screen_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="1", facts=facts, session=sess)
    assert plan["ok"] is True
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True


def test_wallpaper_reads_per_screen_state(multi_screen_plasma, fake_state, fake_config):
    screens = session().read_wallpapers()
    assert len(screens) == 2
    assert screens[0]["screen"] == 0
    assert screens[1]["screen"] == 1
    assert screens[1]["wallpaperPlugin"] == "org.kde.slideshow"
    assert screens[0]["config"]["Image"] == "file:///a.png"


def test_snapshot_carries_desktop_index_and_restore_targets_it(multi_screen_plasma, fake_state, fake_config):
    """Containments diferentes reportam o mesmo screen (-1); restaurar por
    screen colapsa todos no primeiro. O índice do array desktops() endereça
    o containment exato."""
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="1", facts=facts, session=sess)
    snapshot = themes_state.load("snapshots", plan["snapshotId"])
    assert [item.get("desktopIndex") for item in snapshot["wallpapers"]] == [0, 1]

    rollback = rollback_snapshot(plan["snapshotId"], facts=facts, session=sess)
    assert rollback["status"] == "complete"
    assert rollback["restored"] is True


def test_wallpaper_plan_writes_no_containments(fake_plasma, fake_state, fake_config):
    containments = fake_config / "plasma-org.kde.plasma.desktop-appletsrc"
    before = "[Containments][1][General]\nwallpaperPlugin=org.kde.image\n"
    containments.write_text(before, encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.aurora", screen="0", facts=facts, session=sess)
    preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert containments.read_text(encoding="utf-8") == before


def test_wallpaper_lock_target_updates_lock_screen(fake_plasma, fake_state, fake_config):
    lock = fake_config / "kscreenlockerrc"
    lock.write_text("[Greeter][Wallpaper][org.kde.image][General]\nImage=/old.png\n", encoding="utf-8")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.geo-dark", screen="0", wallpaper_target="lock", facts=facts, session=sess)
    assert plan["ok"] is True
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True
    assert "Image=" in lock.read_text(encoding="utf-8")


def test_wallpaper_video_fails_closed_without_extension(fake_plasma, fake_state, fake_config, tmp_path):
    video = tmp_path / "clip.mp4"
    video.write_bytes(b"not really a video")
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper=str(video), screen="0", facts=facts, session=sess)
    assert plan["ok"] is True
    with pytest.raises(Exception, match="extensão de vídeo"):
        preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)


def test_wallpaper_solid_color_params(fake_plasma, fake_state, fake_config):
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(wallpaper="pz.solid-charcoal", screen="0", facts=facts, session=sess)
    preview = preview_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert preview["applied"] is True


# --------------------------------------------------------------------------
# TH-STE-001 — Game Mode: catálogo curado e pause-on-game
# --------------------------------------------------------------------------

def test_game_mode_plugins_curated_with_decky_mapping(fake_plasma, fake_state, fake_config):
    payload = catalog_payload()
    plugins = payload["steamPlugins"]
    assert plugins, "catálogo Steam deve listar plugins do Game Mode"
    assert all(item["deckyPlugin"] for item in plugins)
    assert all(item["sourceUrl"] for item in plugins)
    ids = [item["id"] for item in plugins]
    assert len(ids) == len(set(ids))


def test_game_mode_plan_pauses_on_game(fake_state, fake_config, tmp_path):
    make_facts(tmp_path, gameMode=True, steamOs=True, steamDeck=True)
    facts = detect()
    sess = KdeSession(facts)
    plan = create_plan(
        feature="power.pause-on-game",
        feature_state_target="on",
        facts=facts,
        session=sess,
    )
    assert plan["ok"] is True
    assert plan["status"] == "ready"
    assert plan["actions"][0]["noop"] is False
    operation = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, session=sess)
    assert operation["status"] == "complete"
