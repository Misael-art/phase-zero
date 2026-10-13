import json

import pytest

from linux.ai import credential_vault as credential_vault_module
from linux.ai.credential_vault import CredentialVault, CredentialVaultError
from linux.ai.secret_store import SecretStoreUnavailable


class MemorySecretStore:
    def __init__(self):
        self.items = {}
        self.fail_store = None
        self.fail_after_store = None
        self.fail_delete = None

    def store(self, reference, secret):
        if self.fail_store is not None:
            raise self.fail_store
        self.items[reference] = secret
        if self.fail_after_store is not None:
            raise self.fail_after_store

    def delete(self, reference):
        if self.fail_delete is not None:
            raise self.fail_delete
        return self.items.pop(reference, None) is not None


class WindowsReferenceMemoryStore(MemorySecretStore):
    def new_reference(self):
        return "wincred:" + ("a1" * 24)


class FakeMetadataProtector:
    def protect(self, payload):
        return bytes(byte ^ 0xA5 for byte in payload)

    def unprotect(self, payload):
        return bytes(byte ^ 0xA5 for byte in payload)


def test_vault_stores_secret_only_in_secure_store_and_private_metadata(tmp_path):
    path = tmp_path / "phasezero" / "ai-accounts" / "credentials.json"
    secure_store = MemorySecretStore()
    vault = CredentialVault(path, secure_store)

    entry = vault.add("MiMo API", "Conta principal", "secret-value-never-on-disk")

    raw = path.read_text(encoding="utf-8")
    assert secure_store.items == {entry.secret_ref: "secret-value-never-on-disk"}
    assert "secret-value-never-on-disk" not in raw
    assert entry.secret_ref in raw
    assert entry.public() == {
        "accountId": entry.account_id,
        "provider": "MiMo API",
        "nickname": "Conta principal",
        "storedAt": entry.stored_at,
        "state": "active",
    }
    assert path.stat().st_mode & 0o777 == 0o600
    assert path.parent.stat().st_mode & 0o777 == 0o700

    reopened = CredentialVault(path, secure_store)
    assert reopened.entries == (entry,)


def test_windows_store_reference_round_trips_through_vault(tmp_path):
    secure_store = WindowsReferenceMemoryStore()
    protector = FakeMetadataProtector()
    path = tmp_path / "credentials.json"
    vault = CredentialVault(path, secure_store, metadata_protector=protector)

    entry = vault.add("Provider", "Conta", "credential-value")
    reopened = CredentialVault(path, secure_store, metadata_protector=protector)

    assert entry.secret_ref.startswith("wincred:")
    assert reopened.entries == (entry,)
    assert secure_store.items == {entry.secret_ref: "credential-value"}


def test_windows_registry_metadata_is_dpapi_enveloped_and_reopens(tmp_path, monkeypatch):
    monkeypatch.setattr(credential_vault_module, "_IS_WINDOWS", True)
    protector = FakeMetadataProtector()
    secure_store = MemorySecretStore()
    path = tmp_path / "PhaseZero" / "ai-accounts" / "credentials.dpapi"
    vault = CredentialVault(path, secure_store, metadata_protector=protector)

    entry = vault.add("Provider", "Private nickname", "secret-outside-registry")
    raw = path.read_bytes()

    assert raw.startswith(credential_vault_module._WINDOWS_METADATA_PREFIX)
    assert b"Private nickname" not in raw
    assert b"secret-outside-registry" not in raw
    reopened = CredentialVault(path, secure_store, metadata_protector=protector)
    assert reopened.entries == (entry,)


def test_windows_registry_rejects_unprotected_metadata(tmp_path, monkeypatch):
    monkeypatch.setattr(credential_vault_module, "_IS_WINDOWS", True)
    path = tmp_path / "credentials.dpapi"
    path.write_text('{"schemaVersion":1,"credentials":[]}', encoding="utf-8")

    with pytest.raises(CredentialVaultError, match="not DPAPI protected"):
        CredentialVault(path, MemorySecretStore(), metadata_protector=FakeMetadataProtector())


def test_failed_backend_store_clears_reserved_metadata(tmp_path):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    secure_store.fail_store = SecretStoreUnavailable("Secret Service backend is unavailable")
    vault = CredentialVault(path, secure_store)

    with pytest.raises(SecretStoreUnavailable, match="backend is unavailable"):
        vault.add("MiMo API", "Conta", "secret-value")

    assert json.loads(path.read_text(encoding="utf-8"))["credentials"] == []
    assert secure_store.items == {}


def test_ambiguous_backend_store_failure_attempts_secure_item_cleanup(tmp_path):
    secure_store = MemorySecretStore()
    secure_store.fail_after_store = SecretStoreUnavailable("Secret Service could not store credential")
    vault = CredentialVault(tmp_path / "credentials.json", secure_store)

    with pytest.raises(SecretStoreUnavailable, match="could not store"):
        vault.add("MiMo API", "Conta", "secret-value")

    assert secure_store.items == {}
    assert json.loads((tmp_path / "credentials.json").read_text(encoding="utf-8"))["credentials"] == []


def test_activation_metadata_failure_rolls_back_stored_item_and_hides_os_error(tmp_path, monkeypatch):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    vault = CredentialVault(path, secure_store)
    original_save = vault._save
    saves = 0

    def fail_save():
        nonlocal saves
        saves += 1
        if saves == 2:
            raise OSError("disk path must not leak")
        original_save()

    monkeypatch.setattr(vault, "_save", fail_save)
    with pytest.raises(CredentialVaultError, match="could not finalize credential") as raised:
        vault.add("MiMo API", "Conta", "secret-value")

    assert "disk path" not in str(raised.value)
    assert secure_store.items == {}
    assert vault.entries == ()


def test_failed_cleanup_keeps_pending_reference_for_safe_retry(tmp_path):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    secure_store.fail_after_store = SecretStoreUnavailable("store confirmation lost")
    secure_store.fail_delete = SecretStoreUnavailable("vault temporarily unavailable")
    vault = CredentialVault(path, secure_store)

    with pytest.raises(CredentialVaultError, match="cleanup remains pending"):
        vault.add("MiMo API", "Conta", "secret-value")

    pending = vault.entries[0]
    assert pending.state == "pending"
    assert secure_store.items == {pending.secret_ref: "secret-value"}
    assert pending.secret_ref in path.read_text(encoding="utf-8")

    secure_store.fail_after_store = None
    secure_store.fail_delete = None
    reopened = CredentialVault(path, secure_store)
    assert reopened.entries == (pending,)
    assert reopened.remove(pending.account_id) is True
    assert reopened.entries == ()
    assert secure_store.items == {}


def test_failed_reservation_does_not_call_secure_store(tmp_path, monkeypatch):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    vault = CredentialVault(path, secure_store)

    monkeypatch.setattr(vault, "_save", lambda: (_ for _ in ()).throw(OSError("disk")))
    with pytest.raises(CredentialVaultError, match="could not reserve"):
        vault.add("MiMo API", "Conta", "secret-value")

    assert secure_store.items == {}
    assert vault.entries == ()


def test_remove_deletes_only_matching_vault_item_and_metadata(tmp_path):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    vault = CredentialVault(path, secure_store)
    first = vault.add("Provider A", "A", "secret-a")
    second = vault.add("Provider B", "B", "secret-b")

    assert vault.remove(first.account_id) is True
    assert first.secret_ref not in secure_store.items
    assert secure_store.items == {second.secret_ref: "secret-b"}
    assert vault.entries == (second,)
    assert vault.remove(first.account_id) is False


def test_remove_backend_failure_preserves_metadata(tmp_path):
    path = tmp_path / "credentials.json"
    secure_store = MemorySecretStore()
    vault = CredentialVault(path, secure_store)
    entry = vault.add("Provider", "Conta", "secret-a")
    secure_store.fail_delete = SecretStoreUnavailable("Secret Service could not delete credential")

    with pytest.raises(SecretStoreUnavailable, match="could not delete"):
        vault.remove(entry.account_id)

    assert vault.entries == (entry,)
    assert entry.secret_ref in path.read_text(encoding="utf-8")


@pytest.mark.parametrize("payload", [
    "not-json",
    "[]",
    '{"schemaVersion":true,"credentials":[]}',
    '{"schemaVersion":1,"credentials":[null]}',
    '{"schemaVersion":1,"credentials":[{"accountId":"bad","provider":"P","nickname":"N","secretRef":"/tmp/key","storedAt":"2026-09-25T10:00:00Z"}]}',
])
def test_malformed_or_unsafe_metadata_fails_closed(tmp_path, payload):
    path = tmp_path / "credentials.json"
    path.write_text(payload, encoding="utf-8")
    path.chmod(0o600)

    with pytest.raises((CredentialVaultError, ValueError)):
        CredentialVault(path, MemorySecretStore())


def test_existing_metadata_with_broad_permissions_fails_closed(tmp_path):
    directory = tmp_path / "xdg"
    directory.mkdir()
    path = directory / "credentials.json"
    path.write_text('{"schemaVersion":1,"credentials":[]}', encoding="utf-8")
    path.chmod(0o600)
    directory.chmod(0o755)

    with pytest.raises(CredentialVaultError, match="permissions are unsafe"):
        CredentialVault(path, MemorySecretStore())


def test_registry_symlink_is_not_followed(tmp_path):
    target = tmp_path / "target.json"
    target.write_text('{"schemaVersion":1,"credentials":[]}', encoding="utf-8")
    target.chmod(0o600)
    path = tmp_path / "credentials.json"
    path.symlink_to(target)

    with pytest.raises(CredentialVaultError, match="unavailable or invalid"):
        CredentialVault(path, MemorySecretStore())


def test_invalid_user_input_never_reaches_secure_store(tmp_path):
    secure_store = MemorySecretStore()
    vault = CredentialVault(tmp_path / "credentials.json", secure_store)

    for provider, nickname, secret in (
        ("", "Conta", "key"),
        ("Provider", "\nConta", "key"),
        ("Provider", "Conta", ""),
        ("Provider", "Conta", "contains\x00nul"),
    ):
        with pytest.raises(ValueError):
            vault.add(provider, nickname, secret)

    assert secure_store.items == {}
    assert not (tmp_path / "credentials.json").exists()
