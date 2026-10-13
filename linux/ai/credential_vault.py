"""Private metadata registry for API credentials held in the OS secret store.

The registry stores only opaque references and user supplied labels. It does
not validate provider credentials, create sessions, enable connections, or
grant consumers access.
"""

from __future__ import annotations

import json
import os
import re
import stat
import tempfile
import threading
import unicodedata
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .account_contract import Account, public_account
from .secret_store import (
    SecretStoreUnavailable,
    default_secret_store,
    new_secret_reference,
)


_ACCOUNT_ID = re.compile(r"credential:[0-9a-f]{32}\Z")
_SECRET_REFERENCE = re.compile(r"(?:secret-service|wincred):[0-9a-f]{48}\Z")
_SCHEMA_VERSION = 1
_MAX_LABEL_LENGTH = 120
_MAX_SECRET_BYTES = 64 * 1024
_IS_WINDOWS = os.name == "nt"
_WINDOWS_METADATA_PREFIX = b"PZCRED1\x00"


class CredentialVaultError(RuntimeError):
    """Credential metadata could not be safely read or updated."""


def _label(value: object, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} must be text")
    if any(unicodedata.category(char) == "Cc" for char in value):
        raise ValueError(f"{name} must be 1–120 printable characters")
    value = value.strip()
    if not value or len(value) > _MAX_LABEL_LENGTH:
        raise ValueError(f"{name} must be 1–120 printable characters")
    return value


def _secret(value: object) -> str:
    if not isinstance(value, str) or not value or not value.strip():
        raise ValueError("API key must be non-empty text")
    if "\x00" in value or "\n" in value or "\r" in value:
        raise ValueError("API key must be a single line")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        raise ValueError("API key must be valid UTF-8 text") from None
    if size > _MAX_SECRET_BYTES:
        raise ValueError("API key exceeds secure-store limit")
    return value


def _stored_at(value: object) -> str:
    if not isinstance(value, str):
        raise CredentialVaultError("invalid credential timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise CredentialVaultError("invalid credential timestamp") from None
    if parsed.tzinfo is None:
        raise CredentialVaultError("invalid credential timestamp")
    return value


@dataclass(frozen=True)
class CredentialEntry:
    account: Account
    stored_at: str
    state: str = "active"

    def __post_init__(self) -> None:
        if not isinstance(self.account, Account):
            raise CredentialVaultError("invalid credential account")
        if not isinstance(self.account.account_id, str) or not _ACCOUNT_ID.fullmatch(self.account.account_id):
            raise CredentialVaultError("invalid credential account ID")
        if not isinstance(self.account.secret_ref, str) or not _SECRET_REFERENCE.fullmatch(self.account.secret_ref):
            raise CredentialVaultError("invalid secure-store reference")
        if _label(self.account.provider, "provider") != self.account.provider:
            raise CredentialVaultError("credential provider label is not normalized")
        if _label(self.account.nickname, "nickname") != self.account.nickname:
            raise CredentialVaultError("credential nickname is not normalized")
        _stored_at(self.stored_at)
        if not isinstance(self.state, str) or self.state not in {"pending", "active"}:
            raise CredentialVaultError("invalid credential registry state")

    @property
    def account_id(self) -> str:
        return self.account.account_id

    @property
    def provider(self) -> str:
        return self.account.provider

    @property
    def nickname(self) -> str:
        return self.account.nickname

    @property
    def secret_ref(self) -> str:
        return self.account.secret_ref

    def public(self) -> dict[str, str]:
        """Return display metadata without exposing the secret-store handle."""
        public = public_account(self.account)
        return {
            "accountId": str(public["accountId"]),
            "provider": str(public["provider"]),
            "nickname": str(public["nickname"]),
            "storedAt": self.stored_at,
            "state": self.state,
        }


class CredentialVault:
    """Store API keys in the OS vault; keep only opaque references on disk."""

    def __init__(
        self,
        path: Path,
        secret_store: Any | None = None,
        metadata_protector: Any | None = None,
    ) -> None:
        self.path = Path(path)
        self.secret_store = secret_store if secret_store is not None else default_secret_store()
        self._metadata_protector = metadata_protector
        self._lock = threading.RLock()
        self._entries: dict[str, CredentialEntry] = {}
        if self.path.exists():
            self._load()

    @property
    def entries(self) -> tuple[CredentialEntry, ...]:
        with self._lock:
            return tuple(sorted(self._entries.values(), key=lambda entry: entry.account_id))

    def add(self, provider: str, nickname: str, secret: str) -> CredentialEntry:
        provider = _label(provider, "provider")
        nickname = _label(nickname, "nickname")
        secret = _secret(secret)
        new_reference = getattr(self.secret_store, "new_reference", None)
        reference = new_reference() if callable(new_reference) else new_secret_reference()
        account = Account(
            account_id="credential:" + os.urandom(16).hex(),
            provider=provider,
            nickname=nickname,
            secret_ref=reference,
        )
        entry = CredentialEntry(
            account=account,
            stored_at=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            state="pending",
        )
        with self._lock:
            self._entries[entry.account_id] = entry
            try:
                self._save()
            except Exception:
                self._entries.pop(entry.account_id, None)
                raise CredentialVaultError("could not reserve credential reference") from None

        try:
            self.secret_store.store(reference, secret)
        except SecretStoreUnavailable:
            self._clear_pending_after_store_error(entry)
            raise
        except Exception:
            self._clear_pending_after_store_error(entry)
            raise CredentialVaultError("secure store could not save credential") from None

        active = replace(entry, state="active")
        with self._lock:
            self._entries[entry.account_id] = active
            try:
                self._save()
                return active
            except Exception:
                self._entries[entry.account_id] = entry

        try:
            self.secret_store.delete(reference)
        except Exception:
            raise CredentialVaultError(
                "credential state uncertain; cleanup reference remains pending",
            ) from None
        with self._lock:
            self._entries.pop(entry.account_id, None)
            try:
                self._save()
            except Exception:
                self._entries[entry.account_id] = entry
                raise CredentialVaultError(
                    "credential removed from vault; cleanup reference remains pending",
                ) from None
        raise CredentialVaultError("could not finalize credential reference") from None

    def _clear_pending_after_store_error(self, entry: CredentialEntry) -> None:
        try:
            self.secret_store.delete(entry.secret_ref)
        except Exception:
            raise CredentialVaultError(
                "secure store did not confirm; cleanup remains pending",
            ) from None
        with self._lock:
            self._entries.pop(entry.account_id, None)
            try:
                self._save()
            except Exception:
                self._entries[entry.account_id] = entry
                raise CredentialVaultError(
                    "secure store failed; cleanup reference remains pending",
                ) from None

    def remove(self, account_id: str) -> bool:
        with self._lock:
            entry = self._entries.get(account_id)
        if entry is None:
            return False
        try:
            removed_from_vault = bool(self.secret_store.delete(entry.secret_ref))
        except SecretStoreUnavailable:
            raise
        except Exception:
            raise CredentialVaultError("secure store could not delete credential") from None

        with self._lock:
            if self._entries.get(account_id) != entry:
                raise CredentialVaultError("credential reference changed during removal")
            self._entries.pop(account_id)
            try:
                self._save()
            except Exception:
                self._entries[account_id] = entry
                raise CredentialVaultError("could not remove credential reference") from None
        return removed_from_vault

    def _load(self) -> None:
        fd: int | None = None
        try:
            fd = os.open(self.path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            file_info = os.fstat(fd)
            if _IS_WINDOWS:
                reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
                path_info = self.path.lstat()
                directory_info = self.path.parent.lstat()
                if (
                    not stat.S_ISREG(file_info.st_mode)
                    or not stat.S_ISREG(path_info.st_mode)
                    or getattr(file_info, "st_file_attributes", 0) & reparse
                    or getattr(path_info, "st_file_attributes", 0) & reparse
                    or (file_info.st_dev, file_info.st_ino) != (path_info.st_dev, path_info.st_ino)
                    or not stat.S_ISDIR(directory_info.st_mode)
                    or getattr(directory_info, "st_file_attributes", 0) & reparse
                ):
                    raise CredentialVaultError("credential registry path is unsafe")
            else:
                directory_info = self.path.parent.stat()
                if (
                    not stat.S_ISREG(file_info.st_mode)
                    or file_info.st_uid != os.getuid()
                    or file_info.st_mode & 0o077
                    or directory_info.st_uid != os.getuid()
                    or directory_info.st_mode & 0o077
                ):
                    raise CredentialVaultError("credential registry permissions are unsafe")
            with os.fdopen(fd, "rb") as stream:
                fd = None
                payload = stream.read()
            if _IS_WINDOWS:
                payload = self._unprotect_metadata(payload)
            raw = json.loads(payload.decode("utf-8"))
        except CredentialVaultError:
            raise
        except (OSError, UnicodeError, json.JSONDecodeError):
            raise CredentialVaultError("credential registry is unavailable or invalid") from None
        finally:
            if fd is not None:
                os.close(fd)
        if (
            not isinstance(raw, dict)
            or set(raw) != {"schemaVersion", "credentials"}
            or type(raw.get("schemaVersion")) is not int
            or raw["schemaVersion"] != _SCHEMA_VERSION
            or not isinstance(raw.get("credentials"), list)
        ):
            raise CredentialVaultError("unsupported credential registry schema")

        for item in raw["credentials"]:
            if not isinstance(item, dict) or set(item) != {
                "accountId", "provider", "nickname", "secretRef", "storedAt", "state",
            }:
                raise CredentialVaultError("invalid credential record")
            entry = CredentialEntry(
                account=Account(
                    account_id=item["accountId"],
                    provider=item["provider"],
                    nickname=item["nickname"],
                    secret_ref=item["secretRef"],
                ),
                stored_at=item["storedAt"],
                state=item["state"],
            )
            if entry.account_id in self._entries:
                raise CredentialVaultError("duplicate credential account ID")
            if any(existing.secret_ref == entry.secret_ref for existing in self._entries.values()):
                raise CredentialVaultError("duplicate secure-store reference")
            self._entries[entry.account_id] = entry

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if _IS_WINDOWS:
            self._assert_windows_registry_path()
        else:
            os.chmod(self.path.parent, 0o700)
        payload = {
            "schemaVersion": _SCHEMA_VERSION,
            "credentials": [
                {
                    "accountId": entry.account_id,
                    "provider": entry.provider,
                    "nickname": entry.nickname,
                    "secretRef": entry.secret_ref,
                    "storedAt": entry.stored_at,
                    "state": entry.state,
                }
                for entry in self.entries
            ],
        }
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True).encode("utf-8")
        if _IS_WINDOWS:
            encoded = self._protect_metadata(encoded)
        fd, temp_name = tempfile.mkstemp(prefix=".credentials-", dir=self.path.parent)
        try:
            if not _IS_WINDOWS:
                os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, self.path)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)

    def _get_metadata_protector(self) -> Any:
        if self._metadata_protector is not None:
            return self._metadata_protector
        try:
            from .windows_credential_store import WindowsMetadataProtector

            self._metadata_protector = WindowsMetadataProtector()
            return self._metadata_protector
        except Exception:
            raise CredentialVaultError("Windows metadata protection is unavailable") from None

    def _protect_metadata(self, payload: bytes) -> bytes:
        try:
            return _WINDOWS_METADATA_PREFIX + self._get_metadata_protector().protect(payload)
        except CredentialVaultError:
            raise
        except Exception:
            raise CredentialVaultError("could not protect credential registry") from None

    def _unprotect_metadata(self, payload: bytes) -> bytes:
        if not payload.startswith(_WINDOWS_METADATA_PREFIX):
            raise CredentialVaultError("credential registry is not DPAPI protected")
        try:
            return self._get_metadata_protector().unprotect(payload[len(_WINDOWS_METADATA_PREFIX):])
        except CredentialVaultError:
            raise
        except Exception:
            raise CredentialVaultError("could not read protected credential registry") from None

    def _assert_windows_registry_path(self) -> None:
        reparse = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        try:
            parent_info = self.path.parent.lstat()
            if (
                not stat.S_ISDIR(parent_info.st_mode)
                or getattr(parent_info, "st_file_attributes", 0) & reparse
            ):
                raise CredentialVaultError("credential registry path is unsafe")
            try:
                file_info = self.path.lstat()
            except FileNotFoundError:
                file_info = None
            if file_info is not None:
                if (
                    not stat.S_ISREG(file_info.st_mode)
                    or getattr(file_info, "st_file_attributes", 0) & reparse
                ):
                    raise CredentialVaultError("credential registry path is unsafe")
        except CredentialVaultError:
            raise
        except OSError:
            raise CredentialVaultError("credential registry path is unavailable") from None
