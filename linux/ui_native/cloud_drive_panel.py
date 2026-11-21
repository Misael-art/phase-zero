"""Native Google Drive setup inside Recursos → Backup e nuvem."""

from __future__ import annotations

import json
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QStandardPaths, Qt, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QFileDialog, QFormLayout, QFrame, QGridLayout,
    QHBoxLayout, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMenu, QMessageBox,
    QPushButton, QVBoxLayout, QWidget,
)

from .widgets import SectionHeader

GOOGLE_CLIENTS_URL = "https://console.cloud.google.com/auth/clients"
DRIVE_API_URL = "https://console.cloud.google.com/apis/library/drive.googleapis.com"


def note(text: str = "") -> QLabel:
    label = QLabel(text)
    label.setTextFormat(Qt.TextFormat.PlainText)
    label.setWordWrap(True)
    label.setObjectName("sectionCaption")
    return label


class DriveCommands(QObject):
    def __init__(self, root: Path, parent: QObject) -> None:
        super().__init__(parent)
        self.pz = str(root / "linux/pz")
        self.process = QProcess(self)
        self.callback = None
        self.process.finished.connect(self.finished)
        self.process.errorOccurred.connect(self.failed)
        self.cancellable = False

    def start(self, arguments: list[str], callback) -> None:
        self.callback = callback
        self.cancellable = arguments[0] == "authorize"
        self.process.start(self.pz, ["cloud-drive", *arguments])

    def finished(self, code: int, _status) -> None:
        stdout = bytes(self.process.readAllStandardOutput())
        self.process.readAllStandardError()
        try:
            result = json.loads(stdout)
            if not isinstance(result, dict) or not isinstance(result.get("ok"), bool):
                raise ValueError
            result["ok"] = result["ok"] and code == 0
        except (ValueError, UnicodeError):
            result = {"ok": False, "message": "O PhaseZero não conseguiu concluir a operação."}
        self.deliver(result)

    def failed(self, error) -> None:
        if error == QProcess.ProcessError.FailedToStart:
            self.deliver({"ok": False, "message": "O PhaseZero não conseguiu iniciar o gerenciador de pastas."})

    def deliver(self, result: dict) -> None:
        callback, self.callback = self.callback, None
        self.cancellable = False
        if callback is not None:
            callback(result)

    def cancel(self) -> None:
        if self.cancellable:
            self.process.terminate()

    def shutdown(self) -> None:
        if self.cancellable:
            self.callback = None
            self.cancel()
            self.process.waitForFinished(1200)


class FolderSetup(QDialog):
    def __init__(self, root: Path, account: dict, parent: QWidget) -> None:
        super().__init__(parent)
        self.setWindowTitle("Nova pasta virtual")
        self.resize(480, 460)
        self.commands = DriveCommands(root, self)
        self.account = account
        self.trail = [("", "Meu Drive")]
        self.requested_trail = self.trail
        layout = QVBoxLayout(self)
        layout.addWidget(note(account["email"]))
        self.location = note()
        layout.addWidget(self.location)
        self.folders = QListWidget()
        self.folders.setAccessibleName("Subpastas do Google Drive")
        self.folders.setTextElideMode(Qt.TextElideMode.ElideRight)
        self.folders.itemActivated.connect(self.enter)
        self.folders.currentItemChanged.connect(lambda item, _: self.enter_button.setEnabled(item is not None))
        layout.addWidget(self.folders, 1)
        navigation = QHBoxLayout()
        self.up = QPushButton("Voltar")
        self.up.clicked.connect(lambda: self.list_folders(self.trail[:-1]))
        self.enter_button = QPushButton("Abrir subpasta")
        self.enter_button.clicked.connect(lambda: self.enter(self.folders.currentItem()))
        self.retry = QPushButton("Tentar novamente")
        self.retry.clicked.connect(lambda: self.list_folders(self.requested_trail))
        self.retry.hide()
        navigation.addWidget(self.up)
        navigation.addWidget(self.enter_button)
        navigation.addWidget(self.retry)
        navigation.addStretch()
        layout.addLayout(navigation)
        form = QFormLayout()
        form.setRowWrapPolicy(QFormLayout.RowWrapPolicy.WrapLongRows)
        local_row = QHBoxLayout()
        self.local = QLineEdit()
        self.local.textEdited.connect(lambda: setattr(self, "custom_local", True))
        local_row.addWidget(self.local, 1)
        choose = QPushButton("Escolher…")
        choose.clicked.connect(self.choose_directory)
        local_row.addWidget(choose)
        form.addRow("Pasta no computador", local_row)
        self.local.setAccessibleName("Pasta no computador")
        layout.addLayout(form)
        self.read_only = QCheckBox("Somente leitura nesta pasta")
        self.read_only.setVisible(bool(account["write"]))
        layout.addWidget(self.read_only)
        self.custom_local = False
        self.message = note()
        layout.addWidget(self.message)
        footer = QHBoxLayout()
        footer.addStretch()
        cancel = QPushButton("Cancelar")
        cancel.clicked.connect(self.reject)
        self.save_button = QPushButton("Salvar e montar")
        self.save_button.setObjectName("primaryButton")
        self.save_button.clicked.connect(self.accept)
        footer.addWidget(cancel)
        footer.addWidget(self.save_button)
        layout.addLayout(footer)
        for button in self.findChildren(QPushButton):
            button.setAutoDefault(False)
        self.show_trail()
        self.list_folders(self.trail)

    def show_trail(self) -> None:
        self.location.setText(" / ".join(name for _, name in self.trail))
        if not self.custom_local:
            account_folder = self.account["email"].replace("/", "_")
            parts = [name.replace("/", "_") for _, name in self.trail[1:]]
            if any(part in {"", ".", ".."} for part in [account_folder, *parts]):
                parts = [self.trail[-1][0] or "Meu Drive"]
                account_folder = self.account["id"]
            suggestion = " - ".join([account_folder, *parts]).encode()[:200].decode(errors="ignore")
            self.local.setText(str(Path.home() / "Google Drive" / suggestion))

    def list_folders(self, trail: list[tuple[str, str]]) -> None:
        if not trail or self.commands.callback is not None:
            return
        self.requested_trail = trail
        self.retry.hide()
        self.folders.setEnabled(False)
        self.up.setEnabled(False)
        self.enter_button.setEnabled(False)
        self.save_button.setEnabled(False)
        self.message.setText("Consultando subpastas…")

        def ready(result: dict) -> None:
            self.folders.setEnabled(True)
            if result["ok"]:
                self.trail = trail
                self.show_trail()
                self.folders.clear()
                for folder in result["folders"]:
                    name = "".join(char if char.isprintable() else " " for char in folder["name"])
                    item = QListWidgetItem(name.strip() or folder["id"])
                    item.setData(Qt.ItemDataRole.UserRole, folder["id"])
                    self.folders.addItem(item)
                self.message.setText("" if self.folders.count() else "Esta pasta não tem subpastas.")
            else:
                self.message.setText(result["message"])
                self.retry.show()
            self.enter_button.setEnabled(self.folders.currentItem() is not None)
            self.up.setEnabled(len(self.trail) > 1)
            self.save_button.setEnabled(result["ok"] or bool(self.folders.count()))

        self.commands.start(["folders", self.account["id"], f"--folder={trail[-1][0]}"], ready)

    def enter(self, item: QListWidgetItem | None) -> None:
        if item is not None:
            folder_id = item.data(Qt.ItemDataRole.UserRole)
            if folder_id not in {key for key, _ in self.trail}:
                self.list_folders([*self.trail, (folder_id, item.text())])

    def choose_directory(self) -> None:
        chosen = QFileDialog.getExistingDirectory(self, "Escolher pasta local vazia", str(Path.home()))
        if chosen:
            self.custom_local = True
            self.local.setText(chosen)

    def reject(self) -> None:
        if self.commands.callback is not None:
            self.commands.callback = None
            self.commands.process.terminate()
            self.commands.process.waitForFinished(1000)
        super().reject()

    def arguments(self) -> list[str]:
        folder, label = self.trail[-1]
        return [
            "add", self.account["id"], f"--folder={folder}", f"--label={label}",
            f"--local={self.local.text()}", *(f"--parent={key}" for key, _ in self.trail[1:-1]),
            *(["--read-only"] if self.read_only.isChecked() else []),
        ]


class CloudDrivePanel(QFrame):
    def __init__(self, root: Path, parent: QWidget, prepare_rclone=None) -> None:
        super().__init__(parent)
        self.root = root
        self.setObjectName("choiceJourney")
        self.commands = DriveCommands(root, self)
        QApplication.instance().aboutToQuit.connect(self.commands.shutdown)
        self.data: dict = {}
        self.loaded = False
        self.selection = ""
        self.preferred_account = ""
        self.api_project = None
        layout = QVBoxLayout(self)
        layout.addWidget(SectionHeader("Pastas do Google Drive", "Acesse arquivos da nuvem pelo gerenciador de arquivos."))
        self.body = QWidget()
        body = QVBoxLayout(self.body)
        body.setContentsMargins(0, 0, 0, 0)
        accounts = QGridLayout()
        self.accounts = QComboBox()
        self.accounts.setAccessibleName("Conta do Google Drive")
        self.accounts.setPlaceholderText("Nenhuma conta conectada")
        self.accounts.setSizeAdjustPolicy(QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
        self.accounts.setMinimumContentsLength(12)
        self.accounts.currentIndexChanged.connect(self.update_controls)
        self.connect_button = QPushButton("Conectar conta")
        self.connect_button.clicked.connect(self.connect_account)
        self.account_options = QPushButton("Opções")
        self.account_options.setAccessibleName("Opções da conta e da autorização Google")
        menu = QMenu(self.account_options)
        menu.addAction("Configurar autorização Google", self.set_client)
        self.renew = menu.addAction("Renovar autorização", lambda: self.connect_account(renew=True))
        self.disconnect = menu.addAction("Desconectar conta", self.disconnect_account)
        self.account_options.setMenu(menu)
        self.setup = QPushButton("Configurar autorização Google")
        self.setup.clicked.connect(self.set_client)
        self.prepare = QPushButton("Preparar rclone")
        if prepare_rclone is not None:
            self.prepare.clicked.connect(prepare_rclone)
        self.has_prepare_action = prepare_rclone is not None
        accounts.addWidget(self.accounts, 0, 0, 1, 2)
        accounts.addWidget(self.connect_button, 1, 0)
        accounts.addWidget(self.account_options, 1, 1)
        accounts.addWidget(self.prepare, 2, 0, 1, 2, Qt.AlignmentFlag.AlignLeft)
        accounts.addWidget(self.setup, 3, 0, 1, 2, Qt.AlignmentFlag.AlignLeft)
        body.addLayout(accounts)
        self.prerequisites = note()
        body.addWidget(self.prerequisites)
        self.mounts = QListWidget()
        self.mounts.setAccessibleName("Pastas virtuais registradas")
        self.mounts.setMinimumHeight(100)
        self.mounts.setMaximumHeight(180)
        self.mounts.currentItemChanged.connect(self.mount_selected)
        self.mounts.itemActivated.connect(lambda _: self.open_folder())
        body.addWidget(self.mounts)
        self.details = note()
        body.addWidget(self.details)

        controls = QGridLayout()
        self.add = QPushButton("Nova pasta")
        self.add.setObjectName("primaryButton")
        self.add.clicked.connect(self.add_folder)
        self.change_mount = QPushButton("Montar")
        self.change_mount.clicked.connect(self.toggle_mount)
        self.open = QPushButton("Abrir pasta")
        self.open.clicked.connect(self.open_folder)
        self.remove = QPushButton("Remover pasta")
        self.remove.clicked.connect(self.remove_folder)
        for index, button in enumerate((self.add, self.change_mount, self.open, self.remove)):
            controls.addWidget(button, index // 2, index % 2)
        body.addLayout(controls)
        layout.addWidget(self.body)
        self.message = note()
        self.message.setAccessibleName("Estado da operação do Google Drive")
        layout.addWidget(self.message)
        footer = QHBoxLayout()
        self.fix_api = QPushButton("Ativar API do Drive")
        self.fix_api.setObjectName("primaryButton")
        self.fix_api.clicked.connect(self.open_api_setup)
        footer.addWidget(self.fix_api)
        footer.addStretch()
        self.cancel = QPushButton("Cancelar autorização")
        self.cancel.clicked.connect(self.commands.cancel)
        self.cancel.hide()
        footer.addWidget(self.cancel)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.clicked.connect(lambda: self.refresh())
        footer.addWidget(self.refresh_button)
        layout.addLayout(footer)
        self.update_controls()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self.refresh()

    def refresh(self, message: str = "") -> None:
        if self.commands.callback is not None:
            return
        if not message and self.api_project is not None:
            message = self.message.text()
        self.body.setEnabled(False)
        self.refresh_button.setEnabled(False)
        self.message.setText(message or "Consultando pastas virtuais…")

        def ready(result: dict) -> None:
            self.body.setEnabled(True)
            self.refresh_button.setEnabled(True)
            self.loaded = result["ok"]
            self.message.setText(message if self.loaded else result.get("message", "Atualize a lista para tentar novamente."))
            if self.loaded:
                self.render(result)
            self.update_controls()

        self.commands.start(["status"], ready)

    def render(self, result: dict) -> None:
        previous = self.preferred_account or self.accounts.currentData()
        self.preferred_account = ""
        self.data = result
        self.accounts.blockSignals(True)
        self.accounts.clear()
        for account in result["accounts"]:
            scope = "Edição" if account["write"] else "Leitura"
            self.accounts.addItem(f'{account["email"]} · {scope}', account["id"])
        index = self.accounts.findData(previous)
        self.accounts.setCurrentIndex(max(0, index))
        self.accounts.blockSignals(False)
        self.mounts.blockSignals(True)
        self.mounts.clear()
        selected = None
        owners = {account["id"]: account["email"] for account in result["accounts"]}
        for mount in result["mounts"]:
            state = {"mounted": "Montada", "unmounted": "Desmontada", "occupied": "Pasta ocupada",
                     "stale": "Reconexão necessária"}[mount["state"]]
            item = QListWidgetItem(f'{mount["label"]} · {state} · {owners[mount["account"]]}')
            item.setData(Qt.ItemDataRole.UserRole, mount["id"])
            self.mounts.addItem(item)
            if mount["id"] == self.selection:
                selected = item
        self.mounts.setCurrentItem(selected or self.mounts.item(0))
        self.mounts.blockSignals(False)
        self.mount_selected(self.mounts.currentItem())

    def mount_selected(self, item: QListWidgetItem | None, _previous=None) -> None:
        self.selection = item.data(Qt.ItemDataRole.UserRole) if item else ""
        self.update_controls()

    def selected_account(self) -> dict:
        return next((row for row in self.data.get("accounts", []) if row["id"] == self.accounts.currentData()), {})

    def selected_mount(self) -> dict:
        return next((row for row in self.data.get("mounts", []) if row["id"] == self.selection), {})

    def update_controls(self) -> None:
        data = self.data if self.loaded else {}
        account = self.selected_account() if self.loaded else {}
        mount = self.selected_mount() if self.loaded else {}
        mounted = mount.get("state") in {"mounted", "stale"}
        depends = data.get("rclone") and data.get("fuse")
        connect_ready = bool(data.get("clientConfigured") and data.get("rclone"))
        self.accounts.setVisible(bool(account))
        self.account_options.setVisible(bool(account or data.get("clientConfigured")))
        self.setup.setVisible(self.loaded and not data.get("clientConfigured"))
        self.prepare.setVisible(self.loaded and not data.get("rclone") and self.has_prepare_action)
        self.connect_button.setVisible(connect_ready)
        button_style = "secondaryButton" if account or self.api_project is not None else "primaryButton"
        if self.connect_button.objectName() != button_style:
            self.connect_button.setObjectName(button_style)
            self.connect_button.style().unpolish(self.connect_button)
            self.connect_button.style().polish(self.connect_button)
        self.renew.setEnabled(bool(connect_ready and account))
        self.disconnect.setEnabled(bool(account))
        self.add.setEnabled(bool(depends and account.get("configured")))
        self.add.setVisible(bool(account))
        self.change_mount.setText("Desmontar" if mounted else "Montar")
        self.change_mount.setEnabled(bool(mounted or (depends and mount.get("state") == "unmounted")))
        self.open.setEnabled(mount.get("state") == "mounted")
        self.remove.setEnabled(bool(mount and not mounted))
        self.mounts.setVisible(bool(mount))
        self.details.setVisible(bool(mount))
        for button in (self.change_mount, self.open, self.remove):
            button.setVisible(bool(mount))
        self.fix_api.setVisible(self.api_project is not None)
        owner = next((row["email"] for row in data.get("accounts", []) if row["id"] == mount.get("account")), "")
        scope = "Edição" if mount.get("write") else "Leitura"
        self.details.setText(f'{mount["local"]}\n{owner} · {scope}' if mount else "")
        if self.api_project is not None:
            hint = ""
        elif self.loaded and not data.get("rclone"):
            hint = "O rclone monta as pastas do Drive. Depois de prepará-lo, atualize esta seção."
        elif self.loaded and not data.get("clientConfigured"):
            hint = "Configure o Google uma vez para conectar suas contas pelo navegador."
        elif self.loaded and not account:
            hint = "Conecte uma conta Google para escolher a primeira pasta."
        elif self.loaded and not data.get("fuse"):
            hint = "Esta sessão Linux está sem FUSE. A montagem depende dele."
        elif self.loaded and not mount:
            hint = "Escolha uma pasta do Google Drive e onde ela deve aparecer no computador."
        else:
            hint = ""
        self.prerequisites.setText(hint)
        self.prerequisites.setVisible(bool(hint))

    def operate(self, args: list[str], busy: str, success: str, callback=None) -> None:
        self.api_project = None
        self.fix_api.hide()
        self.body.setEnabled(False)
        self.refresh_button.setEnabled(False)
        self.cancel.setVisible(args[0] == "authorize")
        self.message.setText(busy)

        def ready(result: dict) -> None:
            self.cancel.hide()
            if args[0] == "authorize":
                self.api_project = result.get("activationProject")
            if callback and result["ok"]:
                callback(result)
                return
            message = success if result["ok"] else result.get("message", "A operação falhou.")
            if result.get("pending"):
                message = "Pasta desmontada com envios pendentes. Monte novamente para retomá-los."
            self.refresh(message)

        self.commands.start(args, ready)

    def set_client(self) -> None:
        setup = QDialog(self)
        setup.setWindowTitle("Configurar autorização Google")
        setup.resize(440, 280)
        layout = QVBoxLayout(setup)
        layout.addWidget(SectionHeader("Prepare o acesso no Google Cloud"))
        layout.addWidget(note("No mesmo projeto, ative a Google Drive API e crie um cliente OAuth do tipo Aplicativo para computador."))
        for label, url in (("Ativar Google Drive API", DRIVE_API_URL), ("Criar cliente OAuth", GOOGLE_CLIENTS_URL)):
            action = QPushButton(label)
            action.clicked.connect(lambda _checked=False, target=url: QDesktopServices.openUrl(QUrl(target)))
            layout.addWidget(action)
        layout.addWidget(note("Se o app estiver em teste, adicione sua conta em Público → Usuários de teste. Baixe o JSON do cliente e importe aqui."))
        footer = QHBoxLayout()
        footer.addStretch()
        cancel = QPushButton("Cancelar")
        cancel.clicked.connect(setup.reject)
        import_file = QPushButton("Importar JSON…")
        import_file.setObjectName("primaryButton")
        import_file.clicked.connect(setup.accept)
        footer.addWidget(cancel)
        footer.addWidget(import_file)
        layout.addLayout(footer)
        if setup.exec() != QDialog.DialogCode.Accepted:
            setup.deleteLater()
            return
        setup.deleteLater()
        downloads = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.DownloadLocation)
        filename, _ = QFileDialog.getOpenFileName(self, "Importar cliente OAuth Desktop do Google",
                                                  downloads or str(Path.home()), "Cliente Google (*.json)")
        if filename:
            self.operate(["set-client", "--", filename], "Verificando o arquivo…",
                         "Cliente Google importado. Conecte sua conta quando o rclone estiver pronto.")

    def open_api_setup(self) -> None:
        url = DRIVE_API_URL
        if isinstance(self.api_project, str) and self.api_project.isascii() and self.api_project.isdecimal():
            url += f"?project={self.api_project}"
        if not QDesktopServices.openUrl(QUrl(url)):
            self.message.setText("O navegador não abriu. Ative a Google Drive API no Google Cloud e conecte novamente.")

    def connect_account(self, *, renew: bool = False) -> None:
        args = ["authorize"]
        if renew:
            args.extend(["--account", self.accounts.currentData()])
        else:
            dialog = QMessageBox(self)
            dialog.setWindowTitle("Permissão da conta Google")
            dialog.setText("Como você quer acessar os arquivos deste Drive?")
            dialog.setInformativeText("Leitura permite consultar e copiar. Edição também permite alterar e excluir arquivos no Drive.")
            read = dialog.addButton("Leitura", QMessageBox.ButtonRole.AcceptRole)
            read.setObjectName("primaryButton")
            write = dialog.addButton("Edição", QMessageBox.ButtonRole.ActionRole)
            dialog.addButton("Cancelar", QMessageBox.ButtonRole.RejectRole)
            dialog.setDefaultButton(read)
            dialog.exec()
            if dialog.clickedButton() not in (read, write):
                return
            if dialog.clickedButton() == write:
                args.append("--write")
        self.operate(args, "Permita o acesso no Google e volte ao PhaseZero. A conexão será confirmada aqui.", "", self.authorized)

    def authorized(self, result: dict) -> None:
        self.preferred_account = result["id"]
        self.refresh("Conta Google autorizada.")

    def disconnect_account(self) -> None:
        if QMessageBox.question(self, "Desconectar conta Google",
                                "Remover o acesso local desta conta no PhaseZero?") == QMessageBox.StandardButton.Yes:
            self.operate(["disconnect", self.accounts.currentData()], "Desconectando…", "Conexão local removida.")

    def add_folder(self) -> None:
        setup = FolderSetup(self.root, self.selected_account(), self)
        if setup.exec() == QDialog.DialogCode.Accepted:
            self.operate(setup.arguments(), "Salvando a pasta virtual…", "", self.saved_folder)
        setup.deleteLater()

    def saved_folder(self, result: dict) -> None:
        self.selection = result["id"]
        self.operate(["mount", self.selection], "Pasta salva. Montando…", "Pasta montada. Use Abrir pasta.")

    def toggle_mount(self) -> None:
        if self.selected_mount()["state"] in {"mounted", "stale"}:
            self.operate(["unmount", self.selection], "Verificando envios antes de desmontar…", "Pasta desmontada.")
        else:
            self.operate(["mount", self.selection], "Montando a pasta…", "Pasta montada. Use Abrir pasta.")

    def open_folder(self) -> None:
        mount = self.selected_mount()
        if mount.get("state") == "mounted" and not QDesktopServices.openUrl(QUrl.fromLocalFile(mount["local"])):
            self.message.setText("O gerenciador de arquivos não conseguiu abrir esta pasta.")

    def remove_folder(self) -> None:
        if QMessageBox.question(self, "Remover pasta virtual",
                                "Remover esta pasta da lista do PhaseZero? Os arquivos no Drive serão preservados.") == QMessageBox.StandardButton.Yes:
            self.operate(["remove", self.selection], "Removendo o registro…", "Pasta removida do PhaseZero.")
