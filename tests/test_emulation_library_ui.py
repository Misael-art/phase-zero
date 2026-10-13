from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QFrame, QStackedWidget, QTableWidget

from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.emulation import EmulationPage


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _page() -> EmulationPage:
    from linux.ui_native.catalog import build_catalog

    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "Emulação"]
    page = EmulationPage(ROOT, CommandRunner(ROOT), actions, {a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page


def test_emulation_landing_has_four_task_journeys(qapp):
    page = _page()
    journeys = page.findChildren(QFrame, "journeyCard")
    assert len(journeys) == 4
    assert page.stack.count() == 5
    assert page.represented_action_ids == {action.id for action in page.actions}


def test_library_workspace_has_five_steps_and_results_table(qapp):
    page = _page()
    assert len(page.step_labels) == 5
    assert isinstance(page.table, QTableWidget)
    assert page.table.columnCount() == 5
    assert page.detail is not None and page.detail.isHidden()


def test_scan_payload_populates_summary_and_context_detail(qapp):
    page = _page()
    payload = {
        "scanId": "scan-test",
        "summary": {
            "games": 1, "ready": 0, "actionsRecommended": 1,
            "blocked": 0, "unknown": 0,
        },
        "items": [{
            "path": "/games/PCSE01224.zip",
            "game": "Test Game",
            "systemName": "PlayStation Vita",
            "origin": "ZIP instalável",
            "destination": "vita3k",
            "state": "action",
            "recommendation": "Instalar no Vita3K; original preservado",
            "detection": {"method": "content", "confidence": 0.95},
        }],
    }
    page.scan_payload = payload
    page._render_scan(payload)
    assert page.summary_labels["games"].text() == "1"
    assert page.table.rowCount() == 1
    page.table.selectRow(0)
    QApplication.processEvents()
    assert not page.detail.isHidden()
    assert "Vita3K" in page.detail_body.text()


def test_main_window_inspector_is_contextual_not_permanently_empty(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        assert window.inspector.isHidden()
        action = next(action for action in window.catalog if action.id == "emulation.setup")
        window.inspect_action(action)
        assert not window.inspector.isHidden()
        window.show_category("Emulação")
        assert window.inspector.isHidden()
        window.close()
