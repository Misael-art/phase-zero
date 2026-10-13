"""Layperson surface for managing Windows ISO images.

``ImageManagerDialog`` unifies the fragmented image lifecycle — find a
registered ISO, read its basic characteristics per WIM index, play it in
the provision player, enable direct boot, restore GRUB, or remove it — into
one modal launched from the Windows VM page.

Reuse contract (no duplicate logic):
- characteristics + WIM index list come from the existing ``media inspect``
  JSON produced by ``linux/windows-vm/media-inspect.sh``;
- candidate discovery reuses ``media scan`` (same script);
- play delegates to :class:`provision_player.ProvisionPlayerWindow`;
- boot / GRUB restore are emitted as pending actions so the main window
  runs them through the normal elevated, preview-first confirmation flow;
- registry state is owned by :mod:`image_registry`.

The ISO file on disk is never ``unlink``-ed; the only destructive option is
``QFile.moveToTrash`` (reversible) and it always requires explicit consent.
"""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import QFile, QObject, QProcess, QTimer, Qt, Signal
from PySide6.QtWidgets import (
    QDialog,
    QFileDialog,
    QFrame,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from . import image_registry as reg
from .models import ActionSpec
from .provision_player import ProvisionPlayerWindow
from .widgets import SectionHeader, fit_to_screen
from .windows_install_dialog import completed_image_indices


INSPECT_TIMEOUT_MS = 180_000  # sha256 of a large ISO on slow storage is the floor.
SCAN_TIMEOUT_MS = 60_000

# ``media inspect`` can only name the WIM images when the install payload is
# readable from the ISO; retail media routinely reports ``imageCount: 0`` with
# ``payloadNote`` explaining why. The install journey
# (``windows_install_dialog``) already offers editions 1..10 unconditionally in
# that case, so mirror the same range here instead of dead-ending the user with
# an empty edition list and a permanently disabled play button.
FALLBACK_INDEX_RANGE = range(1, 11)


def _human_bytes(value: object) -> str:
    try:
        size = max(0, int(value))
    except (TypeError, ValueError):
        size = 0
    amount = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if amount < 1024 or unit == "TB":
            return f"{amount:.1f} {unit}" if unit != "B" else f"{int(amount)} B"
        amount /= 1024
    return f"{size} B"


class _PzReader(QObject):
    """Run a read-only ``pz`` command asynchronously with a bounded timeout.

    Independent of :class:`status_loader.StatusLoader` so the dialog can use
    longer budgets (sha256) and dedicated request ids without colliding with
    page status polling.
    """

    finished_ok = Signal(str, str)  # (request_id, stdout)
    failed = Signal(str, str)       # (request_id, message)

    def __init__(self, root: Path, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._root = root
        self._procs: dict[str, QProcess] = {}
        self._timers: dict[str, QTimer] = {}

    def is_running(self, request_id: str) -> bool:
        return request_id in self._procs

    def any_running(self) -> bool:
        return bool(self._procs)

    def has_running_prefix(self, prefix: str) -> bool:
        return any(request_id.startswith(prefix) for request_id in self._procs)

    def run(self, request_id: str, args: list[str], *, timeout_ms: int) -> None:
        if request_id in self._procs:
            return
        pz = str(self._root / "linux" / "pz")
        proc = QProcess(self)
        proc.setWorkingDirectory(str(self._root))
        proc.setProgram(pz)
        proc.setArguments(args)
        proc.setProcessChannelMode(QProcess.SeparateChannels)
        proc.finished.connect(
            lambda _code, _status, rid=request_id, p=proc: self._on_finished(rid, p)
        )
        proc.errorOccurred.connect(lambda _err, rid=request_id: self._on_error(rid))
        timer = QTimer(self)
        timer.setSingleShot(True)
        timer.timeout.connect(lambda rid=request_id: self._on_timeout(rid))
        timer.start(timeout_ms)
        self._procs[request_id] = proc
        self._timers[request_id] = timer
        proc.start()

    def _teardown(self, request_id: str) -> None:
        timer = self._timers.pop(request_id, None)
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        proc = self._procs.pop(request_id, None)
        if proc is not None:
            proc.deleteLater()

    def _on_finished(self, request_id: str, proc: QProcess) -> None:
        if request_id not in self._procs:
            return
        stdout = bytes(proc.readAllStandardOutput().data()).decode("utf-8", errors="replace")
        stderr = bytes(proc.readAllStandardError().data()).decode("utf-8", errors="replace")
        exit_code = proc.exitCode()
        self._teardown(request_id)
        if exit_code != 0:
            self.failed.emit(request_id, f"exit {exit_code}: {stderr.strip()[:300]}")
            return
        self.finished_ok.emit(request_id, stdout)

    def _on_error(self, request_id: str) -> None:
        if request_id not in self._procs:
            return
        self._teardown(request_id)
        self.failed.emit(request_id, "falha ao iniciar o comando")

    def _on_timeout(self, request_id: str) -> None:
        proc = self._procs.get(request_id)
        if proc is None:
            return
        # Drop the request before killing: waitForFinished can deliver
        # `finished` synchronously, and _on_finished would then emit its own
        # terminal signal for the same id, advancing the batch twice. Keep a
        # local reference so the process outlives the bookkeeping.
        self._procs.pop(request_id, None)
        timer = self._timers.pop(request_id, None)
        if timer is not None:
            timer.stop()
            timer.deleteLater()
        if proc.state() != QProcess.NotRunning:
            proc.kill()
            proc.waitForFinished(1000)
        proc.deleteLater()
        self.failed.emit(request_id, "tempo esgotado")


class ImageManagerDialog(QDialog):
    """List registered Windows ISOs and manage them with safe, reused actions."""

    def __init__(
        self,
        root: Path,
        runner: object,
        by_id: dict[str, ActionSpec] | None = None,
        parent: QWidget | None = None,
        *,
        state_path: Path | str | None = None,
        operations_dir: Path | str | None = None,
        advanced: bool = False,
        graphics_profile: str = "compat",
    ) -> None:
        super().__init__(parent, Qt.Dialog)
        self.setObjectName("imageManagerDialog")
        self.setAttribute(Qt.WA_StyledBackground, True)
        self.setAutoFillBackground(True)
        self.setWindowTitle("Gerenciar imagens e VMs Windows")
        self.setWindowModality(Qt.WindowModal)
        fit_to_screen(self, 780, 540)

        self._root = Path(root)
        self._runner = runner
        self._by_id = dict(by_id or {})
        self._state_path = Path(state_path) if state_path else None
        self._operations_dir = Path(operations_dir) if operations_dir else None
        self._advanced = bool(advanced)
        self._graphics_profile = graphics_profile or "compat"

        self._reader = _PzReader(self._root, self)
        self._reader.finished_ok.connect(self._on_read_ok)
        self._reader.failed.connect(self._on_read_failed)

        self._pending_action: ActionSpec | None = None
        self._install_indices: set[int] = set()
        self._vm_entries: list[dict] = []
        self._current: dict | None = None
        self._batch: list[str] = []
        self._batch_source = "manual"
        self._batch_total = 0
        self._batch_done = 0
        self._failed_registrations: list[str] = []

        self._build_ui()
        self._refresh_list()
        if (self._root / "linux" / "pz").is_file():
            self._refresh_vms()
        self.set_advanced_mode(self._advanced)

    # ----- public after exec() -----

    def pending_action(self) -> ActionSpec | None:
        """Action (boot/GRUB) the main window must run after the dialog closes."""
        return self._pending_action

    def set_advanced_mode(self, enabled: bool) -> None:
        self._advanced = bool(enabled)
        self._sha_full_label.setVisible(self._advanced)
        self._raw_view.setVisible(self._advanced)
        self._refresh_details()

    # ----- UI build -----

    def _build_ui(self) -> None:
        outer = QVBoxLayout(self)
        outer.setContentsMargins(20, 18, 20, 18)
        outer.setSpacing(14)

        outer.addWidget(SectionHeader(
            "Imagens e VMs Windows",
            "Gerencie ISOs por edição e remova com segurança VMs criadas pelo PhaseZero.",
        ))

        # Toolbar
        toolbar = QHBoxLayout()
        toolbar.setSpacing(10)
        self.add_button = QPushButton("+ Adicionar ISO")
        self.add_button.setObjectName("secondaryButton")
        self.add_button.clicked.connect(self._add_iso)
        self.scan_button = QPushButton("↻ Buscar ISOs")
        self.scan_button.setObjectName("secondaryButton")
        self.scan_button.clicked.connect(self._scan_isos)
        self.vms_button = QPushButton("VMs instaladas")
        self.vms_button.setObjectName("secondaryButton")
        self.vms_button.setEnabled(False)
        self.vms_button.setToolTip("Carregando instalações concluídas…")
        self.vms_button.clicked.connect(self._show_vm_manager)
        self.refresh_button = QPushButton("Atualizar")
        self.refresh_button.setObjectName("secondaryButton")
        self.refresh_button.clicked.connect(self._refresh_all)
        toolbar.addWidget(self.add_button)
        toolbar.addWidget(self.scan_button)
        toolbar.addWidget(self.vms_button)
        toolbar.addStretch()
        toolbar.addWidget(self.refresh_button)
        outer.addLayout(toolbar)

        # Body: list (left) + details (right)
        body = QHBoxLayout()
        body.setSpacing(12)

        self.list_widget = QListWidget()
        self.list_widget.setObjectName("imageList")
        self.list_widget.setMinimumWidth(280)
        self.list_widget.currentRowChanged.connect(self._on_selection_changed)
        body.addWidget(self.list_widget, 1)

        self.details_stack = QStackedWidget()
        self.details_stack.addWidget(self._build_empty_state())
        self.details_stack.addWidget(self._build_details_panel())
        body.addWidget(self.details_stack, 2)
        outer.addLayout(body, 1)

        # Async progress
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setVisible(False)
        self.progress.setFixedHeight(4)
        outer.addWidget(self.progress)
        self.status_label = QLabel("")
        self.status_label.setObjectName("cardDescription")
        self.status_label.setWordWrap(True)
        outer.addWidget(self.status_label)

        # Action bar
        outer.addLayout(self._build_action_bar())

    def _build_empty_state(self) -> QWidget:
        frame = QFrame()
        layout = QVBoxLayout(frame)
        layout.setContentsMargins(20, 20, 20, 20)
        hint = QLabel(
            "Nenhuma imagem registrada.\n\n"
            "Clique em “Adicionar ISO” para escolher um arquivo, ou “Buscar ISOs” "
            "para localizar imagens do Windows já presentes no computador."
        )
        hint.setObjectName("cardDescription")
        hint.setWordWrap(True)
        layout.addStretch()
        layout.addWidget(hint)
        layout.addStretch()
        return frame

    def _build_details_panel(self) -> QWidget:
        panel = QFrame()
        panel.setObjectName("settingsCard")
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(16, 14, 16, 14)
        layout.setSpacing(8)

        self.title_label = QLabel("")
        self.title_label.setObjectName("sectionHeading")
        self.title_label.setWordWrap(True)
        layout.addWidget(self.title_label)

        self.meta_label = QLabel("")
        self.meta_label.setObjectName("settingValue")
        self.meta_label.setWordWrap(True)
        layout.addWidget(self.meta_label)

        self.sha_short_label = QLabel("")
        self.sha_short_label.setObjectName("cardDescription")
        layout.addWidget(self.sha_short_label)

        self._sha_full_label = QLabel("")
        self._sha_full_label.setObjectName("cardDescription")
        self._sha_full_label.setWordWrap(True)
        self._sha_full_label.setVisible(False)
        layout.addWidget(self._sha_full_label)

        layout.addWidget(QLabel("Edições (índice):"))
        self.index_list = QListWidget()
        self.index_list.setObjectName("imageIndexList")
        self.index_list.currentRowChanged.connect(self._on_index_changed)
        layout.addWidget(self.index_list, 1)

        self._raw_view = QLabel("")
        self._raw_view.setObjectName("cardDescription")
        self._raw_view.setWordWrap(True)
        self._raw_view.setVisible(False)
        layout.addWidget(self._raw_view)
        return panel

    def _build_action_bar(self) -> QVBoxLayout:
        actions = QVBoxLayout()
        actions.setSpacing(8)
        primary_row = QHBoxLayout()
        primary_row.setSpacing(10)
        secondary_row = QHBoxLayout()
        secondary_row.setSpacing(10)
        self.play_button = QPushButton("▶ Reproduzir no player")
        self.play_button.setObjectName("primaryButton")
        self.play_button.setMinimumHeight(44)
        self.play_button.clicked.connect(self._play)
        self.boot_button = QPushButton("⏻ Habilitar no boot")
        self.boot_button.setObjectName("secondaryButton")
        self.boot_button.setMinimumHeight(44)
        self.boot_button.clicked.connect(lambda: self._request_action("windows.boot.install"))
        self.grub_button = QPushButton("⛏ Restaurar GRUB")
        self.grub_button.setObjectName("secondaryButton")
        self.grub_button.setMinimumHeight(44)
        self.grub_button.clicked.connect(lambda: self._request_action("boot.safe-menu"))
        self.remove_button = QPushButton("🗑 Remover")
        self.remove_button.setObjectName("dangerOutlineButton")
        self.remove_button.setMinimumHeight(44)
        self.remove_button.clicked.connect(self._remove)
        self.remove_vm_button = QPushButton("🗑 Remover VM atual")
        self.remove_vm_button.setObjectName("dangerOutlineButton")
        self.remove_vm_button.setMinimumHeight(44)
        self.remove_vm_button.setEnabled("windows.vm.remove" in self._by_id)
        self.remove_vm_button.clicked.connect(
            lambda: self._request_action("windows.vm.remove")
        )
        self.close_button = QPushButton("Fechar")
        self.close_button.setMinimumHeight(44)
        self.close_button.clicked.connect(self.reject)
        for button in (self.play_button, self.boot_button, self.grub_button):
            primary_row.addWidget(button)
        primary_row.addStretch()
        secondary_row.addWidget(self.remove_button)
        secondary_row.addWidget(self.remove_vm_button)
        secondary_row.addStretch()
        secondary_row.addWidget(self.close_button)
        actions.addLayout(primary_row)
        actions.addLayout(secondary_row)
        return actions

    # ----- data flow -----

    def _state_arg(self) -> Path | None:
        return self._state_path

    def _refresh_all(self) -> None:
        self._refresh_list()
        self._refresh_vms()

    def _refresh_vms(self) -> None:
        if self._reader.is_running("vm-inventory"):
            return
        self.vms_button.setEnabled(False)
        self.vms_button.setText("VMs instaladas · …")
        self.vms_button.setToolTip("Carregando instalações concluídas…")
        self._reader.run(
            "vm-inventory",
            ["windows-vm", "provision", "inventory", "--json"],
            timeout_ms=30_000,
        )

    def _refresh_list(self) -> None:
        self._install_indices = set()
        images = reg.list_images(self._state_arg())
        self.list_widget.blockSignals(True)
        self.list_widget.clear()
        for entry in images:
            label = str(entry.get("label") or Path(str(entry.get("path") or "ISO")).name or "ISO")
            size = int(entry.get("sizeMb") or 0)
            valid = bool(entry.get("valid"))
            badge = "✓" if valid else "⚠"
            size_text = f"{size / 1024:g} GB" if size >= 1024 else f"{size} MB"
            item = QListWidgetItem(f"{badge}  {label} — {size_text}")
            item.setData(Qt.UserRole, entry)
            self.list_widget.addItem(item)
        self.list_widget.blockSignals(False)
        if images:
            self.list_widget.setCurrentRow(0)
        else:
            self.details_stack.setCurrentIndex(0)
            self._current = None
            self._set_actions_enabled(False)
        self._set_busy(False, "")

        # Reflect the registration in the list (entries were added/removed).
        selection = self.list_widget.currentRow()
        if selection >= 0:
            self._on_selection_changed(selection)

    def _on_selection_changed(self, row: int) -> None:
        item = self.list_widget.item(row) if row >= 0 else None
        entry = item.data(Qt.UserRole) if item is not None else None
        self._current = entry if isinstance(entry, dict) else None
        self._refresh_details()

    def _refresh_details(self) -> None:
        entry = self._current
        if not entry:
            self.details_stack.setCurrentIndex(0)
            self._set_actions_enabled(False)
            return
        self.details_stack.setCurrentIndex(1)
        self._install_indices = completed_image_indices(
            self._operations_dir, iso_sha256=str(entry.get("sha256") or "")
        )
        label = str(entry.get("label") or Path(str(entry.get("path") or "ISO")).name or "ISO")
        self.title_label.setText(label)
        path_text = str(entry.get("path") or "")
        arch = str(entry.get("arch") or "—")
        uefi = "Sim" if entry.get("uefiBoot") else "Não"
        valid = "Válida" if entry.get("valid") else "Inválida / não confirmada"
        size = int(entry.get("sizeMb") or 0)
        size_text = f"{size / 1024:g} GB" if size >= 1024 else f"{size} MB"
        named_count = len(entry.get("images") or [])
        note = ""
        if not named_count and entry.get("valid"):
            note = (
                "\nOs nomes das edições não puderam ser lidos desta ISO; "
                "escolha a edição pelo número, como na instalação."
            )
        self.meta_label.setText(
            f"Arquivo: {path_text}\n"
            f"Tamanho: {size_text}  •  Arquitetura: {arch}  •  UEFI: {uefi}\n"
            f"Estado: {valid}  •  Edições: {named_count}"
            f"{note}"
        )
        sha = str(entry.get("sha256") or "")
        self.sha_short_label.setText(f"SHA-256: {sha[:12]}…" if sha else "SHA-256: —")
        self._sha_full_label.setText(f"SHA-256 (completo): {sha}" if sha else "")

        self.index_list.blockSignals(True)
        self.index_list.clear()
        entries = self._index_entries(entry)
        first_usable = -1
        for idx, name, edition in entries:
            suffix = ""
            if idx in self._install_indices:
                suffix = "  (já instalada)"
            elif first_usable < 0:
                first_usable = self.index_list.count()
            edition_text = f" — {edition}" if edition and edition != name else ""
            list_item = QListWidgetItem(f"[#{idx}] {name}{edition_text}{suffix}")
            list_item.setData(Qt.UserRole, idx)
            self.index_list.addItem(list_item)
        self.index_list.blockSignals(False)
        if first_usable >= 0:
            self.index_list.setCurrentRow(first_usable)
        elif self.index_list.count() > 0:
            self.index_list.setCurrentRow(0)

        if self._advanced:
            self._raw_view.setText(
                "JSON: " + json.dumps(entry, ensure_ascii=False)[:800]
            )
        else:
            self._raw_view.setText("")

        self._set_actions_enabled(True)
        self._update_play_enabled()

    def _index_entries(self, entry: dict) -> list[tuple[int, str, str]]:
        """Editions to offer for this image: named ones, else the 1..10 range.

        Returns ``(index, name, edition)`` triples. Retail ISOs frequently
        inspect as valid with an empty ``images`` list (see
        :data:`FALLBACK_INDEX_RANGE`); an invalid image offers nothing.
        """
        named: list[tuple[int, str, str]] = []
        for img in entry.get("images") or []:
            if not isinstance(img, dict):
                continue
            idx = int(img.get("index") or 0)
            named.append((
                idx,
                str(img.get("name") or f"Edição {idx}"),
                str(img.get("edition") or ""),
            ))
        if named:
            return named
        if not entry.get("valid"):
            return []
        return [(idx, f"Edição {idx}", "") for idx in FALLBACK_INDEX_RANGE]

    def _on_index_changed(self, _row: int) -> None:
        self._update_play_enabled()

    def _selected_index(self) -> int | None:
        item = self.index_list.currentItem()
        if item is None:
            return None
        value = item.data(Qt.UserRole)
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    def _set_actions_enabled(self, enabled: bool) -> None:
        for button in (self.boot_button, self.grub_button, self.remove_button, self.play_button):
            button.setEnabled(enabled)
        if enabled:
            self._update_play_enabled()

    def _update_play_enabled(self) -> None:
        entry = self._current
        valid = bool(entry and entry.get("valid"))
        has_index = self._selected_index() is not None
        media_busy = self._reader.is_running("scan") or self._reader.has_running_prefix("inspect:")
        self.play_button.setEnabled(valid and has_index and not media_busy)

    def _set_busy(self, busy: bool, message: str) -> None:
        self.progress.setVisible(busy)
        self.status_label.setText(message)
        for button in (self.add_button, self.scan_button):
            button.setEnabled(not busy)
        self.remove_vm_button.setEnabled(
            not busy and "windows.vm.remove" in self._by_id
        )
        # Never hand the primary button back unconditionally: leaving the
        # dialog idle with nothing selected (a scan that found nothing) would
        # show an enabled "Reproduzir" that does nothing when clicked.
        self._set_actions_enabled(not busy and self._current is not None)

    # ----- add / scan -----

    def _add_iso(self) -> None:
        if self._reader.is_running("scan") or self._reader.has_running_prefix("inspect:"):
            return
        path, _filt = QFileDialog.getOpenFileName(
            self,
            "Escolha a ISO do Windows",
            str(Path.home()),
            "Imagens ISO (*.iso);;Todos os arquivos (*)",
        )
        if not path:
            return
        self._inspect_and_add([path], source="manual")

    def _scan_isos(self) -> None:
        if self._reader.is_running("scan") or self._reader.has_running_prefix("inspect:"):
            return
        self._set_busy(True, "Buscando imagens do Windows no computador…")
        self._reader.run(
            "scan",
            ["windows-vm", "media", "scan", "--json"],
            timeout_ms=SCAN_TIMEOUT_MS,
        )

    def _on_read_ok(self, request_id: str, stdout: str) -> None:
        if request_id.startswith("inspect:"):
            path = request_id.split(":", 1)[1]
            try:
                payload = json.loads(stdout)
            except json.JSONDecodeError:
                # Unreadable output is just another failed inspection: record
                # it and keep the queue moving instead of stalling the batch.
                self._fail_inspect(path, "resposta ilegível do comando")
                return
            self._register_inspect(path, payload, source=self._batch_source)
            self._advance_batch()
            return
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError:
            self._set_busy(False, "Não foi possível ler a resposta do comando.")
            return
        if request_id == "scan":
            self._handle_scan_result(payload)
        elif request_id == "vm-inventory":
            entries = payload.get("instances") if isinstance(payload, dict) else None
            self._vm_entries = [entry for entry in (entries or []) if isinstance(entry, dict)]
            count = len(self._vm_entries)
            total = sum(int(entry.get("allocatedBytes") or 0) for entry in self._vm_entries)
            self.vms_button.setText(f"Instalações Windows · {count}")
            self.vms_button.setEnabled(count > 0 and "windows.vm.remove" in self._by_id)
            if count:
                self.vms_button.setToolTip(f"{count} instalação(ões), incluindo parciais, ocupando {_human_bytes(total)}")
            else:
                self.vms_button.setToolTip("Nenhum arquivo de instalação Windows ocupa o staging do PhaseZero")
            self._update_play_enabled()

    def _on_read_failed(self, request_id: str, message: str) -> None:
        if request_id.startswith("inspect:"):
            self._fail_inspect(request_id.split(":", 1)[1], message)
            return
        if request_id == "vm-inventory":
            self._vm_entries = []
            self.vms_button.setText("Instalações Windows · indisponível")
            self.vms_button.setEnabled(False)
            self.vms_button.setToolTip(message)
            self._update_play_enabled()
            return
        self._set_busy(False, f"Falha: {message}")

    def _fail_inspect(self, path: str, message: str) -> None:
        """Record an unusable ISO and move on to the next one in the batch."""
        # Keep an invalid entry so the user still sees the file and can retry.
        self._register_inspect(
            path, {"valid": False, "payloadNote": message}, source=self._batch_source
        )
        self._advance_batch()

    def _advance_batch(self) -> None:
        """Single exit for every terminal inspect path.

        Each of the three ways an inspect can end (parsed, unparseable, failed
        or timed out) has to drop the head of the queue and start the next
        one; doing it in only some of them silently strands the remaining
        images.
        """
        if self._batch:
            self._batch.pop(0)
            self._batch_done += 1
        self._inspect_next()

    def _handle_scan_result(self, payload: dict) -> None:
        candidates = payload.get("candidates") if isinstance(payload, dict) else None
        if not isinstance(candidates, list) or not candidates:
            self._set_busy(False, "Nenhuma imagem do Windows encontrada nos locais padrão.")
            return
        existing_paths = {
            str(img.get("path") or "") for img in reg.list_images(self._state_arg())
        }
        new_paths = [
            str(c.get("path") or "")
            for c in candidates
            if isinstance(c, dict) and str(c.get("path") or "") not in existing_paths
        ]
        if not new_paths:
            self._set_busy(False, "Todas as imagens encontradas já estão registradas.")
            return
        chosen = self._pick_candidates(new_paths)
        if not chosen:
            self._set_busy(False, "")
            return
        self._inspect_and_add(chosen, source="scan")

    def _pick_candidates(self, paths: list[str]) -> list[str]:
        dialog = QDialog(self)
        dialog.setWindowTitle("Selecionar imagens para registrar")
        dialog.setMinimumWidth(520)
        layout = QVBoxLayout(dialog)
        layout.addWidget(QLabel("Imagens encontradas:"))
        list_widget = QListWidget()
        list_widget.setObjectName("scanCandidateList")
        for path in paths:
            item = QListWidgetItem(path)
            item.setCheckState(Qt.Checked)
            list_widget.addItem(item)
        layout.addWidget(list_widget)
        buttons_row = QHBoxLayout()
        ok = QPushButton("Registrar selecionadas")
        ok.setObjectName("primaryButton")
        cancel = QPushButton("Cancelar")
        ok.clicked.connect(dialog.accept)
        cancel.clicked.connect(dialog.reject)
        buttons_row.addStretch()
        buttons_row.addWidget(cancel)
        buttons_row.addWidget(ok)
        layout.addLayout(buttons_row)
        if dialog.exec() != QDialog.Accepted:
            return []
        return [
            list_widget.item(row).text()
            for row in range(list_widget.count())
            if list_widget.item(row).checkState() == Qt.Checked
        ]

    def _inspect_and_add(self, paths: list[str], *, source: str) -> None:
        self._batch = list(paths)
        self._batch_source = source
        self._batch_total = len(paths)
        self._batch_done = 0
        self._set_busy(True, f"Analisando imagens (0/{self._batch_total})…")
        self._inspect_next()

    def _inspect_next(self) -> None:
        if not self._batch:
            self._after_batch_done()
            return
        path = self._batch[0]
        self._set_busy(
            True,
            f"Analisando imagens ({self._batch_done}/{self._batch_total}): {Path(path).name}",
        )
        self._reader.run(
            f"inspect:{path}",
            ["windows-vm", "media", "inspect", "--iso", path, "--json"],
            timeout_ms=INSPECT_TIMEOUT_MS,
        )

    def _register_inspect(self, path: str, payload: dict, *, source: str) -> None:
        size_mb = 0
        try:
            size_mb = int(payload.get("sizeMb") or 0)
        except (TypeError, ValueError):
            size_mb = 0
        entry = {
            "path": path,
            "sha256": str(payload.get("sha256") or self._fallback_sha(path)),
            "label": str(payload.get("label") or Path(path).name),
            "sizeMb": size_mb,
            "arch": str(payload.get("arch") or ""),
            "uefiBoot": bool(payload.get("uefiBoot")),
            "valid": bool(payload.get("valid")),
            "images": list(payload.get("images") or []),
            "source": source,
            "payloadNote": str(payload.get("payloadNote") or ""),
        }
        try:
            reg.add_image(entry, state_path=self._state_arg())
        except (TypeError, ValueError) as exc:
            # `_fallback_sha` always yields an identity, so this only fires if
            # the registry rejects the entry outright. Say so instead of
            # dropping the image silently.
            self._failed_registrations.append(f"{Path(path).name}: {exc}")

    def _fallback_sha(self, path: str) -> str:
        # Distinguish files even when inspect did not return a digest (e.g. it
        # failed to start): pair path with mtime/size so re-adds update.
        try:
            stat = Path(path).stat()
            return f"local:{Path(path).name}:{stat.st_size}:{int(stat.st_mtime)}"
        except OSError:
            return f"local:{Path(path).name}"

    def _after_batch_done(self) -> None:
        self._batch = []
        n = self._batch_total
        rejected = list(self._failed_registrations)
        self._failed_registrations = []
        self._refresh_list()
        if rejected:
            message = (
                f"Pronto. {n} imagem(ns) processada(s); "
                f"{len(rejected)} não pôde(puderam) ser registrada(s): "
                + "; ".join(rejected[:3])
            )
        else:
            message = f"Pronto. {n} imagem(ns) processada(s)." if n else ""
        self._set_busy(False, message)

    # ----- actions -----

    def _show_vm_manager(self) -> None:
        if not self._vm_entries:
            QMessageBox.information(self, "VMs instaladas", "Nenhuma VM concluída ocupa espaço.")
            return
        dialog = QDialog(self)
        dialog.setObjectName("windowsVmInventoryDialog")
        dialog.setWindowTitle("Instalações Windows")
        fit_to_screen(dialog, 780, 540)
        layout = QVBoxLayout(dialog)
        layout.setContentsMargins(20, 18, 20, 18)
        layout.setSpacing(12)
        layout.addWidget(SectionHeader(
            "Instalações Windows",
            "Concluídas e interrompidas aparecem aqui. Escolha uma para conferir espaço e remover os arquivos.",
        ))
        vm_list = QListWidget()
        vm_list.setObjectName("windowsVmInventoryList")
        for entry in self._vm_entries:
            index = int(entry.get("imageIndex") or 0)
            edition = f"Edição {index}" if index else "Edição não identificada"
            state = str(entry.get("state") or "completed")
            status = "Em execução" if entry.get("running") else {
                "interrupted": "Interrompida · pode retomar",
                "failed": "Falhou · arquivos preservados",
                "cancelled": "Cancelada · arquivos preservados",
            }.get(state, "Concluída · desligada")
            item = QListWidgetItem(
                f"Windows 11 · {edition}  —  {_human_bytes(entry.get('allocatedBytes'))}  ·  {status}"
            )
            item.setData(Qt.UserRole, entry)
            vm_list.addItem(item)
        vm_list.setCurrentRow(0)
        layout.addWidget(vm_list, 1)
        details = QLabel()
        details.setObjectName("cardDescription")
        details.setWordWrap(True)
        layout.addWidget(details)

        buttons = QHBoxLayout()
        resume = QPushButton("Retomar instalação")
        resume.setObjectName("primaryButton")
        resume.setMinimumHeight(44)
        trash = QPushButton("Mover para a lixeira")
        trash.setObjectName("secondaryButton")
        trash.setMinimumHeight(44)
        purge = QPushButton("Liberar espaço agora")
        purge.setObjectName("dangerButton")
        purge.setMinimumHeight(44)
        close = QPushButton("Cancelar")
        close.setMinimumHeight(44)
        buttons.addWidget(resume)
        buttons.addWidget(trash)
        buttons.addWidget(purge)
        buttons.addStretch()
        buttons.addWidget(close)
        layout.addLayout(buttons)

        def selected() -> dict | None:
            item = vm_list.currentItem()
            entry = item.data(Qt.UserRole) if item is not None else None
            return entry if isinstance(entry, dict) else None

        def update_details() -> None:
            entry = selected()
            if not entry:
                details.clear()
                trash.setEnabled(False)
                purge.setEnabled(False)
                return
            running = bool(entry.get("running"))
            recoverable = entry.get("state") in {"interrupted", "failed", "cancelled"}
            path_text = str(entry.get("vmDir") or "")
            details.setText(
                f"Espaço ocupado: {_human_bytes(entry.get('allocatedBytes'))}\n"
                f"Criada em: {entry.get('createdAt') or '—'}\n"
                f"Local: {path_text}\n\n"
                + ("Instalação parcial preservada. Retome pelo botão acima ou remova os arquivos desta operação.\n\n"
                   if entry.get("state") in {"interrupted", "failed", "cancelled"} else "")
                + "Lixeira permite recuperação, mas libera espaço somente após ser esvaziada. "
                "Liberação imediata é permanente."
            )
            resume.setVisible(recoverable)
            resume.setEnabled(recoverable and not running and "windows.provision.resume" in self._by_id)
            trash.setEnabled(not running)
            trash.setText("Remover instalação parcial" if recoverable else "Mover VM para a lixeira")
            purge.setEnabled(not running)

        def choose(mode: str) -> None:
            entry = selected()
            if not entry:
                return
            if mode == "purge":
                text, accepted = QInputDialog.getText(
                    dialog,
                    "Confirmar liberação permanente",
                    f"Esta ação apagará {_human_bytes(entry.get('allocatedBytes'))} sem recuperação.\n"
                    "Digite REMOVER para continuar:",
                )
                if not accepted or text.strip().upper() != "REMOVER":
                    return
            self._prepare_vm_removal(entry, purge=(mode == "purge"))
            dialog.accept()
            self.accept()

        vm_list.currentRowChanged.connect(lambda _row: update_details())
        trash.clicked.connect(lambda: choose("trash"))
        purge.clicked.connect(lambda: choose("purge"))
        def resume_selected() -> None:
            self._prepare_vm_resume(selected())
            if self._pending_action is not None:
                dialog.accept()

        resume.clicked.connect(resume_selected)
        close.clicked.connect(dialog.reject)
        update_details()
        dialog.exec()

    def _prepare_vm_removal(self, entry: dict, *, purge: bool) -> None:
        base = self._by_id.get("windows.vm.remove")
        operation_id = str(entry.get("id") or "")
        if base is None or not operation_id:
            return
        preview = [
            "windows-vm", "provision", "remove",
            "--operation-id", operation_id,
            "--purge" if purge else "--trash",
            "--dry-run", "--json",
        ]
        execute = [
            "windows-vm", "provision", "remove",
            "--operation-id", operation_id,
            "--purge" if purge else "--trash",
        ]
        if purge:
            execute.extend(("--confirm-operation", operation_id))
        execute.extend(("--yes", "--json"))
        self._pending_action = replace(
            base,
            title=("Liberar espaço da instalação" if purge else
                   "Remover instalação parcial" if entry.get("state") != "completed" else
                   "Mover VM para a lixeira"),
            description=(
                f"Remove a instalação selecionada e libera {_human_bytes(entry.get('allocatedBytes'))}."
            ),
            args=tuple(execute),
            preview_args=tuple(preview),
        )

    def _prepare_vm_resume(self, entry: dict | None) -> None:
        base = self._by_id.get("windows.provision.resume")
        operation_id = str((entry or {}).get("id") or "")
        if base is None or not operation_id:
            return
        self._pending_action = replace(
            base,
            title="Retomar instalação interrompida",
            description="Continua do último checkpoint. Arquivos parciais serão preservados.",
            args=("windows-vm", "provision", "resume", "--operation-id", operation_id),
            preview_args=("windows-vm", "provision", "status", "--operation-id", operation_id, "--json"),
        )
        self.accept()

    def _play(self) -> None:
        entry = self._current
        if not entry or not entry.get("valid"):
            return
        idx = self._selected_index()
        if idx is None:
            return
        iso = str(entry.get("path") or "")
        try:
            ProvisionPlayerWindow.open(
                self._root,
                self._runner,
                self.parent(),
                iso=iso,
                image_index=str(idx),
                graphics=self._graphics_profile,
                guest_login="auto",
            )
        except Exception as exc:  # noqa: BLE001 - surface to the layperson
            QMessageBox.warning(self, "Player indisponível", str(exc))
            return
        self.accept()

    def _request_action(self, action_id: str) -> None:
        action = self._by_id.get(action_id)
        if action is None:
            QMessageBox.information(
                self,
                "Indisponível",
                "Esta ação não está disponível nesta instalação.",
            )
            return
        self._pending_action = action
        self.accept()

    def _remove(self) -> None:
        entry = self._current
        if not entry:
            return
        sha = str(entry.get("sha256") or "")
        path = str(entry.get("path") or "")
        label = str(entry.get("label") or Path(path).name)
        box = QMessageBox(self)
        box.setWindowTitle("Remover imagem")
        box.setIcon(QMessageBox.Question)
        box.setText(f"Remover “{label}” do registro de imagens?")
        box.setInformativeText(
            "“Remover da lista” apenas esconde a imagem do PhaseZero (o arquivo continua no disco). "
            "“Mover para a lixeira” também envia o arquivo para a lixeira (reversível)."
        )
        btn_list = box.addButton("Remover da lista", QMessageBox.AcceptRole)
        btn_trash = box.addButton("Remover e mover para a lixeira", QMessageBox.DestructiveRole)
        box.addButton("Cancelar", QMessageBox.RejectRole)
        box.exec()
        choice = box.clickedButton()
        if choice is btn_list:
            reg.remove_image(sha256=sha or None, path=path or None, state_path=self._state_arg())
            self._refresh_list()
            self.status_label.setText(f"Imagem “{label}” removida do registro.")
        elif choice is btn_trash:
            reg.remove_image(sha256=sha or None, path=path or None, state_path=self._state_arg())
            trashed = False
            if path:
                # The static overload is ``moveToTrash(fileName) -> (ok, pathInTrash)``
                # in PySide6; the tuple itself is always truthy, so read [0].
                result = QFile.moveToTrash(path)
                trashed = bool(result[0]) if isinstance(result, tuple) else bool(result)
            self._refresh_list()
            if trashed:
                self.status_label.setText(f"Imagem “{label}” removida e enviada para a lixeira.")
            else:
                self.status_label.setText(
                    "Imagem removida do registro; o arquivo não pôde ser movido "
                    "para a lixeira e continua no disco."
                )
