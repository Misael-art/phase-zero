from pathlib import Path
from unittest.mock import Mock
import http.server
import threading
import json
import pytest
from PySide6.QtWidgets import QApplication, QDialog
from linux.ai.credential_vault import CredentialVault, CredentialVaultError
from linux.ai.deepseek_harness_auth import AccountSession, AccountBridgeError
from linux.ui_native.harness_connection import HarnessConnectionDialog, recommended_workspace
from linux.ui_native.pages.ai_overview import overview, HOST, HARNESS, MEMORY


class Store:
    def __init__(self): self.items = {}
    def store(self, ref, value): self.items[ref] = value
    def lookup(self, ref): return self.items.get(ref)
    def delete(self, ref): return self.items.pop(ref, None) is not None


@pytest.fixture
def wallet(tmp_path):
    return CredentialVault(tmp_path / "wallet/credentials.json", Store())


def test_selected_key_never_falls_back_across_provider_pending_or_removed(wallet):
    entry = wallet.add("DeepSeek", "Personal", "fixture-key")
    assert wallet.selected_secret(entry.account_id, provider="deepseek") == "fixture-key"
    with pytest.raises(CredentialVaultError): wallet.selected_secret(entry.account_id, provider="other")
    with pytest.raises(CredentialVaultError): wallet.selected_secret("credential:" + "a" * 32, provider="deepseek")
    wallet.remove(entry.account_id)
    with pytest.raises(CredentialVaultError): wallet.selected_secret(entry.account_id, provider="deepseek")


def test_workspace_uses_saved_existing_project_then_detected_context(tmp_path, monkeypatch):
    project = tmp_path / "project"; project.mkdir(); (project / ".git").mkdir()
    nested = project / "src"; nested.mkdir(); monkeypatch.chdir(nested)
    monkeypatch.delenv("PZ_WORKSPACE_ROOT", raising=False)
    assert recommended_workspace(tmp_path / "installed") == project
    previous = tmp_path / "previous"; previous.mkdir()
    assert recommended_workspace(tmp_path, str(previous)) == previous
    assert recommended_workspace(tmp_path, str(tmp_path / "missing")) == project


def test_connect_dialog_filters_wallet_requires_api_consent_and_keeps_secret_off_account_route(wallet, tmp_path, monkeypatch):
    app = QApplication.instance() or QApplication([])
    monkeypatch.setenv("PZ_WORKSPACE_ROOT", str(tmp_path))
    entry = wallet.add("deepseek", "Minha chave", "fixture-selected")
    wallet.add("other", "Outro provedor", "fixture-other")
    dialog = HarnessConnectionDialog(tmp_path, vault=wallet)
    assert dialog.workspace.text() == str(tmp_path)
    assert dialog.values()["authRoute"] == "account"
    assert dialog.credential.count() == 2
    dialog.route.setCurrentIndex(1)
    assert dialog.values()["credentialId"] == entry.account_id
    dialog.validate(); assert dialog.result() != QDialog.Accepted
    assert "Confirme" in dialog.error.text()
    dialog.consent.setChecked(True); dialog.validate()
    assert dialog.result() == QDialog.Accepted
    dialog.credential.setCurrentIndex(1); dialog.key.setText("fixture-new-key")
    assert dialog.values()["apiKey"] == "fixture-new-key"
    dialog.route.setCurrentIndex(0)
    assert dialog.values()["apiKey"] == "" and dialog.values()["credentialId"] == ""
    dialog.close(); app.processEvents()


def test_dashboard_does_not_infer_running_or_connected_from_installation():
    rows, components = overview({HOST: {"clis": {"codex": {"available": True}}, "services": {"ollama": {"active": False}}, "mcp": {}},
                                HARNESS: {"installed": True, "runtimeState": "stopped"}})
    states = {r[0]: r[1] for r in rows}
    assert states["Agentes e ferramentas"] == "1 instalados"
    assert states["Serviços do host"] == "0 ativos"
    assert states["Conexões MCP"] == "Não verificadas"
    assert states["DeepSeek Harness"] == "Instalado · parado"
    assert states["Memória compartilhada"] == "Aguardando leitura"
    assert ("Ollama", "Parado", "Serviço") in components
    rows, _ = overview({MEMORY: {"serverReachable": True, "automatic": True}})
    assert next(r for r in rows if r[0] == "Memória compartilhada")[1] == "Ativa"


def test_oauth_uses_only_upstream_methods_and_checks_deepseek_authority():
    session = AccountSession.__new__(AccountSession); session.origin = "http://127.0.0.1:4180"; session.version = "0.2.1-rc.2"
    session.call = Mock(return_value={"attempt": {"phase": "waiting-browser", "authorizeUrl": "https://platform.deepseek.com/dsh/authorize?state=fixture"}})
    assert session.login_url().startswith("https://platform.deepseek.com/dsh/authorize")
    call = session.call.call_args
    assert call.args[0] == "account/startSignIn"
    assert call.args[1]["callbackOrigin"] == session.origin and call.args[1]["loginSource"] == "web"
    session.call.return_value = {"attempt": {"authorizeUrl": "https://example.org/dsh/authorize?state=fixture"}}
    with pytest.raises(AccountBridgeError, match="authority"): session.login_url()


def test_oauth_status_projects_no_authorization_url_or_token():
    session = AccountSession.__new__(AccountSession)
    session.call = lambda *_: {"status": "credential-stored", "attempt": {"phase": "succeeded", "authorizeUrl": "secret", "token": "secret"}}
    assert session.state() == {"state": "credential-stored", "phase": "succeeded"}


def test_account_rpc_uses_signed_cookie_origin_and_named_arguments():
    observed = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Set-Cookie", "fixture-session=owned; HttpOnly; Path=/")
            self.end_headers()
        def do_POST(self):
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            observed.append((self.path, dict(self.headers), request))
            assert isinstance(request["payload"]["args"], dict)
            body = json.dumps({"type": "host-response", "rpcId": request["rpcId"], "result": {"ok": True, "value": {"status": "signed-out", "attempt": None}}}).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        port = server.server_address[1]
        session = AccountSession(f"http://127.0.0.1:{port}/?token=fixture", port, version="0.2.1-rc.2")
        assert session.state()["state"] == "signed-out"
        path, headers, request = observed[0]
        assert path == "/api/account/getState" and headers["Origin"] == session.origin
        assert headers["Cookie"] == "fixture-session=owned"
        assert request["payload"] == {"args": {}}
        with pytest.raises(AccountBridgeError): session.call("inference/run", {})
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
