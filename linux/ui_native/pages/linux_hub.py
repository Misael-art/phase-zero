"""Página Linux: apps, serviços e otimizações num lugar só.

Segue a linguagem visual das outras páginas de módulo (`ContextRail` à
esquerda, `SectionHeader` por seção, cartões na área de conteúdo) para não
parecer enxerto no app.

O que a página garante:

- switch nunca é otimista. Ao ligar/desligar, ele vai para `pending` e só
  assume o novo valor quando o host reconfirma no refetch. Falha ou
  cancelamento devolvem o switch ao lugar.
- toda mutação passa pelo mesmo caminho do resto do app (preview → confirmar →
  executar → resultado no histórico), porque o toggle emite um `ActionSpec`
  sintetizado em vez de rodar comando por fora.
- estado não sondado aparece como desconhecido, não como desligado.
"""

from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (
    QButtonGroup,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QStackedWidget,
    QStyle,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from ..command_runner import CommandRunner
from ..linux_hub import HubItem, build_hub_items, group_by_section, load_overlay
from ..models import ActionSpec
from ..widgets import ContextRail, HubAppCard, SectionHeader, themed_icon
from .base import BasePage

CAPABILITY_STATUS_ID = "hub.capabilities.status"

# O trilho lateral tem largura fixa; nome longo aparecia cortado no meio da
# palavra. O título completo continua no cabeçalho da seção.
RAIL_LABELS = {
    "Gaming e streaming": "Gaming",
    "Hardware e drivers": "Hardware",
    "Saúde e desempenho": "Saúde",
    "Segurança e privacidade": "Segurança",
    "Backup e nuvem": "Backup",
    "Criação e produtividade": "Criação",
    "Ajustes do sistema": "Ajustes",
}

FILTERS = (
    ("Tudo", "all"),
    ("Instalados", "installed"),
    ("Recomendados", "recommended"),
    ("Reversíveis", "reversible"),
)


def capability_install_action(item: HubItem) -> ActionSpec:
    """Instalação: `plan` mostra o que será feito, `apply` executa com token.

    O par preview/apply é o mesmo contrato usado pelas outras operações de
    risco do app, então o usuário vê o plano antes de qualquer mutação.
    """
    return ActionSpec(
        id=f"hub.capability.install.{item.id}",
        category="Linux",
        title=f"Instalar {item.title}",
        description=item.description,
        args=("capabilities", "apply", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
        icon=item.icon,
        mutable=True,
        preview_args=("capabilities", "plan", "--capability", item.id),
        preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
        elevated=True,
        badge="Reversível",
        risk=item.risk,
        status_args=("capabilities", "status"),
        result_view="table",
    )


def capability_remove_action(item: HubItem) -> ActionSpec:
    return ActionSpec(
        id=f"hub.capability.remove.{item.id}",
        category="Linux",
        title=f"Remover {item.title}",
        description=f"Remove {item.title} usando o registro da instalação feita pelo PhaseZero.",
        args=("capabilities", "remove", "--plan-id", "{plan_id}", "--confirm", "{confirm}"),
        icon=item.icon,
        mutable=True,
        preview_args=("capabilities", "remove-plan", "--capability", item.id),
        preview_bindings=(("plan_id", "id"), ("confirm", "confirmToken")),
        elevated=True,
        badge="Reversível",
        risk=item.risk,
        status_args=("capabilities", "status"),
        result_view="table",
    )


def tuning_action(item: HubItem, enable: bool) -> ActionSpec:
    toggle = item.tune
    args = toggle.enable_args if enable else toggle.disable_args
    return ActionSpec(
        id=f"hub.tuning.{'apply' if enable else 'revert'}.{item.id}",
        category="Linux",
        title=("Aplicar " if enable else "Reverter ") + item.title.lower(),
        description=item.description,
        args=args,
        icon=item.icon,
        mutable=True,
        preview_args=(*args, "--dry-run"),
        badge="Reversível",
        status_args=toggle.status_args,
    )


class LinuxHubPage(BasePage):
    """Vitrine categorizada de apps, serviços e otimizações do Linux."""

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.overlay = load_overlay()
        self.items: list[HubItem] = []
        self.cards: dict[str, HubAppCard] = {}
        self._pending: dict[str, tuple[str, str]] = {}  # action_id -> (item_id, kind)
        self._filter = "all"
        self._query = ""
        self._sections: list[str] = []
        self._section_widgets: dict[str, QWidget] = {}
        self.rail: ContextRail | None = None
        self.stack: QStackedWidget | None = None
        self.status_loader.status_ready.connect(self._status_ready)
        self.status_loader.status_failed.connect(self._status_failed)

    # ------------------------------------------------------------- montagem
    def build(self) -> None:
        self._layout.setSpacing(10)
        self._layout.addWidget(self._toolbar())
        self.items = build_hub_items(None, self.by_id, self.overlay)
        for item in self.items:
            for action in item.actions:
                self.mark_represented(action)

        workspace = QWidget()
        workspace.setObjectName("moduleWorkspace")
        layout = QHBoxLayout(workspace)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(14)
        self.stack = QStackedWidget()
        self.stack.setObjectName("contextStack")
        self.rail = ContextRail([])
        layout.addWidget(self.rail)
        layout.addWidget(self.stack, 1)
        self._layout.addWidget(workspace, 1)
        self._rebuild_sections()
        QTimer.singleShot(0, self.reload)

    def _toolbar(self) -> QWidget:
        bar = QFrame()
        bar.setObjectName("hubToolbar")
        row = QHBoxLayout(bar)
        row.setContentsMargins(12, 10, 12, 10)
        row.setSpacing(10)

        self.search = QLineEdit()
        self.search.setObjectName("hubSearch")
        self.search.setPlaceholderText("Filtrar apps, serviços e otimizações desta página…")
        self.search.setClearButtonEnabled(True)
        self.search.setAccessibleName("Buscar na página Linux")
        self.search.textChanged.connect(self._on_query)
        row.addWidget(self.search, 1)

        group = QButtonGroup(bar)
        group.setExclusive(True)
        for label, key in FILTERS:
            chip = QToolButton()
            chip.setObjectName("hubFilterChip")
            chip.setText(label)
            chip.setCheckable(True)
            chip.setChecked(key == "all")
            chip.setCursor(Qt.PointingHandCursor)
            chip.setAccessibleName(f"Filtrar: {label}")
            chip.clicked.connect(lambda _checked=False, value=key: self._on_filter(value))
            group.addButton(chip)
            row.addWidget(chip)

        self.summary = QLabel("")
        self.summary.setObjectName("hubSummary")
        row.addWidget(self.summary)

        refresh = QPushButton("Atualizar")
        refresh.setObjectName("secondaryButton")
        refresh.setIcon(themed_icon(self, "view-refresh", QStyle.SP_BrowserReload))
        refresh.setAccessibleName("Reconsultar estado dos itens")
        refresh.clicked.connect(self.reload)
        row.addWidget(refresh)
        return bar

    def _rebuild_sections(self) -> None:
        assert self.stack is not None
        while self.stack.count():
            widget = self.stack.widget(0)
            self.stack.removeWidget(widget)
            widget.deleteLater()
        self.cards.clear()
        self._section_widgets.clear()
        grouped = group_by_section(self.items)
        self._sections = [name for name in self.overlay.get("sections", ()) if name in grouped]
        self._sections.extend(name for name in grouped if name not in self._sections)
        for section in self._sections:
            self.stack.addWidget(self._section_page(section, grouped[section]))
        self._install_rail()
        self._apply_filters()

    def _install_rail(self) -> None:
        layout = self.rail.parentWidget().layout() if self.rail is not None else None
        if layout is None:
            return
        rail = ContextRail([RAIL_LABELS.get(name, name) for name in self._sections])
        rail.section_changed.connect(self.stack.setCurrentIndex)
        layout.replaceWidget(self.rail, rail)
        self.rail.deleteLater()
        self.rail = rail

    def _section_page(self, section: str, items: list[HubItem]) -> QWidget:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader(section, self._caption(items)))
        empty = QLabel("Nenhum item corresponde ao filtro.")
        empty.setObjectName("hubEmpty")
        empty.setVisible(False)
        layout.addWidget(empty)
        for item in items:
            card = HubAppCard(item)
            card.toggle_requested.connect(self._on_toggle)
            card.action_requested.connect(self.request_action)
            self.cards[item.id] = card
            layout.addWidget(card)
        layout.addStretch()
        scroll.setWidget(content)
        self._section_widgets[section] = empty
        return scroll

    @staticmethod
    def _caption(items: list[HubItem]) -> str:
        recommended = sum(1 for item in items if item.mode == "recommended")
        total = len(items)
        if recommended:
            return f"{total} itens · {recommended} recomendados"
        return f"{total} itens"

    # --------------------------------------------------------------- filtros
    def _on_query(self, text: str) -> None:
        self._query = text.strip().casefold()
        self._apply_filters()

    def _on_filter(self, key: str) -> None:
        self._filter = key
        self._apply_filters()

    def _matches(self, item: HubItem) -> bool:
        if self._query and self._query not in item.searchable_text:
            return False
        if self._filter == "installed":
            return item.installed is True
        if self._filter == "recommended":
            return item.mode == "recommended"
        if self._filter == "reversible":
            return item.reversible
        return True

    def _apply_filters(self) -> None:
        visible = 0
        per_section: dict[str, int] = {}
        for item in self.items:
            card = self.cards.get(item.id)
            if card is None:
                continue
            shown = self._matches(item)
            card.setVisible(shown)
            visible += int(shown)
            per_section[item.section] = per_section.get(item.section, 0) + int(shown)
        for section, empty in self._section_widgets.items():
            empty.setVisible(per_section.get(section, 0) == 0)
        installed = sum(1 for item in self.items if item.installed is True)
        self.summary.setText(f"{visible} em exibição · {installed} instalados")

    # ---------------------------------------------------------------- estado
    def reload(self) -> None:
        super().reload()
        self.status_loader.fetch(CAPABILITY_STATUS_ID, ["capabilities", "status"])
        for item in self.items:
            if item.kind == "tuning" and item.tune is not None:
                self.status_loader.fetch(f"hub.tune.{item.id}", list(item.tune.status_args))

    def _status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id == CAPABILITY_STATUS_ID:
            self._absorb_capabilities(parsed)
        elif action_id.startswith("hub.tune."):
            self._absorb_tuning(action_id[len("hub.tune."):], parsed)

    def _status_failed(self, action_id: str, message: str) -> None:
        # Falha de leitura não vira "desligado": os switches ficam inertes e o
        # cartão diz por quê, para o usuário não desfazer nada por engano.
        if action_id == CAPABILITY_STATUS_ID:
            targets = [item for item in self.items if item.kind == "capability"]
        elif action_id.startswith("hub.tune."):
            targets = [item for item in self.items if item.id == action_id[len("hub.tune."):]]
        else:
            return
        for item in targets:
            card = self.cards.get(item.id)
            if card is not None:
                card.set_state(installed=None, applied=None)
                card.set_available(False, f"Estado não verificado: {message}")

    def _absorb_capabilities(self, parsed: object) -> None:
        if not isinstance(parsed, dict):
            return
        previous = {item.id: item for item in self.items}
        # `build_hub_items` devolve o conjunto completo (capabilities + tuning
        # + ações) já ordenado; reusar isso evita reordenar à mão e duplicar.
        refreshed = []
        for item in build_hub_items(parsed, self.by_id, self.overlay):
            older = previous.get(item.id)
            if item.kind != "capability" and older is not None and older.installed is not None:
                # Estado de tuning veio de outra sondagem: não pode ser perdido
                # só porque as capabilities chegaram depois.
                item = replace_installed(item, older.installed)
            refreshed.append(item)
        self.items = refreshed
        if {item.id for item in refreshed} != set(self.cards):
            # Primeira resposta do host: os cartões de capability só existem
            # depois dela.
            self._rebuild_sections()
        self._sync_cards()

    def _sync_cards(self) -> None:
        for item in self.items:
            card = self.cards.get(item.id)
            if card is None:
                continue
            card.item = item
            if item.kind == "capability":
                card.set_available(item.available, item.reason)
                card.set_state(installed=item.installed)
            elif item.installed is not None:
                card.set_state(applied=item.installed)
        self._apply_filters()

    def _absorb_tuning(self, item_id: str, parsed: object) -> None:
        card = self.cards.get(item_id)
        if card is None or not isinstance(parsed, dict):
            return
        applied = bool(parsed.get("applied"))
        card.set_state(applied=applied)
        drift = bool(parsed.get("drift"))
        card.set_available(
            True,
            "Arquivos alterados fora do PhaseZero; reaplicar reescreve com backup." if drift else "",
        )
        for index, item in enumerate(self.items):
            if item.id == item_id:
                self.items[index] = replace_installed(item, applied)
        self._apply_filters()

    # ---------------------------------------------------------------- ações
    def _on_toggle(self, item: HubItem, kind: str, enabled: bool) -> None:
        if kind == "install":
            action = capability_install_action(item) if enabled else capability_remove_action(item)
        else:
            action = tuning_action(item, enabled)
        self._pending[action.id] = (item.id, kind)
        # Toggle actions already carry their plan/apply contract. Passing them
        # through BasePage would reinterpret the capability target as a product
        # shortcut and navigate away before the preview can run.
        self.action_requested.emit(action)

    def cancel_pending_action(self, action_id: str) -> None:
        entry = self._pending.pop(action_id, None)
        if entry is None:
            return
        card = self.cards.get(entry[0])
        if card is not None:
            card.revert_pending()

    def block_while_running(self, running: bool) -> None:
        for card in self.cards.values():
            card.set_busy(running)

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        self._apply_filters()


def replace_installed(item: HubItem, installed: bool | None) -> HubItem:
    """`HubItem` é imutável de propósito; trocar estado cria outro."""
    from dataclasses import replace

    return replace(item, installed=installed)
