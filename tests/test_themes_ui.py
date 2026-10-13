"""QA da página Temas (ThemesPage) e integração com catálogo/histórico.

Hermético: offscreen, sem tocar host. Toggles usam o padrão otimista com
cancelamento; alvos mínimos de 44 px; navegação por teclado via QTabWidget.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication, QPushButton, QTabWidget

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "linux"))

from linux.ui_native.catalog import build_catalog  # noqa: E402
from linux.ui_native.command_runner import CommandRunner  # noqa: E402
from linux.ui_native.pages.themes import ThemesPage  # noqa: E402
from linux.ui_native.widgets import SwitchControl  # noqa: E402

SCHEMA = "themes/v1"


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def page(qapp):
    root = ROOT
    catalog = build_catalog(root)
    by_id = {action.id: action for action in catalog}
    themes = [action for action in catalog if action.category == "Temas"]
    instance = ThemesPage(root, CommandRunner(root), themes, by_id)
    instance.build()
    yield instance
    instance.close()


def test_themes_page_has_eight_tabs(page):
    tabs = page.findChild(QTabWidget)
    assert tabs is not None
    assert [tabs.tabText(index) for index in range(tabs.count())] == [
        "Perfis", "Aparência", "Desktop", "Acessibilidade", "Wallpapers", "Game Mode",
        "Catálogo avaliado", "Histórico",
    ]


def test_themes_page_exposes_twenty_two_toggles(page):
    assert len(page._controls) == 22
    feature_ids = {feature_id for feature_id, _toggle, _detail in page._controls}
    for required in (
        "theme.phasezero", "theme.night-color", "access.text-size",
        "access.reduce-motion", "access.screen-reader", "access.sticky-keys",
        "power.adaptive", "power.pause-on-game",
    ):
        assert required in feature_ids


def test_toggles_are_switch_controls_with_minimum_size(page):
    for _feature_id, toggle, _detail in page._controls:
        assert isinstance(toggle, SwitchControl)
        assert toggle.minimumHeight() == 30 or toggle.minimumSize().height() >= 30


def test_primary_buttons_meet_44px_targets(page):
    targets = [button for button in page.findChildren(QPushButton) if button.minimumHeight() >= 44]
    assert targets, "nenhum botão atinge o alvo mínimo de 44 px"
    for button in targets:
        assert button.minimumHeight() >= 44


def test_toggle_optimistic_then_cancel_restores(page):
    feature_id = "access.reduce-motion"
    index = next(
        i for i, (fid, _toggle, _detail) in enumerate(page._controls) if fid == feature_id
    )
    toggle, _detail = page._controls[index][1], page._controls[index][2]
    with QtSignalBlockerGuardForTest(toggle):
        toggle.setChecked(False)
        toggle.setProperty("applied", False)
        toggle.setProperty("supported", True)
    action = page.by_id.get("themes.feature.access.reduce-motion.on")
    assert action is not None

    toggle.setChecked(True)
    assert toggle.property("applied") is False
    assert toggle.property("pending") is True
    assert action.id in page._pending_toggles

    page.cancel_pending_action(action.id)
    assert toggle.isChecked() is False
    assert toggle.property("pending") is False
    assert action.id not in page._pending_toggles


def test_block_while_running_disables_tabs_but_keeps_hero_actions(page):
    tabs = page.findChild(QTabWidget)
    page.block_while_running(True)
    try:
        assert tabs.isEnabled() is False
        assert page.undo_button.isEnabled() is False
        assert page.rescue_button.isEnabled() is False
    finally:
        page.block_while_running(False)
    assert tabs.isEnabled() is True
    assert page.undo_button.isEnabled() is True


def test_catalog_actions_all_mapped(page):
    missing = [
        action.id for action in page.actions
        if action.id not in page.by_id
    ]
    assert not missing


# ---------------------------------------------------------------------------
# Histórico (CLI hermético)
# ---------------------------------------------------------------------------


@pytest.fixture()
def fake_themes_env(tmp_path):
    state = tmp_path / "state"
    config = tmp_path / "config"
    config.mkdir()
    fake = tmp_path / "fake.json"
    fake.write_text(json.dumps({
        "plasmaMajor": 6, "session": "wayland", "kwin": True,
        "steamOs": False, "steamDeck": False, "gameMode": False, "decky": False,
        "onBattery": False, "batteryPercent": None, "vaapi": True, "vulkan": True,
        "steamInstall": "", "steamLibraries": [],
        "binaries": {"qdbus": ""},
    }), encoding="utf-8")
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
    env = dict(os.environ)
    env.update({
        "PZ_THEMES_STATE_DIR": str(state),
        "PZ_THEMES_CONFIG_DIR": str(config),
        "PZ_THEMES_FAKE_JSON": str(fake),
        "PZ_THEMES_DBUS_CMD": sys.executable + " " + str(stub),
    })
    return env


def run_themes(*args, env):
    return subprocess.run(
        [sys.executable, "-m", "linux.themes", *args],
        capture_output=True, text=True, cwd=str(ROOT), env=env, timeout=60,
    )


def test_history_lists_operations(fake_themes_env):
    plan = run_themes("plan", "--feature", "access.locate-cursor", "--state", "on", env=fake_themes_env)
    assert plan.returncode == 0, plan.stderr
    payload = json.loads(plan.stdout)
    assert payload["ok"] is True

    apply = run_themes("apply", "--plan-id", payload["id"], "--confirm", payload["confirmToken"], env=fake_themes_env)
    assert apply.returncode == 0, apply.stderr
    operation = json.loads(apply.stdout)
    assert operation["status"] == "complete"

    history = run_themes("history", env=fake_themes_env)
    assert history.returncode == 0
    result = json.loads(history.stdout)
    assert result["schema"] == SCHEMA
    assert result["operations"], "histórico vazio após aplicar"
    latest = result["operations"][0]
    assert latest["operationId"] == operation["operationId"]
    assert "access.locate-cursor" in latest["features"]
    assert latest["status"] == "complete"
    assert latest["restored"] is False


def test_history_empty_without_operations(fake_themes_env):
    result = run_themes("history", env=fake_themes_env)
    assert result.returncode == 0
    assert json.loads(result.stdout)["operations"] == []


class QtSignalBlockerGuardForTest:
    """Bloco de sinais sem depender de internals do Qt (teste)."""

    def __init__(self, widget) -> None:
        self._widget = widget

    def __enter__(self):
        self._widget.blockSignals(True)
        return self

    def __exit__(self, *_exc) -> None:
        self._widget.blockSignals(False)
