"""Resolução do ícone original de um app, sem baixar nada.

Cascata, do mais específico ao mais genérico:

  1. ícone declarado no overlay (curadoria explícita vence sempre)
  2. `Icon=` do `.desktop` instalado no host (é o logo real do app)
  3. nome do tema derivado da fonte (app id do Flatpak / nome do pacote)
  4. fallback semântico da seção

Regras que valem a pena declarar:

- nada de rede. Logo de app é conteúdo de terceiro; buscar online colocaria a
  UI dependente de disponibilidade e ainda vazaria quais apps o usuário tem.
- só é lido `.desktop` de diretórios XDG padrão. `Icon=` com caminho absoluto
  só é aceito se o arquivo existir e estiver dentro desses diretórios ou dos
  diretórios de ícones — um `.desktop` de terceiro não escolhe caminho livre.
- a resolução é pura: recebe as raízes e devolve uma referência. Quem
  transforma em QIcon é a camada de widget.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping

# Ícone de tema por seção, quando não há nada melhor.
SECTION_FALLBACK = {
    "Gaming e streaming": "applications-games",
    "Hardware e drivers": "preferences-desktop-peripherals",
    "Saúde e desempenho": "utilities-system-monitor",
    "Segurança e privacidade": "security-high",
    "Backup e nuvem": "drive-multidisk",
    "Desenvolvimento": "applications-development",
    "Criação e produtividade": "applications-graphics",
    "Administração": "preferences-system",
    "Educação": "applications-science",
    "Ajustes do sistema": "preferences-system",
    "Ferramentas": "applications-utilities",
}

GENERIC_FALLBACK = "package-x-generic"


@dataclass(frozen=True)
class IconRef:
    """`kind` diz como usar `value`: nome de tema ou caminho de arquivo."""

    kind: str  # theme | file
    value: str
    origin: str  # overlay | desktop | source | section | generic

    @property
    def is_original(self) -> bool:
        """Veio do app de verdade, não de um ícone genérico do tema."""
        return self.origin in {"desktop", "source"}


def desktop_dirs(environ: Mapping[str, str] | None = None) -> tuple[Path, ...]:
    env = environ if environ is not None else os.environ
    home = Path(env.get("HOME", str(Path.home())))
    data_home = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
    raw_dirs = env.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    roots = [data_home, *(Path(part) for part in raw_dirs.split(":") if part)]
    # Exports do Flatpak não estão em XDG_DATA_DIRS em toda distro, e é
    # justamente onde mora o ícone do app instalado por Flatpak.
    roots.extend((
        data_home / "flatpak/exports/share",
        Path("/var/lib/flatpak/exports/share"),
    ))
    seen: list[Path] = []
    for root in roots:
        applications = root / "applications"
        if applications.is_dir() and applications not in seen:
            seen.append(applications)
    return tuple(seen)


def _read_icon_key(path: Path) -> str:
    """Valor de `Icon=` da seção [Desktop Entry], ou vazio.

    Parser deliberadamente mínimo: o arquivo é dado de terceiro, então nada de
    executar, seguir link ou confiar em tamanho. Só a primeira ocorrência da
    chave dentro da seção correta.
    """
    try:
        if path.is_symlink() and not path.resolve().is_file():
            return ""
        if path.stat().st_size > 256 * 1024:
            return ""
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    in_entry = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_entry = stripped == "[Desktop Entry]"
            continue
        if not in_entry or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        if key.strip() == "Icon":
            return value.strip()
    return ""


def _candidate_basenames(source_kind: str, source_name: str) -> tuple[str, ...]:
    if not source_name:
        return ()
    if source_kind in {"flatpak", "desktop-entry"}:
        # App id é o nome do arquivo exportado, sem exceção.
        return (source_name,)
    # Pacotes: o `.desktop` costuma repetir o nome do binário; variações com
    # sufixo de versão (dotnet-sdk-8.0) caem no prefixo antes do primeiro dígito.
    trimmed = source_name.split("-")[0]
    return tuple(dict.fromkeys(name for name in (source_name, trimmed) if name))


def find_desktop_icon(
    source_kind: str,
    source_name: str,
    roots: Iterable[Path],
) -> tuple[str, Path | None]:
    """(valor de Icon=, arquivo .desktop) do app instalado, ou ("", None)."""
    for basename in _candidate_basenames(source_kind, source_name):
        for root in roots:
            entry = root / f"{basename}.desktop"
            if not entry.is_file():
                continue
            icon = _read_icon_key(entry)
            if icon:
                return icon, entry
    return "", None


def find_desktop_entry(
    source_kind: str,
    source_name: str,
    roots: Iterable[Path],
) -> Path | None:
    """Return a desktop entry constrained to the supplied XDG application roots."""
    for basename in _candidate_basenames(source_kind, source_name):
        for root in roots:
            entry = root / f"{basename}.desktop"
            try:
                resolved = entry.resolve(strict=True)
                resolved.relative_to(root.resolve(strict=True))
            except (OSError, ValueError):
                continue
            if resolved.is_file():
                return resolved
    return None


def _is_allowed_icon_path(path: Path, roots: Iterable[Path]) -> bool:
    try:
        resolved = path.resolve()
    except OSError:
        return False
    if not resolved.is_file():
        return False
    allowed = [root.parent for root in roots]
    allowed.extend((Path("/usr/share/icons"), Path("/usr/share/pixmaps")))
    for base in allowed:
        try:
            resolved.relative_to(base.resolve())
            return True
        except (OSError, ValueError):
            continue
    return False


def resolve_icon(
    item,
    *,
    overlay_icon: str = "",
    roots: Iterable[Path] | None = None,
    has_theme_icon: Callable[[str], bool] | None = None,
) -> IconRef:
    """Melhor ícone disponível para um `HubItem`.

    `has_theme_icon` permite à camada Qt informar se o tema tem o ícone; sem
    ela, presume-se que tem (o widget ainda cai no fallback padrão dele).
    """
    search_roots = tuple(roots) if roots is not None else desktop_dirs()
    if overlay_icon:
        return IconRef("theme", overlay_icon, "overlay")

    icon_value, _entry = find_desktop_icon(
        getattr(item, "source_kind", ""), getattr(item, "source_name", ""), search_roots,
    )
    if icon_value:
        if icon_value.startswith("/"):
            candidate = Path(icon_value)
            if _is_allowed_icon_path(candidate, search_roots):
                return IconRef("file", str(candidate), "desktop")
        else:
            return IconRef("theme", icon_value, "desktop")

    source_name = getattr(item, "source_name", "")
    if source_name and (has_theme_icon is None or has_theme_icon(source_name)):
        return IconRef("theme", source_name, "source")

    section = getattr(item, "section", "")
    fallback = SECTION_FALLBACK.get(section)
    if fallback:
        return IconRef("theme", fallback, "section")
    declared = getattr(item, "icon", "")
    return IconRef("theme", declared or GENERIC_FALLBACK, "generic")
