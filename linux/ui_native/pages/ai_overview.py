"""Read-only IA overview projected from the page's existing observations."""
from datetime import datetime
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QFrame, QGridLayout, QHBoxLayout, QLabel, QToolButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout
from ..widgets import SectionHeader

HOST = "ai.status"
MEMORY = "ai.memory-portability-status"
ECONOMY = "ai.token-economy"
HARNESS = "ai.deepseek-harness-status"
QUOTA = "ai.quota.status"
NAMES = {"ai-memory": "Memória", "codex": "Codex", "opencode": "OpenCode", "claude": "Claude Code",
         "rtk": "RTK", "hermes": "Hermes", "gemini": "Gemini CLI", "ollama": "Ollama",
         "openclaw": "OpenClaw", "codex-update-guard": "Proteção Codex Desktop", "ai-desktop-update": "Atualizações de IA"}


def configured_mcp(item):
    return isinstance(item, dict) and item.get("valid") is True and type(item.get("count")) is int and item["count"] > 0


def overview(observations):
    host = observations.get(HOST, {})
    clis = host.get("clis") if isinstance(host.get("clis"), dict) else {}
    installed = [name for name, item in clis.items() if isinstance(item, dict) and item.get("available") is True]
    services = host.get("services") if isinstance(host.get("services"), dict) else {}
    active = [name for name, item in services.items() if isinstance(item, dict) and item.get("active") is True]
    memory = observations.get(MEMORY)
    economy = observations.get(ECONOMY)
    harness = observations.get(HARNESS)
    rows = []
    rows.append(("Agentes e ferramentas", f"{len(installed)} instalados" if HOST in observations else "Aguardando leitura",
                 ", ".join(NAMES.get(n, n) for n in installed) or "Instalação e sessão são verificações distintas.", "info"))
    rows.append(("Serviços do host", f"{len(active)} ativos" if HOST in observations else "Aguardando leitura",
                 ", ".join(NAMES.get(n, n) for n in active) or "Nenhum serviço ativo confirmado.", "success" if active else "info"))
    rows.append(("Memória compartilhada", "Ativa" if memory and memory.get("serverReachable") is True else "Requer atenção" if memory else "Aguardando leitura",
                 "Sincronização automática ligada" if memory and memory.get("automatic") is True else "Revise projetos, sincronização e backup.",
                 "success" if memory and memory.get("serverReachable") is True else "warning" if memory else "info"))
    mcp = host.get("mcp")
    targets = mcp.get("targets", {}) if isinstance(mcp, dict) and isinstance(mcp.get("targets"), dict) else {}
    configured_targets = [t for t in targets.values() if configured_mcp(t)]
    invalid_targets = [t for t in targets.values() if isinstance(t, dict) and t.get("valid") is False]
    mcp_warning = bool(invalid_targets or isinstance(mcp, dict) and mcp.get("problems"))
    rows.append(("Conexões MCP", "Requer atenção" if mcp_warning else f"{len(configured_targets)} destinos configurados" if configured_targets else "Verificadas" if isinstance(mcp, dict) and "problems" in mcp else "Não verificadas",
                 "Integração configurada não comprova sessão ou acesso ao provedor.",
                 "warning" if mcp_warning else "info"))
    agents = (economy or {}).get("agents", [])
    configured = [a for a in agents if a.get("configured")]
    rows.append(("Eficiência e contexto", f"{len(configured)} perfis configurados" if economy else "Aguardando leitura",
                 "Memória obrigatória · economia opcional; ganho depende de medição.", "info"))
    running = harness and harness.get("runtimeState") == "running" and harness.get("healthCheck", {}).get("healthy") is True
    rows.append(("DeepSeek Harness", "Web ativo" if running else "Instalado · parado" if harness and harness.get("installed") and harness.get("runtimeState") == "stopped" else "Requer atenção" if harness and harness.get("state") == "degraded" else "Não instalado" if harness and harness.get("installed") is False else "Não verificado",
                 "Login, modelo e cota têm estados próprios.", "success" if running else "warning" if harness and harness.get("state") == "degraded" else "info"))
    routing = host.get("routing") if isinstance(host.get("routing"), dict) else {}
    router = routing.get("9router") if isinstance(routing.get("9router"), dict) else {}
    if router:
        title, state, detail, level = rows[3]
        rows[3] = (title, state, detail + (" Gateway 9Router ativo; provedores têm verificação própria." if router.get("healthy") is True else " Revise gateway 9Router."), level)
    components = [(NAMES.get(name, str(name)), "Instalado" if item.get("available") is True else "Não instalado" if item.get("available") is False else "Desconhecido", "CLI") for name, item in clis.items() if isinstance(item, dict)]
    components += [(NAMES.get(name, str(name)), "Ativo" if item.get("active") is True else "Parado" if item.get("active") is False else "Desconhecido", "Serviço") for name, item in services.items() if isinstance(item, dict)]
    ides = host.get("ides") if isinstance(host.get("ides"), dict) else {}
    components += [(NAMES.get(name, str(name)), "Instalado" if item.get("available") is True else "Não instalado" if item.get("available") is False else "Desconhecido", "IDE") for name, item in ides.items() if isinstance(item, dict)]
    components += [("MCP · " + NAMES.get(name, str(name)), "Revisar" if item.get("valid") is False else "Configurado" if configured_mcp(item) else "Não verificado", "Conexão") for name, item in targets.items() if isinstance(item, dict)]
    components += [(a.get("label", a.get("id", "Agente")), "Configurado" if a.get("configured") else "Padrão disponível", "Perfil") for a in agents if isinstance(a, dict)]
    if router:
        components.append(("9Router", "Gateway ativo" if router.get("healthy") is True else "Não verificado", "Gateway"))
    return rows, components


class AiOverview(QFrame):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("settingsCard")
        self.setProperty("cardRole", "aiOverview")
        self.observations = {}
        self._columns = None
        self._components = None
        layout = QVBoxLayout(self); layout.setContentsMargins(16, 14, 16, 14); layout.setSpacing(10)
        layout.addWidget(SectionHeader("Seu ambiente de IA", "Resumo do host · instalado, ativo e conectado têm significados diferentes."))
        self.updated = QLabel("Aguardando observações do host…"); self.updated.setObjectName("sectionCaption")
        layout.addWidget(self.updated)
        self.grid = QGridLayout(); self.grid.setSpacing(10); layout.addLayout(self.grid)
        self.tiles = []
        for _ in range(6):
            tile = QFrame(); tile.setObjectName("aiOverviewTile")
            body = QVBoxLayout(tile); body.setContentsMargins(10, 8, 10, 8); body.setSpacing(4)
            title = QLabel(); title.setObjectName("settingValue"); title.setWordWrap(True)
            state = QLabel(); state.setObjectName("badge"); state.setWordWrap(True)
            detail = QLabel(); detail.setObjectName("sectionCaption"); detail.setWordWrap(True)
            for label in (title, state, detail): body.addWidget(label)
            self.tiles.append((tile, title, state, detail))
        self.details = QToolButton(); self.details.setText("Ver todos os componentes"); self.details.setCheckable(True)
        self.details.setToolButtonStyle(Qt.ToolButtonTextBesideIcon); self.details.setArrowType(Qt.RightArrow)
        layout.addWidget(self.details)
        self.components = QTreeWidget(); self.components.setHeaderLabels(["Componente", "Estado observado", "Tipo"])
        self.components.setRootIsDecorated(False); self.components.setAccessibleName("Todos os componentes de IA observados")
        self.components.setMaximumHeight(220); self.components.hide()
        self.details.toggled.connect(self.toggle_details); layout.addWidget(self.components)
        self.render()

    def toggle_details(self, expanded):
        self.components.setVisible(expanded)
        self.details.setArrowType(Qt.DownArrow if expanded else Qt.RightArrow)

    def update_status(self, action_id, payload):
        if isinstance(payload, dict): self.observations[action_id] = payload
        else: self.observations.pop(action_id, None)
        self.updated.setText("Atualizado às " + datetime.now().strftime("%H:%M:%S") + " · dados indisponíveis não contam como ativos")
        self.render()

    def render(self):
        rows, components = overview(self.observations)
        for i, ((tile, title, state, detail), row) in enumerate(zip(self.tiles, rows)):
            title.setText(row[0]); state.setText(row[1]); detail.setText(row[2])
            state.setProperty("state", row[3]); state.style().unpolish(state); state.style().polish(state)
        self.reflow()
        if components != self._components:
            self._components = components
            self.components.clear()
            for item in components: QTreeWidgetItem(self.components, item)
            self.components.header().setStretchLastSection(False)
            self.components.header().setSectionResizeMode(0, self.components.header().ResizeMode.Stretch)

    def reflow(self):
        columns = 1 if self.width() < 480 else 2 if self.width() < 1100 else 3
        if columns == self._columns:
            return
        self._columns = columns
        for i, (tile, *_) in enumerate(self.tiles): self.grid.addWidget(tile, i // columns, i % columns)
        for i in range(3): self.grid.setColumnStretch(i, 1 if i < columns else 0)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.reflow()
