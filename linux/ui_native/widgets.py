from __future__ import annotations

import json
import re
import shlex
import time
from pathlib import Path

from PySide6.QtCore import (
    QEasingCurve,
    QEvent,
    QPoint,
    QPropertyAnimation,
    QRectF,
    QSize,
    Qt,
    QTimer,
    Signal,
)
from PySide6.QtGui import QColor, QIcon, QMouseEvent, QPainter, QPen
from PySide6.QtWidgets import (
    QApplication,
    QDialog,
    QDialogButtonBox,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGraphicsDropShadowEffect,
    QGraphicsOpacityEffect,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMenu,
    QPlainTextEdit,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QStackedWidget,
    QSizePolicy,
    QStyle,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

from . import __version__

from .models import ActionSpec, OperationResult
from .platform import open_path
from .preferences import reduced_motion
from .result_parser import guidance, is_pending_report, restart_required


_ICON_CACHE: dict[str, QIcon] = {}
_PZ_ICON_DIR: Path | None = None


def _pz_icon_dir() -> Path | None:
    global _PZ_ICON_DIR
    if _PZ_ICON_DIR is None:
        candidates = [
            Path(__file__).resolve().parents[2] / "assets" / "icons" / "hicolor" / "scalable" / "apps",
            Path("/usr/lib/phasezero/assets/icons/hicolor/scalable/apps"),
            Path("/usr/share/icons/hicolor/scalable/apps"),
        ]
        for c in candidates:
            if c.is_dir():
                _PZ_ICON_DIR = c
                break
    return _PZ_ICON_DIR


def themed_icon(widget: QWidget, name: str, fallback: QStyle.StandardPixmap) -> QIcon:
    cached = _ICON_CACHE.get(name)
    if cached is not None:
        return cached
    icon = QIcon.fromTheme(name)
    if icon.isNull():
        d = _pz_icon_dir()
        if d is not None:
            for ext in ("svg", "png"):
                p = d / f"{name}.{ext}"
                if p.exists():
                    icon = QIcon(str(p))
                    break
    if icon.isNull():
        icon = widget.style().standardIcon(fallback)
    _ICON_CACHE[name] = icon
    return icon


def hub_item_icon(widget: QWidget, item, fallback: QStyle.StandardPixmap = QStyle.SP_FileIcon) -> QIcon:
    """Ícone de um `HubItem`, preferindo o logo real do app instalado.

    A cascata vive em `icons.resolve_icon` (sem Qt, testável); aqui só entra o
    que depende do tema carregado: se o tema tem mesmo o ícone chutado a partir
    do nome do pacote. Sem essa checagem a UI mostraria quadrado vazio em vez
    de cair para o ícone da seção.
    """
    from .icons import resolve_icon

    reference = resolve_icon(
        item,
        overlay_icon=item.icon if getattr(item, "icon_explicit", False) else "",
        has_theme_icon=QIcon.hasThemeIcon,
    )
    cache_key = f"hub:{reference.kind}:{reference.value}"
    cached = _ICON_CACHE.get(cache_key)
    if cached is not None:
        return cached
    icon = QIcon(reference.value) if reference.kind == "file" else QIcon.fromTheme(reference.value)
    if icon.isNull():
        icon = themed_icon(widget, getattr(item, "icon", "") or "package-x-generic", fallback)
    _ICON_CACHE[cache_key] = icon
    return icon


def action_icon(widget: QWidget, action: ActionSpec, size: int = 24) -> QIcon:
    """Resolve a semantic system icon without shipping platform-specific assets."""
    text = f"{action.id} {action.title}".casefold()
    rules = (
        (("status", "doctor", "diagnóst", "audit", "check"), QStyle.SP_DialogApplyButton),
        (("repair", "reparo", "fix", "reset", "rollback"), QStyle.SP_BrowserReload),
        (("install", "setup", "import", "download"), QStyle.SP_DialogApplyButton),
        (("remove", "delete", "clean", "limpar"), QStyle.SP_TrashIcon),
        (("folder", "path", "media", "library", "biblioteca"), QStyle.SP_DirOpenIcon),
        (("launch", "start", "run", "boot", "session"), QStyle.SP_ComputerIcon),
        (("settings", "config", "tune", "override"), QStyle.SP_FileDialogDetailedView),
        (("network", "remote", "server", "mcp"), QStyle.SP_DriveNetIcon),
    )
    fallback = QStyle.SP_ComputerIcon
    for terms, candidate in rules:
        if any(term in text for term in terms):
            fallback = candidate
            break
    return themed_icon(widget, action.icon, fallback)


def available_geometry(widget: QWidget):
    """Usable screen area for ``widget`` (patched by tests to emulate a Deck)."""
    screen = widget.screen() if widget is not None else None
    screen = screen or QApplication.primaryScreen()
    return screen.availableGeometry() if screen is not None else None


def fit_to_screen(
    widget: QWidget, width: int, height: int, *, minimum: tuple[int, int] = (320, 240), margin: int = 24
) -> None:
    """LUX-012: prefer ``width×height`` but never exceed the usable screen.

    Steam Deck at 150% offers 853×533 logical pixels; fixed minimums of
    760×540 pushed the action footer off-screen.
    """
    area = available_geometry(widget)
    if area is None:
        widget.setMinimumSize(*minimum)
        widget.resize(width, height)
        return
    max_w = max(minimum[0], area.width() - margin)
    max_h = max(minimum[1], area.height() - margin)
    widget.setMinimumSize(min(minimum[0], max_w), min(minimum[1], max_h))
    widget.setMaximumSize(max_w, max_h)
    widget.resize(min(width, max_w), min(height, max_h))


def _repolish(widget: QWidget) -> None:
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class HeaderBar(QFrame):
    minimize_requested = Signal()
    maximize_requested = Signal()
    close_requested = Signal()

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("headerBar")
        self._drag_position: QPoint | None = None
        layout = QHBoxLayout(self)
        layout.setContentsMargins(18, 8, 10, 8)
        mark = QLabel("PZ")
        mark.setObjectName("brandMark")
        title = QLabel(f"PhaseZero v{__version__}")
        title.setObjectName("windowTitle")
        subtitle = QLabel("Central de Controle")
        subtitle.setObjectName("windowSubtitle")
        title_box = QVBoxLayout()
        title_box.setSpacing(0)
        title_box.addWidget(title)
        title_box.addWidget(subtitle)
        layout.addWidget(mark)
        layout.addLayout(title_box)
        layout.addStretch()
        # Language chips stay visible (EmuDeck keeps locale selection in the open).
        for flag in ("🇧🇷", "🇺🇸"):
            chip = QLabel(flag)
            chip.setObjectName("langChip")
            layout.addWidget(chip)
        for icon_name, fallback, signal, object_name in [
            ("window-minimize", QStyle.SP_TitleBarMinButton, self.minimize_requested, "windowButton"),
            ("window-maximize", QStyle.SP_TitleBarMaxButton, self.maximize_requested, "windowButton"),
            ("window-close", QStyle.SP_TitleBarCloseButton, self.close_requested, "closeButton"),
        ]:
            button = QPushButton()
            button.setObjectName(object_name)
            button.setIcon(themed_icon(self, icon_name, fallback))
            button.setFixedSize(34, 32)
            button.clicked.connect(signal.emit)
            layout.addWidget(button)

    def mousePressEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            handle = self.window().windowHandle()
            if handle is not None and handle.startSystemMove():
                self._drag_position = None
            else:
                self._drag_position = (
                    event.globalPosition().toPoint() - self.window().frameGeometry().topLeft()
                )
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent) -> None:
        if self._drag_position is not None and event.buttons() & Qt.LeftButton:
            self.window().move(event.globalPosition().toPoint() - self._drag_position)
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        self._drag_position = None
        super().mouseReleaseEvent(event)

    def mouseDoubleClickEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton:
            self.maximize_requested.emit()
        super().mouseDoubleClickEvent(event)


class SectionHeader(QWidget):
    """A dashboard section heading: bold title + subtle caption."""

    def __init__(self, title: str, caption: str = "", parent: QWidget | None = None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(2, 8, 2, 2)
        layout.setSpacing(1)
        label = QLabel(title)
        label.setObjectName("sectionHeading")
        layout.addWidget(label)
        if caption:
            cap = QLabel(caption)
            cap.setObjectName("sectionCaption")
            # UX-003/004: an unwrapped caption dictates the container's
            # minimum width and forces horizontal overflow on narrow windows.
            cap.setWordWrap(True)
            layout.addWidget(cap)


class Breadcrumb(QFrame):
    """Compact, accessible location indicator for category navigation."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("breadcrumb")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self._label = QLabel("PhaseZero")
        self._label.setObjectName("breadcrumbText")
        self._label.setAccessibleName("Localização atual")
        layout.addWidget(self._label)
        layout.addStretch()

    def set_path(self, section: str, page: str) -> None:
        parts = ["PhaseZero", section, page]
        text = "  ›  ".join(part for index, part in enumerate(parts) if part and part not in parts[:index])
        self._label.setText(text)
        self._label.setAccessibleDescription(f"Página atual: {page}; seção: {section}")

    @property
    def text(self) -> str:
        return self._label.text()


class ActionCard(QFrame):
    requested = Signal(object)

    def __init__(self, action: ActionSpec, *, hero: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setObjectName("actionCard")
        self.setProperty("variant", action.variant)
        self.setProperty("hero", hero)
        if hero:
            self.setMinimumSize(300, 150)
            self.setMaximumHeight(172)
        else:
            self.setMinimumSize(272, 168)
            self.setMaximumHeight(196)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.PointingHandCursor)
        self.installEventFilter(self)
        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(26 if hero else 20)
        shadow.setOffset(0, 6)
        shadow.setColor(QColor(0, 0, 0, 110 if hero else 80))
        self.setGraphicsEffect(shadow)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 16, 18, 16)
        outer.setSpacing(9)

        heading = QHBoxLayout()
        heading.setSpacing(12)
        icon_tile = QLabel()
        icon_tile.setObjectName("cardIconHero" if hero else "cardIcon")
        px = 34 if hero else 28
        icon_tile.setPixmap(themed_icon(self, action.icon, QStyle.SP_ComputerIcon).pixmap(px, px))
        icon_tile.setFixedSize(56 if hero else 46, 56 if hero else 46)
        icon_tile.setAlignment(Qt.AlignCenter)
        heading.addWidget(icon_tile)
        title_box = QVBoxLayout()
        title_box.setSpacing(1)
        title = QLabel(action.title)
        title.setObjectName("cardTitleHero" if hero else "cardTitle")
        title.setWordWrap(True)
        title_box.addWidget(title)
        if action.elevated:
            lock = QLabel("🔒 requer admin")
            lock.setObjectName("cardLock")
            title_box.addWidget(lock)
        heading.addLayout(title_box, 1)
        # Badge "JSON" é ruído para leigo nos cards simples; o modo avançado
        # tem painel próprio e continua mostrando tudo.
        if action.badge and action.badge.upper() != "JSON":
            badge = QLabel(action.badge)
            badge.setObjectName("badge")
            badge.setProperty("state", action.state)
            badge.setAlignment(Qt.AlignCenter)
            heading.addWidget(badge, 0, Qt.AlignTop)
        outer.addLayout(heading)

        description = QLabel(action.description)
        description.setObjectName("cardDescription")
        description.setWordWrap(True)
        outer.addWidget(description, 1)

        button = QPushButton("Pré-visualizar" if action.mutable else "Executar")
        button.setObjectName(
            {"danger": "dangerButton", "primary": "primaryButton"}.get(action.variant, "secondaryButton")
        )
        button.setCursor(Qt.PointingHandCursor)
        button.setIcon(
            themed_icon(
                self,
                "document-preview" if action.mutable else "media-playback-start",
                QStyle.SP_MediaPlay,
            )
        )
        button.clicked.connect(lambda: self.requested.emit(self.action))
        outer.addWidget(button)

    def eventFilter(self, watched: object, event: QEvent) -> bool:
        if watched is self and event.type() == QEvent.KeyPress:
            if event.key() in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space):
                self.requested.emit(self.action)
                return True
        return super().eventFilter(watched, event)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        # Clicking anywhere on the card (not just the button) triggers it.
        if event.button() == Qt.LeftButton and self.rect().contains(event.position().toPoint()):
            self.requested.emit(self.action)
        super().mouseReleaseEvent(event)


MODE_LABELS = {
    "recommended": ("Recomendado", "success"),
    "opt-in": ("Opcional", "info"),
    "advanced": ("Avançado", "warning"),
}


class HubChip(QLabel):
    """Selo compacto de metadado (reversão, risco, reboot)."""

    def __init__(self, text: str, state: str = "info", tooltip: str = "", parent: QWidget | None = None) -> None:
        super().__init__(text, parent)
        self.setObjectName("hubChip")
        self.setProperty("state", state)
        if tooltip:
            self.setToolTip(tooltip)
            self.setAccessibleDescription(tooltip)


class HubAppCard(QFrame):
    """Cartão de app/serviço/otimização da página Linux.

    Um switch aparece só quando existe contrato para desligar. Estado nunca é
    otimista: `set_state` é chamado com o que o host respondeu, e enquanto a
    operação corre o switch fica em `pending` — a confirmação vem do refetch.
    """

    toggle_requested = Signal(object, str, bool)  # item, "install"|"tune", ligado
    action_requested = Signal(object)             # ActionSpec

    def __init__(self, item, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.item = item
        self.setObjectName("hubCard")
        self.setProperty("mode", item.mode)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setAccessibleName(item.title)

        # Linha densa, como as listas do resto do app: ícone à esquerda, texto
        # no meio, controles à direita. Empilhar tudo verticalmente rendia três
        # cartões por tela e obrigava a rolar para comparar itens.
        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 10, 14, 10)
        layout.setSpacing(12)

        icon_label = QLabel()
        icon_label.setObjectName("hubCardIcon")
        icon_label.setPixmap(hub_item_icon(self, item).pixmap(QSize(32, 32)))
        icon_label.setFixedSize(40, 40)
        icon_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(icon_label, 0, Qt.AlignTop)

        center = QVBoxLayout()
        center.setSpacing(3)
        head = QHBoxLayout()
        head.setSpacing(8)
        title = QLabel(item.title)
        title.setObjectName("hubCardTitle")
        head.addWidget(title, 0)
        mode_text, mode_state = MODE_LABELS.get(item.mode, ("Opcional", "info"))
        head.addWidget(HubChip(
            mode_text,
            mode_state,
            {
                "recommended": "Faz parte do conjunto recomendado do PhaseZero.",
                "opt-in": "Instale só se quiser; nada depende disso.",
                "advanced": "Mexe em áreas sensíveis do sistema. Revise antes.",
            }.get(item.mode, ""),
        ))
        head.addStretch(1)
        center.addLayout(head)

        description = QLabel(item.description)
        description.setObjectName("hubCardDescription")
        description.setWordWrap(True)
        center.addWidget(description)

        chips = QHBoxLayout()
        chips.setSpacing(6)
        for label in item.rollback_labels:
            state = "success" if item.reversible else "warning"
            chips.addWidget(HubChip(label, state, f"Como isto é desfeito: {label.lower()}."))
        if item.reboot == "required":
            chips.addWidget(HubChip("Requer reiniciar", "warning", "Só passa a valer após reiniciar."))
        elif item.reboot == "recommended":
            chips.addWidget(HubChip("Reinício recomendado", "info", "Funciona melhor após reiniciar."))
        if item.risk in {"elevated", "high"}:
            chips.addWidget(HubChip("Pede privilégio", "warning", "Precisa de elevação administrativa."))
        chips.addStretch(1)
        center.addLayout(chips)

        self.reason_label = QLabel(item.reason)
        self.reason_label.setObjectName("hubCardReason")
        self.reason_label.setWordWrap(True)
        self.reason_label.setVisible(bool(item.reason) and not item.available)
        center.addWidget(self.reason_label)
        layout.addLayout(center, 1)

        controls = QHBoxLayout()
        controls.setSpacing(14)
        self.install_switch: SwitchControl | None = None
        self.tune_switch: SwitchControl | None = None
        if item.install is not None:
            controls.addWidget(self._switch_block("Instalado", "install"), 0, Qt.AlignVCenter)
        if item.tune is not None:
            controls.addWidget(self._switch_block("Otimizado", "tune"), 0, Qt.AlignVCenter)
        if item.actions:
            more = QToolButton()
            more.setObjectName("hubCardMore")
            more.setText("Ações")
            more.setPopupMode(QToolButton.InstantPopup)
            more.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
            more.setIcon(themed_icon(self, "open-menu", QStyle.SP_FileDialogDetailedView))
            more.setAccessibleName(f"Ações de {item.title}")
            menu = QMenu(more)
            for action in item.actions:
                entry = menu.addAction(action.title)
                entry.setToolTip(action.description)
                entry.triggered.connect(lambda _checked=False, target=action: self.action_requested.emit(target))
            more.setMenu(menu)
            controls.addWidget(more, 0, Qt.AlignVCenter)
        layout.addLayout(controls, 0)

        if not item.available:
            self.set_available(False, item.reason)

    def _switch_block(self, caption: str, kind: str) -> QWidget:
        # Legenda ao lado do switch, não acima: o switch já escreve
        # "Ligado/Desligado", e a legenda diz o QUE liga. Separados em linhas
        # diferentes, os dois textos pareciam estados concorrentes.
        block = QWidget()
        row = QHBoxLayout(block)
        row.setContentsMargins(0, 0, 0, 0)
        row.setSpacing(8)
        label = QLabel(caption)
        label.setObjectName("hubSwitchCaption")
        switch = SwitchControl()
        switch.setAccessibleName(f"{caption}: {self.item.title}")
        switch.setTristate(False)
        switch.toggled.connect(lambda checked, which=kind: self._on_toggled(which, checked))
        row.addWidget(label, 0, Qt.AlignVCenter)
        row.addWidget(switch, 0, Qt.AlignVCenter)
        if kind == "install":
            self.install_switch = switch
        else:
            self.tune_switch = switch
        return block

    def _on_toggled(self, kind: str, checked: bool) -> None:
        switch = self.install_switch if kind == "install" else self.tune_switch
        if switch is None or switch.property("syncing"):
            return
        switch.set_pending(True)
        self.toggle_requested.emit(self.item, kind, checked)

    # ------------------------------------------------------------- estado
    def _apply(self, switch: SwitchControl | None, value: bool | None) -> None:
        """Escreve o estado vindo do host sem disparar o handler do usuário."""
        if switch is None:
            return
        switch.setProperty("syncing", True)
        switch.blockSignals(True)
        switch.setChecked(bool(value))
        switch.blockSignals(False)
        switch.setProperty("syncing", False)
        switch.set_pending(False)
        # Estado desconhecido não pode parecer "desligado": o texto diz o que
        # sabemos, e o switch fica inerte até o host responder.
        unknown = value is None
        switch.setEnabled(not unknown and self.property("available") is not False)
        switch.setToolTip("Estado ainda não verificado" if unknown else "")

    def set_state(self, *, installed: bool | None = None, applied: bool | None = None) -> None:
        if self.install_switch is not None:
            self._apply(self.install_switch, installed)
        if self.tune_switch is not None:
            self._apply(self.tune_switch, applied)

    def set_pending(self, kind: str, pending: bool) -> None:
        switch = self.install_switch if kind == "install" else self.tune_switch
        if switch is not None:
            switch.set_pending(pending)

    def revert_pending(self) -> None:
        """Desfaz o movimento otimista quando a operação não aconteceu."""
        for switch in (self.install_switch, self.tune_switch):
            if switch is None or not switch.property("pending"):
                continue
            switch.setProperty("syncing", True)
            switch.blockSignals(True)
            switch.setChecked(not switch.isChecked())
            switch.blockSignals(False)
            switch.setProperty("syncing", False)
            switch.set_pending(False)

    def set_available(self, available: bool, reason: str = "") -> None:
        self.setProperty("available", available)
        _repolish(self)
        for switch in (self.install_switch, self.tune_switch):
            if switch is not None:
                switch.setEnabled(available)
                switch.setToolTip(reason if not available else "")
        if reason:
            self.reason_label.setText(reason)
        self.reason_label.setVisible(bool(reason) and not available)

    def set_busy(self, busy: bool) -> None:
        for switch in (self.install_switch, self.tune_switch):
            if switch is not None:
                switch.setEnabled(not busy and self.property("available") is not False)


class StatusPill(QFrame):
    """A coloured status chip for checklists (BIOS Checker style)."""

    def __init__(self, label: str, state: str, detail: str = "", parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("statusPill")
        self.setProperty("state", state)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 7, 12, 7)
        dot = QLabel("●")
        dot.setObjectName("pillDot")
        dot.setProperty("state", state)
        text = QLabel(label)
        text.setObjectName("pillLabel")
        layout.addWidget(dot)
        layout.addWidget(text)
        layout.addStretch()
        if detail:
            det = QLabel(detail)
            det.setObjectName("pillDetail")
            layout.addWidget(det)


class AdvancedActionsPanel(QFrame):
    """Collapsed contextual access to uncommon or administrative actions."""

    requested = Signal(object)

    def __init__(self, actions: list[ActionSpec], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("advancedPanel")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        toggle = QToolButton()
        toggle.setObjectName("advancedToggle")
        toggle.setText(f"Avançado ({len(actions)})")
        toggle.setCheckable(True)
        toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        toggle.setArrowType(Qt.RightArrow)
        toggle.setAccessibleName("Mostrar ações avançadas")
        layout.addWidget(toggle)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        scroll.setMaximumHeight(300)
        content = QWidget()
        rows = QVBoxLayout(content)
        rows.setContentsMargins(4, 4, 4, 4)
        rows.setSpacing(6)
        for action in actions:
            button = QPushButton(action.title)
            button.setObjectName("advancedAction")
            button.setProperty("actionId", action.id)
            # Ajuda em linguagem humana; a sintaxe CLI fica no Inspector.
            button.setToolTip(action.description)
            button.setAccessibleName(action.title)
            button.clicked.connect(lambda _checked=False, item=action: self.requested.emit(item))
            rows.addWidget(button)
        rows.addStretch()
        scroll.setWidget(content)
        scroll.hide()
        toggle.toggled.connect(scroll.setVisible)
        toggle.toggled.connect(lambda checked: toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow))
        layout.addWidget(scroll)


class ActionListRow(QFrame):
    """Selectable action summary. Execution belongs to the context inspector."""

    selected = Signal(object)

    def __init__(self, action: ActionSpec, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setObjectName("actionListRow")
        self.setProperty("selected", False)
        self.setFocusPolicy(Qt.StrongFocus)
        self.setCursor(Qt.PointingHandCursor)
        self.setAccessibleName(action.title)
        self.setAccessibleDescription(action.description)
        row = QHBoxLayout(self)
        row.setContentsMargins(14, 10, 12, 10)
        row.setSpacing(12)
        icon = QLabel()
        icon.setObjectName("actionRowIcon")
        icon.setPixmap(action_icon(self, action).pixmap(24, 24))
        icon.setFixedSize(32, 32)
        icon.setAlignment(Qt.AlignCenter)
        row.addWidget(icon)
        copy = QVBoxLayout()
        copy.setSpacing(2)
        title = QLabel(action.title)
        title.setObjectName("actionRowTitle")
        description = QLabel(action.description)
        description.setObjectName("actionRowDescription")
        description.setWordWrap(True)
        copy.addWidget(title)
        copy.addWidget(description)
        row.addLayout(copy, 1)
        if action.risk != "normal":
            risk = QLabel("Alto risco" if action.risk == "high" else "Requer admin")
            risk.setObjectName("riskChip")
            risk.setProperty("risk", action.risk)
            row.addWidget(risk)
        next_button = QToolButton()
        next_button.setObjectName("rowChevron")
        next_button.setIcon(themed_icon(self, "go-next", QStyle.SP_ArrowRight))
        next_button.setAccessibleName(f"Selecionar {action.title}")
        next_button.clicked.connect(lambda: self.selected.emit(self.action))
        row.addWidget(next_button)

    def set_selected(self, selected: bool) -> None:
        self.setProperty("selected", selected)
        _repolish(self)

    def mouseReleaseEvent(self, event: QMouseEvent) -> None:
        if event.button() == Qt.LeftButton and self.rect().contains(event.position().toPoint()):
            self.selected.emit(self.action)
        super().mouseReleaseEvent(event)

    def keyPressEvent(self, event) -> None:
        if event.key() in (Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space):
            self.selected.emit(self.action)
            event.accept()
            return
        super().keyPressEvent(event)


class ContextRail(QFrame):
    """Secondary navigation within one product module."""

    section_changed = Signal(int)

    def __init__(self, sections: list[str], parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("contextRail")
        self.setFixedWidth(196)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(8, 8, 8, 8)
        layout.setSpacing(4)
        self.buttons: list[QPushButton] = []
        for index, section in enumerate(sections):
            button = QPushButton(section)
            button.setObjectName("contextRailButton")
            button.setCheckable(True)
            button.setMinimumHeight(48)
            button.setAccessibleName(f"Abrir seção {section}")
            icon_map = {
                "Visão geral": QStyle.SP_DialogApplyButton,
                "Biblioteca e mídia": QStyle.SP_DirOpenIcon,
                "Frontends": QStyle.SP_FileDialogListView,
                "Controles": QStyle.SP_ComputerIcon,
                "Sessão": QStyle.SP_DesktopIcon,
                "Plugins": QStyle.SP_DriveNetIcon,
                "Manutenção": QStyle.SP_BrowserReload,
                "Avançado": QStyle.SP_FileDialogDetailedView,
            }
            button.setIcon(self.style().standardIcon(icon_map.get(section, QStyle.SP_FileIcon)))
            button.clicked.connect(lambda _checked=False, value=index: self.select(value))
            layout.addWidget(button)
            self.buttons.append(button)
        layout.addStretch()
        self.select(0, emit=False)

    def select(self, index: int, *, emit: bool = True) -> None:
        if not 0 <= index < len(self.buttons):
            return
        for current, button in enumerate(self.buttons):
            button.setChecked(current == index)
        if emit:
            self.section_changed.emit(index)


class ActionInspector(QFrame):
    """Single execution surface for the currently selected action."""

    requested = Signal(object)

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action: ActionSpec | None = None
        self._advanced_mode = False
        self.setObjectName("actionInspector")
        self.setMinimumWidth(270)
        self.setMaximumWidth(310)
        self.setAccessibleName("Inspetor de contexto")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(16, 16, 16, 14)
        layout.setSpacing(12)
        layout.setAlignment(Qt.AlignTop)
        heading = QLabel("Inspetor de contexto")
        heading.setObjectName("inspectorHeading")
        layout.addWidget(heading)
        self.body = QStackedWidget()
        empty_page = QWidget()
        empty_layout = QVBoxLayout(empty_page)
        empty_layout.setContentsMargins(0, 0, 0, 0)
        empty_layout.setSpacing(12)
        empty_title = QLabel("Nenhuma operação selecionada")
        empty_title.setObjectName("inspectorTitle")
        empty_layout.addWidget(empty_title)
        self.empty = QLabel("Selecione uma operação para entender impacto, risco e resultado antes de executar.")
        self.empty.setObjectName("inspectorEmpty")
        self.empty.setWordWrap(True)
        empty_layout.addWidget(self.empty)
        for title, value in (
            ("Saúde", "Aguardando seleção"),
            ("Risco", "Será avaliado pela ação"),
            ("Resultado esperado", "Detalhes aparecem aqui"),
        ):
            empty_layout.addWidget(self._section_label(title))
            placeholder = QLabel(value)
            placeholder.setObjectName("inspectorValue")
            placeholder.setWordWrap(True)
            empty_layout.addWidget(placeholder)
        empty_layout.addStretch()
        empty_execute = QPushButton("Executar")
        empty_execute.setObjectName("primaryButton")
        empty_execute.setMinimumHeight(48)
        empty_execute.setEnabled(False)
        empty_layout.addWidget(empty_execute)
        self.content = QWidget()
        content = QVBoxLayout(self.content)
        content.setContentsMargins(0, 0, 0, 0)
        content.setSpacing(12)
        self.icon = QLabel()
        self.icon.setObjectName("inspectorIcon")
        self.icon.setFixedSize(42, 42)
        self.icon.setAlignment(Qt.AlignCenter)
        self.title = QLabel()
        self.title.setObjectName("inspectorTitle")
        self.title.setWordWrap(True)
        self.description = QLabel()
        self.description.setObjectName("inspectorDescription")
        self.description.setWordWrap(True)
        content.addWidget(self.icon)
        content.addWidget(self.title)
        content.addWidget(self.description)
        content.addWidget(self._section_label("Risco"))
        self.risk = QLabel()
        self.risk.setObjectName("inspectorValue")
        self.risk.setWordWrap(True)
        content.addWidget(self.risk)
        content.addWidget(self._section_label("Resultado esperado"))
        self.result = QLabel()
        self.result.setObjectName("inspectorValue")
        self.result.setWordWrap(True)
        content.addWidget(self.result)
        self.command_heading = self._section_label("Detalhes técnicos")
        content.addWidget(self.command_heading)
        self.command = QLineEdit()
        self.command.setObjectName("inspectorCommand")
        self.command.setReadOnly(True)
        content.addWidget(self.command)
        self.command_heading.hide()
        self.command.hide()
        content.addStretch()
        self.execute = QPushButton("Selecionar operação")
        self.execute.setObjectName("primaryButton")
        self.execute.setMinimumHeight(48)
        self.execute.setEnabled(False)
        self.execute.clicked.connect(self._request)
        content.addWidget(self.execute)
        self.body.addWidget(empty_page)
        self.body.addWidget(self.content)
        layout.addWidget(self.body, 1)

    def _section_label(self, text: str) -> QLabel:
        label = QLabel(text)
        label.setObjectName("inspectorSection")
        return label

    def set_action(self, action: ActionSpec) -> None:
        self.action = action
        self.body.setCurrentWidget(self.content)
        self.icon.setPixmap(action_icon(self, action, 30).pixmap(30, 30))
        self.title.setText(action.title)
        self.description.setText(action.description)
        risk_copy = {
            "normal": "Normal — confirmação simples.",
            "elevated": "Administrativo — requer bridge de elevação.",
            "high": "Alto — preview válido e confirmação explícita.",
        }
        self.risk.setText(risk_copy[action.risk])
        result_copy = {
            "auto": "Saída estruturada, feedback de estado e registro no histórico.",
            "log": "Log detalhado com opção de copiar e consultar no histórico.",
            "table": "Dados organizados para inspeção e exportação.",
            "path": "Arquivo ou pasta disponível para abertura ao concluir.",
        }
        self.result.setText(result_copy.get(action.result_view, result_copy["auto"]))
        args = action.preview_args if action.mutable and action.preview_args else action.args
        self.command.setText("linux/pz " + " ".join(args))
        self.command.setCursorPosition(0)
        self.execute.setText("Pré-visualizar" if action.mutable else "Executar")
        self.execute.setEnabled(True)
        self.execute.setAccessibleDescription(f"Executar com segurança: {action.title}")

    def clear_action(self) -> None:
        self.action = None
        self.body.setCurrentIndex(0)

    def set_advanced_mode(self, enabled: bool) -> None:
        self._advanced_mode = bool(enabled)
        self.command_heading.setVisible(self._advanced_mode)
        self.command.setVisible(self._advanced_mode)

    def _request(self) -> None:
        if self.action is not None:
            self.requested.emit(self.action)


class SwitchControl(QCheckBox):
    """Semantic on/off control with an explicit state label and pending state."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("largeSwitch")
        self.setCursor(Qt.PointingHandCursor)
        self.setMinimumSize(126, 30)
        self.setAccessibleDescription("Desligado")
        self.toggled.connect(self._state_changed)

    def sizeHint(self) -> QSize:
        return QSize(126, 30)

    def hitButton(self, pos) -> bool:
        # paintEvent desenha trilho e rótulo por toda a largura; o hit rect
        # padrão do QCheckBox cobre só o indicador nativo (à esquerda, vazio),
        # então clicar no switch visível não alternava nada.
        return self.rect().contains(pos)

    def _state_changed(self, checked: bool) -> None:
        self.setAccessibleDescription("Ligado" if checked else "Desligado")
        self.update()

    def set_pending(self, pending: bool) -> None:
        self.setProperty("pending", pending)
        self.update()

    def paintEvent(self, _event) -> None:
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        pending = bool(self.property("pending"))
        checked = self.isChecked()
        enabled = self.isEnabled()
        palette = self.palette()

        text = "Aplicando…" if pending else "Ligado" if checked else "Desligado"
        text_color = QColor("#b77900") if pending else palette.windowText().color() if enabled else palette.mid().color()
        label_rect = QRectF(0, 0, 76, self.height())
        painter.setPen(text_color)
        painter.drawText(label_rect, Qt.AlignRight | Qt.AlignVCenter, text)

        track = QRectF(self.width() - 44, (self.height() - 24) / 2, 44, 24)
        if pending:
            track_color = QColor("#b77900")
        elif checked:
            track_color = palette.highlight().color() if enabled else palette.mid().color()
        else:
            track_color = palette.mid().color() if enabled else palette.button().color()
        painter.setBrush(track_color)
        painter.setPen(QPen(QColor("#f4b942") if pending else palette.dark().color(), 1))
        painter.drawRoundedRect(track, 12, 12)

        knob_x = track.right() - 20 if checked else track.left() + 4
        painter.setPen(Qt.NoPen)
        painter.setBrush(palette.highlightedText().color() if enabled or pending else palette.mid().color())
        painter.drawEllipse(QRectF(knob_x, track.top() + 4, 16, 16))


class ParameterDialog(QDialog):
    """Typed argument form; command tokens are never evaluated by a shell."""

    def __init__(self, action: ActionSpec, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.action = action
        self.setWindowTitle(action.title)
        fit_to_screen(self, 560, 420)
        layout = QVBoxLayout(self)
        description = QLabel(action.description)
        description.setWordWrap(True)
        description.setObjectName("cardDescription")
        layout.addWidget(description)
        form = QFormLayout()
        self._fields: dict[str, QWidget] = {}
        for parameter in action.parameters:
            if parameter.kind == "choice":
                field = QComboBox()
                field.addItems(parameter.choices)
                if "custom" in parameter.choices:
                    custom_row = QWidget()
                    custom_layout = QHBoxLayout(custom_row)
                    custom_layout.setContentsMargins(0, 0, 0, 0)
                    custom_edit = QLineEdit()
                    custom_edit.setPlaceholderText("Perfil/args customizados")
                    custom_edit.setEnabled(False)
                    custom_edit.setAccessibleName(f"{parameter.label} — valor customizado")
                    custom_label = QLabel("Custom:")
                    custom_label.setVisible(False)
                    custom_layout.addWidget(custom_label)
                    custom_layout.addWidget(custom_edit, 1)
                    form.addRow("", custom_row)
                    self._fields[f"{parameter.name}.custom"] = custom_edit
                    field.currentTextChanged.connect(
                        lambda text, e=custom_edit: e.setEnabled(text == "custom")
                    )
            elif parameter.kind == "boolean":
                field = QCheckBox(parameter.label)
                field.setAccessibleName(parameter.label)
            elif parameter.kind == "secret":
                # Masked on screen and routed to stdin by the runner, so the
                # value never reaches argv or the echoed command line.
                field = QLineEdit()
                field.setEchoMode(QLineEdit.Password)
                field.setPlaceholderText(parameter.placeholder)
                if not getattr(self, "_secret_note_added", False):
                    note = QLabel(
                        "Vai direto para o comando por entrada segura: não aparece em logs, "
                        "na linha de comando nem fica guardada na Central."
                    )
                    note.setObjectName("cardDescription")
                    note.setWordWrap(True)
                    form.addRow("", note)
                    self._secret_note_added = True
            else:
                field = QLineEdit()
                field.setPlaceholderText(parameter.placeholder)
                if parameter.kind in {"file", "path"}:
                    row = QWidget()
                    row_layout = QHBoxLayout(row)
                    row_layout.setContentsMargins(0, 0, 0, 0)
                    row_layout.addWidget(field, 1)
                    browse = QPushButton("Selecionar…")
                    browse.clicked.connect(
                        lambda _checked=False, item=parameter, target=field: self._browse(item.kind, target)
                    )
                    row_layout.addWidget(browse)
                    form.addRow(parameter.label + (":" if parameter.required else " (opcional):"), row)
                    self._fields[parameter.name] = field
                    continue
            field.setAccessibleName(parameter.label)
            form.addRow(parameter.label + (":" if parameter.required else " (opcional):"), field)
            self._fields[parameter.name] = field
        layout.addLayout(form)
        self.error = QLabel("")
        self.error.setObjectName("errorTitle")
        layout.addWidget(self.error)
        buttons = QDialogButtonBox(QDialogButtonBox.Cancel | QDialogButtonBox.Ok)
        buttons.button(QDialogButtonBox.Ok).setText("Continuar")
        buttons.accepted.connect(self._validate)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _browse(self, kind: str, target: QLineEdit) -> None:
        if kind == "file":
            value, _ = QFileDialog.getOpenFileName(self, "Selecionar arquivo")
        else:
            value = QFileDialog.getExistingDirectory(self, "Selecionar pasta")
        if value:
            target.setText(value)

    def _validate(self) -> None:
        values = self.values()
        missing = [parameter.label for parameter in self.action.parameters if parameter.required and not values.get(parameter.name)]
        if missing:
            self.error.setText("Preencha: " + ", ".join(missing))
            return
        self.accept()

    def values(self) -> dict[str, str]:
        values: dict[str, str] = {}
        custom_overrides: dict[str, str] = {}
        for name, field in self._fields.items():
            if isinstance(field, QComboBox):
                values[name] = field.currentText()
            elif isinstance(field, QCheckBox):
                values[name] = "true" if field.isChecked() else ""
            elif isinstance(field, QLineEdit):
                if name.endswith(".custom"):
                    base = name[:-7]
                    custom_text = field.text().strip()
                    if custom_text:
                        custom_overrides[base] = custom_text
                else:
                    values[name] = field.text().strip()
        values.update(custom_overrides)
        return values


class SkeletonTile(QFrame):
    """Gray pulsing block that mimics a layout element during loading."""

    def __init__(self, width: int, height: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonTile")
        self.setFixedSize(width, height)


def start_shimmer(widget: QWidget) -> None:
    """Start a shimmer opacity loop on a skeleton widget."""
    existing = getattr(widget, "_phasezero_shimmer", None)
    if existing is not None:
        return
    if reduced_motion():
        # LUX-021: movimento reduzido — destaque estático, sem animação.
        widget.setProperty("shimmer", "true")
        widget.style().unpolish(widget)
        widget.style().polish(widget)
        return
    effect = QGraphicsOpacityEffect(widget)
    widget.setGraphicsEffect(effect)
    anim = QPropertyAnimation(effect, b"opacity", widget)
    anim.setDuration(1200)
    anim.setStartValue(0.4)
    anim.setKeyValueAt(0.5, 1.0)
    anim.setEndValue(0.4)
    anim.setEasingCurve(QEasingCurve.InOutSine)
    anim.setLoopCount(-1)
    widget.setProperty("shimmer", "true")
    widget.style().unpolish(widget)
    widget.style().polish(widget)
    anim.start()
    widget._phasezero_shimmer = anim  # type: ignore[attr-defined]


def stop_shimmer(widget: QWidget) -> None:
    """Stop shimmer on a widget and reset its appearance."""
    anim = getattr(widget, "_phasezero_shimmer", None)
    if anim is not None:
        anim.stop()
        anim.deleteLater()
        widget._phasezero_shimmer = None  # type: ignore[attr-defined]
    widget.setProperty("shimmer", "")
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class SkeletonCard(QFrame):
    """Mimics an ActionCard: icon tile + title + description + button placeholder."""

    def __init__(self, *, hero: bool = False, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonCard")
        self.setProperty("hero", hero)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(18, 16, 18, 16)
        outer.setSpacing(9)
        heading = QHBoxLayout()
        heading.setSpacing(12)
        heading.addWidget(SkeletonTile(46, 46))
        title_col = QVBoxLayout()
        title_col.setSpacing(4)
        title_col.addWidget(SkeletonTile(160, 14))
        title_col.addWidget(SkeletonTile(100, 10))
        heading.addLayout(title_col, 1)
        outer.addLayout(heading)
        outer.addWidget(SkeletonTile(220, 12))
        outer.addWidget(SkeletonTile(120, 32))

    def showEvent(self, event) -> None:
        super().showEvent(event)
        for tile in self.findChildren(SkeletonTile):
            start_shimmer(tile)

    def hideEvent(self, event) -> None:
        for tile in self.findChildren(SkeletonTile):
            stop_shimmer(tile)
        super().hideEvent(event)


class SkeletonPill(QFrame):
    """Mimics a StatusPill: dot + label + detail placeholders."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("skeletonPill")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 7, 12, 7)
        layout.addWidget(SkeletonTile(8, 8))   # dot
        layout.addWidget(SkeletonTile(140, 14))  # label
        layout.addStretch()
        layout.addWidget(SkeletonTile(80, 10))   # detail

    def showEvent(self, event) -> None:
        super().showEvent(event)
        for tile in self.findChildren(SkeletonTile):
            start_shimmer(tile)

    def hideEvent(self, event) -> None:
        for tile in self.findChildren(SkeletonTile):
            stop_shimmer(tile)
        super().hideEvent(event)


class Toast(QFrame):
    """Auto-dismissing toast in the top-right of its parent."""

    def __init__(self, parent: QWidget, message: str, state: str = "success") -> None:
        super().__init__(parent)
        self.setObjectName("toast")
        self.setProperty("state", state)
        self.setAttribute(Qt.WA_StyledBackground, True)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(14, 10, 14, 10)
        icon = QLabel({"success": "✓", "error": "✕", "warning": "!"}.get(state, "ℹ"))
        icon.setObjectName("toastIcon")
        icon.setProperty("state", state)
        text = QLabel(message)
        text.setObjectName("toastText")
        text.setWordWrap(True)
        layout.addWidget(icon)
        layout.addWidget(text, 1)
        self._effect = QGraphicsOpacityEffect(self)
        self.setGraphicsEffect(self._effect)
        self._anim = QPropertyAnimation(self._effect, b"opacity", self)

    def popup(self, msecs: int = 3200) -> None:
        self.adjustSize()
        parent = self.parentWidget()
        if parent is not None:
            self.move(parent.width() - self.width() - 26, 20)
        self.show()
        self.raise_()
        self._effect.setOpacity(0.0)
        self._anim.stop()
        self._anim.setDuration(220)
        self._anim.setStartValue(0.0)
        self._anim.setEndValue(1.0)
        self._anim.setEasingCurve(QEasingCurve.OutCubic)
        self._anim.start()
        QTimer.singleShot(msecs, self._fade_out)

    def _fade_out(self) -> None:
        self._anim.stop()
        self._anim.setDuration(320)
        self._anim.setStartValue(1.0)
        self._anim.setEndValue(0.0)
        self._anim.setEasingCurve(QEasingCurve.InCubic)
        self._anim.finished.connect(self.deleteLater)
        self._anim.start()


STATE_ICONS = {"success": "✓", "warning": "⚠", "error": "✕", "info": "ℹ", "running": "◐"}

_RESULT_KEYS = {
    "ramMb": "Memória",
    "cpus": "Processadores",
    "graphicsProfile": "Perfil gráfico",
    "diskExists": "Disco",
    "installedLike": "Windows detectado",
    "state": "Estado",
    "status": "Estado",
    "installed": "Instalado",
    "ready": "Pronto",
    "healthy": "Saudável",
    "configured": "Configurado",
    "active": "Ativo",
    "version": "Versão",
    "profile": "Perfil",
    "accessMode": "Acesso",
    "warnings": "Avisos",
    "blockers": "Bloqueios",
    "error": "Problema",
    "message": "Mensagem",
    "summary": "Resumo",
    "next": "Próximo passo",
    "needsUser": "Ação sua",
}


def _friendly_result_key(key: str) -> str:
    if key in _RESULT_KEYS:
        return _RESULT_KEYS[key]
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", key).replace("_", " ").strip()
    return value[:1].upper() + value[1:]


def _friendly_result_value(key: str, value: object) -> str:
    if key == "ramMb" and isinstance(value, (int, float)):
        return f"{value / 1024:g} GB"
    if isinstance(value, bool):
        return "Sim" if value else "Não"
    if value is None:
        return "—"
    if isinstance(value, list):
        return f"{len(value)} item(ns)"
    return str(value)


def _result_facts(value: object, *, limit: int = 12) -> list[tuple[str, str]]:
    facts: list[tuple[str, str]] = []
    if not isinstance(value, dict):
        return facts
    preferred_sections = ("vm", "config", "libvirt", "host", "access", "boot")
    ordered = [key for key in preferred_sections if key in value]
    ordered.extend(key for key in value if key not in ordered)
    for key in ordered:
        item = value[key]
        if isinstance(item, dict):
            for child_key, child in item.items():
                if isinstance(child, (dict, list)):
                    continue
                facts.append((_friendly_result_key(child_key), _friendly_result_value(child_key, child)))
                if len(facts) >= limit:
                    return facts
        elif not isinstance(item, (dict, list)):
            facts.append((_friendly_result_key(key), _friendly_result_value(key, item)))
            if len(facts) >= limit:
                return facts
    return facts


class StructuredResultView(QWidget):
    """Visual summary first; JSON and terminal text behind disclosure."""

    def __init__(
        self,
        value: object = None,
        raw_text: str = "",
        parent: QWidget | None = None,
        *,
        advanced_mode: bool = False,
    ) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        self.summary = QWidget()
        self.summary_layout = QVBoxLayout(self.summary)
        self.summary_layout.setContentsMargins(0, 0, 0, 0)
        self.summary_layout.setSpacing(10)
        layout.addWidget(self.summary)
        self.details_toggle = QToolButton()
        self.details_toggle.setObjectName("technicalDisclosure")
        self.details_toggle.setText("Ver detalhes técnicos")
        self.details_toggle.setCheckable(True)
        self.details_toggle.setChecked(advanced_mode)
        self.details_toggle.setArrowType(Qt.DownArrow if advanced_mode else Qt.RightArrow)
        self.details_toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        layout.addWidget(self.details_toggle)
        self.raw = QPlainTextEdit()
        self.raw.setObjectName("logView")
        self.raw.setReadOnly(True)
        self.raw.setMaximumHeight(240)
        self.raw.setVisible(advanced_mode)
        layout.addWidget(self.raw, 1)
        self.details_toggle.toggled.connect(self.raw.setVisible)
        self.details_toggle.toggled.connect(
            lambda checked: self.details_toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow)
        )
        self.set_result(value, raw_text)

    def set_result(self, value: object, raw_text: str) -> None:
        while self.summary_layout.count():
            item = self.summary_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        if isinstance(value, list) and all(isinstance(item, str) for item in value):
            counts = {"PASS": 0, "WARN": 0, "FAIL": 0, "ERROR": 0, "INFO": 0}
            for item in value:
                for status in counts:
                    if item.startswith(f"[{status}]"):
                        counts[status] += 1
                        break
            row = QHBoxLayout()
            row.addWidget(StatusPill("Tudo certo", "success", str(counts["PASS"])))
            row.addWidget(StatusPill("Avisos", "warning", str(counts["WARN"] + counts["INFO"])))
            row.addWidget(StatusPill("Erros", "error", str(counts["FAIL"] + counts["ERROR"])))
            row.addStretch()
            self.summary_layout.addLayout(row)
        else:
            facts = _result_facts(value)
            if facts:
                grid_host = QWidget()
                grid_host.setSizePolicy(QSizePolicy.Preferred, QSizePolicy.Maximum)
                grid = QGridLayout(grid_host)
                grid.setContentsMargins(0, 0, 0, 0)
                grid.setHorizontalSpacing(10)
                grid.setVerticalSpacing(10)
                for index, (title, fact_value) in enumerate(facts):
                    card = QFrame()
                    card.setObjectName("resultFact")
                    card_layout = QVBoxLayout(card)
                    card_layout.setContentsMargins(12, 10, 12, 10)
                    name = QLabel(title)
                    name.setObjectName("healthMetricLabel")
                    result = QLabel(fact_value)
                    result.setObjectName("resultFactValue")
                    result.setWordWrap(True)
                    card_layout.addWidget(name)
                    card_layout.addWidget(result)
                    grid.addWidget(card, index // 3, index % 3)
                for column in range(3):
                    grid.setColumnStretch(column, 1)
                self.summary_layout.addWidget(grid_host)
            else:
                empty = QLabel("Operação concluída. Nenhum detalhe adicional necessário.")
                empty.setObjectName("cardDescription")
                empty.setWordWrap(True)
                self.summary_layout.addWidget(empty)
        if not raw_text and value is not None:
            raw_text = json.dumps(value, ensure_ascii=False, indent=2)
        self.raw.setPlainText(raw_text[:2_000_000])

    def set_advanced_mode(self, enabled: bool) -> None:
        self.details_toggle.setChecked(bool(enabled))


def sanitized_command(command: list[str]) -> str:
    output: list[str] = []
    redact_next = False
    for token in command:
        if redact_next:
            output.append("[REDACTED]")
            redact_next = False
            continue
        output.append(token)
        redact_next = bool(re.search(r"(?i)(token|secret|password|api[_-]?key)$", token.lstrip("-")))
    return shlex.join(output)


STATE_NAMES_PT = {
    "success": "concluído",
    "warning": "aviso",
    "error": "erro",
    "running": "em andamento",
    "info": "informação",
}


class StatefulDialog(QDialog):
    """Accessible dialog foundation with semantic state header and action footer."""

    def __init__(self, title: str, state: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("statefulDialog")
        self.setProperty("state", state)
        self.setWindowTitle(title)
        fit_to_screen(self, 760, 540)
        outer = QVBoxLayout(self)
        header = QHBoxLayout()
        icon = QLabel(STATE_ICONS.get(state, "ℹ"))
        icon.setObjectName("dialogStateIcon")
        icon.setProperty("state", state)
        # LUX-030: leitor de tela anuncia o estado em português.
        icon.setAccessibleName(f"Estado: {STATE_NAMES_PT.get(state, state)}")
        heading = QLabel(title)
        heading.setObjectName("dialogTitle")
        heading.setProperty("state", state)
        header.addWidget(icon)
        header.addWidget(heading, 1)
        outer.addLayout(header)
        # LUX-012: corpo rola; cabeçalho e rodapé de ações ficam sempre
        # visíveis, mesmo numa tela pequena com escala alta.
        body_host = QWidget()
        body_host.setObjectName("dialogBody")
        self.body = QVBoxLayout(body_host)
        self.body.setContentsMargins(0, 0, 0, 0)
        self.body_scroll = QScrollArea()
        self.body_scroll.setWidgetResizable(True)
        self.body_scroll.setFrameShape(QFrame.NoFrame)
        self.body_scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.body_scroll.setWidget(body_host)
        outer.addWidget(self.body_scroll, 1)
        self.footer = QDialogButtonBox()
        outer.addWidget(self.footer)

    def add_action(
        self,
        label: str,
        role: QDialogButtonBox.ButtonRole,
        *,
        variant: str = "",
        enabled: bool = True,
    ) -> QPushButton:
        button = self.footer.addButton(label, role)
        if variant:
            button.setObjectName(variant)
            _repolish(button)
        if role == QDialogButtonBox.AcceptRole:
            button.setDefault(True)
        button.setEnabled(enabled)
        return button


def _format_space_bytes(value: object) -> str:
    if not isinstance(value, int) or value < 0:
        return "não informado"
    if value < 1024:
        return f"{value} B"
    amount = float(value)
    for unit in ("KiB", "MiB", "GiB", "TiB"):
        amount /= 1024
        if amount < 1024 or unit == "TiB":
            return f"{amount:.1f} {unit}"
    return "não informado"


def _capability_space_lines(payload: object) -> list[str]:
    if not isinstance(payload, dict) or payload.get("kind") != "plan":
        return []
    space = payload.get("space")
    if not isinstance(space, dict):
        return []
    targets = space.get("targets")
    if not isinstance(targets, dict) or not targets:
        targets = {"total": space}
    lines = ["Espaço estimado antes da alteração"]
    scope_labels = {"system": "Sistema", "user": "Usuário", "total": "Total"}
    for scope, target in targets.items():
        if not isinstance(target, dict):
            continue
        label = scope_labels.get(str(scope), str(scope))
        lines.append(
            f"{label}: baixar {_format_space_bytes(target.get('downloadBytes'))} · "
            f"instalação {_format_space_bytes(target.get('installedBytes'))} · "
            f"livre {_format_space_bytes(target.get('availableBytes'))}"
        )
    completeness = str(space.get("estimateCompleteness") or "")
    if completeness == "direct-packages-lower-bound":
        note = "Estimativa parcial: dependências transitivas podem acrescentar espaço."
    elif completeness == "resolved-local-package-indexes":
        note = "Estimativa do gerenciador com índices locais; eles podem estar desatualizados."
    elif completeness == "mixed":
        note = "Estimativa parcial: mistura resolução de transação e metadados diretos."
    else:
        note = "Estimativa parcial; confirme espaço e metadados antes de aplicar."
    lines.append(note)
    return lines


class PreviewDialog(StatefulDialog):
    def __init__(
        self,
        result: OperationResult,
        action: ActionSpec | None = None,
        parent: QWidget | None = None,
        *,
        advanced_mode: bool = False,
    ) -> None:
        blockers = result.parsed.get("blockers") if isinstance(result.parsed, dict) else None
        pending = is_pending_report(result.parsed)
        preview_ok = (result.ok or pending) and not blockers
        dialog_state = "success" if preview_ok and not pending else "warning" if preview_ok else "error"
        state_only = bool(action and action.preview_kind == "state")
        if not preview_ok:
            dialog_title = "Não é seguro aplicar agora"
        elif state_only:
            dialog_title = "Revisar antes de aplicar"
        else:
            dialog_title = "Confirmar operação"
        super().__init__(
            dialog_title,
            dialog_state,
            parent,
        )
        self.action = action
        guide = guidance(result.parsed)
        if not preview_ok:
            # LUX-023: prévia que falhou ou tem bloqueios diz por quê.
            headline = guide["summary"] or (
                "A verificação encontrou bloqueios." if blockers
                else "A verificação prévia falhou; nada foi alterado."
            )
        elif state_only:
            # LUX-001: a leitura de estado não simula a mudança; nunca
            # chamá-la de preview concluído.
            headline = guide["summary"] or "Estado atual — isto não simula a mudança."
        else:
            headline = guide["summary"] or "Preview concluído. Nenhuma mutação foi executada."
        next_step = guide["next_action"]
        summary = QLabel(headline)
        summary.setWordWrap(True)
        summary.setObjectName("cardDescription")
        self.body.addWidget(summary)
        for index, line in enumerate(_capability_space_lines(result.parsed)):
            space_label = QLabel(line)
            space_label.setObjectName("capabilitySpaceSummary" if index == 0 else "capabilitySpaceDetail")
            space_label.setAccessibleName(line)
            space_label.setWordWrap(True)
            self.body.addWidget(space_label)
        if not preview_ok:
            items = [str(item) for item in blockers] if isinstance(blockers, list) else []
            for item in items[:8]:
                blocker = QLabel(f"• {item}")
                blocker.setObjectName("errorText")
                blocker.setWordWrap(True)
                self.body.addWidget(blocker)
            unlock = QLabel(
                "Resolva os bloqueios acima e tente de novo." if items
                else "Veja os detalhes técnicos para a causa e tente de novo."
            )
            unlock.setObjectName("cardDescription")
            unlock.setWordWrap(True)
            self.body.addWidget(unlock)
            self.blocked_reason = unlock
        if state_only and action is not None:
            impact = QLabel(f"O que vai acontecer: {action.impact or action.description}")
            impact.setObjectName("impactText")
            impact.setWordWrap(True)
            self.body.addWidget(impact)
            self.impact_label = impact
        for reason in guide["reasons"]:
            reason_label = QLabel(f"• {reason}")
            reason_label.setWordWrap(True)
            reason_label.setObjectName("cardDescription")
            self.body.addWidget(reason_label)
        if next_step:
            follow = QLabel(f"Próximo passo: {next_step}")
            follow.setWordWrap(True)
            follow.setObjectName("cardDescription")
            self.body.addWidget(follow)
        chips = QHBoxLayout()
        chips.addWidget(StatusPill(
            "Pendente" if pending else "Preview",
            "success" if preview_ok and not pending else "warning" if pending else "error",
        ))
        chips.addWidget(StatusPill("Admin", "warning" if action and action.elevated else "info", "necessário" if action and action.elevated else "não"))
        chips.addStretch()
        self.body.addLayout(chips)
        if isinstance(result.parsed, dict):
            warnings = result.parsed.get("warnings", None)
            if warnings and isinstance(warnings, list) and len(warnings) > 0:
                warn_box = QWidget()
                warn_layout = QVBoxLayout(warn_box)
                warn_layout.setContentsMargins(0, 0, 0, 0)
                warn_layout.setSpacing(4)
                for w in warnings:
                    row = QHBoxLayout()
                    row.setContentsMargins(0, 0, 0, 0)
                    pill = StatusPill("atenção", "warning")
                    label = QLabel(w)
                    label.setWordWrap(True)
                    row.addWidget(pill)
                    row.addWidget(label, 1)
                    warn_layout.addLayout(row)
                self.body.addWidget(warn_box)
        self.details_toggle = QToolButton()
        self.details_toggle.setObjectName("technicalDisclosure")
        self.details_toggle.setText("Ver detalhes técnicos")
        self.details_toggle.setCheckable(True)
        self.details_toggle.setChecked(advanced_mode)
        self.details_toggle.setArrowType(Qt.DownArrow if advanced_mode else Qt.RightArrow)
        self.details_toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.body.addWidget(self.details_toggle)
        self.technical = QWidget()
        technical_layout = QVBoxLayout(self.technical)
        technical_layout.setContentsMargins(0, 0, 0, 0)
        command = QLineEdit(sanitized_command(result.command))
        command.setObjectName("commandBar")
        command.setReadOnly(True)
        command.setAccessibleName("Comando sanitizado")
        technical_layout.addWidget(command)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setObjectName("logView")
        self.output.setPlainText(result.stdout + ("\n[stderr]\n" + result.stderr if result.stderr else ""))
        technical_layout.addWidget(self.output, 1)
        self.body.addWidget(self.technical, 1)
        self.technical.setVisible(advanced_mode)
        self.details_toggle.toggled.connect(self.technical.setVisible)
        self.details_toggle.toggled.connect(
            lambda checked: self.details_toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow)
        )
        # LUX-031: o que é copiado é o detalhe técnico, visível ou não.
        copy = self.add_action("Copiar detalhes técnicos", QDialogButtonBox.ActionRole)
        copy.clicked.connect(lambda: QApplication.clipboard().setText(self.output.toPlainText()))
        cancel = self.add_action("Voltar", QDialogButtonBox.RejectRole)
        self.confirm = self.add_action(
            "Confirmar e aplicar",
            QDialogButtonBox.AcceptRole,
            variant="dangerButton" if action and action.risk == "high" else "primaryButton",
            enabled=preview_ok and not (action and action.risk == "high"),
        )
        if action and action.risk == "high":
            warning = QLabel("Alto risco: digite CONFIRMAR para liberar a execução.")
            warning.setObjectName("errorTitle")
            self.confirmation = QLineEdit()
            self.confirmation.setPlaceholderText("CONFIRMAR")
            self.confirmation.setAccessibleName("Confirmação de alto risco")
            self.confirmation.textChanged.connect(
                lambda text: self.confirm.setEnabled(preview_ok and text.strip() == "CONFIRMAR")
            )
            anchor = getattr(self, "impact_label", None) or summary
            position = self.body.indexOf(anchor) + 1
            self.body.insertWidget(position, warning)
            self.body.insertWidget(position + 1, self.confirmation)
            # LUX-025: Tab do campo vai direto ao botão que ele libera.
            QWidget.setTabOrder(self.confirmation, self.confirm)
            self.confirmation.setFocus()
        cancel.clicked.connect(self.reject)
        self.confirm.clicked.connect(self.accept)


class ProgressDialog(StatefulDialog):
    cancel_requested = Signal()
    hidden_while_running = Signal()

    def __init__(
        self,
        title: str,
        command: str,
        parent: QWidget | None = None,
        *,
        advanced_mode: bool = False,
    ) -> None:
        super().__init__(title, "running", parent)
        self._started = time.monotonic()
        self._running = True
        summary = QLabel("Aguarde. O PhaseZero está cuidando desta etapa.")
        summary.setObjectName("cardDescription")
        self.body.addWidget(summary)
        self.details_toggle = QToolButton()
        self.details_toggle.setObjectName("technicalDisclosure")
        self.details_toggle.setText("Ver detalhes técnicos")
        self.details_toggle.setCheckable(True)
        self.details_toggle.setChecked(advanced_mode)
        self.details_toggle.setArrowType(Qt.DownArrow if advanced_mode else Qt.RightArrow)
        self.details_toggle.setToolButtonStyle(Qt.ToolButtonTextBesideIcon)
        self.body.addWidget(self.details_toggle)
        self.technical = QWidget()
        technical_layout = QVBoxLayout(self.technical)
        technical_layout.setContentsMargins(0, 0, 0, 0)
        self.command = QLineEdit(command)
        self.command.setObjectName("commandBar")
        self.command.setReadOnly(True)
        technical_layout.addWidget(self.command)
        self.elapsed = QLabel("Tempo: 00:00")
        self.elapsed.setObjectName("pathLabel")
        self.body.addWidget(self.elapsed)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.body.addWidget(self.progress)
        self.log = QPlainTextEdit()
        self.log.setObjectName("logView")
        self.log.setReadOnly(True)
        self.log.document().setMaximumBlockCount(300)
        technical_layout.addWidget(self.log, 1)
        self.body.addWidget(self.technical, 1)
        self.technical.setVisible(advanced_mode)
        self.details_toggle.toggled.connect(self.technical.setVisible)
        self.details_toggle.toggled.connect(
            lambda checked: self.details_toggle.setArrowType(Qt.DownArrow if checked else Qt.RightArrow)
        )
        cancel = self.add_action("Cancelar operação", QDialogButtonBox.RejectRole, variant="dangerButton")
        cancel.clicked.connect(self.cancel_requested.emit)
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)
        self._timer.start(1000)

    def _tick(self) -> None:
        elapsed = int(time.monotonic() - self._started)
        self.elapsed.setText(f"Tempo: {elapsed // 60:02d}:{elapsed % 60:02d}")

    def append_output(self, text: str, error: bool = False) -> None:
        prefix = "[stderr] " if error else ""
        self.log.appendPlainText(prefix + text.rstrip())
        scrollbar = self.log.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())

    def set_progress(self, value: int) -> None:
        self.progress.setRange(0, 100)
        self.progress.setValue(value)

    def finish(self) -> None:
        self._running = False
        self._timer.stop()
        self.accept()

    def reject(self) -> None:
        # LUX-002: Esc/fechar só esconde; a operação continua e o botão
        # "Mostrar progresso" da barra de status reabre esta janela.
        if self._running:
            self.hide()
            self.hidden_while_running.emit()
            return
        super().reject()


class ResultDialog(StatefulDialog):
    history_requested = Signal()
    resolution_requested = Signal(str)
    retry_requested = Signal(object)

    def __init__(
        self,
        result: OperationResult,
        formatted: str,
        parent: QWidget | None = None,
        *,
        severity: str | None = None,
        advanced_mode: bool = False,
    ) -> None:
        sev = severity or ("success" if result.ok else "error")
        title_map = {"success": "Operação concluída", "warning": "Concluído com avisos", "error": "Operação falhou"}
        title = title_map.get(sev, "Operação falhou")
        if restart_required(result.parsed):
            title = "Reinício necessário"
        super().__init__(title, sev, parent)
        fit_to_screen(self, 760, 480)
        self.formatted = formatted
        message = {
            "success": "Tudo pronto. A operação terminou como esperado.",
            "warning": "A operação terminou, mas alguns itens precisam de revisão.",
            "error": "Não foi possível concluir. Revise a solução recomendada abaixo.",
        }.get(sev, "Revise o resultado.")
        if isinstance(result.parsed, dict):
            guide = guidance(result.parsed)
            human = guide["summary"]
            nxt = guide["next_action"]
            parts = [part for part in (human, f"Próximo passo: {nxt}" if nxt else "") if part]
            if parts:
                message = "\n".join(parts)
        if getattr(result, "timed_out", False):
            message = (
                "A operação passou do tempo limite e foi interrompida.\n"
                "Nada além do que apareceu na saída foi feito. Você pode tentar de novo."
            )
        if sev == "error" and message in {
            "Não foi possível concluir. Revise a solução recomendada abaixo.",
        }:
            detail = ""
            if isinstance(result.parsed, dict):
                detail = str(result.parsed.get("error") or result.parsed.get("message") or "")
                blockers = result.parsed.get("blockers")
                if not detail and isinstance(blockers, list) and blockers:
                    detail = str(blockers[0])
            if not detail and result.stderr.strip():
                detail = result.stderr.strip().splitlines()[0]
            if detail:
                message = detail[:300]
        summary = QLabel(message)
        summary.setObjectName("resultSummary")
        summary.setWordWrap(True)
        self.summary_label = summary
        self.body.addWidget(summary)
        self.view = StructuredResultView(
            result.parsed, formatted, self, advanced_mode=advanced_mode
        )
        self.body.addWidget(self.view, 1)
        copy = self.add_action("Copiar detalhes", QDialogButtonBox.ActionRole)
        copy.clicked.connect(lambda: QApplication.clipboard().setText(formatted))
        if result.result_path is not None:
            open_folder = self.add_action("Abrir pasta técnica", QDialogButtonBox.ActionRole)
            open_folder.clicked.connect(lambda: open_path(result.result_path.parent))
        history = self.add_action("Histórico", QDialogButtonBox.ActionRole)
        history.clicked.connect(self.history_requested.emit)
        if sev in {"warning", "error"}:
            if getattr(result, "timed_out", False):
                retry = self.add_action("Tentar novamente", QDialogButtonBox.AcceptRole, variant="primaryButton")
                # OperationResult expõe action_id; result.action levantava
                # AttributeError dentro do slot e o botão morria.
                retry.clicked.connect(lambda: self.retry_requested.emit(result.action_id))
                retry.clicked.connect(self.accept)
            if result.action_id.startswith("windows."):
                label = "Revisar Windows VM"
            elif result.action_id.startswith("ai.proxies") or result.action_id.startswith("ai.9router"):
                label = "Revisar Proxies IA"
            elif result.action_id.startswith("ai."):
                label = "Revisar IA & Dev"
            else:
                label = "Ver solução"
            resolution = self.add_action(label, QDialogButtonBox.AcceptRole, variant="primaryButton")
            resolution.clicked.connect(lambda: self.resolution_requested.emit(result.action_id))
            resolution.clicked.connect(self.accept)
        close = self.add_action(
            "Fechar", QDialogButtonBox.RejectRole if sev in {"warning", "error"} else QDialogButtonBox.AcceptRole,
            variant="" if sev in {"warning", "error"} else "primaryButton",
        )
        close.clicked.connect(self.accept)
