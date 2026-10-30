#!/usr/bin/env python3
"""Codex account profiles in the existing PhaseZero accounts domain.

Metadata contains no credentials. Codex and the Web bridge own their own login
stores. The current installation is referenced in place, never imported/copied.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid

try:
    import fcntl
except ImportError:  # Importable by the shared Windows account page; execution is Linux-only.
    fcntl = None

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from linux.lib.pz_hostbackup import backup_file, ledger_record

COLORS = {"azul": "#2563eb", "verde": "#15803d", "roxo": "#7e22ce", "laranja": "#c2410c"}
PROFILE_ID = re.compile(r"pz-[0-9a-f]{12}\Z")
CURRENT = {"id": "current", "label": "Conta atual", "color": "azul", "slot": 0}
MAX_PROFILES = 64


class ProfileError(RuntimeError):
    pass


def _text(value: str) -> str:
    value = value.strip()
    if not 1 <= len(value) <= 60 or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ProfileError("Apelido deve conter 1–60 caracteres de texto simples.")
    return value


def _private(path: Path) -> None:
    if path.is_symlink():
        raise ProfileError("Diretório de perfil não pode ser um link simbólico.")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


def _write(path: Path, text: str, mode: int = 0o600) -> None:
    if path.is_symlink():
        raise ProfileError("Arquivo gerenciado não pode ser um link simbólico.")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".codex-profile-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _desktop_exec_path(path: Path) -> str:
    # Desktop Entry Exec has its own quoting, distinct from shell quoting.
    return str(path).replace("\\", "\\\\\\\\").replace('"', '\\\\"').replace("`", "\\\\`").replace("$", "\\\\$").replace("%", "%%")


class CodexProfiles:
    def __init__(self, env: dict[str, str] | None = None) -> None:
        self.env = dict(os.environ if env is None else env)
        for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            anchor = self.env.get("PZ_CODEX_ACCOUNTS_" + key)
            if anchor:
                self.env[key] = anchor
        self.home = Path(self.env.get("HOME") or Path.home())
        self.data = Path(self.env.get("XDG_DATA_HOME") or self.home / ".local/share")
        self.config = Path(self.env.get("XDG_CONFIG_HOME") or self.home / ".config")
        self.root = self.data / "phasezero/ai-accounts/codex-profiles"
        self.runtime_root = self.data / "phasezero/codex"
        self.registry = self.root / "profiles.json"
        self._current = dict(CURRENT)

    def rows(self) -> list[dict]:
        if self.root.is_symlink() or self.registry.is_symlink():
            raise ProfileError("Registro de perfis é um link simbólico; nada foi alterado.")
        try:
            if self.registry.stat().st_size > 64 * 1024:
                raise ProfileError("Registro de perfis excede limite de metadados; arquivo preservado.")
            document = json.loads(self.registry.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self._current = dict(CURRENT)
            return []
        except (OSError, ValueError):
            raise ProfileError("Registro de perfis ilegível; restaure o backup antes de continuar.") from None
        if not isinstance(document, dict) or document.get("schemaVersion") != 1:
            raise ProfileError("Versão desconhecida do registro de perfis.")
        current = document.get("current", {"label": CURRENT["label"], "color": CURRENT["color"]})
        if (not isinstance(current, dict) or not isinstance(current.get("label"), str)
                or current.get("color") not in COLORS):
            raise ProfileError("Identificação da conta atual inválida.")
        self._current = {**CURRENT, "label": _text(current["label"]), "color": current["color"]}
        rows = document.get("profiles")
        if not isinstance(rows, list) or len(rows) > MAX_PROFILES:
            raise ProfileError("Registro de perfis inválido.")
        ids, slots = set(), set()
        for row in rows:
            if (not isinstance(row, dict) or not PROFILE_ID.fullmatch(str(row.get("id", "")))
                    or set(row) - {"id", "label", "color", "slot", "archived"}
                    or row.get("color") not in COLORS or type(row.get("slot")) is not int
                    or not 1 <= row["slot"] <= MAX_PROFILES
                    or row["id"] in ids or row["slot"] in slots
                    or type(row.get("archived", False)) is not bool
                    or not isinstance(row.get("label"), str)):
                raise ProfileError("Registro de perfis inválido; nenhuma conta foi selecionada.")
            _text(row["label"])
            ids.add(row["id"])
            slots.add(row["slot"])
        return rows

    @contextmanager
    def locked(self):
        if fcntl is None:
            raise ProfileError("Perfis Codex gerenciados estão disponíveis neste fluxo apenas no Linux.")
        _private(self.root)
        fd = os.open(self.root / "registry.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            yield

    def _save(self, rows: list[dict]) -> None:
        backup_file(self.registry, module="ai-codex-profiles")
        _write(self.registry, json.dumps({"schemaVersion": 1, "profiles": rows,
                                         "current": {key: self._current[key] for key in ("label", "color")}}, indent=2) + "\n")
        ledger_record(module="ai-codex-profiles", action="metadata", modified=[str(self.registry)],
                      reversible=True)

    def get(self, profile_id: str) -> dict:
        if profile_id == "current":
            self.rows()
            return dict(self._current)
        for row in self.rows():
            if row["id"] == profile_id:
                return row
        raise ProfileError("Perfil não encontrado. Atualize a lista de contas.")

    def add(self, label: str, color: str = "azul") -> dict:
        label = _text(label)
        if color not in COLORS:
            raise ProfileError("Cor desconhecida.")
        with self.locked():
            rows = self.rows()
            used = {row["slot"] for row in rows}
            available = sorted(set(range(1, MAX_PROFILES + 1)) - used)
            if not available:
                raise ProfileError("Limite local de 64 perfis atingido.")
            row = {"id": "pz-" + uuid.uuid4().hex[:12], "label": label,
                   "color": color, "slot": available[0]}
            rows.append(row)
            self._save(rows)
        return row

    def rename(self, profile_id: str, label: str, color: str) -> dict:
        label = _text(label)
        if color not in COLORS:
            raise ProfileError("Cor desconhecida.")
        with self.locked():
            rows = self.rows()
            row = self._current if profile_id == "current" else next((r for r in rows if r["id"] == profile_id), None)
            if row is None:
                raise ProfileError("Perfil não encontrado.")
            row.update(label=label, color=color)
            self._save(rows)
        if not row.get("archived"):
            self.shortcuts(profile_id, existing_only=True)
        return row

    def archive(self, profile_id: str, *, restore: bool = False) -> dict:
        if profile_id == "current":
            raise ProfileError("Instalação atual é preservada; gerencie seu logout dentro do Codex.")
        with self.locked():
            rows = self.rows()
            row = next((r for r in rows if r["id"] == profile_id), None)
            if row is None:
                raise ProfileError("Perfil não encontrado.")
            row["archived"] = not restore
            self._save(rows)
        if not restore:
            for folder in (self.data / "applications", self.desktop_dir()):
                for surface in ("desktop", "cli", "web", "browser"):
                    target = folder / f"phasezero-codex-{profile_id}-{surface}.desktop"
                    if (target.is_file() and not target.is_symlink()
                            and "X-PhaseZero-Managed=codex-profiles" in target.read_text(encoding="utf-8")):
                        backup_file(target, module="ai-codex-profiles")
                        target.unlink()
        return {"profileId": profile_id, "archived": not restore,
                "sessionsPreserved": True, "runningAppsTouched": False}

    def require_active(self, profile_id: str) -> dict:
        row = self.get(profile_id)
        self._check_paths(row)
        if row.get("archived"):
            raise ProfileError("Perfil arquivado. Restaure este ID antes de abrir ou criar atalhos.")
        return row

    def profile_base(self, row: dict) -> Path:
        # Linux AF_UNIX paths are limited to 107 bytes. Keep runtime homes
        # shorter than the account metadata domain; never symlink credentials.
        return self.runtime_root / row["id"]

    @staticmethod
    def check_desktop_socket_path(codex_home: Path) -> None:
        if len(os.fsencode(codex_home / "ipc/ipc.sock")) > 107:
            raise ProfileError("Caminho do perfil excede limite de socket Linux (107 bytes). Use XDG_DATA_HOME mais curto para novos perfis.")

    def _check_paths(self, row: dict) -> None:
        if row["id"] == "current":
            return
        base = self.profile_base(row)
        paths = [self.root, self.runtime_root, base, *(base / name for name in ("native", "web", "browser", "desktop")),
                 *(base / "web" / name for name in ("core-home", "codex-home", "launcher-data", "packages"))]
        if any(path.is_symlink() for path in paths):
            raise ProfileError("Perfil redirecionado por link simbólico; acesso bloqueado para preservar contas.")

    def native_home(self, row: dict) -> Path:
        self._check_paths(row)
        return self.home / ".codex" if row["id"] == "current" else self.profile_base(row) / "native"

    @staticmethod
    def desktop_profiles_supported() -> bool:
        """The Linux launcher must isolate Electron as well as CODEX_HOME."""
        from linux.ai.chatgpt_web_bridge import desktop_profiles_supported
        return desktop_profiles_supported()

    def profile_env(self, row: dict, mode: str = "native") -> dict[str, str]:
        env = dict(self.env)
        for key, folder in (("XDG_DATA_HOME", ".local/share"), ("XDG_CONFIG_HOME", ".config"),
                            ("XDG_STATE_HOME", ".local/state"), ("XDG_CACHE_HOME", ".cache")):
            env["PZ_CODEX_ACCOUNTS_" + key] = self.env.get(key) or str(self.home / folder)
        # Calling from a Web/another Codex window must never inherit its route,
        # API-key provider, authentication override or Electron instance.
        for key in list(env):
            if key.startswith(("CODEX_", "PZ_CHATGPT_WEB_", "PZ_LIVE_CODEX_", "OPENAI_")):
                env.pop(key)
        env.pop("ELECTRON_RUN_AS_NODE", None)
        env["CODEX_HOME"] = str(self.native_home(row))
        if row["id"] != "current":
            base = self.profile_base(row) / "desktop" / mode
            for name, folder in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"),
                                 ("XDG_CACHE_HOME", "cache")):
                env[name] = str(base / folder)
            port = 22100 + row["slot"] * 4 + (1 if mode == "web" else 0)
            env["CODEX_WEBVIEW_PORT"] = str(port)
            # Fixed port keeps the launcher's Electron storage path stable.
            env["CODEX_MULTI_LAUNCH_PORT_RANGE"] = f"{port}-{port}"
            env["CODEX_ELECTRON_USER_DATA_DIR"] = str(base / "electron")
        return env

    def prepare_native(self, row: dict) -> None:
        if row["id"] == "current":
            return
        _private(self.root)
        _private(self.runtime_root)
        _private(self.profile_base(row))
        native = self.native_home(row)
        _private(native)
        target = native / "config.toml"
        if not target.exists():
            _write(target, '# PhaseZero isolated Codex account; Codex owns authentication.\n'
                   'cli_auth_credentials_store = "file"\nforced_login_method = "chatgpt"\n'
                   'sandbox_mode = "workspace-write"\napproval_policy = "on-request"\n')
            ledger_record(module="ai-codex-profiles", action="prepare", created=[str(target)],
                          reversible=True)

    def bridge(self, row: dict):
        from linux.ai.chatgpt_web_bridge import Bridge
        env = self.profile_env(row, "web")
        # Bridge's persistent paths use the account domain, not the desktop XDG.
        env["XDG_DATA_HOME"] = str(self.data)
        env["XDG_CONFIG_HOME"] = str(self.config)
        env["PZ_LIVE_CODEX_HOME"] = str(self.native_home(row))
        env["PZ_CHATGPT_WEB_NO_DOWNLOAD"] = "1"
        if row["id"] != "current":
            env["PZ_CHATGPT_WEB_INSTANCE"] = row["id"]
            env["PZ_CHATGPT_WEB_SLOT"] = str(row["slot"])
            env["PZ_CHATGPT_WEB_ROOT"] = str(self.profile_base(row) / "web")
        return Bridge(env=env)

    def status(self) -> dict:
        profiles = self.rows()
        rows = [*(row for row in reversed(profiles) if not row.get("archived")), dict(self._current),
                *(row for row in reversed(profiles) if row.get("archived"))]
        # Local evidence only. Presence must never be called authenticated.
        return {"schemaVersion": 1, "profiles": [
            {**row, "nativeCredential": "present" if (self.native_home(row) / "auth.json").is_file()
             else "unknown", "session": "unverified", "quota": "unknown",
             "webConfigured": self.bridge(row).paths.state.is_file()}
            for row in rows], "cliInstalled": bool(shutil.which("codex", path=self.env.get("PATH"))),
            "desktopInstalled": bool(shutil.which("codex-desktop", path=self.env.get("PATH")))}

    def launch(self, profile_id: str, surface: str) -> dict:
        row = self.require_active(profile_id)
        self.prepare_native(row)
        if surface == "web":
            bridge = self.bridge(row)
            bridge.require_opt_in(bridge.load_state())
            if row["id"] != "current":
                self.check_desktop_socket_path(bridge.paths.codex_home)
                if not self.desktop_profiles_supported():
                    raise ProfileError("Launcher Desktop sem isolamento de múltiplas contas comprovado.")
            if not bridge.launcher_active() or not bridge.runner.port_in_use(bridge.paths.port):
                self.prepare_web_package(profile_id)
                bridge.setup(login_wait=0)
            return bridge.desktop("tools" if (bridge.upstream_config() or {}).get("mode") == "full" else "web")
        env = self.profile_env(row)
        if surface == "browser":
            browser = next((shutil.which(name, path=self.env.get("PATH")) for name in
                            ("chromium", "google-chrome", "chromium-browser")
                            if shutil.which(name, path=self.env.get("PATH"))), None)
            if not browser:
                raise ProfileError("Chromium/Chrome não encontrado; instale pelo painel Aplicativos.")
            profile = self.profile_base(row) / "browser"
            _private(self.runtime_root)
            _private(profile.parent)
            _private(profile)
            command = [browser, f"--user-data-dir={profile}", f"--class=phasezero-codex-{profile_id}-browser",
                       "--new-window", "https://chatgpt.com/codex"]
        elif surface == "desktop":
            executable = shutil.which("codex-desktop", path=env.get("PATH"))
            if not executable:
                raise ProfileError("Codex Desktop não instalado; use Preparar Codex Desktop no painel.")
            if profile_id != "current":
                self.check_desktop_socket_path(self.native_home(row))
                if not self.desktop_profiles_supported():
                    raise ProfileError("Launcher Desktop sem isolamento de múltiplas contas comprovado. CLI continua disponível.")
                with socket.socket() as probe:
                    probe.settimeout(0.2)
                    if probe.connect_ex(("127.0.0.1", int(env["CODEX_WEBVIEW_PORT"]))) == 0:
                        raise ProfileError("Janela deste perfil já aberta ou porta ocupada. Selecione a janela pelo ícone da conta.")
            command = [executable]
            if profile_id != "current":
                command += ["--new-instance", f"--class=phasezero-codex-{profile_id}"]
        else:
            raise ProfileError("Superfície desconhecida.")
        process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        return {"started": True, "profileId": profile_id, "surface": surface, "pid": process.pid}

    def cli_command(self, profile_id: str, args: list[str], *, login: bool = False) -> tuple[list[str], dict]:
        row = self.require_active(profile_id)
        executable = shutil.which("codex", path=self.env.get("PATH"))
        if not executable:
            raise ProfileError("Codex CLI não instalado; use pz ai setup codex.")
        self.prepare_native(row)
        return [executable, *(["login"] if login else args)], self.profile_env(row)

    def terminal(self, profile_id: str, task: str) -> dict:
        self.require_active(profile_id)
        pz = Path(__file__).resolve().parents[1] / "pz"
        command = [str(pz), "ai", "codex-profiles"]
        command += ["web", profile_id, "setup"] if task == "web-setup" else [task, profile_id]
        terminal = next((name for name in ("konsole", "gnome-terminal", "xterm")
                         if shutil.which(name, path=self.env.get("PATH"))), None)
        if terminal is None:
            raise ProfileError("Terminal não encontrado. Execute login pelo comando do perfil.")
        title = "Codex · " + self.get(profile_id)["label"]
        prefix = {"konsole": ["konsole", "--separate", "-p", f"tabtitle={title}", "-e"],
                  "gnome-terminal": ["gnome-terminal", "--title", title, "--"],
                  "xterm": ["xterm", "-T", title, "-e"]}[terminal]
        process = subprocess.Popen(prefix + command, env=self.env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        return {"started": True, "profileId": profile_id, "task": task, "pid": process.pid}

    def prepare_web_package(self, profile_id: str) -> None:
        """Reuse only the pinned public archive. Never copy a login or download.

        Upstream's archive is >70 MB. Fetching it requires the existing manual
        download journey, even when setup is initiated in the panel.
        """
        from linux.ai.chatgpt_web_bridge import PIN, sha256_file, DISK_MARGIN_BYTES
        row = self.get(profile_id)
        bridge = self.bridge(row)
        asset = bridge.asset()
        target = bridge.paths.package(asset)
        if target.is_file() and target.stat().st_size == asset["size"] and sha256_file(target) == asset["sha256"]:
            return
        original = self.bridge(dict(CURRENT)).paths.package(asset)
        if (profile_id == "current" or not original.is_file()
                or original.stat().st_size != asset["size"] or sha256_file(original) != asset["sha256"]):
            raise ProfileError(
                f"Download manual necessário ({asset['size']} bytes): "
                f"https://github.com/{PIN['repository']}/releases/download/{PIN['tag']}/{asset['name']} · "
                f"SHA-256 {asset['sha256']} · destino {target}")
        _private(bridge.paths.root)
        _private(target.parent)
        if shutil.disk_usage(target.parent).free < asset["size"] + DISK_MARGIN_BYTES:
            raise ProfileError("Espaço insuficiente para reutilizar pacote Web com margem de recuperação.")
        temporary = target.with_suffix(".reuse")
        try:
            shutil.copyfile(original, temporary)
            temporary.chmod(0o400)
            if sha256_file(temporary) != asset["sha256"]:
                raise ProfileError("Arquivo reutilizado não confere com o pin; sessões preservadas.")
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
        ledger_record(module="ai-codex-profiles", action="reuse-public-package", created=[str(target)],
                      reversible=True)

    def desktop_dir(self) -> Path:
        try:
            text = (self.config / "user-dirs.dirs").read_text(encoding="utf-8")
        except FileNotFoundError:
            text = ""
        match = re.search(r'(?m)^XDG_DESKTOP_DIR="([^"]+)"', text)
        return Path(match.group(1).replace("$HOME", str(self.home))) if match else self.home / "Desktop"

    def shortcuts(self, profile_id: str, *, existing_only: bool = False) -> dict:
        row = self.require_active(profile_id)
        folders = [self.data / "applications"]
        if self.desktop_dir().is_dir():
            folders.append(self.desktop_dir())
        if existing_only and not any(
                (folder / f"phasezero-codex-{profile_id}-{surface}.desktop").is_file()
                for folder in folders for surface in ("desktop", "cli", "web", "browser")):
            return {"installed": False, "profileId": profile_id, "count": 0}
        base = self.profile_base(row)
        _private(self.runtime_root)
        _private(base)
        # Stable source root; project policy has one canonical checkout. Missing
        # checkout fails visibly, never selects a different account.
        pz = Path(__file__).resolve().parents[1] / "pz"
        icon = base / "account.svg"
        _write(icon, '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128">'
               f'<rect width="128" height="128" rx="24" fill="{COLORS[row["color"]]}"/>'
               f'<text x="64" y="80" text-anchor="middle" font-family="sans-serif" '
               f'font-size="48" fill="white">C{row["slot"]}</text></svg>\n')
        paths = []
        wrappers = []
        for surface, label, terminal in (("desktop", "Desktop", False), ("cli", "CLI", True),
                                          ("web", "Web Desktop", False), ("browser", "Navegador", False)):
            wrapper = base / f"open-{surface}.sh"
            args = [str(pz), "ai", "codex-profiles", "cli" if surface == "cli" else "open", profile_id]
            if surface != "cli":
                args += ["--surface", surface]
            # Capture base XDG roots so launching from another isolated profile
            # cannot resolve this ID in that profile's settings.
            exports = {"HOME": str(self.home), "XDG_DATA_HOME": str(self.data),
                       "XDG_CONFIG_HOME": str(self.config),
                       "XDG_STATE_HOME": self.env.get("XDG_STATE_HOME", str(self.home / ".local/state")),
                       "XDG_CACHE_HOME": self.env.get("XDG_CACHE_HOME", str(self.home / ".cache"))}
            exports.update({"PZ_CODEX_ACCOUNTS_" + key: value for key, value in list(exports.items())
                            if key.startswith("XDG_")})
            script = "#!/bin/sh\nset -eu\n" + "".join(f"export {key}={shlex.quote(value)}\n" for key, value in exports.items())
            script += "exec " + shlex.join(args) + "\n"
            _write(wrapper, script, 0o700)
            wrappers.append(str(wrapper))
            for folder in folders:
                target = folder / f"phasezero-codex-{profile_id}-{surface}.desktop"
                if existing_only and (not target.is_file() or
                        "X-PhaseZero-Managed=codex-profiles" not in target.read_text(encoding="utf-8")):
                    continue
                label_text = row["label"].replace("\\", "\\\\")
                content = ("[Desktop Entry]\nType=Application\n"
                           f"Name=Codex {label} — {label_text} · C{row['slot']}\n"
                           f'Exec="{_desktop_exec_path(wrapper)}"\nIcon={icon}\n'
                           f"Terminal={str(terminal).lower()}\nCategories=Development;\n"
                           + (f"StartupWMClass=phasezero-codex-{profile_id}-browser\n" if surface == "browser"
                              else "StartupWMClass=codex-desktop\n" if surface in {"desktop", "web"} else "") +
                           "X-PhaseZero-Managed=codex-profiles\n")
                if target.exists():
                    if "X-PhaseZero-Managed=codex-profiles" not in target.read_text(encoding="utf-8"):
                        raise ProfileError("Atalho alterado por terceiros; arquivo preservado.")
                    backup_file(target, module="ai-codex-profiles")
                _write(target, content, 0o755)
                paths.append(str(target))
        ledger_record(module="ai-codex-profiles", action="shortcuts", created=paths + wrappers + [str(icon)],
                      reversible=True)
        return {"installed": True, "profileId": profile_id, "count": len(paths)}

    def install_panel_shortcut(self) -> dict:
        """Expose this checkout's account panel without replacing the installed app."""
        _private(self.root)
        launcher = Path(__file__).resolve().parents[1] / "ui/native.sh"
        wrapper = self.root / "open-panel.sh"
        exports = {"HOME": str(self.home), "XDG_DATA_HOME": str(self.data), "XDG_CONFIG_HOME": str(self.config),
                   "XDG_STATE_HOME": self.env.get("XDG_STATE_HOME", str(self.home / ".local/state")),
                   "XDG_CACHE_HOME": self.env.get("XDG_CACHE_HOME", str(self.home / ".cache"))}
        exports.update({"PZ_CODEX_ACCOUNTS_" + key: value for key, value in list(exports.items())
                        if key.startswith("XDG_")})
        script = "#!/bin/sh\nset -eu\n" + "".join(f"export {key}={shlex.quote(value)}\n" for key, value in exports.items())
        _write(wrapper, script + "exec " + shlex.join(
            [str(launcher), "--category", "Contas e conexões"]) + "\n", 0o700)
        content = ("[Desktop Entry]\nType=Application\nName=PhaseZero — Contas Codex\n"
                   "Comment=Gerenciar contas Codex Desktop, CLI e Web\n"
                   f'Exec="{_desktop_exec_path(wrapper)}"\nIcon=system-users\n'
                   "Terminal=false\nCategories=Development;\nX-PhaseZero-Managed=codex-profiles\n")
        paths = []
        for folder in (self.data / "applications", self.desktop_dir()):
            if folder == self.desktop_dir() and not folder.is_dir():
                continue
            path = folder / "phasezero-codex-accounts.desktop"
            if path.exists():
                if "X-PhaseZero-Managed=codex-profiles" not in path.read_text(encoding="utf-8"):
                    raise ProfileError("Atalho do painel alterado por terceiros; preservado.")
                backup_file(path, module="ai-codex-profiles")
            _write(path, content, 0o755)
            paths.append(str(path))
        ledger_record(module="ai-codex-profiles", action="panel-shortcut", created=paths + [str(wrapper)],
                      reversible=True)
        return {"installed": True, "count": len(paths)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pz ai codex-profiles")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--redacted", action="store_true", help="omite identificação local na saída")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("install-panel-shortcut")
    add = sub.add_parser("add")
    add.add_argument("--label")
    add.add_argument("--metadata-stdin", action="store_true")
    add.add_argument("--color", choices=COLORS, default="azul")
    rename = sub.add_parser("rename")
    rename.add_argument("id")
    rename.add_argument("--label")
    rename.add_argument("--metadata-stdin", action="store_true")
    rename.add_argument("--color", choices=COLORS, default="azul")
    for verb in ("open", "login", "shortcuts", "web", "archive", "restore"):
        command = sub.add_parser(verb)
        command.add_argument("id")
        if verb == "open":
            command.add_argument("--surface", choices=("desktop", "web", "browser"), default="desktop")
        if verb == "web":
            command.add_argument("args", nargs=argparse.REMAINDER)
    terminal = sub.add_parser("terminal")
    terminal.add_argument("id")
    terminal.add_argument("--task", choices=("login", "cli", "web-setup"), required=True)
    cli = sub.add_parser("cli")
    cli.add_argument("id")
    cli.add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    manager = CodexProfiles()
    try:
        if args.redacted and args.command in {"web", "cli", "login"}:
            raise ProfileError("Resumo redigido não encaminha comandos interativos. Use terminal próprio.")
        if args.command in {"add", "rename"}:
            if args.metadata_stdin:
                try:
                    metadata = json.loads(sys.stdin.read(4097))
                except ValueError:
                    raise ProfileError("Identificação local inválida.") from None
                if (not isinstance(metadata, dict) or set(metadata) != {"label", "color"}
                        or not isinstance(metadata["label"], str) or not isinstance(metadata["color"], str)):
                    raise ProfileError("Identificação local inválida.")
                args.label, args.color = metadata["label"], metadata["color"]
            if args.label is None:
                raise ProfileError("Informe apelido pelo painel ou --label.")
        if args.command == "list":
            result = manager.status()
        elif args.command == "install-panel-shortcut":
            result = manager.install_panel_shortcut()
        elif args.command == "add":
            result = manager.add(args.label, args.color)
        elif args.command == "rename":
            result = manager.rename(args.id, args.label, args.color)
        elif args.command == "shortcuts":
            result = manager.shortcuts(args.id)
        elif args.command in {"archive", "restore"}:
            result = manager.archive(args.id, restore=args.command == "restore")
        elif args.command == "open":
            result = manager.launch(args.id, args.surface)
        elif args.command == "terminal":
            result = manager.terminal(args.id, args.task)
        elif args.command == "web":
            from linux.ai.chatgpt_web_bridge import main as bridge_main
            bridge = manager.bridge(manager.require_active(args.id))
            if args.args[:1] in (["setup"], ["fetch"]):
                manager.prepare_native(manager.get(args.id))
                manager.prepare_web_package(args.id)
            # main's explicit env seam keeps one bridge implementation.
            exit_code = bridge_main(args.args, env=bridge.env)
            if args.args[:1] == ["setup"] and exit_code == 0 and args.id != "current":
                manager.shortcuts(args.id)
            return exit_code
        else:
            command, env = manager.cli_command(args.id, args.args if args.command == "cli" else [],
                                                login=args.command == "login")
            os.execvpe(command[0], command, env)
            return 0
    except (ProfileError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    except RuntimeError:
        print(json.dumps({"ok": False, "error": "Perfil Web indisponível; verifique setup deste ID."}))
        return 1
    if args.redacted:
        if args.command == "list":
            result = {"schemaVersion": 1, "total": len(result["profiles"]),
                      "secretsRedacted": True, "identityRedacted": True}
        else:
            result = {"ok": True, "operation": args.command, "identityRedacted": True}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
