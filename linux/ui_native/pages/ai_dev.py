from __future__ import annotations

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

    def _set_state(self, state: str) -> None:
        self.state_label.setProperty("state", state)
        self.state_label.style().unpolish(self.state_label)
        self.state_label.style().polish(self.state_label)

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
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
        if not running and self.isVisible():
            self.reload()
