from __future__ import annotations

import json
import time
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QDialog

from linux.ui_native import image_manager_dialog as imd_mod
from linux.ui_native import image_registry as reg
from linux.ui_native.image_manager_dialog import ImageManagerDialog
from linux.ui_native.command_runner import CommandRunner


ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _wait_for(predicate, *, timeout: float = 6.0) -> bool:
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if predicate():
            return True
        QApplication.processEvents()
        time.sleep(0.02)
    return predicate()


def _sha_for(path: str) -> str:
    # Deterministic distinct digest per path (mirrors the fake pz behavior).
    import hashlib
    return hashlib.sha256(("sha:" + path).encode()).hexdigest()


def _entry(path: str = "/tmp/win.iso", sha: str | None = None, **overrides) -> dict:
    data = {
        "path": path,
        "sha256": sha or _sha_for(path),
        "label": "Win11 Test",
        "sizeMb": 4096,
        "arch": "x64",
        "uefiBoot": True,
        "valid": True,
        "images": [
            {"index": 1, "name": "Windows 11 Home", "edition": "Home"},
            {"index": 4, "name": "Windows 11 Pro", "edition": "Pro"},
        ],
        "source": "manual",
    }
    data.update(overrides)
    return data


def _write_fake_pz(tmp_path: Path, *, inspect_fail: bool = False,
                   scan_candidates: list[str] | None = None,
                   inventory: list[dict] | None = None) -> Path:
    pz = tmp_path / "linux" / "pz"
    pz.parent.mkdir(parents=True, exist_ok=True)
    scan_payload = json.dumps({
        "candidates": [
            {"path": p, "sizeMb": 2048 + i}
            for i, p in enumerate(scan_candidates or [])
        ]
    })
    inventory_payload = json.dumps({
        "schemaVersion": 1,
        "instances": inventory or [],
        "count": len(inventory or []),
        "totalAllocatedBytes": sum(
            int(entry.get("allocatedBytes") or 0) for entry in (inventory or [])
        ),
    })
    inspect_body = (
        '    exit 1 ;;\n'
        if inspect_fail
        else '    path="$5"\n'
        '    printf \'%s\' \'\'\'{"valid":true,"sha256":"SHA_\'"$path"\'","label":"Win11 Test","arch":"x64","uefiBoot":true,"sizeMb":2048,"imageCount":2,"images":[{"index":1,"name":"Home","edition":"Home"},{"index":4,"name":"Pro","edition":"Pro"}],"payloadNote":""}\'\'\'\n'
        "    exit 0 ;;\n"
    )
    pz.write_text(
        "#!/usr/bin/env bash\n"
        'case "$1 $2 $3" in\n'
        '  "windows-vm media scan")\n'
        f"    printf '%s' {json.dumps(scan_payload)}\n"
        "    exit 0 ;;\n"
        '  "windows-vm media inspect")\n'
        f"{inspect_body}"
        '  "windows-vm provision inventory")\n'
        f"    printf '%s' {json.dumps(inventory_payload)}\n"
        "    exit 0 ;;\n"
        "  *) exit 1 ;;\n"
        "esac\n"
    )
    pz.chmod(0o755)
    return pz


def _make_dialog(tmp_path: Path, *, by_id=None, seeded=None, operations_dir=None,
                 advanced=False) -> ImageManagerDialog:
    state = tmp_path / "state" / "images.json"
    ops = operations_dir or (tmp_path / "ops")
    ops.mkdir(parents=True, exist_ok=True)
    dlg = ImageManagerDialog(
        tmp_path, CommandRunner(tmp_path), by_id or {}, None,
        state_path=state, operations_dir=ops, advanced=advanced,
    )
    for entry in seeded or []:
        reg.add_image(entry, state_path=state)
    if seeded:
        dlg._refresh_list()
    return dlg


def _seed_completed_operation(ops: Path, image_index: int, op_id: str = "op-20260811-130000-1") -> None:
    op_dir = ops / op_id
    op_dir.mkdir(parents=True, exist_ok=True)
    (op_dir / "operation.json").write_text(json.dumps({"state": "completed"}))
    (op_dir / "plan.json").write_text(json.dumps({
        "imageIndex": image_index,
        "iso": {"sha256": "a" * 64},
    }))


# ── Empty / disabled state ──

def test_empty_state_disables_actions(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path)
    assert dlg.list_widget.count() == 0
    assert dlg.details_stack.currentIndex() == 0
    for button in (dlg.play_button, dlg.boot_button, dlg.grub_button, dlg.remove_button):
        assert not button.isEnabled()


# ── Seeded image: characteristics + "já instalada" badge ──

def test_seeded_image_shows_indices_used_by_same_iso(qapp, tmp_path: Path) -> None:
    ops = tmp_path / "ops"
    ops.mkdir(parents=True, exist_ok=True)
    _seed_completed_operation(ops, image_index=4)
    dlg = _make_dialog(
        tmp_path,
        seeded=[_entry("/iso/win11.iso", sha="a" * 64)],
        operations_dir=ops,
    )
    assert dlg.list_widget.count() == 1
    assert dlg.details_stack.currentIndex() == 1
    # Index 4 carries the installed badge; index 1 does not.
    row_texts = [dlg.index_list.item(r).text() for r in range(dlg.index_list.count())]
    assert any("[#4]" in t and "já instalada" in t for t in row_texts)
    assert any("[#1]" in t and "já instalada" not in t for t in row_texts)
    # First usable (index 1) is selected, so play is enabled.
    assert dlg.index_list.currentItem().data(Qt.UserRole) == 1
    assert dlg.play_button.isEnabled()


def test_same_index_on_different_iso_is_not_marked_installed(qapp, tmp_path: Path) -> None:
    ops = tmp_path / "ops"
    ops.mkdir(parents=True, exist_ok=True)
    _seed_completed_operation(ops, image_index=4)
    dlg = _make_dialog(
        tmp_path,
        seeded=[_entry("/iso/another.iso", sha="b" * 64)],
        operations_dir=ops,
    )
    row_texts = [dlg.index_list.item(r).text() for r in range(dlg.index_list.count())]
    assert any("[#4]" in text and "já instalada" not in text for text in row_texts)


def test_interrupted_install_resume_action_uses_selected_operation(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    dlg._prepare_vm_resume({"id": "op-interrupted-1", "state": "interrupted"})
    action = dlg.pending_action()
    assert action is not None
    assert action.id == "windows.provision.resume"
    assert action.args == (
        "windows-vm", "provision", "resume", "--operation-id", "op-interrupted-1",
    )
    assert action.preview_args == (
        "windows-vm", "provision", "status", "--operation-id", "op-interrupted-1", "--json",
    )


# ── Play delegates to ProvisionPlayerWindow.open ──

def test_play_invokes_player_with_selected_index(
    qapp, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/win11.iso", sha="b" * 64)])
    captured: dict = {}

    class _FakePlayer:
        @classmethod
        def open(cls, root, runner, parent, *, iso="", graphics="compat",
                 image_index="1", guest_login="auto", recovery=True,
                 recovery_local_only=True):
            captured.update(iso=iso, image_index=image_index, graphics=graphics,
                            guest_login=guest_login)

    # The built-in fixture reverts the patch; a bare MonkeyPatch() would leave
    # the fake installed for every later test in the session.
    monkeypatch.setattr(imd_mod, "ProvisionPlayerWindow", _FakePlayer)
    dlg._play()
    assert captured["iso"] == "/iso/win11.iso"
    assert captured["image_index"] == "1"
    assert captured["graphics"] == "compat"
    assert captured["guest_login"] == "auto"
    assert dlg.result() == QDialog.Accepted


# ── Boot / GRUB emit pending_action and close ──

def _real_by_id() -> dict:
    from linux.ui_native.catalog import build_catalog
    return {a.id: a for a in build_catalog(ROOT)}


def test_boot_button_emits_pending_action(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id(),
                       seeded=[_entry("/iso/win11.iso", sha="c" * 64)])
    dlg._request_action("windows.boot.install")
    assert dlg.pending_action() is not None
    assert dlg.pending_action().id == "windows.boot.install"
    assert dlg.result() == QDialog.Accepted


def test_grub_button_emits_pending_action(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id(),
                       seeded=[_entry("/iso/win11.iso", sha="d" * 64)])
    dlg._request_action("boot.safe-menu")
    assert dlg.pending_action() is not None
    assert dlg.pending_action().id == "boot.safe-menu"


def test_current_vm_remove_button_keeps_standard_action(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    dlg.remove_vm_button.click()
    assert dlg.pending_action() is not None
    assert dlg.pending_action().id == "windows.vm.remove"
    assert dlg.result() == QDialog.Accepted


def test_prepare_vm_purge_builds_preview_first_action(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    dlg._prepare_vm_removal({
        "id": "op-legacy-1", "imageIndex": 2, "allocatedBytes": 21_000_000_000,
    }, purge=True)
    action = dlg.pending_action()
    assert action is not None
    assert action.id == "windows.vm.remove"
    assert action.mutable
    assert action.preview_args == (
        "windows-vm", "provision", "remove", "--operation-id", "op-legacy-1",
        "--purge", "--dry-run", "--json",
    )
    assert action.args == (
        "windows-vm", "provision", "remove", "--operation-id", "op-legacy-1",
        "--purge", "--confirm-operation", "op-legacy-1", "--yes", "--json",
    )
    assert "19.6 GB" in action.description


def test_prepare_vm_trash_keeps_recovery_mode(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    dlg._prepare_vm_removal({
        "id": "op-legacy-2", "imageIndex": 1, "allocatedBytes": 1024,
    }, purge=False)
    action = dlg.pending_action()
    assert action is not None
    assert "--trash" in action.args
    assert "--confirm-operation" not in action.args


def test_inventory_button_reports_count_and_real_space(qapp, tmp_path: Path) -> None:
    _write_fake_pz(tmp_path, inventory=[{
        "id": "op-legacy-1",
        "imageIndex": 2,
        "allocatedBytes": 21_000_000_000,
        "running": False,
        "vmDir": "/state/windows-vm/vms/op-legacy-1",
    }])
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    assert _wait_for(lambda: not dlg._reader.is_running("vm-inventory"))
    assert dlg.vms_button.text() == "Instalações Windows · 1"
    assert dlg.vms_button.isEnabled()
    assert "19.6 GB" in dlg.vms_button.toolTip()
    assert dlg.remove_vm_button is not dlg.vms_button
    assert dlg.remove_vm_button.isEnabled()


def test_action_buttons_fit_minimum_dialog_viewport(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, by_id=_real_by_id())
    dlg.resize(780, 540)
    dlg.show()
    qapp.processEvents()

    bounds = dlg.contentsRect()
    for button in (
        dlg.play_button,
        dlg.boot_button,
        dlg.grub_button,
        dlg.remove_button,
        dlg.remove_vm_button,
        dlg.close_button,
    ):
        top_left = button.mapTo(dlg, button.rect().topLeft())
        bottom_right = button.mapTo(dlg, button.rect().bottomRight())
        assert top_left.x() >= bounds.left()
        assert top_left.y() >= bounds.top()
        assert bottom_right.x() <= bounds.right()
        assert bottom_right.y() <= bounds.bottom()


def test_request_action_unknown_is_safe(
    qapp, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    dlg = _make_dialog(tmp_path, by_id={}, seeded=[_entry("/iso/win11.iso", sha="e" * 64)])
    # Stub the modal so the test does not block. The fixture reverts it; a
    # throwaway MonkeyPatch() would stub QMessageBox for the whole session.
    monkeypatch.setattr(imd_mod.QMessageBox, "information", lambda *a, **k: None)
    dlg._request_action("does.not.exist")
    assert dlg.pending_action() is None


# ── Remove: list-only vs trash ──

class _FakeMsgBox:
    """Stand-in for QMessageBox that returns a chosen button from the test."""

    chosen_role = "cancel"

    # Role/icon constants the dialog references on the class itself.
    AcceptRole = "AcceptRole"
    DestructiveRole = "DestructiveRole"
    RejectRole = "RejectRole"
    Question = "Question"

    def __init__(self, parent=None) -> None:
        self._buttons: dict[object, str] = {}

    def setWindowTitle(self, *_a) -> None: ...
    def setIcon(self, *_a) -> None: ...
    def setText(self, *_a) -> None: ...
    def setInformativeText(self, *_a) -> None: ...

    def addButton(self, text, role):
        marker = object()
        self._buttons[marker] = text
        return marker

    def exec(self) -> int:
        return 1

    def clickedButton(self):
        target = {"list": "Remover da lista",
                  "trash": "Remover e mover para a lixeira",
                  "cancel": "Cancelar"}.get(self.chosen_role, "Cancelar")
        for marker, text in self._buttons.items():
            if text == target:
                return marker
        return None


def test_remove_list_only_keeps_file(qapp, tmp_path: Path) -> None:
    state = tmp_path / "state" / "images.json"
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/win11.iso", sha="f" * 64)])
    trash_calls: list[str] = []
    _FakeMsgBox.chosen_role = "list"
    mp = pytest.MonkeyPatch()
    mp.setattr(imd_mod, "QMessageBox", _FakeMsgBox)
    mp.setattr(imd_mod.QFile, "moveToTrash", staticmethod(lambda p: trash_calls.append(p) or True))
    try:
        dlg._remove()
    finally:
        _FakeMsgBox.chosen_role = "cancel"
        mp.undo()
    assert reg.list_images(state) == []
    assert trash_calls == []


def test_remove_trash_calls_moveToTrash(qapp, tmp_path: Path) -> None:
    state = tmp_path / "state" / "images.json"
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/win11.iso", sha="g" * 64)])
    trash_calls: list[str] = []
    _FakeMsgBox.chosen_role = "trash"
    mp = pytest.MonkeyPatch()
    mp.setattr(imd_mod, "QMessageBox", _FakeMsgBox)
    mp.setattr(imd_mod.QFile, "moveToTrash", staticmethod(lambda p: trash_calls.append(p) or True))
    try:
        dlg._remove()
    finally:
        _FakeMsgBox.chosen_role = "cancel"
        mp.undo()
    assert reg.list_images(state) == []
    assert trash_calls == ["/iso/win11.iso"]


def test_fruitless_scan_leaves_play_disabled(qapp, tmp_path: Path) -> None:
    """An empty registry must never end up with an enabled, inert play button."""
    _write_fake_pz(tmp_path, scan_candidates=[])
    dlg = _make_dialog(tmp_path)
    dlg._scan_isos()
    assert _wait_for(lambda: not dlg._reader.any_running() and bool(dlg.status_label.text()))
    assert dlg.list_widget.count() == 0
    assert "Nenhuma imagem" in dlg.status_label.text()
    assert not dlg.play_button.isEnabled()
    assert not dlg.boot_button.isEnabled()
    # The toolbar must come back so the user can still act.
    assert dlg.add_button.isEnabled()
    assert dlg.scan_button.isEnabled()


def test_valid_iso_without_parseable_images_still_offers_indices(qapp, tmp_path: Path) -> None:
    """Retail media inspects as valid with ``imageCount: 0``.

    Observed on a real Win11 25H2 ISO: ``media inspect`` returns
    ``valid: true`` but ``images: []`` with a payloadNote. Without the 1..10
    fallback (the same range the install dialog offers) the edition list is
    empty and the play button can never be enabled.
    """
    entry = _entry("/iso/retail.iso", sha="r" * 64, images=[],
                   payloadNote="install payload present but WIM images not parseable")
    dlg = _make_dialog(tmp_path, seeded=[entry])
    assert dlg.index_list.count() == 10
    assert dlg._selected_index() == 1
    assert dlg.play_button.isEnabled()
    assert "não puderam ser lidos" in dlg.meta_label.text()


def test_invalid_iso_offers_no_indices(qapp, tmp_path: Path) -> None:
    """The fallback must not resurrect an ISO that failed inspection."""
    entry = _entry("/iso/broken.iso", sha="s" * 64, images=[], valid=False)
    dlg = _make_dialog(tmp_path, seeded=[entry])
    assert dlg.index_list.count() == 0
    assert not dlg.play_button.isEnabled()


def test_named_images_win_over_fallback(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/named.iso", sha="n" * 64)])
    assert dlg.index_list.count() == 2
    assert "Windows 11 Home" in dlg.index_list.item(0).text()


def test_remove_trash_reports_failure_from_tuple_result(qapp, tmp_path: Path) -> None:
    """PySide6's static ``moveToTrash(path)`` returns ``(ok, pathInTrash)``.

    The tuple is always truthy, so a failed trash must be read from ``[0]``;
    otherwise the dialog claims success while the file is still on disk.
    """
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/win11.iso", sha="t" * 64)])
    _FakeMsgBox.chosen_role = "trash"
    mp = pytest.MonkeyPatch()
    mp.setattr(imd_mod, "QMessageBox", _FakeMsgBox)
    mp.setattr(imd_mod.QFile, "moveToTrash", staticmethod(lambda p: (False, "")))
    try:
        dlg._remove()
    finally:
        _FakeMsgBox.chosen_role = "cancel"
        mp.undo()
    assert "não pôde ser movido" in dlg.status_label.text()

    dlg2 = _make_dialog(tmp_path, seeded=[_entry("/iso/win12.iso", sha="u" * 64)])
    _FakeMsgBox.chosen_role = "trash"
    mp2 = pytest.MonkeyPatch()
    mp2.setattr(imd_mod, "QMessageBox", _FakeMsgBox)
    mp2.setattr(imd_mod.QFile, "moveToTrash", staticmethod(lambda p: (True, "/trash/win12.iso")))
    try:
        dlg2._remove()
    finally:
        _FakeMsgBox.chosen_role = "cancel"
        mp2.undo()
    assert "lixeira" in dlg2.status_label.text()
    assert "não pôde" not in dlg2.status_label.text()


# ── Add via inspect (async) ──

def test_inspect_and_add_registers_parsed_fields(qapp, tmp_path: Path) -> None:
    state = tmp_path / "state" / "images.json"
    _write_fake_pz(tmp_path)
    dlg = _make_dialog(tmp_path)
    dlg._inspect_and_add(["/found/Win11.iso"], source="manual")
    assert _wait_for(lambda: not dlg._reader.any_running() and not dlg._batch)
    images = reg.list_images(state)
    assert len(images) == 1
    entry = images[0]
    assert entry["valid"] is True
    assert entry["label"] == "Win11 Test"
    assert entry["sha256"] == "SHA_/found/Win11.iso"
    assert [img["index"] for img in entry["images"]] == [1, 4]
    assert dlg.list_widget.count() == 1


def test_inspect_failure_registers_invalid_entry(qapp, tmp_path: Path) -> None:
    state = tmp_path / "state" / "images.json"
    _write_fake_pz(tmp_path, inspect_fail=True)
    dlg = _make_dialog(tmp_path)
    dlg._inspect_and_add(["/bad/iso.iso"], source="manual")
    assert _wait_for(lambda: not dlg._reader.any_running() and not dlg._batch)
    images = reg.list_images(state)
    assert len(images) == 1
    assert images[0]["valid"] is False


def test_inspect_failure_does_not_abort_remaining_batch(qapp, tmp_path: Path) -> None:
    """A single unreadable ISO must not drop the rest of the queue."""
    state = tmp_path / "state" / "images.json"
    _write_fake_pz(tmp_path, inspect_fail=True)
    dlg = _make_dialog(tmp_path)
    dlg._inspect_and_add(["/bad/one.iso", "/bad/two.iso", "/bad/three.iso"], source="scan")
    assert _wait_for(lambda: not dlg._reader.any_running() and not dlg._batch, timeout=20.0)
    images = reg.list_images(state)
    assert {img["path"] for img in images} == {
        "/bad/one.iso", "/bad/two.iso", "/bad/three.iso"
    }
    assert all(img["valid"] is False for img in images)
    assert all(img["source"] == "scan" for img in images)


# ── Scan (async) registers picked candidates ──

def test_scan_registers_new_candidates(qapp, tmp_path: Path) -> None:
    state = tmp_path / "state" / "images.json"
    _write_fake_pz(tmp_path, scan_candidates=["/dir/a.iso", "/dir/b.iso"])
    dlg = _make_dialog(tmp_path)
    # Avoid the interactive candidate-picker modal: return all candidates.
    monkey = pytest.MonkeyPatch()
    monkey.setattr(dlg, "_pick_candidates", lambda paths: paths)
    dlg._scan_isos()
    # scan completes first, then per-candidate inspect runs.
    assert _wait_for(lambda: not dlg._reader.any_running() and not getattr(dlg, "_batch", ["x"]))
    images = reg.list_images(state)
    paths = {img["path"] for img in images}
    assert paths == {"/dir/a.iso", "/dir/b.iso"}


# ── Advanced mode ──

def test_advanced_mode_reveals_sha_full(qapp, tmp_path: Path) -> None:
    dlg = _make_dialog(tmp_path, seeded=[_entry("/iso/win11.iso", sha="h" * 64)],
                       advanced=False)
    # Offscreen widgets are never rendered; assert on the hidden flag instead.
    assert dlg._sha_full_label.isHidden()
    dlg.set_advanced_mode(True)
    assert not dlg._sha_full_label.isHidden()
    assert "h" * 64 in dlg._sha_full_label.text()
