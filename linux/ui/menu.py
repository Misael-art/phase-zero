#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import configparser
import json
import os
import re
import shlex
import shutil
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path


SCHEMA = "pz.desktop-menu/v1"


@dataclass(frozen=True)
class MenuItemSpec:
    desktop_id: str
    name: str
    group: str
    exec: str
    icon: str
    source: str


GROUPS: dict[str, tuple[str, str, str]] = {
    "games.library": ("Jogos e emulação", "Biblioteca e favoritos", "applications-games"),
    "games.frontends": ("Jogos e emulação", "Frontends", "applications-games"),
    "games.emulators": ("Jogos e emulação", "Emuladores", "applications-games"),
    "games.tools": ("Jogos e emulação", "Ferramentas", "preferences-system"),
    "web.communication": ("Apps web", "Comunicação", "applications-internet"),
    "web.media": ("Apps web", "Mídia", "applications-multimedia"),
    "web.ai": ("Apps web", "IA", "applications-science"),
    "web.cloud": ("Apps web", "Nuvem e documentos", "folder-remote"),
    "web.productivity": ("Apps web", "Produtividade", "office-applications"),
    "system.steamdeck": ("Sistema e sessões", "Steam Deck", "input-gaming"),
    "system.boot": ("Sistema e sessões", "Boot e recuperação", "system-reboot"),
    "system.machines": ("Sistema e sessões", "Máquinas e Android", "computer"),
    "system.tools": ("Sistema e sessões", "Ferramentas", "preferences-system"),
}


def xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")


def xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")


def xdg_state_home() -> Path:
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state")


def applications_dir() -> Path:
    return xdg_data_home() / "applications"


def directories_dir() -> Path:
    return xdg_data_home() / "desktop-directories"


def menu_dir() -> Path:
    return xdg_config_home() / "menus" / "applications-merged"


def state_dir() -> Path:
    return xdg_state_home() / "phasezero" / "desktop-menu"


def _read_desktop(path: Path) -> dict[str, str] | None:
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    try:
        parser.read(path, encoding="utf-8")
        section = parser["Desktop Entry"]
    except (OSError, KeyError, configparser.Error):
        return None
    return {key: value.strip() for key, value in section.items()}


def _managed(path: Path, values: dict[str, str]) -> bool:
    """Uma entrada é nossa se o nome, a categoria, a marca OU o Exec dizem isso.

    O reconhecimento por Exec é a rede de segurança: um lançador que o projeto
    criou sem prefixo `phasezero-` (por exemplo `claude-desktop.desktop`) ficava
    invisível para o menu unificado e, carregando `Categories` padrão, aparecia
    solto em Desenvolvimento/Jogos. Se o comando aponta para dentro do
    namespace PhaseZero, a entrada é nossa independentemente do nome.
    """
    filename = path.name.casefold()
    categories = values.get("Categories", "")
    if (
        filename.startswith(("phz-", "phasezero-", "io.phasezero."))
        or "X-PhaseZero" in categories
        or values.get("X-PhaseZero-Managed", "").casefold() == "true"
    ):
        return True
    return _exec_in_phasezero_namespace(values.get("Exec", ""))


_NAMESPACE_MARKERS = (
    "/.local/bin/phasezero-",
    "/.local/share/phasezero/",
    "/.local/state/phasezero/",
    "/usr/local/lib/phasezero/",
    "/linux/pz ",
)


def _exec_in_phasezero_namespace(command: str) -> bool:
    if not command:
        return False
    text = command.replace("\\", "/")
    if text.rstrip().endswith("/linux/pz"):
        return True
    return any(marker in text for marker in _NAMESPACE_MARKERS)


def _visible(path: Path, values: dict[str, str]) -> bool:
    if values.get("NoDisplay", "").casefold() == "true":
        return False
    categories = values.get("Categories", "")
    if "X-PhaseZero-PC" in categories or path.name.startswith("phasezero-pc-"):
        return values.get("X-PhaseZero-Favorite", "").casefold() == "true" or values.get(
            "X-PHZ-ShowInMenu", ""
        ).casefold() == "true"
    return True


def _normalize_exec(command: str) -> str:
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    functional = [token for token in tokens if not token.startswith("%")]
    if functional:
        candidate = Path(functional[0]).expanduser()
        if candidate.is_absolute():
            functional[0] = str(candidate.resolve(strict=False))
    return " ".join(functional)


def _group(path: Path, values: dict[str, str]) -> str:
    categories = values.get("Categories", "")
    declared = values.get("X-PHZ-Group", "").casefold()
    explicit = values.get("X-PhaseZero-MenuGroup", "")
    if explicit in GROUPS:
        return explicit
    text = " ".join((path.name, values.get("Name", ""), values.get("Exec", ""))).casefold()
    is_web_group = any(
        word in declared
        for word in ("comun", "communication", "mídia", "media", "nuvem", "docs", "cloud", "produt")
    ) or declared == "ia"
    if "X-PhaseZero-WebApp" in categories or is_web_group:
        if any(word in declared for word in ("comun", "communication")):
            return "web.communication"
        if any(word in declared for word in ("mídia", "media")):
            return "web.media"
        if declared == "ia" or "artificial" in declared:
            return "web.ai"
        if any(word in declared for word in ("nuvem", "docs", "cloud")):
            return "web.cloud"
        return "web.productivity"
    if "X-PhaseZero-Game" in categories:
        if "frontend" in declared:
            return "games.frontends"
        if "emulador" in declared or "emulator" in declared:
            return "games.emulators"
        if "ferrament" in declared or "tool" in declared:
            return "games.tools"
        return "games.library"
    if any(word in text for word in ("steamdeck", "steam-deck", "steamos", "handheld", "docked")):
        return "system.steamdeck"
    if any(word in text for word in ("boot", "grub", "recovery", "rescue")):
        return "system.boot"
    if any(word in text for word in ("waydroid", "windows-vm", "winvm", "virtualmachine")):
        return "system.machines"
    if any(word in text for word in ("retroarch", "dolphin", "pcsx2", "rpcs3", "vita3k", "duckstation", "citron", "eden")):
        return "games.emulators"
    return "system.tools"


def scan_items() -> tuple[list[MenuItemSpec], list[dict], int]:
    candidates: list[MenuItemSpec] = []
    hidden = 0
    app_dir = applications_dir()
    if app_dir.is_dir():
        for path in sorted(app_dir.glob("*.desktop")):
            values = _read_desktop(path)
            if values is None or not _managed(path, values):
                continue
            if not _visible(path, values):
                hidden += 1
                continue
            candidates.append(MenuItemSpec(
                desktop_id=path.name,
                name=values.get("Name", path.stem),
                group=_group(path, values),
                exec=values.get("Exec", ""),
                icon=values.get("Icon", "application-x-executable"),
                source=str(path),
            ))

    by_identity: dict[str, list[MenuItemSpec]] = {}
    for item in candidates:
        identity = _normalize_exec(item.exec) or f"desktop:{item.desktop_id}"
        by_identity.setdefault(identity, []).append(item)

    canonical: list[MenuItemSpec] = []
    duplicates: list[dict] = []
    for identity, items in by_identity.items():
        ranked = sorted(
            items,
            key=lambda item: (
                0 if item.desktop_id.startswith("io.phasezero.") else
                1 if item.desktop_id.startswith("phasezero-") else 2,
                item.desktop_id,
            ),
        )
        canonical.append(ranked[0])
        if len(ranked) > 1:
            duplicates.append({
                "identity": identity,
                "canonical": ranked[0].desktop_id,
                "suppressedInMenu": [item.desktop_id for item in ranked[1:]],
            })
    return sorted(canonical, key=lambda item: (item.group, item.name.casefold())), duplicates, hidden


def scan() -> dict:
    items, duplicates, hidden = scan_items()
    legacy = [
        str(path) for path in (menu_dir() / "phz-games.menu", menu_dir() / "phz-webapps.menu")
        if path.exists()
    ]
    return {
        "schema": SCHEMA,
        "kind": "scan",
        "status": "ok",
        "readOnly": True,
        "summary": {
            "managedVisible": len(items),
            "hidden": hidden,
            "duplicateGroups": len(duplicates),
            "legacyRoots": len(legacy),
        },
        "items": [asdict(item) for item in items],
        "duplicates": duplicates,
        "legacyRoots": legacy,
    }


def plan() -> dict:
    payload = scan()
    payload.update(
        kind="plan",
        targetMenu=str(menu_dir() / "phasezero.menu"),
        root="PhaseZero",
        removes=list(payload["legacyRoots"]),
        reversible=True,
    )
    return payload


def _directory_content(name: str, icon: str) -> str:
    return f"[Desktop Entry]\nType=Directory\nName={name}\nIcon={icon}\n"


def _directory_filename(label: str) -> str:
    safe = "".join(character if character.isalnum() else "-" for character in label.casefold())
    while "--" in safe:
        safe = safe.replace("--", "-")
    return f"phasezero-{safe.strip('-')}.directory"


def _render_menu(items: list[MenuItemSpec]) -> tuple[str, dict[str, str]]:
    directories: dict[str, str] = {
        "phasezero.directory": _directory_content("PhaseZero", "io.phasezero.ControlCenter")
    }
    root = ET.Element("Menu")
    ET.SubElement(root, "Name").text = "Applications"
    phasezero = ET.SubElement(root, "Menu")
    ET.SubElement(phasezero, "Name").text = "PhaseZero"
    ET.SubElement(phasezero, "Directory").text = "phasezero.directory"

    control = [item for item in items if item.desktop_id == "io.phasezero.ControlCenter.desktop"]
    if control:
        include = ET.SubElement(phasezero, "Include")
        ET.SubElement(include, "Filename").text = control[0].desktop_id

    branches: dict[str, ET.Element] = {}
    for group, (branch_name, leaf_name, icon) in GROUPS.items():
        group_items = [item for item in items if item.group == group and item not in control]
        if not group_items:
            continue
        branch = branches.get(branch_name)
        if branch is None:
            branch = ET.SubElement(phasezero, "Menu")
            ET.SubElement(branch, "Name").text = branch_name
            branch_file = _directory_filename(branch_name)
            ET.SubElement(branch, "Directory").text = branch_file
            directories[branch_file] = _directory_content(branch_name, icon)
            branches[branch_name] = branch
        leaf = ET.SubElement(branch, "Menu")
        ET.SubElement(leaf, "Name").text = leaf_name
        leaf_file = _directory_filename(f"{branch_name}-{leaf_name}")
        ET.SubElement(leaf, "Directory").text = leaf_file
        directories[leaf_file] = _directory_content(leaf_name, icon)
        include = ET.SubElement(leaf, "Include")
        for item in group_items:
            ET.SubElement(include, "Filename").text = item.desktop_id

    ET.indent(root, space="  ")
    xml = '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding="unicode") + "\n"
    return xml, directories


def _snapshot(paths: list[Path]) -> list[dict]:
    records: list[dict] = []
    for path in paths:
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            data = None
        records.append({
            "path": str(path),
            "content": base64.b64encode(data).decode("ascii") if data is not None else None,
            "mode": (path.stat().st_mode & 0o777) if data is not None else None,
        })
    return records


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def _isolated_desktop(path: Path, menu_group: str, *, suppressed_by: str = "") -> str:
    """Keep a managed launcher out of global categories.

    The unified menu includes canonical desktop IDs explicitly. Duplicate
    wrappers become NoDisplay overrides, while rollback retains exact bytes.
    """
    content = path.read_text(encoding="utf-8", errors="replace")
    category = "Categories=X-PhaseZero;"
    if re.search(r"(?m)^Categories=.*$", content):
        content = re.sub(r"(?m)^Categories=.*$", category, content, count=1)
    else:
        content = content.rstrip() + "\n" + category + "\n"
    managed = "X-PhaseZero-Managed=true"
    # Component owners use this field for integrity checks and safe repair.
    # Grouping a launcher must not erase e.g. codex-profiles/chatgpt-web.
    owner = re.search(r"(?m)^X-PhaseZero-Managed=(.*)$", content)
    if owner is None:
        content = content.rstrip() + "\n" + managed + "\n"
    elif not owner.group(1).strip():
        content = content[:owner.start()] + managed + content[owner.end():]
    group_line = f"X-PhaseZero-MenuGroup={menu_group}"
    if re.search(r"(?m)^X-PhaseZero-MenuGroup=.*$", content):
        content = re.sub(r"(?m)^X-PhaseZero-MenuGroup=.*$", group_line, content, count=1)
    else:
        content = content.rstrip() + "\n" + group_line + "\n"
    if suppressed_by:
        if re.search(r"(?m)^NoDisplay=.*$", content):
            content = re.sub(r"(?m)^NoDisplay=.*$", "NoDisplay=true", content, count=1)
        else:
            content = content.rstrip() + "\nNoDisplay=true\n"
        content = content.rstrip() + f"\nX-PhaseZero-SuppressedBy={suppressed_by}\n"
    return content if content.endswith("\n") else content + "\n"


def apply() -> dict:
    items, duplicates, hidden = scan_items()
    xml, directories = _render_menu(items)
    target = menu_dir() / "phasezero.menu"
    legacy = [menu_dir() / "phz-games.menu", menu_dir() / "phz-webapps.menu"]
    canonical_paths = [Path(item.source) for item in items]
    duplicate_paths = [
        applications_dir() / desktop_id
        for row in duplicates for desktop_id in row["suppressedInMenu"]
    ]
    targets = [
        target, *legacy, *canonical_paths, *duplicate_paths,
        *[directories_dir() / name for name in directories],
    ]
    manifest = {
        "schema": SCHEMA,
        "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "backup": _snapshot(targets),
    }
    state = state_dir()
    state.mkdir(parents=True, exist_ok=True)
    os.chmod(state, 0o700)
    manifest_path = state / f"apply-{time.strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:8]}.json"
    _atomic_write(target, xml)
    for name, content in directories.items():
        _atomic_write(directories_dir() / name, content)
    group_by_id = {item.desktop_id: item.group for item in items}
    for path in canonical_paths:
        _atomic_write(path, _isolated_desktop(path, group_by_id[path.name]))
    canonical_by_duplicate = {
        desktop_id: row["canonical"]
        for row in duplicates for desktop_id in row["suppressedInMenu"]
    }
    for path in duplicate_paths:
        canonical_id = canonical_by_duplicate[path.name]
        _atomic_write(
            path,
            _isolated_desktop(path, group_by_id[canonical_id], suppressed_by=canonical_id),
        )
    for path in legacy:
        path.unlink(missing_ok=True)
    fd = os.open(manifest_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    return {
        "schema": SCHEMA,
        "kind": "apply",
        "status": "ok",
        "menu": str(target),
        "items": len(items),
        "duplicatesSuppressed": sum(len(row["suppressedInMenu"]) for row in duplicates),
        "individualGamesHidden": hidden,
        "manifest": str(manifest_path),
    }


def _dirty_flag() -> Path:
    return state_dir() / "dirty"


def sync() -> dict:
    """Reagrupa o menu só quando alguma instalação o deixou sujo.

    Existe para o agrupamento não depender de o usuário lembrar de rodar
    `menu apply` depois de cada instalação. Os instaladores marcam sujo
    (`pz_menu_mark_dirty` em linux/lib/desktop.sh) e esta chamada é barata
    quando não há nada a fazer.
    """
    flag = _dirty_flag()
    if not flag.exists():
        return {
            "schema": SCHEMA,
            "kind": "sync",
            "status": "ok",
            "applied": False,
            "reason": "menu já sincronizado",
        }
    payload = apply()
    flag.unlink(missing_ok=True)
    payload.update(kind="sync", applied=True)
    return payload


def rollback() -> dict:
    manifests = sorted(state_dir().glob("apply-*.json"), reverse=True) if state_dir().is_dir() else []
    if not manifests:
        return {"schema": SCHEMA, "kind": "rollback", "status": "fail", "error": "manifesto não encontrado"}
    manifest_path = manifests[0]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for record in manifest.get("backup", []):
        path = Path(record["path"])
        encoded = record.get("content")
        if encoded is None:
            path.unlink(missing_ok=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(encoded))
        os.chmod(path, int(record.get("mode") or 0o644))
    return {"schema": SCHEMA, "kind": "rollback", "status": "ok", "manifest": str(manifest_path)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Menu PhaseZero unificado e reversível")
    parser.add_argument("command", choices=("scan", "plan", "apply", "sync", "rollback"))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    payload = {
        "scan": scan, "plan": plan, "apply": apply, "sync": sync, "rollback": rollback,
    }[args.command]()
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if payload.get("status") == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
