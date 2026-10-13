#!/usr/bin/env python3
"""Transactional Claude Code, Bonsai and local proxy manager for Linux."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
ROUTE_KEYS = {
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
}
DEFAULT_MODEL_KEYS = {
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
}
PROFILE_NAMES = (".bashrc", ".bash_profile", ".profile", ".zshrc")
SHIM_PATH_BLOCK_START = "# >>> PhaseZero Bonsai shim PATH >>>"
SHIM_PATH_BLOCK_END = "# <<< PhaseZero Bonsai shim PATH <<<"
SECRET_FILE_RE = re.compile(
    r"(^|/)(\.env($|\.)|\.npmrc$|\.pypirc$|id_[^/]+$|credentials($|\.)|"
    r"secrets?($|[./_-])|.*\.(pem|p12|pfx|key)$)",
    re.IGNORECASE,
)
KNOWN_SHELL_BUILTINS = {".", ":", "source", "test", "[", "printf", "echo", "true", "false"}
BONSAI_ROUTER_URL = "https://go.trybons.ai"
BONSAI_VERSION = "0.4.19"
BONSAI_WORKOS_CLIENT_ID = "client_01K2ZG07ZTYR0FQNERK3PS2CB0"
BONSAI_WORKOS_DEVICE_URL = "https://api.workos.com/user_management/authorize/device"
# Published package identity, not a registry response.  Keep this allowlist
# intentionally narrow: a vanished registry must not turn cache contents into
# an unverified distribution channel.
BONSAI_INTEGRITIES = {
    "0.4.19": "sha512-tC8iTvm+dKpyAWBg0QyNBqR0lrUB3abPoHn2kkKCA36m0W0JNGnh1wCyn55D69YpxdG67pmPOsTTUgXPG2Blig==",
}
BONSAI_EXISTING_HASHES = {
    "0.4.19": {
        "cliSha256": "38fb1e96fe56f393133049bb4a865e37136aab2ab9ed1f68eb5cc8f781a44f54",
        "packageSha256": "5fe587a8d6cd8bef5cbc6d3c2b17177c9868615325918e62ae3ef8cfe663dc70",
    }
}
SEMVER_RE = re.compile(r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
TRANSIENT_NETWORK_CODES = {
    "EAI_AGAIN",
    "ECONNABORTED",
    "ECONNREFUSED",
    "ECONNRESET",
    "EHOSTUNREACH",
    "ENETUNREACH",
    "ENOTFOUND",
    "ENOTIMP",
    "ETIMEDOUT",
    "ETIMEOUT",
}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def stamp() -> str:
    return dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")


def command_path(name: str) -> str | None:
    override = os.environ.get(f"PZ_{name.upper().replace('-', '_')}_COMMAND")
    if override:
        return override if Path(override).exists() else shutil.which(override)
    resolved = shutil.which(name)
    if resolved:
        return resolved
    home = Path(os.environ.get("HOME", str(Path.home())))
    for candidate in (
        home / ".local/bin" / name,
        home / ".npm-global/bin" / name,
        home / ".local/share/npm/bin" / name,
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def run_capture(args: list[str], timeout: int = 12, env: dict[str, str] | None = None) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            args,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            env=env,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 124, "", str(exc)


def json_capture(args: list[str], timeout: int = 12) -> dict[str, Any] | None:
    rc, out, _ = run_capture(args, timeout=timeout)
    if rc != 0:
        return None
    try:
        value = json.loads(out)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        return None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def path_digest(path: Path) -> str | None:
    if path.is_symlink():
        return hashlib.sha256(os.readlink(path).encode()).hexdigest()
    if path.is_file():
        return file_sha256(path)
    if path.is_dir():
        digest = hashlib.sha256()
        for child in sorted(path.rglob("*"), key=lambda item: str(item.relative_to(path))):
            rel = str(child.relative_to(path))
            digest.update(rel.encode())
            if child.is_symlink():
                digest.update(b"L")
                digest.update(os.readlink(child).encode())
            elif child.is_file():
                digest.update(b"F")
                digest.update(file_sha256(child).encode())
            elif child.is_dir():
                digest.update(b"D")
        return digest.hexdigest()
    return None


def path_kind(path: Path) -> str:
    if path.is_symlink():
        return "symlink"
    if path.is_file():
        return "file"
    if path.is_dir():
        return "directory"
    return "absent"


def atomic_text(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_json(path: Path, value: Any, mode: int = 0o600) -> None:
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n", mode)


class Transaction:
    def __init__(self, data_root: Path, operation: str) -> None:
        operation_id = f"{operation}-{stamp()}-{os.getpid()}"
        self.root = data_root / "operations" / operation_id
        self.backup_root = self.root / "backup"
        self.manifest_path = self.root / "manifest.json"
        self.report_path = data_root / f"report-{operation_id}.md"
        self.log_path = data_root / f"install-{operation_id}.log"
        self.manifest: dict[str, Any] = {
            "schemaVersion": SCHEMA_VERSION,
            "operationId": operation_id,
            "operation": operation,
            "startedAt": now_iso(),
            "completedAt": None,
            "status": "running",
            "selectedAuth": None,
            "paths": [],
            "services": {},
            "systemd": {},
            "packages": [],
            "processes": [],
            "verification": {},
            "secretsRedacted": True,
        }
        self._records: dict[str, dict[str, Any]] = {}
        data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(data_root, 0o700)
        self.save()

    def save(self) -> None:
        atomic_json(self.manifest_path, self.manifest)

    def log(self, message: str) -> None:
        safe = re.sub(r"(sk[-_][A-Za-z0-9_-]{4})[A-Za-z0-9_-]+", r"\1<redacted>", message)
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(f"[{now_iso()}] {safe}\n")
        os.chmod(self.log_path, 0o600)

    def backup(self, path: Path) -> dict[str, Any]:
        path = path.expanduser().absolute()
        key = str(path)
        if key in self._records:
            return self._records[key]
        index = len(self.manifest["paths"])
        kind = path_kind(path)
        st = path.lstat() if kind != "absent" else None
        record: dict[str, Any] = {
            "path": key,
            "kindBefore": kind,
            "modeBefore": stat.S_IMODE(st.st_mode) if st else None,
            "uidBefore": st.st_uid if st else None,
            "gidBefore": st.st_gid if st else None,
            "checksumBefore": path_digest(path),
            "linkTargetBefore": os.readlink(path) if kind == "symlink" else None,
            "backup": None,
            "kindAfter": None,
            "checksumAfter": None,
        }
        if kind in {"file", "directory"}:
            target = self.backup_root / f"{index:04d}-{path.name or 'root'}"
            if kind == "file":
                shutil.copy2(path, target)
            else:
                shutil.copytree(path, target, symlinks=True)
            record["backup"] = str(target)
        self.manifest["paths"].append(record)
        self._records[key] = record
        self.save()
        self.log(f"backup registered: {path} ({kind})")
        return record

    def record_service(self, unit: str) -> None:
        if unit in self.manifest["systemd"]:
            return
        systemctl = command_path("systemctl")
        active = enabled = False
        if systemctl:
            active = run_capture([systemctl, "--user", "is-active", "--quiet", unit], timeout=5)[0] == 0
            enabled = run_capture([systemctl, "--user", "is-enabled", "--quiet", unit], timeout=5)[0] == 0
        state = {"activeBefore": active, "enabledBefore": enabled}
        self.manifest["services"][unit] = state
        self.manifest["systemd"][unit] = state
        self.save()

    def finalize_paths(self) -> None:
        for record in self.manifest["paths"]:
            path = Path(record["path"])
            record["kindAfter"] = path_kind(path)
            record["checksumAfter"] = path_digest(path)
        self.save()

    def complete(self, verification: dict[str, Any], report: str) -> None:
        self.finalize_paths()
        self.manifest["verification"] = verification
        self.manifest["status"] = "complete"
        self.manifest["completedAt"] = now_iso()
        self.save()
        atomic_text(self.report_path, report, 0o600)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.is_dir():
        shutil.rmtree(path)


def _path_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _validated_manifest_scope(manifest_path: Path, manifest: dict[str, Any]) -> tuple[Path, list[Path]]:
    """Validate rollback provenance and return operation dir + writable roots.

    Rollback is intentionally destructive. A file picker must never turn an
    arbitrary downloaded JSON document into a delete/restore primitive.
    """
    raw = manifest_path.expanduser().absolute()
    if raw.is_symlink() or not raw.is_file():
        raise RuntimeError("rollback manifest must be a regular managed file")
    st = raw.stat()
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) & 0o077:
        raise RuntimeError("rollback manifest ownership/permissions are unsafe")
    resolved = raw.resolve(strict=True)
    home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().resolve()
    xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).expanduser().resolve()
    xdg_data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")).expanduser().resolve()
    local_bin = Path(os.environ.get("PZ_LOCAL_BIN", home / ".local/bin")).expanduser().resolve()
    installer_roots = (
        Path(os.environ.get("PZ_CC_INSTALLER_ROOT", xdg_data / "cc-installer")).expanduser(),
        Path(os.environ.get("PZ_OPENCODE_ROUTE_ROOT", xdg_data / "opencode-route-installer")).expanduser(),
    )
    operation_dir: Path | None = None
    for installer in installer_roots:
        operations = (installer / "operations").resolve()
        try:
            relative = resolved.relative_to(operations)
        except ValueError:
            continue
        if len(relative.parts) == 2 and relative.parts[1] == "manifest.json":
            operation_dir = operations / relative.parts[0]
            break
    if operation_dir is None or manifest.get("operationId") != operation_dir.name:
        raise RuntimeError("rollback manifest is outside a managed operation")
    writable_roots = list(dict.fromkeys((home, xdg_config, xdg_data, local_bin)))
    return operation_dir, writable_roots


def restore_manifest(manifest_path: Path, force: bool = False) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != SCHEMA_VERSION or not isinstance(manifest.get("paths"), list):
        raise RuntimeError("invalid rollback manifest")
    operation_dir, writable_roots = _validated_manifest_scope(manifest_path, manifest)
    backup_root = (operation_dir / "backup").resolve()
    mismatches: list[str] = []
    for record in manifest["paths"]:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise RuntimeError("invalid rollback path record")
        target = Path(record["path"])
        if not target.is_absolute():
            raise RuntimeError("rollback target must be absolute")
        # Resolve parent traversal/symlinks, but keep final component lexical:
        # a managed launcher may itself be a symlink to an external binary and
        # rollback only removes/restores that link.
        resolved_target = target.parent.resolve(strict=False) / target.name
        if not any(_path_within(resolved_target, root) for root in writable_roots):
            raise RuntimeError(f"rollback target outside managed user roots: {target}")
        if record.get("kindBefore") in {"file", "directory"}:
            backup_value = record.get("backup")
            if not isinstance(backup_value, str):
                raise RuntimeError("rollback backup missing")
            backup_path = Path(backup_value)
            if backup_path.is_symlink() or not _path_within(backup_path.resolve(strict=False), backup_root):
                raise RuntimeError("rollback backup outside operation bundle")
        expected = record.get("checksumAfter")
        current = path_digest(target)
        expected_kind = record.get("kindAfter")
        if expected_kind is not None and (current != expected or path_kind(target) != expected_kind):
            mismatches.append(str(target))
    if mismatches and not force:
        raise RuntimeError("rollback refused; paths changed after install: " + ", ".join(mismatches))

    systemctl = command_path("systemctl")
    if systemctl:
        service_states = manifest.get("systemd") or manifest.get("services", {})
        for unit in service_states:
            run_capture([systemctl, "--user", "disable", "--now", unit], timeout=20)

    for record in reversed(manifest["paths"]):
        target = Path(record["path"])
        kind = record["kindBefore"]
        remove_path(target)
        if kind == "absent":
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if kind == "symlink":
            target.symlink_to(record["linkTargetBefore"])
        elif kind == "file":
            shutil.copy2(Path(record["backup"]), target)
        elif kind == "directory":
            shutil.copytree(Path(record["backup"]), target, symlinks=True)
        if record.get("modeBefore") is not None and not target.is_symlink():
            os.chmod(target, int(record["modeBefore"]))

    if systemctl:
        run_capture([systemctl, "--user", "daemon-reload"], timeout=15)
        for unit, state in service_states.items():
            if state.get("enabledBefore"):
                run_capture([systemctl, "--user", "enable", unit], timeout=15)
            if state.get("activeBefore"):
                run_capture([systemctl, "--user", "start", unit], timeout=30)
    manifest["rollback"] = {"at": now_iso(), "status": "complete", "forced": force}
    atomic_json(manifest_path, manifest)
    return {"status": "complete", "manifest": str(manifest_path), "restored": len(manifest["paths"])}


class Manager:
    def __init__(self) -> None:
        self.home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().absolute()
        self.xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", self.home / ".config"))
        self.xdg_data = Path(os.environ.get("XDG_DATA_HOME", self.home / ".local/share"))
        self.local_bin = Path(os.environ.get("PZ_LOCAL_BIN", self.home / ".local/bin"))
        self.data_root = Path(os.environ.get("PZ_CC_INSTALLER_ROOT", self.xdg_data / "cc-installer"))
        self.claude_settings = self.home / ".claude/settings.json"
        self.bonsai_config = self.xdg_config / "bonsai-cli-nodejs/config.json"
        self.router_env = Path(
            os.environ.get("PZ_9ROUTER_ENV_FILE", self.xdg_config / "phasezero/ai-proxies/9router.env")
        )
        self.router_settings = self.xdg_config / "phasezero/9router/settings.json"
        self.repo_root = Path(__file__).resolve().parents[2]
        self.router_manager = Path(os.environ.get("PZ_9ROUTER_MANAGER", self.repo_root / "linux/ai/9router-manager.sh"))
        self.preflight_log = self.data_root / "preflight-events.jsonl"
        self.bonsai_auth_probe_state = self.data_root / "bonsai-auth-provider.json"

    @staticmethod
    def _failpoint(stage: str) -> None:
        if os.environ.get("PZ_CC_FAIL_AFTER") == stage:
            raise RuntimeError(f"injected failure after {stage}")

    def profiles(self) -> list[Path]:
        result = [self.home / name for name in PROFILE_NAMES]
        result.append(self.xdg_config / "fish/config.fish")
        return [path for path in result if path.exists()]

    def bonsai_workspace_audit(self, raw_path: str | Path) -> dict[str, Any]:
        path = Path(raw_path).expanduser().resolve()
        if not path.is_dir():
            return {"path": str(path), "safe": False, "blockers": ["missing-directory"], "scope": "filenames-only", "contentInspected": False, "secretsRedacted": True}
        sensitive_roots = (
            Path("/"),
            self.home,
            self.xdg_config,
            self.home / ".ssh",
            self.home / ".gnupg",
            self.home / ".aws",
            self.home / ".local/share/cc-installer",
        )
        if path in sensitive_roots or any(root != Path("/") and root in path.parents for root in sensitive_roots[2:]):
            return {"path": str(path), "safe": False, "blockers": ["sensitive-directory"], "scope": "filenames-only", "contentInspected": False, "secretsRedacted": True}
        entries: list[tuple[Path, str]] = []
        git = command_path("git")
        inside_git = bool(git and run_capture([git, "-C", str(path), "rev-parse", "--is-inside-work-tree"], timeout=5)[0] == 0)
        if inside_git and git:
            rc, out, _ = run_capture([git, "-C", str(path), "ls-files", "-co", "--exclude-standard", "-z"], timeout=20)
            if rc == 0:
                tracked = set(run_capture([git, "-C", str(path), "ls-files", "-z"], timeout=20)[1].split("\0"))
                for raw in filter(None, out.split("\0")):
                    candidate = path / raw
                    if not os.path.lexists(candidate):
                        continue
                    entries.append((candidate, "tracked" if raw in tracked else "untracked"))
        else:
            excluded = {".git", "node_modules", ".venv", "venv", "target", "build", "dist"}
            for root, dirs, files in os.walk(path, followlinks=False):
                dirs[:] = [name for name in dirs if name not in excluded]
                for name in files:
                    entries.append((Path(root) / name, "filesystem"))
                for name in dirs:
                    candidate = Path(root) / name
                    if candidate.is_symlink():
                        entries.append((candidate, "filesystem"))
        details: list[dict[str, str]] = []
        for candidate, origin in entries:
            relative = str(candidate.relative_to(path))
            if candidate.is_symlink():
                try:
                    external = not _path_within(candidate.resolve(strict=True), path)
                except OSError:
                    external = True
                if external:
                    details.append({"path": relative, "category": "external-symlink", "origin": origin})
                continue
            lowered = candidate.name.lower()
            category = None
            if lowered == ".env" or (lowered.startswith(".env.") and lowered not in {".env.example", ".env.sample", ".env.template"}):
                category = "dotenv"
            elif lowered in {".npmrc", ".pypirc", "credentials", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"} or lowered.startswith("credentials."):
                category = "credential-file"
            elif Path(lowered).suffix in {".pem", ".p12", ".pfx", ".key"}:
                category = "private-key-file"
            if category:
                details.append({"path": relative, "category": category, "origin": origin})
        categories = {item["category"] for item in details}
        return {
            "path": str(path),
            "safe": not categories,
            "blockers": sorted(categories),
            "filesScanned": len(entries),
            "warnings": ["large-workspace"] if len(entries) > 5000 else [],
            "blockerDetails": sorted(details, key=lambda item: (item["path"], item["category"])),
            "scope": "filenames-only",
            "contentInspected": False,
            "uploadApproved": False,
            "secretsRedacted": True,
        }

    @staticmethod
    def classify_network_failure(code: str | None, http_status: int | None = None) -> dict[str, Any]:
        normalized = (code or "").upper()
        if http_status == 429:
            return {"class": "rate-limit", "transient": True, "action": "explicit-9router-restart"}
        if http_status is not None and http_status >= 500:
            return {"class": "upstream-gateway", "transient": True, "action": "explicit-9router-restart"}
        if normalized == "ENOTIMP":
            return {"class": "dns-not-implemented", "transient": True, "action": "retry-or-explicit-9router"}
        if normalized in TRANSIENT_NETWORK_CODES:
            category = "dns" if normalized in {"EAI_AGAIN", "ENOTFOUND", "ENOTIMP"} else "transport"
            return {"class": category, "transient": True, "action": "retry-or-explicit-9router"}
        if normalized:
            return {"class": "network-error", "transient": False, "action": "inspect-network"}
        return {"class": "healthy", "transient": False, "action": "none"}

    def bonsai_network_preflight(self) -> dict[str, Any]:
        if os.environ.get("PZ_BONSAI_NETWORK_PREFLIGHT") == "skip":
            return {
                "ok": True,
                "class": "skipped-fixture",
                "transient": False,
                "dns": {"lookup": True, "a": True, "aaaa": True},
                "httpStatus": None,
                "durationMs": 0,
                "secretsRedacted": True,
            }
        node = command_path("node")
        if not node:
            return {
                "ok": False,
                "class": "node-missing",
                "transient": False,
                "dns": {"lookup": False, "a": False, "aaaa": False},
                "httpStatus": None,
                "durationMs": 0,
                "secretsRedacted": True,
            }
        base_url = os.environ.get("PZ_BONSAI_ROUTER_URL") or os.environ.get("BONSAI_ROUTER_URL") or BONSAI_ROUTER_URL
        endpoint = base_url.rstrip("/") + "/v1/models"
        host = urllib.parse.urlparse(endpoint).hostname or "unknown"
        script = r"""
const dns = require('node:dns').promises;
const http = require('node:http');
const https = require('node:https');
const target = new URL(process.argv[1]);
const result = {lookup:false, a:false, aaaa:false, status:null, code:null};
async function probeDns() {
  try { await dns.lookup(target.hostname, {all:true}); result.lookup = true; }
  catch (error) { result.code = error && error.code ? String(error.code) : 'DNS_ERROR'; }
  try { result.a = (await dns.resolve4(target.hostname)).length > 0; }
  catch (error) { if (!result.code && !['ENODATA','ENOTFOUND'].includes(error.code)) result.code = String(error.code || 'DNS_A_ERROR'); }
  try { result.aaaa = (await dns.resolve6(target.hostname)).length > 0; }
  catch (error) { if (!result.code && !['ENODATA','ENOTFOUND'].includes(error.code)) result.code = String(error.code || 'DNS_AAAA_ERROR'); }
}
function probeHttp() {
  return new Promise((resolve) => {
    const transport = target.protocol === 'http:' ? http : https;
    const request = transport.get(target, {headers:{'user-agent':'phasezero-bonsai-preflight/1'}}, (response) => {
      result.status = response.statusCode || null;
      response.resume();
      response.on('end', resolve);
    });
    request.setTimeout(5000, () => request.destroy(Object.assign(new Error('timeout'), {code:'ETIMEDOUT'})));
    request.on('error', (error) => { result.code = String(error.code || 'HTTP_ERROR'); resolve(); });
  });
}
(async () => { await probeDns(); if (result.lookup) await probeHttp(); console.log(JSON.stringify(result)); })();
"""
        started = time.monotonic()
        env = os.environ.copy()
        for key in ROUTE_KEYS | {"OPENAI_API_KEY", "OPENAI_BASE_URL"}:
            env.pop(key, None)
        rc, out, err = run_capture([node, "-e", script, endpoint], timeout=12, env=env)
        duration_ms = int((time.monotonic() - started) * 1000)
        raw: dict[str, Any] = {}
        if rc == 0:
            try:
                parsed = json.loads(out)
                raw = parsed if isinstance(parsed, dict) else {}
            except json.JSONDecodeError:
                raw = {}
        code = str(raw.get("code") or "") or next(
            (candidate for candidate in TRANSIENT_NETWORK_CODES if candidate in f"{err} {out}"),
            "PREFLIGHT_FAILED" if rc != 0 else "",
        )
        status_value = raw.get("status")
        http_status = int(status_value) if isinstance(status_value, int) else None
        classification = self.classify_network_failure(code or None, http_status)
        dns_ok = bool(raw.get("lookup") and (raw.get("a") or raw.get("aaaa")))
        http_ok = http_status is not None and http_status < 500 and http_status != 429
        return {
            "ok": bool(rc == 0 and dns_ok and http_ok and not code),
            "class": classification["class"],
            "transient": classification["transient"],
            "action": classification["action"],
            "host": host,
            "dns": {"lookup": bool(raw.get("lookup")), "a": bool(raw.get("a")), "aaaa": bool(raw.get("aaaa"))},
            "httpStatus": http_status,
            "durationMs": duration_ms,
            "secretsRedacted": True,
        }

    def bonsai_auth_probe(self) -> dict[str, Any]:
        """Probe device login without exposing code/URL and without opening a browser."""
        fixture = os.environ.get("PZ_BONSAI_AUTH_PROBE")
        fixture_map = {
            "healthy": (True, "available", 200),
            "disabled": (False, "upstream-auth-disabled", 200),
            "timeout": (False, "upstream-auth-timeout", None),
            "invalid": (False, "upstream-auth-invalid-response", 200),
        }
        if fixture in fixture_map:
            available, category, http_status = fixture_map[fixture]
            result = {"available": available, "class": category, "httpStatus": http_status, "provider": "workos-authkit", "checkedAt": now_iso(), "secretsRedacted": True}
            self._record_bonsai_auth_probe(result)
            return result
        request = urllib.request.Request(
            BONSAI_WORKOS_DEVICE_URL,
            data=json.dumps({"client_id": BONSAI_WORKOS_CLIENT_ID, "scope": "openid email profile"}).encode(),
            headers={"Content-Type": "application/json", "User-Agent": "phasezero-bonsai-auth-probe/1"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=8) as response:
                http_status = response.status
                payload = json.loads(response.read(256 * 1024))
            verification = str(payload.get("verification_uri_complete") or "") if isinstance(payload, dict) else ""
            parsed = urllib.parse.urlparse(verification)
            if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".authkit.app"):
                result = {"available": False, "class": "upstream-auth-invalid-response", "httpStatus": http_status, "provider": "workos-authkit", "checkedAt": now_iso(), "secretsRedacted": True}
            else:
                page_request = urllib.request.Request(verification, headers={"User-Agent": "phasezero-bonsai-auth-probe/1"})
                with urllib.request.urlopen(page_request, timeout=8) as page:
                    body = page.read(256 * 1024).decode("utf-8", errors="replace").lower()
                    page_status = page.status
                disabled = "authentication is disabled for this application" in body
                result = {
                    "available": not disabled and page_status < 500,
                    "class": "upstream-auth-disabled" if disabled else "available" if page_status < 500 else "upstream-auth-http",
                    "httpStatus": page_status,
                    "provider": "workos-authkit",
                    "checkedAt": now_iso(),
                    "secretsRedacted": True,
                }
        except urllib.error.HTTPError as exc:
            result = {"available": False, "class": "upstream-auth-http", "httpStatus": exc.code, "provider": "workos-authkit", "checkedAt": now_iso(), "secretsRedacted": True}
        except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            result = {"available": False, "class": "upstream-auth-unreachable", "httpStatus": None, "provider": "workos-authkit", "checkedAt": now_iso(), "secretsRedacted": True}
        self._record_bonsai_auth_probe(result)
        return result

    def _record_bonsai_auth_probe(self, result: dict[str, Any]) -> None:
        self.data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.data_root, 0o700)
        atomic_json(self.bonsai_auth_probe_state, result, 0o600)

    def _cached_bonsai_auth_probe(self) -> dict[str, Any]:
        try:
            value = json.loads(self.bonsai_auth_probe_state.read_text(encoding="utf-8"))
            if isinstance(value, dict) and value.get("secretsRedacted") is True:
                return value
        except (OSError, json.JSONDecodeError):
            pass
        return {"available": None, "class": "not-probed", "httpStatus": None, "provider": "workos-authkit", "checkedAt": None, "secretsRedacted": True}

    def _record_preflight(self, result: dict[str, Any]) -> None:
        self.data_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.data_root, 0o700)
        event = {
            "at": now_iso(),
            "route": result.get("route"),
            "ok": bool(result.get("ok")),
            "networkClass": result.get("network", {}).get("class"),
            "durationMs": result.get("network", {}).get("durationMs"),
            "exitCode": 0 if result.get("ok") else 69,
            "secretsRedacted": True,
        }
        with self.preflight_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")
        os.chmod(self.preflight_log, 0o600)

    def settings_files(self) -> list[Path]:
        result = [self.claude_settings]
        project_dir = Path.cwd() / ".claude"
        if project_dir.is_dir():
            result.extend(sorted(project_dir.glob("settings*.json")))
        unique: list[Path] = []
        for path in result:
            if path.exists() and path not in unique:
                unique.append(path)
        return unique

    def claude_info(self) -> dict[str, Any]:
        path = command_path("claude")
        version = ""
        auth: dict[str, Any] = {"loggedIn": False, "authMethod": None, "apiProvider": None}
        if path:
            rc, out, _ = run_capture([path, "--version"], timeout=8)
            if rc == 0:
                version = out.strip().splitlines()[0] if out.strip() else ""
            raw = json_capture([path, "auth", "status", "--json"], timeout=12)
            if raw:
                auth = {
                    "loggedIn": bool(raw.get("loggedIn")),
                    "authMethod": raw.get("authMethod"),
                    "apiProvider": raw.get("apiProvider"),
                }
        return {
            "installed": bool(path),
            "path": path,
            "realPath": str(Path(path).resolve()) if path else None,
            "version": version,
            "auth": auth,
        }

    def bonsai_credential_status(self) -> dict[str, Any]:
        if not self.bonsai_config.is_file():
            return {"authenticated": None, "state": "missing", "refreshPresent": False, "apiKeyPresent": False, "secretsRedacted": True}
        node = os.environ.get("PZ_BONSAI_NODE_BIN") or str(self.data_root / "runtime/node-lts/bin/node")
        if not Path(node).is_file():
            return {"authenticated": False, "state": "runtime-unavailable", "refreshPresent": None, "apiKeyPresent": None, "secretsRedacted": True}
        script = r'''
const fs=require("node:fs"), crypto=require("node:crypto");
try {
  const raw=fs.readFileSync(process.argv[1]);
  const iv=raw.subarray(0,16);
  if (raw[16]!==58) throw new Error("invalid-store");
  const encryptionKey=crypto.scryptSync("bonsai-cli","salt",32).toString("hex").slice(0,32);
  const key=crypto.pbkdf2Sync(encryptionKey,iv.toString(),10000,32,"sha512");
  const decipher=crypto.createDecipheriv("aes-256-cbc",key,iv);
  const value=JSON.parse(Buffer.concat([decipher.update(raw.subarray(17)),decipher.final()]).toString("utf8"));
  const access=typeof value.accessToken==="string"&&value.accessToken.length>0;
  const refresh=typeof value.refreshToken==="string"&&value.refreshToken.length>0;
  const unexpired=access&&typeof value.expiresAt==="number"&&Date.now()<value.expiresAt;
  console.log(JSON.stringify({authenticated:unexpired,state:unexpired?"valid-local-token":refresh?"expired-refresh-required":"expired-no-refresh",refreshPresent:refresh,apiKeyPresent:typeof value.apiKey==="string"&&value.apiKey.length>0,secretsRedacted:true}));
} catch (_) { console.log(JSON.stringify({authenticated:false,state:"invalid-store",refreshPresent:null,apiKeyPresent:null,secretsRedacted:true})); }
'''
        rc, out, _ = run_capture([node, "-e", script, str(self.bonsai_config)], timeout=8)
        if rc == 0:
            try:
                value = json.loads(out)
                if isinstance(value, dict) and value.get("secretsRedacted") is True:
                    return value
            except json.JSONDecodeError:
                pass
        return {"authenticated": False, "state": "probe-failed", "refreshPresent": None, "apiKeyPresent": None, "secretsRedacted": True}

    def bonsai_info(self) -> dict[str, Any]:
        path = command_path("bonsai")
        version = ""
        probe_exit = None
        if path:
            rc, out, _ = run_capture([path, "--version"], timeout=8)
            probe_exit = rc
            if rc == 0:
                version = out.strip().splitlines()[0] if out.strip() else ""
        store_dir = self.bonsai_config.parent
        runner_path = self.data_root / "tools/bonsai-runner/bonsai-managed"
        store_present = self.bonsai_config.is_file() and self.bonsai_config.stat().st_size > 0
        credential_status = self.bonsai_credential_status()
        artifact = self._bonsai_artifact_status()
        auth_provider = self._cached_bonsai_auth_probe()
        directory_mode = stat.S_IMODE(store_dir.stat().st_mode) if store_dir.is_dir() else None
        insecure_files = 0
        if store_dir.is_dir():
            for item in store_dir.rglob("*"):
                if item.is_file() and not item.is_symlink() and stat.S_IMODE(item.stat().st_mode) != 0o600:
                    insecure_files += 1
        runner_ready = bool(path and runner_path.is_file() and probe_exit == 0 and version == BONSAI_VERSION)
        credential_store_secure = bool(directory_mode == 0o700 and insecure_files == 0)
        readiness_blockers: list[str] = []
        if not runner_ready:
            readiness_blockers.append("runner-unavailable")
        if not artifact["validated"]:
            readiness_blockers.append("artifact-unvalidated")
        if not credential_status["authenticated"]:
            readiness_blockers.append("bonsai-auth-invalid")
        if not credential_store_secure:
            readiness_blockers.append("credential-store-permissions")
        if auth_provider["class"] == "upstream-auth-disabled" and not credential_status["authenticated"]:
            readiness_blockers.append("upstream-auth-disabled")
        return {
            "installed": bool(path),
            "path": path,
            "version": version,
            "ready": not readiness_blockers,
            "runtimeReady": runner_ready,
            "readinessBlockers": readiness_blockers,
            "credentialStorePresent": store_present,
            "authenticated": credential_status["authenticated"],
            "credentialStatus": credential_status,
            "snapshotConsent": "interactive-upstream",
            "runtime": {
                "node": os.environ.get("PZ_BONSAI_NODE_BIN") or str(self.data_root / "runtime/node-lts/bin/node"),
                "updateCheck": "fail-open",
            },
            "runner": {
                "path": str(runner_path),
                "present": runner_path.is_file(),
                "probeExitCode": probe_exit,
                "ready": runner_ready,
            },
            "artifact": artifact,
            "authProvider": auth_provider,
            "credentialStorePermissions": {
                "directoryMode": f"{directory_mode:04o}" if directory_mode is not None else None,
                "insecureFiles": insecure_files,
                "secure": credential_store_secure,
            },
        }

    def _bonsai_artifact_status(self) -> dict[str, Any]:
        operations = self.data_root / "operations"
        if operations.is_dir():
            for manifest_path in sorted(operations.glob("*/manifest.json"), key=lambda item: item.stat().st_mtime_ns, reverse=True):
                try:
                    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                for package in reversed(manifest.get("packages", [])):
                    if isinstance(package, dict) and package.get("name") == "@bonsai-ai/cli":
                        return {
                            "source": package.get("source") or package.get("method"),
                            "version": package.get("version"),
                            "integrity": package.get("integrity"),
                            "validated": True,
                        }
        existing = self._bonsai_upstream()
        accepted = self._validated_existing_bonsai(existing) if existing else None
        if accepted:
            return {
                "source": accepted["source"],
                "version": accepted["version"],
                "integrity": BONSAI_INTEGRITIES.get(accepted["version"]),
                "validated": True,
            }
        return {"source": None, "version": None, "integrity": None, "validated": False}

    def node_info(self) -> dict[str, Any]:
        node = command_path("node")
        npm = command_path("npm")
        version = ""
        major = 0
        if node:
            rc, out, _ = run_capture([node, "--version"], timeout=5)
            if rc == 0:
                version = out.strip()
                match = re.match(r"v?(\d+)", version)
                major = int(match.group(1)) if match else 0
        return {
            "node": node,
            "npm": npm,
            "version": version,
            "major": major,
            "managers": {name: bool(command_path(name)) for name in ("nvm", "fnm", "volta")},
        }

    def settings_audit(self) -> dict[str, Any]:
        env_hits: list[dict[str, Any]] = []
        hook_hits: list[dict[str, Any]] = []
        invalid: list[str] = []
        for path in self.settings_files():
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                invalid.append(str(path))
                continue
            env = value.get("env", {}) if isinstance(value, dict) else {}
            if isinstance(env, dict):
                for key in sorted((ROUTE_KEYS | DEFAULT_MODEL_KEYS).intersection(env)):
                    if key in DEFAULT_MODEL_KEYS and str(env.get(key, "")).startswith("claude-"):
                        continue
                    env_hits.append({"path": str(path), "key": key})
            hooks = value.get("hooks", {}) if isinstance(value, dict) else {}
            if isinstance(hooks, dict):
                for event, node in hooks.items():
                    for command in self._hook_commands(node):
                        state, executable = self._command_state(command)
                        hook_hits.append(
                            {"path": str(path), "event": event, "state": state, "executable": executable}
                        )
        profile_hits: list[dict[str, Any]] = []
        pattern = re.compile(r"\bANTHROPIC_(?:API_KEY|AUTH_TOKEN|BASE_URL|MODEL)\b")
        for path in self.profiles():
            for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
                if pattern.search(line) and "[cc-installer:quarantine]" not in line:
                    keys = sorted(set(re.findall(r"ANTHROPIC_[A-Z0-9_]+", line)))
                    profile_hits.append({"path": str(path), "line": line_no, "keys": keys})
        return {"env": env_hits, "profiles": profile_hits, "hooks": hook_hits, "invalidJson": invalid}

    @staticmethod
    def _hook_commands(node: Any) -> Iterable[str]:
        if isinstance(node, dict):
            command = node.get("command")
            if isinstance(command, str):
                yield command
            for value in node.values():
                yield from Manager._hook_commands(value)
        elif isinstance(node, list):
            for value in node:
                yield from Manager._hook_commands(value)

    @staticmethod
    def _command_state(command: str) -> tuple[str, str | None]:
        try:
            parts = shlex.split(command)
        except ValueError:
            return "opaque", None
        while parts and ("=" in parts[0] and not parts[0].startswith(("/", "./", "../"))):
            parts.pop(0)
        if not parts:
            return "opaque", None
        executable = parts[0]
        if executable == "env":
            parts.pop(0)
            while parts and (parts[0].startswith("-") or "=" in parts[0]):
                parts.pop(0)
            if not parts:
                return "opaque", None
            executable = parts[0]
        if executable in KNOWN_SHELL_BUILTINS:
            return "opaque", executable
        resolved = shutil.which(executable) if "/" not in executable else str(Path(executable).expanduser())
        if not resolved or not Path(resolved).exists():
            return ("orphan" if "/" in executable else "missing-command"), executable
        if Path(executable).name in {"bash", "sh", "python", "python3", "node"} and len(parts) > 1:
            script = parts[1]
            if script.startswith(("/", "~/", "./", "../")) and not Path(script).expanduser().exists():
                return "orphan", script
        return "present", resolved

    def listener_info(self, port: int = 20128) -> dict[str, Any]:
        ss = command_path("ss")
        output = ""
        if ss:
            _, output, _ = run_capture([ss, "-H", "-ltnp", f"sport = :{port}"], timeout=5)
        pid_match = re.search(r"pid=(\d+)", output)
        local_match = re.search(r"LISTEN\s+\d+\s+\d+\s+(\S+):(\d+)", output)
        pid = int(pid_match.group(1)) if pid_match else None
        address = local_match.group(1).strip("[]") if local_match else None
        command = None
        if pid:
            try:
                command = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            except OSError:
                command = None
        return {"port": port, "listening": bool(output.strip()), "address": address, "pid": pid, "command": command}

    @staticmethod
    def url_healthy(url: str) -> bool:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                return 200 <= response.status < 500
        except (OSError, urllib.error.URLError):
            return False

    def router_status(self) -> dict[str, Any]:
        managed_package = Path(
            os.environ.get(
                "PZ_9ROUTER_PACKAGE_BIN",
                self.home / ".local/share/phasezero/ai-proxies/9router/bin/9router",
            )
        )
        legacy_package = self.home / ".npm-global/lib/node_modules/9router"
        legacy_unit = self.xdg_config / "systemd/user/9router.service"
        legacy_autostart = self.xdg_config / "autostart/9router.desktop"
        listener = self.listener_info()
        health = self.url_healthy("http://127.0.0.1:20128/api/health")
        command = listener.get("command") or ""
        managed_owner = str(managed_package.parent.parent) in command or "phasezero" in command
        systemctl = command_path("systemctl")
        legacy_unit_enabled = False
        managed_main_pid = 0
        if systemctl:
            legacy_unit_enabled = run_capture(
                [systemctl, "--user", "is-enabled", "--quiet", "9router.service"], timeout=5
            )[0] == 0
            rc, out, _ = run_capture(
                [systemctl, "--user", "show", "phasezero-9router.service", "-p", "MainPID", "--value"], timeout=5
            )
            if rc == 0 and out.strip().isdigit():
                managed_main_pid = int(out.strip())
        listener_pid = listener.get("pid")
        if listener_pid and managed_main_pid and self._pid_descends_from(int(listener_pid), managed_main_pid):
            managed_owner = True
        legacy_owner = str(legacy_package) in command or "next-server" in command
        legacy_autostart_enabled = False
        if legacy_autostart.is_file():
            raw = legacy_autostart.read_text(encoding="utf-8", errors="replace")
            hidden = bool(re.search(r"(?mi)^Hidden\s*=\s*true\s*$", raw))
            disabled = bool(re.search(r"(?mi)^X-GNOME-Autostart-enabled\s*=\s*false\s*$", raw))
            legacy_autostart_enabled = not hidden and not disabled
        return {
            "managedInstalled": managed_package.exists(),
            "legacyInstalled": legacy_package.exists(),
            "legacyUnit": legacy_unit.exists(),
            "legacyAutostart": legacy_autostart.exists(),
            "legacyUnitEnabled": legacy_unit_enabled,
            "legacyAutostartEnabled": legacy_autostart_enabled,
            "legacyStartupConflict": legacy_unit_enabled or legacy_autostart_enabled,
            "listener": {key: value for key, value in listener.items() if key != "command"},
            "owner": "managed" if managed_owner else "legacy" if legacy_owner else "unknown" if listener["listening"] else None,
            "healthy": bool(health and listener["listening"] and (managed_owner or legacy_owner)),
            "loopbackOnly": listener.get("address") in {"127.0.0.1", "::1"},
        }

    @staticmethod
    def _pid_descends_from(pid: int, ancestor: int) -> bool:
        for _ in range(32):
            if pid == ancestor:
                return True
            if pid <= 1:
                return False
            try:
                raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
                closing = raw.rfind(")")
                fields = raw[closing + 2 :].split()
                pid = int(fields[1])
            except (OSError, ValueError, IndexError):
                return False
        return False

    def infer_auth(self, requested: str | None) -> str | None:
        if requested:
            return requested
        claude = self.claude_info()
        if claude["auth"]["loggedIn"] and claude["auth"]["apiProvider"] == "firstParty":
            return "subscription"
        bonsai = self.bonsai_info()
        if bonsai["ready"]:
            return "bonsai"
        if self.router_status()["healthy"]:
            return "proxy"
        return None

    def status(self, requested: str | None = None) -> dict[str, Any]:
        settings = self.settings_audit()
        route = self.infer_auth(requested)
        claude = self.claude_info()
        bonsai = self.bonsai_info()
        conflicts: list[dict[str, Any]] = []
        if settings["env"] or settings["profiles"]:
            conflicts.append({"id": "C1-C2", "kind": "anthropic-environment", "count": len(settings["env"]) + len(settings["profiles"])})
        orphan_count = sum(1 for item in settings["hooks"] if item["state"] == "orphan")
        if orphan_count:
            conflicts.append({"id": "C4", "kind": "orphan-hooks", "count": orphan_count})
        router = self.router_status()
        if router["legacyStartupConflict"]:
            conflicts.append({"id": "C3", "kind": "duplicate-9router-startup", "count": 2})
        if router["listener"]["listening"] and router["owner"] == "unknown":
            conflicts.append({"id": "C6", "kind": "unknown-port-owner", "port": 20128})
        next_actions: list[str] = []
        if route is None:
            next_actions.append("claude /login or bonsai login")
        if bonsai["credentialStorePresent"] and not bonsai["authenticated"]:
            if bonsai["authProvider"]["class"] == "upstream-auth-disabled":
                next_actions.append("Bonsai login unavailable upstream; use explicit BONSAI_ROUTE=9router fallback")
            else:
                next_actions.append("bonsai login")
        if conflicts:
            next_actions.append("linux/pz ai claude install --dry-run")
        return {
            "schemaVersion": SCHEMA_VERSION,
            "selectedAuth": route,
            "platform": {
                "os": platform.system().lower(),
                "architecture": platform.machine(),
                "libc": platform.libc_ver()[0] or "unknown",
                "shell": os.environ.get("SHELL"),
            },
            "claude": claude,
            "bonsai": bonsai,
            "installations": {
                "claude": {key: claude[key] for key in ("installed", "path", "realPath", "version")},
                "bonsai": {key: bonsai[key] for key in ("installed", "path", "version")},
            },
            "authentications": {
                "subscription": claude["auth"],
                "bonsai": {
                    "authenticated": bonsai["authenticated"],
                    "credentialStorePresent": bonsai["credentialStorePresent"],
                },
            },
            "routeCapabilities": {
                "subscription": {
                    "ready": bool(claude["auth"]["loggedIn"] and claude["auth"]["apiProvider"] == "firstParty"),
                    "authentication": "claude.ai-oauth",
                    "claudeAiConnectors": True,
                },
                "bonsai": {
                    "ready": bonsai["ready"],
                    "authentication": "external-bearer-injected-by-bonsai",
                    "claudeAiConnectors": False,
                    "connectorsWarningExpected": False,
                    "upstreamDirectCommandMayWarn": True,
                    "phaseZeroLauncherSuppressesWarning": True,
                    "reason": "Claude.ai connectors require Claude.ai subscription authentication and are unavailable through external gateways",
                },
                "proxy": {
                    "ready": bool(router["healthy"] and router["loopbackOnly"]),
                    "authentication": "external-bearer-injected-by-phasezero",
                    "claudeAiConnectors": False,
                    "connectorsWarningExpected": True,
                },
            },
            "node": self.node_info(),
            "proxies": {"9router": router},
            "ports": {"9router": router["listener"]},
            "configuration": settings,
            "hooks": settings["hooks"],
            "conflicts": conflicts,
            "nextActions": next_actions,
            "recommendedActions": next_actions,
            "secretsRedacted": True,
        }

    def planned_actions(self, selected: str) -> list[dict[str, Any]]:
        state = self.status(selected)
        actions: list[dict[str, Any]] = []
        if not state["claude"]["installed"]:
            actions.append({"action": "install-claude-native", "reason": "missing"})
        if not state["bonsai"]["installed"]:
            actions.append({"action": "install-bonsai-user-local", "reason": "missing"})
        if state["bonsai"]["credentialStorePresent"] and not state["bonsai"]["credentialStorePermissions"]["secure"]:
            actions.append({"action": "secure-bonsai-credential-store", "reason": "permissions"})
        if state["configuration"]["env"] or state["configuration"]["profiles"]:
            actions.append({"action": "quarantine-global-anthropic-routing", "reason": "subscription-default"})
        if any(item["state"] == "orphan" for item in state["configuration"]["hooks"]):
            actions.append({"action": "remove-proven-orphan-hooks", "reason": "missing executable"})
        router = state["proxies"]["9router"]
        if router["legacyStartupConflict"]:
            actions.append({"action": "migrate-legacy-9router", "reason": "duplicate startup"})
        actions.append({"action": "write-isolated-launchers", "reason": "per-process authentication"})
        actions.append({"action": "prefer-user-local-shims", "reason": "intercept bonsai start without replacing upstream"})
        actions.append({"action": "verify", "reason": "transaction healthcheck"})
        return actions

    def _ensure_claude(self, tx: Transaction) -> str:
        existing = command_path("claude")
        if existing:
            return existing
        curl = command_path("curl")
        if not curl:
            raise RuntimeError("Claude missing and curl unavailable")
        launcher = self.home / ".local/bin/claude"
        versions = self.home / ".local/share/claude"
        tx.backup(launcher)
        tx.backup(versions)
        with tempfile.TemporaryDirectory(prefix="pz-claude-install-") as raw:
            script = Path(raw) / "install.sh"
            rc, _, err = run_capture([curl, "-fsSL", "https://claude.ai/install.sh", "-o", str(script)], timeout=60)
            if rc != 0:
                raise RuntimeError(f"Claude installer download failed: {err.strip()}")
            proc = subprocess.run(["bash", str(script)], check=False, timeout=300)
            if proc.returncode != 0:
                raise RuntimeError("Claude native installer failed")
        installed = command_path("claude") or str(launcher) if launcher.exists() else None
        if not installed:
            raise RuntimeError("Claude installer completed without launcher")
        tx.manifest["packages"].append({"name": "claude-code", "method": "native", "source": "claude.ai"})
        tx.save()
        return installed

    def _download_node_runtime(self, tx: Transaction) -> tuple[str, str]:
        runtime = self.data_root / "runtime/node-lts"
        existing_node = runtime / "bin/node"
        existing_npm = runtime / "bin/npm"
        if existing_node.is_file() and existing_npm.is_file():
            rc, out, _ = run_capture([str(existing_node), "--version"], timeout=5)
            if rc == 0 and re.match(r"^v?24(?:\.|$)", out.strip()):
                tx.manifest["packages"].append({"name": "node", "version": out.strip(), "method": "reused-verified-runtime", "path": str(existing_node)})
                tx.save()
                return str(existing_node), str(existing_npm)
        libc = platform.libc_ver()[0].lower()
        machine = platform.machine().lower()
        arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
        if arch is None or libc not in {"glibc", "gnu libc", "libc"}:
            raise RuntimeError("Node/npm missing; automatic isolated runtime supports glibc x64/arm64 only")
        with urllib.request.urlopen("https://nodejs.org/dist/index.json", timeout=20) as response:
            releases = json.load(response)
        release = next((item for item in releases if item.get("lts") and int(item["version"].lstrip("v").split(".")[0]) == 24), None)
        if not release:
            raise RuntimeError("no supported Node LTS release found")
        version = release["version"]
        filename = f"node-{version}-linux-{arch}.tar.xz"
        base = f"https://nodejs.org/dist/{version}"
        with urllib.request.urlopen(f"{base}/SHASUMS256.txt", timeout=20) as response:
            sums = response.read().decode()
        expected = next((line.split()[0] for line in sums.splitlines() if line.endswith(f"  {filename}")), None)
        if not expected:
            raise RuntimeError("Node checksum unavailable")
        tx.backup(runtime)
        with tempfile.TemporaryDirectory(prefix="pz-node-") as raw:
            archive = Path(raw) / filename
            with urllib.request.urlopen(f"{base}/{filename}", timeout=120) as response, archive.open("wb") as handle:
                shutil.copyfileobj(response, handle)
            if file_sha256(archive) != expected:
                raise RuntimeError("Node runtime checksum mismatch")
            stage = Path(raw) / "stage"
            stage.mkdir()
            with tarfile.open(archive, "r:xz") as bundle:
                bundle.extractall(stage, filter="data")
            extracted = next(stage.iterdir())
            remove_path(runtime)
            runtime.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(extracted), runtime)
        tx.manifest["packages"].append({"name": "node", "version": version, "sha256": expected, "method": "verified-user-runtime"})
        tx.save()
        return str(runtime / "bin/node"), str(runtime / "bin/npm")

    def _bonsai_upstream(self) -> str | None:
        shim = (self.local_bin / "bonsai").absolute()
        candidates: list[str] = []
        for key in ("PZ_BONSAI_UPSTREAM_COMMAND", "PZ_BONSAI_COMMAND"):
            value = os.environ.get(key)
            if value:
                resolved = value if Path(value).exists() else shutil.which(value)
                if resolved:
                    candidates.append(resolved)
        path_env = os.environ.get("PATH", "")
        filtered_path = os.pathsep.join(
            part for part in path_env.split(os.pathsep) if Path(part or ".").absolute() != self.local_bin.absolute()
        )
        resolved = shutil.which("bonsai", path=filtered_path)
        if resolved:
            candidates.append(resolved)
        candidates.extend(
            str(path)
            for path in (
                self.home / ".npm-global/bin/bonsai",
                self.home / ".local/share/npm/bin/bonsai",
                self.data_root / "tools/bonsai/bin/bonsai-phasezero",
            )
        )
        for candidate in candidates:
            path = Path(candidate).expanduser().absolute()
            if not path.is_file() or not os.access(path, os.X_OK):
                continue
            if path == shim:
                continue
            try:
                if path.resolve() == shim.resolve():
                    continue
            except OSError:
                pass
            return str(path)
        return None

    def _validated_existing_bonsai(self, command: str) -> dict[str, str] | None:
        path = Path(command).expanduser().resolve()
        if path.name == "bonsai-phasezero":
            candidate = path.parent.parent / "lib/node_modules/@bonsai-ai/cli/dist/cli.js"
            if candidate.is_file():
                path = candidate.resolve()
        if path.name != "cli.js" or path.parent.name != "dist":
            return None
        package_json = path.parent.parent / "package.json"
        if not package_json.is_file():
            return None
        try:
            package = json.loads(package_json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        version = str(package.get("version") or "")
        allowed = BONSAI_EXISTING_HASHES.get(version)
        cli_hash = file_sha256(path)
        package_hash = file_sha256(package_json)
        if package.get("name") != "@bonsai-ai/cli" or not allowed:
            return None
        if cli_hash != allowed["cliSha256"] or package_hash != allowed["packageSha256"]:
            return None
        return {
            "command": str(path),
            "version": version,
            "source": "existing-known-installation",
            "cliSha256": cli_hash,
            "packageSha256": package_hash,
        }

    def _ensure_bonsai(self, tx: Transaction) -> str:
        existing = self._bonsai_upstream()
        if existing:
            accepted = self._validated_existing_bonsai(existing)
            if accepted:
                tx.manifest["packages"].append({"name": "@bonsai-ai/cli", **accepted, "method": "allowlisted-existing"})
                tx.save()
                return self._write_bonsai_runner(tx, accepted["command"])
        node, npm = self._download_node_runtime(tx)
        prefix = self.data_root / "tools/bonsai"
        tx.backup(prefix)
        env = os.environ.copy()
        env["PATH"] = f"{Path(node).parent}:{env.get('PATH', '')}"
        rc, metadata_out, _ = run_capture([npm, "view", "@bonsai-ai/cli", "version", "dist.integrity", "--json"], timeout=30, env=env)
        version, integrity, source = self.select_bonsai_distribution(rc, metadata_out)
        with tempfile.TemporaryDirectory(prefix="pz-bonsai-") as raw:
            pack_args = [npm, "pack", f"@bonsai-ai/cli@{version}"]
            if source == "npm-cache":
                pack_args.append("--offline")
            pack_args.extend(["--pack-destination", raw, "--json"])
            rc, pack_out, err = run_capture(
                pack_args, timeout=90, env=env
            )
            if rc != 0:
                raise RuntimeError("upstream-distribution-unavailable")
            packed = json.loads(pack_out)[0]
            if packed.get("integrity") != integrity:
                raise RuntimeError("Bonsai npm integrity mismatch")
            tarball = Path(raw) / packed["filename"]
            stage = Path(raw) / "install"
            rc, _, err = run_capture(
                [npm, "install", "-g", "--prefix", str(stage), "--ignore-scripts", str(tarball)], timeout=180, env=env
            )
            if rc != 0:
                raise RuntimeError(f"Bonsai staged install failed: {err.strip()}")
            remove_path(prefix)
            prefix.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(stage), prefix)
        cli_js = prefix / "lib/node_modules/@bonsai-ai/cli/dist/cli.js"
        if not cli_js.is_file():
            raise RuntimeError("Bonsai staged CLI missing")
        tx.manifest["packages"].append({"name": "@bonsai-ai/cli", "version": version, "integrity": integrity, "source": source, "method": "verified-npm-stage"})
        tx.save()
        return self._write_bonsai_runner(tx, str(cli_js))

    @staticmethod
    def select_bonsai_distribution(metadata_rc: int, metadata_out: str) -> tuple[str, str, str]:
        try:
            metadata = json.loads(metadata_out) if metadata_rc == 0 else {}
        except json.JSONDecodeError:
            metadata = {}
        version = metadata.get("version") if isinstance(metadata, dict) else None
        integrity = (metadata.get("dist.integrity") or metadata.get("dist", {}).get("integrity")) if isinstance(metadata, dict) else None
        if version == BONSAI_VERSION and integrity == BONSAI_INTEGRITIES[BONSAI_VERSION]:
            return version, integrity, "registry"
        return BONSAI_VERSION, BONSAI_INTEGRITIES[BONSAI_VERSION], "npm-cache"

    def _write_bonsai_runner(self, tx: Transaction, upstream: str) -> str:
        """Run every upstream command under isolated Node 24 plus narrow update shim."""
        node = os.environ.get("PZ_BONSAI_NODE_BIN")
        if not node or not Path(node).is_file():
            node, _ = self._download_node_runtime(tx)
        root = self.data_root / "tools/bonsai-runner"
        loader = root / "latest-fail-open.cjs"
        runner = root / "bonsai-managed"
        # Only this optional npm metadata endpoint is synthesized.  Authentication,
        # Bonsai API and router requests retain the original network transport.
        loader_text = r'''"use strict";
function target(input) { try { const u = new URL(input instanceof Request ? input.url : String(input)); return u.hostname === "registry.npmjs.org" && decodeURIComponent(u.pathname) === "/@bonsai-ai/cli/latest"; } catch (_) { return false; } }
function validVersion(value) { return typeof value === "string" && /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(value); }
function fallback(reason) { process.env.PZ_BONSAI_UPDATE_CHECK_RESULT = reason; return new Response(JSON.stringify({version:process.env.PZ_BONSAI_INSTALLED_VERSION || "0.4.19"}), {status:200, headers:{"content-type":"application/json","x-phasezero-update-check":"fail-open"}}); }
const originalFetch = globalThis.fetch;
if (typeof originalFetch === "function") {
  globalThis.fetch = async function(input, init) {
    if (!target(input)) return originalFetch.apply(this, arguments);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), Number(process.env.PZ_BONSAI_UPDATE_TIMEOUT_MS || 4000));
    try {
      const response = await originalFetch(input, {...(init || {}), signal:controller.signal});
      if (!response.ok) return fallback(`http-${response.status}`);
      const payload = await response.clone().json();
      if (!payload || !validVersion(payload.version)) return fallback("invalid-version");
      process.env.PZ_BONSAI_UPDATE_CHECK_RESULT = "valid";
      return response;
    } catch (_) { return fallback(controller.signal.aborted ? "timeout" : "network-error"); }
    finally { clearTimeout(timer); }
  };
}
'''
        runner_text = "#!/usr/bin/env bash\nset -euo pipefail\nexport PZ_BONSAI_INSTALLED_VERSION=" + shlex.quote(BONSAI_VERSION) + "\nexec " + shlex.quote(node) + " --require " + shlex.quote(str(loader)) + " " + shlex.quote(str(Path(upstream).resolve())) + " \"$@\"\n"
        desired = ((loader, loader_text, 0o600), (runner, runner_text, 0o700))
        changed = any(
            not path.is_file()
            or path.read_text(encoding="utf-8", errors="replace") != content
            or stat.S_IMODE(path.stat().st_mode) != mode
            for path, content, mode in desired
        )
        if changed:
            tx.backup(root)
            for path, content, mode in desired:
                if not path.is_file() or path.read_text(encoding="utf-8", errors="replace") != content or stat.S_IMODE(path.stat().st_mode) != mode:
                    atomic_text(path, content, mode)
        tx.manifest["packages"].append({"name": "bonsai-runner", "node": node, "updateCheck": "fail-open", "workaround": "registry-latest-only-valid-response-passthrough"})
        tx.save()
        return str(runner)

    def _secure_bonsai_store(self, tx: Transaction) -> int:
        store_dir = self.bonsai_config.parent
        if not store_dir.is_dir():
            return 0
        targets: list[tuple[Path, int]] = [(store_dir, 0o700)]
        for item in store_dir.rglob("*"):
            if item.is_symlink():
                continue
            if item.is_dir():
                targets.append((item, 0o700))
            elif item.is_file():
                targets.append((item, 0o600))
        changed = [(path, mode) for path, mode in targets if stat.S_IMODE(path.stat().st_mode) != mode]
        if not changed:
            return 0
        tx.backup(store_dir)
        for path, mode in changed:
            os.chmod(path, mode)
        return len(changed)

    @staticmethod
    def _prune_orphans(node: Any) -> tuple[Any, int]:
        removed = 0
        if isinstance(node, list):
            result = []
            for value in node:
                new_value, count = Manager._prune_orphans(value)
                removed += count
                if new_value not in (None, [], {}):
                    result.append(new_value)
            return result, removed
        if isinstance(node, dict):
            command = node.get("command")
            if isinstance(command, str) and Manager._command_state(command)[0] == "orphan":
                return None, 1
            result = {}
            for key, value in node.items():
                new_value, count = Manager._prune_orphans(value)
                removed += count
                if new_value not in (None, [], {}):
                    result[key] = new_value
            if isinstance(node.get("hooks"), list) and "hooks" not in result:
                return None, removed or 1
            return result, removed
        return node, 0

    @staticmethod
    def _prune_hook_config(node: Any) -> tuple[Any, int]:
        if not isinstance(node, dict):
            return node, 0
        result: dict[str, Any] = {}
        removed = 0
        for event, groups in node.items():
            if not isinstance(groups, list):
                result[event] = groups
                continue
            valid_groups: list[Any] = []
            for group in groups:
                if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                    removed += 1
                    continue
                valid_hooks: list[Any] = []
                for hook in group["hooks"]:
                    pruned, count = Manager._prune_orphans(hook)
                    removed += count
                    if pruned not in (None, [], {}):
                        valid_hooks.append(pruned)
                if valid_hooks:
                    repaired_group = dict(group)
                    repaired_group["hooks"] = valid_hooks
                    valid_groups.append(repaired_group)
                elif not group["hooks"]:
                    removed += 1
            if valid_groups:
                result[event] = valid_groups
        return result, removed

    def _repair_settings(self, tx: Transaction, subscription_default: bool) -> dict[str, int]:
        removed_env = removed_hooks = 0
        for path in self.settings_files():
            raw = path.read_text(encoding="utf-8")
            try:
                value = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise RuntimeError(f"invalid Claude settings JSON: {path}: {exc}") from exc
            changed = False
            if subscription_default and isinstance(value, dict) and isinstance(value.get("env"), dict):
                env = value["env"]
                for key in list(env):
                    remove = key in ROUTE_KEYS
                    if key in DEFAULT_MODEL_KEYS:
                        candidate = str(env.get(key, ""))
                        remove = bool(candidate and not candidate.startswith("claude-"))
                    if remove:
                        del env[key]
                        removed_env += 1
                        changed = True
                if not env:
                    value.pop("env", None)
            if isinstance(value, dict) and "hooks" in value:
                hooks, count = self._prune_hook_config(value["hooks"])
                if count:
                    removed_hooks += count
                    changed = True
                    if hooks:
                        value["hooks"] = hooks
                    else:
                        value.pop("hooks", None)
            if changed:
                tx.backup(path)
                mode = stat.S_IMODE(path.stat().st_mode)
                atomic_json(path, value, mode)
        return {"environmentKeys": removed_env, "hooks": removed_hooks}

    def _quarantine_profiles(self, tx: Transaction) -> int:
        pattern = re.compile(r"\bANTHROPIC_(?:API_KEY|AUTH_TOKEN|BASE_URL|MODEL)\b")
        changed_count = 0
        for path in self.profiles():
            raw = path.read_text(encoding="utf-8", errors="replace")
            lines = raw.splitlines(keepends=True)
            changed = False
            output: list[str] = []
            for line in lines:
                if pattern.search(line) and "[cc-installer:quarantine]" not in line and not line.lstrip().startswith("#"):
                    newline = "\n" if line.endswith("\n") else ""
                    content = line[:-1] if newline else line
                    output.append(f"# [cc-installer:quarantine] {content}{newline}")
                    changed = True
                    changed_count += 1
                else:
                    output.append(line)
            if changed:
                tx.backup(path)
                atomic_text(path, "".join(output), stat.S_IMODE(path.stat().st_mode))
        return changed_count

    def _ensure_shim_path_precedence(self, tx: Transaction) -> int:
        """Keep PhaseZero shim before npm-global without replacing upstream Bonsai."""
        changed_count = 0
        block_pattern = re.compile(
            rf"(?ms)^\s*{re.escape(SHIM_PATH_BLOCK_START)}\n.*?^\s*{re.escape(SHIM_PATH_BLOCK_END)}\n?"
        )
        for path in self.profiles():
            raw = path.read_text(encoding="utf-8", errors="replace")
            base = block_pattern.sub("", raw).rstrip("\n")
            if path.name == "config.fish":
                command = 'fish_add_path --prepend --move "$HOME/.local/bin"'
            else:
                command = 'export PATH="$HOME/.local/bin:$PATH"'
            block = f"{SHIM_PATH_BLOCK_START}\n{command}\n{SHIM_PATH_BLOCK_END}\n"
            desired = f"{base}\n\n{block}" if base else block
            if desired == raw:
                continue
            tx.backup(path)
            atomic_text(path, desired, stat.S_IMODE(path.stat().st_mode))
            changed_count += 1
        return changed_count

    def _write_launchers(self, tx: Transaction, claude: str, bonsai: str) -> list[str]:
        self.local_bin.mkdir(parents=True, exist_ok=True)
        claude_real = str(Path(claude).resolve())
        bonsai_real = str(Path(bonsai).resolve())
        manager_dir = self.data_root / "tools/phasezero-claude-manager"
        managed_manager = manager_dir / "claude_code_manager.py"
        manager_content = Path(__file__).read_text(encoding="utf-8")
        manager_current = managed_manager.read_text(encoding="utf-8", errors="replace") if managed_manager.is_file() else None
        manager_mode = stat.S_IMODE(managed_manager.stat().st_mode) if managed_manager.is_file() else None
        if manager_current != manager_content or manager_mode != 0o700:
            if not manager_dir.exists():
                tx.backup(manager_dir)
            else:
                tx.backup(managed_manager)
            manager_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(manager_dir, 0o700)
            atomic_text(managed_manager, manager_content, 0o700)
        manager_command = f"python3 {shlex.quote(str(managed_manager))}"
        desktop_workspace = self._bonsai_desktop_workspace()
        wrappers: dict[str, str] = {
            "claude-subscription": f"""#!/usr/bin/env bash
set -euo pipefail
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
exec {shlex.quote(claude_real)} "$@"
""",
            "claude-9router": f"""#!/usr/bin/env bash
set -euo pipefail
env_file={shlex.quote(str(self.router_env))}
settings_file={shlex.quote(str(self.router_settings))}
[ -r "$env_file" ] || {{ echo "9Router environment missing: $env_file" >&2; exit 1; }}
[ -r "$settings_file" ] || {{ echo "9Router settings missing: $settings_file" >&2; exit 1; }}
token="$(awk -F= '$1=="PHASEZERO_9ROUTER_API_KEY" {{sub(/^[^=]*=/,""); print; exit}}' "$env_file")"
model="$(jq -r '.activeCombo // .model // empty' "$settings_file")"
[ -n "$token" ] || {{ echo "9Router API token missing" >&2; exit 1; }}
[ -n "$model" ] || {{ echo "9Router Claude combo missing" >&2; exit 1; }}
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
export ANTHROPIC_BASE_URL=http://127.0.0.1:20128
export ANTHROPIC_AUTH_TOKEN="$token"
exec {shlex.quote(claude_real)} --model "$model" "$@"
""",
            "claude-bonsai": f"""#!/usr/bin/env bash
set -euo pipefail
allow_sensitive=false
args=()
for arg in "$@"; do
  if [ "$arg" = "--allow-sensitive-upload" ]; then allow_sensitive=true; else args+=("$arg"); fi
done
preflight_command=({manager_command} preflight bonsai --cwd "$PWD")
$allow_sensitive && preflight_command+=(--allow-sensitive-upload)
if ! preflight="$("${{preflight_command[@]}}")"; then
  printf '%s\n' "$preflight" >&2
  exit 69
fi
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
export ENABLE_CLAUDEAI_MCP_SERVERS=false
if [ -t 2 ] && [ "${{PZ_CLAUDE_ROUTE_QUIET:-0}}" != "1" ]; then
  echo "PhaseZero: Bonsai uses external authentication; Claude.ai connectors are unavailable on this route." >&2
  echo "PhaseZero: use claude-subscription when Claude.ai connectors are required." >&2
fi
exec {shlex.quote(bonsai_real)} start "${{args[@]}}"
""",
            "bonsai": f"""#!/usr/bin/env bash
set -euo pipefail
upstream={shlex.quote(bonsai_real)}
manager={shlex.quote(str(managed_manager))}
if [ "${{1:-}}" = "login" ]; then
  shift
  [ "$#" -eq 0 ] || {{ echo "bonsai login: unexpected arguments" >&2; exit 2; }}
  exec python3 "$manager" login bonsai
fi
if [ "${{1:-}}" != "start" ]; then
  exec "$upstream" "$@"
fi
shift
cwd="$PWD"
route="${{BONSAI_ROUTE:-direct}}"
allow_sensitive=false
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cwd)
      [ "$#" -ge 2 ] || {{ echo "bonsai start: --cwd requires a directory" >&2; exit 2; }}
      cwd="$2"; shift 2 ;;
    --cwd=*) cwd="${{1#*=}}"; shift ;;
    --route)
      [ "$#" -ge 2 ] || {{ echo "bonsai start: --route requires direct or 9router" >&2; exit 2; }}
      route="$2"; shift 2 ;;
    --route=*) route="${{1#*=}}"; shift ;;
    --allow-sensitive-upload) allow_sensitive=true; shift ;;
    --) shift; args+=("$@"); break ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$route" in
  direct|bonsai)
    command=(python3 "$manager" run bonsai --cwd "$cwd")
    $allow_sensitive && command+=(--allow-sensitive-upload)
    command+=(-- "${{args[@]}}")
    exec "${{command[@]}}"
    ;;
  9router|proxy)
    echo "PhaseZero: route=9router; Bonsai is not started, no Bonsai snapshot/upload occurs." >&2
    exec python3 "$manager" run proxy --proxy=9router --cwd "$cwd" -- "${{args[@]}}"
    ;;
  *)
    echo "bonsai start: invalid BONSAI_ROUTE/--route '$route' (expected direct or 9router)" >&2
    exit 2
    ;;
esac
""",
            "phasezero-ai-bonsai": f"""#!/usr/bin/env bash
set -euo pipefail
workspace={shlex.quote(str(desktop_workspace))}
[ -d "$workspace" ] || {{ echo "PhaseZero workspace missing: $workspace" >&2; exit 1; }}
export BONSAI_ROUTE="${{PZ_BONSAI_DESKTOP_ROUTE:-9router}}"
exec {shlex.quote(str(self.local_bin / 'bonsai'))} start --cwd "$workspace" -- "$@"
""",
        }
        for name, content in wrappers.items():
            target = self.local_bin / name
            if target.is_file() and target.read_text(encoding="utf-8", errors="replace") == content \
                and stat.S_IMODE(target.stat().st_mode) == 0o700:
                continue
            tx.backup(target)
            atomic_text(target, content, 0o700)
        self._write_bonsai_desktop_entry(tx, desktop_workspace)
        return sorted(wrappers)

    def _bonsai_desktop_workspace(self) -> Path:
        configured = os.environ.get("PZ_BONSAI_DESKTOP_CWD")
        if configured:
            return Path(configured).expanduser().resolve()
        git = command_path("git")
        if git:
            rc, out, _ = run_capture(
                [git, "-C", str(self.repo_root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                timeout=5,
            )
            if rc == 0 and out.strip():
                common_dir = Path(out.strip())
                if not common_dir.is_absolute():
                    common_dir = (self.repo_root / common_dir).resolve()
                if common_dir.name == ".git":
                    return common_dir.parent
        return self.repo_root

    def _write_bonsai_desktop_entry(self, tx: Transaction, workspace: Path) -> None:
        icon_source = self.repo_root / "assets/ai/phasezero-bonsai.png"
        if not icon_source.is_file():
            raise RuntimeError(f"PhaseZero Bonsai icon missing: {icon_source}")
        icon_target = self.xdg_data / "icons/hicolor/512x512/apps/phasezero-bonsai.png"
        icon_data = icon_source.read_bytes()
        if not icon_target.is_file() or icon_target.read_bytes() != icon_data or stat.S_IMODE(icon_target.stat().st_mode) != 0o644:
            tx.backup(icon_target)
            atomic_bytes(icon_target, icon_data, 0o644)

        desktop_target = self.xdg_data / "applications/phasezero-ai-bonsai.desktop"
        launcher = self.local_bin / "phasezero-ai-bonsai"
        content = f"""[Desktop Entry]
Type=Application
Name=PhaseZero AI — Bonsai
Comment=Iniciar Claude Code no PhaseZero pela rota 9Router segura
Exec={launcher}
TryExec={launcher}
Icon=phasezero-bonsai
Terminal=true
Categories=Development;
Keywords=AI;Claude;Bonsai;9Router;PhaseZero;
StartupNotify=true
X-PHZ-Group=ia
X-PhaseZero-Managed=true
X-PhaseZero-MenuGroup=web.ai
X-PhaseZero-Workspace={workspace}
"""
        if not desktop_target.is_file() or desktop_target.read_text(encoding="utf-8", errors="replace") != content or stat.S_IMODE(desktop_target.stat().st_mode) != 0o644:
            tx.backup(desktop_target)
            atomic_text(desktop_target, content, 0o644)

    def _refresh_desktop_menu(self) -> list[dict[str, Any]]:
        results: list[dict[str, Any]] = []
        applications = self.xdg_data / "applications"
        commands = (
            ("update-desktop-database", [str(applications)]),
            ("kbuildsycoca6", ["--noincremental"]),
            ("kbuildsycoca5", ["--noincremental"]),
        )
        for name, args in commands:
            executable = command_path(name)
            if not executable:
                continue
            rc, _, _ = run_capture([executable, *args], timeout=30)
            results.append({"command": name, "exitCode": rc})
        return results

    def _ensure_router_model(self, tx: Transaction) -> str | None:
        if not self.router_settings.is_file():
            return None
        combos = self._router_snapshot().get("combos", [])
        if not combos:
            return None
        try:
            settings = json.loads(self.router_settings.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            settings = {}
        current = settings.get("activeCombo") or settings.get("model")
        if current in combos:
            return str(current)
        selected = next((name for name in combos if "claude" in name.lower()), None)
        selected = selected or ("Default" if "Default" in combos else combos[0])
        tx.backup(self.router_settings)
        settings["model"] = selected
        settings["activeCombo"] = selected
        atomic_json(self.router_settings, settings, 0o600)
        return selected

    def _legacy_process_tree(self) -> tuple[list[int], list[str]]:
        ps = command_path("ps")
        if not ps:
            return [], []
        rc, out, _ = run_capture([ps, "-eo", "pid=,ppid=,args="], timeout=8)
        if rc != 0:
            return [], []
        rows: dict[int, tuple[int, str]] = {}
        for line in out.splitlines():
            match = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)", line)
            if match:
                rows[int(match.group(1))] = (int(match.group(2)), match.group(3))
        roots = [pid for pid, (_, args) in rows.items() if "/node_modules/9router/cli.js" in args and "--tray" in args]
        selected = set(roots)
        listener = self.listener_info()
        listener_pid = listener.get("pid")
        if roots and listener_pid in rows and "next-server" in rows[int(listener_pid)][1]:
            selected.add(int(listener_pid))
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _) in rows.items():
                if ppid in selected and pid not in selected:
                    selected.add(pid)
                    changed = True
        commands = [rows[pid][1] for pid in roots]
        return sorted(selected), commands

    @staticmethod
    def _terminate_known_tree(pids: list[int]) -> None:
        for pid in reversed(pids):
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        deadline = time.time() + 8
        while time.time() < deadline and any(Path(f"/proc/{pid}").exists() for pid in pids):
            time.sleep(0.2)
        for pid in reversed(pids):
            if Path(f"/proc/{pid}").exists():
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass

    def _router_snapshot(self) -> dict[str, Any]:
        machine_path = self.home / ".9router/machine-id"
        secret_path = self.home / ".9router/auth/cli-secret"
        if not machine_path.is_file() or not secret_path.is_file():
            return {}
        machine = machine_path.read_text(encoding="utf-8", errors="ignore").strip()
        secret = secret_path.read_text(encoding="utf-8", errors="ignore").strip()
        token = hashlib.sha256(f"{machine}9r-cli-auth{secret}".encode()).hexdigest()[:16]

        def fetch(path: str) -> dict[str, Any]:
            request = urllib.request.Request(
                f"http://127.0.0.1:20128{path}", headers={"x-9r-cli-token": token}
            )
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    value = json.load(response)
                    return value if isinstance(value, dict) else {}
            except (OSError, urllib.error.URLError, json.JSONDecodeError):
                return {}

        providers = fetch("/api/providers")
        combos = fetch("/api/combos")
        provider_rows = providers.get("connections") or providers.get("providers") or []
        combo_rows = combos.get("combos") or combos.get("data") or []
        return {
            "providers": len(provider_rows) if isinstance(provider_rows, list) else 0,
            "combos": sorted(
                str(item.get("name")) for item in combo_rows if isinstance(item, dict) and item.get("name")
            ),
        }

    def _migrate_legacy_router(self, tx: Transaction) -> dict[str, Any]:
        router = self.router_status()
        if not router["legacyStartupConflict"]:
            return {"migrated": False, "reason": "legacy-startup-not-detected"}
        if router["listener"]["listening"] and router["owner"] == "unknown":
            raise RuntimeError("port 20128 belongs to an unknown process")
        baseline = self._router_snapshot()
        paths = [
            self.home / ".9router",
            self.xdg_config / "systemd/user/9router.service",
            self.xdg_config / "autostart/9router.desktop",
            self.home / ".local/share/phasezero/ai-proxies/9router",
            self.home / ".local/share/phasezero/ai-proxies/.runtime/node24",
            self.home / ".local/share/phasezero/ai-proxies/.9router-backups",
            self.xdg_config / "phasezero/9router",
            self.router_env,
            self.xdg_config / "systemd/user/phasezero-9router.service",
            self.xdg_config / "systemd/user/phasezero-9router-watch.service",
            self.xdg_config / "systemd/user/phasezero-9router-watch.timer",
            self.xdg_config / "systemd/user/phasezero-9router-unix-bridge.service",
            self.local_bin / "9router",
            self.local_bin / "phasezero-9router-run",
            self.xdg_data / "applications/phasezero-9router.desktop",
        ]
        for path in paths:
            tx.backup(path)
        tx.record_service("9router.service")
        for unit in (
            "phasezero-9router.service",
            "phasezero-9router-watch.timer",
            "phasezero-9router-unix-bridge.service",
        ):
            tx.record_service(unit)

        systemctl = command_path("systemctl")
        if systemctl:
            run_capture([systemctl, "--user", "disable", "--now", "9router.service"], timeout=25)
        pids, old_commands = self._legacy_process_tree()
        tx.manifest["legacyProcesses"] = [{"command": command} for command in old_commands]
        tx.manifest["processes"] = [{"pid": pid, "role": "legacy-9router"} for pid in pids]
        tx.save()
        self._terminate_known_tree(pids)
        autostart = self.xdg_config / "autostart/9router.desktop"
        if autostart.exists():
            raw = autostart.read_text(encoding="utf-8", errors="replace")
            raw = re.sub(r"(?m)^Hidden=.*$", "Hidden=true", raw)
            if "Hidden=" not in raw:
                raw += "\nHidden=true\n"
            raw = re.sub(r"(?m)^X-GNOME-Autostart-enabled=.*$", "X-GNOME-Autostart-enabled=false", raw)
            atomic_text(autostart, raw, stat.S_IMODE(autostart.stat().st_mode))
        deadline = time.time() + 10
        while self.listener_info()["listening"] and time.time() < deadline:
            time.sleep(0.5)
        if self.listener_info()["listening"]:
            raise RuntimeError("port 20128 remained occupied after stopping confirmed legacy 9Router")
        router_env = os.environ.copy()
        node_info = self.node_info()
        if node_info["major"] != 24:
            node_bin, npm_bin = self._download_node_runtime(tx)
            router_env["PZ_9ROUTER_NODE_BIN"] = node_bin
            router_env["PZ_9ROUTER_NPM_CLI"] = str(Path(npm_bin).resolve())
        proc = subprocess.run(
            ["bash", str(self.router_manager), "install"],
            text=True,
            timeout=600,
            check=False,
            env=router_env,
        )
        if proc.returncode != 0:
            raise RuntimeError("PhaseZero 9Router installation failed")
        final = self._router_snapshot()
        listener = self.listener_info()
        if not listener["listening"] or listener["address"] not in {"127.0.0.1", "::1"}:
            raise RuntimeError("managed 9Router is not loopback-only")
        if baseline.get("providers", 0) > final.get("providers", 0):
            raise RuntimeError("9Router provider count decreased after migration")
        if not set(baseline.get("combos", [])).issubset(final.get("combos", [])):
            raise RuntimeError("9Router combos changed after migration")
        return {"migrated": True, "before": baseline, "after": final, "listener": listener}

    def verify(self, auth: str | None, proxy: str | None, live: bool = False, cwd: str | None = None) -> dict[str, Any]:
        selected = self.infer_auth(auth)
        state = self.status(selected)
        checks: dict[str, Any] = {
            "selectedAuth": selected,
            "claudeInstalled": state["claude"]["installed"],
            "orphanHooks": sum(1 for item in state["configuration"]["hooks"] if item["state"] == "orphan"),
            "globalRoutingConflicts": len(state["configuration"]["env"]) + len(state["configuration"]["profiles"]),
            "launchers": {name: (self.local_bin / name).is_file() for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai", "phasezero-ai-bonsai")},
            "desktop": {
                "entry": (self.xdg_data / "applications/phasezero-ai-bonsai.desktop").is_file(),
                "icon": (self.xdg_data / "icons/hicolor/512x512/apps/phasezero-bonsai.png").is_file(),
            },
            "live": {},
        }
        ok = checks["claudeInstalled"] and checks["orphanHooks"] == 0 and checks["globalRoutingConflicts"] == 0 and all(checks["launchers"].values()) and all(checks["desktop"].values())
        if selected == "proxy" or proxy == "9router":
            router = self.router_status()
            checks["router"] = router
            ok = ok and router["healthy"] and router["loopbackOnly"]
        if selected == "bonsai" and cwd:
            route_preflight = self.preflight("bonsai", cwd)
            checks["bonsaiWorkspace"] = route_preflight["workspace"]
            checks["bonsaiNetwork"] = route_preflight["network"]
            ok = ok and route_preflight["ok"]
        if live and selected in {"subscription", "proxy"}:
            launcher = self.local_bin / ("claude-subscription" if selected == "subscription" else "claude-9router")
            with tempfile.TemporaryDirectory(prefix="pz-claude-smoke-") as raw:
                proc = subprocess.run(
                    [str(launcher), "-p", "responda apenas: ok"],
                    cwd=raw,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=90,
                    check=False,
                )
            combined = f"{proc.stdout}\n{proc.stderr}"
            lowered = combined.lower()
            quota_blocked = any(
                marker in lowered for marker in ("weekly limit", "usage limit", "rate limit")
            )
            passed = proc.returncode == 0 and "401" not in combined and "invalid api key" not in lowered
            if quota_blocked:
                checks["live"][selected] = {
                    "passed": None,
                    "exitCode": proc.returncode,
                    "blockedReason": "account-quota",
                }
            else:
                checks["live"][selected] = {"passed": passed, "exitCode": proc.returncode}
                ok = ok and passed
        elif live and selected == "bonsai":
            checks["live"]["bonsai"] = {
                "passed": None,
                "routeReady": bool(state["routeCapabilities"]["bonsai"]["ready"]),
                "interactiveConsentRequired": True,
                "fixtureOnly": True,
                "claudeAiConnectors": False,
                "connectorsWarningExpected": False,
                "upstreamDirectCommandMayWarn": True,
                "phaseZeroLauncherSuppressesWarning": True,
                "safeCommand": "linux/pz ai claude run bonsai --cwd <reviewed-directory>",
            }
        checks["ok"] = bool(ok)
        checks["secretsRedacted"] = True
        return checks

    def preflight(self, route: str, cwd: str, allow_sensitive: bool = False) -> dict[str, Any]:
        if route != "bonsai":
            raise RuntimeError("only Bonsai workspace preflight is supported")
        audit = self.bonsai_workspace_audit(cwd)
        network = self.bonsai_network_preflight()
        bonsai = self.bonsai_info()
        workspace_ok = bool(audit["safe"] or allow_sensitive)
        readiness_blockers = list(bonsai["readinessBlockers"])
        if not network["ok"]:
            readiness_blockers.append("bonsai-network")
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "route": route,
            "ok": bool(workspace_ok and network["ok"] and bonsai["ready"]),
            "workspace": audit,
            "readinessBlockers": readiness_blockers,
            "workspaceOverride": bool(allow_sensitive and not audit["safe"]),
            "network": network,
            "authentication": {
                "installed": bonsai["installed"],
                "authenticated": bonsai["authenticated"],
                "credentialStoreSecure": bonsai["credentialStorePermissions"]["secure"],
            },
            "authProvider": bonsai["authProvider"],
            "runner": {
                "ready": bonsai["runner"]["ready"],
                "runtimeNode": bonsai["runtime"]["node"],
                "probeExitCode": bonsai["runner"]["probeExitCode"],
                "updateCheck": "fail-open",
            },
            "artifact": bonsai["artifact"],
            "fallbackCommand": f"BONSAI_ROUTE=9router bonsai start --cwd {shlex.quote(str(Path(cwd).expanduser().resolve()))}",
            "secretsRedacted": True,
        }
        self._record_preflight(result)
        return result

    def install(self, auth: str | None, proxy: str | None, dry_run: bool, yes: bool, verbose: bool) -> dict[str, Any]:
        selected = self.infer_auth(auth)
        if selected is None:
            raise RuntimeError("no authentication route available; run claude /login or bonsai login")
        if selected == "proxy" and proxy not in {None, "9router"}:
            raise RuntimeError("only proxy=9router is currently supported")
        actions = self.planned_actions(selected)
        if dry_run:
            return {"schemaVersion": SCHEMA_VERSION, "dryRun": True, "selectedAuth": selected, "state": self.status(selected), "plannedActions": actions, "secretsRedacted": True}
        if not yes and sys.stdin.isatty():
            answer = input(f"Apply {len(actions)} Claude/Bonsai actions with automatic rollback? [y/N] ").strip().lower()
            if answer not in {"y", "yes", "s", "sim"}:
                raise RuntimeError("cancelled")
        tx = Transaction(self.data_root, "install")
        tx.manifest["selectedAuth"] = selected
        tx.save()
        stopped_legacy_commands: list[str] = []
        try:
            claude = self._ensure_claude(tx)
            self._failpoint("claude")
            bonsai = self._ensure_bonsai(tx)
            self._failpoint("bonsai")
            secured_bonsai_paths = self._secure_bonsai_store(tx)
            self._failpoint("bonsai-store")
            repairs = self._repair_settings(tx, subscription_default=(selected == "subscription"))
            self._failpoint("settings")
            quarantined = self._quarantine_profiles(tx) if selected == "subscription" else 0
            self._failpoint("profiles")
            migration = self._migrate_legacy_router(tx)
            self._failpoint("9router-migration")
            stopped_legacy_commands = [item["command"] for item in tx.manifest.get("legacyProcesses", [])]
            router_model = self._ensure_router_model(tx)
            self._failpoint("9router-model")
            wrappers = self._write_launchers(tx, claude, bonsai)
            self._failpoint("launchers")
            desktop_cache = self._refresh_desktop_menu()
            shim_profiles = self._ensure_shim_path_precedence(tx)
            self._failpoint("path-precedence")
            router_after = self.router_status()
            verify_proxy = "9router" if selected == "proxy" or router_after["managedInstalled"] else proxy
            verification = self.verify(selected, verify_proxy, live=False)
            if not verification["ok"]:
                raise RuntimeError("post-install verification failed")
            report = "\n".join(
                [
                    "# Claude Code + Bonsai Linux report",
                    "",
                    f"- Completed: {now_iso()}",
                    f"- Default authentication: `{selected}`",
                    f"- Quarantined profile lines: {quarantined}",
                    f"- Secured Bonsai credential paths: {secured_bonsai_paths}",
                    f"- Removed settings keys: {repairs['environmentKeys']}",
                    f"- Removed orphan hooks: {repairs['hooks']}",
                    f"- 9Router migrated: {str(migration.get('migrated', False)).lower()}",
                    f"- 9Router Claude model: `{router_model or 'not-configured'}`",
                    f"- Launchers: {', '.join(wrappers)}",
                    f"- Desktop menu refresh: {json.dumps(desktop_cache, sort_keys=True)}",
                    f"- Shell profiles updated for shim precedence: {shim_profiles}",
                    f"- Rollback: `linux/pz ai claude rollback {tx.manifest_path}`",
                    "- Secrets: redacted",
                    "",
                ]
            )
            tx.complete(verification, report)
            return {
                "schemaVersion": SCHEMA_VERSION,
                "status": "complete",
                "selectedAuth": selected,
                "manifest": str(tx.manifest_path),
                "report": str(tx.report_path),
                "migration": migration,
                "desktopMenu": desktop_cache,
                "verification": verification,
                "secretsRedacted": True,
            }
        except Exception:
            if not stopped_legacy_commands:
                stopped_legacy_commands = [item["command"] for item in tx.manifest.get("legacyProcesses", [])]
            tx.finalize_paths()
            tx.manifest["status"] = "failed-rolling-back"
            tx.save()
            try:
                restore_manifest(tx.manifest_path, force=True)
                for command in stopped_legacy_commands:
                    parts = shlex.split(command)
                    if parts:
                        subprocess.Popen(parts, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                tx.manifest = json.loads(tx.manifest_path.read_text(encoding="utf-8"))
                tx.manifest["status"] = "failed-rolled-back"
                tx.manifest["completedAt"] = now_iso()
                tx.save()
            except Exception as rollback_exc:
                tx.log(f"rollback failure: {rollback_exc}")
            raise

    def login(self, route: str) -> int:
        if route == "subscription":
            claude = command_path("claude")
            if not claude:
                raise RuntimeError("Claude Code missing")
            return subprocess.run([claude, "/login"], check=False).returncode
        bonsai_path = self.data_root / "tools/bonsai-runner/bonsai-managed"
        if not bonsai_path.is_file():
            raise RuntimeError("Bonsai managed runner missing")
        bonsai = str(bonsai_path)
        info = self.bonsai_info()
        if not info["runner"]["ready"]:
            print(json.dumps({
                "schemaVersion": SCHEMA_VERSION,
                "status": "runner-unavailable",
                "fallback": "linux/pz ai claude install --yes",
                "secretsRedacted": True,
            }, indent=2), file=sys.stderr)
            return 69
        auth_probe = self.bonsai_auth_probe()
        if not auth_probe["available"]:
            print(json.dumps({
                "schemaVersion": SCHEMA_VERSION,
                "status": auth_probe["class"],
                "authProvider": auth_probe,
                "credentialPreserved": True,
                "fallback": "BONSAI_ROUTE=9router bonsai start --cwd <reviewed-directory>",
                "secretsRedacted": True,
            }, indent=2), file=sys.stderr)
            return 69
        store_dir = self.bonsai_config.parent
        existed = store_dir.is_dir()
        succeeded = False
        with tempfile.TemporaryDirectory(prefix="pz-bonsai-login-") as raw:
            backup = Path(raw) / "credential-store"
            if existed:
                shutil.copytree(store_dir, backup, symlinks=True)
            try:
                rc = subprocess.run([bonsai, "login"], check=False).returncode
                succeeded = rc == 0
            except KeyboardInterrupt:
                rc = 130
            if not succeeded:
                remove_path(store_dir)
                if existed:
                    shutil.copytree(backup, store_dir, symlinks=True)
                print(json.dumps({
                    "schemaVersion": SCHEMA_VERSION,
                    "status": "login-cancelled" if rc in {130, -signal.SIGINT} else "login-failed",
                    "exitCode": rc,
                    "credentialPreserved": True,
                    "secretsRedacted": True,
                }, indent=2), file=sys.stderr)
                return rc if rc > 0 else 1
        if store_dir.is_dir():
            os.chmod(store_dir, 0o700)
            for item in store_dir.rglob("*"):
                if item.is_symlink():
                    continue
                os.chmod(item, 0o700 if item.is_dir() else 0o600)
        return 0

    def run_route(self, route: str, args: list[str], cwd: str | None = None, allow_sensitive: bool = False) -> int:
        name = {"subscription": "claude-subscription", "bonsai": "claude-bonsai", "proxy": "claude-9router"}[route]
        launcher = self.local_bin / name
        if not launcher.is_file():
            raise RuntimeError(f"launcher missing: {launcher}; run install first")
        run_cwd = Path(cwd).expanduser().resolve() if cwd else Path.cwd()
        if not run_cwd.is_dir():
            raise RuntimeError(f"working directory missing: {run_cwd}")
        if route == "bonsai":
            route_preflight = self.preflight("bonsai", str(run_cwd), allow_sensitive=allow_sensitive)
            if not route_preflight["ok"]:
                print(json.dumps(route_preflight, indent=2, sort_keys=True), file=sys.stderr)
                print(f"Bonsai preflight failed. Explicit fallback: {route_preflight['fallbackCommand']}", file=sys.stderr)
                return 69
            if allow_sensitive:
                args = ["--allow-sensitive-upload", *args]
        return subprocess.run([str(launcher), *args], cwd=run_cwd, check=False).returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pz ai claude")
    parser.add_argument("--rollback", dest="rollback_alias")
    sub = parser.add_subparsers(dest="command")
    status = sub.add_parser("status")
    status.add_argument("--verbose", action="store_true")
    status.add_argument("--auth", choices=("subscription", "bonsai", "proxy"))
    install = sub.add_parser("install", aliases=["setup", "repair"])
    install.add_argument("--dry-run", action="store_true")
    install.add_argument("--yes", action="store_true")
    install.add_argument("--verbose", action="store_true")
    install.add_argument("--auth", choices=("subscription", "bonsai", "proxy"))
    install.add_argument("--proxy", choices=("9router",))
    verify = sub.add_parser("verify")
    verify.add_argument("--auth", choices=("subscription", "bonsai", "proxy"))
    verify.add_argument("--proxy", choices=("9router",))
    verify.add_argument("--live", action="store_true")
    verify.add_argument("--cwd")
    preflight = sub.add_parser("preflight")
    preflight.add_argument("route", choices=("bonsai",))
    preflight.add_argument("--cwd", required=True)
    preflight.add_argument("--allow-sensitive-upload", action="store_true")
    login = sub.add_parser("login")
    login.add_argument("route", choices=("subscription", "bonsai"))
    run = sub.add_parser("run")
    run.add_argument("route", choices=("subscription", "bonsai", "proxy"))
    run.add_argument("--proxy", choices=("9router",))
    run.add_argument("--cwd")
    run.add_argument("--allow-sensitive-upload", action="store_true")
    run.add_argument("args", nargs="*")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("manifest")
    rollback.add_argument("--force", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    passthrough: list[str] = []
    if raw_argv[:1] == ["run"] and "--" in raw_argv:
        separator = raw_argv.index("--")
        passthrough = raw_argv[separator + 1 :]
        raw_argv = raw_argv[:separator]
    args = parser.parse_args(raw_argv)
    try:
        if args.rollback_alias:
            print(json.dumps(restore_manifest(Path(args.rollback_alias)), indent=2))
            return 0
        manager = Manager()
        command = args.command or "status"
        if command == "status":
            result = manager.status(getattr(args, "auth", None))
        elif command in {"install", "setup", "repair"}:
            result = manager.install(args.auth, args.proxy, args.dry_run, args.yes, args.verbose)
        elif command == "verify":
            result = manager.verify(args.auth, args.proxy, args.live, args.cwd)
        elif command == "preflight":
            result = manager.preflight(args.route, args.cwd, args.allow_sensitive_upload)
        elif command == "login":
            return manager.login(args.route)
        elif command == "run":
            route_args = [*args.args, *passthrough]
            return manager.run_route(args.route, route_args, args.cwd, args.allow_sensitive_upload)
        elif command == "rollback":
            result = restore_manifest(Path(args.manifest), args.force)
        else:
            parser.error(f"unknown command: {command}")
            return 2
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("ok", True) else 1
    except (RuntimeError, OSError, json.JSONDecodeError, urllib.error.URLError) as exc:
        print(json.dumps({"schemaVersion": SCHEMA_VERSION, "status": "error", "error": str(exc), "secretsRedacted": True}, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
