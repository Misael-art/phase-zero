from __future__ import annotations

import json
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path

from PySide6.QtCore import QProcess, QProcessEnvironment, Qt, QTimer
from PySide6.QtWidgets import (
    QButtonGroup,
    QDialog,
    QDialogButtonBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMessageBox,
    QPushButton,
    QRadioButton,
    QStyle,
    QVBoxLayout,
)

from .widgets import fit_to_screen, themed_icon
from .platform import admin_bridge


@dataclass(frozen=True)
class BootChoice:
    key: str
    title: str
    description: str
    icon: str


BOOT_CHOICES = (
    BootChoice("normal", "Linux normal", "Limpa one-shot e usa padrão da distro.", "computer"),
    BootChoice("steamos", "SteamOS", "Próximo boot abre Steam/Gamepad UI.", "input-gaming"),
    BootChoice("windows", "Windows VM", "Próximo boot abre Windows VM fullscreen.", "computer"),
    BootChoice("waydroid", "Waydroid", "Próximo boot abre Android kiosk.", "phone"),
    BootChoice("emergency", "Emergência", "Próximo boot entra em rescue.target.", "dialog-warning"),
)


def load_dynamic_boot_choices(root: Path) -> tuple[BootChoice, ...]:
    command = [str(root / "linux" / "pz"), "boot", "catalog"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=5, check=False)
        if result.returncode != 0:
            return ()
        payload = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return ()
    choices: list[BootChoice] = []
    for item in payload.get("choices", []):
        if not item.get("available", False):
            continue
        key = str(item.get("key", ""))
        title = str(item.get("title", ""))
        description = str(item.get("description", ""))
        if not key or not title:
            continue
        icon = "drive-removable-media" if key.startswith("usb:") else "media-optical"
        if key == "grubfm":
            icon = "folder-open"
        choices.append(BootChoice(key, title, description, icon))
    return tuple(choices)


def build_boot_selector_program(root: Path, choice: str, *, reboot: bool) -> tuple[str, list[str]]:
    bridge = admin_bridge()
    if not bridge:
        raise RuntimeError("elevação indisponível; execute `linux/pz ai setup admin`")
    pz = str(root / "linux" / "pz")
    args = [pz, "boot", "choose", choice]
    if reboot:
        args.append("--reboot")
    return bridge, args


class BootSelectorWindow(QDialog):
    def __init__(self, root: Path, *, smoke_test: bool = False) -> None:
        super().__init__()
        self.root = root
        self.boot_choices = BOOT_CHOICES + load_dynamic_boot_choices(root)
        self.choice_buttons: dict[int, str] = {}
        self.group = QButtonGroup(self)
        self.setWindowTitle("PhaseZero - Seletor de Boot")
        fit_to_screen(self, 560, 560)
        self._build_ui()
        if smoke_test:
            self.setProperty("smokeTest", True)

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 18, 18, 18)
        outer.setSpacing(12)
        title = QLabel("Seletor de boot")
        title.setObjectName("pageTitle")
        subtitle = QLabel("Escolha a próxima sessão antes de reiniciar.")
        subtitle.setObjectName("pageSubtitle")
        outer.addWidget(title)
        outer.addWidget(subtitle)

        for index, choice in enumerate(self.boot_choices):
            card = QFrame()
            card.setObjectName("actionCard")
            row = QHBoxLayout(card)
            row.setContentsMargins(14, 12, 14, 12)
            icon = QLabel()
            icon.setPixmap(themed_icon(card, choice.icon, QStyle.SP_ComputerIcon).pixmap(30, 30))
            icon.setFixedSize(38, 38)
            row.addWidget(icon)
            text_box = QVBoxLayout()
            label = QLabel(choice.title)
            label.setObjectName("cardTitle")
            desc = QLabel(choice.description)
            desc.setObjectName("cardDescription")
            desc.setWordWrap(True)
            text_box.addWidget(label)
            text_box.addWidget(desc)
            row.addLayout(text_box, 1)
            radio = QRadioButton()
            radio.setAccessibleName(choice.title)
            self.group.addButton(radio, index)
            self.choice_buttons[index] = choice.key
            row.addWidget(radio)
            card.mousePressEvent = lambda _event, button=radio: button.setChecked(True)  # type: ignore[method-assign]
            outer.addWidget(card)
            if index == 0:
                radio.setChecked(True)

        buttons = QDialogButtonBox()
        self.status_label = QLabel("")
        self.status_label.setObjectName("pageSubtitle")
        self.status_label.setWordWrap(True)
        self.status_label.setAccessibleName("Estado do agendamento")
        outer.addWidget(self.status_label)
        schedule = QPushButton("Agendar")
        schedule.setObjectName("primaryButton")
        schedule.clicked.connect(lambda: self.run_choice(reboot=False))
        reboot = QPushButton("Agendar + reiniciar")
        reboot.setObjectName("dangerButton")
        reboot.clicked.connect(lambda: self.run_choice(reboot=True))
        cancel = buttons.addButton("Cancelar", QDialogButtonBox.RejectRole)
        cancel.clicked.connect(self.reject)
        buttons.addButton(schedule, QDialogButtonBox.ActionRole)
        buttons.addButton(reboot, QDialogButtonBox.ActionRole)
        self.action_buttons = (schedule, reboot)
        self._process: QProcess | None = None
        self._timeout_timer = QTimer(self)
        self._timeout_timer.setSingleShot(True)
        self._timeout_timer.timeout.connect(self._choice_timed_out)
        self._timed_out = False
        outer.addWidget(buttons)

    def selected_choice(self) -> str:
        return self.choice_buttons.get(self.group.checkedId(), "normal")

    RUN_TIMEOUT_MS = 120_000

    def _choice_title(self, key: str) -> str:
        return next((c.title for c in self.boot_choices if c.key == key), key)

    def _report(self, icon, title: str, text: str, informative: str = "", detailed: str = "") -> None:
        box = QMessageBox(self)
        box.setIcon(icon)
        box.setWindowTitle(title)
        box.setText(text)
        if informative:
            box.setInformativeText(informative)
        if detailed:
            box.setDetailedText(detailed)
        box.exec()

    def reject(self) -> None:
        # Não abandona um agendamento em curso (GRUB pela metade).
        if self._process is not None:
            self.status_label.setText("Aguarde: o agendamento ainda está em andamento.")
            return
        super().reject()

    def _set_busy(self, busy: bool, message: str = "") -> None:
        for button in self.action_buttons:
            button.setEnabled(not busy)
        self.status_label.setText(message)

    def run_choice(self, *, reboot: bool) -> None:
        """LUX-015: agenda sem congelar a janela (pkexec pode esperar senha)."""
        if self._process is not None:
            return
        choice = self.selected_choice()
        try:
            program, args = build_boot_selector_program(self.root, choice, reboot=reboot)
        except RuntimeError as exc:
            self._report(QMessageBox.Critical, "Elevação indisponível", str(exc))
            return
        self._pending = (choice, shlex.join([program, *args]))
        self._timed_out = False
        process = QProcess(self)
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PZ_UI", "native-boot-selector")
        process.setProcessEnvironment(env)
        process.setWorkingDirectory(str(self.root))
        process.finished.connect(self._choice_finished)
        process.errorOccurred.connect(self._choice_error)
        self._process = process
        self._set_busy(True, "Aguardando autorização do administrador…")
        process.start(program, args)
        self._timeout_timer.start(self.RUN_TIMEOUT_MS)

    def _choice_timed_out(self) -> None:
        if self._process is not None and self._process.state() != QProcess.NotRunning:
            self._timed_out = True
            self._process.kill()

    def _choice_error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart and self._process is not None:
            message = self._process.errorString()
            self._finish_process()
            self._fail(message)

    def _finish_process(self) -> tuple[str, str]:
        self._timeout_timer.stop()
        process = self._process
        self._process = None
        self._set_busy(False)
        if process is None:
            return "", ""
        out = bytes(process.readAllStandardOutput().data()).decode("utf-8", errors="replace").strip()
        err = bytes(process.readAllStandardError().data()).decode("utf-8", errors="replace").strip()
        process.deleteLater()
        return out, err

    def _choice_finished(self, code: int, _status=None) -> None:
        if self._process is None:
            return
        stdout, stderr = self._finish_process()
        choice, display = self._pending
        if self._timed_out:
            self._fail("tempo esgotado aguardando a autorização ou o GRUB", detailed=display)
            return
        if code == 0:
            self._report(
                QMessageBox.Information, "Boot agendado",
                f"Próximo boot: {self._choice_title(choice)}.", detailed=stdout or display,
            )
            self.accept()
            return
        lines = [ln.strip() for ln in (stderr.splitlines() + stdout.splitlines()) if ln.strip()]
        cause = lines[-1][:200] if lines else f"código {code}"
        detailed = "\n".join(part for part in (display, stdout, stderr) if part)
        self._fail(cause, detailed=detailed)

    def _fail(self, cause: str, *, detailed: str = "") -> None:
        choice = self._pending[0] if getattr(self, "_pending", None) else self.selected_choice()
        title = self._choice_title(choice)
        if choice == "windows":
            hint = ("Confira se a entrada do Windows existe no GRUB e tente de novo; "
                    "o reparo fica em Windows VM → Reparo.")
        else:
            hint = "Confira o estado em Boot Direto na Central e tente de novo."
        self._report(
            QMessageBox.Critical, "Falha ao agendar boot",
            f"Não foi possível agendar “{title}” agora.",
            f"Causa: {cause}\n\n{hint}", detailed,
        )
