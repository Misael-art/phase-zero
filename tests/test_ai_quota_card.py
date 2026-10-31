from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QFrame, QLabel, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.ai_dev import AiDevPage

ROOT = Path(__file__).resolve().parents[1]

PAYLOAD = {
    "tray": {"autostart": False, "running": False},
    "meters": [
        {"id": "codex:current", "label": "Codex · Principal", "color": "#2563eb", "remaining": 75,
         "level": "green", "resetsAt": "2099-01-01T00:00:00+00:00", "plan": "Pro",
         "subscriptionUntil": "2099-02-01T15:00:00+00:00", "windows": []},
        {"id": "claude:default", "label": "Claude", "color": "#d97757", "remaining": 30,
         "level": "yellow", "resetsAt": None, "plan": "Max", "subscriptionUntil": None,
         "windows": []},
        {"id": "codex:x", "label": "Codex · X", "color": "#15803d", "remaining": 0,
         "level": "red", "resetsAt": None, "windows": []},
        {"id": "grok:default", "label": "Grok", "color": "#9ca3af", "remaining": None,
         "level": None, "resetsAt": None, "error": "o Grok não expõe", "windows": []},
    ],
}


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def build_page(monkeypatch, tmp_path):
    monkeypatch.setenv("PZ_CHATGPT_WEB_ROOT", str(tmp_path / "absent"))
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "IA & Dev"]
    page = AiDevPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page


def card(page, role):
    return next(f for f in page.findChildren(QFrame) if f.property("cardRole") == role)


def test_quota_rows_use_level_badges_and_toggle_follows_tray(qapp, monkeypatch, tmp_path):
    page = build_page(monkeypatch, tmp_path)
    requested = []
    page.action_requested.connect(requested.append)
    page._on_status_ready("ai.quota.status", "", PAYLOAD)
    quota = card(page, "quota")
    badges = {b.text(): b.property("state") for b in quota.findChildren(QLabel)
              if b.objectName() == "badge"}
    assert badges == {"75%": "success", "30%": "warning", "0%": "error", "n/d": "info"}
    text = " ".join(label.text() for label in quota.findChildren(QLabel))
    assert "plano Pro" in text and "assinatura paga até 01/02/2099" in text
    toggle = next(b for b in quota.findChildren(QPushButton) if b.property("quotaRole") == "toggle")
    assert toggle.text() == "Ligar medidores na bandeja"
    toggle.click()
    assert requested[-1].id == "ai.quota.install"

    page._on_status_ready("ai.quota.status", "", {**PAYLOAD, "tray": {"autostart": True, "running": False}})
    assert toggle.text() == "Abrir medidores na bandeja" and page.quota_state.property("state") == "warning"
    toggle.click()
    assert requested[-1].id == "ai.quota.install"

    page._on_status_ready("ai.quota.status", "", {**PAYLOAD, "tray": {"autostart": True, "running": True}})
    assert toggle.text() == "Desligar medidores na bandeja"
    assert page.quota_state.property("state") == "success"
    toggle.click()
    assert requested[-1].id == "ai.quota.remove"
    # Rows are replaced, not stacked, on refresh.
    assert len([b for b in quota.findChildren(QLabel) if b.objectName() == "badge"
                and not b.isHidden() and b.parent() is not None]) >= 4


def test_desktop_card_switches_install_and_update(qapp, monkeypatch, tmp_path):
    page = build_page(monkeypatch, tmp_path)
    page._on_status_ready("ai.desktop.status", "", {"claudeDesktop": {"installed": False}})
    assert not page.desktop_install.isHidden() and page.desktop_update.isHidden()
    assert not page.desktop_check.isEnabled()
    page._on_status_ready("ai.desktop.status", "", {
        "claudeDesktop": {"installed": True, "version": "4.4212.0", "launcherManaged": True},
        "updater": {"timerEnabled": False}})
    assert page.desktop_install.isHidden() and page.desktop_update.isEnabled()
    assert "4.4212.0" in page.desktop_state.text() and "desligada" in page.desktop_state.text()
    requested = []
    page.action_requested.connect(requested.append)
    assert page.desktop_auto.text() == "Ligar atualização automática"
    page.desktop_auto.click()
    assert requested[-1].id == "ai.desktop.updates.on"
    page._on_status_ready("ai.desktop.status", "", {
        "claudeDesktop": {"installed": True, "version": "4.4212.0", "launcherManaged": True},
        "updater": {"timerEnabled": True}})
    assert page.desktop_auto.text() == "Desligar atualização automática"
    page.desktop_auto.click()
    assert requested[-1].id == "ai.desktop.updates.off"
    page._on_status_ready("ai.desktop.claude.check", "", {
        "installed": "4.4212.0", "latest": "4.5000.0", "available": True, "running": True})
    assert "4.5000.0" in page.desktop_state.text() and page.desktop_state.property("state") == "warning"


def test_running_lock_disables_new_controls(qapp, monkeypatch, tmp_path):
    page = build_page(monkeypatch, tmp_path)
    page._on_status_ready("ai.desktop.status", "", {"claudeDesktop": {"installed": True, "version": "1"}})
    page.block_while_running(True)
    assert not page.quota_toggle.isEnabled() and not page.desktop_update.isEnabled()
