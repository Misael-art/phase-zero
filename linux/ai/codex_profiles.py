#!/usr/bin/env python3
"""Codex account profiles in the existing PhaseZero accounts domain.

Metadata contains no credentials. Codex and the Web bridge own their own login
stores. The current installation is referenced in place, never imported/copied.
"""
from __future__ import annotations

import argparse
import colorsys
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import stat
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
for _index in range(61):
    # Fixed palette: 64 custom colours plus the reserved primary blue.
    _rgb = colorsys.hsv_to_rgb((_index * 0.61803398875 + 0.02) % 1, 0.72, 0.78)
    COLORS[f"cor-{_index + 5:02d}"] = '#' + ''.join(f'{round(c * 255):02x}' for c in _rgb)
PROFILE_ID = re.compile(r"pz-[0-9a-f]{12}\Z")
CURRENT = {"id": "current", "label": "Principal", "color": "azul", "slot": 0}
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
        self._current = {**CURRENT, "label": _text(current["label"])}
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

    def add(self, label: str, color: str | None = None) -> dict:
        label = _text(label)
        with self.locked():
            rows = self.rows()
            if len(rows) >= MAX_PROFILES:
                raise ProfileError('Limite local de 64 perfis atingido.')
            used_colors = {'azul', *(row['color'] for row in rows)}
            if color is None:
                color = next((key for key in COLORS if key not in used_colors), None)
            if color not in COLORS or color in used_colors:
                raise ProfileError('Cor indisponível ou já usada por outro perfil. Escolha outra cor.')
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
            if ((profile_id == 'current' and color != 'azul')
                    or (profile_id != 'current' and (color == 'azul' or any(
                        r['id'] != profile_id and r['color'] == color for r in rows)))):
                raise ProfileError('Cor reservada ou já usada por outro perfil. Escolha outra cor.')
            row.update(label=label, color=color)
            self._save(rows)
        self.sync_appearance(row)
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

    def _profile_processes(self, row: dict) -> list[int]:
        """Read-only ownership probe; never stop apps or match profile nicknames."""
        base = str(self.profile_base(row))
        found = []
        for entry in Path('/proc').iterdir():
            if not entry.name.isdigit():
                continue
            try:
                if entry.stat().st_uid != os.getuid():
                    continue
                # Zombies have no live handles and must not block recovery.
                if (entry / 'stat').read_text().rsplit(')', 1)[1].split()[0] == 'Z':
                    continue
                # Desktop daemons such as kwin/sd-pam are non-dumpable even
                # for their user. Their private environment is not needed;
                # keep checking public argv and executable independently.
                try:
                    values = (entry / 'environ').read_bytes().split(b'\0')
                except PermissionError:
                    values = []
                owned = any(
                    key in {b'CODEX_HOME', b'XDG_CONFIG_HOME', b'XDG_STATE_HOME',
                            b'XDG_CACHE_HOME', b'CODEX_ELECTRON_USER_DATA_DIR',
                            b'CODEX_WEB_GPT_LAUNCHER_DATA_DIR', b'PZ_CHATGPT_WEB_ROOT'}
                    and os.fsdecode(value).startswith(base + '/')
                    for item in values if b'=' in item
                    for key, value in [item.split(b'=', 1)]
                )
                # Electron/Chromium may clear their environment and collapse argv.
                command = os.fsdecode((entry / 'cmdline').read_bytes())
                owned |= bool(re.search(r'(?:^|[\s\x00=])' + re.escape(base) + r'/', command))
                try:
                    owned |= os.readlink(entry / 'exe').startswith(base + '/')
                except PermissionError:
                    pass
                if owned:
                    found.append(int(entry.name))
            except (FileNotFoundError, ProcessLookupError):
                continue
            except PermissionError:
                raise ProfileError('Não foi possível verificar processos do usuário; limpeza bloqueada.') from None
        return sorted(found)

    def _removal_plan(self, row: dict) -> dict:
        if row['id'] == 'current':
            raise ProfileError('Codex padrão e seu Codex Web são protegidos contra exclusão.')
        self._check_paths(row)
        if self._profile_processes(row):
            raise ProfileError('Perfil ainda em uso. Use Sair no Desktop e feche CLI/navegador deste perfil antes de excluir.')
        bridge = self.bridge(row)
        if bridge.launcher_active():
            raise ProfileError('Codex Web deste perfil está ativo. Encerre seu launcher antes de excluir.')
        targets = [self.profile_base(row)]
        for folder in (self.data / 'applications', self.desktop_dir()):
            targets.extend(folder / f"phasezero-codex-{row['id']}-{surface}.desktop"
                           for surface in ('desktop', 'cli', 'web', 'browser'))
            targets.extend(folder / name for name in bridge.paths.shortcut_entries.values())
        targets.append(bridge.paths.managed_autostart)
        if bridge.paths.runtime:
            targets.append(bridge.paths.runtime)
        runtime = self.env.get('XDG_RUNTIME_DIR')
        desktop_runtime = set()
        if runtime:
            for mode in ('native', 'web'):
                port = self.profile_env(row, mode)['CODEX_WEBVIEW_PORT']
                directory = Path(runtime) / 'codex-desktop/instances' / f'port-{port}'
                if directory.exists():
                    if bridge.runner.port_in_use(int(port)):
                        raise ProfileError('Porta Desktop ainda em uso; limpeza bloqueada para preservar a instância.')
                    desktop_runtime.add(directory)
                    targets.append(directory)
        existing = []
        for target in dict.fromkeys(targets):
            if any(parent.is_symlink() for parent in (target, *target.parents)):
                raise ProfileError('Caminho de limpeza redirecionado por link simbólico; nada removido.')
            if not target.exists():
                continue
            if target == self.profile_base(row) or target == bridge.paths.runtime or target in desktop_runtime:
                if not target.is_dir() or target.stat().st_uid != os.getuid():
                    raise ProfileError('Diretório do perfil com proprietário/tipo inesperado; preservado.')
            else:
                mode = target.stat()
                if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.getuid() or mode.st_size > 65536:
                    raise ProfileError('Atalho de perfil alterado por terceiros; preservado.')
                text = target.read_text(encoding='utf-8')
                if target == bridge.paths.managed_autostart:
                    managed = text == bridge.autostart_entry_text()
                elif target.name in bridge.paths.shortcut_entries.values():
                    managed = str(bridge.paths.root) in text
                else:
                    managed = 'X-PhaseZero-Managed=codex-profiles' in text
                if not managed:
                    raise ProfileError('Atalho de perfil alterado por terceiros; preservado.')
            existing.append(target)
        ephemeral = {bridge.paths.runtime, *desktop_runtime}
        return {'row': row, 'paths': [p for p in existing if p not in ephemeral],
                'runtime': [p for p in existing if p in ephemeral]}

    def remove(self, profile_id: str | None = None, *, all_custom: bool = False,
               dry_run: bool = False) -> dict:
        """Detach custom installations; retain private, inactive recovery data.

        Preflight every account before touching any. Unknown/live ownership blocks
        cleanup instead of killing a primary app or losing an in-flight write.
        """
        if all_custom == (profile_id is not None):
            raise ProfileError('Selecione um perfil ou todas as instalações personalizadas.')
        with self.locked():
            rows = self.rows()
            selected = rows if all_custom else [self.get(profile_id)]
            plans = [self._removal_plan(row) for row in selected]
            result = {'removed': 0, 'selected': len(plans), 'primaryPreserved': True,
                      'primaryWebPreserved': True, 'dryRun': dry_run,
                      'remoteRevocation': False}
            if dry_run or not plans:
                return result
            recovery_root = self.root / 'removed'
            _private(recovery_root)
            recovery = recovery_root / uuid.uuid4().hex
            _private(recovery)
            # Same-filesystem rename keeps credentials out of logs and avoids
            # duplicating package/session data. Runtime sockets are disposable,
            # not copied across filesystems (copytree cannot copy Unix sockets).
            previous = self.registry.read_text() if self.registry.exists() else None
            moves = []
            try:
                manifest = {'schemaVersion': 1, 'profiles': selected, 'moves': []}
                for plan in plans:
                    for source in plan['paths']:
                        destination = recovery / str(len(manifest['moves']))
                        manifest['moves'].append({'source': str(source), 'backup': str(destination)})
                _write(recovery / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
                for item in manifest['moves']:
                    source, destination = Path(item['source']), Path(item['backup'])
                    shutil.move(str(source), str(destination))
                    moves.append((source, destination))
                removed = {row['id'] for row in selected}
                self._save([row for row in rows if row['id'] not in removed])
                ledger_record(module='ai-codex-profiles', action='remove',
                              modified=[str(self.registry), *(str(source) for source, _ in moves)],
                              backups=[str(recovery / 'manifest.json')],
                              reversible=True)
            except Exception:
                for source, destination in reversed(moves):
                    shutil.move(str(destination), str(source))
                if previous is not None:
                    _write(self.registry, previous)
                raise
            runtime_remaining = []
            for plan in plans:
                for directory in plan.get('runtime', []):
                    try:
                        shutil.rmtree(directory)
                    except FileNotFoundError:
                        pass
                    except OSError:
                        runtime_remaining.append(str(directory))
            return {**result, 'removed': len(plans), 'recovery': str(recovery),
                    'ok': not runtime_remaining,
                    'runtimeRemaining': runtime_remaining,
                    'guidance': 'Dados fora do ambiente ativo, em recuperação privada. '
                                'Conectores e túneis remotos não são revogados pela limpeza local.'}

    def profile_base(self, row: dict) -> Path:
        # Linux AF_UNIX paths are limited to 107 bytes. Keep runtime homes
        # shorter than the account metadata domain; never symlink credentials.
        return self.root / 'primary' if row['id'] == 'current' else self.runtime_root / row["id"]

    def browser_home(self, row: dict) -> Path:
        legacy = self.runtime_root / 'current/browser'
        if row['id'] == 'current' and legacy.exists():
            if any(p.is_symlink() for p in (legacy, *legacy.parents)):
                raise ProfileError('Perfil de navegador redirecionado; sessão preservada.')
            return legacy
        return self.profile_base(row) / 'browser'

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
        self.prepare_desktop_dirs(row)
        self.sync_appearance(row)

    def sync_appearance(self, row: dict) -> int:
        """A profile's native/Web Appearance follows its colour; default is untouched."""
        if row['id'] == 'current':
            return 0
        self._check_paths(row)
        from linux.ai.chatgpt_web_bridge import BridgeError, sync_account_appearance
        accent = COLORS[row['color']]
        bridge = self.bridge(row)
        changed = 0
        for path in (self.native_home(row) / 'config.toml', bridge.paths.codex_config):
            if not path.is_file():
                continue
            try:
                updated = sync_account_appearance(
                    path, accent, lambda target: backup_file(target, module='ai-codex-profiles'))
            except BridgeError as error:
                raise ProfileError(str(error)) from None
            if updated:
                changed += 1
                ledger_record(module='ai-codex-profiles', action='appearance',
                              modified=[str(path)], reversible=True)
        if bridge.paths.state.is_file():
            state = bridge.load_state()
            if state.get('accountAppearanceAccent') != accent:
                backup_file(bridge.paths.state, module='ai-codex-profiles')
                state['accountAppearanceAccent'] = accent
                bridge.save_state(state)
        return changed

    def prepare_desktop_dirs(self, row: dict) -> int:
        """Repair folder discovery for existing/new native and Web desktops."""
        if row["id"] == "current":
            return 0
        from linux.ai.chatgpt_web_bridge import sync_desktop_user_dirs
        self._check_paths(row)
        changed = 0
        for mode in ("native", "web"):
            target = self.profile_base(row) / "desktop" / mode / "config"
            existed = (target / "user-dirs.dirs").exists()
            if sync_desktop_user_dirs(self.home, self.config, target,
                                      lambda path: backup_file(path, module="ai-codex-profiles")):
                changed += 1
                ledger_record(module="ai-codex-profiles", action="desktop-directories",
                              created=[] if existed else [str(target / "user-dirs.dirs")],
                              modified=[str(target / "user-dirs.dirs")] if existed else [], reversible=True)
        return changed

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
            if row.get('color') in COLORS:
                env['PZ_CHATGPT_WEB_ACCOUNT_COLOR'] = COLORS[row['color']]
        return Bridge(env=env)

    def status(self) -> dict:
        profiles = self.rows()
        rows = [dict(self._current), *(row for row in reversed(profiles) if not row.get("archived")),
                *(row for row in reversed(profiles) if row.get("archived"))]
        # Local evidence only. Presence must never be called authenticated.
        return {"schemaVersion": 1, "profiles": [
            {**row, "nativeCredential": "present" if (self.native_home(row) / "auth.json").is_file()
             else "unknown", "session": "unverified", "quota": "unknown",
             "webConfigured": self.bridge(row).paths.state.is_file()}
            for row in rows], "cliInstalled": bool(shutil.which("codex", path=self.env.get("PATH"))),
            "desktopInstalled": bool(shutil.which("codex-desktop", path=self.env.get("PATH")))}

    @staticmethod
    def icon_svg(row: dict) -> str:
        template = (Path(__file__).with_name('assets') / 'codex-account.svg').read_text()
        if row['id'] == 'current':
            return template
        rgb = tuple(int(COLORS[row['color']][i:i + 2], 16) for i in (1, 3, 5))
        top = '#' + ''.join(f'{round(c + (255-c)*0.38):02x}' for c in rgb)
        bottom = '#' + ''.join(f'{round(c*0.90):02x}' for c in rgb)
        return template.replace('#aaa0ff', top).replace('#433bff', bottom)

    def launch(self, profile_id: str, surface: str) -> dict:
        with self.locked():
            return self._launch(profile_id, surface)

    def _launch(self, profile_id: str, surface: str) -> dict:
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
            profile = self.browser_home(row)
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
                        from linux.ai.chatgpt_web_bridge import focus_desktop_instance
                        pid = focus_desktop_instance(env)
                        if pid is not None:
                            return {"started": False, "focused": True, "profileId": profile_id,
                                    "surface": surface, "pid": pid}
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
        with self.locked():
            return self._terminal(profile_id, task)

    def _terminal(self, profile_id: str, task: str) -> dict:
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
        self.sync_appearance(row)
        folders = [self.data / "applications"]
        if self.desktop_dir().is_dir():
            folders.append(self.desktop_dir())
        if existing_only and not any(
                (folder / self.entry_name(row, surface)).is_file()
                for folder in folders for surface in ("desktop", "cli", "web", "browser")):
            return {"installed": False, "profileId": profile_id, "count": 0}
        base = self.profile_base(row)
        _private(self.runtime_root)
        _private(base)
        # Stable source root; project policy has one canonical checkout. Missing
        # checkout fails visibly, never selects a different account.
        pz = Path(__file__).resolve().parents[1] / "pz"
        icon = base / "account.svg"
        _write(icon, self.icon_svg(row))
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
                target = folder / self.entry_name(row, surface)
                if folder == self.desktop_dir() and surface in {'cli', 'browser'}:
                    if target.is_file() and 'X-PhaseZero-Managed=codex-profiles' in target.read_text():
                        backup_file(target, module='ai-codex-profiles')
                        target.unlink()
                    continue
                if existing_only and (not target.is_file() or
                        not any(marker in target.read_text(encoding="utf-8") for marker in
                                ('X-PhaseZero-Managed=codex-profiles', 'X-PhaseZero-Managed=chatgpt-web'))):
                    continue
                label_text = row["label"].replace("\\", "\\\\")
                content = ("[Desktop Entry]\nType=Application\n"
                           f"Name=Codex{' Web' if surface == 'web' else ''} {label_text}"
                           + (f' — {label}' if surface in {'cli', 'browser'} else '') + '\n'
                           f'Exec="{_desktop_exec_path(wrapper)}"\nIcon={icon}\n'
                           f"Terminal={str(terminal).lower()}\nCategories=Development;\n"
                           + (f"StartupWMClass=phasezero-codex-{profile_id}-browser\n" if surface == "browser"
                              else "StartupWMClass=codex-desktop\n" if surface in {"desktop", "web"} else "") +
                           "X-PhaseZero-Managed=codex-profiles\n")
                if surface in {'cli', 'browser'}:
                    content += 'NoDisplay=true\n'
                if surface == 'desktop':
                    if profile_id == 'current':
                        # Preserve packaged protocol handling, flags and actions.
                        system = self.primary_desktop_entry()
                        if system:
                            content = self.patch_desktop_entry(system.read_text(), {
                                'Name': f'Codex {label_text}', 'Icon': str(icon),
                                'NoDisplay': 'false', 'Hidden': 'false',
                                'X-PhaseZero-Managed': 'codex-profiles'})
                    else:
                        content += ('Actions=CLI;Browser;\n\n[Desktop Action CLI]\nName=Abrir CLI\n'
                                    f'Exec="{_desktop_exec_path(base / "open-cli.sh")}"\n'
                                    '\n[Desktop Action Browser]\nName=Abrir no navegador\n'
                                    f'Exec="{_desktop_exec_path(base / "open-browser.sh")}"\n')
                if target.exists():
                    if ("X-PhaseZero-Managed=codex-profiles" not in target.read_text(encoding="utf-8")
                            and not (profile_id == 'current' and (surface == 'desktop' or
                                'X-PhaseZero-Managed=chatgpt-web' in target.read_text()))):
                        raise ProfileError("Atalho alterado por terceiros; arquivo preservado.")
                    backup_file(target, module="ai-codex-profiles")
                _write(target, content, 0o755)
                paths.append(str(target))
        bridge = self.bridge(row)
        if bridge.paths.state.is_file():
            state = bridge.load_state()
            if state.get('accountShortcuts') != 'codex-profiles' or state.get('accountShortcutsRemoved'):
                backup_file(bridge.paths.state, module='ai-codex-profiles')
                state['accountShortcuts'] = 'codex-profiles'
                state.pop('accountShortcutsRemoved', None)
                bridge.save_state(state)
        if profile_id == 'current':
            # Earlier account shortcuts used different IDs from the native
            # package/bridge. Retire only those explicitly owned aliases.
            for folder in folders:
                for surface in ('desktop', 'web'):
                    old = folder / f'phasezero-codex-current-{surface}.desktop'
                    if (old.is_file() and not old.is_symlink()
                            and 'X-PhaseZero-Managed=codex-profiles' in old.read_text()):
                        backup_file(old, module='ai-codex-profiles')
                        old.unlink()
        ledger_record(module="ai-codex-profiles", action="shortcuts", created=paths + wrappers + [str(icon)],
                      reversible=True)
        return {"installed": True, "profileId": profile_id, "count": len(paths)}

    @staticmethod
    def entry_name(row: dict, surface: str) -> str:
        if row['id'] == 'current' and surface in {'desktop', 'web'}:
            return 'codex-desktop.desktop' if surface == 'desktop' else 'phasezero-chatgpt-web.desktop'
        return f"phasezero-codex-{row['id']}-{surface}.desktop"

    def primary_desktop_entry(self) -> Path | None:
        # XDG override keeps the existing desktop ID and taskbar/protocol links.
        for folder in (self.data / 'applications', Path('/usr/local/share/applications'),
                       Path('/usr/share/applications')):
            candidate = folder / 'codex-desktop.desktop'
            if candidate.is_file() and not candidate.is_symlink():
                return candidate
        return None

    @staticmethod
    def patch_desktop_entry(text: str, fields: dict[str, str]) -> str:
        main, separator, actions = text.partition('\n[Desktop Action')
        lines = main.splitlines()
        for key, value in fields.items():
            lines = [line for line in lines if not line.startswith(key + '=')
                     and not line.startswith(key + '[')]
            lines.append(f'{key}={value}')
        return '\n'.join(lines) + '\n' + (separator.lstrip('\n') + actions if separator else '')

    def organize(self, *, dry_run: bool = False) -> dict:
        """Reconcile presentation through the accounts owner; never uninstall apps."""
        if dry_run:
            rows = self.rows()
            return {'organized': False, 'dryRun': True, 'accounts': len(rows) + 1,
                    'visibleLaunchersPerActiveAccount': 2, 'primaryFirst': True,
                    'preservesApplicationsAndSessions': True}
        with self.locked():
            rows = self.rows()
            used = {'azul'}
            unavailable = {'azul', *(row['color'] for row in rows)}
            for row in rows:
                if row['color'] in used:
                    row['color'] = next(key for key in COLORS if key not in unavailable)
                    unavailable.add(row['color'])
                used.add(row['color'])
            if self._current['label'] == 'Conta atual':
                self._current['label'] = 'Principal'
            self._save(rows)
        for row in [self.get('current'), *rows]:
            if not row.get('archived'):
                self.shortcuts(row['id'])
        hidden = []
        # Old bridge's extra Tools entry remains invocable, but not a duplicate
        # menu item. Its desktop copy is backed up and removed.
        for folder in (self.data / 'applications', self.desktop_dir()):
            candidate = folder / 'phasezero-chatgpt-web-tools.desktop'
            if candidate.is_file() and not candidate.is_symlink():
                text = candidate.read_text()
                if 'X-PhaseZero-Managed=chatgpt-web' in text:
                    backup_file(candidate, module='ai-codex-profiles')
                    if folder == self.desktop_dir():
                        candidate.unlink()
                    else:
                        _write(candidate, self.patch_desktop_entry(text, {'NoDisplay': 'true'}), 0o755)
                    hidden.append(str(candidate))
        for candidate in (self.data / 'applications').glob('appimagekit_*.desktop'):
            if candidate.is_symlink() or not candidate.is_file():
                continue
            text = candidate.read_text()
            if ('X-AppImage-Old-Name=Codex Desktop' in text
                    and re.search(r'(?m)^Exec=[^\n]*codex-desktop[^\n]*\.AppImage(?: |$)', text)):
                backup_file(candidate, module='ai-codex-profiles')
                _write(candidate, self.patch_desktop_entry(text, {
                    'NoDisplay': 'true', 'X-PhaseZero-HiddenBy': 'codex-profiles'}), 0o755)
                hidden.append(str(candidate))
        # Existing bridge wrappers run their stable snapshot after reboot.
        for row in [self.get('current'), *rows]:
            bridge = self.bridge(row)
            if bridge.paths.manager_script.is_file():
                for path in (bridge.paths.manager_script, bridge.paths.manager_secret_store,
                             bridge.paths.manager_windows_secret_store):
                    backup_file(path, module='ai-codex-profiles')
                bridge.install_managed_entrypoint()
        ledger_record(module='ai-codex-profiles', action='organize-menu',
                      modified=hidden, reversible=True)
        return {'organized': True, 'accounts': len(rows) + 1, 'hiddenDuplicates': len(hidden)}

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
    organize = sub.add_parser('organize')
    organize.add_argument('--dry-run', action='store_true')
    remove = sub.add_parser('remove')
    selection = remove.add_mutually_exclusive_group(required=True)
    selection.add_argument('--id')
    selection.add_argument('--all-custom', action='store_true')
    remove.add_argument('--dry-run', action='store_true')
    add = sub.add_parser("add")
    add.add_argument("--label")
    add.add_argument("--metadata-stdin", action="store_true")
    add.add_argument("--color", choices=COLORS)
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
        elif args.command == 'organize':
            result = manager.organize(dry_run=args.dry_run)
        elif args.command == 'remove':
            result = manager.remove(args.id, all_custom=args.all_custom, dry_run=args.dry_run)
        elif args.command == "add":
            result = manager.add(args.label, args.color)
            manager.shortcuts(result['id'])
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
            # Keep creation/exec atomic relative to remove. registry.lock is
            # CLOEXEC: the new CLI's scoped environment becomes visible in
            # /proc before another cleaner can acquire this lock.
            with manager.locked():
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
            summary = {key: result[key] for key in ('removed', 'selected', 'dryRun',
                       'primaryPreserved', 'primaryWebPreserved', 'remoteRevocation',
                       'accounts', 'organized', 'hiddenDuplicates', 'visibleLaunchersPerActiveAccount',
                       'primaryFirst', 'preservesApplicationsAndSessions') if key in result}
            if 'runtimeRemaining' in result:
                summary['runtimeRemainingCount'] = len(result['runtimeRemaining'])
            result = {"ok": result.get('ok', True), "operation": args.command,
                      "identityRedacted": True, **summary}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 1 if result.get('ok') is False else 0


if __name__ == "__main__":
    raise SystemExit(main())
