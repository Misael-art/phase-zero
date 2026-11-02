from __future__ import annotations

import json
import os
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QStyle, QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..widgets import SectionHeader, themed_icon
from .base import BasePage
from .memory import MemoryCard, STATUS_ID as MEMORY_STATUS_ID
from .economy import EconomyCard, STATUS_ID as ECONOMY_STATUS_ID
from .ai_overview import AiOverview


_PRIMARY_IDS = {
    "ai.status",
    "ai.doctor",
    "ai.repair",
    "ai.opencode-status",
    "ai.opencode-install",
    "ai.opencode-verify",
    "ai.opencode-free",
    "ai.claude-status",
    "ai.claude-install",
    "ai.claude-verify",
    "ai.claude-bonsai-login",
    "ai.bonsai-diagnose",
    "ai.quota.status",
    "ai.quota.install",
    "ai.quota.remove",
    "ai.desktop.status",
    "ai.desktop.claude",
    "ai.desktop.claude.check",
    "ai.desktop.claude.update",
    "ai.desktop.updates.on",
    "ai.desktop.updates.off",
    "ai.mcp-sync",
    "ai.compat",
    "ai.memory",
    "ai.ides",
    "ai.admin",
}

# Gateways live on Proxies IA; keep them off the leftover dump here.
_REPRESENTED_ELSEWHERE = {
    "ai.9router-status",
    "ai.9router-tui",
    "ai.9router-repair",
    "ai.9router-install",
    "ai.9router-dashboard",
    "ai.9router-test",
    "ai.9router-secrets",
    "ai.9router-combos",
    "ai.9router-usage",
    "ai.9router-client",
    "ai.9router-check",
    "ai.9router-update",
    "ai.9router-doctor",
    "ai.odysseus-status",
    "ai.odysseus-install",
    "ai.odysseus-open",
    "ai.odysseus-check",
    "ai.odysseus-update",
    "ai.odysseus-backup",
    "ai.odysseus-doctor",
    "ai.hermes-status",
    "ai.hermes-doctor",
    "ai.workspaces-doctor",
    "ai.workspaces-plan",
    "ai.operations-status",
    "ai.operations-resume",
    "ai.updates-status",
    "ai.updates-timer",
    "ai.claude-bonsai-run",
}


# The ChatGPT Web bridge stays out of the public catalog while its gates are
# pending. This card is private to hosts that already opted in through the
# manager: its actions are built here and never registered in the catalog.
_QUOTA_STATUS_ID = "ai.quota.status"
_DESKTOP_STATUS_ID = "ai.desktop.status"
_CLAUDE_CHECK_ID = "ai.desktop.claude.check"
_HARNESS_STATUS_ID = "ai.deepseek-harness-status"
_HARNESS_ACTIONS = ("status", "plan", "install", "update", "start", "open", "login", "stop", "doctor", "uninstall")
_LEVEL_STATES = {"green": "success", "yellow": "warning", "red": "error"}
_BRIDGE_STATUS_ID = "private.chatgpt-web.status"
_BRIDGE_ARGS = ("ai", "chatgpt-web")
_BRIDGE_STAGES = {
    "opted-in": "aceito, ainda não instalado",
    "package-verified": "instalado, ainda não configurado",
    "launcher-configured": "configurado, mas desligado",
    "web-model": "modelo Web ativo (sem ferramentas locais)",
    "tools-experimental": "modelo Web com ferramentas (experimental)",
}
_BRIDGE_BUTTONS = (
    # object name, label, command, mutable, what changes
    ("chatgptWebOpen", "Abrir Web", ("desktop",), False, ""),
    ("chatgptWebSetup", "Preparar ou reparar", ("setup", "--login-wait", "0"), True,
     "Inicia o launcher isolado e o bridge local e religa a rota no perfil dedicado. "
     "O ~/.codex do seu Codex normal não é alterado."),
    ("chatgptWebTools", "Ver requisitos", ("tools", "status"), False, ""),
    ("chatgptWebToolsOn", "Ligar ferramentas", ("tools", "enable"), True,
     "Troca o launcher isolado para o modo com ferramentas, confere túnel e conector e "
     "volta sozinho ao modo Web se algo falhar. O Codex segue no sandbox somente leitura."),
    ("chatgptWebToolsOff", "Desligar ferramentas", ("tools", "disable"), True,
     "Volta ao modo Web e encerra o túnel. O ~/.codex do seu Codex normal não é alterado."),
    ("chatgptWebSmoke", "Testar modelo (1 mensagem)", ("smoke",), True,
     "Envia um turno real pelo bridge. Gasta uma mensagem da sua conta ChatGPT."),
    ("chatgptWebUpdate", "Atualizar app", ("update",), True,
     "Baixa a versão mais nova do Codex Web GPT, confere o SHA-256 publicado na release, "
     "migra a integração e religa o launcher isolado. Feche somente o Codex do perfil Web "
     "antes; login e preferências são mantidos. Se uma atualização ficou incompleta, "
     "conclui com o pacote local já conferido; clique novamente para retomar."),
    ("chatgptWebDisable", "Desligar", ("disable",), True,
     "Restaura a rota do perfil dedicado e encerra o launcher. O ~/.codex do seu Codex "
     "normal não é alterado; o login do ChatGPT no launcher é mantido."),
)


def _bridge_opted_in() -> bool:
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    root = Path(os.environ.get("PZ_CHATGPT_WEB_ROOT") or data / "phasezero/chatgpt-web")
    try:
        state = json.loads((root / "state.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return isinstance(state, dict) and bool(state.get("optIn"))


def _cli_available(payload: dict, name: str) -> bool:
    clis = payload.get("clis") if isinstance(payload.get("clis"), dict) else {}
    node = clis.get(name)
    return bool(isinstance(node, dict) and node.get("available"))


class AiDevPage(BasePage):
    """WinVM-style home for agents, MCPs and host AI tools."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._operation_running = False
        self._payload: dict = {}
        self._technical_widgets: list[QWidget] = []
        self._bridge_buttons: dict[str, QPushButton] = {}
        self._bridge_ready = False
        self._quota_toggle_id = "ai.quota.install"
        self._updates_on: bool | None = None
        self._quota_rows: list[QWidget] = []
        self._harness_payload: dict | None = None
        self._harness_buttons: dict[str, QPushButton] = {}

    def build(self) -> None:
        for action_id in _PRIMARY_IDS | _REPRESENTED_ELSEWHERE | {
            f"ai.deepseek-harness-{name}" for name in _HARNESS_ACTIONS
        }:
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(14)
        layout.addWidget(self._build_hero())
        self.overview = AiOverview(self)
        layout.addWidget(self.overview)
        layout.addWidget(self._build_quota_card())
        cards = QGridLayout()
        cards.setContentsMargins(0, 0, 0, 0)
        cards.setHorizontalSpacing(14)
        cards.setVerticalSpacing(14)
        cards.addWidget(self._agent_card(
            "OpenCode",
            "Verificação disponível; uso gerenciado bloqueado sem vínculo da conta por requisição",
            "opencode",
            "ai.opencode-verify",
            "Verificar",
            "ai.opencode-free",
            "Modelo free",
        ), 0, 0)
        cards.addWidget(self._agent_card(
            "Claude",
            "Cliente Claude Code",
            "claude",
            "ai.claude-install",
            "Reparar",
            "ai.claude-verify",
            "Verificar",
        ), 0, 1)
        cards.addWidget(self._tool_card(
            "MCPs",
            "Servidores seguros nas IDEs e agentes",
            "mcp",
            "ai.mcp-sync",
            "Sincronizar",
            "ai.repair",
            "Reparar",
        ), 1, 0)
        cards.addWidget(self._tool_card(
            "Agentes no host",
            "RTK, Caveman e ponte admin",
            "compat",
            "ai.compat",
            "Configurar",
            "ai.admin",
            "Ponte admin",
        ), 1, 1)
        cards.setColumnStretch(0, 1)
        cards.setColumnStretch(1, 1)
        layout.addLayout(cards)
        self.economy_card = EconomyCard(self)
        layout.addWidget(self.economy_card)
        self.memory_card = MemoryCard(self)
        layout.addWidget(self.memory_card)
        layout.addWidget(self._build_harness_card())
        layout.addWidget(self._build_desktop_apps_card())
        layout.addWidget(self._build_bonsai_card())
        layout.addWidget(self._build_bridge_card())
        layout.addWidget(self._build_advanced_connections())
        layout.addWidget(self._build_shortcuts())
        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll, 1)
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def _build_harness_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        card.setProperty("cardRole", "deepseekHarness")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "DeepSeek Harness · Experimental",
            "Agente oficial de desenvolvimento, com conta e API independentes do DeepSeek Proxy.",
        ))
        self.harness_state = QLabel("● Verificando DeepSeek Harness…")
        self.harness_state.setObjectName("deepseekHarnessState")
        self.harness_state.setWordWrap(True)
        self.harness_state.setAccessibleName("Estado do DeepSeek Harness")
        layout.addWidget(self.harness_state)
        journey = QLabel("Instalar → Conectar → Escolher pasta → Verificar → Abrir → Parar")
        journey.setObjectName("deepseekHarnessJourney")
        journey.setWordWrap(True)
        journey.setAccessibleName("Etapas do DeepSeek Harness")
        layout.addWidget(journey)
        self.harness_next = QLabel("Próximo passo: aguarde a leitura do estado local.")
        self.harness_next.setObjectName("sectionCaption")
        self.harness_next.setWordWrap(True)
        layout.addWidget(self.harness_next)
        primary_row = QHBoxLayout()
        secondary_row = QHBoxLayout()
        for index, (name, label) in enumerate((
            ("install", "Instalar"), ("start", "Conectar / escolher pasta"),
            ("open", "Abrir"), ("stop", "Parar"), ("doctor", "Verificar"), ("login", "Entrar com DeepSeek"),
            ("status", "Atualizar estado"),
        )):
            button = self._action_button(
                f"ai.deepseek-harness-{name}", label, primary=name in {"install", "start", "open"}, direct=True,
            )
            if button is not None:
                button.setProperty("harnessRole", name)
                button.setAccessibleName(label)
                if name == "status":
                    button.clicked.disconnect()
                    button.clicked.connect(self._fetch_harness)
                self._harness_buttons[name] = button
                (primary_row if index < 3 else secondary_row).addWidget(button)
        primary_row.addStretch()
        secondary_row.addStretch()
        layout.addLayout(primary_row)
        layout.addLayout(secondary_row)
        boundary = QLabel(
            "Experimental · conta, saldo e cota exigem verificação própria. "
            "A política de arquivos não limita rede nem processos; isolamento do runtime ainda não comprovado."
        )
        boundary.setObjectName("deepseekHarnessBoundary")
        boundary.setWordWrap(True)
        layout.addWidget(boundary)
        advanced = QWidget()
        advanced_layout = QVBoxLayout(advanced)
        advanced_layout.setContentsMargins(0, 0, 0, 0)
        details = QLabel(
            "Perfil Web sob demanda, porta loopback configurável e telemetria desativada. "
            "ACP/SDK, plugins/MCPs e início automático aguardam integração validada. "
            "Proxy/9Router continua bloqueado até grants por requisição. Conta e API não fazem fallback. "
            "V8 limitado a 2 GiB; ferramentas e processos filhos não têm cota rígida."
        )
        details.setObjectName("deepseekHarnessAdvanced")
        details.setWordWrap(True)
        advanced_layout.addWidget(details)
        row = QHBoxLayout()
        for name, label in (("plan", "Revisar instalação"), ("update", "Atualizar versão"), ("uninstall", "Remover")):
            button = self._action_button(f"ai.deepseek-harness-{name}", label, primary=False, direct=True)
            if button is not None:
                button.setProperty("harnessRole", name)
                button.setAccessibleName(label)
                self._harness_buttons[name] = button
                row.addWidget(button)
        advanced_layout.addLayout(row)
        advanced.setVisible(self._advanced_mode)
        self._technical_widgets.append(advanced)
        layout.addWidget(advanced)
        self._apply_harness_buttons()
        self.harness_card = card
        return card

    def _fetch_harness(self) -> None:
        action = self.by_id.get(_HARNESS_STATUS_ID)
        if action is not None:
            self.status_loader.fetch_action(action)

    def focus_journey(self, key: str) -> None:
        if key.startswith("economy"):
            agent = key.partition(":")[2]
            if agent:
                self.economy_card.select_agent(agent)
            scroll = self.findChild(QScrollArea)
            if scroll:
                scroll.ensureWidgetVisible(self.economy_card.summary, 8, 8)
            self.economy_card.agent.setFocus()
            return
        if key in {"memory", "ai-memory"}:
            scroll = self.findChild(QScrollArea)
            if scroll is not None:
                scroll.ensureWidgetVisible(self.memory_card.state, 8, 8)
            for name in ("install", "sync", "repair", "portability-status"):
                button = self.memory_card.buttons[name]
                if button.isEnabled() and not button.isHidden():
                    button.setFocus()
                    break
            return
        if key == "deepseek-harness":
            scroll = self.findChild(QScrollArea)
            if scroll is not None:
                scroll.ensureWidgetVisible(self.harness_state, 8, 8)
            for name in ("install", "start", "open", "doctor"):
                button = self._harness_buttons.get(name)
                if button is not None and button.isEnabled() and not button.isHidden():
                    button.setFocus()
                    break

    def _apply_harness_buttons(self) -> None:
        payload = self._harness_payload or {}
        installed = payload.get("installed")
        running = payload.get("runtimeState") in {"running", "starting-or-unhealthy"}
        state = payload.get("state")
        enabled = not self._operation_running
        available = {
            "install": installed is False and not running,
            "start": installed is True and not running and payload.get("memoryBudget") == "sufficient",
            "open": running and state == "running", "stop": running,
            "login": running and state == "running" and payload.get("authRoute") == "account" and "account-oauth" in payload.get("connectionFeatures", []),
            "update": installed is True and not running,
            "uninstall": (installed is True or state == "degraded") and not running,
            "doctor": True, "plan": True,
            "status": not self.status_loader.running(_HARNESS_STATUS_ID),
        }
        for name, button in self._harness_buttons.items():
            button.setEnabled(enabled and available.get(name, False))
            if name in {"install", "start", "open", "login"}:
                button.setVisible(available[name])

    def _on_harness_status(self, payload: dict) -> None:
        self._harness_payload = payload
        state = str(payload.get("state", "unknown"))
        installed = payload.get("installed")
        route = {"account": "conta DeepSeek", "api": "chave API"}.get(payload.get("authRoute"), "não escolhida")
        if state == "running":
            self._set_label_state(self.harness_state, f"● Web ativo em loopback · rota {route}", "success")
            phase = (payload.get("oauth") or {}).get("phase")
            if phase in {"initializing", "waiting-browser", "exchanging", "committing"}:
                step = "Conclua autorização no site DeepSeek."
            elif payload.get("accountAuth") == "credential-stored":
                step = "Autorização guardada pelo Harness; abra o app e confirme o projeto."
            elif payload.get("apiCredentialSource") == "phasezero-wallet":
                step = "Chave da carteira vinculada ao processo API; abra o app e confirme o projeto."
            elif "account-oauth" not in payload.get("connectionFeatures", []):
                step = "Supervisor anterior: pare e conecte novamente para carregar novo fluxo de entrada."
            else:
                step = "Use Entrar com DeepSeek ou abra o app para revisar a conexão."
            self.harness_next.setText(step + " Validade, cota e saldo ainda não verificados.")
        elif payload.get("runtimeState") == "starting-or-unhealthy":
            self._set_label_state(self.harness_state, "● Runtime iniciado · saúde ainda não confirmada", "warning")
            self.harness_next.setText("Próximo passo: atualize o estado, use Verificar ou Pare o runtime antes de tentar outra configuração.")
        elif state == "degraded":
            self._set_label_state(self.harness_state, "● DeepSeek Harness precisa de atenção", "warning")
            self.harness_next.setText("Próximo passo: use Verificar para diagnosticar runtime e recuperação.")
        elif installed is True:
            self._set_label_state(self.harness_state, f"● Versão {payload.get('installedVersion', '')} instalada · parado", "info")
            self.harness_next.setText("Chave removida da carteira ou configuração alterada. Revise chave selecionada antes de conectar novamente."
                                     if payload.get("lifecycleNotice") == "wallet-selection-revoked-or-overridden" else
                                     "Próximo passo: Conectar sugere seu projeto e oferece login DeepSeek ou chave da carteira.")
        elif installed is False:
            self._set_label_state(self.harness_state, "● DeepSeek Harness não instalado", "info")
            self.harness_next.setText("Próximo passo: revise a instalação. Preparar o app não inicia serviços nem conecta contas.")
        else:
            self._set_label_state(self.harness_state, "● Estado do DeepSeek Harness desconhecido", "warning")
            self.harness_next.setText("Próximo passo: atualize o estado ou use Verificar.")
        if payload.get("memoryBudget") != "sufficient":
            self.harness_next.setText(self.harness_next.text() + " Início exige pelo menos 2 GiB de memória disponível medida.")
        self._apply_harness_buttons()

    # ---- quotas and subscriptions -----------------------------------------

    def _build_quota_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        card.setProperty("cardRole", "quota")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Franquias e assinaturas",
            "Restante de cada conta (100% → 0%), renovação, plano e vencimento",
        ))
        self.quota_state = QLabel("● Verificando…")
        self.quota_state.setObjectName("chatgptWebState")
        self.quota_state.setAccessibleName("Estado dos medidores de franquia")
        self.quota_state.setWordWrap(True)
        layout.addWidget(self.quota_state)
        self.quota_grid = QGridLayout()
        self.quota_grid.setHorizontalSpacing(10)
        self.quota_grid.setVerticalSpacing(6)
        self.quota_grid.setColumnStretch(3, 1)
        layout.addLayout(self.quota_grid)
        legend = QLabel("Cores: verde acima de 60% · amarelo de 21% a 60% · vermelho 20% ou menos")
        legend.setObjectName("sectionCaption")
        legend.setWordWrap(True)
        layout.addWidget(legend)
        row = QHBoxLayout()
        row.setSpacing(10)
        self.quota_toggle = QPushButton("Ligar medidores na bandeja")
        self.quota_toggle.setObjectName("primaryButton")
        self.quota_toggle.setProperty("quotaRole", "toggle")
        self.quota_toggle.clicked.connect(self._toggle_quota_tray)
        row.addWidget(self.quota_toggle)
        refresh = QPushButton("Atualizar")
        refresh.setObjectName("secondaryButton")
        refresh.setProperty("quotaRole", "refresh")
        refresh.setToolTip("Lê de novo uso, renovação e assinatura de cada conta.")
        refresh.clicked.connect(self._fetch_quota)
        self.quota_refresh = refresh
        row.addWidget(refresh)
        row.addStretch()
        layout.addLayout(row)
        self.quota_card = card
        return card

    def _fetch_quota(self) -> None:
        if not self.status_loader.running(_QUOTA_STATUS_ID):
            self.status_loader.fetch(_QUOTA_STATUS_ID, ["ai", "quota", "status", "--json"])

    def _toggle_quota_tray(self) -> None:
        action = self.by_id.get(self._quota_toggle_id)
        if action is not None:
            self.action_requested.emit(action)

    def _on_quota_status(self, payload: dict) -> None:
        from linux.ai.quota_meter import countdown, subscription_text, parse_time
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        tray = payload.get("tray") if isinstance(payload.get("tray"), dict) else {}
        on = bool(tray.get("autostart"))
        running = bool(tray.get("running"))
        if on and running:
            self._set_label_state(self.quota_state, "● Medidores ligados na bandeja · iniciam com o login", "success")
        elif on:
            self._set_label_state(self.quota_state, "● Ligados no login, mas fora da bandeja agora", "warning")
        else:
            self._set_label_state(self.quota_state, "● Medidores desligados · os dados abaixo continuam disponíveis aqui", "info")
        # Enabled and visible -> offer off; enabled but closed -> reopen; off -> on.
        self._quota_toggle_id = "ai.quota.remove" if on and running else "ai.quota.install"
        self.quota_toggle.setText("Desligar medidores na bandeja" if on and running
                                  else "Abrir medidores na bandeja" if on else "Ligar medidores na bandeja")
        self.quota_toggle.setObjectName("secondaryButton" if on and running else "primaryButton")
        self.quota_toggle.style().unpolish(self.quota_toggle)
        self.quota_toggle.style().polish(self.quota_toggle)
        action = self.by_id.get(self._quota_toggle_id)
        self.quota_toggle.setToolTip(action.description if action else "")
        for widget in self._quota_rows:
            self.quota_grid.removeWidget(widget)
            widget.deleteLater()
        self._quota_rows = []
        meters = [item for item in payload.get("meters") or [] if isinstance(item, dict)]
        for index, item in enumerate(meters):
            dot = QLabel("●")
            dot.setStyleSheet(f"color: {item.get('color') or '#888'}; font-size: 16px;")
            dot.setAccessibleName(f"Cor da conta {item.get('label', '')}")
            name = QLabel(str(item.get("label", "")))
            name.setObjectName("settingValue")
            value = item.get("remaining")
            badge = QLabel(f"{value}%" if value is not None else "n/d")
            badge.setObjectName("badge")
            badge.setAlignment(Qt.AlignCenter)
            badge.setMinimumWidth(52)
            badge.setProperty("state", _LEVEL_STATES.get(item.get("level"), "info"))
            badge.setProperty("quotaLevel", item.get("level") or "")
            parts = ["Observação vencida · use Atualizar" if item.get("freshness") == "expired" else countdown(item.get("resetsAt"), now)]
            if item.get("seenAt"):
                parts.append(f"observado: {item['seenAt']}")
            if item.get("source"):
                parts.append(f"origem: {item['source']}")
            if item.get("error"):
                parts.append(str(item["error"]))
            sub = subscription_text(item)
            if sub:
                parts.append(sub)
            detail = QLabel(" · ".join(parts))
            detail.setWordWrap(True)
            tips = [f"{w['name']}: {str(w['remaining']) + '%' if w['remaining'] is not None else 'n/d'} · {countdown(w.get('resetsAt'), now)}"
                    for w in item.get("windows") or []]
            if item.get("error"):
                tips.append(str(item["error"]))
            for widget in (name, badge, detail):
                widget.setToolTip("\n".join(tips))
            for column, widget in enumerate((dot, name, badge, detail)):
                self.quota_grid.addWidget(widget, index, column)
                self._quota_rows.append(widget)
        if not meters:
            empty = QLabel("Nenhuma conta Codex, Claude ou Grok encontrada neste host.")
            self.quota_grid.addWidget(empty, 0, 0, 1, 4)
            self._quota_rows.append(empty)
        self.quota_toggle.setEnabled(not self._operation_running)
        self.quota_refresh.setEnabled(not self._operation_running)

    # ---- desktop apps -------------------------------------------------------

    def _build_desktop_apps_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        card.setProperty("cardRole", "desktopApps")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Apps desktop de IA",
            "Claude Desktop oficial · repositório assinado da Anthropic",
        ))
        self.desktop_state = QLabel("● Verificando…")
        self.desktop_state.setObjectName("chatgptWebState")
        self.desktop_state.setAccessibleName("Estado do Claude Desktop")
        self.desktop_state.setWordWrap(True)
        layout.addWidget(self.desktop_state)
        row = QHBoxLayout()
        row.setSpacing(10)
        self.desktop_install = self._action_button(
            "ai.desktop.claude", "Instalar Claude Desktop", primary=True, direct=True)
        self.desktop_update = self._action_button(
            "ai.desktop.claude.update", "Atualizar Claude Desktop", primary=True, direct=True)
        self.desktop_check = QPushButton("Verificar atualização")
        self.desktop_check.setObjectName("secondaryButton")
        self.desktop_check.setToolTip("Compara a versão instalada com o repositório assinado; não altera nada.")
        self.desktop_check.clicked.connect(self._check_claude_desktop)
        self.mark_represented(self.by_id[_CLAUDE_CHECK_ID]) if _CLAUDE_CHECK_ID in self.by_id else None
        self.desktop_auto = QPushButton("Ligar atualização automática")
        self.desktop_auto.setObjectName("secondaryButton")
        self.desktop_auto.setProperty("desktopRole", "autoUpdate")
        self.desktop_auto.clicked.connect(self._toggle_desktop_updates)
        for button in (self.desktop_install, self.desktop_update, self.desktop_check, self.desktop_auto):
            if button is not None:
                row.addWidget(button)
        row.addStretch()
        layout.addLayout(row)
        self._claude_installed: bool | None = None
        self._apply_desktop_buttons()
        return card

    def _toggle_desktop_updates(self) -> None:
        action = self.by_id.get("ai.desktop.updates.off" if self._updates_on else "ai.desktop.updates.on")
        if action is not None:
            self.action_requested.emit(action)

    def _check_claude_desktop(self) -> None:
        if not self.status_loader.running(_CLAUDE_CHECK_ID):
            self.desktop_check.setEnabled(False)
            self.desktop_state.setText("● Consultando repositório assinado…")
            self.status_loader.fetch(_CLAUDE_CHECK_ID, ["ai", "desktop", "check-claude"])

    def _apply_desktop_buttons(self) -> None:
        running = self._operation_running
        installed = self._claude_installed
        if self.desktop_install is not None:
            self.desktop_install.setVisible(installed is False)
            self.desktop_install.setEnabled(not running and installed is False)
        if self.desktop_update is not None:
            self.desktop_update.setVisible(installed is not False)
            self.desktop_update.setEnabled(not running and installed is True)
        self.desktop_check.setEnabled(not running and installed is True and not self.status_loader.running(_CLAUDE_CHECK_ID))
        self.desktop_auto.setEnabled(not running and installed is True and self._updates_on is not None)
        self.desktop_auto.setText("Desligar atualização automática" if self._updates_on
                                  else "Ligar atualização automática")
        action = self.by_id.get("ai.desktop.updates.off" if self._updates_on else "ai.desktop.updates.on")
        self.desktop_auto.setToolTip(action.description if action else "")

    def _on_desktop_status(self, payload: dict) -> None:
        claude = payload.get("claudeDesktop") if isinstance(payload.get("claudeDesktop"), dict) else {}
        installed = claude.get("installed") if isinstance(claude.get("installed"), bool) else None
        self._claude_installed = installed
        enabled = (payload.get("updater") or {}).get("timerEnabled")
        self._updates_on = enabled if isinstance(enabled, bool) else None
        if installed is None:
            self._set_label_state(self.desktop_state, "● Instalação desconhecida · use Atualizar para verificar", "warning")
        elif not installed:
            self._set_label_state(self.desktop_state, "● Claude Desktop não instalado", "info")
        elif claude.get("launcherManaged") is False:
            self._set_label_state(self.desktop_state,
                                  f"● Claude Desktop {claude.get('version')} · atalho de outro instalador; use Atualizar para reparar",
                                  "warning")
        else:
            self._set_label_state(self.desktop_state,
                                  f"● Claude Desktop {claude.get('version')} instalado · atualização automática "
                                  + ("ligada" if self._updates_on is True else "desligada" if self._updates_on is False else "desconhecida"),
                                  "success")
        self._apply_desktop_buttons()

    def _on_claude_check(self, payload: dict) -> None:
        latest, installed = payload.get("latest"), payload.get("installed")
        if payload.get("available"):
            text = f"● Nova versão {latest} disponível (instalada: {installed or 'nenhuma'})"
            if payload.get("running"):
                text += " · o app aberto segue na versão atual até reabrir"
            self._set_label_state(self.desktop_state, text, "warning")
        elif payload.get("available") is False and installed and latest:
            self._set_label_state(self.desktop_state, f"● Claude Desktop {installed} é a versão mais nova", "success")
        else:
            self._set_label_state(self.desktop_state, "● Versão mais nova desconhecida · tente Verificar atualização", "warning")
        self._apply_desktop_buttons()

    def _set_label_state(self, label: QLabel, text: str, state: str) -> None:
        label.setText(text)
        label.setProperty("state", state)
        label.style().unpolish(label)
        label.style().polish(label)

    def _build_bonsai_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.addWidget(SectionHeader("Bonsai", "Serviço externo · diagnóstico e login"))
        self.bonsai_state = QLabel("Estado ainda não observado")
        self.bonsai_state.setWordWrap(True)
        layout.addWidget(self.bonsai_state)
        actions = QHBoxLayout()
        actions.setSpacing(10)
        self.bonsai_login = self._action_button(
            "ai.claude-bonsai-login", "Login Bonsai", primary=True, direct=True
        )
        if self.bonsai_login:
            self.bonsai_login.setToolTip(
                "Verifica as condições atuais e tenta abrir login em terminal privado. "
                "A autenticação depende do Bonsai."
            )
            actions.addWidget(self.bonsai_login, 1)
        self.bonsai_diagnose = self._action_button(
            "ai.bonsai-diagnose", "Atualizar diagnóstico", primary=False, direct=True
        )
        if self.bonsai_diagnose:
            actions.addWidget(self.bonsai_diagnose, 1)
        layout.addLayout(actions)
        self.bonsai_reason = QLabel("Aguarde diagnóstico. Presença de credencial não comprova autenticação.")
        self.bonsai_reason.setWordWrap(True)
        layout.addWidget(self.bonsai_reason)
        self.bonsai_next = QLabel("Próximo passo: atualizar diagnóstico. Execução e proxy indisponíveis.")
        self.bonsai_next.setWordWrap(True)
        layout.addWidget(self.bonsai_next)
        self.bonsai_details = QLabel("")
        self.bonsai_details.setWordWrap(True)
        self.bonsai_details.setTextFormat(Qt.PlainText)
        self._technical_widgets.append(self.bonsai_details)
        layout.addWidget(self.bonsai_details)
        return card

    def _install_context_status(self) -> None:
        return

    def _build_hero(self) -> QFrame:
        hero = QFrame()
        hero.setObjectName("serviceHero")
        row = QHBoxLayout(hero)
        row.setContentsMargins(20, 18, 20, 18)
        row.setSpacing(16)
        icon = QLabel()
        icon.setObjectName("serviceIcon")
        icon.setPixmap(themed_icon(hero, "applications-development", QStyle.SP_ComputerIcon).pixmap(38, 38))
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(58, 58)
        row.addWidget(icon)
        copy = QVBoxLayout()
        copy.setSpacing(3)
        title = QLabel("IA & Dev")
        title.setObjectName("serviceTitle")
        self.state_label = QLabel("● Verificando…")
        self.state_label.setObjectName("serviceState")
        self.state_label.setProperty("state", "info")
        self.state_detail = QLabel("Lendo agentes, MCPs e ferramentas do host")
        self.state_detail.setObjectName("cardDescription")
        self.state_detail.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(self.state_label)
        copy.addWidget(self.state_detail)
        row.addLayout(copy, 1)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.setObjectName("secondaryButton")
        self.refresh_button.clicked.connect(self.reload)
        row.addWidget(self.refresh_button)
        self.repair_button = QPushButton("Reparar ambiente")
        self.repair_button.setObjectName("primaryButton")
        self.repair_button.setMinimumSize(170, 50)
        self.repair_button.clicked.connect(lambda: self.run_action("ai.repair"))
        row.addWidget(self.repair_button)
        return hero

    def _agent_card(
        self, title: str, description: str, cli_key: str,
        primary_id: str, primary_label: str,
        secondary_id: str, secondary_label: str,
    ) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(title, description))
        status = QLabel("Verificando…")
        status.setObjectName("settingValue")
        status.setWordWrap(True)
        layout.addWidget(status)
        buttons = QHBoxLayout()
        primary = self._action_button(primary_id, primary_label, primary=True)
        secondary = self._action_button(secondary_id, secondary_label, primary=False)
        if primary is not None:
            buttons.addWidget(primary)
        if secondary is not None:
            buttons.addWidget(secondary)
        buttons.addStretch()
        layout.addLayout(buttons)
        if cli_key in {"opencode", "claude"}:
            economy = QPushButton("Memória e eficiência")
            economy.setObjectName("secondaryButton")
            agent_id = "claude-code" if cli_key == "claude" else cli_key
            economy.setAccessibleName(f"Memória e eficiência de {title}")
            economy.clicked.connect(lambda _checked=False, agent=agent_id: self.focus_journey("economy:" + agent))
            layout.addWidget(economy)
        card.setProperty("cliKey", cli_key)
        self._bind_status_label(cli_key, status)
        return card

    def _tool_card(
        self, title: str, description: str, key: str,
        primary_id: str, primary_label: str,
        secondary_id: str, secondary_label: str,
    ) -> QFrame:
        return self._agent_card(
            title, description, key, primary_id, primary_label, secondary_id, secondary_label,
        )

    def _build_shortcuts(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.addWidget(SectionHeader("Atalhos", "Ferramentas do host sem abrir o catálogo"))
        row = QHBoxLayout()
        for aid, label in (
            ("ai.ides", "Configurar IDEs (agentes)"),
            ("ai.admin", "Ponte admin"),
            ("ai.doctor", "Diagnóstico MCP"),
            ("ai.opencode-verify", "Verificar OpenCode"),
        ):
            button = self._action_button(aid, label, primary=False)
            if button is not None:
                row.addWidget(button)
        row.addStretch()
        layout.addLayout(row)
        return card

    def _build_bridge_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("chatgptWebCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "ChatGPT Web no Codex (experimental)",
            "Modelo Web numa janela separada. O acesso às ferramentas depende do plano "
            "e da verificação no host; seu Codex normal não muda.",
        ))
        self.bridge_state = QLabel("Verificando…")
        self.bridge_state.setObjectName("chatgptWebState")
        self.bridge_state.setWordWrap(True)
        self.bridge_state.setAccessibleName("Estado do ChatGPT Web no Codex")
        layout.addWidget(self.bridge_state)
        self.bridge_tools = QLabel("")
        # Native styling is keyed on object names; the role is a separate property.
        self.bridge_tools.setObjectName("cardDescription")
        self.bridge_tools.setProperty("bridgeRole", "tools")
        self.bridge_tools.setWordWrap(True)
        layout.addWidget(self.bridge_tools)
        self.bridge_account = QLabel("")
        self.bridge_account.setObjectName("cardDescription")
        self.bridge_account.setProperty("bridgeRole", "account")
        self.bridge_account.setWordWrap(True)
        self.bridge_account.setAccessibleName("Permissão da conta ChatGPT para ferramentas")
        layout.addWidget(self.bridge_account)
        self.bridge_next = QLabel("")
        self.bridge_next.setObjectName("cardDescription")
        self.bridge_next.setProperty("bridgeRole", "next")
        self.bridge_next.setWordWrap(True)
        self.bridge_next.setAccessibleName("Próximo passo do ChatGPT Web")
        layout.addWidget(self.bridge_next)
        actions = QGridLayout()
        actions.setHorizontalSpacing(8)
        actions.setVerticalSpacing(8)
        for index, (name, label, command, mutable, impact) in enumerate(_BRIDGE_BUTTONS):
            action = ActionSpec(
                id="private.chatgpt-web." + "-".join(part for part in command
                                                     if not part.startswith("-")
                                                     and not part.isdigit()),
                category="IA & Dev",
                title=f"ChatGPT Web no Codex — {label}", description=impact or label,
                args=(*_BRIDGE_ARGS, *command), icon="applications-development",
                mutable=mutable, preview_args=(*_BRIDGE_ARGS, "status") if mutable else None,
                preview_kind_override="state" if mutable else "", impact=impact,
                visibility="advanced", timeout_s=600 if mutable else 0,
            )
            button = QPushButton(label)
            button.setObjectName("primaryButton" if name == "chatgptWebOpen"
                                 else "secondaryButton")
            button.setProperty("bridgeRole", name)
            button.setToolTip(impact or {
                "chatgptWebOpen": "Abre o Codex Desktop no perfil dedicado, em janela separada.",
                "chatgptWebTools": "Mostra os requisitos e limites reais das ferramentas.",
            }[name])
            button.clicked.connect(
                lambda _checked=False, spec=action: self.action_requested.emit(spec))
            self._bridge_buttons[name] = button
            actions.addWidget(button, index // 3, index % 3)
        actions.setColumnStretch(2, 1)
        layout.addLayout(actions)
        card.setVisible(_bridge_opted_in())
        self.bridge_card = card
        return card

    def _set_bridge_state(self, text: str, state: str) -> None:
        self.bridge_state.setText(text)
        self.bridge_state.setProperty("state", state)
        self.bridge_state.style().unpolish(self.bridge_state)
        self.bridge_state.style().polish(self.bridge_state)

    def _apply_bridge_buttons(self) -> None:
        running = self._operation_running
        for name, button in self._bridge_buttons.items():
            button.setEnabled(not running and (name != "chatgptWebOpen" or self._bridge_ready))

    def _on_bridge_status(self, payload: dict) -> None:
        def node(key: str) -> dict:
            value = payload.get(key)
            return value if isinstance(value, dict) else {}

        stage = str(payload.get("stage") or "")
        label = _BRIDGE_STAGES.get(stage, stage or "estado desconhecido")
        running = bool(node("launcher").get("active") and node("route").get("active")
                       and payload.get("daemonListening"))
        self._bridge_ready = running
        self._bridge_buttons["chatgptWebSetup"].setText(
            "Reparar" if running else "Preparar ou reparar")
        login = {"enabled": "inicia com o login", "off": "início no login desligado",
                 "inconsistent": "início no login inconsistente"}.get(
                     str(node("autostart").get("state")), "")
        if payload.get("liveCodexRouteTouched"):
            self._set_bridge_state(
                "● Atenção: o ~/.codex do seu Codex normal aponta para um bridge local. "
                "A ponte nunca faz isso; confira a configuração.", "error")
        elif running and payload.get("upstreamMode") == "full":
            self._set_bridge_state("● Web ativo — ferramentas em verificação"
                                   + (f"; {login}" if login else ""), "warning")
        elif running:
            self._set_bridge_state(f"● Pronto — {label}" + (f"; {login}" if login else ""),
                                   "success")
        elif payload.get("signedIn") is False:
            self._set_bridge_state(
                "● Falta o login no ChatGPT. Use Ligar ou reparar e entre na janela do "
                "launcher.", "warning")
        else:
            self._set_bridge_state(f"● Parado — {label}. Use Ligar ou reparar.", "warning")
        blockers = node("eligibility").get("blockers")
        pending = node("toolsGate").get("next")
        if not isinstance(pending, dict):
            pending = {}
        gate_detail = str(pending.get("detail") or "")
        gate_action = str(pending.get("action") or "")
        gate_id = str(pending.get("id") or "")
        capability = str(node("eligibility").get("planMcpCapability") or "")
        if capability == "write-unverified":
            self.bridge_account.setText(
                "Conta Pro: plugins MCP podem expor escrita. Permissão desta conta "
                "e chamada real ainda não verificadas.")
        elif capability == "write-beta":
            self.bridge_account.setText(
                "Plano compatível com MCP completo (beta). Ferramentas exigem teste real.")
        else:
            self.bridge_account.setText("Permissão da conta ainda não confirmada.")
        if gate_id == "plan-full":
            self.bridge_next.setText(
                "Confira permissões do plugin MCP nesta conta e faça teste real "
                "antes de ativar ferramentas.")
        else:
            self.bridge_next.setText(f"Próximo passo: {gate_action}" if gate_action else "")
        self.bridge_next.setVisible(bool(gate_action))
        if payload.get("upstreamMode") == "full":
            if isinstance(blockers, list) and blockers:
                self.bridge_tools.setText(f"Com ferramentas: configuração bloqueada — "
                                          f"{blockers[0]}.")
            elif gate_detail:
                self.bridge_tools.setText(f"Com ferramentas: bloqueado — {gate_detail}.")
            else:
                self.bridge_tools.setText("Com ferramentas: ativo — o conector lê o workspace "
                                          "da tarefa; escrita local recusada (sandbox somente "
                                          "leitura). Abrir já usa este modo.")
        elif isinstance(blockers, list) and blockers:
            self.bridge_tools.setText(f"Com ferramentas: bloqueado — {blockers[0]}.")
        elif gate_id == "plan-full":
            self.bridge_tools.setText("Acesso completo ao host: permissão MCP não comprovada.")
        elif gate_detail:
            self.bridge_tools.setText(f"Com ferramentas: bloqueado — {gate_detail}.")
        else:
            self.bridge_tools.setText("Com ferramentas: ainda não configurado. Veja Com "
                                      "ferramentas… para o próximo passo.")
        self._apply_bridge_buttons()

    def _build_advanced_connections(self) -> QFrame:
        card = QFrame()
        card.setObjectName("aiAdvancedConnections")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Conexões avançadas",
            "Proxies, rotas e políticas. Contas e permissões ficam em Contas e conexões.",
        ))
        row = QHBoxLayout()
        for category, label, object_name in (
            ("Proxies IA", "Proxies e provedores", "openAiProxiesPage"),
            ("Roteamento IA", "Rotas e políticas", "openAiRoutingPage"),
        ):
            button = QPushButton(label)
            button.setObjectName(object_name)
            button.setAccessibleName(f"Abrir {label}")
            button.setToolTip("Abrir ferramentas técnicas de IA; contas continuam independentes.")
            button.clicked.connect(
                lambda _checked=False, target=category: self.request_category(target)
            )
            row.addWidget(button)
        row.addStretch()
        layout.addLayout(row)
        return card

    def _bind_status_label(self, key: str, label: QLabel) -> None:
        if not hasattr(self, "_status_labels"):
            self._status_labels: dict[str, QLabel] = {}
        self._status_labels[key] = label

    def _action_button(self, action_id: str, label: str, *, primary: bool, direct: bool = False) -> QPushButton | None:
        action = self.by_id.get(action_id)
        if action is None:
            return None
        self.mark_represented(action)
        button = QPushButton(label)
        button.setObjectName("primaryButton" if primary else "secondaryButton")
        button.setToolTip(action.description)
        if direct:
            # The Bonsai card owns these operations; app-catalog shortcuts
            # would navigate away instead of running their explicit action.
            button.clicked.connect(lambda _checked=False, a=action: self.action_requested.emit(a))
        else:
            button.clicked.connect(lambda _checked=False, a=action: self.request_action(a))
        return button

    def reload(self) -> None:
        action = self.by_id.get("ai.status")
        if action is None or self.status_loader.running(action.id):
            return
        self.refresh_button.setEnabled(False)
        self.state_label.setText("● Verificando…")
        self._set_state("info")
        self.status_loader.fetch_action(action)
        self.status_loader.fetch("private.bonsai.status", ["ai", "claude", "bonsai-status"])
        self._fetch_quota()
        self._fetch_harness()
        self.memory_card.fetch()
        self.economy_card.fetch()
        if not self.status_loader.running(_DESKTOP_STATUS_ID):
            self.status_loader.fetch(_DESKTOP_STATUS_ID, ["ai", "desktop", "status"])
        self.bridge_card.setVisible(_bridge_opted_in())
        if not self.bridge_card.isHidden() and not self.status_loader.running(_BRIDGE_STATUS_ID):
            self.status_loader.fetch(_BRIDGE_STATUS_ID, [*_BRIDGE_ARGS, "--json", "status"])

    def _set_state(self, state: str) -> None:
        self.state_label.setProperty("state", state)
        self.state_label.style().unpolish(self.state_label)
        self.state_label.style().polish(self.state_label)

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        self.overview.update_status(action_id, parsed)
        if action_id == ECONOMY_STATUS_ID:
            self.economy_card.update_status(parsed) if isinstance(parsed, dict) else self.economy_card.failed()
            return
        if action_id == MEMORY_STATUS_ID:
            if isinstance(parsed, dict):
                self.memory_card.update_status(parsed)
            else:
                self.memory_card.failed()
            return
        if action_id == _HARNESS_STATUS_ID and isinstance(parsed, dict):
            self._on_harness_status(parsed)
            return
        if action_id == _QUOTA_STATUS_ID and isinstance(parsed, dict):
            self._on_quota_status(parsed)
            return
        if action_id == _DESKTOP_STATUS_ID and isinstance(parsed, dict):
            self._on_desktop_status(parsed)
            return
        if action_id == _CLAUDE_CHECK_ID and isinstance(parsed, dict):
            self._on_claude_check(parsed)
            return
        if action_id == "private.bonsai.status" and isinstance(parsed, dict):
            provider = parsed.get("authProvider")
            if not isinstance(provider, dict):
                provider = {}
            previously_disabled = provider.get("class") == "upstream-auth-disabled"
            disabled = previously_disabled and provider.get("fresh") is True
            historical_disabled = previously_disabled and not disabled
            unknown = provider.get("currentAvailability", "unknown") == "unknown" and not previously_disabled
            attempt_ready = parsed.get("loginAttemptAvailable") is True
            terminal_ready = parsed.get("loginTerminalAvailable") is True
            compatibility = parsed.get("loginCompatibility") == "registry-404-pinned-cli"
            if disabled:
                label = "Autenticação desativada pelo Bonsai"
            elif historical_disabled:
                label = "Última falha: autenticação desativada; estado atual desconhecido"
            elif terminal_ready:
                label = "Tentativa local pronta (npm HTTP 404)" if compatibility else "Tentativa local pronta; autenticação não confirmada"
            elif attempt_ready:
                label = "Tentativa possível; terminal gráfico indisponível"
            elif unknown:
                label = "Autenticação não verificada"
            else:
                label = "Bonsai sem pré-verificação concluída"
            self.bonsai_state.setText(label)
            credential = parsed.get("credentialStatus")
            if not isinstance(credential, dict):
                credential = {}
            expired = str(credential.get("state", "")).startswith("expired")
            reason = "Credencial vencida; renovação necessária." if expired else "Autenticação ainda não comprovada."
            if disabled:
                reason += " O Bonsai desativou a autenticação desta aplicação; PhaseZero não pode reativá-la."
            elif historical_disabled:
                reason += " Observação anterior apontou autenticação desativada; não comprova disponibilidade atual."
            elif unknown:
                reason += " Observação anterior não comprova disponibilidade atual."
            update = parsed.get("updateObservation")
            if not isinstance(update, dict):
                update = {}
            if update.get("state") == "not-probed-or-stale":
                reason += " Atualização ainda não verificada; atualize diagnóstico."
            elif update.get("available") is False or update.get("state") == "registry-http-error":
                http = f" (HTTP {update['httpStatus']})" if update.get("httpStatus") else ""
                reason += f" Atualização indisponível{http}."
            if update.get("failureClass") == "package-unavailable":
                reason += " npm responde; pacote Bonsai não está acessível."
            if compatibility:
                reason += " PhaseZero contorna só a checagem de versão da CLI 0.4.19 instalada; autenticação depende do Bonsai."
            self.bonsai_reason.setText(reason)
            if disabled:
                next_step = (
                    "Próximo passo: contate o suporte oficial Bonsai para reativar a autenticação. "
                    "Login Bonsai permanece disponível para nova tentativa; credenciais preservadas."
                )
            elif terminal_ready:
                next_step = (
                    "Próximo passo: Login Bonsai abre terminal privado. Se o navegador mostrar "
                    "'Authentication is disabled for this application', o bloqueio é do Bonsai; "
                    "contate o suporte oficial. O HTTP 404 do npm não comprova autenticação."
                )
            else:
                next_step = (
                    "Próximo passo: Login Bonsai verifica novamente as condições antes de abrir "
                    "o terminal privado. Atualizar diagnóstico consulta npm, não testa autenticação. "
                    "Se o site disser que a autenticação está desativada, contate o suporte Bonsai."
                )
            self.bonsai_next.setText(next_step)
            self.bonsai_details.setText(json.dumps({"route": "bonsai/direct", **parsed}, ensure_ascii=False, indent=2))
            return
        if action_id == _BRIDGE_STATUS_ID and isinstance(parsed, dict):
            self._on_bridge_status(parsed)
            return
        if action_id != "ai.status" or not isinstance(parsed, dict):
            return
        self.refresh_button.setEnabled(not self._operation_running)
        self._payload = parsed
        mode = str(parsed.get("mode") or "degraded")
        recs = parsed.get("recommendations") if isinstance(parsed.get("recommendations"), list) else []
        setup_catalog = parsed.get("setupCatalog") if isinstance(parsed.get("setupCatalog"), dict) else {}
        essentials = setup_catalog.get("essentials") if isinstance(setup_catalog.get("essentials"), list) else []
        essential_missing = [
            entry for entry in essentials
            if isinstance(entry, dict) and entry.get("state") != "ready"
        ]
        opencode = _cli_available(parsed, "opencode")
        claude = _cli_available(parsed, "claude")
        labels = getattr(self, "_status_labels", {})
        if "opencode" in labels:
            labels["opencode"].setText("Instalado e visível no PATH" if opencode else "Ainda não configurado neste host")
        if "claude" in labels:
            labels["claude"].setText("Instalado e visível no PATH" if claude else "Ainda não configurado neste host")
        mcp = parsed.get("mcp") if isinstance(parsed.get("mcp"), dict) else {}
        if "mcp" in labels:
            labels["mcp"].setText(
                "Há MCPs para reparar" if mcp.get("problems") else
                "Diagnóstico local sem pendências" if "problems" in mcp else
                "Destinos listados; conexão ainda não verificada"
            )
        compat = parsed.get("agentCompat") if isinstance(parsed.get("agentCompat"), dict) else {}
        compat_mode = str(compat.get("mode") or mode)
        if "compat" in labels:
            labels["compat"].setText(
                "RTK, Caveman e memória alinhados" if compat_mode == "ready"
                else "Ambiente de agentes incompleto"
            )
        if essentials and not essential_missing:
            self.state_label.setText("● Pronto")
            self.state_detail.setText("Base essencial pronta. Hermes, Odysseus e outros extras são opcionais.")
            self._set_state("success")
        elif essential_missing:
            self.state_label.setText("● Falta configurar")
            labels_missing = ", ".join(str(item.get("label")) for item in essential_missing[:3])
            self.state_detail.setText(f"Essenciais pendentes: {labels_missing}. Use Reparar ambiente.")
            self._set_state("warning")
        elif mode == "ready" and not recs:
            self.state_label.setText("● Pronto")
            self.state_detail.setText("Agentes, memória e ponte admin estão no lugar.")
            self._set_state("success")
        elif recs:
            self.state_label.setText("● Falta configurar")
            first = str(recs[0])
            self.state_detail.setText(f"Próximo passo: {first}" if self._advanced_mode else "Há itens para configurar. Use Reparar ambiente.")
            self._set_state("warning")
        else:
            self.state_label.setText("● Parcial")
            self.state_detail.setText("Parte da stack está pronta. Abra um card para continuar.")
            self._set_state("info")

    def _on_status_failed(self, action_id: str, message: str) -> None:
        self.overview.update_status(action_id, None)
        if action_id == ECONOMY_STATUS_ID:
            self.economy_card.failed()
            return
        if action_id == MEMORY_STATUS_ID:
            self.memory_card.failed()
            return
        if action_id == _HARNESS_STATUS_ID:
            self._harness_payload = None
            self._set_label_state(self.harness_state, "● Estado Harness indisponível. Use Atualizar estado.", "warning")
            self._apply_harness_buttons()
            return
        if action_id == _QUOTA_STATUS_ID:
            self._set_label_state(self.quota_state, "● Não foi possível ler as franquias. Use Atualizar.", "warning")
            self.quota_refresh.setEnabled(not self._operation_running)
            return
        if action_id in (_DESKTOP_STATUS_ID, _CLAUDE_CHECK_ID):
            self._set_label_state(self.desktop_state, "● Não foi possível consultar o Claude Desktop. Tente de novo.", "warning")
            self._apply_desktop_buttons()
            return
        if action_id == "private.bonsai.status":
            self.bonsai_state.setText("Estado Bonsai indisponível")
            self.bonsai_next.setText(
                "Próximo passo: tente Login Bonsai para verificar as condições atuais ou "
                "atualize o diagnóstico. A autenticação depende do provedor."
            )
            return
        if action_id == _BRIDGE_STATUS_ID:
            self._set_bridge_state("● Não foi possível ler o estado. Use Atualizar.", "warning")
            self.bridge_tools.setText("Estado das ferramentas indisponível.")
            self.bridge_account.setText("")
            self.bridge_next.setText("")
            self.bridge_next.hide()
            return
        if action_id != "ai.status":
            return
        self.refresh_button.setEnabled(not self._operation_running)
        self.state_label.setText("● Estado indisponível")
        self.state_detail.setText("Não foi possível ler o host. Tente atualizar.")
        self._set_state("error")
        for label in getattr(self, "_status_labels", {}).values():
            # Falha de leitura não deve despejar rc cru no card; causa curta só
            # no modo avançado.
            if self._advanced_mode and message and not message.startswith("exit code"):
                label.setText(f"Leitura falhou ({message[:80]})")
            else:
                label.setText("Indisponível — tente atualizar")

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for widget in self._technical_widgets:
            widget.setVisible(enabled)

    def block_while_running(self, running: bool) -> None:
        self._operation_running = running
        self.memory_card.apply_buttons()
        self.economy_card.render()
        self._apply_harness_buttons()
        self.refresh_button.setEnabled(not running)
        self.repair_button.setEnabled(not running)
        self._apply_bridge_buttons()
        self.quota_toggle.setEnabled(not running)
        self.quota_refresh.setEnabled(not running)
        self._apply_desktop_buttons()
        if not running and self.isVisible():
            self.reload()
