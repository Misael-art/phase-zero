from __future__ import annotations

import json
import time
from pathlib import Path

from PySide6.QtCore import QProcess, QTimer, Qt, Signal
from PySide6.QtGui import QAction, QCloseEvent, QIcon, QKeySequence, QResizeEvent, QTextCursor
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSizeGrip,
    QStackedWidget,
    QStyle,
    QVBoxLayout,
    QWidget,
)

from .catalog import (
    CATEGORIES, DASHBOARD, NESTED_CATEGORIES, NESTED_CATEGORY_PARENTS,
    SIDEBAR_GROUPS, build_catalog,
)
from .command_runner import CommandRunner
from .models import ActionSpec, OperationResult
from .product_inventory import target_for
from .provision_player import ProvisionPlayerWindow
from .windows_install_dialog import WindowsInstallDialog
from .preferences import UiPreferences
from .pages.registry import PageRegistry
from .result_parser import restart_required, severity_for
from .widgets import (
    ActionInspector,
    ActionListRow,
    Breadcrumb,
    HeaderBar,
    ParameterDialog,
    PreviewDialog,
    ProgressDialog,
    ResultDialog,
    SwitchControl,
    Toast,
    themed_icon,
)



def _repolish_widget(widget: QWidget) -> None:
    widget.style().unpolish(widget)
    widget.style().polish(widget)

class MainWindow(QMainWindow):
    theme_changed = Signal(str)

    def __init__(self, root: Path, *, initial_category: str = "") -> None:
        super().__init__()
        self.root = root
        self.catalog = build_catalog(root)
        self.by_id = {action.id: action for action in self.catalog}
        self.cat_meta = {row[0]: row for row in (DASHBOARD, *CATEGORIES)}
        self.runner = CommandRunner(root, self)
        self.current_category = initial_category or DASHBOARD[0]
        self._product_origin_state = None
        self.pending_action: ActionSpec | None = None
        self.pending_value = ""
        self.pending_values: dict[str, str] = {}
        self._action_queue: list[ActionSpec] = []
        self.sidebar_buttons: dict[str, QPushButton] = {}
        self.dark_theme = True
        self._maximized = False
        self._start_failed = False
        self._search_cards: list[QWidget] = []
        self._controls_compact: bool | None = None
        self._graphics_probe: QProcess | None = None
        self._host_process: QProcess | None = None
        self._closing = False
        self.progress_dialog: ProgressDialog | None = None
        self._operation_started_at: float | None = None
        self._failure_count = 0
        self.preferences = UiPreferences(self)
        self._elapsed_timer = QTimer(self)
        self._elapsed_timer.setInterval(1000)
        self._elapsed_timer.timeout.connect(self._update_elapsed)
        self._search_relayout_timer = QTimer(self)
        self._search_relayout_timer.setSingleShot(True)
        self._search_relayout_timer.setInterval(120)
        self._search_relayout_timer.timeout.connect(self.rebuild_search)

        self.setWindowTitle("PhaseZero — Central de Controle")
        # The compact layout keeps navigation and controls available down to the
        # smallest documented high-DPI viewport. Page content scrolls vertically.
        self.setMinimumSize(400, 280)
        self.resize(1280, 800)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.Window)
        self._build_ui()
        self._connect_runner()
        self._install_shortcuts()
        self.show_category(self.current_category)

    def _build_ui(self) -> None:
        shell = QFrame()
        shell.setObjectName("appShell")
        self.setCentralWidget(shell)
        shell_layout = QVBoxLayout(shell)
        shell_layout.setContentsMargins(1, 1, 1, 1)
        shell_layout.setSpacing(0)

        header = HeaderBar()
        header.minimize_requested.connect(self.showMinimized)
        header.maximize_requested.connect(self.toggle_maximize)
        header.close_requested.connect(self.close)
        shell_layout.addWidget(header)

        body = QWidget()
        body_layout = QHBoxLayout(body)
        body_layout.setContentsMargins(0, 0, 0, 0)
        body_layout.setSpacing(0)
        shell_layout.addWidget(body, 1)

        sidebar = QFrame()
        sidebar.setObjectName("sidebar")
        sidebar.setFixedWidth(230)
        self.sidebar = sidebar
        sidebar_scroll = QScrollArea()
        sidebar_scroll.setWidgetResizable(True)
        sidebar_scroll.setFrameShape(QFrame.NoFrame)
        sidebar_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        sidebar_inner = QWidget()
        sidebar_layout = QVBoxLayout(sidebar_inner)
        sidebar_layout.setContentsMargins(12, 8, 10, 12)
        sidebar_layout.setSpacing(3)
        # EmuDeck-style grouped sidebar: section captions + icon-and-text items.
        self._section_labels: list[QLabel] = []
        self._sidebar_rail: bool | None = None
        for group_title, categories in SIDEBAR_GROUPS:
            section = QLabel(group_title.upper())
            section.setObjectName("sectionLabel")
            sidebar_layout.addWidget(section)
            self._section_labels.append(section)
            for category in categories:
                meta = self.cat_meta.get(category)
                if meta is None:
                    continue
                button = QPushButton(category.replace("&", "&&"))
                button.setObjectName("sidebarButton")
                button.setCheckable(True)
                button.setCursor(Qt.PointingHandCursor)
                button.setToolTip(meta[2])
                button.setAccessibleName(f"Abrir {category}")
                button.setAccessibleDescription(meta[2])
                fallback_icons = {
                    "Início": QStyle.SP_DirHomeIcon,
                    "Visão geral": QStyle.SP_DialogApplyButton,
                    "Perfis": QStyle.SP_FileDialogListView,
                    "Steam Deck": QStyle.SP_DriveDVDIcon,
                    "Windows VM": QStyle.SP_ComputerIcon,
                    "Waydroid": QStyle.SP_DriveHDIcon,
                    "Servidor": QStyle.SP_DriveNetIcon,
                    "Homelab": QStyle.SP_DriveNetIcon,
                    "Emulação": QStyle.SP_DriveDVDIcon,
                    "Boot Direto": QStyle.SP_BrowserReload,
                    "Flatpak": QStyle.SP_DriveHDIcon,
                    "Recursos": QStyle.SP_DesktopIcon,
                    "Ajustes": QStyle.SP_FileDialogDetailedView,
                    "IA & Dev": QStyle.SP_CommandLink,
                    "Proxies IA": QStyle.SP_DriveNetIcon,
                    "Aplicativos": QStyle.SP_DirIcon,
                    "Resultados": QStyle.SP_FileDialogInfoView,
                }
                button.setIcon(themed_icon(self, meta[1], fallback_icons.get(category, QStyle.SP_FileIcon)))
                button.clicked.connect(lambda _checked=False, name=category: self.show_category(name))
                self.sidebar_buttons[category] = button
                sidebar_layout.addWidget(button)
        sidebar_layout.addStretch()
        sidebar_scroll.setWidget(sidebar_inner)
        outer_sidebar_layout = QVBoxLayout(sidebar)
        outer_sidebar_layout.setContentsMargins(0, 10, 0, 0)
        outer_sidebar_layout.setSpacing(0)
        outer_sidebar_layout.addWidget(sidebar_scroll, 1)
        self.system_label = QLabel("Host: verificando…")
        self.system_label.setObjectName("sidebarStatus")
        self.system_label.setWordWrap(True)
        outer_sidebar_layout.addWidget(self.system_label)
        body_layout.addWidget(sidebar)

        main = QWidget()
        main.setObjectName("content")
        main_layout = QVBoxLayout(main)
        main_layout.setContentsMargins(24, 18, 24, 14)
        main_layout.setSpacing(14)
        body_layout.addWidget(main, 1)

        self.breadcrumb = Breadcrumb()
        main_layout.addWidget(self.breadcrumb)

        top = QVBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        top.setSpacing(6)
        title_row = QHBoxLayout()
        title_box = QVBoxLayout()
        self.page_title = QLabel()
        self.page_title.setObjectName("pageTitle")
        self.page_subtitle = QLabel()
        self.page_subtitle.setObjectName("pageSubtitle")
        title_box.addWidget(self.page_title)
        title_box.addWidget(self.page_subtitle)
        title_row.addLayout(title_box)
        title_row.addStretch()
        self.compact_menu = QPushButton("Menu")
        self.compact_menu.setObjectName("secondaryButton")
        self.compact_menu.setAccessibleName("Abrir navegação")
        self.compact_menu.setToolTip("Abrir páginas da Central de Controle")
        navigation_menu = QMenu(self.compact_menu)
        for _group_title, categories in SIDEBAR_GROUPS:
            for category in categories:
                if category not in self.cat_meta:
                    continue
                item = navigation_menu.addAction(category)
                item.triggered.connect(lambda _checked=False, name=category: self.show_category(name))
        self.compact_menu.setMenu(navigation_menu)
        self.compact_menu.hide()
        title_row.addWidget(self.compact_menu)
        top.addLayout(title_row)
        self.controls_layout = QGridLayout()
        self.controls_layout.setHorizontalSpacing(8)
        self.controls_layout.setVerticalSpacing(6)
        self.search = QLineEdit()
        self.search.setObjectName("searchBox")
        self.search.setPlaceholderText("Buscar ação, perfil ou módulo…")
        self.search.setClearButtonEnabled(True)
        self.search.setMinimumWidth(160)
        self.search.setMinimumHeight(25)
        self.search.setAccessibleName("Busca de ações")
        self.search.textChanged.connect(self.on_search)
        self.controls_layout.addWidget(self.search, 0, 0)
        self.mode_label = QLabel("Modo avançado")
        self.mode_label.setObjectName("modeSwitchLabel")
        self.controls_layout.addWidget(self.mode_label, 0, 1)
        self.mode_switch = SwitchControl()
        self.mode_switch.setObjectName("modeSwitch")
        self.mode_switch.setAccessibleName("Modo avançado")
        self.mode_switch.setToolTip("Revela comandos, logs e operações técnicas")
        self.mode_switch.setAccessibleDescription(
            "Desativado por padrão. Ative para mostrar comandos, logs e ações avançadas."
        )
        self.mode_switch.setChecked(self.preferences.advanced_mode)
        self.mode_switch.toggled.connect(self._set_advanced_mode)
        self.controls_layout.addWidget(self.mode_switch, 0, 2)
        self.theme_button = QPushButton()
        self.theme_button.setObjectName("iconButton")
        self.theme_button.setToolTip("Alternar tema")
        self.theme_button.setMinimumHeight(25)
        theme_icon = QIcon.fromTheme("weather-clear-night")
        if theme_icon.isNull():
            self.theme_button.setText("◐")
        else:
            self.theme_button.setIcon(theme_icon)
        self.theme_button.clicked.connect(self.toggle_theme)
        self.theme_button.setAccessibleName("Alternar tema claro ou escuro")
        self.controls_layout.addWidget(self.theme_button, 0, 3)
        self.controls_layout.setColumnStretch(0, 1)
        top.addLayout(self.controls_layout)
        main_layout.addLayout(top)

        reboot_marker = Path("/run/reboot-required")
        if not reboot_marker.exists():
            reboot_marker = Path("/var/run/reboot-required")
        if reboot_marker.exists():
            banner = QFrame()
            banner.setObjectName("warningBanner")
            banner_layout = QHBoxLayout(banner)
            banner_layout.setContentsMargins(12, 8, 12, 8)
            warning = QLabel("Reboot pendente. Conclua reinicialização antes de mudanças de sistema.")
            warning.setObjectName("warningText")
            banner_layout.addWidget(warning)
            banner_layout.addStretch()
            main_layout.addWidget(banner)

        self.registry = PageRegistry(self.root, self.runner)
        for page in self.registry.pages():
            page.action_requested.connect(self.request_action)
            page.actions_requested.connect(self.request_actions)
            page.action_selected.connect(self.inspect_action)
            page.category_requested.connect(self.show_journey)
        product_page = self.registry.page_for("Aplicativos")
        if product_page is not None and hasattr(product_page, "product_opened"):
            product_page.product_opened.connect(self._product_opened)
            product_page.comparison_opened.connect(self._product_comparison_opened)
            product_page.back_requested.connect(self._product_back)
            product_page.desktop_entry_requested.connect(self._launch_product_desktop_entry)
        development_page = self.registry.page_for("Desenvolvimento")
        if development_page is not None and hasattr(development_page, "product_requested"):
            development_page.product_requested.connect(self.open_product)
        self.stack = QStackedWidget()
        # Keep nested technical pages in the stack without exposing them as
        # peer destinations in the sidebar or compact navigation menu.
        for category in (DASHBOARD[0], *(row[0] for row in CATEGORIES)):
            page = self.registry.page_for(category)
            if page is not None:
                self.stack.addWidget(page)
        # Search results page (keeps old ActionCard grid for cross-category search).
        self.search_page = QWidget()
        sp_layout = QVBoxLayout(self.search_page)
        sp_layout.setContentsMargins(0, 0, 0, 0)
        self.search_scroll = QScrollArea()
        self.search_scroll.setWidgetResizable(True)
        self.search_scroll.setFrameShape(QFrame.NoFrame)
        self.search_host = QWidget()
        self.search_grid = QGridLayout(self.search_host)
        self.search_grid.setContentsMargins(0, 4, 6, 8)
        self.search_grid.setHorizontalSpacing(14)
        self.search_grid.setVerticalSpacing(14)
        self.search_scroll.setWidget(self.search_host)
        sp_layout.addWidget(self.search_scroll)
        self.stack.addWidget(self.search_page)
        self._search_page_idx = self.stack.count() - 1
        workspace = QHBoxLayout()
        workspace.setSpacing(14)
        workspace.addWidget(self.stack, 1)
        self.inspector = ActionInspector()
        self.inspector.requested.connect(self.request_action)
        self.inspector.hide()
        workspace.addWidget(self.inspector)
        main_layout.addLayout(workspace, 1)

        operation = QFrame()
        operation.setObjectName("operationPanel")
        operation.setAccessibleName("Operação atual")
        operation_layout = QVBoxLayout(operation)
        operation_layout.setContentsMargins(14, 10, 14, 10)
        operation_layout.setSpacing(8)
        status_row = QHBoxLayout()
        self.status_dot = QLabel("●")
        self.status_dot.setObjectName("statusIdle")
        self.status_text = QLabel("Pronto")
        self.status_text.setObjectName("statusText")
        self.elapsed_label = QLabel("")
        self.elapsed_label.setObjectName("operationElapsed")
        self.command_label = QLabel("")
        self.command_label.setObjectName("pathLabel")
        self.command_label.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.cancel_button = QPushButton("Cancelar")
        self.cancel_button.setObjectName("dangerButton")
        self.cancel_button.setEnabled(False)
        self.cancel_button.clicked.connect(self.confirm_cancel)
        self.cancel_button.setAccessibleDescription("Interrompe processo em andamento (pede confirmação)")
        self.show_progress_button = QPushButton("Mostrar progresso")
        self.show_progress_button.setAccessibleDescription("Reabre a janela de progresso da operação atual")
        self.show_progress_button.setVisible(False)
        self.show_progress_button.clicked.connect(self._show_progress_dialog)
        self.toggle_logs_button = QPushButton("Logs")
        self.toggle_logs_button.clicked.connect(self.toggle_logs)
        status_row.addWidget(self.status_dot)
        status_row.addWidget(self.status_text)
        status_row.addWidget(self.elapsed_label)
        status_row.addWidget(self.command_label, 1)
        status_row.addWidget(self.toggle_logs_button)
        status_row.addWidget(self.show_progress_button)
        status_row.addWidget(self.cancel_button)
        # Frameless window: QSizeGrip is the only mouse-resize affordance.
        status_row.addWidget(QSizeGrip(operation), 0, Qt.AlignBottom | Qt.AlignRight)
        operation_layout.addLayout(status_row)
        self.operation_status_row = status_row
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.setMaximumHeight(4)
        self.progress.hide()
        operation_layout.addWidget(self.progress)
        self.log_view = QPlainTextEdit()
        self.log_view.setObjectName("logView")
        self.log_view.setReadOnly(True)
        self.log_view.document().setMaximumBlockCount(10_000)
        self.log_view.setMaximumHeight(190)
        self.log_view.hide()
        operation_layout.addWidget(self.log_view)
        main_layout.addWidget(operation)
        self._build_global_status_bar()
        self._set_advanced_mode(self.preferences.advanced_mode, persist=False)
        QTimer.singleShot(0, self._host_summary)

    def _build_global_status_bar(self) -> None:
        self.global_state = QLabel("Pronto")
        self.global_state.setObjectName("globalState")
        self.global_state.setAccessibleName("Estado global")
        self.global_context = QLabel("Nenhuma falha pendente")
        self.global_context.setObjectName("globalContext")
        self.global_context.setAccessibleName("Resumo de falhas")
        self.operation_status_row.insertWidget(3, self.global_state, 1)
        self.operation_status_row.insertWidget(4, self.global_context)

    def _connect_runner(self) -> None:
        self.runner.started.connect(self.operation_started)
        self.runner.output.connect(self.append_output)
        self.runner.progress.connect(self.update_progress)
        self.runner.completed.connect(self.operation_completed)
        self.runner.failed_to_start.connect(self.operation_start_failed)

    def _install_shortcuts(self) -> None:
        search_action = QAction(self)
        search_action.setShortcut(QKeySequence.Find)
        search_action.triggered.connect(self.search.setFocus)
        self.addAction(search_action)
        cancel_action = QAction(self)
        cancel_action.setShortcut(QKeySequence(Qt.Key_Escape))
        cancel_action.triggered.connect(self.cancel_or_clear)
        self.addAction(cancel_action)
        # LUX-016: Ctrl+N segue a ordem visual da barra lateral (Início = 1)
        # e aparece no tooltip de cada destino.
        for index, category in enumerate(self.sidebar_order()[:9], start=1):
            action = QAction(self)
            action.setShortcut(QKeySequence(f"Ctrl+{index}"))
            action.triggered.connect(lambda _checked=False, name=category: self.show_category(name))
            self.addAction(action)
            button = self.sidebar_buttons.get(category)
            if button is not None:
                button.setToolTip(f"{button.toolTip()} (Ctrl+{index})")

    def sidebar_order(self) -> list[str]:
        """Destinations in the order the sidebar shows them."""
        return [
            category
            for _group, categories in SIDEBAR_GROUPS
            for category in categories
            if category in self.sidebar_buttons
        ]

    def _host_summary(self) -> None:
        process = QProcess(self)
        process.setProgram(str(self.root / "linux" / "pz"))
        process.setArguments(["version"])
        process.setWorkingDirectory(str(self.root))
        process.finished.connect(self._host_summary_finished)
        process.errorOccurred.connect(self._host_summary_error)
        self._host_process = process
        process.start()
        QTimer.singleShot(4000, self._host_summary_timeout)

    def _host_summary_timeout(self) -> None:
        if self._host_process is not None and self._host_process.state() != QProcess.NotRunning:
            self._host_process.kill()

    def _host_summary_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart:
            self._host_summary_finished()

    def _host_summary_finished(self, *_args) -> None:
        process = self._host_process
        if process is None:
            return
        text = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace").strip()
        if text:
            self.system_label.setText(text)
        else:
            self.system_label.setText("PhaseZero Linux")
        self._host_process = None
        process.deleteLater()

    def show_category(self, category: str) -> None:
        if self.registry.page_for(category) is None:
            category = DASHBOARD[0]
        if self.current_category != "Aplicativos" or category != "Aplicativos":
            product_page = self.registry.page_for("Aplicativos")
            if product_page is not None and hasattr(product_page, "show_catalog"):
                product_page.show_catalog()
            self._product_origin_state = None
        self.current_category = category
        self.inspector.clear_action()
        self.inspector.hide()
        sidebar_category = NESTED_CATEGORY_PARENTS.get(category, category)
        for name, button in self.sidebar_buttons.items():
            button.setChecked(name == sidebar_category)
        if self.search.text().strip():
            self.search.clear()
        meta = self.cat_meta.get(category)
        section = self._navigation_section(category)
        self.breadcrumb.set_path(section, category)
        page = self.registry.page_for(category)
        if page is not None:
            self.stack.setCurrentWidget(page)
            self.page_title.setText(category)
            self.page_subtitle.setText(meta[2] if meta else "")
            if hasattr(page, "reload"):
                page.reload()
        self.global_state.setText(f"Página: {category}")

    @staticmethod
    def _navigation_section(category: str) -> str:
        if category in NESTED_CATEGORIES:
            return "Inteligência artificial · Conexões avançadas"
        return next(
            (title for title, categories in SIDEBAR_GROUPS if category in categories),
            "Navegação",
        )

    GRAPHICS_PROBE_TIMEOUT_MS = 20_000

    def _graphics_probe_command(self) -> list[str]:
        return [str(self.root / "linux" / "pz"), "windows-vm", "graphics", "status", "--json"]

    def _measure_graphics_then_install(self) -> None:
        """Measured graphics capability of this host, without blocking the UI.

        Bounded and never fatal: an unavailable measurement means the
        install dialog falls back to the compatible profile, never to an
        optimistic one (UX-010).
        """
        if self._graphics_probe is not None:
            return
        program, *args = self._graphics_probe_command()
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        self._graphics_probe = process
        timer = QTimer(process)
        timer.setSingleShot(True)
        timer.timeout.connect(process.kill)

        def done(*_args) -> None:
            if self._graphics_probe is not process or self._closing:
                return
            self._graphics_probe = None
            timer.stop()
            status: dict = {}
            if process.exitStatus() == QProcess.NormalExit and process.exitCode() == 0:
                try:
                    parsed = json.loads(bytes(process.readAllStandardOutput().data()).decode("utf-8", "replace"))
                    status = parsed if isinstance(parsed, dict) else {}
                except ValueError:
                    status = {}
            process.deleteLater()
            self.status_text.setText("Pronto")
            self._open_windows_install(status)

        def failed(error: QProcess.ProcessError) -> None:
            if error == QProcess.FailedToStart:
                done()

        process.finished.connect(done)
        process.errorOccurred.connect(failed)
        self.status_text.setText("Medindo gráficos deste computador…")
        process.start(program, args)
        timer.start(self.GRAPHICS_PROBE_TIMEOUT_MS)

    def _open_windows_install(self, graphics_status: dict) -> None:
        # UX-010: the dialog only promises what this host measured.
        dialog = WindowsInstallDialog(
            self,
            graphics_status=graphics_status,
            advanced=self.preferences.advanced_mode,
        )
        if dialog.exec() != WindowsInstallDialog.Accepted:
            return
        values = dialog.values()
        ProvisionPlayerWindow.open(
            self.root, self.runner, self,
            iso=values["input"],
            graphics=values["graphics"],
            image_index=values["image_index"],
            guest_login=values["guest_login"],
        )

    def show_journey(self, category: str, focus: str = "") -> None:
        """UX-006: open a goal's destination and land on its entry step."""
        self.show_category(category)
        page = self.registry.page_for(category)
        if page is not None and focus:
            page.focus_journey(focus)

    def inspect_action(self, action: ActionSpec) -> None:
        try:
            target = target_for(action)
        except ValueError:
            target = None
        if target is not None and target.target_kind == "app":
            self.open_product(target.target_id, action.id)
            return
        self.inspector.set_action(action)
        self.inspector.show()
        self.global_state.setText(f"Selecionado: {action.title}")

    def open_product(self, app_id: str, context_action_id: str = "") -> None:
        page = self.registry.page_for("Aplicativos")
        if page is None or not hasattr(page, "open_product"):
            return
        current_page = self.stack.currentWidget()
        if current_page is not page:
            section, page_name = "Navegação", "Busca"
            if self.stack.currentIndex() != self._search_page_idx:
                page_name = self.current_category
                section = self._navigation_section(self.current_category)
            self._product_origin_state = (
                current_page, self.current_category, section, page_name,
                self.page_title.text(), self.page_subtitle.text(), self.global_state.text(),
            )
            self.current_category = "Aplicativos"
            for name, button in self.sidebar_buttons.items():
                button.setChecked(name == "Aplicativos")
            self.stack.setCurrentWidget(page)
        self.inspector.clear_action()
        self.inspector.hide()
        page.open_product(app_id, context_action_id)

    def _product_opened(self, app_id: str, _context_action_id: str) -> None:
        page = self.registry.page_for("Aplicativos")
        name_getter = getattr(page, "product_name", None)
        name = name_getter(app_id) if callable(name_getter) else app_id
        self.page_title.setText(name)
        self.page_subtitle.setText(f"{app_id} · detalhe do produto")
        self.breadcrumb.set_path("Aplicativos", name)
        self.global_state.setText(f"Produto: {name}")

    def _launch_product_desktop_entry(self, desktop_entry: str) -> None:
        started, _process_id = QProcess.startDetached("gio", ["launch", desktop_entry])
        if not started:
            self._toast("Não foi possível abrir este aplicativo pelo atalho instalado.", "error")

    def _product_comparison_opened(self, category: str) -> None:
        self.page_title.setText("Comparação de aplicativos")
        self.page_subtitle.setText(f"Função: {category}")
        self.breadcrumb.set_path("Aplicativos", "Comparação")
        self.global_state.setText("Comparação de produtos")

    def _product_back(self) -> None:
        origin = self._product_origin_state
        self._product_origin_state = None
        if origin is not None:
            page, category, section, page_name, title, subtitle, state = origin
            self.stack.setCurrentWidget(page)
            self.current_category = category
            self.page_title.setText(title)
            self.page_subtitle.setText(subtitle)
            self.global_state.setText(state)
            self.breadcrumb.set_path(section, page_name)
            sidebar_category = NESTED_CATEGORY_PARENTS.get(category, category)
            for name, button in self.sidebar_buttons.items():
                button.setChecked(name == sidebar_category)
            return
        self.page_title.setText("Aplicativos")
        self.page_subtitle.setText(self.cat_meta["Aplicativos"][2])
        self.breadcrumb.set_path("Desktop", "Aplicativos")
        self.global_state.setText("Página: Aplicativos")

    def on_search(self, text: str) -> None:
        if text.strip():
            self.stack.setCurrentIndex(self._search_page_idx)
            self.page_title.setText("Busca")
            self.page_subtitle.setText(f"Resultados para “{text.strip()}”")
            self.breadcrumb.set_path("Navegação", "Busca")
            self.global_state.setText("Busca global")
            self.rebuild_search()
        else:
            self.show_category(self.current_category)

    def rebuild_search(self) -> None:
        while self.search_grid.count():
            item = self.search_grid.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._search_cards.clear()
        query = self.search.text().strip().casefold()
        # CCS-020: o modo simples não expõe ações avançadas nem na busca —
        # progressive disclosure vale para a busca também.
        visible = [
            action for action in self.catalog
            if query and query in action.searchable_text
            and (self.preferences.advanced_mode or action.visibility != "advanced")
        ]
        columns = 1
        for index, action in enumerate(visible):
            row = ActionListRow(action)
            row.selected.connect(lambda item, widget=row: self._select_search_action(item, widget))
            row.setEnabled(not self.runner.running)
            self._search_cards.append(row)
            self.search_grid.addWidget(row, index, 0)
        for col in range(columns):
            self.search_grid.setColumnStretch(col, 1)
        if not visible:
            empty = QLabel("Nenhuma ação corresponde à busca.")
            empty.setObjectName("emptyState")
            self.search_grid.addWidget(empty, 0, 0, 1, columns)
        self.search_grid.setRowStretch((len(visible) + columns - 1) // columns, 1)

    def _select_search_action(self, action: ActionSpec, selected: ActionListRow) -> None:
        for row in self._search_cards:
            if isinstance(row, ActionListRow):
                row.set_selected(row is selected)
        self.inspect_action(action)

    def resizeEvent(self, event: QResizeEvent) -> None:
        super().resizeEvent(event)
        # LUX-020: entre 850 e 1100 px lógicos (Deck a 150% = 853) a navegação
        # vira um trilho de ícones. Abaixo de 850 o trilho roubaria largura
        # que o Homelab precisa (overflow com fontes largas, ex. DejaVu).
        compact = event.size().width() < 850
        self._set_sidebar_rail(850 <= event.size().width() < 1100)
        compact_controls = event.size().width() < 450
        hide_mode_label = event.size().width() < 560
        short_viewport = event.size().height() < 360
        self.sidebar.setVisible(not compact)
        self.compact_menu.setVisible(compact)
        self.mode_label.setVisible(not hide_mode_label)
        self.breadcrumb.setVisible(not short_viewport)
        self.page_title.setVisible(not short_viewport)
        self.page_subtitle.setVisible(not short_viewport)
        self._set_controls_compact(compact_controls)
        if self.stack.currentIndex() == self._search_page_idx:
            self._search_relayout_timer.start()

    SIDEBAR_WIDTH = 230
    SIDEBAR_RAIL_WIDTH = 64

    def _sidebar_label(self, category: str) -> str:
        label = category
        if category == "Resultados" and self._failure_count:
            label = f"Resultados ({self._failure_count})"
        return label.replace("&", "&&")

    def _set_sidebar_rail(self, rail: bool) -> None:
        if self._sidebar_rail is rail:
            return
        self._sidebar_rail = rail
        self.sidebar.setFixedWidth(self.SIDEBAR_RAIL_WIDTH if rail else self.SIDEBAR_WIDTH)
        for label in self._section_labels:
            label.setVisible(not rail)
        self.system_label.setVisible(not rail)
        for category, button in self.sidebar_buttons.items():
            button.setText("" if rail else self._sidebar_label(category))
            button.setProperty("rail", rail)
            _repolish_widget(button)

    def _set_controls_compact(self, compact: bool) -> None:
        """Stack header controls before they can overlap at high DPI."""
        if self._controls_compact is compact:
            return
        self._controls_compact = compact
        for widget in (self.search, self.mode_label, self.mode_switch, self.theme_button):
            self.controls_layout.removeWidget(widget)
        if compact:
            self.controls_layout.addWidget(self.search, 0, 0, 1, 3)
            self.controls_layout.addWidget(self.mode_switch, 1, 0)
            self.controls_layout.addWidget(self.theme_button, 1, 1)
            self.controls_layout.setColumnStretch(0, 1)
            self.controls_layout.setColumnStretch(1, 0)
            self.controls_layout.setColumnStretch(2, 0)
        else:
            self.controls_layout.addWidget(self.search, 0, 0)
            self.controls_layout.addWidget(self.mode_label, 0, 1)
            self.controls_layout.addWidget(self.mode_switch, 0, 2)
            self.controls_layout.addWidget(self.theme_button, 0, 3)
            self.controls_layout.setColumnStretch(0, 1)
            self.controls_layout.setColumnStretch(1, 0)
            self.controls_layout.setColumnStretch(2, 0)
            self.controls_layout.setColumnStretch(3, 0)

    def request_actions(self, actions: object) -> None:
        """Run a user-selected batch sequentially, retaining confirmation gates."""
        if self.runner.running:
            return
        selected = [action for action in list(actions) if isinstance(action, ActionSpec)]
        if not selected:
            self._toast("Nenhuma ação selecionada", "warning")
            return
        self._action_queue = selected[1:]
        self.request_action(selected[0])

    def request_action(self, action: ActionSpec) -> None:
        if self.runner.running:
            self._toast("Já existe operação em andamento — aguarde ou cancele", "warning")
            return
        values: dict[str, str] = {}
        if action.id == "windows.provision.player":
            # LUX-015: measure asynchronously; the window keeps responding.
            self._measure_graphics_then_install()
            return
        if action.id == "windows.images.manage":
            from .image_manager_dialog import ImageManagerDialog
            dialog = ImageManagerDialog(
                self.root, self.runner, self.by_id, self,
                advanced=self.preferences.advanced_mode,
            )
            dialog.exec()
            pending = dialog.pending_action()
            if pending is not None:
                self.request_action(pending)
            return
        if action.parameters:
            dialog = ParameterDialog(action, self)
            if dialog.exec() != ParameterDialog.Accepted:
                return
            values = dialog.values()

        self.pending_action = action
        self.pending_value = values.get("input", "")
        self.pending_values = values
        self.log_view.clear()
        self.log_view.setVisible(self.preferences.advanced_mode)
        try:
            page = self.registry.page_for(self.current_category)
            extra = getattr(page, "consume_action_values", None)
            if callable(extra):
                values.update(extra(action) or {})
            self.runner.start(action, preview=action.mutable, values=values)
        except (ValueError, RuntimeError) as exc:
            self.pending_action = None
            self.pending_value = ""
            self.pending_values = {}
            self._action_queue.clear()
            QMessageBox.warning(self, "Não foi possível iniciar", str(exc))

    def operation_started(self, command: str) -> None:
        self.status_text.setText("Pré-visualizando…" if self.runner.preview else "Executando…")
        self.status_dot.setObjectName("statusRunning")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        self.command_label.setText(command)
        self.command_label.setVisible(self.preferences.advanced_mode)
        self.cancel_button.setEnabled(True)
        self.cancel_button.setToolTip(
            "O pacote atual termina; o cancelamento ocorre entre etapas seguras."
            if self.runner.safe_cancel_supported else
            "Interrompe processo em andamento (pede confirmação)."
        )
        self._operation_started_at = time.monotonic()
        self._elapsed_timer.start()
        self._update_elapsed()
        self.progress.setRange(0, 0)
        self.progress.show()
        self.registry.block_all(True)
        self.inspector.setEnabled(False)
        for card in self._search_cards:
            card.setEnabled(False)
        self.append_output(f"$ {command}\n", False)
        if not self.runner.preview:
            title = self.pending_action.title if self.pending_action is not None else "Executando operação"
            self.progress_dialog = ProgressDialog(
                title, command, self, advanced_mode=self.preferences.advanced_mode
            )
            self.progress_dialog.cancel_requested.connect(self.confirm_cancel)
            self.progress_dialog.hidden_while_running.connect(
                lambda: self.show_progress_button.setVisible(True)
            )
            self.progress_dialog.show()

    def append_output(self, text: str, error: bool) -> None:
        if error:
            self.log_view.appendPlainText("[stderr] " + text.rstrip())
        else:
            cursor = self.log_view.textCursor()
            cursor.movePosition(QTextCursor.MoveOperation.End)
            cursor.insertText(text)
            self.log_view.setTextCursor(cursor)
        scrollbar = self.log_view.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())
        if self.progress_dialog is not None:
            self.progress_dialog.append_output(text, error)

    def update_progress(self, value: int) -> None:
        self.progress.setRange(0, 100)
        self.progress.setValue(value)
        if self.progress_dialog is not None:
            self.progress_dialog.set_progress(value)

    def operation_completed(self, result: OperationResult) -> None:
        start_failed = self._start_failed
        self._start_failed = False
        self.progress.hide()
        self._elapsed_timer.stop()
        self._update_elapsed(final=True)
        if self.progress_dialog is not None:
            self.progress_dialog.finish()
            self.progress_dialog.deleteLater()
            self.progress_dialog = None
        self.cancel_button.setEnabled(False)
        self.show_progress_button.setVisible(False)
        action = self.pending_action
        is_mutable = bool(action and action.mutable)
        is_cancelled = bool(
            isinstance(result.parsed, dict) and result.parsed.get("status") == "cancelled"
        )
        severity = "warning" if is_cancelled else severity_for(
            result.parsed, result.exit_code, mutable=is_mutable
        )
        status_map = {"success": "Concluído", "warning": "Concluído com avisos", "error": "Falhou"}
        status_label = status_map.get(severity, "Falhou")
        if is_cancelled:
            status_label = "Cancelado após etapa segura; pronto para retomar"
        if restart_required(result.parsed):
            status_label = "Reinício necessário"
        self.status_text.setText(status_label)
        self.status_dot.setObjectName("statusSuccess" if severity == "success" else "statusWarning" if severity == "warning" else "statusError")
        self.status_dot.style().unpolish(self.status_dot)
        self.status_dot.style().polish(self.status_dot)
        self.registry.block_all(False)
        self.inspector.setEnabled(True)
        if not result.ok and not is_cancelled:
            self._failure_count += 1
        elif not result.preview:
            # A confirmed operation that succeeded clears the pending-failure
            # badge; preview runs must not clear it (no change was applied).
            self._failure_count = 0
        self._update_failure_summary()
        for card in self._search_cards:
            card.setEnabled(True)
        if self._closing:
            self.pending_action = None
            self.pending_value = ""
            self.pending_values = {}
            self._action_queue.clear()
            return
        action_title = action.title if action is not None else "Operação"
        if start_failed:
            pass  # operation_start_failed already told the user
        elif result.preview and action is not None:
            dialog = PreviewDialog(
                result, action, self, advanced_mode=self.preferences.advanced_mode
            )
            if dialog.exec() == PreviewDialog.Accepted:
                try:
                    self._bind_preview_result(action, result)
                except ValueError as exc:
                    self._action_queue.clear()
                    QMessageBox.warning(self, "Preview não aplicável", str(exc))
                    self._cancel_page_pending_action(action.id)
                    self.pending_action = None
                    self.pending_values = {}
                    return
                self.log_view.appendPlainText("\n--- execução confirmada ---\n")
                try:
                    self.runner.start(action, preview=False, values=self.pending_values)
                    return
                except (ValueError, RuntimeError) as exc:
                    self._action_queue.clear()
                    QMessageBox.warning(self, "Não foi possível iniciar", str(exc))
            self._cancel_page_pending_action(action.id)
            self._action_queue.clear()
        else:
            formatted = self._format_result(result)
            dialog = ResultDialog(
                result,
                formatted,
                self,
                severity=severity,
                advanced_mode=self.preferences.advanced_mode,
            )
            dialog.history_requested.connect(lambda: self.show_category("Resultados"))
            dialog.resolution_requested.connect(self._open_resolution)
            if severity == "error":
                # Falha confirmada: reverte o toggle otimista na hora, sem
                # esperar o refetch assíncrono (que pode falhar também).
                self._cancel_page_pending_action(action.id)
            dialog.retry_requested.connect(lambda _a: self.request_action(action))
            dialog.exec()
            verb_map = {"success": "concluída", "warning": "concluída com avisos", "error": "falhou"}
            verb = "cancelada; pronta para retomar" if is_cancelled else verb_map.get(severity, "falhou")
            self._toast(f"{action_title} {verb}", severity)
        self.pending_action = None
        self.pending_value = ""
        self.pending_values = {}
        if result.ok and self._action_queue:
            next_action = self._action_queue.pop(0)
            QTimer.singleShot(0, lambda: self.request_action(next_action))
        elif not result.ok:
            self._action_queue.clear()
        page = self.registry.page_for(self.current_category)
        on_result = getattr(page, "on_operation_result", None)
        if action is not None and callable(on_result) and not result.preview:
            on_result(action, result)
        if not result.preview and page is not None:
            QTimer.singleShot(0, page.reload)

    def _bind_preview_result(self, action: ActionSpec, result: OperationResult) -> None:
        if not action.preview_bindings:
            return
        if not isinstance(result.parsed, dict):
            raise ValueError("preview não retornou resultado estruturado")
        blockers = result.parsed.get("blockers")
        if blockers:
            raise ValueError("plano contém bloqueios; revise compatibilidade e fontes")
        for parameter, result_key in action.preview_bindings:
            value = result.parsed.get(result_key)
            if not isinstance(value, (str, int)) or not str(value):
                raise ValueError(f"preview não retornou {result_key}")
            self.pending_values[parameter] = str(value)

    def _toast(self, message: str, state: str) -> None:
        toast = Toast(self, message, state)
        toast.popup()

    def _open_resolution(self, action_id: str) -> None:
        if action_id.startswith("windows."):
            self.show_category("Windows VM")
        elif action_id.startswith("ai.proxies") or action_id.startswith("ai.9router") or action_id.startswith("ai.odysseus"):
            self.show_category("Proxies IA")
        elif action_id.startswith("ai.routing"):
            self.show_category("Roteamento IA")
        elif action_id.startswith("ai."):
            self.show_category("IA & Dev")
        elif action_id == "system.doctor":
            self.show_category("Visão geral")
        else:
            self.show_category("Visão geral")
            action = self.by_id.get("system.repair-plan")
            if action is not None:
                self.inspect_action(action)

    def _format_result(self, result: OperationResult) -> str:
        blocks = []
        if result.parsed is not None:
            blocks.append("RESULTADO ESTRUTURADO\n" + json.dumps(result.parsed, ensure_ascii=False, indent=2))
        if result.stdout:
            blocks.append("STDOUT\n" + result.stdout)
        if result.stderr:
            blocks.append("STDERR\n" + result.stderr)
        if not blocks:
            blocks.append("Processo terminou sem saída.")
        return "\n\n".join(blocks)

    def operation_start_failed(self, message: str) -> None:
        self._start_failed = True
        self.progress.hide()
        self.cancel_button.setEnabled(False)
        self.status_text.setText("Falha ao iniciar")
        self._elapsed_timer.stop()
        self._operation_started_at = None
        self.elapsed_label.clear()
        self._failure_count += 1
        self._update_failure_summary()
        if self.pending_action is not None:
            self._cancel_page_pending_action(self.pending_action.id)
        QMessageBox.critical(self, "Falha ao iniciar", message)

    def _cancel_page_pending_action(self, action_id: str) -> None:
        page = self.registry.page_for(self.current_category)
        if page is not None:
            page.cancel_pending_action(action_id)

    def _update_elapsed(self, *, final: bool = False) -> None:
        if self._operation_started_at is None:
            if not final:
                self.elapsed_label.clear()
            return
        elapsed = max(0, int(time.monotonic() - self._operation_started_at))
        minutes, seconds = divmod(elapsed, 60)
        self.elapsed_label.setText(f"{minutes:02d}:{seconds:02d}")
        self.elapsed_label.setAccessibleName(f"Tempo decorrido: {minutes} minutos e {seconds} segundos")
        if final:
            self._operation_started_at = None

    def _update_failure_summary(self) -> None:
        if self._failure_count:
            text = f"{self._failure_count} falha{'s' if self._failure_count != 1 else ''} pendente{'s' if self._failure_count != 1 else ''}"
            self.global_context.setText(text)
            self.global_context.setProperty("state", "error")
            results = self.sidebar_buttons.get("Resultados")
            if results is not None and not self._sidebar_rail:
                results.setText(self._sidebar_label("Resultados"))
        else:
            self.global_context.setText("Nenhuma falha pendente")
            self.global_context.setProperty("state", "success")
        self.global_context.style().unpolish(self.global_context)
        self.global_context.style().polish(self.global_context)

    def cancel_or_clear(self) -> None:
        # LUX-002: Esc nunca aborta uma operação — só limpa a busca.
        if self.search.text():
            self.search.clear()

    def _ask_cancel(self, title: str, elevated: bool) -> bool:
        if self.runner.safe_cancel_supported:
            text = (
                f"O pacote atual de “{title}” termina sem interrupção. "
                "A instalação para antes da próxima etapa e pode ser retomada."
            )
        else:
            text = f"Parar agora pode deixar “{title}” incompleto."
        if elevated and not self.runner.safe_cancel_supported:
            text += " Pode exigir reparo depois."
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Warning)
        box.setWindowTitle("Parar operação?")
        box.setText(text)
        keep = box.addButton("Continuar operação", QMessageBox.RejectRole)
        stop_label = "Parar após pacote atual" if self.runner.safe_cancel_supported else "Parar mesmo assim"
        stop = box.addButton(stop_label, QMessageBox.DestructiveRole)
        box.setDefaultButton(keep)
        box.setEscapeButton(keep)
        box.exec()
        return box.clickedButton() is stop

    def confirm_cancel(self) -> None:
        """LUX-002: cancelar exige uma segunda decisão explícita."""
        if not self.runner.running:
            return
        action = self.pending_action
        title = action.title if action is not None else "a operação"
        if self._ask_cancel(title, bool(action and action.elevated)):
            self.runner.cancel()
            if self.runner.safe_cancel_pending:
                self.status_text.setText("Aguardando etapa segura…")
                self.cancel_button.setEnabled(False)
            elif self.runner.cancel_error:
                QMessageBox.warning(self, "Cancelamento indisponível", self.runner.cancel_error)

    def _show_progress_dialog(self) -> None:
        self.show_progress_button.setVisible(False)
        if self.progress_dialog is not None:
            self.progress_dialog.show()
            self.progress_dialog.raise_()

    def toggle_logs(self) -> None:
        self.log_view.setVisible(not self.log_view.isVisible())

    def _set_advanced_mode(self, enabled: bool, *, persist: bool = True) -> None:
        enabled = bool(enabled)
        if persist:
            self.preferences.set_advanced_mode(enabled)
        self.mode_switch.blockSignals(True)
        self.mode_switch.setChecked(enabled)
        self.mode_switch.blockSignals(False)
        self.inspector.set_advanced_mode(enabled)
        self.registry.set_advanced_mode(enabled)
        self.command_label.setVisible(enabled and bool(self.command_label.text()))
        self.toggle_logs_button.setVisible(enabled or self._failure_count > 0)
        if not enabled:
            self.log_view.hide()

    def toggle_maximize(self) -> None:
        if self.isMaximized():
            self.showNormal()
            self._maximized = False
        else:
            self.showMaximized()
            self._maximized = True

    def toggle_theme(self) -> None:
        self.dark_theme = not self.dark_theme
        theme = "dark" if self.dark_theme else "light"
        # LUX-021: a escolha explícita sobrevive ao reinício.
        self.preferences.set_theme(theme)
        self.theme_changed.emit(theme)

    def closeEvent(self, event: QCloseEvent) -> None:
        if self.runner.running:
            if self.runner.safe_cancel_supported:
                answer = QMessageBox.question(
                    self,
                    "Etapa de pacote em andamento",
                    "Para preservar o pacote em execução, solicite cancelamento seguro e feche depois que esta etapa terminar?",
                    QMessageBox.Yes | QMessageBox.No,
                    QMessageBox.No,
                )
                if answer == QMessageBox.Yes:
                    self.runner.cancel()
                    if self.runner.safe_cancel_pending:
                        self.status_text.setText("Aguardando etapa segura; feche depois da conclusão.")
                        self.cancel_button.setEnabled(False)
                    elif self.runner.cancel_error:
                        QMessageBox.warning(self, "Cancelamento indisponível", self.runner.cancel_error)
                event.ignore()
                return
            answer = QMessageBox.question(
                self,
                "Operação em andamento",
                "Cancelar operação e fechar?",
                QMessageBox.Yes | QMessageBox.No,
                QMessageBox.No,
            )
            if answer != QMessageBox.Yes:
                event.ignore()
                return
        self._closing = True
        probe, self._graphics_probe = self._graphics_probe, None
        if probe is not None:
            probe.kill()
            probe.waitForFinished(500)
        self.runner.shutdown()
        if self._host_process is not None:
            self._host_process.kill()
            self._host_process.waitForFinished(500)
        event.accept()
