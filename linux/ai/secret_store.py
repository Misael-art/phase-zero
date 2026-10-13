"""Fail-closed Secret Service adapter for opaque account credential handles.

Call synchronous methods from a worker, never from the UI thread. Secret
material is passed directly to libsecret; it is never placed in argv, labels,
references, logs, or PhaseZero-managed files.
"""

from __future__ import annotations

import os
import re
import secrets
from typing import Any


_REFERENCE_PREFIX = "secret-service:"
_REFERENCE_PATTERN = re.compile(r"secret-service:[0-9a-f]{48}\Z")
_SCHEMA_NAME = "org.phasezero.AccountCredential"
_ATTRIBUTE_NAME = "reference"
_ITEM_LABEL = "PhaseZero account credential"
_MAX_SECRET_BYTES = 64 * 1024
_IS_WINDOWS = os.name == "nt"


class SecretStoreUnavailable(RuntimeError):
    """Secure store missing, locked, or unable to complete an operation."""


def new_secret_reference() -> str:
    """Return a random handle. It contains no provider or account identity."""
    return _REFERENCE_PREFIX + secrets.token_hex(24)


def _load_secret_api() -> Any:
    try:
        import gi

        gi.require_version("Secret", "1")
        from gi.repository import Secret
    except Exception:
        raise SecretStoreUnavailable("Secret Service backend is unavailable") from None
    return Secret


def _validate_reference(reference: object) -> str:
    if not isinstance(reference, str) or not _REFERENCE_PATTERN.fullmatch(reference):
        raise ValueError("invalid Secret Service reference")
    return reference


def _validate_secret(secret: object) -> str:
    if not isinstance(secret, str) or not secret or "\x00" in secret:
        raise ValueError("credential must be non-empty text")
    try:
        size = len(secret.encode("utf-8"))
    except UnicodeError:
        raise ValueError("credential must be valid UTF-8 text") from None
    if size > _MAX_SECRET_BYTES:
        raise ValueError("credential exceeds secure-store limit")
    return secret


def default_secret_store() -> Any:
    """Return the native per-user store for the current operating system.

    Backend absence fails closed. Never substitute an unprotected file store.
    """
    if _IS_WINDOWS:
        from .windows_credential_store import WindowsCredentialManagerStore

        return WindowsCredentialManagerStore()
    return SecretServiceStore()


class SecretServiceStore:
    """Store and retrieve credentials using the user's Secret Service.

    References must come from :func:`new_secret_reference`. A missing
    Secret Service never falls back to plaintext storage.
    """

    def __init__(self, secret_api: Any | None = None) -> None:
        self._secret_api = secret_api
        self._schema: Any | None = None

    def _api(self) -> Any:
        if self._secret_api is None:
            try:
                self._secret_api = _load_secret_api()
            except SecretStoreUnavailable:
                raise
            except Exception:
                raise SecretStoreUnavailable("Secret Service backend is unavailable") from None
        if self._schema is None:
            try:
                self._schema = self._secret_api.Schema.new(
                    _SCHEMA_NAME,
                    self._secret_api.SchemaFlags.NONE,
                    {_ATTRIBUTE_NAME: self._secret_api.SchemaAttributeType.STRING},
                )
            except Exception:
                raise SecretStoreUnavailable("Secret Service backend is unavailable") from None
        return self._secret_api

    def store(self, reference: str, secret: str) -> None:
        reference = _validate_reference(reference)
        secret = _validate_secret(secret)
        api = self._api()
        try:
            stored = api.password_store_sync(
                self._schema,
                {_ATTRIBUTE_NAME: reference},
                api.COLLECTION_DEFAULT,
                _ITEM_LABEL,
                secret,
                None,
            )
        except Exception:
            raise SecretStoreUnavailable("Secret Service could not store credential") from None
        if not stored:
            raise SecretStoreUnavailable("Secret Service could not store credential")

    def lookup(self, reference: str) -> str | None:
        reference = _validate_reference(reference)
        api = self._api()
        try:
            secret = api.password_lookup_sync(
                self._schema, {_ATTRIBUTE_NAME: reference}, None,
            )
        except Exception:
            raise SecretStoreUnavailable("Secret Service could not read credential") from None
        if secret is None:
            return None
        if not isinstance(secret, str):
            raise SecretStoreUnavailable("Secret Service returned invalid credential data")
        return secret

    def delete(self, reference: str) -> bool:
        """Delete matching credential; return False when handle had no item."""
        reference = _validate_reference(reference)
        api = self._api()
        try:
            return bool(api.password_clear_sync(
                self._schema, {_ATTRIBUTE_NAME: reference}, None,
            ))
        except Exception:
            raise SecretStoreUnavailable("Secret Service could not delete credential") from None
