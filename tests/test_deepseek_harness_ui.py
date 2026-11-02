from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.accounts import AccountChannelsDialog
from linux.ui_native.pages.ai_dev import AiDevPage
from linux.ui_native.status_loader import StatusLoader
from linux.ui_native.widgets import ParameterDialog

ROOT = Path(__file__).resolve().parents[1]
STATUS = "ai.deepseek-harness-status"


@pytest.fixture
def page(monkeypatch):
    app = QApplication.instance() or QApplication([])
    monkeypatch.setattr(StatusLoader, "fetch", lambda *_: None)
    catalog = build_catalog(ROOT)
    result = AiDevPage(ROOT, CommandRunner(ROOT),
                       [a for a in catalog if a.category == "IA & Dev"],
                       by_id={a.id: a for a in catalog})
    result.build()
    yield result
    result.close()
    result.deleteLater()
    app.processEvents()


def test_harness_waits_for_observation_and_exposes_all_catalog_operations(page):
    assert not page._harness_buttons["install"].isEnabled()
    assert not page._harness_buttons["start"].isEnabled()
    assert page._harness_buttons["doctor"].isEnabled()
    assert set(page._harness_buttons) == {
        "status", "plan", "install", "update", "start", "open", "login", "stop", "doctor", "uninstall",
    }
    page._on_status_ready(STATUS, "", {"installed": False, "state": "not-installed", "memoryBudget": "sufficient"})
    assert page._harness_buttons["install"].isEnabled()
    assert page._harness_buttons["start"].isHidden()
    requested = []
    page.action_requested.connect(requested.append)
    page._harness_buttons["install"].click()
    assert requested[-1].id == "ai.deepseek-harness-install"


@pytest.mark.parametrize("state,runtime", [("installed", "stopped"), ("running", "running"), ("degraded", "crashed-or-stale")])
def test_harness_callbacks_preserve_busy_lock_and_recover(page, state, runtime):
    payload = {"installed": True, "state": state, "runtimeState": runtime, "memoryBudget": "sufficient"}
    page.block_while_running(True)
    page._on_status_ready(STATUS, "", payload)
    assert not any(button.isEnabled() for button in page._harness_buttons.values())
    page.block_while_running(False)
    assert page._harness_buttons["doctor"].isEnabled()
    assert page._harness_buttons["start"].isEnabled() is (runtime != "running")
    assert page._harness_buttons["open"].isEnabled() is (runtime == "running")


def test_harness_failure_clears_mutation_readiness_and_memory_blocks_start(page):
    page._on_status_ready(STATUS, "", {"installed": True, "state": "installed", "memoryBudget": "insufficient"})
    assert not page._harness_buttons["start"].isEnabled()
    assert "2 GiB" in page.harness_next.text()
    page._on_status_failed(STATUS, "offline")
    assert not page._harness_buttons["install"].isEnabled()
    assert not page._harness_buttons["uninstall"].isEnabled()
    assert "indisponível" in page.harness_state.text()


def test_unhealthy_runtime_is_not_shown_as_stopped(page):
    page._on_status_ready(STATUS, "", {"installed": True, "state": "installed",
        "runtimeState": "starting-or-unhealthy", "memoryBudget": "sufficient"})
    assert "saúde ainda não confirmada" in page.harness_state.text()
    assert "parado" not in page.harness_state.text()
    assert page._harness_buttons["stop"].isEnabled()
    assert not page._harness_buttons["start"].isEnabled()


def test_mcp_config_inventory_does_not_claim_verified_connection(page):
    page._on_status_ready("ai.status", "", {"mcp": {"definitions": [], "targets": {}}, "clis": {}})
    assert "não verificada" in page._status_labels["mcp"].text()
    page._on_status_ready("ai.status", "", {"mcp": {"problems": [{"id": "invalid-target"}]}, "clis": {}})
    assert "reparar" in page._status_labels["mcp"].text()


def test_browser_login_requires_account_route_and_current_supervisor(page):
    payload = {"installed": True, "state": "running", "runtimeState": "running",
               "memoryBudget": "sufficient", "authRoute": "account"}
    page._on_status_ready(STATUS, "", payload)
    assert page._harness_buttons["login"].isHidden()
    payload["connectionFeatures"] = ["account-oauth"]
    page._on_status_ready(STATUS, "", payload)
    button = page._harness_buttons["login"]
    assert not button.isHidden() and button.isEnabled()
    requested = []; page.action_requested.connect(requested.append); button.click()
    assert requested[-1].args == ("ai", "deepseek-harness", "login", "--json")
    payload["authRoute"] = "api"
    page._on_status_ready(STATUS, "", payload)
    assert button.isHidden() and not button.isEnabled()


def test_start_form_and_preview_bind_route_workspace_and_custom_port(page):
    action = page.by_id["ai.deepseek-harness-start"]
    dialog = ParameterDialog(action)
    dialog._fields["workspace"].setText("/tmp/explicit-workspace")
    dialog._fields["authRoute"].setCurrentText("api")
    dialog._fields["port"].setCurrentText("custom")
    dialog._fields["port.custom"].setText("4199")
    values = dialog.values()
    assert values == {"workspace": "/tmp/explicit-workspace", "authRoute": "api", "port": "4199",
                      "keySource": "web", "credentialId": "", "nickname": "", "apiKey": ""}
    assert action.preview_args[2] == "start-plan"
    for name in values.keys() - {"apiKey"}:
        assert "{" + name + "}" in action.args
        assert "{" + name + "}" in action.preview_args
    values["apiKey"] = "fixture-secret-not-for-argv"
    assert action.stdin_parameter == "apiKey"
    assert values["apiKey"] not in " ".join(action.resolved_args(values=values))
    assert values["apiKey"] not in " ".join(action.resolved_args(values=values, preview=True))
    dialog.close()


def test_account_channels_navigate_to_same_harness_journey(page):
    dialog = AccountChannelsDialog()
    targets = []
    dialog.destination_requested.connect(lambda *args: targets.append(args))
    buttons = dialog.findChildren(QPushButton, "openHarnessFromAccounts")
    assert len(buttons) == 2
    buttons[0].click()
    assert targets == [("IA & Dev", "deepseek-harness")]
    dialog.close()
