from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from PySide6.QtCore import QIODevice, QProcess, QSaveFile, QSize, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QIcon
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QGridLayout, QLabel, QPushButton,
    QFrame, QHBoxLayout, QInputDialog, QLineEdit, QListWidget, QListWidgetItem, QScrollArea,
    QTabWidget, QVBoxLayout, QWidget,
)

from .a11y_events import announce_accessible
from .platform import secure_file, state_dir
from .vibe_apps import AppEntry, read_apps
from .widgets import SectionHeader


EDITORS = (
    ("code", "Visual Studio Code"),
    ("codium", "VSCodium"),
)
DESKTOP_ENTRY = "phasezero-vibe-code.desktop"
AUTOSTART_MARKER = "X-PhaseZero-Vibe-Code-Autostart=true"


class VibeCodeDialog(QDialog):
    """Resume a project or open an app through its normal desktop entry."""

    product_requested = Signal(str)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Vibe Code · PhaseZero")
        area = self.screen().availableGeometry()
        self.resize(min(850, area.width() - 24), min(660, area.height() - 40))
        self.state = state_dir() / "vibe-code.json"
        self.project: Path | None = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 12)
        layout.addWidget(SectionHeader("Vibe Code", "Retome seu projeto e abra os aplicativos que precisa usar."))
        self.tabs = QTabWidget()
        layout.addWidget(self.tabs, 1)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        overview = QWidget()
        overview_layout = QVBoxLayout(overview)
        overview_layout.setContentsMargins(2, 12, 8, 4)
        overview_layout.setSpacing(12)
        scroll.setWidget(overview)
        self.tabs.addTab(scroll, "Início")
        overview_layout.addWidget(SectionHeader("Aplicativos principais", "Abra um aplicativo para começar."))
        self.shortcuts = QGridLayout()
        self.shortcut_cards: list[QFrame] = []
        self.shortcut_columns = 0
        overview_layout.addLayout(self.shortcuts)
        more = QPushButton("Ver todos os aplicativos")
        more.clicked.connect(lambda: self.tabs.setCurrentIndex(1))
        overview_layout.addWidget(more, 0, Qt.AlignmentFlag.AlignLeft)

        project = QFrame()
        project.setObjectName("settingsCard")
        project_layout = QVBoxLayout(project)
        project_title = QLabel("Projeto")
        project_title.setObjectName("serviceTitle")
        project_layout.addWidget(project_title)
        overview_layout.addWidget(project)

        self.folder = QLabel()
        self.folder.setTextFormat(Qt.TextFormat.PlainText)
        self.folder.setWordWrap(True)
        self.folder.setAccessibleName("Pasta do projeto")
        project_layout.addWidget(self.folder)

        form = QFormLayout()
        self.editor = QComboBox()
        self.editor.setAccessibleName("Editor do projeto")
        for executable, label in EDITORS:
            self.editor.addItem(label, executable)
        form.addRow("Editor", self.editor)
        project_layout.addLayout(form)

        self.open_editor = QPushButton("Retomar projeto")
        self.open_editor.setObjectName("vibeResumeProject")
        self.open_editor.setMinimumHeight(42)
        self.open_editor.clicked.connect(self._open_editor)

        self.choose_folder = QPushButton("Escolher pasta…")
        self.choose_folder.setObjectName("vibeChooseFolder")
        self.choose_folder.clicked.connect(self._choose)
        project_actions = QHBoxLayout()
        project_actions.addWidget(self.open_editor, 1)
        project_actions.addWidget(self.choose_folder)
        project_layout.addLayout(project_actions)

        overview_layout.addWidget(SectionHeader("Ferramentas do projeto", "Arquivos, edição rápida e preview."))

        tools = QGridLayout()
        self.project_tools: list[QPushButton] = []
        for index, (label, program) in enumerate((
            ("Terminal", "konsole"), ("Arquivos", "dolphin"),
            ("Editor de texto", "kate"),
        )):
            button = QPushButton(label)
            button.clicked.connect(lambda _checked=False, name=program: self._open_tool(name))
            tools.addWidget(button, index // 2, index % 2)
            self.project_tools.append(button)
        browser = QPushButton("Navegador")
        browser.clicked.connect(self._open_browser)
        tools.addWidget(browser, 1, 1)
        overview_layout.addLayout(tools)
        self._build_autostart(overview_layout)
        overview_layout.addStretch()

        self._build_apps()

        self.status = QLabel()
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.status)
        self._restore()
        self._refresh()
        self._reload_apps()
        self.editor.currentIndexChanged.connect(self._remember_selection)

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if hasattr(self, "shortcut_cards"):
            self._arrange_shortcuts()

    def _arrange_shortcuts(self) -> None:
        columns = 3 if self.width() >= 660 else 1
        if columns == self.shortcut_columns:
            return
        self.shortcut_columns = columns
        for index in range(3):
            self.shortcuts.setColumnStretch(index, int(index < columns))
        for index, card in enumerate(self.shortcut_cards):
            self.shortcuts.removeWidget(card)
            self.shortcuts.addWidget(card, index // columns, index % columns)

    def _build_apps(self) -> None:
        page = QWidget()
        body = QVBoxLayout(page)
        body.setContentsMargins(2, 12, 2, 4)
        row = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("Buscar no menu de aplicativos…")
        self.search.setAccessibleName("Buscar aplicativos")
        self.search.textChanged.connect(self._filter_apps)
        row.addWidget(self.search, 1)
        reload_button = QPushButton("Atualizar")
        reload_button.clicked.connect(self._reload_apps)
        row.addWidget(reload_button)
        body.addLayout(row)
        self.app_list = QListWidget()
        self.app_list.setAccessibleName("Aplicativos")
        self.app_list.setSpacing(2)
        self.app_list.currentItemChanged.connect(self._describe_app)
        self.app_list.itemActivated.connect(lambda item: self._launch_app(item.data(Qt.ItemDataRole.UserRole)))
        body.addWidget(self.app_list, 1)
        self.app_detail = QLabel()
        self.app_detail.setWordWrap(True)
        self.app_detail.setTextFormat(Qt.TextFormat.PlainText)
        body.addWidget(self.app_detail)
        self.app_action = QPushButton("Abrir aplicativo")
        self.app_action.clicked.connect(self._open_selected_app)
        body.addWidget(self.app_action)
        self.tabs.addTab(page, "Aplicativos")

    def _reload_apps(self) -> None:
        self.featured, menu, self.menu_available = read_apps()
        self.apps = [*self.featured, *menu]
        while self.shortcuts.count():
            self.shortcuts.takeAt(0).widget().deleteLater()
        self.shortcut_cards.clear()
        for entry in self.featured[:3]:
            card = QFrame()
            card.setObjectName("settingsCard")
            body = QVBoxLayout(card)
            body.setContentsMargins(12, 10, 12, 10)
            title = QLabel(entry.shortcut.name)
            title.setObjectName("sectionTitle")
            title.setWordWrap(True)
            body.addWidget(title)
            detail = QLabel("Atalho disponível" if entry.ready else "Preparação necessária")
            detail.setObjectName("cardDescription")
            detail.setWordWrap(True)
            body.addWidget(detail)
            body.addStretch()
            launch = QPushButton("Abrir" if entry.ready else "Preparar")
            launch.setAccessibleName(f"{launch.text()} {entry.shortcut.name}")
            launch.clicked.connect(lambda _checked=False, app=entry: self._launch_app(app))
            body.addWidget(launch)
            self.shortcut_cards.append(card)
        self.shortcut_columns = 0
        self._arrange_shortcuts()
        self._filter_apps()

    def _filter_apps(self) -> None:
        previous = self.app_list.currentItem()
        selected = previous.data(Qt.ItemDataRole.UserRole).shortcut.name if previous else ""
        self.app_list.clear()
        terms = self.search.text().casefold().split()
        for entry in self.apps:
            name = entry.shortcut.name
            if not all(term in f"{name} {entry.shortcut.detail}".casefold() for term in terms):
                continue
            suffix = " · Central" if entry.catalog_only else (" · Preparação necessária" if not entry.ready else "")
            item = QListWidgetItem(name + suffix)
            item.setSizeHint(QSize(0, 32))
            item.setData(Qt.ItemDataRole.UserRole, entry)
            if entry.desktop is not None:
                icon = entry.desktop.get_icon()
                if icon:
                    if hasattr(icon, "get_file"):
                        item.setIcon(QIcon(icon.get_file().get_path() or ""))
                    elif hasattr(icon, "get_names"):
                        names = icon.get_names()
                        if names:
                            item.setIcon(QIcon.fromTheme(names[0]))
            self.app_list.addItem(item)
            if name == selected:
                self.app_list.setCurrentItem(item)
        if self.app_list.count() and self.app_list.currentRow() < 0:
            self.app_list.setCurrentRow(0)
        self._describe_app(self.app_list.currentItem())

    def _describe_app(self, item: QListWidgetItem | None) -> None:
        entry = item.data(Qt.ItemDataRole.UserRole) if item else None
        if entry is None:
            text = "Nenhum aplicativo encontrado." if self.menu_available else "Menu do sistema indisponível. Verifique o pacote python-gobject."
            self.app_detail.setText(text)
            self.app_action.setEnabled(False)
            return
        self.app_detail.setText(entry.shortcut.detail)
        action = "Ver na Central" if entry.catalog_only else ("Abrir aplicativo" if entry.ready else "Abrir preparação")
        self.app_action.setText(action)
        self.app_action.setEnabled(entry.ready or bool(entry.shortcut.product))

    def _open_selected_app(self) -> None:
        item = self.app_list.currentItem()
        if item is not None:
            self._launch_app(item.data(Qt.ItemDataRole.UserRole))

    def _launch_app(self, entry: AppEntry) -> None:
        name = entry.shortcut.name
        if entry.desktop is not None:
            try:
                if entry.shortcut.action:
                    entry.desktop.launch_action(entry.shortcut.action, None)
                    launched = True
                else:
                    launched = entry.desktop.launch([], None)
            except Exception:
                launched = False
            self._report(f"Abertura solicitada · {name}" if launched else f"Falha ao abrir {name}. Atualize a lista e revise o atalho instalado.")
        elif entry.command:
            if not self._folder_available():
                self.tabs.setCurrentIndex(0)
                self.choose_folder.setFocus()
                self._report(f"Escolha a pasta para abrir {name} no terminal do projeto.")
                return
            self._open_tool("konsole", [entry.command])
        elif entry.shortcut.product:
            self.product_requested.emit(entry.shortcut.product)
        else:
            self._report(f"{name} indisponível. Prepare o aplicativo pelo seu instalador.")

    def _build_autostart(self, layout: QVBoxLayout) -> None:
        data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        self.autostart_path = config / "autostart" / DESKTOP_ENTRY
        self.desktop_entry = data / "applications" / DESKTOP_ENTRY
        if not self.desktop_entry.is_file() and not self.autostart_path.exists():
            return
        self.autostart = QCheckBox("Mostrar Vibe Code ao entrar no Plasma")
        self.autostart.setChecked(self._owns_autostart())
        self.autostart.toggled.connect(self._toggle_autostart)
        layout.addWidget(self.autostart)

    def _owns_autostart(self) -> bool:
        if self.autostart_path.is_symlink():
            return False
        try:
            return AUTOSTART_MARKER in self.autostart_path.read_text(encoding="utf-8").splitlines()
        except (OSError, ValueError):
            return False

    def _toggle_autostart(self, enabled: bool) -> None:
        path = self.autostart_path
        try:
            if path.is_symlink() or (path.exists() and not self._owns_autostart()):
                raise ValueError
            if enabled:
                entry = self.desktop_entry.read_text(encoding="utf-8")
                if self.desktop_entry.is_symlink() or "X-PhaseZero-Managed=true" not in entry.splitlines():
                    raise ValueError
                path.parent.mkdir(parents=True, exist_ok=True)
                target = QSaveFile(str(path))
                content = (entry.rstrip() + "\nOnlyShowIn=KDE;\n" + AUTOSTART_MARKER + "\n").encode()
                if not target.open(QIODevice.OpenModeFlag.WriteOnly) or target.write(content) != len(content) or not target.commit():
                    raise OSError
            else:
                path.unlink(missing_ok=True)
        except (OSError, ValueError):
            was_blocked = self.autostart.blockSignals(True)
            self.autostart.setChecked(self._owns_autostart())
            self.autostart.blockSignals(was_blocked)
            self._report("Falhou ao alterar a abertura automática. Configuração anterior preservada.")
        else:
            self._report("Preferência salva para a próxima entrada no Plasma.")

    def _restore(self) -> None:
        try:
            saved = json.loads(self.state.read_text(encoding="utf-8"))
            if not isinstance(saved, dict):
                raise ValueError
            folder = saved.get("folder")
            if isinstance(folder, str) and Path(folder).is_absolute() and "\0" not in folder:
                self.project = Path(folder)
            index = self.editor.findData(saved.get("editor"))
            if index >= 0:
                self.editor.setCurrentIndex(index)
        except FileNotFoundError:
            pass
        except (OSError, ValueError):
            self._report("Não foi possível ler o último projeto. Escolha uma pasta.")

    def _refresh(self) -> None:
        available = self._folder_available()
        self.folder.setText(str(self.project) if self.project else "Escolha uma pasta para começar.")
        self.open_editor.setEnabled(available)
        self.open_editor.setDefault(available)
        self.choose_folder.setDefault(not available)
        for button in self.project_tools:
            button.setEnabled(available)
        if self.project and not available:
            self._report("Pasta indisponível. Reconecte o disco ou escolha outra pasta.")

    def _folder_available(self) -> bool:
        try:
            return bool(self.project and self.project.is_dir() and os.access(self.project, os.R_OK | os.X_OK))
        except OSError:
            return False

    def _report(self, message: str) -> None:
        self.status.setText(message)
        announce_accessible(self.status, message)

    def _choose(self) -> None:
        initial = self.project if self._folder_available() else Path.home()
        folder = QFileDialog.getExistingDirectory(self, "Escolher pasta do projeto", str(initial))
        if not folder:
            return
        self.project = Path(folder)
        self._report("")
        self._refresh()
        if self._remember_selection():
            self.open_editor.setFocus()

    def _remember_selection(self) -> bool:
        if not self._folder_available():
            return False
        try:
            secure_file(self.state, json.dumps({
                "folder": str(self.project),
                "editor": self.editor.currentData(),
            }, ensure_ascii=False) + "\n")
            return True
        except OSError:
            self._report("A pasta pode ser aberta agora. Falhou ao salvar para retomar depois.")
            return False

    def _open_editor(self) -> None:
        self._open_tool(self.editor.currentData())

    def _open_browser(self) -> None:
        text, accepted = QInputDialog.getText(
            self, "Abrir no navegador", "Endereço do preview ou da documentação",
            QLineEdit.EchoMode.Normal, "http://localhost:3000",
        )
        if not accepted:
            return
        url = QUrl(text.strip(), QUrl.ParsingMode.StrictMode)
        if not url.isValid() or url.scheme() not in {"http", "https"} or not url.host():
            self._report("Digite um endereço completo começando com http:// ou https://.")
            return
        if QDesktopServices.openUrl(url):
            self._report("Abertura solicitada ao navegador padrão.")
        else:
            self._report("Falha ao abrir. Confira o navegador padrão nas configurações do desktop.")

    def _open_tool(self, program: str, terminal_command: list[str] | None = None) -> None:
        if not self._folder_available():
            self._refresh()
            return
        working_directory = str(self.project)
        if program == "konsole":
            args = ["--separate", "--workdir", working_directory]
            if terminal_command:
                args += ["-e", *terminal_command]
        elif program == "kate":
            file, _filter = QFileDialog.getOpenFileName(self, "Editar arquivo", working_directory)
            if not file:
                return
            args = [file]
        else:
            args = [working_directory]
        executable = shutil.which(program)
        if not executable and program == "codium":
            data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
            exports = (data / "flatpak/exports", Path("/var/lib/flatpak/exports"))
            if any((path / "share/applications/com.vscodium.codium.desktop").is_file() for path in exports):
                executable = shutil.which("flatpak")
                args = ["run", "com.vscodium.codium", *args]
        if not executable:
            self._report(f"{program} indisponível. Prepare a ferramenta em Desenvolvimento ou escolha outro editor.")
            return
        if program == "konsole":
            # Konsole starts the shell in --workdir but can forward the launcher's PWD.
            args = [f"PWD={working_directory}", executable, *args]
            executable = "/usr/bin/env"
        started, _pid = QProcess.startDetached(executable, args, working_directory)
        self._report("Abertura solicitada." if started else f"Falha ao iniciar {program}. Tente novamente.")
