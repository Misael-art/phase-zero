"""Fachada KDE/Plasma para o motor de temas.

Princípios:
- Escrita cirúrgica em arquivos de configuração (grupo/chave), preservando o
  restante byte a byte. Rollback restaura cópias byte-level.
- Wallpaper por tela via API D-Bus do Plasma (evaluateScript). Nunca reescreve
  containments inteiros.
- Tudo é redirecionável por env para testes herméticos:
  PZ_THEMES_CONFIG_DIR, PZ_THEMES_STATE_DIR, PZ_THEMES_DBUS_CMD,
  PZ_THEMES_PROCESSES, PZ_THEMES_CRASH_LOG, PZ_THEMES_FAKE_JSON.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from . import state


def config_dir() -> Path:
    override = os.environ.get("PZ_THEMES_CONFIG_DIR")
    if override:
        return Path(override).expanduser()
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base


def config_path(name: str) -> Path:
    return config_dir() / name


def _split_sections(text: str) -> list[tuple[str | None, list[str]]]:
    """Divide INI em seções, preservando linhas e comentários."""
    sections: list[tuple[str | None, list[str]]] = []
    current: list[str] = []
    for raw in text.splitlines(keepends=True):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            sections.append((None, current))
            current = []
            sections.append((stripped, []))
        else:
            current.append(raw)
    if current or not sections:
        sections.append((None, current))
    return sections


def _join_sections(sections: list[tuple[str | None, list[str]]]) -> str:
    parts: list[str] = []
    for header, lines in sections:
        if header is not None:
            parts.append(header)
            parts.append("\n")
        parts.extend(lines)
    return "".join(parts)


def read_ini_key(path: Path, group: str, key: str) -> str:
    """Lê um valor de chave; retorna '' quando ausente."""
    if not path.exists():
        return ""
    text = path.read_text(encoding="utf-8", errors="replace")
    target = f"[{group}]"
    in_group = False
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("["):
            in_group = stripped == target
            continue
        if not in_group or not stripped or stripped.startswith("#") or stripped.startswith(";"):
            continue
        if "=" not in stripped:
            continue
        name, _, value = stripped.partition("=")
        if name.strip() == key:
            return value.strip()
    return ""


def set_ini_key(path: Path, group: str, key: str, value: str) -> bool:
    """Grava chave em grupo preservando o restante do arquivo byte a byte."""
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    sections = _split_sections(existing)
    header = f"[{group}]"
    target_index = next((i for i, (h, _) in enumerate(sections) if h == header), None)
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    if target_index is not None:
        lines = sections[target_index][1]
        replaced = False
        for index, line in enumerate(lines):
            stripped = line.lstrip()
            if key_re.match(stripped):
                lines[index] = f"{stripped[:len(stripped) - len(stripped.lstrip())]}{key}={value}\n"
                replaced = True
                break
        if not replaced:
            if lines and not lines[-1].endswith("\n"):
                lines[-1] += "\n"
            lines.append(f"{key}={value}\n")
    else:
        if existing and not existing.endswith("\n"):
            existing += "\n"
        sections.append((header, [f"{key}={value}\n"]))
    content = _join_sections(sections)
    temporary = path.with_suffix(f"{path.suffix}.{os.getpid()}.tmp")
    try:
        temporary.write_text(content, encoding="utf-8")
        if path.exists():
            # os.replace herda o modo do temp (umask); sem isso um
            # kdeglobals 0600 virava 0644 a cada escrita.
            shutil.copymode(path, temporary)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return True


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        digest.update(path.read_bytes())
    except OSError:
        return ""
    return digest.hexdigest()


def _run(argv: list[str], timeout: int = 15) -> tuple[int, str, str]:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        return 127, "", f"comando não encontrado: {argv[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def process_running(name: str) -> bool:
    """Verifica processo do usuário; env PZ_THEMES_PROCESSES simula em testes."""
    override = os.environ.get("PZ_THEMES_PROCESSES")
    if override is not None:
        return name in {item.strip() for item in override.split(",") if item.strip()}
    return _run(["pgrep", "-x", name])[0] == 0


def count_plasma_crashes(since_seconds: int = 60) -> int | None:
    """Conta crashes do plasmashell no período; None quando ilegível."""
    crash_log = os.environ.get("PZ_THEMES_CRASH_LOG")
    if crash_log:
        path = Path(crash_log).expanduser()
        try:
            return sum(
                1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
                if "plasmashell" in line
            )
        except OSError:
            return None
    journalctl = shutil.which("journalctl")
    if not journalctl:
        return None
    code, stdout, _ = _run(
        [
            journalctl, "--user", "--since", f"{since_seconds} seconds ago", "--no-pager", "-o", "cat",
        ],
        timeout=10,
    )
    if code != 0 and code != 1:
        return None
    return sum(
        1
        for line in stdout.splitlines()
        if "plasmashell" in line and any(token in line for token in ("crash", "segfault", "Segmentation", "core"))
    )


class ConfigWrite:
    """Snapshot byte-level de arquivos de configuração antes de mutar."""

    def __init__(self) -> None:
        self._files: list[Path] = []
        self._backups: list[Path] = []

    def track(self, *paths: Path) -> None:
        for path in paths:
            if path.exists() and path not in self._files:
                self._files.append(path)

    def capture(self) -> dict:
        records = []
        for path in self._files:
            digest = file_sha256(path)
            if not digest:
                continue
            backup_dir = state.root() / "config-backups"
            backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            backup = backup_dir / f"{hashlib.sha256(str(path).encode()).hexdigest()[:16]}-{digest[:12]}.cfg"
            # Backups are content addressed and shared between snapshots, so a
            # name that already exists was assumed to hold the right bytes and
            # was reused untouched - for weeks, across unrelated snapshots. If
            # such a file is ever truncated, edited or collides on the 48 bits
            # of digest in its name, every later rollback silently writes those
            # wrong bytes over the live configuration. Re-verify before reuse.
            if not backup.exists() or file_sha256(backup) != digest:
                shutil.copy2(path, backup)
                backup.chmod(0o600)
            self._backups.append(backup)
            records.append({"path": str(path), "sha256": digest, "backup": str(backup)})
        return {"files": records}

    def restore(self, records: list[dict]) -> None:
        for record in records:
            backup = Path(str(record["backup"]))
            target = Path(str(record["path"]))
            if not backup.exists():
                continue
            # The snapshot recorded what these bytes must hash to. Writing a
            # backup that no longer matches would replace a working config with
            # unknown content and call it a restore; skipping leaves the file as
            # the apply left it, which is recoverable and honest.
            expected = str(record.get("sha256", ""))
            if expected and file_sha256(backup) != expected:
                raise KdeStateError(
                    f"backup de {target.name} não confere com o snapshot; restauração recusada"
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup, target)


# Keys read back from a wallpaper plugin's config group. Containment exposes no
# configKeys() in Plasma 6, so the set has to be named explicitly.
WALLPAPER_CONFIG_KEYS = [
    "Image", "FillMode", "Color", "SlidePaths", "SlideInterval",
    "Provider", "Category",
    "SteamLibraryPath", "WallpaperWorkShopId", "WallpaperSource",
]


class KdeSession:
    """Operações reais sobre a sessão Plasma."""

    def __init__(self, facts) -> None:
        self.facts = facts

    # --- Configuração ----------------------------------------------------

    def config_path(self, name: str) -> Path:
        return config_path(name)

    def read_key(self, config: str, group: str, key: str) -> str:
        return read_ini_key(config_path(config), group, key)

    def write_key(self, config: str, group: str, key: str, value: str) -> None:
        # A live Plasma session keeps its own view of these files and flushes
        # it back later. A byte-level rewrite races that cache - the daemon
        # resurrected old keys alongside ours, leaving duplicates in the same
        # section. kwriteconfig goes through KConfig itself, so the daemon
        # stays in sync; the byte-level writer remains for environments
        # without the binary (headless, hermetic tests).
        if "][" in group:
            # Composite section headers (kscreenlockerrc's
            # [Greeter][Wallpaper][org.kde.image][General]) depend on the
            # literal bracket spelling; kwriteconfig's --group splitting may
            # not reproduce it. Byte-level keeps the section exact.
            set_ini_key(config_path(config), group, key, value)
            return
        binary = self.facts.binaries.get("kwriteconfig6") or self.facts.binaries.get("kwriteconfig5")
        if binary:
            code, _out, err = _run(
                [binary, "--file", str(config_path(config)), "--group", group, "--key", key, value],
                timeout=10,
            )
            if code != 0:
                raise KdeStateError(f"kwriteconfig falhou para {config} [{group}]/{key}: {err.strip()}")
            return
        set_ini_key(config_path(config), group, key, value)

    def notify(self) -> None:
        """Notifica KWin para recarregar configuração (best-effort)."""
        qdbus = self.facts.binaries.get("qdbus") or self.facts.binaries.get("qdbus6")
        if not qdbus:
            return
        _run([qdbus, "org.kde.KWin", "/KWin", "reconfigure"], timeout=5)

    _KWIN_EFFECT_DIRS = (
        "/usr/lib/qt6/plugins/kwin/effects/plugins",
        "/usr/lib64/qt6/plugins/kwin/effects/plugins",
        "/usr/lib/qt5/plugins/kwin/effects/plugins",
        "/usr/lib64/qt5/plugins/kwin/effects/plugins",
        "/usr/lib/kwin/effects/plugins",
        "/usr/lib64/kwin/effects/plugins",
        "/usr/local/lib/qt6/plugins/kwin/effects/plugins",
        "/usr/local/lib64/qt6/plugins/kwin/effects/plugins",
    )

    def effect_supported(self, name: str) -> bool | None:
        """Efeito existente neste KWin? None = indisponível para consultar.

        Efeitos não builtin só existem se o plugin estiver instalado; sem a
        checagem, escrever a chave de um efeito ausente produzia um
        "ligado" auto-consistente que nunca fez nada. Este KWin não expõe
        supportedEffects por D-Bus, então combina loadedEffects com a
        presença do .so do plugin nos diretórios padrão.
        """
        qdbus = self.facts.binaries.get("qdbus") or self.facts.binaries.get("qdbus6")
        if qdbus:
            code, stdout, _err = _run(
                [qdbus, "org.kde.KWin", "/Effects", "loadedEffects"], timeout=5
            )
            if code == 0 and name in stdout.split():
                return True
        import glob as _glob

        for pattern in self._KWIN_EFFECT_DIRS:
            if _glob.glob(f"{pattern}/*{name}*.so"):
                return True
        # Sem qdbus não dá para afirmar que não está carregado; com qdbus a
        # resposta negativa (não carregado + sem .so) é conclusiva.
        return False if qdbus else None

    # --- Aplicadores oficiais (fallback para escrita direta) -------------

    def apply_lookandfeel(self, package: str) -> None:
        binary = self.facts.binaries.get("plasma-apply-lookandfeel")
        if binary:
            # Unlike its colorscheme, cursortheme and desktoptheme siblings,
            # this tool takes the package through -a/--apply and treats a bare
            # positional as a usage error - for which it prints help and still
            # exits 0. Nothing was applied and nothing reported a failure, so
            # every global theme change silently did nothing.
            _run([binary, "--apply", package], timeout=20)
            return
        # The fallback wrote the look-and-feel id into plasmarc:[Theme]/name,
        # which holds a desktop theme name, corrupting one setting while
        # leaving the intended one untouched.
        self.write_key("kdeglobals", "KDE", "LookAndFeelPackage", package)

    def apply_colorscheme(self, name: str) -> None:
        binary = self.facts.binaries.get("plasma-apply-colorscheme")
        if binary:
            _run([binary, name], timeout=20)
            return
        self.write_key("kdeglobals", "General", "ColorScheme", name)

    def apply_cursortheme(self, name: str, size: int) -> None:
        binary = self.facts.binaries.get("plasma-apply-cursortheme")
        if binary:
            _run([binary, name], timeout=20)
            return
        self.write_key("kcminputrc", "Mouse", "cursorTheme", name)
        if size:
            self.write_key("kcminputrc", "Mouse", "cursorSize", str(size))

    # --- D-Bus do Plasma -------------------------------------------------

    def dbus_script(self, script: str) -> tuple[int, str, str]:
        """Executa evaluateScript no plasmashell; PZ_THEMES_DBUS_CMD injeta stub em testes."""
        cmd = os.environ.get("PZ_THEMES_DBUS_CMD")
        if cmd:
            import shlex

            argv = [*shlex.split(cmd), script]
        else:
            qdbus = self.facts.binaries.get("qdbus") or self.facts.binaries.get("qdbus6")
            if not qdbus:
                return 127, "", "qdbus não disponível"
            argv = [qdbus, "org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell.evaluateScript", script]
        return _run(argv, timeout=20)

    # Read by name, since the keys cannot be enumerated. Covers the stock
    # plugins and Wallpaper Engine; a key absent from a given plugin simply
    # comes back empty and is omitted.
    def _wallpaper_read_script(self) -> str:
        return (
            "var out = desktops().map(function(d) {"
            "  var cfg = {};"
            # Two faults made wallpaper configuration unreadable. The group has
            # to be selected first, or these keys belong to the containment
            # rather than the wallpaper plugin. And Containment has no
            # configKeys() in Plasma 6, so enumerating threw a TypeError that
            # the surrounding catch swallowed into an empty object - every read
            # returned {} and any check based on it was meaningless.
            "  try { d.currentConfigGroup = ['Wallpaper', d.wallpaperPlugin, 'General'];"
            f"    var names = {json.dumps(WALLPAPER_CONFIG_KEYS)};"
            "    for (var i = 0; i < names.length; i++) {"
            "      var v = d.readConfig(names[i]);"
            "      if (v !== undefined && v !== null && String(v) !== '') { cfg[names[i]] = String(v); }"
            "    }"
            "  } catch (e) { cfg['_error'] = String(e); }"
            "  return {id: String(d.id), screen: d.screen, wallpaperPlugin: d.wallpaperPlugin,"
            "          wallpaperMode: d.wallpaperMode, config: cfg};"
            "});"
            "print(JSON.stringify(out));"
        )

    def read_wallpapers(self) -> list[dict]:
        """Lê wallpaper de cada monitor via D-Bus (somente leitura)."""
        code, stdout, stderr = self.dbus_script(self._wallpaper_read_script())
        if code != 0:
            raise KdeStateError(f"estado KDE ilegível: {stderr.strip() or 'falha na avaliação D-Bus'}")
        text = stdout.strip()
        start = text.find("[")
        if start < 0:
            raise KdeStateError("estado KDE ilegível: resposta D-Bus sem JSON")
        try:
            payload = json.loads(text[start:])
        except json.JSONDecodeError as exc:
            raise KdeStateError(f"estado KDE ilegível: JSON inválido ({exc})") from exc
        items = payload if isinstance(payload, list) else []
        # Rollback restores by desktop array index: several containments report
        # the same screen number (-1 for "unbound"), so a screen-equality match
        # collapsed every one of them onto the first and the last restore won.
        for index, item in enumerate(items):
            item["desktopIndex"] = index
        return items

    def write_wallpaper(
        self,
        screen: int,
        plugin: str,
        params: dict,
        *,
        mode: str = "SingleImage",
        slide_paths: list[str] | None = None,
        desktop_index: int | None = None,
    ) -> None:
        """Aplica wallpaper em um monitor via D-Bus, sem reescrever containments.

        `desktop_index` endereça o containment direto pelo índice do array
        `desktops()`; sem ele, cai na busca por `screen`.
        """
        body = [
            # Assigning wallpaperPlugin resets the current config group, so
            # selecting the group first sent every writeConfig below into
            # whatever group the switch left selected. The plugin was applied
            # and its settings silently went nowhere, leaving the new wallpaper
            # with no content to show.
            f'  d.wallpaperPlugin = "{plugin}";',
            f'  d.wallpaperMode = "{mode}";',
            f'  d.currentConfigGroup = ["Wallpaper", "{plugin}", "General"];',
        ]
        for key, value in params.items():
            body.append(f'  d.writeConfig("{key}", {json.dumps(str(value))});')
        if slide_paths:
            encoded = ", ".join(json.dumps(str(item)) for item in slide_paths)
            body.append(f'  d.writeConfig("ImageSources", [{encoded}]);')
        body.append(f'  d.reloadConfig(); print("OK_" + {screen}); }}')
        if desktop_index is not None:
            parts = [
                'var ds = desktops();',
                f'if (ds.length <= {int(desktop_index)}) {{ print("NO_SCREEN_" + {screen}); }} else {{',
                f'  var d = ds[{int(desktop_index)}];',
                *body,
            ]
        else:
            parts = [
                f'var d = null; var ds = desktops();',
                f'for (var i = 0; i < ds.length; i++) {{ if (ds[i].screen === {screen}) {{ d = ds[i]; break; }} }}',
                f'if (!d) {{ print("NO_SCREEN_" + {screen}); }} else {{',
                *body,
            ]
        code, stdout, stderr = self.dbus_script("".join(parts))
        if code != 0:
            raise KdeStateError(f"falha ao aplicar wallpaper na tela {screen}: {stderr.strip()}")
        if "OK_" not in stdout:
            raise KdeStateError(f"tela {screen} não encontrada entre os desktops do Plasma")

    # --- Tela de bloqueio ------------------------------------------------

    def lock_screen_params(self, params: dict) -> None:
        for key, value in params.items():
            self.write_key("kscreenlockerrc", "Greeter][Wallpaper][org.kde.image][General", key, value)

    def read_lock_screen_image(self) -> str:
        return self.read_key(
            "kscreenlockerrc",
            "Greeter][Wallpaper][org.kde.image][General",
            "Image",
        ).replace("file://", "")

    # --- Processos -------------------------------------------------------

    def start_process(self, name: str, args: list[str]) -> dict:
        pidfile = state.root() / "processes" / f"{name}.pid"
        pidfile.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if process_running(name):
            return {"started": False, "reason": "já em execução"}
        env = dict(os.environ)
        proc = subprocess.Popen(
            args,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
        pidfile.write_text(f"{proc.pid}\n", encoding="utf-8")
        pidfile.chmod(0o600)
        return {"started": True, "pid": proc.pid}

    def stop_process(self, name: str) -> dict:
        pidfile = state.root() / "processes" / f"{name}.pid"
        if not pidfile.exists():
            return {"stopped": False, "reason": "nenhum processo gerenciado"}
        try:
            pid = int(pidfile.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            pidfile.unlink(missing_ok=True)
            return {"stopped": False, "reason": "PID ilegível; encerrado sem ação"}
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
        except OSError:
            return {"stopped": False, "reason": "permissão negada para encerrar processo"}
        pidfile.unlink(missing_ok=True)
        return {"stopped": True, "pid": pid}


class KdeStateError(RuntimeError):
    """Estado KDE ilegível ou operação D-Bus falhou — falha fechado."""
