from __future__ import annotations

import hashlib
import re
from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from ..command_runner import CommandRunner
from ..icons import desktop_dirs, find_desktop_entry
from ..models import ActionSpec, ProductInstance
from ..product_inventory import inventory_manifest, target_for
from ..status_loader import remote_product_status_slug
from ..widgets import ActionListRow, AdvancedActionsPanel, SectionHeader
from .base import BasePage


_RECOVERY_ACTION_BY_APP = {
    # The canonical setup route is idempotent and previews through AI status;
    # the legacy server restore route changes exposure defaults and is unsafe
    # as an implicit recovery action.
    "app.ollama": "ai.ollama",
    "app.opencode": "ai.opencode-install",
}
_HOST_LIST_ACTION_ID = "product.homelab-hosts"
_HOST_ALIAS = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_HOST_ID = re.compile(r"^hlh-[0-9a-f]{12}$")

# These managed-session and dashboard routes remain unavailable until a
# supported adapter can bind each inference request to an enforceable grant.
_ACCOUNT_GRANT_GATED_ACTIONS = frozenset({
    "ai.claude-bonsai-run", "ai.opencode-install",
    "ai.proxies-ensure-kimi", "ai.proxies-ensure-qwen",
    "ai.proxies-ensure-deeps", "ai.proxies-ensure-mimo", "ai.proxies-ensure-all",
    "ai.proxies-start-kimi", "ai.proxies-start-qwen",
    "ai.proxies-start-deeps", "ai.proxies-start-mimo", "ai.proxies-start-all",
    "ai.proxies-open-kimi", "ai.proxies-open-qwen",
    "ai.proxies-open-deeps", "ai.proxies-open-mimo",
    "ai.proxies-credentials-mimo", "ai.proxies-ides", "ai.proxies-test",
    "ai.proxies.restart-one", "ai.proxies.test-one",
    "ai.9router-dashboard", "ai.9router-combos", "ai.9router-secrets",
    "ai.odysseus-install", "ai.odysseus-update", "ai.odysseus-open",
    "ai.webui", "ai.webui-open",
})
_PROXY_CONFIGURE_ACTION_BY_APP = {
    "app.kimiproxy": "ai.proxies-login-kimi",
    "app.qwen-proxy": "ai.proxies-login-qwen",
    "app.deepseek-proxy": "ai.proxies-login-deeps",
    "app.mimo-proxy": "ai.proxies-credentials-mimo",
}
_PROXY_CONFIGURE_TARGET_BY_APP = {
    "app.kimiproxy": ("login", "kimiproxy"),
    "app.qwen-proxy": ("login", "qwenproxy"),
    "app.deepseek-proxy": ("login", "deepsproxy"),
    "app.mimo-proxy": ("set-credentials", "mimo-ai-proxy"),
}
_PROXY_INSTANCE_CONTROL_ACTIONS_BY_APP = {
    "app.kimiproxy": frozenset({
        "ai.proxies-ensure-kimi", "ai.proxies-stop-kimi", "ai.proxies-login-kimi",
        "ai.proxies-start-kimi",
    }),
    "app.qwen-proxy": frozenset({
        "ai.proxies-ensure-qwen", "ai.proxies-stop-qwen", "ai.proxies-login-qwen",
        "ai.proxies-start-qwen",
    }),
    "app.deepseek-proxy": frozenset({
        "ai.proxies-ensure-deeps", "ai.proxies-stop-deeps", "ai.proxies-login-deeps",
        "ai.proxies-start-deeps",
    }),
    "app.mimo-proxy": frozenset({
        "ai.proxies-ensure-mimo", "ai.proxies-stop-mimo", "ai.proxies-credentials-mimo",
        "ai.proxies-start-mimo",
    }),
}
_DASHBOARD_CONFIGURE_ACTION_BY_APP = {
    "app.9router": "ai.9router-dashboard",
}
_RECOVERY_IMPACT_BY_APP = {
    "app.ollama": (
        "Ativa ou inicia o serviço Ollama gerenciado; se o pacote estiver ausente, "
        "a rotina também pode instalá-lo. Nenhum modelo é baixado."
    ),
    "app.opencode": (
        "Sincroniza OpenCode e mescla a rota local 9Router com rollback; pode instalar "
        "ou atualizar a CLI. Não inicia login nem importa credenciais."
    ),
}


class ProductRegistryPage(BasePage):
    """One searchable app list and one reusable detail for every app context."""

    product_opened = Signal(str, str)
    comparison_opened = Signal(str)
    back_requested = Signal()
    desktop_entry_requested = Signal(str)

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.manifest = inventory_manifest(root)
        self.products = [row for row in self.manifest["products"] if isinstance(row, dict)]
        self._product_by_id = {str(row["appId"]): row for row in self.products}
        self._targets = {
            row.action_id: row for row in (target_for(action) for action in self.by_id.values())
        }
        self._cards: dict[str, QFrame] = {}
        self._compare_checks: dict[str, QCheckBox] = {}
        self._compare_selected: set[str] = set()
        self._instances: dict[str, ProductInstance] = {}
        self._instance_id_collision = False
        self._selected_app_id = ""
        self._context_action_id = ""
        self._status_action_id = ""
        self._status_scope = "host"
        self._selected_host_id = "local"
        self._remote_hosts: dict[str, str] = {}
        self._host_list_pending = False
        self._list_page: QWidget | None = None
        self._detail_page: QWidget | None = None
        self._comparison_page: QWidget | None = None
        self._stack: QStackedWidget | None = None
        self._search: QLineEdit | None = None
        self._detail_layout: QVBoxLayout | None = None
        self._detail_scroll: QScrollArea | None = None
        self._detail_actions_start = 0
        self._status_label: QLabel | None = None
        self._instance_selector: QComboBox | None = None
        self._host_context_panel: QWidget | None = None
        self._host_selector: QComboBox | None = None
        self._host_refresh_button: QPushButton | None = None
        self._host_context_status: QLabel | None = None
        self._primary_button: QPushButton | None = None
        self._primary_action: ActionSpec | None = None
        self._primary_desktop_entry = ""
        self._product_summary: QLabel | None = None
        self._product_facts: QLabel | None = None
        self._context_label: QLabel | None = None
        self.status_loader.product_instances_ready.connect(self._instances_ready)
        self.status_loader.status_ready.connect(self._status_ready)
        self.status_loader.status_failed.connect(self._status_failed)

    @property
    def selected_app_id(self) -> str:
        return self._selected_app_id

    @property
    def context_action_id(self) -> str:
        return self._context_action_id

    def product_name(self, app_id: str) -> str:
        product = self._product_by_id.get(app_id, {})
        return str(product.get("name") or app_id)

    @property
    def instances(self) -> tuple[ProductInstance, ...]:
        return tuple(self._instances.values())

    def _selected_host_context(self) -> tuple[str, str | None]:
        host_id = self._selected_host_id
        if self._host_selector is not None:
            selected = self._host_selector.currentData()
            host_id = str(selected or "local")
        if host_id == "local":
            return "local", None
        alias = self._remote_hosts.get(host_id)
        return (host_id, alias) if alias else ("local", None)

    def _populate_host_selector(self, preferred_host_id: str = "local") -> None:
        selector = self._host_selector
        if selector is None:
            self._selected_host_id = "local"
            return
        selector.blockSignals(True)
        selector.clear()
        selector.addItem("Este computador (local)", "local")
        for host_id, alias in sorted(self._remote_hosts.items(), key=lambda item: item[1].casefold()):
            selector.addItem(f"{alias} (Homelab)", host_id)
        index = selector.findData(preferred_host_id)
        selector.setCurrentIndex(index if index >= 0 else 0)
        self._selected_host_id = str(selector.currentData() or "local")
        selector.blockSignals(False)

    def refresh_remote_hosts(self) -> None:
        if self._host_list_pending or self.status_loader.running(_HOST_LIST_ACTION_ID):
            return
        self._host_list_pending = True
        if self._host_refresh_button is not None:
            self._host_refresh_button.setEnabled(False)
        self.status_loader.fetch(
            _HOST_LIST_ACTION_ID, ["server", "homelab", "hosts", "list", "--json"],
        )

    def _status_ready(self, action_id: str, _stdout: str, payload: object) -> None:
        if action_id != _HOST_LIST_ACTION_ID:
            return
        previous_context = self._selected_host_context()
        self._host_list_pending = False
        if self._host_refresh_button is not None:
            self._host_refresh_button.setEnabled(True)
        if (
            not isinstance(payload, dict)
            or payload.get("schemaVersion") not in ("1", 1)
            or payload.get("tool") != "homelab-hosts"
            or payload.get("action") != "list"
            or not isinstance(payload.get("hosts"), list)
        ):
            self._remote_hosts = {}
            self._populate_host_selector()
            self._host_registry_context_changed(previous_context)
            if self._host_context_status is not None:
                self._host_context_status.setText(
                    "Registro Homelab inválido; consulta local continua disponível."
                )
            self._render_primary_action()
            return
        hosts: dict[str, str] = {}
        aliases: set[str] = set()
        for row in payload["hosts"]:
            if not isinstance(row, dict):
                continue
            host_id = row.get("id")
            alias = row.get("alias")
            if (
                not isinstance(host_id, str) or not _HOST_ID.fullmatch(host_id)
                or not isinstance(alias, str) or not _HOST_ALIAS.fullmatch(alias)
                or host_id != "hlh-" + hashlib.sha256(alias.encode("utf-8")).hexdigest()[:12]
                or host_id in hosts or alias in aliases
            ):
                continue
            hosts[host_id] = alias
            aliases.add(alias)
        preferred = self._selected_host_id
        self._remote_hosts = hosts
        self._populate_host_selector(preferred)
        self._host_registry_context_changed(previous_context)
        if self._host_context_status is not None:
            count = len(hosts)
            self._host_context_status.setText(
                f"{count} host(s) Homelab registrado(s). Consulta remota é somente leitura."
                if count else "Nenhum host Homelab registrado; consulta local continua disponível."
            )
        self._render_primary_action()

    def _host_registry_context_changed(self, previous: tuple[str, str | None]) -> None:
        current = self._selected_host_context()
        self._selected_host_id = current[0]
        if previous == current or not self._selected_app_id:
            return
        if self._status_action_id:
            self.status_loader.cancel(self._status_action_id)
        self._instances.clear()
        self._instance_id_collision = False
        self._populate_instance_selector()
        if self._status_label is not None:
            self._status_label.setText("Instalação, configuração e saúde: desconhecidas")
        if self._host_context_status is not None:
            self._host_context_status.setText(
                f"Host {current[1]} selecionado; consulte status read-only."
                if current[1] else "Status e ações neste computador."
            )
        self._render_primary_action()
        self._render_detail_actions()

    def _selected_host_changed(self, _index: int) -> None:
        host_id, alias = self._selected_host_context()
        self._selected_host_id = host_id
        if not self._selected_app_id:
            return
        if self._status_action_id:
            self.status_loader.cancel(self._status_action_id)
        self._instances.clear()
        self._instance_id_collision = False
        self._populate_instance_selector()
        if self._status_label is not None:
            self._status_label.setText(
                f"Host {alias} selecionado · clique Verificar remoto para consulta read-only."
                if alias else "Instalação, configuração e saúde: desconhecidas"
            )
        if self._host_context_status is not None:
            self._host_context_status.setText(
                f"{alias}: somente status remoto; alterações e abertura ficam indisponíveis aqui."
                if alias else "Status e ações neste computador."
            )
        self._render_primary_action()
        self._render_detail_actions()

    def build(self) -> None:
        self._stack = QStackedWidget()
        self._list_page = self._build_list()
        self._detail_page = self._build_detail()
        self._comparison_page = self._build_comparison()
        self._stack.addWidget(self._list_page)
        self._stack.addWidget(self._detail_page)
        self._stack.addWidget(self._comparison_page)
        self._stack.setCurrentWidget(self._list_page)
        self._layout.addWidget(self._stack, 1)
        for action in self.actions:
            target = self._targets.get(action.id)
            if target is not None and target.target_kind == "app":
                self.mark_represented(action)

    def _build_list(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader("Aplicativos", "Busque um produto. Atalhos antigos levam ao mesmo detalhe."))
        self._search = QLineEdit()
        self._search.setObjectName("productSearch")
        self._search.setPlaceholderText("Buscar app pelo nome ou recurso…")
        self._search.setClearButtonEnabled(True)
        self._search.setAccessibleName("Buscar aplicativos")
        self._search.textChanged.connect(self._filter_products)
        layout.addWidget(self._search)
        self._compare_button = QPushButton("Comparar selecionados (0/2)")
        self._compare_button.setObjectName("compareProducts")
        self._compare_button.setEnabled(False)
        self._compare_button.clicked.connect(self._compare_products)
        layout.addWidget(self._compare_button)
        scroll = QScrollArea()
        scroll.setObjectName("productCatalogScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        self._cards_layout = QVBoxLayout(content)
        self._cards_layout.setContentsMargins(2, 2, 8, 12)
        self._cards_layout.setSpacing(8)
        for product in sorted(self.products, key=lambda row: str(row.get("name", "")).casefold()):
            app_id = str(product["appId"])
            card = QFrame()
            card.setObjectName("productCard")
            card_layout = QVBoxLayout(card)
            card_layout.setContentsMargins(12, 10, 12, 10)
            title_row = QHBoxLayout()
            open_button = QPushButton(str(product.get("name") or app_id))
            open_button.setObjectName("productOpenButton")
            open_button.setAccessibleDescription(f"Abrir detalhe de {product.get('name') or app_id}")
            open_button.clicked.connect(lambda _checked=False, key=app_id: self.open_product(key))
            title_row.addWidget(open_button, 1)
            compare_category = product.get("comparisonCategory")
            if isinstance(compare_category, str) and compare_category:
                compare = QCheckBox("Comparar")
                compare.setObjectName("compareProductToggle")
                compare.setAccessibleName(f"Selecionar {product.get('name') or app_id} para comparação")
                compare.toggled.connect(lambda checked, key=app_id: self._toggle_comparison(key, checked))
                self._compare_checks[app_id] = compare
                title_row.addWidget(compare)
            card_layout.addLayout(title_row)
            info = QLabel(f"{app_id} · Estado não verificado")
            info.setObjectName("productCardSummary")
            info.setWordWrap(True)
            card_layout.addWidget(info)
            self._cards[app_id] = card
            self._cards_layout.addWidget(card)
        non_product_actions = [
            action for action in self.actions
            if self._targets.get(action.id) is None or self._targets[action.id].target_kind != "app"
        ]
        if non_product_actions:
            self._cards_layout.addWidget(SectionHeader(
                "Outras operações do desktop",
                "Atalhos de sistema e jornadas antigas continuam disponíveis.",
            ))
            for action in non_product_actions:
                self.mark_represented(action)
                row = ActionListRow(action)
                row.selected.connect(self.action_selected.emit)
                self._cards_layout.addWidget(row)
        self._cards_layout.addStretch()
        scroll.setWidget(content)
        layout.addWidget(scroll, 1)
        return page

    def _build_detail(self) -> QWidget:
        page = QWidget()
        page_layout = QVBoxLayout(page)
        page_layout.setContentsMargins(0, 0, 0, 0)
        page_layout.setSpacing(0)
        scroll = QScrollArea()
        scroll.setObjectName("productDetailScroll")
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Expanding)
        content = QWidget()
        self._detail_scroll = scroll
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        scroll.setWidget(content)
        page_layout.addWidget(scroll)
        back = QPushButton("‹  Todos os aplicativos")
        back.setObjectName("productDetailBack")
        back.clicked.connect(self.close_detail)
        layout.addWidget(back)
        self._detail_layout = layout
        self._context_label = QLabel("")
        self._context_label.setObjectName("productContext")
        self._context_label.setWordWrap(True)
        layout.addWidget(self._context_label)
        self._host_context_panel = QWidget()
        self._host_context_panel.setObjectName("productHostContext")
        host_layout = QVBoxLayout(self._host_context_panel)
        host_layout.setContentsMargins(0, 0, 0, 0)
        host_row = QHBoxLayout()
        host_caption = QLabel("Verificar em:")
        self._host_selector = QComboBox()
        self._host_selector.setObjectName("productHostSelector")
        self._host_selector.setAccessibleName("Host para verificar aplicativo")
        self._host_selector.addItem("Este computador (local)", "local")
        self._host_selector.currentIndexChanged.connect(self._selected_host_changed)
        host_caption.setBuddy(self._host_selector)
        host_row.addWidget(host_caption)
        host_row.addWidget(self._host_selector, 1)
        self._host_refresh_button = QPushButton("Listar hosts")
        self._host_refresh_button.setObjectName("productHostRefresh")
        self._host_refresh_button.setAccessibleName("Listar hosts Homelab registrados")
        self._host_refresh_button.clicked.connect(self.refresh_remote_hosts)
        host_row.addWidget(self._host_refresh_button)
        host_layout.addLayout(host_row)
        self._host_context_status = QLabel("Status local. Hosts Homelab carregam sob demanda.")
        self._host_context_status.setObjectName("productHostContextStatus")
        self._host_context_status.setWordWrap(True)
        host_layout.addWidget(self._host_context_status)
        layout.addWidget(self._host_context_panel)
        self._host_context_panel.hide()
        self._product_summary = QLabel("")
        self._product_summary.setObjectName("productDescription")
        self._product_summary.setWordWrap(True)
        layout.addWidget(self._product_summary)
        self._product_facts = QLabel("")
        self._product_facts.setObjectName("productFacts")
        self._product_facts.setWordWrap(True)
        layout.addWidget(self._product_facts)
        self._instance_selector = QComboBox()
        self._instance_selector.setObjectName("productInstanceSelector")
        self._instance_selector.setAccessibleName("Instância do aplicativo")
        self._instance_selector.currentIndexChanged.connect(self._selected_instance_changed)
        self._instance_selector.hide()
        layout.addWidget(self._instance_selector)
        self._status_label = QLabel("Instalação, configuração e saúde: desconhecidas")
        self._status_label.setObjectName("productStatus")
        self._status_label.setWordWrap(True)
        layout.addWidget(self._status_label)
        self._account_grant_notice = QLabel()
        self._account_grant_notice.setObjectName("accountGrantNotice")
        self._account_grant_notice.setWordWrap(True)
        self._account_grant_notice.setText(
            "Execução gerenciada bloqueada: a rota não vincula cada requisição à conexão aprovada. "
            "Login, status online ou grant registrado, isoladamente, não provam qual conta será usada."
        )
        self._account_grant_notice.hide()
        layout.addWidget(self._account_grant_notice)
        self._primary_button = QPushButton("Verificar")
        self._primary_button.setObjectName("productPrimaryAction")
        self._primary_button.setToolTip("Confere status antes de escolher uma ação.")
        self._primary_button.clicked.connect(self._primary_clicked)
        layout.addWidget(self._primary_button)
        layout.addWidget(SectionHeader("Ações disponíveis", "Ações atuais convergem neste produto e mantêm a confirmação existente."))
        self._detail_actions_start = layout.count()
        return page

    def _build_comparison(self) -> QWidget:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        back = QPushButton("‹  Voltar aos aplicativos")
        back.setObjectName("comparisonBack")
        back.clicked.connect(self._close_comparison)
        layout.addWidget(back)
        self._comparison_layout = layout
        self._comparison_content_start = layout.count()
        return page

    def _filter_products(self, text: str) -> None:
        query = text.strip().casefold()
        for app_id, product in self._product_by_id.items():
            aliases = product.get("searchTerms", [])
            fields = [str(product.get("name", "")), app_id]
            if isinstance(aliases, list):
                fields.extend(str(alias) for alias in aliases)
            fields.extend(
                self.by_id[action_id].searchable_text
                for action_id in product.get("actionIds", [])
                if action_id in self.by_id
            )
            self._cards[app_id].setVisible(not query or any(query in value.casefold() for value in fields))

    def _toggle_comparison(self, app_id: str, checked: bool) -> None:
        if checked:
            if len(self._compare_selected) >= 2:
                checkbox = self._compare_checks[app_id]
                checkbox.blockSignals(True)
                checkbox.setChecked(False)
                checkbox.blockSignals(False)
                return
            self._compare_selected.add(app_id)
        else:
            self._compare_selected.discard(app_id)
        for key, checkbox in self._compare_checks.items():
            checkbox.setEnabled(key in self._compare_selected or len(self._compare_selected) < 2)
        count = len(self._compare_selected)
        self._compare_button.setText(f"Comparar selecionados ({count}/2)")
        self._compare_button.setEnabled(count == 2)

    def _compare_products(self) -> None:
        if len(self._compare_selected) != 2 or self._stack is None:
            return
        first_id, second_id = sorted(self._compare_selected)
        first = self._product_by_id[first_id]
        second = self._product_by_id[second_id]
        category = first.get("comparisonCategory")
        if not category or category != second.get("comparisonCategory"):
            return
        self._clear_comparison_rows()
        names = f"{first.get('name', first_id)} e {second.get('name', second_id)}"
        self._comparison_layout.addWidget(SectionHeader(
            f"Comparar {names}", f"Mesma função catalogada: {category}. Sem recomendação de substituição automática.",
        ))
        fields = (
            ("Descrição", "description"),
            ("Grupo", "group"),
            ("Fontes de instalação", "sources"),
            ("Requisitos", "requires"),
            ("Conflitos", "conflicts"),
            ("Compatibilidade", "compatibility"),
            ("Risco declarado", "risk"),
            ("Licença", "license"),
        )
        for label, key in fields:
            self._comparison_layout.addWidget(self._comparison_row(
                label, self._display_value(first.get(key)), self._display_value(second.get(key)),
            ))
        self._comparison_layout.addStretch()
        self._stack.setCurrentWidget(self._comparison_page)
        self.comparison_opened.emit(str(category))

    def _comparison_row(self, label: str, first: str, second: str) -> QFrame:
        frame = QFrame()
        frame.setObjectName("comparisonRow")
        row = QHBoxLayout(frame)
        row.setContentsMargins(12, 8, 12, 8)
        key = QLabel(label)
        key.setObjectName("comparisonKey")
        key.setWordWrap(True)
        left = QLabel(first)
        right = QLabel(second)
        left.setWordWrap(True)
        right.setWordWrap(True)
        row.addWidget(key, 1)
        row.addWidget(left, 2)
        row.addWidget(right, 2)
        return frame

    @staticmethod
    def _display_value(value: object) -> str:
        if isinstance(value, list):
            return ", ".join(str(item.get("name") or item.get("kind")) if isinstance(item, dict) else str(item)
                             for item in value) or "Não informado"
        if isinstance(value, dict):
            values = [f"{key}: {ProductRegistryPage._display_value(item)}" for key, item in value.items()]
            return " · ".join(values) or "Não informado"
        if value is None or value == "":
            return "Não informado"
        return str(value)

    def _clear_comparison_rows(self) -> None:
        while self._comparison_layout.count() > self._comparison_content_start:
            item = self._comparison_layout.takeAt(self._comparison_content_start)
            widget = item.widget()
            if widget is not None:
                widget.setParent(None)
                widget.deleteLater()

    def _close_comparison(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self._stack.setCurrentWidget(self._list_page)
            self._compare_selected.clear()
            for checkbox in self._compare_checks.values():
                checkbox.blockSignals(True)
                checkbox.setChecked(False)
                checkbox.setEnabled(True)
                checkbox.blockSignals(False)
            self._toggle_comparison_count()
            self.back_requested.emit()

    def _toggle_comparison_count(self) -> None:
        self._compare_button.setText(f"Comparar selecionados ({len(self._compare_selected)}/2)")
        self._compare_button.setEnabled(len(self._compare_selected) == 2)

    def open_product(self, app_id: str, context_action_id: str = "") -> None:
        product = self._product_by_id.get(app_id)
        if product is None or self._stack is None or self._detail_layout is None:
            return
        context_target = self._targets.get(context_action_id) if context_action_id else None
        if (
            context_action_id
            and (context_target is None or context_target.target_kind != "app"
                 or context_target.target_id != app_id)
        ):
            context_action_id = ""
        self.status_loader.cancel_all()
        self._host_list_pending = False
        if self._host_refresh_button is not None:
            self._host_refresh_button.setEnabled(True)
        self._selected_app_id = app_id
        self._context_action_id = context_action_id
        grant_gated_app = app_id in {
            "app.claude-code", "app.opencode", "app.9router", "app.kimiproxy", "app.qwen-proxy",
            "app.deepseek-proxy", "app.mimo-proxy", "app.odysseus",
        }
        self._account_grant_notice.setText(
            "Dashboard 9Router bloqueado: testes de provider podem enviar inferência e consumir cota "
            "sem grant por requisição. O painel direto ainda fica fora do ledger PhaseZero."
            if app_id == "app.9router" else
            "Uso Odysseus bloqueado: workspace encaminha inferência à credencial compartilhada do 9Router "
            "sem grant por requisição. URL local direta ainda fica fora do ledger PhaseZero."
            if app_id == "app.odysseus" else
            "Execução gerenciada bloqueada: a rota não vincula cada requisição à conexão aprovada. "
            "Login, status online ou grant registrado, isoladamente, não provam qual conta será usada."
        )
        self._account_grant_notice.setVisible(grant_gated_app)
        self._instances.clear()
        self._instance_id_collision = False
        self._populate_instance_selector()
        self._status_label.setText("Instalação, configuração e saúde: desconhecidas")
        self._product_summary.setText(self._display_value(product.get("description")))
        facts = (
            ("Grupo", product.get("group")),
            ("Fontes", product.get("sources")),
            ("Requisitos", product.get("requires")),
            ("Conflitos", product.get("conflicts")),
            ("Compatibilidade", product.get("compatibility")),
            ("Risco", product.get("risk")),
            ("Licença", product.get("license")),
        )
        self._product_facts.setText("\n".join(
            f"{label}: {self._display_value(value)}" for label, value in facts
        ))
        if context_action_id and context_action_id in self.by_id:
            action = self.by_id[context_action_id]
            target = self._targets.get(context_action_id)
            scope = target.instance_scope if target is not None else "selected"
            self._context_label.setText(f"Atalho de origem: {action.category} · {action.title} · escopo {scope}")
        else:
            self._context_label.setText("Catálogo de aplicativos")
        self._stack.setCurrentWidget(self._detail_page)
        self.product_opened.emit(app_id, context_action_id)
        status_action = self._status_action(product)
        self._status_action_id = status_action.id if status_action is not None else ""
        target = self._targets.get(status_action.id) if status_action is not None else None
        self._status_scope = target.instance_scope if target is not None else "host"
        remote_slug = (
            remote_product_status_slug(status_action, app_id)
            if status_action is not None else None
        )
        if self._host_context_panel is not None:
            self._host_context_panel.setVisible(remote_slug is not None)
        if remote_slug is None:
            self._populate_host_selector()
        host_id, remote_alias = self._selected_host_context()
        if self._host_context_status is not None and remote_alias:
            self._host_context_status.setText(
                f"{remote_alias}: somente status remoto; alterações e abertura ficam indisponíveis aqui."
            )
        self._clear_detail_actions()
        self._render_detail_actions()
        self._detail_layout.addStretch()
        self._render_primary_action()
        if self._detail_scroll is not None:
            self._detail_scroll.verticalScrollBar().setValue(0)
        if status_action is not None and host_id == "local":
            self.status_loader.fetch_product_status(
                status_action, app_id=app_id, host_id="local", scope=self._status_scope,
            )
        elif status_action is not None and remote_alias:
            self._status_label.setText(
                f"Host {remote_alias} selecionado · clique Verificar remoto para consulta read-only."
            )

    def _render_detail_actions(self) -> None:
        self._clear_detail_actions()
        product = self._product_by_id.get(self._selected_app_id, {})
        all_actions = [self.by_id[item] for item in product.get("actionIds", []) if item in self.by_id]
        actions = all_actions
        context_message = ""
        _host_id, remote_alias = self._selected_host_context()
        if remote_alias:
            actions = []
            context_message = (
                f"Host {remote_alias}: este detalhe oferece consulta read-only; "
                "operações e abertura remotas ainda indisponíveis."
            )
        elif self._instances:
            instance = self._selected_instance()
            if instance is None:
                actions = []
                context_message = "Selecione uma instância para ver ações aplicáveis."
            elif instance.host_id != "local":
                actions = []
                context_message = "Ações remotas ainda não estão disponíveis neste detalhe."
            elif self._same_scope_instance_count(instance) > 1:
                actions = []
                context_message = "Há várias instâncias neste escopo; ações não conseguem distingui-las ainda."
            else:
                actions = [
                    action for action in all_actions
                    if (target := self._targets.get(action.id)) is not None
                    and target.instance_scope == instance.scope
                    and self._detail_action_allowed(action, product, instance)
                ]
                if not actions:
                    context_message = "Nenhuma ação disponível para este escopo."
        else:
            actions = [
                action for action in all_actions
                if self._detail_action_allowed(action, product, None)
            ]
        if context_message:
            notice = QLabel(context_message)
            notice.setObjectName("productInstanceActionNotice")
            notice.setWordWrap(True)
            self._detail_layout.addWidget(notice)
            return
        action_ids = [item for item in product.get("actionIds", []) if item in self.by_id]
        action_ids.sort(key=lambda action_id: (
            action_id != product.get("canonicalActionId"),
            not bool(self._manifest_action(action_id).get("installationAuthorityId")),
            self.by_id[action_id].title.casefold(),
        ))
        standard: list[ActionSpec] = []
        advanced: list[ActionSpec] = []
        for action_id in action_ids:
            action = self.by_id[action_id]
            if action not in actions:
                continue
            (advanced if action.visibility == "advanced" or action.risk in {"elevated", "high"} else standard).append(action)
        for action in standard:
            row = ActionListRow(action)
            row.selected.connect(self.action_requested.emit)
            self._detail_layout.addWidget(row)
        if advanced:
            panel = AdvancedActionsPanel(advanced)
            panel.requested.connect(self.action_requested.emit)
            panel.setVisible(self._advanced_mode)
            self._advanced_panels.append(panel)
            self._detail_layout.addWidget(panel)

    def _selected_instance(self) -> ProductInstance | None:
        if not self._instances:
            return None
        if len(self._instances) == 1:
            return next(iter(self._instances.values()))
        if self._instance_selector is None:
            return None
        instance_id = self._instance_selector.currentData()
        return self._instances.get(str(instance_id)) if instance_id else None

    def _same_scope_instance_count(self, instance: ProductInstance) -> int:
        return sum(
            other.host_id == instance.host_id and other.scope == instance.scope
            for other in self._instances.values()
        )

    def _populate_instance_selector(self) -> None:
        selector = self._instance_selector
        if selector is None:
            return
        selector.blockSignals(True)
        selector.clear()
        if len(self._instances) > 1:
            selector.addItem("Selecione uma instância…", "")
            for instance in sorted(
                self._instances.values(), key=lambda item: (item.host_id, item.scope, item.instance_id),
            ):
                label = f"{instance.host_id} · {instance.scope}"
                if self._same_scope_instance_count(instance) > 1:
                    label += f" · {instance.instance_id}"
                selector.addItem(label, instance.instance_id)
            selector.setCurrentIndex(0)
            selector.show()
        else:
            selector.hide()
        selector.blockSignals(False)

    def _selected_instance_changed(self, _index: int) -> None:
        self._render_status()
        self._render_detail_actions()

    def _selected_context_is_actionable(self) -> bool:
        if not self._instances:
            return True
        instance = self._selected_instance()
        return bool(
            instance is not None
            and instance.host_id == "local"
            and self._same_scope_instance_count(instance) == 1
        )

    def _action_matches_selected_instance(self, action: ActionSpec) -> bool:
        if not self._instances:
            return True
        instance = self._selected_instance()
        target = self._targets.get(action.id)
        return bool(
            self._selected_context_is_actionable()
            and instance is not None and target is not None
            and target.instance_scope == instance.scope
        )

    def _detail_action_allowed(
        self,
        action: ActionSpec,
        product: dict[str, object],
        instance: ProductInstance | None,
    ) -> bool:
        """Hide mutating routes until selected instance proves ownership/state.

        The primary state CTA remains the path for verified prepare/configure/
        recovery. Secondary legacy rows must not bypass its ownership checks.
        """
        app_id = str(product.get("appId") or "")
        if action.id in _ACCOUNT_GRANT_GATED_ACTIONS:
            return False
        if instance is not None and instance.usage_blocked:
            verbs = set(action.args) | set(action.id.casefold().split("."))
            if verbs.intersection({"install", "setup", "open", "launch", "dashboard",
                                   "run", "start", "restart", "configure"}):
                return False
        if not action.mutable:
            verbs = set(action.args) | set(action.id.casefold().split("."))
            if not verbs.intersection({"open", "launch", "dashboard"}):
                return True
            if instance is None or instance.next_action not in {"open", "configure"}:
                return False
            route = self._action_for_state(instance.next_action)
            return bool(route is not None and route.id == action.id)
        if instance is None:
            return False
        if action.id in _PROXY_INSTANCE_CONTROL_ACTIONS_BY_APP.get(app_id, ()):
            return bool(
                instance.installation == "present"
                and instance.origin == "phasezero"
                and instance.manager == "phasezero-ai-proxy-suite"
            )
        if action.id == _RECOVERY_ACTION_BY_APP.get(app_id):
            recovery = self._action_for_state("resolve")
            return bool(recovery is not None and recovery.mutable and recovery.id == action.id)
        if action.id in _PROXY_CONFIGURE_ACTION_BY_APP.values():
            return self._action_for_state("configure") is not None

        verbs = set(action.args)
        if verbs & {"start", "restart", "stop", "repair"}:
            authority = self._manifest_action(action.id).get("installationAuthorityId")
            return bool(
                instance is not None and instance.installation == "present"
                and instance.origin == "phasezero" and authority
                and authority in product.get("installationAuthorityIds", [])
            )

        authority = self._manifest_action(action.id).get("installationAuthorityId")
        if not authority or instance is None:
            return False
        if authority not in product.get("installationAuthorityIds", []):
            return False
        if instance.installation == "unknown":
            return False
        if instance.installation == "present" and instance.origin != "phasezero":
            return False
        return True

    def _manifest_action(self, action_id: str) -> dict[str, object]:
        return next((row for row in self.manifest["actions"] if row.get("actionId") == action_id), {})

    def _status_action(self, product: dict[str, object]) -> ActionSpec | None:
        candidates = []
        for action_id in product.get("actionIds", []):
            action = self.by_id.get(action_id)
            target = self._targets.get(action_id)
            if (
                action is not None and target is not None and not action.mutable
                and (action.id.endswith("status") or ".status." in action.id)
                and action.status_args
            ):
                candidates.append((target.instance_scope != "local", action.id, action))
        if candidates:
            return min(candidates)[2]
        if product.get("capabilityId"):
            return ActionSpec(
                "product.capabilities.status", "Aplicativos", "Verificar aplicativo", "",
                ("capabilities", "status", "--json"), "",
                status_args=("capabilities", "status", "--json"),
            )
        return None

    def _action_for_state(self, state: str) -> ActionSpec | None:
        if not self._selected_app_id:
            return None
        instance = self._selected_instance()
        if instance is not None and instance.usage_blocked and state != "verify":
            return None
        product = self._product_by_id[self._selected_app_id]
        actions = [self.by_id[item] for item in product.get("actionIds", []) if item in self.by_id]
        if state == "prepare":
            authority_ids = set(product.get("installationAuthorityIds", []))
            return next((action for action in actions if self._action_matches_selected_instance(action)
                         and action.id not in _ACCOUNT_GRANT_GATED_ACTIONS
                         and self._manifest_action(action.id).get(
                             "installationAuthorityId") in authority_ids and action.mutable), None)
        if state == "configure":
            configure_id = _PROXY_CONFIGURE_ACTION_BY_APP.get(self._selected_app_id, "")
            configure = self.by_id.get(configure_id)
            instance = self._selected_instance()
            route = _PROXY_CONFIGURE_TARGET_BY_APP.get(self._selected_app_id)
            if (
                configure is not None and configure_id not in _ACCOUNT_GRANT_GATED_ACTIONS
                and route is not None and instance is not None
                and configure_id in product.get("actionIds", [])
                and self._action_matches_selected_instance(configure)
                and instance.origin == "phasezero"
                and instance.manager == "phasezero-ai-proxy-suite"
                and configure.mutable and len(configure.args) == 4
                and configure.args[2:] == route
            ):
                return configure
            dashboard_id = _DASHBOARD_CONFIGURE_ACTION_BY_APP.get(self._selected_app_id, "")
            dashboard = self.by_id.get(dashboard_id)
            if (
                dashboard is not None and dashboard_id not in _ACCOUNT_GRANT_GATED_ACTIONS
                and dashboard_id in product.get("actionIds", [])
                and self._action_matches_selected_instance(dashboard)
                and instance is not None and instance.health == "online"
                and not dashboard.mutable
                and dashboard.args == ("ai", "9router", "dashboard")
            ):
                return dashboard
        terms = {
            "configure": {"configure", "setup"},
            # Resolver may run a read-only diagnostic automatically. Mutable
            # repair/start actions require an app-specific, ownership-checked
            # recovery route above; matching command arguments here can start
            # an unrelated managed service for an externally observed app.
            "resolve": {"doctor", "health", "verify"},
            "open": {"open", "launch", "dashboard"},
        }.get(state, set())
        if state == "resolve":
            recovery_id = _RECOVERY_ACTION_BY_APP.get(self._selected_app_id, "")
            recovery = self.by_id.get(recovery_id)
            instance = self._selected_instance()
            if (
                recovery is not None and recovery_id not in _ACCOUNT_GRANT_GATED_ACTIONS
                and recovery_id in product.get("actionIds", [])
                and self._action_matches_selected_instance(recovery)
                and instance is not None and instance.origin == "phasezero"
            ):
                authority_id = self._manifest_action(recovery_id).get("installationAuthorityId")
                declared_authority = authority_id in product.get("installationAuthorityIds", [])
                if recovery.mutable and declared_authority:
                    return replace(
                        recovery,
                        impact=_RECOVERY_IMPACT_BY_APP.get(self._selected_app_id, recovery.impact),
                    )
        return next((action for action in actions if action.id not in _ACCOUNT_GRANT_GATED_ACTIONS
                     and self._action_matches_selected_instance(action)
                     and (state != "resolve" or not action.mutable) and any(
            term in action.id.casefold().replace("-", ".").split(".")
            or term in action.args for term in terms
        ) and action.id != self._status_action_id), None)

    def _desktop_entry_for_product(self, product: dict[str, object]) -> str:
        entries = product.get("desktopEntries", [])
        if isinstance(entries, list):
            roots = desktop_dirs()
            for name in entries:
                if isinstance(name, str) and name:
                    entry = find_desktop_entry("desktop-entry", name, roots)
                    if entry is not None:
                        return str(entry)
        sources = product.get("sources", [])
        if not isinstance(sources, list):
            return ""
        roots = desktop_dirs()
        for source in sources:
            if not isinstance(source, dict):
                continue
            entry = find_desktop_entry(
                str(source.get("kind") or ""), str(source.get("name") or ""), roots,
            )
            if entry is not None:
                return str(entry)
        return ""

    def _render_primary_action(self) -> None:
        if self._primary_button is None or not self._selected_app_id:
            return
        _host_id, remote_alias = self._selected_host_context()
        if remote_alias:
            product = self._product_by_id.get(self._selected_app_id, {})
            status_action = self._status_action(product) if product else None
            supported = (
                status_action is not None
                and remote_product_status_slug(status_action, self._selected_app_id) is not None
            )
            running = bool(status_action and self.status_loader.running(status_action.id))
            self._primary_action = None
            self._primary_desktop_entry = ""
            self._primary_button.setText(
                "Verificando…" if running else
                "Atualizar status remoto" if self._instances else "Verificar remoto"
            )
            self._primary_button.setEnabled(supported and not running)
            self._primary_button.setToolTip(
                f"Consulta read-only em {remote_alias}. Instalar, alterar ou abrir continua indisponível aqui."
            )
            return
        instance = self._selected_instance()
        if len(self._instances) > 1 and instance is None:
            self._primary_button.setText("Selecionar instância")
            self._primary_action = None
            self._primary_desktop_entry = ""
            self._primary_button.setEnabled(False)
            self._primary_button.setToolTip("Escolha qual instância do aplicativo este detalhe representa.")
            return
        context_tooltip = ""
        if instance is not None and instance.host_id != "local":
            context_tooltip = "Ações remotas indisponíveis: este host ainda não tem executor vinculado."
        elif instance is not None and self._same_scope_instance_count(instance) > 1:
            context_tooltip = "Ação bloqueada: executor ainda não distingue instâncias no mesmo host e escopo."
        state = instance.next_action if instance is not None else "verify"
        product = self._product_by_id[self._selected_app_id]
        action = self._action_for_state(state) if state != "verify" else None
        if (
            state == "configure" and action is None and instance is not None
            and instance.health in {"offline", "failed"}
        ):
            diagnostic = self._action_for_state("resolve")
            if diagnostic is not None:
                state, action = "resolve", diagnostic
        labels = {"prepare": "Preparar", "configure": "Configurar",
                  "verify": "Verificar", "resolve": "Resolver", "open": "Abrir"}
        consumer_route_blocked = (
            (
                instance is not None and instance.usage_blocked
                or self._selected_app_id == "app.9router" and state in {"configure", "open"}
                or self._selected_app_id == "app.odysseus" and state in {"prepare", "configure", "open"}
                or self._selected_app_id == "app.open-webui" and state in {"prepare", "configure", "resolve", "open"}
            )
            and action is None
        )
        self._primary_button.setText(
            "Uso bloqueado" if consumer_route_blocked else labels.get(state, "Verificar")
        )
        self._primary_action = action
        self._primary_desktop_entry = (
            self._desktop_entry_for_product(product)
            if state == "open" and self._primary_action is None
            and not (instance is not None and instance.usage_blocked)
            and self._selected_context_is_actionable() else ""
        )
        enabled = (
            bool(self._status_action_id) if state == "verify" else
            self._primary_action is not None or bool(self._primary_desktop_entry)
        )
        enabled = enabled and self._selected_context_is_actionable()
        self._primary_button.setEnabled(enabled)
        if context_tooltip:
            self._primary_button.setToolTip(context_tooltip)
        elif consumer_route_blocked and self._selected_app_id == "app.9router":
            self._primary_button.setToolTip(
                "Dashboard bloqueado: testes do painel podem enviar inferência sem grant vinculado "
                "à requisição e consumir cota."
            )
        elif consumer_route_blocked and self._selected_app_id == "app.odysseus":
            self._primary_button.setToolTip(
                "Uso Odysseus bloqueado: workspace encaminha inferência pela credencial 9Router "
                "sem grant por requisição."
            )
        elif self._selected_app_id == "app.open-webui" and state in {"prepare", "configure", "resolve", "open"}:
            self._primary_button.setToolTip(
                "Uso bloqueado: Open WebUI pode salvar conexões de provedores, mas não vincula "
                "cada inferência a um grant PhaseZero."
            )
        elif state == "verify":
            self._primary_button.setToolTip("Confere status sem alterar instalação, conta ou serviço.")
        else:
            self._primary_button.setToolTip(
                self._primary_action.description if self._primary_action is not None
                else "Abre pelo atalho de aplicativo instalado." if self._primary_desktop_entry
                else "Ação principal indisponível para este estado observado."
            )

    def _primary_clicked(self) -> None:
        if not self._selected_app_id:
            return
        host_id, remote_alias = self._selected_host_context()
        if remote_alias:
            product = self._product_by_id[self._selected_app_id]
            status_action = self._status_action(product)
            if (
                status_action is None
                or remote_product_status_slug(status_action, self._selected_app_id) is None
            ):
                return
            instance = self._selected_instance()
            if self._primary_button is not None:
                self._primary_button.setText("Verificando…")
                self._primary_button.setEnabled(False)
            self.status_loader.fetch_product_status(
                status_action,
                app_id=self._selected_app_id,
                host_id=host_id,
                scope=instance.scope if instance is not None else self._status_scope,
                instance_key=(
                    instance.instance_id.rsplit(":", 1)[-1]
                    if instance is not None else "default"
                ),
                remote_alias=remote_alias,
            )
            return
        if not self._selected_context_is_actionable():
            return
        if self._primary_action is not None:
            self.action_requested.emit(self._primary_action)
            return
        if self._primary_desktop_entry:
            self.desktop_entry_requested.emit(self._primary_desktop_entry)
            return
        product = self._product_by_id[self._selected_app_id]
        status_action = self._status_action(product)
        if status_action is not None:
            instance = self._selected_instance()
            selected_scope = instance.scope if instance is not None else self._status_scope
            selected_host = instance.host_id if instance is not None else "local"
            target = self._targets.get(status_action.id)
            self._status_scope = selected_scope or (target.instance_scope if target is not None else "host")
            if self._primary_button is not None:
                self._primary_button.setText("Verificando…")
                self._primary_button.setEnabled(False)
            self.status_loader.fetch_product_status(
                status_action, app_id=self._selected_app_id, host_id=selected_host, scope=self._status_scope,
                instance_key=(
                    instance.instance_id.rsplit(":", 1)[-1]
                    if instance is not None else "default"
                ),
            )

    def _instances_ready(self, action_id: str, instances: object) -> None:
        if action_id != self._status_action_id:
            # StatusLoader discards replaced contexts; keep this guard for same-app refreshes.
            return
        rows = tuple(
            item for item in instances if isinstance(item, ProductInstance)
        ) if isinstance(instances, tuple) else ()
        instance_ids = [item.instance_id for item in rows]
        self._instance_id_collision = len(instance_ids) != len(set(instance_ids))
        self._instances = {} if self._instance_id_collision else {
            item.instance_id: item for item in rows
        }
        self._populate_instance_selector()
        self._render_status()
        self._render_detail_actions()

    def _status_failed(self, action_id: str, _message: str) -> None:
        if action_id == _HOST_LIST_ACTION_ID:
            previous_context = self._selected_host_context()
            self._host_list_pending = False
            self._remote_hosts = {}
            self._populate_host_selector()
            self._host_registry_context_changed(previous_context)
            if self._host_refresh_button is not None:
                self._host_refresh_button.setEnabled(True)
            if self._host_context_status is not None:
                self._host_context_status.setText(
                    "Registro Homelab indisponível; consulta local continua disponível."
                )
            self._render_primary_action()
            self._render_detail_actions()
            return
        if action_id == self._status_action_id:
            self._instances.clear()
            self._instance_id_collision = False
            self._populate_instance_selector()
            _host_id, remote_alias = self._selected_host_context()
            self._status_label.setText(
                f"Status remoto de {remote_alias} indisponível · verifique conexão e pareamento Homelab"
                if remote_alias else
                "Status indisponível · instalação, configuração e saúde desconhecidas"
            )
            self._render_primary_action()
            self._render_detail_actions()

    def _render_status(self) -> None:
        if self._instance_id_collision:
            self._status_label.setText(
                "Status ambíguo · IDs de instância repetidos; ações mutáveis bloqueadas"
            )
            self._render_primary_action()
            return
        if not self._instances:
            self._status_label.setText("Instalação, configuração e saúde: desconhecidas")
            self._render_primary_action()
            return
        instance = self._selected_instance()
        if instance is None:
            self._status_label.setText(
                f"{len(self._instances)} instâncias observadas · selecione uma para ver estado e ações."
            )
            self._render_primary_action()
            return
        self._status_label.setText(
            f"Instância: {instance.host_id} · escopo {instance.scope} · "
            f"Instalação: {instance.installation} · Origem: {instance.origin} · "
            f"Configuração: {instance.configuration} · Saúde: {instance.health} · "
            f"Ação: {'uso bloqueado' if instance.usage_blocked else instance.next_action}"
        )
        self._render_primary_action()

    def _clear_detail_actions(self) -> None:
        if self._detail_layout is None:
            return
        while self._detail_layout.count() > self._detail_actions_start:
            item = self._detail_layout.takeAt(self._detail_actions_start)
            widget = item.widget()
            if widget is not None:
                if widget in self._advanced_panels:
                    self._advanced_panels.remove(widget)
                widget.setParent(None)
                widget.deleteLater()

    def close_detail(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self.status_loader.cancel_all()
            self._host_list_pending = False
            if self._host_refresh_button is not None:
                self._host_refresh_button.setEnabled(True)
            self._selected_app_id = ""
            self._context_action_id = ""
            self._status_action_id = ""
            self._stack.setCurrentWidget(self._list_page)
            self.back_requested.emit()

    def show_catalog(self) -> None:
        if self._stack is not None and self._list_page is not None:
            self.status_loader.cancel_all()
            self._host_list_pending = False
            if self._host_refresh_button is not None:
                self._host_refresh_button.setEnabled(True)
            self._selected_app_id = ""
            self._context_action_id = ""
            self._status_action_id = ""
            self._stack.setCurrentWidget(self._list_page)

    def reload(self) -> None:
        if self._selected_app_id:
            self.open_product(self._selected_app_id, self._context_action_id)

    def block_while_running(self, running: bool) -> None:
        for card in self._cards.values():
            card.setEnabled(not running)
        if self._detail_page is not None:
            self._detail_page.setEnabled(not running)

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
