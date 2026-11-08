"""API credit observations, separate from subscription quotas and key validity."""
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from hashlib import sha256
import math

OPENAI_CREDITS_URL = "https://developers.openai.com/api/docs/guides/chatgpt-api-credits"
OPENAI_BILLING_URL = "https://platform.openai.com/settings/organization/billing/overview"


def timestamp(value: str, *, optional=False):
    if optional and not value:
        return
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("horário precisa incluir fuso")


@dataclass(frozen=True)
class ApiCredit:
    provider: str
    organization: str
    currency: str = "USD"
    kind: str = "subscription"
    activation: str = "unknown"
    total: float | None = None
    remaining: float | None = None
    expires_at: str = ""
    observed_at: str = ""
    source: str = "user_reported"

    def __post_init__(self):
        for value in (self.provider, self.organization):
            if (not isinstance(value, str) or not value.strip() or len(value) > 120
                    or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                raise ValueError("provedor e organização precisam de identificação válida")
        if self.currency not in {"USD", "BRL", "EUR", "CNY"}:
            raise ValueError("moeda inválida")
        if self.kind not in {"subscription", "purchased", "other"}:
            raise ValueError("tipo de crédito inválido")
        if self.activation not in {"unknown", "active", "not-activated", "ineligible"}:
            raise ValueError("ativação inválida")
        if self.source not in {"user_reported", "official"}:
            raise ValueError("origem inválida")
        timestamp(self.observed_at)
        timestamp(self.expires_at, optional=True)
        for value in (self.total, self.remaining):
            if value is not None and (type(value) not in {int, float} or not math.isfinite(value) or value < 0):
                raise ValueError("valor de crédito inválido")
        if self.total is not None and self.remaining is not None and self.remaining > self.total:
            raise ValueError("saldo supera concessão observada")
        if self.activation != "active" and (self.total is not None or self.remaining is not None):
            raise ValueError("concessão precisa estar ativa para registrar valores")

    @property
    def identity(self):
        return sha256((self.provider.casefold() + "\0" + self.organization).encode()).hexdigest()

    @property
    def state(self):
        if self.expires_at and datetime.fromisoformat(self.expires_at.replace("Z", "+00:00")) <= datetime.now(timezone.utc):
            return "expired"
        return "exhausted" if self.remaining == 0 else self.activation

    def public(self):
        return {**asdict(self), "state": self.state}

    def display(self):
        state = {"expired": "Crédito vencido", "exhausted": "Saldo observado esgotado",
                 "unknown": "Ativação desconhecida", "not-activated": "Benefício não ativado",
                 "ineligible": "Conta informada como inelegível", "active": "Crédito informado como ativo"}[self.state]
        amount = "Saldo não informado" if self.remaining is None else f"Saldo observado: {self.remaining:g} {self.currency}"
        origin = "Observação oficial" if self.source == "official" else "Informado pelo usuário; sem consulta automática"
        return f"{state}. {amount}. {origin}. Compartilhado pela organização; não somar por chave."


def openai_allowance(plan: str, *, standard_seats=0, premium_seats=0):
    """Documented full-period amount; NEVER an observed balance or issued grant."""
    if plan in {"pro-100", "pro-200", "pro-500"}:
        return int(plan.split("-")[1])
    if plan == "business":
        if any(type(n) is not int or n < 0 for n in (standard_seats, premium_seats)):
            raise ValueError("quantidade de assentos inválida")
        return min(500, 20 * standard_seats + 100 * premium_seats)
    return None
