from __future__ import annotations

import json
import os
import re
import secrets
import shlex
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from .models import ActionSpec, OperationResult
from .operation_ledger import OperationLedger
from .platform import (
    admin_bridge,
    configure_process_group,
    secure_directory,
    secure_file,
    state_dir,
    terminate_process_group,
)
from .result_parser import parse_json_output

CAPTURE_LIMIT = 8 * 1024 * 1024


# LUX-022: progress markers the backends emit on purpose.
PROGRESS_RE = re.compile(
    r"PZ_PROGRESS=(\d{1,3})\b"
    r"|^\s*Progress:\s*(\d{1,3})%"
    r"|\]\s*(\d{1,3})%\s*\|",
    re.MULTILINE,
)
READ_TIMEOUT_MS = 10 * 60 * 1000

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def build_program(
    root: Path,
    action: ActionSpec,
    *,
    preview: bool,
    value: str = "",
    values: dict[str, str] | None = None,
) -> tuple[str, list[str]]:
    pz = str(root / "linux" / "pz")
    args = action.resolved_args(value, preview=preview, values=values)
    if any(token.startswith("{") and token.endswith("}") for token in args):
        raise ValueError(f"input required for {action.id}")
    if action.elevated and not preview:
        bridge = admin_bridge()
        if not bridge:
            raise RuntimeError("elevação indisponível; execute `linux/pz ai setup admin`")
        return bridge, [pz, *args]
    return pz, args


class CommandRunner(QObject):
    output = Signal(str, bool)
    progress = Signal(int)
    started = Signal(str)
    completed = Signal(object)
    failed_to_start = Signal(str)

    def __init__(
        self, root: Path, parent: QObject | None = None, *, timeout_ms: int = 30 * 60 * 1000
    ) -> None:
        super().__init__(parent)
        self.root = root
        self.process: QProcess | None = None
        self.action: ActionSpec | None = None
        self.preview = False
        self.command: list[str] = []
        self.stdout_parts: list[str] = []
        self.stderr_parts: list[str] = []
        self._stdout_size = 0
        self._stderr_size = 0
        self.started_at = ""
        self.operation_id = ""
        self._cancel_requested = False
        self._safe_cancel_supported = False
        self._safe_cancel_pending = False
        self._cancel_file: Path | None = None
        self.cancel_error = ""
        self.ledger = OperationLedger()
        try:
            self.ledger.recover_interrupted()
        except OSError:
            pass
        self.timeout_ms = timeout_ms
        self.current_timeout_ms = timeout_ms
        self.timeout_timer = QTimer(self)
        self.timeout_timer.setSingleShot(True)
        self.timeout_timer.timeout.connect(self._timeout)

    @property
    def running(self) -> bool:
        return self.process is not None and self.process.state() != QProcess.NotRunning

    @property
    def safe_cancel_pending(self) -> bool:
        return self._safe_cancel_pending

    @property
    def safe_cancel_supported(self) -> bool:
        return self._safe_cancel_supported

    def timeout_for(self, action: ActionSpec, *, preview: bool) -> int:
        """LUX-022: leituras e prévias não esperam 30 min para falhar."""
        if action.timeout_s:
            return action.timeout_s * 1000
        if preview or not action.mutable:
            return min(self.timeout_ms, READ_TIMEOUT_MS)
        return self.timeout_ms

    def start(
        self,
        action: ActionSpec,
        *,
        preview: bool = False,
        value: str = "",
        values: dict[str, str] | None = None,
    ) -> None:
        if self.running:
            raise RuntimeError("operation already running")
        program, args = build_program(self.root, action, preview=preview, value=value, values=values)
        # Read before anything echoes the command: this value goes to stdin and
        # must stay out of argv, out of self.command and out of the started
        # signal that renders the command to the user.
        stdin_data = ""
        if action.stdin_parameter and (not preview or action.stdin_on_preview):
            stdin_data = (values or {}).get(action.stdin_parameter, "")
        self.action = action
        self.preview = preview
        self._safe_cancel_supported = bool(
            not preview and action.mutable
            and action.args[:2] == ("capabilities", "apply")
        )
        self._safe_cancel_pending = False
        self._cancel_file = None
        self.cancel_error = ""
        if self._safe_cancel_supported:
            try:
                cancel_dir = secure_directory(state_dir() / "cancel-requests")
                self._cancel_file = cancel_dir / f"{secrets.token_hex(16)}.request"
                args.extend(("--cancel-file", str(self._cancel_file)))
            except OSError:
                self._safe_cancel_supported = False
        self.command = [program, *args]
        self.stdout_parts = []
        self.stderr_parts = []
        self._stdout_size = 0
        self._stderr_size = 0
        self.timed_out = False
        self.started_at = utc_now()
        self._cancel_requested = False
        try:
            self.operation_id = self.ledger.begin(action, preview=preview)
        except OSError:
            self.operation_id = ""
        process = QProcess(self)
        process.setWorkingDirectory(str(self.root))
        env = QProcessEnvironment.systemEnvironment()
        env.insert("PYTHONUNBUFFERED", "1")
        env.insert("PZ_UI", "native")
        admin_bin = str(self.root / "linux" / "ui_native" / "admin-bin")
        env.insert("PATH", admin_bin + os.pathsep + env.value("PATH"))
        process.setProcessEnvironment(env)
        configure_process_group(process)
        process.setProgram(program)
        process.setArguments(args)
        process.setProcessChannelMode(QProcess.SeparateChannels)
        process.readyReadStandardOutput.connect(self._stdout)
        process.readyReadStandardError.connect(self._stderr)
        process.errorOccurred.connect(self._error)
        process.finished.connect(self._finished)
        self.process = process
        display = shlex.join(self.command)
        self.started.emit(display)
        process.start()
        if stdin_data:
            # The receiving script reads one line and refuses an empty secret,
            # so terminate it and close the channel: without the EOF the child
            # blocks on read and the action hangs until the timeout.
            process.write((stdin_data + "\n").encode("utf-8"))
            process.closeWriteChannel()
        self.current_timeout_ms = self.timeout_for(action, preview=preview)
        self.timeout_timer.start(self.current_timeout_ms)
        try:
            self.ledger.update(status="previewing" if preview else "running")
        except OSError:
            pass

    def cancel(self) -> None:
        if not self.running or self.process is None:
            return
        process = self.process
        self.cancel_error = ""
        if self._safe_cancel_supported and self._cancel_file is not None:
            try:
                secure_file(self._cancel_file, "cancel\n")
                self._safe_cancel_pending = True
                self._cancel_requested = True
                try:
                    self.ledger.update(status="cancelling")
                except OSError:
                    pass
                return
            except OSError as exc:
                self.cancel_error = f"Não foi possível pedir cancelamento seguro: {exc}"
                return
        self._cancel_requested = True
        try:
            self.ledger.update(status="cancelling")
        except OSError:
            pass
        terminate_process_group(process)
        QTimer.singleShot(
            2000,
            lambda: process.kill() if process.state() != QProcess.NotRunning else None,
        )

    def shutdown(self, timeout_ms: int = 2500) -> None:
        """Stop the whole process group before the application exits."""
        process = self.process
        if process is None or process.state() == QProcess.NotRunning:
            return
        self.cancel()
        if process.waitForFinished(timeout_ms):
            return
        terminate_process_group(process, force=True)
        process.waitForFinished(1000)

    def _capture(self, text: str, *, stderr: bool) -> None:
        parts = self.stderr_parts if stderr else self.stdout_parts
        size_name = "_stderr_size" if stderr else "_stdout_size"
        current = getattr(self, size_name)
        if current >= CAPTURE_LIMIT:
            return
        remaining = CAPTURE_LIMIT - current
        encoded = text.encode("utf-8", errors="replace")
        if len(encoded) <= remaining:
            parts.append(text)
            setattr(self, size_name, current + len(encoded))
            return
        captured = encoded[:remaining].decode("utf-8", errors="ignore")
        parts.append(captured + "\n[saída truncada pelo limite da interface]\n")
        setattr(self, size_name, CAPTURE_LIMIT)

    def _decode(self, data: bytes) -> str:
        return bytes(data).decode("utf-8", errors="replace")

    def _stdout(self) -> None:
        if self.process is None:
            return
        text = self._decode(self.process.readAllStandardOutput().data())
        self._capture(text, stderr=False)
        self.output.emit(text, False)
        # LUX-022: só marcadores explícitos de progresso. "disco 95% usado"
        # não é progresso da operação.
        matches = PROGRESS_RE.findall(text)
        if matches:
            value = min(100, int(next(group for group in matches[-1] if group)))
            self.progress.emit(value)
            try:
                self.ledger.update(progress=value)
            except OSError:
                pass

    def _stderr(self) -> None:
        if self.process is None:
            return
        text = self._decode(self.process.readAllStandardError().data())
        self._capture(text, stderr=True)
        self.output.emit(text, True)

    def _error(self, error: QProcess.ProcessError) -> None:
        if error == QProcess.FailedToStart and self.process is not None:
            message = self.process.errorString()
            self._capture(message, stderr=True)
            self.failed_to_start.emit(message)
            self._finished(127, QProcess.CrashExit)

    def _timeout(self) -> None:
        if not self.running:
            return
        self.timed_out = True
        minutes = max(1, self.current_timeout_ms // 60000)
        message = f"tempo limite de {minutes} min atingido; operação interrompida\n"
        self._capture(message, stderr=True)
        self.output.emit(message, True)
        self.cancel()

    def _finished(self, code: int, _status: QProcess.ExitStatus) -> None:
        if self.action is None:
            return
        # QProcess may report completion before the final readyRead callback.
        self._stdout()
        self._stderr()
        self.timeout_timer.stop()
        action = self.action
        self.action = None
        stdout = "".join(self.stdout_parts)
        stderr = "".join(self.stderr_parts)
        parsed = parse_json_output(stdout)
        result = OperationResult(
            action_id=action.id,
            command=self.command,
            preview=self.preview,
            exit_code=code,
            started_at=self.started_at,
            finished_at=utc_now(),
            stdout=stdout,
            stderr=stderr,
            parsed=parsed,
            operation_id=self.operation_id,
            timed_out=self.timed_out,
        )
        try:
            private_state = secure_directory(state_dir())
            destination = secure_directory(private_state / "results")
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            safe_id = re.sub(r"[^a-zA-Z0-9_.-]", "-", action.id)
            result_path = destination / f"{stamp}-{safe_id}.json"
            payload = json.dumps(result.to_dict(), ensure_ascii=False, indent=2) + "\n"
            secure_file(result_path, payload)
            result.result_path = result_path
            retained = sorted(destination.glob("*.json"), reverse=True)
            for obsolete in retained[250:]:
                obsolete.unlink(missing_ok=True)
        except OSError as exc:
            result.stderr += f"\nfailed to persist result: {exc}\n"
        try:
            cancelled = bool(
                self._cancel_requested and (
                    code != 0
                    or isinstance(parsed, dict) and parsed.get("status") == "cancelled"
                )
            )
            self.ledger.finish(
                exit_code=code,
                result_path=result.result_path,
                cancelled=cancelled,
            )
        except OSError as exc:
            result.stderr += f"\nfailed to persist operation ledger: {exc}\n"
        self.operation_id = ""
        self._cancel_requested = False
        self._safe_cancel_pending = False
        self._safe_cancel_supported = False
        if self._cancel_file is not None:
            try:
                self._cancel_file.unlink(missing_ok=True)
            except OSError:
                pass
            self._cancel_file = None
        self.process = None
        self.completed.emit(result)
