from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication

from linux.capabilities.engine import catalog_payload
from linux.capabilities.platform import HostFacts
from linux.ui_native.catalog import CATEGORIES, SIDEBAR_GROUPS, build_catalog
from linux.ui_native.pages.linux_hub import LinuxHubPage
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.widgets import HubAppCard

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def facts() -> HostFacts:
    return HostFacts(
        platform="linux",
        architecture="x86_64",
        distro="arch",
        distro_like=(),
        package_family="arch",
        immutable=False,
        immutable_kind="",
        container=False,
        init="systemd",
        desktop="kde",
        session="wayland",
        gpus=("amd",),
        package_manager="pacman",
        flatpak=True,
        flathub=True,
    )


def status_payload(installed_ids: set[str] | None = None) -> dict:
    payload = catalog_payload(facts=facts())
    payload["hasStatus"] = True
    for item in payload["capabilities"]:
        item["installed"] = item["id"] in (installed_ids or set())
    return payload


@pytest.fixture
def page(qapp, catalog, monkeypatch):
    by_id = {action.id: action for action in catalog}
    widget = LinuxHubPage(ROOT, CommandRunner(ROOT), [], by_id)
    # build() queues reload with a zero-delay timer; cancel_all() before that
    # timer fires cannot cancel the future QProcess. These tests feed status
    # by hand, so intercept the host query before constructing the page.
    monkeypatch.setattr(widget.status_loader, "fetch", lambda *_args, **_kwargs: None)
    widget.build()
    return widget


def card_for(page: LinuxHubPage, item_id: str) -> HubAppCard:
    card = page.cards[item_id]
    assert isinstance(card, HubAppCard)
    return card


def test_linux_section_is_registered_in_the_sidebar():
    assert any(name == "Linux" for name, _icon, _caption in CATEGORIES)
    groups = {name: entries for name, entries in SIDEBAR_GROUPS}
    assert "Linux" in groups["Ações rápidas"]


def test_page_opens_with_tuning_and_tools_before_the_host_answers(page):
    # Nada de tela vazia esperando o backend: o que não depende de sondagem já
    # aparece, e as capabilities entram quando o host responde.
    assert {"tune.gaming", "tune.browser", "tune.dev"} <= set(page.cards)
    assert "hub.flatpak" in page.cards


def test_capability_status_populates_cards_and_switches(page):
    page._absorb_capabilities(status_payload({"gaming.mangohud"}))
    card = card_for(page, "gaming.mangohud")
    assert card.install_switch is not None
    assert card.install_switch.isChecked() is True
    other = card_for(page, "gaming.gamescope")
    assert other.install_switch.isChecked() is False


def test_unprobed_state_is_shown_as_unknown_not_off(page):
    payload = catalog_payload(facts=facts())  # sem include_status
    page._absorb_capabilities(payload)
    card = card_for(page, "gaming.mangohud")
    assert card.install_switch.isChecked() is False
    # Inerte e explicado: o usuário não pode "desligar" o que não foi lido.
    assert card.install_switch.isEnabled() is False
    assert "não verificado" in card.install_switch.toolTip()


def test_status_failure_disables_switches_with_a_reason(page):
    page._absorb_capabilities(status_payload({"gaming.mangohud"}))
    page._status_failed("hub.capabilities.status", "timed out")
    card = card_for(page, "gaming.mangohud")
    assert card.install_switch.isEnabled() is False
    assert "timed out" in card.reason_label.text()
    assert card.reason_label.isVisible() or not card.isVisible()


def test_install_toggle_emits_plan_then_apply_contract(page):
    page._absorb_capabilities(status_payload())
    card = card_for(page, "gaming.mangohud")
    spy = QSignalSpy(page.action_requested)
    card.install_switch.setChecked(True)
    assert spy.count() == 1
    action = spy.at(0)[0]
    assert action.preview_args == ("capabilities", "plan", "--capability", "gaming.mangohud")
    assert action.args == ("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}")
    assert action.preview_bindings == (("plan_id", "id"), ("confirm", "confirmToken"))
    assert action.mutable and action.elevated
    # Enquanto a operação não confirma, o switch fica pendente — não ligado.
    assert card.install_switch.property("pending") is True


def test_uninstall_toggle_uses_the_removal_plan(page):
    page._absorb_capabilities(status_payload({"gaming.mangohud"}))
    card = card_for(page, "gaming.mangohud")
    spy = QSignalSpy(page.action_requested)
    card.install_switch.setChecked(False)
    action = spy.at(0)[0]
    assert action.preview_args == ("capabilities", "remove-plan", "--capability", "gaming.mangohud")
    assert action.args[:2] == ("capabilities", "remove")


def test_tuning_toggle_uses_apply_revert_and_dry_run_preview(page):
    card = card_for(page, "tune.gaming")
    spy = QSignalSpy(page.action_requested)
    card.tune_switch.setChecked(True)
    action = spy.at(0)[0]
    assert action.args == ("tune", "gaming", "apply")
    assert action.preview_args == ("tune", "gaming", "apply", "--dry-run")
    assert action.status_args == ("tune", "gaming", "status")
    card.tune_switch.setChecked(False)
    revert = spy.at(1)[0]
    assert revert.args == ("tune", "gaming", "revert")


def test_cancelled_operation_restores_the_switch(page):
    card = card_for(page, "tune.gaming")
    spy = QSignalSpy(page.action_requested)
    card.tune_switch.setChecked(True)
    action = spy.at(0)[0]
    assert card.tune_switch.isChecked() is True
    page.cancel_pending_action(action.id)
    # Preview recusado não muda o host, então o switch volta ao lugar.
    assert card.tune_switch.isChecked() is False
    assert card.tune_switch.property("pending") is False


def test_tuning_status_reports_applied_and_drift(page):
    page._absorb_tuning("tune.gaming", {"applied": True, "drift": False})
    card = card_for(page, "tune.gaming")
    assert card.tune_switch.isChecked() is True
    assert card.reason_label.isHidden() or card.reason_label.text() == ""
    page._absorb_tuning("tune.gaming", {"applied": True, "drift": True})
    assert "fora do PhaseZero" in card.reason_label.text()


def test_search_and_filters_narrow_the_visible_cards(page):
    page._absorb_capabilities(status_payload({"gaming.mangohud"}))
    page._on_query("mangohud")
    visible = {item_id for item_id, card in page.cards.items() if card.isVisibleTo(page)}
    # A busca cobre descrição também: quem depende de MangoHud aparece junto,
    # e quem não tem relação some.
    assert "gaming.mangohud" in visible
    assert "gaming.goverlay" in visible
    assert "gaming.gamescope" not in visible
    page._on_query("")
    page._on_filter("installed")
    installed = [item_id for item_id, card in page.cards.items() if card.isVisibleTo(page)]
    assert installed == ["gaming.mangohud"]
    page._on_filter("recommended")
    recommended = {item_id for item_id, card in page.cards.items() if card.isVisibleTo(page)}
    assert "tune.gaming" in recommended
    assert "education.stellarium" not in recommended


def test_unavailable_item_cannot_be_toggled(page):
    payload = status_payload()
    for item in payload["capabilities"]:
        if item["id"] == "gaming.mangohud":
            item["applicable"] = False
            item["reason"] = "fonte não encontrada no repositório"
    page._absorb_capabilities(payload)
    card = card_for(page, "gaming.mangohud")
    assert card.install_switch.isEnabled() is False
    assert "fonte não encontrada" in card.reason_label.text()


def test_every_card_shows_mode_and_rollback_evidence(page):
    page._absorb_capabilities(status_payload())
    for item_id, card in page.cards.items():
        assert card.item.mode in {"recommended", "opt-in", "advanced"}
        assert card.item.rollback_labels, f"{item_id} sem selo de reversão"


def test_synthesized_actions_produce_real_pz_commands(monkeypatch, catalog):
    from linux.ui_native import command_runner
    from linux.ui_native.linux_hub import build_hub_items, load_overlay

    by_id = {action.id: action for action in catalog}
    items = {item.id: item for item in build_hub_items(status_payload(), by_id, load_overlay())}

    from linux.ui_native.pages.linux_hub import capability_install_action, tuning_action

    install = capability_install_action(items["gaming.mangohud"])
    program, args = command_runner.build_program(ROOT, install, preview=True)
    # Preview não escala privilégio: só planeja.
    assert program.endswith("linux/pz")
    assert args == ["capabilities", "plan", "--capability", "gaming.mangohud"]

    monkeypatch.setattr(command_runner, "admin_bridge", lambda: "/usr/bin/phasezero-admin")
    program, args = command_runner.build_program(
        ROOT, install, preview=False, values={"plan_id": "plan-1", "confirm": "tok"},
    )
    assert program == "/usr/bin/phasezero-admin"
    assert args[1:] == ["capabilities", "apply", "--plan-id", "plan-1", "--confirm", "tok"]

    tune = tuning_action(items["tune.gaming"], True)
    program, args = command_runner.build_program(ROOT, tune, preview=False)
    assert args == ["tune", "gaming", "apply"]
