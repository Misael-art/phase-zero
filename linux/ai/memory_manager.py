#!/usr/bin/env python3
"""ai-memory lifecycle and encrypted portability. No direct memory DB writes.

CLI, scheduled workers and UI use this same owner. Knowledge goes through the
official conditional-write companion; full snapshots never merge live stores.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
import platform
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import shlex
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import webbrowser
from urllib.request import Request, urlopen
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from linux.ai.secret_store import default_secret_store, new_secret_reference  # noqa: E402
from linux.lib.pz_hostbackup import backup_file, ledger_record  # noqa: E402

FORMAT = "phasezero-memory/v1"
MAX_KNOWLEDGE = 8 * 1024 * 1024
MAX_EXPANDED = 16 * 1024**3
FAMILIES = ("concepts", "decisions", "gotchas", "procedures", "notes", "_rules")
SAFE_ID = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,95}\Z")
PRACTICES_PROJECT = "phasezero-development-practices"
PRACTICES_SCOPE = hashlib.sha256(b"phasezero:development-practices:v1").hexdigest()
PRACTICES_PATH = "_rules/development-practices.md"
PRACTICES_SIGNATURE = "\n\n<!-- phasezero-practices-signature\n"
PRACTICES_REVISION = re.compile(r"<!-- phasezero-practices revision: ([1-9][0-9]{0,8}) -->\n")
CURATION_ACTIONS = {"curate-plan", "curate", "curate-review", "curate-apply"}


class MemoryError(RuntimeError):
    pass


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_path(path: Path) -> Path:
    path = path.expanduser().absolute()
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise MemoryError("symlink-path-refused")
    return path


def atomic(path: Path, payload: bytes, *, expected_sha256: str | None = None) -> None:
    path = safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".partial-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        if expected_sha256 is not None and (not path.is_file() or digest(safe_path(path)) != expected_sha256):
            raise MemoryError("source-changed-before-replace")
        os.replace(name, path)
        if os.name != "nt":
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path: Path, default=None):
    if not path.exists():
        return default
    safe_path(path)
    if path.stat().st_size > 16 * 1024 * 1024:
        raise MemoryError("metadata-too-large")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError):
        raise MemoryError("invalid-metadata") from None


def write_json(path: Path, value) -> None:
    atomic(path, json.dumps(value, ensure_ascii=False, indent=2).encode())


def unit_quote(value):
    value = str(value)
    if any(ord(c) < 32 for c in value):
        raise MemoryError("invalid-systemd-path")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'


def remote_identity(remote):
    """Only GitHub has a known SSH/HTTPS, case-insensitive identity contract."""
    if "://" not in remote and re.match(r"^[^/]+@[^/:]+:", remote):
        remote = "ssh://" + remote.replace(":", "/", 1)
    parsed = urlparse(remote)
    if parsed.scheme not in {"https", "http", "ssh", "git"} or not parsed.hostname:
        return None
    hostname = parsed.hostname.lower()
    path = parsed.path.strip("/").removesuffix(".git")
    port = parsed.port
    default = {"https": 443, "http": 80, "ssh": 22, "git": 9418}[parsed.scheme]
    authority = hostname + (f":{port}" if port and port != default else "")
    if hostname == "github.com" and (not port or port == default):
        return authority + "/" + path.lower()
    return parsed.scheme + "://" + authority + "/" + path


def run(args, *, data=None, env=None, timeout=120, allowed=(0,)):
    try:
        result = subprocess.run([str(a) for a in args], input=data, capture_output=True,
                                timeout=timeout, env=env, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise MemoryError(f"command-unavailable-or-timeout:{Path(str(args[0])).name}") from None
    if result.returncode not in allowed:
        # stderr may contain provider config, page bodies or credentials.
        raise MemoryError(f"command-failed:{Path(str(args[0])).name}:{result.returncode}")
    return result


@contextmanager
def locked(path: Path):
    safe_path(path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(descriptor, "a+b") as stream:
        try:
            if os.name == "nt":
                import msvcrt
                if path.stat().st_size == 0:
                    stream.write(b"0")
                    stream.flush()
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise MemoryError("operation-busy") from None
        try:
            yield
        finally:
            if os.name == "nt":
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def operation_running(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        with locked(path):
            return False
    except MemoryError:
        return True


def unpack(archive: Path, destination: Path, limit=MAX_EXPANDED) -> None:
    """Validate the entire archive before extracting any entry, including links."""
    with tarfile.open(archive, "r:gz") as tar:
        entries = tar.getmembers()
        total = 0
        seen = set()
        for entry in entries:
            name = PurePosixPath(entry.name)
            if (name.is_absolute() or ".." in name.parts or "\\" in entry.name
                    or any(":" in p for p in name.parts) or not (entry.isfile() or entry.isdir())):
                raise MemoryError("unsafe-archive-entry")
            key = str(name).casefold()
            if key in seen:
                raise MemoryError("duplicate-archive-entry")
            seen.add(key)
            total += entry.size
            if total > limit or len(seen) > 200000:
                raise MemoryError("archive-budget-exceeded")
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        for entry in entries:
            target = safe_path(destination / entry.name)
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                source = tar.extractfile(entry)
                if source is None:
                    raise MemoryError("invalid-archive-entry")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o600)


def crypt(source: Path, destination: Path, password: str, *, decrypt=False) -> None:
    args = ["gpg", "--batch", "--yes", "--no-symkey-cache", "--pinentry-mode", "loopback",
            "--passphrase-fd", "0", "--output", str(destination)]
    args += ["--decrypt"] if decrypt else ["--symmetric", "--cipher-algo", "AES256",
                "--s2k-mode", "3", "--s2k-digest-algo", "SHA512", "--s2k-count", "65011712", "--compress-algo", "none"]
    try:
        run([*args, str(source)], data=password.encode(), timeout=900)
        destination.chmod(0o600)
    except Exception:
        destination.unlink(missing_ok=True)
        raise


class Manager:
    def __init__(self, *, vault=None):
        home = Path.home()
        platform_config = Path(os.environ.get("LOCALAPPDATA", home)) if os.name == "nt" else home / ".config"
        platform_state = Path(os.environ.get("LOCALAPPDATA", home)) if os.name == "nt" else home / ".local/state"
        self.config_home = Path(os.environ.get("XDG_CONFIG_HOME", platform_config))
        self.state_home = Path(os.environ.get("XDG_STATE_HOME", platform_state))
        self.state = self.state_home / "phasezero/ai-memory"
        self.config_path = self.config_home / "phasezero/ai-memory/portability.json"
        self.config = read_json(self.config_path, {})
        if self.config and self.config.get("schemaVersion") != 1:
            raise MemoryError("unsupported-config-schema")
        default_data = Path(os.environ.get("LOCALAPPDATA", home)) / "ai-memory" if os.name == "nt" else home / ".local/share/ai-memory"
        self.data = safe_path(Path(os.environ.get("AI_MEMORY_DATA_DIR", self.config.get("dataDir", default_data))))
        self.native_config = Path(os.environ.get("AI_MEMORY_CONFIG", self.config.get("nativeConfig", self.data / "config.toml" if os.name == "nt" else self.config_home / "ai-memory/config.toml")))
        managed_binary = (Path(os.environ.get("LOCALAPPDATA", home)) / "PhaseZero/ai-tools/ai-memory/ai-memory.exe"
                          if os.name == "nt" else home / ".local/bin/ai-memory")
        self.binary = os.environ.get("AI_MEMORY_BIN") or (str(managed_binary) if managed_binary.is_file() else shutil.which("ai-memory")) or str(managed_binary)
        companion_path = (Path(os.environ.get("LOCALAPPDATA", home)) / "PhaseZero/ai-tools/ai-memory/wikisync/bin/ai-memory-wikisync.exe"
                          if os.name == "nt" else home / ".local/bin/ai-memory-wikisync")
        self.companion = os.environ.get("AI_MEMORY_WIKISYNC_BIN") or str(companion_path)
        self.vault = vault or default_secret_store()

    def save(self):
        safe_path(self.config_path)
        if os.name != "nt":
            backup_file(self.config_path, module="ai-memory")
        write_json(self.config_path, self.config)
        ledger_record(module="ai-memory", action="configuration", modified=[str(self.config_path)], reversible=True)

    def initialize(self):
        if not self.config:
            self.config = {"schemaVersion": 1, "memoryId": str(uuid.uuid4()),
                           "hostId": str(uuid.uuid4()), "hostName": socket.gethostname(),
                           "createdAt": now(), "automatic": False, "keep": 7,
                           "scopes": [], "devices": []}
            self.save()
        context = {"dataDir": str(self.data), "nativeConfig": str(self.native_config),
                   "serverUrl": os.environ.get("AI_MEMORY_SERVER_URL", self.config.get("serverUrl", "http://127.0.0.1:49374"))}
        if any(self.config.get(k) != v for k, v in context.items()):
            self.config.update(context)
            self.save()
        if not self.config.get("keyRef"):
            reference = new_secret_reference()
            if os.name == "nt":
                reference = reference.replace("secret-service:", "wincred:")
            self.vault.store(reference, secrets.token_urlsafe(48))
            self.config["keyRef"] = reference
            self.save()

    def password(self):
        reference = self.config.get("keyRef")
        value = self.vault.lookup(reference) if reference else None
        if not value:
            raise MemoryError("memory-key-unavailable-unlock-system-vault")
        return value

    def native(self, *args, timeout=900, data=None):
        return run([self.binary, "--data-dir", self.data, "--config", self.native_config, *args], timeout=timeout, data=data,
                   env=self.client_environment())

    def client_environment(self):
        env = os.environ.copy()
        env.setdefault("AI_MEMORY_SERVER_URL", self.config.get("serverUrl", "http://127.0.0.1:49374"))
        env["AI_MEMORY_DATA_DIR"] = str(self.data)
        env["AI_MEMORY_CONFIG"] = str(self.native_config)
        env_path = Path(os.environ.get("AI_MEMORY_ENV", self.config_home / "ai-memory/env"))
        if "AI_MEMORY_AUTH_TOKEN" not in env and env_path.is_file():
            for line in env_path.read_text().splitlines():
                if line.startswith("AI_MEMORY_AUTH_TOKEN="):
                    env["AI_MEMORY_AUTH_TOKEN"] = line.split("=", 1)[1].strip().strip("\"'")
        if "AI_MEMORY_AUTH_TOKEN" not in env and self.native_config.is_file():
            import tomllib
            config = tomllib.loads(self.native_config.read_text())
            token_file = config.get("auth", {}).get("bearer_token_file")
            if token_file:
                token_path = Path(token_file).expanduser()
                if not token_path.is_absolute():
                    token_path = self.data / token_path
                env["AI_MEMORY_AUTH_TOKEN"] = token_path.read_text().strip()
        origin = urlparse(env.get("AI_MEMORY_SERVER_URL", "http://127.0.0.1:49374"))
        if (origin.username or origin.password or origin.scheme not in {"http", "https"}
                or origin.scheme == "http" and origin.hostname not in {"127.0.0.1", "localhost", "::1"}):
            raise MemoryError("remote-memory-server-requires-https")
        return env

    def status(self):
        installed = shutil.which(self.binary) is not None or Path(self.binary).is_file()
        version = run([self.binary, "--version"], timeout=8).stdout.decode().strip() if installed else ""
        if os.name == "nt":
            service = "unknown"
        else:
            service = run(["systemctl", "--user", "is-active", "ai-memory.service"], timeout=5,
                          allowed=(0, 1, 3, 4)).stdout.decode().strip()
        reachable = False
        try:
            env = self.client_environment()
            headers = {"Authorization": "Bearer " + env["AI_MEMORY_AUTH_TOKEN"]} if env.get("AI_MEMORY_AUTH_TOKEN") else {}
            request = Request(env.get("AI_MEMORY_SERVER_URL", "http://127.0.0.1:49374").rstrip("/") + "/healthz", headers=headers)
            with urlopen(request, timeout=3) as response:
                reachable = response.status == 200
        except Exception:
            pass
        if os.name == "nt":
            service = "active" if reachable else "unknown"
        projects = []
        if reachable:
            try:
                projects = json.loads(self.native("list-projects", "--json", timeout=10).stdout)
            except Exception:
                pass
        state = read_json(self.state / "last-run.json", {})
        recovery = read_json(self.state_home / "phasezero/ai/ai-memory-recovery-required.json")
        devices = []
        try:
            volumes = self.volumes() if self.config.get("devices") else []
        except Exception:
            volumes = None
        for device in self.config.get("devices", []):
            online = None
            if volumes is not None:
                try:
                    self.device_root(device, volumes=volumes)
                    online = True
                except MemoryError:
                    online = False
            devices.append({**device, "online": online})
        busy = operation_running(self.state / "operation.lock")
        if state.get("state") == "running" and not busy:
            state = {**state, "state": "interrupted-retry-required", "ok": False}
        return {"schemaVersion": 1, "ok": True, "installed": installed, "version": version,
                "service": service, "serverReachable": reachable,
                "state": "recovery-required" if recovery else "missing" if not installed else "ready" if service == "active" and reachable else "needs-repair",
                "recoveryRequired": recovery,
                "hostId": self.config.get("hostId"), "hostName": socket.gethostname(),
                "memoryId": self.config.get("memoryId"), "keyConfigured": bool(self.config.get("keyRef")),
                "recoveryExported": bool(self.config.get("recoveryExportedAt")),
                "automatic": self.config.get("automatic", False), "scopes": self.config.get("scopes", []),
                "operationRunning": busy, "intervalMinutes": self.config.get("intervalMinutes", 15),
                "backupHours": self.config.get("backupHours", 24), "keep": self.config.get("keep", 7),
                "availableProjects": projects,
                "devices": devices, "github": self.config.get("github"),
                "companionInstalled": Path(self.companion).is_file() or shutil.which(self.companion) is not None,
                "conflicts": self.conflicts(),
                "curation": read_json(self.state / "curation" / "latest.json", {}),
                "curationRunning": operation_running(self.state / "curation" / "operation.lock"),
                "sync": state, "dataDir": str(self.data), "observedAt": now()}

    def conflicts(self):
        records = []
        for path in sorted((self.state / "conflicts").glob("*.json")):
            value = read_json(path, {})
            if not value.get("resolvedAt"):
                records.append(value)
        return records

    @contextmanager
    def scratch(self):
        root = safe_path(self.state / "tmp")
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(dir=root) as temp:
            yield Path(temp)

    def snapshot(self, kind, temp, *, scope=None, files=None):
        payload = temp / "payload"
        payload.mkdir(mode=0o700)
        if kind == "backup":
            if shutil.disk_usage(temp).free < 4 * 1024**3:
                raise MemoryError("backup-requires-4GiB-free")
            self.native("backup", "--to", str(payload / "native.tar.gz"))
            if not (payload / "native.tar.gz").is_file() or not (payload / "native.tar.gz").stat().st_size:
                raise MemoryError("native-backup-produced-no-archive")
            if self.native_config.is_file():
                shutil.copyfile(self.native_config, payload / "external-config.toml")
            write_json(payload / "portability-metadata.json", {"format": FORMAT,
                "memoryId": self.config["memoryId"], "scopes": [
                    {key: s[key] for key in ("id", "project", "workspace", "families")}
                    for s in self.config.get("scopes", [])]})
            # raw segments are complementary to the native snapshot, not DB replication.
            if (self.data / "raw").exists():
                shutil.copytree(self.data / "raw", payload / "raw", symlinks=True)
        else:
            for file in files or []:
                relative = file.relative_to(scope["directory"])
                target = payload / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(safe_path(file), target)
        items = []
        for path in sorted(payload.rglob("*")):
            safe_path(path)
            if path.is_file():
                items.append({"path": path.relative_to(temp).as_posix(), "sha256": digest(path), "size": path.stat().st_size})
        manifest = {"format": FORMAT, "kind": kind, "memoryId": self.config["memoryId"],
                    "sourceHost": {"id": self.config["hostId"], "name": socket.gethostname()},
                    "createdAt": now(), "nativeVersion": run([self.binary, "--version"], timeout=8).stdout.decode().strip(),
                    "scopeId": scope["id"] if scope else None, "items": items,
                    "rawIncluded": kind == "backup" and (self.data / "raw").is_dir(),
                    "provenance": scope.get("provenance", {}) if scope else {},
                    "providerCredentialFilesIncluded": False}
        write_json(temp / "manifest.json", manifest)
        archive = temp / "snapshot.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(temp / "manifest.json", arcname="manifest.json", recursive=False)
            for item in items:
                tar.add(temp / item["path"], arcname=item["path"], recursive=False)
        if kind == "knowledge" and archive.stat().st_size > MAX_KNOWLEDGE:
            raise MemoryError("knowledge-exceeds-8MiB-budget-reduce-scope")
        encrypted = temp / "snapshot.gpg"
        crypt(archive, encrypted, self.password())
        # Authentication and all file hashes are checked before publishing.
        self.verify(encrypted, temp / "verification")
        return encrypted, manifest

    def verify(self, source, destination):
        destination.mkdir(parents=True, mode=0o700)
        plain = destination / "decrypted.tar.gz"
        crypt(safe_path(Path(source)), plain, self.password(), decrypt=True)
        unpack(plain, destination / "extracted")
        root = destination / "extracted"
        manifest = read_json(root / "manifest.json", {})
        if (manifest.get("format") != FORMAT or manifest.get("memoryId") != self.config.get("memoryId")
                or manifest.get("kind") not in {"backup", "knowledge"}):
            raise MemoryError("foreign-or-invalid-memory-bundle")
        expected = set()
        for item in manifest["items"]:
            relative = PurePosixPath(item["path"])
            if relative.is_absolute() or ".." in relative.parts or relative.parts[0] != "payload":
                raise MemoryError("unsafe-manifest-path")
            path = safe_path(root / str(relative))
            if not path.is_file() or digest(path) != item["sha256"] or path.stat().st_size != item["size"]:
                raise MemoryError("bundle-integrity-failed")
            expected.add(str(relative))
        actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()} - {"manifest.json"}
        if expected != actual:
            raise MemoryError("bundle-inventory-mismatch")
        return root, manifest

    def add_scope(self, project, workspace, repo_path, families, *, create_project=False, identity=None):
        projects = json.loads(self.native("list-projects", "--json", timeout=15).stdout)
        matches = [p for p in projects if p.get("project_name") == project and p.get("workspace_name") == workspace]
        if len(matches) > 1 or not matches and not create_project:
            raise MemoryError("select-existing-project-and-workspace-from-memory-status")
        self.initialize()
        path = safe_path(Path(repo_path))
        if not path.is_dir():
            raise MemoryError("existing-project-directory-required")
        if identity:
            if not re.fullmatch(r"[0-9a-fA-F]{64}", identity):
                raise MemoryError("shared-project-identity-must-be-64-hex-characters")
            scope_id = identity.lower()
        else:
            remote = run(["git", "-C", path, "config", "--get", "remote.origin.url"], allowed=(0, 1, 128)).stdout.decode().strip()
            network_identity = remote_identity(remote)
            scope_id = hashlib.sha256(network_identity.encode()).hexdigest() if network_identity else secrets.token_hex(32)
        selected = [x.strip() for x in families.split(",") if x.strip()]
        if not selected or any(x not in FAMILIES for x in selected):
            raise MemoryError("unsupported-page-family")
        if any(s["id"] == scope_id for s in self.config["scopes"]):
            raise MemoryError("scope-already-enrolled")
        if any(s["workspace"] == workspace and s["project"] == project for s in self.config["scopes"]):
            raise MemoryError("project-already-bound-unenroll-before-changing-identity")
        if create_project and not matches:
            registered = now()
            # Durable configuration/provenance record, created through the upstream
            # API rather than an empty DB or a fabricated conversation/session.
            body = ("---\ntier: semantic\n" + f"hostname: {json.dumps(socket.gethostname())}\n"
                    + f"source_host: {json.dumps(socket.gethostname())}\nregistered_by: phasezero\nregistered_at: {registered}\n---\n"
                    + "# Host enrolled for shared project memory\n\n"
                    + f"Host ID: {self.config['hostId']}\nProject identity: {scope_id}\n"
                    + f"Environment: {platform.system()} {platform.release()}\n"
                    + "Enrollment establishes this project's memory scope on this host. "
                    + "Record timestamps describe enrollment; imported knowledge retains original context.\n")
            self.native("write-page", "--workspace", workspace, "--project", project,
                        "--path", "notes/hosts/" + self.config["hostId"] + ".md", "--body", "-", data=body.encode())
            projects = json.loads(self.native("list-projects", "--json", timeout=15).stdout)
            matches = [p for p in projects if p.get("project_name") == project and p.get("workspace_name") == workspace]
            if len(matches) != 1:
                raise MemoryError("new-project-identity-not-confirmed")
        self.config["scopes"].append({"id": scope_id, "project": project, "workspace": workspace,
                                      "projectId": matches[0]["project_id"],
                                      "families": selected, "repoPath": str(path)})
        self.save()
        return {"ok": True, "state": "scope-enrolled", "scopeId": scope_id}

    def configure_practices(self, fingerprint, repo_path):
        fingerprint = (fingerprint or "").upper()
        if not re.fullmatch(r"[0-9A-F]{40}|[0-9A-F]{64}", fingerprint):
            raise MemoryError("practices-full-gpg-fingerprint-required")
        if self.config.get("practicesSigner", fingerprint) != fingerprint:
            raise MemoryError("practices-signer-change-requires-explicit-migration")
        keys = run(["gpg", "--batch", "--with-colons", "--list-keys", fingerprint], allowed=(0, 2))
        primary = next((line.split(":")[9] for line in keys.stdout.decode().splitlines()
                        if line.startswith("fpr:")), None)
        if keys.returncode or primary != fingerprint:
            raise MemoryError("practices-trusted-primary-key-not-found")
        scope = next((item for item in self.config.get("scopes", []) if item["id"] == PRACTICES_SCOPE), None)
        if not scope:
            self.add_scope(PRACTICES_PROJECT, "default", repo_path, "_rules",
                           create_project=True, identity=PRACTICES_SCOPE)
        elif (scope["workspace"], scope["project"], scope["families"]) != ("default", PRACTICES_PROJECT, ["_rules"]):
            raise MemoryError("practices-scope-mismatch")
        if self.config.get("practicesSigner") != fingerprint:
            self.config["practicesSigner"] = fingerprint
            self.save()
        return {"ok": True, "state": "practices-configured", "fingerprint": fingerprint, "scopeId": PRACTICES_SCOPE}

    def practices_signer(self):
        if not self.config.get("practicesSigner") or not any(
            item["id"] == PRACTICES_SCOPE for item in self.config.get("scopes", [])
        ):
            raise MemoryError("practices-not-configured")
        return self.config["practicesSigner"]

    def verify_practices(self, page):
        payload, separator, signature = page.rstrip().rpartition(PRACTICES_SIGNATURE)
        revision = PRACTICES_REVISION.match(payload)
        if not separator or not revision or not signature.endswith("\n-->"):
            raise MemoryError("practices-signature-required")
        with self.scratch() as temp:
            signature_path = temp / "signature.asc"
            signature_path.write_bytes(signature.removesuffix("\n-->").encode() + b"\n")
            verification = run(["gpg", "--batch", "--no-auto-key-retrieve", "--status-fd", "1",
                                "--verify", signature_path, "-"], data=payload.encode(), allowed=(0, 1, 2))
        valid_signers = [line.split()[-1] for line in verification.stdout.decode().splitlines()
                         if line.startswith("[GNUPG:] VALIDSIG ")]
        if verification.returncode or valid_signers != [self.practices_signer()]:
            raise MemoryError("practices-signature-untrusted")
        return int(revision[1]), payload[revision.end():], hashlib.sha256(payload.encode()).hexdigest()

    def practices(self):
        signer = self.practices_signer()
        try:
            response = self.native("read-page", "--json", "--workspace", "default",
                                   "--project", PRACTICES_PROJECT, "--path", PRACTICES_PATH, timeout=10)
        except MemoryError as error:
            raise MemoryError("practices-page-unavailable") from error
        page = json.loads(response.stdout)
        revision, body, checksum = self.verify_practices(page["body"])
        accepted_path = self.state / "practices-accepted.json"
        accepted = read_json(accepted_path, {})
        record = {"revision": revision, "sha256": checksum}
        if revision < accepted.get("revision", 0) or (revision == accepted.get("revision") and accepted != record):
            raise MemoryError("practices-revision-conflict-or-rollback")
        if record != accepted:
            write_json(accepted_path, record)
        return {"ok": True, "state": "practices-verified", "revision": revision, "body": body,
                "fingerprint": signer, "workspace": "default", "project": PRACTICES_PROJECT, "path": PRACTICES_PATH}

    def publish_practices(self, path, revision):
        signer = self.practices_signer()
        if revision is None or not 1 <= revision <= 999999999:
            raise MemoryError("practices-positive-revision-required")
        accepted = read_json(self.state / "practices-accepted.json", {})
        if revision <= accepted.get("revision", 0):
            raise MemoryError("practices-revision-must-increase")
        source = safe_path(Path(path))
        if not source.is_file() or source.stat().st_size > 32 * 1024:
            raise MemoryError("practices-markdown-file-up-to-32KiB-required")
        body = source.read_text(encoding="utf-8").strip()
        if not body.startswith("# ") or PRACTICES_SIGNATURE in body:
            raise MemoryError("practices-markdown-heading-required")
        payload = f"<!-- phasezero-practices revision: {revision} -->\n{body}"
        signature = run(["gpg", "--batch", "--local-user", signer, "--armor", "--detach-sign",
                         "--output", "-"], data=payload.encode()).stdout.decode().strip()
        page = payload + PRACTICES_SIGNATURE + signature + "\n-->\n"
        self.verify_practices(page)
        self.native("write-page", "--workspace", "default", "--project", PRACTICES_PROJECT,
                    "--path", PRACTICES_PATH, "--tier", "procedural", "--pinned", "--body", "-", data=page.encode())
        result = self.practices()
        if (result["revision"], result["body"]) != (revision, body):
            raise MemoryError("practices-published-page-changed")
        return {"ok": True, "state": "practices-published-locally", "revision": revision, "path": PRACTICES_PATH}

    def companion_run(self, scope, directory, *, check=False, export=False, prefer=None):
        env = self.client_environment()
        args = [self.companion, "export" if export else "sync", "--dest", directory,
                "--workspace", scope["workspace"], "--project", scope["project"],
                "--server", env.get("AI_MEMORY_SERVER_URL", "http://127.0.0.1:49374")]
        for family in scope["families"]:
            args += ["--include", family]
        args += ["--check"] if check else ["--apply"]
        if prefer:
            args += ["--prefer", prefer]
        result = run(args, env=env, allowed=(0, 3, 4) if check else (0,), timeout=300)
        if result.returncode == 4:
            raise MemoryError("knowledge-conflict-review-required")
        return result.returncode

    def export_knowledge(self, scope, temp):
        directory = self.state / "exports" / scope["id"]
        self.companion_run(scope, directory, export=True)
        files = sorted(p for p in directory.rglob("*.md") if ".ai-memory-wikisync" not in p.parts)
        if scope["id"] == PRACTICES_SCOPE:
            files = [p for p in files if p.relative_to(directory).as_posix() == PRACTICES_PATH]
            for page in files:
                self.verify_exported_practices(page)
        hashes = {p.relative_to(directory).as_posix(): digest(p) for p in files}
        provenance_path = self.state / "provenance" / (scope["id"] + ".json")
        provenance = read_json(provenance_path, {})
        for path, checksum in hashes.items():
            key = path + ":" + checksum
            if key not in provenance:
                provenance[key] = {"sourceHostId": self.config["hostId"], "firstObservedAt": now(),
                                   "historicalOrigin": "see-original-page-metadata"}
        write_json(provenance_path, provenance)
        snapshot_scope = {**scope, "directory": directory,
                          "provenance": {p + ":" + h: provenance[p + ":" + h] for p, h in hashes.items()}}
        fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
        blob, manifest = self.snapshot("knowledge", temp, scope=snapshot_scope, files=files)
        return blob, manifest, fingerprint

    def verify_exported_practices(self, path):
        content = path.read_text(encoding="utf-8")
        if content.startswith("---\n"):
            _, _, content = content[4:].partition("\n---\n")
        return self.verify_practices(content.lstrip("\n"))

    def import_knowledge(self, blob, scope, peer, temp, *, prefer=None):
        root, manifest = self.verify(blob, temp)
        if manifest.get("kind") != "knowledge" or manifest.get("scopeId") != scope["id"]:
            raise MemoryError("foreign-knowledge-scope")
        peer_id = manifest.get("sourceHost", {}).get("id")
        if not isinstance(peer_id, str) or not SAFE_ID.fullmatch(peer_id) or peer_id != peer:
            raise MemoryError("invalid-peer-identity")
        if scope["id"] == PRACTICES_SCOPE:
            paths = [item["path"] for item in manifest["items"]]
            if not paths:
                return
            if paths != ["payload/" + PRACTICES_PATH]:
                raise MemoryError("practices-bundle-unexpected-page")
            revision, _, checksum = self.verify_exported_practices(root / paths[0])
            accepted = read_json(self.state / "practices-accepted.json", {})
            if revision < accepted.get("revision", 0):
                return  # A peer may still be using its last synchronized copy.
            if revision == accepted.get("revision") and checksum != accepted["sha256"]:
                raise MemoryError("practices-revision-conflict-or-rollback")
        directory = self.state / "imports" / scope["id"] / peer_id
        # Per-peer companion baselines stay local and never travel in bundles.
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        for item in manifest["items"]:
            relative = PurePosixPath(item["path"]).relative_to("payload")
            if relative.suffix != ".md" or relative.parts[0] not in scope["families"]:
                raise MemoryError("knowledge-family-refused")
            atomic(directory / str(relative), (root / item["path"]).read_bytes())
        # Deletions are intentionally not imported or propagated.
        try:
            if not prefer:
                self.companion_run(scope, directory, check=True)
            self.companion_run(scope, directory, prefer=prefer)
            self.companion_run(scope, directory, check=True)
        except MemoryError as error:
            if "conflict" in str(error):
                conflict_id = digest(blob)
                conflict_root = self.state / "conflicts"
                atomic(conflict_root / (conflict_id + ".gpg"), Path(blob).read_bytes())
                write_json(conflict_root / (conflict_id + ".json"), {
                    "id": conflict_id, "scopeId": scope["id"], "project": scope["project"],
                    "peer": peer, "sourceHost": manifest["sourceHost"], "receivedAt": now(),
                    "sourceCreatedAt": manifest["createdAt"],
                    "pages": [i["path"] for i in manifest["items"]]})
            raise
        provenance_path = self.state / "provenance" / (scope["id"] + ".json")
        provenance = read_json(provenance_path, {})
        for key, value in manifest.get("provenance", {}).items():
            provenance.setdefault(key, value)
        write_json(provenance_path, provenance)
        if scope["id"] == PRACTICES_SCOPE:
            self.practices()

    def import_peer(self, blob, scope, peer, temp, practice_errors, *, prefer=None):
        try:
            self.import_knowledge(blob, scope, peer, temp, prefer=prefer)
        except Exception as error:
            if scope["id"] != PRACTICES_SCOPE:
                raise
            practice_errors.append(self.error_code(error))

    def resolve(self, conflict_id, prefer, *, plan=False):
        if not conflict_id or not re.fullmatch(r"[0-9a-f]{64}", conflict_id):
            raise MemoryError("selected-conflict-required")
        record_path = self.state / "conflicts" / (conflict_id + ".json")
        record = read_json(record_path)
        if not record or record.get("resolvedAt"):
            raise MemoryError("unresolved-conflict-required")
        if plan:
            return {"ok": True, "state": "conflict-planned", "conflict": record,
                    "choices": {"server": "keep local server version", "repo": "use selected received version"}}
        scope = next((s for s in self.config["scopes"] if s["id"] == record["scopeId"]), None)
        if not scope or prefer not in {"server", "repo"}:
            raise MemoryError("enrolled-scope-and-resolution-required")
        blob = record_path.with_suffix(".gpg")
        if digest(blob) != conflict_id:
            raise MemoryError("conflict-bundle-damaged")
        with self.scratch() as temp:
            self.import_knowledge(blob, scope, record["peer"], temp / "resolution", prefer=prefer)
        record.update(resolvedAt=now(), preference=prefer)
        write_json(record_path, record)
        return {"ok": True, "state": "conflict-resolved", "id": conflict_id}

    def gh(self, endpoint, *, method="GET", value=None):
        args = ["gh", "api", endpoint, "--method", method]
        data = None
        if value is not None:
            args += ["--input", "-"]
            data = json.dumps(value).encode()
        result = run(args, data=data, timeout=120)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def github_login(self):
        executable = shutil.which("gh")
        if not executable:
            raise MemoryError("github-cli-required")
        command = [executable, "auth", "login", "--hostname", "github.com", "--web", "--git-protocol", "https"]
        if os.name == "nt":
            subprocess.Popen(command, creationflags=subprocess.CREATE_NEW_CONSOLE)
        else:
            terminal = next((([path, *flags]) for name, flags in (
                ("konsole", ["--separate", "-e"]), ("gnome-terminal", ["--"]), ("xterm", ["-e"]))
                if (path := shutil.which(name))), None)
            if not terminal or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
                raise MemoryError("open-private-terminal-and-run-gh-auth-login")
            subprocess.Popen([*terminal, *command], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        return {"ok": True, "state": "login-terminal-opened", "authenticated": None,
                "message": "Conclua login no terminal privado e depois conecte repositório na memória."}

    def github_open_backups(self):
        self.github_validate()
        url = "https://github.com/" + self.config["github"]["repository"] + "/releases"
        if not webbrowser.open(url, new=2):
            raise MemoryError("default-browser-unavailable")
        return {"ok": True, "state": "backups-opened", "message": "Selecione snapshot no GitHub, baixe arquivo .gpg e use Verificar/Restaurar na memória."}

    def github_validate(self, config=None):
        config = config or self.config.get("github")
        if not config:
            raise MemoryError("github-not-configured")
        repo = self.gh("repos/" + config["repository"])
        if repo.get("private") is not True or repo.get("id") != config["repositoryId"]:
            raise MemoryError("github-repository-identity-or-privacy-changed")
        if not repo.get("permissions", {}).get("push"):
            raise MemoryError("github-write-access-unavailable")
        return repo

    def github_configure(self, repository, *, create=False):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise MemoryError("invalid-github-repository")
        self.initialize()
        if create:
            owner, name = repository.split("/")
            user = self.gh("user")["login"]
            endpoint = "user/repos" if owner.lower() == user.lower() else "orgs/" + owner + "/repos"
            self.gh(endpoint, method="POST", value={"name": name, "private": True, "auto_init": True,
                    "description": "Encrypted ai-memory knowledge and host recovery snapshots"})
        repo = self.gh("repos/" + repository)
        config = {"repository": repository, "repositoryId": repo["id"], "branch": repo["default_branch"]}
        self.github_validate(config)
        # A repo has one encryption domain. Joining requires its recovery key.
        try:
            remote = self.gh("repos/" + repository + "/contents/memory.json")
        except MemoryError:
            # Distinguish missing from auth/network errors using the tree listing.
            tree = self.gh("repos/" + repository + "/git/trees/" + config["branch"] + "?recursive=1")
            if any(x["path"] == "memory.json" for x in tree["tree"]):
                raise
            remote = None
        if remote:
            metadata = json.loads(base64.b64decode(remote["content"]))
            if metadata.get("format") != FORMAT or metadata.get("memoryId") != self.config["memoryId"]:
                raise MemoryError("import-repository-recovery-key-before-enrolling-this-host")
        else:
            metadata = {"format": FORMAT, "memoryId": self.config["memoryId"]}
            self.gh("repos/" + repository + "/contents/memory.json", method="PUT", value={
                "message": "Initialize encrypted memory domain", "branch": config["branch"],
                "content": base64.b64encode(json.dumps(metadata).encode()).decode()})
        self.config["github"] = config
        self.save()
        return {"ok": True, "state": "github-configured", "repository": repository}

    def github_pull(self, scopes, temp, *, prefer=None):
        config = self.config["github"]
        self.github_validate()
        base = "repos/" + config["repository"]
        tree = self.gh(base + "/git/trees/" + config["branch"] + "?recursive=1")
        if tree.get("truncated"):
            raise MemoryError("github-tree-budget-exceeded")
        by_id = {s["id"]: s for s in scopes}
        practice_errors = []
        for item in tree["tree"]:
            match = re.fullmatch(r"knowledge/([a-zA-Z0-9-]+)/([0-9a-f]{64})\.gpg", item["path"])
            if not match or match[1] == self.config["hostId"] or match[2] not in by_id:
                continue
            if item.get("size", MAX_KNOWLEDGE + 1) > MAX_KNOWLEDGE:
                raise MemoryError("remote-knowledge-budget-exceeded")
            blob = self.gh(base + "/git/blobs/" + item["sha"])
            downloaded = temp / (match[1] + "-" + match[2] + ".gpg")
            atomic(downloaded, base64.b64decode(blob["content"], validate=False))
            self.import_peer(downloaded, by_id[match[2]], match[1], temp / uuid.uuid4().hex,
                             practice_errors, prefer=prefer)
        return practice_errors

    def github_push(self, blob, scope, fingerprint):
        config = self.config["github"]
        self.github_validate()
        endpoint = "repos/" + config["repository"] + "/contents/knowledge/" + self.config["hostId"] + "/" + scope["id"] + ".gpg"
        existing = None
        tree = self.gh("repos/" + config["repository"] + "/git/trees/" + config["branch"] + "?recursive=1")
        path = endpoint.split("/contents/", 1)[1]
        for item in tree["tree"]:
            if item["path"] == path:
                existing = item["sha"]
        record_path = self.state / "github-published" / (scope["id"] + ".json")
        record = read_json(record_path, {})
        if record.get("fingerprint") == fingerprint and record.get("sha") == existing and existing:
            return "unchanged"
        value = {"message": "Update encrypted knowledge", "branch": config["branch"],
                 "content": base64.b64encode(blob.read_bytes()).decode()}
        if existing:
            value["sha"] = existing
        result = self.gh(endpoint, method="PUT", value=value)
        write_json(record_path, {"fingerprint": fingerprint, "sha": result["content"]["sha"]})
        return "published"

    def github_backup(self, blob):
        if blob.stat().st_size > 2_000_000_000:
            raise MemoryError("backup-exceeds-2GB-GitHub-budget-use-external-device")
        self.github_validate()
        repo = self.config["github"]["repository"]
        tag = "memory-" + self.config["hostId"] + "-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        # Native gh binary upload streams the file using its existing credential helper.
        run(["gh", "release", "create", tag, "--repo", repo, "--title", "Encrypted host backup",
             "--notes", "Encrypted ai-memory recovery snapshot; provider credential files excluded.", "--prerelease"], timeout=120)
        run(["gh", "release", "upload", tag, str(blob) + "#ai-memory.gpg", "--repo", repo], timeout=1800)
        self.github_validate()
        release = self.gh("repos/" + repo + "/releases/tags/" + tag)
        asset = next((a for a in release["assets"] if a["name"] == blob.name), None)
        if not asset or asset.get("digest") != "sha256:" + digest(blob) or asset.get("size") != blob.stat().st_size:
            raise MemoryError("github-backup-upload-not-verified")
        # Retain only this host's completed snapshots; never other releases/hosts.
        releases = []
        retention_complete = False
        for page in range(1, 21):
            batch = self.gh("repos/" + repo + f"/releases?per_page=100&page={page}")
            releases.extend(batch)
            if len(batch) < 100:
                retention_complete = True
                break
        if not retention_complete:
            return {"tag": tag, "sha256": digest(blob), "verifiedAt": now(), "retention": "manual-review-required"}
        own = sorted((r for r in releases if r["tag_name"].startswith("memory-" + self.config["hostId"] + "-")
                      and any(a.get("digest") for a in r["assets"])), key=lambda r: r["created_at"], reverse=True)
        for old in own[self.config.get("keep", 7):]:
            run(["gh", "release", "delete", old["tag_name"], "--repo", repo, "--yes", "--cleanup-tag"])
        return {"tag": tag, "sha256": digest(blob), "verifiedAt": now()}

    def volumes(self):
        if os.name == "nt":
            script = "Get-Volume | Where-Object DriveLetter | ForEach-Object { @{ path=([string]$_.DriveLetter + ':\\'); id=$_.UniqueId } } | ConvertTo-Json -Compress"
            output = run(["powershell.exe", "-NoProfile", "-Command", script], timeout=20).stdout
            value = json.loads(output) if output.strip() else []
            return value if isinstance(value, list) else [value]
        data = json.loads(run(["lsblk", "--json", "-o", "UUID,MOUNTPOINTS"]).stdout)
        result = []
        def walk(nodes):
            for node in nodes:
                if node.get("uuid"):
                    result.extend({"path": p, "id": node["uuid"]} for p in node.get("mountpoints", []) if p)
                walk(node.get("children", []))
        walk(data["blockdevices"])
        return result

    def device_root(self, device, *, enrolling=False, volumes=None):
        matches = [v for v in (self.volumes() if volumes is None else volumes) if v["id"] == device["volumeId"]]
        if len(matches) != 1:
            raise MemoryError("device-offline-or-ambiguous")
        mount = safe_path(Path(matches[0]["path"]))
        root = safe_path(mount / device["relativePath"])
        if not enrolling:
            marker = read_json(root / "device.json", {})
            if marker != {"format": FORMAT, "deviceId": device["id"], "memoryId": self.config["memoryId"]}:
                raise MemoryError("device-identity-mismatch")
        return root

    def device_enroll(self, mount_path):
        self.initialize()
        mount = safe_path(Path(mount_path))
        volumes = [v for v in self.volumes() if safe_path(Path(v["path"])) == mount]
        system_drive = os.environ.get("SystemDrive", "C:").lower()
        if len(volumes) != 1 or (os.name != "nt" and mount == Path(mount.anchor)) or (os.name == "nt" and str(mount).lower().startswith(system_drive)):
            raise MemoryError("select-mounted-data-volume")
        device = {"id": str(uuid.uuid4()), "volumeId": volumes[0]["id"],
                  "relativePath": "PhaseZero/ai-memory", "label": mount.name}
        root = self.device_root(device, enrolling=True)
        marker = read_json(root / "device.json")
        if marker:
            if marker.get("format") != FORMAT or marker.get("memoryId") != self.config["memoryId"]:
                raise MemoryError("foreign-device-import-recovery-key-first")
            device["id"] = marker["deviceId"]
        if any(d["volumeId"] == device["volumeId"] for d in self.config["devices"]):
            raise MemoryError("device-already-enrolled")
        write_json(root / "device.json", {"format": FORMAT, "deviceId": device["id"], "memoryId": self.config["memoryId"]})
        self.config["devices"].append(device)
        self.save()
        return {"ok": True, "state": "device-enrolled", "device": device}

    def device_publish(self, device, blob, kind, scope=None, fingerprint=None):
        root = self.device_root(device)
        relative = Path(kind) / self.config["hostId"]
        if scope:
            relative /= scope["id"]
        destination = safe_path(root / relative)
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        previous = read_json(destination / "latest.json", {})
        if fingerprint and previous.get("contentFingerprint") == fingerprint:
            old_hash = previous.get("sha256", "")
            if re.fullmatch(r"[0-9a-f]{64}", old_hash):
                old = safe_path(destination / (old_hash + ".gpg"))
                if old.is_file() and digest(old) == old_hash:
                    return "unchanged"
        checksum = digest(blob)
        final = destination / (checksum + ".gpg")
        if not final.exists():
            if shutil.disk_usage(destination).free < blob.stat().st_size + 64 * 1024**2:
                raise MemoryError("device-insufficient-space")
            # Stage on destination filesystem; never overwrite last-good object.
            fd, name = tempfile.mkstemp(prefix=".partial-", dir=destination)
            try:
                with os.fdopen(fd, "wb") as output, blob.open("rb") as source:
                    shutil.copyfileobj(source, output)
                    output.flush()
                    os.fsync(output.fileno())
                if digest(Path(name)) != checksum:
                    raise MemoryError("device-transfer-integrity-failed")
                self.device_root(device)  # removable path still belongs to enrolled volume
                os.replace(name, final)
            finally:
                Path(name).unlink(missing_ok=True)
        elif digest(final) != checksum:
            raise MemoryError("device-object-damaged")
        write_json(destination / "latest.json", {"sha256": checksum, "size": blob.stat().st_size,
                   "contentFingerprint": fingerprint, "verifiedAt": now()})
        objects = sorted(destination.glob("*.gpg"), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in objects[max(2, self.config.get("keep", 7)):]:
            if old != final:
                safe_path(old).unlink()

    def device_pull(self, device, scopes, temp, *, prefer=None):
        root = self.device_root(device)
        by_id = {s["id"]: s for s in scopes}
        practice_errors = []
        for pointer in sorted((root / "knowledge").glob("*/*/latest.json")):
            peer, scope_id = pointer.parent.parent.name, pointer.parent.name
            if peer == self.config["hostId"] or scope_id not in by_id:
                continue
            metadata = read_json(pointer, {})
            checksum = metadata.get("sha256", "")
            if not re.fullmatch(r"[0-9a-f]{64}", checksum):
                raise MemoryError("invalid-device-pointer")
            blob = safe_path(pointer.parent / (checksum + ".gpg"))
            if blob.stat().st_size > MAX_KNOWLEDGE or digest(blob) != checksum:
                raise MemoryError("device-knowledge-integrity-failed")
            self.import_peer(blob, by_id[scope_id], peer, temp / uuid.uuid4().hex,
                             practice_errors, prefer=prefer)
        return practice_errors

    def sync(self, *, automatic=False, force_backup=False):
        if not self.config.get("keyRef"):
            raise MemoryError("configure-memory-key-first")
        if automatic and not self.config.get("automatic"):
            return {"ok": True, "state": "paused"}
        previous = read_json(self.state / "last-run.json", {})
        # The system vault may be locked after login. Do not pull, write a
        # running marker, or fail the timer for a condition the user can clear.
        try:
            self.password()
        except MemoryError as error:
            if not automatic or str(error) != "memory-key-unavailable-unlock-system-vault":
                raise
            waiting = {"schemaVersion": 1, "ok": True, "state": "waiting-unlock",
                       "synchronized": False, "reason": str(error), "startedAt": now(),
                       "completedAt": now(),
                       "targets": [{**target, "ok": False, "state": "waiting-unlock"}
                                   for target in previous.get("targets", [])]}
            write_json(self.state / "last-run.json", waiting)
            return waiting
        result = {"schemaVersion": 1, "ok": True, "startedAt": now(), "targets": []}
        previous_targets = {r["id"]: r for r in previous.get("targets", [])}
        write_json(self.state / "last-run.json", {**previous, "state": "running", "startedAt": result["startedAt"]})
        with self.scratch() as temp:
            available = []
            for device in self.config.get("devices", []):
                try:
                    self.device_root(device)
                    available.append((device["id"], device))
                except MemoryError as error:
                    result["targets"].append({"id": device["id"], "state": str(error), "ok": False,
                        "lastBackup": previous_targets.get(device["id"], {}).get("lastBackup")})
            if self.config.get("github"):
                old_github = previous_targets.get("github", {})
                retry = old_github.get("retryAfter")
                if automatic and retry and datetime.fromisoformat(retry) > datetime.now(timezone.utc):
                    result["targets"].append({**old_github, "state": "retry-pending", "ok": False})
                else:
                    available.append(("github", None))
            if not available:
                result.update(ok=not bool(result["targets"]), state="no-target-online" if result["targets"] else "no-target-configured")
            scopes = self.config.get("scopes", [])
            # Pull before exporting, but no destructive mirroring on either side.
            healthy = []
            knowledge_errors = {}
            practice_errors = {}
            for target_id, device in available:
                try:
                    if device:
                        errors = self.device_pull(device, scopes, temp)
                    else:
                        errors = self.github_pull(scopes, temp)
                    if errors:
                        practice_errors[target_id] = errors
                    healthy.append((target_id, device))
                except Exception as error:
                    knowledge_errors[target_id] = self.error_code(error)
            exports = []
            if healthy:
                for scope in scopes:
                    try:
                        scope_temp = temp / scope["id"]
                        scope_temp.mkdir()
                        exports.append((scope, *self.export_knowledge(scope, scope_temp)))
                    except Exception as error:
                        reason = self.error_code(error)
                        if scope["id"] == PRACTICES_SCOPE:
                            for target_id, _device in healthy:
                                practice_errors.setdefault(target_id, []).append(reason)
                            continue
                        for target_id, _device in healthy:
                            knowledge_errors[target_id] = reason
                        exports = []
                        break
            backup_blob = None
            for target_id, device in available:
                old = previous_targets.get(target_id, {})
                target_result = {"id": target_id, "ok": target_id not in knowledge_errors,
                                 "lastBackup": old.get("lastBackup"), "lastSync": old.get("lastSync")}
                try:
                    if target_id not in knowledge_errors:
                        for scope, blob, _manifest, fingerprint in exports:
                            if device:
                                self.device_publish(device, blob, "knowledge", scope, fingerprint)
                            else:
                                self.github_push(blob, scope, fingerprint)
                        target_result["lastSync"] = now()
                    last = old.get("lastBackup", {}).get("verifiedAt") if old.get("lastBackup") else None
                    due = force_backup or not last or (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() >= self.config.get("backupHours", 24) * 3600
                    if due:
                        if backup_blob is None:
                            backup_temp = temp / "backup"
                            backup_temp.mkdir()
                            backup_blob, _ = self.snapshot("backup", backup_temp)
                        if device:
                            self.device_publish(device, backup_blob, "backup")
                            target_result["lastBackup"] = {"verifiedAt": now(), "sha256": digest(backup_blob)}
                        else:
                            target_result["lastBackup"] = self.github_backup(backup_blob)
                    target_result["state"] = knowledge_errors.get(target_id, "current")
                except Exception as error:
                    target_result.update(ok=False, state=self.error_code(error))
                if target_id == "github" and (target_result["state"].startswith("command-failed:gh:")
                                                or target_result["state"].startswith("command-unavailable-or-timeout:gh")):
                    failures = old.get("failures", 0) + 1
                    seconds = min(21600, self.config.get("intervalMinutes", 15) * 60 * 2 ** min(failures - 1, 6))
                    target_result.update(failures=failures,
                        retryAfter=(datetime.now(timezone.utc) + timedelta(seconds=seconds + secrets.randbelow(30))).isoformat(timespec="seconds"))
                elif target_result["ok"]:
                    target_result.update(failures=0, retryAfter=None)
                if target_id in practice_errors:
                    if target_result["ok"]:
                        target_result["state"] = "practices-needs-attention"
                    target_result.update(ok=False, practicesErrors=sorted(set(practice_errors[target_id])))
                result["targets"].append(target_result)
        result["ok"] = result["ok"] and all(r["ok"] for r in result["targets"])
        result.setdefault("state", "current" if result["ok"] else "needs-attention")
        result["completedAt"] = now()
        write_json(self.state / "last-run.json", result)
        return result

    @staticmethod
    def error_code(error):
        return str(error) if isinstance(error, MemoryError) else "operation-failed-check-dependencies-or-system-vault"

    @staticmethod
    def advice(reason):
        messages = {
            "knowledge-conflict-review-required": "Conflito preservado. Revise versão local e recebida em Resolver conflitos.",
            "device-offline-or-ambiguous": "Reconecte dispositivo cadastrado e tente novamente.",
            "memory-key-unavailable-unlock-system-vault": "Desbloqueie cofre do sistema ou importe chave de recuperação.",
            "github-repository-identity-or-privacy-changed": "Confira identidade do destino e mantenha repositório privado.",
            "select-existing-project-and-workspace-from-memory-status": "Selecione projeto existente ou escolha criar projeto neste host.",
            "install-PhaseZero-runtime-before-enabling-automation": "Instale runtime PhaseZero antes de ligar automação.",
            "operation-busy": "Outra operação está em andamento. Aguarde e atualize estado.",
            "practices-not-configured": "Cadastre a chave pública do curador com practices-configure.",
            "practices-page-unavailable": "Confirme que o ai-memory local está ativo e sincronize um catálogo aprovado.",
            "practices-trusted-primary-key-not-found": "Importe a chave pública do curador e confira a impressão digital completa.",
            "practices-signature-required": "A página não contém um catálogo assinado. Use as regras do repositório.",
            "practices-signature-untrusted": "A assinatura não corresponde à chave confiável ou o catálogo foi alterado.",
            "practices-revision-conflict-or-rollback": "A revisão recebida diverge da versão já aceita. Confira com o curador.",
            "curation-select-memorial": "Selecione o memorial.md que deseja revisar.",
            "curation-memorial-file-required": "Selecione um memorial.md em UTF-8, com título Markdown e até 32 KiB.",
            "curation-no-eligible-subscription": "Nenhuma conta com cota confirmada para um modelo de alta capacidade. Confira o login e as cotas e tente novamente.",
            "curation-account-changed": "A conta mudou durante a seleção. Confirme o login e inicie nova curadoria.",
            "curation-source-changed": "O memorial mudou. Inicie nova curadoria para revisar a versão atual.",
            "source-changed-before-replace": "O arquivo mudou antes de salvar. Gere uma proposta para a versão atual.",
            "curation-review-source-first": "Revise a prévia atual e confirme a operação.",
            "curation-report-required": "Gere uma proposta de curadoria para revisar.",
            "curation-no-changes": "A proposta não contém mudanças para aplicar.",
            "curation-invalid-result": "O CLI retornou uma proposta inválida. Confira o memorial antes de gerar outra.",
            "curation-unsubstantiated-result": "A proposta contém achado sem evidência verificável no memorial.",
            "curation-overlapping-edits": "A proposta contém edições que se sobrepõem. Gere uma nova proposta.",
            "curation-editorial-replacement": "O modelo explicou a edição sem fornecer o texto final. Gere outra proposta.",
            "curation-cli-timeout-or-unavailable": "O CLI selecionado ficou indisponível ou excedeu o tempo. Confira a sessão e a rede.",
            "curation-cli-failed": "O CLI selecionado interrompeu a revisão. Confira a sessão e a cota antes de tentar novamente.",
            "operation-failed-check-dependencies-or-system-vault": "Confira dependências e desbloqueio do cofre do sistema.",
        }
        if reason.startswith("command-failed:gh:"):
            return "Confira conexão de rede, login GitHub CLI e acesso ao repositório privado."
        if "ai-memory-wikisync" in reason:
            return "Use Reparar e confira projeto, versão e API da memória."
        return messages.get(reason, "Operação interrompida. Confira diagnóstico e recuperação antes de tentar novamente.")

    def recovery(self, action, file, passphrase):
        if len(passphrase) < 12:
            raise MemoryError("recovery-passphrase-needs-12-characters")
        with self.scratch() as temp:
            plain = temp / "recovery.json"
            if action == "key-export":
                destination = safe_path(Path(file))
                if destination.exists():
                    raise MemoryError("recovery-output-already-exists")
                write_json(plain, {"format": FORMAT, "memoryId": self.config["memoryId"], "key": self.password()})
                encrypted = temp / "recovery.gpg"
                crypt(plain, encrypted, passphrase)
                atomic(destination, encrypted.read_bytes())
                self.config["recoveryExportedAt"] = now()
            else:
                if self.config.get("devices") or self.config.get("github") or self.config.get("scopes"):
                    raise MemoryError("import-recovery-before-enrolling-targets-and-scopes")
                crypt(safe_path(Path(file)), plain, passphrase, decrypt=True)
                metadata = read_json(plain, {})
                if (metadata.get("format") != FORMAT or not isinstance(metadata.get("key"), str)
                        or len(metadata["key"]) < 32):
                    raise MemoryError("invalid-recovery-key")
                uuid.UUID(metadata["memoryId"])
                self.initialize()
                old_reference = self.config["keyRef"]
                reference = new_secret_reference()
                if os.name == "nt":
                    reference = reference.replace("secret-service:", "wincred:")
                self.vault.store(reference, metadata["key"])
                self.config["keyRef"] = reference
                self.config.setdefault("retiredKeyRefs", []).append(old_reference)
                self.config["memoryId"] = metadata["memoryId"]
            self.save()
        return {"ok": True, "state": action + "ed"}

    def schedule(self, enabled):
        if enabled and (ROOT / ".git").exists():
            raise MemoryError("install-PhaseZero-runtime-before-enabling-automation")
        self.initialize()
        if os.name == "nt":
            python = sys.executable
            command = f'"{python}" "{Path(__file__).resolve()}" sync --automatic'
            if enabled:
                run(["schtasks.exe", "/Create", "/F", "/SC", "MINUTE", "/MO", str(self.config.get("intervalMinutes", 15)),
                     "/TN", "PhaseZero-AiMemorySync", "/TR", command])
                watch = f'"{python}" "{Path(__file__).resolve()}" watch'
                run(["schtasks.exe", "/Create", "/F", "/SC", "ONLOGON", "/TN", "PhaseZero-AiMemoryWatch", "/TR", watch])
                run(["schtasks.exe", "/Run", "/TN", "PhaseZero-AiMemoryWatch"])
            else:
                run(["schtasks.exe", "/Delete", "/F", "/TN", "PhaseZero-AiMemorySync"], allowed=(0, 1))
                run(["schtasks.exe", "/End", "/TN", "PhaseZero-AiMemoryWatch"], allowed=(0, 1))
                run(["schtasks.exe", "/Delete", "/F", "/TN", "PhaseZero-AiMemoryWatch"], allowed=(0, 1))
        else:
            units = self.config_home / "systemd/user"
            manager_path = Path(__file__).resolve()
            installed_base = Path(os.environ.get("PZ_USER_INSTALL_ROOT", Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "phasezero"))
            if ROOT.is_relative_to(installed_base / "releases"):
                manager_path = installed_base / "current/linux/ai/memory_manager.py"
            command = unit_quote(sys.executable) + " " + unit_quote(manager_path)
            for name, text in {
                "phasezero-ai-memory-sync.service": "[Unit]\nDescription=PhaseZero encrypted memory sync\n[Service]\nType=oneshot\nUMask=0077\nExecStart=" + command + " sync --automatic\nTimeoutStartSec=45min\n",
                "phasezero-ai-memory-sync.timer": f"[Unit]\nDescription=PhaseZero memory synchronization\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec={self.config.get('intervalMinutes', 15)}min\nRandomizedDelaySec=30\nPersistent=true\n[Install]\nWantedBy=timers.target\n",
                "phasezero-ai-memory-watch.service": "[Unit]\nDescription=PhaseZero memory enrolled-device watcher\n[Service]\nUMask=0077\nExecStart=" + command + " watch\nRestart=on-failure\nRestartSec=30\n[Install]\nWantedBy=default.target\n",
            }.items():
                backup_file(units / name, module="ai-memory")
                atomic(units / name, text.encode())
            run(["systemctl", "--user", "daemon-reload"])
            run(["systemctl", "--user", "enable" if enabled else "disable", "--now",
                 "phasezero-ai-memory-sync.timer", "phasezero-ai-memory-watch.service"])
            if enabled:
                run(["systemctl", "--user", "restart", "phasezero-ai-memory-sync.timer"])
        self.config["automatic"] = enabled
        self.save()
        ledger_record(module="ai-memory", action="automatic-enable" if enabled else "automatic-pause",
                      services=["phasezero-ai-memory-sync", "phasezero-ai-memory-watch"], reversible=True)
        return {"ok": True, "state": "automatic-enabled" if enabled else "automatic-paused"}

    def settings(self, interval, backup_hours, keep):
        if not 5 <= interval <= 1440 or not 1 <= backup_hours <= 168 or not 2 <= keep <= 30:
            raise MemoryError("invalid-cadence-or-retention")
        self.initialize()
        self.config.update(intervalMinutes=interval, backupHours=backup_hours, keep=keep)
        self.save()
        if self.config.get("automatic"):
            self.schedule(True)
        return {"ok": True, "state": "settings-updated", "intervalMinutes": interval, "backupHours": backup_hours, "keep": keep}

    def watch(self):
        previous = set()
        while True:
            self.config = read_json(self.config_path, {})
            current = {v["id"] for v in self.volumes()}
            enrolled = {d["volumeId"] for d in self.config.get("devices", [])}
            if self.config.get("automatic") and (current - previous) & enrolled:
                try:
                    with locked(self.state / "operation.lock"):
                        self.sync(automatic=True)
                except MemoryError:
                    pass  # timer retries; never terminates another worker
            previous = current
            time.sleep(10)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "plan", "install", "repair", "initialize", "sync", "backup",
                        "scope-add", "scope-remove", "device-add", "device-remove", "github", "automatic", "watch",
                        "verify", "restore-plan", "restore", "key-export", "key-import", "install-sync", "resolve", "conflict-plan", "settings", "github-remove", "github-login", "github-open-backups",
                        "practices", "practices-configure", "practices-publish",
                        "curate-plan", "curate", "curate-review", "curate-apply"))
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--automatic", action="store_true")
    parser.add_argument("--enabled", choices=("yes", "no"), default="yes")
    parser.add_argument("--project")
    parser.add_argument("--workspace", default="default")
    parser.add_argument("--repo-path")
    parser.add_argument("--identity")
    parser.add_argument("--fingerprint")
    parser.add_argument("--revision", type=int)
    parser.add_argument("--families", default=",".join(FAMILIES))
    parser.add_argument("--id")
    parser.add_argument("--path")
    parser.add_argument("--repository")
    parser.add_argument("--create", action="store_true")
    parser.add_argument("--create-project", action="store_true")
    parser.add_argument("--confirm")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--prefer", choices=("repo", "server"))
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--backup-hours", type=int, default=24)
    parser.add_argument("--keep", type=int, default=7)
    parser.add_argument("--passphrase-stdin", action="store_true")
    args = parser.parse_args(argv)
    try:
        manager = Manager()
        if args.action == "status":
            result = manager.status()
        elif args.action == "plan":
            result = {"ok": True, "state": "planned", "version": json.loads((ROOT / "packaging/ai-memory/pins.json").read_text())["version"],
                      "changes": ["preserve existing memory", "verified native install", "official knowledge companion", "repair service and wiring"],
                      "credentialsIncluded": False, "githubRequires": "private repository and enrolled recovery key"}
        elif args.action == "watch":
            manager.watch()
            return 0
        else:
            action = args.action
            lock_path = "curation/operation.lock" if action in CURATION_ACTIONS else "operation.lock"
            with locked(manager.state / lock_path):
                if action in {"install", "repair", "install-sync"}:
                    script = ROOT / ("windows/ai/memory.ps1" if os.name == "nt" else "linux/ai/setup-memory.sh")
                    if os.name == "nt":
                        run(["powershell.exe", "-NoProfile", "-File", script, "-Action", action], timeout=1800, env=manager.client_environment())
                    else:
                        run(["bash", script, "install-sync" if action == "install-sync" else "setup"], timeout=1800, env=manager.client_environment())
                        if action in {"install", "repair"} and not Path(manager.companion).is_file():
                            run(["bash", script, "install-sync"], timeout=1800)
                    manager.initialize()
                    result = manager.status()
                    result["ok"] = result["state"] == "ready"
                elif action == "initialize":
                    manager.initialize()
                    result = {"ok": True, "state": "initialized"}
                elif action in {"sync", "backup"}:
                    if args.prefer:
                        raise MemoryError("resolve-one-selected-conflict-instead-of-bulk-overwrite")
                    result = manager.sync(automatic=args.automatic, force_backup=action == "backup")
                elif action in {"resolve", "conflict-plan"}:
                    result = manager.resolve(args.id, args.prefer, plan=action == "conflict-plan")
                elif action == "scope-add":
                    if not args.project or not args.repo_path:
                        raise MemoryError("project-and-repository-path-required")
                    result = manager.add_scope(args.project, args.workspace, args.repo_path, args.families, create_project=args.create_project, identity=args.identity)
                elif action == "practices-configure":
                    result = manager.configure_practices(args.fingerprint, args.repo_path or Path.cwd())
                elif action == "practices-publish":
                    if not args.path:
                        raise MemoryError("practices-markdown-path-required")
                    result = manager.publish_practices(args.path, args.revision)
                elif action == "practices":
                    result = manager.practices()
                elif action in CURATION_ACTIONS:
                    from linux.ai import memory_curation
                    if action == "curate-plan":
                        result = memory_curation.plan(args.path)
                    elif action == "curate":
                        result = memory_curation.run_curation(manager, args.path, args.expected_sha256, args.confirm)
                    else:
                        result = memory_curation.review(manager, args.id, apply=action == "curate-apply",
                                                        confirm=args.confirm, checksum=args.expected_sha256)
                elif action == "device-add":
                    if not args.path:
                        raise MemoryError("mounted-device-path-required")
                    result = manager.device_enroll(args.path)
                elif action in {"scope-remove", "device-remove"}:
                    key = "scopes" if action == "scope-remove" else "devices"
                    if not args.id or not any(x["id"] == args.id for x in manager.config.get(key, [])):
                        raise MemoryError("enrolled-id-required")
                    manager.config[key] = [x for x in manager.config[key] if x["id"] != args.id]
                    manager.save()
                    result = {"ok": True, "state": "unenrolled-data-preserved"}
                elif action == "github":
                    if not args.repository:
                        raise MemoryError("github-repository-required")
                    result = manager.github_configure(args.repository, create=args.create)
                elif action == "github-login":
                    result = manager.github_login()
                elif action == "github-open-backups":
                    result = manager.github_open_backups()
                elif action == "automatic":
                    result = manager.schedule(args.enabled == "yes")
                elif action == "settings":
                    result = manager.settings(args.interval, args.backup_hours, args.keep)
                elif action == "github-remove":
                    manager.config.pop("github", None)
                    manager.save()
                    result = {"ok": True, "state": "github-unlinked-remote-data-preserved"}
                elif action in {"key-export", "key-import"}:
                    if not args.path or not args.passphrase_stdin:
                        raise MemoryError("path-and-passphrase-stdin-required")
                    passphrase = sys.stdin.buffer.readline().decode("utf-8").rstrip("\r\n")
                    result = manager.recovery(action, args.path, passphrase)
                elif action in {"verify", "restore-plan", "restore"}:
                    if not args.path:
                        raise MemoryError("bundle-path-required")
                    with manager.scratch() as temp:
                        source_hash = digest(safe_path(Path(args.path)))
                        root, manifest = manager.verify(Path(args.path), temp / "verified")
                        if digest(Path(args.path)) != source_hash:
                            raise MemoryError("bundle-changed-during-verification")
                        result = {"ok": True, "state": "verified" if action == "verify" else "restore-planned",
                                  "sha256": source_hash, "bundlePath": str(Path(args.path).absolute()),
                                  "manifest": manifest, "preBackup": True, "stopService": True,
                                  "restoreConfig": False, "restoreRaw": manifest.get("rawIncluded", False)}
                        if action == "restore":
                            if args.confirm != "RESTORE" or manifest["kind"] != "backup" or args.expected_sha256 != source_hash:
                                raise MemoryError("restore-plan-hash-and-confirm-RESTORE-required")
                            result = restore_native(manager, root, manifest)
                else:
                    raise MemoryError("unsupported-action")
        print(json.dumps(result, ensure_ascii=True))
        return 0 if result.get("ok") else 1
    except Exception as error:
        reason = Manager.error_code(error)
        print(json.dumps({"schemaVersion": 1, "ok": False, "state": "blocked", "reason": reason, "message": Manager.advice(reason)}, ensure_ascii=True))
        return 1


def restore_native(manager, root, manifest):
    """Never restore implicitly on sync. Preserve current store before stopping."""
    if os.name == "nt":
        managed_root = Path(os.environ["LOCALAPPDATA"]) / "PhaseZero/ai-tools/ai-memory"
        if not Path(manager.binary).resolve().is_relative_to(managed_root.resolve()):
            raise MemoryError("external-memory-server-requires-its-own-offline-restore")
        env = os.environ.copy()
        env["PZ_MEMORY_RESTORE_EXE"] = str(Path(manager.binary).resolve())
        env["PZ_MEMORY_RESTORE_DATA"] = str(manager.data)
        stop = ["powershell.exe", "-NoProfile", "-Command",
                "Get-CimInstance Win32_Process -Filter \"Name='ai-memory.exe'\" | "
                "Where-Object { $_.ExecutablePath -eq $env:PZ_MEMORY_RESTORE_EXE -and "
                "$_.CommandLine -match [regex]::Escape($env:PZ_MEMORY_RESTORE_DATA) } | "
                "ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction Stop; 'stopped' }"]
        start = ["schtasks.exe", "/Run", "/TN", "BootstrapTools-AiMemoryServer"]
        active = manager.status()["serverReachable"]
    else:
        active = run(["systemctl", "--user", "is-active", "ai-memory.service"], allowed=(0, 1, 3, 4)).returncode == 0
        unit = manager.config_home / "systemd/user/ai-memory.service"
        if active:
            fragment = run(["systemctl", "--user", "show", "ai-memory.service", "--property=FragmentPath", "--value"]).stdout.decode().strip()
            if Path(fragment) != unit or not unit.is_file():
                raise MemoryError("external-memory-service-preserved")
            command = next((line[10:] for line in unit.read_text().splitlines() if line.startswith("ExecStart=")), "")
            arguments = shlex.split(command)
            if "--data-dir" not in arguments or Path(arguments[arguments.index("--data-dir") + 1]).resolve() != manager.data.resolve():
                raise MemoryError("memory-service-data-directory-mismatch")
        env = None
        stop = ["systemctl", "--user", "stop", "ai-memory.service"]
        start = ["systemctl", "--user", "start", "ai-memory.service"]
    rollback = manager.state / "restore" / uuid.uuid4().hex
    rollback.mkdir(parents=True, mode=0o700)
    manager.native("backup", "--to", str(rollback / "before.tar.gz"))
    if (root / "payload/external-config.toml").is_file():
        atomic(rollback / "external-config-from-backup.toml", (root / "payload/external-config.toml").read_bytes())
    if (root / "payload/portability-metadata.json").is_file():
        atomic(rollback / "portability-metadata-from-backup.json", (root / "payload/portability-metadata.json").read_bytes())
    raw_previous = manager.data / (".phasezero-raw-before-" + uuid.uuid4().hex)
    raw_stage = manager.data / (".phasezero-raw-stage-" + uuid.uuid4().hex)
    swapped = False
    had_raw = (manager.data / "raw").exists()
    if manifest.get("rawIncluded"):
        raw_source = root / "payload/raw"
        if raw_source.exists():
            shutil.copytree(raw_source, raw_stage)
        else:
            raw_stage.mkdir(mode=0o700)
    if active:
        run(stop, env=env)
    try:
        manager.native("restore", "--from", str(root / "payload/native.tar.gz"), "--force")
        if manifest.get("rawIncluded"):
            if had_raw:
                (manager.data / "raw").rename(raw_previous)
            try:
                raw_stage.rename(manager.data / "raw")
                swapped = True
            except Exception:
                if had_raw:
                    raw_previous.rename(manager.data / "raw")
                raise
    except Exception:
        manager.native("restore", "--from", str(rollback / "before.tar.gz"), "--force")
        if swapped:
            (manager.data / "raw").rename(raw_stage)
            if had_raw:
                raw_previous.rename(manager.data / "raw")
        raise
    finally:
        if raw_stage.exists():
            shutil.rmtree(raw_stage)
        if active:
            run(start, env=env)
    return {"ok": True, "state": "restored", "rollback": str(rollback), "sourceHost": manifest["sourceHost"],
            "rawBefore": str(raw_previous) if raw_previous.exists() else None,
            "configuration": "preserved-review-external-config-from-backup-in-rollback-directory"}


if __name__ == "__main__":
    sys.modules["linux.ai.memory_manager"] = sys.modules[__name__]
    raise SystemExit(main())
