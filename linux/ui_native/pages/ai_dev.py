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
_BRIDGE_STATUS_ID = "private.chatgpt-web.status"
_BRIDGE_ARGS = ("ai", "chatgpt-web")
_PROJECT_MCP_STATUS_ID = "private.chatgpt-project-mcp.status"
_PROJECT_MCP_ARGS = ("ai", "chatgpt-project-mcp")
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
    ("chatgptWebSmoke", "Testar modelo (1 mensagem)", ("smoke",), True,
     "Envia um turno real pelo bridge. Gasta uma mensagem da sua conta ChatGPT."),
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


def _project_mcp_installed() -> bool:
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    return (data / "phasezero/chatgpt-project-mcp/config.json").is_file()


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
        self._payload: dict = {}
        self._technical_widgets: list[QWidget] = []
        self._bridge_buttons: dict[str, QPushButton] = {}
        self._bridge_ready = False
        self._project_mcp_buttons: list[QPushButton] = []
        self._project_mcp_active: bool | None = None
        self._project_mcp_integrity = False

    def build(self) -> None:
        for action_id in _PRIMARY_IDS | _REPRESENTED_ELSEWHERE:
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
            "Claude Code com rota Bonsai isolada",
            "claude",
            "ai.claude-install",
            "Reparar",
            "ai.claude-bonsai-login",
            "Login Bonsai",
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
            "RTK, Caveman, memória e ponte admin",
            "compat",
            "ai.compat",
            "Configurar",
            "ai.memory",
            "Memória",
        ), 1, 1)
        cards.setColumnStretch(0, 1)
        cards.setColumnStretch(1, 1)
        layout.addLayout(cards)
        layout.addWidget(self._build_bridge_card())
        layout.addWidget(self._build_project_mcp_card())
        layout.addWidget(self._build_advanced_connections())
        layout.addWidget(self._build_shortcuts())
        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll, 1)
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

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
                id=f"private.chatgpt-web.{command[0]}", category="IA & Dev",
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

    def _build_project_mcp_card(self) -> QFrame:
        card = QFrame()
        card.setObjectName("chatgptProjectMcpCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)
        layout.addWidget(SectionHeader(
            "Ferramentas do projeto no ChatGPT (experimental)",
            "Conector privado para um repositório Git. Leia e altere arquivos com confirmação "
            "na conta; não oferece comandos livres nem acesso ao restante do host.",
        ))
        self.project_mcp_state = QLabel("Verificando túnel…")
        self.project_mcp_state.setObjectName("chatgptProjectMcpState")
        self.project_mcp_state.setWordWrap(True)
        layout.addWidget(self.project_mcp_state)
        self.project_mcp_detail = QLabel("")
        self.project_mcp_detail.setObjectName("cardDescription")
        self.project_mcp_detail.setWordWrap(True)
        layout.addWidget(self.project_mcp_detail)
        row = QHBoxLayout()
        for label, command, mutable, impact in (
            ("Ver estado", "status", False, ""),
            ("Ligar túnel", "start", True, "Inicia o túnel privado nesta sessão."),
            ("Desligar túnel", "stop", True, "Encerra o túnel e apaga a chave temporária."),
        ):
            action = ActionSpec(
                id=f"private.chatgpt-project-mcp.{command}", category="IA & Dev",
                title=f"Ferramentas do projeto — {label}", description=impact or label,
                args=(*_PROJECT_MCP_ARGS, command), icon="applications-development",
                mutable=mutable, preview_args=(*_PROJECT_MCP_ARGS, "status") if mutable else None,
                preview_kind_override="state" if mutable else "", impact=impact,
                visibility="advanced", timeout_s=120 if mutable else 0,
            )
            button = QPushButton(label)
            button.setObjectName("secondaryButton")
            button.setProperty("projectMcpRole", command)
            button.clicked.connect(
                lambda _checked=False, spec=action: self.action_requested.emit(spec))
            self._project_mcp_buttons.append(button)
            row.addWidget(button)
        row.addStretch()
        layout.addLayout(row)
        self._apply_project_mcp_buttons()
        card.setVisible(_project_mcp_installed())
        self.project_mcp_card = card
        return card

    def _on_project_mcp_status(self, payload: dict) -> None:
        integrity = payload.get("integrity") is True
        active = payload.get("active") is True
        ready = payload.get("tunnelReady") is True
        proven = payload.get("toolCallProven") is True
        if not integrity:
            label, state = "● Arquivos do conector alterados — reinstale antes de ligar", "error"
        elif not active:
            label, state = "● Túnel desligado", "warning"
        elif not ready:
            label, state = "● Túnel iniciado, conexão ainda indisponível", "warning"
        elif not proven:
            label, state = "● Túnel conectado; uso pela conta ainda não comprovado", "warning"
        else:
            label, state = "● Leitura e escrita comprovadas nesta sessão", "success"
        self.project_mcp_state.setText(label)
        self.project_mcp_state.setProperty("state", state)
        self.project_mcp_state.style().unpolish(self.project_mcp_state)
        self.project_mcp_state.style().polish(self.project_mcp_state)
        repo = str(payload.get("repo") or "")
        self.project_mcp_detail.setText(
            (f"Projeto: {repo}. " if repo else "")
            + "No ChatGPT, selecione o plugin privado e confirme uma leitura e uma escrita "
              "reversível antes de considerar as ferramentas prontas."
        )
        self._project_mcp_active = active
        self._project_mcp_integrity = integrity
        self._apply_project_mcp_buttons()

    def _apply_project_mcp_buttons(self, running: bool = False) -> None:
        for button in self._project_mcp_buttons:
            role = button.property("projectMcpRole")
            button.setEnabled(not running and (
                role == "status" or
                (role == "start" and self._project_mcp_active is False
                 and self._project_mcp_integrity) or
                (role == "stop" and self._project_mcp_active is True)))

    def _apply_bridge_buttons(self, running: bool = False) -> None:
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
                self.bridge_tools.setText("Com ferramentas: configurado, mas chamada MCP "
                                          "real ainda não verificada. Cada ação local exige "
                                          "permissão do seu plano e aprovação.")
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

    def _action_button(self, action_id: str, label: str, *, primary: bool) -> QPushButton | None:
        action = self.by_id.get(action_id)
        if action is None:
            return None
        self.mark_represented(action)
        button = QPushButton(label)
        button.setObjectName("primaryButton" if primary else "secondaryButton")
        button.setToolTip(action.description)
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
        self.bridge_card.setVisible(_bridge_opted_in())
        if not self.bridge_card.isHidden() and not self.status_loader.running(_BRIDGE_STATUS_ID):
            self.status_loader.fetch(_BRIDGE_STATUS_ID, [*_BRIDGE_ARGS, "--json", "status"])
        self.project_mcp_card.setVisible(_project_mcp_installed())
        if not self.project_mcp_card.isHidden() and not self.status_loader.running(_PROJECT_MCP_STATUS_ID):
            self.status_loader.fetch(_PROJECT_MCP_STATUS_ID, [*_PROJECT_MCP_ARGS, "status"])

    def _set_state(self, state: str) -> None:
        self.state_label.setProperty("state", state)
        self.state_label.style().unpolish(self.state_label)
        self.state_label.style().polish(self.state_label)

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id == _BRIDGE_STATUS_ID and isinstance(parsed, dict):
            self._on_bridge_status(parsed)
            return
        if action_id == _PROJECT_MCP_STATUS_ID and isinstance(parsed, dict):
            self._on_project_mcp_status(parsed)
            return
        if action_id != "ai.status" or not isinstance(parsed, dict):
            return
        self.refresh_button.setEnabled(True)
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
        mcp_ok = not bool(mcp.get("problems")) if "problems" in mcp else True
        if "mcp" in labels:
            labels["mcp"].setText("Integrações seguras ok" if mcp_ok else "Há MCPs para reparar")
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
        if action_id == _BRIDGE_STATUS_ID:
            self._set_bridge_state("● Não foi possível ler o estado. Use Atualizar.", "warning")
            self.bridge_tools.setText("Estado das ferramentas indisponível.")
            self.bridge_account.setText("")
            self.bridge_next.setText("")
            self.bridge_next.hide()
            return
        if action_id == _PROJECT_MCP_STATUS_ID:
            self.project_mcp_state.setText("● Estado indisponível — use Ver estado")
            self.project_mcp_state.setProperty("state", "warning")
            self.project_mcp_detail.setText("")
            self._project_mcp_active = None
            self._apply_project_mcp_buttons()
            return
        if action_id != "ai.status":
            return
        self.refresh_button.setEnabled(True)
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
        self.refresh_button.setEnabled(not running)
        self.repair_button.setEnabled(not running)
        self._apply_bridge_buttons(running)
        self._apply_project_mcp_buttons(running)
        if not running and self.isVisible():
            self.reload()
