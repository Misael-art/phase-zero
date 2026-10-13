from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QAccessible
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QComboBox, QFormLayout, QLabel, QPushButton


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _window(qapp):
    from linux.ui_native.main_window import MainWindow

    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    return MainWindow(ROOT), host_patcher, status_patcher


def test_development_controls_build_optional_editor_plan_validate_and_open(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        assert page is not None
        objective = page.findChild(QComboBox, "developmentObjective")
        editor = page.findChild(QComboBox, "developmentEditor")
        prepare = page.findChild(QPushButton, "prepareDevelopment")
        validate = page.findChild(QPushButton, "validateDevelopment")
        open_tool = page.findChild(QPushButton, "openDevelopmentTool")
        assert objective is not None and editor is not None
        assert prepare is not None and validate is not None and open_tool is not None

        editor.setCurrentIndex(1)
        with patch.object(window.runner, "start") as start:
            prepare.click()
        action = start.call_args.args[0]
        assert action.id == "development.recipe.development-web-js.development.vscode"
        assert start.call_args.kwargs["preview"] is True
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", "development-web-js",
            "--capability", "development.vscode",
        ]

        with patch.object(window.runner, "start") as start:
            validate.click()
        assert start.call_args.args[0].id == "capability.status"
        assert start.call_args.kwargs["preview"] is False

        open_tool.click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == "app.vscode"
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_development_controls_have_accessible_names_and_keyboard_order(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        window.show()
        qapp.processEvents()
        page = window.registry.page_for("Desenvolvimento")
        controls = (
            page.findChild(QComboBox, "developmentObjective"),
            page.findChild(QComboBox, "developmentEditor"),
            page.findChild(QPushButton, "prepareDevelopment"),
            page.findChild(QPushButton, "validateDevelopment"),
            page.findChild(QPushButton, "openDevelopmentTool"),
        )
        expected_names = (
            "Objetivo de desenvolvimento", "Editor opcional",
            "Revisar plano e preparar", "Validar ambiente", "Abrir ferramenta",
        )
        expected_descriptions = (
            "Escolha a receita inicial para este projeto.",
            "Escolha Visual Studio Code, VSCodium ou decida depois.",
            "Exibe custos e mudanças antes de preparar o ambiente.",
            "Consulta o estado das ferramentas selecionadas.",
            "Abre o detalhe canônico da ferramenta escolhida.",
        )
        interface_names = (
            "Web JavaScript / TypeScript", "Escolher depois",
            "Revisar plano e preparar", "Validar ambiente", "Abrir ferramenta",
        )
        for control, expected_name, expected_description, interface_name in zip(
            controls, expected_names, expected_descriptions, interface_names, strict=True,
        ):
            assert control.accessibleName() == expected_name
            assert control.accessibleDescription() == expected_description
            interface = QAccessible.queryAccessibleInterface(control)
            assert interface is not None
            assert interface.text(QAccessible.Text.Name) == interface_name
            assert interface.text(QAccessible.Text.Description) == expected_description
            assert control.focusPolicy() & Qt.TabFocus

        form = page.findChild(QFormLayout)
        objective_label = form.labelForField(controls[0])
        editor_label = form.labelForField(controls[1])
        assert isinstance(objective_label, QLabel) and objective_label.buddy() is controls[0]
        assert isinstance(editor_label, QLabel) and editor_label.buddy() is controls[1]

        controls[0].setFocus()
        qapp.processEvents()
        assert controls[0].hasFocus()
        for current, following in zip(controls[:-1], controls[1:], strict=True):
            QTest.keyClick(current, Qt.Key_Tab)
            qapp.processEvents()
            assert following.hasFocus()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


@pytest.mark.parametrize(
    ("action_id", "exit_code", "parsed", "expected"),
    (
        (
            "capability.profile.development-web-js", 130,
            {"kind": "operation", "status": "cancelled"},
            "Preparação pausada entre etapas. O que terminou foi preservado; "
            "gere novo preview para retomar.",
        ),
        (
            "capability.profile.development-web-js", 0,
            {"kind": "operation", "status": "completed"},
            "Preparação concluída. Valide o ambiente para conferir cada ferramenta.",
        ),
        (
            "capability.profile.development-web-js", 0,
            {"kind": "operation", "status": "failed"},
            "Preparação interrompida ou incompleta. Revise o erro; você pode "
            "gerar novo plano e tentar novamente.",
        ),
        (
            "capability.status", 1,
            {"kind": "status", "status": "unknown"},
            "A validação falhou. O estado permanece desconhecido; tente novamente.",
        ),
    ),
    ids=("cancelled", "completed", "failed-with-zero-exit", "validation-failed"),
)
def test_development_operation_results_are_announced_accessibly(
    qapp, monkeypatch, action_id, exit_code, parsed, expected,
):
    from PySide6 import QtGui
    from linux.ui_native.models import OperationResult

    announcement_type = getattr(QtGui, "QAccessibleAnnouncementEvent", None)
    if announcement_type is None:
        pytest.skip("Qt before 6.8 has no QAccessibleAnnouncementEvent")
    events = []
    monkeypatch.setattr(QAccessible, "isActive", staticmethod(lambda: True))
    monkeypatch.setattr(QAccessible, "updateAccessibility", events.append)

    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        action = page.by_id[action_id]
        result = OperationResult(
            action_id=action.id, command=["linux/pz", "capabilities", "apply"],
            preview=False, exit_code=exit_code, started_at="", finished_at="",
            stdout="{}", stderr="", parsed=parsed,
        )

        page.on_operation_result(action, result)

        assert page.status.text() == expected
        assert len(events) == 1
        assert isinstance(events[0], announcement_type)
        assert events[0].message() == expected
        assert events[0].politeness() == QAccessible.AnnouncementPoliteness.Polite
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_development_python_recipe_preserves_os_runtime_copy(qapp):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        objective = page.findChild(QComboBox, "developmentObjective")
        objective.setCurrentIndex(1)
        description = page.findChild(QLabel, "developmentRecipeDescription")
        assert "não altera o Python do sistema" in description.text()
        with patch.object(window.runner, "start") as start:
            page.findChild(QPushButton, "prepareDevelopment").click()
        action = start.call_args.args[0]
        assert action.id == "capability.profile.development-python"
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", "development-python",
        ]
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


def test_cancelled_development_apply_explains_safe_resume(qapp):
    from linux.ui_native.models import OperationResult

    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        action = page.by_id["capability.profile.development-web-js"]
        result = OperationResult(
            action_id=action.id, command=["linux/pz", "capabilities", "apply"],
            preview=False, exit_code=130, started_at="", finished_at="",
            stdout='{"status":"cancelled"}', stderr="", parsed={
                "kind": "operation", "status": "cancelled",
                "summary": "Etapas concluídas preservadas.",
            },
        )
        page.on_operation_result(action, result)
        status = page.findChild(QLabel, "developmentStatus")
        assert status is not None
        assert "pausada entre etapas" in status.text()
        assert "gere novo preview para retomar" in status.text()
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()


@pytest.mark.parametrize(
    ("objective_index", "profile_id", "app_id"),
    (
        (2, "development-rust", "app.rust"),
        (3, "development-c-cpp", "app.cpp"),
        (4, "development-java", "app.maven"),
        (5, "development-dotnet", "app.dotnet"),
    ),
)
def test_development_objectives_create_profile_plan_and_open_canonical_detail(
    qapp, objective_index, profile_id, app_id,
):
    window, host_patcher, status_patcher = _window(qapp)
    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        objective = page.findChild(QComboBox, "developmentObjective")
        objective.setCurrentIndex(objective_index)

        with patch.object(window.runner, "start") as start:
            page.findChild(QPushButton, "prepareDevelopment").click()
        action = start.call_args.args[0]
        assert action.resolved_args(preview=True) == [
            "capabilities", "plan", "--profile", profile_id,
        ]
        assert start.call_args.kwargs["preview"] is True

        page.findChild(QPushButton, "openDevelopmentTool").click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == app_id
    finally:
        window.close()
        host_patcher.stop()
        status_patcher.stop()
