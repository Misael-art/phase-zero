from __future__ import annotations

from PySide6.QtCore import QSignalBlocker, Qt
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSlider,
    QStyle,
    QVBoxLayout,
    QWidget,
)

from ..models import ActionSpec
from ..widgets import SectionHeader, SwitchControl, themed_icon
from .base import BasePage


RUNNING_STATES = {"running", "paused", "in shutdown", "pmsuspended"}


class WindowsVmPage(BasePage):
    """Friendly Windows VM control surface backed by the status JSON contract."""

    _PRIMARY_IDS = {
        "windows.status",
        "windows.launch",
        "windows.guest-login.shutdown",
        "windows.provision.player",
        "windows.optimize",
        "windows.graphics.status",
        "windows.host-access",
        "windows.guest-login.status",
        "windows.provision.cancel",
        "windows.provision.discard",
        "windows.images.manage",
        "windows.boot.install",
        "windows.shares.enable",
        "windows.shares.disable",
        "windows.graphics.enable",
        "windows.graphics.disable",
        "windows.usb.enable",
        "windows.usb.disable",
    }

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._payload: dict = {}
        self._technical_widgets: list[QWidget] = []
        self._integration_actions: dict[SwitchControl, tuple[str, str]] = {}
        self._pending_integrations: dict[str, tuple[SwitchControl, bool, QLabel, str]] = {}
        # UX-004: reflow state; built widgets arrive in build().
        self._narrow_layout: bool | None = None
        self._cards: QGridLayout | None = None
        self._hero_grid: QGridLayout | None = None
        self._perf_card: QFrame | None = None
        self._integration_card: QFrame | None = None

    def build(self) -> None:
        for action_id in self._PRIMARY_IDS:
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        # UX-011: rolar na vertical, nunca na horizontal. Sem isto o
        # conteúdo mantém a largura que quer (em 200% de escala, mais do
        # que a janela) e os controles saem pela lateral em vez de refluir.
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        host = QWidget()
        layout = QVBoxLayout(host)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(14)

        layout.addWidget(self._build_hero())
        cards = QGridLayout()
        cards.setContentsMargins(0, 0, 0, 0)
        cards.setHorizontalSpacing(14)
        cards.setVerticalSpacing(14)
        self._perf_card = self._build_performance()
        self._integration_card = self._build_integrations()
        cards.addWidget(self._perf_card, 0, 0)
        cards.addWidget(self._integration_card, 0, 1)
        cards.setColumnStretch(0, 1)
        cards.setColumnStretch(1, 1)
        self._cards = cards
        layout.addLayout(cards)
        layout.addWidget(self._build_setup_card())
        layout.addWidget(self._build_danger_zone())
        layout.addStretch()
        scroll.setWidget(host)
        self._layout.addWidget(scroll, 1)
        self._page_scroll = scroll

        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def _wide_layout_min_width(self) -> int:
        """Largura que a linha única do hero realmente exige, agora.

        UX-011: um limiar fixo em pixels assume o tamanho de fonte padrão.
        Em 200% os mesmos controles ficam muito maiores, continuam na
        arrumação larga e vazam pela lateral. Perguntar aos widgets o que
        eles precisam faz o reflow acompanhar a escala do sistema.
        """
        def row_width(grid, widgets) -> int:
            present = [widget for widget in widgets if widget is not None]
            if not grid or not present:
                return 0
            margins = grid.contentsMargins()
            return (
                sum(widget.sizeHint().width() for widget in present)
                + grid.horizontalSpacing() * max(0, len(present) - 1)
                + margins.left() + margins.right()
            )

        hero = row_width(self._hero_grid, (
            self._hero_icon, self._hero_copy, self.refresh_button,
            self.install_button, self.power_button,
        ))
        # A linha do card de instalação é a mais larga da arrumação ampla:
        # o texto mais todos os botões de manutenção lado a lado.
        setup = row_width(
            getattr(self, "_setup_grid", None),
            (getattr(self, "_setup_copy", None), *getattr(self, "_setup_buttons", ())),
        )
        return max(1000, hero, setup)

    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt override)
        super().resizeEvent(event)
        if self._cards is None or self._hero_grid is None:
            return
        self._apply_reflow(self.width() < self._wide_layout_min_width())

    def _reflow_hero(self, narrow: bool) -> None:
        g = self._hero_grid
        g.addWidget(self._hero_icon, 0, 0)
        g.addWidget(self._hero_copy, 0, 1)
        if narrow:
            g.addWidget(self.refresh_button, 1, 1)
            g.addWidget(self.install_button, 2, 1)
            g.addWidget(self.power_button, 3, 1)
        else:
            g.addWidget(self.refresh_button, 0, 2)
            g.addWidget(self.install_button, 0, 3)
            g.addWidget(self.power_button, 0, 4)
        g.setColumnStretch(0, 0)
        g.setColumnStretch(1, 1)
        for col in (2, 3, 4):
            g.setColumnStretch(col, 0)

    def _apply_reflow(self, narrow: bool) -> None:
        if narrow == self._narrow_layout:
            return
        self._narrow_layout = narrow
        self._reflow_hero(narrow)
        if self._cards is not None:
            # Cards: side by side (wide) or one per row spanning both columns.
            if narrow:
                self._cards.addWidget(self._perf_card, 0, 0, 1, 2)
                self._cards.addWidget(self._integration_card, 1, 0, 1, 2)
            else:
                self._cards.addWidget(self._perf_card, 0, 0)
                self._cards.addWidget(self._integration_card, 0, 1)
        if getattr(self, "_setup_grid", None) is not None:
            self._reflow_setup(narrow)

    def _build_hero(self) -> QFrame:
        hero = QFrame()
        hero.setObjectName("serviceHero")
        # UX-004: the whole hero is one grid so the reflow can move icon,
        # copy and actions between the wide (single row) and narrow
        # (stacked) arrangements without leaving anything side by side.
        self._hero_grid = QGridLayout(hero)
        self._hero_grid.setContentsMargins(20, 18, 20, 18)
        self._hero_grid.setHorizontalSpacing(16)
        self._hero_grid.setVerticalSpacing(10)
        icon = QLabel()
        icon.setObjectName("serviceIcon")
        icon.setPixmap(themed_icon(hero, "computer", QStyle.SP_ComputerIcon).pixmap(38, 38))
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(58, 58)
        self._hero_icon = icon
        copy = QVBoxLayout()
        copy.setSpacing(3)
        title = QLabel("Windows 11 VM")
        title.setObjectName("serviceTitle")
        self.state_label = QLabel("● Verificando…")
        self.state_label.setObjectName("serviceState")
        self.state_label.setProperty("state", "info")
        self.state_detail = QLabel("Lendo configuração e estado da máquina virtual")
        self.state_detail.setObjectName("cardDescription")
        self.state_detail.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(self.state_label)
        copy.addWidget(self.state_detail)
        self._hero_copy = QWidget()
        self._hero_copy.setLayout(copy)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.setObjectName("secondaryButton")
        self.refresh_button.clicked.connect(self.reload)
        self.install_button = QPushButton("Instalar automaticamente")
        self.install_button.setObjectName("secondaryButton")
        self.install_button.setMinimumHeight(50)
        self.install_button.clicked.connect(lambda: self.run_action("windows.provision.player"))
        self.power_button = QPushButton("Iniciar VM")
        self.power_button.setObjectName("primaryButton")
        self.power_button.setMinimumSize(150, 50)
        self.power_button.setEnabled(False)
        self.power_button.clicked.connect(self._power_action)
        self._apply_reflow(bool(self._narrow_layout))
        return hero

    def _build_performance(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Desempenho", "Recursos reservados para o Windows"))
        self.ram_value = QLabel("Memória: —")
        self.ram_value.setObjectName("settingValue")
        self.ram_slider = QSlider(Qt.Horizontal)
        self.ram_slider.setRange(4, 32)
        self.ram_slider.setEnabled(False)
        self.ram_slider.setAccessibleName("Memória configurada em gigabytes")
        self.cpu_value = QLabel("Processadores: —")
        self.cpu_value.setObjectName("settingValue")
        self.cpu_slider = QSlider(Qt.Horizontal)
        self.cpu_slider.setRange(2, 16)
        self.cpu_slider.setEnabled(False)
        self.cpu_slider.setAccessibleName("Processadores configurados")
        layout.addWidget(self.ram_value)
        layout.addWidget(self.ram_slider)
        layout.addWidget(self.cpu_value)
        layout.addWidget(self.cpu_slider)
        # CCS-020: leitura honesta — os sliders exibem o estado, não editam.
        for slider in (self.ram_slider, self.cpu_slider):
            slider.setToolTip("Somente leitura; ajuste pelo assistente de instalação")
            slider.setAccessibleDescription("Somente leitura; ajuste pelo assistente de instalação")
        hint = QLabel("Exibição somente leitura; ajustes ficam no assistente de instalação.")
        hint.setObjectName("cardDescription")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        edit = QPushButton("Ajustar com segurança")
        edit.setObjectName("secondaryButton")
        edit.clicked.connect(lambda: self.run_action("windows.provision.player"))
        layout.addWidget(edit)
        return card

    def _integration_switch(self, title: str, description: str) -> tuple[QWidget, SwitchControl, QLabel]:
        row = QWidget()
        layout = QHBoxLayout(row)
        layout.setContentsMargins(0, 4, 0, 4)
        copy = QVBoxLayout()
        name = QLabel(title)
        name.setObjectName("settingValue")
        note = QLabel(description)
        note.setObjectName("cardDescription")
        note.setWordWrap(True)
        copy.addWidget(name)
        copy.addWidget(note)
        toggle = SwitchControl()
        toggle.setEnabled(False)
        toggle.setAccessibleName(title)
        layout.addLayout(copy, 1)
        layout.addWidget(toggle)
        return row, toggle, note

    def _build_integrations(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader("Dispositivos e integração", "Recursos conectados ao Windows"))
        share, self.share_toggle, self.share_note = self._integration_switch(
            "Compartilhar arquivos", "Pasta de troca entre Linux e Windows"
        )
        gpu, self.gpu_toggle, self.gpu_note = self._integration_switch(
            "Aceleração de vídeo", "Usa o perfil gráfico compatível disponível"
        )
        usb, self.usb_toggle, self.usb_note = self._integration_switch(
            "Dispositivos USB", "Libera periféricos permitidos para a VM"
        )
        layout.addWidget(share)
        layout.addWidget(gpu)
        layout.addWidget(usb)
        self._bind_integration_toggle(self.share_toggle, "windows.shares.enable", "windows.shares.disable")
        self._bind_integration_toggle(self.gpu_toggle, "windows.graphics.enable", "windows.graphics.disable")
        self._bind_integration_toggle(self.usb_toggle, "windows.usb.enable", "windows.usb.disable")
        configure = QPushButton("Atualizar integrações")
        configure.setObjectName("secondaryButton")
        configure.clicked.connect(self.reload)
        layout.addWidget(configure)
        return card

    def _bind_integration_toggle(self, toggle: SwitchControl, enable_id: str, disable_id: str) -> None:
        self._integration_actions[toggle] = (enable_id, disable_id)
        toggle.toggled.connect(lambda checked, control=toggle: self._integration_toggle_requested(control, checked))

    def _integration_toggle_requested(self, toggle: SwitchControl, checked: bool) -> None:
        applied = bool(toggle.property("applied"))
        if checked == applied:
            return
        enable_id, disable_id = self._integration_actions[toggle]
        action_id = enable_id if checked else disable_id
        note = self.share_note if toggle is self.share_toggle else self.gpu_note if toggle is self.gpu_toggle else self.usb_note
        previous_note = note.text()
        toggle.set_pending(True)
        toggle.setEnabled(False)
        note.setText("Aguardando confirmação…")
        self._pending_integrations[action_id] = (toggle, applied, note, previous_note)
        self.run_action(action_id)

    @staticmethod
    def _apply_toggle(toggle: SwitchControl, checked: bool, enabled: bool = True) -> None:
        with QSignalBlocker(toggle):
            toggle.setChecked(checked)
            toggle.setProperty("applied", checked)
            toggle.setProperty("supported", enabled)
            toggle.set_pending(False)
            toggle.setEnabled(enabled)

    def cancel_pending_action(self, action_id: str) -> None:
        pending = self._pending_integrations.pop(action_id, None)
        if pending is None:
            return
        toggle, applied, note, previous_note = pending
        with QSignalBlocker(toggle):
            toggle.setChecked(applied)
        toggle.set_pending(False)
        toggle.setEnabled(bool(toggle.property("supported")))
        note.setText(previous_note)

    def _build_setup_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        # UX-004: one grid — copy stays at (0,0) and the reflow moves the
        # maintenance buttons between the wide side-by-side row and the
        # narrow stacked column, so the card no longer dictates 785px.
        self._setup_grid = QGridLayout(card)
        self._setup_grid.setContentsMargins(16, 14, 16, 14)
        self._setup_grid.setHorizontalSpacing(10)
        self._setup_grid.setVerticalSpacing(10)
        copy = QVBoxLayout()
        title = QLabel("Instalação e manutenção")
        title.setObjectName("sectionHeading")
        desc = QLabel("Prepare uma nova VM, revise compatibilidade ou otimize o host.")
        desc.setObjectName("cardDescription")
        desc.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(desc)
        self.maintenance_health = QLabel("Verificando saúde da instalação…")
        self.maintenance_health.setObjectName("cardDescription")
        self.maintenance_health.setWordWrap(True)
        copy.addWidget(self.maintenance_health)
        self._setup_copy = QWidget()
        self._setup_copy.setLayout(copy)
        self._setup_grid.addWidget(self._setup_copy, 0, 0)
        self._setup_buttons = []
        self.repair_boot_button = QPushButton("Atualizar boot direto")
        self.repair_boot_button.setObjectName("secondaryButton")
        self.repair_boot_button.clicked.connect(lambda: self.run_action("windows.boot.install"))
        self.repair_boot_button.setVisible(False)
        self._setup_buttons.append(self.repair_boot_button)
        self.dock_entry_button = QPushButton("GRUB: Windows (Dock)")
        self.dock_entry_button.setObjectName("secondaryButton")
        self.dock_entry_button.setCheckable(True)
        self.dock_entry_button.setToolTip(
            "Adiciona/remove a entrada GRUB dedicada que inicia a VM sempre no monitor da dock"
        )
        self.dock_entry_button.clicked.connect(
            lambda: self.run_action(
                "windows.boot.dock.enable" if self.dock_entry_button.isChecked()
                else "windows.boot.dock.disable"
            )
        )
        self._setup_buttons.append(self.dock_entry_button)
        images = QPushButton("Gerenciar imagens")
        images.setObjectName("secondaryButton")
        images.clicked.connect(lambda: self.run_action("windows.images.manage"))
        install = QPushButton("Preparar Windows")
        install.setObjectName("primaryButton")
        install.clicked.connect(lambda: self.run_action("windows.provision.player"))
        optimize = QPushButton("Otimizar")
        optimize.setObjectName("secondaryButton")
        optimize.clicked.connect(lambda: self.run_action("windows.optimize"))
        self._setup_buttons += [images, optimize, install]
        self._reflow_setup(bool(self._narrow_layout))
        return card

    def _reflow_setup(self, narrow: bool) -> None:
        for index, btn in enumerate(self._setup_buttons):
            if narrow:
                self._setup_grid.addWidget(btn, index + 1, 0)
            else:
                self._setup_grid.addWidget(btn, 0, index + 1)
        self._setup_grid.setColumnStretch(0, 1)
        for col in range(1, len(self._setup_buttons) + 1):
            self._setup_grid.setColumnStretch(col, 0)

    def _build_danger_zone(self) -> QFrame:
        zone = QFrame()
        zone.setObjectName("dangerZone")
        layout = QVBoxLayout(zone)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Zona de perigo",
            "Ações destrutivas exigem prévia e confirmação digitada.",
        ))
        buttons = QHBoxLayout()
        cancel = QPushButton("Cancelar instalação")
        cancel.setObjectName("dangerOutlineButton")
        cancel.clicked.connect(lambda: self.run_action("windows.provision.cancel"))
        discard = QPushButton("Descartar instalação")
        discard.setObjectName("dangerButton")
        discard.clicked.connect(lambda: self.run_action("windows.provision.discard"))
        buttons.addWidget(cancel)
        buttons.addWidget(discard)
        buttons.addStretch()
        layout.addLayout(buttons)
        return zone

    def _install_context_status(self) -> None:
        return  # Hero owns the status surface.

    def reload(self) -> None:
        action = self.by_id.get("windows.status")
        if action is None or self.status_loader.running(action.id):
            return
        self.refresh_button.setEnabled(False)
        self.state_label.setText("● Verificando…")
        self._set_state("info")
        self.status_loader.fetch_action(action)

    def focus_journey(self, key: str) -> None:
        """UX-006: "Instalar e usar Windows" lands on the install entry.

        The hero's install control is the entry point of the installation
        journey, so arriving from the goal card brings it forward instead
        of leaving the operator to find it among the maintenance switches.
        """
        if key != "install":
            return
        install = getattr(self, "install_button", None)
        if install is None:
            return
        install.setFocus(Qt.FocusReason.OtherFocusReason)
        scroll = self.findChild(QScrollArea)
        if scroll is not None:
            scroll.ensureWidgetVisible(install)

    def _set_state(self, state: str) -> None:
        self.state_label.setProperty("state", state)
        self.state_label.style().unpolish(self.state_label)
        self.state_label.style().polish(self.state_label)

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id != "windows.status" or not isinstance(parsed, dict):
            return
        self.refresh_button.setEnabled(True)
        self._payload = parsed
        vm = parsed.get("vm") if isinstance(parsed.get("vm"), dict) else {}
        libvirt = parsed.get("libvirt") if isinstance(parsed.get("libvirt"), dict) else {}
        access = parsed.get("access") if isinstance(parsed.get("access"), dict) else {}
        host = parsed.get("host") if isinstance(parsed.get("host"), dict) else {}
        health = parsed.get("health") if isinstance(parsed.get("health"), dict) else {}
        findings = health.get("findings") if isinstance(health.get("findings"), list) else []
        state = str(libvirt.get("state", "missing")).strip().casefold()
        running = state in RUNNING_STATES
        configured = bool((parsed.get("config") or {}).get("installed"))
        disk_exists = bool(vm.get("diskExists"))
        disk_ready = bool(health.get("readyToLaunch")) if "readyToLaunch" in health else bool(vm.get("installedLike")) or bool(
            ((parsed.get("discovery") or {}).get("discoveredUsableDisk") or {}).get("usable")
        )
        if running:
            self.state_label.setText("● Rodando")
            self.state_detail.setText("Windows está ligado e pronto para uso")
            self._set_state("success")
            self.power_button.setText("Desligar")
            self.power_button.setObjectName("dangerButton")
        elif configured and disk_ready:
            self.state_label.setText("● Parado")
            self.state_detail.setText("Máquina pronta para iniciar")
            self._set_state("info")
            self.power_button.setText("▶ Iniciar VM")
            self.power_button.setObjectName("primaryButton")
        elif configured and disk_exists:
            self.state_label.setText("● Instalação incompleta")
            self.state_detail.setText("O disco existe, mas ainda não contém um Windows inicializável")
            self._set_state("warning")
            self.power_button.setText("Iniciar VM")
            self.power_button.setObjectName("primaryButton")
        else:
            self.state_label.setText("● Precisa configurar")
            self.state_detail.setText("Prepare o Windows antes do primeiro uso")
            self._set_state("warning")
            self.power_button.setText("Iniciar VM")
            self.power_button.setObjectName("primaryButton")
        self.power_button.style().unpolish(self.power_button)
        self.power_button.style().polish(self.power_button)
        self.power_button.setEnabled(running or (configured and disk_ready))
        boot_block = parsed.get("boot") or {}
        if hasattr(self, "dock_entry_button"):
            self.dock_entry_button.setChecked(bool(boot_block.get("dockEntryInstalled")))
        boot_stale = any(
            isinstance(item, dict) and item.get("id") == "boot-runtime-stale" for item in findings
        ) or bool(boot_block.get("bootRuntimeStale")) or bool(boot_block.get("bootRuntimePendingSync"))
        guest_unclean = any(
            isinstance(item, dict) and item.get("id") == "guest-unclean-shutdown" for item in findings
        )
        if not disk_ready:
            self.maintenance_health.setText("Ação necessária: conclua a instalação antes de iniciar a VM.")
        elif guest_unclean:
            self.maintenance_health.setText(
                "Windows foi desligado de forma inesperada. Inicie e deixe o reparo automático "
                "concluir — pode levar alguns minutos."
            )
        elif boot_stale:
            self.maintenance_health.setText("Atenção: boot direto desatualizado; a inicialização normal continua disponível.")
        else:
            self.maintenance_health.setText("VM pronta; componentes essenciais verificados.")
        self.repair_boot_button.setVisible(boot_stale)
        ram_mb = int(vm.get("ramMb") or 0)
        cpus = int(vm.get("cpus") or 0)
        self.ram_value.setText(f"Memória: {ram_mb / 1024:g} GB" if ram_mb else "Memória: —")
        self.ram_slider.setMaximum(max(4, 32, (ram_mb + 1023) // 1024))
        self.ram_slider.setValue(max(4, (ram_mb + 1023) // 1024) if ram_mb else 4)
        self.cpu_value.setText(f"Processadores: {cpus}" if cpus else "Processadores: —")
        self.cpu_slider.setMaximum(max(2, 16, cpus))
        self.cpu_slider.setValue(max(2, cpus) if cpus else 2)
        share_ready = bool(
            access.get("shareLinksReady")
            and access.get("sambaManaged")
            and access.get("sambaPolicyCompliant")
            and access.get("sambaReachable")
        )
        self._apply_toggle(self.share_toggle, share_ready)
        if share_ready:
            policy = str(access.get("sharePolicy") or "minimal")
            self.share_note.setText(
                "Pasta de troca disponível; pastas extras somente leitura"
                if policy == "full" and not access.get("shareWritable")
                else "Pasta de troca disponível no Linux e no Windows"
            )
        else:
            self.share_note.setText("Integração incompleta; ative para reparar configuração e acesso")
        profile = str(vm.get("graphicsProfile") or "compat")
        gpu_available = bool(host.get("qemu"))
        self._apply_toggle(self.gpu_toggle, gpu_available and profile != "compat", gpu_available)
        if not gpu_available:
            self.gpu_note.setText(
                "QEMU ausente no host — instale o runtime em Windows VM → Preparar (perfil windows-vm-linux)"
            )
        else:
            self.gpu_note.setText(f"Perfil ativo: {profile}")
        usb_ready = int(access.get("usbRedirChannels") or 0) > 0 or bool(access.get("usbUdevManaged"))
        self._apply_toggle(self.usb_toggle, usb_ready)
        if usb_ready:
            self.usb_note.setText("Permissões prontas; canais USB abrem quando a VM inicia")
        else:
            self.usb_note.setText("Desativado até configurar permissões seguras")
        self._pending_integrations.clear()

    def _on_status_failed(self, action_id: str, message: str) -> None:
        if action_id != "windows.status":
            return
        self.refresh_button.setEnabled(True)
        self.power_button.setEnabled(False)
        self.state_label.setText("● Estado indisponível")
        if message == "timed out":
            self.state_detail.setText("A verificação demorou demais. Tente atualizar novamente.")
        else:
            self.state_detail.setText("Não foi possível consultar o host. Tente atualizar novamente.")
        self.maintenance_health.setText("Falha temporária de leitura; nenhuma configuração da VM foi alterada.")
        self._set_state("error")

    def _guest_agent_at_risk(self) -> bool:
        """CCS-020: sessão desligada sem QGA — iniciar e matar em 120s suja o NTFS."""
        health = self._payload.get("health") if isinstance(self._payload.get("health"), dict) else {}
        findings = health.get("findings") if isinstance(health.get("findings"), list) else []
        return any(
            isinstance(item, dict) and item.get("id") == "guest-unclean-shutdown"
            for item in findings
        )

    def _confirm_risky_launch(self) -> bool:
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Warning)
        box.setWindowTitle("Windows não foi desligado corretamente")
        box.setText(
            "O agente convidado (QGA) não respondeu no último desligamento. "
            "Se a VM for fechada à força depois de iniciar, o disco pode ficar marcado como sujo."
        )
        box.setInformativeText(
            "Recomendado: inicie e deixe o Reparo Automático do Windows terminar, "
            "depois use \"Desligar\" dentro da própria VM."
        )
        confirm = box.addButton("Iniciar mesmo assim", QMessageBox.AcceptRole)
        box.addButton("Cancelar", QMessageBox.RejectRole)
        box.exec()
        return box.clickedButton() is confirm

    def _power_action(self) -> None:
        libvirt = self._payload.get("libvirt") if isinstance(self._payload.get("libvirt"), dict) else {}
        state = str(libvirt.get("state", "missing")).strip().casefold()
        config = self._payload.get("config") if isinstance(self._payload.get("config"), dict) else {}
        vm = self._payload.get("vm") if isinstance(self._payload.get("vm"), dict) else {}
        if state in RUNNING_STATES:
            self.run_action("windows.guest-login.shutdown")
            return
        disk_ready = bool(
            ((self._payload.get("health") or {}).get("readyToLaunch"))
            if isinstance(self._payload.get("health"), dict) and "readyToLaunch" in self._payload.get("health", {})
            else vm.get("installedLike")
            or (((self._payload.get("discovery") or {}).get("discoveredUsableDisk") or {}).get("usable"))
        )
        if not (config.get("installed") and disk_ready):
            return
        # CCS-020: QGA indisponível no último ciclo exige confirmação explícita.
        if self._guest_agent_at_risk() and not self._confirm_risky_launch():
            return
        self.run_action("windows.launch")

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for widget in self._technical_widgets:
            widget.setVisible(enabled)

    def block_while_running(self, running: bool) -> None:
        self.power_button.setEnabled(not running)
        self.refresh_button.setEnabled(not running)
        self.install_button.setEnabled(not running)
        self.repair_boot_button.setEnabled(not running)
        for toggle in self._integration_actions:
            toggle.setEnabled(
                not running and bool(toggle.property("supported")) and not bool(toggle.property("pending"))
            )
