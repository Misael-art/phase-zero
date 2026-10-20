#!/usr/bin/env python3
"""Transactional, opt-in manager for the official DeepSeek Harness runtime.

The pinned upstream package is launched only from an explicit user request.
Secrets stay in the PhaseZero OS credential vault or Harness's own DSH_HOME.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import hmac
import http.server
import json
import os
import platform
import posixpath
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterator


SCHEMA_VERSION = 1
APP_ID = "app.deepseek-harness"
DEFAULT_PORT = 3080
MIN_FREE_BYTES = 512 * 1024 * 1024
MIN_AVAILABLE_MEMORY_BYTES = 2 * 1024 * 1024 * 1024
READY_TIMEOUT_SECONDS = 35
ROOT = Path(__file__).resolve().parents[2]
PIN_FILE = ROOT / "packaging" / "deepseek-harness" / "pins.json"
PACKAGE_DIR = ROOT / "packaging" / "deepseek-harness"
SENSITIVE_ENV = re.compile(
    r"(?:^|_)(?:API|AUTH|ACCESS|REFRESH|BEARER|KEY|TOKEN|SECRET|PASSWORD|COOKIE|CREDENTIALS?)(?:_|$)",
    re.I,
)
UNTRUSTED_NODE_ENV = re.compile(r"^(?:NODE_OPTIONS|NODE_PATH|NODE_EXTRA_CA_CERTS)$|^NPM_CONFIG_", re.I)
TOKEN_QUERY = re.compile(r"([?&](?:token|launchToken)=)[^&\s\"']+", re.I)
SECRET_ASSIGNMENT = re.compile(
    r'''(?ix)(["']?\b(?:deepseek[\s_-]+)?(?:api[\s_-]*key|access[\s_-]*token|refresh[\s_-]*token|launch[\s_-]*token|client[\s_-]*secret|secret|password|cookie|authorization|bearer|token)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)'''
)


class DshError(RuntimeError):
    def __init__(self, code: str, reason: str, next_action: str = "") -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason
        self.next_action = next_action


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _xdg_data() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")).expanduser()


def app_root() -> Path:
    override = os.environ.get("PZ_DSH_ROOT")
    return Path(override).expanduser().absolute() if override else _xdg_data() / "phasezero/deepseek-harness"


def state_file() -> Path:
    return app_root() / "state.json"


def active_file() -> Path:
    return app_root() / "active.json"


def install_root() -> Path:
    return app_root() / "runtime"


def homes_root() -> Path:
    return app_root() / "homes"


def supervisor_file() -> Path:
    return app_root() / "supervisor.json"


def log_file() -> Path:
    return app_root() / "logs" / "dsh.log"


def _load_json(path: Path, default: Any = None) -> Any:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        return default
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return default
    return value


def _private_dir(path: Path) -> None:
    root = Path(os.path.abspath(app_root()))
    target = Path(os.path.abspath(path))
    if root == Path(root.anchor) or (target != root and root not in target.parents):
        raise DshError("unsafe-managed-path", "Managed path escapes the dedicated Harness root")
    if os.name == "nt":
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if root.is_symlink():
            raise DshError("unsafe-managed-path", "Harness root cannot be a reparse point")
        return
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or not root.is_dir():
        raise DshError("unsafe-managed-path", "Harness root must be a real directory")
    root.chmod(0o700)
    current = root
    for part in target.relative_to(root).parts:
        current = current / part
        if current.exists() and (current.is_symlink() or not current.is_dir()):
            raise DshError("unsafe-managed-path", "Managed directories cannot be symlinks or files")
        current.mkdir(exist_ok=True, mode=0o700)
        current.chmod(0o700)


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    _private_dir(path.parent)
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        if os.name != "nt":
            os.chmod(path, 0o600)
    finally:
        with contextlib.suppress(OSError):
            temp.unlink()


def _read_pins() -> dict[str, Any]:
    try:
        pins = json.loads(PIN_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise DshError("pin-data-invalid", "Committed version pins are unavailable") from None
    if not isinstance(pins, dict) or pins.get("schemaVersion") != 1:
        raise DshError("pin-data-invalid", "Committed version pins have unsupported schema")
    return pins


def _host_support() -> tuple[str, str]:
    os_name = platform.system().lower()
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        arch = "x64"
    elif machine in {"aarch64", "arm64"}:
        arch = "arm64"
    else:
        arch = machine
    return os_name, arch


def _available_memory_bytes() -> int | None:
    """Return conservative available memory, accounting for cgroup limits."""
    available: int | None = None
    try:
        for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
            if line.startswith("MemAvailable:"):
                available = int(line.split()[1]) * 1024
                break
    except (OSError, ValueError, IndexError):
        return None
    if available is None:
        return None
    for limit_path, current_path in (
        (Path("/sys/fs/cgroup/memory.max"), Path("/sys/fs/cgroup/memory.current")),
        (Path("/sys/fs/cgroup/memory/memory.limit_in_bytes"), Path("/sys/fs/cgroup/memory/memory.usage_in_bytes")),
    ):
        try:
            limit_raw = limit_path.read_text(encoding="ascii").strip()
            current_raw = current_path.read_text(encoding="ascii").strip()
            if limit_raw != "max":
                limit, current = int(limit_raw), int(current_raw)
                # cgroup v1 reports an effectively infinite value when unset.
                if 0 < limit < (1 << 60):
                    available = min(available, max(0, limit - current))
        except (OSError, ValueError):
            continue
    return available


def _managed_root_safe() -> bool:
    root = Path(os.path.abspath(app_root()))
    if root == Path(root.anchor):
        return False
    if root.is_symlink() or (root.exists() and not root.is_dir()):
        return False
    return True


def _resource(pins: dict[str, Any], os_name: str, arch: str) -> dict[str, Any] | None:
    resources = pins.get("node", {}).get("platforms", {})
    os_key = {"windows": "win32"}.get(os_name, os_name)
    return resources.get(f"{os_key}-{arch}") if isinstance(resources, dict) else None


def _port() -> int:
    saved = _load_json(state_file(), {})
    configured = saved.get("port", DEFAULT_PORT) if isinstance(saved, dict) else DEFAULT_PORT
    raw = os.environ.get("PZ_DSH_PORT", str(configured))
    try:
        value = int(raw)
    except ValueError:
        raise DshError("invalid-port", "Port must be an integer from 1024 to 65535") from None
    if not 1024 <= value <= 65535:
        raise DshError("invalid-port", "Port must be an integer from 1024 to 65535")
    return value


def _result(
    command: str,
    *,
    ok: bool,
    state: str,
    reason: str = "",
    next_action: str = "",
    **extra: Any,
) -> dict[str, Any]:
    pins = _read_pins()
    payload: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "appId": APP_ID,
        "command": command,
        "ok": ok,
        "state": state,
        "reason": reason,
        "nextAction": next_action,
        "version": pins["harness"]["version"],
        "profile": "web",
        "port": _port(),
        "authRoute": "unknown",
        "accountAuth": "unknown",
        "apiCredential": "unknown",
        "quota": "unknown",
        "balance": "unknown",
        "sandboxPolicy": "workspace-write + ask (requested)",
        "sandboxEnforcement": "unknown",
        "workspaceSelection": "confirm in Harness Web UI",
        "plugins": "opt-in; none enabled by PhaseZero",
        "telemetry": "disabled by DSH_TELEMETRY_DISABLED=1",
    }
    payload.update(extra)
    return payload


def _output(payload: dict[str, Any], exit_code: int = 0) -> int:
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return exit_code


def _active_runtime() -> tuple[Path | None, dict[str, Any] | None]:
    active = _load_json(active_file(), {})
    if not isinstance(active, dict) or active.get("schemaVersion") != 1:
        return None, None
    relative = active.get("runtimePath")
    if not isinstance(relative, str) or not relative:
        return None, active
    candidate = install_root() / relative
    try:
        resolved = candidate.resolve(strict=True)
        base = install_root().resolve(strict=True)
    except OSError:
        return None, active
    if base not in resolved.parents or not resolved.is_dir():
        return None, active
    return resolved, active


def _supervisor_state() -> dict[str, Any]:
    value = _load_json(supervisor_file(), {})
    return value if isinstance(value, dict) else {}


def _pid_alive(pid: object) -> bool:
    if type(pid) is not int or pid <= 0:
        return False
    if os.name == "nt":
        # The supervisor file is private to this user; the TCP control endpoint
        # is the authoritative liveness probe on Windows and Linux.
        return True
    try:
        stat_path = Path(f"/proc/{pid}/stat")
        if stat_path.is_file():
            fields = stat_path.read_text(encoding="ascii").split()
            if len(fields) > 2 and fields[2] == "Z":
                return False
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _probe_http(port: int, timeout: float = 0.75) -> tuple[bool, int | None]:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/", headers={"Host": f"127.0.0.1:{port}"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status in {200, 301, 302, 303, 307, 308, 401}, response.status
    except urllib.error.HTTPError as exc:
        return exc.code in {301, 302, 303, 307, 308, 401}, exc.code
    except (OSError, urllib.error.URLError, TimeoutError):
        return False, None


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def _control(action: str, timeout: float = 3.0) -> dict[str, Any]:
    info = _supervisor_state()
    port, nonce = info.get("controlPort"), info.get("controlNonce")
    if type(port) is not int or not isinstance(nonce, str):
        raise DshError("not-running", "Harness supervisor is not active", "start")
    body = json.dumps({"action": action, "nonce": nonce}).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/control", data=body,
        headers={"Content-Type": "application/json", "Host": f"127.0.0.1:{port}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read(4096).decode("utf-8"))
    except (OSError, urllib.error.URLError, TimeoutError, json.JSONDecodeError, UnicodeError):
        raise DshError("supervisor-unreachable", "Harness supervisor control is unavailable", "doctor") from None
    if not isinstance(result, dict) or not result.get("ok"):
        code = result.get("code", "control-failed") if isinstance(result, dict) else "invalid-control-response"
        reason = result.get("reason", "Control request failed") if isinstance(result, dict) else "Invalid supervisor response"
        raise DshError(str(code), str(reason), "doctor")
    return result


def _base_environment(dsh_home: Path) -> dict[str, str]:
    env = os.environ.copy()
    for name in tuple(env):
        if SENSITIVE_ENV.search(name) or name.upper().startswith("DEEPSEEK_") or UNTRUSTED_NODE_ENV.search(name):
            env.pop(name, None)
    env["DSH_HOME"] = str(dsh_home)
    env["DSH_TELEMETRY_DISABLED"] = "1"
    env["DSH_PERMISSION_MODE"] = "workspace-write"
    # Bound V8 old-space; this does not sandbox native code or child tools.
    env["NODE_OPTIONS"] = "--max-old-space-size=2048"
    return env


def _version_status() -> tuple[str, Path | None, dict[str, Any] | None]:
    runtime, active = _active_runtime()
    if runtime is None or active is None:
        return "absent", None, active
    version = active.get("version")
    if version != _read_pins()["harness"]["version"]:
        return "version-drift", runtime, active
    return "installed", runtime, active


def _runtime_paths(runtime: Path) -> tuple[Path, Path, Path]:
    node_dir = runtime / "node"
    app_dir = runtime / "app"
    node = node_dir / ("node.exe" if os.name == "nt" else "bin/node")
    npm = node_dir / ("npm.cmd" if os.name == "nt" else "bin/npm")
    dsh = app_dir / "node_modules/@deepseek-ai/dsh/lib/bin.js"
    return node, npm, dsh


def status_payload(command: str = "status") -> dict[str, Any]:
    status, runtime, active = _version_status()
    saved = _load_json(state_file(), {})
    saved = saved if isinstance(saved, dict) else {}
    supervisor = _supervisor_state()
    route = saved.get("authRoute", "unknown")
    pid = supervisor.get("pid") or saved.get("supervisorPid")
    live = _pid_alive(pid)
    if live:
        try:
            live = bool(_control("status", timeout=0.5).get("running"))
        except DshError:
            live = False
    http_ok = False
    http_status = None
    if live:
        http_ok, http_status = _probe_http(_port())
    if not live and supervisor:
        run_state = "crashed-or-stale"
    elif live and http_ok:
        run_state = "running"
    elif live:
        run_state = "starting-or-unhealthy"
    else:
        run_state = "stopped"
    if status != "installed":
        overall = "not-installed" if status == "absent" else "degraded"
    elif run_state == "running":
        overall = "running"
    elif run_state == "crashed-or-stale":
        overall = "degraded"
    else:
        overall = "installed"
    api_state = "not-selected"
    account_state = "unknown"
    if route in {"account", "api"}:
        credential_present = (homes_root() / route / ".credentials.yaml").is_file()
        if route == "account":
            account_state = "credential file present; session unknown" if credential_present else "unknown"
        else:
            api_state = "credential file present; validity unknown" if credential_present else "not observed"
    next_action = {
        "not-installed": "install",
        "degraded": "doctor",
        "running": "open",
        "installed": "choose workspace and auth route, then start",
    }.get(overall, "doctor")
    memory_available = _available_memory_bytes()
    return _result(
        command, ok=status == "installed" and run_state != "crashed-or-stale",
        state=overall, reason="" if status == "installed" else status,
        next_action=next_action,
        installed=status == "installed", runtimeState=run_state,
        installedVersion=active.get("version", "") if isinstance(active, dict) else "",
        workspace=saved.get("requestedWorkspace", ""),
        workspaceSelection=saved.get("workspaceSelection", "not-selected"), authRoute=route,
        accountAuth=account_state, apiCredential=api_state,
        processId=pid if live else None, healthCheck={"loopbackHttp": http_status, "healthy": http_ok},
        availableMemoryBytes=memory_available, requiredMemoryBytes=MIN_AVAILABLE_MEMORY_BYTES,
        memoryBudget=("unknown" if memory_available is None else "sufficient" if memory_available >= MIN_AVAILABLE_MEMORY_BYTES else "insufficient"),
        dshHome=str(homes_root() / route) if route in {"account", "api"} else "",
        proxyRoute="blocked until request-bound grants are available",
    )


def plan_payload() -> dict[str, Any]:
    pins = _read_pins()
    os_name, arch = _host_support()
    node_resource = _resource(pins, os_name, arch)
    nearest = app_root()
    while not nearest.exists() and nearest != nearest.parent:
        nearest = nearest.parent
    free = shutil.disk_usage(nearest).free
    memory_available = _available_memory_bytes()
    root_safe = _managed_root_safe()
    supported = os_name == "linux" and arch == "x64" and node_resource is not None and root_safe
    enough_disk = free >= MIN_FREE_BYTES
    enough_memory = memory_available is not None and memory_available >= MIN_AVAILABLE_MEMORY_BYTES
    ready = supported and enough_disk and enough_memory
    return _result(
        "plan", ok=ready,
        state="ready" if ready else "blocked",
        reason="" if ready else (
            "unsafe-managed-root" if not root_safe else
            "unsupported-platform-or-architecture" if not (os_name == "linux" and arch == "x64" and node_resource is not None) else
            "insufficient-disk-space" if not enough_disk else
            "memory-status-unavailable" if memory_available is None else "insufficient-memory"
        ),
        next_action="install" if ready else (
            "choose a dedicated, non-symlink PZ_DSH_ROOT" if not root_safe else
            "use supported Linux x64 host with at least 512 MiB free and 2 GiB available memory"
        ),
        platform=os_name, architecture=arch, nodeVersion=pins["node"]["version"],
        nodeArchive=node_resource.get("url", "") if node_resource else "",
        nodeSha256=node_resource.get("sha256", "") if node_resource else "",
        packageIntegrity=pins["harness"]["integrity"], registry=pins["harness"]["registry"],
        freeBytes=free, requiredFreeBytes=MIN_FREE_BYTES,
        availableMemoryBytes=memory_available, requiredMemoryBytes=MIN_AVAILABLE_MEMORY_BYTES,
        memoryBudget="sufficient" if enough_memory else "unknown" if memory_available is None else "insufficient",
        mutatesHost=False, startsRuntime=False,
    )


@contextlib.contextmanager
def _operation_lock() -> Iterator[None]:
    _private_dir(app_root())
    path = app_root() / "operation.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if os.name == "nt":
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            try:
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            except OSError:
                raise DshError("operation-busy", "Another Harness operation is active", "retry after it finishes") from None
        else:
            import fcntl
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise DshError("operation-busy", "Another Harness operation is active", "retry after it finishes") from None
        yield
    finally:
        with contextlib.suppress(Exception):
            if os.name == "nt":
                import msvcrt
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _download(url: str, target: Path, expected_sha256: str) -> None:
    digest = hashlib.sha256()
    request = urllib.request.Request(url, headers={"User-Agent": "PhaseZero-DeepSeek-Harness/1"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response, target.open("xb") as out:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                digest.update(chunk)
            out.flush()
            os.fsync(out.fileno())
    except (OSError, urllib.error.URLError, TimeoutError) as exc:
        target.unlink(missing_ok=True)
        raise DshError("download-failed", f"Node download failed ({type(exc).__name__})", "check network and retry") from None
    if not hmac.compare_digest(digest.hexdigest(), expected_sha256.lower()):
        target.unlink(missing_ok=True)
        raise DshError("integrity-mismatch", "Node archive SHA-256 does not match committed pin", "keep current runtime; retry only after pin review")


def _safe_extract(archive: Path, target: Path) -> None:
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                path = PurePosixPath(info.filename)
                mode = info.external_attr >> 16
                if path.is_absolute() or ".." in path.parts or (mode & 0o170000) == 0o120000:
                    raise DshError("archive-path-unsafe", "Node archive contains an unsafe path entry")
            zf.extractall(target)
        return
    try:
        with tarfile.open(archive, "r:xz") as tf:
            for member in tf.getmembers():
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise DshError("archive-path-unsafe", "Node archive contains an unsafe path entry")
                if member.isdev() or member.isfifo():
                    raise DshError("archive-entry-unsafe", "Node archive contains a device or FIFO")
                if member.issym() or member.islnk():
                    link = member.linkname if member.islnk() else posixpath.join(posixpath.dirname(member.name), member.linkname)
                    normalized = posixpath.normpath(link)
                    top = PurePosixPath(member.name).parts[0]
                    if normalized.startswith("../") or normalized == ".." or normalized.split("/", 1)[0] != top:
                        raise DshError("archive-link-unsafe", "Node archive contains an unsafe symbolic link")
            tf.extractall(target)
    except (OSError, tarfile.TarError) as exc:
        raise DshError("archive-invalid", f"Node archive could not be extracted ({type(exc).__name__})") from None


def _flatten_node(extracted: Path, destination: Path, os_name: str) -> None:
    candidates = [path for path in extracted.iterdir() if path.is_dir()]
    if len(candidates) != 1:
        raise DshError("node-archive-layout", "Node archive has unexpected top-level layout")
    shutil.move(str(candidates[0]), str(destination))
    node = destination / ("node.exe" if os_name == "windows" else "bin/node")
    if not node.is_file():
        raise DshError("node-archive-invalid", "Node executable is missing from verified archive")
    if os_name != "windows":
        node.chmod(node.stat().st_mode | 0o111)


def _run_checked(args: list[str], *, cwd: Path, env: dict[str, str], timeout: int) -> str:
    try:
        completed = subprocess.run(
            args, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
            check=False, text=True, encoding="utf-8", errors="replace",
        )
    except subprocess.TimeoutExpired:
        raise DshError("dependency-timeout", "Pinned dependency preparation timed out", "retry after checking registry and host load") from None
    except OSError as exc:
        raise DshError("dependency-launch-failed", f"Pinned dependency tool could not start ({type(exc).__name__})") from None
    if completed.returncode != 0:
        # Do not expose registry error bodies: they can include private URLs or tokens.
        tail = (completed.stderr or completed.stdout).splitlines()[-1:] or ["dependency command failed"]
        line = TOKEN_QUERY.sub(r"\1[redacted]", tail[0])
        raise DshError("dependency-failed", f"Pinned dependency preparation failed: {line[:180]}", "check registry availability; previous runtime remains active")
    return completed.stdout.strip()


def install(*, update: bool = False) -> dict[str, Any]:
    pins = _read_pins()
    os_name, arch = _host_support()
    node_resource = _resource(pins, os_name, arch)
    if os_name != "linux" or arch != "x64" or node_resource is None:
        raise DshError("unsupported-platform", "Linux x64 is the only platform handled by this manager", "use the Windows PowerShell manager on Windows")
    plan = plan_payload()
    if not plan["ok"]:
        raise DshError(str(plan["reason"]), "Install plan is blocked", str(plan["nextAction"]))
    with _operation_lock():
        if _pid_alive(_supervisor_state().get("pid")):
            raise DshError("runtime-running", "Stop Harness before replacing its runtime", "stop")
        current_version, _runtime, _active = _version_status()
        if current_version == "installed" and not update:
            return status_payload("install")
        _private_dir(install_root())
        staging = install_root() / f".stage-{uuid.uuid4().hex}"
        stage_node, stage_app = staging / "node", staging / "app"
        _private_dir(staging)
        try:
            archive = staging / Path(urllib.parse.urlparse(node_resource["url"]).path).name
            _download(node_resource["url"], archive, node_resource["sha256"])
            extracted = staging / "extract"
            _private_dir(extracted)
            _safe_extract(archive, extracted)
            _flatten_node(extracted, stage_node, os_name)
            archive.unlink(missing_ok=True)
            shutil.rmtree(extracted, ignore_errors=True)
            stage_app.mkdir(mode=0o700)
            shutil.copy2(PACKAGE_DIR / "package.json", stage_app / "package.json")
            shutil.copy2(PACKAGE_DIR / "package-lock.json", stage_app / "package-lock.json")
            npm_userconfig = staging / "npm-userconfig"
            npm_globalconfig = staging / "npm-globalconfig"
            npm_userconfig.touch(mode=0o600)
            npm_globalconfig.touch(mode=0o600)
            node, npm, _ = _runtime_paths(staging)
            env = os.environ.copy()
            for name in tuple(env):
                if SENSITIVE_ENV.search(name) or name.upper().startswith("DEEPSEEK_") or UNTRUSTED_NODE_ENV.search(name):
                    env.pop(name, None)
            env.update({
                "PATH": str(node.parent) + os.pathsep + env.get("PATH", ""),
                "npm_config_cache": str(staging / "npm-cache"),
                "npm_config_update_notifier": "false",
                "npm_config_audit": "false",
                "npm_config_fund": "false",
                "CI": "1",
            })
            _run_checked([str(node), "--version"], cwd=staging, env=env, timeout=20)
            _run_checked([
                str(npm), "ci", "--ignore-scripts", "--no-audit", "--no-fund",
                "--userconfig", str(npm_userconfig), "--globalconfig", str(npm_globalconfig),
                "--registry", "https://registry.npmjs.org",
            ], cwd=stage_app, env=env, timeout=900)
            # Upstream's own pnpm allowBuilds list grants build hooks only to
            # these three locked packages. Reproduce that narrow allowlist with
            # npm; all other lifecycle scripts remain disabled.
            _run_checked([
                str(npm), "rebuild", "--foreground-scripts", "--no-audit", "--no-fund",
                "--userconfig", str(npm_userconfig), "--globalconfig", str(npm_globalconfig),
                "--registry", "https://registry.npmjs.org", "node-pty", "koffi",
                "@deepseek-ai/dsh-subprocess-local",
            ], cwd=stage_app, env=env, timeout=600)
            lock = json.loads((stage_app / "package-lock.json").read_text(encoding="utf-8"))
            dsh = lock.get("packages", {}).get("node_modules/@deepseek-ai/dsh", {})
            if dsh.get("version") != pins["harness"]["version"] or dsh.get("integrity") != pins["harness"]["integrity"]:
                raise DshError("package-integrity-mismatch", "Installed lock entry diverges from committed npm integrity", "keep current runtime; review package pin")
            entry = stage_app / "node_modules/@deepseek-ai/dsh/package.json"
            metadata = json.loads(entry.read_text(encoding="utf-8"))
            if metadata.get("version") != pins["harness"]["version"] or metadata.get("license") != "MIT":
                raise DshError("package-metadata-mismatch", "Installed package version or license differs from reviewed pin")
            final_name = f"dsh-{pins['harness']['version']}-{uuid.uuid4().hex[:8]}"
            final = install_root() / final_name
            os.replace(staging, final)
            previous = _load_json(active_file(), {})
            active = {
                "schemaVersion": 1, "version": pins["harness"]["version"],
                "nodeVersion": pins["node"]["version"], "runtimePath": final_name,
                "installedAt": utc_now(), "sourceCommit": pins["harness"]["commit"],
            }
            try:
                _atomic_json(active_file(), active)
            except Exception:
                # The previous active pointer remains byte-for-byte intact when
                # atomic replace fails; the newly staged tree is unreferenced.
                if previous:
                    raise DshError("activation-failed", "Runtime could not be activated; prior version remains selected", "retry install") from None
                shutil.rmtree(final, ignore_errors=True)
                raise DshError("activation-failed", "Runtime could not be activated", "retry install") from None
            return status_payload("update" if update else "install")
        except Exception:
            shutil.rmtree(staging, ignore_errors=True)
            raise


def _workspace_path(raw: str) -> Path:
    if not raw:
        raise DshError("workspace-required", "Choose a workspace folder before starting Harness", "select a folder and retry")
    try:
        workspace = Path(raw).expanduser().resolve(strict=True)
    except OSError:
        raise DshError("workspace-unavailable", "Selected workspace folder does not exist", "choose an existing folder") from None
    if not workspace.is_dir():
        raise DshError("workspace-not-directory", "Selected workspace is not a folder", "choose an existing folder")
    return workspace


def _dsh_command(runtime: Path, port: int) -> list[str]:
    node, _npm, dsh = _runtime_paths(runtime)
    if not node.is_file() or not dsh.is_file():
        raise DshError("runtime-incomplete", "Pinned Node or Harness executable is missing", "run doctor, then reinstall")
    return [str(node), str(dsh), "--profile", "web", "--host", "127.0.0.1", "--port", str(port), "--no-open"]


def start(workspace_raw: str, route: str) -> dict[str, Any]:
    if route not in {"account", "api"}:
        raise DshError("auth-route-required", "Select exactly one route: account or api", "choose an auth route explicitly")
    workspace = _workspace_path(workspace_raw)
    status, runtime, _ = _version_status()
    if status != "installed" or runtime is None:
        raise DshError("runtime-not-installed", "Pinned Harness runtime is not installed", "install")
    port = _port()
    with _operation_lock():
        live = _supervisor_state()
        if _pid_alive(live.get("pid")):
            healthy, _http = _probe_http(port)
            if healthy:
                current = _load_json(state_file(), {})
                if (
                    isinstance(current, dict)
                    and current.get("authRoute") == route
                    and current.get("requestedWorkspace") == str(workspace)
                ):
                    return status_payload("start")
                raise DshError(
                    "different-route-running",
                    "Harness already runs with another route or requested workspace; PhaseZero will not switch it silently",
                    "stop, then choose the intended route and folder",
                )
            raise DshError("start-already-running", "Harness supervisor already owns this runtime but health is not ready", "doctor or stop")
        memory_available = _available_memory_bytes()
        if memory_available is None:
            raise DshError("memory-status-unavailable", "Available memory could not be measured; Harness will not start", "doctor; verify system memory")
        if memory_available < MIN_AVAILABLE_MEMORY_BYTES:
            raise DshError("insufficient-memory", "Harness start requires at least 2 GiB available memory", "close workloads or retry when memory is available")
        if _port_in_use(port):
            raise DshError("port-occupied", f"Loopback port {port} is occupied by another process", "select another PZ_DSH_PORT or stop its owner")
        launch_dir = homes_root() / route / "launch"
        _private_dir(launch_dir)
        saved = _load_json(state_file(), {})
        saved = saved if isinstance(saved, dict) else {}
        state = {
            "schemaVersion": 1, "requestedWorkspace": str(workspace),
            "workspace": "", "workspaceSelection": "confirm in Harness Web UI",
            "authRoute": route,
            "state": "starting", "port": port, "profile": "web",
            "supervisorPid": None,
            "sandboxPolicy": "workspace-write + ask (requested)",
            "sandboxEnforcement": "unknown", "plugins": [], "updatedAt": utc_now(),
        }
        _atomic_json(state_file(), state)
        launcher_env = _base_environment(homes_root() / route)
        args = [sys.executable, str(Path(__file__).resolve()), "_supervise", str(launch_dir), route, str(port), str(runtime), str(workspace)]
        log_path = log_file()
        _private_dir(log_path.parent)
        log_stream = log_path.open("a", encoding="utf-8")
        try:
            supervisor = subprocess.Popen(
                args, cwd=launch_dir, env=launcher_env, stdin=subprocess.DEVNULL,
                stdout=log_stream, stderr=log_stream,
                start_new_session=(os.name != "nt"), close_fds=True,
            )
        except OSError as exc:
            log_stream.close()
            raise DshError("supervisor-start-failed", f"Harness supervisor could not start ({type(exc).__name__})", "doctor") from None
        log_stream.close()
        # Supervisor writes its own control nonce after binding loopback. Keep
        # its PID separately to avoid racing that file and losing the nonce.
        state["supervisorPid"] = supervisor.pid
        _atomic_json(state_file(), state)
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if not _pid_alive(supervisor.pid):
            raise DshError("runtime-crashed", "Harness process exited before becoming healthy", "doctor; inspect redacted local log")
        ready, _ = _probe_http(port)
        info = _supervisor_state()
        if ready and info.get("ready") is True:
            return status_payload("start")
        time.sleep(0.25)
    _stop_supervisor(timeout=2)
    raise DshError("health-timeout", "Harness did not pass loopback health check before timeout", "doctor; inspect redacted local log")


def _redact_line(line: str) -> str:
    line = TOKEN_QUERY.sub(r"\1[redacted]", line)
    line = SECRET_ASSIGNMENT.sub(r"\1[redacted]", line)
    line = re.sub(r"(?i)\bBearer\s+\S+", "Bearer [redacted]", line)
    line = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}", "[redacted-api-key]", line)
    return line


def _startup_url(line: str, port: int) -> str | None:
    if "dsh web:" not in line.lower():
        return None
    match = re.search(r"https?://[^\s\"']+", line)
    if not match:
        return None
    raw = match.group(0).rstrip(".,;)")
    parsed = urllib.parse.urlsplit(raw)
    query = urllib.parse.parse_qs(parsed.query)
    host = parsed.hostname or ""
    if host not in {"127.0.0.1", "localhost", "::1"} or parsed.port != port:
        return None
    if not any(query.get(key) for key in ("token", "launchToken")):
        return None
    return raw


class _ControlServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True


def _supervise(launch_dir: Path, route: str, port: int, runtime: Path, requested_workspace: Path) -> int:
    root = app_root()
    lock_path = root / "supervisor.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    if os.name != "nt":
        import fcntl
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(lock_fd)
            return 3
    nonce = os.urandom(32).hex()
    launch_url: dict[str, str] = {"value": ""}
    base_url = f"http://127.0.0.1:{port}/"
    child: subprocess.Popen[str] | None = None
    stop_requested = threading.Event()
    ready = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/control" or self.client_address[0] not in {"127.0.0.1", "::1"}:
                self.send_error(404)
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 2048:
                    raise ValueError
                payload = json.loads(self.rfile.read(size).decode("utf-8"))
            except (ValueError, UnicodeError, json.JSONDecodeError):
                self._send({"ok": False, "code": "invalid-request", "reason": "Invalid control request"}, 400)
                return
            provided = payload.get("nonce") if isinstance(payload, dict) else None
            if not isinstance(provided, str) or not hmac.compare_digest(provided, nonce):
                self._send({"ok": False, "code": "unauthorized", "reason": "Control request denied"}, 403)
                return
            action = payload.get("action")
            if action == "status":
                self._send({"ok": True, "ready": ready.is_set(), "running": child is not None and child.poll() is None})
            elif action == "open":
                url = launch_url["value"] or base_url
                # The launch token stays in this process's memory; it never
                # enters state, status output, or the append-only log.
                if not webbrowser.open(url, new=2, autoraise=True):
                    self._send({"ok": False, "code": "browser-unavailable", "reason": "Could not hand the local URL to a browser"})
                    return
                launch_url["value"] = ""
                self._send({"ok": True, "opened": True})
            elif action == "stop":
                stop_requested.set()
                self._send({"ok": True, "stopping": True})
            else:
                self._send({"ok": False, "code": "unknown-action", "reason": "Unsupported control action"}, 400)

        def _send(self, payload: dict[str, Any], status: int = 200) -> None:
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            with contextlib.suppress(BrokenPipeError, OSError):
                self.wfile.write(data)

        def log_message(self, _format: str, *_args: Any) -> None:
            return

    server = _ControlServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, name="dsh-control", daemon=True)
    server_thread.start()
    _atomic_json(supervisor_file(), {
        "schemaVersion": 1, "pid": os.getpid(), "port": port,
        "controlPort": server.server_address[1], "controlNonce": nonce,
        "startedAt": utc_now(), "ready": False,
    })
    try:
        dsh_home = homes_root() / route
        env = _base_environment(dsh_home)
        argv = _dsh_command(runtime, port)
        child = subprocess.Popen(
            argv, cwd=launch_dir, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
            start_new_session=(os.name != "nt"), close_fds=True,
        )
        _atomic_json(state_file(), {
            "schemaVersion": 1, "requestedWorkspace": str(requested_workspace),
            "workspace": "", "workspaceSelection": "confirm in Harness Web UI",
            "authRoute": route,
            "state": "starting", "port": port, "profile": "web",
            "sandboxPolicy": "workspace-write + ask (requested)",
            "sandboxEnforcement": "unknown", "plugins": [], "updatedAt": utc_now(),
        })

        def collect_output() -> None:
            assert child is not None and child.stdout is not None
            try:
                for raw in child.stdout:
                    url = _startup_url(raw, port)
                    if url:
                        launch_url["value"] = url
                        ready.set()
                        info = _supervisor_state()
                        info["ready"] = True
                        _atomic_json(supervisor_file(), info)
                        state = _load_json(state_file(), {})
                        if isinstance(state, dict):
                            state["state"] = "running"
                            state["updatedAt"] = utc_now()
                            _atomic_json(state_file(), state)
                    with log_file().open("a", encoding="utf-8") as log:
                        log.write(_redact_line(raw))
                        log.flush()
            except (OSError, UnicodeError):
                pass

        reader = threading.Thread(target=collect_output, name="dsh-output", daemon=True)
        reader.start()
        while child.poll() is None and not stop_requested.wait(0.2):
            pass
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
        reader.join(timeout=1)
        state = _load_json(state_file(), {})
        if isinstance(state, dict):
            state["state"] = "stopped" if stop_requested.is_set() else "crashed"
            state["updatedAt"] = utc_now()
            _atomic_json(state_file(), state)
        return child.returncode or 0
    except Exception as exc:
        with log_file().open("a", encoding="utf-8") as log:
            log.write(f"PhaseZero supervisor error: {type(exc).__name__}\n")
        if child is not None and child.poll() is None:
            child.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                child.wait(timeout=3)
        state = _load_json(state_file(), {})
        if isinstance(state, dict):
            state["state"] = "failed"
            state["updatedAt"] = utc_now()
            _atomic_json(state_file(), state)
        return 1
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=1)
        with contextlib.suppress(OSError):
            lock_fd and os.close(lock_fd)


def _stop_supervisor(timeout: float = 5) -> dict[str, Any]:
    try:
        result = _control("stop", timeout=timeout)
    except DshError as exc:
        info = _supervisor_state()
        if not _pid_alive(info.get("pid")):
            record = supervisor_file()
            if record.is_file() and not record.is_symlink():
                record.unlink()
            saved = _load_json(state_file(), {})
            if isinstance(saved, dict) and saved.get("state") in {"starting", "running"}:
                saved["state"] = "stopped"
                saved["updatedAt"] = utc_now()
                _atomic_json(state_file(), saved)
            return {"ok": True, "state": "stopped", "reason": "stale supervisor state cleared"}
        raise exc
    deadline = time.monotonic() + timeout
    pid = _supervisor_state().get("pid")
    while time.monotonic() < deadline and _pid_alive(pid):
        time.sleep(0.1)
    if _pid_alive(pid):
        raise DshError("stop-timeout", "Harness supervisor did not exit after stop request", "doctor; retry stop")
    record = supervisor_file()
    if record.is_file() and not record.is_symlink():
        record.unlink()
    return result


def doctor_payload() -> dict[str, Any]:
    payload = status_payload("doctor")
    status, runtime, _active = _version_status()
    checks: list[dict[str, Any]] = []
    checks.append({"id": "pin-lock-sbom", "state": "ok" if (PACKAGE_DIR / "package-lock.json").is_file() and (PACKAGE_DIR / "sbom.cdx.json").is_file() else "missing"})
    checks.append({"id": "node-and-package", "state": "ok" if status == "installed" and runtime else status})
    process = _supervisor_state()
    healthy, http_status = _probe_http(_port())
    checks.append({"id": "loopback-runtime", "state": "healthy" if healthy and _pid_alive(process.get("pid")) else "stopped", "httpStatus": http_status})
    saved = _load_json(state_file(), {})
    workspace = saved.get("workspace") if isinstance(saved, dict) else ""
    checks.append({"id": "workspace", "state": "selected-and-present" if workspace and Path(workspace).is_dir() else "not-selected-or-unavailable"})
    checks.append({"id": "sandbox-enforcement", "state": "unknown", "reason": "no live sandbox probe has been run; file policy is not process or network isolation"})
    checks.append({"id": "account-session", "state": "unknown"})
    checks.append({"id": "api-validity-and-quota", "state": "unknown"})
    checks.append({"id": "proxy-and-9router", "state": "blocked", "reason": "request-bound grants are not available"})
    checks.append({"id": "autostart", "state": "disabled"})
    memory_available = _available_memory_bytes()
    memory_state = "unknown" if memory_available is None else "sufficient" if memory_available >= MIN_AVAILABLE_MEMORY_BYTES else "insufficient"
    checks.append({"id": "memory-budget", "state": memory_state, "availableBytes": memory_available, "requiredBytes": MIN_AVAILABLE_MEMORY_BYTES})
    ok = status == "installed" and all(item["state"] not in {"missing", "version-drift", "insufficient"} for item in checks)
    payload.update({
        "ok": ok, "state": "healthy" if ok else "degraded",
        "reason": "" if ok else "one or more local checks need attention",
        "nextAction": "review unknown security and account gates before using tools",
        "checks": checks, "logPath": str(log_file()),
        "availableMemoryBytes": memory_available, "requiredMemoryBytes": MIN_AVAILABLE_MEMORY_BYTES,
        "memoryBudget": memory_state,
    })
    return payload


def uninstall() -> dict[str, Any]:
    with _operation_lock():
        _stop_supervisor()
        root = app_root()
        runtime = install_root()
        if runtime.exists():
            resolved_root = root.resolve()
            resolved_runtime = runtime.resolve()
            if resolved_runtime.parent != resolved_root or runtime.is_symlink():
                raise DshError("unsafe-runtime-path", "Managed runtime path is not a direct, owned directory")
            shutil.rmtree(runtime)
        for path in (active_file(), supervisor_file(), state_file(), log_file(), root / "supervisor.lock"):
            try:
                if path.is_file() and not path.is_symlink():
                    path.unlink()
            except OSError:
                raise DshError("uninstall-incomplete", "A PhaseZero Harness state file could not be removed", "inspect DSH root; user DSH_HOME data was preserved") from None
        return _result(
            "uninstall", ok=True, state="removed", reason="runtime removed; DSH_HOME and workspace data preserved",
            next_action="install when needed", installed=False,
            preservedData=[str(homes_root() / "account"), str(homes_root() / "api")],
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="pz ai deepseek-harness")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "status", "install", "update", "open", "stop", "doctor", "uninstall"):
        item = sub.add_parser(name)
        item.add_argument("--json", action="store_true", help="emit stable JSON")
    start_parser = sub.add_parser("start")
    start_parser.add_argument("--workspace", required=True)
    start_parser.add_argument("--auth-route", required=True, choices=("account", "api"))
    start_parser.add_argument("--port", type=int, help="loopback port (default 3080; retained in local state)")
    start_parser.add_argument("--json", action="store_true")
    return parser


def _dispatch(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    if args.command == "plan":
        payload = plan_payload()
    elif args.command == "status":
        payload = status_payload()
    elif args.command == "doctor":
        payload = doctor_payload()
    elif args.command in {"install", "update"}:
        payload = install(update=args.command == "update")
    elif args.command == "start":
        if args.port is not None:
            if args.port < 1024 or args.port > 65535:
                raise DshError("invalid-port", "Port must be between 1024 and 65535", "choose a user-space loopback port")
            os.environ["PZ_DSH_PORT"] = str(args.port)
        payload = start(args.workspace, args.auth_route)
    elif args.command == "open":
        result = _control("open")
        payload = status_payload("open")
        payload.update({"opened": True, "reason": "authenticated local Web UI handoff requested", "nextAction": "use Open to return after login"})
    elif args.command == "stop":
        result = _stop_supervisor()
        payload = status_payload("stop")
        payload.update({"state": result.get("state", "stopped"), "reason": result.get("reason", "Harness runtime stopped"), "nextAction": "start when needed"})
    elif args.command == "uninstall":
        payload = uninstall()
    else:
        raise DshError("unknown-command", "Unsupported DeepSeek Harness operation")
    # Read-only plan/status commands are reports. Their JSON carries degraded
    # state; the process exit code signals whether the report was produced.
    if args.command in {"plan", "status"}:
        return payload, 0
    return payload, 0 if payload.get("ok") else 1


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    if argv and argv[0] == "_supervise":
        if len(argv) != 6:
            return 2
        launch_dir, route, port, runtime, requested_workspace = argv[1:]
        return _supervise(Path(launch_dir), route, int(port), Path(runtime), Path(requested_workspace))
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        payload, exit_code = _dispatch(args)
    except DshError as exc:
        payload = _result(
            args.command, ok=False, state="blocked", reason=exc.code,
            next_action=exc.next_action, error={"code": exc.code, "message": exc.reason},
        )
        exit_code = 2
    except KeyboardInterrupt:
        payload = _result(args.command, ok=False, state="cancelled", reason="cancelled", next_action="retry")
        exit_code = 130
    except Exception as exc:
        payload = _result(
            args.command, ok=False, state="error", reason="unexpected-error",
            next_action="doctor", error={"code": "unexpected-error", "message": type(exc).__name__},
        )
        exit_code = 2
    return _output(payload, exit_code)


if __name__ == "__main__":
    raise SystemExit(main())
