from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone

import pytest

from linux.ai import deepseek_harness_manager as harness
from linux.ai.credential_inventory import display_id, needs_review, observe_managed_uses, remove_local_credential, stored_days
from linux.ai.credential_vault import CredentialVault, CredentialVaultError


class Store:
    def __init__(self):
        self.deleted = []

    def store(self, *_args):
        pass

    def lookup(self, *_args):
        pytest.fail("inventory must not read a secret")

    def delete(self, reference):
        self.deleted.append(reference)
        return True


def test_stored_age_is_not_provider_age_or_validity(tmp_path):
    vault = CredentialVault(tmp_path / "wallet/credentials.json", Store())
    entry = vault.add("deepseek", "Development", "controlled-test-value")
    entry = replace(entry, stored_at="2026-01-01T00:00:00Z")
    now = datetime(2026, 4, 1, tzinfo=timezone.utc)
    assert stored_days(entry, now) == 90
    assert needs_review(entry, now)
    assert entry.state == "active"
    assert display_id(entry) == display_id(entry)
    assert entry.secret_ref not in display_id(entry)
    assert entry.account_id not in display_id(entry)


def test_metadata_reload_observes_external_add_and_remove_without_secret_lookup(tmp_path):
    path = tmp_path / "wallet/credentials.json"
    first = CredentialVault(path, Store())
    other = CredentialVault(path, Store())
    entry = other.add("openai", "Other client", "controlled-test-value")
    first.reload_metadata()
    assert first.entries == (entry,)
    other.remove(entry.account_id)
    first.reload_metadata()
    assert first.entries == ()


def test_failed_metadata_refresh_does_not_replace_last_good_snapshot(tmp_path):
    path = tmp_path / "wallet/credentials.json"
    vault = CredentialVault(path, Store())
    entry = vault.add("openai", "Saved", "controlled-test-value")
    path.write_text("{invalid")
    with pytest.raises(CredentialVaultError):
        vault.reload_metadata()
    assert vault.entries == (entry,)


def test_absent_harness_has_no_claimed_usage_or_filesystem_writes(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_DSH_ROOT", str(tmp_path / "absent"))
    assert observe_managed_uses() == ()
    assert not harness.app_root().exists()


def test_usage_projection_binds_only_exact_selected_key(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_DSH_ROOT", str(tmp_path / "harness"))
    harness._atomic_json(harness.state_file(), {})
    monkeypatch.setattr(harness, "status_payload", lambda: {
        "authRoute": "api", "apiCredentialId": "credential:" + "a" * 32,
        "runtimeState": "running", "processId": 123,
        "requestedWorkspace": "/controlled/project", "observedAt": "2026-11-07T12:00:00Z",
    })
    use, = observe_managed_uses()
    assert use.account_id == "credential:" + "a" * 32
    assert use.running and use.process_id == 123
    assert use.project == "/controlled/project"


def test_remove_stops_selected_consumer_before_native_deletion_under_owner_lock(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_DSH_ROOT", str(tmp_path / "harness"))
    vault = CredentialVault(tmp_path / "wallet/credentials.json", Store())
    entry = vault.add("deepseek", "Saved", "controlled-test-value")
    harness._atomic_json(harness.state_file(), {"authRoute": "api", "apiCredentialId": entry.account_id})
    events = []

    def stop():
        events.append("stop")
        # A concurrent start must remain excluded while revocation runs.
        with pytest.raises(harness.DshError, match="Another Harness operation"):
            with harness._operation_lock():
                pass

    monkeypatch.setattr(harness, "_stop_supervisor", stop)
    original_delete = vault.secret_store.delete

    def delete(reference):
        assert events == ["stop"]
        assert harness._load_json(harness.state_file(), {})["apiCredentialId"] == ""
        events.append("delete")
        return original_delete(reference)

    vault.secret_store.delete = delete
    assert remove_local_credential(vault, entry.account_id)
    assert events == ["stop", "delete"]
    assert vault.entries == ()


def test_stop_failure_preserves_key_and_binding(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_DSH_ROOT", str(tmp_path / "harness"))
    store = Store()
    vault = CredentialVault(tmp_path / "wallet/credentials.json", store)
    entry = vault.add("deepseek", "Saved", "controlled-test-value")
    harness._atomic_json(harness.state_file(), {"authRoute": "api", "apiCredentialId": entry.account_id})

    def stop():
        raise harness.DshError("stop-timeout", "Controlled stop failure")

    monkeypatch.setattr(harness, "_stop_supervisor", stop)
    with pytest.raises(harness.DshError):
        remove_local_credential(vault, entry.account_id)
    assert vault.entries == (entry,)
    assert store.deleted == []
    assert harness._load_json(harness.state_file(), {})["apiCredentialId"] == entry.account_id


def test_revoking_other_key_preserves_current_consumer(tmp_path, monkeypatch):
    monkeypatch.setenv("PZ_DSH_ROOT", str(tmp_path / "harness"))
    selected, other = "credential:" + "a" * 32, "credential:" + "b" * 32
    harness._atomic_json(harness.state_file(), {"authRoute": "api", "apiCredentialId": selected})
    monkeypatch.setattr(harness, "_stop_supervisor", lambda: pytest.fail("unrelated consumer stopped"))
    assert harness.revoke_wallet_use(other)
    assert harness._load_json(harness.state_file(), {})["apiCredentialId"] == selected
