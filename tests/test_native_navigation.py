from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton, QScrollArea

from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.models import ActionSpec
from linux.ui_native.pages.base import BasePage
from linux.ui_native.widgets import Breadcrumb


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_breadcrumb_exposes_current_location(qapp):
    breadcrumb = Breadcrumb()
    breadcrumb.set_path("Sistema", "Visão geral")
    assert breadcrumb.text == "PhaseZero  ›  Sistema  ›  Visão geral"
    label = breadcrumb.findChild(QLabel, "breadcrumbText")
    assert label.accessibleName() == "Localização atual"
    assert "Visão geral" in label.accessibleDescription()


def test_main_window_has_persistent_status_and_grouped_breadcrumb(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("Steam Deck")
        assert window.global_state.parent() is not None
        assert window.global_context.parent() is not None
        assert "Plataformas" in window.breadcrumb.text
        assert "Steam Deck" in window.breadcrumb.text
        assert window.sidebar_buttons["Steam Deck"].isChecked()
        window.close()


@pytest.mark.parametrize("width,height", [(949, 593), (800, 1280), (474, 296), (400, 640)])
def test_main_window_supports_documented_narrow_viewport(qapp, width, height):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show()
        window.resize(width, height)
        qapp.processEvents()
        assert window.size().width() == width
        # Window managers may clamp an oversized portrait request to a bound
        # between availableGeometry and the requested size. Exact height is
        # meaningful only when Qt can honor it; width/reflow assertions below
        # remain strict in either case.
        actual_height = window.size().height()
        available_height = qapp.primaryScreen().availableGeometry().height()
        assert actual_height == height or (
            height > available_height and available_height <= actual_height < height
        )
        if width >= 850:
            # LUX-020: trilho de ícones (850–1100 px; Deck a 150% = 853).
            assert window.sidebar.isVisible()
            assert window.sidebar.width() <= 72
            assert window.compact_menu.isHidden()
            assert all(not b.text() for b in window.sidebar_buttons.values())
            assert all(b.accessibleName() for b in window.sidebar_buttons.values())
            window.sidebar_buttons["Visão geral"].click()
            assert window.current_category == "Visão geral"
            window.show_category("Início")
            qapp.processEvents()
            dashboard_scroll = window.registry.page_for("Início").findChild(QScrollArea)
            assert dashboard_scroll.horizontalScrollBar().maximum() == 0
            window.resize(1280, 800)
            qapp.processEvents()
            assert window.sidebar_buttons["Início"].text() == "Início"
            window.close()
            return
        assert not window.sidebar.isVisible()
        assert not window.compact_menu.isHidden()
        assert window.search.isVisible()
        assert window.mode_switch.isVisible()
        assert window.theme_button.isVisible()
        assert window.search.height() >= 25
        assert window.theme_button.height() >= 25
        if width < 450:
            assert window.search.geometry().bottom() < window.mode_switch.geometry().top()
            assert window.mode_switch.geometry().right() < window.theme_button.geometry().left()
        else:
            assert window.search.geometry().right() < window.mode_switch.geometry().left()
        assert window.compact_menu.menu() is not None
        assert len(window.compact_menu.menu().actions()) == len(window.sidebar_buttons)
        window.compact_menu.menu().actions()[1].trigger()
        assert window.current_category == "Visão geral"
        window.show_category("Início")
        qapp.processEvents()
        dashboard_scroll = window.registry.page_for("Início").findChild(QScrollArea)
        assert dashboard_scroll.horizontalScrollBar().maximum() == 0
        window.close()


def test_base_page_context_health_uses_explicit_status_args(qapp):
    action = ActionSpec(
        id="module.status",
        category="Teste",
        title="Estado do módulo",
        description="Consulta estado",
        args=("module", "mutate"),
        status_args=("module", "status", "--json"),
        icon="system-run",
    )
    page = BasePage(ROOT, CommandRunner(ROOT), [action], {action.id: action})
    page.finalize_action_coverage()
    assert page.findChild(QLabel, "contextStatusText") is not None
    with patch.object(page.status_loader, "fetch") as fetch:
        page.reload_context_status()
    fetch.assert_called_once_with(action.id, ["module", "status", "--json"])


def test_routing_page_registered_in_sidebar_and_builds(qapp):
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("IA & Dev")
        assert "Roteamento IA" not in window.sidebar_buttons
        ai_page = window.registry.page_for("IA & Dev")
        ai_page.findChild(QPushButton, "openAiRoutingPage").click()
        assert window.current_category == "Roteamento IA"
        assert window.sidebar_buttons["IA & Dev"].isChecked()
        assert "Inteligência artificial · Conexões avançadas" in window.breadcrumb.text
        page = window.registry.page_for("Roteamento IA")
        assert page is not None
        assert page.__class__.__name__ == "AiRoutingPage"
        for aid in ("ai.routing-status", "ai.routing-inventory", "ai.routing-verify",
                    "ai.routing-plan", "ai.routing-apply-all", "ai.routing-rollback"):
            assert aid in window.registry.by_id, aid
        page.findChild(QPushButton, "backToAiHome").click()
        assert window.current_category == "IA & Dev"
        ai_page.findChild(QPushButton, "openAiProxiesPage").click()
        assert window.current_category == "Proxies IA"
        assert window.sidebar_buttons["IA & Dev"].isChecked()
        assert "Inteligência artificial · Conexões avançadas" in window.breadcrumb.text
        proxy_page = window.registry.page_for("Proxies IA")
        proxy_page.findChild(QPushButton, "backToAiHome").click()
        assert window.current_category == "IA & Dev"
        window.close()


def test_ai_and_account_destinations_have_separate_sidebar_groups(qapp):
    from linux.ui_native.catalog import SIDEBAR_GROUPS
    from linux.ui_native.main_window import MainWindow

    groups = {name: categories for name, categories in SIDEBAR_GROUPS}
    assert groups["Desenvolvimento"] == ("Desenvolvimento",)
    assert groups["Inteligência artificial"] == ("IA & Dev",)
    assert groups["Contas e conexões"] == ("Contas e conexões",)
    assert "IA · Conexões avançadas" not in groups
    assert "Proxies IA" not in {category for _group, categories in SIDEBAR_GROUPS for category in categories}
    assert "Roteamento IA" not in {category for _group, categories in SIDEBAR_GROUPS for category in categories}

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("Roteamento IA")
        assert "Inteligência artificial · Conexões avançadas" in window.breadcrumb.text
        assert "Roteamento IA" in window.breadcrumb.text
        window.close()


def test_homelab_reachable_from_sidebar_and_registry(qapp):
    """CCS-013: Homelab é uma superfície alcançável — sidebar + registry."""
    from linux.ui_native.catalog import CATEGORIES, SIDEBAR_GROUPS
    from linux.ui_native.main_window import MainWindow

    from linux.ui_native.catalog import NESTED_CATEGORIES

    sidebar_categories = {cat for _title, cats in SIDEBAR_GROUPS for cat in cats}
    assert "Homelab" in sidebar_categories, "Homelab ausente da navegação (SIDEBAR_GROUPS)"
    # Toda categoria registrada deve ser navegável; nada pode ficar órfão.
    orphans = [
        name for name, *_ in CATEGORIES
        if name not in sidebar_categories and name not in NESTED_CATEGORIES
    ]
    assert orphans == [], f"categorias fora do menu: {orphans}"

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        window.show_category("Homelab")
        assert "Homelab" in window.sidebar_buttons
        page = window.registry.page_for("Homelab")
        assert page is not None
        assert page.__class__.__name__ == "HomelabPage"
        window.close()


def test_home_journeys_cover_objectives_with_single_entry(qapp, tmp_path, monkeypatch):
    """PZ-AUD-029: Início mostra objetivos (não taxonomias), cada um com
    UMA ação de entrada real mais requisito, custo e maturidade.

    Host com histórico (não primeiro uso): os seis objetivos aparecem. No
    primeiro uso o objetivo que repete o passo 2 some (LUX-013)."""
    import json as _json
    from linux.ui_native.main_window import MainWindow
    from unittest.mock import patch

    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    op = tmp_path / "phasezero" / "control-center" / "operations" / "20260101T000000Z-1-a-x"
    op.mkdir(parents=True)
    (op / "operation.json").write_text(_json.dumps({
        "schemaVersion": 1, "operationId": op.name, "actionId": "system.doctor",
        "title": "Diagnóstico", "category": "Visão geral", "status": "succeeded",
        "mutable": True, "preview": False,
    }), encoding="utf-8")

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
        page = window.registry.page_for("Início")
        assert page is not None
        cards = getattr(page, "journey_cards", [])
        assert len(cards) == 6, f"expected 6 journey cards, got {len(cards)}"
        seen_actions = set()
        for card in cards:
            labels = [w.text() for w in card.findChildren(QLabel)]
            joined = "\n".join(labels)
            assert "Precisa:" in joined
            assert "Custo:" in joined
            assert "Maturidade:" in joined
            # UX-006: one entry control per card — it either runs the
            # entry action or opens the page that carries the journey.
            buttons = [b for b in card.findChildren(QPushButton)
                       if b.text() in ("Preparar e usar", "Abrir jornada")]
            assert len(buttons) == 1
        from linux.ui_native.pages.dashboard import JOURNEYS

        for _key, _title, action_id, _req, _cost, _mat, dest, _focus in JOURNEYS:
            assert action_id in window.registry.by_id, action_id
            if dest:
                assert window.registry.page_for(dest) is not None, dest
            seen_actions.add(action_id)
        assert len(seen_actions) == 6
        window.close()


def test_ctrl_number_follows_sidebar_order(qapp):
    """LUX-016: Ctrl+N abre o N-ésimo destino da barra lateral."""
    from unittest.mock import patch
    from PySide6.QtGui import QKeySequence
    from linux.ui_native.main_window import MainWindow

    with patch.object(MainWindow, "_host_summary"), patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_action"
    ):
        window = MainWindow(ROOT)
    try:
        order = window.sidebar_order()
        assert order[0] == "Início"
        shortcuts = {
            action.shortcut().toString(): action for action in window.actions()
            if action.shortcut().toString().startswith("Ctrl+")
            and action.shortcut().toString()[5:].isdigit()
        }
        for index, category in enumerate(order[:9], start=1):
            shortcuts[f"Ctrl+{index}"].trigger()
            assert window.current_category == category
            assert f"(Ctrl+{index})" in window.sidebar_buttons[category].toolTip()
    finally:
        window.close()
