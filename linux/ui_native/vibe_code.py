from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

from PySide6.QtCore import QIODevice, QProcess, QSaveFile, Qt
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QGridLayout, QLabel, QPushButton,
    QVBoxLayout, QWidget,
)

from .a11y_events import announce_accessible
from .platform import secure_file, state_dir
from .widgets import SectionHeader


EDITORS = (
    ("code", "Visual Studio Code"),
    ("codium", "VSCodium"),
)
DESKTOP_ENTRY = "phasezero-vibe-code.desktop"
AUTOSTART_MARKER = "X-PhaseZero-Vibe-Code-Autostart=true"


class VibeCodeDialog(QDialog):
    """Open tools on a project selected by the user, without running its tasks."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Vibe Code · PhaseZero")
        self.state = state_dir() / "vibe-code.json"
        self.project: Path | None = None
        layout = QVBoxLayout(self)
        layout.addWidget(SectionHeader("Vibe Code", "Abra suas ferramentas na pasta do projeto."))

        self.folder = QLabel()
        self.folder.setTextFormat(Qt.TextFormat.PlainText)
        self.folder.setWordWrap(True)
        self.folder.setAccessibleName("Pasta do projeto")
        layout.addWidget(self.folder)

        form = QFormLayout()
        self.editor = QComboBox()
        self.editor.setAccessibleName("Editor do projeto")
        for executable, label in EDITORS:
            self.editor.addItem(label, executable)
        form.addRow("Editor", self.editor)
        layout.addLayout(form)

        self.open_editor = QPushButton("Retomar projeto")
        self.open_editor.setObjectName("vibeResumeProject")
        self.open_editor.setMinimumHeight(42)
        self.open_editor.clicked.connect(self._open_editor)
        layout.addWidget(self.open_editor)

        self.choose_folder = QPushButton("Escolher pasta…")
        self.choose_folder.setObjectName("vibeChooseFolder")
        self.choose_folder.clicked.connect(self._choose)
        layout.addWidget(self.choose_folder)

        tools = QGridLayout()
        self.project_tools: list[QPushButton] = []
        for index, (label, program) in enumerate((
            ("Terminal", "konsole"), ("Arquivos", "dolphin"),
            ("Editor de texto", "kate"), ("Navegador", "firefox"),
        )):
            button = QPushButton(label)
            button.clicked.connect(lambda _checked=False, name=program: self._open_tool(name))
            tools.addWidget(button, index // 2, index % 2)
            if program != "firefox":
                self.project_tools.append(button)
        layout.addLayout(tools)

        self.status = QLabel()
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.status)
        self._build_autostart(layout)
        self._restore()
        self._refresh()
        self.editor.currentIndexChanged.connect(self._remember_selection)

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

    def _open_tool(self, program: str) -> None:
        args: list[str] = []
        working_directory = str(Path.home())
        if program != "firefox":
            if not self._folder_available():
                self._refresh()
                return
            working_directory = str(self.project)
            if program == "konsole":
                args = ["--workdir", working_directory]
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
        started, _pid = QProcess.startDetached(executable, args, working_directory)
        self._report("Abertura solicitada." if started else f"Falha ao iniciar {program}. Tente novamente.")
