import json
import pytest
from PySide6.QtWidgets import QApplication, QDialog
from linux.ai.api_credits import ApiCredit, openai_allowance
from linux.ai.credential_vault import CredentialVault, CredentialVaultError
from linux.ui_native.api_credit_dialog import ApiCreditDialog
from tests.test_credential_vault import MemorySecretStore, FakeMetadataProtector


def observed(**values):
    return ApiCredit(provider="openai", organization="org-example", activation="active",
                     observed_at="2026-11-07T12:00:00Z", **values)


@pytest.mark.parametrize("plan,amount", [("plus", None), ("go", None), ("enterprise", None), ("pro-100", 100), ("pro-200", 200), ("pro-500", 500)])
def test_allowance_is_documented_eligibility_not_account_balance(plan, amount):
    assert openai_allowance(plan) == amount
    assert observed().remaining is None


def test_business_cap_and_invalid_seats():
    assert openai_allowance("business", standard_seats=5, premium_seats=3) == 400
    assert openai_allowance("business", standard_seats=10, premium_seats=4) == 500
    with pytest.raises(ValueError): openai_allowance("business", standard_seats=True)


@pytest.mark.parametrize("value", [-1, float("nan"), float("inf"), True, "100"])
def test_bad_amounts_never_become_balances(value):
    with pytest.raises(ValueError): observed(remaining=value)


def test_zero_expiration_and_unknown_are_distinct():
    assert observed().state == "active" and "não informado" in observed().display()
    assert observed(remaining=0).state == "exhausted"
    assert observed(remaining=20, expires_at="2020-01-01T00:00:00Z").state == "expired"
    with pytest.raises(ValueError): observed(total=10, remaining=20)
    with pytest.raises(ValueError): observed(expires_at="2026-11-07")


def test_v1_migration_shared_org_reload_and_removal_keep_one_credit_account(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    store = MemorySecretStore(); path = tmp_path / "wallet/credentials.json"
    vault = CredentialVault(path, store)
    one = vault.add("openai", "one", "not-in-metadata-one")
    two = vault.add("OpenAI", "two", "not-in-metadata-two")
    before = path.read_bytes()
    assert json.loads(before)["schemaVersion"] == 1
    vault.record_api_credit(one.account_id, observed(total=100, remaining=80))
    vault.record_api_credit(two.account_id, observed(total=100, remaining=70))
    reopened = CredentialVault(path, store)
    assert reopened.api_credit(one.account_id).remaining == 70
    assert reopened.api_credit(two.account_id).remaining == 70
    raw = json.loads(path.read_text())
    assert len(raw["apiCredits"]["accounts"]) == 1
    assert b"not-in-metadata" not in path.read_bytes()
    from linux.lib.pz_hostbackup import latest_backup
    assert latest_backup(path).read_bytes() == before
    assert vault.remove(one.account_id)
    reopened.reload_metadata()
    assert reopened.api_credit(one.account_id) is None
    assert reopened.api_credit(two.account_id).remaining == 70


def test_provider_mismatch_and_damaged_binding_are_rejected(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    store = MemorySecretStore(); path = tmp_path / "wallet/credentials.json"
    vault = CredentialVault(path, store); entry = vault.add("anthropic", "one", "secret")
    with pytest.raises(CredentialVaultError): vault.record_api_credit(entry.account_id, observed())
    entry = vault.add("openai", "two", "secret")
    vault.record_api_credit(entry.account_id, observed())
    data = json.loads(path.read_text()); data["apiCredits"]["bindings"][entry.account_id] = "missing"
    path.write_text(json.dumps(data))
    with pytest.raises(CredentialVaultError, match="credit metadata"): CredentialVault(path, store)


def test_failed_metadata_update_rolls_back_observation(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    vault = CredentialVault(tmp_path / "wallet/credentials.json", MemorySecretStore())
    entry = vault.add("openai", "one", "secret")
    monkeypatch.setattr(vault, "_save", lambda: (_ for _ in ()).throw(OSError("unavailable")))
    with pytest.raises(OSError): vault.record_api_credit(entry.account_id, observed())
    assert vault.api_credit(entry.account_id) is None


def test_credit_metadata_keeps_windows_dpapi_protection(tmp_path, monkeypatch):
    from linux.ai import credential_vault as module
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr(module, "_IS_WINDOWS", True)
    store = MemorySecretStore(); path = tmp_path / "wallet/credentials.dpapi"
    vault = CredentialVault(path, store, FakeMetadataProtector())
    entry = vault.add("openai", "one", "secret")
    vault.record_api_credit(entry.account_id, observed(remaining=10))
    assert b"org-example" not in path.read_bytes()
    assert CredentialVault(path, store, FakeMetadataProtector()).api_credit(entry.account_id).remaining == 10


def test_dialog_does_not_invent_grant_or_mark_manual_entry_official():
    app = QApplication.instance() or QApplication([])
    dialog = ApiCreditDialog("openai")
    dialog.organization.setText("org-example")
    assert dialog.values().activation == "unknown"
    assert dialog.values().remaining is None and dialog.values().source == "user_reported"
    dialog.remaining.setText("100")
    dialog.validate()
    assert dialog.result() != QDialog.Accepted
    dialog.activation.setCurrentIndex(dialog.activation.findData("active"))
    assert dialog.values().remaining == 100
    dialog.reject()


def test_opencode_credit_status_does_not_read_keys_or_change_default(tmp_path, monkeypatch):
    from linux.ai.opencode_9router_manager import OpenCodeManager
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    path = tmp_path / "config/opencode/opencode.json"
    path.parent.mkdir(parents=True); path.write_text('{"model":"existing/model"}')
    before = path.read_bytes()
    manager = OpenCodeManager()
    result = manager.openai_credit_status()
    assert result["registeredKeys"] == 0 and result["balanceVerified"] is False
    assert result["executionVerified"] is False and result["defaultChanged"] is False
    assert path.read_bytes() == before


def test_wallet_details_show_shared_credit_provenance_without_organization_in_privacy(tmp_path, monkeypatch):
    from linux.ui_native.credential_manager import CredentialManager
    from PySide6.QtWidgets import QLabel, QPushButton
    app = QApplication.instance() or QApplication([])
    vault = CredentialVault(tmp_path / "wallet/credentials.json", MemorySecretStore())
    entry = vault.add("openai", "private account", "secret")
    panel = CredentialManager(); panel.credits = {entry.account_id: observed(remaining=25)}
    panel.set_entries((entry,)); panel._select(entry.account_id)
    assert "Compartilhado pela organização" in panel.findChild(QLabel, "apiCreditState").text()
    requested=[]; panel.credit_requested.connect(requested.append)
    panel.findChild(QPushButton, "recordApiCredit").click(); assert requested == [entry.account_id]
    panel.set_entries((entry,), hidden=True)
    assert "org-example" not in " ".join(w.text() for w in panel.detail.findChildren(QLabel) if not w.isHidden())
    panel.close()


def test_credit_forms_keep_controls_reachable_with_large_text():
    from PySide6.QtGui import QFont
    from PySide6.QtWidgets import QScrollArea, QDialogButtonBox
    from linux.ui_native.api_credit_dialog import OpenCodeApiDialog
    app = QApplication.instance() or QApplication([])
    original = QFont(app.font()); large = QFont(original)
    large.setPointSizeF(original.pointSizeF() * 2)
    app.setFont(large)
    try:
        for dialog in [ApiCreditDialog("openai"), OpenCodeApiDialog()]:
            dialog.show(); app.processEvents()
            area = dialog.findChild(QScrollArea)
            assert area.horizontalScrollBar().maximum() == 0
            assert dialog.findChild(QDialogButtonBox).isVisible()
            dialog.close()
    finally:
        app.setFont(original)
