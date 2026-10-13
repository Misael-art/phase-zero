from __future__ import annotations

from collections import OrderedDict

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QStyle,
    QVBoxLayout,
    QWidget,
)

from ..health_models import HealthCheck, parse_health_checks, suggested_action_id
from ..models import ActionSpec
from ..widgets import SectionHeader, SkeletonPill, SkeletonTile, stop_shimmer, themed_icon
from .base import BasePage


PILL_ACTION_IDS = ("system.doctor", "system.repair-plan", "system.support-bundle", "system.version")
INSTALL_ACTION_IDS = (
    "system.installation.status", "system.self-update.check", "system.self-update.apply",
    "system.installation.converge", "system.installation.prune",
)


class OverviewPage(BasePage):
    """Answer-first system health dashboard; raw doctor output stays hidden."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._technical_labels: list[QLabel] = []

    def build(self) -> None:
        for action_id in (*PILL_ACTION_IDS, *INSTALL_ACTION_IDS):
            action = self.by_id.get(action_id)
            if action is not None:
                self.mark_represented(action)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._inner = QWidget()
        self._content = QVBoxLayout(self._inner)
        self._content.setContentsMargins(2, 2, 8, 12)
        self._content.setSpacing(14)
        self._content.addWidget(self._build_health_hero())
        self.metrics = QGridLayout()
        self.metrics.setContentsMargins(0, 0, 0, 0)
        self.metrics.setHorizontalSpacing(12)
        self._content.addLayout(self.metrics)
        self.health_host = QWidget()
        self.health_layout = QVBoxLayout(self.health_host)
        self.health_layout.setContentsMargins(0, 0, 0, 0)
        self.health_layout.setSpacing(12)
        self._content.addWidget(self.health_host)
        self._content.addWidget(self._build_tools())
        self._content.addStretch()
        scroll.setWidget(self._inner)
        self._layout.addWidget(scroll)
        self.status_loader.status_ready.connect(self._on_status_ready)
        self.status_loader.status_failed.connect(self._on_status_failed)

    def _build_health_hero(self) -> QFrame:
        hero = QFrame()
        hero.setObjectName("healthHero")
        row = QHBoxLayout(hero)
        row.setContentsMargins(20, 18, 20, 18)
        # LUX-011: nada de ✓ antes de medir.
        icon = QLabel("…")
        icon.setObjectName("healthShield")
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(58, 58)
        row.addWidget(icon)
        copy = QVBoxLayout()
        self.health_title = QLabel("Verificando saúde do sistema…")
        self.health_title.setObjectName("serviceTitle")
        self.health_summary = QLabel("Isso pode levar alguns segundos.")
        self.health_summary.setObjectName("cardDescription")
        self.health_summary.setWordWrap(True)
        copy.addWidget(self.health_title)
        copy.addWidget(self.health_summary)
        row.addLayout(copy, 1)
        refresh = QPushButton("Verificar novamente")
        refresh.setObjectName("primaryButton")
        refresh.clicked.connect(self.reload)
        row.addWidget(refresh)
        self.health_icon = icon
        self.health_refresh = refresh
        return hero

    def _metric(self, title: str, value: int, state: str) -> QFrame:
        card = QFrame()
        card.setObjectName("healthMetric")
        card.setProperty("state", state)
        layout = QVBoxLayout(card)
        layout.setContentsMargins(14, 12, 14, 12)
        number = QLabel(str(value))
        number.setObjectName("healthMetricValue")
        number.setProperty("state", state)
        label = QLabel(title)
        label.setObjectName("healthMetricLabel")
        layout.addWidget(number)
        layout.addWidget(label)
        return card

    def _build_tools(self) -> QFrame:
        card = QFrame()
        card.setObjectName("settingsCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.addWidget(SectionHeader("Ferramentas", "Ações seguras para entender e corrigir problemas"))
        buttons = QHBoxLayout()
        for action_id, label in (
            ("system.repair-plan", "Ver recomendações"),
            ("system.installation.status", "Ver atualização"),
            ("system.version", "Versão instalada"),
        ):
            action = self.by_id.get(action_id)
            if action is None:
                continue
            button = QPushButton(label)
            button.setObjectName("primaryButton" if action_id == "system.repair-plan" else "secondaryButton")
            button.clicked.connect(lambda _checked=False, item=action: self.request_action(item))
            buttons.addWidget(button)
        buttons.addStretch()
        layout.addLayout(buttons)
        return card

    def _install_context_status(self) -> None:
        return  # Health hero owns the status surface.

    def reload(self) -> None:
        self._clear_health()
        self.health_refresh.setEnabled(False)
        self.health_title.setText("Verificando saúde do sistema…")
        self.health_summary.setText("Isso pode levar alguns segundos.")
        self.health_icon.setText("…")
        self.begin_loading(self._show_status_skeletons)
        # CCS-016: o hero de saúde usa o escopo system — rápido e sem
        # auditar subsystemas opcionais que o usuário nunca habilitou.
        action = self.by_id.get("system.doctor.system") or self.by_id.get("system.doctor")
        if action is not None:
            self.status_loader.fetch_action(action)
        else:
            self._on_status_failed("system.doctor", "ação indisponível")

    def _show_status_skeletons(self) -> None:
        for _ in range(4):
            self.health_layout.addWidget(SkeletonPill())

    def _clear_health(self) -> None:
        while self.health_layout.count():
            item = self.health_layout.takeAt(0)
            if item.widget():
                for tile in item.widget().findChildren(SkeletonTile):
                    stop_shimmer(tile)
                item.widget().deleteLater()
        while self.metrics.count():
            item = self.metrics.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._technical_labels.clear()

    def _on_status_ready(self, action_id: str, _stdout: str, parsed: object) -> None:
        if action_id not in {"system.doctor", "system.doctor.system"}:
            return
        self.finish_loading()
        self._clear_health()
        self.health_refresh.setEnabled(True)
        checks = parse_health_checks(parsed)
        if not checks:
            self.health_title.setText("Diagnóstico concluído")
            self.health_summary.setText("Não foi possível organizar os detalhes. Consulte o histórico.")
            self.health_icon.setText("i")
            return
        passed = sum(check.status == "PASS" for check in checks)
        # LUX-011: INFO é informativo (subsistema não optado, CCS-016); não
        # conta como aviso nem muda o veredito — igual a needs_attention.
        warnings = sum(check.status == "WARN" for check in checks)
        infos = sum(check.status == "INFO" for check in checks)
        failures = sum(check.status in {"FAIL", "ERROR"} for check in checks)
        if failures:
            self.health_title.setText(f"{failures} item(ns) precisam de atenção")
            self.health_summary.setText("Corrija itens vermelhos primeiro. O PhaseZero sugere o próximo passo.")
            self.health_icon.setText("!")
        elif warnings:
            self.health_title.setText("Sistema funcionando com avisos")
            self.health_summary.setText("Nada crítico. Há melhorias recomendadas abaixo.")
            self.health_icon.setText("⚠")
        else:
            self.health_title.setText("Tudo certo")
            self.health_summary.setText("Hardware, conexão e serviços essenciais estão saudáveis.")
            self.health_icon.setText("✓")
        for column, (title, value, state) in enumerate((
            ("Tudo certo", passed, "success"),
            ("Avisos", warnings, "warning"),
            ("Erros", failures, "error"),
            ("Informativos", infos, "info"),
        )):
            self.metrics.addWidget(self._metric(title, value, state), 0, column)
            self.metrics.setColumnStretch(column, 1)
        groups: OrderedDict[str, list[HealthCheck]] = OrderedDict()
        for check in checks:
            groups.setdefault(check.group, []).append(check)
        for title, group_checks in groups.items():
            self.health_layout.addWidget(self._group_card(title, group_checks))

    def _group_card(self, title: str, checks: list[HealthCheck]) -> QFrame:
        card = QFrame()
        card.setObjectName("healthGroup")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        heading = QFrame()
        heading.setObjectName("healthGroupHeader")
        heading_row = QHBoxLayout(heading)
        heading_row.setContentsMargins(14, 10, 14, 10)
        name = QLabel(title)
        name.setObjectName("sectionHeading")
        attention = sum(check.needs_attention for check in checks)
        badge = QLabel("Tudo certo" if not attention else f"{attention} para revisar")
        badge.setObjectName("badge")
        badge.setProperty("state", "success" if not attention else "warning")
        heading_row.addWidget(name)
        heading_row.addStretch()
        heading_row.addWidget(badge)
        layout.addWidget(heading)
        for check in checks:
            layout.addWidget(self._check_row(check))
        return card

    def _check_row(self, check: HealthCheck) -> QWidget:
        row = QWidget()
        row.setObjectName("healthCheckRow")
        layout = QHBoxLayout(row)
        layout.setContentsMargins(14, 9, 14, 9)
        icon = QLabel({"success": "✓", "warning": "⚠", "error": "✕", "info": "i"}[check.state])
        icon.setObjectName("healthCheckIcon")
        icon.setProperty("state", check.state)
        icon.setAlignment(Qt.AlignCenter)
        icon.setFixedSize(28, 28)
        copy = QVBoxLayout()
        title = QLabel(check.title)
        title.setObjectName("settingValue")
        detail = QLabel(check.detail or ("Sem ação necessária" if check.state == "success" else "Revisão recomendada"))
        detail.setObjectName("cardDescription")
        detail.setWordWrap(True)
        technical = QLabel(check.check_id)
        technical.setObjectName("technicalLabel")
        technical.setVisible(self._advanced_mode)
        self._technical_labels.append(technical)
        copy.addWidget(title)
        copy.addWidget(detail)
        copy.addWidget(technical)
        layout.addWidget(icon)
        layout.addLayout(copy, 1)
        if check.needs_attention:
            action = self.by_id.get(suggested_action_id(check))
            if action is not None:
                fix = QPushButton("Ver solução")
                fix.setObjectName("secondaryButton")
                fix.clicked.connect(lambda _checked=False, item=action: self.action_selected.emit(item))
                layout.addWidget(fix)
        return row

    def _on_status_failed(self, action_id: str, _error: str) -> None:
        if action_id not in {"system.doctor", "system.doctor.system"}:
            return
        self.finish_loading()
        self._clear_health()
        self.health_refresh.setEnabled(True)
        self.health_icon.setText("!")
        self.health_title.setText("Não foi possível verificar agora")
        self.health_summary.setText("Tente novamente. Se persistir, veja o histórico em Resultados.")
        # LUX-011: o botão "Verificar novamente" do topo já repete; aqui só
        # o caminho para o histórico.
        history = QPushButton("Abrir Resultados")
        history.setObjectName("secondaryButton")
        history.clicked.connect(lambda: self.request_category("Resultados"))
        self.health_layout.addWidget(history)

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        for label in self._technical_labels:
            label.setVisible(enabled)

    def block_while_running(self, running: bool) -> None:
        self.setEnabled(not running)
