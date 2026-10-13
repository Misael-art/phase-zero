from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QTimer, Signal
from PySide6.QtWidgets import QFrame, QGridLayout, QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..product_inventory import target_for
from ..status_loader import StatusLoader
from ..result_parser import guidance, severity_for
from ..widgets import AdvancedActionsPanel, SkeletonCard, SkeletonTile, stop_shimmer


class BasePage(QWidget):
    """Base class for every category page."""

    action_requested = Signal(object)
    actions_requested = Signal(object)
    action_selected = Signal(object)
    # UX-006: a goal card may lead to the page where that goal is actually
    # carried out, instead of firing one action and leaving the operator to
    # find the rest of the journey in the sidebar. The second argument names
    # the journey to bring forward once that page is shown.
    category_requested = Signal(str, str)

    def __init__(
        self,
        root: Path,
        runner: CommandRunner,
        actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.root = root
        self.runner = runner
        self.actions = actions
        self.by_id = by_id or {}
        self.status_loader = StatusLoader(root, self)
        self._layout = QVBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._layout.setSpacing(0)
        self._skeleton_grid: QGridLayout | None = None
        self._loading_timer = QTimer(self)
        self._loading_timer.setSingleShot(True)
        self._loading_callback = None
        self._loading_timer.timeout.connect(self._show_delayed_loading)
        self._represented_ids: set[str] = set()
        self._advanced_ids: set[str] = set()
        self._advanced_mode = False
        self._advanced_panels: list[QWidget] = []
        self._context_status_action: ActionSpec | None = None
        self._context_status: QFrame | None = None
        self.status_loader.status_ready.connect(self._context_status_ready)
        self.status_loader.status_failed.connect(self._context_status_failed)

    def build(self) -> None:
        pass

    def reload(self) -> None:
        self.reload_context_status()

    def block_while_running(self, running: bool) -> None:
        pass

    def cancel_pending_action(self, _action_id: str) -> None:
        """Restore optimistic controls when a preview is rejected or cannot start."""
        pass

    def set_advanced_mode(self, enabled: bool) -> None:
        self._advanced_mode = bool(enabled)
        for panel in self._advanced_panels:
            panel.setVisible(self._advanced_mode)

    def show_skeletons(self, count: int = 6, columns: int = 3) -> QGridLayout:
        """Show N skeleton cards in a grid. Returns the grid for layout positioning."""
        self.clear_skeletons()
        container = QWidget()
        grid = QGridLayout(container)
        grid.setContentsMargins(2, 2, 8, 8)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        for index in range(count):
            card = SkeletonCard()
            grid.addWidget(card, index // columns, index % columns)
        for col in range(columns):
            grid.setColumnStretch(col, 1)
        self._layout.addWidget(container)
        container.setObjectName("_skeleton_container")
        self._skeleton_grid = grid
        return grid

    def begin_loading(self, callback, delay_ms: int = 200) -> None:
        """Schedule loading placeholders, avoiding flashes for fast status calls."""
        self.finish_loading()
        self._loading_callback = callback
        self._loading_timer.start(max(0, delay_ms))

    def _show_delayed_loading(self) -> None:
        callback = self._loading_callback
        self._loading_callback = None
        if callback is not None:
            callback()

    def finish_loading(self) -> None:
        self._loading_timer.stop()
        self._loading_callback = None
        self.clear_skeletons()

    def clear_skeletons(self) -> None:
        """Remove all skeleton cards from the page."""
        container = self.findChild(QWidget, "_skeleton_container")
        if container is not None:
            for tile in container.findChildren(SkeletonTile):
                stop_shimmer(tile)
            self._layout.removeWidget(container)
            container.setParent(None)
            container.deleteLater()
        self._skeleton_grid = None

    def cancel_status(self) -> None:
        self._loading_timer.stop()
        self.status_loader.cancel_all()
        self.clear_skeletons()

    def request_action(self, action: ActionSpec) -> None:
        try:
            target = target_for(action)
        except ValueError:
            target = None
        if target is not None and target.target_kind == "app":
            # Legacy/custom-page app buttons are shortcuts. Route them through
            # the canonical product detail so its observed state chooses the
            # next action; the detail page emits its own action_requested only
            # after the operator chooses Prepare/Configure/Resolve.
            self.action_selected.emit(action)
            return
        self.action_requested.emit(action)

    def request_category(self, category: str, focus: str = "") -> None:
        """UX-006: go to the page that carries out this goal."""
        self.category_requested.emit(category, focus)

    def focus_journey(self, key: str) -> None:
        """Bring the journey named by ``key`` forward on this page.

        The default is a no-op: a page without a specific entry point is
        simply shown. Pages that own a multi-step journey override this so
        arriving from a goal card lands on the right step.
        """

    def request_actions(self, actions: list[ActionSpec]) -> None:
        if actions:
            self.actions_requested.emit(actions)

    def run_action(self, action_id: str) -> None:
        action = self.by_id.get(action_id)
        if action is not None:
            self.request_action(action)

    def find(self, action_id: str) -> ActionSpec | None:
        action = self.by_id.get(action_id)
        if action is not None and action.category in {item.category for item in self.actions}:
            self._represented_ids.add(action.id)
        return action

    def mark_represented(self, action: ActionSpec) -> None:
        self._represented_ids.add(action.id)

    def finalize_action_coverage(self) -> None:
        self._install_context_status()
        remaining = [action for action in self.actions if action.id not in self._represented_ids]
        if not remaining:
            return
        panel = AdvancedActionsPanel(remaining)
        panel.requested.connect(self.request_action)
        panel.setVisible(self._advanced_mode)
        self._advanced_panels.append(panel)
        self._advanced_ids = {action.id for action in remaining}
        self._layout.addWidget(panel)

    def _install_context_status(self) -> None:
        if self._context_status is not None or not self.actions:
            return
        if self._context_status_action is None:
            candidates = [
                action for action in self.actions
                if not action.mutable
                and action.status_args
                and not action.parameters
                and not any(token.startswith("{") for token in action.status_args)
            ]
            preferred = [
                action for action in candidates
                if any(term in action.id for term in (".status", ".doctor", ".check", ".list"))
            ]
            if not preferred and not candidates:
                return
            self._context_status_action = (preferred or candidates)[0]
        action = self._context_status_action
        if action.mutable or action.parameters or not action.status_args:
            return
        frame = QFrame()
        frame.setObjectName("contextStatus")
        row = QHBoxLayout(frame)
        row.setContentsMargins(12, 8, 12, 8)
        copy = QVBoxLayout()
        copy.setSpacing(1)
        heading = QLabel("Saúde do módulo")
        heading.setObjectName("contextStatusHeading")
        label = QLabel("Saúde: aguardando verificação")
        label.setObjectName("contextStatusText")
        label.setAccessibleName("Resumo de saúde da página")
        copy.addWidget(heading)
        copy.addWidget(label)
        retry = QPushButton("Atualizar")
        retry.setObjectName("secondaryButton")
        retry.clicked.connect(self.reload_context_status)
        row.addLayout(copy, 1)
        row.addWidget(retry)
        self._context_status = frame
        self._layout.insertWidget(0, frame)

    def reload_context_status(self) -> None:
        action = self._context_status_action
        if action is None or self.status_loader.running(action.id):
            return
        label = self._context_status.findChild(QLabel, "contextStatusText") if self._context_status else None
        if label is not None:
            label.setText("Saúde: verificando…")
        self.status_loader.fetch_action(action)

    def _context_status_ready(self, action_id: str, stdout: str, parsed: object) -> None:
        action = self._context_status_action
        if action is None or action.id != action_id or self._context_status is None:
            return
        state = severity_for(parsed, 0)
        guide = guidance(parsed)
        detail = "OK" if state == "success" else "Atenção" if state == "warning" else "Verificar"
        label = self._context_status.findChild(QLabel, "contextStatusText")
        if label is not None:
            suffix = f" — {guide['next_action']}" if guide["next_action"] and state != "success" else f" — {action.title}"
            label.setText(f"Saúde: {detail}{suffix}")
            label.setProperty("state", state)
            label.style().unpolish(label)
            label.style().polish(label)

    def _context_status_failed(self, action_id: str, message: str) -> None:
        action = self._context_status_action
        if action is None or action.id != action_id or self._context_status is None:
            return
        label = self._context_status.findChild(QLabel, "contextStatusText")
        if label is not None:
            # Falha de LEITURA ≠ estado ruim: orienta repetir em vez de assustar.
            cause = "" if message.startswith("exit code") or message == "timed out" else f" ({message})"
            label.setText(f"Saúde: não foi possível verificar{cause} — clique para tentar de novo")
            label.setProperty("state", "warning")
            label.style().unpolish(label)
            label.style().polish(label)

    @property
    def represented_action_ids(self) -> set[str]:
        return self._represented_ids | self._advanced_ids
