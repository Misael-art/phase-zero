"""Memory journey embedded in the existing AI page; execution stays in catalog."""
from dataclasses import replace
from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QFileDialog, QFrame, QGridLayout, QInputDialog, QLabel, QVBoxLayout, QWidget

from ..widgets import SectionHeader


STATUS_ID = "ai.memory-portability-status"
BUTTONS = {
    "install": ("ai.memory", "Instalar"),
    "repair": ("ai.memory-repair", "Reparar"),
    "sync": ("ai.memory-sync", "Sincronizar agora"),
    "portability-status": (STATUS_ID, "Atualizar estado"),
    **{name: ("ai.memory-" + name, title) for name, title in (
        ("scope-add", "Adicionar projeto"), ("device-add", "Cadastrar dispositivo"),
        ("github", "Conectar GitHub"), ("github-create", "Criar destino privado"),
        ("github-login", "Entrar no GitHub"),
        ("github-open-backups", "Backups no GitHub"),
        ("github-remove", "Desvincular GitHub"), ("device-remove", "Desvincular dispositivo"),
        ("scope-remove", "Parar compartilhamento"), ("settings", "Frequência e retenção"),
        ("automatic-on", "Ligar automação"), ("automatic-off", "Pausar automação"),
        ("backup", "Backup completo agora"), ("verify", "Verificar backup"),
        ("restore", "Restaurar backup"), ("key-export", "Guardar recuperação"),
        ("key-import", "Cadastrar outro host"), ("resolve", "Resolver conflitos"),
        ("curate", "Curar memorial"), ("curate-apply", "Revisar proposta"),
    )},
}


class MemoryCard(QFrame):
    def __init__(self, page):
        super().__init__(page)
        self.page = page
        self.payload = None
        self.buttons = {}
        self.setObjectName("settingsCard")
        self.setProperty("cardRole", "memory")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setAlignment(Qt.AlignTop)
        layout.addWidget(SectionHeader("Memória dos agentes", "Conhecimento entre hosts · backups privados por equipamento"))
        self.state = QLabel("Verificando memória…")
        self.state.setObjectName("memoryState")
        self.state.setWordWrap(True)
        self.state.setAccessibleName("Estado da memória")
        layout.addWidget(self.state)
        self.details = QLabel("Instale ou repare; cadastre projetos e destinos para sincronização automática.")
        self.details.setWordWrap(True)
        self.details.setTextFormat(Qt.PlainText)
        self.details.setObjectName("sectionCaption")
        layout.addWidget(self.details)
        self.targets = QLabel("")
        self.targets.setWordWrap(True)
        self.targets.setTextFormat(Qt.PlainText)
        self.targets.setObjectName("memoryTargets")
        layout.addWidget(self.targets)
        main = QGridLayout()
        advanced = QWidget()
        extra = QGridLayout(advanced)
        extra.setContentsMargins(0, 0, 0, 0)
        curation = QGridLayout()
        for index, (name, (action_id, title)) in enumerate(BUTTONS.items()):
            action = page.by_id.get(action_id)
            if action is None:
                continue
            page.mark_represented(action)
            button = page._action_button(action_id, title, primary=name in {"install", "sync"}, direct=True)
            button.setProperty("memoryRole", name)
            button.setAccessibleName(title)
            self.buttons[name] = button
            if name == "portability-status":
                button.clicked.disconnect()
                button.clicked.connect(self.fetch)
            elif name == "resolve":
                button.clicked.disconnect()
                button.clicked.connect(self.resolve_selected)
            elif name == "scope-add":
                button.clicked.disconnect()
                button.clicked.connect(self.enroll_project)
            elif name in {"curate", "curate-apply"}:
                button.clicked.disconnect()
                button.clicked.connect(self.select_memorial if name == "curate" else self.review_curation)
                curation.addWidget(button, 0, 0 if name == "curate" else 1)
                continue
            elif name in {"device-remove", "scope-remove"}:
                button.clicked.disconnect()
                button.clicked.connect(lambda _checked=False, selected=name: self.remove_selected(selected))
            grid = main if index < 4 else extra
            position = index if index < 4 else index - 4
            if index < 4:
                row, column = {"install": (0, 0), "sync": (0, 0), "repair": (0, 1), "portability-status": (1, 0)}[name]
            else:
                row, column = position // 2, position % 2
            grid.addWidget(button, row, column)
        layout.addLayout(main)
        layout.addWidget(SectionHeader("Curadoria do memorial"))
        self.curation_status = QLabel("Selecione um memorial.md para gerar uma proposta de revisão.")
        self.curation_status.setObjectName("sectionCaption")
        self.curation_status.setAccessibleName("Estado da curadoria")
        self.curation_status.setTextFormat(Qt.PlainText)
        self.curation_status.setWordWrap(True)
        layout.addWidget(self.curation_status)
        layout.addLayout(curation)
        self.advanced = advanced
        advanced.setVisible(page._advanced_mode)
        page._technical_widgets.append(advanced)
        # Destination setup belongs in the normal journey, not hidden in advanced mode.
        for name in ("scope-add", "device-add", "github", "github-login", "automatic-on", "automatic-off", "key-export"):
            extra.removeWidget(self.buttons[name])
        setup = QGridLayout()
        for index, name in enumerate(("scope-add", "device-add", "github", "github-login", "automatic-on", "automatic-off", "key-export")):
            setup.addWidget(self.buttons[name], index // 2, index % 2)
        layout.addLayout(setup)
        layout.addWidget(advanced)
        self.apply_buttons()

    def select_memorial(self):
        initial = Path(__file__).resolve().parents[3] / "assets/agent-skills/memorial.md"
        path, _ = QFileDialog.getOpenFileName(self, "Selecionar memorial", str(initial), "Memorial (memorial.md)")
        if path:
            self.request_curation_action("curate", "{path}", path)

    def review_curation(self):
        report_id = (self.payload or {}).get("curation", {}).get("id")
        if report_id:
            self.request_curation_action("curate-apply", "{id}", report_id)

    def request_curation_action(self, name, placeholder, value):
        action = self.page.by_id["ai.memory-" + name]
        self.page.action_requested.emit(replace(action,
            args=tuple(value if part == placeholder else part for part in action.args),
            preview_args=tuple(value if part == placeholder else part for part in action.preview_args),
            parameters=()))

    def resolve_selected(self):
        conflicts = (self.payload or {}).get("conflicts", [])
        labels = [f"{c.get('project', '')} · {c.get('sourceHost', {}).get('name', c['peer'])} · {c['sourceCreatedAt']} · {c['id'][:8]}" for c in conflicts]
        if not labels:
            return
        label, accepted = QInputDialog.getItem(self, "Resolver conflito", "Versão recebida para revisar", labels, 0, False)
        if accepted:
            conflict = conflicts[labels.index(label)]
            action = self.page.by_id["ai.memory-resolve"]
            self.page.action_requested.emit(replace(action,
                args=tuple(conflict["id"] if x == "{id}" else x for x in action.args),
                preview_args=tuple(conflict["id"] if x == "{id}" else x for x in action.preview_args),
                parameters=tuple(p for p in action.parameters if p.name != "id")))

    def enroll_project(self):
        projects = (self.payload or {}).get("availableProjects", [])
        labels = [f"{p['workspace_name']} / {p['project_name']}" for p in projects] + ["Criar projeto neste host e vincular checkout…"]
        label, accepted = QInputDialog.getItem(self, "Compartilhar projeto", "Projeto existente na memória", labels, 0, False)
        if accepted:
            if label == labels[-1]:
                action = self.page.by_id["ai.memory-scope-add"]
                self.page.action_requested.emit(replace(action, args=(*action.args, "--create-project")))
                return
            project = projects[labels.index(label)]
            action = self.page.by_id["ai.memory-scope-add"]
            values = {"{project}": project["project_name"], "{workspace}": project["workspace_name"]}
            self.page.action_requested.emit(replace(action,
                args=tuple(values.get(x, x) for x in action.args),
                parameters=tuple(p for p in action.parameters if p.name not in {"project", "workspace"})))

    def remove_selected(self, action_name):
        values = (self.payload or {}).get("devices" if action_name == "device-remove" else "scopes", [])
        labels = [str(value.get("label", value.get("project", value["id"]))) for value in values]
        if not labels:
            return
        label, accepted = QInputDialog.getItem(self, "Desvincular sem apagar dados", "Vínculo cadastrado", labels, 0, False)
        if accepted:
            selected = values[labels.index(label)]
            action = self.page.by_id["ai.memory-" + action_name]
            self.page.action_requested.emit(replace(action,
                args=tuple(selected["id"] if x == "{id}" else x for x in action.args), parameters=()))

    def fetch(self):
        action = self.page.by_id.get(STATUS_ID)
        if action:
            self.page.status_loader.fetch_action(action)

    def update_status(self, payload):
        self.payload = payload
        installed = payload.get("installed")
        active = payload.get("service") == "active"
        automatic = "ligada" if payload.get("automatic") else "pausada"
        self.state.setText(f"{'Memória ativa' if active else 'Precisa de reparo' if installed else 'Memória não instalada'} · automação {automatic}")
        if payload.get("sync", {}).get("state") == "waiting-unlock":
            self.state.setText("Sincronização aguardando desbloqueio do cofre do sistema")
        if payload.get("operationRunning"):
            self.state.setText("Sincronização ou manutenção em andamento…")
        if payload.get("recoveryRequired"):
            self.state.setText("Restauração necessária. Consulte diagnóstico e backup anterior antes de reparar.")
        projects = [s.get("project", "") for s in payload.get("scopes", [])]
        self.details.setText("Projetos compartilhados: " + (", ".join(projects) or "nenhum cadastrado") +
            ". Histórico completo preservado nos backups por host." +
            (" Guarde chave de recuperação fora deste equipamento." if not payload.get("recoveryExported") else " Chave de recuperação exportada."))
        if payload.get("companionInstalled") is False:
            self.details.setText(self.details.text() + " Use Reparar para preparar sincronizador oficial.")
        if payload.get("conflicts"):
            self.details.setText(self.details.text() + f" {len(payload['conflicts'])} conflito(s) preservado(s) para revisão.")
        rows = []
        results = {r["id"]: r for r in payload.get("sync", {}).get("targets", [])}
        for target in ([{"id": "github", "label": "GitHub privado"}] if payload.get("github") else []) + payload.get("devices", []):
            status = results.get(target["id"], {})
            backup = status.get("lastBackup") or {}
            state = {"current": "em dia", "waiting-unlock": "desbloqueie cofre do sistema",
                     "device-offline-or-ambiguous": "desconectado",
                     "retry-pending": "aguardando nova tentativa",
                     "knowledge-conflict-review-required": "conflito: revisão necessária",
                     "command-failed:gh:1": "verifique conexão e login GitHub",
                     "memory-key-unavailable-unlock-system-vault": "desbloqueie cofre do sistema"}.get(status.get("state"), "aguardando sincronização" if not status else "requer atenção")
            if target.get("online") is False:
                state = "desconectado"
            rows.append(f"{target.get('label', 'Dispositivo')}: {state} · backup verificado: {backup.get('verifiedAt', 'ainda não')}")
        self.targets.setText("\n".join(rows) or "Cadastre dispositivo ou repositório privado para proteger memória.")
        report = payload.get("curation") or {}
        if report:
            count = report.get("findings", 0)
            outcome = ("Alterações aplicadas ao memorial local." if report.get("applied") else
                       "Um achado para revisar." if count == 1 else
                       f"{count} achados para revisar." if count else
                       "A revisão não identificou achados com evidência.")
            self.curation_status.setText(f"{outcome} {report['provider']} · {report['model']}")
        else:
            self.curation_status.setText("Selecione um memorial.md para gerar uma proposta de revisão.")
        self.apply_buttons()

    def failed(self):
        self.payload = None
        self.state.setText("Estado da memória indisponível. Atualize estado para continuar.")
        self.curation_status.setText("Estado da curadoria indisponível. Atualize para consultar propostas.")
        self.apply_buttons()

    def apply_buttons(self):
        payload = self.payload or {}
        idle = not self.page._operation_running and not payload.get("operationRunning", False)
        report = payload.get("curation") or {}
        review_pending = bool(report.get("findings") and not report.get("applied"))
        curation_primary = "curate-apply" if review_pending else "curate"
        for name, button in self.buttons.items():
            enabled = self.payload is not None
            if name == "install":
                enabled = payload.get("installed") is False
            elif name == "repair":
                enabled = payload.get("installed") is True and not payload.get("recoveryRequired")
            elif name == "portability-status":
                enabled = not self.page.status_loader.running(STATUS_ID)
            elif name in {"sync", "backup"}:
                enabled = payload.get("service") == "active" and payload.get("keyConfigured") and bool(payload.get("devices") or payload.get("github"))
            elif name == "automatic-on":
                enabled = bool(payload.get("keyConfigured")) and not payload.get("automatic")
            elif name == "automatic-off":
                enabled = payload.get("automatic") is True
            elif name == "resolve":
                enabled = bool(payload.get("conflicts"))
            elif name == "curate-apply":
                enabled = review_pending
            elif name == "scope-add":
                enabled = payload.get("service") == "active"
            elif name == "scope-remove":
                enabled = bool(payload.get("scopes"))
            elif name == "device-remove":
                enabled = bool(payload.get("devices"))
            elif name == "github-remove":
                enabled = bool(payload.get("github"))
            elif name == "github-open-backups":
                enabled = bool(payload.get("github"))
            elif name in {"verify", "restore", "key-export"}:
                enabled = bool(payload.get("keyConfigured"))
            if name in {"curate", "curate-apply"}:
                style = "primaryButton" if name == curation_primary else "secondaryButton"
                if button.objectName() != style:
                    button.setObjectName(style)
                    button.style().unpolish(button)
                    button.style().polish(button)
            button.setEnabled(bool((idle or name == "portability-status" and not self.page._operation_running) and enabled))
        self.buttons["install"].setVisible(payload.get("installed") is not True)
        self.buttons["sync"].setVisible(payload.get("installed") is True)
