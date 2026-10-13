"""LUX-015 — seletor de boot não congela e explica falhas pela escolha feita."""
from __future__ import annotations

import time
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from linux.ui_native import boot_selector

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def selector(qapp):
    with patch.object(boot_selector, "load_dynamic_boot_choices", return_value=()):
        window = boot_selector.BootSelectorWindow(ROOT, smoke_test=True)
    reports: list[tuple] = []
    window._report = lambda *args, **kw: reports.append(args)  # type: ignore[method-assign]
    window.reports = reports
    yield window
    if window._process is not None:
        window._process.kill()
        window._process.waitForFinished(2000)
    window.close()


def _wait(predicate, timeout_ms=20000):
    # Só limita a espera pela conclusão; o não-bloqueio é medido à parte
    # (retorno < 0,5 s). Após suítes pesadas o loop de eventos fica lento.
    deadline = time.monotonic() + timeout_ms / 1000
    while not predicate() and time.monotonic() < deadline:
        QTest.qWait(20)
    assert predicate()


def _select(window, key):
    index = next(i for i, k in window.choice_buttons.items() if k == key)
    window.group.button(index).setChecked(True)


def test_run_choice_returns_immediately_and_reports_by_choice(selector):
    _select(selector, "waydroid")
    with patch.object(boot_selector, "build_boot_selector_program",
                      return_value=("sh", ["-c", "sleep 1; echo 'grub falhou' >&2; exit 3"])):
        started = time.monotonic()
        selector.run_choice(reboot=False)
        assert time.monotonic() - started < 0.5
        assert not selector.action_buttons[0].isEnabled()
        selector.reject()  # não fecha durante o agendamento
        assert selector._process is not None
        _wait(lambda: selector._process is None)
    assert selector.action_buttons[0].isEnabled()
    _icon, title, text, informative, *_ = selector.reports[-1]
    assert "Waydroid" in text
    assert "grub falhou" in informative
    assert "Windows" not in informative


def test_timeout_is_handled(selector):
    selector.RUN_TIMEOUT_MS = 200
    with patch.object(boot_selector, "build_boot_selector_program",
                      return_value=("sh", ["-c", "sleep 10"])):
        selector.run_choice(reboot=False)
        _wait(lambda: selector._process is None)
    assert "tempo esgotado" in selector.reports[-1][3]


def test_missing_program_is_handled(selector):
    with patch.object(boot_selector, "build_boot_selector_program",
                      return_value=("/nonexistent/pz-missing", [])):
        selector.run_choice(reboot=False)
        _wait(lambda: selector._process is None)
    assert selector.reports and selector.reports[-1][1] == "Falha ao agendar boot"


def test_windows_install_measures_graphics_without_blocking(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
    opened: list[dict] = []
    win._graphics_probe_command = lambda: ["sh", "-c", 'sleep 1; echo \'{"backend": "virgl"}\'']
    win._open_windows_install = lambda status: opened.append(status)
    try:
        started = time.monotonic()
        win.request_action(win.by_id["windows.provision.player"])
        assert time.monotonic() - started < 0.5
        assert "Medindo" in win.status_text.text()
        _wait(lambda: bool(opened))
        assert opened == [{"backend": "virgl"}]
    finally:
        win.close()


def test_windows_install_probe_failure_falls_back_to_unknown(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
    opened: list[dict] = []
    win._graphics_probe_command = lambda: ["/nonexistent/pz"]
    win._open_windows_install = lambda status: opened.append(status)
    try:
        win.request_action(win.by_id["windows.provision.player"])
        _wait(lambda: bool(opened))
        assert opened == [{}]
    finally:
        win.close()
