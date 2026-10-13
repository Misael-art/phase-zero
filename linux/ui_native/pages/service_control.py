from __future__ import annotations

from PySide6.QtCore import QSignalBlocker, Qt
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..widgets import SectionHeader, SwitchControl, themed_icon
from ..result_parser import guidance
from .base import BasePage


class FriendlyServicePage(BasePage):
    service_name = "Serviço"
    service_subtitle = ""
    service_icon = "network-server"
    status_action_id = ""
    start_action_id = ""
    stop_action_id = ""
    setup_action_id = ""
    represented_ids: tuple[str, ...] = ()

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._payload: dict = {}
        self._running = False
        self._configured = False
        self._feature_actions: list[tuple[str, str]] = []
        self._pending_features: dict[str, tuple[SwitchControl, bool, QLabel, str]] = {}

    def build(self) -> None:
        for action_id in self.represented_ids:
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        layout = QVBoxLayout(host)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(14)
        layout.addWidget(self._build_hero())
        body = QGridLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.setHorizontalSpacing(14)
        body.addWidget(self._build_status_card(), 0, 0)
        body.addWidget(self._build_features_card(), 0, 1)
        body.setColumnStretch(0, 1)
        body.setColumnStretch(1, 1)
        layout.addLayout(body)
        layout.addWidget(self._build_shortcuts())
        extra = self.build_extra()
        if extra is not None:
            layout.addWidget(extra)
        layout.addStretch()
        scroll.setWidget(host)
        self._layout.addWidget(scroll, 1)
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def _build_hero(self) -> QFrame:
        hero = QFrame()
        hero.setObjectName("serviceHero")
        row = QHBoxLayout(hero)
        row.setContentsMargins(20, 18, 20, 18)
        row.setSpacing(16)
        icon = QLabel()
        icon.setObjectName("serviceIcon")
        icon.setPixmap(themed_icon(hero, self.service_icon, QStyle.SP_ComputerIcon).pixmap(38, 38))
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(58, 58)
        row.addWidget(icon)
        copy = QVBoxLayout()
        title = QLabel(self.service_name)
        title.setObjectName("serviceTitle")
        self.state_label = QLabel("● Verificando…")
        self.state_label.setObjectName("serviceState")
        self.state_label.setProperty("state", "info")
        self.state_detail = QLabel(self.service_subtitle)
        self.state_detail.setObjectName("cardDescription")
        copy.addWidget(title)
        copy.addWidget(self.state_label)
        copy.addWidget(self.state_detail)
        row.addLayout(copy, 1)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.setObjectName("secondaryButton")
        self.refresh_button.clicked.connect(self.reload)
        row.addWidget(self.refresh_button)
        self.power_button = QPushButton("Iniciar")
        self.power_button.setObjectName("primaryButton")
        self.power_button.setMinimumSize(140, 50)
        self.power_button.setEnabled(False)
        self.power_button.clicked.connect(self._power_action)
        row.addWidget(self.power_button)
        return hero

    def _build_status_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Resumo", "Informações essenciais"))
        self.fact_labels: list[QLabel] = []
        for _ in range(4):
            label = QLabel("—")
            label.setObjectName("settingValue")
            label.setWordWrap(True)
            self.fact_labels.append(label)
            layout.addWidget(label)
        layout.addStretch()
        return card

    def _feature_switch(self, title: str) -> tuple[QWidget, SwitchControl, QLabel]:
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 3, 0, 3)
        copy = QVBoxLayout()
        name = QLabel(title)
        name.setObjectName("settingValue")
        detail = QLabel("Verificando…")
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        toggle = SwitchControl()
        toggle.setEnabled(False)
        toggle.setAccessibleName(title)
        copy.addWidget(name)
        copy.addWidget(detail)
        layout.addLayout(copy, 1)
        layout.addWidget(toggle)
        return row, toggle, detail

    def _build_features_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader("Integrações", "Recursos conectados"))
        self.feature_controls: list[tuple[SwitchControl, QLabel]] = []
        self._feature_actions = list(self.feature_actions())
        for index, title in enumerate(self.feature_titles()):
            row, toggle, detail = self._feature_switch(title)
            layout.addWidget(row)
            self.feature_controls.append((toggle, detail))
            if index < len(self._feature_actions):
                toggle.toggled.connect(
                    lambda checked, feature_index=index: self._feature_toggle_requested(feature_index, checked)
                )
        layout.addStretch()
        return card

    def _build_shortcuts(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.addWidget(SectionHeader("Ações rápidas", "Tarefas comuns sem terminal"))
        buttons = QHBoxLayout()
        self.shortcut_buttons: dict[str, QPushButton] = {}
        for action_id, label, primary in self.shortcut_actions():
            action = self.by_id.get(action_id)
            if action is None:
                continue
            button = QPushButton(label)
            button.setObjectName("primaryButton" if primary else "secondaryButton")
            button.clicked.connect(lambda _checked=False, item=action: self.request_action(item))
            self.shortcut_buttons[action_id] = button
            buttons.addWidget(button)
        buttons.addStretch()
        layout.addLayout(buttons)
        return card

    def feature_titles(self) -> tuple[str, ...]:
        return ()

    def feature_actions(self) -> tuple[tuple[str, str], ...]:
        return ()

    def build_extra(self) -> QWidget | None:
        return None

    def _feature_toggle_requested(self, index: int, checked: bool) -> None:
        toggle, _detail = self.feature_controls[index]
        applied = bool(toggle.property("applied"))
        if checked == applied:
            return
        enable_id, disable_id = self._feature_actions[index]
        action_id = enable_id if checked else disable_id
        detail = self.feature_controls[index][1]
        previous_detail = detail.text()
        toggle.set_pending(True)
        toggle.setEnabled(False)
        detail.setText("Aguardando confirmação…")
        self._pending_features[action_id] = (toggle, applied, detail, previous_detail)
        self.run_action(action_id)

    @staticmethod
    def _apply_feature(toggle: SwitchControl, checked: bool, enabled: bool = True) -> None:
        with QSignalBlocker(toggle):
            toggle.setChecked(checked)
            toggle.setProperty("applied", checked)
            toggle.setProperty("supported", enabled)
            toggle.set_pending(False)
            toggle.setEnabled(enabled)

    def cancel_pending_action(self, action_id: str) -> None:
        pending = self._pending_features.pop(action_id, None)
        if pending is None:
            return
        toggle, applied, detail, previous_detail = pending
        with QSignalBlocker(toggle):
            toggle.setChecked(applied)
        toggle.set_pending(False)
        toggle.setEnabled(bool(toggle.property("supported")))
        detail.setText(previous_detail)

    def shortcut_actions(self) -> tuple[tuple[str, str, bool], ...]:
        return ()

    def apply_payload(self, payload: dict) -> None:
        raise NotImplementedError

    def _install_context_status(self) -> None:
        return

    def reload(self) -> None:
        action = self.by_id.get(self.status_action_id)
        if action is None or self.status_loader.running(action.id):
            return
        self.refresh_button.setEnabled(False)
        self.power_button.setEnabled(False)
        self.state_label.setText("● Verificando…")
        self._set_state("info")
        self.status_loader.fetch_action(action)

    def _set_state(self, state: str) -> None:
        self.state_label.setProperty("state", state)
        self.state_label.style().unpolish(self.state_label)
        self.state_label.style().polish(self.state_label)

    def _set_service_state(self, running: bool, configured: bool, detail: str = "") -> None:
        self._running = running
        self._configured = configured
        if running:
            self.state_label.setText("● Rodando")
            self._set_state("success")
            self.power_button.setText("Parar")
            self.power_button.setObjectName("dangerButton")
        elif configured:
            self.state_label.setText("● Parado")
            self._set_state("info")
            self.power_button.setText("▶ Iniciar")
            self.power_button.setObjectName("primaryButton")
        else:
            self.state_label.setText("● Precisa configurar")
            self._set_state("warning")
            self.power_button.setText("Configurar")
            self.power_button.setObjectName("primaryButton")
        self.state_detail.setText(detail or self.service_subtitle)
        self.power_button.style().unpolish(self.power_button)
        self.power_button.style().polish(self.power_button)
        self.power_button.setEnabled(True)
        for action_id, button in self.shortcut_buttons.items():
            if not configured:
                enabled = action_id == self.setup_action_id or "repair" in action_id
            elif ".open-" in action_id:
                enabled = running
            elif action_id == self.start_action_id:
                enabled = not running
            else:
                enabled = True
            button.setEnabled(enabled)

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id != self.status_action_id or not isinstance(parsed, dict):
            return
        self.refresh_button.setEnabled(True)
        self._payload = parsed
        self.apply_payload(parsed)
        self._pending_features.clear()

    def _on_status_failed(self, action_id: str, _message: str) -> None:
        if action_id != self.status_action_id:
            return
        self.refresh_button.setEnabled(True)
        self._payload = {}
        # Falha de LEITURA não vira "precisa configurar" (estado real desconhecido);
        # e toggles pendentes são liberados para não prender a página.
        for _aid, (toggle, applied, detail, previous_detail) in list(self._pending_features.items()):
            with QSignalBlocker(toggle):
                toggle.set_pending(False)
                toggle.setChecked(applied)
            detail.setText(previous_detail or "—")
        self._pending_features.clear()
        self.refresh_button.setText("Tentar de novo")
        self.state_label.setText("● Indisponível agora")
        self._set_state("warning")
        self.state_detail.setText(
            "Não foi possível ler o estado agora — nada foi alterado. Clique em Tentar de novo."
        )

    def _power_action(self) -> None:
        target = self.stop_action_id if self._running else self.start_action_id if self._configured else self.setup_action_id
        action = self.by_id.get(target)
        if action is not None:
            self.request_action(action)

    def block_while_running(self, running: bool) -> None:
        self.power_button.setEnabled(not running)
        self.refresh_button.setEnabled(not running)
        for toggle, _detail in self.feature_controls:
            toggle.setEnabled(
                not running and bool(toggle.property("supported")) and not bool(toggle.property("pending"))
            )


class WaydroidPage(FriendlyServicePage):
    service_name = "Android com Waydroid"
    service_subtitle = "Aplicativos Android integrados ao desktop"
    service_icon = "phone"
    status_action_id = "waydroid.status"
    start_action_id = "waydroid.launch"
    stop_action_id = "waydroid.stop"
    setup_action_id = "waydroid.install"
    represented_ids = (
        "waydroid.status", "waydroid.launch", "waydroid.stop", "waydroid.install",
        "waydroid.repair", "waydroid.host-access", "waydroid.host-access.remove",
        "waydroid.shares.enable", "waydroid.shares.disable",
        "waydroid.boot.install", "waydroid.boot.remove", "waydroid.plan",
    )

    def feature_titles(self) -> tuple[str, ...]:
        # CCS-015: três contratos distintos — link no host, pastas LXC e USB.
        return (
            "Pasta Android no gerenciador de arquivos",
            "Pastas do host dentro do Android",
            "Barramento USB no Android",
        )

    def feature_actions(self) -> tuple[tuple[str, str], ...]:
        return (
            ("waydroid.host-access", "waydroid.host-access.remove"),
            ("waydroid.shares.enable", "waydroid.shares.disable"),
            ("waydroid.usb.enable", "waydroid.usb.disable"),
        )

    def shortcut_actions(self) -> tuple[tuple[str, str, bool], ...]:
        return (
            ("waydroid.host-access", "Compartilhar arquivos", False),
            ("waydroid.repair", "Reparar", False),
            ("waydroid.launch", "Abrir Android", True),
        )

    def apply_payload(self, payload: dict) -> None:
        config = payload.get("config") if isinstance(payload.get("config"), dict) else {}
        android = payload.get("android") if isinstance(payload.get("android"), dict) else {}
        access = payload.get("access") if isinstance(payload.get("access"), dict) else {}
        host = payload.get("host") if isinstance(payload.get("host"), dict) else {}
        # CCS-005: Rodando = sessão Android ativa, não o container systemd.
        session_running = bool(android.get("sessionRunning"))
        container_active = str(android.get("serviceActive", "")).casefold() == "active"
        configured = bool(config.get("installed") or android.get("initialized"))
        if session_running:
            detail = "Android está pronto para uso"
        elif container_active:
            detail = "Container ativo, mas a sessão Android está parada"
        elif configured:
            detail = "Sessão Android desligada"
        else:
            detail = "Instale as imagens Android para começar"
        self._set_service_state(session_running, configured, detail)
        self.fact_labels[0].setText(f"Imagem: {android.get('imageType') or '—'}")
        self.fact_labels[1].setText("Android inicializado" if android.get("initialized") else "Android ainda não inicializado")
        binder = bool(host.get("binderDevices") or host.get("binderMounted"))
        self.fact_labels[2].setText("Hardware compatível" if binder else "Compatibilidade precisa de revisão")
        mount_count = int(access.get("mountCount") or 0)
        values = (
            (bool(access.get("hostLinked")), "Link gerenciado para o armazenamento Android"),
            (mount_count > 0, f"{mount_count} pasta(s) do host montada(s) via LXC"),
            (bool(access.get("usbBusShared")), "Dispositivos USB visíveis ao Android"),
        )
        for (toggle, detail), (checked, text) in zip(self.feature_controls, values):
            self._apply_feature(toggle, checked, configured)
            detail.setText(text)


class ServerPage(FriendlyServicePage):
    service_name = "Servidor doméstico"
    service_subtitle = "Mídia, arquivos e serviços privados"
    service_icon = "network-server"
    status_action_id = "server.homelab.status"
    start_action_id = "server.homelab.up"
    stop_action_id = "server.homelab.down"
    setup_action_id = "server.homelab.repair"
    represented_ids = (
        "server.homelab.status", "server.homelab.up", "server.homelab.down",
        "server.homelab.up-tailscale",
        "server.homelab.repair", "server.homelab.plan", "server.homelab.open-portainer",
        "server.homelab.open-jellyfin", "server.homelab.open-vaultwarden",
        "server.homelab.open-kuma", "server.homelab.update",
    )

    def feature_titles(self) -> tuple[str, ...]:
        return ("Serviços principais", "Acesso remoto privado")

    def feature_actions(self) -> tuple[tuple[str, str], ...]:
        return (
            ("server.homelab.up", "server.homelab.down"),
            ("server.homelab.up-tailscale", "server.homelab.up"),
        )

    def shortcut_actions(self) -> tuple[tuple[str, str, bool], ...]:
        return (
            ("server.homelab.open-jellyfin", "Abrir mídia", False),
            ("server.homelab.open-vaultwarden", "Abrir cofre", False),
            ("server.homelab.open-kuma", "Ver saúde", False),
            ("homelab.backup", "Criar backup", False),
            ("server.homelab.up", "Iniciar servidor", True),
        )

    def apply_payload(self, payload: dict) -> None:
        stack = payload.get("stack") if isinstance(payload.get("stack"), dict) else {}
        apps = stack.get("apps") if isinstance(stack.get("apps"), list) else []
        running_count = sum(bool(app.get("running")) for app in apps if isinstance(app, dict))
        configured = bool(payload.get("configured") or payload.get("profile") or apps)
        running = bool(payload.get("active") or payload.get("ready") or running_count)
        degraded = bool(payload.get("degraded"))
        guide = guidance(payload)
        if not configured and guide["next_action"]:
            # Envelope v1.17.2: diagnóstico honesto com próximo passo embutido.
            self.state_detail.setText(guide["summary"] or "Servidor ainda não preparado.")
            self.fact_labels[3].setText(f"Próximo passo: {guide['next_action']}")
        self._set_service_state(
            running, configured,
            f"{running_count} serviço(s) rodando" if running else "Serviços desligados; dados preservados" if configured else "Escolha um perfil e prepare o servidor",
        )
        if degraded:
            reasons = guide["reasons"]
            detail = "; ".join(reasons[:2]) if reasons else (guide["summary"] or "")
            self.state_label.setText("● Atenção necessária")
            if detail:
                self.state_detail.setText(detail)
            if guide["next_action"]:
                self.fact_labels[3].setText(f"Próximo passo: {guide['next_action']}")
            self._set_state("warning")
        access = payload.get("accessMode") if isinstance(payload.get("accessMode"), dict) else {}
        backup = payload.get("backupState") if isinstance(payload.get("backupState"), dict) else {}
        self.fact_labels[0].setText(f"Perfil: {payload.get('profile') or 'nenhum'}")
        self.fact_labels[1].setText(f"Aplicativos: {running_count}/{len(apps)} rodando")
        self.fact_labels[2].setText(f"Acesso: {access.get('effective') or 'local'}")
        values = (
            (running_count > 0, f"{running_count} serviço(s) disponível(is)"),
            (str(access.get("effective", "local")) == "tailscale", f"Modo {access.get('effective') or 'local'}"),
        )
        for (toggle, detail), (checked, text) in zip(self.feature_controls, values):
            self._apply_feature(toggle, checked, configured)
            detail.setText(text)
        backup_button = self.shortcut_buttons.get("homelab.backup")
        if backup_button is not None:
            backup_button.setToolTip(
                "Backup verificado disponível" if backup.get("lastBackup") else "Nenhum backup recente"
            )
        host_facts = payload.get("hostFacts") if isinstance(payload.get("hostFacts"), dict) else None
        if host_facts:
            self.apply_host_facts(host_facts)

    def build_extra(self) -> QWidget | None:
        card = QFrame()
        card.setObjectName("settingsCard")
        card.setAccessibleName("Hardware do servidor")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader("Hardware", "Leitura local; dado ausente fica indisponível"))
        self.hw_labels: dict[str, QLabel] = {}
        for key, caption in (
            ("smart", "SMART"),
            ("network", "Rede"),
            ("disk", "Disco"),
            ("temperature", "Temperatura"),
        ):
            label = QLabel(f"{caption}: indisponível")
            label.setObjectName("settingValue")
            label.setWordWrap(True)
            label.setAccessibleName(caption)
            self.hw_labels[key] = label
            layout.addWidget(label)
        layout.addStretch()
        return card

    @staticmethod
    def _fact_line(title: str, block: dict | None, present_text: str | None) -> str:
        if not isinstance(block, dict) or not block.get("available"):
            reason = ""
            if isinstance(block, dict):
                reason = str(block.get("reason") or "")
            suffix = f" ({reason})" if reason else ""
            return f"{title}: indisponível{suffix}"
        if not present_text:
            return f"{title}: indisponível"
        return f"{title}: {present_text}"

    def apply_host_facts(self, payload: dict) -> None:
        if not getattr(self, "hw_labels", None):
            return
        smart = payload.get("smart") if isinstance(payload.get("smart"), dict) else {}
        devices = smart.get("devices") if isinstance(smart.get("devices"), list) else []
        smart_text = None
        if smart.get("available") and devices:
            bits = []
            for item in devices:
                if not isinstance(item, dict):
                    continue
                health = item.get("health")
                if health:
                    bits.append(f"{item.get('device')}: {health}")
            smart_text = ", ".join(bits) if bits else None
        net = payload.get("network") if isinstance(payload.get("network"), dict) else {}
        net_text = net.get("hostname") if net.get("available") else None
        disk = payload.get("disk") if isinstance(payload.get("disk"), dict) else {}
        disk_text = None
        volumes = disk.get("volumes") if isinstance(disk.get("volumes"), list) else []
        if disk.get("available") and volumes:
            first = volumes[0] if isinstance(volumes[0], dict) else {}
            if "usedBytes" in first and "totalBytes" in first:
                disk_text = f"{first.get('mount')} {first.get('usedBytes')}/{first.get('totalBytes')} B"
        temp = payload.get("temperature") if isinstance(payload.get("temperature"), dict) else {}
        temp_text = None
        if temp.get("available") and temp.get("celsius") is not None:
            temp_text = f"{temp.get('celsius')} °C"
        self.hw_labels["smart"].setText(self._fact_line("SMART", smart, smart_text))
        self.hw_labels["network"].setText(self._fact_line("Rede", net, str(net_text) if net_text else None))
        self.hw_labels["disk"].setText(self._fact_line("Disco", disk, disk_text))
        self.hw_labels["temperature"].setText(self._fact_line("Temperatura", temp, temp_text))
