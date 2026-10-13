from __future__ import annotations

import ctypes

import pytest

from linux.ai import secret_store
from linux.ai import windows_credential_store as windows_store
from linux.ai.secret_store import SecretStoreUnavailable
from linux.ai.windows_credential_store import WindowsCredentialManagerStore


class _MemoryCredentialManager:
    def __init__(self):
        self.items: dict[str, bytes] = {}
        self.calls: list[tuple[str, str]] = []
        self.failure: Exception | None = None

    def write(self, target: str, blob: bytearray) -> None:
        self.calls.append(("write", target))
        if self.failure is not None:
            raise self.failure
        self.items[target] = bytes(blob)

    def read(self, target: str) -> bytearray | None:
        self.calls.append(("read", target))
        if self.failure is not None:
            raise self.failure
        value = self.items.get(target)
        return None if value is None else bytearray(value)

    def delete(self, target: str) -> bool:
        self.calls.append(("delete", target))
        if self.failure is not None:
            raise self.failure
        return self.items.pop(target, None) is not None


def test_windows_credential_store_uses_random_generic_target_and_round_trips():
    api = _MemoryCredentialManager()
    store = WindowsCredentialManagerStore(api)
    reference = store.new_reference()
    secret = "credential-value-never-in-target"

    assert reference.startswith("wincred:")
    assert reference != store.new_reference()
    store.store(reference, secret)

    target = "PhaseZero:AccountCredential:" + reference.split(":", 1)[1]
    assert api.items == {target: secret.encode("utf-8")}
    assert secret not in target
    assert store.lookup(reference) == secret
    assert store.delete(reference) is True
    assert store.delete(reference) is False
    assert all(secret not in call for call in api.calls)


def test_windows_credential_store_rejects_invalid_handles_and_oversized_values():
    api = _MemoryCredentialManager()
    store = WindowsCredentialManagerStore(api)

    with pytest.raises(ValueError, match="invalid Windows Credential Manager reference"):
        store.lookup("wincred:../../escape")
    reference = store.new_reference()
    with pytest.raises(ValueError, match="Windows Credential Manager limit"):
        store.store(reference, "x" * (5 * 512 + 1))
    assert api.calls == []


def test_windows_credential_store_sanitizes_native_failures():
    secret = "sensitive-native-error"
    api = _MemoryCredentialManager()
    api.failure = RuntimeError(secret)
    store = WindowsCredentialManagerStore(api)

    with pytest.raises(SecretStoreUnavailable) as raised:
        store.store(store.new_reference(), "credential-value")
    assert secret not in str(raised.value)
    assert raised.value.__cause__ is None


def test_windows_credential_store_default_selection_has_no_plaintext_fallback(monkeypatch):
    api = _MemoryCredentialManager()
    monkeypatch.setattr(secret_store, "_IS_WINDOWS", True)
    monkeypatch.setattr(windows_store, "_CredentialManagerApi", lambda: api)

    selected = secret_store.default_secret_store()

    assert isinstance(selected, WindowsCredentialManagerStore)
    assert selected._api is api


def test_windows_native_struct_layout_matches_wincred_abi_pointer_width():
    pointer_size = ctypes.sizeof(ctypes.c_void_p)
    expected_credential_size = 80 if pointer_size == 8 else 52
    expected_blob_size = 16 if pointer_size == 8 else 8

    assert ctypes.sizeof(windows_store._CredentialW) == expected_credential_size
    assert ctypes.sizeof(windows_store._DataBlob) == expected_blob_size


def test_dpapi_input_blob_preserves_exact_payload_without_string_buffer_overread():
    payload = b'{"schemaVersion":1,"credentials":[]}'

    buffer, blob = windows_store._input_data_blob(payload)

    assert blob.cbData == len(payload)
    assert ctypes.string_at(blob.pbData, blob.cbData) == payload
    ctypes.memset(buffer, 0, len(payload))
    assert ctypes.string_at(blob.pbData, blob.cbData) == b"\0" * len(payload)
