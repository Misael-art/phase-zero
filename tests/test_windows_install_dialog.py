from __future__ import annotations

import json
from pathlib import Path

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QStandardItemModel
from PySide6.QtWidgets import QApplication

from linux.ui_native.windows_install_dialog import WindowsInstallDialog, completed_image_indices


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_completed_indices_are_scoped_to_matching_iso_digest(tmp_path: Path) -> None:
    complete = tmp_path / "op-complete"
    complete.mkdir()
    (complete / "operation.json").write_text(json.dumps({"state": "completed"}))
    (complete / "plan.json").write_text(json.dumps({"imageIndex": 4, "iso": {"sha256": "a" * 64}}))
    failed = tmp_path / "op-failed"
    failed.mkdir()
    (failed / "operation.json").write_text(json.dumps({"state": "failed"}))
    (failed / "plan.json").write_text(json.dumps({"imageIndex": 5}))
    assert completed_image_indices(tmp_path, iso_sha256="a" * 64) == {4}
    assert completed_image_indices(tmp_path, iso_sha256="b" * 64) == set()


def test_removed_or_missing_vm_releases_completed_index(tmp_path: Path) -> None:
    removed = tmp_path / "op-removed"
    removed.mkdir()
    (removed / "operation.json").write_text(json.dumps({
        "state": "completed", "vmRemovedAt": "2026-08-16T12:00:00Z",
    }))
    (removed / "plan.json").write_text(json.dumps({"imageIndex": 2, "iso": {"sha256": "a" * 64}}))

    missing = tmp_path / "op-missing"
    missing.mkdir()
    (missing / "operation.json").write_text(json.dumps({"state": "completed"}))
    (missing / "plan.json").write_text(json.dumps({"imageIndex": 3, "iso": {"sha256": "a" * 64}}))
    (missing / "vm_dir").write_text(str(tmp_path / "no-longer-present"))

    active = tmp_path / "op-active"
    active.mkdir()
    vm_dir = tmp_path / "existing-vm"
    vm_dir.mkdir()
    (active / "operation.json").write_text(json.dumps({"state": "completed"}))
    (active / "plan.json").write_text(json.dumps({"imageIndex": 4, "iso": {"sha256": "a" * 64}}))
    (active / "vm_dir").write_text(str(vm_dir))

    assert completed_image_indices(tmp_path, iso_sha256="a" * 64) == {4}


def test_dialog_allows_reinstalling_edition_used_by_another_vm(qapp) -> None:
    dialog = WindowsInstallDialog(used_indices={2, 7})
    assert dialog.isWindow()
    assert dialog.testAttribute(Qt.WA_StyledBackground)
    assert dialog.autoFillBackground()
    assert dialog.edition_combo.count() == 0
    model = dialog.edition_combo.model()
    assert isinstance(model, QStandardItemModel)
    assert dialog.manual_index.value() == 0
    assert dialog.manual_index.specialValueText() == "Informe o índice da imagem"
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()


def test_dialog_exposes_only_installable_profiles_and_returns_iso_before_player(qapp, tmp_path: Path) -> None:
    # UX-010: sem medição do host, o modo simples fica no perfil compatível.
    # virtio-gl é experimental e só aparece no avançado, dito como tal.
    iso = tmp_path / "Windows.iso"
    iso.touch()
    simple = WindowsInstallDialog(used_indices=set())
    simple_ids = [simple.graphics_combo.itemData(i)[0] for i in range(simple.graphics_combo.count())]
    assert simple_ids == ["compat"]
    simple.close()
    simple.deleteLater()

    dialog = WindowsInstallDialog(used_indices=set(), advanced=True)
    dialog.iso_edit.setText(str(iso))
    dialog._set_image_entries([{"index": 1, "edition": "Windows 11 Home"}])
    dialog._media_inspected = True
    dialog._media_valid = True
    ids = [dialog.graphics_combo.itemData(index)[0] for index in range(dialog.graphics_combo.count())]
    labels = [dialog.graphics_combo.itemText(index) for index in range(dialog.graphics_combo.count())]
    assert ids == ["compat", "virtio-gl"]
    assert labels[0] == "compat — máxima compatibilidade"
    assert "experimental" in labels[1] and "sem 3D garantido" in labels[1]
    assert not hasattr(dialog, "custom_graphics")
    assert not hasattr(dialog, "custom_label")
    dialog.graphics_combo.setCurrentIndex(1)
    values = dialog.values()
    assert values["input"] == str(iso)
    assert values["graphics"] == "virtio-gl"
    assert values["image_index"] == "1"
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()


def test_unreadable_wim_requires_explicit_index(qapp, tmp_path: Path) -> None:
    iso = tmp_path / "retail.iso"
    iso.touch()
    dialog = WindowsInstallDialog()
    dialog.iso_edit.setText(str(iso))
    dialog._set_image_entries([])
    dialog._media_inspected = True
    dialog._media_valid = True

    assert dialog.edition_combo.count() == 0
    assert dialog.manual_index.value() == 0
    assert dialog.values()["image_index"] == "0"
    dialog.manual_index.setValue(4)
    assert dialog.values()["image_index"] == "4"

    warnings: list[str] = []
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(
        "linux.ui_native.windows_install_dialog.QMessageBox.warning",
        lambda _parent, title, _message: warnings.append(title),
    )
    try:
        dialog.manual_index.setValue(0)
        dialog._accept_if_valid()
    finally:
        monkeypatch.undo()
    assert warnings == ["Índice da edição necessário"]
    dialog.close()
    dialog.deleteLater()
    QApplication.processEvents()
