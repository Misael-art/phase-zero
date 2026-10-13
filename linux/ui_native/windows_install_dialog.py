from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import QProcess, QProcessEnvironment, QTimer, Qt
from PySide6.QtWidgets import (
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)

from .catalog import WINDOWS_VM_GRAPHICS_OPTIONS
from .graphics_profiles import (
    host_profile_state, recommended_profile, simple_graphics_options,
)
from .widgets import fit_to_screen


def completed_image_indices(operations_dir: Path | None = None, *, iso_sha256: str = "") -> set[int]:
    """Return indices installed from this exact ISO digest for display hints."""
    if not iso_sha256:
        return set()
    root = operations_dir or Path.home() / ".local/state/phasezero/operations"
    used: set[int] = set()
    if not root.is_dir():
        return used
    for operation_file in root.glob("*/operation.json"):
        try:
            operation = json.loads(operation_file.read_text(encoding="utf-8"))
            if operation.get("state") != "completed" or operation.get("vmRemovedAt"):
                continue
            vm_dir_file = operation_file.parent / "vm_dir"
            if vm_dir_file.exists() and not Path(vm_dir_file.read_text().strip()).is_dir():
                continue
            plan = json.loads((operation_file.parent / "plan.json").read_text(encoding="utf-8"))
            plan_sha = str((plan.get("iso") or {}).get("sha256") or plan.get("isoSha256") or "")
            index = int(plan.get("imageIndex", 0))
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            continue
        if plan_sha.casefold() == iso_sha256.casefold() and index > 0:
            used.add(index)
    return used


class WindowsInstallDialog(QDialog):
    """Collect the complete install contract before the provision player opens."""

    def __init__(self, parent: QWidget | None = None, *, used_indices: set[int] | None = None,
                 graphics_status: dict | None = None, advanced: bool = False) -> None:
        super().__init__(parent, Qt.Dialog)
        self.setObjectName("windowsInstallDialog")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setAutoFillBackground(True)
        self.setWindowTitle("Instalar Windows automaticamente")
        self.setWindowModality(Qt.WindowModal)
        fit_to_screen(self, 620, 520)
        # Indices identify images inside one ISO; repeated installs are valid.
        # Keep the legacy keyword accepted while callers migrate.
        self._media_process: QProcess | None = None
        self._media_stdout = bytearray()
        self._media_stderr = bytearray()
        self._media_inspected = False
        self._media_valid = False
        self._has_named_images = False
        self._media_timeout = QTimer(self)
        self._media_timeout.setSingleShot(True)
        self._media_timeout.timeout.connect(self._media_timed_out)
        # UX-010: what this host can actually do decides what is offered.
        self._graphics_status = graphics_status or {}
        self._advanced = advanced

        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 18, 20, 18)
        layout.setSpacing(14)

        title = QLabel("Preparar instalação do Windows 11")
        title.setObjectName("sectionHeading")
        layout.addWidget(title)
        intro = QLabel(
            "Escolha a ISO e as opções antes de iniciar. O PhaseZero valida o arquivo "
            "e lê as edições disponíveis nessa mídia."
        )
        intro.setObjectName("cardDescription")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(12)

        iso_row = QHBoxLayout()
        self.iso_edit = QLineEdit()
        self.iso_edit.setObjectName("windowsIsoPath")
        self.iso_edit.setReadOnly(True)
        self.iso_edit.setPlaceholderText("Nenhuma ISO selecionada")
        choose = QPushButton("Escolher ISO…")
        choose.setObjectName("secondaryButton")
        choose.clicked.connect(self.choose_iso)
        self.choose_iso_button = choose
        iso_row.addWidget(self.iso_edit, 1)
        iso_row.addWidget(choose)
        form.addRow("ISO do Windows:", iso_row)

        # UX-010: simple mode offers only what is stable on THIS host, and
        # says which display is recommended and why. Experimental paths —
        # including anything the host reports as experimental or blocked —
        # exist only in the advanced list, labelled as such.
        self.graphics_combo = QComboBox()
        self.graphics_combo.setObjectName("windowsGraphicsProfile")
        options = (
            WINDOWS_VM_GRAPHICS_OPTIONS if self._advanced
            else simple_graphics_options(self._graphics_status)
        ) or simple_graphics_options({})
        for value, label, helper in options:
            host_mode, blockers = host_profile_state(self._graphics_status, value)
            if host_mode in ("experimental", "blocked"):
                label = f"{label} — {'indisponível neste host' if host_mode == 'blocked' else 'experimental neste host'}"
                if blockers:
                    helper = f"{helper}\nNeste host: {blockers[0]}"
            self.graphics_combo.addItem(label, (value, helper))
        self.graphics_combo.currentIndexChanged.connect(self._graphics_changed)
        form.addRow("Aceleração gráfica:", self.graphics_combo)

        profile, reason = recommended_profile(self._graphics_status)
        for row in range(self.graphics_combo.count()):
            data = self.graphics_combo.itemData(row)
            if isinstance(data, tuple) and data and data[0] == profile:
                self.graphics_combo.setCurrentIndex(row)
                break
        self.graphics_recommendation = QLabel(
            f"Recomendado para esta máquina: {profile}." + (f" {reason}" if reason else "")
        )
        self.graphics_recommendation.setObjectName("cardDescription")
        self.graphics_recommendation.setAccessibleName("Display recomendado e motivo")
        self.graphics_recommendation.setWordWrap(True)
        form.addRow("", self.graphics_recommendation)

        self.graphics_help = QLabel()
        self.graphics_help.setObjectName("cardDescription")
        self.graphics_help.setWordWrap(True)
        form.addRow("", self.graphics_help)

        self.edition_combo = QComboBox()
        self.edition_combo.setObjectName("windowsEditionIndex")
        self.edition_combo.hide()
        self.manual_index = QSpinBox()
        self.manual_index.setObjectName("windowsManualEditionIndex")
        self.manual_index.setRange(0, 99)
        self.manual_index.setSpecialValueText("Informe o índice da imagem")
        self.manual_index.setToolTip(
            "Use o índice mostrado pelo DISM /Get-WimInfo ou wimlib-imagex info."
        )
        edition_row = QHBoxLayout()
        edition_row.addWidget(self.edition_combo, 1)
        edition_row.addWidget(self.manual_index, 1)
        self.manual_index.hide()
        form.addRow("Edição do Windows:", edition_row)

        self.login_combo = QComboBox()
        self.login_combo.setObjectName("windowsGuestLogin")
        self.login_combo.addItem("Entrar automaticamente", "auto")
        self.login_combo.addItem("Exigir senha", "password")
        form.addRow("Login no Windows:", self.login_combo)
        layout.addLayout(form)

        self.buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        install = self.buttons.button(QDialogButtonBox.Ok)
        cancel = self.buttons.button(QDialogButtonBox.Cancel)
        if install:
            install.setText("Instalar automaticamente")
            install.setObjectName("primaryButton")
            install.setEnabled(True)
        if cancel:
            cancel.setText("Cancelar")
        self.buttons.accepted.connect(self._accept_if_valid)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)
        self._graphics_changed(self.graphics_combo.currentIndex())

    def choose_iso(self) -> None:
        path, _selected_filter = QFileDialog.getOpenFileName(
            self,
            "Escolha a ISO do Windows",
            str(Path.home()),
            "Imagens ISO (*.iso);;Todos os arquivos (*)",
        )
        if path:
            self.iso_edit.setText(path)
            self._media_inspected = False
            self._media_valid = False
            self._set_image_entries([])
            self._inspect_iso(path)

    def _set_image_entries(self, images: list[dict]) -> None:
        self.edition_combo.clear()
        for image in images:
            try:
                index = int(image.get("index", 0))
            except (TypeError, ValueError):
                continue
            if index < 1:
                continue
            edition = str(image.get("edition") or image.get("name") or f"Índice {index}")
            self.edition_combo.addItem(f"{index} — {edition}", index)
        has_named_images = self.edition_combo.count() > 0
        self._has_named_images = has_named_images
        self.edition_combo.setVisible(has_named_images)
        self.manual_index.setVisible(not has_named_images)
        if not has_named_images:
            self.graphics_help.setText(
                "Esta ISO é válida, mas a lista de imagens não pôde ser lida. Informe o índice exato "
                "do WIM/ESD; a instalação fica bloqueada enquanto o índice estiver em branco."
            )

    def _inspect_iso(self, path: str) -> None:
        if self._media_process is not None and self._media_process.state() != QProcess.NotRunning:
            self._media_process.finished.disconnect()
            self._media_process.errorOccurred.disconnect()
            self._media_process.kill()
        self._media_stdout.clear()
        self._media_stderr.clear()
        process = QProcess(self)
        self._media_process = process
        process.setProcessEnvironment(QProcessEnvironment.systemEnvironment())
        process.readyReadStandardOutput.connect(
            lambda p=process: self._media_stdout.extend(bytes(p.readAllStandardOutput()))
        )
        process.readyReadStandardError.connect(
            lambda p=process: self._media_stderr.extend(bytes(p.readAllStandardError()))
        )
        process.finished.connect(self._media_finished)
        process.errorOccurred.connect(self._media_error)
        self.graphics_help.setText("Lendo edições desta ISO…")
        self.choose_iso_button.setEnabled(False)
        self.buttons.button(QDialogButtonBox.Ok).setEnabled(False)
        self._media_inspected = False
        self._media_valid = False
        root = Path(__file__).resolve().parents[2]
        process.start(str(root / "linux" / "pz"), [
            "windows-vm", "media", "inspect", "--iso", path, "--json",
        ])
        self._media_timeout.start(120_000)

    def _media_finished(self, exit_code: int, _exit_status: QProcess.ExitStatus) -> None:
        self._media_timeout.stop()
        self.choose_iso_button.setEnabled(True)
        self.buttons.button(QDialogButtonBox.Ok).setEnabled(True)
        try:
            payload = json.loads(bytes(self._media_stdout).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        images = payload.get("images") if isinstance(payload, dict) else None
        self._set_image_entries([item for item in images or [] if isinstance(item, dict)])
        self._media_inspected = exit_code == 0 and isinstance(payload, dict)
        self._media_valid = self._media_inspected and payload.get("valid") is True
        self.buttons.button(QDialogButtonBox.Ok).setEnabled(self._media_valid)
        if not self._media_valid:
            self.graphics_help.setText(
                "A ISO não passou na validação (inicialização UEFI ou payload Windows ausente). "
                "Escolha outra mídia antes de instalar."
            )
            return
        if isinstance(payload, dict) and payload.get("payloadNote"):
            self.graphics_help.setText(
                str(payload["payloadNote"]) + " Informe o índice exato do WIM/ESD para continuar."
            )

    def _media_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart:
            self._media_finished(127, QProcess.CrashExit)

    def _media_timed_out(self) -> None:
        if self._media_process is not None and self._media_process.state() != QProcess.NotRunning:
            self._media_process.kill()
        self.graphics_help.setText("A leitura desta ISO excedeu o tempo limite. Confira o arquivo e tente novamente.")
        self.choose_iso_button.setEnabled(True)
        self._media_inspected = False
        self._media_valid = False
        self.buttons.button(QDialogButtonBox.Ok).setEnabled(False)

    def _graphics_changed(self, index: int) -> None:
        data = self.graphics_combo.itemData(index)
        value, helper = data if isinstance(data, tuple) and len(data) == 2 else ("compat", "")
        self.graphics_help.setText(str(helper))

    def _accept_if_valid(self) -> None:
        iso = Path(self.iso_edit.text()).expanduser()
        if not self.iso_edit.text() or not iso.is_file() or iso.suffix.casefold() != ".iso":
            QMessageBox.warning(
                self,
                "ISO necessária",
                "Escolha um arquivo .iso do Windows válido antes de continuar.",
            )
            return
        if not self._media_inspected or not self._media_valid:
            QMessageBox.warning(self, "ISO não validada", "Aguarde a inspeção ou escolha uma ISO válida.")
            return
        if self._has_named_images and self.edition_combo.currentIndex() < 0:
            QMessageBox.warning(
                self, "Edições indisponíveis",
                "A ISO não apresentou índices de edição utilizáveis. Confira a mídia ou escolha outra ISO.",
            )
            return
        if not self._has_named_images and self.manual_index.value() < 1:
            QMessageBox.warning(
                self, "Índice da edição necessário",
                "A mídia não revelou as edições. Informe o índice exato do WIM/ESD antes de iniciar.",
            )
            return
        self.accept()

    def graphics_value(self) -> str:
        data = self.graphics_combo.currentData()
        value = data[0] if isinstance(data, tuple) and data else "compat"
        return str(value)

    def values(self) -> dict[str, str]:
        return {
            "input": self.iso_edit.text(),
            "graphics": self.graphics_value(),
            "image_index": str(
                self.edition_combo.currentData()
                if self._has_named_images
                else self.manual_index.value()
            ),
            "guest_login": str(self.login_combo.currentData()),
        }
