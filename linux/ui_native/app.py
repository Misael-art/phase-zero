#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtGui import QColor, QIcon, QPalette
from PySide6.QtWidgets import QApplication

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from linux.ui_native import __version__
    from linux.ui_native.boot_selector import BootSelectorWindow
    from linux.ui_native.main_window import MainWindow
    from linux.ui_native.tokens import DARK, LIGHT, font_scale, render_qss
    from linux.ui_native.platform import current_platform
    from linux.ui_native.preferences import UiPreferences, resolve_theme
else:
    from . import __version__
    from .boot_selector import BootSelectorWindow
    from .main_window import MainWindow
    from .tokens import DARK, LIGHT, font_scale, render_qss
    from .platform import current_platform
    from .preferences import UiPreferences, resolve_theme


ROOT = Path(__file__).resolve().parents[2]


def _init_icon_theme() -> None:
    icon_dir = ROOT / "assets" / "icons"
    if icon_dir.is_dir():
        paths = QIcon.themeSearchPaths()
        if str(icon_dir) not in paths:
            QIcon.setThemeSearchPaths([str(icon_dir), *paths])


def apply_theme(app: QApplication, theme: str) -> None:
    tokens = LIGHT if theme == "light" else DARK
    app.setStyle("Fusion")
    app.setStyleSheet(render_qss(tokens, font_scale(app.font().pointSizeF())))
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor(tokens.bg))
    palette.setColor(QPalette.WindowText, QColor(tokens.text))
    palette.setColor(QPalette.Base, QColor(tokens.surface_inset))
    palette.setColor(QPalette.Text, QColor(tokens.text))
    palette.setColor(QPalette.Button, QColor(tokens.surface))
    palette.setColor(QPalette.ButtonText, QColor(tokens.text))
    palette.setColor(QPalette.Highlight, QColor(tokens.accent))
    palette.setColor(QPalette.HighlightedText, QColor(tokens.on_accent))
    app.setPalette(palette)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="PhaseZero Central de Controle")
    parser.add_argument("--version", action="version", version=f"PhaseZero {__version__}")
    parser.add_argument("--category", default="")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--screenshot", default="")
    parser.add_argument("--light", action="store_true")
    parser.add_argument("--boot-selector", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    _init_icon_theme()
    QApplication.setHighDpiScaleFactorRoundingPolicy(Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
    app = QApplication(sys.argv)
    app.setApplicationName("PhaseZero")
    app.setOrganizationName("PhaseZero")
    app.setDesktopFileName("io.phasezero.ControlCenter")
    app.setQuitOnLastWindowClosed(True)
    # LUX-021: preferência salva (padrão: seguir o desktop); --light força.
    theme = "light" if args.light else resolve_theme(UiPreferences().theme)
    apply_theme(app, theme)
    if args.boot_selector:
        if current_platform() != "linux":
            parser_message = "Seletor de boot disponível somente no Linux."
            print(parser_message, file=sys.stderr)
            return 2
        window = BootSelectorWindow(ROOT, smoke_test=args.smoke_test)
    else:
        window = MainWindow(ROOT, initial_category=args.category)
        window.dark_theme = theme == "dark"
        window.theme_changed.connect(lambda theme: apply_theme(app, theme))
    window.show()
    if args.smoke_test:
        def finish() -> None:
            if args.screenshot:
                target = Path(args.screenshot).expanduser().resolve()
                target.parent.mkdir(parents=True, exist_ok=True)
                window.grab().save(str(target))
            window.close()
            app.quit()

        QTimer.singleShot(900, finish)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
