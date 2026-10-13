from __future__ import annotations

import os

from PySide6.QtCore import QObject, QSettings, Signal


class UiPreferences(QObject):
    """Persistent presentation preferences for progressive disclosure."""

    advanced_mode_changed = Signal(bool)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._settings = QSettings("PhaseZero", "ControlCenter")

    @property
    def advanced_mode(self) -> bool:
        override = os.environ.get("PZ_UI_ADVANCED_MODE", "").strip().casefold()
        if override:
            return override in {"1", "true", "yes", "on"}
        return self._settings.value("interface/advancedMode", False, type=bool)

    # LUX-021: tema persistido; "system" segue o esquema de cor do desktop.
    THEMES = ("system", "dark", "light")

    @property
    def theme(self) -> str:
        value = str(self._settings.value("interface/theme", "system") or "system")
        return value if value in self.THEMES else "system"

    def set_theme(self, theme: str) -> None:
        if theme not in self.THEMES:
            raise ValueError(f"unknown theme: {theme}")
        self._settings.setValue("interface/theme", theme)
        self._settings.sync()

    @property
    def hide_account_identity(self) -> bool:
        return self._settings.value("accounts/hideIdentity", False, type=bool)

    def set_hide_account_identity(self, hidden: bool) -> None:
        hidden = bool(hidden)
        if hidden == self.hide_account_identity:
            return
        self._settings.setValue("accounts/hideIdentity", hidden)
        self._settings.sync()

    def set_advanced_mode(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if enabled == self.advanced_mode:
            return
        self._settings.setValue("interface/advancedMode", enabled)
        self._settings.sync()
        self.advanced_mode_changed.emit(enabled)


def resolve_theme(preference: str) -> str:
    """``dark``/``light`` for a stored preference (``system`` asks Qt)."""
    if preference in {"dark", "light"}:
        return preference
    try:
        from PySide6.QtCore import Qt
        from PySide6.QtGui import QGuiApplication

        scheme = QGuiApplication.styleHints().colorScheme()
        return "light" if scheme == Qt.ColorScheme.Light else "dark"
    except (AttributeError, RuntimeError):
        return "dark"


def reduced_motion() -> bool:
    """LUX-021: honor the desktop's reduce-motion choice (read-only)."""
    override = os.environ.get("PZ_REDUCE_MOTION", "").strip().casefold()
    if override:
        return override in {"1", "true", "yes", "on"}
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    try:
        with open(os.path.join(config, "kdeglobals"), encoding="utf-8") as handle:
            section = ""
            for raw in handle:
                line = raw.strip()
                if line.startswith("["):
                    section = line
                elif section == "[KDE]" and line.startswith("AnimationDurationFactor="):
                    return float(line.split("=", 1)[1] or "1") == 0.0
    except (OSError, ValueError):
        return False
    return False
