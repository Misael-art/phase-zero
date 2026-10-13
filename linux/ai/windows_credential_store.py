"""Windows Credential Manager adapter for opaque account credential handles.

Credentials use the per-user generic credential set. Target names contain only
random references; provider labels and account identity stay in the private
metadata registry. Call synchronous methods from a worker, never the UI thread.
"""

from __future__ import annotations

import ctypes
import os
import re
import secrets
from ctypes import wintypes
from typing import Any

from .secret_store import SecretStoreUnavailable, _validate_secret


_REFERENCE_PATTERN = re.compile(r"wincred:[0-9a-f]{48}\Z")
_REFERENCE_PREFIX = "wincred:"
_TARGET_PREFIX = "PhaseZero:AccountCredential:"
_COMMENT = "PhaseZero account credential"
_CRED_TYPE_GENERIC = 1
_CRED_PERSIST_LOCAL_MACHINE = 2
_CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512
_ERROR_NOT_FOUND = 1168
_CRYPTPROTECT_UI_FORBIDDEN = 0x1


class _FileTime(ctypes.Structure):
    _fields_ = [("dwLowDateTime", ctypes.c_uint32), ("dwHighDateTime", ctypes.c_uint32)]


class _CredentialAttributeW(ctypes.Structure):
    _fields_ = [
        ("Keyword", ctypes.c_wchar_p),
        ("Flags", ctypes.c_uint32),
        ("ValueSize", ctypes.c_uint32),
        ("Value", ctypes.POINTER(ctypes.c_ubyte)),
    ]


class _CredentialW(ctypes.Structure):
    _fields_ = [
        ("Flags", ctypes.c_uint32),
        ("Type", ctypes.c_uint32),
        ("TargetName", ctypes.c_wchar_p),
        ("Comment", ctypes.c_wchar_p),
        ("LastWritten", _FileTime),
        ("CredentialBlobSize", ctypes.c_uint32),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
        ("Persist", ctypes.c_uint32),
        ("AttributeCount", ctypes.c_uint32),
        ("Attributes", ctypes.POINTER(_CredentialAttributeW)),
        ("TargetAlias", ctypes.c_wchar_p),
        ("UserName", ctypes.c_wchar_p),
    ]


class _DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", ctypes.c_uint32),
        ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
    ]


def _input_data_blob(payload: bytes) -> tuple[Any, _DataBlob]:
    buffer = (ctypes.c_ubyte * len(payload)).from_buffer_copy(payload)
    blob = _DataBlob(
        len(payload), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)),
    )
    return buffer, blob


class _CredentialManagerApi:
    """Small WinCred wrapper. Injectable fake APIs keep tests host-hermetic."""

    def __init__(self) -> None:
        if os.name != "nt":
            raise OSError("Windows Credential Manager is unavailable")
        try:
            self._advapi32 = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
            self._advapi32.CredWriteW.argtypes = [ctypes.POINTER(_CredentialW), ctypes.c_uint32]
            self._advapi32.CredWriteW.restype = wintypes.BOOL
            self._advapi32.CredReadW.argtypes = [
                ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                ctypes.POINTER(ctypes.POINTER(_CredentialW)),
            ]
            self._advapi32.CredReadW.restype = wintypes.BOOL
            self._advapi32.CredDeleteW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
            self._advapi32.CredDeleteW.restype = wintypes.BOOL
            self._advapi32.CredFree.argtypes = [ctypes.c_void_p]
            self._advapi32.CredFree.restype = None
        except Exception:
            raise OSError("Windows Credential Manager API is unavailable") from None

    @staticmethod
    def _last_error() -> OSError:
        return ctypes.WinError(ctypes.get_last_error())

    def write(self, target: str, blob: bytearray) -> None:
        target_w = ctypes.c_wchar_p(target)
        comment_w = ctypes.c_wchar_p(_COMMENT)
        blob_array = (ctypes.c_ubyte * len(blob)).from_buffer(blob)
        credential = _CredentialW()
        credential.Flags = 0
        credential.Type = _CRED_TYPE_GENERIC
        credential.TargetName = target_w
        credential.Comment = comment_w
        credential.CredentialBlobSize = len(blob)
        credential.CredentialBlob = ctypes.cast(blob_array, ctypes.POINTER(ctypes.c_ubyte))
        credential.Persist = _CRED_PERSIST_LOCAL_MACHINE
        credential.AttributeCount = 0
        credential.Attributes = None
        credential.TargetAlias = None
        credential.UserName = None
        if not self._advapi32.CredWriteW(ctypes.byref(credential), 0):
            raise self._last_error()

    def read(self, target: str) -> bytearray | None:
        credential_ptr = ctypes.POINTER(_CredentialW)()
        if not self._advapi32.CredReadW(target, _CRED_TYPE_GENERIC, 0, ctypes.byref(credential_ptr)):
            error = ctypes.get_last_error()
            if error == _ERROR_NOT_FOUND:
                return None
            raise ctypes.WinError(error)
        if not credential_ptr:
            raise OSError("Windows Credential Manager returned invalid credential data")
        try:
            credential = credential_ptr.contents
            size = int(credential.CredentialBlobSize)
            if size > _CRED_MAX_CREDENTIAL_BLOB_SIZE:
                raise OSError("Windows Credential Manager returned invalid credential data")
            if size == 0:
                raise OSError("Windows Credential Manager returned invalid credential data")
            if size and not credential.CredentialBlob:
                raise OSError("Windows Credential Manager returned invalid credential data")
            value = bytearray(size)
            ctypes.memmove((ctypes.c_ubyte * size).from_buffer(value), credential.CredentialBlob, size)
            return value
        finally:
            try:
                if credential_ptr:
                    credential = credential_ptr.contents
                    if credential.CredentialBlob and credential.CredentialBlobSize:
                        ctypes.memset(credential.CredentialBlob, 0, int(credential.CredentialBlobSize))
            finally:
                if credential_ptr:
                    self._advapi32.CredFree(ctypes.cast(credential_ptr, ctypes.c_void_p))

    def delete(self, target: str) -> bool:
        if self._advapi32.CredDeleteW(target, _CRED_TYPE_GENERIC, 0):
            return True
        error = ctypes.get_last_error()
        if error == _ERROR_NOT_FOUND:
            return False
        raise ctypes.WinError(error)


class WindowsCredentialManagerStore:
    """Store API keys in the current user's Windows Credential Manager."""

    def __init__(self, api: Any | None = None) -> None:
        try:
            self._api = api if api is not None else _CredentialManagerApi()
        except Exception:
            raise SecretStoreUnavailable("Windows Credential Manager is unavailable") from None

    @staticmethod
    def new_reference() -> str:
        return _REFERENCE_PREFIX + secrets.token_hex(24)

    @staticmethod
    def _target(reference: str) -> str:
        if not isinstance(reference, str) or not _REFERENCE_PATTERN.fullmatch(reference):
            raise ValueError("invalid Windows Credential Manager reference")
        return _TARGET_PREFIX + reference[len(_REFERENCE_PREFIX):]

    def store(self, reference: str, secret: str) -> None:
        target = self._target(reference)
        secret = _validate_secret(secret)
        blob = bytearray(secret.encode("utf-8"))
        if len(blob) > _CRED_MAX_CREDENTIAL_BLOB_SIZE:
            blob[:] = b"\x00" * len(blob)
            raise ValueError("credential exceeds Windows Credential Manager limit")
        try:
            self._api.write(target, blob)
        except Exception:
            raise SecretStoreUnavailable("Windows Credential Manager could not store credential") from None
        finally:
            blob[:] = b"\x00" * len(blob)

    def lookup(self, reference: str) -> str | None:
        target = self._target(reference)
        try:
            blob = self._api.read(target)
        except Exception:
            raise SecretStoreUnavailable("Windows Credential Manager could not read credential") from None
        if blob is None:
            return None
        try:
            if len(blob) > _CRED_MAX_CREDENTIAL_BLOB_SIZE:
                raise SecretStoreUnavailable("Windows Credential Manager returned invalid credential data")
            return bytes(blob).decode("utf-8", errors="strict")
        except SecretStoreUnavailable:
            raise
        except Exception:
            raise SecretStoreUnavailable("Windows Credential Manager returned invalid credential data") from None
        finally:
            if isinstance(blob, bytearray):
                blob[:] = b"\x00" * len(blob)

    def delete(self, reference: str) -> bool:
        target = self._target(reference)
        try:
            return bool(self._api.delete(target))
        except Exception:
            raise SecretStoreUnavailable("Windows Credential Manager could not delete credential") from None


class WindowsMetadataProtector:
    """Protect credential registry metadata with current-user DPAPI."""

    def __init__(self) -> None:
        if os.name != "nt":
            raise OSError("DPAPI is unavailable")
        try:
            self._crypt32 = ctypes.WinDLL("Crypt32.dll", use_last_error=True)
            self._kernel32 = ctypes.WinDLL("Kernel32.dll", use_last_error=True)
            self._crypt32.CryptProtectData.argtypes = [
                ctypes.POINTER(_DataBlob), ctypes.c_wchar_p, ctypes.POINTER(_DataBlob),
                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(_DataBlob),
            ]
            self._crypt32.CryptProtectData.restype = wintypes.BOOL
            self._crypt32.CryptUnprotectData.argtypes = [
                ctypes.POINTER(_DataBlob), ctypes.c_void_p, ctypes.POINTER(_DataBlob),
                ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(_DataBlob),
            ]
            self._crypt32.CryptUnprotectData.restype = wintypes.BOOL
            self._kernel32.LocalFree.argtypes = [ctypes.c_void_p]
            self._kernel32.LocalFree.restype = ctypes.c_void_p
        except Exception:
            raise OSError("DPAPI is unavailable") from None

    def _transform(self, payload: bytes, protect: bool) -> bytes:
        if not isinstance(payload, bytes) or not payload:
            raise ValueError("metadata payload must be non-empty bytes")
        input_buffer, input_blob = _input_data_blob(payload)
        output_blob = _DataBlob()
        try:
            if protect:
                ok = self._crypt32.CryptProtectData(
                    ctypes.byref(input_blob), "PhaseZero account metadata", None,
                    None, None, _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(output_blob),
                )
            else:
                ok = self._crypt32.CryptUnprotectData(
                    ctypes.byref(input_blob), None, None, None, None,
                    _CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(output_blob),
                )
            if not ok:
                raise OSError("DPAPI operation failed")
            if not output_blob.pbData or output_blob.cbData == 0:
                raise OSError("DPAPI returned invalid data")
            return ctypes.string_at(output_blob.pbData, int(output_blob.cbData))
        finally:
            try:
                if output_blob.pbData and output_blob.cbData:
                    ctypes.memset(output_blob.pbData, 0, int(output_blob.cbData))
                if output_blob.pbData:
                    self._kernel32.LocalFree(ctypes.cast(output_blob.pbData, ctypes.c_void_p))
            finally:
                ctypes.memset(input_buffer, 0, len(payload))

    def protect(self, payload: bytes) -> bytes:
        try:
            return self._transform(payload, True)
        except Exception:
            raise SecretStoreUnavailable("Windows could not protect credential metadata") from None

    def unprotect(self, payload: bytes) -> bytes:
        try:
            return self._transform(payload, False)
        except Exception:
            raise SecretStoreUnavailable("Windows could not read protected credential metadata") from None
