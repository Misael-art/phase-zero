from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from PySide6.QtCore import QObject, QTimer, QProcess, Qt
from PySide6.QtWidgets import QApplication, QDialog, QMessageBox

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")
sys.path.insert(0, str(ROOT))

from linux.ui_native import provision_player as pp_mod
from linux.ui_native.provision_player import (
    AsyncProc, ProvisionWorker, ProvisionPlayerWindow, recovery_password_strength,
    ST_IDLE, ST_DONE, ST_FAILED, ST_CANCELLED, ST_PROVISIONING, ST_VALIDATING,
)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(autouse=True)
def _isolated_state_path(tmp_path: Path) -> None:
    tmp_state = tmp_path / "windows-vm" / "player.json"
    tmp_operations = tmp_path / "operations"
    tmp_state.parent.mkdir(parents=True)
    tmp_operations.mkdir()
    orig = pp_mod.PLAYER_STATE_PATH
    orig_operations = pp_mod.OPERATIONS_STATE_DIR
    pp_mod.PLAYER_STATE_PATH = tmp_state
    pp_mod.OPERATIONS_STATE_DIR = tmp_operations
    yield
    _cleanup_player()
    pp_mod.PLAYER_STATE_PATH = orig
    pp_mod.OPERATIONS_STATE_DIR = orig_operations


def _cleanup_player():
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    windows = [
        widget for widget in QApplication.topLevelWidgets()
        if isinstance(widget, ProvisionPlayerWindow)
    ]
    if ProvisionPlayerWindow._instance is not None and ProvisionPlayerWindow._instance not in windows:
        windows.append(ProvisionPlayerWindow._instance)
    for win in windows:
        if win._worker and win._worker.isRunning():
            win._worker.abort()
            win._worker.wait(2000)
        if win._async_proc:
            win._async_proc.abort()
        win._closing = True
        win.close()
    ProvisionPlayerWindow._instance = None
    for _ in range(10):
        QApplication.processEvents()
        time.sleep(0.05)
    if PLAYER_STATE_PATH.exists():
        PLAYER_STATE_PATH.unlink()


def _write_operation(operation_id: str = "op-20260810-120000-1234",
                     state: str = "running") -> str:
    operation_dir = pp_mod.OPERATIONS_STATE_DIR / operation_id
    operation_dir.mkdir(parents=True, exist_ok=True)
    (operation_dir / "operation.json").write_text(json.dumps({
        "state": state,
        "checkpoint": "setup",
        "progress": 50,
    }))
    return operation_id


@pytest.fixture
def fake_pz(tmp_path: Path) -> Path:
    pz = tmp_path / "linux" / "pz"
    pz.parent.mkdir(parents=True)
    pz.write_text("#!/usr/bin/env bash\necho '{\"operationId\":\"op-test-001\",\"state\":\"running\"}'")
    pz.chmod(0o755)
    return tmp_path


@pytest.fixture
def fake_pz_with_status(tmp_path: Path) -> tuple[Path, Path]:
    pz = tmp_path / "linux" / "pz"
    pz.parent.mkdir(parents=True)
    fixture = tmp_path / "status_fixture.json"
    fixture.write_text(json.dumps({
        "state": "completed", "progress": 100,
        "checkpoint": "relaunch", "currentLabel": "test",
        "log": ["step1", "step2", "step3"],
        "vmDir": "/tmp/vm", "snapshotPath": "/tmp/snap.qcow2",
        "snapshotExists": True, "qemuPid": 0, "qemuRunning": False,
        "libvirtRunning": False,
    }))
    pz.write_text(f"""#!/usr/bin/env bash
case "$1" in
  windows-vm)
    case "$2" in
      provision)
        case "$3" in
          start) echo '{{"operationId":"op-test-001","state":"running"}}' ;;
          status) cat {fixture} ;;
          resume) exit 0 ;;
          cancel)
            if [ -n "$PZ_FAKE_CANCEL_FAIL" ]; then exit 1; fi
            if [ -n "$PZ_FAKE_CANCEL_NO_REMOVE" ]; then
              echo '{{"success":true,"cancelled":true,"removalRequested":true,"removalSucceeded":false,"preservedPath":"/tmp/vm","error":"staging removal failed","operationId":"op-test-001"}}'
              exit 1
            fi
            case " $* " in
              *" --remove-staging "*)
                echo '{{"success":true,"cancelled":true,"removalRequested":true,"removalSucceeded":true,"preservedPath":"","error":"","operationId":"op-test-001"}}' ;;
              *)
                echo '{{"success":true,"cancelled":true,"removalRequested":false,"removalSucceeded":false,"preservedPath":"","error":"","operationId":"op-test-001"}}' ;;
            esac ;;
          shutdown)
            if [ -n "$PZ_FAKE_SHUTDOWN_FAIL" ]; then
              echo '{{"success":false,"operationId":"op-test-001","waitedSeconds":0}}'
              exit 1
            fi
            echo '{{"success":true,"operationId":"op-test-001","waitedSeconds":2}}' ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
""")
    pz.chmod(0o755)
    return tmp_path, fixture


# ── AsyncProc tests ──

def test_async_proc_timeout_emits_once(qapp, tmp_path: Path) -> None:
    script = tmp_path / "sleep.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 10\n echo ok")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=200)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 5:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][1] == -1


def test_async_proc_failed_to_start_terminates(qapp) -> None:
    results: list[tuple[object | None, int]] = []
    errors: list[str] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))
    proc.errorOccurred.connect(lambda msg: errors.append(msg))

    proc.run("/nonexistent/binary", [], timeout_ms=500)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 3:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][1] == -2


def test_async_proc_stdout_stderr_preserved(qapp, tmp_path: Path) -> None:
    script = tmp_path / "echo.sh"
    script.write_text("#!/usr/bin/env bash\necho '{\"ok\":true}'\necho errmsg >&2")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=2000)
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 3:
        QApplication.processEvents()
        time.sleep(0.05)

    assert len(results) == 1
    assert results[0][0] == {"ok": True}


def test_async_proc_writes_secret_only_to_stdin(qapp, tmp_path: Path) -> None:
    script = tmp_path / "stdin.sh"
    script.write_text("#!/usr/bin/env bash\nIFS= read -r value\nprintf '{\"length\":%s}\\n' \"${#value}\"\n")
    script.chmod(0o755)
    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))
    proc.run(str(script), ["safe-argument"], timeout_ms=2000,
             stdin_data="not-persisted-secret\n")
    start = time.monotonic()
    while len(results) < 1 and time.monotonic() - start < 3:
        QApplication.processEvents()
        time.sleep(0.05)
    assert results == [({"length": 20}, 0)]


def test_async_proc_abort_prevents_emit(qapp, tmp_path: Path) -> None:
    script = tmp_path / "sleep.sh"
    script.write_text("#!/usr/bin/env bash\nsleep 10\necho ok")
    script.chmod(0o755)

    results: list[tuple[object | None, int]] = []
    proc = AsyncProc()
    proc.finished.connect(lambda data, code: results.append((data, code)))

    proc.run(str(script), [], timeout_ms=5000)
    proc.abort()
    QApplication.processEvents()
    time.sleep(0.1)
    QApplication.processEvents()

    assert len(results) == 0


# ── ProvisionWorker tests ──

def test_worker_attach_does_not_execute_start(fake_pz: Path) -> None:
    worker = ProvisionWorker(fake_pz, "plan-1", "tok-1")
    worker.configure_attach("op-existing-001")
    assert worker._mode == "attach"
    assert worker._operation_id == "op-existing-001"
    assert worker._plan_id == "plan-1"
    assert worker._confirm_token == "tok-1"


# ── Progress sequence tests ──

def test_progress_sequence_from_shell() -> None:
    script = ROOT / "linux" / "windows-vm" / "provision.sh"
    text = script.read_text(encoding="utf-8")
    m = re.search(r"CP_WEIGHTS=\(([^)]+)\)", text)
    assert m
    weights = [int(x) for x in m.group(1).split()]
    assert sum(weights) == 100

    checkpoints = ["validate", "assets", "answer-media", "disk", "setup",
                   "drivers", "tweaks", "verify", "snapshot", "relaunch"]
    start_seq = []
    end_seq = []
    for cp in checkpoints:
        s = 0
        e = 0
        for i, w in enumerate(weights):
            if checkpoints[i] == cp:
                e += w
                break
            s += w
            e += w
        start_seq.append(s)
        end_seq.append(e)

    assert start_seq == [0, 5, 15, 20, 50, 65, 75, 80, 85, 95]
    assert end_seq == [5, 15, 20, 50, 65, 75, 80, 85, 95, 100]


def test_progress_completed_is_100_from_shell() -> None:
    script = ROOT / "linux" / "windows-vm" / "provision.sh"
    text = script.read_text(encoding="utf-8")
    assert '.progress = 100' in text


def test_completed_snapshot_is_finalized_before_boot_validation(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    with patch.object(win, "_run_finalize_async") as finalize:
        win._on_validation_result({
            "snapshotExists": True,
            "qemuRunning": False,
            "libvirtRunning": False,
            "adoptedDiskExists": False,
        }, 0)
    finalize.assert_called_once_with([])
    _cleanup_player()


def test_finalize_success_continues_to_boot_validation(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    issues: list[str] = []
    with patch.object(win, "_fetch_boot_status_async") as boot_status:
        win._on_finalize_result({"success": True, "adoptedDisk": "/tmp/windows.qcow2"}, 0, issues)
    assert win._adopted_ok is True
    assert issues == []
    boot_status.assert_called_once_with(issues)
    _cleanup_player()


# ── Window lifecycle tests ──

def test_close_aborts_worker(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, iso="/fake.iso")
    win._operation_id = "op-test"
    win._attach_worker("op-test")
    assert win._worker is not None
    assert win._worker.isRunning()
    win.close()
    QApplication.processEvents()
    time.sleep(0.3)
    assert not win._worker.isRunning()
    _cleanup_player()


def test_player_hides_technical_log_until_requested(qapp) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(ROOT, MagicMock(), None, iso="/fake.iso")
    assert win.isWindow()
    assert win.testAttribute(Qt.WA_StyledBackground)
    assert win.autoFillBackground()
    assert win._log_frame.isHidden()
    assert win._details_btn.text() == "Ver detalhes técnicos"
    win._details_btn.click()
    assert not win._log_frame.isHidden()
    assert win._details_btn.text() == "Ocultar detalhes técnicos"
    win.close()
    _cleanup_player()


def test_player_action_intercepted_in_request_action(qapp) -> None:
    from linux.ui_native.main_window import MainWindow, WindowsInstallDialog
    from linux.ui_native.catalog import build_catalog

    catalog = build_catalog(ROOT)
    player_action = [a for a in catalog if a.id == "windows.provision.player"]
    assert len(player_action) == 1
    assert player_action[0].args == ("--internal-player",)
    assert not player_action[0].elevated

    with (
        patch("linux.ui_native.status_loader.StatusLoader.fetch_action"),
        patch("linux.ui_native.main_window.ProvisionPlayerWindow.open") as mock_open,
        patch("linux.ui_native.main_window.CommandRunner.start") as mock_start,
        patch.object(WindowsInstallDialog, "exec", return_value=WindowsInstallDialog.Accepted),
        patch.object(WindowsInstallDialog, "values", return_value={"input": "/fake.iso", "graphics": "compat", "image_index": "1", "guest_login": "auto"}),
    ):
        win = MainWindow(ROOT)
        # LUX-015: a medição de gráficos é assíncrona.
        win._graphics_probe_command = lambda: ["sh", "-c", "echo '{}'"]
        win.request_action(player_action[0])
        deadline = time.monotonic() + 5
        while not mock_open.called and time.monotonic() < deadline:
            QApplication.processEvents()
            time.sleep(0.02)
        mock_open.assert_called_once()
        assert mock_open.call_args.kwargs["guest_login"] == "auto"
        mock_start.assert_not_called()
        win.close()
        win.deleteLater()
        QApplication.processEvents()


def test_password_policy_passes_secret_via_stdin_only(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None, guest_login="password")
    win._qga_socket = "/tmp/qga.sock"
    win._provision_snapshot = "/tmp/golden.qcow2"
    async_instance = MagicMock()
    with (
        patch("linux.ui_native.provision_player.QInputDialog.getText",
              return_value=("S3cret!", True)),
        patch("linux.ui_native.provision_player.AsyncProc",
              return_value=async_instance),
    ):
        win._apply_guest_login_async([])
    program, args = async_instance.run.call_args.args
    kwargs = async_instance.run.call_args.kwargs
    assert program.endswith("/linux/pz")
    assert "S3cret!" not in args
    assert kwargs["stdin_data"] == "S3cret!\n"
    assert "--password-stdin" in args
    _cleanup_player()


@pytest.mark.parametrize("password,expected", [
    ("short", False),
    ("alllowercase123!", False),
    ("NOLOWERCASE123!", False),
    ("NoNumberSymbols!!", False),
    ("Strong-Recovery-42!", True),
])
def test_recovery_password_strength_contract(password: str, expected: bool) -> None:
    assert recovery_password_strength(password)[0] is expected


def test_recovery_secret_stdin_and_snapshot_proof_only(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None)
    win._qga_socket = "/tmp/qga.sock"
    win._provision_snapshot = "/tmp/golden.qcow2"
    async_instance = MagicMock()
    dialog = MagicMock()
    dialog.exec.return_value = QDialog.Accepted
    dialog.take_credentials.return_value = ("Strong-Recovery-42!", False)
    with (
        patch("linux.ui_native.provision_player.RecoveryPasswordDialog", return_value=dialog),
        patch("linux.ui_native.provision_player.AsyncProc", return_value=async_instance),
    ):
        win._apply_recovery_async([])
    _program, args = async_instance.run.call_args.args
    kwargs = async_instance.run.call_args.kwargs
    assert "Strong-Recovery-42!" not in args
    assert kwargs["stdin_data"] == "Strong-Recovery-42!\n"
    assert args[args.index("--backup-proof") + 1] == "/tmp/golden.qcow2"
    assert "--local-only" in args
    _cleanup_player()


def test_qga_repair_has_no_secret_and_manifest_survives_resume(qapp, fake_pz: Path) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None)
    win._vm_running = False
    async_instance = MagicMock()
    with (
        patch("linux.ui_native.provision_player.QMessageBox.question", return_value=QMessageBox.Yes),
        patch("linux.ui_native.provision_player.AsyncProc", return_value=async_instance),
    ):
        win._on_repair_qga()
    _program, args = async_instance.run.call_args.args
    assert args == ["windows-vm", "guest-login", "repair-qga", "--json"]
    with patch("linux.ui_native.provision_player.QMessageBox.information"):
        win._on_repair_qga_result({
            "state": "pending-guest-boot",
            "rollbackManifest": "/private/rollback/manifest.json",
        }, 0)
    saved = PLAYER_STATE_PATH.read_text(encoding="utf-8")
    assert "/private/rollback/manifest.json" in saved
    assert "password" not in saved.lower()
    _cleanup_player()


def test_qga_rollback_uses_manifest_and_clears_resume_state(qapp, fake_pz: Path) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None)
    win._vm_running = False
    win._rollback_manifest = "/private/rollback/manifest.json"
    async_instance = MagicMock()
    with (
        patch("linux.ui_native.provision_player.QMessageBox.question", return_value=QMessageBox.Yes),
        patch("linux.ui_native.provision_player.AsyncProc", return_value=async_instance),
    ):
        win._on_rollback_qga()
    _program, args = async_instance.run.call_args.args
    assert args == [
        "windows-vm", "guest-login", "rollback", "--manifest",
        "/private/rollback/manifest.json", "--json",
    ]
    win._on_rollback_qga_result({"success": True}, 0)
    assert win._rollback_manifest == ""
    assert "/private/rollback/manifest.json" not in PLAYER_STATE_PATH.read_text(encoding="utf-8")
    _cleanup_player()


# ── Cancel/retry/discard non-zero exit handling ──

def test_cancel_transitions_to_cancelled(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_CANCELLED,):
            break
        time.sleep(0.05)
    assert win._state in (ST_CANCELLED,)
    _cleanup_player()


def test_cancel_failure_transitions_to_failed(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    with patch.dict("os.environ", {"PZ_FAKE_CANCEL_FAIL": "1"}):
        win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_FAILED, ST_CANCELLED):
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED, "cancel failure must not mark cancelled"
    assert "Cancelamento falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_cancel_failure_keeps_player_state(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_PROVISIONING
    win._operation_id = "op-test"
    win._save_state()
    with patch.dict("os.environ", {"PZ_FAKE_CANCEL_FAIL": "1"}):
        win._on_cancel()
    for _ in range(100):
        QApplication.processEvents()
        if win._state in (ST_FAILED, ST_CANCELLED):
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED
    assert PLAYER_STATE_PATH.exists(), "player.json must survive a failed cancel (attach/resume)"
    _cleanup_player()


def test_discard_success_removes_state_and_closes(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_FAILED
    win._operation_id = _write_operation()
    win._save_state()
    assert PLAYER_STATE_PATH.exists()
    with patch("linux.ui_native.provision_player.QMessageBox.question",
               return_value=QMessageBox.Yes):
        win._on_discard()
    for _ in range(100):
        QApplication.processEvents()
        if win._discarding:
            break
        time.sleep(0.05)
    assert win._discarding, "discard must close after removal confirmed"
    assert not PLAYER_STATE_PATH.exists()
    _cleanup_player()


def test_discard_failure_keeps_window_and_state(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_FAILED
    win._operation_id = _write_operation()
    win._save_state()
    with (
        patch.dict("os.environ", {"PZ_FAKE_CANCEL_NO_REMOVE": "1"}),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_discard()
    for _ in range(100):
        QApplication.processEvents()
        if "Descarte falhou" in win._checkpoint_label.text():
            break
        time.sleep(0.05)
    assert win._state == ST_FAILED, "discard failure must not close the window"
    assert not win._discarding
    assert PLAYER_STATE_PATH.exists(), "player.json must survive a failed discard"
    assert "Descarte falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_shutdown_requires_json_success(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._operation_id = _write_operation()
    win._on_shutdown_vm()
    for _ in range(100):
        QApplication.processEvents()
        if win._async_proc is None:
            break
        time.sleep(0.05)
    assert win._vm_running is False
    assert win._state in (ST_DONE, ST_VALIDATING)
    _cleanup_player()


def test_shutdown_failure_stays_failed(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._operation_id = _write_operation()
    win._vm_running = True
    with patch.dict("os.environ", {"PZ_FAKE_SHUTDOWN_FAIL": "1"}):
        win._on_shutdown_vm()
    for _ in range(100):
        QApplication.processEvents()
        if win._async_proc is None:
            break
        time.sleep(0.05)
    assert win._vm_running is True, "failed shutdown must not clear vm_running"
    assert "Desligamento falhou" in win._checkpoint_label.text()
    _cleanup_player()


def test_reboot_stores_proc_and_error_restores_ui(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._one_shot_ready = True
    win._vm_running = False
    win._reboot_btn.setEnabled(True)
    bridge = fake_root / "bridge"
    bridge.write_text("#!/usr/bin/env bash\nexit 3\n")
    bridge.chmod(0o755)
    with (
        patch("linux.ui_native.provision_player.admin_bridge", return_value=str(bridge)),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_reboot()
    assert win._reboot_proc is not None, "reboot QProcess must be stored"
    for _ in range(100):
        QApplication.processEvents()
        if win._reboot_proc is None:
            break
        time.sleep(0.05)
    assert win._reboot_proc is None, "reboot proc must be released after finished"
    assert "Rein\u00edcio falhou" in win._checkpoint_label.text()
    assert win._progress_bar.maximum() == 100, "UI must be restored after reboot failure"
    assert win._reboot_btn.isEnabled(), "reboot button must be re-enabled"
    _cleanup_player()


def test_reboot_success_message(qapp, fake_pz_with_status: tuple[Path, Path]) -> None:
    fake_root, _ = fake_pz_with_status
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_root, MagicMock(), None)
    win._state = ST_DONE
    win._one_shot_ready = True
    win._vm_running = False
    bridge = fake_root / "bridge-ok"
    bridge.write_text("#!/usr/bin/env bash\nexit 0\n")
    bridge.chmod(0o755)
    with (
        patch("linux.ui_native.provision_player.admin_bridge", return_value=str(bridge)),
        patch("linux.ui_native.provision_player.QMessageBox.question",
              return_value=QMessageBox.Yes),
    ):
        win._on_reboot()
    for _ in range(100):
        QApplication.processEvents()
        if win._reboot_proc is None:
            break
        time.sleep(0.05)
    assert "Rein\u00edcio agendado" in win._checkpoint_label.text()
    _cleanup_player()


def test_retry_without_operation_recovers_to_new_install(qapp, fake_pz: Path) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(fake_pz, MagicMock(), None)
    win._operation_id = ""
    win._on_retry()
    QApplication.processEvents()
    assert win._state == ST_IDLE
    assert win._start_btn.isVisible()
    assert "Inicie uma nova instalação" in win._checkpoint_label.text()
    _cleanup_player()


def test_discard_removes_state_file(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    for _ in range(5):
        QApplication.processEvents()
        time.sleep(0.05)
    try:
        win = ProvisionPlayerWindow(ROOT, MagicMock(), None)
        win._operation_id = ""
        win._set_state(ST_FAILED)
        win._save_state()
        assert PLAYER_STATE_PATH.exists()
        with patch("linux.ui_native.provision_player.QMessageBox.question",
                   return_value=QMessageBox.Yes):
            win._on_discard()
        for _ in range(20):
            QApplication.processEvents()
            time.sleep(0.02)
        assert not PLAYER_STATE_PATH.exists()
    finally:
        for _ in range(5):
            QApplication.processEvents()
            time.sleep(0.05)
        _cleanup_player()


def test_open_params_beat_persisted_state(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    try:
        PLAYER_STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        PLAYER_STATE_PATH.write_text(json.dumps({
            "state": "failed",
            "iso": "/old.iso",
            "graphics": "virtio-gl",
            "imageIndex": "99",
            "operationId": "",
        }))
        win = ProvisionPlayerWindow(ROOT, MagicMock(), None,
                                    iso="/new.iso", graphics="compat",
                                    image_index="2")
        assert win._iso == "/new.iso", f"expected /new.iso, got {win._iso}"
        assert win._graphics == "compat", f"expected compat, got {win._graphics}"
        assert win._image_index == "2", f"expected 2, got {win._image_index}"
    finally:
        _cleanup_player()


def test_orphaned_done_state_is_quarantined_and_starts_clean(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    PLAYER_STATE_PATH.write_text(json.dumps({
        "state": "done",
        "iso": "/synthetic.iso",
        "graphics": "virtio-gl",
        "imageIndex": "9",
        "operationId": "op-test",
    }))

    with patch.object(ProvisionPlayerWindow, "_run_post_validation") as validation:
        win = ProvisionPlayerWindow(
            ROOT, MagicMock(), None,
            iso="/current.iso", graphics="compat", image_index="2",
        )

    validation.assert_not_called()
    assert win._state == ST_IDLE
    assert win._operation_id == ""
    assert win._iso == "/current.iso"
    assert win._graphics == "compat"
    assert win._image_index == "2"
    assert not win._start_btn.isHidden()
    assert "Inicie uma nova instalação" in win._checkpoint_label.text()
    assert not PLAYER_STATE_PATH.exists()
    assert len(list(PLAYER_STATE_PATH.parent.glob("player.orphaned-*.json"))) == 1
    _cleanup_player()


def test_valid_failed_state_resumes_original_operation(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    operation_id = _write_operation(state="failed")
    PLAYER_STATE_PATH.write_text(json.dumps({
        "state": "failed",
        "iso": "/original.iso",
        "graphics": "virtio-venus",
        "imageIndex": "4",
        "guestLogin": "auto",
        "operationId": operation_id,
    }))

    win = ProvisionPlayerWindow(
        ROOT, MagicMock(), None,
        iso="/new.iso", graphics="compat", image_index="2",
    )

    assert win._state == ST_FAILED
    assert win._operation_id == operation_id
    assert win._iso == "/original.iso"
    assert win._graphics == "virtio-venus"
    assert win._image_index == "4"
    assert not win._retry_btn.isHidden()
    assert "Retome ou descarte" in win._checkpoint_label.text()
    _cleanup_player()


def test_validation_failure_exposes_backend_reason(qapp) -> None:
    _cleanup_player()
    win = ProvisionPlayerWindow(ROOT, MagicMock(), None, iso="/fake.iso")
    async_proc = MagicMock()
    async_proc.stderr = "ERROR: metadata checksum mismatch"
    win._async_proc = async_proc

    win._on_validation_result(None, 1)

    assert win._state == ST_FAILED
    assert "metadata checksum mismatch" in win._checkpoint_label.text()
    assert "metadata checksum mismatch" in win._log.toPlainText()
    _cleanup_player()


def test_discard_orphaned_operation_returns_to_start(qapp) -> None:
    from linux.ui_native.provision_player import PLAYER_STATE_PATH
    _cleanup_player()
    win = ProvisionPlayerWindow(ROOT, MagicMock(), None, iso="/fake.iso")
    win._operation_id = "op-test"
    win._set_state(ST_FAILED)
    win._save_state()

    with patch("linux.ui_native.provision_player.QMessageBox.question") as question:
        win._on_discard()

    question.assert_not_called()
    assert win._state == ST_IDLE
    assert win._operation_id == ""
    assert "Inicie uma nova instalação" in win._checkpoint_label.text()
    assert not PLAYER_STATE_PATH.exists()
    _cleanup_player()
