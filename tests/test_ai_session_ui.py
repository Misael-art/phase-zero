from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QGroupBox, QLabel, QPushButton, QWidget

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.models import OperationResult
from linux.ui_native.operation_ledger import OperationLedger
from linux.ui_native.pages.ai_dev import AiDevPage
from linux.ui_native.pages.ai_proxies import AiProxiesPage
from linux.ui_native.pages.ai_routing import AiRoutingPage
from linux.ui_native.pages.results import ResultsPage
from linux.ui_native.pages.registry import PageRegistry
from linux.ui_native.proxy_models import ProxyState
from linux.ui_native.result_parser import severity_for
from linux.ui_native.widgets import PreviewDialog, ResultDialog


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def catalog():
    return build_catalog(ROOT)


@pytest.fixture
def by_id(catalog):
    return {a.id: a for a in catalog}


@pytest.fixture
def proxies_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "Proxies IA"]
    page = AiProxiesPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


@pytest.fixture
def ai_dev_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "IA & Dev"]
    page = AiDevPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


@pytest.fixture
def routing_page(qapp, catalog, by_id):
    actions = [action for action in catalog if action.category == "Roteamento IA"]
    page = AiRoutingPage(ROOT, CommandRunner(ROOT), actions, by_id=by_id)
    page.build()
    page.finalize_action_coverage()
    page.set_advanced_mode(False)
    return page, actions


def test_registry_uses_dedicated_ai_pages():
    assert PageRegistry._CATEGORY_PAGES["IA & Dev"] is AiDevPage
    assert PageRegistry._CATEGORY_PAGES["Proxies IA"] is AiProxiesPage
    assert PageRegistry._CATEGORY_PAGES["Roteamento IA"] is AiRoutingPage


def test_bonsai_run_waits_for_account_bound_grant(routing_page):
    page, _actions = routing_page
    button = next(
        child for child in page.findChildren(QPushButton)
        if child.text().startswith("Executar Claude via Bonsai")
    )
    assert not button.isEnabled()
    assert "grant por conexão" in button.toolTip()
    warning = next(
        child for child in page.findChildren(QLabel)
        if "consentimento de upload não autoriza inferência" in child.text()
    )
    assert "indisponível" in warning.text()


def test_main_window_previews_every_mutable_action():
    src = (ROOT / "linux/ui_native/main_window.py").read_text(encoding="utf-8")
    assert "preview=action.mutable, values=values" in src
    assert "skip_preview" not in src


def test_proxy_usage_actions_remain_explicitly_blocked(by_id):
    for action_id, proxy in (
        ("ai.proxies-ensure-kimi", "kimiproxy"),
        ("ai.proxies-ensure-qwen", "qwenproxy"),
        ("ai.proxies-ensure-deeps", "deepsproxy"),
        ("ai.proxies-ensure-mimo", "mimo-ai-proxy"),
        ("ai.proxies-ensure-all", "all"),
    ):
        action = by_id[action_id]
        assert action.mutable
        assert action.args == ("ai", "proxies", "ensure", proxy)
        assert action.preview_args == ("ai", "proxies", "ensure", proxy, "--dry-run")
        assert "grant" in action.description.lower()
    assert by_id["ai.proxies-start-all"].mutable
    assert "bloqueado" in by_id["ai.proxies-test"].title.lower()
    assert by_id["ai.proxies"].visibility == "advanced"
    assert by_id["ai.proxies-start-qwen"].visibility == "advanced"
    assert by_id["ai.proxies-login-qwen"].visibility == "advanced"
    assert "não testa inferência nem inicia o serviço" in by_id["ai.proxies-login-qwen"].description
    assert by_id["ai.proxies-open-qwen"].args == ("ai", "proxies", "open", "qwenproxy")
    assert not by_id["ai.proxies-open-qwen"].mutable
    assert by_id["ai.proxies-credentials-mimo"].stdin_parameter == "credentials"


def test_workspace_auth_and_provenance_actions_are_catalogued(by_id):
    assert by_id["ai.hermes-status"].args == ("ai", "hermes", "status")
    assert by_id["ai.hermes-doctor"].args == ("ai", "hermes", "doctor")
    assert by_id["ai.workspaces-doctor"].args == ("ai", "workspaces", "doctor")
    assert by_id["ai.workspaces-plan"].args == ("ai", "workspaces", "plan")
    assert by_id["ai.odysseus-install"].preview_args == ("ai", "odysseus", "plan")
    assert by_id["ai.auth-registry"].args == ("ai", "auth", "status")
    assert by_id["ai.auth-doctor"].args == ("ai", "auth", "doctor")
    assert by_id["ai.operations-status"].args == ("ai", "operations", "status")


def test_ai_portability_actions_keep_passphrase_off_argv(by_id):
    export = by_id["ai.backup.export"]
    verify = by_id["ai.backup.verify"]
    restore = by_id["ai.backup.restore"]
    assert export.stdin_parameter == "passphrase"
    assert "{passphrase}" not in export.args
    assert verify.stdin_parameter == "passphrase"
    assert "{passphrase}" not in verify.args
    assert restore.stdin_parameter == "passphrase"
    assert restore.stdin_on_preview is True
    assert "{passphrase}" not in restore.args
    assert "{passphrase}" not in restore.preview_args


def test_proxies_page_covers_all_catalog_actions(proxies_page):
    page, actions = proxies_page
    assert {action.id for action in actions} <= page.represented_action_ids


def test_proxies_page_disables_unbound_consumer_use(proxies_page):
    page, _actions = proxies_page
    labels = []
    hero = page.prepare_button.parentWidget()
    for index in range(hero.layout().count()):
        widget = hero.layout().itemAt(index).widget()
        if isinstance(widget, QPushButton):
            labels.append(widget.text())
    assert labels == ["Atualizar", "Uso bloqueado"]
    qwen = page._cards["qwenproxy"]
    use = qwen["use"]
    assert isinstance(use, QPushButton)
    assert use.text() == "Uso bloqueado"
    assert not use.isEnabled()
    assert not page.prepare_button.isEnabled()
    selected = []
    page.action_selected.connect(lambda action: selected.append(action.id))
    use.click()
    assert selected == []


def test_proxies_page_hides_ports_in_simple_mode(proxies_page):
    page, _actions = proxies_page
    port = page._cards["qwenproxy"]["port"]
    assert isinstance(port, QLabel)
    assert port.isHidden()
    page.set_advanced_mode(True)
    assert not port.isHidden()


def test_unbound_proxy_consumer_use_and_ide_sync_are_blocked(proxies_page):
    page, _actions = proxies_page
    page._apply_proxies({
        "qwenproxy": ProxyState(
            id="qwenproxy", installed=True, service="active",
            auth_status="authenticated",
        ),
        "mimo-ai-proxy": ProxyState(
            id="mimo-ai-proxy", installed=True, service="active",
            auth_status="missing-credentials",
        ),
    })
    qwen_use = page._cards["qwenproxy"]["use"]
    mimo_use = page._cards["mimo-ai-proxy"]["use"]
    assert not qwen_use.isEnabled()
    assert not mimo_use.isEnabled()
    assert "grant por conexão" in qwen_use.toolTip()
    with patch.object(page, "run_action") as run_action:
        page._on_use_clicked("qwenproxy")
        page._on_use_clicked("mimo-ai-proxy")
        run_action.assert_not_called()
    ide_setup = next(
        button for button in page.findChildren(QPushButton)
        if button.text() == "Uso por IDE bloqueado"
    )
    assert not ide_setup.isEnabled()
    assert "grant por conexão" in ide_setup.toolTip()
    for action_id in (
        "ai.proxies-start-all", "ai.proxies-test", "ai.proxies-credentials-mimo",
        "ai.proxies.restart-one", "ai.proxies.test-one",
    ):
        blocked = page._action_button(action_id, "Blocked action")
        assert blocked is not None and not blocked.isEnabled()


def test_proxies_page_translates_status_into_human_copy(proxies_page):
    page, _actions = proxies_page
    page._apply_proxies({
        "qwenproxy": ProxyState(
            id="qwenproxy", installed=False, service="inactive",
            auth_status="not-installed",
        ),
        "kimiproxy": ProxyState(
            id="kimiproxy", installed=True, service="active",
            auth_status="authenticated",
        ),
        "deepsproxy": ProxyState(
            id="deepsproxy", installed=True, service="inactive",
            auth_status="ready-for-login",
        ),
        "mimo-ai-proxy": ProxyState(
            id="mimo-ai-proxy", installed=True, service="active",
            auth_status="missing-credentials", auth_missing=("service-token-group",),
        ),
    })
    assert page._cards["qwenproxy"]["headline"].text() == "Precisa preparar"
    assert page._cards["kimiproxy"]["headline"].text() == "Pronto"
    assert page._cards["deepsproxy"]["headline"].text() == "Falta login"
    assert page._cards["mimo-ai-proxy"]["headline"].text() == "Falta chave da API"
    assert "Falta login" in page.state_label.text() or "Precisa preparar" in page.state_label.text()


def test_proxies_page_integrates_hermes_and_safe_odysseus_plan(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.hermes-status", "", {
        "installed": True,
        "ready": False,
        "configurationReady": True,
        "usageBlocked": True,
        "blockedReason": "connection-grant-not-enforceable",
        "version": "0.20.5",
        "auth": {"configured": False},
    })
    hermes = page._gateway_rows["hermes"]
    assert hermes["use"].text() == "Uso bloqueado"
    assert not hermes["use"].isEnabled()
    assert "grant por conexão" in hermes["detail"].text()
    with patch.object(page, "run_action") as run_action:
        page._gateway_use("hermes")
    run_action.assert_not_called()
    page._proxy_status_ready("ai.odysseus-status", "", {
        "installed": False, "ready": False, "podmanRootless": True,
    })
    odysseus = page._gateway_rows["odysseus"]
    assert odysseus["use"].text() == "Ver plano"


def test_proxies_page_blocks_9router_dashboard_when_healthy(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.9router-status", "", {
        "installed": True, "healthy": True, "service": "active",
    })
    router = page._gateway_rows["9router"]
    assert router["use"].text() == "Bloqueado"
    assert not router["use"].isEnabled()
    assert "sem grant por requisição" in router["use"].toolTip()
    with patch.object(page, "run_action") as run_action:
        router["use"].click()
        page._gateway_use("9router")
    run_action.assert_not_called()
    assert not any(button.text() == "Gerenciar providers" for button in page.findChildren(QPushButton))


def test_proxies_page_blocks_odysseus_workspace_when_healthy(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.odysseus-status", "", {
        "installed": True, "configured": True, "healthy": True, "service": "active",
    })
    odysseus = page._gateway_rows["odysseus"]
    assert odysseus["use"].text() == "Bloqueado"
    assert not odysseus["use"].isEnabled()
    assert "sem grant por requisição" in odysseus["use"].toolTip()
    with patch.object(page, "run_action") as run_action:
        odysseus["use"].click()
        page._gateway_use("odysseus")
    run_action.assert_not_called()


def test_proxies_page_catalogues_redacted_auth_without_account_identity(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.auth-registry", "", {
        "summary": {
            "total": 7, "ready": 4, "attention": 2,
            "missingEssential": 0, "accounts": 12,
        },
        "entries": [
            {"id": "gateway:9router", "label": "9Router", "ready": True},
            {"id": "client:opencode", "label": "OpenCode", "ready": True},
            {"id": "provider:xai", "label": "XAI", "ready": True},
            {"id": "provider:codex", "label": "CODEX", "ready": False},
            {"id": "proxy:mimo-ai-proxy", "label": "Mimo Proxy", "ready": False},
            {"id": "workspace:hermes", "label": "Hermes", "ready": False},
            {"id": "workspace:odysseus", "label": "Odysseus", "ready": True,
             "usageBlocked": True, "blockedReason": "connection-grant-not-enforceable"},
        ],
        "secretsRedacted": True,
    })
    assert "12 contas catalogadas" in page.auth_summary.text()
    assert "CODEX" in page._auth_group_labels["providers"].text()
    assert "Mimo Proxy" in page._auth_group_labels["proxies"].text()
    assert "uso bloqueado: Odysseus" in page._auth_group_labels["workspaces"].text()
    rendered = " ".join(label.text() for label in page._auth_group_labels.values())
    assert "@" not in rendered and "token" not in rendered.casefold()


def test_auth_probe_failure_does_not_render_zero_accounts(proxies_page):
    page, _actions = proxies_page
    page._proxy_status_ready("ai.auth-registry", "", {
        "summary": {"total": 1, "ready": 0, "attention": 0,
                    "missingEssential": 0, "accounts": None},
        "entries": [{"id": "gateway:9router", "label": "9Router", "ready": None,
                     "status": "unknown"}],
        "probes": {"router": "timeout", "providers": "backend-unavailable"},
        "secretsRedacted": True,
    })
    assert "Verificação parcial" in page.auth_summary.text()
    assert "contas não informadas" in page.auth_summary.text()
    assert "Status indisponível" in page._auth_group_labels["providers"].text()


def test_interrupted_operation_can_retry_only_through_confirmation_flow(
    qapp, by_id, tmp_path, monkeypatch,
):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    operations = tmp_path / "state" / "phasezero" / "control-center" / "operations"
    ledger = OperationLedger(operations)
    ledger.begin(by_id["ai.proxies-ensure-mimo"], preview=False)
    ledger.finish(exit_code=1)
    page = ResultsPage(ROOT, CommandRunner(ROOT), [], by_id=by_id)
    page.build()
    page.reload()
    assert page.table is not None and page.table.rowCount() == 1
    page.table.selectRow(0)
    qapp.processEvents()
    assert page.retry_button is not None and page.retry_button.isEnabled()
    requested = []
    page.action_requested.connect(lambda action: requested.append(action.id))
    page.retry_button.click()
    assert requested == ["ai.proxies-ensure-mimo"]


def test_ai_dev_page_covers_all_catalog_actions(ai_dev_page):
    page, actions = ai_dev_page
    assert page.represented_action_ids == {action.id for action in actions}


def test_ai_dev_app_shortcut_opens_canonical_detail_instead_of_running_directly(ai_dev_page):
    page, _actions = ai_dev_page
    selected = []
    requested = []
    page.action_selected.connect(lambda action: selected.append(action.id))
    page.action_requested.connect(lambda action: requested.append(action.id))

    opencode_card = next(
        card for card in page.findChildren(QWidget)
        if card.property("cliKey") == "opencode"
    )
    configure = next(
        button for button in opencode_card.findChildren(QPushButton)
        if button.text() == "Verificar"
    )
    configure.click()
    assert selected == ["ai.opencode-verify"]
    assert requested == []


def test_ai_dev_page_hero_uses_status_payload(ai_dev_page):
    page, _actions = ai_dev_page
    page._on_status_ready("ai.status", "", {
        "mode": "degraded",
        "clis": {"opencode": {"available": False}, "claude": {"available": True}},
        "mcp": {},
        "agentCompat": {"mode": "degraded"},
        "recommendations": ["linux/pz ai setup opencode"],
    })
    assert page.state_label.text() == "● Falta configurar"
    assert "Reparar ambiente" in page.repair_button.text()
    assert "não configurado" in page._status_labels["opencode"].text()
    assert "Instalado" in page._status_labels["claude"].text()
    assert "linux/pz" not in page.state_detail.text()


def test_ai_dev_optional_tools_do_not_make_essential_stack_incomplete(ai_dev_page):
    page, _actions = ai_dev_page
    page._on_status_ready("ai.status", "", {
        "mode": "degraded",
        "clis": {"opencode": {"available": True}, "claude": {"available": False}},
        "mcp": {},
        "agentCompat": {"mode": "degraded"},
        "recommendations": ["linux/pz ai setup hermes", "linux/pz ai odysseus install"],
        "setupCatalog": {
            "essentials": [
                {"label": "OpenCode", "state": "ready"},
                {"label": "9Router", "state": "ready"},
                {"label": "Memória", "state": "ready"},
                {"label": "MCPs", "state": "ready"},
            ],
            "optional": [
                {"label": "Hermes", "state": "optional"},
                {"label": "Odysseus", "state": "optional"},
            ],
        },
    })
    assert page.state_label.text() == "● Pronto"
    assert "opcionais" in page.state_detail.text()


def test_routing_hides_technical_surfaces_in_simple_mode(routing_page):
    page, _actions = routing_page
    boxes = page.findChildren(QGroupBox)
    titles = {box.title() for box in boxes}
    assert "Cadeia sugerida (somente leitura)" in titles
    assert "Rollback transacional" in titles
    for widget in page._technical_widgets:
        assert widget.isHidden()
    page.set_advanced_mode(True)
    for widget in page._technical_widgets:
        assert not widget.isHidden()


def test_routing_preview_keeps_policy_and_apply_is_blocked(routing_page):
    page, _actions = routing_page
    policy = page._policy_combo
    policy.setCurrentIndex(policy.findData("privacy"))
    requested = []
    page.action_requested.connect(lambda action: requested.append(action))
    page._task_preview("code")
    page._apply_all()
    assert len(requested) == 1
    assert requested[0].args == (
        "ai", "routing", "apply", "--task", "code", "--policy", "privacy", "--dry-run",
    )
    assert page._apply_all_button is not None and not page._apply_all_button.isEnabled()
    assert not any(button.text() == "Aplicar ordem" for button in page.findChildren(QPushButton))
    assert "conexão autorizada" in page._apply_gate_notice.text()


def test_routing_recommendations_populate_fallback_but_keep_apply_blocked(routing_page):
    page, _actions = routing_page
    recommendation = [
            {
                "model_id": "provider/model-a", "score": 0.9,
                "justifications": ["boa qualidade"], "quota_state": "known",
                "quota": 0.8, "quota_confidence": 1.0,
            },
            {
                "model_id": "provider/model-b", "score": 0.7,
                "justifications": [], "quota_state": "unknown",
                "quota": 0.5, "quota_confidence": 0.4,
            },
        ]
    for task in ("code", "analysis", "plan"):
        page._routing_status_ready(
            f"routing.dynamic.{task}.balanced", "", {"recommendation": recommendation},
        )
    card = page._task_cards["code"]
    assert not page._apply_all_button.isEnabled()
    assert page._chain_editor.count() == 2
    assert page._chain_editor.item(0).text() == "provider/model-a"
    assert "cota: conhecida" in card["quota"].text()


def test_routing_quota_ui_shows_provenance_without_presenting_estimate_as_fact(routing_page):
    page, _actions = routing_page
    page._routing_status_ready("ai.routing-inventory", "", {
        "connections": [{
            "provider": "glm", "quotaState": "unknown", "quota": {
                "source": "9router_usage_api", "observedAt": "2026-09-24T12:00:00Z",
                "buckets": [{"dimension": "session", "unit": "unknown",
                             "remainingPercentage": None,
                             "estimatedRemainingPercentage": 75,
                             "resetAt": "2026-09-26T12:00:00Z"}],
            },
        }],
    })
    assert "fonte: 9Router Usage API" in page._quota_details.text()
    assert "consultada em: 2026-09-24T12:00:00Z" in page._quota_details.text()
    assert "unidade desconhecida" in page._quota_details.text()
    assert "estimativa local 75%" in page._quota_details.text()
    assert "reinicia em 2026-09-26T12:00:00Z" in page._quota_details.text()

    recommendation = [{"model_id": "provider/model-a", "score": 0.9,
                       "quota_state": "unknown", "quota": 0.5,
                       "quota_confidence": 0.4}]
    page._routing_status_ready("routing.dynamic.code.balanced", "", {"recommendation": recommendation})
    assert "desconhecida" in page._task_cards["code"]["quota"].text()
    assert "50%" not in page._task_cards["code"]["quota"].text()


def test_routing_quota_ui_hides_invalid_numeric_metadata(routing_page):
    page, _actions = routing_page
    page._routing_status_ready("ai.routing-inventory", "", {
        "connections": [{
            "provider": "glm", "quotaState": "known", "quota": {
                "source": "9router_usage_api", "observedAt": "yesterday",
                "buckets": [{
                    "dimension": "", "unit": 2, "remaining": float("nan"),
                    "remainingPercentage": True,
                    "estimatedRemainingPercentage": float("inf"),
                    "resetAt": "tomorrow",
                }],
            },
        }],
    })
    details = page._quota_details.text()
    assert "percentual não informado" in details
    assert "valor restante indisponível" in details
    assert "dimensão desconhecida" in details
    assert "unidade desconhecida" in details
    assert "cota desconhecida" in details
    assert "horário indisponível" in details
    assert "tomorrow" not in details
    assert "nan" not in details.lower()
    assert "estimativa local inf%" not in details.lower()


def test_routing_quota_poll_is_visible_read_only_and_never_calls_recommendation(routing_page, monkeypatch):
    page, _actions = routing_page
    calls = []
    monkeypatch.setattr(page.status_loader, "fetch_action", lambda action: calls.append(action.id))
    monkeypatch.setattr(page.status_loader, "running", lambda _action_id: False)
    monkeypatch.setattr(page, "_fetch_recommendations", lambda: calls.append("recommendation"))

    page.show()
    page.reload()
    assert page._quota_poll.isActive()
    calls.clear()
    page._poll_quota_inventory()
    assert calls == ["ai.routing-inventory"]
    action = page.by_id["ai.routing-inventory"]
    assert "--refresh-quota" in action.args
    assert "inference" not in " ".join(action.args).lower()
    page.hide()
    assert not page._quota_poll.isActive()


def test_routing_dynamic_failure_never_stays_verifying(routing_page):
    page, _actions = routing_page
    page._routing_status_failed("routing.dynamic.analysis.quality", "timeout")
    card = page._task_cards["analysis"]
    assert card["recommended"].text() == "Recomendação indisponível"
    assert not page._apply_all_button.isEnabled()


def test_ensure_status_severity_is_honest():
    assert severity_for({"status": "ready"}, 0) == "success"
    assert severity_for({"status": "needs-login"}, 0) == "warning"
    assert severity_for({"status": "needs-credentials"}, 0) == "warning"
    assert severity_for({"status": "gui-required"}, 0) == "warning"
    assert severity_for({"status": "error"}, 0) == "error"


def test_incomplete_structured_result_is_not_success():
    result = OperationResult(
        action_id="ai.proxies-ensure-qwen",
        command=["pz", "ai", "proxies", "ensure", "qwenproxy"],
        preview=False,
        exit_code=0,
        started_at="t0",
        finished_at="t1",
        stdout="",
        stderr="",
        parsed={"ok": False, "status": "needs-login", "resumable": True},
    )
    assert result.ok is False


def test_result_dialog_prefers_json_summary(qapp):
    result = OperationResult(
        action_id="ai.proxies-ensure-qwen",
        command=["pz", "ai", "proxies", "ensure", "qwenproxy"],
        preview=False,
        exit_code=0,
        started_at="t0",
        finished_at="t1",
        stdout='{"summary":"Uma janela do navegador abriu para o login do Qwen.","next":"Conclua o login."}',
        stderr="INFO: npm ci",
        parsed={
            "summary": "Uma janela do navegador abriu para o login do Qwen.",
            "next": "Conclua o login.",
            "status": "needs-login",
        },
    )
    dialog = ResultDialog(result, "raw", None, severity="warning", advanced_mode=False)
    assert "Uma janela do navegador abriu" in dialog.summary_label.text()
    assert "Conclua o login" in dialog.summary_label.text()
    assert "npm ci" not in dialog.summary_label.text()


def test_preview_dialog_uses_ensure_summary(qapp):
    result = OperationResult(
        action_id="ai.proxies-ensure-qwen",
        command=["pz", "ai", "proxies", "ensure", "qwenproxy", "--dry-run"],
        preview=True,
        exit_code=0,
        started_at="t0",
        finished_at="t1",
        stdout="",
        stderr="",
        parsed={
            "summary": "Vai instalar o Qwen, abrir o navegador para login e iniciar o serviço.",
            "next": "Uma janela do Chromium abre para você entrar na conta.",
            "dryRun": True,
        },
    )
    dialog = PreviewDialog(result, None, None, advanced_mode=False)
    labels = [child.text() for child in dialog.findChildren(QLabel) if child.text()]
    assert any("Vai instalar o Qwen" in text for text in labels)
    assert dialog.technical.isHidden()


def test_crash_looping_proxy_is_not_shown_as_running():
    # AISR-002: a unit restarting forever is "active" for systemd between crashes.
    from linux.ui_native.pages.ai_proxies import _friendly_proxy_copy

    state = ProxyState(id="qwenproxy", installed=True, service="crash-loop", auth_status="session-present")
    assert not state.running
    assert state.service_label == "reiniciando sem parar"
    headline, _detail, severity = _friendly_proxy_copy(state)
    assert headline == "Falhando ao iniciar"
    assert severity == "error"


def test_routing_status_text_reports_provider_availability():
    # AISR-014: "Online" alone hid that 15 of 16 providers were down.
    from linux.ui_native.pages.ai_routing import routing_status_text

    assert routing_status_text({"health": False}) == "Indisponível"
    assert routing_status_text({"health": True}) == "Online"
    degraded = {"health": True, "providerAvailability": {"state": "degraded", "ready": 1, "total": 16}}
    assert routing_status_text(degraded) == "Online, 1 de 16 provedores disponíveis"
    down = {"health": True, "providerAvailability": {"state": "down", "ready": 0, "total": 3}}
    assert "sem provedor disponível" in routing_status_text(down)
