from __future__ import annotations

from pathlib import Path

from ..catalog import CATEGORIES, DASHBOARD, build_catalog
from ..command_runner import CommandRunner

from .base import BasePage
from .dashboard import DashboardPage
from .overview import OverviewPage
from .profiles import ProfilesPage
from .homelab import HomelabPage
from .linux_hub import LinuxHubPage
from .emulation import EmulationPage
from .ai_proxies import AiProxiesPage
from .ai_routing import AiRoutingPage
from .ai_dev import AiDevPage
from .steamdeck import SteamDeckPage
from .tuning import TuningPage
from .results import ResultsPage
from .workspace import CatalogWorkspacePage
from .product_registry import ProductRegistryPage
from .development import DevelopmentPage
from .accounts import AccountsPage
from .windows_vm import WindowsVmPage
from .service_control import ServerPage, WaydroidPage
from .themes import ThemesPage


class PageRegistry:
    """Maps category names to page widget instances."""

    def __init__(self, root: Path, runner: CommandRunner) -> None:
        self.root = root
        self.runner = runner
        self.catalog = build_catalog(root)
        self.by_id = {a.id: a for a in self.catalog}
        self.cat_meta = {row[0]: row for row in (DASHBOARD, *CATEGORIES)}
        self._pages: dict[str, BasePage] = {}
        self._build()

    # Category -> page class mapping. Categories rendered by the generic
    # catalog workspace page are mapped directly; bespoke pages only survive
    # where they add real UI (Homelab, Emulação, Proxies/Roteamento IA, ...).
    _CATEGORY_PAGES: dict[str, type[BasePage]] = {
        "Início": DashboardPage,
        "Visão geral": OverviewPage,
        "Perfis": ProfilesPage,
        "Linux": LinuxHubPage,
        "Steam Deck": SteamDeckPage,
        "Windows VM": WindowsVmPage,
        "Waydroid": WaydroidPage,
        "Servidor": ServerPage,
        "Homelab": HomelabPage,
        "Emulação": EmulationPage,
        "Boot Direto": CatalogWorkspacePage,
        "Flatpak": CatalogWorkspacePage,
        "Recursos": CatalogWorkspacePage,
        "IA & Dev": AiDevPage,
        "Proxies IA": AiProxiesPage,
        "Roteamento IA": AiRoutingPage,
        "Aplicativos": ProductRegistryPage,
        "Desenvolvimento": DevelopmentPage,
        "Contas e conexões": AccountsPage,
        "Ajustes": TuningPage,
        "Temas": ThemesPage,
        "Resultados": ResultsPage,
    }

    def _build(self) -> None:
        for category, page_cls in self._CATEGORY_PAGES.items():
            actions = [a for a in self.catalog if a.category == category]
            page = page_cls(self.root, self.runner, actions, by_id=self.by_id)
            page.build()
            page.finalize_action_coverage()
            self._pages[category] = page

    def page_for(self, category: str) -> BasePage | None:
        return self._pages.get(category)

    def pages(self) -> tuple[BasePage, ...]:
        return tuple(self._pages.values())

    def block_all(self, running: bool) -> None:
        for page in self._pages.values():
            page.block_while_running(running)

    def set_advanced_mode(self, enabled: bool) -> None:
        for page in self._pages.values():
            page.set_advanced_mode(enabled)
