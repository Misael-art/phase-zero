"""Isolated real-theme Bonsai UI probe; no host probes or mutable actions."""
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QScrollArea
from linux.ui_native.app import apply_theme
from linux.ui_native.main_window import MainWindow
from linux.ui_native.status_loader import StatusLoader

root = Path(__file__).resolve().parents[2]
app = QApplication([])
apply_theme(app, sys.argv[1])
with patch.object(MainWindow, "_host_summary"), patch.object(StatusLoader, "fetch"):
    window = MainWindow(root)
    window.resize(800, 600)
    window.show()
    window.show_category("IA & Dev")
    page = window.registry.page_for("IA & Dev")
    requested = []
    selected = []
    page.action_requested.disconnect(window.request_action)
    page.action_requested.connect(requested.append)
    page.action_selected.connect(selected.append)
    observed = {
        "installed": True, "authenticated": False, "sessionUsable": False,
        "proxyAvailable": False, "loginAvailable": False,
        "credentialStatus": {"state": "expired-refresh-required"},
        "authProvider": {"class": "upstream-auth-disabled", "source": "provider-cache", "fresh": True, "currentAvailability": "unknown"},
        "updateObservation": {"state": "registry-http-error", "httpStatus": 404},
    }
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert (window.width(), window.height()) == (800, 600)
    assert page.bonsai_state.text() == "Autenticação desativada pelo Bonsai"
    assert "vencida" in page.bonsai_reason.text()
    assert "PhaseZero não pode reativá-la" in page.bonsai_reason.text()
    assert "suporte oficial Bonsai" in page.bonsai_next.text()
    assert page.bonsai_login.isEnabledTo(window)
    assert page.bonsai_login.objectName() == "primaryButton"
    assert page.bonsai_diagnose.objectName() == "secondaryButton"
    observed["authProvider"]["fresh"] = False
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert page.bonsai_state.text() == "Última falha: autenticação desativada; estado atual desconhecido"
    assert "não comprova disponibilidade atual" in page.bonsai_reason.text()
    assert "HTTP 404" in page.bonsai_reason.text()
    assert "não testa autenticação" in page.bonsai_next.text()
    assert page.bonsai_login.isEnabledTo(window)
    area = page.findChildren(QScrollArea)[0]
    area.ensureWidgetVisible(page.bonsai_login)
    for _ in range(3):
        app.processEvents()
    assert area.horizontalScrollBar().maximum() == 0
    login, diagnose = page.bonsai_login, page.bonsai_diagnose
    assert login.isVisible() and diagnose.isVisible()
    assert login.mapToGlobal(login.rect().center()).y() == diagnose.mapToGlobal(diagnose.rect().center()).y()
    assert login.mapToGlobal(login.rect().center()).x() < diagnose.mapToGlobal(diagnose.rect().center()).x()
    for button in (login, diagnose):
        bounds = button.rect()
        top_left = area.viewport().mapFromGlobal(button.mapToGlobal(bounds.topLeft()))
        bottom_right = area.viewport().mapFromGlobal(button.mapToGlobal(bounds.bottomRight()))
        assert area.viewport().rect().contains(top_left)
        assert area.viewport().rect().contains(bottom_right)
        hit = app.widgetAt(button.mapToGlobal(bounds.center()))
        assert hit is button
        QTest.mouseClick(hit, Qt.LeftButton)
    assert [action.id for action in requested] == ["ai.claude-bonsai-login", "ai.bonsai-diagnose"]
    assert not selected
    assert not page.bonsai_details.isVisible()
    # Registry recovery changes status, not the button's position or availability.
    observed["loginAvailable"] = False
    observed["loginAttemptAvailable"] = True
    observed["loginTerminalAvailable"] = True
    observed["loginRequiresPrivateTerminal"] = True
    observed["updateObservation"] = {"available": True, "state": "available"}
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert page.bonsai_state.text() == "Última falha: autenticação desativada; estado atual desconhecido"
    observed["authProvider"]["class"] = "not-probed"
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert page.bonsai_state.text() == "Tentativa local pronta; autenticação não confirmada"
    assert "terminal privado" in page.bonsai_next.text()
    assert page.bonsai_login.isEnabled()
    assert page.bonsai_login.isEnabledTo(window)
    assert page.bonsai_login.objectName() == "primaryButton"
    assert page.bonsai_diagnose.objectName() == "secondaryButton"
    assert [action.id for action in requested] == ["ai.claude-bonsai-login", "ai.bonsai-diagnose"]
    assert not selected
    assert requested[0].args == ("ai", "claude", "login", "bonsai", "--terminal")
    observed["loginCompatibility"] = "registry-404-pinned-cli"
    observed["updateObservation"] = {"available": False, "state": "registry-http-error", "httpStatus": 404,
                                     "failureClass": "package-unavailable"}
    page._on_status_ready("private.bonsai.status", "", observed)
    assert page.bonsai_login.isEnabled()
    assert page.bonsai_login.objectName() == "primaryButton"
    assert "npm HTTP 404" in page.bonsai_state.text()
    assert "autenticação depende do Bonsai" in page.bonsai_reason.text()
    assert "Authentication is disabled for this application" in page.bonsai_next.text()
    assert window.grab().save(sys.argv[2])
    observed["loginCompatibility"] = "none"
    observed["loginTerminalAvailable"] = False
    page._on_status_ready("private.bonsai.status", "", observed)
    assert page.bonsai_login.isEnabled()
    assert page.bonsai_login.objectName() == "primaryButton"
    assert page.bonsai_diagnose.objectName() == "secondaryButton"
    assert "verifica novamente" in page.bonsai_next.text()
    observed["loginAttemptAvailable"] = False
    observed["loginAvailable"] = False
    observed["updateObservation"] = {"state": "registry-http-error", "httpStatus": 404}
    page._on_status_ready("private.bonsai.status", "", observed)
    assert page.bonsai_login.isEnabled()
    page._on_status_failed("private.bonsai.status", "falha simulada")
    assert page.bonsai_login.isEnabled()
    QTest.mouseClick(window.mode_switch, Qt.LeftButton)
    app.processEvents()
    assert page.bonsai_details.isVisible()
    assert "provider-cache" in page.bonsai_details.text()
    assert "bonsai/direct" in page.bonsai_details.text()
    page._on_status_ready("private.bonsai.status", "", {
        "authProvider": None, "credentialStatus": None, "updateObservation": None,
    })
    assert page.bonsai_login.isEnabled()
    assert page.bonsai_state.text() == "Autenticação não verificada"
    window.close()
