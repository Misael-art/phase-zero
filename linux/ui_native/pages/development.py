from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QComboBox, QFormLayout, QFrame, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QVBoxLayout, QWidget,
)

from ..a11y_events import announce_accessible
from ..command_runner import CommandRunner
from ..models import ActionSpec, OperationResult
from ..widgets import SectionHeader
from .base import BasePage


_OBJECTIVES = (
    ("Web JavaScript / TypeScript", "development-web-js", "app.nodejs",
     "Node.js e pnpm. Não inclui IA local, Docker ou acesso remoto."),
    ("Python e dados", "development-python", "app.pyenv",
     "Instala pyenv para versões isoladas; não altera o Python do sistema."),
    ("Rust", "development-rust", "app.rust",
     "Instala Rust e Cargo pelo gerenciador de pacotes do sistema."),
    ("C/C++", "development-c-cpp", "app.cpp",
     "Instala o compilador GCC para C e C++ pelo gerenciador do sistema."),
    ("Java e JVM", "development-java", "app.maven",
     "Instala Maven e seu requisito OpenJDK. Não altera configuração de projetos existentes."),
    (".NET", "development-dotnet", "app.dotnet",
     "Instala o SDK .NET pelo gerenciador de pacotes do sistema."),
)
_EDITORS = (
    ("Escolher depois", ""),
    ("Visual Studio Code", "development.vscode"),
    ("VSCodium", "development.vscodium"),
)


class DevelopmentPage(BasePage):
    """Public objective-to-plan path backed by the capabilities recipe ledger."""

    product_requested = Signal(str, str)

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.objective: QComboBox | None = None
        self.editor: QComboBox | None = None
        self.description: QLabel | None = None
        self.status: QLabel | None = None
        self.prepare_button: QPushButton | None = None

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        inner = QWidget()
        layout = QVBoxLayout(inner)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(12)
        layout.addWidget(SectionHeader(
            "Preparar desenvolvimento",
            "Escolha um objetivo, revise o plano e valide antes de abrir as ferramentas.",
        ))

        form = QFormLayout()
        self.objective = QComboBox()
        self.objective.setObjectName("developmentObjective")
        self.objective.setAccessibleName("Objetivo de desenvolvimento")
        self.objective.setAccessibleDescription("Escolha a receita inicial para este projeto.")
        for title, profile_id, app_id, description in _OBJECTIVES:
            self.objective.addItem(title, profile_id)
        self.objective.currentIndexChanged.connect(self._update_objective)
        form.addRow("Objetivo:", self.objective)

        self.editor = QComboBox()
        self.editor.setObjectName("developmentEditor")
        self.editor.setAccessibleName("Editor opcional")
        self.editor.setAccessibleDescription("Escolha Visual Studio Code, VSCodium ou decida depois.")
        for title, capability_id in _EDITORS:
            self.editor.addItem(title, capability_id)
        form.addRow("Editor (opcional):", self.editor)
        layout.addLayout(form)

        self.description = QLabel("")
        self.description.setObjectName("developmentRecipeDescription")
        self.description.setWordWrap(True)
        layout.addWidget(self.description)

        row = QHBoxLayout()
        self.prepare_button = QPushButton("Revisar plano e preparar")
        self.prepare_button.setObjectName("prepareDevelopment")
        self.prepare_button.setAccessibleName("Revisar plano e preparar")
        self.prepare_button.setAccessibleDescription("Exibe custos e mudanças antes de preparar o ambiente.")
        self.prepare_button.setMinimumHeight(42)
        self.prepare_button.clicked.connect(self._prepare)
        row.addWidget(self.prepare_button)
        self.validate_button = QPushButton("Validar ambiente")
        self.validate_button.setObjectName("validateDevelopment")
        self.validate_button.setAccessibleName("Validar ambiente")
        self.validate_button.setAccessibleDescription("Consulta o estado das ferramentas selecionadas.")
        self.validate_button.clicked.connect(self._validate)
        row.addWidget(self.validate_button)
        self.open_button = QPushButton("Abrir ferramenta")
        self.open_button.setObjectName("openDevelopmentTool")
        self.open_button.setAccessibleName("Abrir ferramenta")
        self.open_button.setAccessibleDescription("Abre o detalhe canônico da ferramenta escolhida.")
        self.open_button.clicked.connect(self._open_tool)
        row.addWidget(self.open_button)
        layout.addLayout(row)

        QWidget.setTabOrder(self.objective, self.editor)
        QWidget.setTabOrder(self.editor, self.prepare_button)
        QWidget.setTabOrder(self.prepare_button, self.validate_button)
        QWidget.setTabOrder(self.validate_button, self.open_button)

        self.status = QLabel("Nenhum ambiente validado nesta sessão.")
        self.status.setObjectName("developmentStatus")
        self.status.setAccessibleName("Status do ambiente de desenvolvimento")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        layout.addStretch()
        scroll.setWidget(inner)
        self._layout.addWidget(scroll, 1)
        self._update_objective(0)

    def _objective(self) -> tuple[str, str, str, str]:
        assert self.objective is not None
        return _OBJECTIVES[self.objective.currentIndex()]

    def _update_objective(self, _index: int) -> None:
        if self.description is not None:
            self.description.setText(self._objective()[3])
        if self.status is not None:
            self.status.setText("Selecione Revisar plano e preparar para continuar.")

    def _prepare(self) -> None:
        profile_id = self._objective()[1]
        action = self.by_id.get(f"capability.profile.{profile_id}")
        if action is None:
            if self.status is not None:
                self._set_status("Receita indisponível. Atualize o catálogo e tente novamente.")
            return
        editor_id = self.editor.currentData() if self.editor is not None else ""
        if editor_id:
            editor = self.by_id.get(f"capability.plan.{editor_id}")
            if editor is None or action.preview_args is None:
                return
            action = replace(
                action,
                id=f"development.recipe.{profile_id}.{editor_id}",
                title=f"Preparar ambiente com {editor.title}",
                description=f"Receita {profile_id} e editor opcional {editor.title}.",
                preview_args=(*action.preview_args, "--capability", editor_id),
            )
        self.status.setText("O plano será exibido antes de qualquer alteração.")
        self.request_action(action)

    def _validate(self) -> None:
        action = self.by_id.get("capability.status")
        if action is not None:
            self._set_status("Validação iniciada.")
            self.request_action(action)

    def _set_status(self, message: str) -> None:
        if self.status is None:
            return
        self.status.setText(message)
        announce_accessible(self.status, message)

    def _open_tool(self) -> None:
        _title, profile_id, default_app_id, _description = self._objective()
        editor_id = self.editor.currentData() if self.editor is not None else ""
        app_id = f"app.{editor_id.rsplit('.', 1)[-1]}" if editor_id else default_app_id
        self.product_requested.emit(app_id, f"capability.profile.{profile_id}")

    def on_operation_result(self, action: ActionSpec | None, result: OperationResult) -> None:
        if self.status is None or action is None or result.preview:
            return
        if action.id.startswith(("capability.profile.development-", "development.recipe.")):
            cancelled = bool(
                isinstance(result.parsed, dict) and result.parsed.get("status") == "cancelled"
            )
            if cancelled:
                self._set_status(
                    "Preparação pausada entre etapas. O que terminou foi preservado; "
                    "gere novo preview para retomar."
                )
            else:
                self._set_status(
                    "Preparação concluída. Valide o ambiente para conferir cada ferramenta."
                    if result.ok else
                    "Preparação interrompida ou incompleta. Revise o erro; você pode gerar novo plano e tentar novamente."
                )
        elif action.id == "capability.status":
            self._set_status(
                "Validação consultada. Confira estados desconhecidos e ferramentas ausentes no resultado."
                if result.ok else
                "A validação falhou. O estado permanece desconhecido; tente novamente."
            )

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
