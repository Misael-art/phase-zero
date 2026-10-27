from __future__ import annotations

import json
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QFrame, QLabel, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.ai_dev import AiDevPage

ROOT = Path(__file__).resolve().parents[1]

STATUS = {
    "stage": "web-model", "optIn": True,
    "launcher": {"active": True}, "route": {"active": True}, "daemonListening": True,
    "signedIn": True, "liveCodexRouteTouched": False, "upstreamMode": "browser-only",
    "autostart": {"state": "enabled"},
    "eligibility": {"blockers": ["o plano Plus não oferece MCP de desenvolvedor confirmado "
                                 "nesta integração; confira as permissões atuais da conta "
                                 "e do workspace"]},
}


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def build_page(monkeypatch, tmp_path, opted_in: bool):
    root = tmp_path / "chatgpt-web"
    root.mkdir()
    state = {"schemaVersion": 1}
    if opted_in:
        state["optIn"] = {"at": "2026-10-12T00:00:00Z"}
    (root / "state.json").write_text(json.dumps(state))
    monkeypatch.setenv("PZ_CHATGPT_WEB_ROOT", str(root))
    catalog = build_catalog(ROOT)
    actions = [action for action in catalog if action.category == "IA & Dev"]
    page = AiDevPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page, catalog


def card_of(page) -> QFrame:
    return page.findChild(QFrame, "chatgptWebCard")


def buttons_of(card) -> dict[str, QPushButton]:
    return {button.property("bridgeRole"): button for button in card.findChildren(QPushButton)}


def test_bridge_card_is_absent_until_this_host_opted_in(qapp, monkeypatch, tmp_path):
    page, catalog = build_page(monkeypatch, tmp_path, opted_in=False)

    assert card_of(page).isHidden()
    # Private card: nothing about the bridge enters the public catalog.
    assert not any("chatgpt-web" in " ".join(action.args) for action in catalog)
    assert not any(action.id.startswith("private.chatgpt-web") for action in catalog)


def test_bridge_card_offers_the_everyday_commands_once_opted_in(qapp, monkeypatch, tmp_path):
    page, _ = build_page(monkeypatch, tmp_path, opted_in=True)
    card = card_of(page)
    assert not card.isHidden()
    requested = []
    page.action_requested.connect(requested.append)
    buttons = buttons_of(card)
    # Same button styles as every other card on the page.
    assert {button.objectName() for button in buttons.values()} == {"primaryButton",
                                                                    "secondaryButton"}

    expected = {
        "chatgptWebOpen": ("ai", "chatgpt-web", "desktop"),
        "chatgptWebSetup": ("ai", "chatgpt-web", "setup", "--login-wait", "0"),
        "chatgptWebTools": ("ai", "chatgpt-web", "tools", "status"),
        "chatgptWebToolsOn": ("ai", "chatgpt-web", "tools", "enable"),
        "chatgptWebToolsOff": ("ai", "chatgpt-web", "tools", "disable"),
        "chatgptWebSmoke": ("ai", "chatgpt-web", "smoke"),
        "chatgptWebDisable": ("ai", "chatgpt-web", "disable"),
    }
    assert set(buttons) == set(expected)
    for name, args in expected.items():
        buttons[name].click()
        assert requested[-1].args == args
        assert requested[-1].category == "IA & Dev"
    by_name = {name: requested[index] for index, name in enumerate(expected)}
    assert by_name["chatgptWebOpen"].mutable is False
    assert by_name["chatgptWebTools"].mutable is False
    for name in ("chatgptWebSetup", "chatgptWebSmoke", "chatgptWebDisable",
                 "chatgptWebToolsOn", "chatgptWebToolsOff"):
        action = by_name[name]
        assert action.mutable is True and action.impact
        assert action.preview_args == ("ai", "chatgpt-web", "status")
    assert "1 mensagem" in buttons["chatgptWebSmoke"].text()
    assert buttons["chatgptWebTools"].text() == "Ver requisitos"
    assert "~/.codex" in by_name["chatgptWebDisable"].impact
    assert len({action.id for action in requested}) == len(requested)


def test_bridge_card_reports_state_and_why_tools_are_blocked(qapp, monkeypatch, tmp_path):
    page, _ = build_page(monkeypatch, tmp_path, opted_in=True)
    card = card_of(page)

    page._on_status_ready("private.chatgpt-web.status", "", STATUS)

    state = card.findChild(QLabel, "chatgptWebState")
    tools = next(label for label in card.findChildren(QLabel)
                 if label.property("bridgeRole") == "tools")
    assert "modelo Web ativo" in state.text() and "inicia com o login" in state.text()
    assert state.property("state") == "success"
    assert "bloqueado" in tools.text() and "Plus" in tools.text()
    assert buttons_of(card)["chatgptWebOpen"].isEnabled()

    full_without_access = {**STATUS, "upstreamMode": "full"}
    page._on_status_ready("private.chatgpt-web.status", "", full_without_access)
    assert "bloqueada" in tools.text() and "Plus" in tools.text()
    assert "ferramentas em verificação" in state.text()

    full_without_proof = {**STATUS, "upstreamMode": "full",
                          "eligibility": {"blockers": []},
                          "toolsGate": {"next": {"id": "full-runtime",
                                                 "detail": "Full 6.1.8 exige rede no turno"}}}
    page._on_status_ready("private.chatgpt-web.status", "", full_without_proof)
    assert "bloqueado" in tools.text() and "rede no turno" in tools.text()

    pro_unverified = {**STATUS, "eligibility": {"blockers": [],
                                               "planMcpCapability": "write-unverified"},
                      "toolsGate": {"next": {"id": "full-runtime",
                                             "detail": "Full exige turno MCP real",
                                             "action": "Teste o runtime Full."}}}
    page._on_status_ready("private.chatgpt-web.status", "", pro_unverified)
    account = next(label for label in card.findChildren(QLabel)
                   if label.property("bridgeRole") == "account")
    next_step = next(label for label in card.findChildren(QLabel)
                     if label.property("bridgeRole") == "next")
    assert "Conta Pro" in account.text() and "ainda não verificadas" in account.text()
    assert "Full exige turno MCP real" in tools.text()
    assert "Teste o runtime Full" in next_step.text()
    assert buttons_of(card)["chatgptWebSetup"].text() == "Reparar"

    stopped = {**STATUS, "stage": "launcher-configured", "launcher": {"active": False},
               "route": {"active": False}, "daemonListening": False}
    page._on_status_ready("private.chatgpt-web.status", "", stopped)
    assert "Ligar ou reparar" in state.text() and state.property("state") == "warning"
    assert not buttons_of(card)["chatgptWebOpen"].isEnabled()
    assert buttons_of(card)["chatgptWebSetup"].text() == "Preparar ou reparar"

    touched = {**STATUS, "liveCodexRouteTouched": True}
    page._on_status_ready("private.chatgpt-web.status", "", touched)
    assert state.property("state") == "error" and "~/.codex" in state.text()

    page._on_status_failed("private.chatgpt-web.status", "timed out")
    assert "Atualizar" in state.text() and state.property("state") == "warning"
    assert not next_step.text() and not account.text()


def test_bridge_card_follows_the_running_lock(qapp, monkeypatch, tmp_path):
    page, _ = build_page(monkeypatch, tmp_path, opted_in=True)
    card = card_of(page)
    page._on_status_ready("private.chatgpt-web.status", "", STATUS)

    page.block_while_running(True)
    assert not any(button.isEnabled() for button in card.findChildren(QPushButton))
