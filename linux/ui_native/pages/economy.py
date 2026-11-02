"""One project/client profile journey, reused from agent/product shortcuts."""
from dataclasses import replace

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QComboBox, QFileDialog, QFormLayout, QFrame, QHBoxLayout, QLabel,
    QLineEdit, QPushButton, QVBoxLayout, QMessageBox,
)

from ..widgets import SectionHeader

STATUS_ID = "ai.token-economy"


class EconomyCard(QFrame):
    def __init__(self, page):
        super().__init__(page)
        self.page = page
        self.payload = None
        self.setObjectName("settingsCard")
        self.setProperty("cardRole", "tokenEconomy")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.addWidget(SectionHeader("Eficiência dos agentes", "Memória sempre vinculada · economia por projeto e agente"))
        self.summary = QLabel("Escolha projeto para configurar e comparar resultados.")
        self.summary.setWordWrap(True)
        self.summary.setTextFormat(Qt.PlainText)
        self.summary.setAccessibleName("Estado da eficiência")
        layout.addWidget(self.summary)
        form = QFormLayout()
        project_row = QHBoxLayout()
        self.project = QLineEdit()
        self.project.setPlaceholderText("Pasta do projeto")
        self.project.setAccessibleName("Projeto para economia de tokens")
        self.browse = QPushButton("Escolher pasta")
        self.browse.setObjectName("secondaryButton")
        self.browse.clicked.connect(self.choose_project)
        project_row.addWidget(self.project, 1)
        project_row.addWidget(self.browse)
        form.addRow("Projeto", project_row)
        self.agent = QComboBox()
        self.agent.setAccessibleName("Agente para economia de tokens")
        # Catalog choices are the same policy used by the backend.
        action = page.by_id.get("ai.tokens-apply")
        if action:
            for agent in next(p.choices for p in action.parameters if p.name == "agent"):
                self.agent.addItem(agent, agent)
        form.addRow("Agente", self.agent)
        self.profile = QComboBox()
        self.profile.setAccessibleName("Perfil de eficiência")
        self.profile.addItem("Padrão · essencial", "basic")
        self.profile.addItem("Econômico · contexto enxuto", "economy")
        form.addRow("Perfil", self.profile)
        layout.addLayout(form)
        self.memory = QLabel("Memória: aguardando verificação.")
        self.evidence = QLabel("Economia de custo: ainda não medida.")
        for label in (self.memory, self.evidence):
            label.setWordWrap(True)
            label.setTextFormat(Qt.PlainText)
            layout.addWidget(label)
        row = QHBoxLayout()
        self.apply = QPushButton("Aplicar perfil")
        self.apply.setObjectName("primaryButton")
        self.reset = QPushButton("Restaurar padrão")
        self.refresh = QPushButton("Atualizar estado")
        self.measure = QPushButton("Medir saída local")
        self.buttons = (self.apply, self.reset, self.refresh, self.measure)
        for button in self.buttons:
            button.setAccessibleName(button.text())
            if button is not self.apply:
                button.setObjectName("secondaryButton")
        # Two rows keep all primary controls visible on narrow screens.
        row.addWidget(self.apply)
        row.addWidget(self.reset)
        layout.addLayout(row)
        second = QHBoxLayout()
        second.addWidget(self.refresh)
        second.addWidget(self.measure)
        layout.addLayout(second)
        self.apply.clicked.connect(lambda: self.dispatch("apply"))
        self.reset.clicked.connect(lambda: self.dispatch("reset"))
        self.measure.clicked.connect(lambda: self.dispatch("measure"))
        self.refresh.clicked.connect(self.fetch)
        self.project.editingFinished.connect(self.fetch)
        self.project.textChanged.connect(lambda: self.render())
        self.agent.currentIndexChanged.connect(self.agent_changed)
        self.detail = QLabel("Headroom experimental: uso gerenciado aguarda homologação de rota, conta e memória. "
                             "Perfis preservam modelo, permissões, MCPs e testes. Abra nova sessão após aplicar.")
        self.detail.setWordWrap(True)
        self.detail.setObjectName("sectionCaption")
        layout.addWidget(self.detail)
        extra = QHBoxLayout()
        self.import_usage = QPushButton("Importar comparação A/B")
        self.review = QPushButton("Revisar componentes")
        for button in (self.import_usage, self.review):
            button.setObjectName("secondaryButton")
            extra.addWidget(button)
            button.setAccessibleName(button.text())
        layout.addLayout(extra)
        self.import_usage.clicked.connect(self.import_report)
        self.review.clicked.connect(self.show_review)
        for name in ("apply", "reset", "measure", "record", "review"):
            action = page.by_id.get("ai.tokens-" + name)
            if action:
                page.mark_represented(action)
        page.mark_represented(page.by_id[STATUS_ID]) if STATUS_ID in page.by_id else None
        self.render()

    def choose_project(self):
        folder = QFileDialog.getExistingDirectory(self, "Escolher projeto", self.project.text())
        if folder:
            self.project.setText(folder)
            self.fetch()

    def fetch(self):
        if self.page.status_loader.running(STATUS_ID):
            return
        args = ["ai", "token-economy", "status", "--json"]
        if self.project.text().strip():
            args += ["--project", self.project.text().strip()]
        self.payload = None
        self.render()
        self.page.status_loader.fetch(STATUS_ID, args)

    def update_status(self, payload):
        if payload.get("ok") is not True:
            self.failed()
            return
        self.payload = payload
        for row in payload.get("agents", []):
            index = self.agent.findData(row["id"])
            if index >= 0:
                self.agent.setItemText(index, row["label"])
        if not self.project.hasFocus() and payload.get("project"):
            self.project.setText(payload["project"])
        row = next((r for r in payload.get("agents", []) if r["id"] == self.agent.currentData()), {})
        self.profile.setCurrentIndex(max(0, self.profile.findData(row.get("profile", "basic"))))
        self.render()

    def agent_changed(self):
        row = next((r for r in (self.payload or {}).get("agents", []) if r["id"] == self.agent.currentData()), {})
        self.profile.setCurrentIndex(max(0, self.profile.findData(row.get("profile", "basic"))))
        self.render()

    def failed(self):
        self.payload = None
        self.summary.setText("Estado indisponível. Atualize antes de aplicar perfil.")
        self.render()

    def select_agent(self, agent):
        index = self.agent.findData(agent)
        if index >= 0:
            self.agent.setCurrentIndex(index)

    def render(self):
        payload = self.payload or {}
        selected = next((r for r in payload.get("agents", []) if r["id"] == self.agent.currentData()), {})
        idle = not self.page._operation_running
        # An edited path cannot inherit another project's readiness.
        same_project = bool(payload.get("project") and self.project.text().strip() == payload["project"])
        ready = idle and same_project and bool(selected) and not selected.get("drift")
        self.apply.setEnabled(ready)
        self.reset.setEnabled(ready and selected.get("configured", False))
        self.measure.setEnabled(ready and payload.get("rtk", {}).get("installed", False))
        if hasattr(self, "import_usage"):
            self.import_usage.setEnabled(ready)
            self.review.setEnabled(idle and bool(self.payload))
        self.refresh.setEnabled(idle and not self.page.status_loader.running(STATUS_ID))
        for widget in (self.agent, self.profile, self.project, self.browse):
            widget.setEnabled(idle)
        if not selected:
            return
        self.agent.setItemText(self.agent.currentIndex(), selected.get("label", selected["id"]))
        self.profile.setToolTip("Configurado: " + selected["profile"] + ". Escolha perfil e aplique para mudar.")
        state = "alteração externa: revisão necessária" if selected.get("drift") else "regras configuradas" if selected.get("configured") else "padrão disponível para preparar"
        self.summary.setText(f"{selected['label']}: {state}. Uso nesta sessão ainda não verificado.")
        memory = selected.get("memory", {})
        self.memory.setText("ai-memory: " + ("serviço e vínculo presentes" if memory.get("connected") else "vínculo indisponível ou não verificado; use Reparar memória") + ". Obrigatória nos dois perfis.")
        hook_state = "captura configurada" if memory.get("hooks") is True else "captura não configurada" if memory.get("hooks") is False else "hooks não homologados"
        self.memory.setText(self.memory.text() + " " + hook_state + ".")
        report = payload.get("measurements", {}).get(selected["id"])
        if report:
            percent = report.get("reductionPercent")
            text = f"Saída local: {percent}% de redução em bytes" if percent is not None else "Saída local sem volume para comparar"
            self.evidence.setText(text + ". Tokens estimados; custo API e qualidade da sessão não medidos.")
        else:
            self.evidence.setText("Saída local ainda não comparada. Custo API e qualidade da sessão não medidos.")
        pairs = [p for p in payload.get("usage", {}).get("pairs", []) if p["agent"] == selected["id"]]
        if pairs:
            accepted = sum(bool(p["accepted"]) for p in pairs)
            self.evidence.setText(self.evidence.text() + f" A/B: {len(pairs)} par(es) reportado(s), {accepted} com aceite nos dois perfis.")
        comparison = payload.get("usage", {}).get("byAgent", {}).get(selected["id"])
        if comparison:
            self.evidence.setText(self.evidence.text() + f" Tokens reportados: {comparison['baselineTokens']} → {comparison['economyTokens']} "
                                 f"({comparison['reductionPercent']}%); {comparison['retryRegressions']} regressão(ões) de tentativas.")
        if payload.get("review", {}).get("stale"):
            self.summary.setText(self.summary.text() + " Revisão de compatibilidade vencida.")

    def show_review(self):
        if not self.payload:
            return
        review = self.payload.get("review", {})
        rows = ["Revisão: " + str(review.get("reviewedAt", "desconhecida"))]
        names = {"required": "Essencial", "basic": "Padrão", "experimental": "Experimental",
                 "optional-style": "Preferência de estilo", "candidate": "Em avaliação",
                 "workspace-only": "Projetos compatíveis", "not-integrated": "Sem integração"}
        rows += [f"{r['id']} · {names.get(r['decision'], r['decision'])}\n{r['reason']}" for r in review.get("components", [])]
        QMessageBox.information(self, "Compatibilidade e finalidade", "\n\n".join(rows))

    def import_report(self):
        path, _filter = QFileDialog.getOpenFileName(self, "Importar metadados de uso", "", "JSON (*.json)")
        if path:
            self.dispatch("record", path)

    def dispatch(self, name, path=""):
        if not self.payload or self.page._operation_running:
            return
        action = self.page.by_id.get("ai.tokens-" + name)
        if not action:
            return
        if self.project.text().strip() != self.payload.get("project"):
            return
        values = {"project": self.project.text().strip(), "agent": self.agent.currentData(), "profile": self.profile.currentData(), "path": path}
        # Shared runner retains confirmation/plan and target binding.
        resolved = replace(action, args=action.resolved_args(values=values), parameters=(),
                           preview_args=tuple(v.format(**values) for v in action.preview_args) if action.preview_args else ())
        self.page.action_requested.emit(resolved)
