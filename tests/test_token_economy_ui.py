from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.ai_dev import AiDevPage
from linux.ui_native.pages.economy import STATUS_ID
from linux.ui_native.status_loader import StatusLoader

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def page(monkeypatch):
    app = QApplication.instance() or QApplication([])
    monkeypatch.setattr(StatusLoader, "fetch", lambda *_args: None)
    catalog = build_catalog(ROOT)
    page = AiDevPage(ROOT, CommandRunner(ROOT), [a for a in catalog if a.category == "IA & Dev"], by_id={a.id: a for a in catalog})
    page.build()
    yield page
    page.close()
    page.deleteLater()
    app.processEvents()


def payload(**changes):
    return {"ok": True, "project": "/fixture/project", "agents": [{"id": "codex", "label": "Codex", "configured": True,
            "profile": "basic", "memory": {"connected": True}}], "rtk": {"installed": True}, **changes}


def test_unknown_failed_and_busy_states_cannot_mutate(page):
    card = page.economy_card
    assert not card.apply.isEnabled()
    page._on_status_ready(STATUS_ID, "", payload())
    assert card.apply.isEnabled()
    page.block_while_running(True)
    page._on_status_ready(STATUS_ID, "", payload())
    assert not card.apply.isEnabled() and not card.import_usage.isEnabled()
    page.block_while_running(False)
    page._on_status_failed(STATUS_ID, "timeout")
    assert not card.apply.isEnabled()


def test_profile_action_uses_runner_preview_and_same_project(page):
    card = page.economy_card
    page._on_status_ready(STATUS_ID, "", payload())
    requested = []
    page.action_requested.connect(requested.append)
    card.profile.setCurrentIndex(1)
    card.apply.click()
    action = requested[0]
    assert action.mutable and "economy" in action.args
    assert "plan" in action.preview_args and "/fixture/project" in action.preview_args
    assert not action.parameters
    assert "memória" in card.memory.text().lower() or "ai-memory" in card.memory.text()
    card.project.setText("/other-project")
    assert not card.apply.isEnabled()
    card.dispatch("apply")
    assert len(requested) == 1


def test_negative_estimate_and_unknown_bill_are_visible(page):
    report = {"reductionPercent": -20}
    page._on_status_ready(STATUS_ID, "", payload(measurements={"codex": report}))
    assert "-20%" in page.economy_card.evidence.text()
    assert "não medidos" in page.economy_card.evidence.text()
    assert page.economy_card.profile.currentData() == "basic"
    assert set(page.economy_card.agent.itemData(i) for i in range(page.economy_card.agent.count())) >= {"codex", "claude-code", "opencode", "gemini", "deepseek-harness"}
