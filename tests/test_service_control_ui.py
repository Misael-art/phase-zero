from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtTest import QSignalSpy
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.service_control import ServerPage, WaydroidPage


ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def _page(page_type, category: str, catalog):
    actions = [action for action in catalog if action.category == category]
    page = page_type(ROOT, CommandRunner(ROOT), actions, by_id={a.id: a for a in catalog})
    page.build()
    page.finalize_action_coverage()
    return page, actions


def test_waydroid_page_covers_catalog_and_maps_visual_status(qapp, catalog):
    page, actions = _page(WaydroidPage, "Waydroid", catalog)
    assert page.represented_action_ids == {action.id for action in actions}
    page.apply_payload({
        "config": {"installed": True},
        "android": {
            "initialized": True, "imageType": "GAPPS", "serviceActive": "active",
            "sessionRunning": True,
        },
        "host": {"binderDevices": True},
        "access": {"sharesReady": True, "hostLinked": True, "mountCount": 4, "usbBusShared": True},
        "boot": {"helperInstalled": True, "artifactsCurrent": True},
    })
    assert page.state_label.text() == "● Rodando"
    assert page.power_button.text() == "Parar"
    assert all(toggle.isChecked() for toggle, _detail in page.feature_controls)
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.at(0)[0].id == "waydroid.stop"


def test_waydroid_power_follows_session_not_container(qapp, catalog):
    """CCS-005: container ativo + sessão parada = Parado (▶ Iniciar)."""
    page, _actions = _page(WaydroidPage, "Waydroid", catalog)
    page.apply_payload({
        "config": {"installed": True},
        "android": {"initialized": True, "serviceActive": "active", "sessionRunning": False},
        "host": {"binderDevices": True},
        "access": {},
        "boot": {},
    })
    assert page.state_label.text() == "● Parado"
    assert page.power_button.text() == "▶ Iniciar"
    assert "Container ativo" in page.state_detail.text()
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.at(0)[0].id == "waydroid.launch"


def test_waydroid_three_toggles_are_independent_contracts(qapp, catalog):
    """CCS-015: host-link ≠ pastas LXC ≠ USB — cada toggle dispara o par certo."""
    page, _actions = _page(WaydroidPage, "Waydroid", catalog)
    page.apply_payload({
        "config": {"installed": True},
        "android": {"initialized": True},
        "host": {},
        "access": {"hostLinked": False, "sharesReady": False, "mountCount": 0,
                   "usbBusShared": False},
        "boot": {},
    })
    spy = QSignalSpy(page.action_requested)
    page.feature_controls[0][0].click()
    assert spy.at(0)[0].id == "waydroid.host-access"
    page.cancel_pending_action("waydroid.host-access")
    page.feature_controls[1][0].click()
    assert spy.at(1)[0].id == "waydroid.shares.enable"
    page.cancel_pending_action("waydroid.shares.enable")
    page.feature_controls[2][0].click()
    assert spy.at(2)[0].id == "waydroid.usb.enable"
    # estados independentes: só USB ligada não liga as pastas
    page.apply_payload({
        "config": {"installed": True},
        "android": {"initialized": True},
        "host": {},
        "access": {"hostLinked": False, "sharesReady": False, "mountCount": 0,
                   "usbBusShared": True},
        "boot": {},
    })
    assert not page.feature_controls[1][0].isChecked()
    assert page.feature_controls[2][0].isChecked()


def test_waydroid_boot_actions_split_schedule_from_reboot(by_id_catalog):
    """CCS-015: boot.next agenda; next-reboot é explícito e fica no advanced."""
    schedule = by_id_catalog["waydroid.boot.next"]
    reboot = by_id_catalog["waydroid.boot.next-reboot"]
    assert schedule.args == ("waydroid", "boot", "next")
    assert "NÃO reinicia" in schedule.description
    assert reboot.args == ("waydroid", "boot", "next-reboot")
    assert reboot.visibility == "advanced"
    assert reboot.badge == "Alto risco"


@pytest.fixture(scope="module")
def by_id_catalog(catalog):
    return {a.id: a for a in catalog}


def test_waydroid_page_mirrors_windows_vm_ui_contract(qapp, catalog):
    """CCS-037: espelho do contrato de test_windows_vm_ui.py para Waydroid —
    cobertura total, status traduzido em controles e dispatch real nos cliques."""
    from PySide6.QtWidgets import QPushButton

    page, actions = _page(WaydroidPage, "Waydroid", catalog)
    # 1) cobertura completa da categoria (espelho de
    #    test_workspace_page_covers_all_windows_vm_actions)
    assert page.represented_action_ids == {a.id for a in actions}
    # 2) botões de atalho existem e disparam ações reais ao clicar
    buttons = {b.text(): b for b in page.findChildren(QPushButton)}
    assert "Abrir Android" in buttons
    spy = QSignalSpy(page.action_requested)
    buttons["Abrir Android"].click()
    assert spy.at(0)[0].id == "waydroid.launch"
    # 3) refresh dispara o loader de status da página
    page.reload()
    assert page.status_loader.running("waydroid.status") or page._proc_running()


def _proc_running(self):  # helper usado pelo teste acima
    return False


def test_waydroid_shares_previews_are_area_scoped(by_id_catalog):
    enable = by_id_catalog["waydroid.shares.enable"]
    disable = by_id_catalog["waydroid.shares.disable"]
    usb_enable = by_id_catalog["waydroid.usb.enable"]
    usb_disable = by_id_catalog["waydroid.usb.disable"]
    assert enable.preview_args[:2] == ("waydroid", "shares")
    assert disable.preview_args == ("waydroid", "shares", "status")
    assert "--groups" in usb_enable.args and "usb" in usb_enable.args
    assert "--groups" in usb_disable.args and "usb" in usb_disable.args


def test_waydroid_prevents_launch_before_configuration(qapp, catalog):
    page, _actions = _page(WaydroidPage, "Waydroid", catalog)
    page.apply_payload({"config": {"installed": False}, "android": {"initialized": False}})
    assert not page.shortcut_buttons["waydroid.launch"].isEnabled()
    assert page.shortcut_buttons["waydroid.repair"].isEnabled()


def test_server_page_uses_single_power_control_and_visual_facts(qapp, catalog):
    page, actions = _page(ServerPage, "Servidor", catalog)
    assert page.represented_action_ids == {action.id for action in actions}
    page.apply_payload({
        "configured": True,
        "ready": True,
        "profile": "assistant-private",
        "accessMode": {"effective": "tailscale"},
        "stack": {"apps": [
            {"key": "jellyfin", "running": True},
            {"key": "vaultwarden", "running": False},
        ]},
        "backupState": {"lastBackup": {"latest": "/safe/backup"}},
    })
    assert page.state_label.text() == "● Rodando"
    assert page.power_button.text() == "Parar"
    assert page.fact_labels[0].text() == "Perfil: assistant-private"
    spy = QSignalSpy(page.action_requested)
    page._power_action()
    assert spy.at(0)[0].id == "server.homelab.down"
    assert page.shortcut_buttons["server.homelab.open-jellyfin"].isEnabled()


def test_waydroid_stop_action_is_preview_protected(catalog):
    action = next(action for action in catalog if action.id == "waydroid.stop")
    assert action.mutable
    assert action.args == ("waydroid", "stop", "--json")
    assert action.preview_args == ("waydroid", "status", "--json")


def test_waydroid_toggles_dispatch_reversible_actions(qapp, catalog):
    page, _actions = _page(WaydroidPage, "Waydroid", catalog)
    page.apply_payload({
        "config": {"installed": True},
        "android": {"initialized": True},
        "access": {"hostLinked": True, "usbBusShared": False},
        "boot": {"helperInstalled": False},
    })
    spy = QSignalSpy(page.action_requested)
    page.feature_controls[0][0].click()
    assert not page.feature_controls[0][0].isChecked()
    assert page.feature_controls[0][0].property("pending") is True
    assert not page.feature_controls[0][0].isEnabled()
    assert spy.at(0)[0].id == "waydroid.host-access.remove"
    page.cancel_pending_action("waydroid.host-access.remove")
    assert page.feature_controls[0][0].isChecked()
    assert page.feature_controls[0][0].isEnabled()
    page.feature_controls[1][0].click()
    assert page.feature_controls[1][0].isChecked()
    assert spy.at(1)[0].id == "waydroid.shares.enable"


def test_server_toggles_dispatch_service_access_and_backup_actions(qapp, catalog):
    page, _actions = _page(ServerPage, "Servidor", catalog)
    page.apply_payload({
        "configured": True,
        "ready": False,
        "accessMode": {"effective": "local"},
        "stack": {"apps": []},
        "backupState": {},
    })
    spy = QSignalSpy(page.action_requested)
    page.feature_controls[0][0].click()
    assert spy.at(0)[0].id == "server.homelab.up"
    page.feature_controls[1][0].click()
    assert spy.at(1)[0].id == "server.homelab.up-tailscale"
    assert len(page.feature_controls) == 2
    page.shortcut_buttons["homelab.backup"].click()
    assert spy.at(2)[0].id == "homelab.backup"


def test_server_page_host_facts_missing_sensors_are_unavailable(qapp, catalog):
    page, _actions = _page(ServerPage, "Servidor", catalog)
    assert "indisponível" in page.hw_labels["smart"].text()
    assert "indisponível" in page.hw_labels["temperature"].text()
    page.apply_host_facts(
        {
            "smart": {"available": False, "reason": "smartctl ausente", "devices": []},
            "network": {"available": False, "reason": "ip ausente", "hostname": None},
            "disk": {"available": False, "reason": "df ausente", "volumes": []},
            "temperature": {"available": False, "reason": "sensors ausente", "celsius": None},
        }
    )
    for key in ("smart", "network", "disk", "temperature"):
        text = page.hw_labels[key].text().lower()
        assert "indisponível" in text
        assert "42" not in text
        assert "passed" not in text
    page.apply_host_facts(
        {
            "smart": {
                "available": True,
                "devices": [{"device": "/dev/sda", "health": "PASSED"}],
            },
            "network": {"available": True, "hostname": "garage"},
            "disk": {
                "available": True,
                "volumes": [{"mount": "/", "usedBytes": 10, "totalBytes": 100}],
            },
            "temperature": {"available": True, "celsius": 42},
        }
    )
    assert "PASSED" in page.hw_labels["smart"].text()
    assert "garage" in page.hw_labels["network"].text()
    assert "/ 10/100 B" in page.hw_labels["disk"].text()
    assert "42" in page.hw_labels["temperature"].text()
