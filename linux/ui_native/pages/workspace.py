from __future__ import annotations

from collections import OrderedDict
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame,
    QButtonGroup,
    QHBoxLayout,
    QLabel,
    QRadioButton,
    QScrollArea,
    QStackedWidget,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import ActionListRow, ContextRail, SectionHeader
from .base import BasePage


_ADVANCED_TERMS = (
    "privileged", "secret", "reset", "uninstall", "remove", "rollback",
    "delete", "efi", "grub", "raw", "low-level",
)
_MAINTENANCE_TERMS = (
    "repair", "reparo", "fix", "clean", "limpar", "audit", "doctor",
    "diagnóst", "update", "restore", "backup", "verify", "health",
)

_CATEGORY_RULES: dict[str, tuple[tuple[str, tuple[str, ...]], ...]] = {
    "Steam Deck": (
        ("Visão geral", ("status", "detect", "runtime", "launch-options")),
        ("Sessão", ("handheld", "docked", "console", "desktop", "boot", "display")),
        ("Controles", ("keyboard", "hotkeys", "tdp", "watcher", "removable")),
        ("Plugins", ("plugin", "theme", "decky")),
    ),
    "Emulação": (
        ("Visão geral", ("status", "setup", "doctor", "fixes", "layout")),
        ("Biblioteca e mídia", ("media", "shared", "bios", "keys", "firmware", "nsz", "ps3", "rom")),
        ("Frontends", ("emudeck", "retrodeck", "srm", "launchbox", "bigbox", "frontend", "eden", "citron", "hydra")),
        ("Controles", ("controller", "performance", "optimizer", "lsfg", "shortcut")),
    ),
    "Windows VM": (
        ("Visão geral", ("status", "discover", "plan")),
        ("Máquina virtual", ("install", "launch", "disk", "iso", "adopt")),
        ("Integração", ("share", "host-access", "optimize", "fullscreen")),
    ),
    "Waydroid": (
        ("Visão geral", ("status", "plan")),
        ("Sessão Android", ("install", "launch", "kiosk", "boot")),
        ("Integração", ("host-access", "share", "storage")),
    ),
    "Servidor": (
        ("Visão geral", ("status", "plan", "doctor")),
        ("Serviços", ("up", "start", "stop", "restart", "open", "logs")),
        ("Dados", ("backup", "restore", "storage", "update")),
        ("Acesso", ("tailscale", "network", "casaos", "remote")),
    ),
    "Boot Direto": (
        ("Testar distros", ("boot.iso.",)),
        ("Visão geral", ("status", "list", "detect")),
        ("Próxima sessão", ("choose", "selector", "next", "menu")),
        ("Recuperação", ("recovery", "rescue", "repair", "restore")),
    ),
    "Flatpak": (
        ("Visão geral", ("status", "audit", "remote")),
        ("Aplicativos", ("install", "update", "compat")),
        ("Permissões", ("override", "permission", "sandbox")),
    ),
    "IA & Dev": (
        ("Visão geral", ("status", "doctor", "usage", "token-economy")),
        ("Agentes", ("codex", "claude", "opencode", "omo", "hermes", "openclaw")),
        ("MCPs", ("mcp", "memory", "context")),
        ("Modelos e proxies", ("model", "ollama", "proxy", "auth", "login")),
    ),
    "Aplicativos": (
        ("Visão geral", ("status", "scan", "list")),
        ("Web apps", ("webapp",)),
        ("Jogos", ("game", "launcher")),
    ),
}


def action_section(category: str, action: ActionSpec) -> str:
    if category == "Boot Direto" and action.id.startswith("boot.iso."):
        return "Testar distros"
    text = f"{action.id} {action.title}".casefold()
    if action.visibility == "advanced" or action.risk in {"elevated", "high"} or any(
        term in text for term in _ADVANCED_TERMS
    ):
        return "Avançado"
    for section, terms in _CATEGORY_RULES.get(category, ()):
        if any(term in text for term in terms):
            return section
    if any(term in text for term in _MAINTENANCE_TERMS):
        return "Manutenção"
    return "Operações"


def grouped_actions(category: str, actions: list[ActionSpec]) -> OrderedDict[str, list[ActionSpec]]:
    if category == "Recursos":
        groups: OrderedDict[str, list[ActionSpec]] = OrderedDict()
        preferred = (
            "Visão geral", "Perfis prontos", "Gaming e streaming",
            "Hardware e drivers", "Saúde e desempenho", "Segurança e privacidade",
            "Backup e nuvem", "Desenvolvimento", "Criação e produtividade",
            "Administração", "Educação", "Operação e recuperação",
        )
        for group in preferred:
            matches = [action for action in actions if action.group == group]
            if matches:
                groups[group] = matches
        for action in actions:
            groups.setdefault(action.group, [])
            if action not in groups[action.group]:
                groups[action.group].append(action)
        return groups
    groups: OrderedDict[str, list[ActionSpec]] = OrderedDict()
    for action in actions:
        groups.setdefault(action_section(category, action), []).append(action)
    preferred = [
        section for section, _terms in _CATEGORY_RULES.get(category, ())
    ] + ["Operações", "Manutenção", "Avançado"]
    ordered: OrderedDict[str, list[ActionSpec]] = OrderedDict()
    for section in preferred:
        if section in groups:
            ordered[section] = groups.pop(section)
    ordered.update(groups)
    return ordered


class CatalogWorkspacePage(BasePage):
    """Consistent context navigation and action lists for operational modules."""

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.category = actions[0].category if actions else "Módulo"
        self.rows: dict[str, ActionListRow] = {}
        self.rail: ContextRail | None = None
        self.stack: QStackedWidget | None = None

    def build(self) -> None:
        groups = grouped_actions(self.category, self.actions)
        workspace = QWidget()
        workspace.setObjectName("moduleWorkspace")
        layout = QHBoxLayout(workspace)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(14)
        self.rail = ContextRail(list(groups))
        layout.addWidget(self.rail)
        self.stack = QStackedWidget()
        self.stack.setObjectName("contextStack")
        for section, actions in groups.items():
            self.stack.addWidget(self._section_page(section, actions))
        self.rail.section_changed.connect(self.stack.setCurrentIndex)
        layout.addWidget(self.stack, 1)
        self._layout.addWidget(workspace, 1)

    def _section_page(self, section: str, actions: list[ActionSpec]) -> QWidget:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(12)
        captions = {
            "Visão geral": "Estado, descoberta e próximos passos do módulo.",
            "Operações": "Jornadas principais organizadas por intenção.",
            "Manutenção": "Diagnóstico, reparo e preservação do ambiente.",
            "Avançado": "Operações raras ou sensíveis. Revise impacto antes de executar.",
        }
        layout.addWidget(SectionHeader(section, captions.get(section, f"{len(actions)} operações disponíveis.")))
        choice_ids = {
            "steamdeck.handheld", "steamdeck.docked-tv", "steamdeck.docked-monitor",
        }
        choice_actions = [
            action for action in actions
            if self.category == "Steam Deck" and section == "Sessão" and action.id in choice_ids
        ]
        if choice_actions:
            choices = QFrame()
            choices.setObjectName("choiceJourney")
            choice_layout = QVBoxLayout(choices)
            choice_layout.setContentsMargins(14, 12, 14, 12)
            choice_layout.setSpacing(6)
            choice_title = QLabel("Modo de sessão")
            choice_title.setObjectName("sectionHeading")
            choice_layout.addWidget(choice_title)
            choice_group = QButtonGroup(choices)
            for index, action in enumerate(choice_actions):
                self.mark_represented(action)
                radio = QRadioButton(action.title)
                radio.setToolTip(action.description)
                radio.setAccessibleDescription(action.description)
                radio.setMinimumHeight(48)
                radio.toggled.connect(
                    lambda checked, item=action: self._select_action(item) if checked else None
                )
                choice_group.addButton(radio, index)
                choice_layout.addWidget(radio)
            layout.addWidget(choices)
            actions = [action for action in actions if action not in choice_actions]
        surface = QFrame()
        surface.setObjectName("actionListSurface")
        rows = QVBoxLayout(surface)
        rows.setContentsMargins(0, 0, 0, 0)
        rows.setSpacing(0)
        for action in actions:
            self.mark_represented(action)
            row = ActionListRow(action)
            row.selected.connect(self._select_action)
            self.rows[action.id] = row
            rows.addWidget(row)
        if section == "Avançado":
            disclosure = QToolButton()
            disclosure.setObjectName("advancedDisclosure")
            disclosure.setText(f"Mostrar {len(actions)} operações avançadas")
            disclosure.setCheckable(True)
            disclosure.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
            disclosure.setArrowType(Qt.RightArrow)
            disclosure.toggled.connect(surface.setVisible)
            disclosure.toggled.connect(
                lambda checked: disclosure.setArrowType(Qt.DownArrow if checked else Qt.RightArrow)
            )
            surface.hide()
            layout.addWidget(disclosure)
        layout.addWidget(surface)
        if section == "Visão geral":
            facts = QFrame()
            facts.setObjectName("moduleFacts")
            fact_layout = QHBoxLayout(facts)
            fact_layout.setContentsMargins(14, 10, 14, 10)
            fact_layout.setSpacing(0)
            values = (
                ("Ações disponíveis", str(len(self.actions))),
                ("Com preview seguro", str(sum(action.mutable for action in self.actions))),
                ("Avançadas", str(sum(action.visibility == "advanced" for action in self.actions))),
            )
            for title, value in values:
                cell = QWidget()
                cell_layout = QVBoxLayout(cell)
                cell_layout.setContentsMargins(8, 0, 8, 0)
                number = QLabel(value)
                number.setObjectName("moduleFactValue")
                name = QLabel(title)
                name.setObjectName("moduleFactLabel")
                cell_layout.addWidget(number)
                cell_layout.addWidget(name)
                fact_layout.addWidget(cell, 1)
            layout.addWidget(facts)
        layout.addStretch()
        scroll.setWidget(content)
        return scroll

    def _select_action(self, action: ActionSpec) -> None:
        for action_id, row in self.rows.items():
            row.set_selected(action_id == action.id)
        self.action_selected.emit(action)

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
