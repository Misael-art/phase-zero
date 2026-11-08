"""Record an observed grant, never manufacture a balance from plan price."""
from datetime import datetime, timezone
from PySide6.QtCore import QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFormLayout, QFrame, QLabel, QLineEdit, QPushButton, QScrollArea, QVBoxLayout, QWidget
from linux.ai.api_credits import ApiCredit, OPENAI_BILLING_URL
from .widgets import fit_to_screen


class ApiCreditDialog(QDialog):
    def __init__(self, provider, credit=None, parent=None):
        super().__init__(parent)
        self.provider = provider
        self.setWindowTitle("Cota da API")
        fit_to_screen(self, 580, 560)
        outer = QVBoxLayout(self)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setFrameShape(QFrame.NoFrame)
        body = QWidget(); layout = QVBoxLayout(body); scroll.setWidget(body); outer.addWidget(scroll, 1)
        note = QLabel("Registre valores vistos no faturamento do provedor. Crédito pertence à organização, não a cada chave. Deixe saldo vazio quando desconhecido. Atualize observação no novo ciclo; este cadastro não consulta nem desconta consumo automaticamente.")
        note.setWordWrap(True); layout.addWidget(note)
        if provider.casefold() == "openai":
            guide = QLabel("OpenAI: benefício para Pro e Business elegíveis, com ativação e organização vinculada. Plus não é elegível. Primeiro crédito pode ser proporcional; vence no ciclo. Valor do plano não comprova concessão nem saldo. Após crédito gratuito, OpenAI pode consumir saldo comprado.")
            guide.setWordWrap(True); layout.addWidget(guide)
            link = QPushButton("Abrir faturamento OpenAI")
            link.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(OPENAI_BILLING_URL)))
            layout.addWidget(link)
        form = QFormLayout(); form.setRowWrapPolicy(QFormLayout.WrapAllRows); layout.addLayout(form)
        self.organization = QLineEdit(credit.organization if credit else "")
        self.activation = QComboBox()
        for label, value in [("Não verificada", "unknown"), ("Ativa no faturamento", "active"), ("Ainda não ativada", "not-activated"), ("Conta não elegível", "ineligible")]:
            self.activation.addItem(label, value)
        self.activation.setCurrentIndex(max(0, self.activation.findData(credit.activation if credit else "unknown")))
        self.kind = QComboBox()
        for label, value in [("Benefício da assinatura", "subscription"), ("Crédito comprado", "purchased"), ("Outro crédito", "other")]:
            self.kind.addItem(label, value)
        self.kind.setCurrentIndex(max(0, self.kind.findData(credit.kind if credit else "subscription")))
        self.currency = QComboBox(); self.currency.addItems(["USD", "BRL", "EUR", "CNY"])
        if credit: self.currency.setCurrentText(credit.currency)
        self.total = QLineEdit(str(credit.total) if credit and credit.total is not None else "")
        self.remaining = QLineEdit(str(credit.remaining) if credit and credit.remaining is not None else "")
        self.expires = QLineEdit(credit.expires_at if credit else "")
        self.expires.setPlaceholderText("2026-12-07T00:00:00-03:00 · vazio se desconhecido")
        for label, widget in [("Organização/conta de faturamento", self.organization), ("Ativação observada", self.activation), ("Origem do crédito", self.kind), ("Moeda", self.currency), ("Concessão observada", self.total), ("Saldo observado", self.remaining), ("Vencimento com fuso", self.expires)]:
            widget.setAccessibleName(label); form.addRow(label, widget)
        self.error = QLabel(); self.error.setWordWrap(True); layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Save | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Save).setText("Registrar observação")
        buttons.accepted.connect(self.validate); buttons.rejected.connect(self.reject)
        outer.addWidget(buttons)

    def values(self):
        number = lambda value: float(value.replace(",", ".")) if value.strip() else None
        return ApiCredit(provider=self.provider, organization=self.organization.text().strip(),
            currency=self.currency.currentText(), kind=self.kind.currentData(), activation=self.activation.currentData(),
            total=number(self.total.text()), remaining=number(self.remaining.text()),
            expires_at=self.expires.text().strip(), observed_at=datetime.now(timezone.utc).isoformat(), source="user_reported")

    def validate(self):
        try: self.values()
        except (ValueError, TypeError) as error:
            self.error.setText(f"Confira campos: {error}"); return
        self.accept()


class OpenCodeApiDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("OpenAI API como padrão do OpenCode")
        fit_to_screen(self, 580, 420)
        outer = QVBoxLayout(self)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setFrameShape(QFrame.NoFrame)
        body = QWidget(); layout = QVBoxLayout(body); scroll.setWidget(body); outer.addWidget(scroll, 1)
        note = QLabel("Experimental. Usa somente a chave selecionada, organização cadastrada e projeto API informado. Exige OpenCode CLI e desktop compatíveis (mínimo 2.2.6). Chave será resolvida no cofre a cada requisição; 9Router permanece separado.")
        note.setWordWrap(True); layout.addWidget(note)
        form = QFormLayout(); form.setRowWrapPolicy(QFormLayout.WrapAllRows); layout.addLayout(form)
        self.project = QLineEdit(); self.project.setPlaceholderText("proj_…")
        self.model = QLineEdit("gpt-6.1-sol")
        form.addRow("ID do projeto API", self.project); form.addRow("Modelo API", self.model)
        self.consent = QCheckBox("Autorizar esta chave")
        layout.addWidget(self.consent)
        billing = QLabel("OpenAI usa créditos promocionais antes dos comprados. Esta seleção pode consumir saldo comprado após esgotar benefício. Não há garantia local de uso exclusivo da cota gratuita. Não ativa compra ou recarga automática.")
        billing.setWordWrap(True); layout.addWidget(billing)
        self.error = QLabel(); self.error.setWordWrap(True); layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Configurar padrão")
        outer.addWidget(buttons)
        buttons.accepted.connect(self.validate); buttons.rejected.connect(self.reject)

    def validate(self):
        if not self.consent.isChecked() or not self.project.text().strip() or not self.model.text().strip():
            self.error.setText("Informe projeto/modelo e confirme uso e possível consumo de saldo comprado."); return
        self.accept()
