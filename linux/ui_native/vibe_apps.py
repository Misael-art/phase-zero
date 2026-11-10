from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Shortcut:
    name: str
    detail: str
    desktop_ids: tuple[str, ...] = ()
    command: str = ""
    product: str = ""
    menu_name: str = ""


SHORTCUTS = (
    Shortcut("OpenCode Desktop", "Interface de desenvolvimento", ("opencode-desktop.desktop", "ai.opencode.desktop.desktop"), product="app.opencode"),
    Shortcut("Codex Desktop", "Projetos e tarefas do Codex", ("codex-desktop.desktop",), product="app.codex-desktop"),
    Shortcut("Claude Desktop", "Claude e sessões Claude Code", ("claude-desktop.desktop",), product="app.claude-desktop"),
    Shortcut("Codex CLI", "Terminal na pasta do projeto", command="codex", product="app.codex"),
    Shortcut("Claude Code", "Terminal na pasta do projeto", command="claude", product="app.claude-code"),
    Shortcut("OpenCode CLI", "Terminal na pasta do projeto", command="opencode", product="app.opencode"),
    Shortcut("OpenClaw", "Aplicativo instalado pelo operador", menu_name="OpenClaw"),
    Shortcut("Fôlego", "Voz e acessibilidade", ("folego.desktop",)),
    Shortcut("DeepSeek Harness", "Agente de desenvolvimento", ("phasezero-deepseek-harness.desktop",), product="app.deepseek-harness"),
    Shortcut("Grok Build", "Agente de desenvolvimento", ("phasezero-grok-build.desktop",), product="app.grok-build"),
    Shortcut("Qwen Code Desktop", "Interface Qwen Code", ("qwen-code-desktop.desktop",), product="app.qwen-code-desktop"),
)


@dataclass(frozen=True)
class AppEntry:
    shortcut: Shortcut
    desktop: Any = None
    command: str = ""
    catalog_only: bool = False

    @property
    def ready(self) -> bool:
        return self.desktop is not None or bool(self.command)


def read_apps() -> tuple[list[AppEntry], list[AppEntry], bool]:
    """Use the desktop's XDG inventory, including its precedence and visibility."""
    try:
        from gi.repository import Gio
    except ImportError:
        Gio = None
    installed = Gio.AppInfo.get_all() if Gio else []
    by_id = {item.get_id(): item for item in installed}
    visible = sorted(
        (item for item in installed if item.should_show()),
        key=lambda item: item.get_display_name().casefold(),
    )
    assigned: set[str] = set()
    featured = []
    for shortcut in SHORTCUTS:
        desktop = None
        if Gio:
            for entry_id in shortcut.desktop_ids:
                item = by_id.get(entry_id)
                if item is not None and not item.get_is_hidden() and shutil.which(item.get_executable() or ""):
                    desktop = item
                    break
            if desktop is None and shortcut.menu_name:
                desktop = next((
                    item for item in visible
                    if item.get_name().startswith(shortcut.menu_name)
                    and shutil.which(item.get_executable() or "")
                ), None)
        if desktop is not None:
            assigned.update(shortcut.desktop_ids)
            assigned.add(desktop.get_id())
        command = (shutil.which(shortcut.command) or "") if shortcut.command else ""
        featured.append(AppEntry(shortcut, desktop, command))
    other = [
        AppEntry(Shortcut(item.get_display_name(), item.get_description() or "Aplicativo do menu do sistema"), item)
        for item in visible
        if item.get_id() not in assigned and item.get_id() != "phasezero-vibe-code.desktop"
    ]
    inventory = Path(__file__).with_name("product_inventory.json")
    try:
        products = json.loads(inventory.read_text(encoding="utf-8")).get("products", [])
    except (OSError, ValueError, AttributeError):
        products = []
    pinned_products = {entry.shortcut.product for entry in featured}
    other.extend(
        AppEntry(Shortcut(
            product["name"], product.get("description") or product["group"],
            product=product["appId"],
        ), catalog_only=True)
        for product in products if product["appId"] not in pinned_products
    )
    return featured, other, Gio is not None
