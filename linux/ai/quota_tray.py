"""Qt process boundary for blocking quota adapters; no network on the GUI thread."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from linux.ai.quota_meter import claude_cache_identity


class TrayCollector(QObject):
    ready = Signal(list)
    failed = Signal(str)

    def __init__(self, env: dict[str, str], parent=None, *, command=None, timeout_ms=40000):
        super().__init__(parent)
        self.env = dict(env)
        self.command = command or [sys.executable, str(Path(__file__).with_name("quota_meter.py")),
                                   "status", "--json"]
        self.process = QProcess(self)
        process_env = QProcessEnvironment()
        for key, value in self.env.items():
            process_env.insert(key, value)
        self.process.setProcessEnvironment(process_env)
        self.process.finished.connect(self._finished)
        self.process.errorOccurred.connect(self._error)
        self.timer = QTimer(self)
        self.timer.setSingleShot(True)
        self.timer.setInterval(timeout_ms)
        self.timer.timeout.connect(self._timeout)
        self._closed = False
        self._discard = False
        self._identity = ""

    def refresh(self) -> bool:
        if self._closed or self.process.state() != QProcess.NotRunning:
            return False
        self._identity = claude_cache_identity(self.env, "")
        self._discard = False
        self.process.start(self.command[0], self.command[1:])
        self.timer.start()
        return True

    def _timeout(self) -> None:
        self._discard = True
        self.process.kill()
        self.failed.emit("Coleta excedeu prazo; use Atualizar para tentar novamente")

    def _error(self, error) -> None:
        if error == QProcess.FailedToStart and not self._closed:
            self.timer.stop()
            self.failed.emit("Não foi possível iniciar coleta; use Atualizar")

    def _finished(self, code, _status) -> None:
        self.timer.stop()
        raw = bytes(self.process.readAllStandardOutput())
        self.process.readAllStandardError()  # never forward adapter logs/credentials
        if self._closed or self._discard:
            return
        if self._identity != claude_cache_identity(self.env, ""):
            self.failed.emit("Conta alterada; aguardando nova observação")
            QTimer.singleShot(0, self.refresh)
            return
        try:
            payload = json.loads(raw) if code == 0 else None
            items = payload["meters"]
            if not isinstance(items, list) or not all(isinstance(item, dict) and "id" in item for item in items):
                raise ValueError("invalid meters")
        except (ValueError, KeyError, TypeError):
            self.failed.emit("Coleta indisponível; use Atualizar")
            return
        self.ready.emit(items)

    def close(self) -> None:
        self._closed = True
        self.timer.stop()
        if self.process.state() != QProcess.NotRunning:
            self.process.kill()
            self.process.waitForFinished(1000)
