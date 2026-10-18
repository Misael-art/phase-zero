#!/usr/bin/env python3
"""Opt-in, experimental manager for the ChatGPT Web bridge used by Codex (PXA-010/011).

Two independent channels exist and this manager never conflates them:

* Inference: Codex -> local bridge -> the launcher's own ChatGPT Web session.
  ChatGPT account limits keep applying; no quota saving is promised.
* Local tools: MCP call -> outbound OpenAI tunnel -> local broker -> tools of
  the current Codex turn, still subject to task scope, sandbox and approvals.

Design rules enforced here, not only documented:

* Off by default. Every mutation needs a recorded opt-in.
* The upstream package is pinned by version, commit, size and SHA-256. A hash
  detects a changed file; it does not prove who published it. Upstream packages
  are not platform-signed.
* The AppImage is never executed. Hosts with an AppImage integration handler
  (binfmt) move the file and register a desktop entry on first execution, so
  the image is kept non-executable, unpacked with unsquashfs and the launcher
  binary is started directly, without ``--no-sandbox``.
* The launcher runs in a transient systemd user unit with a dedicated
  CODEX_HOME. The user's live Codex home is mounted read-only for that unit and
  personal browser profiles are inaccessible to it, so no cookie or profile
  import can happen. Sign-in is an explicit user action inside the launcher.
* The upstream launcher registers its own login autostart and, started that
  way, runs outside the unit with its default profile and a writable live Codex
  home. The autostart directory is read-only for the unit, the launcher's own
  setting is forced off, and any launcher found outside the unit blocks every
  mutation until `repair` stops it and quarantines the entry.
* `adopt-session` only relocates the launcher's own default profile (created
  when it ran outside the unit) into the managed directory. It never reads a
  personal browser and never copies cookie values.
* Route activation is separate from installation and is always compared with a
  backup. Disable restores the route first, then stops the launcher; removal
  refuses any other order.
* Local write, the upstream launcher's own autostart, automatic account
  switching, the live Codex route and catalog listing stay locked. No command in
  this file can unlock them.
* Starting at login is a separate opt-in (`autostart enable`). It installs a
  PhaseZero entry that goes through the same isolated unit and checks; it never
  re-enables the upstream launcher's own entry.
* Menu and desktop shortcuts are local files pointing at a stable wrapper; they
  open the dedicated profile only and never edit the user's own Codex entry.
* Local history reaches a Web model only as a bounded, redacted summary of one
  repository the user consented to. Codex profiles (live or dedicated) and the
  whole home directory are out of scope, and file contents are never included.
"""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import getpass
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable


SCHEMA_VERSION = 1
PRODUCT_ID = "codex-chatgpt-web"
UNIT_NAME = "pz-chatgpt-web-launcher.service"
DEFAULT_PORT = 17841

# Audited as text on 2026-10-12. Moving references such as /releases/latest are
# never resolved: changing this pin requires a new audit.
PIN: dict[str, Any] = {
    "repository": "miuuyy/codex-chatgpt-web",
    "version": "6.1.8",
    "tag": "v6.1.8",
    "tagObject": "09af1a06b2bde862ec41d3ca01b0a7577a14fa56",
    "commit": "7cc8b8d8aadbbf729bd2bd43ca47fa15ea9965c0",
    "checksumsSha256": "703cce52455053666f8ac9b16fb9e3bbf6cc5e5cd414e1c3ef19a943bffb8c8a",
    "auditedAt": "2026-10-12",
    "platformSigned": False,
    "assets": {
        "linux-x86_64": {
            "name": "codex-web-gpt-6.1.8-linux-x64.AppImage",
            "size": 186153944,
            "sha256": "b334c762098b15f7745e156932858a96de2abc21fe4dd86764c122300e431938",
        },
        # Recorded for the future Windows adapter; this manager is Linux-only.
        "windows-x86_64": {
            "name": "codex-web-gpt-6.1.8-win-x64.exe",
            "size": 150965610,
            "sha256": "18743bfb6b3e200bf36823a57e1d9d58b17a99fed16dd8701b03a49801d113d1",
        },
    },
}

# Capabilities that stay off until real-account, clean-host (Arch and Windows),
# permission, failure and rollback gates are proven outside this code.
LOCKED_CAPABILITIES: dict[str, str] = {
    "local-write": "Codex roda em sandbox read-only neste perfil; escrita local segue bloqueada.",
    "upstream-autostart": "O autostart do próprio launcher fica bloqueado; iniciar no login "
                          "só pelo opt-in `autostart enable`, sempre pelo unit isolado.",
    "account-auto-switch": "Não há troca automática de conta ou modelo.",
    "live-codex-route": "A rota do Codex do usuário (~/.codex) nunca é alterada; só o perfil dedicado.",
    "catalog-listing": "A integração permanece fora do catálogo público.",
    "auto-approve-tool-calls": "Aprovação automática de ferramentas é recusada.",
}
# Observed on the pinned 6.1.8 runtime with a real tunnel and connector:
# its Full resolver needs network access inside the Codex turn, while this
# profile deliberately uses the read-only sandbox. The upstream doctor only
# checks infrastructure; it cannot certify a working tool turn.
FULL_RUNTIME_BLOCKER = (
    f"Full {PIN['version']} falha no turno real: o upstream exige acesso de rede no contexto "
    "Codex, indisponível no sandbox read-only deste perfil"
)
FULL_RUNTIME_ACTION = (
    "Mantenha browser-only. Adaptar o transporte Full sem ampliar o sandbox; "
    "depois provar uma chamada MCP real, aprovação por tarefa e rollback."
)
PENDING_GATES = (
    "real-account",
    "clean-host-arch",
    "clean-host-windows",
    "permissions",
    "failure-injection",
    "rollback",
)

# The older Developer Mode article described Pro as read/fetch-only. Current
# custom MCP plugin documentation explicitly includes write tools, subject to
# account/workspace permissions. A plan label alone never verifies those grants.
PLAN_MCP_CAPABILITY = {
    "free": "none",
    "go": "none",
    "plus": "none",
    "pro": "write-unverified",
    "business": "write-beta",
    "enterprise": "write-beta",
    "edu": "write-beta",
}
PLAN_LABELS = {"free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "business": "Business",
               "enterprise": "Enterprise", "edu": "Edu"}
PLAN_SOURCE = "https://developers.openai.com/api/docs/guides/custom-mcp-server"
ELIGIBILITY_MAX_AGE_DAYS = 30
KEY_ROTATION_DEFAULT_DAYS = 30
KEY_ROTATION_MAX_DAYS = 90

MANAGED_ROUTE_KEYS = (
    "openai_base_url",
    "experimental_realtime_webrtc_call_base_url",
    "multi_agent",
    "multi_agent_v2",
    "max_depth",
)
# How upstream words every refusal to edit a config it no longer recognises.
UPSTREAM_REFUSAL = "refusing to overwrite"
OWNED_CONFIG_HEADER = "# PhaseZero: perfil dedicado ChatGPT Web (experimental)."
# Codex 0.162 rejects `untrusted` outright; `on-request` under a read-only
# sandbox is the strictest policy it still accepts.
APPROVAL_POLICY = "on-request"
LEGACY_APPROVAL_LINE = 'approval_policy = "untrusted"'
APPROVAL_LINE = f'approval_policy = "{APPROVAL_POLICY}"'
OWNED_CONFIG = (
    f"{OWNED_CONFIG_HEADER}\n"
    'sandbox_mode = "read-only"\n'
    f"{APPROVAL_LINE}\n"
)
FORBIDDEN_CODEX_ARGS = (
    "-s", "--sandbox", "-a", "--ask-for-approval", "--full-auto", "--yolo",
    "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
    "--approve-for-me",
)
FORBIDDEN_CODEX_OVERRIDES = re.compile(
    r"^\s*(sandbox_mode|sandbox_permissions|sandbox_workspace_write|approval_policy|"
    r"openai_base_url|model_provider|model_providers)\b"
)
# Keys that would move the dedicated profile off the read-only, loopback-only contract.
FORBIDDEN_PROFILE_KEYS = ("model_provider", "model_providers", "sandbox_workspace_write",
                          "sandbox_permissions", "chatgpt_base_url", "profile", "profiles")
PERMISSIONLESS_FS = {"fuseblk", "vfat", "exfat", "msdos", "ntfs", "ntfs3", "9p", "cifs"}
PERSONAL_BROWSER_DIRS = (
    ".mozilla", ".config/google-chrome", ".config/chromium", ".config/BraveSoftware",
    ".config/microsoft-edge", ".config/vivaldi", ".config/opera", ".config/thorium",
    ".librewolf", ".zen", ".var/app",
)
DISK_MARGIN_BYTES = 1024 * 1024 * 1024
LAUNCHER_BINARY = "codex-web-gpt-launcher"
LAUNCH_SETTLE_SECONDS = 8
# Written by the upstream launcher itself ("Launch at login", on by default).
UPSTREAM_AUTOSTART_ENTRY = "dev.codexwebgpt.launcher.desktop"
# PhaseZero's own opt-in entry. It runs this manager, never the launcher directly.
MANAGED_AUTOSTART_ENTRY = "phasezero-chatgpt-web.desktop"
# Defaults the launcher falls back to when started without the managed env.
UPSTREAM_DEFAULT_PROFILE = ".config/Codex Web GPT"
UPSTREAM_DEFAULT_CORE = ".codex-chatgpt-web"
SESSION_COOKIE_DB = "Partitions/codex-web-gpt-chatgpt/Cookies"
PROFILE_RUNTIME_LEFTOVERS = ("SingletonLock", "SingletonCookie", "SingletonSocket",
                             "DevToolsActivePort")
DESCRIPTOR_WAIT_SECONDS = 60
DAEMON_WAIT_SECONDS = 90
LOGIN_WAIT_SECONDS = 300
DESKTOP_COMMAND = "codex-desktop"
NOTIFY_TITLE = "ChatGPT Web no Codex"
SMOKE_TOKEN = "PONG"
# Local shortcuts (menu + desktop). Never listed in the public catalog.
SHORTCUT_ENTRIES = {"web": "phasezero-chatgpt-web.desktop",
                    "tools": "phasezero-chatgpt-web-tools.desktop"}
WEB_MODEL_PREFIX = "chatgpt-web/"
# Consented, read-only summary of one repository's history. File contents never
# leave by default: only branch, commit subjects, changed paths and line counts.
HISTORY_CONSENT_MAX_AGE_DAYS = 30
HISTORY_DEFAULT_COMMITS = 30
HISTORY_MAX_COMMITS = 100
HISTORY_MAX_SECTION_LINES = 80
HISTORY_MAX_BYTES = 40_000
HISTORY_QUESTION_MAX_CHARS = 4_000
SECRET_LIKE = re.compile(
    r"sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"
    r"|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}"
    r"|eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{10,}[A-Za-z0-9._-]*"
    r"|\b[A-Fa-f0-9]{40,}\b|[A-Za-z0-9+/_-]{48,}={0,2}")
ASK_TIMEOUT_SECONDS = 420
SMOKE_TIMEOUT_SECONDS = 420

WARNINGS = (
    "Automação não oficial do ChatGPT Web; mudanças na interface podem quebrar a integração.",
    "Os limites da conta ChatGPT continuam valendo. O túnel MCP não transporta inferência "
    "e não garante economia de cota.",
    "O medidor do launcher é estimativa local das mensagens que ele enviou; não é saldo, "
    "reset nem cota oficial.",
    "Pacotes upstream não têm assinatura de plataforma. O SHA-256 fixado detecta alteração "
    "do arquivo; não comprova quem o publicou. Nunca ignore avisos do sistema operacional.",
    "O endpoint loopback do bridge é alcançável por qualquer processo do mesmo usuário. "
    "Use somente em conta local individual, sem código não confiável em execução.",
    "Login no ChatGPT acontece apenas dentro do launcher, por sua ação. Nenhum cookie, "
    "perfil ou sessão de outro navegador é lido ou importado.",
)


class BridgeError(RuntimeError):
    """Operation refused or failed; message is safe to show."""

    def __init__(self, message: str, code: str = "blocked") -> None:
        super().__init__(message)
        self.code = code


def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso(value: dt.datetime | None = None) -> str:
    return (value or now()).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_iso(value: object) -> dt.datetime | None:
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def squashfs_offset(image: Path) -> int:
    """Offset of the squashfs payload: end of the ELF section header table."""
    with image.open("rb") as handle:
        header = handle.read(64)
    if len(header) < 64 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1:
        raise BridgeError("pacote não é ELF64 little-endian esperado", "package-format")
    section_offset = struct.unpack_from("<Q", header, 0x28)[0]
    entry_size, entry_count = struct.unpack_from("<HH", header, 0x3A)
    return section_offset + entry_size * entry_count


def tree_digest(root: Path) -> dict[str, Any]:
    """Stable digest of every path, type and content under ``root``."""
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            digest.update(f"L\0{relative}\0{os.readlink(path)}\0".encode())
        elif path.is_file():
            digest.update(f"F\0{relative}\0{sha256_file(path)}\0".encode())
            count += 1
        else:
            digest.update(f"D\0{relative}\0".encode())
    return {"sha256": digest.hexdigest(), "files": count}


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def mount_fs_type(path: Path) -> str:
    """Filesystem type of the mount containing ``path`` (longest prefix)."""
    target = str(path.resolve())
    best = ("", "unknown")
    try:
        lines = Path("/proc/self/mountinfo").read_text(encoding="utf-8").splitlines()
    except OSError:
        return "unknown"
    for line in lines:
        left, _, right = line.partition(" - ")
        fields = left.split()
        if len(fields) < 5 or not right:
            continue
        mount_point = fields[4].replace("\\040", " ")
        if target == mount_point or target.startswith(mount_point.rstrip("/") + "/"):
            if len(mount_point) >= len(best[0]):
                best = (mount_point, right.split()[0])
    return best[1]


def enforces_permissions(directory: Path) -> bool:
    """True only when the filesystem really applies owner-only modes."""
    if mount_fs_type(directory) in PERMISSIONLESS_FS:
        return False
    try:
        fd, probe = tempfile.mkstemp(prefix=".pz-perm-", dir=directory)
    except OSError:
        return False
    try:
        os.close(fd)
        os.chmod(probe, 0o600)
        info = os.stat(probe)
        return (info.st_mode & 0o777) == 0o600 and info.st_uid == os.getuid()
    finally:
        os.unlink(probe)


def load_sibling(name: str) -> Any:
    path = Path(__file__).resolve().with_name(f"{name}.py")
    spec = importlib.util.spec_from_file_location(f"pz_{name}", path)
    if not spec or not spec.loader:
        raise BridgeError(f"módulo {name} indisponível", "internal")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Runner:
    """Process seam; tests replace it, production uses real commands."""

    session_dir = Path("/run/systemd/sessions")

    def run(self, args: list[str], *, env: dict[str, str] | None = None,
            timeout: int = 30, input_text: str | None = None) -> tuple[int, str, str]:
        try:
            done = subprocess.run(
                args, env=env, timeout=timeout, input=input_text,
                capture_output=True, text=True, check=False,
            )
        except FileNotFoundError:
            return 127, "", f"{args[0]}: comando ausente"
        except subprocess.TimeoutExpired:
            return 124, "", f"{args[0]}: tempo esgotado"
        return done.returncode, done.stdout, done.stderr

    def exec(self, args: list[str], env: dict[str, str]) -> int:
        os.execvpe(args[0], args, env)
        return 127

    def download(self, url: str, target: Path, expected_size: int) -> None:
        request = urllib.request.Request(url, headers={"User-Agent": "PhaseZero"})
        with urllib.request.urlopen(request, timeout=60) as response, target.open("wb") as out:
            received = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                received += len(chunk)
                if received > expected_size:
                    raise BridgeError("download maior que o tamanho fixado", "size-mismatch")
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())

    def spawn(self, args: list[str], env: dict[str, str]) -> int:
        """Start a detached GUI process; returns its PID."""
        process = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        return process.pid

    def notify(self, title: str, body: str, critical: bool = False) -> bool:
        """Desktop notification (KDE shows it in the alerts tray). Best effort."""
        code, _, _ = self.run(
            ["notify-send", "--app-name=PhaseZero", "--icon=dialog-information",
             f"--urgency={'critical' if critical else 'normal'}", "--expire-time=30000",
             title, body], timeout=5)
        return code == 0

    def port_in_use(self, port: int) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            return probe.connect_ex(("127.0.0.1", port)) == 0

    def other_users(self) -> list[str]:
        if not hasattr(os, "getuid"):
            return ["unknown"]
        code, out, _ = self.run(["loginctl", "list-users", "--no-legend"], timeout=5)
        own_uid = os.getuid()
        if code == 0:
            rows = [line.split() for line in out.splitlines() if line.strip()]
            if rows and all(row and row[0].isdigit() for row in rows):
                uids = {int(row[0]) for row in rows}
                if own_uid in uids:
                    return [self.uid_label(uid) for uid in sorted(uids - {own_uid})]
        # logind's D-Bus query can fail inside an otherwise working Codex turn.
        # Read its runtime session records as a second source; unknown remains
        # fail-closed if records are absent or cannot be parsed completely.
        try:
            entries = [path for path in self.session_dir.iterdir() if path.is_file()]
            if not entries:
                return ["unknown"]
            uids = set()
            for path in entries:
                match = re.search(r"(?m)^UID=(\d+)$", path.read_text(encoding="utf-8"))
                if match is None:
                    return ["unknown"]
                uids.add(int(match.group(1)))
            if own_uid not in uids:
                return ["unknown"]
            return [self.uid_label(uid) for uid in sorted(uids - {own_uid})]
        except OSError:
            return ["unknown"]

    @staticmethod
    def uid_label(uid: int) -> str:
        try:
            import pwd
            return pwd.getpwuid(uid).pw_name
        except (ImportError, KeyError):
            return f"uid:{uid}"

    def launcher_processes(self, binary: Path, data_dir: Path,
                           readonly_path: Path) -> list[dict[str, Any]]:
        """This user's launcher main processes, flagged by whether they are isolated.

        Chromium moves itself into its own ``app-*.scope``, so the cgroup says
        nothing. Isolation is read from the process itself: the managed data
        directory in its environment and ``readonly_path`` mounted read-only in
        its mount namespace.
        """
        marker = f"CODEX_WEB_GPT_LAUNCHER_DATA_DIR={data_dir}".encode()
        found: list[dict[str, Any]] = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if entry.stat().st_uid != os.getuid() or Path(os.readlink(entry / "exe")) != binary:
                    continue
                arguments = (entry / "cmdline").read_bytes().split(b"\0")
                environ = (entry / "environ").read_bytes().split(b"\0")
                mounts = (entry / "mountinfo").read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if any(argument.startswith(b"--type=") for argument in arguments):
                continue
            sealed = any(len(fields) > 5 and fields[4] == str(readonly_path)
                         and "ro" in fields[5].split(",")
                         for fields in (line.split() for line in mounts.splitlines()))
            found.append({"pid": int(entry.name), "managed": marker in environ and sealed})
        return found

    def terminate(self, pid: int, timeout: float = 20.0) -> bool:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            return True
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not Path(f"/proc/{pid}").exists():
                return True
            time.sleep(0.25)
        return False

    def codex_processes(self, codex_home: Path) -> list[int]:
        """PIDs of this user's processes whose CODEX_HOME is the dedicated one."""
        needle = f"CODEX_HOME={codex_home}".encode()
        found: list[int] = []
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit() or int(entry.name) == os.getpid():
                continue
            try:
                if entry.stat().st_uid != os.getuid():
                    continue
                environ = (entry / "environ").read_bytes().split(b"\0")
                comm = (entry / "comm").read_text().strip()
            except OSError:
                continue
            # Exact name: the launcher ("codex-web-gpt-l") carries the same CODEX_HOME.
            if needle in environ and comm == "codex":
                found.append(int(entry.name))
        return found


class Paths:
    def __init__(self, env: dict[str, str]) -> None:
        home = Path(env.get("HOME") or Path.home())
        data = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
        self.home = home
        self.root = Path(env.get("PZ_CHATGPT_WEB_ROOT") or data / "phasezero/chatgpt-web")
        self.state = self.root / "state.json"
        self.packages = self.root / "packages" / PIN["version"]
        self.core_home = self.root / "core-home"
        self.launcher_data = self.root / "launcher-data"
        self.codex_home = self.root / "codex-home"
        self.codex_config = self.codex_home / "config.toml"
        self.journal = self.root / "journal"
        self.live_codex_home = Path(env.get("PZ_LIVE_CODEX_HOME") or home / ".codex")
        runtime = env.get("XDG_RUNTIME_DIR")
        self.runtime = Path(runtime) / "pz-chatgpt-web" if runtime else None

        self.app = self.packages / "app"
        config = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
        self.autostart_dir = config / "autostart"
        self.autostart_entry = self.autostart_dir / UPSTREAM_AUTOSTART_ENTRY
        self.managed_autostart = self.autostart_dir / MANAGED_AUTOSTART_ENTRY
        # Menu/login wrappers call a private manager snapshot. Neither target
        # may depend on the source worktree remaining mounted or present.
        self.autostart_bin = self.root / "bin"
        self.manager_dir = self.root / "manager"
        self.manager_script = self.manager_dir / "chatgpt_web_bridge.py"
        self.manager_secret_store = self.manager_dir / "secret_store.py"
        self.manager_windows_secret_store = self.manager_dir / "windows_credential_store.py"
        self.autostart_wrapper = self.autostart_bin / "chatgpt-web-autostart.sh"
        self.autostart_target = self.autostart_bin / "chatgpt-web-autostart.target"
        self.open_wrapper = self.autostart_bin / "chatgpt-web-open.sh"
        self.open_target = self.autostart_bin / "chatgpt-web-open.target"
        self.applications = data / "applications"
        self.user_dirs = config / "user-dirs.dirs"
        self.default_profile = home / UPSTREAM_DEFAULT_PROFILE
        self.default_core = home / UPSTREAM_DEFAULT_CORE
        self.descriptor = self.core_home / "runtime" / "launcher-browser.json"
        self.launcher_state = self.launcher_data / "launcher-state.json"

    def package(self, asset: dict[str, Any]) -> Path:
        return self.packages / asset["name"]


class Bridge:
    def __init__(self, env: dict[str, str] | None = None, runner: Runner | None = None,
                 secret_store: Any | None = None, clock: Callable[[], dt.datetime] = now) -> None:
        self.env = dict(os.environ if env is None else env)
        self.paths = Paths(self.env)
        self.runner = runner or Runner()
        self._secret_store = secret_store
        self.clock = clock
        self.settle_seconds = float(self.env.get("PZ_CHATGPT_WEB_SETTLE_SECONDS",
                                                 LAUNCH_SETTLE_SECONDS))
        self.poll_seconds = float(self.env.get("PZ_CHATGPT_WEB_POLL_SECONDS", 2))

    # ---- state -----------------------------------------------------------

    def load_state(self) -> dict[str, Any]:
        try:
            state = json.loads(self.paths.state.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {"schemaVersion": SCHEMA_VERSION}
        except (OSError, ValueError):
            raise BridgeError("state.json ilegível; nada foi alterado", "state-corrupt") from None
        if not isinstance(state, dict) or state.get("schemaVersion") != SCHEMA_VERSION:
            raise BridgeError("state.json com versão desconhecida", "state-corrupt")
        return state

    def save_state(self, state: dict[str, Any]) -> None:
        private_dir(self.paths.root)
        state["schemaVersion"] = SCHEMA_VERSION
        atomic_write(self.paths.state,
                     (json.dumps(state, indent=2, sort_keys=True) + "\n").encode())

    def require_opt_in(self, state: dict[str, Any]) -> None:
        if not state.get("optIn"):
            raise BridgeError(
                "Integração experimental desligada. Leia `plan` e rode `opt-in` com os "
                "reconhecimentos exigidos.", "opt-in-required")

    # ---- platform --------------------------------------------------------

    def platform_key(self) -> str:
        system = self.env.get("PZ_CHATGPT_WEB_SYSTEM") or platform.system()
        machine = self.env.get("PZ_CHATGPT_WEB_MACHINE") or platform.machine()
        return f"{system.lower()}-{machine.lower().replace('amd64', 'x86_64')}"

    def asset(self) -> dict[str, Any]:
        key = self.platform_key()
        if key != "linux-x86_64":
            raise BridgeError(f"plataforma {key} sem adaptador neste manager", "unsupported-platform")
        return PIN["assets"][key]

    def asset_url(self, asset: dict[str, Any]) -> str:
        return (f"https://github.com/{PIN['repository']}/releases/download/"
                f"{PIN['tag']}/{asset['name']}")

    def upstream_env(self) -> dict[str, str]:
        env = dict(self.env)
        env["CODEX_HOME"] = str(self.paths.codex_home)
        env["CODEX_CHATGPT_WEB_HOME"] = str(self.paths.core_home)
        env["CODEX_WEB_GPT_LAUNCHER_DATA_DIR"] = str(self.paths.launcher_data)
        for name in ("CODEX_WEB_GPT_DEV_HOME", "CODEX_WEB_GPT_VERSION", "CODEX_WEB_GPT_REPOSITORY"):
            env.pop(name, None)
        return env

    # ---- observation -----------------------------------------------------

    def package_state(self) -> dict[str, Any]:
        try:
            asset = self.asset()
        except BridgeError as error:
            return {"state": "unsupported", "detail": str(error)}
        path = self.paths.package(asset)
        if not path.exists():
            return {"state": "absent", "path": str(path)}
        if path.stat().st_size != asset["size"] or sha256_file(path) != asset["sha256"]:
            return {"state": "mismatch", "path": str(path)}
        return {"state": "verified", "path": str(path), "sha256": asset["sha256"],
                "unpacked": self.unpacked_state()}

    def unpacked_state(self) -> str:
        record = self.load_state().get("unpacked")
        binary = self.paths.app / LAUNCHER_BINARY
        if not isinstance(record, dict) or not binary.is_file():
            return "absent"
        return "verified" if tree_digest(self.paths.app) == record["tree"] else "mismatch"

    def launcher_active(self) -> bool:
        code, out, _ = self.runner.run(["systemctl", "--user", "is-active", UNIT_NAME], timeout=10)
        return code == 0 and out.strip() in {"active", "activating"}

    def upstream_config(self) -> dict[str, Any] | None:
        try:
            value = json.loads((self.paths.core_home / "config.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def runtime_command(self) -> list[str]:
        """Upstream CLI: the configured one, else the copy the launcher unpacked."""
        command = (self.upstream_config() or {}).get("runtimeCommand")
        if (not isinstance(command, list) or not command
                or not all(isinstance(part, str) and part for part in command)):
            bundled = (self.paths.core_home / "versions" / f"{PIN['version']}-linux-x64"
                       / "bin" / "codex-chatgpt-web")
            if not bundled.is_file():
                raise BridgeError(
                    "Runtime upstream ainda não disponível. Rode `setup` (ou `launch`) e "
                    "aguarde o launcher terminar de preparar o runtime.",
                    "upstream-not-configured")
            command = [str(bundled)]
        root = self.paths.root.resolve()
        if not Path(command[0]).resolve().is_relative_to(root):
            raise BridgeError("runtime upstream fora do diretório gerenciado", "upstream-escaped")
        return command

    def upstream_cli(self, args: list[str], timeout: int = 60) -> tuple[int, str, str]:
        """Run the upstream CLI with the same path restrictions as the launcher unit."""
        env = self.upstream_env()
        command = ["systemd-run", "--user", "--wait", "--collect", "--quiet", "--pipe"]
        for prop in self.hardening_properties():
            command += ["-p", prop]
        for name in ("CODEX_HOME", "CODEX_CHATGPT_WEB_HOME", "CODEX_WEB_GPT_LAUNCHER_DATA_DIR"):
            command.append(f"--setenv={name}={env[name]}")
        return self.runner.run(command + self.runtime_command() + args, env=env, timeout=timeout)

    # ---- isolation -------------------------------------------------------

    def stray_launchers(self) -> list[int]:
        return [item["pid"] for item in self.launcher_processes() if not item["managed"]]

    def launcher_processes(self) -> list[dict[str, Any]]:
        return self.runner.launcher_processes(self.paths.app / LAUNCHER_BINARY,
                                              self.paths.launcher_data, self.paths.autostart_dir)

    def session_present(self, profile: Path) -> bool | None:
        """Whether the launcher profile holds a ChatGPT session. Reads cookie names only."""
        source = profile / SESSION_COOKIE_DB
        if not source.is_file():
            return False
        try:
            with tempfile.TemporaryDirectory(prefix="pz-session-") as scratch:
                copy = Path(scratch) / "cookies"
                shutil.copyfile(source, copy)
                for suffix in ("-wal", "-journal"):
                    extra = source.with_name(source.name + suffix)
                    if extra.is_file():
                        shutil.copyfile(extra, copy.with_name(copy.name + suffix))
                connection = sqlite3.connect(copy)
                try:
                    row = connection.execute(
                        "SELECT COUNT(*) FROM cookies WHERE name LIKE '%session-token%'").fetchone()
                finally:
                    connection.close()
        except (OSError, sqlite3.Error):
            return None
        return bool(row and row[0])

    def isolation(self) -> dict[str, Any]:
        strays = self.stray_launchers()
        entry = self.paths.autostart_entry
        autostart = str(entry) if entry.exists() or entry.is_symlink() else None
        launcher_state = self._read_json(self.paths.launcher_state) or {}
        return {"ok": not strays and not autostart, "unmanagedLaunchers": strays,
                "upstreamAutostartEntry": autostart,
                "launcherAutostartSetting": bool(launcher_state.get("autoStart")),
                "defaultProfileSession": self.session_present(self.paths.default_profile),
                "defaultProfile": (str(self.paths.default_profile)
                                   if self.paths.default_profile.exists() else None)}

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any] | None:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def force_autostart_off(self, profile: Path) -> bool:
        """Turn the launcher's own "launch at login" off. Only while it is stopped."""
        target = profile / "launcher-state.json"
        current = self._read_json(target)
        if current is None:
            if target.exists():
                return False
            current = {"version": 1}
        if current.get("autoStart") is False:
            return False
        current["autoStart"] = False
        private_dir(profile)
        atomic_write(target, (json.dumps(current, indent=2) + "\n").encode())
        return True

    def repair(self) -> dict[str, Any]:
        """Stop launchers running outside the unit and quarantine the upstream autostart."""
        stopped: list[int] = []
        for pid in self.stray_launchers():
            if not self.runner.terminate(pid):
                raise BridgeError(f"launcher fora do isolamento (PID {pid}) não encerrou",
                                  "stray-launcher")
            stopped.append(pid)
        quarantined = None
        entry = self.paths.autostart_entry
        if entry.exists() or entry.is_symlink():
            private_dir(self.paths.root)
            private_dir(self.paths.journal)
            stamp = self.clock().strftime("%Y%m%dT%H%M%SZ")
            quarantined = self.paths.journal / f"quarantined-autostart-{stamp}.desktop"
            os.replace(entry, quarantined)
        settings = [str(profile) for profile in (self.paths.launcher_data,
                                                 self.paths.default_profile)
                    if profile.is_dir() and not self.launcher_active()
                    and self.force_autostart_off(profile)]
        return {"repaired": True, "stoppedLaunchers": stopped,
                "quarantinedAutostart": str(quarantined) if quarantined else None,
                "autostartSettingTurnedOff": settings,
                "liveCodexRouteTouched": self.live_route_touched(),
                "isolation": self.isolation()}

    def adopt_session(self) -> dict[str, Any]:
        """Move the launcher's own default profile into the managed directory."""
        state = self.load_state()
        self.require_opt_in(state)
        if self.launcher_active() or self.stray_launchers():
            raise BridgeError("launcher em execução; rode `disable`/`repair` antes de adotar a sessão",
                              "launcher-active")
        source = self.paths.default_profile
        if self.session_present(source) is not True:
            raise BridgeError("perfil padrão do launcher não tem sessão ChatGPT para adotar",
                              "no-session")
        if self.session_present(self.paths.launcher_data) is True:
            raise BridgeError("perfil gerenciado já tem sessão; nada foi movido", "already-signed-in")
        private_dir(self.paths.root)
        private_dir(self.paths.journal)
        previous = None
        if self.paths.launcher_data.exists():
            stamp = self.clock().strftime("%Y%m%dT%H%M%SZ")
            previous = self.paths.journal / f"launcher-data-pre-adopt-{stamp}"
            os.replace(self.paths.launcher_data, previous)
        shutil.move(str(source), str(self.paths.launcher_data))
        os.chmod(self.paths.launcher_data, 0o700)
        for leftover in PROFILE_RUNTIME_LEFTOVERS:
            (self.paths.launcher_data / leftover).unlink(missing_ok=True)
        self.force_autostart_off(self.paths.launcher_data)
        state["sessionAdopted"] = {"at": iso(self.clock()), "from": str(source),
                                   "previousProfile": str(previous) if previous else None}
        self.save_state(state)
        return {"adopted": True, "from": str(source), "to": str(self.paths.launcher_data),
                "previousProfile": str(previous) if previous else None,
                "leftover": (str(self.paths.default_core)
                             if self.paths.default_core.exists() else None),
                "note": "Sessão do próprio launcher realocada; nenhum navegador pessoal foi lido."}

    def route_status(self) -> dict[str, Any]:
        if not self.upstream_config():
            return {"installed": False, "active": False, "source": "no-upstream-config"}
        code, out, err = self.upstream_cli(["route", "status"])
        try:
            parsed = json.loads(out)
        except ValueError:
            parsed = None
        if code != 0 or not isinstance(parsed, dict):
            return {"installed": None, "active": None, "source": "upstream-error",
                    "detail": (err or out).strip()[:300]}
        errors = parsed.get("errors") or []
        result = {"installed": bool(parsed.get("installed")), "active": bool(parsed.get("active")),
                  "routeUrl": parsed.get("routeUrl"), "errors": errors, "source": "upstream"}
        if any(UPSTREAM_REFUSAL in str(error) for error in errors):
            result["desktopRewroteConfig"] = True
            result["hint"] = ("o Codex Desktop regravou a configuração do perfil dedicado e o "
                              "launcher não a reconhece mais. A rota segue funcionando; no "
                              "`disable` o gerenciador restaura o perfil por conta própria.")
        return result

    def live_route_touched(self) -> bool | None:
        """True when the user's own Codex config points at a loopback bridge."""
        try:
            text = (self.paths.live_codex_home / "config.toml").read_text(encoding="utf-8")
        except FileNotFoundError:
            return False
        except OSError:
            return None
        return bool(re.search(r"(?m)^\s*openai_base_url\s*=\s*[\"']http://127\.0\.0\.1:", text))

    def eligibility(self, state: dict[str, Any]) -> dict[str, Any]:
        record = state.get("eligibility")
        base = {"source": "operator-attestation", "verified": False}
        if not isinstance(record, dict):
            return {**base, "state": "unknown", "webModel": "unknown", "tools": "unknown",
                    "blockers": ["elegibilidade não registrada"]}
        recorded = parse_iso(record.get("recordedAt"))
        stale = (not recorded
                 or self.clock() - recorded > dt.timedelta(days=ELIGIBILITY_MAX_AGE_DAYS))
        plan_cap = PLAN_MCP_CAPABILITY.get(str(record.get("plan")), "none")
        blockers: list[str] = []
        if stale:
            blockers.append("atestado de elegibilidade vencido; registre de novo")
        if plan_cap == "none":
            blockers.append(
                f"o plano {PLAN_LABELS.get(str(record.get('plan')), 'informado')} não oferece MCP "
                "de desenvolvedor confirmado nesta integração; confira as permissões "
                "atuais da conta e do workspace")
        if record.get("developerMode") != "yes":
            blockers.append("Developer Mode do workspace não confirmado")
        if record.get("tunnelPermission") not in {"use", "manage"}:
            blockers.append("permissão Tunnels Read + Use não confirmada")
        if record.get("singleUserTrusted") != "yes":
            blockers.append("conta local individual e confiável não confirmada")
        tools = "none" if blockers else ("unverified" if plan_cap == "write-unverified"
                                          else "read-only-write-locked")
        return {**base, "state": "stale" if stale else "recorded", "plan": record.get("plan"),
                "recordedAt": record.get("recordedAt"), "planMcpCapability": plan_cap,
                "webModel": "requires-sign-in", "tools": tools, "blockers": blockers}

    def key_status(self, state: dict[str, Any]) -> dict[str, Any]:
        record = state.get("runtimeKey")
        if not isinstance(record, dict):
            return {"state": "absent"}
        rotate_by = parse_iso(record.get("rotateBy"))
        overdue = bool(rotate_by and self.clock() > rotate_by)
        staged = bool(self.paths.runtime and (self.paths.runtime / "runtime-key").exists())
        return {"state": "rotation-overdue" if overdue else "stored", "store": "os-secret-store",
                "storedAt": record.get("storedAt"), "rotateBy": record.get("rotateBy"),
                "staged": staged, "requiredPermission": "Tunnels Read + Use"}

    def preflight(self) -> dict[str, Any]:
        checks: list[dict[str, Any]] = []

        def add(check_id: str, ok: bool | None, detail: str) -> None:
            checks.append({"id": check_id,
                           "status": "ok" if ok else ("unknown" if ok is None else "blocked"),
                           "detail": detail})

        key = self.platform_key()
        add("platform", key == "linux-x86_64", key)
        parent = self.paths.root
        while not parent.exists():
            parent = parent.parent
        add("filesystem-permissions", enforces_permissions(parent),
            f"{mount_fs_type(parent)} em {parent}")
        try:
            free = shutil.disk_usage(parent).free
            need = PIN["assets"].get(key, {}).get("size", 0) * 2 + DISK_MARGIN_BYTES
            add("disk", free >= need, f"livre {free} bytes; necessário ~{need}")
        except OSError as error:
            add("disk", None, str(error))
        for tool in ("systemctl", "systemd-run", "unsquashfs"):
            add(f"tool-{tool}", shutil.which(tool, path=self.env.get("PATH")) is not None, tool)
        active = self.launcher_active()
        busy = self.runner.port_in_use(DEFAULT_PORT)
        add("port", active or not busy,
            f"127.0.0.1:{DEFAULT_PORT} " + ("em uso pelo launcher" if active and busy
                                            else "ocupada por outro processo" if busy else "livre"))
        others = self.runner.other_users()
        add("single-user-host", not others if others != ["unknown"] else None,
            "outros usuários com sessão: " + (", ".join(others) or "nenhum"))
        add("live-codex-route-untouched", self.live_route_touched() is False,
            str(self.paths.live_codex_home / "config.toml"))
        isolation = self.isolation()
        add("no-unmanaged-launcher", not isolation["unmanagedLaunchers"],
            "launcher fora do unit isolado: PIDs "
            + (", ".join(map(str, isolation["unmanagedLaunchers"])) or "nenhum")
            + ("; rode `repair`" if isolation["unmanagedLaunchers"] else ""))
        add("no-upstream-autostart", not isolation["upstreamAutostartEntry"],
            (isolation["upstreamAutostartEntry"] or "nenhuma entrada de autostart")
            + ("; rode `repair`" if isolation["upstreamAutostartEntry"] else ""))
        return {"checks": checks,
                "blocked": [c["id"] for c in checks if c["status"] == "blocked"]}

    def status(self) -> dict[str, Any]:
        state = self.load_state()
        config = self.upstream_config()
        mode = (config or {}).get("mode")
        route = self.route_status() if config else {"installed": False, "active": False}
        package = self.package_state()
        active = self.launcher_active()
        if not state.get("optIn"):
            stage = "off"
        elif package["state"] != "verified" or package["unpacked"] != "verified":
            stage = "opted-in"
        elif not config:
            stage = "package-verified"
        elif not route.get("active"):
            stage = "launcher-configured"
        else:
            stage = "web-model" if mode == "browser-only" else "tools-experimental"
        return {
            "product": PRODUCT_ID, "experimental": True, "optIn": bool(state.get("optIn")),
            "stage": stage, "pin": {k: PIN[k] for k in ("version", "tag", "commit", "auditedAt")},
            "package": package, "launcher": {"active": active, "unit": UNIT_NAME,
                                             "hardening": state.get("hardening")},
            "upstreamMode": mode,
            "autoApproveToolCalls": bool((config or {}).get("autoApproveToolCalls")),
            "route": route, "codexHome": str(self.paths.codex_home),
            "liveCodexRouteTouched": self.live_route_touched(),
            "isolation": self.isolation(),
            "signedIn": self.session_present(self.paths.launcher_data),
            "daemonListening": self.runner.port_in_use(DEFAULT_PORT),
            "eligibility": self.eligibility(state), "runtimeKey": self.key_status(state),
            "toolsGate": self.tools_steps() if state.get("optIn") else None,
            "lastSmoke": state.get("lastSmoke"), "autostart": self.autostart_status(),
            "lockedCapabilities": LOCKED_CAPABILITIES, "pendingGates": list(PENDING_GATES),
            "usageMeter": "local-estimate-not-official-quota",
        }

    def plan(self) -> dict[str, Any]:
        return {
            "product": PRODUCT_ID, "experimental": True, "pin": PIN,
            "channels": {
                "inference": "Codex -> bridge local -> sessão própria do ChatGPT Web",
                "localTools": "chamada MCP -> túnel de saída -> broker local -> ferramentas "
                              "do turno Codex (escopo, sandbox e aprovações)",
            },
            "modes": [
                {"id": "web-model", "tools": False, "offeredFirst": True,
                 "requires": ["opt-in", "pacote verificado e desempacotado",
                              "login no launcher"]},
                {"id": "tools-experimental", "tools": True, "offeredFirst": False,
                 "requires": ["web-model funcionando", "elegibilidade registrada",
                              "túnel e conector criados pelo operador", "chave Read + Use no cofre",
                              "broker verificado"],
                 "limits": ["sandbox read-only", "sem aprovação automática",
                            "sem Allow all actions"]},
            ],
            "warnings": list(WARNINGS), "lockedCapabilities": LOCKED_CAPABILITIES,
            "pendingGates": list(PENDING_GATES), "preflight": self.preflight(),
            "paths": {"root": str(self.paths.root), "codexHome": str(self.paths.codex_home)},
        }

    # ---- consent ---------------------------------------------------------

    def opt_in(self, acknowledged: set[str]) -> dict[str, Any]:
        required = {"experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"}
        missing = sorted(required - acknowledged)
        if missing:
            raise BridgeError("reconhecimentos ausentes: " + ", ".join(missing), "ack-missing")
        state = self.load_state()
        state["optIn"] = {"at": iso(self.clock()), "acknowledged": sorted(required)}
        self.save_state(state)
        return {"optIn": True}

    def opt_out(self) -> dict[str, Any]:
        state = self.load_state()
        if self.launcher_active() or self.route_status().get("active"):
            raise BridgeError("rode `disable` antes de `opt-out`", "still-enabled")
        self.autostart_disable()
        self.shortcuts_remove()
        state = self.load_state()
        state.pop("optIn", None)
        self.save_state(state)
        return {"optIn": False}

    def record_eligibility(self, plan: str, developer_mode: str, tunnel_permission: str,
                           single_user: str) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        state["eligibility"] = {
            "plan": plan, "developerMode": developer_mode, "tunnelPermission": tunnel_permission,
            "singleUserTrusted": single_user, "recordedAt": iso(self.clock()),
        }
        self.save_state(state)
        return self.eligibility(state)

    # ---- package ---------------------------------------------------------

    def fetch(self) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        asset = self.asset()
        if self.package_state()["state"] == "verified":
            return {"package": "verified", "downloaded": False}
        blocked = set(self.preflight()["blocked"]) & {"filesystem-permissions", "disk", "platform"}
        if blocked:
            raise BridgeError("preflight bloqueou: " + ", ".join(sorted(blocked)), "preflight")
        private_dir(self.paths.root)
        target = self.paths.package(asset)
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".part")
        try:
            self.runner.download(self.asset_url(asset), partial, asset["size"])
            size = partial.stat().st_size
            if size != asset["size"]:
                raise BridgeError(f"tamanho {size} difere do fixado {asset['size']}", "size-mismatch")
            digest = sha256_file(partial)
            if digest != asset["sha256"]:
                raise BridgeError("SHA-256 difere do valor fixado; arquivo descartado",
                                  "hash-mismatch")
            # No execute bit: an AppImage binfmt handler must never see this file run.
            os.chmod(partial, 0o400)
            os.replace(partial, target)
        except (OSError, urllib.error.URLError) as error:
            raise BridgeError(f"download falhou: {error}", "download-failed") from None
        finally:
            partial.unlink(missing_ok=True)
        return {"package": "verified", "downloaded": True, "sha256": asset["sha256"],
                "note": "hash confere com o pin; não comprova identidade do publicador"}

    def install(self) -> dict[str, Any]:
        """Unpack the verified image without executing it; no desktop entry, no autostart."""
        state = self.load_state()
        self.require_opt_in(state)
        package = self.package_state()
        if package["state"] != "verified":
            raise BridgeError("pacote ausente ou não confere com o pin; rode `fetch`",
                              "package-unverified")
        if self.launcher_active():
            raise BridgeError("launcher ativo; rode `disable` antes de reinstalar", "launcher-active")
        if package["unpacked"] == "verified":
            return {"install": "already-verified", "tree": state["unpacked"]["tree"]}
        image = Path(package["path"])
        staging = self.paths.packages / "app.next"
        shutil.rmtree(staging, ignore_errors=True)
        code, out, err = self.runner.run(
            ["unsquashfs", "-o", str(squashfs_offset(image)), "-q", "-n", "-no-xattrs",
             "-d", str(staging), str(image)], timeout=300)
        try:
            binary = staging / LAUNCHER_BINARY
            if code != 0 or not binary.is_file():
                raise BridgeError(f"desempacotamento falhou: {(err or out).strip()[:300]}",
                                  "unpack-failed")
            code, out, _ = self.runner.run(["ldd", str(binary)], timeout=30)
            missing = sorted({line.split()[0] for line in out.splitlines() if "not found" in line})
            if code != 0 or missing:
                raise BridgeError("bibliotecas ausentes no sistema: "
                                  + (", ".join(missing) or "ldd falhou"), "missing-libraries")
            shutil.rmtree(self.paths.app, ignore_errors=True)
            os.replace(staging, self.paths.app)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        state["unpacked"] = {"tree": tree_digest(self.paths.app), "at": iso(self.clock()),
                             "imageSha256": package["sha256"]}
        self.save_state(state)
        return {"install": "unpacked", "tree": state["unpacked"]["tree"], "desktopEntry": False,
                "autostart": False, "routeChanged": False}

    # ---- launcher --------------------------------------------------------

    def hardening_properties(self) -> list[str]:
        properties = [f"ReadOnlyPaths=-{self.paths.live_codex_home}",
                      f"ReadOnlyPaths=-{self.paths.autostart_dir}"]
        for relative in PERSONAL_BROWSER_DIRS:
            properties.append(f"InaccessiblePaths=-{self.paths.home / relative}")
        return properties

    def seed_codex_home(self) -> None:
        private_dir(self.paths.codex_home)
        if not self.paths.codex_config.exists():
            atomic_write(self.paths.codex_config, OWNED_CONFIG.encode())

    def migrate_owned_config(self, state: dict[str, Any]) -> bool:
        """Replace the approval policy Codex no longer accepts, in config and baseline alike."""
        current = self._config_text()
        if OWNED_CONFIG_HEADER not in current or LEGACY_APPROVAL_LINE not in current:
            return False
        atomic_write(self.paths.codex_config,
                     current.replace(LEGACY_APPROVAL_LINE, APPROVAL_LINE).encode())
        if isinstance(state.get("routeBaseline"), dict):
            baseline = self._baseline_text(state).replace(LEGACY_APPROVAL_LINE, APPROVAL_LINE)
            state.pop("routeBaseline")
            data = baseline.encode()
            backup = self.paths.journal / f"config-baseline-{sha256_bytes(data)[:16]}.toml"
            atomic_write(backup, data)
            state["routeBaseline"] = {"path": str(backup), "sha256": sha256_bytes(data),
                                      "at": iso(self.clock()), "migrated": "approval-policy"}
        self.save_state(state)
        return True

    def snapshot_baseline(self, state: dict[str, Any]) -> None:
        """Keep the pre-activation config so every later change can be compared."""
        if state.get("routeBaseline"):
            return
        data = self.paths.codex_config.read_bytes()
        private_dir(self.paths.journal)
        backup = self.paths.journal / f"config-baseline-{sha256_bytes(data)[:16]}.toml"
        atomic_write(backup, data)
        state["routeBaseline"] = {"path": str(backup), "sha256": sha256_bytes(data),
                                  "at": iso(self.clock())}

    def launch(self) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        package = self.package_state()
        if package["state"] != "verified":
            raise BridgeError("pacote ausente ou não confere com o pin; rode `fetch`",
                              "package-unverified")
        self.migrate_owned_config(state)
        if self.launcher_active():
            return {"launcher": "already-active", "unit": UNIT_NAME}
        if package["unpacked"] != "verified":
            raise BridgeError("launcher não instalado ou alterado após a verificação; rode `install`",
                              "install-unverified")
        blocked = self.preflight()["blocked"]
        if blocked:
            raise BridgeError("preflight bloqueou: " + ", ".join(blocked), "preflight")
        for directory in (self.paths.core_home, self.paths.launcher_data):
            private_dir(directory)
        self.seed_codex_home()
        self.snapshot_baseline(state)
        # The directory must exist to be mounted read-only; otherwise the
        # launcher could create it and register itself.
        self.paths.autostart_dir.mkdir(parents=True, exist_ok=True)
        self.force_autostart_off(self.paths.launcher_data)
        env = self.upstream_env()
        bundled = str(self.paths.app / "usr/lib")
        env["LD_LIBRARY_PATH"] = bundled + (f":{env['LD_LIBRARY_PATH']}"
                                            if env.get("LD_LIBRARY_PATH") else "")
        command = ["systemd-run", "--user", "--collect", "--quiet", f"--unit={UNIT_NAME}",
                   "--description=PhaseZero ChatGPT Web launcher (experimental)",
                   "-p", "KillMode=mixed", "-p", "TimeoutStopSec=45", "-p", "Restart=no"]
        for prop in self.hardening_properties():
            command += ["-p", prop]
        passthrough = ("CODEX_HOME", "CODEX_CHATGPT_WEB_HOME", "CODEX_WEB_GPT_LAUNCHER_DATA_DIR",
                       "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE",
                       "XDG_CURRENT_DESKTOP", "DBUS_SESSION_BUS_ADDRESS", "XAUTHORITY", "LANG",
                       "LD_LIBRARY_PATH")
        for name in passthrough:
            if env.get(name):
                command.append(f"--setenv={name}={env[name]}")
        command.append(str(self.paths.app / LAUNCHER_BINARY))
        code, out, err = self.runner.run(command, env=env, timeout=30)
        if code != 0:
            raise BridgeError(f"launcher não iniciou: {(err or out).strip()[:300]}", "launch-failed")
        deadline = time.monotonic() + self.settle_seconds
        while time.monotonic() < deadline:
            if not self.launcher_active():
                break
            time.sleep(min(1.0, self.settle_seconds))
        if not self.launcher_active():
            _, log, _ = self.runner.run(["journalctl", "--user", "-u", UNIT_NAME, "-n", "8",
                                         "--no-pager", "-o", "cat"], timeout=10)
            self.save_state(state)
            raise BridgeError("launcher encerrou logo após iniciar: " + log.strip()[-400:],
                              "launch-failed")
        if not self.isolation()["ok"]:
            raise BridgeError("launcher iniciou, mas há launcher fora do isolamento ou entrada de "
                              "autostart upstream; rode `repair`", "isolation")
        state["hardening"] = {"liveCodexHome": "read-only", "personalBrowserProfiles": "inaccessible",
                              "autostartDirectory": "read-only", "autostart": False}
        state["launchedAt"] = iso(self.clock())
        self.save_state(state)
        return {"launcher": "started", "unit": UNIT_NAME, "hardening": state["hardening"],
                "next": "Entre no ChatGPT dentro da janela do launcher e rode `setup`."}

    def stop_launcher(self) -> dict[str, Any]:
        if not self.launcher_active():
            return {"launcher": "inactive"}
        route = self.route_status()
        if route.get("active") is not False:
            raise BridgeError("restaure a rota antes de encerrar o launcher (`route disable`)",
                              "route-active")
        code, out, err = self.runner.run(["systemctl", "--user", "stop", UNIT_NAME], timeout=90)
        # The main process leaves the unit's cgroup for its own scope; make sure it is gone.
        survivors = [item["pid"] for item in self.launcher_processes() if item["managed"]
                     and not self.runner.terminate(item["pid"])]
        if code != 0 or self.launcher_active() or survivors:
            raise BridgeError(f"launcher não encerrou: {(err or out).strip()[:300]}", "stop-failed")
        if self.runner.port_in_use(DEFAULT_PORT):
            raise BridgeError(f"porta {DEFAULT_PORT} ainda ocupada após encerrar", "port-residual")
        return {"launcher": "stopped", "residualPort": False}

    # ---- route -----------------------------------------------------------

    def _config_text(self) -> str:
        try:
            return self.paths.codex_config.read_text(encoding="utf-8")
        except FileNotFoundError:
            return ""

    def _baseline_text(self, state: dict[str, Any]) -> str:
        baseline = state.get("routeBaseline")
        if not isinstance(baseline, dict):
            raise BridgeError("sem baseline da rota; rode `launch` primeiro", "no-baseline")
        data = Path(baseline["path"]).read_bytes()
        if sha256_bytes(data) != baseline["sha256"]:
            raise BridgeError("backup da configuração foi alterado; restauração recusada",
                              "backup-tampered")
        return data.decode("utf-8")

    def managed_hook_lines(self) -> tuple[re.Pattern[str], ...]:
        """The interrupt hook upstream installs, accepted only when it runs the managed runtime."""
        version = re.escape(str(self.paths.core_home / "versions"
                                / f"{PIN['version']}-linux-x64"))
        core = re.escape(str(self.paths.core_home))
        config = re.escape(str(self.paths.codex_config))
        return tuple(re.compile(pattern) for pattern in (
            r"\[\[hooks\.Interrupt(\.hooks)?\]\]",
            r'type = "command"',
            r"timeout = \d{1,2}",
            rf"command = \"'{version}/bin/codex-chatgpt-web' '--home' '{core}' "
            r"'hook' 'interrupt'\"",
            rf"command = \"'{version}/runtime/bun' '{version}/app/cli\.js' '--home' '{core}' "
            r"'hook' 'interrupt'\"",
            rf'\[hooks\.state\."{config}:interrupt:\d+:\d+"\]',
            r'trusted_hash = "sha256:[0-9a-f]{64}"',
        ))

    def classify_diff(self, before: str, after: str) -> dict[str, Any]:
        """Split changed lines into upstream-managed and unexpected ones."""
        hook_lines = self.managed_hook_lines()
        managed: list[str] = []
        unexpected: list[str] = []
        diff = list(difflib.unified_diff(before.splitlines(), after.splitlines(),
                                         "baseline", "atual", lineterm="", n=0))
        for line in diff:
            if line.startswith(("---", "+++", "@@")):
                continue
            body = line[1:].strip()
            key = body.split("=", 1)[0].strip()
            structural = (not body or body.startswith("#")
                          or body in {"[features]", "[agents]"})
            if (key in MANAGED_ROUTE_KEYS or structural
                    or any(pattern.fullmatch(body) for pattern in hook_lines)):
                managed.append(line)
            else:
                unexpected.append(line)
        return {"diff": diff, "managed": managed, "unexpected": unexpected}

    def route_preview(self) -> dict[str, Any]:
        state = self.load_state()
        current = self._config_text()
        present = {key: bool(re.search(rf"(?m)^\s*{re.escape(key)}\s*=", current))
                   for key in MANAGED_ROUTE_KEYS}
        return {
            "target": str(self.paths.codex_config), "writes": False,
            "liveCodexHomeAffected": False,
            "willManage": list(MANAGED_ROUTE_KEYS),
            "expectedRoute": f"http://127.0.0.1:{DEFAULT_PORT}",
            "conflicts": [key for key, found in present.items()
                          if found and not self.route_status().get("active")],
            "baseline": state.get("routeBaseline"), "route": self.route_status(),
        }

    def ensure_approval_safety(self, config: dict[str, Any]) -> None:
        if not config.get("autoApproveToolCalls"):
            return
        if config.get("mode") == "full":
            raise BridgeError("aprovação automática ligada no upstream; desligue antes",
                              "auto-approve")
        if config.get("mode") == "browser-only":
            broker = self.paths.core_home / "runtime/turn-broker.sock"
            if broker.exists():
                raise BridgeError("broker local inesperado no modo somente Web; interrompa o "
                                  "launcher e revise a configuração", "unexpected-broker")
            return
        raise BridgeError("modo do launcher desconhecido com aprovação automática ligada",
                          "auto-approve")

    def desktop_dir(self) -> Path | None:
        """Install directory of Codex Desktop; its command may be a one-line exec wrapper."""
        launcher = shutil.which(DESKTOP_COMMAND, path=self.env.get("PATH"))
        if not launcher:
            return None
        resolved = Path(launcher).resolve()
        try:
            wrapper = resolved.read_bytes()[:4096].decode("utf-8", errors="ignore")
        except OSError:
            wrapper = ""
        target = re.search(r'(?m)^exec\s+"?(/[^\s"]+)/start\.sh\b', wrapper)
        return Path(target.group(1)) if target else resolved.parent

    def policy_violations(self, text: str) -> list[str]:
        """What breaks the profile's contract, whoever wrote it.

        Codex Desktop keeps its own plugins, marketplaces and bundled MCP
        servers in this file, so a line diff against the baseline cannot tell
        housekeeping from a real change. This reads the meaning instead.
        """
        try:
            config = tomllib.loads(text)
        except tomllib.TOMLDecodeError as error:
            return [f"config.toml inválido: {error}"]
        found: list[str] = []
        if config.get("sandbox_mode") != "read-only":
            found.append("sandbox_mode deixou de ser read-only")
        if config.get("approval_policy") != APPROVAL_POLICY:
            found.append(f"approval_policy deixou de ser {APPROVAL_POLICY}")
        found += [f"chave não permitida: {key}" for key in FORBIDDEN_PROFILE_KEYS if key in config]
        route = config.get("openai_base_url")
        if route is not None and route != f"http://127.0.0.1:{DEFAULT_PORT}/v1":
            found.append("openai_base_url aponta para fora do bridge local")
        hook_commands_allowed = self.managed_hook_lines()[3:5]

        def hook_commands(node: Any) -> list[str]:
            if isinstance(node, dict):
                own = [node["command"]] if isinstance(node.get("command"), str) else []
                return own + [item for key, value in node.items() if key != "state"
                              for item in hook_commands(value)]
            if isinstance(node, list):
                return [item for value in node for item in hook_commands(value)]
            return []

        for command in hook_commands(config.get("hooks", {})):
            if not any(pattern.fullmatch(f"command = {json.dumps(command)}")
                       for pattern in hook_commands_allowed):
                found.append("hook fora do runtime gerenciado")
        desktop = self.desktop_dir()
        for name, server in (config.get("mcp_servers") or {}).items():
            server = server if isinstance(server, dict) else {}
            command, url = server.get("command"), server.get("url")
            bundled = (desktop is not None and isinstance(command, str)
                       and Path(command).is_relative_to(desktop))
            # Loopback HTTP servers (e.g. the user's ai-memory) stay inside the
            # same-user boundary this profile already assumes.
            loopback = (command is None and isinstance(url, str)
                        and re.fullmatch(r"http://(127\.0\.0\.1|localhost)(:\d+)?(/.*)?", url))
            if not (bundled or loopback):
                found.append(f"servidor MCP fora do Codex Desktop e fora do loopback: {name}")
        return found

    def route_verify(self) -> dict[str, Any]:
        state = self.load_state()
        current = self._config_text()
        result = self.classify_diff(self._baseline_text(state), current)
        violations = self.policy_violations(current)
        # Lines outside upstream's set are reported, but only a contract breach fails.
        result["otherChanges"] = result.pop("unexpected")
        result.update({"route": self.route_status(), "violations": violations,
                       "ok": not violations,
                       "liveCodexRouteTouched": self.live_route_touched()})
        return result

    def route_enable(self) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        if not self.launcher_active():
            raise BridgeError("launcher parado; a rota apontaria para serviço ausente",
                              "launcher-inactive")
        config = self.upstream_config() or {}
        # Upstream can persist this flag in browser-only mode. Permit that
        # legacy state only while its local tools broker is absent.
        self.ensure_approval_safety(config)
        if config.get("mode") == "full":
            self.require_tools_ready(state)
        before = self._config_text()
        private_dir(self.paths.journal)
        backup = self.paths.journal / f"config-pre-enable-{sha256_bytes(before.encode())[:16]}.toml"
        atomic_write(backup, before.encode())
        code, out, err = self.upstream_cli(["route", "connect"])
        after = self._config_text()
        check = self.classify_diff(before, after)
        if code != 0 or check["unexpected"]:
            self.upstream_cli(["route", "disconnect"])
            restored = self._config_text() == before
            raise BridgeError(
                "ativação recusada: " + ("mudanças inesperadas na configuração"
                                         if check["unexpected"] else (err or out).strip()[:300])
                + ("; configuração anterior restaurada" if restored
                   else "; CONFLITO: confira a configuração com o backup " + str(backup)),
                "route-enable-failed")
        state["routeEnabled"] = {"at": iso(self.clock()), "backup": str(backup),
                                 "beforeSha256": sha256_bytes(before.encode()),
                                 "afterSha256": sha256_bytes(after.encode())}
        self.save_state(state)
        return {"route": "active", "diff": check["diff"], "backup": str(backup),
                "next": "Reinicie o Codex do perfil dedicado para carregar a rota."}

    def route_disable(self) -> dict[str, Any]:
        state = self.load_state()
        if not self.upstream_config():
            return {"route": "not-installed"}
        code, out, err = self.upstream_cli(["route", "disconnect"])
        route = self.route_status()
        refusal = " ".join([out, err, *map(str, route.get("errors") or [])])
        if route.get("active") is not False and UPSTREAM_REFUSAL in refusal:
            return self.reset_route(state)
        if code != 0 or route.get("active") is not False:
            raise BridgeError("rota não foi restaurada: " + (err or out).strip()[:300]
                              + ". Nada mais foi encerrado.", "route-restore-failed")
        current = self._config_text()
        leftovers = [key for key in MANAGED_ROUTE_KEYS[:2]
                     if re.search(rf"(?m)^\s*{re.escape(key)}\s*=", current)]
        if leftovers:
            raise BridgeError("entradas da rota ainda presentes: " + ", ".join(leftovers)
                              + ". Edição externa em conflito; resolva manualmente.",
                              "route-conflict")
        external = self.classify_diff(self._baseline_text(state), current)
        state.pop("routeEnabled", None)
        self.save_state(state)
        return {"route": "restored", "matchesBaseline": not external["diff"],
                "externalEditsPreserved": external["diff"],
                "next": "Reinicie o Codex do perfil dedicado antes de encerrar o launcher."}

    def reset_route(self, state: dict[str, Any]) -> dict[str, Any]:
        """Manager-side restore for a dedicated profile upstream refuses to touch.

        Codex Desktop re-serialises config.toml (comments and layout are lost) and
        upstream then declines every route change. The dedicated profile belongs to
        this manager: it goes back to its recorded baseline, the rewritten file is
        kept as a backup, and upstream's own route state is moved aside so the next
        `setup` configures from scratch. The ChatGPT session is not touched.
        """
        baseline = self._baseline_text(state)
        current = self._config_text()
        private_dir(self.paths.journal)
        backup = self.paths.journal / f"config-pre-reset-{sha256_bytes(current.encode())[:16]}.toml"
        atomic_write(backup, current.encode())
        quarantine = private_dir(
            self.paths.journal / f"upstream-route-{self.clock().strftime('%Y%m%dT%H%M%SZ')}")
        moved = [*sorted((self.paths.core_home / "codex").glob("integration-journal*.json")),
                 self.paths.core_home / "config.json"]
        for item in moved:
            if item.is_file():
                os.replace(item, quarantine / item.name)
        atomic_write(self.paths.codex_config, baseline.encode())
        state.pop("routeEnabled", None)
        self.save_state(state)
        return {"route": "restored-by-reset", "matchesBaseline": True,
                "configBackup": str(backup), "upstreamStateQuarantined": str(quarantine),
                "reason": "o Codex Desktop regravou a configuração do perfil dedicado e o "
                          "launcher se recusou a desfazer a própria rota",
                "next": "Ajustes feitos pelo Codex Desktop neste perfil (plugins, fontes) "
                        "voltam ao padrão; `setup` configura a rota de novo."}

    # ---- one-step setup --------------------------------------------------

    def _wait(self, ready: Callable[[], bool], seconds: float, message: str, code: str) -> None:
        deadline = time.monotonic() + seconds
        while not ready():
            if time.monotonic() >= deadline:
                raise BridgeError(message, code)
            time.sleep(self.poll_seconds)

    def descriptor_ready(self) -> bool:
        """The browser descriptor belongs to the isolated launcher running now."""
        descriptor = self._read_json(self.paths.descriptor) or {}
        return descriptor.get("pid") in {item["pid"] for item in self.launcher_processes()
                                         if item["managed"]}

    def default_model(self, light: bool = False) -> str:
        """A Web model the bridge serves; Codex's own default would need a Codex login."""
        if not (self.upstream_config() or {}).get("solAvailable"):
            return "chatgpt-web/luna"
        return "chatgpt-web/light" if light else "chatgpt-web/medium"

    def configure_web_model(self) -> dict[str, Any]:
        """Run upstream's browser-only setup against the dedicated profile, diff-checked."""
        state = self.load_state()
        self.require_opt_in(state)
        if (self.upstream_config() or {}).get("mode") == "full":
            raise BridgeError("launcher está no modo com ferramentas; o setup automático cobre "
                              "apenas o modelo Web", "full-mode")
        if not self.descriptor_ready():
            raise BridgeError("launcher isolado não está pronto; rode `launch`", "launcher-inactive")
        before = self._config_text()
        private_dir(self.paths.journal)
        backup = self.paths.journal / f"config-pre-enable-{sha256_bytes(before.encode())[:16]}.toml"
        atomic_write(backup, before.encode())
        code, out, err = self.upstream_cli(
            ["setup", "--browser-only", "--browser-host-descriptor", str(self.paths.descriptor),
             "--acknowledge-unofficial", "--port", str(DEFAULT_PORT)], timeout=600)
        after = self._config_text()
        check = self.classify_diff(before, after)
        config = self.upstream_config() or {}
        refused = ("mudanças inesperadas na configuração" if check["unexpected"]
                   else "upstream ligou aprovação automática" if config.get("autoApproveToolCalls")
                   else (err or out).strip()[-300:] if code != 0 else "")
        if refused:
            if config:
                self.upstream_cli(["route", "disconnect"])
            restored = self._config_text() == before
            raise BridgeError(
                "configuração do modelo Web recusada: " + refused
                + ("; configuração anterior restaurada" if restored
                   else "; CONFLITO: confira a configuração com o backup " + str(backup)),
                "web-model-setup-failed")
        state["routeEnabled"] = {"at": iso(self.clock()), "backup": str(backup),
                                 "beforeSha256": sha256_bytes(before.encode()),
                                 "afterSha256": sha256_bytes(after.encode())}
        self.save_state(state)
        return {"webModel": "configured", "diff": check["diff"], "backup": str(backup)}

    def restart_launcher(self) -> None:
        """The launcher only starts the Responses daemon at startup, once configured."""
        running = self.runner.codex_processes(self.paths.codex_home)
        if running:
            raise BridgeError("feche o Codex do perfil dedicado (PIDs "
                              + ", ".join(map(str, running)) + ") antes de reiniciar o launcher",
                              "codex-running")
        self.runner.run(["systemctl", "--user", "stop", UNIT_NAME], timeout=90)
        survivors = [item["pid"] for item in self.launcher_processes()
                     if not self.runner.terminate(item["pid"])]
        if survivors or self.launcher_active():
            raise BridgeError("launcher não encerrou para reiniciar", "stop-failed")
        self.launch()

    def setup(self, report: Callable[[str, str], None] = lambda *_: None,
              login_wait: float = LOGIN_WAIT_SECONDS) -> dict[str, Any]:
        """Everything from a recorded opt-in to a working Web model, idempotent."""
        self.require_opt_in(self.load_state())
        steps: list[dict[str, str]] = []

        def done(step: str, detail: str) -> None:
            steps.append({"step": step, "detail": detail})
            report(step, detail)

        if self.isolation()["ok"]:
            done("isolamento", "nenhum launcher fora do isolamento, sem autostart upstream")
        else:
            fixed = self.repair()
            done("isolamento", f"{len(fixed['stoppedLaunchers'])} launcher(s) fora do isolamento "
                 "encerrado(s); autostart upstream "
                 + ("movido para quarentena" if fixed["quarantinedAutostart"] else "ausente"))
        done("pacote", "baixado e conferido com o pin" if self.fetch()["downloaded"]
             else "já presente e conferido com o pin")
        if not self.launcher_active():
            self.install()
            if (self.session_present(self.paths.launcher_data) is not True
                    and self.session_present(self.paths.default_profile) is True):
                self.adopt_session()
                done("sessão", "login já feito no launcher foi movido para o perfil isolado")
            self.launch()
        done("launcher", "ativo no unit isolado (~/.codex e autostart somente leitura)")
        self._wait(self.descriptor_ready, DESCRIPTOR_WAIT_SECONDS,
                   "launcher não ficou pronto a tempo; veja `journalctl --user -u "
                   f"{UNIT_NAME}`", "launcher-timeout")
        if self.session_present(self.paths.launcher_data) is not True:
            report("login", "entre no ChatGPT na janela do Codex Web GPT; aguardando até "
                            f"{int(login_wait // 60)} min")
            self.runner.notify(NOTIFY_TITLE + " — login necessário",
                               "Entre no ChatGPT na janela do Codex Web GPT.\n"
                               "A configuração continua sozinha depois do login.", critical=True)
            self._wait(lambda: self.session_present(self.paths.launcher_data) is True, login_wait,
                       "Login no ChatGPT ainda não concluído. Entre pela janela do Codex Web GPT "
                       "e rode `setup` de novo; o que já foi feito é reaproveitado.",
                       "login-required")
        done("login", "sessão ChatGPT presente no perfil do launcher")
        if (self.upstream_config() or {}).get("mode") != "browser-only":
            if not self.upstream_config() and self.runner.port_in_use(DEFAULT_PORT):
                # A daemon from a previous configuration still holds the port.
                self.restart_launcher()
                self._wait(self.descriptor_ready, DESCRIPTOR_WAIT_SECONDS,
                           "launcher não ficou pronto a tempo", "launcher-timeout")
            self.configure_web_model()
            done("modelo web", "rota instalada no perfil dedicado; ~/.codex intocado")
        elif self.route_status().get("active"):
            done("modelo web", "rota já instalada no perfil dedicado")
        else:
            # Already configured: upstream's setup would collide with its own daemon's port.
            self.route_enable()
            done("modelo web", "rota religada no perfil dedicado; ~/.codex intocado")
        if not self.route_verify()["ok"]:
            raise BridgeError("configuração do perfil tem mudanças inesperadas; rode `route verify`",
                              "config-drift")
        if not self.runner.port_in_use(DEFAULT_PORT):
            self.restart_launcher()
            self._wait(lambda: self.runner.port_in_use(DEFAULT_PORT), DAEMON_WAIT_SECONDS,
                       f"bridge não abriu 127.0.0.1:{DEFAULT_PORT}", "daemon-timeout")
        done("bridge", f"respondendo em 127.0.0.1:{DEFAULT_PORT}")
        self.runner.notify(NOTIFY_TITLE + " — pronto",
                           "Modelo Web ativo no perfil dedicado.\n"
                           "Abra com: pz ai chatgpt-web desktop\n"
                           "O Codex Desktop normal continua na cota nativa.")
        return {"ready": True, "steps": steps, "stage": self.status()["stage"],
                "model": self.default_model(), "liveCodexRouteTouched": self.live_route_touched(),
                "next": ["pz ai chatgpt-web desktop (Codex Desktop no perfil dedicado)",
                         "pz ai chatgpt-web smoke   (turno real; gasta 1 mensagem da conta)",
                         "pz ai chatgpt-web codex   (Codex no perfil dedicado, sandbox read-only)",
                         "pz ai chatgpt-web disable (restaura a rota e encerra o launcher)"]}

    def smoke(self) -> dict[str, Any]:
        """One real turn through the bridge. Spends one message of the ChatGPT account."""
        model = self.default_model(light=True)
        scratch = private_dir(self.paths.root / "smoke")
        reply_file = scratch / "last-message.txt"
        reply_file.unlink(missing_ok=True)
        command, env = self.codex_command(
            ["exec", "--skip-git-repo-check", "--ephemeral", "-C", str(scratch), "-m", model,
             "-o", str(reply_file), f"Responda somente com a palavra: {SMOKE_TOKEN}"])
        code, out, err = self.runner.run(command, env=env, timeout=SMOKE_TIMEOUT_SECONDS,
                                         input_text="")
        try:
            reply = reply_file.read_text(encoding="utf-8").strip()
        except OSError:
            reply = ""
        ok = code == 0 and SMOKE_TOKEN in reply.upper()
        state = self.load_state()
        state["lastSmoke"] = {"at": iso(self.clock()), "ok": ok, "model": model}
        self.save_state(state)
        result: dict[str, Any] = {"ok": ok, "model": model, "reply": reply[-200:],
                                  "sandbox": "read-only", "exitCode": code,
                                  "liveCodexRouteTouched": self.live_route_touched()}
        if not ok:
            result["detail"] = (err or out).strip()[-600:]
        return result

    # ---- opt-in start at login -------------------------------------------

    def wrapper_text(self, purpose: str, target: str, failure: str, fix: str,
                     command: str) -> str:
        """POSIX wrapper at a stable path; fails visibly when the manager is gone."""
        return ("#!/bin/sh\n"
                f"# PhaseZero ChatGPT Web — {purpose}. Este caminho é estável;\n"
                f"# o gerenciador pode mudar. Alvo atual em {target}.\n"
                "set -eu\n"
                "DIR=$(dirname \"$0\")\n"
                f"TARGET=\"$DIR/{target}\"\n"
                "PY=$(sed -n '1p' \"$TARGET\" 2>/dev/null || true)\n"
                "SCRIPT=$(sed -n '2p' \"$TARGET\" 2>/dev/null || true)\n"
                "if [ -z \"$SCRIPT\" ] || [ ! -f \"$SCRIPT\" ] || [ ! -f \"$PY\" ]; then\n"
                "  notify-send --app-name=PhaseZero --urgency=critical --expire-time=30000 \\\n"
                f"    \"PhaseZero — ChatGPT Web {failure}\" \\\n"
                "    \"O gerenciador em ${SCRIPT:-desconhecido} não existe mais. "
                f"Religue a partir do repositório atual: {fix}\" \\\n"
                "    || true\n"
                "  exit 1\n"
                "fi\n"
                f"exec \"$PY\" \"$SCRIPT\" {command}\n")

    def autostart_wrapper_text(self) -> str:
        return self.wrapper_text(
            "início no login (opt-in)", self.paths.autostart_target.name, "não iniciou",
            "pz ai chatgpt-web autostart enable --acknowledge-autostart", "autostart run")

    def install_managed_entrypoint(self) -> None:
        """Snapshot this manager outside disposable worktrees for menu/login launch."""
        if not self.managed_python().is_file() or not os.access(self.managed_python(), os.X_OK):
            raise BridgeError("Python estável indisponível para o atalho", "manager-python")
        source = Path(__file__).resolve()
        helper = source.with_name("secret_store.py")
        windows_helper = source.with_name("windows_credential_store.py")
        try:
            script_bytes = source.read_bytes()
            helper_bytes = helper.read_bytes()
            windows_helper_bytes = windows_helper.read_bytes()
        except OSError as error:
            raise BridgeError(f"gerenciador incompleto: {error}", "manager-source") from None
        if self.paths.manager_dir.is_symlink():
            raise BridgeError("diretório do gerenciador é um symlink", "manager-path")
        private_dir(self.paths.manager_dir)
        atomic_write(self.paths.manager_secret_store, helper_bytes)
        atomic_write(self.paths.manager_windows_secret_store, windows_helper_bytes)
        atomic_write(self.paths.manager_script, script_bytes)

    def managed_python(self) -> Path:
        system_python = Path("/usr/bin/python3")
        return (system_python if os.name != "nt" and system_python.is_file()
                else Path(getattr(sys, "_base_executable", sys.executable)))

    def autostart_target_text(self) -> str:
        return f"{self.managed_python()}\n{self.paths.manager_script}\n"

    def entrypoint_ready(self, target: Path) -> bool:
        try:
            return (target.read_text(encoding="utf-8") == self.autostart_target_text()
                    and self.paths.manager_script.is_file()
                    and self.paths.manager_secret_store.is_file()
                    and self.paths.manager_windows_secret_store.is_file()
                    and self.managed_python().is_file()
                    and os.access(self.managed_python(), os.X_OK))
        except OSError:
            return False

    def autostart_entry_text(self) -> str:
        return ("[Desktop Entry]\n"
                "Type=Application\n"
                "Name=PhaseZero — ChatGPT Web no Codex\n"
                "Comment=Inicia o launcher isolado e o bridge (opt-in)\n"
                f'Exec="{self.paths.autostart_wrapper}"\n'
                "Terminal=false\n"
                "NoDisplay=true\n"
                "X-GNOME-Autostart-enabled=true\n"
                "X-PhaseZero-Managed=chatgpt-web\n")

    def autostart_status(self) -> dict[str, Any]:
        record = self.load_state().get("autostart")
        entry = self.paths.managed_autostart
        try:
            current = entry.read_text(encoding="utf-8")
        except OSError:
            current = None
        state = ("off" if not record and current is None
                 else "enabled" if record and current == self.autostart_entry_text()
                 and self.paths.autostart_wrapper.is_file()
                 and self.entrypoint_ready(self.paths.autostart_target)
                 else "inconsistent")
        return {"state": state, "entry": str(entry), "optedInAt": (record or {}).get("at"),
                "startsUpstreamLauncherDirectly": False}

    def autostart_enable(self, acknowledged: bool) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        if not acknowledged:
            raise BridgeError("iniciar no login exige `--acknowledge-autostart`: o launcher e o "
                              "bridge passam a subir sozinhos a cada sessão", "ack-missing")
        if self.package_state().get("unpacked") != "verified":
            raise BridgeError("conclua `setup` antes de ligar o início no login",
                              "install-unverified")
        self.install_managed_entrypoint()
        self.paths.autostart_dir.mkdir(parents=True, exist_ok=True)
        atomic_write(self.paths.autostart_wrapper, self.autostart_wrapper_text().encode(), 0o755)
        atomic_write(self.paths.autostart_target, self.autostart_target_text().encode(), 0o600)
        atomic_write(self.paths.managed_autostart, self.autostart_entry_text().encode(), 0o600)
        state["autostart"] = {"at": iso(self.clock())}
        self.save_state(state)
        return self.autostart_status()

    def autostart_disable(self) -> dict[str, Any]:
        state = self.load_state()
        self.paths.managed_autostart.unlink(missing_ok=True)
        self.paths.autostart_wrapper.unlink(missing_ok=True)
        self.paths.autostart_target.unlink(missing_ok=True)
        state.pop("autostart", None)
        self.save_state(state)
        return self.autostart_status()

    def autostart_run(self) -> dict[str, Any]:
        """What the login entry executes: the normal setup, without waiting for a login."""
        if self.autostart_status()["state"] != "enabled":
            raise BridgeError("início no login não está ligado (ou a entrada foi alterada); "
                              "nada foi iniciado", "autostart-off")
        try:
            return self.setup(login_wait=0)
        except BridgeError as error:
            self.runner.notify(NOTIFY_TITLE + " — não iniciou",
                               f"{error}\nRode: pz ai chatgpt-web setup", critical=True)
            raise

    # ---- local shortcuts (menu + desktop) --------------------------------

    def user_desktop_dir(self) -> Path:
        """The session's desktop folder, localised names included."""
        try:
            text = self.paths.user_dirs.read_text(encoding="utf-8")
        except OSError:
            text = ""
        match = re.search(r'(?m)^XDG_DESKTOP_DIR="([^"]+)"', text)
        if match:
            value = match.group(1).replace("$HOME", str(self.paths.home))
            if value.startswith("/"):
                return Path(value)
        return self.paths.home / "Desktop"

    def shortcut_entry_text(self, mode: str) -> str:
        name, comment = {
            "web": ("ChatGPT Web no Codex",
                    "Codex Desktop em janela separada com os modelos ChatGPT Web, somente "
                    "leitura. O Codex normal não muda."),
            "tools": ("ChatGPT Web no Codex — com ferramentas (experimental)",
                      "Bloqueado até túnel, chave e elegibilidade estarem prontos. Sandbox "
                      "somente leitura e aprovação por ação."),
        }[mode]
        return ("[Desktop Entry]\n"
                "Type=Application\n"
                f"Name={name}\n"
                f"Comment={comment}\n"
                f'Exec="{self.paths.open_wrapper}" {mode}\n'
                "Icon=codex-desktop\n"
                "Terminal=false\n"
                "Categories=Development;\n"
                "StartupNotify=false\n"
                "X-PhaseZero-Managed=chatgpt-web\n")

    def shortcut_files(self, desktop_copy: bool) -> list[tuple[Path, str]]:
        folders = [self.paths.applications] + ([self.user_desktop_dir()] if desktop_copy else [])
        return [(folder / name, mode) for folder in folders
                for mode, name in SHORTCUT_ENTRIES.items()]

    def shortcuts_status(self) -> dict[str, Any]:
        record = self.load_state().get("shortcuts")
        desktop_copy = bool((record or {}).get("desktopCopy", True))
        expected = self.shortcut_files(desktop_copy)
        present = [path for path, _ in self.shortcut_files(True) if path.exists()]

        def intact(path: Path, mode: str) -> bool:
            try:
                return path.read_text(encoding="utf-8") == self.shortcut_entry_text(mode)
            except OSError:
                return False

        state = ("off" if not record and not present
                 else "installed" if record and all(intact(*item) for item in expected)
                 and len(present) == len(expected) and self.paths.open_wrapper.is_file()
                 and self.entrypoint_ready(self.paths.open_target)
                 else "inconsistent")
        return {"state": state, "desktopCopy": desktop_copy if record else None,
                "menu": str(self.paths.applications), "desktop": str(self.user_desktop_dir()),
                "entries": [str(path) for path in present], "installedAt": (record or {}).get("at"),
                "listedInPublicCatalog": False}

    def shortcuts_install(self, desktop_copy: bool = True) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        if self.package_state().get("unpacked") != "verified":
            raise BridgeError("conclua `setup` antes de criar os atalhos", "install-unverified")
        desktop = self.user_desktop_dir()
        if desktop_copy and not desktop.is_dir():
            raise BridgeError(f"pasta da área de trabalho não encontrada ({desktop}); use "
                              "`--no-desktop-copy`", "desktop-dir-missing")
        self.install_managed_entrypoint()
        self.shortcuts_remove()
        state = self.load_state()
        private_dir(self.paths.autostart_bin)
        atomic_write(self.paths.open_wrapper, self.wrapper_text(
            "atalhos de menu e área de trabalho", self.paths.open_target.name, "não abriu",
            "pz ai chatgpt-web shortcuts install",
            'shortcuts run --mode "${1:-web}"').encode(), 0o755)
        atomic_write(self.paths.open_target, self.autostart_target_text().encode(), 0o600)
        self.paths.applications.mkdir(parents=True, exist_ok=True)
        for path, mode in self.shortcut_files(desktop_copy):
            # Executable: KDE refuses to launch a desktop icon it does not trust.
            atomic_write(path, self.shortcut_entry_text(mode).encode(), 0o755)
        state["shortcuts"] = {"at": iso(self.clock()), "desktopCopy": desktop_copy}
        self.save_state(state)
        return self.shortcuts_status()

    def shortcuts_remove(self) -> dict[str, Any]:
        state = self.load_state()
        for path, mode in self.shortcut_files(True):
            try:
                ours = "X-PhaseZero-Managed=chatgpt-web" in path.read_text(encoding="utf-8")
            except OSError:
                continue
            if ours or state.get("shortcuts"):
                path.unlink(missing_ok=True)
        self.paths.open_wrapper.unlink(missing_ok=True)
        self.paths.open_target.unlink(missing_ok=True)
        state.pop("shortcuts", None)
        self.save_state(state)
        return self.shortcuts_status()

    def shortcut_run(self, mode: str) -> dict[str, Any]:
        """What a shortcut executes: no terminal, so every refusal becomes a notification."""
        label = "com ferramentas" if mode == "tools" else "janela"
        try:
            if self.shortcuts_status()["state"] != "installed":
                raise BridgeError("atalhos não estão instalados (ou foram alterados); rode "
                                  "`pz ai chatgpt-web shortcuts install`", "shortcuts-off")
            if mode == "tools":
                self.require_tools_ready(self.load_state())
            if not (self.launcher_active() and self.runner.port_in_use(DEFAULT_PORT)):
                self.setup(login_wait=0)
            return self.desktop(mode)
        except BridgeError as error:
            body = f"{error}" + {"shortcuts-off": ""}.get(error.code,
                                                         "\nRode: pz ai chatgpt-web setup")
            if error.code == "tools-not-ready":
                pending = self.tools_steps()["next"] or {}
                body = ("O modo com ferramentas ainda não pode abrir.\n"
                        f"Falta: {pending.get('detail', error)}.\n"
                        f"Próximo passo: {pending.get('action', 'pz ai chatgpt-web tools status')}\n"
                        "Enquanto isso, o atalho \"ChatGPT Web no Codex\" segue funcionando "
                        "(sem ferramentas locais).")
            self.runner.notify(f"{NOTIFY_TITLE} — {label} não abriu", body, critical=True)
            raise

    # ---- consented local history -----------------------------------------

    def history_root(self, repo: str) -> Path:
        """Canonical top level of a real repository outside every Codex profile."""
        path = Path(repo).expanduser()
        try:
            path = path.resolve(strict=True)
        except OSError:
            raise BridgeError(f"pasta não encontrada: {repo}", "history-not-a-repo") from None
        fenced = (self.paths.live_codex_home.resolve(), self.paths.root.resolve(),
                  self.paths.default_core.resolve(), self.paths.default_profile.resolve())
        home = self.paths.home.resolve()

        def refuse_scope(candidate: Path) -> None:
            if candidate == home or any(candidate == item or item in candidate.parents
                                        for item in fenced):
                raise BridgeError(
                    "fora do escopo: sessões, memórias e perfis do Codex (normal ou dedicado) e a "
                    "pasta pessoal inteira nunca são compartilhados", "history-scope")

        refuse_scope(path)
        code, out, _ = self.runner.run(self.git_command(path, "rev-parse", "--show-toplevel"),
                                       timeout=20)
        if code != 0 or not out.strip():
            raise BridgeError(f"{path} não é um repositório git", "history-not-a-repo")
        top = Path(out.strip()).resolve()
        refuse_scope(top)
        return top

    @staticmethod
    def git_command(root: Path, *args: str) -> list[str]:
        # Read-only invocations; repository-provided hooks and helpers stay off.
        return ["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null", "-C", str(root), *args]

    def history_status(self) -> dict[str, Any]:
        record = self.load_state().get("history") or {}
        limit = dt.timedelta(days=HISTORY_CONSENT_MAX_AGE_DAYS)
        repos = []
        for path, entry in sorted(record.items()):
            granted = parse_iso(entry.get("at"))
            fresh = bool(granted and self.clock() - granted <= limit)
            repos.append({"path": path, "grantedAt": entry.get("at"),
                          "state": "granted" if fresh else "expired"})
        return {"repos": repos, "sends": "ramo, assuntos de commit, caminhos alterados e "
                                         "contagem de linhas; nunca o conteúdo dos arquivos",
                "destination": "sua conta ChatGPT, pelo bridge",
                "neverShared": ["~/.codex (sessões, índice e memórias)", "perfil dedicado",
                                "pasta pessoal inteira"],
                "expiresAfterDays": HISTORY_CONSENT_MAX_AGE_DAYS}

    def history_consent(self, repo: str, acknowledged: bool) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        if not acknowledged:
            raise BridgeError(
                "compartilhar histórico exige `--acknowledge-upload`: ramo, assuntos de commit e "
                "caminhos alterados deste repositório serão enviados à sua conta ChatGPT",
                "ack-missing")
        root = self.history_root(repo)
        state.setdefault("history", {})[str(root)] = {"at": iso(self.clock())}
        self.save_state(state)
        return self.history_status()

    def history_revoke(self, repo: str) -> dict[str, Any]:
        state = self.load_state()
        record = state.get("history") or {}
        candidates = {repo, str(Path(repo).expanduser().resolve())}
        for path in candidates & set(record):
            del record[path]
        if not record:
            state.pop("history", None)
        self.save_state(state)
        return self.history_status()

    def history_snapshot(self, repo: str, commits: int = HISTORY_DEFAULT_COMMITS) -> dict[str, Any]:
        """Exactly the text a consented `ask` would send; nothing is sent here."""
        state = self.load_state()
        self.require_opt_in(state)
        if not 1 <= commits <= HISTORY_MAX_COMMITS:
            raise BridgeError(f"commits deve ficar entre 1 e {HISTORY_MAX_COMMITS}", "history-range")
        root = self.history_root(repo)
        entry = (state.get("history") or {}).get(str(root))
        granted = parse_iso((entry or {}).get("at"))
        if not granted:
            raise BridgeError(
                f"sem consentimento para {root}; rode `history consent --repo {root} "
                "--acknowledge-upload`", "history-consent-required")
        if self.clock() - granted > dt.timedelta(days=HISTORY_CONSENT_MAX_AGE_DAYS):
            raise BridgeError(f"o consentimento para {root} venceu; registre de novo",
                              "history-consent-required")

        def git(*args: str) -> list[str]:
            code, out, err = self.runner.run(self.git_command(root, *args), timeout=30)
            if code != 0:
                raise BridgeError("git falhou ao ler o histórico: " + (err or out).strip()[-200:],
                                  "history-git-failed")
            return [SECRET_LIKE.sub("[REDIGIDO]", line) for line in out.splitlines() if line.strip()]

        def section(title: str, lines: list[str]) -> str:
            shown = lines[:HISTORY_MAX_SECTION_LINES]
            more = len(lines) - len(shown)
            body = shown + ([f"… (+{more} linhas omitidas)"] if more > 0 else [])
            return f"## {title}\n" + ("\n".join(body) if body else "(vazio)")

        log = git("log", f"-n{commits}", "--date=short", "--pretty=format:%h %ad %s")
        text = "\n\n".join([
            f"# Histórico local (somente leitura) — {root.name}",
            section("Ramo atual", git("rev-parse", "--abbrev-ref", "HEAD")),
            section(f"Últimos {len(log)} commits (hash, data, assunto)", log),
            section("Arquivos com mudanças não commitadas", git("status", "--short")),
            section("Tamanho das mudanças não commitadas",
                    git("diff", "--stat", "--no-ext-diff", "--no-textconv", "HEAD")),
        ])
        encoded = text.encode()[:HISTORY_MAX_BYTES]
        text = encoded.decode("utf-8", errors="ignore")
        return {"repo": str(root), "commits": len(log), "bytes": len(text.encode()), "text": text,
                "fileContentsIncluded": False, "sent": False}

    def ask(self, repo: str, question: str,
            commits: int = HISTORY_DEFAULT_COMMITS) -> dict[str, Any]:
        """One real Web-model turn about a consented repository. Spends one message."""
        question = question.strip()
        if not question:
            raise BridgeError("escreva a pergunta", "usage")
        if len(question) > HISTORY_QUESTION_MAX_CHARS:
            raise BridgeError("pergunta longa demais", "history-range")
        snapshot = self.history_snapshot(repo, commits)
        prompt = ("Você recebeu um resumo somente leitura do histórico de um repositório local. "
                  "Não há ferramentas locais neste turno: não finja executar comandos nem editar "
                  "arquivos; quando sugerir mudanças, descreva-as ou escreva o patch para o "
                  "operador aplicar.\n\n" + snapshot["text"] + "\n\n## Pedido do operador\n"
                  + question)
        scratch = private_dir(self.paths.root / "ask")
        reply_file = scratch / "last-message.txt"
        reply_file.unlink(missing_ok=True)
        command, env = self.codex_command(
            ["exec", "--skip-git-repo-check", "--ephemeral", "-C", str(scratch),
             "-o", str(reply_file), prompt])
        code, out, err = self.runner.run(command, env=env, timeout=ASK_TIMEOUT_SECONDS,
                                         input_text="")
        try:
            reply = reply_file.read_text(encoding="utf-8").strip()
        except OSError:
            reply = ""
        ok = code == 0 and bool(reply)
        result: dict[str, Any] = {
            "ok": ok, "repo": snapshot["repo"], "commits": snapshot["commits"],
            "bytesSent": len(prompt.encode()), "model": command[command.index("--model") + 1],
            "reply": reply, "sandbox": "read-only", "localTools": False, "exitCode": code,
            "liveCodexRouteTouched": self.live_route_touched()}
        if not ok:
            result["detail"] = (err or out).strip()[-600:]
        return result

    # ---- ordered teardown ------------------------------------------------

    def disable(self) -> dict[str, Any]:
        steps: list[dict[str, Any]] = [{"step": "route", **self.route_disable()}]
        running = self.runner.codex_processes(self.paths.codex_home)
        if running:
            raise BridgeError(
                "Rota restaurada. Feche o Codex do perfil dedicado (PIDs "
                + ", ".join(map(str, running)) + ") e rode `disable` de novo.", "codex-running")
        steps.append({"step": "codex", "running": []})
        steps.append({"step": "launcher", **self.stop_launcher()})
        result: dict[str, Any] = {"disabled": True, "steps": steps}
        if self.autostart_status()["state"] != "off":
            result["autostart"] = ("início no login segue ligado; rode `autostart disable` "
                                   "para não voltar na próxima sessão")
        return result

    def remove(self, purge_session: bool) -> dict[str, Any]:
        if self.launcher_active():
            raise BridgeError("launcher ativo; rode `disable` antes de remover", "launcher-active")
        if self.route_status().get("active") is not False and self.upstream_config():
            raise BridgeError("rota ativa; rode `disable` antes de remover", "route-active")
        removed: list[str] = []
        if self.paths.packages.parent.exists():
            shutil.rmtree(self.paths.packages.parent)
            removed.append("packages")
        if purge_session:
            for directory in (self.paths.core_home, self.paths.launcher_data,
                              self.paths.codex_home, self.paths.journal):
                if directory.exists():
                    shutil.rmtree(directory)
                    removed.append(directory.name)
            state = self.load_state()
            for key in ("routeBaseline", "routeEnabled", "hardening", "launchedAt"):
                state.pop(key, None)
            self.save_state(state)
        if "packages" in removed:
            state = self.load_state()
            state.pop("unpacked", None)
            self.save_state(state)
        return {"removed": removed, "sessionPreserved": not purge_session,
                "manualCleanup": [
                    "Remova o conector no ChatGPT e o túnel na plataforma OpenAI, se criados.",
                    "Revogue a chave de runtime na plataforma e rode `tunnel key revoke`.",
                ]}

    # ---- tunnel / tools --------------------------------------------------

    def secret_store(self) -> Any:
        if self._secret_store is None:
            self._secret_store = load_sibling("secret_store").SecretServiceStore()
        return self._secret_store

    def tunnel_guide(self) -> dict[str, Any]:
        return {
            "administrative": True, "automated": False,
            "steps": [
                "Confirme no workspace: plano, Developer Mode e política de ações do administrador.",
                "Crie o túnel na plataforma OpenAI (exige Tunnels Read + Manage). Anote o tunnel_id.",
                "Crie uma chave de runtime restrita a Tunnels Read + Use, com expiração definida. "
                "Não use chave ampla nem sem expiração.",
                "Guarde a chave com `tunnel key store` (entrada oculta; vai para o cofre do sistema).",
                "No ChatGPT, crie o conector usando o tunnel_id. O conector é resolvido pela "
                "identidade MCP configurada no launcher; o nome visível do túnel não precisa coincidir.",
                "`Authentication: None` vale apenas porque o transporte é túnel + broker com chave "
                "de runtime. Não substitui autorização por tarefa.",
                "Não selecione `Allow all actions`. Mantenha aprovação por ação.",
                "Conclua a verificação na página MCP do launcher e rode `tools check`.",
            ],
            "links": {"tunnels": "https://platform.openai.com/settings/organization/tunnels",
                      "runtimeKeys": "https://platform.openai.com/settings/organization/api-keys",
                      "connectors": "https://chatgpt.com/#settings/Plugins"},
            "network": "somente HTTPS de saída; nenhuma porta pública ou regra de entrada",
        }

    def key_store(self, secret: str, rotate_days: int) -> dict[str, Any]:
        state = self.load_state()
        self.require_opt_in(state)
        if not 1 <= rotate_days <= KEY_ROTATION_MAX_DAYS:
            raise BridgeError(f"rotação deve ficar entre 1 e {KEY_ROTATION_MAX_DAYS} dias",
                              "rotation-range")
        secret = secret.strip()
        if not secret:
            raise BridgeError("chave vazia", "empty-key")
        module = load_sibling("secret_store")
        store = self.secret_store()
        previous = (state.get("runtimeKey") or {}).get("ref")
        reference = module.new_secret_reference()
        try:
            store.store(reference, secret)
            if previous:
                store.delete(previous)
        except module.SecretStoreUnavailable as error:
            raise BridgeError(f"cofre do sistema indisponível: {error}. Nenhum arquivo foi usado "
                              "como alternativa.", "secret-store") from None
        stored = self.clock()
        state["runtimeKey"] = {"ref": reference, "storedAt": iso(stored),
                               "rotateBy": iso(stored + dt.timedelta(days=rotate_days))}
        self.save_state(state)
        return self.key_status(state)

    def key_stage(self) -> dict[str, Any]:
        """Materialise the key on tmpfs for the launcher's file import only."""
        state = self.load_state()
        self.require_tools_ready(state, need_broker=False)
        if not self.paths.runtime:
            raise BridgeError("XDG_RUNTIME_DIR ausente; sem local temporário privado", "no-runtime-dir")
        module = load_sibling("secret_store")
        try:
            secret = self.secret_store().lookup(state["runtimeKey"]["ref"])
        except module.SecretStoreUnavailable as error:
            raise BridgeError(f"cofre do sistema indisponível: {error}", "secret-store") from None
        if not secret:
            raise BridgeError("chave não encontrada no cofre", "key-missing")
        private_dir(self.paths.runtime)
        if not enforces_permissions(self.paths.runtime):
            raise BridgeError("diretório temporário não aplica permissões", "runtime-perms")
        target = self.paths.runtime / "runtime-key"
        atomic_write(target, secret.encode())
        return {"path": str(target), "mode": "0600",
                "next": "Importe pelo launcher (cópia de arquivo) e rode `tunnel key unstage`."}

    def key_unstage(self) -> dict[str, Any]:
        target = self.paths.runtime / "runtime-key" if self.paths.runtime else None
        if not target or not target.exists():
            return {"staged": False}
        size = target.stat().st_size
        with target.open("r+b") as handle:
            handle.write(b"\0" * size)
            handle.flush()
            os.fsync(handle.fileno())
        target.unlink()
        return {"staged": False, "wiped": True}

    def key_revoke(self) -> dict[str, Any]:
        state = self.load_state()
        self.key_unstage()
        record = state.pop("runtimeKey", None)
        removed = False
        if isinstance(record, dict) and record.get("ref"):
            module = load_sibling("secret_store")
            try:
                removed = bool(self.secret_store().delete(record["ref"]))
            except module.SecretStoreUnavailable as error:
                raise BridgeError(f"cofre do sistema indisponível: {error}", "secret-store") from None
        upstream_copy = None
        config = self.upstream_config() or {}
        for tunnel_key in ("automaticTunnel", "manualTunnel", "tunnel"):
            candidate = (config.get(tunnel_key) or {}).get("runtimeKeyFile")
            if candidate and Path(candidate).exists():
                upstream_copy = candidate
                if not self.launcher_active():
                    Path(candidate).unlink()
        self.save_state(state)
        return {"vaultEntryRemoved": removed,
                "upstreamCopy": ("removida" if upstream_copy and not self.launcher_active()
                                 else "presente; pare o launcher e repita" if upstream_copy
                                 else "ausente"),
                "manual": "Revogue a chave também na plataforma OpenAI; a remoção local não a invalida."}

    def require_tools_ready(self, state: dict[str, Any], need_broker: bool = True) -> None:
        self.require_opt_in(state)
        blockers = list(self.eligibility(state)["blockers"])
        key = self.key_status(state)
        if key["state"] == "absent":
            blockers.append("chave de runtime não está no cofre")
        elif key["state"] == "rotation-overdue":
            blockers.append("chave de runtime passou do prazo de rotação")
        if self.runner.other_users():
            blockers.append("há outros usuários com sessão neste host")
        if need_broker:
            capability = self.eligibility(state).get("planMcpCapability")
            if capability not in {"write-unverified", "write-beta"}:
                blockers.append("acesso completo pelo conector MCP não comprovado no plano informado")
            config = self.upstream_config() or {}
            if config.get("mode") != "full":
                blockers.append("launcher não está no modo com ferramentas")
            if config.get("autoApproveToolCalls"):
                blockers.append("aprovação automática ligada no upstream")
            blockers.append(FULL_RUNTIME_BLOCKER)
        if blockers:
            raise BridgeError("modo com ferramentas indisponível: " + "; ".join(blockers),
                              "tools-not-ready")

    def tools_steps(self) -> dict[str, Any]:
        """Ordered checklist for the tools mode with the single next action."""
        state = self.load_state()
        self.require_opt_in(state)
        record = state.get("eligibility") if isinstance(state.get("eligibility"), dict) else None
        eligibility = self.eligibility(state)
        key = self.key_status(state)
        config = self.upstream_config() or {}
        other_users = self.runner.other_users()
        trusted_user = (record or {}).get("singleUserTrusted") == "yes"
        if other_users == ["unknown"]:
            user_detail = "não foi possível verificar as sessões de outras contas locais"
        elif other_users:
            user_detail = "há outra conta local com sessão neste host"
        elif trusted_user:
            user_detail = "verificado: somente a conta local atual tem sessão"
        else:
            user_detail = "confiança na conta local individual ainda não confirmada"
        user_action = ("Nenhuma ação necessária." if trusted_user and not other_users
                       else "Não ative ferramentas enquanto houver outra conta com sessão."
                       if other_users and other_users != ["unknown"]
                       else "Verifique as sessões locais antes de ativar ferramentas."
                       if other_users == ["unknown"]
                       else "Confirme a conta local individual no comando eligibility.")
        plan = str((record or {}).get("plan"))
        label = PLAN_LABELS.get(plan, "não informado")
        manager = "pz ai chatgpt-web"
        steps = [
            ("eligibility", bool(record) and eligibility["state"] == "recorded",
             "plano e permissões registrados" if record and eligibility["state"] == "recorded"
             else "atestado vencido" if record else "plano e permissões ainda não registrados",
             f"{manager} eligibility --plan … --developer-mode … --tunnel-permission … "
             "--single-user-trusted …"),
            ("plan", bool(record) and eligibility["planMcpCapability"] != "none",
             f"plano {label}: " + ("permissão MCP sujeita à conta/workspace"
                                   if record and eligibility["planMcpCapability"] != "none" else
                                   "permissão MCP não confirmada nesta integração"),
             f"Confira MCP no workspace e registre a elegibilidade. Fonte: {PLAN_SOURCE}"),
            ("plan-full", eligibility.get("planMcpCapability") in
             {"write-unverified", "write-beta"},
             "sem exclusão comprovada pelo plano Pro; escrita na conta ainda "
             "não verificada por chamada MCP real"
             if eligibility.get("planMcpCapability") == "write-unverified" else
             "plano informado admite MCP completo; chamada real ainda necessária"
             if eligibility.get("planMcpCapability") == "write-beta" else
             "acesso completo não disponível ou não comprovado no plano informado",
             "Confira permissões do plugin MCP nesta conta. Mantenha o modo Web até "
             "uma chamada real de escrita reversível ser aprovada e concluída."),
            ("developer-mode", (record or {}).get("developerMode") == "yes",
             "modo desenvolvedor do ChatGPT " + ("confirmado" if (record or {}).get("developerMode")
                                                 == "yes" else "não confirmado"),
             "Ative em Configurações → Apps → Configurações avançadas e registre de novo."),
            ("tunnel-permission", (record or {}).get("tunnelPermission") in {"use", "manage"},
             "permissão de túnel na plataforma OpenAI",
             f"{manager} tunnel guide"),
            ("single-user", trusted_user and not other_users,
             user_detail, user_action),
            ("runtime-key", key["state"] == "stored",
             {"absent": "chave de runtime ainda não está no cofre",
              "rotation-overdue": "chave de runtime passou do prazo de rotação",
              "stored": "chave de runtime no cofre do sistema"}[key["state"]],
             f"Crie uma chave restrita a Tunnels Read + Use, com expiração, e rode "
             f"`{manager} tunnel key store` (entrada oculta)."),
            ("auto-approve", not config.get("autoApproveToolCalls"),
             "aprovação automática desligada no launcher" if not config.get("autoApproveToolCalls")
             else "aprovação automática LIGADA no launcher",
             "Desligue a aprovação automática na página MCP do launcher."),
            ("full-runtime", False, FULL_RUNTIME_BLOCKER, FULL_RUNTIME_ACTION),
            ("launcher-mode", config.get("mode") == "full",
             "launcher no modo com ferramentas" if config.get("mode") == "full"
             else "launcher mantido no modo somente Web enquanto Full está bloqueado",
             "Mantenha browser-only. Não altere o launcher até resolver full-runtime e "
             "provar uma chamada MCP real."),
        ]
        listed = [{"id": step, "ok": bool(ok), "detail": detail, "action": action}
                  for step, ok, detail, action in steps]
        pending = next((item for item in listed if not item["ok"]), None)
        return {"ready": pending is None, "steps": listed, "next": pending,
                "webModelStillWorks": config.get("mode") == "browser-only",
                "planSource": PLAN_SOURCE, "lockedCapabilities": LOCKED_CAPABILITIES,
                "note": "A infraestrutura pode estar saudável, mas Full 6.1.8 falhou em "
                        "turno real sob sandbox read-only. Browser-only segue disponível."}

    def tools_check(self) -> dict[str, Any]:
        state = self.load_state()
        blockers: list[str] = []
        try:
            self.require_tools_ready(state)
        except BridgeError as error:
            blockers.append(str(error))
        doctor: Any = None
        if self.upstream_config():
            code, out, err = self.upstream_cli(["doctor", "--json"], timeout=120)
            try:
                doctor = json.loads(out)
            except ValueError:
                doctor = {"ok": False, "detail": (err or out).strip()[:300]}
            if code != 0 or not doctor.get("ok"):
                blockers.append("doctor upstream reportou falha"
                                + (": " + self.route_status()["hint"]
                                   if self.route_status().get("desktopRewroteConfig") else ""))
        else:
            blockers.append("runtime upstream não configurado")
        return {"ready": not blockers, "blockers": blockers, "doctor": doctor,
                "capability": self.eligibility(state)["tools"],
                "lockedCapabilities": LOCKED_CAPABILITIES,
                "note": "Doctor saudável não prova turno MCP. Full 6.1.8 falhou em "
                        "turno real sob sandbox read-only."}

    # ---- codex in the dedicated profile ----------------------------------

    def require_ready(self, state: dict[str, Any]) -> None:
        """Launcher up, route active and unmodified, no automatic approvals."""
        if not self.launcher_active():
            raise BridgeError("launcher parado; rode `setup`", "launcher-inactive")
        if not self.route_status().get("active"):
            raise BridgeError("rota inativa no perfil dedicado; rode `setup`", "route-inactive")
        if not self.route_verify()["ok"]:
            raise BridgeError("configuração do perfil tem mudanças inesperadas; rode `route verify`",
                              "config-drift")
        config = self.upstream_config() or {}
        self.ensure_approval_safety(config)
        if config.get("mode") == "full":
            self.require_tools_ready(state)

    def codex_signed_in(self) -> bool:
        """Codex's own login in the dedicated profile (needed for the model list)."""
        return (self.paths.codex_home / "auth.json").is_file()

    def visible_web_models(self) -> list[str]:
        """Labels the Desktop selector really shows; tier slugs are hidden there."""
        cache = self._read_json(self.paths.codex_home / "models_cache.json") or {}
        models = cache.get("models")
        return [str(item["display_name"]) for item in models if isinstance(item, dict)
                and str(item.get("slug", "")).startswith(WEB_MODEL_PREFIX)
                and item.get("visibility") == "list" and item.get("display_name")
                ] if isinstance(models, list) else []

    def desktop(self, mode: str = "web") -> dict[str, Any]:
        """Open Codex Desktop as a separate instance bound to the dedicated profile."""
        state = self.load_state()
        self.require_opt_in(state)
        tools = mode == "tools"
        if not tools and (self.upstream_config() or {}).get("mode") == "full":
            raise BridgeError("o launcher está no modo com ferramentas; use o atalho "
                              "\"com ferramentas\" (`desktop --mode tools`)", "full-mode")
        self.require_ready(state)
        if tools:
            self.require_tools_ready(state)
        launcher = shutil.which(DESKTOP_COMMAND, path=self.env.get("PATH"))
        if not launcher:
            raise BridgeError("Codex Desktop não encontrado no PATH", "desktop-missing")
        env = dict(self.env)
        env["CODEX_HOME"] = str(self.paths.codex_home)
        env["CODEX_MULTI_LAUNCH"] = "1"
        pid = self.runner.spawn([launcher, "--new-instance"], env)
        signed_in = self.codex_signed_in()
        labels = self.visible_web_models()
        pick = ("No seletor de modelo, escolha um que termine em \"(Web)\""
                + (": " + ", ".join(labels[:4]) + "." if labels else
                   ", por exemplo \"GPT-6 Sol (Web)\"."))
        guidance = (
            ([] if signed_in else
             ["1. Faça login no Codex NESTA janela nova (só na primeira vez)."])
            + [f"{'1' if signed_in else '2'}. {pick}",
               "Os modelos Web usam sua conta ChatGPT, não a cota do Codex."]
            + (["Com ferramentas: cada ação local pede sua aprovação. Nunca escolha aprovar "
                "tudo nem acesso total no seletor de permissões.",
                "Sandbox somente leitura; escrita local segue bloqueada."] if tools else
               ["Somente leitura: conversa e análise, sem editar arquivos."])
            + ["A outra janela do Codex continua no perfil normal."])
        notified = self.runner.notify(
            NOTIFY_TITLE + (" — login necessário" if not signed_in else " — janela aberta"),
            "\n".join(guidance), critical=not signed_in)
        return {"desktop": "started", "mode": mode, "pid": pid,
                "codexHome": str(self.paths.codex_home), "sandbox": "read-only",
                "codexSignedIn": signed_in, "model": self.default_model(),
                "visibleModels": labels, "guidance": guidance,
                "notified": notified, "liveCodexRouteTouched": self.live_route_touched()}

    def codex_command(self, args: list[str]) -> tuple[list[str], dict[str, str]]:
        state = self.load_state()
        self.require_opt_in(state)
        for index, arg in enumerate(args):
            flag = arg.split("=", 1)[0]
            if flag in FORBIDDEN_CODEX_ARGS:
                raise BridgeError(f"argumento {flag} não é permitido neste perfil", "forbidden-arg")
            if flag in {"-c", "--config"}:
                value = arg.split("=", 1)[1] if "=" in arg and flag == "--config" else (
                    args[index + 1] if index + 1 < len(args) else "")
                if FORBIDDEN_CODEX_OVERRIDES.match(value):
                    raise BridgeError("override de sandbox, aprovação ou rota não é permitido",
                                      "forbidden-override")
            if flag in {"-p", "--profile"}:
                raise BridgeError("perfis de configuração não são permitidos aqui", "forbidden-arg")
        self.require_ready(state)
        codex = shutil.which("codex", path=self.env.get("PATH"))
        if not codex:
            raise BridgeError("codex não encontrado no PATH", "codex-missing")
        env = dict(self.env)
        env["CODEX_HOME"] = str(self.paths.codex_home)
        chosen = any(arg.split("=", 1)[0] in {"-m", "--model"} for arg in args)
        model = [] if chosen else ["--model", self.default_model()]
        return [codex, "--sandbox", "read-only", "--ask-for-approval", APPROVAL_POLICY,
                *model, *args], env


def read_secret(stream: Any) -> str:
    if stream.isatty():
        return getpass.getpass("Chave de runtime (oculta): ")
    return stream.readline()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pz ai chatgpt-web",
        description="ChatGPT Web no Codex — experimental, opt-in, capacidades graduais.")
    parser.add_argument("--json", action="store_true",
                        help="saída JSON em setup, status, smoke e repair")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "status", "fetch", "install", "launch", "stop", "disable", "opt-out",
                 "repair", "adopt-session", "smoke"):
        sub.add_parser(name)
    desktop = sub.add_parser("desktop", help="Codex Desktop no perfil dedicado")
    desktop.add_argument("--mode", choices=("web", "tools"), default="web")
    shortcuts = sub.add_parser("shortcuts", help="atalhos locais de menu e área de trabalho")
    shortcuts.add_argument("action", choices=("status", "install", "remove", "run"))
    shortcuts.add_argument("--mode", choices=("web", "tools"), default="web")
    shortcuts.add_argument("--no-desktop-copy", action="store_true")
    history = sub.add_parser("history", help="histórico local compartilhado com consentimento")
    history.add_argument("action", choices=("status", "consent", "revoke", "snapshot"))
    history.add_argument("--repo")
    history.add_argument("--commits", type=int, default=HISTORY_DEFAULT_COMMITS)
    history.add_argument("--acknowledge-upload", action="store_true")
    ask = sub.add_parser("ask", help="pergunta ao modelo Web sobre um repositório consentido")
    ask.add_argument("--repo", required=True)
    ask.add_argument("--commits", type=int, default=HISTORY_DEFAULT_COMMITS)
    ask.add_argument("question", nargs="+")
    setup = sub.add_parser("setup", help="faz tudo: pacote, launcher isolado, login, modelo Web")
    setup.add_argument("--login-wait", type=int, default=LOGIN_WAIT_SECONDS,
                       help="segundos aguardando o login na janela do launcher")
    opt_in = sub.add_parser("opt-in")
    for ack in ("experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"):
        opt_in.add_argument(f"--acknowledge-{ack}", action="store_true")
    remove = sub.add_parser("remove")
    remove.add_argument("--purge-session", action="store_true")
    eligibility = sub.add_parser("eligibility")
    eligibility.add_argument("--plan", choices=sorted(PLAN_MCP_CAPABILITY), required=True)
    eligibility.add_argument("--developer-mode", choices=("yes", "no", "unknown"), required=True)
    eligibility.add_argument("--tunnel-permission", choices=("none", "use", "manage"), required=True)
    eligibility.add_argument("--single-user-trusted", choices=("yes", "no"), required=True)
    route = sub.add_parser("route")
    route.add_argument("action", choices=("status", "preview", "verify", "enable", "disable"))
    tunnel = sub.add_parser("tunnel")
    tunnel_sub = tunnel.add_subparsers(dest="tunnel_command", required=True)
    tunnel_sub.add_parser("guide")
    key = tunnel_sub.add_parser("key")
    key.add_argument("action", choices=("store", "status", "stage", "unstage", "revoke"))
    key.add_argument("--rotate-days", type=int, default=KEY_ROTATION_DEFAULT_DAYS)
    autostart = sub.add_parser("autostart", help="início no login (opt-in)")
    autostart.add_argument("action", choices=("status", "enable", "disable", "run"))
    autostart.add_argument("--acknowledge-autostart", action="store_true")
    tools = sub.add_parser("tools")
    tools.add_argument("action", choices=("status", "check"))
    codex = sub.add_parser("codex")
    codex.add_argument("args", nargs=argparse.REMAINDER)
    return parser


def dispatch(bridge: Bridge, args: argparse.Namespace) -> Any:
    command = args.command
    if command == "plan":
        return bridge.plan()
    if command == "status":
        return bridge.status()
    if command == "opt-in":
        return bridge.opt_in({name[len("acknowledge_"):].replace("_", "-")
                              for name, value in vars(args).items()
                              if name.startswith("acknowledge_") and value})
    if command == "opt-out":
        return bridge.opt_out()
    if command == "eligibility":
        return bridge.record_eligibility(args.plan, args.developer_mode, args.tunnel_permission,
                                         args.single_user_trusted)
    if command == "fetch":
        return bridge.fetch()
    if command == "install":
        return bridge.install()
    if command == "launch":
        return bridge.launch()
    if command == "smoke":
        return bridge.smoke()
    if command == "desktop":
        return bridge.desktop(args.mode)
    if command == "shortcuts":
        if args.action == "install":
            return bridge.shortcuts_install(desktop_copy=not args.no_desktop_copy)
        if args.action == "run":
            return bridge.shortcut_run(args.mode)
        return {"status": bridge.shortcuts_status,
                "remove": bridge.shortcuts_remove}[args.action]()
    if command == "history":
        if args.action == "status":
            return bridge.history_status()
        if not args.repo:
            raise BridgeError("informe `--repo CAMINHO`", "usage")
        if args.action == "consent":
            return bridge.history_consent(args.repo, args.acknowledge_upload)
        if args.action == "revoke":
            return bridge.history_revoke(args.repo)
        return bridge.history_snapshot(args.repo, args.commits)
    if command == "ask":
        return bridge.ask(args.repo, " ".join(args.question), args.commits)
    if command == "repair":
        return bridge.repair()
    if command == "adopt-session":
        return bridge.adopt_session()
    if command == "stop":
        return bridge.stop_launcher()
    if command == "disable":
        return bridge.disable()
    if command == "remove":
        return bridge.remove(args.purge_session)
    if command == "route":
        return {"status": bridge.route_status, "preview": bridge.route_preview,
                "verify": bridge.route_verify, "enable": bridge.route_enable,
                "disable": bridge.route_disable}[args.action]()
    if command == "tunnel":
        if args.tunnel_command == "guide":
            return bridge.tunnel_guide()
        if args.action == "store":
            return bridge.key_store(read_secret(sys.stdin), args.rotate_days)
        if args.action == "status":
            return bridge.key_status(bridge.load_state())
        return {"stage": bridge.key_stage, "unstage": bridge.key_unstage,
                "revoke": bridge.key_revoke}[args.action]()
    if command == "autostart":
        if args.action == "enable":
            return bridge.autostart_enable(args.acknowledge_autostart)
        return {"status": bridge.autostart_status, "disable": bridge.autostart_disable,
                "run": bridge.autostart_run}[args.action]()
    if command == "tools":
        return bridge.tools_steps() if args.action == "status" else bridge.tools_check()
    raise BridgeError(f"comando desconhecido: {command}", "usage")


FRIENDLY_COMMANDS = {"setup", "status", "smoke", "repair", "desktop", "shortcuts", "ask",
                     "tools"}
STAGE_LABELS = {
    "off": "desligado (rode `setup`)",
    "opted-in": "aceito, pacote ainda não instalado",
    "package-verified": "launcher instalado, modelo Web ainda não configurado",
    "launcher-configured": "configurado, rota inativa",
    "web-model": "modelo Web ativo (sem ferramentas locais)",
    "tools-experimental": "modelo Web com ferramentas (experimental)",
}


def mark(value: object) -> str:
    return "✓" if value is True else "?" if value is None else "✗"


def render(command: str, result: dict[str, Any]) -> str:
    """Short pt-BR summary for people; `--json` keeps the full payload."""
    lines: list[str] = []
    if command == "setup":
        lines += ["", f"Pronto: {STAGE_LABELS.get(result['stage'], result['stage'])}.",
                  f"Modelo padrão: {result['model']}", "Próximos passos:"]
        lines += [f"  {item}" for item in result["next"]]
    elif command == "status":
        isolation = result["isolation"]
        lines += [
            f"ChatGPT Web no Codex (experimental) — {STAGE_LABELS.get(result['stage'], result['stage'])}",
            f"  {mark(result['package']['state'] == 'verified')} pacote {result['pin']['version']} "
            "conferido com o pin",
            f"  {mark(result['launcher']['active'])} launcher no unit isolado",
            f"  {mark(isolation['ok'])} isolamento (sem launcher solto, sem autostart upstream)",
            f"  {mark(result['signedIn'])} sessão ChatGPT no perfil do launcher",
            f"  {mark(bool(result['route'].get('active')))} rota no perfil dedicado",
            f"  {mark(result['daemonListening'])} bridge em 127.0.0.1:{DEFAULT_PORT}",
            f"  {mark(result['liveCodexRouteTouched'] is False)} ~/.codex do usuário intocado",
        ]
        smoke = result.get("lastSmoke")
        if smoke:
            lines.append(f"  {mark(smoke['ok'])} último turno real: {smoke['at']} ({smoke['model']})")
        if not isolation["ok"]:
            lines.append("  → rode `pz ai chatgpt-web repair`")
        autostart = result["autostart"]["state"]
        lines.append("  início no login: "
                     + {"off": "desligado (ligue com `autostart enable --acknowledge-autostart`)",
                        "enabled": "ligado, pelo unit isolado",
                        "inconsistent": "INCONSISTENTE; rode `autostart disable`"}[autostart])
        lines.append("Bloqueado por desenho: escrita local, autostart do launcher upstream, "
                     "rota do ~/.codex, catálogo.")
    elif command == "smoke":
        lines.append(f"{mark(result['ok'])} turno real via {result['model']} "
                     f"(sandbox {result['sandbox']}): {result['reply'] or 'sem resposta'}")
        if not result["ok"]:
            lines.append(result.get("detail", ""))
    elif command == "desktop":
        lines += ["✓ Codex Desktop aberto no perfil dedicado (janela separada)"]
        lines += [f"  {item}" for item in result["guidance"]]
    elif command == "shortcuts":
        if "desktop" in result and "state" not in result:
            return render("desktop", result)
        lines.append({"off": "atalhos: não instalados (`shortcuts install`)",
                      "installed": "✓ atalhos instalados (menu"
                                   + (" + área de trabalho)" if result["desktopCopy"] else ")"),
                      "inconsistent": "✗ atalhos INCONSISTENTES; rode `shortcuts install`"
                      }[result["state"]])
        lines += [f"  {item}" for item in result["entries"]]
        lines.append("  Fora do catálogo público; o Codex Desktop normal não foi alterado.")
    elif command == "tools":
        if "steps" not in result:
            return json.dumps(result, ensure_ascii=False, indent=2)
        lines.append("ChatGPT Web com ferramentas (experimental) — "
                     + ("pronto para abrir" if result["ready"] else "ainda bloqueado"))
        lines += [f"  {mark(item['ok'])} {item['detail']}" for item in result["steps"]]
        if result["next"]:
            lines += ["Próximo passo:", f"  {result['next']['action']}"]
        if result["webModelStillWorks"]:
            lines.append("O modo Web (sem ferramentas) continua funcionando normalmente.")
    elif command == "ask":
        lines.append(f"{mark(result['ok'])} {result['model']} — {result['commits']} commits de "
                     f"{result['repo']} ({result['bytesSent']} bytes enviados, sem ferramentas "
                     "locais)")
        lines.append(result["reply"] or result.get("detail", "sem resposta"))
    elif command == "repair":
        lines += [f"✓ launchers fora do isolamento encerrados: {len(result['stoppedLaunchers'])}",
                  "✓ autostart upstream: "
                  + (f"em quarentena ({result['quarantinedAutostart']})"
                     if result["quarantinedAutostart"] else "ausente"),
                  f"{mark(result['liveCodexRouteTouched'] is False)} ~/.codex do usuário intocado"]
    return "\n".join(lines)


def interactive_opt_in(bridge: Bridge) -> None:
    """Setup's consent prompt. Never answered on the user's behalf."""
    if bridge.load_state().get("optIn") or not sys.stdin.isatty():
        return
    print("ChatGPT Web no Codex — integração experimental. Antes de continuar:\n")
    for warning in WARNINGS:
        print(f"  • {warning}")
    if input("\nDigite ACEITO para continuar: ").strip() != "ACEITO":
        raise BridgeError("sem aceite; nada foi alterado", "opt-in-required")
    bridge.opt_in({"experimental", "unofficial", "unsigned", "same-user-boundary",
                   "no-quota-promise"})


def offer_autostart(bridge: Bridge) -> None:
    """Asked once, after a successful interactive setup. Default is no."""
    state = bridge.load_state()
    if state.get("autostartOffered") or state.get("autostart") or not sys.stdin.isatty():
        return
    answer = input("\nIniciar junto com o login (launcher isolado + bridge)? [s/N] ")
    state["autostartOffered"] = iso(bridge.clock())
    bridge.save_state(state)
    if answer.strip().lower() in {"s", "sim"}:
        bridge.autostart_enable(True)
        print("✓ início no login ligado (desligue com `pz ai chatgpt-web autostart disable`)")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    bridge = Bridge()
    friendly = args.command in FRIENDLY_COMMANDS and not args.json
    try:
        if args.command == "codex":
            extra = args.args[1:] if args.args[:1] == ["--"] else args.args
            command, env = bridge.codex_command(extra)
            return bridge.runner.exec(command, env)
        if args.command == "setup":
            interactive_opt_in(bridge)
            result = bridge.setup(
                (lambda step, detail: print(f"✓ {step}: {detail}", flush=True))
                if friendly else (lambda *_: None), args.login_wait)
            if friendly:
                offer_autostart(bridge)
        else:
            result = dispatch(bridge, args)
    except BridgeError as error:
        if friendly:
            print(f"✗ {error}\n  (código: {error.code})")
        else:
            print(json.dumps({"ok": False, "code": error.code, "error": str(error)},
                             ensure_ascii=False, indent=2))
        return 2 if error.code == "usage" else 1
    if friendly:
        print(render(args.command, result))
        return 0 if result.get("ok", True) else 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main())
