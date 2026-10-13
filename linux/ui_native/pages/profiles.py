from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFormLayout, QFrame, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader
from .base import BasePage


# LUX-024: o perfil seguro abre a lista; o resto segue em ordem alfabética.
RECOMMENDED_PROFILE = "profile.safe-base"


class ProfilesPage(BasePage):
    """Profile selection via ComboBox + Install button, instead of 15 cards."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.combo: QComboBox | None = None
        self.desc_label: QLabel | None = None
        self.install_btn: QPushButton | None = None
        self._install_connected: bool = False

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 8)
        layout.setSpacing(14)

        layout.addWidget(SectionHeader("Instalar perfil", "Selecione um perfil e clique em Instalar."))

        form = QFormLayout()
        form.setSpacing(10)
        self.combo = QComboBox()
        self.combo.setObjectName("profileCombo")
        # LUX-024: sem largura mínima fixa — o combo encolhe com a janela.
        self.combo.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon)
        self.combo.setMinimumContentsLength(16)
        ordered = sorted(self.actions, key=lambda a: (a.id != RECOMMENDED_PROFILE, a.title))
        for action in ordered:
            self.mark_represented(action)
            label = f"{action.title} — recomendado" if action.id == RECOMMENDED_PROFILE else action.title
            self.combo.addItem(label, action.id)
        self.combo.currentIndexChanged.connect(self._on_select)
        form.addRow("Perfil:", self.combo)

        row = QHBoxLayout()
        self.install_btn = QPushButton("Instalar perfil")
        self.install_btn.setObjectName("primaryButton")
        self.install_btn.setMinimumHeight(40)
        row.addWidget(self.install_btn)
        row.addStretch()
        form.addRow("", row)
        layout.addLayout(form)

        self.desc_label = QLabel("")
        self.desc_label.setObjectName("cardDescription")
        self.desc_label.setWordWrap(True)
        layout.addWidget(self.desc_label)

        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll)
        self._on_select(0)

    def _on_select(self, _index: int) -> None:
        if self.combo is None:
            return
        action_id = self.combo.currentData()
        action = self.by_id.get(action_id)
        if action is None:
            return
        self.desc_label.setText(action.description)
        # Mutável = prévia primeiro; o botão diz o que vai acontecer agora.
        self.install_btn.setText("Instalar" if not action.mutable else "Ver o que instala")
        if self._install_connected:
            self.install_btn.clicked.disconnect()
        self.install_btn.clicked.connect(lambda: self.request_action(action))
        self._install_connected = True

    def _preview_selected(self) -> None:
        if self.combo is None:
            return
        action_id = self.combo.currentData()
        action = self.by_id.get(action_id)
        if action is None:
            return
        self.request_action(action)

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
