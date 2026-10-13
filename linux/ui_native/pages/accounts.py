from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Qt, Signal, Slot
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QDialog, QDialogButtonBox, QFormLayout, QFrame, QHBoxLayout,
    QLabel, QLineEdit, QMessageBox, QPushButton, QRadioButton, QScrollArea, QVBoxLayout, QWidget,
)

from linux.ai.account_adapters import adapt_account_sources
from linux.ai.account_contract import Account, Connection, Evidence, public_account, redacted_summary
from linux.ai.credential_vault import CredentialEntry, CredentialVault, CredentialVaultError
from linux.ai.grants import CONSENT_RECORD_ADAPTERS, GrantError, GrantLedger
from linux.ai.secret_store import SecretStoreUnavailable

from ..a11y_events import announce_accessible
from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..preferences import UiPreferences
from ..widgets import SectionHeader
from .base import BasePage


_SOURCES = ("claude", "proxies", "router-providers", "router-status")
_SOURCE_LABELS = {
    "claude": "Claude",
    "proxies": "Proxies IA",
    "router-providers": "Provedores 9Router",
    "router-status": "Saúde 9Router",
}
_CONSUMER_LABELS = {
    "app.claude-code": "Claude Code",
    "app.opencode": "OpenCode",
}


@dataclass(frozen=True)
class AccountChannel:
    channel_id: str
    name: str
    requirements: str
    login_method: str
    maturity: str


ACCOUNT_CHANNELS = (
    AccountChannel(
        "claude-code", "Claude Code",
        "Claude Code instalado no host; status vem do comando oficial de autenticação.",
        "Sessão gerida dentro do Claude Code; esta tela não inicia login.",
        "Somente leitura. Credencial e identidade não são expostas; uso gerenciado aguarda grant aplicado.",
    ),
    AccountChannel(
        "proxy-browser", "Kimi, Qwen e DeepSeek Proxy",
        "Proxy e perfil de sessão mantidos pelo manager do proxy.",
        "Login de navegador no fluxo próprio do proxy.",
        "Inventário local. Artefato de sessão salvo não prova sessão válida agora.",
    ),
    AccountChannel(
        "mimo-api", "MiMo API oficial",
        "Configuração oficial do MiMo concluída pelo manager do proxy.",
        "Chave configurada no fluxo do MiMo; não há entrada de segredo nesta tela.",
        "Configuração local apenas; validade de sessão e cota não verificadas aqui.",
    ),
    AccountChannel(
        "9router-provider", "Provedores no 9Router",
        "Registro de provedor já existente na configuração do 9Router.",
        "Cadastro e autenticação geridos pelo dashboard do 9Router.",
        "Status do provider apenas. Identidade, isolamento por consumidor e grants efetivos não comprovados.",
    ),
)


class AccountChannelsDialog(QDialog):
    """Explain known account channels without starting provider login flows."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("accountChannelsDialog")
        self.setWindowTitle("Canais de conexão reconhecidos")
        screen = self.screen() or QApplication.primaryScreen()
        if screen is None:
            self.resize(640, 480)
        else:
            available = screen.availableGeometry()
            self.resize(
                max(1, min(640, available.width() - 24)),
                max(1, min(480, available.height() - 24)),
            )
        layout = QVBoxLayout(self)
        intro = QLabel(
            "Estes canais podem aparecer em Contas e conexões. Login continua no app ou manager do provedor; "
            "esta lista não inicia login nem recebe credenciais."
        )
        intro.setWordWrap(True)
        layout.addWidget(intro)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        cards = QVBoxLayout(content)
        cards.setContentsMargins(0, 0, 0, 0)
        for channel in ACCOUNT_CHANNELS:
            card = QFrame()
            card.setObjectName(f"accountChannel_{channel.channel_id}")
            details = QVBoxLayout(card)
            name = QLabel(channel.name)
            name.setObjectName("accountChannelName")
            name.setAccessibleName(channel.name)
            details.addWidget(name)
            for key, heading, value in (
                ("requirements", "Requisitos", channel.requirements),
                ("login", "Tipo de login", channel.login_method),
                ("maturity", "Maturidade", channel.maturity),
            ):
                line = QLabel(f"{heading}: {value}")
                line.setObjectName(f"accountChannel_{key}")
                line.setWordWrap(True)
                details.addWidget(line)
            cards.addWidget(card)
        cards.addStretch()
        scroll.setWidget(content)
        layout.addWidget(scroll, 1)
        close = QPushButton("Fechar")
        close.setObjectName("closeAccountChannels")
        close.clicked.connect(self.accept)
        layout.addWidget(close, 0, Qt.AlignRight)


class AddApiCredentialDialog(QDialog):
    """Collect an API key for local vault storage only."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("addApiCredentialDialog")
        self.setWindowTitle("Armazenar chave de API")
        layout = QVBoxLayout(self)
        intro = QLabel(
            "A chave vai ao cofre seguro do sistema. Esta ação não valida a chave, "
            "não conecta o provedor e não autoriza nenhum aplicativo."
        )
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        self.provider = QLineEdit()
        self.provider.setObjectName("credentialProvider")
        self.provider.setAccessibleName("Provedor da chave")
        self.nickname = QLineEdit()
        self.nickname.setObjectName("credentialNickname")
        self.nickname.setAccessibleName("Apelido da chave")
        self.secret = QLineEdit()
        self.secret.setObjectName("credentialValue")
        self.secret.setAccessibleName("Chave de API")
        self.secret.setEchoMode(QLineEdit.Password)
        form.addRow("Provedor", self.provider)
        form.addRow("Apelido", self.nickname)
        form.addRow("Chave de API", self.secret)
        layout.addLayout(form)

        self.error = QLabel("")
        self.error.setObjectName("credentialFormError")
        self.error.setWordWrap(True)
        layout.addWidget(self.error)
        actions = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        save = actions.button(QDialogButtonBox.Save)
        save.setText("Armazenar no cofre")
        save.setObjectName("saveApiCredential")
        cancel = actions.button(QDialogButtonBox.Cancel)
        cancel.setObjectName("cancelApiCredential")
        actions.accepted.connect(self._accept_if_valid)
        actions.rejected.connect(self.reject)
        layout.addWidget(actions)

    def values(self) -> tuple[str, str, str]:
        return self.provider.text(), self.nickname.text(), self.secret.text()

    def _accept_if_valid(self) -> None:
        provider, nickname, secret = self.values()
        if not provider.strip() or not nickname.strip() or not secret.strip():
            self.error.setText("Informe provedor, apelido e chave.")
            return
        if any(ord(char) < 32 or ord(char) == 127 for char in provider + nickname):
            self.error.setText("Provedor e apelido devem conter texto simples.")
            return
        if "\n" in secret or "\r" in secret:
            self.error.setText("A chave deve ocupar uma única linha.")
            return
        self.accept()


class _CredentialWorkerSignals(QObject):
    finished = Signal(str, object, str)


class _CredentialWorker(QRunnable):
    """Run potentially blocking Secret Service calls off the UI thread."""

    def __init__(self, vault: CredentialVault, operation: str, values: tuple[str, ...]) -> None:
        super().__init__()
        self.vault = vault
        self.operation = operation
        self.values = values
        self.signals = _CredentialWorkerSignals()

    @Slot()
    def run(self) -> None:
        result: object = None
        error = ""
        try:
            if self.operation == "add":
                result = self.vault.add(*self.values)
            elif self.operation == "remove":
                result = self.vault.remove(self.values[0])
            else:
                raise CredentialVaultError("unsupported credential operation")
        except (CredentialVaultError, SecretStoreUnavailable, ValueError) as exc:
            error = str(exc)
        except Exception:
            error = "Falha inesperada ao acessar o cofre seguro."
        finally:
            if self.operation == "add":
                self.values = (self.values[0], self.values[1], "")
        self.signals.finished.emit(self.operation, result, error)


def _grant_ledger_path() -> Path:
    data_home = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return data_home / "phasezero" / "ai-accounts" / "grants.json"


def _credential_vault_path(
    *,
    platform: str | None = None,
    local_app_data: str | None = None,
    xdg_data_home: str | None = None,
) -> Path:
    current_platform = os.name if platform is None else platform
    if current_platform == "nt":
        app_data = local_app_data if local_app_data is not None else os.environ.get("LOCALAPPDATA", "")
        if not app_data:
            raise OSError("Windows local application data path is unavailable")
        return Path(app_data) / "PhaseZero" / "ai-accounts" / "credentials.dpapi"
    data_home = Path(
        xdg_data_home
        if xdg_data_home is not None
        else os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")
    )
    return data_home / "phasezero" / "ai-accounts" / "credentials.json"


class AccountsPage(BasePage):
    """Private account view built from read-only status adapters."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._generation = 0
        self._pending: set[str] = set()
        self._results: dict[str, object] = {}
        self._source_observed_at: dict[str, str] = {}
        self._outcomes: dict[str, str] = {}
        self._accounts: tuple[tuple[Account, Connection], ...] = ()
        self._selected_by_provider: dict[str, str] = {}
        self._radios_by_provider: dict[str, list[tuple[str, QRadioButton]]] = {}
        self._cards_layout: QVBoxLayout | None = None
        self.summary: QLabel | None = None
        self._probe_ids: dict[str, tuple[int, str]] = {}
        self._grant_load_error = False
        self._credential_load_error = False
        self._credential_busy = False
        self._credential_confirmed_ids: set[str] = set()
        self._credential_worker: _CredentialWorker | None = None
        self._credential_status: QLabel | None = None
        self._credentials_layout: QVBoxLayout | None = None
        self._add_credential_button: QPushButton | None = None
        self.preferences = UiPreferences(self)
        self._privacy_toggle: QCheckBox | None = None
        try:
            self.grant_ledger = GrantLedger(_grant_ledger_path())
        except (OSError, ValueError, TypeError):
            self.grant_ledger = GrantLedger()
            self._grant_load_error = True
        try:
            self.credential_vault: CredentialVault | None = CredentialVault(_credential_vault_path())
        except (OSError, ValueError, TypeError, CredentialVaultError):
            self.credential_vault = None
            self._credential_load_error = True

    @property
    def redacted_export(self) -> dict[str, object]:
        return redacted_summary(tuple(connection for _account, connection in self._accounts))

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(2, 2, 8, 12)
        layout.setSpacing(10)
        layout.addWidget(SectionHeader(
            "Contas e conexões",
            "Identidade aparece só nesta tela privada. Status sem prova continua desconhecido.",
        ))
        row = QHBoxLayout()
        self.summary = QLabel("Ainda não verificado")
        self.summary.setObjectName("accountsSummary")
        self.summary.setAccessibleName("Status das contas e conexões")
        row.addWidget(self.summary, 1)
        refresh = QPushButton("Atualizar status")
        refresh.setObjectName("refreshAccounts")
        refresh.clicked.connect(self.refresh_accounts)
        row.addWidget(refresh)
        layout.addLayout(row)
        add_connection = QPushButton("Adicionar conexão")
        add_connection.setObjectName("addAccountConnection")
        add_connection.clicked.connect(self._show_channel_catalog)
        layout.addWidget(add_connection)
        credential_heading = QLabel("Chaves de API")
        credential_heading.setObjectName("accountCredentialsHeading")
        layout.addWidget(credential_heading)
        credential_note = QLabel(
            "Chaves ficam no cofre seguro local. Guardar não valida nem conecta o provedor; "
            "nenhum aplicativo recebe permissão automaticamente."
        )
        credential_note.setObjectName("accountCredentialsNote")
        credential_note.setWordWrap(True)
        layout.addWidget(credential_note)
        self._add_credential_button = QPushButton("Armazenar chave de API")
        self._add_credential_button.setObjectName("addApiCredential")
        self._add_credential_button.clicked.connect(self._show_add_api_credential)
        layout.addWidget(self._add_credential_button)
        self._credential_status = QLabel("")
        self._credential_status.setObjectName("credentialVaultStatus")
        self._credential_status.setAccessibleName("Status do cofre de credenciais")
        self._credential_status.setWordWrap(True)
        layout.addWidget(self._credential_status)
        credentials = QWidget()
        self._credentials_layout = QVBoxLayout(credentials)
        self._credentials_layout.setContentsMargins(0, 0, 0, 0)
        self._credentials_layout.setSpacing(6)
        layout.addWidget(credentials)
        self._render_credentials()
        self._privacy_toggle = QCheckBox("Ocultar identidade das contas")
        self._privacy_toggle.setObjectName("hideAccountIdentity")
        self._privacy_toggle.setAccessibleName("Ocultar identidade das contas nesta tela")
        self._privacy_toggle.setChecked(self.preferences.hide_account_identity)
        self._privacy_toggle.toggled.connect(self._set_identity_hidden)
        layout.addWidget(self._privacy_toggle)
        cards = QWidget()
        self._cards_layout = QVBoxLayout(cards)
        self._cards_layout.setContentsMargins(0, 0, 0, 0)
        self._cards_layout.setSpacing(8)
        layout.addWidget(cards)
        privacy = QLabel("Esta tela privada mostra nomes e estado. Relatórios redigidos incluem só contagens; IDs e referências secretas não são exportados.")
        privacy.setObjectName("accountsPrivacy")
        privacy.setWordWrap(True)
        layout.addWidget(privacy)
        layout.addStretch()
        scroll.setWidget(content)
        self._layout.addWidget(scroll, 1)
        self.status_loader.status_ready.connect(self._source_ready)
        self.status_loader.status_failed.connect(self._source_failed)

    def _show_channel_catalog(self) -> None:
        AccountChannelsDialog(self).exec()

    def _show_add_api_credential(self) -> None:
        if self.credential_vault is None or self._credential_busy:
            return
        dialog = AddApiCredentialDialog(self)
        if dialog.exec() != QDialog.Accepted:
            return
        values = dialog.values()
        dialog.secret.clear()
        self._start_credential_operation("add", values)

    def _start_credential_operation(self, operation: str, values: tuple[str, ...]) -> None:
        if self.credential_vault is None or self._credential_busy:
            return
        self._credential_busy = True
        if self._add_credential_button is not None:
            self._add_credential_button.setEnabled(False)
        if self._credential_status is not None:
            self._credential_status.setText("Aguardando resposta do cofre seguro…")
            announce_accessible(self._credential_status, self._credential_status.text())
        worker = _CredentialWorker(self.credential_vault, operation, values)
        worker.signals.finished.connect(self._credential_operation_finished)
        self._credential_worker = worker
        QThreadPool.globalInstance().start(worker)
        self._render_credentials()

    @Slot(str, object, str)
    def _credential_operation_finished(self, operation: str, result: object, error: str) -> None:
        self._credential_busy = False
        self._credential_worker = None
        if not error and operation == "add" and isinstance(result, CredentialEntry):
            self._credential_confirmed_ids.add(result.account_id)
        if not error and operation == "remove" and self.credential_vault is not None:
            self._credential_confirmed_ids.intersection_update(
                entry.account_id for entry in self.credential_vault.entries
            )
        if self._add_credential_button is not None:
            self._add_credential_button.setEnabled(self.credential_vault is not None)
        if self._credential_status is not None:
            if error:
                if "backend is unavailable" in error:
                    message = (
                        "Cofre seguro indisponível; nenhuma chave foi guardada."
                        if operation == "add" else
                        "Cofre seguro indisponível; referência mantida para nova tentativa."
                    )
                elif "cleanup" in error or "uncertain" in error:
                    message = (
                        "Gravação incerta; referência mantida para limpeza segura. "
                        "Nenhum aplicativo recebeu acesso."
                    )
                elif "could not store" in error or "could not save" in error:
                    message = "O cofre não guardou a chave; nenhuma conexão foi criada."
                elif "could not delete" in error:
                    message = "O cofre não confirmou a remoção; referência foi mantida."
                else:
                    message = "Falha segura ao atualizar o cofre de credenciais."
            elif operation == "add" and isinstance(result, CredentialEntry):
                message = (
                    "Chave guardada no cofre local. Sessão, validade e cota não verificadas; "
                    "nenhum aplicativo autorizado."
                )
            elif operation == "remove" and result is True:
                message = "Cópia local removida do cofre; a chave do provedor não foi revogada."
            else:
                message = "Referência local removida; a chave do provedor não foi revogada."
            self._credential_status.setText(message)
            announce_accessible(self._credential_status, message)
        self._render_credentials()

    def _render_credentials(self) -> None:
        if self._credentials_layout is None:
            return
        while self._credentials_layout.count():
            item = self._credentials_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

        if self.credential_vault is None:
            if self._credential_status is not None:
                self._credential_status.setText(
                    "Cofre de credenciais indisponível ou registro inválido; ações bloqueadas."
                )
            if self._add_credential_button is not None:
                self._add_credential_button.setEnabled(False)
            return

        if self._credential_status is not None and not self._credential_status.text():
            self._credential_status.setText(
                "Nenhuma chave de API armazenada." if not self.credential_vault.entries else
                "Referências locais registradas; presença atual no cofre, validade e uso por apps não verificados."
            )

        hidden = self.preferences.hide_account_identity
        for index, entry in enumerate(self.credential_vault.entries, start=1):
            card = QFrame()
            card.setObjectName("storedApiCredential")
            row = QHBoxLayout(card)
            details = QVBoxLayout()
            label = QLabel(
                f"Chave {index}" if hidden else f"{entry.provider} · {entry.nickname}"
            )
            label.setObjectName("storedApiCredentialLabel")
            presence = (
                "Gravação não confirmada · referência mantida para limpeza" if entry.state == "pending"
                else "Cofre confirmou gravação nesta sessão"
                if entry.account_id in self._credential_confirmed_ids else
                "Registro ativo · presença atual no cofre não consultada"
            )
            state = QLabel(
                f"{presence} · sessão e cota não verificadas · nenhum app autorizado"
            )
            state.setObjectName("storedApiCredentialState")
            state.setWordWrap(True)
            details.addWidget(label)
            details.addWidget(state)
            row.addLayout(details, 1)
            remove = QPushButton("Remover cópia local")
            remove.setObjectName("removeApiCredential")
            remove.setAccessibleName(
                f"Remover chave {index}" if hidden else f"Remover chave de {entry.provider}"
            )
            remove.setToolTip(
                "Apaga somente esta cópia local do cofre; não revoga a chave no provedor."
            )
            remove.setEnabled(not self._credential_busy)
            remove.clicked.connect(
                lambda _checked=False, account_id=entry.account_id:
                self._remove_api_credential(account_id)
            )
            row.addWidget(remove)
            self._credentials_layout.addWidget(card)

    def _remove_api_credential(self, account_id: str) -> None:
        if self.credential_vault is None or self._credential_busy:
            return
        entry = next(
            (candidate for candidate in self.credential_vault.entries
             if candidate.account_id == account_id),
            None,
        )
        if entry is None or not self._confirm_remove_api_credential(entry):
            return
        self._start_credential_operation("remove", (account_id,))

    def _confirm_remove_api_credential(self, entry: CredentialEntry) -> bool:
        label = "esta chave" if self.preferences.hide_account_identity else entry.nickname
        answer = QMessageBox.question(
            self,
            "Remover cópia local?",
            f"A cópia segura de {label} será apagada deste sistema. "
            "A chave não será revogada no provedor e apps não serão alterados.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        return answer == QMessageBox.Yes

    def _set_identity_hidden(self, hidden: bool) -> None:
        self.preferences.set_hide_account_identity(hidden)
        self._render_cards()
        self._render_credentials()

    def refresh_accounts(self) -> None:
        self._generation += 1
        generation = self._generation
        self.status_loader.cancel_all()
        self._pending = set(_SOURCES)
        self._results = {}
        self._source_observed_at = {}
        self._outcomes = {source: "loading" for source in _SOURCES}
        if self.summary is not None:
            self.summary.setText("Verificando provedores disponíveis…")
            announce_accessible(self.summary, self.summary.text())
        commands = {
            "claude": ["ai", "claude", "status"],
            "proxies": ["ai", "proxies", "detailed-status"],
            "router-providers": ["ai", "9router", "provider", "status"],
            "router-status": ["ai", "9router", "status"],
        }
        self._probe_ids.clear()
        for source, args in commands.items():
            action_id = f"accounts:{generation}:{source}"
            self._probe_ids[action_id] = (generation, source)
            self.status_loader.fetch(action_id, args)

    def _source_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        identity = self._probe_ids.get(action_id)
        if identity is None or identity[0] != self._generation:
            return
        _generation, source = identity
        self._results[source] = parsed
        self._source_observed_at[source] = datetime.now(timezone.utc).isoformat()
        self._outcomes[source] = "ok" if isinstance(parsed, dict) else "invalid"
        self._pending.discard(source)
        self._render_if_ready()

    def _source_failed(self, action_id: str, _message: str) -> None:
        identity = self._probe_ids.get(action_id)
        if identity is None or identity[0] != self._generation:
            return
        _generation, source = identity
        self._source_observed_at[source] = datetime.now(timezone.utc).isoformat()
        self._outcomes[source] = "unavailable"
        self._pending.discard(source)
        self._render_if_ready()

    def _render_if_ready(self) -> None:
        if self._pending:
            return
        proxy_payload = self._results.get("proxies")
        proxies = proxy_payload.get("proxies", []) if isinstance(proxy_payload, dict) else []
        router_payload = self._results.get("router-providers")
        router_status = self._results.get("router-status")
        router_health = Evidence(
            source="9router-health", observed_at=self._source_observed_at.get("router-status", ""),
        )
        if isinstance(router_status, dict) and isinstance(router_status.get("healthy"), bool):
            router_health = Evidence(
                "yes" if router_status["healthy"] else "no",
                "9router-health", self._source_observed_at.get("router-status", ""),
            )
        try:
            self._accounts = adapt_account_sources(
                {
                    "claude": self._results.get("claude"),
                    "proxies": proxies if isinstance(proxies, list) else [],
                    "routerProviders": router_payload,
                },
                host_id="local", router_health=router_health,
                observed_at_by_source={
                    "claude": self._source_observed_at.get("claude", ""),
                    "proxies": self._source_observed_at.get("proxies", ""),
                    "routerProviders": self._source_observed_at.get("router-providers", ""),
                },
            )
        except (TypeError, ValueError):
            self._accounts = ()
            self._outcomes["adapters"] = "invalid"
        self._render_cards()
        if self.summary is not None:
            unavailable = [
                _SOURCE_LABELS[source] for source in _SOURCES
                if self._outcomes.get(source) != "ok"
            ]
            if self._outcomes.get("adapters") == "invalid":
                unavailable.append("adaptação de status")
            if unavailable:
                self.summary.setText(
                    f"Consulta parcial · {len(self._accounts)} registros conhecidos · "
                    f"sem resposta: {', '.join(unavailable)}"
                )
            else:
                self.summary.setText(f"Consulta concluída · {len(self._accounts)} registros conhecidos")
            announce_accessible(self.summary, self.summary.text())

    def _render_cards(self) -> None:
        if self._cards_layout is None:
            return
        while self._cards_layout.count():
            item = self._cards_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
        self._radios_by_provider.clear()
        for index, (account, connection) in enumerate(self._accounts, start=1):
            public = public_account(account)
            hidden = self.preferences.hide_account_identity
            display_name = f"Conta {index}" if hidden else str(
                public.get("displayName") or public.get("nickname") or "Conta"
            )
            workspace = "workspace oculto" if hidden else str(
                public.get("workspace") or "workspace não informado"
            )
            card = QFrame()
            card.setObjectName("accountCard")
            row = QHBoxLayout(card)
            initials = "?" if hidden else self._initials(display_name)
            avatar = QLabel(initials)
            avatar.setObjectName("accountAvatarInitials")
            avatar.setAlignment(Qt.AlignCenter)
            avatar.setFixedSize(48, 48)
            row.addWidget(avatar)
            details = QVBoxLayout()
            name = QLabel(display_name)
            name.setObjectName("accountDisplayName")
            provider = QLabel(f"{account.provider} · {workspace}")
            provider.setObjectName("accountProvider")
            state = QLabel(self._connection_state(connection))
            state.setObjectName("accountEvidence")
            quota = QLabel(self._quota_state(connection))
            quota.setObjectName("accountQuota")
            quota.setTextFormat(Qt.PlainText)
            observation = QLabel(self._observation_state(connection))
            observation.setObjectName("accountObservation")
            observation.setWordWrap(True)
            observation.setToolTip(self._observation_tooltip(connection))
            observation.setAccessibleDescription(observation.toolTip())
            for label in (name, provider, state, quota, observation):
                label.setWordWrap(True)
                details.addWidget(label)
            row.addLayout(details, 1)
            select = QRadioButton("Selecionar nesta tela")
            select.setAccessibleName(f"Selecionar {name.text()} ({account.provider})")
            select.setChecked(self._selected_by_provider.get(account.provider) == account.account_id)
            select.toggled.connect(
                lambda checked, provider_id=account.provider, account_id=account.account_id:
                self._select_account(provider_id, account_id, checked)
            )
            self._radios_by_provider.setdefault(account.provider, []).append((account.account_id, select))
            row.addWidget(select)
            self._cards_layout.addWidget(card)
            consent_consumers = [
                consumer for consumer, adapters in CONSENT_RECORD_ADAPTERS.items()
                if connection.adapter_id in adapters
            ]
            if consent_consumers:
                if self._grant_load_error:
                    unavailable = QLabel("Autorizações indisponíveis · ledger local inválido")
                    unavailable.setObjectName("accountGrantUnavailable")
                    unavailable.setWordWrap(True)
                    self._cards_layout.addWidget(unavailable)
                    continue
                access_note = QLabel(
                    "Registra somente consentimento por app; este grant não libera inferência. "
                    "Sessões não aplicam o vínculo por requisição, então uso segue bloqueado."
                )
                access_note.setObjectName("accountGrantScopeNote")
                access_note.setWordWrap(True)
                self._cards_layout.addWidget(access_note)
                for consumer_id in consent_consumers:
                    active = next((grant for grant in self.grant_ledger.for_consumer(consumer_id)
                                   if grant.connection_id == connection.connection_id), None)
                    action = QPushButton(
                        f"Revogar consentimento em {_CONSUMER_LABELS[consumer_id]}" if active else
                        "Conexão desativada" if not connection.enabled else
                        f"Registrar consentimento em {_CONSUMER_LABELS[consumer_id]}"
                    )
                    action.setObjectName("accountConsumerGrant")
                    action.setAccessibleName(action.text())
                    action.setEnabled(bool(active) or connection.enabled)
                    if not connection.enabled and not active:
                        action.setToolTip("Ative esta conexão no 9Router antes de registrar consentimento.")
                    action.clicked.connect(
                        lambda _checked=False, conn=connection, cid=consumer_id:
                        self._toggle_grant(conn, cid)
                    )
                    self._cards_layout.addWidget(action)

    def _toggle_grant(self, connection: Connection, consumer_id: str) -> None:
        current = next((grant for grant in self.grant_ledger.for_consumer(consumer_id)
                        if grant.connection_id == connection.connection_id), None)
        if current is not None:
            self.grant_ledger.revoke(current.grant_id)
            self._render_cards()
            return
        if not self._confirm_grant(consumer_id):
            return
        try:
            self.grant_ledger.grant(
                connection, consumer_id, ("inference",),
                support=CONSENT_RECORD_ADAPTERS, consented=True,
            )
        except GrantError as exc:
            QMessageBox.warning(self, "Conexão incompatível", str(exc))
            return
        self._render_cards()

    def _confirm_grant(self, consumer_id: str) -> bool:
        label = _CONSUMER_LABELS[consumer_id]
        answer = QMessageBox.question(
            self, "Registrar consentimento?",
            f"Registra apenas consentimento de {label}. Nenhuma sessão gerenciada aplica "
            "este grant; nenhuma inferência será habilitada por esta ação. Quando o vínculo "
            "por requisição estiver disponível, o provedor poderá cobrar ou aplicar limites.",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No,
        )
        return answer == QMessageBox.Yes

    def _select_account(self, provider: str, account_id: str, checked: bool) -> None:
        if checked:
            self._selected_by_provider[provider] = account_id
            for other_id, other_radio in self._radios_by_provider.get(provider, []):
                if other_id != account_id and other_radio.isChecked():
                    other_radio.setChecked(False)
        elif self._selected_by_provider.get(provider) == account_id:
            self._selected_by_provider.pop(provider, None)

    @staticmethod
    def _initials(name: str) -> str:
        parts = [part for part in name.split() if part]
        return "".join(part[0].upper() for part in parts[:2]) or "?"

    @staticmethod
    def _connection_state(connection: Connection) -> str:
        def status(evidence: Evidence) -> str:
            return "expirada" if evidence.is_expired else evidence.state

        return " · ".join((
            f"credencial {status(connection.credential)}",
            f"sessão {status(connection.session)}",
            f"serviço {status(connection.service)}",
            f"acesso {status(connection.access)}",
        ))

    @staticmethod
    def _quota_state(connection: Connection) -> str:
        quota = connection.quota
        if quota is None or quota.source == "unknown":
            return "Cota restante: não informada"

        source = "Fonte oficial" if quota.source == "official" else "Estimativa local"
        if quota.remaining is None:
            amount = "restante não informado"
            if quota.total is not None:
                amount += f"; total {quota.total:g} {quota.unit}"
        else:
            amount = f"{quota.remaining:g} {quota.unit} restantes"
            if quota.total is not None:
                amount += f" (total {quota.total:g})"

        observed = ""
        if quota.observed_at:
            timestamp = datetime.fromisoformat(quota.observed_at.replace("Z", "+00:00"))
            observed = f" · observado {timestamp.astimezone().strftime('%d/%m %H:%M')}"
        return f"{source}: {amount}{observed}"

    @staticmethod
    def _format_observation_time(value: str) -> str:
        timestamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return timestamp.astimezone().strftime("%d/%m/%Y %H:%M %Z").strip()

    @classmethod
    def _observation_state(cls, connection: Connection) -> str:
        observed = [
            evidence.observed_at
            for evidence in (
                connection.credential, connection.session, connection.service, connection.access,
            )
            if evidence.observed_at
        ]
        if not observed:
            return "Consulta local: horário não informado"
        latest = max(
            observed,
            key=lambda value: datetime.fromisoformat(value.replace("Z", "+00:00")),
        )
        return f"Consulta local mais recente: {cls._format_observation_time(latest)}"

    @classmethod
    def _observation_tooltip(cls, connection: Connection) -> str:
        fields = (
            ("Credencial", connection.credential),
            ("Sessão", connection.session),
            ("Serviço", connection.service),
            ("Acesso", connection.access),
        )
        details = [
            f"{label}: {evidence.source} · {cls._format_observation_time(evidence.observed_at)}"
            for label, evidence in fields if evidence.observed_at
        ]
        return (
            "Cada horário indica resposta de consulta local; isso não comprova sessão válida, acesso ou cota."
            + ("\n" + "\n".join(details) if details else "")
        )

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)

    def hideEvent(self, event) -> None:
        self._generation += 1
        self.status_loader.cancel_all()
        self._pending.clear()
        super().hideEvent(event)
