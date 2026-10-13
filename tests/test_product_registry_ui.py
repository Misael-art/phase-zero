from __future__ import annotations

import hashlib
import os
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import QColor, QPalette
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (
    QApplication, QComboBox, QLabel, QPushButton, QScrollArea, QStyleFactory,
)
from linux.ui_native.models import ProductInstance
from linux.ui_native.product_inventory import target_for

ROOT = Path(__file__).resolve().parents[1]

from linux.ui_native.widgets import ActionListRow


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    patcher = patch.object(MainWindow, "_host_summary")
    patcher.start()
    # Page initialization can call fetch() directly. Keep these UI tests from
    # starting host probes; tests that assert a fetch override it per instance.
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch", return_value=None)
    status_patcher.start()
    # Homelab schedules its own QProcess probe from build(), outside StatusLoader.
    # Capture a no-op callback during construction so layout tests stay hermetic.
    with patch("linux.ui_native.pages.homelab.HomelabPage.refresh_hosts", lambda _self: None):
        window = MainWindow(ROOT)
    return window, patcher, status_patcher


def _detail_action_rows(page):
    rows = []
    for index in range(page._detail_actions_start, page._detail_layout.count()):
        widget = page._detail_layout.itemAt(index).widget()
        if isinstance(widget, ActionListRow):
            rows.append(widget)
    return rows


def _detail_action_ids(page):
    row_ids = [row.action.id for row in _detail_action_rows(page)]
    advanced_ids = [
        str(button.property("actionId"))
        for button in page._detail_page.findChildren(QPushButton)
        if button.objectName() == "advancedAction" and button.property("actionId")
    ]
    return set(row_ids + advanced_ids)


@pytest.mark.parametrize("action_id", ["ai.ollama", "server.llm"])
def test_legacy_app_routes_open_same_product_and_preserve_context(qapp, action_id):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.search.setText("Ollama")
        row = next(row for row in window._search_cards if row.action.id == action_id)
        row.selected.emit(row.action)
        page = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is page
        assert page.selected_app_id == "app.ollama"
        assert page.context_action_id == action_id
        assert "Ollama" in window.page_title.text()
        assert "Atalho de origem" in page._context_label.text()
        assert page._status_label.text() == "Instalação, configuração e saúde: desconhecidas"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_product_detail_discards_context_action_for_another_app(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        unrelated_action_id = next(
            action_id for action_id, target in page._targets.items()
            if target.target_kind == "app" and target.target_id != "app.ollama"
        )

        page.open_product("app.ollama", unrelated_action_id)

        assert page.selected_app_id == "app.ollama"
        assert page.context_action_id == ""
        assert page._context_label.text() == "Catálogo de aplicativos"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_opening_product_resets_detail_scroll_to_top(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.resize(800, 600)
        window.show_category("Aplicativos")
        window.show()
        qapp.processEvents()
        page = window.registry.page_for("Aplicativos")
        scroll = page.findChild(QScrollArea, "productDetailScroll")
        assert scroll is not None
        with patch.object(page.status_loader, "fetch_product_status"):
            page.open_product("app.ollama")
            qapp.processEvents()
            content = scroll.widget()
            assert content is not None
            # Keep this state test independent of font/theme metrics that can
            # make the current product fit the viewport in a larger full-suite
            # window. Hit-test/reflow tests cover natural content geometry.
            content.setMinimumHeight(scroll.viewport().height() + 80)
            qapp.processEvents()
            assert scroll.verticalScrollBar().maximum() > 0
            scroll.verticalScrollBar().setValue(scroll.verticalScrollBar().maximum())
            assert scroll.verticalScrollBar().value() > 0
            page.open_product("app.usagebar")
            qapp.processEvents()
        assert scroll.verticalScrollBar().value() == 0
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_product_detail_back_returns_to_search_context(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.search.setText("Ollama")
        search_page = window.search_page
        row = next(row for row in window._search_cards if row.action.id == "server.llm")
        row.selected.emit(row.action)
        page = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is page
        back = page.findChild(QPushButton, "productDetailBack")
        assert back is not None
        back.click()
        assert window.stack.currentWidget() is search_page
        assert window.search.text() == "Ollama"
        assert window.page_title.text() == "Busca"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_legacy_page_action_routes_to_detail_and_detail_keeps_execute_path(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Servidor")
        action = window.registry.by_id["server.llm"]
        server_page = window.registry.page_for("Servidor")
        window.inspect_action(action)
        products = window.registry.page_for("Aplicativos")
        assert window.stack.currentWidget() is products
        assert products.selected_app_id == "app.ollama"
        assert products.context_action_id == "server.llm"
        assert products._primary_button.text() == "Verificar"
        assert not any(row.action.id == "server.llm" for row in _detail_action_rows(products))
        products._instances_ready(products._status_action_id, (ProductInstance(
            "local:host:app.ollama", "app.ollama", "local", "host",
            installation="absent",
        ),))
        row = next(row for row in products.findChildren(ActionListRow) if row.action.id == "server.llm")
        with patch.object(window.runner, "start") as start:
            row.selected.emit(row.action)
        start.assert_called_once()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_every_app_action_resolves_to_canonical_detail_with_source_context(qapp):
    from linux.ui_native.product_inventory import target_for

    window, host_patcher, status_patcher = _window(qapp)
    routes = []
    try:
        product_page = window.registry.page_for("Aplicativos")
        expected = {
            action.id: target_for(action).target_id
            for action in window.registry.by_id.values()
            if target_for(action).target_kind == "app"
        }
        window.open_product = lambda app_id, context_action_id="": routes.append(
            (app_id, context_action_id)
        )
        for action_id in expected:
            window.inspect_action(window.registry.by_id[action_id])

        assert set(expected.values()) == {
            product["appId"] for product in product_page.products
        }
        assert routes == [(expected[action_id], action_id) for action_id in expected]
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_registry_has_all_manifest_products_and_unknown_is_not_absent(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        assert page.__class__.__name__ == "ProductRegistryPage"
        assert len(page.products) == 103
        assert page._product_by_id["app.ollama"]["canonicalActionId"] == "ai.ollama"
        window.open_product("app.ollama", "server.llm")
        assert not page.instances
        assert "desconhecidas" in page._status_label.text()
        assert page._detail_layout.indexOf(page._status_label) >= 0
        assert "ai.ollama" not in _detail_action_ids(page)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_unknown_status_hides_every_mutating_secondary_app_action(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        for product in page.products:
            page.open_product(product["appId"])
            mutable_ids = {
                action_id for action_id in product["actionIds"]
                if action_id in window.registry.by_id
                and window.registry.by_id[action_id].mutable
            }
            visible_mutations = _detail_action_ids(page) & mutable_ids
            assert not visible_mutations, (product["appId"], visible_mutations)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_claude_detail_explains_grant_gate_and_never_offers_bonsai_run(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.claude-code")
        notice = page.findChild(QLabel, "accountGrantNotice")
        assert notice is not None and not notice.isHidden()
        assert "grant registrado" in notice.text()
        assert "conexão aprovada" in notice.text()
        assert "ai.claude-bonsai-run" not in _detail_action_ids(page)

        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:host:app.claude-code", "app.claude-code", "local", "local",
            manager="phasezero-claude-code", installation="present", origin="phasezero",
            configuration="ready", health="online",
        ),))
        assert page._primary_action is None or page._primary_action.id != "ai.claude-bonsai-run"
        assert "ai.claude-bonsai-run" not in _detail_action_ids(page)
        assert not notice.isHidden()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_external_installation_hides_every_mutating_secondary_app_action(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        for product in page.products:
            page.open_product(product["appId"])
            page._instances_ready(page._status_action_id, (ProductInstance(
                f"external:{product['appId']}", product["appId"], "local", page._status_scope,
                manager="external", installation="present", origin="external",
                configuration="unknown", health="offline",
            ),))
            mutable_ids = {
                action_id for action_id in product["actionIds"]
                if action_id in window.registry.by_id
                and window.registry.by_id[action_id].mutable
            }
            visible_mutations = _detail_action_ids(page) & mutable_ids
            assert not visible_mutations, (product["appId"], visible_mutations)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_unknown_status_hides_secondary_open_and_dashboard_actions(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        for product in page.products:
            page.open_product(product["appId"])
            open_ids = {
                action_id for action_id in product["actionIds"]
                if action_id in window.registry.by_id
                and ({"open", "launch", "dashboard"} & {
                    *action_id.casefold().split("."),
                    *(arg.casefold() for arg in window.registry.by_id[action_id].args),
                })
            }
            visible_open_routes = _detail_action_ids(page) & open_ids
            assert not visible_open_routes, (product["appId"], visible_open_routes)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_product_search_indexes_purpose_synonyms(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page._filter_products("chat local")
        assert not page._cards["app.ollama"].isHidden()
        assert page._cards["app.vscode"].isHidden()

        page._filter_products("agente de código")
        assert not page._cards["app.claude-code"].isHidden()
        assert not page._cards["app.opencode"].isHidden()
        assert page._cards["app.ollama"].isHidden()

        page._filter_products("programar")
        assert not page._cards["app.vscode"].isHidden()
        assert not page._cards["app.vscodium"].isHidden()
        assert page._cards["app.ollama"].isHidden()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_comparison_only_enables_curated_functional_alternatives(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        assert "app.vscode" in page._compare_checks
        assert "app.vscodium" in page._compare_checks
        assert "app.ollama" not in page._compare_checks
        page._compare_checks["app.vscode"].setChecked(True)
        page._compare_checks["app.vscodium"].setChecked(True)
        assert page._compare_button.isEnabled()
        page._compare_button.click()
        assert any(
            "Comparar Visual Studio Code e VSCodium" in label.text()
            for label in page._comparison_page.findChildren(QLabel)
        )
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_primary_action_waits_for_observed_state_then_prepares_absent_app(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode", "capability.plan.development.vscode")
        assert page._primary_button.text() == "Verificar"
        assert page._primary_button.isEnabled()
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:host:app.vscode", "app.vscode", "local", "host",
            installation="absent",
        ),))
        assert page._primary_button.text() == "Preparar"
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.kwargs["preview"] is True
        assert start.call_args.args[0].id == "capability.plan.development.vscode"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_primary_open_uses_installed_desktop_entry_without_shell(qapp, tmp_path, monkeypatch):
    from linux.ui_native.main_window import QProcess

    window, host_patcher, status_patcher = _window(qapp)
    try:
        apps = tmp_path / "applications"
        apps.mkdir()
        entry = apps / "com.visualstudio.code.desktop"
        entry.write_text("[Desktop Entry]\nType=Application\nName=VS Code\n", encoding="utf-8")
        monkeypatch.setattr("linux.ui_native.pages.product_registry.desktop_dirs", lambda: (apps,))
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "host:app.vscode", "app.vscode", "local", "host",
            installation="present", origin="external", configuration="ready", health="online",
        ),))
        assert page._primary_button.text() == "Abrir"
        assert page._primary_button.isEnabled()
        with patch.object(QProcess, "startDetached", return_value=(True, 42)) as start:
            page._primary_button.click()
        start.assert_called_once_with("gio", ["launch", str(entry)])
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_managed_desktop_opens_when_launcher_is_ready_and_runtime_health_unknown(
    qapp, tmp_path, monkeypatch,
):
    from linux.ui_native.main_window import QProcess
    from linux.ui_native.product_inventory import instances_from_status_payload

    window, host_patcher, status_patcher = _window(qapp)
    try:
        apps = tmp_path / "applications"
        apps.mkdir()
        entry = apps / "claude-desktop.desktop"
        entry.write_text("[Desktop Entry]\nType=Application\nName=Claude Desktop\n", encoding="utf-8")
        monkeypatch.setattr("linux.ui_native.pages.product_registry.desktop_dirs", lambda: (apps,))
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.claude-desktop")
        observed = instances_from_status_payload({
            "hasStatus": True, "installationState": "present", "origin": "phasezero",
            "configurationState": "ready", "health": "unknown", "launchable": True,
        }, app_id="app.claude-desktop", host_id="local", scope="local")
        page._instances_ready(page._status_action_id, observed)
        assert "Saúde: unknown" in page._status_label.text()
        assert page._primary_button.text() == "Abrir"
        assert page._primary_button.isEnabled()
        with patch.object(QProcess, "startDetached", return_value=(True, 42)) as start:
            page._primary_button.click()
        start.assert_called_once_with("gio", ["launch", str(entry)])
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_open_webui_status_keeps_usage_blocked_without_request_grants(qapp, tmp_path, monkeypatch):
    apps = tmp_path / "applications"
    apps.mkdir()
    (apps / "open-webui.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=Open WebUI\n", encoding="utf-8",
    )
    monkeypatch.setattr("linux.ui_native.pages.product_registry.desktop_dirs", lambda: (apps,))
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.open-webui")
        assert page._status_action_id == "ai.webui-status"
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.open-webui", "app.open-webui", "local", "local",
            installation="present", origin="unknown", configuration="ready", health="online",
            usage_blocked=True, blocked_reason="connection-grant-not-enforceable",
        ),))
        assert page._primary_button.text() == "Uso bloqueado"
        assert not page._primary_button.isEnabled()
        assert page._primary_action is None
        assert page._primary_desktop_entry == ""
        assert page._primary_button.toolTip() == (
            "Uso bloqueado: Open WebUI pode salvar conexões de provedores, mas não vincula "
            "cada inferência a um grant PhaseZero."
        )
        assert not {"ai.webui", "ai.webui-open"}.intersection(_detail_action_ids(page))
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()
        assert "Ação: uso bloqueado" in page._status_label.text()

        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.open-webui", "app.open-webui", "local", "local",
            installation="present", origin="unknown", configuration="ready", health="offline",
            usage_blocked=True, blocked_reason="connection-grant-not-enforceable",
        ),))
        assert page._primary_button.text() == "Uso bloqueado"
        assert not page._primary_button.isEnabled()
        assert "ai.webui-open" not in _detail_action_ids(page)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_resolve_uses_read_only_diagnostic_and_never_starts_external_proxy(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.9router")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.9router", "app.9router", "local", "local",
            installation="present", origin="external", configuration="ready", health="failed",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.9router-doctor"
        assert not page._primary_action.mutable
        assert not _detail_action_ids(page).intersection({
            "ai.9router-install", "ai.9router-repair",
        })
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.9router-doctor"

        page.open_product("app.qwen-proxy")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.qwen-proxy", "app.qwen-proxy", "local", "local",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


@pytest.mark.parametrize(
    ("app_id", "diagnostic_id"),
    (("app.claude-code", "ai.claude-verify"), ("app.codexbar", "ai.codexbar-health")),
)
def test_resolve_exposes_read_only_verify_and_health_diagnostics_for_external_apps(
    qapp, app_id, diagnostic_id,
):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product(app_id)
        page._instances_ready(page._status_action_id, (ProductInstance(
            f"external:local:{app_id}", app_id, "local", "local",
            manager="external", installation="present", origin="external",
            configuration="ready", health="failed",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == diagnostic_id
        assert not page._primary_action.mutable
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == diagnostic_id
        assert start.call_args.kwargs["preview"] is False
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_hermes_detail_uses_local_status_and_read_only_recovery(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.hermes")
        assert page._status_action_id == "ai.hermes-status"
        assert page._status_scope == "local"
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.hermes", "app.hermes", "local", "local",
            installation="present", origin="unknown", configuration="ready", health="offline",
            usage_blocked=True, blocked_reason="connection-grant-not-enforceable",
        ),))
        assert page._primary_button.text() == "Uso bloqueado"
        assert not page._primary_button.isEnabled()
        assert page._primary_action is None
        assert any(row.action.id == "ai.hermes-doctor" for row in _detail_action_rows(page))
        assert "server.hermes.start" not in {
            row.action.id for row in _detail_action_rows(page)
        }
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_proxy_resolver_stays_blocked_until_request_bound_grant(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.qwen-proxy")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.qwen-proxy:managed", "app.qwen-proxy", "local", "local",
            manager="phasezero-ai-proxy-suite", installation="present", origin="phasezero",
            configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()
        warning = page.findChild(QLabel, "accountGrantNotice")
        assert warning is not None and not warning.isHidden()

        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.qwen-proxy:login", "app.qwen-proxy", "local", "local",
            manager="phasezero-ai-proxy-suite", installation="present", origin="phasezero",
            configuration="needed", health="online",
        ),))
        assert page._primary_button.text() == "Configurar"
        assert page._primary_action.id == "ai.proxies-login-qwen"
        assert "não testa inferência nem inicia o serviço" in page._primary_action.description
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.proxies-login-qwen"
        assert start.call_args.kwargs["preview"] is True

        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.qwen-proxy", "app.qwen-proxy", "local", "local",
            manager="external", installation="present", origin="phasezero",
            configuration="ready", health="offline",
        ),))
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
        visible_ids = _detail_action_ids(page)
        assert not visible_ids.intersection({
            "ai.proxies-ensure-qwen", "ai.proxies-start-qwen",
            "ai.proxies-open-qwen", "ai.proxies-credentials-mimo",
        })

        page._instances_ready(page._status_action_id, (ProductInstance(
            "unknown-manager:local:app.qwen-proxy", "app.qwen-proxy", "local", "local",
            manager="unknown", installation="present", origin="phasezero",
            configuration="needed", health="online",
        ),))
        assert page._primary_button.text() == "Configurar"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_external_proxy_instances_hide_every_manager_control(qapp):
    from linux.ui_native.pages.product_registry import _PROXY_INSTANCE_CONTROL_ACTIONS_BY_APP

    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        for app_id, controls in _PROXY_INSTANCE_CONTROL_ACTIONS_BY_APP.items():
            page.open_product(app_id)
            page._instances_ready(page._status_action_id, (ProductInstance(
                f"external:{app_id}", app_id, "local", "local",
                manager="external", installation="present", origin="external",
                configuration="unknown", health="unknown",
            ),))
            assert not _detail_action_ids(page).intersection(controls), app_id
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_multiple_instances_require_explicit_local_scope_selection(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                "local:host:app.vscode:host-default", "app.vscode", "local", "host",
                installation="absent",
            ),
            ProductInstance(
                "homelab:host:app.vscode", "app.vscode", "homelab", "host",
                installation="present", origin="phasezero", configuration="ready", health="online",
            ),
        ))
        selector = page.findChild(QComboBox, "productInstanceSelector")
        assert selector is not None and selector.count() == 3
        assert page._status_label.text().startswith("2 instâncias observadas")
        assert page._primary_button.text() == "Selecionar instância"
        assert not page._primary_button.isEnabled()
        assert not _detail_action_rows(page)

        local_index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:host:app.vscode:host-default"
        )
        selector.setCurrentIndex(local_index)
        assert "Instância: local · escopo host" in page._status_label.text()
        assert page._primary_button.text() == "Preparar"
        assert page._primary_button.isEnabled()
        assert page._primary_action.id == "capability.plan.development.vscode"
        rows = _detail_action_rows(page)
        assert rows
        assert all(target_for(row.action).instance_scope == "host" for row in rows)

        remote_index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "homelab:host:app.vscode"
        )
        selector.setCurrentIndex(remote_index)
        assert page._primary_button.text() == "Abrir"
        assert not page._primary_button.isEnabled()
        assert "executor vinculado" in page._primary_button.toolTip()
        assert not _detail_action_rows(page)
        notice = page.findChild(QLabel, "productInstanceActionNotice")
        assert notice is not None and "remotas" in notice.text()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_duplicate_instances_in_same_scope_block_unscoped_actions(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        from linux.ui_native.product_inventory import instances_from_status_payload

        instances = instances_from_status_payload({
            "hasStatus": True,
            "instances": [
                {"instanceKey": "first", "installationState": "absent"},
                {"instanceKey": "second", "installationState": "present", "origin": "phasezero",
                 "configurationState": "ready", "health": "online"},
            ],
        }, app_id="app.vscode", host_id="local", scope="host")
        page._instances_ready(page._status_action_id, instances)
        selector = page.findChild(QComboBox, "productInstanceSelector")
        index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:host:app.vscode:first"
        )
        selector.setCurrentIndex(index)
        assert page._primary_button.text() == "Preparar"
        assert not page._primary_button.isEnabled()
        assert "mesmo host e escopo" in page._primary_button.toolTip()
        notice = page.findChild(QLabel, "productInstanceActionNotice")
        assert notice is not None and "várias instâncias neste escopo" in notice.text()
        assert not _detail_action_rows(page)
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_duplicate_instance_ids_are_reported_ambiguous_and_block_actions(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.qwen-proxy")
        duplicate_id = "local:host:app.qwen-proxy"
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                duplicate_id, "app.qwen-proxy", "local", "host",
                manager="phasezero-ai-proxy-suite", installation="present",
                origin="phasezero", configuration="ready", health="offline",
            ),
            ProductInstance(
                duplicate_id, "app.qwen-proxy", "local", "host",
                manager="external", installation="present",
                origin="external", configuration="unknown", health="offline",
            ),
        ))

        assert "IDs de instância repetidos" in page._status_label.text()
        assert page._primary_action is None
        assert page._primary_button.text() == "Verificar"
        assert page._primary_button.isEnabled()  # Only retrying read-only status remains.
        assert not _detail_action_ids(page).intersection({
            "ai.proxies-ensure-qwen", "ai.proxies-start-qwen",
            "ai.proxies-stop-qwen", "ai.proxies-login-qwen",
        })
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_verify_uses_selected_instance_scope(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.vscode")
        page._instances_ready(page._status_action_id, (
            ProductInstance(
                "local:host:app.vscode", "app.vscode", "local", "host",
                installation="unknown",
            ),
            ProductInstance(
                "local:project:app.vscode:project-default", "app.vscode", "local", "project",
                installation="unknown",
            ),
        ))
        selector = page.findChild(QComboBox, "productInstanceSelector")
        index = next(
            index for index in range(1, selector.count())
            if selector.itemData(index) == "local:project:app.vscode:project-default"
        )
        selector.setCurrentIndex(index)
        assert page._primary_button.text() == "Verificar"
        with patch.object(page.status_loader, "fetch_product_status") as fetch:
            page._primary_button.click()
        fetch.assert_called_once()
        assert fetch.call_args.kwargs["host_id"] == "local"
        assert fetch.call_args.kwargs["scope"] == "project"
        assert fetch.call_args.kwargs["instance_key"] == "project-default"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_remote_product_status_requires_registered_host_and_keeps_actions_blocked(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.usagebar")
        assert not page._host_context_panel.isHidden()
        with patch.object(page.status_loader, "fetch") as list_hosts:
            page._host_refresh_button.click()
            list_hosts.assert_called_once_with(
                "product.homelab-hosts", ["server", "homelab", "hosts", "list", "--json"],
            )
        alias = "garage"
        host_id = "hlh-" + hashlib.sha256(alias.encode()).hexdigest()[:12]
        page._status_ready("product.homelab-hosts", "", {
            "schemaVersion": "1",
            "tool": "homelab-hosts",
            "action": "list",
            "hosts": [
                {"id": host_id, "alias": alias, "user": "operator", "host": "192.0.2.1"},
                {"id": "hlh-000000000000", "alias": "forged", "user": "x", "host": "y"},
            ],
        })
        selector = page.findChild(QComboBox, "productHostSelector")
        assert selector is not None and selector.count() == 2
        selector.setCurrentIndex(1)
        assert selector.currentText() == "garage (Homelab)"

        with patch.object(page.status_loader, "fetch_product_status") as fetch:
            page.open_product("app.usagebar")
            fetch.assert_not_called()  # selecting a remote host never contacts it
            assert page._primary_button.text() == "Verificar remoto"
            assert page._primary_button.isEnabled()
            page._primary_button.click()
            fetch.assert_called_once()
            assert fetch.call_args.kwargs["host_id"] == host_id
            assert fetch.call_args.kwargs["remote_alias"] == alias
            assert fetch.call_args.kwargs["instance_key"] == "default"
            assert not _detail_action_ids(page)
            assert page._primary_button.text() == "Verificando…"
            assert not page._primary_button.isEnabled()

        page._instances_ready(page._status_action_id, (
            ProductInstance(
                f"{host_id}:user:app.usagebar:default", "app.usagebar", host_id, "user",
                installation="unknown",
            ),
        ))
        assert page._primary_button.text() == "Atualizar status remoto"
        assert page._primary_button.isEnabled()
        notice = page.findChild(QLabel, "productInstanceActionNotice")
        assert notice is not None and "consulta read-only" in notice.text()
        assert not _detail_action_ids(page)

        page._status_ready("product.homelab-hosts", "", {
            "schemaVersion": "1", "tool": "homelab-hosts", "action": "list", "hosts": [],
        })
        assert selector.currentData() == "local"
        assert page.instances == ()
        assert page._status_label.text() == "Instalação, configuração e saúde: desconhecidas"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


@pytest.mark.parametrize("theme", ["dark", "light"])
def test_product_host_controls_fit_and_receive_pointer_at_supported_widths(qapp, theme):
    from linux.ui_native.tokens import DARK, LIGHT, font_scale, render_qss

    window = host_patcher = status_patcher = None
    try:
        window, host_patcher, status_patcher = _window(qapp)
        tokens = LIGHT if theme == "light" else DARK
        fusion_style = QStyleFactory.create("Fusion")
        assert fusion_style is not None
        fusion_style.setParent(window)
        window.setStyle(fusion_style)
        window.setStyleSheet(render_qss(tokens, font_scale(qapp.font().pointSizeF())))
        palette = QPalette()
        palette.setColor(QPalette.Window, QColor(tokens.bg))
        palette.setColor(QPalette.WindowText, QColor(tokens.text))
        palette.setColor(QPalette.Base, QColor(tokens.surface_inset))
        palette.setColor(QPalette.Text, QColor(tokens.text))
        palette.setColor(QPalette.Button, QColor(tokens.surface))
        palette.setColor(QPalette.ButtonText, QColor(tokens.text))
        palette.setColor(QPalette.Highlight, QColor(tokens.accent))
        palette.setColor(QPalette.HighlightedText, QColor(tokens.on_accent))
        window.setPalette(palette)
        window.show()
        window.resize(800, 600)
        window.show_category("Aplicativos")
        qapp.processEvents()
        page = window.registry.page_for("Aplicativos")
        page._search.setText("UsageBar")
        open_button = next(
            button for button in page.findChildren(QPushButton, "productOpenButton")
            if button.text() == "UsageBar"
        )
        QTest.mouseClick(open_button, Qt.LeftButton)
        qapp.processEvents()

        selector = page.findChild(QComboBox, "productHostSelector")
        refresh = page.findChild(QPushButton, "productHostRefresh")
        primary = page.findChild(QPushButton, "productPrimaryAction")
        detail_scroll = page.findChild(QScrollArea, "productDetailScroll")
        assert (
            selector is not None and refresh is not None and primary is not None
            and detail_scroll is not None
        )
        screen = qapp.primaryScreen().availableGeometry()
        screen_width = screen.width()
        require_hit_test = os.environ.get("PZ_REQUIRE_UI_HIT_TEST") == "1"
        if require_hit_test:
            assert screen.width() == int(os.environ["PZ_EXPECT_QSCREEN_WIDTH"])
            assert screen.height() == int(os.environ["PZ_EXPECT_QSCREEN_HEIGHT"])
            assert window.devicePixelRatioF() == pytest.approx(
                float(os.environ["PZ_EXPECT_DEVICE_SCALE"]), abs=0.01,
            )
        # Reflow narrow -> wide -> narrow; independent window instances can hide
        # stale geometry left behind when the user resizes back.
        for width, height in ((800, 600), (1280, 800), (800, 600)):
            window.resize(width, height)
            qapp.processEvents()
            viewport = QRect(window.mapToGlobal(QPoint(0, 0)), window.size())
            if require_hit_test:
                assert window.size().width() == width and window.size().height() == height
            for widget in (selector, refresh, primary):
                detail_scroll.ensureWidgetVisible(widget, 8, 8)
                qapp.processEvents()
                rect = QRect(widget.mapToGlobal(QPoint(0, 0)), widget.size())
                scroll_viewport = QRect(
                    detail_scroll.viewport().mapToGlobal(QPoint(0, 0)),
                    detail_scroll.viewport().size(),
                )
                assert widget.isVisible() and not widget.visibleRegion().isEmpty()
                assert widget.isEnabled()
                assert viewport.contains(rect), f"{theme} {width}x{height}: {widget.objectName()} fora do viewport"
                assert scroll_viewport.contains(rect), (
                    f"{theme} {width}x{height}: {widget.objectName()} fora da área rolável"
                )
                if require_hit_test:
                    assert width <= screen_width, (
                        f"screen width {screen_width} cannot hit-test {width}px viewport"
                    )
                    # The offscreen QPA may return an ancestor for widgetAt;
                    # strict pointer targeting belongs to the XCB/Xvfb CI job.
                    hit = qapp.widgetAt(widget.mapToGlobal(widget.rect().center()))
                    if hit is not widget and (hit is None or not widget.isAncestorOf(hit)):
                        def path(candidate):
                            rows = []
                            while candidate is not None:
                                rect = candidate.rect()
                                rows.append(
                                    f"{type(candidate).__name__}#{candidate.objectName()}"
                                    f"[{rect.x()},{rect.y()},{rect.width()},{rect.height()}]"
                                    f" transparent={candidate.testAttribute(Qt.WA_TransparentForMouseEvents)}"
                                )
                                candidate = candidate.parentWidget()
                            return " <- ".join(rows)

                        raise AssertionError(
                            f"{theme} {width}x{height}: {widget.objectName()} recebeu hit "
                            f"em {path(hit) if hit is not None else None}; "
                            f"alvo={path(widget)}"
                        )

        if require_hit_test:
            detail_scroll.ensureWidgetVisible(selector, 8, 8)
            qapp.processEvents()
            hit = qapp.widgetAt(selector.mapToGlobal(selector.rect().center()))
            assert hit is selector or (hit is not None and selector.isAncestorOf(hit))
            QTest.mouseClick(hit, Qt.LeftButton, pos=hit.rect().center())
            qapp.processEvents()
            assert selector.view().isVisible()
            selector.hidePopup()

            detail_scroll.ensureWidgetVisible(primary, 8, 8)
            qapp.processEvents()
            hit = qapp.widgetAt(primary.mapToGlobal(primary.rect().center()))
            assert hit is primary or (hit is not None and primary.isAncestorOf(hit))
            with patch.object(page.status_loader, "fetch_product_status") as fetch_status:
                QTest.mouseClick(hit, Qt.LeftButton, pos=hit.rect().center())
            fetch_status.assert_called_once()

        detail_scroll.ensureWidgetVisible(refresh, 8, 8)
        qapp.processEvents()
        with patch.object(page.status_loader, "fetch") as fetch:
            if require_hit_test:
                hit = qapp.widgetAt(refresh.mapToGlobal(refresh.rect().center()))
                assert hit is refresh or (hit is not None and refresh.isAncestorOf(hit))
                QTest.mouseClick(hit, Qt.LeftButton, pos=hit.rect().center())
            else:
                QTest.mouseClick(refresh, Qt.LeftButton)
        fetch.assert_called_once_with(
            "product.homelab-hosts", ["server", "homelab", "hosts", "list", "--json"],
        )
    finally:
        if window is not None:
            window.close()
        if host_patcher is not None:
            host_patcher.stop()
        if status_patcher is not None:
            status_patcher.stop()


def test_recovery_state_does_not_auto_select_restore(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.ollama", "server.llm")
        assert page._action_for_state("resolve") is None
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_offline_ollama_uses_canonical_setup_as_confirmed_recovery(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.ollama")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:host:app.ollama", "app.ollama", "local", "host",
            installation="present", origin="phasezero", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.ollama"
        assert page._primary_action.impact
        assert "Nenhum modelo é baixado" in page._primary_action.impact
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.ollama"
        assert start.call_args.kwargs["preview"] is True
        assert page._primary_action.id != "server.llm.restore"

        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:host:app.ollama", "app.ollama", "local", "host",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_opencode_recovery_never_offers_unbound_9router_setup(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Aplicativos")
        page.open_product("app.opencode")
        page._instances_ready(page._status_action_id, (ProductInstance(
            "local:local:app.opencode", "app.opencode", "local", "local",
            installation="present", origin="phasezero", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.opencode-verify"
        assert not page._primary_action.mutable
        notice = page.findChild(QLabel, "accountGrantNotice")
        assert notice is not None and not notice.isHidden()
        assert "não vincula cada requisição" in notice.text()
        assert "ai.opencode-install" not in _detail_action_ids(page)
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.opencode-verify"
        assert start.call_args.kwargs["preview"] is False

        page._instances_ready(page._status_action_id, (ProductInstance(
            "external:local:app.opencode", "app.opencode", "local", "local",
            installation="present", origin="external", configuration="ready", health="offline",
        ),))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.opencode-verify"
        assert not page._primary_action.mutable
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_called_once()
        assert start.call_args.args[0].id == "ai.opencode-verify"
        assert start.call_args.kwargs["preview"] is False
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_ready_9router_dashboard_is_blocked_from_simple_open_route(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        from linux.ui_native.product_inventory import instances_from_status_payload

        page = window.registry.page_for("Aplicativos")
        page.open_product("app.9router")
        assert page._status_action_id == "ai.9router-status"
        instance = instances_from_status_payload(
            {"id": "9router", "installed": True, "healthy": True, "service": "active",
             "providers": {"active": 2, "total": 2}},
            app_id="app.9router", host_id="local", scope="local",
        )[0]
        page._instances_ready(page._status_action_id, (instance,))
        assert instance.origin == "unknown"
        assert page._primary_button.text() == "Uso bloqueado"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
        assert "ai.9router-dashboard" not in _detail_action_ids(page)
        assert "podem enviar inferência" in page._account_grant_notice.text()
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_9router_configuration_dashboard_is_blocked_and_offline_resolves_read_only(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        from linux.ui_native.product_inventory import instances_from_status_payload

        page = window.registry.page_for("Aplicativos")
        page.open_product("app.9router")
        configured = instances_from_status_payload(
            {"id": "9router", "installed": True, "healthy": True,
             "providers": {"active": 0, "total": 0}},
            app_id="app.9router", host_id="local", scope="local",
        )[0]
        page._instances_ready(page._status_action_id, (configured,))
        assert page._primary_button.text() == "Uso bloqueado"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
        assert "ai.9router-dashboard" not in _detail_action_ids(page)
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()

        offline = instances_from_status_payload(
            {"id": "9router", "installed": True, "healthy": False, "service": "inactive",
             "providers": {"active": 0, "total": 0}},
            app_id="app.9router", host_id="local", scope="local",
        )[0]
        page._instances_ready(page._status_action_id, (offline,))
        assert page._primary_button.text() == "Resolver"
        assert page._primary_action.id == "ai.9router-doctor"
        assert not page._primary_action.mutable
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_ready_odysseus_blocks_unbound_workspace_open(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        from linux.ui_native.product_inventory import instances_from_status_payload

        page = window.registry.page_for("Aplicativos")
        page.open_product("app.odysseus")
        assert page._status_action_id == "ai.odysseus-status"
        instance = instances_from_status_payload(
            {"id": "odysseus", "installed": True, "configured": True,
             "healthy": True, "service": "active"},
            app_id="app.odysseus", host_id="local", scope="local",
        )[0]
        page._instances_ready(page._status_action_id, (instance,))
        assert instance.origin == "unknown"
        assert page._primary_button.text() == "Uso bloqueado"
        assert page._primary_action is None
        assert not page._primary_button.isEnabled()
        assert "ai.odysseus-open" not in _detail_action_ids(page)
        assert "ai.odysseus-install" not in _detail_action_ids(page)
        assert "ai.odysseus-update" not in _detail_action_ids(page)
        assert "sem grant por requisição" in page._account_grant_notice.text()
        with patch.object(window.runner, "start") as start:
            page._primary_button.click()
        start.assert_not_called()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_desktop_launcher_rejects_entry_symlink_outside_xdg_root(tmp_path):
    from linux.ui_native.icons import find_desktop_entry

    apps = tmp_path / "applications"
    apps.mkdir()
    outside = tmp_path / "outside.desktop"
    outside.write_text("[Desktop Entry]\nType=Application\n", encoding="utf-8")
    (apps / "com.visualstudio.code.desktop").symlink_to(outside)
    assert find_desktop_entry("flatpak", "com.visualstudio.code", (apps,)) is None
