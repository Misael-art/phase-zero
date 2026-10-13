"""Desktop toggles on the Themes page: default on, user can turn each off."""
from __future__ import annotations

import os
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QTabWidget

from linux.themes.catalog import FEATURES, PROFILES
from linux.themes.features import adapter_for
from linux.themes.platform import HostFacts
from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.themes import DESKTOP, FEATURE_HINTS, FEATURE_TITLES
from linux.ui_native.widgets import SwitchControl

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    return QApplication.instance() or QApplication([])


def test_desktop_features_are_default_on_and_outside_profiles() -> None:
    for feature_id in ("desktop.controller", "desktop.terminal-keyboard"):
        spec = FEATURES[feature_id]
        assert spec.section == "desktop"
        assert spec.kind == "systemd-user"
        assert spec.default_state == "ligado"
        assert spec.config_keys == ()
        assert adapter_for(spec) is not None
    for profile in PROFILES.values():
        assert "desktop.controller" not in profile.features
        assert "desktop.terminal-keyboard" not in profile.features


def test_desktop_services_do_not_customize_appearance_profile(monkeypatch) -> None:
    from linux.themes import engine

    steam_deck = {
        "theme.phasezero",
        "access.text-size",
        "theme.cursor",
        "power.adaptive",
        "desktop.controller",
        "desktop.terminal-keyboard",
    }

    def fake_state(spec, facts, session):  # noqa: ARG001
        if spec.id in steam_deck:
            return {"state": "ligado", "params": dict(spec.default_params)}
        return {"state": "desligado", "params": {}}

    monkeypatch.setattr(engine, "feature_state", fake_state)
    result = engine._profile_effective(HostFacts(plasma_major=6, kwin=True), None)
    assert result["id"] == "steam-deck"


def test_catalog_exposes_both_directions() -> None:
    catalog = build_catalog(ROOT)
    ids = {item.id for item in catalog}
    for feature_id in DESKTOP:
        assert f"themes.feature.{feature_id}.on" in ids
        assert f"themes.feature.{feature_id}.off" in ids
    controller = next(item for item in catalog if item.id == "themes.feature.desktop.controller.off")
    keyboard = next(item for item in catalog if item.id == "themes.feature.desktop.terminal-keyboard.off")
    assert "ponteiro do firmware não volta" in controller.description
    assert "Steam+X continua" in keyboard.description


def test_desktop_tab_uses_switches(qapp) -> None:
    from linux.ui_native.pages.themes import ThemesPage

    catalog = build_catalog(ROOT)
    actions = [item for item in catalog if item.category == "Temas"]
    page = ThemesPage(ROOT, CommandRunner(ROOT), actions, {item.id: item for item in catalog})
    page.build()
    tabs = page.findChild(QTabWidget)
    titles = [tabs.tabText(index) for index in range(tabs.count())]
    assert titles.index("Desktop") == titles.index("Aparência") + 1
    assert len(page.desktop_tab.findChildren(SwitchControl)) == 2
    texts = [label.text() for label in page.desktop_tab.findChildren(QLabel)]
    assert FEATURE_TITLES["desktop.controller"] in texts
    assert FEATURE_TITLES["desktop.terminal-keyboard"] in texts
    assert any("ponteiro do firmware" in text for text in texts)
    assert any("Steam+X" in text for text in texts)
    assert "themes.feature.desktop.controller.on" in page._represented_ids
    assert "themes.feature.desktop.controller.off" in page._represented_ids
    assert "themes.feature.desktop.terminal-keyboard.on" in page._represented_ids
    assert "themes.feature.desktop.terminal-keyboard.off" in page._represented_ids
    joined = " ".join(FEATURE_HINTS.values())
    assert "Vem ligado" in joined
    assert "Desligar" in joined


def test_failed_persist_on_does_not_stamp_a_rollback(tmp_path, monkeypatch) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "systemctl.log"
    state = tmp_path / "systemd-state"
    state.mkdir()
    (bin_dir / "systemctl").write_text(
        "#!/bin/bash\n"
        "printf '%s\\n' \"$*\" >>\"$PZ_FAKE_SYSTEMCTL_LOG\"\n"
        "[ \"${1:-}\" = --user ] || exit 1\n"
        "case \"$2\" in\n"
        "  show) exit 0 ;;\n"
        "  is-enabled) exit 1 ;;\n"
        "  is-active) exit 3 ;;\n"
        "  *) exit 1 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    (bin_dir / "pgrep").write_text(
        "#!/bin/bash\nexit 0\n",
        encoding="utf-8",
    )
    (bin_dir / "scc-daemon").write_text("#!/bin/bash\nexit 99\n", encoding="utf-8")
    for path in bin_dir.iterdir():
        path.chmod(0o755)
    sysfs = tmp_path / "sysfs" / "3-3"
    sysfs.mkdir(parents=True)
    (sysfs / "idVendor").write_text("28de\n", encoding="utf-8")
    (sysfs / "idProduct").write_text("1205\n", encoding="utf-8")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setenv("PZ_SCC_CONFIG_DIR", str(tmp_path / "scc"))
    monkeypatch.setenv("PZ_SYSTEMD_USER_DIR", str(tmp_path / "units"))
    monkeypatch.setenv("PZ_CONTROLLER_SYSFS_ROOT", str(tmp_path / "sysfs"))
    monkeypatch.setenv("PZ_CONTROLLER_PERSIST_SETTLE", "0")
    monkeypatch.setenv("PZ_SCC_DAEMON_BIN", str(bin_dir / "scc-daemon"))
    monkeypatch.setenv("PZ_FAKE_SYSTEMCTL_LOG", str(log))
    monkeypatch.setenv("PZ_FAKE_SYSTEMD_STATE", str(state))
    monkeypatch.setenv("PATH", f"{bin_dir}:/usr/bin:/bin")
    for directory in ("home", "config", "state", "cache", "scc", "units"):
        (tmp_path / directory).mkdir()
    profile = tmp_path / "scc" / "profiles"
    profile.mkdir()
    (profile / "PhaseZero-Desktop.sccprofile").write_text("MARKER-KEEP\n", encoding="utf-8")

    adapter = adapter_for(FEATURES["desktop.controller"])
    assert adapter is not None
    result = adapter.apply(None, None, {"target": {"state": "ligado"}})
    assert result["status"] == "failed"
    assert "steam está ativo" in result["error"]
    stamp = tmp_path / "state" / "phasezero" / "desktop-service-toggles" / "desktop.controller.stamp"
    assert not stamp.exists()
    rolled = adapter.rollback(None, None, {"target": {"state": "ligado"}})
    assert rolled["status"] == "ok"
    assert "disable --now" not in log.read_text(encoding="utf-8")
    assert (profile / "PhaseZero-Desktop.sccprofile").read_text(encoding="utf-8") == "MARKER-KEEP\n"
