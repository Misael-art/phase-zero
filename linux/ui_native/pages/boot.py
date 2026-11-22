from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import QSize, Qt
from PySide6.QtWidgets import (
    QFileDialog, QFrame, QHBoxLayout, QLabel, QListWidget, QListWidgetItem,
    QPushButton, QScrollArea, QVBoxLayout, QWidget,
)

from ..models import ActionSpec
from ..widgets import SectionHeader
from .workspace import CatalogWorkspacePage


class BootPage(CatalogWorkspacePage):
    """Register and remove live ISO entries through the normal preview runner."""

    def _section_page(self, section: str, actions: list[ActionSpec]) -> QWidget:
        if section != "Testar distros":
            return super()._section_page(section, actions)
        self.iso_actions = {action.id: action for action in actions}
        for action in actions:
            self.mark_represented(action)
        self.status_loader.status_ready.connect(self._iso_status_ready)
        self.status_loader.status_failed.connect(self._iso_status_failed)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(12)
        layout.addWidget(SectionHeader(
            section, "Escolha uma imagem de Linux para testar a distribuição pelo menu do GRUB."
        ))

        card = QFrame()
        card.setObjectName("moduleFacts")
        card_layout = QVBoxLayout(card)
        card_layout.setContentsMargins(14, 12, 14, 12)
        card_layout.setSpacing(8)
        title = QLabel("Imagens no menu")
        title.setObjectName("sectionHeading")
        card_layout.addWidget(title)

        self.iso_status = QLabel("Verificando imagens registradas…")
        self.iso_status.setWordWrap(True)
        self.iso_status.setObjectName("cardDescription")
        card_layout.addWidget(self.iso_status)
        self.iso_list = QListWidget()
        self.iso_list.setAccessibleName("Imagens ISO registradas no GRUB")
        self.iso_list.setObjectName("bootIsoList")
        self.iso_list.setUniformItemSizes(True)
        self.iso_list.currentItemChanged.connect(self._iso_selection_changed)
        self.iso_list.hide()
        card_layout.addWidget(self.iso_list)
        self.iso_details = QLabel()
        self.iso_details.setTextFormat(Qt.TextFormat.PlainText)
        self.iso_details.setWordWrap(True)
        self.iso_details.setObjectName("cardDescription")
        self.iso_details.hide()
        card_layout.addWidget(self.iso_details)

        buttons = QHBoxLayout()
        self.iso_add = QPushButton("Escolher ISO…")
        self.iso_add.setObjectName("primaryButton")
        self.iso_add.setMinimumHeight(44)
        self.iso_add.clicked.connect(self._choose_iso)
        buttons.addWidget(self.iso_add)
        self.iso_remove = QPushButton("Remover do menu")
        self.iso_remove.setObjectName("secondaryButton")
        self.iso_remove.setMinimumHeight(44)
        self.iso_remove.setEnabled(False)
        self.iso_remove.hide()
        self.iso_remove.clicked.connect(self._remove_iso)
        buttons.addWidget(self.iso_remove)
        buttons.addStretch()
        card_layout.addLayout(buttons)
        layout.addWidget(card)
        layout.addStretch()
        scroll.setWidget(content)
        return scroll

    def reload(self) -> None:
        super().reload()
        action = self.iso_actions["boot.iso.status"]
        self.status_loader.fetch(action.id, list(action.args))

    def block_while_running(self, running: bool) -> None:
        super().block_while_running(running)
        self.iso_add.setEnabled(not running)
        self.iso_remove.setEnabled(not running and self.iso_list.currentItem() is not None)

    def _iso_status_ready(self, action_id: str, _stdout: str, payload: object) -> None:
        if action_id != "boot.iso.status":
            return
        if not isinstance(payload, dict) or not isinstance(payload.get("entries"), list):
            self._iso_status_failed(action_id, "")
            return
        self.iso_list.clear()
        for entry in payload["entries"]:
            if not isinstance(entry, dict) or not entry.get("id"):
                continue
            title = str(entry.get("title") or entry["id"])
            item = QListWidgetItem(title)
            item.setSizeHint(QSize(0, 42))
            item.setData(Qt.ItemDataRole.UserRole, entry)
            item.setToolTip(str(entry.get("hostPath") or ""))
            self.iso_list.addItem(item)
        self.iso_list.setVisible(self.iso_list.count() > 0)
        if self.iso_list.count():
            self.iso_list.setFixedHeight(42 * min(self.iso_list.count(), 4) + 2 * self.iso_list.frameWidth())
            self.iso_status.setText("Confira o estado da imagem antes de reiniciar.")
            self.iso_list.setCurrentRow(0)
        else:
            self.iso_status.setText("Nenhuma ISO registrada. Escolha um arquivo para começar.")

    def _iso_status_failed(self, action_id: str, _error: str) -> None:
        if action_id == "boot.iso.status":
            self.iso_list.clear()
            self.iso_list.hide()
            self.iso_status.setText("Não foi possível consultar as imagens registradas.")

    def _iso_selection_changed(self, current: QListWidgetItem | None, _previous: QListWidgetItem | None) -> None:
        self.iso_remove.setEnabled(current is not None and not self.runner.running)
        self.iso_remove.setVisible(current is not None)
        self.iso_details.setVisible(current is not None)
        if current is not None:
            entry = current.data(Qt.ItemDataRole.UserRole)
            state = {
                "ready": "Arquivo disponível. Sessão live pendente de teste no hardware.",
                "miso-ntfs": "BigLinux / Manjaro em NTFS. Use um pendrive de instalação separado.",
                "missing": "Arquivo indisponível",
                "metadata-mismatch": "O arquivo mudou. Selecione a ISO novamente.",
                "hash-mismatch": "O arquivo mudou. Selecione a ISO novamente.",
            }.get(entry.get("reason"), "Estado do arquivo desconhecido")
            self.iso_details.setText(f"{state}\n{entry.get('hostPath', '')}")

    def _run_iso_action(self, action_id: str, value: str) -> None:
        action = self.iso_actions[action_id]
        self.request_action(replace(
            action, parameters=(),
            args=tuple(action.resolved_args(value)),
            preview_args=tuple(action.resolved_args(value, preview=True)),
        ))

    def _choose_iso(self) -> None:
        folder = ""
        current = self.iso_list.currentItem()
        if current is not None:
            source = current.data(Qt.ItemDataRole.UserRole).get("hostPath")
            if isinstance(source, str):
                iso = Path(source)
                if iso.is_absolute() and iso.parent.is_dir():
                    folder = str(iso.parent)
        path, _ = QFileDialog.getOpenFileName(self, "Escolher ISO de Linux", folder, "Imagens ISO (*.iso *.ISO)")
        if path:
            self._run_iso_action("boot.iso.add", path)

    def _remove_iso(self) -> None:
        item = self.iso_list.currentItem()
        if item is not None:
            self._run_iso_action("boot.iso.remove", item.data(Qt.ItemDataRole.UserRole)["id"])
