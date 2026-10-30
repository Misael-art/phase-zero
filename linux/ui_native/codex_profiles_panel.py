"""Account-scoped Codex actions inside Contas e conexões."""
from __future__ import annotations

import sys
import json

from PySide6.QtCore import Signal, Qt, QTimer
from PySide6.QtWidgets import (
    QComboBox, QDialog, QDialogButtonBox, QFormLayout, QFrame, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QVBoxLayout, QWidget, QScrollArea,
)

from linux.ai.codex_profiles import COLORS, CodexProfiles, ProfileError
from .models import ActionSpec


class CodexProfileDialog(QDialog):
    def __init__(self, parent=None, row: dict | None = None):
        super().__init__(parent)
        self.setObjectName("codexProfileDialog")
        self.setWindowTitle("Identificar conta Codex" if row else "Adicionar conta Codex")
        layout = QVBoxLayout(self)
        note = QLabel("Escolha um apelido e uma cor. Depois abra Desktop e entre na conta desejada. "
                      "Login fica salvo neste perfil; cada conta tem seu próprio ID.")
        note.setWordWrap(True)
        layout.addWidget(note)
        form = QFormLayout()
        self.label = QLineEdit((row or {}).get("label", ""))
        self.label.setMaxLength(60)
        self.label.setObjectName("codexProfileLabel")
        self.color = QComboBox()
        self.color.setObjectName("codexProfileColor")
        for color in COLORS:
            self.color.addItem(color.title(), color)
        self.color.setCurrentIndex(max(0, self.color.findData((row or {}).get("color", "azul"))))
        form.addRow("Apelido da conta", self.label)
        form.addRow("Cor", self.color)
        layout.addLayout(form)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)


class CodexProfilesPanel(QWidget):
    action_requested = Signal(object)

    def __init__(self, runner, *, hidden: bool, parent=None):
        super().__init__(parent)
        self.setObjectName("codexProfilesPanel")
        self.hidden = hidden
        self._pending_metadata = {}
        self.manager = CodexProfiles()
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        title = QLabel("Contas Codex · Desktop, CLI e Web")
        title.setObjectName("codexProfilesHeading")
        self._layout.addWidget(title)
        note = QLabel("Adicione uma conta, abra Desktop e faça login uma vez. Perfis podem funcionar "
                      "ao mesmo tempo. Web Desktop usa ChatGPT Web experimental, com login próprio na mesma conta. "
                      "Navegador abre Codex no site. Não há alternância automática de contas.")
        note.setWordWrap(True)
        self._layout.addWidget(note)
        actions = QHBoxLayout()
        add = QPushButton("＋ Adicionar conta Codex")
        add.setObjectName("addCodexProfile")
        add.clicked.connect(self.add_profile)
        actions.addWidget(add)
        refresh = QPushButton("Atualizar perfis")
        refresh.setObjectName("refreshCodexProfiles")
        refresh.clicked.connect(self.refresh)
        actions.addWidget(refresh)
        actions.addStretch()
        self._layout.addLayout(actions)
        cleanup = QPushButton("Limpar instalações personalizadas")
        cleanup.setObjectName("clearCustomCodexProfiles")
        cleanup.setToolTip("Exclui todos os perfis personalizados. Codex padrão e seu Web são preservados.")
        cleanup.clicked.connect(lambda: self.remove_profiles())
        self._layout.addWidget(cleanup)
        self.cleanup = cleanup
        self.status = QLabel("")
        self.status.setWordWrap(True)
        self.status.setObjectName("codexProfilesStatus")
        self._layout.addWidget(self.status)
        self.cards = QVBoxLayout()
        self._layout.addLayout(self.cards)
        self._runner = runner
        runner.completed.connect(self._completed)
        self.refresh()

    def set_hidden(self, hidden: bool):
        self.hidden = hidden
        self.refresh()

    def _request(self, title: str, args: tuple[str, ...], *, mutable=False, metadata=None, impact=None):
        if metadata is not None:
            self._pending_metadata = {"codex_metadata": json.dumps(metadata)}
        action = ActionSpec(
            id=f"ai.codex-profiles.{args[0]}", category="Contas e conexões", title=title,
            description=("Limpa instalações personalizadas; instalação padrão e seu Web são protegidos."
                         if args[0] == "remove" else
                         "Opera somente no ID de perfil selecionado; credenciais permanecem no Codex."),
            args=("ai", "codex-profiles", "--redacted", *args), icon="system-users", mutable=mutable,
            preview_args=(("ai", "codex-profiles", "--redacted", *args, "--dry-run")
                          if args[0] == "remove" else
                          ("ai", "codex-profiles", "--redacted", "list")) if mutable else None,
            stdin_parameter="codex_metadata" if metadata is not None else "",
            impact=impact or "Cria ou atualiza perfil local. Não copia sessões nem autentica outra conta.",
        )
        self.action_requested.emit(action)

    def remove_profiles(self, row=None):
        args = ("remove", "--id", row["id"]) if row else ("remove", "--all-custom")
        self._request("Excluir perfil Codex" if row else "Limpar instalações personalizadas",
                      args, mutable=True,
                      impact="Remove perfis personalizados, login local, atalhos e início automático do ambiente ativo. "
                             "Codex padrão e seu Web são protegidos. Feche aplicativos dos perfis antes de limpar. "
                             "Dados permanecem em recuperação privada; conectores/túneis remotos não são revogados.")

    def _delete_button(self, row):
        button = QPushButton("Excluir perfil")
        button.setObjectName("deleteCodexProfile")
        button.setProperty("profileId", row["id"])
        button.clicked.connect(lambda _checked=False, row=row: self.remove_profiles(row))
        return button

    def consume_action_values(self, action):
        if action.stdin_parameter != "codex_metadata":
            return {}
        values, self._pending_metadata = self._pending_metadata, {}
        return values

    def add_profile(self):
        dialog = CodexProfileDialog(self)
        if dialog.exec() != QDialog.Accepted or not dialog.label.text().strip():
            return
        self._request("Adicionar perfil Codex", ("add", "--metadata-stdin"), mutable=True,
                      metadata={"label": dialog.label.text(), "color": dialog.color.currentData()})

    def edit_profile(self, row):
        dialog = CodexProfileDialog(self, row)
        if dialog.exec() == QDialog.Accepted and dialog.label.text().strip():
            self._request("Identificar perfil Codex", ("rename", row["id"], "--metadata-stdin"), mutable=True,
                          metadata={"label": dialog.label.text(), "color": dialog.color.currentData()})

    def _completed(self, result):
        if str(getattr(result, "action_id", "")).startswith("ai.codex-profiles."):
            self.refresh()
            if result.action_id == "ai.codex-profiles.add" and not result.preview:
                QTimer.singleShot(0, self._focus_first_profile)

    def _focus_first_profile(self):
        button = self.findChild(QPushButton, "codexProfileDesktop")
        if button is None:
            return
        button.setFocus(Qt.TabFocusReason)
        parent = button.parentWidget()
        while parent is not None:
            if isinstance(parent, QScrollArea):
                parent.ensureWidgetVisible(button)
                break
            parent = parent.parentWidget()

    def refresh(self):
        while self.cards.count():
            item = self.cards.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.hide()
                widget.setParent(None)
                widget.deleteLater()
        if sys.platform != "linux":
            self.status.setText("Gestão isolada de contas Codex disponível neste fluxo para Linux. Windows ainda não homologado.")
            self.setEnabled(False)
            return
        try:
            snapshot = self.manager.status()
        except (ProfileError, OSError):
            self.status.setText("Registro Codex indisponível. Contas preservadas; restaure backup antes de editar.")
            return
        install = QFrame()
        install_row = QHBoxLayout(install)
        install_row.setContentsMargins(0, 0, 0, 0)
        missing = []
        if not snapshot["cliInstalled"]:
            missing.append(("Instalar Codex CLI", ("ai", "setup", "codex"),
                            ("ai", "codex-profiles", "list")))
        if not snapshot["desktopInstalled"]:
            missing.append(("Instalar Codex Desktop", ("ai", "desktop", "install-codex-ready"),
                            ("ai", "desktop", "status")))
        for text, args, preview in missing:
            button = QPushButton(text)
            button.setObjectName("installCodexProfileRuntime")
            spec = ActionSpec(
                id="ai.codex-profiles.install", category="Contas e conexões", title=text,
                description="Usa instalador existente; Desktop requer pacote local preparado.",
                args=args, icon="system-software-install", mutable=True, preview_args=preview,
                impact="Instala ferramenta compartilhada. Login continua separado por perfil.",
            )
            button.clicked.connect(lambda _checked=False, spec=spec: self.action_requested.emit(spec))
            install_row.addWidget(button)
        if missing:
            self.cards.addWidget(install)
        else:
            install.deleteLater()
        self.status.setText("Status local: sessão e cota ainda não verificadas. “Conta atual” preserva sua instalação existente.")
        self.cleanup.setEnabled(any(row["id"] != "current" for row in snapshot["profiles"]))
        for index, row in enumerate(snapshot["profiles"]):
            card = QFrame()
            card.setObjectName("codexProfileCard")
            layout = QVBoxLayout(card)
            identity = QHBoxLayout()
            badge = QLabel(f"C{row['slot']}")
            badge.setObjectName("codexProfileBadge")
            badge.setStyleSheet(f"background: {COLORS[row['color']]}; color: white; padding: 6px; border-radius: 6px;")
            identity.addWidget(badge)
            name = QLabel(f"Conta Codex {index + 1}" if self.hidden else row["label"])
            name.setObjectName("codexProfileName")
            name.setTextFormat(Qt.PlainText)
            name.setWordWrap(True)
            identity.addWidget(name, 1)
            if not self.hidden:
                identity.addWidget(QLabel(row["id"]))
            layout.addLayout(identity)
            if row.get("archived"):
                archived = QLabel("Arquivada. Sessões e dados preservados; aplicativos abertos continuam ativos.")
                archived.setWordWrap(True)
                layout.addWidget(archived)
                restore = QPushButton("Restaurar perfil")
                restore.setObjectName("restoreCodexProfile")
                restore.clicked.connect(lambda _checked=False, row=row:
                                        self._request("Restaurar perfil Codex", ("restore", row["id"]), mutable=True))
                layout.addWidget(restore)
                layout.addWidget(self._delete_button(row))
                self.cards.addWidget(card)
                continue
            state = QLabel("Login salvo localmente; validade não verificada." if row["nativeCredential"] == "present"
                           else "Abra Desktop para entrar ou retomar a sessão. Cofre do sistema não consultado.")
            state.setWordWrap(True)
            layout.addWidget(state)
            if row["id"] == "current":
                legacy = QLabel("Instalação padrão protegida contra exclusão, incluindo seu Web. "
                                "Confirme a conta em cada janela; vínculo entre elas não verificado.")
                legacy.setWordWrap(True)
                layout.addWidget(legacy)
            line = QHBoxLayout()
            buttons = [
                ("Abrir Desktop", "codexProfileDesktop", ("open", row["id"], "--surface", "desktop")),
                ("Abrir CLI", "codexProfileCli", ("terminal", row["id"], "--task", "cli")),
                ("Navegador", "codexProfileBrowser", ("open", row["id"], "--surface", "browser")),
            ]
            for text, object_name, args in buttons:
                button = QPushButton(text)
                button.setObjectName(object_name)
                button.setProperty("profileId", row["id"])
                button.clicked.connect(lambda _checked=False, args=args, text=text: self._request(text, args))
                line.addWidget(button)
            line.addStretch()
            layout.addLayout(line)
            web_line = QHBoxLayout()
            for text, object_name, args, mutable in (
                ("Preparar / login Web", "codexProfileWebSetup", ("terminal", row["id"], "--task", "web-setup"), False),
                ("Abrir Web Desktop", "codexProfileWeb", ("open", row["id"], "--surface", "web"), False),
                ("Criar atalhos", "codexProfileShortcuts", ("shortcuts", row["id"]), True),
            ):
                button = QPushButton(text)
                button.setObjectName(object_name)
                button.setProperty("profileId", row["id"])
                button.clicked.connect(lambda _checked=False, args=args, text=text, mutable=mutable:
                                       self._request(text, args, mutable=mutable))
                if object_name == "codexProfileWeb":
                    button.setEnabled(row["webConfigured"])
                    button.setToolTip("Conclua preparação e login Web deste perfil.")
                web_line.addWidget(button)
            web_line.addStretch()
            layout.addLayout(web_line)
            manage_line = QHBoxLayout()
            login = QPushButton("Login CLI")
            login.setObjectName("codexProfileLogin")
            login.clicked.connect(lambda _checked=False, row=row: self._request(
                "Login CLI", ("terminal", row["id"], "--task", "login")))
            manage_line.addWidget(login)
            edit = QPushButton("Nome / cor")
            edit.setObjectName("editCodexProfile")
            edit.clicked.connect(lambda _checked=False, row=row: self.edit_profile(row))
            manage_line.addWidget(edit)
            if row["id"] != "current":
                archive = QPushButton("Arquivar")
                archive.setObjectName("archiveCodexProfile")
                archive.setToolTip("Oculta ações e remove atalhos deste perfil; preserva login e aplicativos abertos.")
                archive.clicked.connect(lambda _checked=False, row=row:
                                        self._request("Arquivar perfil Codex", ("archive", row["id"]), mutable=True))
                manage_line.addWidget(archive)
            manage_line.addStretch()
            layout.addLayout(manage_line)
            if row["id"] != "current":
                layout.addWidget(self._delete_button(row))
            self.cards.addWidget(card)
