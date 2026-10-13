from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QThread, Signal, Qt, QTimer
from PySide6.QtGui import QTextCursor
from PySide6.QtWidgets import (
    QCheckBox, QDialog, QDialogButtonBox, QFormLayout, QFrame, QHBoxLayout,
    QLabel, QPlainTextEdit, QProgressBar, QPushButton, QStyle, QVBoxLayout,
    QWidget, QMessageBox, QInputDialog, QLineEdit,
)

from .journey import failure_cause
from .models import ActionSpec
from .platform import admin_bridge, state_dir, secure_file
from .widgets import fit_to_screen


PLAYER_STATE_PATH = state_dir() / "windows-vm" / "player.json"
OPERATIONS_STATE_DIR = state_dir().parent / "operations"
PRODUCTION_OPERATION_ID = re.compile(r"^op-\d{8}-\d{6}-\d+$")

ST_IDLE = "idle"
ST_PLANNING = "planning"
ST_CONFIRMING = "confirming"
ST_PROVISIONING = "provisioning"
ST_VALIDATING = "validating"
ST_DONE = "done"
ST_CANCELLED = "cancelled"
ST_FAILED = "failed"

MAX_POLL_FAILURES = 5
POLL_INTERVAL_MS = 2000
BACKOFF_INTERVAL_MS = 5000
SHUTDOWN_TIMEOUT_MS = 70_000
VALIDATE_TIMEOUT_MS = 20_000
BOOT_STATUS_TIMEOUT_MS = 20_000
CANCEL_TIMEOUT_MS = 15_000
FINALIZE_TIMEOUT_MS = 30 * 60 * 1000

# Workers that outlived the window's bounded close wait; kept referenced so
# their QThreads are not destroyed while still running.
_DETACHED_WORKERS: list[ProvisionWorker] = []


def recovery_password_strength(password: str) -> tuple[bool, str]:
    checks = (
        len(password) >= 14,
        any(char.isupper() for char in password),
        any(char.islower() for char in password),
        any(char.isdigit() for char in password),
        any(not char.isalnum() for char in password),
    )
    score = sum(checks)
    if score == 5:
        return True, "Forte — requisitos atendidos"
    missing = []
    labels = ("14+ caracteres", "maiúscula", "minúscula", "número", "símbolo")
    for ok, label in zip(checks, labels):
        if not ok:
            missing.append(label)
    return False, "Faltam: " + ", ".join(missing)



# LUX-022: worker reasons are technical English; the user sees these.
_PROVISION_FAILURES = {
    "provision start timed out": "A instalação não começou a tempo. Tente de novo.",
    "provision start failed": "A instalação não conseguiu começar. Veja os detalhes técnicos e tente de novo.",
    "no operationId": "A instalação não foi registrada. Tente de novo.",
    "status JSON invalid": "Perdemos o acompanhamento da instalação. Feche e reabra para reconectar.",
    "failed": "A instalação do Windows falhou. Veja os detalhes técnicos; você pode tentar de novo.",
    "cancelled": "A instalação foi cancelada. O disco foi preservado para retomar.",
}


def friendly_provision_failure(reason: str) -> str:
    text = (reason or "").strip()
    if text in _PROVISION_FAILURES:
        return _PROVISION_FAILURES[text]
    if text.startswith("status poll failed"):
        return "Perdemos contato com a instalação em andamento. Ela pode continuar; reabra para reconectar."
    if text.startswith("start JSON"):
        return _PROVISION_FAILURES["provision start failed"]
    cause, action = failure_cause(text)
    return f"{cause} {action}"

class RecoveryPasswordDialog(QDialog):
    """Collect a recovery secret in memory. No state or logging hooks."""

    def __init__(self, parent: QWidget | None = None, allow_remote: bool = False) -> None:
        super().__init__(parent, Qt.Window)
        self.setWindowTitle("Administrador de recuperação")
        layout = QVBoxLayout(self)
        note = QLabel(
            "Crie uma senha conhecida por você para PZ-Recovery. "
            "PhaseZero não salva nem consegue recuperar esta senha."
        )
        note.setWordWrap(True)
        layout.addWidget(note)
        form = QFormLayout()
        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.password_edit.setObjectName("recoveryPassword")
        self.confirm_edit = QLineEdit()
        self.confirm_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.confirm_edit.setObjectName("recoveryPasswordConfirm")
        form.addRow("Senha:", self.password_edit)
        form.addRow("Confirmar:", self.confirm_edit)
        layout.addLayout(form)
        self.strength_label = QLabel("Faltam: 14+ caracteres, maiúscula, minúscula, número, símbolo")
        self.strength_label.setObjectName("recoveryPasswordStrength")
        self.strength_label.setWordWrap(True)
        layout.addWidget(self.strength_label)
        self.remote_check = QCheckBox("Permitir recuperação via RDP")
        self.remote_check.setChecked(allow_remote)
        layout.addWidget(self.remote_check)
        self.buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        layout.addWidget(self.buttons)
        self.password_edit.textChanged.connect(self._validate)
        self.confirm_edit.textChanged.connect(self._validate)
        self._validate()

    def _validate(self) -> None:
        strong, label = recovery_password_strength(self.password_edit.text())
        matches = bool(self.password_edit.text()) and self.password_edit.text() == self.confirm_edit.text()
        if strong and not matches:
            label = "Forte — confirmação não coincide"
        self.strength_label.setText(label)
        self.strength_label.setStyleSheet("color: #4caf50;" if strong and matches else "color: #e0a000;")
        button = self.buttons.button(QDialogButtonBox.Ok)
        if button:
            button.setEnabled(strong and matches)

    def take_credentials(self) -> tuple[str, bool]:
        password = self.password_edit.text()
        allow_remote = self.remote_check.isChecked()
        self.password_edit.clear()
        self.confirm_edit.clear()
        return password, allow_remote


class AsyncProc(QObject):
    finished = Signal(object, int)
    errorOccurred = Signal(str)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._proc: QProcess | None = None
        self._timeout_timer: QTimer | None = None
        self._done = False
        self._stdout_buf = ""
        self._stderr_buf = ""

    def run(self, program: str, args: list[str], timeout_ms: int = 30_000,
            stdin_data: str = "") -> None:
        self._done = False
        self._stdout_buf = ""
        self._stderr_buf = ""
        self._proc = QProcess(self)
        self._proc.setProgram(program)
        self._proc.setArguments(args)
        self._proc.readyReadStandardOutput.connect(self._on_stdout)
        self._proc.readyReadStandardError.connect(self._on_stderr)
        self._proc.finished.connect(self._on_finished)
        self._proc.errorOccurred.connect(self._on_error)
        self._proc.start()
        if stdin_data:
            self._proc.write(stdin_data.encode("utf-8"))
            self._proc.closeWriteChannel()
        if timeout_ms > 0:
            self._timeout_timer = QTimer(self)
            self._timeout_timer.setSingleShot(True)
            self._timeout_timer.timeout.connect(self._on_timeout)
            self._timeout_timer.start(timeout_ms)

    def abort(self) -> None:
        self._done = True
        if self._timeout_timer:
            self._timeout_timer.stop()
        if self._proc and self._proc.state() != QProcess.NotRunning:
            self._proc.kill()

    @property
    def stdout(self) -> str:
        return self._stdout_buf

    @property
    def stderr(self) -> str:
        return self._stderr_buf

    def _finish_once(self, parsed: object | None, exit_code: int) -> None:
        if self._done:
            return
        self._done = True
        if self._timeout_timer:
            self._timeout_timer.stop()
        self.finished.emit(parsed, exit_code)

    def _on_stdout(self) -> None:
        if self._proc:
            self._stdout_buf += self._proc.readAllStandardOutput().data().decode("utf-8", errors="replace")

    def _on_stderr(self) -> None:
        if self._proc:
            self._stderr_buf += self._proc.readAllStandardError().data().decode("utf-8", errors="replace")

    def _on_finished(self, exit_code: int) -> None:
        data = self._stdout_buf
        try:
            parsed = json.loads(data.strip())
        except (json.JSONDecodeError, ValueError):
            parsed = None
        self._finish_once(parsed, exit_code)

    def _on_error(self, error: QProcess.ProcessError) -> None:
        err_msg = self._proc.errorString() if self._proc else str(error)
        self.errorOccurred.emit(err_msg)
        self._finish_once(None, -2)

    def _on_timeout(self) -> None:
        if self._proc and self._proc.state() != QProcess.NotRunning:
            self._proc.kill()
        self._finish_once(None, -1)


class ProvisionWorker(QThread):
    progress_updated = Signal(str, int, str, str, list)
    started = Signal(str)
    completed = Signal(str)
    failed = Signal(str)

    def __init__(self, root: Path, plan_id: str, confirm_token: str,
                 parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._root = root
        self._plan_id = plan_id
        self._confirm_token = confirm_token
        self._operation_id = ""
        self._mode = "start"
        self._aborted = False
        self._last_log_count = 0

    def configure_attach(self, operation_id: str) -> None:
        self._mode = "attach"
        self._operation_id = operation_id

    def abort(self) -> None:
        self._aborted = True

    def run(self) -> None:
        pz = str(self._root / "linux" / "pz")

        if self._mode == "start":
            proc = QProcess()
            proc.setProgram(pz)
            proc.setArguments([
                "windows-vm", "provision", "start",
                "--plan-id", self._plan_id,
                "--confirm", self._confirm_token,
                "--json",
            ])
            proc.start()
            if not proc.waitForFinished(30_000):
                self.failed.emit("provision start timed out")
                return
            if proc.exitCode() != 0:
                err = proc.readAllStandardError().data().decode("utf-8", errors="replace").strip()
                self.failed.emit(err or "provision start failed")
                return
            data = proc.readAllStandardOutput().data().decode("utf-8", errors="replace").strip()
            try:
                start_data = json.loads(data)
            except json.JSONDecodeError as exc:
                self.failed.emit(f"start JSON: {exc}")
                return
            op_id = start_data.get("operationId", "")
            if not op_id:
                self.failed.emit("no operationId")
                return
            self._operation_id = op_id
            self.started.emit(op_id)
        else:
            self.started.emit(self._operation_id)

        failures = 0
        while not self._aborted:
            stat_proc = QProcess()
            stat_proc.setProgram(pz)
            stat_proc.setArguments([
                "windows-vm", "provision", "status",
                "--operation-id", self._operation_id,
                "--json",
            ])
            stat_proc.start()
            ok = stat_proc.waitForFinished(15_000)
            if not ok:
                # QProcess coletado com filho vivo vira órfão; mata antes de
                # descartar e reprograma o poll.
                stat_proc.kill()
                stat_proc.waitForFinished(2_000)
            if self._aborted:
                return
            if not ok or stat_proc.exitCode() != 0:
                failures += 1
                if failures >= MAX_POLL_FAILURES:
                    self.failed.emit(f"status poll failed {failures}x")
                    return
                for _ in range(BACKOFF_INTERVAL_MS // 100):
                    if self._aborted:
                        return
                    self.msleep(100)
                continue

            failures = 0
            raw = stat_proc.readAllStandardOutput().data().decode("utf-8", errors="replace").strip()
            try:
                stat = json.loads(raw)
            except json.JSONDecodeError:
                failures += 1
                if failures >= MAX_POLL_FAILURES:
                    self.failed.emit("status JSON invalid")
                    return
                for _ in range(BACKOFF_INTERVAL_MS // 100):
                    if self._aborted:
                        return
                    self.msleep(100)
                continue

            state = stat.get("state", "")
            checkpoint = stat.get("currentLabel", stat.get("checkpoint", ""))
            progress = stat.get("progress", 0)
            log_entries = stat.get("log", [])
            new_logs = log_entries[self._last_log_count:]
            self._last_log_count = len(log_entries)

            self.progress_updated.emit(checkpoint, progress, state, self._operation_id, new_logs)

            if state == "completed":
                self.completed.emit(self._operation_id)
                return
            if state in ("failed", "cancelled"):
                self.failed.emit(state)
                return

            for _ in range(POLL_INTERVAL_MS // 100):
                if self._aborted:
                    return
                self.msleep(100)


class StepIndicator(QWidget):
    STEPS = ["Plan", "Confirm", "Run", "Validate", "Done"]

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(4)
        for i, name in enumerate(self.STEPS):
            dot = QLabel()
            dot.setFixedSize(12, 12)
            dot.setObjectName(f"stepDot_{i}")
            dot.setToolTip(name)
            layout.addWidget(dot)
            lbl = QLabel(name)
            lbl.setObjectName(f"stepLbl_{i}")
            layout.addWidget(lbl)
            if i < len(self.STEPS) - 1:
                sep = QLabel("\u2500")
                sep.setStyleSheet("color: #444;")
                layout.addWidget(sep)
        self._current = -1
        self._update_colors()

    def set_step(self, index: int) -> None:
        self._current = index
        self._update_colors()

    def _update_colors(self) -> None:
        done_color = "#4caf50"
        active_color = "#f0b000"
        pending_color = "#555"
        for i in range(len(self.STEPS)):
            dot = self.findChild(QLabel, f"stepDot_{i}")
            lbl = self.findChild(QLabel, f"stepLbl_{i}")
            if not dot or not lbl:
                continue
            if i < self._current:
                dot.setStyleSheet(f"background: {done_color}; border-radius: 6px; min-width: 12px; min-height: 12px;")
                lbl.setStyleSheet("color: #aaa; font-size: 10px;")
            elif i == self._current:
                dot.setStyleSheet(f"background: {active_color}; border-radius: 6px; min-width: 12px; min-height: 12px;")
                lbl.setStyleSheet("color: #ddd; font-size: 10px; font-weight: bold;")
            else:
                dot.setStyleSheet(f"background: {pending_color}; border-radius: 6px; min-width: 12px; min-height: 12px;")
                lbl.setStyleSheet("color: #666; font-size: 10px;")


class ProvisionPlayerWindow(QDialog):
    _instance: ProvisionPlayerWindow | None = None

    @classmethod
    def open(cls, root: Path, runner, parent: QWidget | None = None,
             iso: str = "", graphics: str = "compat",
             image_index: str = "1", guest_login: str = "auto", recovery: bool = True,
             recovery_local_only: bool = True) -> ProvisionPlayerWindow:
        if cls._instance is not None:
            win = cls._instance
            resumed = win._resume_state()
            if not resumed:
                win._apply_launch_params(iso, graphics, image_index, guest_login, recovery, recovery_local_only)
            win._update_summary()
            win.show()
            win.raise_()
            win.activateWindow()
            return win
        instance = cls(root, runner, parent, iso, graphics, image_index, guest_login, recovery, recovery_local_only)
        cls._instance = instance
        return instance

    def __init__(self, root: Path, runner, parent: QWidget | None = None,
                 iso: str = "", graphics: str = "compat",
                 image_index: str = "1", guest_login: str = "auto", recovery: bool = True,
                 recovery_local_only: bool = True) -> None:
        super().__init__(parent, Qt.Window)
        self.setObjectName("provisionPlayerWindow")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setAutoFillBackground(True)
        self._root = root
        self._runner = runner
        self._iso = ""
        self._graphics = "compat"
        self._image_index = "1"
        self._guest_login = "auto"
        self._guest_login_applied = False
        self._recovery_requested = True
        self._recovery_local_only = True
        self._qga_socket = ""
        self._provision_snapshot = ""
        self._plan_id = ""
        self._confirm_token = ""
        self._operation_id = ""
        self._worker: ProvisionWorker | None = None
        self._state = ST_IDLE
        self._elapsed_start = 0.0
        self._boot_ready = False
        self._one_shot_ready = False
        self._vm_running = False
        self._snapshot_ok = False
        self._adopted_ok = False
        self._async_proc: AsyncProc | None = None
        self._rollback_manifest = ""
        self._reboot_proc: QProcess | None = None
        self._closing = False
        self._discarding = False

        self.setWindowTitle("Preparar Windows e reiniciar")
        self.setWindowModality(Qt.WindowModal)
        fit_to_screen(self, 820, 540)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        layout.setContentsMargins(16, 16, 16, 16)

        hdr = QLabel("Preparar Windows para boot direto")
        hdr.setStyleSheet("font-size: 18px; font-weight: bold;")
        layout.addWidget(hdr)

        self._summary = QLabel()
        self._summary.setWordWrap(True)
        self._summary.setStyleSheet("color: #aaa; font-size: 12px;")
        layout.addWidget(self._summary)

        self._steps = StepIndicator()
        layout.addWidget(self._steps)

        sep = QFrame()
        sep.setFrameShape(QFrame.HLine)
        sep.setStyleSheet("color: #333;")
        layout.addWidget(sep)

        self._progress_bar = QProgressBar()
        self._progress_bar.setRange(0, 100)
        self._progress_bar.setValue(0)
        self._progress_bar.setTextVisible(True)
        layout.addWidget(self._progress_bar)

        self._checkpoint_label = QLabel("Aguardando in\u00edcio\u2026")
        self._checkpoint_label.setStyleSheet("font-size: 13px; color: #ccc;")
        layout.addWidget(self._checkpoint_label)

        self._elapsed_label = QLabel("00:00")
        self._elapsed_label.setStyleSheet("font-size: 11px; color: #888;")
        layout.addWidget(self._elapsed_label)

        self._details_btn = QPushButton("Ver detalhes técnicos")
        self._details_btn.setObjectName("secondaryButton")
        self._details_btn.setCheckable(True)
        layout.addWidget(self._details_btn, 0, Qt.AlignLeft)

        self._log_frame = QFrame()
        self._log_frame.setFrameShape(QFrame.StyledPanel)
        log_inner = QVBoxLayout(self._log_frame)
        log_inner.setContentsMargins(0, 0, 0, 0)
        log_lbl = QLabel("Log da opera\u00e7\u00e3o")
        log_lbl.setStyleSheet("font-size: 11px; color: #888; padding: 2px 0;")
        log_inner.addWidget(log_lbl)
        self._log = QPlainTextEdit()
        self._log.setReadOnly(True)
        self._log.setMaximumBlockCount(500)
        self._log.setStyleSheet(
            "font-family: monospace; font-size: 11px; background: #1a1a1a; color: #aaa;"
        )
        log_inner.addWidget(self._log)
        layout.addWidget(self._log_frame, 1)
        self._log_frame.setVisible(False)
        self._details_btn.toggled.connect(self._toggle_details)

        footer = QHBoxLayout()
        footer.setSpacing(8)

        self._start_btn = QPushButton("Iniciar instalação")
        self._start_btn.setObjectName("primaryButton")
        self._start_btn.clicked.connect(self._on_start_clicked)
        footer.addWidget(self._start_btn)

        self._cancel_btn = QPushButton("Cancelar")
        self._cancel_btn.clicked.connect(self._on_cancel)
        self._cancel_btn.setVisible(False)
        footer.addWidget(self._cancel_btn)

        self._retry_btn = QPushButton("Retomar")
        self._retry_btn.clicked.connect(self._on_retry)
        self._retry_btn.setVisible(False)
        footer.addWidget(self._retry_btn)

        self._discard_btn = QPushButton("Descartar")
        self._discard_btn.clicked.connect(self._on_discard)
        self._discard_btn.setVisible(False)
        footer.addWidget(self._discard_btn)

        self._repair_btn = QPushButton("Reparar boot")
        self._repair_btn.clicked.connect(self._on_repair_boot)
        self._repair_btn.setVisible(False)
        footer.addWidget(self._repair_btn)

        self._qga_repair_btn = QPushButton("Reparar agente e conta de recuperação")
        self._qga_repair_btn.clicked.connect(self._on_repair_qga)
        self._qga_repair_btn.setVisible(False)

        self._rollback_btn = QPushButton("Reverter reparo offline")
        self._rollback_btn.clicked.connect(self._on_rollback_qga)
        self._rollback_btn.setVisible(False)

        self._shutdown_btn = QPushButton("Desligar VM e validar")
        self._shutdown_btn.clicked.connect(self._on_shutdown_vm)
        self._shutdown_btn.setVisible(False)
        footer.addWidget(self._shutdown_btn)

        footer.addStretch()

        self._reboot_btn = QPushButton("Reiniciar no Windows")
        self._reboot_btn.setObjectName("rebootButton")
        self._reboot_btn.setStyleSheet(
            "QPushButton { background: #4caf50; color: #000; font-weight: bold; "
            "padding: 10px 24px; border-radius: 6px; }"
            "QPushButton:disabled { background: #333; color: #666; }"
        )
        self._reboot_btn.clicked.connect(self._on_reboot)
        self._reboot_btn.setEnabled(False)
        footer.addWidget(self._reboot_btn)

        layout.addLayout(footer)
        recovery_footer = QHBoxLayout()
        recovery_footer.addWidget(self._qga_repair_btn)
        recovery_footer.addWidget(self._rollback_btn)
        recovery_footer.addStretch()
        layout.addLayout(recovery_footer)

        self._elapsed_timer = QTimer(self)
        self._elapsed_timer.timeout.connect(self._update_elapsed)
        self._elapsed_timer.setInterval(1000)

        # Resume only after every widget used by _attach_worker/_set_state exists.
        # Caller parameters win over persisted display parameters.
        resumed = self._resume_state()
        if not resumed:
            self._apply_launch_params(iso, graphics, image_index, guest_login, recovery, recovery_local_only)
        self._update_summary()
        self.show()

    def _toggle_details(self, visible: bool) -> None:
        self._log_frame.setVisible(visible)
        self._details_btn.setText("Ocultar detalhes técnicos" if visible else "Ver detalhes técnicos")
        if visible:
            self.resize(
                min(max(self.width(), 820), self.maximumWidth()),
                min(max(self.height(), 640), self.maximumHeight()),
            )

    def _set_state(self, state: str) -> None:
        self._state = state
        step_map = {
            ST_IDLE: 0, ST_PLANNING: 0, ST_CONFIRMING: 1,
            ST_PROVISIONING: 2, ST_VALIDATING: 3, ST_DONE: 4,
            ST_CANCELLED: 2, ST_FAILED: 2,
        }
        self._steps.set_step(step_map.get(state, 0))
        running = state in (ST_CONFIRMING, ST_PROVISIONING, ST_VALIDATING)
        self._cancel_btn.setVisible(running)
        self._start_btn.setVisible(state in (ST_IDLE,))
        self._retry_btn.setVisible(state in (ST_FAILED, ST_CANCELLED))
        self._discard_btn.setVisible(state in (ST_FAILED, ST_CANCELLED))
        self._shutdown_btn.setVisible(False)
        self._repair_btn.setVisible(False)
        self._qga_repair_btn.setVisible(False)
        self._rollback_btn.setVisible(False)
        self._reboot_btn.setEnabled(False)

    def _save_state(self) -> None:
        data = {
            "state": self._state,
            "iso": self._iso,
            "graphics": self._graphics,
            "imageIndex": self._image_index,
            "guestLogin": self._guest_login,
            "operationId": self._operation_id,
            "rollbackManifest": self._rollback_manifest,
        }
        data["updatedAt"] = datetime.now(timezone.utc).isoformat()
        try:
            PLAYER_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
            secure_file(PLAYER_STATE_PATH, json.dumps(data, indent=2))
        except OSError:
            pass

    def _apply_launch_params(self, iso: str = "", graphics: str = "compat",
                              image_index: str = "1", guest_login: str = "auto", recovery: bool = True,
                              recovery_local_only: bool = True) -> None:
        self._iso = iso
        self._graphics = graphics
        self._image_index = image_index
        self._guest_login = guest_login if guest_login in ("auto", "password") else "auto"
        self._recovery_requested = bool(recovery)
        self._recovery_local_only = bool(recovery_local_only)

    def _operation_resume_issue(self, operation_id: str) -> str:
        if not operation_id:
            return "identificador ausente"
        if not PRODUCTION_OPERATION_ID.fullmatch(operation_id):
            return "identificador inválido"
        metadata = OPERATIONS_STATE_DIR / operation_id / "operation.json"
        if not metadata.is_file():
            return "operação não encontrada"
        try:
            payload = json.loads(metadata.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return "metadados ilegíveis"
        if not isinstance(payload, dict):
            return "metadados inválidos"
        return ""

    def _quarantine_orphaned_state(self, reason: str) -> None:
        quarantine = ""
        if PLAYER_STATE_PATH.exists():
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
            candidate = PLAYER_STATE_PATH.with_name(f"player.orphaned-{stamp}.json")
            try:
                PLAYER_STATE_PATH.replace(candidate)
                quarantine = str(candidate)
            except OSError:
                pass
        self._operation_id = ""
        self._plan_id = ""
        self._confirm_token = ""
        self._rollback_manifest = ""
        self._set_state(ST_IDLE)
        self._progress_bar.setRange(0, 100)
        self._progress_bar.setValue(0)
        self._checkpoint_label.setText("Sessão anterior inválida. Inicie uma nova instalação.")
        self._add_log(f"Sessão anterior ignorada: {reason}.")
        if quarantine:
            self._add_log(f"Registro preservado para diagnóstico: {quarantine}")

    def _resume_state(self) -> bool:
        if not PLAYER_STATE_PATH.exists():
            return False
        try:
            data = json.loads(PLAYER_STATE_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            self._quarantine_orphaned_state("registro local ilegível")
            return False

        if not isinstance(data, dict):
            self._quarantine_orphaned_state("registro local inválido")
            return False

        prev = data.get("state", "")
        self._operation_id = str(data.get("operationId") or "")
        resumable = prev in (ST_PROVISIONING, ST_VALIDATING, ST_DONE, ST_FAILED, ST_CANCELLED)
        if resumable:
            issue = self._operation_resume_issue(self._operation_id)
            if issue:
                self._quarantine_orphaned_state(issue)
                return False

        self._iso = str(data.get("iso") or self._iso)
        self._graphics = str(data.get("graphics") or self._graphics)
        self._image_index = str(data.get("imageIndex") or self._image_index)
        self._guest_login = str(data.get("guestLogin") or "auto")
        self._rollback_manifest = str(data.get("rollbackManifest") or "")

        if prev in (ST_PROVISIONING, ST_VALIDATING) and self._operation_id:
            self._attach_worker(self._operation_id)
        elif prev == ST_DONE:
            self._set_state(ST_DONE)
            self._run_post_validation()
        elif prev in (ST_FAILED, ST_CANCELLED):
            self._set_state(prev)
            self._checkpoint_label.setText(
                "Instalação anterior interrompida. Retome ou descarte o progresso."
            )
        else:
            return False
        return True

    def _update_summary(self) -> None:
        parts = []
        if self._iso:
            parts.append(f"ISO: {Path(self._iso).name}")
        parts.append(f"Gr\u00e1ficos: {self._graphics}")
        if self._image_index:
            parts.append(f"\u00cdndice: {self._image_index}")
        parts.append("Login Windows: autom\u00e1tico" if self._guest_login == "auto"
                     else "Login Windows: exigir senha")
        self._summary.setText(" | ".join(parts))

    def _update_elapsed(self) -> None:
        if self._elapsed_start > 0:
            secs = int(time.monotonic() - self._elapsed_start)
            self._elapsed_label.setText(f"{secs // 60:02d}:{secs % 60:02d}")

    def _add_log(self, text: str) -> None:
        cursor = self._log.textCursor()
        cursor.movePosition(QTextCursor.MoveOperation.End)
        cursor.insertText(text + "\n")
        scroll = self._log.verticalScrollBar()
        if scroll:
            scroll.setValue(scroll.maximum())

    def _append_logs(self, entries: list[str]) -> None:
        if not entries:
            return
        cursor = self._log.textCursor()
        cursor.movePosition(QTextCursor.MoveOperation.End)
        for entry in entries:
            cursor.insertText(entry + "\n")
        scroll = self._log.verticalScrollBar()
        if scroll:
            scroll.setValue(scroll.maximum())

    # ── Plan ──

    def _on_start_clicked(self) -> None:
        if not self._iso:
            QMessageBox.warning(self, "ISO ausente", "Selecione um ISO do Windows primeiro.")
            return
        self._set_state(ST_PLANNING)
        self._checkpoint_label.setText("Gerando plano de instala\u00e7\u00e3o\u2026")
        self._progress_bar.setRange(0, 0)
        self._add_log("Gerando plano de instala\u00e7\u00e3o\u2026")

        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_plan_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, [
            "windows-vm", "provision", "plan",
            "--iso", self._iso,
            "--image-index", self._image_index,
            "--graphics", self._graphics,
            "--guest-login", self._guest_login,
            "--json",
        ], timeout_ms=30_000)

    def _on_plan_result(self, plan: object | None, exit_code: int) -> None:
        self._async_proc = None
        if exit_code != 0 or plan is None:
            self._set_state(ST_FAILED)
            self._checkpoint_label.setText("Falha ao gerar plano")
            return
        if not isinstance(plan, dict):
            self._set_state(ST_FAILED)
            self._checkpoint_label.setText("Plano inv\u00e1lido")
            return

        blockers = plan.get("blockers", [])
        warnings = plan.get("warnings", [])
        destructive_ops = plan.get("destructiveOps", [])
        self._plan_id = plan.get("id", "")
        self._confirm_token = plan.get("confirmToken", "")
        self._add_log(f"Plano: {self._plan_id}")
        for w in warnings:
            self._add_log(f"  \u26a0 {w}")
        for b in blockers:
            self._add_log(f"  \U0001f534 {b}")
        for d in destructive_ops:
            self._add_log(f"  \U0001f527 {d}")

        if blockers:
            self._set_state(ST_FAILED)
            self._checkpoint_label.setText("Bloqueios impedem instala\u00e7\u00e3o")
            QMessageBox.critical(self, "Bloqueios",
                                 "O plano tem bloqueios:\n\n" +
                                 "\n".join(f"\u2022 {b}" for b in blockers))
            return

        confirm_parts = ["Plano gerado com sucesso."]
        if warnings:
            confirm_parts.append("\n\nAvisos:\n" + "\n".join(f"\u2022 {w}" for w in warnings))
        if destructive_ops:
            confirm_parts.append("\n\nOpera\u00e7\u00f5es destrutivas:\n" + "\n".join(f"\u2022 {d}" for d in destructive_ops))
        confirm_parts.append("\n\nDeseja iniciar o provisionamento?")
        msg = "".join(confirm_parts)
        reply = QMessageBox.question(self, "Confirmar", msg,
                                     QMessageBox.Yes | QMessageBox.No)
        if reply != QMessageBox.Yes:
            self._set_state(ST_CANCELLED)
            self._checkpoint_label.setText("Cancelado pelo usu\u00e1rio")
            return

        self._checkpoint_label.setText("Iniciando provisionamento\u2026")
        self._start_provision()

    def _start_provision(self) -> None:
        if not self._plan_id or not self._confirm_token:
            self._set_state(ST_FAILED)
            return
        self._start_worker()

    # ── Worker ──

    def _start_worker(self) -> None:
        if self._worker and self._worker.isRunning():
            return
        self._worker = ProvisionWorker(self._root, self._plan_id, self._confirm_token, self)
        self._worker.started.connect(self._on_worker_started)
        self._worker.progress_updated.connect(self._on_worker_progress)
        self._worker.completed.connect(self._on_worker_completed)
        self._worker.failed.connect(self._on_worker_failed)
        self._worker.start()

    def _attach_worker(self, operation_id: str) -> None:
        if self._worker and self._worker.isRunning():
            return
        self._worker = ProvisionWorker(self._root, "", "", self)
        self._worker.configure_attach(operation_id)
        self._worker.started.connect(self._on_worker_started)
        self._worker.progress_updated.connect(self._on_worker_progress)
        self._worker.completed.connect(self._on_worker_completed)
        self._worker.failed.connect(self._on_worker_failed)
        self._add_log(f"Reconectando \u00e0 opera\u00e7\u00e3o {operation_id}\u2026")
        self._worker.start()

    def _on_worker_started(self, op_id: str) -> None:
        self._operation_id = op_id
        self._set_state(ST_PROVISIONING)
        self._elapsed_start = time.monotonic()
        self._elapsed_timer.start()
        self._progress_bar.setRange(0, 100)
        self._add_log(f"Opera\u00e7\u00e3o: {op_id}")
        self._save_state()

    def _on_worker_progress(self, checkpoint: str, progress: int,
                           state: str, op_id: str, new_logs: list[str]) -> None:
        self._progress_bar.setValue(progress)
        if checkpoint:
            self._checkpoint_label.setText(checkpoint)
        self._append_logs(new_logs)
        self._save_state()

    def _on_worker_completed(self, op_id: str) -> None:
        self._add_log("Provisionamento conclu\u00eddo!")
        self._set_state(ST_VALIDATING)
        self._checkpoint_label.setText("Validando disco, snapshot e boot\u2026")
        self._progress_bar.setRange(0, 0)
        self._run_post_validation()

    def _on_worker_failed(self, reason: str) -> None:
        self._elapsed_timer.stop()
        self._set_state(ST_FAILED)
        # LUX-022: rótulo em linguagem de produto; o motivo cru fica no log.
        self._checkpoint_label.setText(friendly_provision_failure(reason))
        self._progress_bar.setRange(0, 100)
        self._progress_bar.setValue(0)
        self._add_log(f"FALHA: {reason}")
        self._save_state()

    # ── Validation ──

    def _run_post_validation(self) -> None:
        issue = self._operation_resume_issue(self._operation_id)
        if issue:
            self._quarantine_orphaned_state(issue)
            return
        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_validation_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, [
            "windows-vm", "provision", "status",
            "--operation-id", self._operation_id,
            "--json",
        ], timeout_ms=VALIDATE_TIMEOUT_MS)

    def _on_validation_result(self, data: object | None, exit_code: int) -> None:
        stderr = self._async_proc.stderr.strip() if self._async_proc else ""
        self._async_proc = None
        if exit_code != 0 or not isinstance(data, dict):
            if "operation not found" in stderr.casefold():
                self._quarantine_orphaned_state("operação não encontrada durante a validação")
                return
            self._set_state(ST_FAILED)
            detail = stderr.splitlines()[-1].strip() if stderr else "resposta inválida do backend"
            self._checkpoint_label.setText(f"Validação falhou: {detail[:160]}")
            self._add_log(f"Falha ao obter status do provisionamento: {detail}")
            self._progress_bar.setRange(0, 100)
            self._save_state()
            return

        self._snapshot_ok = data.get("snapshotExists", False)
        self._provision_snapshot = str(data.get("snapshotPath") or "")
        vm_dir = str(data.get("vmDir") or "")
        self._qga_socket = str(Path(vm_dir) / "qga.sock") if vm_dir else ""
        self._vm_running = data.get("qemuRunning", False) or data.get("libvirtRunning", False)
        # Missing key means an older provision backend; preserve compatibility.
        self._adopted_ok = bool(data.get("adoptedDiskExists", True))

        issues: list[str] = []

        if not self._snapshot_ok:
            issues.append("snapshot")
            self._add_log("Snapshot de restaura\u00e7\u00e3o ausente")

        if not self._vm_running and self._snapshot_ok and not self._adopted_ok:
            self._run_finalize_async(issues)
        else:
            self._fetch_boot_status_async(issues)

    def _run_finalize_async(self, issues: list[str]) -> None:
        self._checkpoint_label.setText("Finalizando imagem para uso permanente\u2026")
        self._add_log("Achatando snapshot e adotando VM no PhaseZero\u2026")
        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(
            lambda parsed, code: self._on_finalize_result(parsed, code, issues))
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, [
            "windows-vm", "provision", "finalize",
            "--operation-id", self._operation_id,
            "--json",
        ], timeout_ms=FINALIZE_TIMEOUT_MS)

    def _on_finalize_result(self, data: object | None, exit_code: int,
                            issues: list[str]) -> None:
        self._async_proc = None
        if exit_code == 0 and isinstance(data, dict) and data.get("success") is True:
            self._adopted_ok = True
            self._add_log(f"Imagem adotada: {data.get('adoptedDisk', '')}")
        else:
            issues.append("finalize")
            self._add_log("Falha ao finalizar/adotar imagem")
        self._fetch_boot_status_async(issues)

    def _fetch_boot_status_async(self, issues: list[str]) -> None:
        bridge = admin_bridge()
        if not bridge:
            self._add_log("Boot status indispon\u00edvel (sem admin bridge)")
            issues.append("boot")
            self._finish_validation(issues)
            return

        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(
            lambda parsed, code: self._on_boot_status_result(parsed, code, issues))
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(bridge, [pz, "windows-vm", "boot", "status", "--json"],
                             timeout_ms=BOOT_STATUS_TIMEOUT_MS)

    def _on_boot_status_result(self, data: object | None, exit_code: int,
                               issues: list[str]) -> None:
        self._async_proc = None
        if exit_code != 0 or not isinstance(data, dict):
            self._add_log("Boot status indispon\u00edvel")
            issues.append("boot")
        else:
            self._boot_ready = data.get("bootReady", False)
            self._one_shot_ready = data.get("oneShotReady", False)
            if self._boot_ready:
                self._add_log("Boot OK" + (" (one-shot)" if self._one_shot_ready else ""))
            else:
                self._add_log(f"Boot incompleto: bootReady={self._boot_ready}")
                issues.append("boot")
        if self._vm_running and self._qga_socket and self._provision_snapshot:
            self._apply_guest_login_async(issues)
        else:
            issues.append("guest_login")
            self._add_log("Login Windows ainda não verificado: VM/QGA indisponível")
            if self._recovery_requested:
                issues.append("recovery")
                self._add_log("PZ-Recovery ainda não verificado")
            self._finish_validation(issues)

    def _apply_guest_login_async(self, issues: list[str]) -> None:
        password = ""
        args = [
            "windows-vm", "guest-login", "apply",
            "--mode", self._guest_login,
            "--socket", self._qga_socket,
            "--backup-proof", self._provision_snapshot,
            "--json",
        ]
        if self._guest_login == "password":
            password, ok = QInputDialog.getText(
                self, "Senha do Windows",
                "Defina a senha da conta Windows. Ela não será salva no host:",
                QLineEdit.EchoMode.Password,
            )
            if not ok or not password:
                issues.append("guest_login")
                self._add_log("Política de senha não aplicada: senha não informada")
                self._finish_validation(issues)
                return
            args.append("--password-stdin")
        self._checkpoint_label.setText("Aplicando política de login do Windows…")
        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(
            lambda parsed, code: self._on_guest_login_result(parsed, code, issues))
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, args, timeout_ms=90_000,
                             stdin_data=(password + "\n") if password else "")
        password = ""

    def _on_guest_login_result(self, data: object | None, exit_code: int,
                               issues: list[str]) -> None:
        self._async_proc = None
        if exit_code == 0 and isinstance(data, dict) and data.get("guestLoginVerified") is True:
            self._guest_login_applied = True
            self._add_log(f"Login Windows configurado: {self._guest_login}")
        else:
            issues.append("guest_login")
            self._add_log("Falha ao aplicar/verificar política de login Windows")
        if self._recovery_requested and self._guest_login_applied:
            self._apply_recovery_async(issues)
        else:
            self._finish_validation(issues)

    def _apply_recovery_async(self, issues: list[str]) -> None:
        dialog = RecoveryPasswordDialog(self, allow_remote=not self._recovery_local_only)
        if dialog.exec() != QDialog.Accepted:
            issues.append("recovery")
            self._add_log("Recovery não configurado: senha não informada")
            dialog.deleteLater()
            self._finish_validation(issues)
            return
        password, allow_remote = dialog.take_credentials()
        dialog.deleteLater()
        self._recovery_local_only = not allow_remote
        args = ["windows-vm", "guest-login", "recovery", "apply", "--password-stdin",
                "--local-only" if self._recovery_local_only else "--allow-remote",
                "--socket", self._qga_socket,
                "--backup-proof", self._provision_snapshot, "--json"]
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(
            lambda parsed, code: self._on_recovery_result(parsed, code, issues))
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(str(self._root / "linux" / "pz"), args, timeout_ms=90_000,
                             stdin_data=password + "\n")
        password = ""

    def _on_recovery_result(self, data: object | None, exit_code: int,
                            issues: list[str]) -> None:
        self._async_proc = None
        verified = isinstance(data, dict) and data.get("recoveryConfigured") is True \
            and data.get("recoveryEnabled") is True \
            and data.get("recoveryAdministrator") is True \
            and data.get("qgaServiceHealthy") is True \
            and data.get("recoveryLocalOnly") is self._recovery_local_only
        if exit_code != 0 or not verified:
            issues.append("recovery")
            self._add_log("Administrador de recuperação não verificado")
        else:
            policy = "somente local" if self._recovery_local_only else "local e RDP"
            self._add_log(f"PZ-Recovery configurado: {policy}")
        self._finish_validation(issues)

    def _finish_validation(self, issues: list[str]) -> None:
        if self._vm_running:
            issues.append("vm_running")
            self._add_log("VM ainda ativa \u2014 desligue antes do reboot")

        if issues:
            self._set_state(ST_DONE)
            self._shutdown_btn.setVisible("vm_running" in issues)
            self._repair_btn.setVisible("boot" in issues)
            recovery_degraded = "guest_login" in issues or "recovery" in issues
            self._qga_repair_btn.setVisible(recovery_degraded and not self._vm_running)
            self._rollback_btn.setVisible(bool(self._rollback_manifest) and not self._vm_running)
            if "snapshot" in issues:
                self._checkpoint_label.setText("Conclu\u00eddo \u2014 snapshot ausente")
            elif "finalize" in issues:
                self._checkpoint_label.setText("Conclu\u00eddo \u2014 ado\u00e7\u00e3o da imagem falhou")
            elif self._vm_running:
                self._checkpoint_label.setText("Conclu\u00eddo \u2014 VM ativa, desligue para reboot")
            else:
                self._checkpoint_label.setText("Conclu\u00eddo \u2014 reparo necess\u00e1rio")
        else:
            self._set_state(ST_DONE)
            self._checkpoint_label.setText("Tudo pronto!")
            self._reboot_btn.setEnabled(self._one_shot_ready)
            self._progress_bar.setValue(100)

        self._progress_bar.setRange(0, 100)
        self._save_state()

    # ── Actions (all async via AsyncProc) ──

    def _on_cancel(self) -> None:
        if self._worker and self._worker.isRunning():
            self._worker.abort()
        if self._operation_id:
            pz = str(self._root / "linux" / "pz")
            self._async_proc = AsyncProc(self)
            self._async_proc.finished.connect(self._on_cancel_result)
            self._async_proc.errorOccurred.connect(self._on_async_error)
            self._async_proc.run(pz, [
                "windows-vm", "provision", "cancel",
                "--operation-id", self._operation_id,
                "--json",
            ], timeout_ms=CANCEL_TIMEOUT_MS)
        else:
            self._finish_cancel()

    def _on_cancel_result(self, data: object | None, exit_code: int) -> None:
        self._async_proc = None
        ok = exit_code == 0 and isinstance(data, dict) and data.get("success") is True
        if not ok:
            err = ""
            if isinstance(data, dict):
                err = str(data.get("error") or "")
            self._set_state(ST_FAILED)
            self._checkpoint_label.setText(f"Cancelamento falhou: {err or 'sem confirma\u00e7\u00e3o JSON'}")
            self._add_log(f"FALHA no cancelamento: {err or 'sem confirma\u00e7\u00e3o JSON'}")
            self._save_state()
            self._rollback_btn.setVisible(True)
            return
        self._finish_cancel()

    def _finish_cancel(self) -> None:
        self._elapsed_timer.stop()
        self._set_state(ST_CANCELLED)
        self._checkpoint_label.setText("Cancelado")
        self._progress_bar.setRange(0, 100)
        self._save_state()

    def _on_retry(self) -> None:
        issue = self._operation_resume_issue(self._operation_id)
        if issue:
            self._quarantine_orphaned_state(issue)
            return
        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_retry_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, [
            "windows-vm", "provision", "resume",
            "--operation-id", self._operation_id,
        ], timeout_ms=CANCEL_TIMEOUT_MS)

    def _on_retry_result(self, _data: object | None, exit_code: int) -> None:
        self._async_proc = None
        if exit_code == 0:
            self._attach_worker(self._operation_id)
        else:
            self._set_state(ST_FAILED)
            self._checkpoint_label.setText("Retomada falhou")
            self._add_log("Retomada falhou \u2014 descarte e recomece")

    def _on_discard(self) -> None:
        if self._operation_id and self._operation_resume_issue(self._operation_id):
            self._quarantine_orphaned_state("operação ausente durante o descarte")
            return
        reply = QMessageBox.question(
            self, "Descartar",
            "Remove staging e libera recursos.\n"
            "O progresso ser\u00e1 perdido.",
            QMessageBox.Yes | QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return
        if self._operation_id:
            pz = str(self._root / "linux" / "pz")
            self._async_proc = AsyncProc(self)
            self._async_proc.finished.connect(self._on_discard_result)
            self._async_proc.errorOccurred.connect(self._on_async_error)
            self._async_proc.run(pz, [
                "windows-vm", "provision", "cancel",
                "--operation-id", self._operation_id,
                "--remove-staging",
                "--json",
            ], timeout_ms=CANCEL_TIMEOUT_MS)
        else:
            self._finish_discard()

    def _on_discard_result(self, data: object | None, exit_code: int) -> None:
        self._async_proc = None
        ok = (exit_code == 0 and isinstance(data, dict)
              and data.get("success") is True
              and data.get("removalSucceeded") is True)
        if ok:
            self._finish_discard()
            return
        err = ""
        if isinstance(data, dict):
            err = str(data.get("error") or "")
        # Staging/window/player.json are kept: user can retry the discard.
        self._set_state(ST_FAILED)
        self._checkpoint_label.setText(f"Descarte falhou: {err or 'staging n\u00e3o removido'}")
        self._add_log(f"FALHA no descarte: {err or 'sem confirma\u00e7\u00e3o JSON'}")
        self._save_state()

    def _finish_discard(self) -> None:
        self._discarding = True
        self.close()

    def _on_repair_boot(self) -> None:
        bridge = admin_bridge()
        if not bridge:
            QMessageBox.warning(self, "Eleva\u00e7\u00e3o necess\u00e1ria",
                                "Instale o admin bridge:\nlinux/pz ai setup admin")
            return
        pz = str(self._root / "linux" / "pz")
        self._add_log("Reparando boot (elevado)\u2026")
        self._progress_bar.setRange(0, 0)
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_repair_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(bridge, [pz, "windows-vm", "boot", "install"],
                             timeout_ms=30_000)

    def _on_repair_result(self, _data: object | None, exit_code: int) -> None:
        self._async_proc = None
        self._progress_bar.setRange(0, 100)
        if exit_code == 0:
            self._add_log("Reparo conclu\u00eddo")
            self._run_post_validation()
        else:
            self._add_log("Reparo falhou")
            self._checkpoint_label.setText("Reparo falhou")

    def _on_repair_qga(self) -> None:
        if self._vm_running:
            QMessageBox.warning(
                self, "VM ativa",
                "Desligue o Windows completamente antes do reparo offline."
            )
            return
        reply = QMessageBox.question(
            self, "Reparo offline seguro",
            "PhaseZero verificará o qcow2, criará backup de disco/OVMF/TPM e "
            "injetará reparo one-shot do QGA. Nenhuma senha será armazenada.\n\nContinuar?",
            QMessageBox.Yes | QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return
        self._add_log("Criando rollback e preparando reparo offline do QGA…")
        self._checkpoint_label.setText("Reparando agente com VM desligada…")
        self._progress_bar.setRange(0, 0)
        self._qga_repair_btn.setEnabled(False)
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_repair_qga_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(
            str(self._root / "linux" / "pz"),
            ["windows-vm", "guest-login", "repair-qga", "--json"],
            timeout_ms=11 * 60 * 1000,
        )

    def _on_repair_qga_result(self, data: object | None, exit_code: int) -> None:
        self._async_proc = None
        self._progress_bar.setRange(0, 100)
        self._qga_repair_btn.setEnabled(True)
        if exit_code == 0 and isinstance(data, dict) and data.get("state") == "pending-guest-boot":
            self._rollback_manifest = str(data.get("rollbackManifest") or "")
            self._add_log("Reparo one-shot preparado; rollback verificado disponível")
            self._checkpoint_label.setText(
                "Reparo preparado — inicie o Windows e retome para validar e criar PZ-Recovery"
            )
            QMessageBox.information(
                self, "Próxima etapa",
                "Inicie a VM uma vez. O Windows reparará o QGA como SYSTEM. "
                "Depois retome este player; a senha de PZ-Recovery será solicitada novamente."
            )
            self._save_state()
            return
        self._add_log("Reparo offline recusado ou revertido automaticamente")
        self._checkpoint_label.setText("Reparo offline falhou — disco restaurado quando possível")

    def _on_rollback_qga(self) -> None:
        if self._vm_running or not self._rollback_manifest:
            QMessageBox.warning(self, "Rollback indisponível", "Desligue a VM e selecione um reparo preparado.")
            return
        reply = QMessageBox.question(
            self, "Reverter reparo offline",
            "Restaurar qcow2, OVMF e TPM usando o backup verificado?",
            QMessageBox.Yes | QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return
        self._progress_bar.setRange(0, 0)
        self._rollback_btn.setEnabled(False)
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_rollback_qga_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(
            str(self._root / "linux" / "pz"),
            ["windows-vm", "guest-login", "rollback", "--manifest",
             self._rollback_manifest, "--json"],
            timeout_ms=11 * 60 * 1000,
        )

    def _on_rollback_qga_result(self, data: object | None, exit_code: int) -> None:
        self._async_proc = None
        self._progress_bar.setRange(0, 100)
        self._rollback_btn.setEnabled(True)
        if exit_code == 0 and isinstance(data, dict) and data.get("success") is True:
            self._rollback_manifest = ""
            self._rollback_btn.setVisible(False)
            self._add_log("Rollback offline concluído e imagem verificada")
            self._checkpoint_label.setText("Rollback concluído — inicie a VM para validar")
            self._save_state()
            return
        self._add_log("Rollback offline falhou; manifesto preservado para nova tentativa")
        self._checkpoint_label.setText("Rollback falhou — nenhuma confirmação de restauração")

    def _on_shutdown_vm(self) -> None:
        self._add_log("Desligando VM via QGA\u2026")
        self._progress_bar.setRange(0, 0)
        pz = str(self._root / "linux" / "pz")
        self._async_proc = AsyncProc(self)
        self._async_proc.finished.connect(self._on_shutdown_result)
        self._async_proc.errorOccurred.connect(self._on_async_error)
        self._async_proc.run(pz, [
            "windows-vm", "provision", "shutdown",
            "--operation-id", self._operation_id,
            "--json",
        ], timeout_ms=SHUTDOWN_TIMEOUT_MS)

    def _on_shutdown_result(self, data: object | None, exit_code: int) -> None:
        self._async_proc = None
        self._progress_bar.setRange(0, 100)
        ok = exit_code == 0 and isinstance(data, dict) and data.get("success") is True
        if ok:
            self._add_log("VM desligada")
            self._vm_running = False
            self._run_post_validation()
        else:
            err = ""
            if isinstance(data, dict):
                err = str(data.get("error") or "")
            self._add_log(f"Desligamento falhou ou expirou ({err or 'sem confirma\u00e7\u00e3o JSON'})")
            self._checkpoint_label.setText("Desligamento falhou")

    def _on_async_error(self, message: str) -> None:
        self._add_log(f"Erro ass\u00edncrono: {message}")

    def _on_reboot(self) -> None:
        if self._vm_running:
            QMessageBox.warning(self, "VM ativa",
                                "QEMU ainda est\u00e1 rodando.\n"
                                "Desligue a VM primeiro.")
            return

        if not self._one_shot_ready:
            QMessageBox.warning(self, "Boot n\u00e3o suporta one-shot",
                                "Este loader n\u00e3o garante pr\u00f3ximo boot no Windows VM.\n"
                                "Use o menu GRUB manualmente.")
            return

        reply = QMessageBox.question(
            self, "Reiniciar no Windows",
            "O computador ser\u00e1 reiniciado e inicializar\u00e1 no Windows VM.",
            QMessageBox.Yes | QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return
        bridge = admin_bridge()
        if not bridge:
            QMessageBox.warning(self, "Eleva\u00e7\u00e3o necess\u00e1ria",
                                "Instale o admin bridge:\nlinux/pz ai setup admin")
            return
        pz = str(self._root / "linux" / "pz")
        self._add_log("Reiniciando\u2026")
        self._progress_bar.setRange(0, 0)
        self._reboot_btn.setEnabled(False)
        proc = QProcess(self)
        proc.setProgram(bridge)
        proc.setArguments([pz, "windows-vm", "boot", "next-reboot"])
        proc.started.connect(self._on_reboot_started)
        proc.errorOccurred.connect(self._on_reboot_error)
        proc.finished.connect(self._on_reboot_finished)
        self._reboot_proc = proc
        proc.start()

    def _on_reboot_started(self) -> None:
        self._add_log("Bridge admin aceitou o pedido de rein\u00edcio\u2026")

    def _on_reboot_error(self, error: QProcess.ProcessError) -> None:
        self._restore_reboot_ui()
        err_msg = self._reboot_proc.errorString() if self._reboot_proc else str(error)
        self._add_log(f"Falha ao iniciar rein\u00edcio: {err_msg}")
        self._checkpoint_label.setText("Rein\u00edcio falhou")
        self._reboot_proc = None

    def _on_reboot_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        self._restore_reboot_ui()
        if exit_code == 0 and exit_status == QProcess.ExitStatus.NormalExit:
            self._add_log("Rein\u00edcio aceito \u2014 o sistema ser\u00e1 reiniciado no Windows VM")
            self._checkpoint_label.setText("Rein\u00edcio agendado")
        else:
            self._add_log(f"Rein\u00edcio falhou (exit {exit_code})")
            self._checkpoint_label.setText("Rein\u00edcio falhou")
        self._reboot_proc = None

    def _restore_reboot_ui(self) -> None:
        self._progress_bar.setRange(0, 100)
        self._reboot_btn.setEnabled(self._one_shot_ready)

    def closeEvent(self, event: QCloseEvent) -> None:
        if self._closing:
            event.accept()
            return
        if self._async_proc:
            self._async_proc.abort()
        if self._worker and self._worker.isRunning():
            self._worker.abort()
            # Bounded wait: the worker polls in 100ms slices and exits quickly,
            # but if it is still alive after the limit it is detached (kept
            # referenced) so its QThread is never destroyed while running.
            if not self._worker.wait(2500):
                worker = self._worker
                worker.setParent(None)
                _DETACHED_WORKERS.append(worker)
        if self._discarding:
            PLAYER_STATE_PATH.unlink(missing_ok=True)
        else:
            self._save_state()
        ProvisionPlayerWindow._instance = None
        self._closing = True
        event.accept()
