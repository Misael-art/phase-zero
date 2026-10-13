"""LUX-021 — tema persiste; movimento reduzido desliga o shimmer."""
from __future__ import annotations

import pytest
from PySide6.QtCore import QSettings
from PySide6.QtWidgets import QApplication

from linux.ui_native.preferences import UiPreferences, reduced_motion, resolve_theme


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def settings_dir(tmp_path):
    QSettings.setPath(QSettings.NativeFormat, QSettings.UserScope, str(tmp_path))
    yield tmp_path


def test_theme_defaults_to_system_and_persists(qapp, settings_dir):
    prefs = UiPreferences()
    assert prefs.theme == "system"
    assert resolve_theme("system") in {"dark", "light"}
    prefs.set_theme("light")
    assert UiPreferences().theme == "light"
    assert resolve_theme("light") == "light"
    with pytest.raises(ValueError):
        prefs.set_theme("rosa")


def test_reduced_motion_from_env_and_kdeglobals(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_REDUCE_MOTION", "1")
    assert reduced_motion() is True
    monkeypatch.delenv("PZ_REDUCE_MOTION")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    assert reduced_motion() is False
    (tmp_path / "kdeglobals").write_text("[General]\nx=1\n[KDE]\nAnimationDurationFactor=0\n")
    assert reduced_motion() is True


def test_shimmer_is_static_with_reduced_motion(qapp, monkeypatch):
    from linux.ui_native.widgets import SkeletonTile, start_shimmer

    monkeypatch.setenv("PZ_REDUCE_MOTION", "1")
    tile = SkeletonTile(100, 10)
    start_shimmer(tile)
    assert tile.property("shimmer") == "true"
    assert getattr(tile, "_phasezero_shimmer", None) is None
