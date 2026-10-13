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
        excluded = {".git", "node_modules", ".venv", "venv", "target", "build", "dist"}
        categories: set[str] = set()
        scanned = 0
        for root, dirs, files in os.walk(path, followlinks=False):
            dirs[:] = [name for name in dirs if name not in excluded]
            for name in files:
                scanned += 1
                lowered = name.lower()
                if lowered == ".env" or (lowered.startswith(".env.") and lowered not in {".env.example", ".env.sample", ".env.template"}):
                    categories.add("dotenv")
                elif lowered in {".npmrc", ".pypirc", "credentials", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"} or lowered.startswith("credentials."):
                    categories.add("credential-file")
                elif Path(lowered).suffix in {".pem", ".p12", ".pfx", ".key"}:
                    categories.add("private-key-file")
        return {
            "path": str(path),
            "safe": not categories,
            "blockers": sorted(categories),
            "filesScanned": scanned,
            "warnings": ["large-workspace"] if scanned > 5000 else [],
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
        auth: dict[str, Any] = {
            "loggedIn": None, "authMethod": None, "apiProvider": None,
            "probeStatus": "backend-unavailable",
        }
        if path:
            rc, out, _ = run_capture([path, "--version"], timeout=8)
            if rc == 0:
                version = out.strip().splitlines()[0] if out.strip() else ""
            auth_rc, auth_out, _ = run_capture([path, "auth", "status", "--json"], timeout=12)
            if auth_rc == 124:
                auth["probeStatus"] = "timeout"
            elif auth_rc != 0:
                auth["probeStatus"] = "backend-unavailable"
            else:
                try:
                    raw = json.loads(auth_out)
                except json.JSONDecodeError:
                    raw = None
                if isinstance(raw, dict):
                    auth = {
                        "loggedIn": raw.get("loggedIn") if isinstance(raw.get("loggedIn"), bool) else None,
                        "authMethod": raw.get("authMethod"),
                        "apiProvider": raw.get("apiProvider"),
                        "probeStatus": "ok",
                    }
                else:
                    auth["probeStatus"] = "backend-unavailable"
        return {
            "installed": bool(path),
            "path": path,
            "realPath": str(Path(path).resolve()) if path else None,
            "version": version,
            "auth": auth,
        }

    def bonsai_info(self) -> dict[str, Any]:
        path = command_path("bonsai")
        version = ""
        if path:
            rc, out, _ = run_capture([path, "--version"], timeout=8)
            if rc == 0:
                version = out.strip().splitlines()[0] if out.strip() else ""
        store_dir = self.bonsai_config.parent
        store_present = self.bonsai_config.is_file() and self.bonsai_config.stat().st_size > 0
        directory_mode = stat.S_IMODE(store_dir.stat().st_mode) if store_dir.is_dir() else None
        insecure_files = 0
        if store_dir.is_dir():
            for item in store_dir.rglob("*"):
                if item.is_file() and not item.is_symlink() and stat.S_IMODE(item.stat().st_mode) != 0o600:
                    insecure_files += 1
        update_check = self._bonsai_update_check(path)
        return {
            "installed": bool(path),
            "path": path,
            "version": version,
            "updateCheck": update_check,
            "nextAction": (
                "remova o runner que fixa a versão e reinstale pelo canal oficial (https://www.trybons.ai)"
                if update_check == "forged"
                else ""
            ),
            "credentialStorePresent": store_present,
            "authenticated": True if store_present else None,
            "snapshotConsent": "interactive-upstream",
            "credentialStorePermissions": {
                "directoryMode": f"{directory_mode:04o}" if directory_mode is not None else None,
                "insecureFiles": insecure_files,
                "secure": bool(directory_mode == 0o700 and insecure_files == 0),
            },
        }

    @staticmethod
    def _bonsai_update_check(path: str | None) -> str:
        """Follow the launcher chain and flag a runner that fakes npm "latest".

        A hand-made runner once pinned PZ_BONSAI_INSTALLED_VERSION and answered
        /@bonsai-ai/cli/latest with the installed version whenever the registry
        failed, so the CLI believed it was current forever.
        """
        if not path:
            return "not-installed"
        seen: set[Path] = set()
        pending = [Path(path)]
        while pending and len(seen) < 6:
            current = pending.pop()
            try:
                current = current.resolve()
                if current in seen or not current.is_file() or current.stat().st_size > 65536:
                    continue
                seen.add(current)
                text = current.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if "latest-fail-open" in text or "PZ_BONSAI_INSTALLED_VERSION" in text:
                return "forged"
            for match in re.finditer(r"^(?:upstream=|exec\s+)['\"]?([^'\"\s]+)", text, re.MULTILINE):
                pending.append(Path(match.group(1)))
        return "upstream"

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
        if bonsai["installed"] and bonsai["credentialStorePresent"]:
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
                    "ready": bool(bonsai["installed"] and bonsai["credentialStorePresent"]),
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
            "managedSessionLaunch": {
                "enabled": False,
                "blockedReason": "account-bound-consumer-grant-unavailable",
                "message": "Authentication status does not authorize a managed inference session.",
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
        libc = platform.libc_ver()[0].lower()
        machine = platform.machine().lower()
        arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
        if arch is None or libc not in {"glibc", "gnu libc", "libc"}:
            raise RuntimeError("Node/npm missing; automatic isolated runtime supports glibc x64/arm64 only")
        with urllib.request.urlopen("https://nodejs.org/dist/index.json", timeout=20) as response:
            releases = json.load(response)
        release = next((item for item in releases if item.get("lts") and int(item["version"].lstrip("v").split(".")[0]) >= 22), None)
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
        runtime = self.data_root / "runtime/node-lts"
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
        tx.manifest["packages"].append({"name": "node", "version": version, "method": "verified-user-runtime"})
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

    def _ensure_bonsai(self, tx: Transaction) -> str:
        existing = self._bonsai_upstream()
        if existing:
            return existing
        node_info = self.node_info()
        npm = node_info["npm"]
        node = node_info["node"]
        if not npm or not node or node_info["major"] < 16:
            node, npm = self._download_node_runtime(tx)
        prefix = self.data_root / "tools/bonsai"
        tx.backup(prefix)
        env = os.environ.copy()
        env["PATH"] = f"{Path(node).parent}:{env.get('PATH', '')}"
        rc, metadata_out, err = run_capture([npm, "view", "@bonsai-ai/cli", "version", "dist.integrity", "--json"], timeout=30, env=env)
        if rc != 0:
            if "E404" in err or "404" in err:
                # @bonsai-ai/cli was unpublished from npm (registry 404 since
                # 2026-09). An existing install keeps working; only a fresh one
                # has no verifiable source.
                raise RuntimeError(
                    "Bonsai CLI indisponível no npm (@bonsai-ai/cli retorna 404). "
                    "Instale pelo canal oficial em https://www.trybons.ai e rode de novo; "
                    "uma instalação existente continua sendo reutilizada."
                )
            raise RuntimeError(f"Bonsai registry metadata failed: {err.strip()}")
        metadata = json.loads(metadata_out)
        version = metadata.get("version")
        integrity = metadata.get("dist.integrity") or metadata.get("dist", {}).get("integrity")
        if not version or not integrity:
            raise RuntimeError("Bonsai registry did not publish version/integrity")
        with tempfile.TemporaryDirectory(prefix="pz-bonsai-") as raw:
            rc, pack_out, err = run_capture(
                [npm, "pack", f"@bonsai-ai/cli@{version}", "--pack-destination", raw, "--json"], timeout=90, env=env
            )
            if rc != 0:
                raise RuntimeError(f"Bonsai pack failed: {err.strip()}")
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
        launcher = prefix / "bin/bonsai-phasezero"
        atomic_text(launcher, f"#!/usr/bin/env bash\nexec {shlex.quote(node)} {shlex.quote(str(cli_js))} \"$@\"\n", 0o700)
        tx.manifest["packages"].append({"name": "@bonsai-ai/cli", "version": version, "integrity": integrity, "method": "verified-npm-stage"})
        tx.save()
        return str(launcher)

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

    def _write_launchers(self, tx: Transaction, bonsai: str) -> list[str]:
        self.local_bin.mkdir(parents=True, exist_ok=True)
        bonsai_real = str(Path(bonsai).resolve())
        pz_cli = self.repo_root / "linux/pz"
        wrappers: dict[str, str] = {
            "claude-subscription": f"""#!/usr/bin/env bash
set -euo pipefail
exec bash {shlex.quote(str(pz_cli))} ai claude run subscription --cwd "$PWD" -- "$@"
""",
            "claude-9router": f"""#!/usr/bin/env bash
set -euo pipefail
exec bash {shlex.quote(str(pz_cli))} ai claude run proxy --cwd "$PWD" -- "$@"
""",
            "claude-bonsai": f"""#!/usr/bin/env bash
set -euo pipefail
exec bash {shlex.quote(str(pz_cli))} ai claude run bonsai --cwd "$PWD" -- "$@"
""",
            "bonsai": f"""#!/usr/bin/env bash
set -euo pipefail
upstream={shlex.quote(bonsai_real)}
pz={shlex.quote(str(pz_cli))}
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
    command=(bash "$pz" ai claude run bonsai --cwd "$cwd")
    $allow_sensitive && command+=(--allow-sensitive-upload)
    command+=(-- "${{args[@]}}")
    exec "${{command[@]}}"
    ;;
  9router|proxy)
    echo "PhaseZero: route=9router; Bonsai is not started, no Bonsai snapshot/upload occurs." >&2
    exec bash "$pz" ai claude run proxy --proxy=9router --cwd "$cwd" -- "${{args[@]}}"
    ;;
  *)
    echo "bonsai start: invalid BONSAI_ROUTE/--route '$route' (expected direct or 9router)" >&2
    exit 2
    ;;
esac
""",
        }
        for name, content in wrappers.items():
            target = self.local_bin / name
            if target.is_file() and target.read_text(encoding="utf-8", errors="replace") == content \
                and stat.S_IMODE(target.stat().st_mode) == 0o700:
                continue
            tx.backup(target)
            atomic_text(target, content, 0o700)
        return sorted(wrappers)

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
            "managedLaunchEnabled": state["managedSessionLaunch"]["enabled"],
            "managedLaunchBlockedReason": state["managedSessionLaunch"]["blockedReason"],
            "orphanHooks": sum(1 for item in state["configuration"]["hooks"] if item["state"] == "orphan"),
            "globalRoutingConflicts": len(state["configuration"]["env"]) + len(state["configuration"]["profiles"]),
            "launchers": {name: (self.local_bin / name).is_file() for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai")},
            "live": {},
        }
        ok = (checks["claudeInstalled"] and checks["orphanHooks"] == 0
              and checks["globalRoutingConflicts"] == 0
              and all(checks["launchers"].values()))
        if selected == "proxy" or proxy == "9router":
            router = self.router_status()
            checks["router"] = router
            ok = ok and router["healthy"] and router["loopbackOnly"]
        if selected == "bonsai" and cwd:
            route_preflight = self.preflight("bonsai", cwd)
            checks["bonsaiWorkspace"] = route_preflight["workspace"]
            checks["bonsaiNetwork"] = route_preflight["network"]
            ok = ok and route_preflight["ok"]
        if live and selected in {"subscription", "bonsai", "proxy"}:
            checks["live"][selected] = {
                "passed": None,
                "blockedReason": state["managedSessionLaunch"]["blockedReason"],
                "message": "No inference prompt sent; connection-bound grant enforcement unavailable.",
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
        result = {
            "schemaVersion": SCHEMA_VERSION,
            "route": route,
            "ok": bool(workspace_ok and network["ok"] and bonsai["installed"] and bonsai["authenticated"]),
            "workspace": audit,
            "workspaceOverride": bool(allow_sensitive and not audit["safe"]),
            "network": network,
            "authentication": {"installed": bonsai["installed"], "authenticated": bonsai["authenticated"]},
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
            wrappers = self._write_launchers(tx, bonsai)
            self._failpoint("launchers")
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
        bonsai = command_path("bonsai")
        if not bonsai:
            raise RuntimeError("Bonsai missing")
        return subprocess.run([bonsai, "login"], check=False).returncode

    def run_route(self, route: str, args: list[str], cwd: str | None = None, allow_sensitive: bool = False) -> int:
        if route not in {"subscription", "bonsai", "proxy"}:
            raise RuntimeError("unsupported authentication route")
        raise RuntimeError(
            f"Claude {route} launch disabled: no account-bound consumer grant can be "
            "enforced for this route; login and workspace consent do not authorize inference; "
            "no client process was started"
        )


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
