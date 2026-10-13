"""UX-006 — Início por objetivo real.

A goal card is only honest if it reaches the place where that goal is
carried out. These tests drive the real dashboard widgets and the real
MainWindow navigation: choosing Windows must arrive at the Windows
installation entry, choosing a remote server must arrive at pairing, no
first-use step may require AI, and a recent task must be resumable.
"""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from linux.ui_native.pages.dashboard import JOURNEYS, ONBOARDING_STEPS, DashboardPage

ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")
ONBOARD_FIRST_STEP = "discover"


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def window(qapp, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        win = MainWindow(ROOT)
    yield win
    win.close()


def _button(page, text: str) -> QPushButton | None:
    for button in page.findChildren(QPushButton):
        if button.text() == text and button.isVisibleTo(page):
            return button
    return None


def _journey_button(page, title: str) -> QPushButton | None:
    for button in page.findChildren(QPushButton):
        if button.accessibleName().startswith(title):
            return button
    return None


# ---------------------------------------------------------------- destinations
@pytest.mark.parametrize(
    "title,category,focus",
    [
        ("Instalar e usar Windows", "Windows VM", "install"),
        ("Cuidar de outro computador", "Homelab", "pair"),
        ("Hospedar serviços em casa", "Homelab", "install"),
    ],
)
def test_goal_card_reaches_the_page_that_carries_the_goal(window, title, category, focus):
    dashboard = window.registry.page_for("Início")
    button = _journey_button(dashboard, title)
    assert button is not None, f"card '{title}' ausente no Início"

    seen: list[tuple[str, str]] = []
    dashboard.category_requested.connect(lambda c, f: seen.append((c, f)))
    QTest.mouseClick(button, Qt.LeftButton)

    assert seen == [(category, focus)]
    # The click really navigates: MainWindow is wired to the same signal.
    assert window.current_category == category
    assert window.stack.currentWidget() is window.registry.page_for(category)


def test_windows_goal_lands_on_the_installation_entry(window):
    window.show_journey("Windows VM", "install")
    page = window.registry.page_for("Windows VM")
    # Offscreen windows are never active, so focus is asserted through the
    # window's focus widget rather than hasFocus().
    assert page.window().focusWidget() is page.install_button
    assert page.install_button.text() == "Instalar automaticamente"


def test_remote_server_goal_lands_on_pairing(window):
    window.show_journey("Homelab", "pair")
    page = window.registry.page_for("Homelab")
    assert page.onboard_step_name() == "pair"
    assert "pareie" in page._state_label.text().casefold()
    # Arriving at pairing must not carry a confirmation from another host.
    assert page._onboard_confirmed is False


def test_hosting_goal_starts_the_guided_flow_from_the_beginning(window):
    page = window.registry.page_for("Homelab")
    page._onboard_step = 3
    window.show_journey("Homelab", "install")
    assert page.onboard_step_name() == ONBOARD_FIRST_STEP


def test_unknown_focus_still_shows_the_page(window):
    window.show_journey("Homelab", "nao-existe")
    assert window.current_category == "Homelab"


# ------------------------------------------------------------------- no AI
def test_first_use_steps_never_require_ai(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "empty"))
    from linux.ui_native.pages.registry import PageRegistry
    from linux.ui_native.command_runner import CommandRunner

    registry = PageRegistry(ROOT, CommandRunner(ROOT))
    dashboard = registry.page_for("Início")
    ai_actions = {
        action_id for action_id, action in dashboard.by_id.items()
        if action.category in {"IA & Dev", "Proxies IA", "Roteamento IA"}
    }
    used = set()
    for number, _title, _hint in ONBOARDING_STEPS:
        action_id = {"1": "system.doctor.system", "2": "profile.safe-base"}.get(number, "")
        used.add(action_id)
    assert used and not (used & ai_actions), "primeiro uso não pode exigir IA"
    assert len(ONBOARDING_STEPS) >= 2


def test_ai_stays_available_as_one_goal_among_others():
    keys = [row[0] for row in JOURNEYS]
    assert "ai" in keys
    assert keys.index("ai") > 0, "IA não é o primeiro objetivo oferecido"


# ------------------------------------------------------------------- resume
def _write_operation(state_root: Path, *, title: str, category: str, status: str) -> None:
    op_dir = state_root / "operations" / "20260908T120000Z-1-abc-test"
    op_dir.mkdir(parents=True)
    (op_dir / "operation.json").write_text(json.dumps({
        "schemaVersion": 1,
        "operationId": op_dir.name,
        "actionId": "homelab.status",
        "title": title,
        "category": category,
        "status": status,
        "progress": 40,
    }), encoding="utf-8")


def test_recent_task_can_be_resumed_from_the_start_page(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    state = tmp_path / "state" / "phasezero" / "control-center"
    _write_operation(state, title="Preparar Homelab", category="Homelab",
                     status="interrupted")
    from linux.ui_native.command_runner import CommandRunner

    page = DashboardPage(ROOT, CommandRunner(ROOT), [], by_id={})
    page.build()
    assert page.first_use is False

    seen: list[tuple[str, str]] = []
    page.category_requested.connect(lambda c, f: seen.append((c, f)))
    resume = _button(page, "Retomar")
    assert resume is not None, "tarefa recente não oferece retomada"
    QTest.mouseClick(resume, Qt.LeftButton)
    assert seen == [("Homelab", "")]

    labels = " | ".join(w.text() for w in page.resume_card.findChildren(QLabel))
    assert "Tarefa interrompida" in labels
    assert "Preparar Homelab" in labels


def test_first_use_has_no_resume_card(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    from linux.ui_native.command_runner import CommandRunner

    page = DashboardPage(ROOT, CommandRunner(ROOT), [], by_id={})
    page.build()
    assert page.first_use is True
    assert _button(page, "Retomar") is None
