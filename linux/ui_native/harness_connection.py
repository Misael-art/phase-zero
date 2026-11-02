"""Guided Harness connection; credentials are stored by the backend owner."""
from pathlib import Path
import os

from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout,
    QHBoxLayout, QLabel, QLineEdit, QPushButton, QScrollArea, QFrame, QToolButton, QVBoxLayout, QWidget,
)
from PySide6.QtCore import Qt
from linux.ai.credential_vault import CredentialVault, credential_vault_path
from .widgets import fit_to_screen


def recommended_workspace(root: Path, saved: str = "") -> Path | None:
    candidates = [saved, os.environ.get("PZ_WORKSPACE_ROOT", "")]
    cwd = Path.cwd()
    candidates.extend(str(p) for p in (cwd, *cwd.parents) if (p / ".git").exists())
    candidates += [str(root) if (root / ".git").exists() else "", str(Path.home() / "Projects/PhaseZero")]
    for value in candidates:
        if value:
            path = Path(value).expanduser()
            if path.is_dir() and path != Path.home() and path != Path(path.anchor):
                return path.resolve()
    return None


class HarnessConnectionDialog(QDialog):
    def __init__(self, root: Path, parent=None, *, saved_workspace="", vault=None):
        super().__init__(parent)
        self.setObjectName("harnessConnection")
        self.setWindowTitle("Conectar DeepSeek Harness")
        fit_to_screen(self, 580, 570)
        layout = QVBoxLayout(self)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setFrameShape(QFrame.NoFrame)
        body = QWidget(); body_layout = QVBoxLayout(body)
        body_layout.setAlignment(Qt.AlignTop)
        body_layout.setSpacing(14)
        layout.addWidget(scroll, 1); scroll.setWidget(body)
        intro = QLabel("Escolha projeto e forma de acesso. Login acontece no site oficial DeepSeek; chave API fica na carteira segura do PhaseZero.")
        intro.setWordWrap(True)
        body_layout.addWidget(intro)
        form = QFormLayout()
        self.workspace = QLineEdit()
        self.workspace.setAccessibleName("Projeto em que o Harness trabalhará")
        selected = recommended_workspace(root, saved_workspace)
        self.workspace.setText(str(selected) if selected else "")
        self.workspace.setPlaceholderText("Selecione a pasta do seu projeto")
        row = QWidget(); row_layout = QHBoxLayout(row); row_layout.setContentsMargins(0, 0, 0, 0)
        row_layout.addWidget(self.workspace, 1)
        browse = QPushButton("Trocar pasta…")
        browse.setObjectName("secondaryButton")
        browse.clicked.connect(self.browse)
        row_layout.addWidget(browse)
        form.addRow("Seu projeto:", row)
        note = QLabel("Pasta sugerida pelo contexto deste computador. Você pode trocar para outro projeto.")
        note.setWordWrap(True); note.setObjectName("sectionCaption")
        form.addRow("", note)
        self.route = QComboBox()
        self.route.addItem("Entrar com DeepSeek · navegador (OAuth)", "account")
        self.route.addItem("Usar chave API · cobrança conforme consumo", "api")
        form.addRow("Como entrar:", self.route)
        self.api = QWidget(); api_form = QFormLayout(self.api); api_form.setContentsMargins(0, 0, 0, 0)
        self.credential = QComboBox()
        self.vault_error = ""
        try:
            wallet = vault if vault is not None else CredentialVault(credential_vault_path())
            for entry in wallet.entries:
                if entry.state == "active" and entry.provider.casefold() == "deepseek":
                    self.credential.addItem(entry.nickname, entry.account_id)
        except Exception:
            self.vault_error = "Carteira indisponível. Repare o cofre em Contas e conexões antes de continuar."
        self.credential.addItem("Adicionar nova chave à carteira…", "new")
        api_form.addRow("Chave DeepSeek:", self.credential)
        self.new_fields = QWidget(); new_form = QFormLayout(self.new_fields); new_form.setContentsMargins(0, 0, 0, 0)
        self.nickname = QLineEdit("DeepSeek")
        self.nickname.setAccessibleName("Nome da chave na carteira")
        self.key = QLineEdit(); self.key.setEchoMode(QLineEdit.Password)
        self.key.setAccessibleName("Nova chave API DeepSeek")
        new_form.addRow("Nome na carteira:", self.nickname); new_form.addRow("Nova chave:", self.key)
        api_form.addRow(self.new_fields)
        self.consent = QCheckBox("Autorizar chave para este Harness")
        api_form.addRow(self.consent)
        billing = QLabel("API pode gerar cobrança. Remover esta chave da carteira interrompe o Harness vinculado.")
        billing.setWordWrap(True); api_form.addRow(billing)
        form.addRow(self.api)
        self.port = QLineEdit("3080"); self.port.setAccessibleName("Porta local")
        advanced_toggle = QToolButton(); advanced_toggle.setText("Opções avançadas"); advanced_toggle.setCheckable(True)
        advanced_toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        advanced_toggle.setArrowType(Qt.RightArrow)
        form.addRow(advanced_toggle)
        advanced = QWidget(); advanced_form = QFormLayout(advanced); advanced_form.setContentsMargins(0, 0, 0, 0)
        advanced_form.addRow("Porta local:", self.port); advanced.hide(); form.addRow(advanced)
        advanced_toggle.toggled.connect(advanced.setVisible)
        advanced_toggle.toggled.connect(lambda on: advanced_toggle.setArrowType(Qt.DownArrow if on else Qt.RightArrow))
        body_layout.addLayout(form)
        self.error = QLabel(""); self.error.setWordWrap(True); self.error.setObjectName("errorTitle")
        layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        self.continue_button = buttons.button(QDialogButtonBox.Ok)
        self.continue_button.setObjectName("primaryButton")
        buttons.button(QDialogButtonBox.Cancel).setObjectName("secondaryButton")
        buttons.accepted.connect(self.validate); buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)
        self.route.currentIndexChanged.connect(self.render)
        self.credential.currentIndexChanged.connect(self.render)
        self.render()

    def render(self):
        api = self.route.currentData() == "api"
        self.api.setVisible(api)
        self.new_fields.setVisible(self.credential.currentData() == "new")
        self.continue_button.setText("Conectar API e abrir" if api else "Entrar no site DeepSeek")
        self.error.setText(self.vault_error if api else "")
        self.resize(self.width(), min(self.maximumHeight(), 570 if api else 420))

    def browse(self):
        chosen = QFileDialog.getExistingDirectory(self, "Escolher projeto", self.workspace.text())
        if chosen: self.workspace.setText(chosen)

    def validate(self):
        value = self.values()
        if not value["workspace"] or not Path(value["workspace"]).is_dir():
            self.error.setText("Escolha uma pasta de projeto existente."); return
        if not self.port.text().isdigit() or not 1024 <= int(self.port.text()) <= 65535:
            self.error.setText("Escolha porta entre 1024 e 65535."); return
        if value["authRoute"] == "api":
            if self.vault_error:
                self.error.setText(self.vault_error); return
            if not self.consent.isChecked():
                self.error.setText("Confirme uso da chave e possível cobrança da API."); return
            if value["keySource"] == "new" and (not value["apiKey"] or not value["nickname"]):
                self.error.setText("Informe nome e nova chave para guardar na carteira."); return
        self.accept()

    def values(self):
        api = self.route.currentData() == "api"
        fresh = api and self.credential.currentData() == "new"
        return {"workspace": self.workspace.text().strip(), "authRoute": "api" if api else "account",
                "port": self.port.text().strip(), "keySource": "new" if fresh else "wallet" if api else "web",
                "credentialId": self.credential.currentData() if api and not fresh else "",
                "nickname": self.nickname.text().strip() if fresh else "", "apiKey": self.key.text().strip() if fresh else ""}
