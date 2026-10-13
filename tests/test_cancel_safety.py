"""LUX-002 — Esc e fechar nunca abortam; cancelar exige segunda decisão."""
from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from PySide6.QtCore import QProcess, Qt
from PySide6.QtGui import QCloseEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QMessageBox

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def window(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
        yield win
        process = win.runner.process
        if process is not None:
            process.kill()
            process.waitForFinished(2000)
        win.runner.process = None
        win.close()


def _fake_running(win):
    process = QProcess(win)
    process.start("sleep", ["30"])
    assert process.waitForStarted(3000)
    win.runner.process = process
    return process


def test_escape_in_main_window_does_not_cancel(window):
    process = _fake_running(window)
    QTest.keyClick(window, Qt.Key_Escape)
    window.cancel_or_clear()  # o atalho Esc chama isto
    assert process.state() != QProcess.NotRunning
    assert window.runner._cancel_requested is False


def test_escape_in_progress_dialog_hides_without_cancel(window):
    from linux.ui_native.widgets import ProgressDialog

    process = _fake_running(window)
    dialog = ProgressDialog("Instalar", "pz install", window)
    dialog.cancel_requested.connect(window.confirm_cancel)
    hidden = []
    dialog.hidden_while_running.connect(lambda: hidden.append(True))
    dialog.show()
    with patch.object(type(window), "_ask_cancel") as ask:
        dialog.reject()
        ask.assert_not_called()
    assert hidden == [True]
    assert not dialog.isVisible()
    assert process.state() != QProcess.NotRunning


def test_cancel_requires_confirmation(window):
    process = _fake_running(window)
    with patch.object(type(window), "_ask_cancel", return_value=False):
        window.confirm_cancel()
    assert window.runner._cancel_requested is False
    assert process.state() != QProcess.NotRunning
    with patch.object(type(window), "_ask_cancel", return_value=True):
        window.confirm_cancel()
    assert window.runner._cancel_requested is True


def test_capability_apply_cancel_requests_safe_boundary_without_killing_process_group(tmp_path):
    from linux.ui_native.command_runner import CommandRunner

    runner = CommandRunner(ROOT)
    process = SimpleNamespace(state=lambda: QProcess.Running, processId=lambda: 4321)
    runner.process = process
    runner._safe_cancel_supported = True
    runner._cancel_file = tmp_path / "cancel-requests" / "operation.request"
    with patch.object(runner.ledger, "update"), patch(
        "linux.ui_native.command_runner.terminate_process_group"
    ) as terminate:
        runner.cancel()
    terminate.assert_not_called()
    assert runner.safe_cancel_pending
    assert runner._cancel_file.is_file()


def test_runner_passes_cancel_request_file_to_capability_apply(qapp, tmp_path, monkeypatch):
    from linux.ui_native import command_runner as runner_module
    from linux.ui_native.command_runner import CommandRunner
    from linux.ui_native.models import ActionSpec

    class SignalStub:
        def connect(self, _callback):
            pass

    class FakeProcess:
        NotRunning = QProcess.NotRunning
        Running = QProcess.Running
        SeparateChannels = QProcess.SeparateChannels

        def __init__(self, _parent):
            self.readyReadStandardOutput = SignalStub()
            self.readyReadStandardError = SignalStub()
            self.errorOccurred = SignalStub()
            self.finished = SignalStub()
            self.args = []

        def __getattr__(self, _name):
            return lambda *_args: None

        def setArguments(self, args):
            self.args = list(args)

        def state(self):
            return self.Running

    monkeypatch.setattr(runner_module, "QProcess", FakeProcess)
    monkeypatch.setattr(
        runner_module, "build_program",
        lambda *_args, **_kwargs: ("linux/pz", ["capabilities", "apply", "--plan-id", "plan"]),
    )
    runner = CommandRunner(ROOT)
    monkeypatch.setattr(runner.ledger, "begin", lambda *_args, **_kwargs: "operation-id")
    monkeypatch.setattr(runner.ledger, "update", lambda **_kwargs: None)
    action = ActionSpec(
        id="capability.profile.development-web-js", category="Desenvolvimento",
        title="Preparar Web JS", description="", args=("capabilities", "apply"),
        icon="system-run", mutable=True,
    )
    runner.start(action)
    assert runner.safe_cancel_supported
    assert runner.process.args[-2] == "--cancel-file"
    assert runner.process.args[-1].endswith(".request")
    runner.timeout_timer.stop()


def test_close_requests_safe_cancel_but_keeps_window_open_until_step_finishes(window, tmp_path):
    process = _fake_running(window)
    window.runner._safe_cancel_supported = True
    window.runner._cancel_file = tmp_path / "cancel-requests" / "operation.request"
    event = QCloseEvent()
    with patch("linux.ui_native.main_window.QMessageBox.question", return_value=QMessageBox.Yes):
        window.closeEvent(event)
    assert not event.isAccepted()
    assert window.runner.safe_cancel_pending
    assert window.runner._cancel_file.is_file()
    assert process.state() != QProcess.NotRunning
