from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox, QFrame, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage


TUNE_AREAS = ("browser", "gaming", "dev")
TUNE_LABELS = {
    "browser": "Hardening navegador",
    "gaming": "Ajustes gaming",
    "dev": "Ajustes dev",
}
TUNE_DESCRIPTIONS = {
    "browser": "Privacidade, segurança e isolamento do navegador.",
    "gaming": "Performance, latência e telemetria para Steam/Heroic.",
    "dev": "Toolchain, limites do host e serviços de desenvolvimento.",
}


class TuningPage(BasePage):
    """Checkboxes per tune area + single Apply button."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.checkboxes: dict[str, QCheckBox] = {}

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Ajustes do sistema", "Marque as áreas e aplique."))

        added = False
        for area in TUNE_AREAS:
            action = self.find(f"tune.{area}")
            if action is None:
                continue
            cb = QCheckBox(f"  {TUNE_LABELS.get(area, area)}")
            cb.setObjectName("tuneCheck")
            cb.setToolTip(TUNE_DESCRIPTIONS.get(area, ""))
            self.checkboxes[area] = cb
            layout.addWidget(cb)
            added = True
        if not added:
            empty = QLabel("Nenhuma área de ajuste disponível nesta instalação.")
            empty.setObjectName("cardDescription")
            empty.setWordWrap(True)
            layout.addWidget(empty)

        btn_row = QHBoxLayout()
        apply_btn = QPushButton("Aplicar selecionados")
        apply_btn.setObjectName("primaryButton")
        apply_btn.clicked.connect(self._apply_selected)
        btn_row.addWidget(apply_btn)
        btn_row.addStretch()
        layout.addLayout(btn_row)
        layout.addStretch()

        scroll.setWidget(inner)
        self._layout.addWidget(scroll)

    def _apply_selected(self) -> None:
        selected: list[ActionSpec] = []
        for area, cb in self.checkboxes.items():
            if cb.isChecked():
                action = self.find(f"tune.{area}")
                if action is not None:
                    selected.append(action)
        self.request_actions(selected)

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
