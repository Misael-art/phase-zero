from __future__ import annotations

from types import SimpleNamespace

import pytest

from linux.ai import secret_store
from linux.ai.secret_store import SecretServiceStore, SecretStoreUnavailable, new_secret_reference


class _Schema:
    @staticmethod
    def new(name, flags, attributes):
        return (name, flags, attributes)


class _FakeSecretAPI:
    Schema = _Schema
    SchemaFlags = SimpleNamespace(NONE=0)
    SchemaAttributeType = SimpleNamespace(STRING="string")
    COLLECTION_DEFAULT = "default"

    def __init__(self):
        self.values = {}
        self.calls = []
        self.failure = None
        self.store_result = True

    def _check(self):
        if self.failure is not None:
            raise RuntimeError(str(self.failure))

    def password_store_sync(self, schema, attributes, collection, label, password, cancellable):
        self._check()
        self.calls.append(("store", schema, attributes, collection, label, password, cancellable))
        if self.store_result:
            self.values[attributes["reference"]] = password
        return self.store_result

    def password_lookup_sync(self, schema, attributes, cancellable):
        self._check()
        self.calls.append(("lookup", schema, attributes, cancellable))
        return self.values.get(attributes["reference"])

    def password_clear_sync(self, schema, attributes, cancellable):
        self._check()
        self.calls.append(("delete", schema, attributes, cancellable))
        return self.values.pop(attributes["reference"], None) is not None


def test_secret_service_store_uses_opaque_reference_and_is_idempotent():
    api = _FakeSecretAPI()
    store = SecretServiceStore(api)
    reference = new_secret_reference()

    assert reference.startswith("secret-service:")
    assert reference != new_secret_reference()
    store.store(reference, "private-token-value")
    store.store(reference, "replacement-test-value")

    assert store.lookup(reference) == "replacement-test-value"
    assert store.lookup(new_secret_reference()) is None
    assert len(api.values) == 1
    assert store.delete(reference)
    assert not store.delete(reference)
    assert all(call[3] == "default" for call in api.calls if call[0] == "store")
    assert all(call[4] == "PhaseZero account credential" for call in api.calls if call[0] == "store")
    assert "private-token-value" not in reference
    assert all("private-token-value" not in repr(call[2:5]) for call in api.calls if call[0] == "store")


def test_secret_service_rejects_invalid_handles_and_values_before_backend_call():
    api = _FakeSecretAPI()
    store = SecretServiceStore(api)
    reference = new_secret_reference()

    for invalid in ("keyring:some-handle", "secret-service:../../escape", "secret-service:"):
        with pytest.raises(ValueError, match="invalid Secret Service reference"):
            store.lookup(invalid)
    for invalid in ("", "contains\x00nul", "x" * (64 * 1024 + 1)):
        with pytest.raises(ValueError):
            store.store(reference, invalid)
    assert api.calls == []


def test_secret_service_failures_are_sanitized_and_never_fall_back(monkeypatch):
    api = _FakeSecretAPI()
    store = SecretServiceStore(api)
    reference = new_secret_reference()
    secret = "do-not-echo-this-credential"
    api.failure = secret

    with pytest.raises(SecretStoreUnavailable) as raised:
        store.store(reference, secret)
    assert secret not in str(raised.value)
    assert raised.value.__cause__ is None

    api.failure = None
    api.store_result = False
    with pytest.raises(SecretStoreUnavailable, match="could not store credential"):
        store.store(reference, secret)

    def missing_backend():
        raise RuntimeError(secret)

    monkeypatch.setattr(secret_store, "_load_secret_api", missing_backend)
    with pytest.raises(SecretStoreUnavailable, match="backend is unavailable") as unavailable:
        SecretServiceStore().lookup(reference)
    assert secret not in str(unavailable.value)
    assert unavailable.value.__cause__ is None
