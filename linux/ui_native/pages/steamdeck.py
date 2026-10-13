from __future__ import annotations

from PySide6.QtCore import QSignalBlocker
from PySide6.QtWidgets import (
    QButtonGroup, QFrame, QGridLayout, QHBoxLayout, QLabel,
    QPushButton, QRadioButton, QVBoxLayout,
)

from .base import BasePage

MODE_ACTIONS = {
    "handheld": "steamdeck.handheld",
    "docked-tv": "steamdeck.docked-tv",
    "docked-monitor": "steamdeck.docked-monitor",
}

MODE_LABELS = {
    "handheld": "Handheld (painel interno)",
    "docked-tv": "Docked na TV",
    "docked-monitor": "Docked no monitor",
}


def _dict(value: object) -> dict:
    return value if isinstance(value, dict) else {}


class SteamDeckPage(BasePage):
    """Página Steam Deck viva: modo, watcher, teclado, Decky e boot direto.

    Os radios de modo leem ``status.mode`` do payload de ``steamdeck.status``
    e disparam a ação correspondente; os fatos mostram o estado real medido,
    não o catálogo de ações disponíveis.
    """

    def __init__(self, root, runner, actions, by_id=None, parent=None) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._payload: dict = {}
        self._mode_pending = False
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)
        self.represented_ids = {
            "steamdeck.status", *MODE_ACTIONS.values(), "steamdeck.detect"
        }

    def build(self) -> None:
        self._layout.setSpacing(12)

        header = QHBoxLayout()
        self.state_label = QLabel("● Verificando…")
        self.state_label.setObjectName("sectionHeading")
        header.addWidget(self.state_label)
        header.addStretch(1)
        refresh = QPushButton("Atualizar")
        refresh.setObjectName("secondaryButton")
        refresh.clicked.connect(self.reload)
        header.addWidget(refresh)
        self._layout.addLayout(header)

        mode_box = QFrame()
        mode_box.setObjectName("settingsCard")
        mode_layout = QVBoxLayout(mode_box)
        mode_title = QLabel("Modo de uso")
        mode_title.setObjectName("cardDescription")
        mode_layout.addWidget(mode_title)
        radio_row = QHBoxLayout()
        self._mode_group = QButtonGroup(self)
        self._mode_radios: dict[str, QRadioButton] = {}
        for mode, label in MODE_LABELS.items():
            radio = QRadioButton(label)
            radio.setToolTip("Aplica TDP, governor e perfil do modo ao confirmar")
            radio.toggled.connect(lambda checked, m=mode: self._on_mode_toggled(checked, m))
            self._mode_group.addButton(radio)
            self._mode_radios[mode] = radio
            radio_row.addWidget(radio)
        radio_row.addStretch(1)
        mode_layout.addLayout(radio_row)
        self.mode_note = QLabel("O modo reflete o watcher e a última aplicação manual.")
        self.mode_note.setObjectName("cardDescription")
        mode_layout.addWidget(self.mode_note)
        self._layout.addWidget(mode_box)

        facts_box = QFrame()
        facts_box.setObjectName("settingsCard")
        facts_grid = QGridLayout(facts_box)
        facts_grid.setHorizontalSpacing(18)
        facts_grid.setVerticalSpacing(6)
        self.watcher_label = self._fact(facts_grid, 0, 0, "Modo automático (watcher)")
        self.keyboard_label = self._fact(facts_grid, 0, 1, "Teclado virtual")
        self.decky_label = self._fact(facts_grid, 1, 0, "Decky Loader")
        self.boot_label = self._fact(facts_grid, 1, 1, "Boot direto Game Mode")
        self.display_label = self._fact(facts_grid, 2, 0, "Perfil de vídeo")
        self._layout.addWidget(facts_box)

        actions_row = QHBoxLayout()
        for label, action_id in (
            ("Instalar atalhos Game Mode", "steamdeck.hotkeys"),
            ("Alternar teclado", "steamdeck.keyboard.toggle"),
            ("Instalar Decky", "steamdeck.plugins"),
            ("Ligar watcher", "steamdeck.watcher.enable"),
        ):
            button = QPushButton(label)
            button.setObjectName("secondaryButton")
            button.clicked.connect(lambda _checked=False, aid=action_id: self.run_action(aid))
            actions_row.addWidget(button)
        actions_row.addStretch(1)
        self._layout.addLayout(actions_row)

        # CCS-012: ações elevadas ficam visíveis no primário com o custo claro.
        admin_row = QHBoxLayout()
        for label, action_id, risk in (
            ("Controles TDP (requer admin)", "steamdeck.privileged",
             "Instala sudoers limitados para TDP/GPU; revisível em steamdeck.privileged.status."),
            ("Boot Game Mode (requer admin)", "steamdeck.boot",
             "Escreve entrada GRUB dedicada; requer senha e toca configuração de boot."),
            ("USB automático (requer admin)", "steamdeck.removable",
             "Auto-mount de USB; desligado durante a Windows VM; requer senha."),
        ):
            button = QPushButton(label)
            button.setObjectName("dangerOutlineButton")
            button.setToolTip(risk)
            button.setAccessibleDescription(risk)
            button.clicked.connect(lambda _checked=False, aid=action_id: self.run_action(aid))
            admin_row.addWidget(button)
        admin_row.addStretch(1)
        self._layout.addLayout(admin_row)
        self._layout.addStretch(1)

    def _fact(self, grid: QGridLayout, row: int, col: int, title: str) -> QLabel:
        box = QVBoxLayout()
        heading = QLabel(title)
        heading.setObjectName("cardDescription")
        value = QLabel("—")
        value.setWordWrap(True)
        box.addWidget(heading)
        box.addWidget(value)
        grid.addLayout(box, row, col)
        return value

    def reload(self) -> None:
        action = self.by_id.get("steamdeck.status")
        if action is None or self.status_loader.running(action.id):
            return
        self.state_label.setText("● Verificando…")
        self.refresh_modes(enabled=False)
        self.status_loader.fetch_action(action)

    # -- mode radios ---------------------------------------------------------
    def _on_mode_toggled(self, checked: bool, mode: str) -> None:
        if not checked or self._mode_pending:
            return
        self._mode_pending = True
        self.refresh_modes(enabled=False)
        self.run_action(MODE_ACTIONS[mode])

    def refresh_modes(self, *, enabled: bool) -> None:
        for radio in self._mode_radios.values():
            radio.setEnabled(enabled)

    def _sync_mode_from_payload(self) -> None:
        mode = str(self._payload.get("mode") or "")
        radio = self._mode_radios.get(mode)
        # Bloqueia cada radio individualmente: bloquear só o QButtonGroup não
        # impede o toggled de cada botão durante a sincronização.
        for candidate in self._mode_radios.values():
            with QSignalBlocker(candidate):
                candidate.setChecked(candidate is radio)
        if radio is None:
            self.mode_note.setText("Modo desconhecido para este host.")
        else:
            automation = _dict(self._payload.get("automation"))
            if automation.get("watcherActive"):
                self.mode_note.setText("O assistente de dock mantém este modo conforme você encaixa ou desencaixa.")
            else:
                self.mode_note.setText("Watcher inativo; o modo vale até nova aplicação manual.")

    def cancel_pending_action(self, action_id: str) -> None:
        if action_id in MODE_ACTIONS.values():
            self._mode_pending = False
            self.refresh_modes(enabled=True)
            self._sync_mode_from_payload()

    # -- status --------------------------------------------------------------
    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id != "steamdeck.status" or not isinstance(parsed, dict):
            return
        self._payload = parsed
        self._mode_pending = False
        self.refresh_modes(enabled=True)
        self._sync_mode_from_payload()

        automation = _dict(parsed.get("automation"))
        if automation.get("watcherActive"):
            self.watcher_label.setText("Ativo (aplica o modo sozinho)")
        else:
            self.watcher_label.setText("Inativo")

        keyboard = _dict(parsed.get("virtualKeyboard"))
        kde = _dict(keyboard.get("kde"))
        opened = _dict(keyboard.get("open"))
        configured = _dict(keyboard.get("configured"))
        dbus = _dict(keyboard.get("dbus"))
        provider = str(keyboard.get("provider") or "—")
        # Configured and D-Bus-available are not the same as a keyboard the
        # user can type on. "Ligado" used to fire from the config flag alone.
        if opened.get("effective") or kde.get("visible"):
            self.keyboard_label.setText(f"Aberto ({provider})")
        elif dbus.get("available") or kde.get("available"):
            self.keyboard_label.setText(f"Disponível, fechado ({provider})")
        elif configured.get("inputMethod") or kde.get("enabled"):
            self.keyboard_label.setText(f"Configurado, KWin sem teclado ativo ({provider})")
        else:
            self.keyboard_label.setText("Indisponível neste desktop")

        decky = _dict(_dict(parsed.get("plugins")).get("decky"))
        service = _dict(decky.get("service"))
        if decky.get("installed") and service.get("active"):
            self.decky_label.setText("Instalado e serviço ativo")
        elif decky.get("installed"):
            self.decky_label.setText("Instalado, serviço parado")
        else:
            self.decky_label.setText("Não instalado")

        boot = _dict(parsed.get("boot"))
        entry = str(boot.get("grubCfgEntry") or boot.get("nextEntry") or "unknown")
        if entry == "active":
            self.boot_label.setText("Entrada GRUB presente e marcada")
        elif entry in {"none", "missing"}:
            self.boot_label.setText("Sem entrada GRUB dedicada")
        else:
            self.boot_label.setText(f"Estado: {entry}")

        display = _dict(parsed.get("display"))
        profile = str(display.get("profile") or "—")
        if "oled" in profile:
            profile += " (OLED)"
        self.display_label.setText(profile)

    def _on_status_failed(self, action_id: str, message: str) -> None:
        if action_id != "steamdeck.status":
            return
        self.refresh_modes(enabled=True)
        self.state_label.setText("● Estado indisponível")
        if message == "timed out":
            self.mode_note.setText("A verificação demorou demais; tente atualizar novamente.")
        else:
            self.mode_note.setText("Falha ao consultar o Steam Deck; nada foi alterado.")
