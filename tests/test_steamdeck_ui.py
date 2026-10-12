from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication, QPushButton, QRadioButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.registry import PageRegistry
from linux.ui_native.pages.steamdeck import MODE_ACTIONS, SteamDeckPage


ROOT = Path(__file__).resolve().parents[1]


def _built_page(catalog):
    actions = [a for a in catalog if a.category == "Steam Deck"]
    built = SteamDeckPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    built.build()
    built.finalize_action_coverage()
    return built


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


@pytest.fixture
def page(qapp, catalog):
    actions = [action for action in catalog if action.category == "Steam Deck"]
    built = SteamDeckPage(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    built.build()
    built.finalize_action_coverage()
    return built


def _payload() -> dict:
    return {
        "mode": "handheld",
        "automation": {
            "watcherActive": True,
            "kdeHotkeys": True,
            "privilegedHelperInstalled": False,
            "steamPlusFallback": True,
        },
        "virtualKeyboard": {
            "provider": "kde-kwin",
            "kde": {"supported": True, "available": True, "enabled": True},
        },
        "plugins": {
            "decky": {
                "installed": True,
                "service": {"active": True},
            },
        },
        "boot": {"grubCfgEntry": "active", "nextEntry": "none"},
        "display": {"profile": "steamdeck-oled-handheld"},
    }


def test_steamdeck_page_covers_all_category_actions(page, catalog):
    actions = [action for action in catalog if action.category == "Steam Deck"]
    assert page.represented_action_ids == {action.id for action in actions}


def test_status_payload_drives_mode_radios_and_facts(page):
    page._on_status_ready("steamdeck.status", "", _payload())
    assert page._mode_radios["handheld"].isChecked()
    assert not page._mode_radios["docked-tv"].isChecked()
    assert page.watcher_label.text() == "Ativo (aplica o modo sozinho)"
    assert "Disponível, fechado" in page.keyboard_label.text()
    assert "Ligado" not in page.keyboard_label.text()
    assert page.decky_label.text() == "Instalado e serviço ativo"
    assert page.boot_label.text() == "Entrada GRUB presente e marcada"
    assert "OLED" in page.display_label.text()


def test_keyboard_open_is_not_reported_from_the_config_flag(page):
    payload = _payload()
    payload["virtualKeyboard"] = {
        "provider": "plasma-keyboard",
        "kde": {"supported": True, "available": False, "enabled": True, "visible": False},
        "configured": {"enabled": True, "inputMethod": "/usr/share/applications/org.kde.plasma.keyboard.desktop"},
        "dbus": {"supported": True, "available": False, "visible": False},
        "open": {"effective": False, "reason": "kwin-command-missing"},
    }
    page._on_status_ready("steamdeck.status", "", payload)
    assert page.keyboard_label.text().startswith("Configurado, KWin sem teclado ativo")
    assert "Ligado" not in page.keyboard_label.text()

    payload["virtualKeyboard"]["open"] = {"effective": True, "reason": "kwin-visible"}
    payload["virtualKeyboard"]["kde"]["visible"] = True
    page._on_status_ready("steamdeck.status", "", payload)
    assert page.keyboard_label.text().startswith("Aberto")


def test_docked_payload_moves_the_radio(page):
    payload = _payload()
    payload["mode"] = "docked-monitor"
    payload["automation"]["watcherActive"] = False
    page._on_status_ready("steamdeck.status", "", payload)
    assert page._mode_radios["docked-monitor"].isChecked()
    assert not page._mode_radios["handheld"].isChecked()
    assert page.watcher_label.text() == "Inativo"


def test_unknown_mode_leaves_radios_clear_and_explains(page):
    page._on_status_ready("steamdeck.status", "", {"mode": "teleport"})
    assert all(not radio.isChecked() for radio in page._mode_radios.values())
    assert "desconhecido" in page.mode_note.text().casefold()


def test_clicking_a_mode_radio_dispatches_its_action(page):
    page._on_status_ready("steamdeck.status", "", _payload())
    spy = QSignalSpy(page.action_requested)
    page._mode_radios["docked-tv"].setChecked(True)
    assert spy.count() == 1
    assert spy.at(0)[0].id == "steamdeck.docked-tv"
    # otimista: radios ficam travados até a próxima leitura de status
    assert all(not radio.isEnabled() for radio in page._mode_radios.values())


def test_cancel_pending_restores_sync_from_last_status(page, qapp=None):
    page._on_status_ready("steamdeck.status", "", _payload())
    page._on_mode_toggled(True, "docked-tv")
    page.cancel_pending_action("steamdeck.docked-tv")
    assert all(radio.isEnabled() for radio in page._mode_radios.values())
    assert page._mode_radios["handheld"].isChecked()


def test_status_failure_reports_without_touching_config(page):
    page._on_status_failed("steamdeck.status", "timed out")
    assert page.state_label.text() == "● Estado indisponível"
    assert "demorou demais" in page.mode_note.text()
    assert all(radio.isEnabled() for radio in page._mode_radios.values())


def test_registry_maps_steam_deck_to_live_page():
    registry = PageRegistry(ROOT, CommandRunner(ROOT))
    page = registry.page_for("Steam Deck")
    assert isinstance(page, SteamDeckPage)


def test_mode_actions_match_catalog_ids(catalog):
    by_id = {a.id: a for a in catalog}
    for mode, action_id in MODE_ACTIONS.items():
        assert f"steamdeck.{mode}" == action_id
        assert action_id in by_id, f"{action_id} ausente no catálogo"


def test_hotkeys_copy_matches_real_combinations(by_id_catalog):
    """CCS-011: as hotkeys reais são Meta+Shift+F1–F8 (Ctrl+Alt é VT)."""
    description = by_id_catalog["steamdeck.hotkeys"].description
    assert "Meta+Shift" in description
    assert "Ctrl+Alt" not in description


def test_deck_previews_are_area_scoped_not_status(by_id_catalog):
    plugins = by_id_catalog["steamdeck.plugins"]
    conveniences = by_id_catalog["steamdeck.conveniences"]
    assert plugins.preview_args == ("steamdeck", "plugins", "dry-run")
    assert conveniences.preview_args == ("steamdeck", "conveniences", "plan")


def test_display_detect_is_read_only(by_id_catalog):
    display = by_id_catalog["steamdeck.display"]
    assert not display.mutable, "detect é somente leitura"
    assert display.args == ("steamdeck", "display", "detect")


def test_elevated_installs_are_primary_with_risk_copy(by_id_catalog):
    """CCS-012: boot/privileged/USB visíveis no primário com badge de risco."""
    for action_id in ("steamdeck.privileged", "steamdeck.boot", "steamdeck.removable"):
        action = by_id_catalog[action_id]
        assert action.visibility == "primary", f"{action_id} escondido no advanced"
        assert action.badge == "Requer admin"
        assert "admin" in (action.title + action.description).casefold()


def test_advanced_keeps_status_actions(by_id_catalog):
    advanced = [aid for aid, a in by_id_catalog.items()
                if a.category == "Steam Deck" and a.visibility == "advanced"]
    assert advanced, "painel avançado não pode ficar vazio"
    for aid in advanced:
        assert aid.endswith(".status") or "conveniences" in aid or "repair" in aid, (
            f"{aid} deveria estar no primário"
        )


def test_watcher_enable_is_exposed(by_id_catalog, catalog):
    enable = by_id_catalog["steamdeck.watcher.enable"]
    assert enable.args == ("steamdeck", "watcher", "enable")
    assert enable.mutable and enable.preview_args == ("steamdeck", "watcher", "status")
    page = _built_page(catalog)
    texts = [b.text() for b in page.findChildren(QPushButton)]
    assert "Ligar watcher" in texts


def test_admin_row_buttons_present_on_page(catalog):
    page = _built_page(catalog)
    texts = [b.text() for b in page.findChildren(QPushButton)]
    for expected in ("Controles TDP (requer admin)", "Boot Game Mode (requer admin)",
                     "USB automático (requer admin)"):
        assert expected in texts
        button = next(b for b in page.findChildren(QPushButton) if b.text() == expected)
        assert button.toolTip(), "ação elevada sem explicação de risco"


@pytest.fixture(scope="module")
def by_id_catalog(qapp, catalog):
    return {a.id: a for a in catalog}
