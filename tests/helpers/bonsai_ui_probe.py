"""Isolated real-theme Bonsai UI probe; no host probes or mutable actions."""
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QPushButton, QScrollArea
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
    page.request_action = requested.append
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
    assert page.bonsai_state.text() == "Login indisponível no provedor"
    assert "vencida" in page.bonsai_reason.text()
    assert "Próximo passo" in page.bonsai_next.text()
    assert not page.bonsai_login.isEnabled()
    observed["authProvider"]["fresh"] = False
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert page.bonsai_state.text() == "Login indisponível; provedor sem verificação atual"
    assert "não comprova disponibilidade atual" in page.bonsai_reason.text()
    assert "HTTP 404" in page.bonsai_reason.text()
    assert "não testa login" in page.bonsai_next.text()
    assert not page.bonsai_login.isEnabled()
    area = page.findChildren(QScrollArea)[0]
    area.ensureWidgetVisible(page.bonsai_login)
    app.processEvents()
    assert page.bonsai_login.isVisible()
    assert area.horizontalScrollBar().maximum() == 0
    QTest.mouseClick(page.bonsai_login, Qt.LeftButton)
    assert not requested
    diagnose = next(button for button in page.findChildren(QPushButton) if button.text() == "Atualizar diagnóstico")
    area.ensureWidgetVisible(diagnose)
    app.processEvents()
    QTest.mouseClick(diagnose, Qt.LeftButton)
    assert [action.id for action in requested] == ["ai.bonsai-diagnose"]
    assert not page.bonsai_details.isVisible()
    # Registry recovery enables the explicit private-terminal action.
    observed["loginAvailable"] = False
    observed["loginAttemptAvailable"] = True
    observed["loginTerminalAvailable"] = True
    observed["loginRequiresPrivateTerminal"] = True
    observed["updateObservation"] = {"available": True, "state": "available"}
    page._on_status_ready("private.bonsai.status", "", observed)
    app.processEvents()
    assert page.bonsai_state.text() == "Login disponível no terminal privado"
    assert "terminal privado" in page.bonsai_next.text()
    assert page.bonsai_login.isEnabled()
    area.ensureWidgetVisible(page.bonsai_login)
    app.processEvents()
    QTest.mouseClick(page.bonsai_login, Qt.LeftButton)
    assert [action.id for action in requested] == ["ai.bonsai-diagnose", "ai.claude-bonsai-login"]
    assert requested[-1].args == ("ai", "claude", "login", "bonsai", "--terminal")
    observed["loginCompatibility"] = "registry-404-pinned-cli"
    observed["updateObservation"] = {"available": False, "state": "registry-http-error", "httpStatus": 404,
                                     "failureClass": "package-unavailable"}
    page._on_status_ready("private.bonsai.status", "", observed)
    assert page.bonsai_login.isEnabled()
    assert "npm HTTP 404" in page.bonsai_state.text()
    assert "autenticação depende do Bonsai" in page.bonsai_reason.text()
    assert "não comprova autenticação" in page.bonsai_next.text()
    observed["loginCompatibility"] = "none"
    observed["loginTerminalAvailable"] = False
    page._on_status_ready("private.bonsai.status", "", observed)
    assert not page.bonsai_login.isEnabled()
    assert "execute bonsai login" in page.bonsai_next.text()
    observed["loginAttemptAvailable"] = False
    observed["loginAvailable"] = False
    observed["updateObservation"] = {"state": "registry-http-error", "httpStatus": 404}
    page._on_status_ready("private.bonsai.status", "", observed)
    assert not page.bonsai_login.isEnabled()
    QTest.mouseClick(window.mode_switch, Qt.LeftButton)
    app.processEvents()
    assert page.bonsai_details.isVisible()
    assert "provider-cache" in page.bonsai_details.text()
    assert "bonsai/direct" in page.bonsai_details.text()
    assert window.grab().save(sys.argv[2])
    window.close()
