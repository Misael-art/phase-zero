from __future__ import annotations

import os
import secrets

import pytest

from linux.ai.windows_credential_store import (
    WindowsCredentialManagerStore,
    WindowsMetadataProtector,
)


def test_native_windows_credential_manager_round_trips_and_deletes_temporary_secret():
    if os.name != "nt":
        pytest.skip("native Credential Manager smoke runs only on disposable Windows CI")

    store = WindowsCredentialManagerStore()
    reference = store.new_reference()
    synthetic_secret = "pz-ci-" + secrets.token_hex(24)
    try:
        assert store.lookup(reference) is None
        store.store(reference, synthetic_secret)
        stored = store.lookup(reference)
        assert stored is not None and secrets.compare_digest(stored, synthetic_secret)
    finally:
        store.delete(reference)

    assert store.lookup(reference) is None


def test_native_windows_dpapi_protects_and_restores_temporary_metadata():
    if os.name != "nt":
        pytest.skip("native DPAPI smoke runs only on disposable Windows CI")

    protector = WindowsMetadataProtector()
    payload = b'{"schemaVersion":1,"credentials":["synthetic-ci-marker"]}'

    protected = protector.protect(payload)

    assert protected != payload
    restored = protector.unprotect(protected)
    assert secrets.compare_digest(restored, payload)
