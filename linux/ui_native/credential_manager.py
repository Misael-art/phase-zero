"""Private wallet list and details, projected from CredentialVault metadata."""
from __future__ import annotations

from datetime import datetime

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QApplication, QAbstractItemView, QComboBox, QFrame, QGridLayout, QHBoxLayout, QHeaderView,
    QLabel, QLineEdit, QPushButton, QSizePolicy, QTableWidget, QVBoxLayout, QWidget,
)

from linux.ai.credential_inventory import CredentialUse, display_id, needs_review, stored_days
from linux.ai.credential_vault import CredentialEntry


def text_label(text: str, name: str = "sectionCaption") -> QLabel:
    label = QLabel(text)
    label.setObjectName(name)
    label.setTextFormat(Qt.PlainText)
    label.setWordWrap(True)
    label.setMinimumWidth(0)
    return label


def date_text(value: str) -> str:
    if not value:
        return "Não informada"
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().strftime("%d/%m/%Y %H:%M %Z").strip()


class CredentialManager(QWidget):
    add_requested = Signal()
    close_requested = Signal()
    observe_requested = Signal()
    remove_requested = Signal(str)
    revoke_requested = Signal(str)
    connect_requested = Signal(str)
    replace_requested = Signal(str)
    credit_requested = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("credentialManager")
        self.entries: tuple[CredentialEntry, ...] = ()
        self.uses: tuple[CredentialUse, ...] = ()
        self.credits = {}
        self.hidden = False
        self.busy = False
        self.unavailable = False
        self.selected_id = ""
        self.observation = "Uso no host ainda não consultado."
        self._compact = False
        self._filter_columns = 0
        self._detail_signature = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        breadcrumb = QHBoxLayout()
        back = QPushButton("Voltar")
        back.setObjectName("closeCredentialManager")
        back.clicked.connect(self.close_requested)
        breadcrumb.addWidget(back)
        breadcrumb.addWidget(text_label("Contas e conexões / Carteira"), 1)
        layout.addLayout(breadcrumb)
        actions = QHBoxLayout()
        actions.addWidget(text_label("Chaves de API", "pageTitle"), 1)
        self.add = QPushButton("Cadastrar chave")
        self.add.setObjectName("addApiCredential")
        self.add.setProperty("primary", True)
        self.add.clicked.connect(self.add_requested)
        self.observe = QPushButton("Atualizar uso no host")
        self.observe.setObjectName("observeCredentialUses")
        self.observe.clicked.connect(self.observe_requested)
        actions.addWidget(self.add)
        actions.addWidget(self.observe)
        layout.addLayout(actions)
        layout.addWidget(text_label("Datas de cadastro, situação e uso gerenciado neste computador."))
        self.totals = text_label("", "credentialTotals")
        layout.addWidget(self.totals)
        self.status = text_label("", "credentialVaultStatus")
        self.status.setAccessibleName("Status do cofre de credenciais")
        layout.addWidget(self.status)

        filters = QWidget()
        self.filters = QGridLayout(filters)
        self.filters.setContentsMargins(0, 0, 0, 0)
        self.search = QLineEdit()
        self.search.setObjectName("credentialSearch")
        self.search.setPlaceholderText("Nome ou identificador")
        self.search.setClearButtonEnabled(True)
        self.provider = QComboBox()
        self.provider.setObjectName("credentialProviderFilter")
        self.situation = QComboBox()
        self.situation.setObjectName("credentialSituationFilter")
        for label, value in (("Todas as situações", "all"), ("Em uso gerenciado", "running"),
                             ("A revisar", "review"), ("Registro ativo", "active"),
                             ("Gravação pendente", "pending"), ("Sem vínculo observado", "unbound")):
            self.situation.addItem(label, value)
        self.order = QComboBox()
        self.order.setObjectName("credentialSort")
        for label, value in (("Precisam de atenção", "attention"), ("Cadastro mais antigo", "oldest"),
                             ("Nome da chave", "name")):
            self.order.addItem(label, value)
        self._filter_fields = []
        for title, control in (("Buscar chave", self.search), ("Plataforma", self.provider),
                               ("Situação", self.situation), ("Ordenar por", self.order)):
            control.setAccessibleName(title)
            control.setMinimumWidth(0)
            control.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Fixed)
            field = QWidget()
            field_layout = QVBoxLayout(field)
            field_layout.setContentsMargins(0, 0, 0, 0)
            label = text_label(title)
            label.setBuddy(control)
            field_layout.addWidget(label)
            field_layout.addWidget(control)
            self._filter_fields.append(field)
        self.search.textChanged.connect(self._render)
        for combo in (self.provider, self.situation, self.order):
            combo.currentIndexChanged.connect(self._render)
        layout.addWidget(filters)

        self.list_heading = text_label("Chaves cadastradas", "sectionHeading")
        layout.addWidget(self.list_heading)
        self.body = QHBoxLayout()
        self.table = QTableWidget(0, 7)
        self.table.setObjectName("credentialTable")
        self.table.setAccessibleName("Lista de chaves de API cadastradas")
        self.table.setHorizontalHeaderLabels(["Chave", "Plataforma", "Situação", "Datas e idade", "Uso no host", "Verificação", "Ações"])
        self.table.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.table.setSelectionMode(QAbstractItemView.NoSelection)
        self.table.setShowGrid(False)
        self.table.verticalHeader().hide()
        self.table.horizontalHeader().setMinimumSectionSize(70)
        self.table.horizontalHeader().setDefaultAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(6, QHeaderView.Fixed)
        self.table.setColumnWidth(6, 106)
        self.table.setMinimumHeight(160)
        self.table.setMinimumWidth(0)
        self.body.addWidget(self.table, 3, Qt.AlignTop)
        self.detail = QFrame()
        self.detail.setObjectName("credentialDetails")
        self.detail.setMinimumWidth(0)
        self.details = QVBoxLayout(self.detail)
        self.body.addWidget(self.detail, 2, Qt.AlignTop)
        self.detail.hide()
        layout.addLayout(self.body)
        self.empty = text_label("Nenhuma chave cadastrada. Use Cadastrar chave para guardar uma no cofre.", "credentialEmpty")
        layout.addWidget(self.empty)
        self.coverage = text_label(self.observation, "credentialUsageCoverage")
        layout.addWidget(self.coverage)
        layout.addWidget(text_label(
            "Criação e expiração no provedor: não informadas. Cadastro no cofre é uma data diferente. "
            "Revisão após 90 dias é um lembrete local; não prova vazamento ou expiração. "
            "Uso externo, validade e saldo não são deduzidos do cadastro."
        ))
        layout.addWidget(text_label(
            "Acesso pela sessão deste usuário. Cofre do sistema pode pedir desbloqueio ao guardar ou remover. "
            "Esta lista não lê nem revela o valor das chaves. Voltar fecha os detalhes privados."
        ))
        layout.addStretch()
        self._reflow()

    def set_entries(self, entries, *, hidden=False, busy=False, unavailable=False):
        self.entries = tuple(entries)
        self.hidden, self.busy, self.unavailable = hidden, busy, unavailable
        selected_provider = self.provider.currentData()
        self.provider.blockSignals(True)
        self.provider.clear()
        self.provider.addItem("Todas as plataformas", "")
        for name in sorted({entry.provider for entry in self.entries}, key=str.casefold):
            self.provider.addItem(name, name)
        self.provider.setCurrentIndex(max(0, self.provider.findData(selected_provider)))
        self.provider.blockSignals(False)
        self.search.setEnabled(not hidden)
        if hidden:
            self.search.clear()
        self.add.setEnabled(not busy and not unavailable)
        self.observe.setEnabled(not busy and not unavailable)
        if not any(entry.account_id == self.selected_id for entry in self.entries):
            self.selected_id = ""
        self._render()

    def set_uses(self, uses, observation):
        self.uses = tuple(uses)
        self.observation = observation
        self._render()

    def close_details(self):
        selected = self.selected_id
        self.selected_id = ""
        self._reflow()
        self._render()
        for row, identity in enumerate(self._row_ids):
            if identity == selected:
                self.table.cellWidget(row, 6).setFocus(Qt.OtherFocusReason)
                break

    def _uses_for(self, entry):
        return tuple(use for use in self.uses if use.account_id == entry.account_id)

    def _name(self, entry):
        return f"Chave {self.entries.index(entry) + 1}" if self.hidden else entry.nickname

    def _state(self, entry):
        if entry.state == "pending":
            return "Gravação pendente\nreferência mantida para limpeza"
        return ("Revisar cadastro" if needs_review(entry) else "Registro ativo") + "\nValidade desconhecida"

    def _usage_text(self, entry):
        uses = self._uses_for(entry)
        if not uses:
            return "Sem vínculo observado\nUso externo desconhecido"
        use = uses[0]
        state = {"running": "Processo ativo", "starting-or-unhealthy": "Processo ativo; saúde incerta",
                 "configured": "Conexão selecionada; processo não observado",
                 "stopped": "Processo parado", "crashed-or-stale": "Processo não confirmado"}.get(use.state, "Estado desconhecido")
        return f"{use.consumer}\n{state}"

    def _render(self, *_args):
        query = self.search.text().strip().casefold()
        provider, situation = self.provider.currentData(), self.situation.currentData()
        rows = []
        for entry in self.entries:
            uses = self._uses_for(entry)
            if provider and entry.provider != provider:
                continue
            if query and query not in f"{entry.nickname} {display_id(entry)}".casefold():
                continue
            if situation == "running" and not any(use.running for use in uses):
                continue
            if situation == "review" and not needs_review(entry):
                continue
            if situation in {"active", "pending"} and entry.state != situation:
                continue
            if situation == "unbound" and uses:
                continue
            rows.append(entry)
        order = self.order.currentData()
        rows.sort(key=lambda entry: (
            (not needs_review(entry), entry.stored_at) if order == "attention" else
            (entry.stored_at,) if order == "oldest" else
            (self._name(entry).casefold(), entry.account_id)
        ))
        self._row_ids = tuple(entry.account_id for entry in rows)
        if self.selected_id and self.selected_id not in self._row_ids:
            self.selected_id = ""
            self._reflow()
        running = sum(any(use.running for use in self._uses_for(entry)) for entry in self.entries)
        self.totals.setText(f"{len(self.entries)} cadastradas   ·   {running} com processo ativo observado   ·   {sum(needs_review(entry) for entry in self.entries)} a revisar")
        self.list_heading.setText(f"Chaves cadastradas · {len(rows)} de {len(self.entries)}")
        self.status.setVisible(bool(self.status.text()))
        self.empty.setVisible(not rows)
        self.empty.setText("Registro indisponível. Corrija o acesso ao cofre e reabra a página." if self.unavailable else
                           "Nenhuma chave corresponde à busca. Limpe os filtros para ver todas." if self.entries else
                           "Nenhuma chave cadastrada. Use Cadastrar chave para guardar uma no cofre.")
        self.table.setVisible(bool(rows))
        # Qt defers destruction of replaced cell widgets. Hide them first so
        # old controls cannot paint over the new rows or receive user input.
        for row in range(self.table.rowCount()):
            for column in range(self.table.columnCount()):
                old = self.table.cellWidget(row, column)
                if old is not None:
                    old.hide()
        self.table.setRowCount(len(rows))
        for row, entry in enumerate(rows):
            identity = self._name(entry) + ("\nIdentificador oculto" if self.hidden else "\n" + display_id(entry))
            if self._compact and not self.hidden:
                identity += "\n" + entry.provider
            values = [identity, entry.provider, self._state(entry),
                      f"No cofre: {date_text(entry.stored_at)}\nHá {stored_days(entry)} dias\nCriação no provedor: não informada",
                      self._usage_text(entry), "Não verificada\nSaldo e expiração não informados"]
            for column, value in enumerate(values):
                label = text_label(value, "storedApiCredentialLabel" if column == 0 else
                                   "storedApiCredentialState" if column == 2 else "credentialCell")
                label.setContentsMargins(8, 10, 8, 10)
                label.setToolTip(value)
                self.table.setCellWidget(row, column, label)
            manage = QPushButton("Gerenciar")
            manage.setFixedHeight(36)
            manage.setObjectName("manageApiCredential")
            manage.setAccessibleName(f"Gerenciar {self._name(entry)}")
            manage.clicked.connect(lambda _checked=False, key=entry.account_id: self._select(key))
            self.table.setCellWidget(row, 6, manage)
            self.table.setRowHeight(row, 142 if not self._compact else 104)
        self.table.setFixedHeight(max(160, min(8, len(rows)) * (104 if self._compact else 142) + 42))
        self.coverage.setText(self.observation + " Cobertura: vínculos do DeepSeek Harness e OpenCode API OpenAI; processos do OpenCode e uso externo não verificados.")
        self._render_details()
        self._reflow()

    def _select(self, account_id):
        self.selected_id = account_id
        self._reflow()
        self._render()
        self.close_details_button.setFocus(Qt.OtherFocusReason)

    def _render_details(self):
        entry = next((entry for entry in self.entries if entry.account_id == self.selected_id), None)
        credit = self.credits.get(entry.account_id) if entry else None
        signature = (entry, credit, self.hidden, self.busy, self._uses_for(entry) if entry else ())
        if signature == self._detail_signature:
            return
        self._detail_signature = signature
        focus = QApplication.focusWidget()
        focus_name = focus.objectName() if focus and self.detail.isAncestorOf(focus) else ""
        while self.details.count():
            item = self.details.takeAt(0)
            if item.widget():
                item.widget().hide()
                item.widget().deleteLater()
        self.detail.setVisible(entry is not None)
        if entry is None:
            return
        self.details.addWidget(text_label(self._name(entry), "sectionHeading"))
        close = QPushButton("Fechar detalhes")
        self.close_details_button = close
        close.setObjectName("closeCredentialDetails")
        close.clicked.connect(self.close_details)
        self.details.addWidget(close)
        if focus_name == "closeCredentialDetails":
            close.setFocus(Qt.OtherFocusReason)
        self.details.addWidget(text_label(self._state(entry)))
        self.details.addWidget(text_label(credit.display() if credit else "Cota API: saldo e ativação ainda não informados.", "apiCreditState"))
        if credit:
            self.details.addWidget(text_label(
                f"Observado em: {date_text(credit.observed_at)} · vencimento: {date_text(credit.expires_at)}"
                + ("" if self.hidden else f"\nOrganização: {credit.organization}")))
        self.details.addWidget(text_label(
            f"Plataforma: {entry.provider}\nCadastrada no cofre: {date_text(entry.stored_at)}\n"
            f"Tempo de cadastro: {stored_days(entry)} dias\nCriação no provedor: não informada\n"
            "Expiração e renovação: não informadas\nÚltima verificação no provedor: não realizada"
        ))
        for use in self._uses_for(entry):
            self.details.addWidget(text_label(
                f"{self._usage_text(entry)}\nPasta sugerida: {'oculta' if self.hidden else use.project or 'não informada'}\n"
                f"PID do supervisor: {use.process_id or 'não confirmado'}\n"
                f"Observação local: {date_text(use.observed_at)}\nÚltima requisição: não observada"
            ))
        for title, name, signal, value in (
            ("Registrar cota da API", "recordApiCredit", self.credit_requested, entry.account_id),
            ("Configurar uso no app", "connectApiCredential", self.connect_requested, entry.provider),
            ("Cadastrar substituta", "replaceApiCredential", self.replace_requested, entry.provider),
            ("Revogar uso gerenciado", "revokeApiCredentialUse", self.revoke_requested, entry.account_id),
            ("Remover cópia local", "removeApiCredential", self.remove_requested, entry.account_id),
        ):
            button = QPushButton(title)
            button.setObjectName(name)
            button.setAccessibleName(f"{title}: {self._name(entry)}")
            button.setEnabled(not self.busy)
            if name == "revokeApiCredentialUse":
                button.setEnabled(not self.busy and bool(self._uses_for(entry)))
            button.clicked.connect(lambda _checked=False, sig=signal, val=value: sig.emit(val))
            self.details.addWidget(button)
            if focus_name == name:
                button.setFocus(Qt.OtherFocusReason)
        self.details.addWidget(text_label(
            "Substituição exige selecionar a nova chave e consentir no app. Remover apaga a cópia local; "
            "revogação definitiva acontece no provedor. Nenhum segredo é exibido nesta tela."
        ))
        self.details.addStretch()

    def _reflow(self):
        compact = self.width() < 920 or bool(self.selected_id)
        for column in (1, 3, 4, 5):
            self.table.setColumnHidden(column, compact)
        self._compact = compact
        columns = 2 if self.width() < 850 else 4
        if columns != self._filter_columns:
            self._filter_columns = columns
            for index, field in enumerate(self._filter_fields):
                self.filters.addWidget(field, index // columns, index % columns)
        self.body.setDirection(QHBoxLayout.TopToBottom if self.width() < 760 else QHBoxLayout.LeftToRight)
        if self.selected_id:
            width = self.width() if self.width() < 760 else int(self.width() * .4)
            self.detail.setMinimumHeight(max(self.details.sizeHint().height(), self.details.totalHeightForWidth(max(1, width))))

    def resizeEvent(self, event):
        previous = self._compact
        self._reflow()
        if previous != self._compact:
            self._render()
        super().resizeEvent(event)
