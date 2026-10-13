from __future__ import annotations

import json
import time
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6 import QtGui
from PySide6.QtCore import QCoreApplication, QEvent, QTimer, Qt
from PySide6.QtGui import QAccessible
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QLabel, QLineEdit, QMessageBox, QPushButton,
    QRadioButton, QWidget,
)


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")

from linux.ai.account_adapters import router_provider_accounts
from linux.ai.account_contract import Connection, Evidence, Quota
from linux.ai.credential_vault import CredentialVault
from linux.ai.grants import CONSENT_RECORD_ADAPTERS, GrantLedger
from linux.ai.secret_store import SecretStoreUnavailable
from linux.ui_native.pages.accounts import (
    AccountChannelsDialog, AccountsPage, AddApiCredentialDialog, _credential_vault_path,
)


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    host_patcher = patch.object(MainWindow, "_host_summary")
    host_patcher.start()
    # Start on the accounts page. The default dashboard runs a real system
    # health probe during construction, which would break hermetic UI tests.
    return MainWindow(ROOT, initial_category="Contas e conexões"), host_patcher


def test_credential_vault_path_uses_dpapi_location_on_windows():
    path = _credential_vault_path(
        platform="nt", local_app_data=r"C:\Users\User\AppData\Local",
    )
    assert str(path).replace("\\", "/") == (
        "C:/Users/User/AppData/Local/PhaseZero/ai-accounts/credentials.dpapi"
    )


def test_credential_vault_path_fails_closed_without_windows_profile():
    with pytest.raises(OSError, match="local application data"):
        _credential_vault_path(platform="nt", local_app_data="")


@pytest.fixture(autouse=True)
def reject_unmocked_status_probes(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg-data"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg-config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "xdg-state"))

    def reject(*_args, **_kwargs):
        pytest.fail("account UI test attempted a real status probe")

    # This page is outside the Accounts UI tests and starts a local capability
    # probe during MainWindow construction.
    monkeypatch.setattr("linux.ui_native.pages.linux_hub.LinuxHubPage.reload", lambda _self: None)
    monkeypatch.setattr("linux.ui_native.status_loader.StatusLoader.fetch", reject)


def test_accounts_page_keeps_same_provider_accounts_separate_and_rejects_stale_probe(
    qapp, tmp_path, monkeypatch,
):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page is not None
        calls = []
        with patch.object(page.status_loader, "fetch", side_effect=lambda key, args: calls.append((key, args))):
            window.show_category("Contas e conexões")
            assert calls == []  # Opening private view never probes providers.
            page.findChild(QPushButton, "refreshAccounts").click()
            old_claude = next(key for key, _args in calls if key.endswith(":claude"))
            page.refresh_accounts()
            current = {key.rsplit(":", 1)[-1]: key for key, _args in calls[-4:]}
            page.status_loader.status_ready.emit(old_claude, "", {"auth": {"loggedIn": True}})
            assert page.summary.text() == "Verificando provedores disponíveis…"

            page.status_loader.status_ready.emit(
                current["claude"], "", {"auth": {"apiProvider": "anthropic", "loggedIn": True}},
            )
            page.status_loader.status_ready.emit(
                current["proxies"], "", {"proxies": []},
            )
            page.status_loader.status_ready.emit(
                current["router-providers"], "", {"connections": [
                    {"id": "record-a", "provider": "openai", "name": "Account One", "active": True, "status": "success"},
                    {"id": "record-b", "provider": "openai", "name": "Account Two", "active": True, "status": "success"},
                ]},
            )
            page.status_loader.status_ready.emit(
                current["router-status"], "", {"healthy": True},
            )

        openai_cards = [
            card for card in page.findChildren(QRadioButton)
            if "openai" in card.accessibleName()
        ]
        assert len(openai_cards) == 2
        assert all(card.focusPolicy() != Qt.NoFocus for card in openai_cards)
        assert len({account.account_id for account, _connection in page._accounts
                    if account.provider == "openai"}) == 2
        openai_cards[0].click()
        openai_cards[1].click()
        assert not openai_cards[0].isChecked()
        assert openai_cards[1].isChecked()
        assert page._selected_by_provider["openai"] == next(
            account.account_id for account, _connection in page._accounts
            if account.provider == "openai" and account.nickname == "Account Two"
        )

        grant_buttons = page.findChildren(QPushButton, "accountConsumerGrant")
        assert len(grant_buttons) == 4
        scope_note = page.findChild(QLabel, "accountGrantScopeNote").text().casefold()
        assert "não libera inferência" in scope_note
        assert all(button.text().startswith("Registrar consentimento em ")
                   for button in grant_buttons)
        with patch("linux.ui_native.pages.accounts.QMessageBox.question",
                   return_value=QMessageBox.Yes) as confirm:
            grant_buttons[0].click()
        assert confirm.call_args.args[1] == "Registrar consentimento?"
        assert (
            "nenhuma inferência será habilitada por esta ação"
            in confirm.call_args.args[2].casefold()
        )
        granted = page.grant_ledger.for_consumer("app.claude-code")
        assert len(granted) == 1
        assert granted[0].connection_id == page._accounts[1][1].connection_id
        revoke = next(button for button in page.findChildren(QPushButton, "accountConsumerGrant")
                      if button.text().startswith("Revogar consentimento"))
        revoke.click()
        assert page.grant_ledger.for_consumer("app.claude-code") == ()

        summary = page.redacted_export
        assert summary == {
            "schemaVersion": 2, "total": 3, "enabled": 2,
            "usable": 0, "secretsRedacted": True,
        }
        assert "Account One" not in json.dumps(summary)
        assert "Account Two" not in json.dumps(summary)

        with patch.object(page.status_loader, "fetch", side_effect=lambda key, args: calls.append((key, args))):
            page.refresh_accounts()
            failed = {key.rsplit(":", 1)[-1]: key for key, _args in calls[-4:]}
            for probe_id in failed.values():
                page.status_loader.status_failed.emit(probe_id, "unavailable")
            assert "Consulta parcial" in page.summary.text()
            assert "sem resposta: Claude" in page.summary.text()
            assert "0 contas" not in page.summary.text()
    finally:
        window.close()
        host_patcher.stop()


def test_accounts_page_records_per_probe_local_observation_time(
    qapp, tmp_path, monkeypatch,
):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        calls = []
        with patch.object(page.status_loader, "fetch", side_effect=lambda key, args: calls.append((key, args))):
            page.refresh_accounts()
            probe_ids = {key.rsplit(":", 1)[-1]: key for key, _args in calls}
            moments = iter(datetime(2026, 9, 25, 11, minute, tzinfo=timezone.utc) for minute in range(4))

            class SequentialDateTime(datetime):
                @classmethod
                def now(cls, tz=None):
                    value = next(moments)
                    return value.astimezone(tz) if tz is not None else value.replace(tzinfo=None)

            with patch("linux.ui_native.pages.accounts.datetime", SequentialDateTime):
                page.status_loader.status_ready.emit(
                    probe_ids["claude"], "", {"auth": {"loggedIn": True, "apiProvider": "firstParty"}},
                )
                page.status_loader.status_ready.emit(
                    probe_ids["proxies"], "", {"proxies": [{
                        "id": "qwenproxy", "credentialStatus": "present",
                        "sessionStatus": "authenticated", "service": "active",
                    }]},
                )
                page.status_loader.status_ready.emit(
                    probe_ids["router-providers"], "", {"connections": [{
                        "id": "router-id", "provider": "openai", "active": True, "status": "success",
                    }]},
                )
                page.status_loader.status_ready.emit(
                    probe_ids["router-status"], "", {"healthy": True},
                )

        expected = {
            "claude": "2026-09-25T11:00:00+00:00",
            "proxies": "2026-09-25T11:01:00+00:00",
            "router-providers": "2026-09-25T11:02:00+00:00",
            "router-status": "2026-09-25T11:03:00+00:00",
        }
        assert page._source_observed_at == expected
        observation = page.findChild(QLabel, "accountObservation")
        assert observation is not None
        assert "Consulta local mais recente" in observation.text()
        assert "não comprova sessão válida" in observation.toolTip()
        by_adapter = {connection.adapter_id: connection for _account, connection in page._accounts}
        assert by_adapter["claude-code-auth-status"].session.observed_at == expected["claude"]
        assert by_adapter["proxy-auth-status"].credential.observed_at == expected["proxies"]
        assert by_adapter["9router-provider-status"].access.observed_at == expected["router-providers"]
        assert by_adapter["9router-provider-status"].service.observed_at == expected["router-status"]
    finally:
        window.close()
        host_patcher.stop()


def test_account_refresh_announces_progress_and_final_status_accessibly(
    qapp, tmp_path, monkeypatch,
):
    announcement_type = getattr(QtGui, "QAccessibleAnnouncementEvent", None)
    if announcement_type is None:
        pytest.skip("Qt announcement events require Qt 6.8 or newer")

    events = []
    monkeypatch.setattr(QAccessible, "isActive", staticmethod(lambda: True))
    monkeypatch.setattr(QAccessible, "updateAccessibility", staticmethod(events.append))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page.summary.accessibleName() == "Status das contas e conexões"
        summary_accessible = QAccessible.queryAccessibleInterface(page.summary)
        assert summary_accessible.text(QAccessible.Text.Name) == "Status das contas e conexões"
        calls = []
        monkeypatch.setattr(
            page.status_loader, "fetch",
            lambda action_id, args: calls.append((action_id, args)),
        )

        page.refresh_accounts()
        assert len(events) == 1
        assert events[0].message() == "Verificando provedores disponíveis…"
        assert events[0].politeness() == QAccessible.AnnouncementPoliteness.Polite

        probe_ids = [action_id for action_id, _args in calls]
        assert len(probe_ids) == 4
        for probe_id in probe_ids[:-1]:
            page.status_loader.status_failed.emit(probe_id, "unavailable")
        assert len(events) == 1

        page.status_loader.status_failed.emit(probe_ids[-1], "unavailable")
        assert len(events) == 2
        assert isinstance(events[-1], announcement_type)
        assert events[-1].message() == page.summary.text()
        assert events[-1].message().startswith("Consulta parcial")
        assert events[-1].politeness() == QAccessible.AnnouncementPoliteness.Polite
    finally:
        window.close()
        host_patcher.stop()


def test_account_screen_labels_expired_evidence_explicitly():
    positive = Evidence("yes", "fixture")
    expired = Evidence("no", "fixture", error="expired")
    connection = Connection(
        "conn", "account", "adapter", "local", True,
        credential=positive, session=expired, service=positive, access=positive,
    )

    assert "sessão expirada" in AccountsPage._connection_state(connection)


def test_account_quota_shows_unknown_official_zero_and_local_estimate(qapp):
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        account, connection = router_provider_accounts({"connections": [{
            "id": "quota-account", "provider": "openai", "name": "Quota account", "active": True,
        }]})[0]

        def render_quota(value):
            page._accounts = ((account, value),)
            page._render_cards()
            QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
            return page.findChild(QLabel, "accountQuota").text()

        assert render_quota(connection) == "Cota restante: não informada"

        timestamp = "2026-09-25T10:00:00Z"
        official = replace(connection, quota=Quota(
            "messages", "mensagens", remaining=0, total=500,
            source="official", observed_at=timestamp,
        ))
        official_label = render_quota(official)
        assert "Fonte oficial: 0 mensagens restantes (total 500)" in official_label
        assert "observado" in official_label

        estimate = replace(connection, quota=Quota(
            "tokens", "tokens", remaining=2.5, source="local_estimate",
            observed_at=timestamp,
        ))
        estimate_label = render_quota(estimate)
        assert "Estimativa local: 2.5 tokens restantes" in estimate_label
        assert "Fonte oficial" not in estimate_label
    finally:
        window.close()
        host_patcher.stop()


def test_hidden_ai_dev_page_probes_only_when_opened(qapp):
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("IA & Dev")
        assert page is not None
        calls = []
        with patch.object(
            page.status_loader, "fetch",
            side_effect=lambda action_id, args: calls.append((action_id, args)),
        ):
            page.block_while_running(False)
            assert calls == []
            window.show_category("IA & Dev")
        assert calls == [("ai.status", ["ai", "status"])]
    finally:
        window.close()
        host_patcher.stop()


def test_account_without_photo_uses_accessible_initials(qapp):
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page._initials("Account Two") == "AT"
        assert page._initials("") == "?"
    finally:
        window.close()
        host_patcher.stop()


def test_add_connection_lists_supported_channel_requirements_and_maturity(qapp):
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        add = page.findChild(QPushButton, "addAccountConnection")
        assert add is not None

        def close_public_dialog():
            active = QApplication.activeModalWidget()
            assert isinstance(active, AccountChannelsDialog)
            active.findChild(QPushButton, "closeAccountChannels").click()

        QTimer.singleShot(0, close_public_dialog)
        add.click()

        dialog = AccountChannelsDialog()
        screen = dialog.screen() or qapp.primaryScreen()
        assert screen is not None
        available = screen.availableGeometry()
        assert dialog.width() <= available.width()
        assert dialog.height() <= available.height()
        cards = dialog.findChildren(QWidget)
        channels = [
            card for card in cards
            if card.objectName().startswith("accountChannel_")
            and card.objectName() not in {
                "accountChannelName", "accountChannel_requirements",
                "accountChannel_login", "accountChannel_maturity",
            }
        ]
        assert len(channels) == 4
        copy = " ".join(label.text() for label in dialog.findChildren(QLabel))
        assert "Requisitos:" in copy
        assert "Tipo de login:" in copy
        assert "Maturidade:" in copy
        assert "esta lista não inicia login nem recebe credenciais" in copy
        assert "Provedores no 9Router" in copy

        dialog.show()
        qapp.processEvents()
        QTest.keyClick(dialog, Qt.Key_Escape)
        assert not dialog.isVisible()
    finally:
        window.close()
        host_patcher.stop()


def test_accounts_privacy_toggle_masks_identity_and_persists(qapp, tmp_path, monkeypatch):
    class Preferences:
        hidden = False

        def __init__(self, _parent=None):
            pass

        @property
        def hide_account_identity(self):
            return self.hidden

        def set_hide_account_identity(self, hidden):
            type(self).hidden = bool(hidden)

    monkeypatch.setattr("linux.ui_native.pages.accounts.UiPreferences", Preferences)
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        page._accounts = router_provider_accounts({"connections": [
            {
                "id": "private-a", "provider": "openai", "name": "Private Account",
                "workspace": "sensitive-workspace", "active": True,
            },
            {
                "id": "private-b", "provider": "openai", "name": "Second Identity",
                "workspace": "second-workspace", "active": True,
            },
        ]})
        page._render_cards()

        privacy = page.findChild(QCheckBox, "hideAccountIdentity")
        assert privacy is not None and not privacy.isChecked()
        assert [label.text() for label in page.findChildren(QLabel, "accountDisplayName")] == [
            "Private Account", "Second Identity",
        ]

        privacy.setFocus()
        QTest.keyClick(privacy, Qt.Key_Space)
        assert privacy.isChecked()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        assert [label.text() for label in page.findChildren(QLabel, "accountDisplayName")] == [
            "Conta 1", "Conta 2",
        ]
        assert all(
            "workspace oculto" in label.text()
            for label in page.findChildren(QLabel, "accountProvider")
        )
        assert all(button.accessibleName() in {
            "Selecionar Conta 1 (openai)", "Selecionar Conta 2 (openai)",
        } for button in page.findChildren(QRadioButton))
        radio_names = [
            QAccessible.queryAccessibleInterface(button).text(QAccessible.Text.Name)
            for button in page.findChildren(QRadioButton)
        ]
        assert set(radio_names) == {
            "Selecionar Conta 1 (openai)", "Selecionar Conta 2 (openai)",
        }
        assert all(label.text() == "?" for label in page.findChildren(QLabel, "accountAvatarInitials"))
        accessible_text = " ".join(
            " ".join(
                (
                    interface.text(QAccessible.Text.Name),
                    interface.text(QAccessible.Text.Description),
                )
            )
            for widget in page.findChildren(QWidget)
            if (interface := QAccessible.queryAccessibleInterface(widget)) is not None
        )
        assert "Private Account" not in accessible_text
        assert "Second Identity" not in accessible_text
        assert "sensitive-workspace" not in accessible_text
        assert "second-workspace" not in accessible_text
        rendered_text = " ".join(
            widget.text() + " " + widget.accessibleName()
            for widget in page.findChildren(QWidget)
            if hasattr(widget, "text")
        )
        assert "Private Account" not in rendered_text
        assert "Second Identity" not in rendered_text
        assert "sensitive-workspace" not in rendered_text
        assert "second-workspace" not in rendered_text

        window.close()
        host_patcher.stop()
        window, host_patcher = _window(qapp)
        page = window.registry.page_for("Contas e conexões")
        privacy = page.findChild(QCheckBox, "hideAccountIdentity")
        assert privacy.isChecked()
        page._accounts = router_provider_accounts({"connections": [
            {"id": "private-a", "provider": "openai", "name": "Private Account", "active": True},
        ]})
        privacy.setFocus()
        QTest.keyClick(privacy, Qt.Key_Space)
        assert not privacy.isChecked()
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        assert [label.text() for label in page.findChildren(QLabel, "accountDisplayName")] == [
            "Private Account",
        ]
        assert not page.preferences.hide_account_identity
    finally:
        window.close()
        host_patcher.stop()


def test_disabled_connection_cannot_receive_a_new_consumer_grant(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        page._accounts = router_provider_accounts({
            "connections": [
                {"id": "disabled", "provider": "openai", "name": "Paused", "active": False},
            ],
        })
        page._render_cards()
        buttons = page.findChildren(QPushButton, "accountConsumerGrant")
        assert len(buttons) == 2
        assert all(not button.isEnabled() for button in buttons)
        assert {button.text() for button in buttons} == {"Conexão desativada"}
        assert all("Ative esta conexão" in button.toolTip() for button in buttons)
    finally:
        window.close()
        host_patcher.stop()


@pytest.mark.parametrize("invalid_contents", [
    "not-json", "[]", '{"schemaVersion":true,"grants":[null]}',
])
def test_invalid_grant_ledger_disables_consent_controls(
    qapp, tmp_path, monkeypatch, invalid_contents,
):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    ledger_path = tmp_path / "phasezero" / "ai-accounts" / "grants.json"
    ledger_path.parent.mkdir(parents=True)
    ledger_path.write_text(invalid_contents)
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page._grant_load_error
        account, connection = router_provider_accounts({"connections": [{
            "id": "record-a", "provider": "openai", "name": "Private Account", "active": True,
        }]})[0]
        page._accounts = ((account, connection),)
        page._render_cards()
        assert page.findChildren(QPushButton, "accountConsumerGrant") == []
        assert "ledger local inválido" in page.findChild(QLabel, "accountGrantUnavailable").text()
    finally:
        window.close()
        host_patcher.stop()


def test_coerced_grant_enabled_value_disables_consent_controls(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))
    ledger_path = tmp_path / "phasezero" / "ai-accounts" / "grants.json"
    account, connection = router_provider_accounts({"connections": [{
        "id": "record-a", "provider": "openai", "name": "Private Account", "active": True,
    }]})[0]
    ledger = GrantLedger(ledger_path)
    ledger.grant(
        connection, "app.claude-code", ("inference",),
        support=CONSENT_RECORD_ADAPTERS, consented=True,
    )
    payload = json.loads(ledger_path.read_text())
    payload["grants"][0]["enabled"] = "false"
    ledger_path.write_text(json.dumps(payload))

    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        assert page._grant_load_error
        page._accounts = ((account, connection),)
        page._render_cards()
        assert page.findChildren(QPushButton, "accountConsumerGrant") == []
        assert "ledger local inválido" in page.findChild(QLabel, "accountGrantUnavailable").text()
    finally:
        window.close()
        host_patcher.stop()


class FakeCredentialStore:
    def __init__(self, failure=None):
        self.values = {}
        self.failure = failure

    def store(self, reference, secret):
        if self.failure is not None:
            raise self.failure
        self.values[reference] = secret

    def delete(self, reference):
        if self.failure is not None:
            raise self.failure
        return self.values.pop(reference, None) is not None


def _submit_api_credential(qapp, page, *, secret="secret-value-for-test"):
    def fill_and_submit():
        dialog = QApplication.activeModalWidget()
        assert isinstance(dialog, AddApiCredentialDialog)
        dialog.findChild(QLineEdit, "credentialProvider").setText("MiMo API")
        dialog.findChild(QLineEdit, "credentialNickname").setText("Conta particular")
        secret_input = dialog.findChild(QLineEdit, "credentialValue")
        assert secret_input.echoMode() == QLineEdit.Password
        secret_input.setText(secret)
        dialog.findChild(QPushButton, "saveApiCredential").click()

    QTimer.singleShot(0, fill_and_submit)
    page.findChild(QPushButton, "addApiCredential").click()
    deadline = time.monotonic() + 3
    while page._credential_busy and time.monotonic() < deadline:
        qapp.processEvents()
        QTest.qWait(10)
    assert not page._credential_busy


def test_public_credential_flow_uses_secure_vault_without_connecting_or_granting(
    qapp, tmp_path, monkeypatch,
):
    announcement_type = getattr(QtGui, "QAccessibleAnnouncementEvent", None)
    if announcement_type is None:
        pytest.skip("Qt announcement events require Qt 6.8 or newer")
    events = []
    monkeypatch.setattr(QAccessible, "isActive", staticmethod(lambda: True))
    monkeypatch.setattr(QAccessible, "updateAccessibility", staticmethod(events.append))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg-data"))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        secure_store = FakeCredentialStore()
        credential_path = tmp_path / "credential-fixture" / "credentials.json"
        page.credential_vault = CredentialVault(credential_path, secure_store)
        credential_status = page.findChild(QLabel, "credentialVaultStatus")
        status_accessible = QAccessible.queryAccessibleInterface(credential_status)
        assert status_accessible.text(QAccessible.Text.Name) == "Status do cofre de credenciais"

        _submit_api_credential(qapp, page)

        assert [event.message() for event in events] == [
            "Aguardando resposta do cofre seguro…",
            page.findChild(QLabel, "credentialVaultStatus").text(),
        ]
        assert all(isinstance(event, announcement_type) for event in events)
        assert all(event.politeness() == QAccessible.AnnouncementPoliteness.Polite for event in events)

        assert len(page.credential_vault.entries) == 1
        entry = page.credential_vault.entries[0]
        assert secure_store.values == {entry.secret_ref: "secret-value-for-test"}
        assert "secret-value-for-test" not in credential_path.read_text(encoding="utf-8")
        assert "secret-value-for-test" not in " ".join(
            widget.text() for widget in page.findChildren(QWidget) if hasattr(widget, "text")
        )
        assert page._accounts == ()
        assert page.grant_ledger.for_consumer("app.claude-code") == ()
        assert page.redacted_export == {
            "schemaVersion": 2, "total": 0, "enabled": 0,
            "usable": 0, "secretsRedacted": True,
        }
        assert "nenhum app autorizado" in page.findChild(
            QLabel, "storedApiCredentialState",
        ).text()

        page.findChild(QCheckBox, "hideAccountIdentity").setChecked(True)
        QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
        assert "MiMo API" not in page.findChild(QLabel, "storedApiCredentialLabel").text()
        assert "Conta particular" not in page.findChild(
            QLabel, "storedApiCredentialLabel",
        ).text()

        page._confirm_remove_api_credential = lambda _entry: True
        page.findChild(QPushButton, "removeApiCredential").click()
        deadline = time.monotonic() + 3
        while page._credential_busy and time.monotonic() < deadline:
            qapp.processEvents()
            QTest.qWait(10)
        assert not page._credential_busy
        assert len(events) == 4
        assert all("secret-value-for-test" not in event.message() for event in events)
        assert all("Conta particular" not in event.message() for event in events)
        assert page.credential_vault.entries == ()
        assert secure_store.values == {}
        assert "não foi revogada" in page.findChild(QLabel, "credentialVaultStatus").text()
    finally:
        window.close()
        host_patcher.stop()


def test_credential_ui_fails_closed_when_secure_store_is_unavailable(
    qapp, tmp_path, monkeypatch,
):
    announcement_type = getattr(QtGui, "QAccessibleAnnouncementEvent", None)
    if announcement_type is None:
        pytest.skip("Qt announcement events require Qt 6.8 or newer")
    events = []
    monkeypatch.setattr(QAccessible, "isActive", staticmethod(lambda: True))
    monkeypatch.setattr(QAccessible, "updateAccessibility", staticmethod(events.append))
    window, host_patcher = _window(qapp)
    try:
        page = window.registry.page_for("Contas e conexões")
        secure_store = FakeCredentialStore(
            SecretStoreUnavailable("Secret Service backend is unavailable"),
        )
        credential_path = tmp_path / "credential-fixture" / "credentials.json"
        page.credential_vault = CredentialVault(credential_path, secure_store)

        _submit_api_credential(qapp, page, secret="never-display-this-secret")

        pending = page.credential_vault.entries
        assert len(pending) == 1
        assert pending[0].state == "pending"
        assert secure_store.values == {}
        assert "never-display-this-secret" not in credential_path.read_text(encoding="utf-8")
        assert "Gravação incerta" in page.findChild(
            QLabel, "credentialVaultStatus",
        ).text()
        assert len(events) == 2
        assert isinstance(events[-1], announcement_type)
        assert "Gravação incerta" in events[-1].message()
        assert "never-display-this-secret" not in events[-1].message()
        assert "referência mantida para limpeza" in page.findChild(
            QLabel, "storedApiCredentialState",
        ).text()

        secure_store.failure = None
        page._confirm_remove_api_credential = lambda _entry: True
        page.findChild(QPushButton, "removeApiCredential").click()
        deadline = time.monotonic() + 3
        while page._credential_busy and time.monotonic() < deadline:
            qapp.processEvents()
            QTest.qWait(10)
        assert not page._credential_busy
        assert len(events) == 4
        assert all("never-display-this-secret" not in event.message() for event in events)
        assert page.credential_vault.entries == ()
        assert json.loads(credential_path.read_text(encoding="utf-8"))["credentials"] == []
        assert secure_store.values == {}
        rendered = " ".join(
            widget.text() for widget in page.findChildren(QWidget) if hasattr(widget, "text")
        )
        assert "never-display-this-secret" not in rendered
    finally:
        window.close()
        host_patcher.stop()
