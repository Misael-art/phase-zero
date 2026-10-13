from __future__ import annotations

import json
import os
from pathlib import Path

from PySide6.QtCore import QProcess, Qt, QTimer
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
    QHeaderView, QInputDialog, QLabel, QLineEdit, QMessageBox, QPlainTextEdit,
    QProgressBar, QPushButton, QScrollArea, QTableWidget, QTableWidgetItem,
    QVBoxLayout, QWidget,
)
from shiboken6 import isValid

from .base import BasePage
from ..journey import (
    CONFIGURE_ACCESS, NOT_INSTALLED, PREPARING, READY,
    app_journey, failure_banner_text, first_use_steps, journey_action_label,
    journey_headline, open_url, plan_is_simulation, plan_simulation_refusal,
    plan_summary, profile_simulation_note, split_profiles,
)
from ..platform import state_dir

CMD_TIMEOUT_MS = 30 * 60 * 1000


class HomelabPage(BasePage):
    """Homelab Player: live stack status, profile slot, governor budget and
    one-click plan/up/down/backup/verify/restore backed by linux/pz.

    All external commands run through QProcess (never blocking subprocess in the
    GUI thread). ``_spawn_cmd`` is used for the status poll and short queries;
    ``run_cmd`` owns user-initiated actions with separated stdout/stderr,
    timeout and double-emit protection. The restore path never passes ``--yes``
    automatically; it asks the operator inside the Player instead.
    """

    def __init__(
        self,
        root,
        runner,
        actions,
        by_id=None,
        parent=None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self._green = QLabel("●")
        self._green.setObjectName("serviceState")
        self._proc: QProcess | None = None
        self._profile_map: dict[str, str] = {}
        self._last_status: dict = {}
        self._timeouts: dict[int, QTimer] = {}
        self._action_buttons: list[QPushButton] = []
        self._card_buttons: list[QPushButton] = []
        self._pending_confirm_file: Path | None = None
        self._cards_layout: QGridLayout | None = None
        self._cards_host: QWidget | None = None
        self._hosts: dict[str, dict] = {}
        self._host_combo: QComboBox | None = None
        self._host_badge: QLabel | None = None
        self._pair_btn: QPushButton | None = None
        self._dash_btn: QPushButton | None = None
        self._onboard_step = 0
        self._onboard_confirmed = False
        self._onboard_state: dict = {}
        self._pair_advance = False
        self._pair_host = ""
        self._onboard_label: QLabel | None = None
        self._plan_summary: QLabel | None = None
        self._onboard_next: QPushButton | None = None
        # UX-005: simple mode installs; simulating a budget is opt-in.
        self._profiles_all: list = []
        self._simulate_check: QCheckBox | None = None
        self._profile_note: QLabel | None = None
        # UX-007: failures are recovered from the interface, not from the log.
        self._error_banner: QLabel | None = None
        self._error_retry: QPushButton | None = None
        self._last_cmd: tuple[list[str], str | None] | None = None
        # UX-009: apps carry a journey; first access is remembered per app.
        self._apps: list = []
        self._card_advanced: list = []
        self._first_access: set[str] = self._load_first_access()
        # UX-003: reflow state; built widgets arrive in build().
        self._narrow_layout: bool | None = None
        self._header_grid: QGridLayout | None = None
        self._profile_grid: QGridLayout | None = None
        self._actions_grid: QGridLayout | None = None

    # ------------------------------------------------------------- theming
    def resizeEvent(self, event) -> None:  # noqa: N802 (Qt override)
        super().resizeEvent(event)
        if self._header_grid is None:
            return
        self._apply_reflow(self.width() < 1000)

    def _apply_reflow(self, narrow: bool) -> None:
        if narrow == self._narrow_layout:
            return
        self._narrow_layout = narrow
        self._reflow_header(narrow)
        self._reflow_profile(narrow)
        self._reflow_actions(narrow)

    def _reflow_header(self, narrow: bool) -> None:
        g = self._header_grid
        if g is None:
            return
        if narrow:
            # two rows: status + refresh on top, host controls below
            g.addWidget(self._state_label, 0, 1)
            g.addWidget(self._green, 0, 2)
            g.addWidget(self.refresh_header_btn, 0, 3)
            g.addWidget(self._host_caption, 1, 0)
            g.addWidget(self._host_combo, 1, 1)
            g.addWidget(self._host_badge, 1, 2)
            g.addWidget(self._pair_btn, 1, 3)
            g.addWidget(self._dash_btn, 1, 4)
            g.setColumnStretch(0, 1)
            g.setColumnStretch(5, 1)
        else:
            g.addWidget(self._state_label, 0, 7)
            g.addWidget(self._green, 0, 8)
            g.addWidget(self.refresh_header_btn, 0, 9)
            g.addWidget(self._host_caption, 0, 1)
            g.addWidget(self._host_combo, 0, 2)
            g.addWidget(self._host_badge, 0, 3)
            g.addWidget(self._pair_btn, 0, 4)
            g.addWidget(self._dash_btn, 0, 5)
            g.setColumnStretch(6, 1)
            g.setColumnStretch(0, 0)

    def _reflow_profile(self, narrow: bool) -> None:
        g = self._profile_grid
        if g is None:
            return
        if narrow:
            g.addWidget(self._profile_caption, 0, 0)
            g.addWidget(self._profile_combo, 0, 1, 1, 3)
            g.addWidget(self._profile_set, 1, 0)
            g.addWidget(self._budget_caption, 1, 1)
            g.addWidget(self._budget_label, 1, 2)
            g.addWidget(self._policy_btn, 1, 3)
            g.setColumnStretch(1, 1)
            g.setColumnStretch(3, 1)
        else:
            g.addWidget(self._profile_caption, 0, 0)
            g.addWidget(self._profile_combo, 0, 1)
            g.addWidget(self._profile_set, 0, 2)
            g.addWidget(self._budget_caption, 0, 3)
            g.addWidget(self._budget_label, 0, 4)
            g.addWidget(self._policy_btn, 0, 5)
            g.setColumnStretch(1, 1)
            g.setColumnStretch(4, 0)

    def _reflow_actions(self, narrow: bool) -> None:
        g = self._actions_grid
        if g is None:
            return
        for index, btn in enumerate(self._action_buttons):
            if narrow:
                g.addWidget(btn, index // 3, index % 3)
            else:
                g.addWidget(btn, 0, index)

    def _set_state(self, state: str) -> None:
        """Cor via tema (objectName+property), nunca stylesheet cru."""
        for label in (self._state_label, self._green):
            label.setProperty("state", state)
            label.style().unpolish(label)
            label.style().polish(label)

    def build(self) -> None:
        # UX-003: the whole page lives in a vertical scroll area — at
        # 1280x800 and 800x600 every control stays reachable by scrolling;
        # no group is compressed and no horizontal scroll is needed.
        self._page_scroll = QScrollArea()
        self._page_scroll.setWidgetResizable(True)
        self._page_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self._page_scroll.setFrameShape(QFrame.NoFrame)
        self._page_scroll.setAccessibleName("Conteúdo do Homelab")
        page_host = QWidget()
        page_host.setObjectName("homelabPageHost")
        lay = QVBoxLayout(page_host)
        lay.setSpacing(12)
        self._layout.addSpacing(8)
        self._layout.addWidget(self._page_scroll, 1)
        self._layout = lay
        self._page_scroll.setWidget(page_host)

        # UX-003: header, profile and actions live in reflowable grids —
        # on narrow windows the rows wrap instead of dictating a minimum
        # width that would clip controls at 800x600 with the real theme.
        self._header_grid = QGridLayout()
        self._header_grid.setContentsMargins(0, 0, 0, 0)
        self._header_grid.setHorizontalSpacing(8)
        title = QLabel("Homelab Player")
        title.setStyleSheet("font-size:17px;font-weight:700")
        self._header_grid.addWidget(title, 0, 0)
        host_caption = QLabel("Host:")
        self._host_caption = host_caption
        self._host_combo = QComboBox()
        self._host_combo.setAccessibleName("Host Homelab")
        self._host_combo.addItem("Este computador (local)", "")
        host_caption.setBuddy(self._host_combo)
        self._host_badge = QLabel("Local")
        self._host_badge.setObjectName("serviceState")
        self._host_badge.setProperty("state", "success")
        self._pair_btn = QPushButton("Parear")
        self._pair_btn.setToolTip("Copia a chave SSH sem colocar senha na linha de comando.")
        self._pair_btn.setEnabled(False)
        self._pair_btn.clicked.connect(self.start_pair)
        self._dash_btn = QPushButton("Abrir dashboard")
        self._dash_btn.setToolTip("Abre o dashboard HTTPS do host Homelab selecionado.")
        self._dash_btn.setAccessibleName("Abrir dashboard")
        self._dash_btn.clicked.connect(self.open_dashboard)
        self._state_label = QLabel("—")
        self._state_label.setObjectName("serviceState")
        self._green = QLabel("●")
        self._green.setObjectName("serviceState")
        refresh = QPushButton("Atualizar")
        refresh.setAccessibleName("Atualizar status do Homelab")
        refresh.clicked.connect(self.refresh_status)
        self.refresh_header_btn = refresh
        self._reflow_header(bool(self._narrow_layout))
        self._host_combo.currentIndexChanged.connect(self._on_host_changed)
        lay.addLayout(self._header_grid)

        # UX-007: one visible place for the cause of a failure and the way
        # out of it. The log stays available, but it is never the only copy
        # of what went wrong.
        self._error_frame = QFrame()
        self._error_frame.setObjectName("homelabFailureBanner")
        err_lay = QHBoxLayout(self._error_frame)
        err_lay.setContentsMargins(8, 6, 8, 6)
        self._error_banner = QLabel("")
        self._error_banner.setObjectName("serviceState")
        self._error_banner.setProperty("state", "error")
        self._error_banner.setWordWrap(True)
        self._error_banner.setAccessibleName("Motivo da falha")
        self._error_retry = QPushButton("Tentar de novo")
        self._error_retry.setAccessibleName("Tentar de novo")
        self._error_retry.clicked.connect(self._retry_last_cmd)
        err_lay.addWidget(self._error_banner, 1)
        err_lay.addWidget(self._error_retry)
        self._error_frame.setVisible(False)
        lay.addWidget(self._error_frame)

        onboard = QGroupBox("Primeiros passos")
        onboard.setAccessibleName("Onboarding do Homelab")
        o_lay = QHBoxLayout()
        self._onboard_label = QLabel(self._onboard_prompt())
        self._onboard_label.setWordWrap(True)
        start = QPushButton("Começar")
        start.setAccessibleName("Começar onboarding")
        start.clicked.connect(self.start_onboarding)
        # UX-001: the review step has an explicit, reachable confirmation —
        # the state machine's onboard_confirm_review() is wired to a real
        # control instead of existing only for tests.
        self._onboard_confirm = QPushButton("Confirmar revisão")
        self._onboard_confirm.setAccessibleName("Confirmar revisão do Homelab")
        self._onboard_confirm.setToolTip("Aceita a política mostrada e libera a instalação.")
        self._onboard_confirm.clicked.connect(self._confirm_review_clicked)
        self._onboard_confirm.setVisible(False)
        self._onboard_next = QPushButton("Avançar")
        self._onboard_next.setAccessibleName("Avançar onboarding")
        self._onboard_next.clicked.connect(self.onboard_advance)
        o_lay.addWidget(self._onboard_label, 1)
        o_lay.addWidget(start)
        o_lay.addWidget(self._onboard_confirm)
        o_lay.addWidget(self._onboard_next)
        onboard_box = QVBoxLayout()
        onboard_box.addLayout(o_lay)
        # UX-007: the reviewed plan is stated in the interface, in product
        # language. The JSON document stays in Saída for the advanced view;
        # reading it is never required to know what will happen.
        self._plan_summary = QLabel("")
        self._plan_summary.setObjectName("homelabPlanSummary")
        self._plan_summary.setWordWrap(True)
        self._plan_summary.setAccessibleName("Resumo do plano")
        self._plan_summary.setVisible(False)
        onboard_box.addWidget(self._plan_summary)
        onboard.setLayout(onboard_box)
        lay.addWidget(onboard)

        # App cards (one-click catalog) ------------------------------------
        cards_box = QGroupBox("Aplicativos")
        cards_box.setAccessibleName("Catálogo de aplicativos do Homelab")
        cards_outer = QVBoxLayout()
        self._cards_scroll = QScrollArea()
        self._cards_scroll.setWidgetResizable(True)
        self._cards_host = QWidget()
        self._cards_layout = QGridLayout(self._cards_host)
        self._cards_layout.setContentsMargins(4, 4, 4, 4)
        self._cards_scroll.setWidget(self._cards_host)
        self._cards_scroll.setMinimumHeight(200)
        cards_outer.addWidget(self._cards_scroll)
        cards_box.setLayout(cards_outer)
        lay.addWidget(cards_box)

        # Status table ------------------------------------------------------
        self._table = QTableWidget(0, 5)
        self._table.setHorizontalHeaderLabels(["Serviço", "Camada", "Endereço", "URL", "Rodando"])
        self._table.setAccessibleName("Serviços do Homelab")
        header_view = self._table.horizontalHeader()
        header_view.setSectionResizeMode(QHeaderView.ResizeToContents)
        self._table.setEditTriggers(QTableWidget.NoEditTriggers)
        self._table.setSelectionMode(QTableWidget.SingleSelection)
        self._table.setSelectionBehavior(QTableWidget.SelectRows)
        self._table.setAlternatingRowColors(True)
        self._table.verticalHeader().setVisible(False)
        self._table.setMinimumHeight(140)
        lay.addWidget(self._table, 1)

        # Profile + governor ------------------------------------------------
        profile_box = QGroupBox("Perfil e orçamento")
        profile_outer = QVBoxLayout()
        self._profile_grid = QGridLayout()
        self._profile_grid.setContentsMargins(0, 0, 0, 0)
        self._profile_grid.setHorizontalSpacing(8)
        self._profile_combo = QComboBox()
        # UX-011: o rótulo "Perfil:" é buddy, não nome acessível — sem isto o
        # leitor de tela anuncia só o valor atual, sem dizer do que se trata.
        self._profile_combo.setAccessibleName("Perfil do Homelab")
        self._budget_label = QLabel("—")
        profile_caption = QLabel("Perfil:")
        self._profile_caption = profile_caption
        profile_caption.setBuddy(self._profile_combo)
        self._profile_grid.addWidget(profile_caption, 0, 0)
        self._profile_grid.addWidget(self._profile_combo, 0, 1)
        self._profile_set = QPushButton("Aplicar perfil")
        self._profile_set.clicked.connect(self.apply_profile)
        self._profile_grid.addWidget(self._profile_set, 0, 2)
        budget_caption = QLabel("Orçamento:")
        self._budget_caption = budget_caption
        budget_caption.setBuddy(self._budget_label)
        self._profile_grid.addWidget(budget_caption, 0, 3)
        self._profile_grid.addWidget(self._budget_label, 0, 4)
        policy = QPushButton("Política")
        self._policy_btn = policy
        policy.clicked.connect(self.show_policy)
        self._profile_grid.addWidget(policy, 0, 5)
        profile_outer.addLayout(self._profile_grid)
        # UX-005: installing and simulating a budget are different jobs.
        # Simple mode offers only profiles that install something; the
        # budget-only ones appear when the operator asks for a simulation.
        self._simulate_check = QCheckBox("Simular recursos (avançado)")
        self._simulate_check.setAccessibleName("Simular recursos")
        self._simulate_check.setToolTip(
            "Mostra perfis que apenas reservam orçamento, sem instalar soluções."
        )
        self._simulate_check.toggled.connect(self._on_simulate_toggled)
        profile_outer.addWidget(self._simulate_check)
        self._profile_note = QLabel("")
        self._profile_note.setObjectName("serviceState")
        self._profile_note.setProperty("state", "warning")
        self._profile_note.setWordWrap(True)
        self._profile_note.setAccessibleName("Aviso do perfil")
        self._profile_note.setVisible(False)
        profile_outer.addWidget(self._profile_note)
        self._profile_combo.currentIndexChanged.connect(self._refresh_profile_note)
        profile_box.setLayout(profile_outer)
        lay.addWidget(profile_box)
        self._reflow_profile(bool(self._narrow_layout))

        # Actions -----------------------------------------------------------
        actions_box = QGroupBox("Ações")
        self._actions_grid = QGridLayout()
        self._actions_grid.setContentsMargins(0, 0, 0, 0)
        for label, fn in (
            ("Planejar", lambda: self.run_cmd(["plan"])),
            ("Copiar segurança", lambda: self.run_cmd(["backup"])),
            ("Conferir backup", lambda: self.run_cmd(["backup", "verify", "--source", self._last_backup()])),
            ("Restaurar", self.pick_restore),
            ("Reparar", lambda: self.run_cmd(["repair"])),
            ("Subir", lambda: self.run_cmd(["up"])),
        ):
            btn = QPushButton(label)
            btn.setToolTip(
                {
                    "Planejar": "Mostra o plano de implantação sem alterar nada.",
                    "Copiar segurança": "Gera backup verificado dos volumes.",
                    "Conferir backup": "Valida o último backup (checksums e manifesto).",
                    "Restaurar": "Fluxo assistido: prévia, confirmação digitada e rollback.",
                    "Reparar": "Prepara/repara a configuração do Homelab.",
                    "Subir": "Liga os serviços; dados preservados.",
                }.get(label, "")
            )
            btn.clicked.connect(fn)
            self._action_buttons.append(btn)
            self._actions_grid.addWidget(btn, 0, len(self._action_buttons) - 1)
        actions_box.setLayout(self._actions_grid)
        lay.addWidget(actions_box)
        self._reflow_actions(bool(self._narrow_layout))

        # Output ------------------------------------------------------------
        out_group = QGroupBox("Saída")
        out_layout = QVBoxLayout(out_group)
        self._output = QPlainTextEdit()
        self._output.setReadOnly(True)
        self._output.setMaximumBlockCount(4000)
        self._output.setStyleSheet("font-family:monospace;font-size:12px")
        out_layout.addWidget(self._output)
        self._bar = QProgressBar()
        self._bar.setRange(0, 0)
        self._bar.hide()
        out_layout.addWidget(self._bar)
        self._output.setMinimumHeight(160)
        lay.addWidget(out_group, 1)
        lay.addStretch(0)

        QTimer.singleShot(0, self.refresh_hosts)

    # -- data ---------------------------------------------------------------
    def _setup_proc(self, proc: QProcess) -> None:
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.setInterval(CMD_TIMEOUT_MS)
        timer.timeout.connect(lambda: self._kill_timed_out(proc))
        self._timeouts[id(proc)] = timer
        timer.start()

    def _cancel_timeout(self, proc: QProcess) -> None:
        timer = self._timeouts.pop(id(proc), None)
        if timer is not None:
            timer.stop()

    def _kill_timed_out(self, proc: QProcess) -> None:
        self._cancel_timeout(proc)
        if proc.state() != QProcess.NotRunning:
            proc.kill()
        if self._proc is proc:
            self._proc = None
        self._state_label.setText("comando excedeu o tempo (processo terminado)")

    def _spawn(self, args: list[str], on_done) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        proc = QProcess(self)
        self._setup_proc(proc)

        def on_finished(code: int) -> None:
            self._cancel_timeout(proc)
            if not isValid(proc):
                if self._proc is proc:
                    self._proc = None
                return
            on_done(
                code,
                bytes(proc.readAllStandardOutput()),
                bytes(proc.readAllStandardError()),
            )

        proc.finished.connect(on_finished)
        proc.start(str(self.root / "linux" / "pz"), args)
        self._proc = proc

    def _selected_host(self) -> str:
        if self._host_combo is None:
            return ""
        data = self._host_combo.currentData()
        return str(data) if data else ""

    def dashboard_url(self) -> str:
        """HTTPS URL of the appliance dashboard for the selected host."""
        alias = self._selected_host()
        if alias:
            rec = self._hosts.get(alias) or {}
            host = str(rec.get("host") or "127.0.0.1")
            port = int(rec.get("webPort") or 17443)
            return f"https://{host}:{port}/"
        return "https://127.0.0.1:17443/"

    def open_dashboard(self) -> None:
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices

        QDesktopServices.openUrl(QUrl(self.dashboard_url()))

    ONBOARD_STEPS = ("discover", "pair", "profile", "review", "apply")

    def onboard_step_name(self) -> str:
        steps = self.ONBOARD_STEPS
        idx = min(max(self._onboard_step, 0), len(steps) - 1)
        return steps[idx]

    def _onboard_prompt(self) -> str:
        name = self.onboard_step_name()
        # UX-007: each step says what the operator gets, in product language.
        # Technical vocabulary (argv, bind, dry-run) lives in tooltips and in
        # the advanced surfaces, never as the only description of the step.
        copy = {
            "discover": "Passo 1 de 5 — Encontrar o servidor onde suas soluções vão rodar.",
            "pair": "Passo 2 de 5 — Autorizar este computador a administrar o servidor.",
            "profile": "Passo 3 de 5 — Escolher o perfil que cabe na memória disponível.",
            "review": "Passo 4 de 5 — Conferir o que será feito e como o acesso fica protegido.",
            "apply": "Passo 5 de 5 — Preparar o servidor. Depois, instale suas soluções abaixo.",
        }
        return copy[name]

    def _confirm_review_clicked(self) -> None:
        # UX-001: production path for the review confirmation.
        self.onboard_confirm_review()
        self._refresh_onboard_label()

    def _refresh_onboard_label(self) -> None:
        if self._onboard_label is not None:
            text = self._onboard_prompt()
            if self.onboard_step_name() == "review" and self._onboard_confirmed:
                text = "Revisão confirmada — Avançar gera o plano para instalação."
            self._onboard_label.setText(text)
        # UX-001: the confirm control exists only while the review step is
        # unconfirmed; after confirmation Avançar is the single next action.
        if self._onboard_confirm is not None:
            visible = self.onboard_step_name() == "review" and not self._onboard_confirmed
            self._onboard_confirm.setVisible(visible)
            self._onboard_confirm.setEnabled(visible)

    def focus_journey(self, key: str) -> None:
        """UX-006: arriving from a goal card lands on that goal's step.

        "install" starts the guided flow from the beginning; "pair" jumps
        to the step that authorizes this computer to run another machine,
        which is the goal 'cuidar de outro computador' actually means.
        """
        if key == "pair":
            self._onboard_step = self.ONBOARD_STEPS.index("pair")
            self._onboard_confirmed = False
            self._refresh_onboard_label()
            if self._host_combo is not None:
                self._host_combo.setFocus()
            self._state_label.setText(
                "Escolha o computador remoto e pareie para administrá-lo daqui"
            )
        elif key == "install":
            self.start_onboarding()

    def start_onboarding(self) -> None:
        self._onboard_step = 0
        self._onboard_confirmed = False
        self._onboard_state = {}
        self._refresh_onboard_label()

    def onboard_ingest_discover(self, payload: dict) -> None:
        self._onboard_state["discover"] = payload if isinstance(payload, dict) else {}

    def onboard_ingest_pair(self, ok: bool, detail: dict | None = None) -> None:
        self._onboard_state["pair"] = bool(ok)
        if detail is not None:
            self._onboard_state["pair_detail"] = detail

    def onboard_confirm_review(self) -> None:
        self._onboard_confirmed = True
        self._onboard_state["review"] = {
            "lanBind": False,
            "upnp": False,
            "external": "tailscale",
        }

    def onboard_review_text(self) -> str:
        return (
            "Bind padrão 127.0.0.1. Sem UPnP. Acesso externo só via Tailscale. "
            "SMART/rede/disco ausentes aparecem como indisponível."
        )

    def onboard_advance(self) -> None:
        # PZ-AUD-013: every step executes something real. Nothing advances
        # on placeholders: discover runs agent discovery, pair needs a real
        # pairing result (or an explicit local host), profile records the
        # actual selection, review needs confirmation, apply needs a plan.
        current = self.onboard_step_name()
        if current == "discover" and "discover" not in self._onboard_state:
            self._run_discover()
            return
        elif current == "pair":
            # REV-005: only a real pairing success for THIS host advances.
            # pair=false / cancel / offline keep the operator on the step
            # with an actionable error; nothing auto-advances.
            pair_detail = self._onboard_state.get("pair_detail") or {}
            if pair_detail.get("local") is True:
                paired_for = ""
            else:
                paired_for = str(pair_detail.get("alias") or "")
            if self._onboard_state.get("pair") is not True \
                    or paired_for != self._selected_host():
                alias = self._selected_host()
                if not alias:
                    self.onboard_ingest_pair(True, {"local": True})
                else:
                    self._pair_advance = True
                    self.start_pair()
                    return
        elif current == "profile":
            combo = self._profile_combo
            self._onboard_state["profile"] = {
                "profile": combo.currentData() if combo is not None else "",
            }
        elif current == "review" and not self._onboard_confirmed:
            return
        elif current == "apply":
            self.onboard_apply()
            return
        if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
            self._onboard_step += 1
        self._refresh_onboard_label()

    def _run_discover(self) -> None:
        self._state_label.setText("Descobrindo Homelab…")
        self._spawn(["server", "homelab", "agent", "discover", "--json"], self._on_discover_done)

    def _first_json_document(self, text: str) -> dict:
        decoder = json.JSONDecoder()
        for idx, ch in enumerate(text):
            if ch != "{":
                continue
            try:
                doc, _end = decoder.raw_decode(text, idx)
            except ValueError:
                continue
            if isinstance(doc, dict):
                return doc
        return {}

    def _parse_json_payload(self, raw: bytes) -> dict:
        """REV-004: one document parser for every Player command output.

        Accepts pretty or compact JSON anywhere in stdout (``jq -n`` emits
        multiline documents) instead of parsing line by line, and unwraps
        the remote-host envelope ``{hostAlias, rc, payload, ...}`` produced
        by ``--host`` so callers see the inner payload plus the bound
        ``hostAlias``.
        """
        doc = self._first_json_document(raw.decode("utf-8", "replace"))
        payload = doc.get("payload")
        if isinstance(payload, dict) and isinstance(doc.get("hostAlias"), str):
            merged = dict(payload)
            merged["hostAlias"] = doc["hostAlias"]
            return merged
        return doc

    def _on_discover_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        if code == 0 and payload:
            self.onboard_ingest_discover(payload)
            self.refresh_hosts()
            if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
                self._onboard_step += 1
            self._refresh_onboard_label()
        else:
            detail = err.decode("utf-8", "replace").strip().splitlines()
            reason = detail[-1] if detail else f"exit {code}"
            self._state_label.setText(f"Descoberta falhou: {reason}")
        self._refresh_onboard_label()

    def onboard_apply(self) -> None:
        if not self._onboard_confirmed:
            return
        # PZ-AUD-002/013 + REV-006/007: apply is plan-then-execute, and the
        # plan is a typed document bound to the host and profile the
        # operator reviewed. The captured host — never the mutable combo —
        # is what execution may target.
        self._state_label.setText("Gerando plano…")
        profile = (self._onboard_state.get("profile") or {}).get("profile") or ""
        plan_args = ["prepare", "--dry-run", "--json"]
        if profile:
            plan_args += ["--profile", profile]
        self._onboard_state["plan_host"] = self._selected_host()
        self._onboard_state["plan_args"] = plan_args
        self._spawn(self._hl(*plan_args), self._on_apply_plan_done)

    def _on_apply_plan_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        if code != 0 or not payload:
            detail = err.decode("utf-8", "replace").strip().splitlines()
            reason = detail[-1] if detail else f"exit {code}"
            self._state_label.setText(f"Plano falhou: {reason}")
            return
        # REV-006: the plan must belong to the captured host. A late
        # callback generated for another target is dropped, and a host
        # switch while the plan ran invalidates the reviewed plan.
        captured_host = str(self._onboard_state.get("plan_host") or "")
        plan_host = str(payload.get("hostAlias") or payload.get("host") or "local")
        if plan_host != (captured_host or "local"):
            self._onboard_state.pop("review_plan", None)
            self._state_label.setText("Plano é de outro host — gere um novo plano para o host selecionado")
            return
        if self._selected_host() != captured_host:
            self._onboard_state.pop("review_plan", None)
            self._state_label.setText("Host mudou durante o plano — revise e gere um novo plano")
            return
        plan_hash = json.dumps(self._plan_intent(payload), sort_keys=True)
        previous = self._onboard_state.get("review_plan")
        if previous is None:
            self._onboard_state["review_plan"] = plan_hash
            self._render_onboard_plan(payload)
            self._state_label.setText("Plano pronto — revise acima e pressione Aplicar de novo para executar")
            return
        if previous != plan_hash:
            self._onboard_state["review_plan"] = plan_hash
            self._render_onboard_plan(payload)
            self._state_label.setText("Plano mudou — revise de novo e pressione Aplicar para executar")
            return
        # UX-002: intent is stable, but the observed budget may have crossed
        # a limit since the review — execution would fail downstream.
        budget = payload.get("budget") if isinstance(payload.get("budget"), dict) else {}
        if str(budget.get("verdict") or "") == "fail":
            self._state_label.setText(
                "Recursos insuficientes agora — libere memória/disco ou revise o plano"
            )
            return
        # UX-005: installing is not simulating. A budget-only profile has no
        # install recipe, so `prepare --profile X` would set the budget and
        # install the catalog defaults — answering a goal the operator never
        # chose. The choice is made explicit instead of assumed.
        if plan_is_simulation(payload):
            choice = self._ask_simulation_choice(payload)
            if choice == "simulate":
                self._onboard_state.pop("review_plan", None)
                self.run_cmd(["profile", "set", str(payload.get("profile") or "")],
                             host=captured_host)
                return
            if choice != "install-base":
                self._state_label.setText(
                    "Nada instalado — esta escolha só reserva recursos"
                )
                return
            self._onboard_state.pop("review_plan", None)
            # Explicitly the base server, without the profile that cannot
            # deliver its services.
            self.run_cmd(["prepare", "--json"], host=captured_host)
            return

        self._onboard_state.pop("review_plan", None)
        # REV-007: execute exactly the reviewed plan (same profile), not a
        # re-derivation from current widget state.
        exec_args = ["prepare", "--json"]
        profile = (self._onboard_state.get("profile") or {}).get("profile") or ""
        if profile:
            exec_args += ["--profile", profile]
        self.run_cmd(exec_args, host=captured_host)

    def _ask_simulation_choice(self, payload: dict) -> str:
        """Ask what a budget-only choice should actually do.

        Returns ``"simulate"`` (reserve the budget, install nothing),
        ``"install-base"`` (install the base server, without the profile)
        or ``"cancel"``.
        """
        apps = ", ".join(str(a) for a in (payload.get("apps") or []))
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Warning)
        box.setWindowTitle("Esta escolha não instala o que promete")
        box.setText(plan_simulation_refusal(payload))
        box.setInformativeText(
            f"Instalar a base do servidor traz os aplicativos padrão ({apps})."
            if apps else "Escolha o que fazer."
        )
        cancel = box.addButton("Cancelar", QMessageBox.RejectRole)
        simulate = box.addButton("Só reservar recursos", QMessageBox.AcceptRole)
        install = box.addButton("Instalar base do servidor", QMessageBox.AcceptRole)
        box.setDefaultButton(cancel)
        box.exec()
        clicked = box.clickedButton()
        if clicked is simulate:
            return "simulate"
        if clicked is install:
            return "install-base"
        return "cancel"

    @staticmethod
    def _plan_intent(payload: dict) -> dict:
        """UX-002: what a confirmation binds to is the reviewed INTENT —
        host, profile, apps, access, policy — not volatile telemetry.
        availableMB/diskAvailableMB drift by megabytes between renders; a
        1 MiB RAM change must never revoke the operator's review. Material
        changes (apps/host/profile/access) stay in the intent and still
        force a new review; a crossed resource limit is caught separately
        by the budget verdict at execution time."""
        return {k: v for k, v in payload.items() if k != "budget"}

    def _render_onboard_plan(self, payload: dict) -> None:
        # R01-003 + UX-007: what the plan does is shown in the interface,
        # in product language — including the fact that a budget-only
        # profile installs none of its services. The raw document follows
        # in Saída for whoever wants it.
        lines = plan_summary(payload)
        if self._plan_summary is not None:
            self._plan_summary.setText("\n".join(f"• {line}" for line in lines))
            self._plan_summary.setVisible(bool(lines))
        for line in lines:
            self._append(f"[plano] {line}\n")
        self._append(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")

    def _hl_for(self, alias: str, *parts: str) -> list[str]:
        args = ["server", "homelab"]
        if alias:
            args += ["--host", alias]
        args.extend(parts)
        return args

    def _hl(self, *parts: str) -> list[str]:
        return self._hl_for(self._selected_host(), *parts)

    def _on_host_changed(self) -> None:
        alias = self._selected_host()
        # REV-005/006: pairing and plan confirmation are bound to one host.
        # Switching the target invalidates them — an authorization made for
        # host A must never apply to host B. The flow rewinds to the pair
        # step so the new host is verified on its own.
        self._onboard_state.pop("review_plan", None)
        self._onboard_state.pop("plan_host", None)
        self._onboard_state.pop("plan_args", None)
        self._onboard_state.pop("pair", None)
        self._onboard_state.pop("pair_detail", None)
        self._onboard_confirmed = False
        # R01-002: an in-flight pairing belongs to the old host — its late
        # callback will be dropped by the captured-alias check; kill the
        # auto-advance and the captured alias right away.
        self._pair_advance = False
        self._pair_host = ""
        if self._onboard_step >= 1:
            self._onboard_step = 1
            self._refresh_onboard_label()
        if self._host_badge is not None:
            if alias:
                self._host_badge.setText("Remoto")
                self._host_badge.setProperty("state", "warning")
            else:
                self._host_badge.setText("Local")
                self._host_badge.setProperty("state", "success")
            self._host_badge.style().unpolish(self._host_badge)
            self._host_badge.style().polish(self._host_badge)
        if self._pair_btn is not None:
            self._pair_btn.setEnabled(bool(alias))
        if self._proc is None or self._proc.state() == QProcess.NotRunning:
            self.refresh_status()

    def refresh_hosts(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(["server", "homelab", "hosts", "list", "--json"], self._on_hosts_done)

    def _on_hosts_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        hosts = payload.get("hosts") if isinstance(payload.get("hosts"), list) else []
        current = self._selected_host()
        if self._host_combo is not None:
            self._host_combo.blockSignals(True)
            self._host_combo.clear()
            self._host_combo.addItem("Este computador (local)", "")
            self._hosts = {}
            for host in hosts:
                if not isinstance(host, dict):
                    continue
                alias = str(host.get("alias") or "")
                if not alias:
                    continue
                self._hosts[alias] = host
                label = f"{alias} ({host.get('user')}@{host.get('host')})"
                self._host_combo.addItem(label, alias)
            idx = self._host_combo.findData(current)
            self._host_combo.setCurrentIndex(idx if idx >= 0 else 0)
            self._host_combo.blockSignals(False)
        self.refresh_status()

    def start_pair(self, generate: bool = False, password: str = "") -> None:
        # PZ-AUD-014: pairing runs through `hosts pair`, which honors the
        # registry port and reuses or generates keys explicitly.
        # UX-008: when a password is supplied, the same command completes the
        # very first contact — no terminal, and the secret only ever travels
        # on stdin.
        alias = self._selected_host()
        if not alias:
            QMessageBox.information(self, "Parear", "Selecione um host remoto.")
            return
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        self._state_label.setText("Pareando chave SSH…")
        args = ["server", "homelab", "hosts", "pair", alias, "--json"]
        if generate:
            args.append("--generate")
        if password:
            # UX-008: the password goes in over stdin, never as an argument.
            args.append("--password-stdin")
        self._pair_host = alias
        proc = QProcess(self)
        self._setup_proc(proc)
        # R01-002: capture the alias the pairing was started for — the
        # combo selection may change while the process runs.
        proc.finished.connect(
            lambda code, p=proc, a=alias: self._on_pair_done(
                code, bytes(p.readAllStandardOutput()), bytes(p.readAllStandardError()), a
            )
        )
        proc.start(str(self.root / "linux" / "pz"), args)
        if password:
            proc.write((password + "\n").encode("utf-8"))
            proc.closeWriteChannel()
        self._proc = proc

    def _ask_first_contact_password(self, alias: str) -> str:
        """Collect the remote password for the first pairing, in memory.

        Nothing here is persisted: the value is handed to ``start_pair``,
        written to the child's stdin and dropped. Cancelling returns an
        empty string, which leaves the host unpaired.
        """
        host = self._hosts.get(alias) or {}
        target = f"{host.get('user')}@{host.get('host')}" if host else alias
        password, ok = QInputDialog.getText(
            self, "Primeiro acesso",
            f"Senha de {target} neste servidor.\n"
            "Usada uma vez para instalar a chave; o PhaseZero não guarda a senha.",
            QLineEdit.EchoMode.Password,
        )
        return password if ok else ""

    def _on_pair_done(self, code: int, out: bytes, err: bytes, alias: str | None = None) -> None:
        if self._proc is not None:
            self._cancel_timeout(self._proc)
        self._proc = None
        payload = self._parse_json_payload(out)
        # R01-002: a late pairing result belongs to the host it was started
        # for (captured at spawn; the envelope hostAlias confirms it). If
        # the selection changed meanwhile, the result is dropped: nothing
        # is ingested, nothing advances, no follow-up runs on the new host.
        result_host = str(payload.get("hostAlias") or alias or "")
        selected = self._selected_host()
        if alias is not None and result_host != selected:
            self._pair_advance = False
            self._state_label.setText("Pareamento era para outro host — pareie o host selecionado")
            return
        state = str(payload.get("state", ""))
        if code == 0 and payload.get("paired"):
            self.onboard_ingest_pair(True, {"alias": result_host})
            if self._pair_advance:
                self._pair_advance = False
                if self._onboard_step < len(self.ONBOARD_STEPS) - 1:
                    self._onboard_step += 1
                self._refresh_onboard_label()
            self._state_label.setText("Chave copiada — testando…")
            self.run_cmd(["hosts", "ping", self._selected_host(), "--json"])
            return
        # Retrying first contact must keep the onboarding intent that started
        # this pairing; every other failure path drops it.
        advance = self._pair_advance
        self._pair_advance = False
        self.onboard_ingest_pair(False)
        if state == "missing-key":
            want = QMessageBox.question(
                self, "Parear",
                "Nenhuma chave SSH encontrada.\n"
                "Gerar uma chave ed25519 nova (sem senha, só para automação)?",
                QMessageBox.Yes | QMessageBox.No,
            )
            if want == QMessageBox.Yes:
                self.start_pair(generate=True)
            else:
                self._state_label.setText("Pareamento cancelado — sem chave")
            return
        # UX-008: the first pairing is completed here, not in a terminal.
        # The backend only ever gets the password on stdin, and answering
        # nothing simply leaves the host unpaired.
        if state == "needs-first-contact":
            password = self._ask_first_contact_password(result_host)
            if password:
                self._pair_advance = advance
                self.start_pair(password=password)
                password = ""
                return
            self._state_label.setText("Primeiro acesso cancelado — host segue sem pareamento")
            return
        guidance = str(payload.get("guidance") or "")
        reason = str(payload.get("reason") or "")
        detail = "\n".join(part for part in (guidance, reason) if part)
        if state in ("auth-failed", "timeout", "unreachable", "empty-password"):
            retry = QMessageBox.question(
                self, "Primeiro acesso",
                f"{detail}\n\nTentar de novo?",
                QMessageBox.Yes | QMessageBox.No,
            )
            if retry == QMessageBox.Yes:
                password = self._ask_first_contact_password(result_host)
                if password:
                    self._pair_advance = advance
                    self.start_pair(password=password)
                    password = ""
                    return
            self._state_label.setText(f"Primeiro acesso não concluído: {detail[:120]}")
            return
        QMessageBox.warning(
            self, "Parear",
            f"Não foi possível concluir o pareamento.\n{detail}",
        )
        self._state_label.setText("Pareamento precisa de primeiro acesso")

    def refresh_status(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._state_label.setText("carregando…")
        self._spawn(self._hl("status", "--json"), self._on_status_done)

    def refresh_profiles(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(self._hl("profiles", "--json"), self._on_profiles_done)

    def refresh_apps(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        self._spawn(self._hl("apps", "list", "--json"), self._on_apps_done)

    def _on_apps_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        payload = self._parse_json_payload(raw)
        apps = payload.get("apps") if isinstance(payload.get("apps"), list) else []
        self._rebuild_cards(apps)
        self.refresh_profiles()

    def _clear_layout(self, layout: QGridLayout) -> None:
        while layout.count():
            item = layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()

    def _rebuild_cards(self, apps: list) -> None:
        if self._cards_layout is None:
            return
        self._apps = [a for a in apps if isinstance(a, dict)]
        self._clear_layout(self._cards_layout)
        self._card_buttons = []
        # The previous panels died with the cards; never keep dangling refs.
        self._card_advanced = []
        for index, app in enumerate(self._apps):
            self._cards_layout.addWidget(self._make_app_card(app), index // 2, index % 2)

    # ---------------------------------------------------------- UX-009
    def _first_access_path(self) -> Path:
        return state_dir() / "homelab" / "first-access.json"

    def _load_first_access(self) -> set[str]:
        try:
            data = json.loads(self._first_access_path().read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, ValueError):
            return set()
        apps = data.get("apps") if isinstance(data, dict) else None
        return {str(k) for k in apps} if isinstance(apps, list) else set()

    def _mark_first_access(self, key: str) -> None:
        if not key:
            return
        self._first_access.add(key)
        target = self._first_access_path()
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(
                json.dumps({"apps": sorted(self._first_access)}, indent=2),
                encoding="utf-8",
            )
        except OSError:
            pass

    def app_journey_state(self, app: dict) -> tuple[str, str]:
        """UX-009: journey state of one app against the live status."""
        key = str(app.get("key") or "")
        return app_journey(app, self._last_status, key in self._first_access)

    def _ask_first_access_done(self, app: dict) -> bool:
        """Ask whether the app's own first-use steps were completed.

        Opening the page is not the same as having created the first
        account, so PhaseZero asks instead of assuming. Answering "ainda
        não" keeps the card in "Configurar acesso" with the steps visible.
        """
        steps = first_use_steps(app)
        body = "\n".join(f"• {step}" for step in steps) or \
            "Conclua o primeiro acesso na própria solução."
        box = QMessageBox(self)
        box.setIcon(QMessageBox.Question)
        box.setWindowTitle(f"Primeiro acesso — {app.get('title') or app.get('key')}")
        box.setText("Conclua estes passos na solução que acabou de abrir:")
        box.setInformativeText(body)
        later = box.addButton("Ainda não", QMessageBox.RejectRole)
        done = box.addButton("Concluí o primeiro acesso", QMessageBox.AcceptRole)
        box.setDefaultButton(later)
        box.exec()
        return box.clickedButton() is done

    def _open_solution(self, app: dict, configuring: bool) -> None:
        from PySide6.QtCore import QUrl
        from PySide6.QtGui import QDesktopServices

        url = open_url(app)
        if not url:
            QMessageBox.information(
                self, "Abrir",
                "Esta solução não publica endereço próprio; use o dashboard.",
            )
            return
        QDesktopServices.openUrl(QUrl(url))
        if configuring and self._ask_first_access_done(app):
            self._mark_first_access(str(app.get("key") or ""))
            self._rebuild_cards(self._apps)

    def _make_app_card(self, app: dict) -> QFrame:
        frame = QFrame()
        frame.setObjectName("homelabAppCard")
        frame.setFrameShape(QFrame.StyledPanel)
        frame.setAccessibleName(f"Aplicativo {app.get('title') or app.get('key')}")
        lay = QVBoxLayout(frame)
        title = QLabel(f"{app.get('title') or app.get('key')} · {app.get('layer', '')}")
        title.setStyleSheet("font-weight:700")
        lay.addWidget(title)

        state, explanation = self.app_journey_state(app)
        headline = QLabel(f"{journey_headline(state)} · {app.get('budgetMB', '—')} MiB")
        headline.setObjectName("serviceState")
        headline.setProperty(
            "state",
            {READY: "success", CONFIGURE_ACCESS: "warning",
             PREPARING: "warning", NOT_INSTALLED: "idle"}.get(state, "idle"),
        )
        lay.addWidget(headline)
        detail = QLabel(explanation)
        detail.setWordWrap(True)
        lay.addWidget(detail)
        if state == CONFIGURE_ACCESS:
            steps = first_use_steps(app)[1:]
            for step in steps:
                hint = QLabel(f"• {step}")
                hint.setWordWrap(True)
                lay.addWidget(hint)

        enabled = bool(app.get("enabled"))
        gov = app.get("governor") if isinstance(app.get("governor"), dict) else {}
        verdict = str(gov.get("verdict") or "")
        if verdict == "fail":
            reasons = gov.get("reasons") if isinstance(gov.get("reasons"), list) else []
            reason = str(reasons[0]) if reasons else "orçamento insuficiente"
            warn = QLabel(reason)
            warn.setWordWrap(True)
            warn.setObjectName("serviceState")
            warn.setProperty("state", "warning")
            lay.addWidget(warn)

        key = str(app.get("key") or "")
        row = QHBoxLayout()
        # UX-009: one primary action per state — the journey ends on
        # "Abrir solução", not on a container that happens to be running.
        primary = QPushButton(journey_action_label(state))
        primary.setObjectName("primaryButton")
        primary.setAccessibleName(f"{journey_action_label(state)} — {app.get('title') or key}")
        if state == NOT_INSTALLED:
            primary.setToolTip("Instala e liga esta solução neste servidor.")
            primary.setEnabled(verdict != "fail")
            primary.clicked.connect(
                lambda _=False, k=key: self.run_cmd(["apps", "enable", k, "--json"])
            )
        elif state == PREPARING:
            primary.setToolTip("A solução ainda está subindo; atualize para acompanhar.")
            primary.setEnabled(False)
        else:
            configuring = state == CONFIGURE_ACCESS
            primary.setToolTip(
                "Abre a solução para concluir o primeiro acesso." if configuring
                else "Abre a solução pronta para uso."
            )
            primary.clicked.connect(
                lambda _=False, a=app, c=configuring: self._open_solution(a, c)
            )
        row.addWidget(primary)
        self._card_buttons.append(primary)

        # Advanced controls: preview, image update and turning the app off
        # are not part of the simple journey.
        advanced = QWidget()
        adv_row = QHBoxLayout(advanced)
        adv_row.setContentsMargins(0, 0, 0, 0)
        action = "disable" if enabled else "enable"
        preview = QPushButton("Prévia")
        preview.setToolTip("Mostra o plano sem alterar o host.")
        preview.clicked.connect(
            lambda _=False, k=key, a=action: self.run_cmd(
                ["apps", a, k, "--dry-run", "--json"]
            )
        )
        toggle = QPushButton("Desligar" if enabled else "Ligar")
        toggle.setToolTip("Ativa ou desativa só este aplicativo.")
        if verdict == "fail" and not enabled:
            toggle.setEnabled(False)
        toggle.clicked.connect(
            lambda _=False, k=key, a=action: self.run_cmd(["apps", a, k, "--json"])
        )
        update = QPushButton("Atualizar")
        update.setToolTip("Atualiza a imagem pinada deste aplicativo.")
        update.clicked.connect(
            lambda _=False, k=key: self.run_cmd(["apps", "update", k, "--json"])
        )
        for btn in (preview, toggle, update):
            adv_row.addWidget(btn)
            self._card_buttons.append(btn)
        advanced.setVisible(self._advanced_mode)
        self._card_advanced.append(advanced)
        row.addWidget(advanced)
        lay.addLayout(row)
        return frame

    def _last_backup(self) -> str:
        last = self._last_status.get("backupState", {}).get("lastBackup")
        return (last or {}).get("latest", "") if isinstance(last, dict) else ""

    def _apply_status(self, raw: bytes) -> None:
        payload = self._parse_json_payload(raw)
        if not payload:
            self._state_label.setText("falha ao ler status")
            return
        self._last_status = payload
        ready = bool(payload.get("ready"))
        degraded = bool(payload.get("degraded"))
        mode = (payload.get("accessMode") or {}).get("effective", "?")
        state_key = str(payload.get("state") or "")
        headline = {
            "ready": "Saudável",
            "needs-config": "Ainda não configurado",
            "stopped": "Desligado · dados preservados",
            "degraded": "Atenção necessária",
            "unhealthy": "Saúde insuficiente",
        }.get(state_key)
        if not headline:
            headline = "pronto" if ready else "não pronto"
            if degraded:
                headline += " · degradado"
        self._state_label.setText(f"{headline} · acesso={mode}")
        self._set_state(
            "success" if ready else "warning"
            if degraded or state_key in {"degraded", "unhealthy"} else "error"
        )

        reasons = payload.get("reasons") or []
        if reasons and not ready:
            bullets = "\n".join(f"- {r}" for r in reasons[:4])
            self._append(f"[status] Motivos:\n{bullets}\n")
        next_action = payload.get("nextAction")
        if isinstance(next_action, str) and next_action.strip():
            self._append(f"[status] Próximo passo: {next_action}\n")

        apps = (payload.get("stack") or {}).get("apps", [])
        if not apps:
            self._table.setRowCount(1)
            placeholder = QTableWidgetItem(
                "Nada rodando ainda — clique Subir para preparar o servidor."
            )
            placeholder.setFlags(Qt.ItemIsEnabled)
            self._table.setItem(0, 0, placeholder)
            for col in range(1, 5):
                self._table.setItem(0, col, QTableWidgetItem(""))
            return
        self._table.setRowCount(len(apps))
        for row, app in enumerate(apps):
            for col, key in enumerate(("key", "layer", "bind", "url", "running")):
                item = QTableWidgetItem(str(app.get(key, "—")))
                if key == "running" and item.text() == "True":
                    item.setText("sim")
                    item.setForeground(Qt.GlobalColor.green)
                elif key == "running":
                    item.setText("não")
                    item.setForeground(Qt.GlobalColor.red)
                self._table.setItem(row, col, item)

        budget = payload.get("resourceBudget")
        if budget:
            self._budget_label.setText(
                f"{budget.get('budgetMB')} / {budget.get('availableMB')} MiB "
                f"[{budget.get('verdict')}]"
            )
        else:
            self._budget_label.setText("sem perfil ativo")
        self.refresh_apps()

    def _on_status_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        if b"{" in raw:
            self._apply_status(raw)
            return
        self._state_label.setText("não foi possível diagnosticar agora")
        detail = err.decode("utf-8", "replace").strip().splitlines()
        reason = detail[-1] if detail else f"exit {code}"
        self._show_failure(reason)
        self._append(
            f"[status] Diagnóstico falhou ({reason}).\n"
            "Verifique se o Docker está ativo e clique Atualizar.\n"
        )

    def _on_profiles_done(self, code: int, raw: bytes, err: bytes) -> None:
        self._proc = None
        try:
            payload: dict = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            return
        profiles = payload.get("profiles", []) or []
        if profiles:
            self._profiles_all = [p for p in profiles if isinstance(p, dict)]
            self._rebuild_profile_combo()

    def _simulating(self) -> bool:
        return bool(self._simulate_check is not None and self._simulate_check.isChecked())

    def _rebuild_profile_combo(self) -> None:
        """UX-005: simple mode lists only profiles with an install recipe."""
        installable, budget_only = split_profiles(self._profiles_all)
        visible = installable + (budget_only if self._simulating() else [])
        current = str(self._profile_combo.currentData() or "") \
            or str(self._last_status.get("profile") or "")
        self._profile_combo.blockSignals(True)
        self._profile_combo.clear()
        self._profile_map.clear()
        for p in visible:
            key = str(p.get("key", ""))
            maturity = str(p.get("maturity", ""))
            self._profile_map[key] = str(p.get("title", key))
            label = f"{p.get('title', key)} ({key})"
            if maturity and maturity not in ("stable",):
                label += f" [{maturity}]"
            if not p.get("installable"):
                label += " — simulação"
                self._profile_map[key + ":note"] = profile_simulation_note(p)
            self._profile_combo.addItem(label, key)
        idx = self._profile_combo.findData(current)
        self._profile_combo.setCurrentIndex(idx if idx >= 0 else 0)
        self._profile_combo.blockSignals(False)
        self._refresh_profile_note()

    def _on_simulate_toggled(self, _checked: bool) -> None:
        self._rebuild_profile_combo()

    def _refresh_profile_note(self) -> None:
        """UX-005: the simulation warning is shown, never only logged."""
        if self._profile_note is None:
            return
        key = str(self._profile_combo.currentData() or "")
        note = self._profile_map.get(key + ":note", "")
        self._profile_note.setText(note)
        self._profile_note.setVisible(bool(note))

    # -- profile ------------------------------------------------------------
    def apply_profile(self) -> None:
        key = self._profile_combo.currentData()
        if not key:
            QMessageBox.warning(self, "Perfil", "Selecione um perfil.")
            return
        # PZ-AUD-022: applying sets the RAM budget; installable=false
        # profiles have no install recipe, and the user must know that.
        note = self._profile_map.get(key + ":note", "")
        if note:
            QMessageBox.information(self, "Perfil", note)
        self.run_cmd(["profile", "set", key])

    def show_policy(self) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            return
        proc = QProcess(self)
        self._setup_proc(proc)

        def on_finished(code: int) -> None:
            self._cancel_timeout(proc)
            if self._proc is proc:
                self._proc = None
            self._render_policy(code, bytes(proc.readAllStandardOutput()))

        proc.finished.connect(on_finished)
        proc.start(str(self.root / "linux" / "server" / "ai-policy-broker.sh"), ["status"])
        self._proc = proc

    def _render_policy(self, code: int, raw: bytes) -> None:
        try:
            payload: dict = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            QMessageBox.warning(
                self, "Política",
                "Policy broker indisponível agora.\n\n"
                "Tente novamente; se persistir, execute:\n"
                "linux/pz server ai-policy status",
            )
            return
        denied = ", ".join(payload.get("deniedActions", []) or []) or "nenhuma"
        QMessageBox.information(
            self, "Política AI",
            f"modo: {payload.get('mode')}\nnegadas: {denied}",
        )

    # -- actions ------------------------------------------------------------
    def run_cmd(self, args: list[str], host: str | None = None) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        if getattr(getattr(self, "runner", None), "running", False):
            self._state_label.setText("Já existe operação global em andamento — aguarde")
            return
        self._output.clear()
        self._clear_failure()
        self._last_cmd = (list(args), host)
        self._bar.show()
        proc = QProcess(self)
        self._setup_proc(proc)
        proc.readyReadStandardOutput.connect(
            lambda: self._append(str(bytes(proc.readAllStandardOutput()), "utf-8", "replace"))
        )
        proc.readyReadStandardError.connect(
            lambda: self._append_log(bytes(proc.readAllStandardError()))
        )
        proc.finished.connect(self._on_cmd_done)
        proc.errorOccurred.connect(lambda err: self._on_cmd_error(err, proc))
        if args and args[0] == "hosts":
            argv = ["server", "homelab", *args]
        else:
            argv = self._hl_for(self._selected_host() if host is None else host, *args)
        proc.start(str(self.root / "linux" / "pz"), argv)
        self._proc = proc

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for panel in self._card_advanced:
            if isValid(panel):
                panel.setVisible(self._advanced_mode)

    # ---------------------------------------------------------- UX-007
    def _show_failure(self, raw_text: str) -> None:
        """State the cause and the way out, in the interface."""
        if self._error_banner is None:
            return
        self._error_banner.setText(failure_banner_text(raw_text))
        self._error_frame.setVisible(True)
        if self._error_retry is not None:
            self._error_retry.setVisible(self._last_cmd is not None)

    def _clear_failure(self) -> None:
        if self._error_banner is not None:
            self._error_banner.setText("")
        if getattr(self, "_error_frame", None) is not None:
            self._error_frame.setVisible(False)

    def _retry_last_cmd(self) -> None:
        last = self._last_cmd
        self._clear_failure()
        if last is None:
            self.refresh_status()
            return
        args, host = last
        self.run_cmd(list(args), host=host)

    def block_while_running(self, running: bool) -> None:
        for btn in self._action_buttons:
            btn.setEnabled(not running)
        for btn in self._card_buttons:
            btn.setEnabled(not running)
        self._profile_set.setEnabled(not running)

    def _on_cmd_done(self, code: int) -> None:
        proc = self._proc
        tail = ""
        if proc is not None:
            self._cancel_timeout(proc)
            if proc.state() == QProcess.NotRunning:
                err = bytes(proc.readAllStandardError())
                if err.strip():
                    tail = str(err, "utf-8", "replace")
                    self._append_log(err)
        self._bar.hide()
        confirm = self._pending_confirm_file
        if confirm is not None:
            # A frase digitada vive só o necessário; nada de segredo-restos.
            try:
                confirm.unlink(missing_ok=True)
            except OSError:
                pass
            self._pending_confirm_file = None
        if code == 0:
            self._state_label.setText("Concluído")
            self._set_state("success")
            self._clear_failure()
        else:
            # UX-007: the cause and the next action are stated here; the
            # output pane stays as evidence, not as the only explanation.
            self._state_label.setText("Não foi possível concluir")
            self._set_state("error")
            self._show_failure(tail or self._output.toPlainText()[-4000:])
        QTimer.singleShot(300, self.refresh_status)

    def _on_cmd_error(self, error: QProcess.ProcessError, proc: QProcess) -> None:
        if error == QProcess.FailedToStart:
            self._bar.hide()
            self._state_label.setText("não foi possível iniciar o comando")
            if self._proc is proc:
                self._proc = None

    def _append_log(self, data: bytes) -> None:
        text = str(data, "utf-8", "replace").strip()
        if text:
            self._append(f"[stderr] {text}\n")

    def _append(self, text: str) -> None:
        self._output.insertPlainText(text)
        self._output.verticalScrollBar().setValue(self._output.verticalScrollBar().maximum())

    def pick_restore(self) -> None:
        last = self._last_backup()
        if not last:
            QMessageBox.warning(
                self, "Restaurar",
                "Nenhum backup anterior localizado.\n"
                "Clique em Copiar segurança para criar o primeiro.",
            )
            return
        self._start_restore_flow(last)

    # ------------------------------------------------- restore assistido
    @staticmethod
    def _confirmation_phrase(source: str) -> str:
        return f"RESTAURAR {Path(source).name}"

    def _start_restore_flow(self, source: str) -> None:
        if self._proc is not None and self._proc.state() != QProcess.NotRunning:
            self._state_label.setText("Já existe operação em andamento — aguarde")
            return
        self._state_label.setText("Restaurar · verificando backup…")
        self._bar.show()
        proc = QProcess(self)
        self._setup_proc(proc)
        proc.finished.connect(
            lambda code, p=proc, src=source: self._on_restore_plan_done(
                code, bytes(p.readAllStandardOutput()), src
            )
        )
        proc.errorOccurred.connect(lambda _e, p=proc: self._restore_failed(p, "não iniciou"))
        proc.start(str(self.root / "linux" / "pz"),
                   self._hl("restore", "--source", source, "--plan"))
        self._proc = proc

    def _restore_failed(self, proc: QProcess, why: str) -> None:
        self._cancel_timeout(proc)
        if self._proc is proc:
            self._proc = None
        self._bar.hide()
        self._set_state("error")
        self._state_label.setText("Restaurar · falhou antes da prévia")
        self._append(f"[restore] {why}\n")

    def _parse_plan(self, raw: bytes) -> dict:
        payload = self._parse_json_payload(raw)
        if isinstance(payload, dict) and payload.get("action") == "restore":
            return payload
        return {}

    def _restore_summary_text(self, plan: dict, source: str) -> str:
        checks = plan.get("checks") or []
        passed = sum(1 for c in checks if isinstance(c, dict) and c.get("ok"))
        volumes = [str(v) for v in (plan.get("volumesAffected") or [])]
        lines = [
            f"Origem: {source}",
            f"Verificação: {'aprovada' if plan.get('verified') else 'FALHOU'}"
            f" ({passed}/{len(checks)} provas)",
            f"Arquivos de volume: {len(plan.get('archives') or [])}",
            "Volumes substituídos: " + (", ".join(volumes[:6]) or "—")
            + ("…" if len(volumes) > 6 else ""),
            "",
            "Antes de aplicar, o PhaseZero faz um pré-backup automático",
            "dos volumes atuais (rollback possível em caso de falha).",
        ]
        return "\n".join(lines)

    def _on_restore_plan_done(self, code: int, raw: bytes, source: str) -> None:
        self._cancel_timeout(self._proc) if self._proc is not None else None
        if self._proc is not None and self._proc.state() == QProcess.NotRunning:
            self._proc = None
        self._bar.hide()
        plan = self._parse_plan(raw)
        if code != 0 or not plan:
            self._set_state("error")
            self._state_label.setText("Restaurar · prévia indisponível")
            self._append("[restore] Não foi possível gerar a prévia do restore.\n")
            return
        if not plan.get("verified"):
            QMessageBox.critical(
                self, "Restaurar",
                "Este backup NÃO passou na verificação (checksums/manifesto).\n"
                "Nada foi alterado. Gere um novo backup com Copiar segurança.",
            )
            return

        phrase = self._confirmation_phrase(source)
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Warning)
        dialog.setWindowTitle("Restaurar Homelab")
        dialog.setText("Restauração assistida — os volumes serão SUBSTITUÍDOS.")
        dialog.setInformativeText(self._restore_summary_text(plan, source))
        confirmation = QPlainTextEdit()
        confirmation.setPlaceholderText(f"Digite exatamente: {phrase}")
        confirmation.setAccessibleName("Confirmação da restauração")
        confirmation.setMaximumHeight(64)
        dialog.layout().addWidget(confirmation)
        cancel = dialog.addButton("Voltar", QMessageBox.RejectRole)
        apply_btn = dialog.addButton("Aplicar restauração", QMessageBox.AcceptRole)
        apply_btn.setObjectName("dangerButton")
        apply_btn.setEnabled(False)
        confirmation.textChanged.connect(
            lambda: apply_btn.setEnabled(confirmation.toPlainText().strip() == phrase)
        )
        dialog.setDefaultButton(cancel)
        dialog.exec()
        if dialog.clickedButton() is not apply_btn:
            self._state_label.setText("Restaurar · cancelado")
            return
        confirm_file = self._write_confirm_file(source, phrase)
        if confirm_file is None:
            QMessageBox.critical(self, "Restaurar", "Não foi possível gravar o arquivo de confirmação.")
            return
        self._pending_confirm_file = confirm_file
        self.run_cmd(["restore", "--source", source, "--confirm-file", str(confirm_file)])

    def _write_confirm_file(self, source: str, phrase: str) -> Path | None:
        state_dir = (
            Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
            / "phasezero" / "homelab"
        )
        try:
            state_dir.mkdir(parents=True, exist_ok=True)
            target = state_dir / f"confirm-{Path(source).name}.txt"
            target.write_text(f"{phrase}\n", encoding="utf-8")
            target.chmod(0o600)
            return target
        except OSError:
            return None
