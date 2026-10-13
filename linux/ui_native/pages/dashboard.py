from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton,
    QScrollArea, QStyle, QSizePolicy, QVBoxLayout, QWidget,
)

from ..catalog import DASHBOARD_QUICK, DASHBOARD_TOOLS
from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..operation_ledger import OperationLedger
from ..widgets import ActionCard, SectionHeader, themed_icon
from .base import BasePage

# Jornada de primeiro uso: dois passos concretos, cada um uma ação real do
# catálogo (nada de navegação inventada). IDs ausentes simplesmente somem.
# UX-006: nenhum passo exige IA — quem nunca vai usar assistente conclui o
# primeiro uso inteiro. IA continua disponível como objetivo, por escolha.
ONBOARDING_STEPS: tuple[tuple[str, str, str], ...] = (
    ("1", "Diagnosticar o sistema",
     "Uma checagem rápida diz o que já está bom e o que precisa de atenção."),
    ("2", "Preparar este computador",
     "Aplica a base segura do sistema: pacotes essenciais e ajustes conservadores."),
)

# PZ-AUD-029: objetivos em vez de taxonomias. Cinco jornadas, cada uma com
# UMA ação de entrada real do catálogo mais requisito, custo e maturidade.
# Detalhes técnicos continuam nas páginas de cada área (revelação progressiva).
# UX-006: cada objetivo leva ao lugar onde ele acontece. Objetivos com
# jornada própria (``destination``) abrem a página e caem na etapa de
# entrada; os demais executam a ação real do catálogo. Nenhum objetivo
# depende de IA — ela é uma escolha entre as outras.
JOURNEYS: tuple[tuple[str, str, str, str, str, str, str, str], ...] = (
    # key, title, entry action id, requirement, cost, maturity,
    # destination category, journey focus
    ("use", "Preparar este computador",
     "profile.safe-base",
     "Arch/derivada + bridge admin (configurada após instalar)",
     "pacotes do sistema",
     "perfil base", "", ""),
    ("host", "Hospedar serviços em casa",
     "profile.homelab",
     "Docker instalado pelo preparo; orçamento verificado antes",
     "~1 GiB de RAM base + apps",
     "receitas por app", "Homelab", "install"),
    ("manage", "Cuidar de outro computador",
     "homelab.hosts",
     "SSH + pareamento com a chave do admin",
     "sem custo nesta máquina",
     "ponte remota", "Homelab", "pair"),
    ("windows", "Instalar e usar Windows",
     "windows.provision.player",
     "ISO do Windows + espaço em disco; bridge admin para o boot",
     "download da ISO + imagem da VM",
     "instalação assistida", "Windows VM", "install"),
    ("ai", "IA e desenvolvimento",
     "profile.dev-ai",
     "toolchain via perfil; logins dos provedores quando pedir",
     "modelos sob demanda",
     "núcleo + proxies", "", ""),
    # LUX-013: o card executa só o perfil de jogos; Android e Windows têm
    # páginas e objetivos próprios, então não são prometidos aqui.
    ("play", "Jogos e emulação",
     "profile.gaming",
     "drivers/Steam conforme a página de cada área",
     "downloads por área",
     "catálogo por área", "", ""),
)

_STEP_HINTS = {number: hint for number, _t, hint in ONBOARDING_STEPS}
ONBOARDING_ACTIONS = {"1": "system.doctor.system", "2": "profile.safe-base"}


def _hint_for(number: str) -> str:
    return _STEP_HINTS.get(number, "")


class DashboardPage(BasePage):
    """Welcome screen with hero cards + tool grid."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.dashboard_cards: list[ActionCard] = []
        self._grids: list[tuple[QGridLayout, list[ActionCard], int]] = []
        try:
            # The ledger lives in the state dir, like every other caller.
            # Passing the repo root made every start look like a first use,
            # so "retomar" never had anything to offer.
            records = OperationLedger().records(limit=50)
        except Exception:
            records = []
        # LUX-014: leituras e previews não são "a última tarefa". Registros
        # antigos sem os campos contam como tarefa real.
        recent = [
            record for record in records
            if record.get("preview") is not True and record.get("mutable") is not False
        ][:1]
        self.first_use = not recent
        self._recent = recent[0] if recent else {}

    def build(self) -> None:
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        host = QWidget()
        host_layout = QVBoxLayout(host)
        host_layout.setContentsMargins(2, 2, 8, 8)
        host_layout.setSpacing(14)

        # LUX-032: sem emoji no título — leitores de tela o anunciavam.
        if self.first_use:
            welcome = QLabel("Vamos configurar seu computador")
        else:
            welcome = QLabel("Bem-vindo de volta ao PhaseZero")
        welcome.setObjectName("welcomeTitle")
        welcome.setWordWrap(True)
        host_layout.addWidget(welcome)
        subtitle = QLabel("Escaneie, escolha um card e execute — sem decorar caminhos de menu.")
        subtitle.setObjectName("welcomeSubtitle")
        subtitle.setWordWrap(True)
        host_layout.addWidget(subtitle)

        if self.first_use:
            onboarding = self._build_onboarding()
            if onboarding is not None:
                host_layout.addWidget(onboarding)
        else:
            resume = self._build_resume()
            if resume is not None:
                host_layout.addWidget(resume)

        journeys = self._build_journeys()
        if journeys is not None:
            host_layout.addWidget(SectionHeader("Comece por um objetivo", "Uma operação prepara e usa."))
            host_layout.addWidget(journeys)

        # LUX-013: no primeiro uso, só os passos e os objetivos. Atalhos
        # aparecem depois que o primeiro trabalho foi feito.
        if not self.first_use:
            host_layout.addWidget(SectionHeader("Ações rápidas", "As tarefas mais comuns, em destaque."))
            host_layout.addWidget(self._make_grid(DASHBOARD_QUICK, hero=True, columns=2))

            host_layout.addWidget(SectionHeader("Ferramentas & utilidades", "Atalhos para status e reparos."))
            host_layout.addWidget(self._make_grid(DASHBOARD_TOOLS, hero=False, columns=3))
        host_layout.addStretch()

        scroll.setWidget(host)
        self._layout.addWidget(scroll)

    def _build_onboarding(self) -> QWidget | None:
        """Faixa 'Comece por aqui' — 3 passos, só com ações que existem."""
        steps: list[tuple[str, str, ActionSpec]] = []
        for number, title, _hint in ONBOARDING_STEPS:
            action_id = ONBOARDING_ACTIONS.get(number, "")
            action = self.by_id.get(action_id)
            if action is not None:
                steps.append((number, title, action))
        if len(steps) < 2:
            return None
        card = QFrame()
        card.setObjectName("healthHero")
        # Faixa precisa encolher em viewports estreitos: sem largura mínima
        # herdada de texto longo (labels têm wrap; política Ignored horizontal).
        policy = card.sizePolicy()
        policy.setHorizontalPolicy(QSizePolicy.Policy.Ignored)
        card.setSizePolicy(policy)
        card.setMinimumWidth(0)
        column = QVBoxLayout(card)
        column.setContentsMargins(20, 16, 20, 16)
        column.setSpacing(8)
        heading = QLabel("Comece por aqui")
        heading.setObjectName("serviceTitle")
        column.addWidget(heading)
        for number, title, action in steps:
            row = QHBoxLayout()
            badge = QLabel(number)
            badge.setObjectName("healthShield")
            badge.setAlignment(Qt.AlignCenter)
            badge.setFixedSize(30, 30)
            text = QVBoxLayout()
            label = QLabel(title)
            label.setObjectName("serviceTitle")
            label.setWordWrap(True)
            label.setMinimumWidth(0)
            hint = QLabel(_hint_for(number))
            hint.setObjectName("cardDescription")
            hint.setWordWrap(True)
            hint.setMinimumWidth(0)
            text.addWidget(label)
            text.addWidget(hint)
            run = QPushButton("Executar")
            run.setObjectName("primaryButton")
            run.setAccessibleName(f"{title} — executar agora")
            run.clicked.connect(lambda _=False, a=action: self.request_action(a))
            row.addWidget(badge)
            row.addLayout(text, 1)
            row.addWidget(run)
            column.addLayout(row)
        return card

    def _build_resume(self) -> QWidget | None:
        """UX-006: retomar a tarefa recente, do lugar onde ela acontece.

        O ledger registra ciclo de vida (nunca comandos ou segredos). O que
        interessa aqui é onde a tarefa estava e como voltar para ela — não
        o identificador da operação.
        """
        record = self._recent
        title = str(record.get("title") or "")
        category = str(record.get("category") or "")
        # MainWindow falls back to Início for a category it cannot show, so
        # the card only needs both fields to be present.
        if not title or not category:
            return None
        status = str(record.get("status") or "")
        headline = {
            "succeeded": "Última tarefa concluída",
            "failed": "Última tarefa falhou",
            "interrupted": "Tarefa interrompida",
            "cancelled": "Última tarefa cancelada",
        }.get(status, "Tarefa em andamento")
        card = QFrame()
        card.setObjectName("healthHero")
        policy = card.sizePolicy()
        policy.setHorizontalPolicy(QSizePolicy.Policy.Ignored)
        card.setSizePolicy(policy)
        card.setMinimumWidth(0)
        row = QHBoxLayout(card)
        row.setContentsMargins(20, 16, 20, 16)
        copy = QVBoxLayout()
        heading = QLabel(headline)
        heading.setObjectName("serviceTitle")
        heading.setWordWrap(True)
        heading.setMinimumWidth(0)
        detail = QLabel(f"{title} · {category}")
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        detail.setMinimumWidth(0)
        copy.addWidget(heading)
        copy.addWidget(detail)
        row.addLayout(copy, 1)
        action = self.by_id.get(str(record.get("actionId") or ""))
        if status in {"failed", "cancelled"}:
            # LUX-014: falha oferece entender e repetir, não "retomar".
            details = QPushButton("Ver o que falhou")
            details.setObjectName("secondaryButton")
            details.setAccessibleName(f"Ver o que falhou em {title}")
            details.clicked.connect(lambda: self.request_category("Resultados"))
            row.addWidget(details)
            if action is not None:
                retry = QPushButton("Tentar de novo")
                retry.setObjectName("primaryButton")
                retry.setAccessibleName(f"Tentar de novo: {title}")
                retry.clicked.connect(lambda _=False, a=action: self.request_action(a))
                row.addWidget(retry)
        else:
            resume = QPushButton("Retomar")
            resume.setObjectName("primaryButton")
            resume.setAccessibleName(f"Retomar {title}")
            resume.clicked.connect(lambda _=False, c=category: self.request_category(c))
            row.addWidget(resume)
        self.resume_card = card
        return card

    def _build_journeys(self) -> QWidget | None:
        """Faixa de objetivos — PZ-AUD-029. Só ações que existem."""
        rows: list[tuple[ActionSpec, str, str, str, str, str, str]] = []
        for _key, title, action_id, requirement, cost, maturity, dest, focus in JOURNEYS:
            action = self.by_id.get(action_id)
            if action is None:
                continue
            # LUX-013: não repetir o que a faixa "Comece por aqui" já oferece.
            if self.first_use and action_id in ONBOARDING_ACTIONS.values():
                continue
            rows.append((action, title, requirement, cost, maturity, dest, focus))
        if not rows:
            return None
        self.journey_cards: list[QWidget] = []
        holder = QWidget()
        grid = QGridLayout(holder)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, (action, title, requirement, cost, maturity, dest, focus) in enumerate(rows):
            card = QFrame()
            card.setObjectName("journeyCard")
            # Same reflow contract as ActionCard: narrow viewports collapse
            # to one column instead of growing a horizontal scrollbar.
            card.setMinimumWidth(272)
            column = QVBoxLayout(card)
            head = QLabel(title)
            head.setObjectName("serviceTitle")
            head.setWordWrap(True)
            column.addWidget(head)
            meta = QLabel(f"Precisa: {requirement}\nCusto: {cost}\nMaturidade: {maturity}")
            meta.setObjectName("cardDescription")
            meta.setWordWrap(True)
            meta.setMinimumWidth(0)
            column.addWidget(meta)
            if dest:
                run = QPushButton("Abrir jornada")
                run.setAccessibleName(f"{title} — abrir jornada")
                run.setToolTip(f"Vai para {dest} e começa na etapa certa.")
                run.clicked.connect(
                    lambda _=False, d=dest, f=focus: self.request_category(d, f)
                )
            else:
                run = QPushButton("Preparar e usar")
                run.setAccessibleName(f"{title} — preparar e usar")
                run.clicked.connect(lambda _=False, a=action: self.request_action(a))
            run.setObjectName("primaryButton")
            column.addWidget(run)
            self.journey_cards.append(card)
            self.mark_represented(action)
            grid.addWidget(card, index // 2, index % 2)
        for column in range(2):
            grid.setColumnStretch(column, 1)
        cards: list = list(self.journey_cards)
        self._grids.append((grid, cards, 2))
        self._reflow_grid(grid, cards, 2, holder.width())
        return holder

    def _make_grid(self, ids: tuple[str, ...], *, hero: bool, columns: int) -> QWidget:
        holder = QWidget()
        grid = QGridLayout(holder)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index, action_id in enumerate(ids):
            action = self.by_id.get(action_id)
            if action is None:
                continue
            card = ActionCard(action, hero=hero)
            card.requested.connect(self.request_action)
            self.dashboard_cards.append(card)
            grid.addWidget(card, index // columns, index % columns)
        for column in range(columns):
            grid.setColumnStretch(column, 1)
        cards = [grid.itemAt(index).widget() for index in range(grid.count())]
        self._grids.append((grid, cards, columns))
        self._reflow_grid(grid, self._grids[-1][1], columns, holder.width())
        return holder

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self._reflow_for_width(event.size().width())

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._reflow_for_width(self.width())

    def _reflow_for_width(self, width: int) -> None:
        for grid, cards, max_columns in self._grids:
            self._reflow_grid(grid, cards, max_columns, width)

    @staticmethod
    def _reflow_grid(
        grid: QGridLayout,
        cards: list[ActionCard],
        max_columns: int,
        width: int,
    ) -> None:
        """Use only as many columns as fit without a horizontal scrollbar."""
        card_width = max(card.minimumWidth() for card in cards) if cards else 1
        columns = max(
            1,
            min(
                max_columns,
                (max(0, width) + grid.horizontalSpacing())
                // (card_width + grid.horizontalSpacing()),
            ),
        )
        while grid.count():
            grid.takeAt(0)
        for index, card in enumerate(cards):
            grid.addWidget(card, index // columns, index % columns)
        for column in range(max_columns):
            grid.setColumnStretch(column, 1 if column < columns else 0)
            grid.setColumnMinimumWidth(column, 0)

    def block_while_running(self, running: bool) -> None:
        for card in self.dashboard_cards:
            card.setEnabled(not running)
