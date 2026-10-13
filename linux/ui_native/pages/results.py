from __future__ import annotations

import json
import os
import re
import zipfile
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QApplication,
    QFileDialog, QFrame, QHBoxLayout, QHeaderView,
    QMessageBox, QPushButton, QSplitter, QTableWidget, QTableWidgetItem,
    QVBoxLayout, QWidget,
)

from ..command_runner import CommandRunner
from ..models import ActionSpec
from ..platform import open_path, state_dir
from ..widgets import StructuredResultView
from .base import BasePage


_EXPORT_SECRET_PATTERNS = (
    re.compile(r'(?i)(authorization:\s*bearer\s+)(\S+)'),
    re.compile(
        r'(?i)(["\']?(?:access[_-]?token|refresh[_-]?token|client[_-]?secret|api[_-]?key|password|passwd|authorization|cookie|session)["\']?\s*[:=]\s*["\']?)([^\s,"\';}]+)'
    ),
    re.compile(r'(?i)(\b(?:token|key|secret|password)=)([^&\s]+)'),
)


def _redact_export_text(text: str) -> str:
    for pattern in _EXPORT_SECRET_PATTERNS:
        text = pattern.sub(r"\1[REDACTED]", text)
    return text


def create_safe_results_archive(source: Path, archive_path: Path) -> Path:
    """Export bounded, redacted results/logs; never include runtime auth files."""
    candidates = [
        (path, f"results/{path.name}")
        for path in sorted((source / "ui" / "results").glob("*.json"))
    ]
    candidates.extend(
        (path, f"results/{path.name}")
        for path in sorted((source / "control-center" / "results").glob("*.json"))
    )
    candidates.extend(
        (path, f"operations/{path.parent.name}/operation.json")
        for path in sorted((source / "control-center" / "operations").glob("*/operation.json"))
    )
    candidates.extend(
        (path, f"logs/{path.name}") for path in sorted(source.glob("*.log"))
    )
    candidates = candidates[-500:]
    total = 0
    limit_per_file = 8 * 1024 * 1024
    limit_total = 64 * 1024 * 1024
    temp = archive_path.with_name(f".{archive_path.name}.{os.getpid()}.tmp")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        with zipfile.ZipFile(temp, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path, member in candidates:
                if not path.is_file() or path.is_symlink():
                    continue
                size = path.stat().st_size
                if size > limit_per_file or total + size > limit_total:
                    continue
                content = path.read_text(encoding="utf-8", errors="replace")
                archive.writestr(member, _redact_export_text(content))
                total += size
        os.replace(temp, archive_path)
        archive_path.chmod(0o600)
    except Exception:
        temp.unlink(missing_ok=True)
        raise
    return archive_path


class ResultsPage(BasePage):
    """Operation history as a QTableWidget (sortable columns) + detail pane."""

    def __init__(
        self, root: Path, runner: CommandRunner, actions: list[ActionSpec],
        by_id: dict[str, ActionSpec] | None = None, parent: QWidget | None = None,
    ) -> None:
        super().__init__(root, runner, actions, by_id, parent)
        self.table: QTableWidget | None = None
        self.detail: StructuredResultView | None = None
        self.retry_button: QPushButton | None = None
        self._retry_action_id = ""

    def build(self) -> None:
        toolbar = QHBoxLayout()
        refresh = QPushButton("Atualizar")
        refresh.clicked.connect(self.reload)
        self.retry_button = QPushButton("Tentar novamente")
        self.retry_button.setObjectName("primaryButton")
        self.retry_button.setEnabled(False)
        self.retry_button.setToolTip("Executa nova prévia e pede confirmação antes de repetir.")
        self.retry_button.clicked.connect(self._retry_selected)
        folder = QPushButton("Abrir pasta")
        folder.clicked.connect(self._open_folder)
        export = QPushButton("Exportar ZIP")
        export.clicked.connect(self._export)
        toolbar.addWidget(refresh)
        toolbar.addWidget(self.retry_button)
        toolbar.addWidget(folder)
        toolbar.addWidget(export)
        toolbar.addStretch()
        self._layout.addLayout(toolbar)

        splitter = QSplitter()
        self.table = QTableWidget()
        self.table.setColumnCount(3)
        self.table.setHorizontalHeaderLabels(["Operação", "Estado", "Data"])
        self.table.setAlternatingRowColors(True)
        self.table.setSelectionBehavior(QTableWidget.SelectRows)
        self.table.setSelectionMode(QTableWidget.SingleSelection)
        self.table.setEditTriggers(QTableWidget.NoEditTriggers)
        # Keep Tab traversal moving out of the table to the result detail pane;
        # arrow keys remain available for row navigation.
        self.table.setTabKeyNavigation(False)
        self.table.horizontalHeader().setStretchLastSection(False)
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeToContents)
        self.table.setSortingEnabled(True)
        self.table.itemSelectionChanged.connect(self._show_selected)
        self.table.setObjectName("historyTable")
        splitter.addWidget(self.table)

        self.detail = StructuredResultView()
        splitter.addWidget(self.detail)
        splitter.setSizes([360, 620])
        self._layout.addWidget(splitter, 1)

    def reload(self) -> None:
        if self.table is None:
            return
        self.table.setSortingEnabled(False)
        self.table.setRowCount(0)
        result_dir = state_dir() / "results"
        rows = []
        linked_results: set[str] = set()
        status_labels = {
            "starting": "Iniciando",
            "previewing": "Prévia",
            "running": "Em andamento",
            "cancelling": "Cancelando",
            "succeeded": "OK",
            "failed": "Falha",
            "cancelled": "Cancelada",
            "interrupted": "Interrompida",
        }
        operation_dir = state_dir() / "operations"
        if operation_dir.exists():
            for path in sorted(operation_dir.glob("*/operation.json"), reverse=True)[:250]:
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeError, json.JSONDecodeError):
                    continue
                result_path = str(data.get("resultPath") or "")
                if result_path:
                    linked_results.add(result_path)
                state = str(data.get("status") or "unknown")
                rows.append((
                    str(data.get("title") or data.get("actionId") or path.parent.name),
                    status_labels.get(state, state),
                    str(data.get("updatedAt") or data.get("startedAt") or ""),
                    str(path),
                ))
        if result_dir.exists():
            for path in sorted(result_dir.glob("*.json"), reverse=True)[:250]:
                if str(path) in linked_results:
                    continue
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeError, json.JSONDecodeError):
                    continue
                rows.append((
                    str(data.get("action", path.stem)),
                    "OK" if data.get("ok") else "Falha",
                    str(data.get("finishedAt", "")),
                    str(path),
                ))
        phasezero_state = state_dir().parent
        for path in sorted(phasezero_state.glob("*.log")):
            rows.append((path.name, "Log", "", str(path)))
        self.table.setRowCount(len(rows))
        for i, (action, status, finished, path_str) in enumerate(rows):
            self.table.setItem(i, 0, QTableWidgetItem(action))
            self.table.setItem(i, 1, QTableWidgetItem(status))
            self.table.setItem(i, 2, QTableWidgetItem(finished))
            self.table.item(i, 0).setData(Qt.UserRole, path_str)
        self.table.setSortingEnabled(True)
        if not rows:
            self.table.setRowCount(1)
            placeholder = QTableWidgetItem("Nenhuma operação ainda — execute uma ação na página Início.")
            placeholder.setFlags(Qt.ItemIsEnabled)
            self.table.setItem(0, 0, placeholder)

    def _show_selected(self) -> None:
        if self.table is None or self.detail is None:
            return
        row = self.table.currentRow()
        if row < 0:
            return
        first = self.table.item(row, 0)
        path_str = first.data(Qt.UserRole) if first is not None else ""
        if not path_str:
            return
        path = Path(path_str)
        self._retry_action_id = ""
        if self.retry_button is not None:
            self.retry_button.setEnabled(False)
        try:
            if path.stat().st_size > 8 * 1024 * 1024:
                self.detail.set_result(None, "Arquivo excede limite de visualização de 8 MiB.")
                return
            if path.suffix == ".json":
                data = json.loads(path.read_text(encoding="utf-8"))
                if data.get("resumable") is True and isinstance(data.get("nextAction"), str):
                    action_id = str(data["nextAction"])
                    if action_id in self.by_id:
                        self._retry_action_id = action_id
                        if self.retry_button is not None:
                            self.retry_button.setEnabled(True)
                raw = json.dumps(data, ensure_ascii=False, indent=2)
                self.detail.set_result(data.get("result", data), raw)
            else:
                self.detail.set_result(None, path.read_text(errors="replace"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            self.detail.set_result(None, str(exc))

    def _retry_selected(self) -> None:
        action = self.by_id.get(self._retry_action_id)
        if action is None:
            return
        # Explicit retry resumes the previously selected operation through
        # its confirmation flow; it is not a shortcut into app navigation.
        self.action_requested.emit(action)

    def _open_folder(self) -> None:
        folder = state_dir().parent
        folder.mkdir(parents=True, exist_ok=True)
        if not open_path(folder):
            QApplication.clipboard().setText(str(folder))
            QMessageBox.warning(
                self, "Abrir pasta",
                f"Não foi possível abrir {folder}\nO caminho foi copiado para a área de transferência.",
            )

    def _export(self) -> None:
        source = state_dir().parent
        source.mkdir(parents=True, exist_ok=True)
        target, _ = QFileDialog.getSaveFileName(
            self, "Exportar logs e resultados",
            str(Path.home() / "phasezero-results.zip"),
            "Arquivo ZIP (*.zip)",
        )
        if not target:
            return
        if target.casefold().endswith(".zip"):
            target = target[:-4]
        archive_path = Path(target + ".zip").expanduser().resolve()
        try:
            archive_path.relative_to(source.resolve())
        except ValueError:
            pass
        else:
            QMessageBox.warning(
                self, "Destino inválido",
                "Salve o ZIP fora da pasta de resultados para evitar arquivo recursivo.",
            )
            return
        try:
            archive = create_safe_results_archive(source, archive_path)
        except (OSError, ValueError, zipfile.BadZipFile) as exc:
            QMessageBox.critical(self, "Falha ao exportar", str(exc))
            return
        QMessageBox.information(self, "Exportação concluída", str(archive))

    def block_while_running(self, running: bool) -> None:
        if self.retry_button is not None:
            self.retry_button.setEnabled(not running and bool(self._retry_action_id))

    def set_advanced_mode(self, enabled: bool) -> None:
        super().set_advanced_mode(enabled)
        if self.detail is not None:
            self.detail.set_advanced_mode(enabled)
