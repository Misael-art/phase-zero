"""Request-bound OpenAI API consumer. No router, token file or account fallback."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import shutil
import tempfile
import urllib.request
import urllib.error

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from linux.ai.account_contract import Connection
from linux.ai.credential_vault import CredentialVault, credential_vault_path
from linux.ai.grants import GrantLedger
from linux.lib.pz_hostbackup import backup_file

PROVIDER = "phasezero-openai-api"
CONSUMER = "app.opencode"
ADAPTER = "openai-api-wallet"
SUPPORT = {CONSUMER: {ADAPTER: ("inference",)}}


def save(path, value):
    atomic(path, json.dumps(value).encode())


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError("symlink preservado")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".openai-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


class OpenAIConsumer:
    def __init__(self, vault=None):
        data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        self.state_path = data / "opencode-route-installer/openai-api.json"
        self.ledger = GrantLedger(data / "phasezero/ai-accounts/grants.json")
        self.vault = vault or CredentialVault(credential_vault_path())
        self.config = config / "opencode/opencode.json"

    def state(self):
        if self.state_path.is_symlink(): raise ValueError("registro symlink preservado")
        if not self.state_path.exists(): return {}
        return json.loads(self.state_path.read_text())

    def selected(self):
        state = self.state()
        if not state.get("enabled"): raise ValueError("OpenAI não autorizado para OpenCode")
        self.vault.reload_metadata()
        entry = self.vault.selected_entry(state["credentialId"], provider="openai")
        credit = self.vault.api_credit(entry.account_id)
        if not credit or credit.organization != state["organization"] or credit.state != "active":
            raise ValueError("cota ausente, vencida, esgotada ou organização alterada")
        grant_id = state["grantId"]
        self.ledger = GrantLedger(self.ledger.path)
        if not any(g.grant_id == grant_id and g.connection_id == entry.account_id
                   and "inference" in g.scopes for g in self.ledger.for_consumer(CONSUMER)):
            raise ValueError("consentimento revogado")
        return state, entry, credit

    def request_credential(self, url):
        # HTTP only; the plugin refuses WebSocket and non-OpenAI destinations.
        if url not in {"https://api.openai.com/v1/chat/completions", "https://api.openai.com/v1/responses"}:
            raise ValueError("destino fora da API OpenAI autorizada")
        state, entry, _ = self.selected()
        return {"key": self.vault.selected_secret(entry.account_id, provider="openai"),
                "organization": state["organization"], "project": state["project"], "model": state["model"]}

    def probe(self, credential_id, organization, project):
        key = self.vault.selected_secret(credential_id, provider="openai")
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs): return None
        request = urllib.request.Request("https://api.openai.com/v1/models", headers={
            "Authorization": "Bearer " + key, "OpenAI-Organization": organization, "OpenAI-Project": project})
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
                return {row["id"] for row in json.load(response).get("data", [])}
        except urllib.error.HTTPError as error:
            raise ValueError(f"API OpenAI recusou autenticação/acesso: HTTP {error.code}") from None
        except (OSError, ValueError):
            raise ValueError("consulta OpenAI indisponível; saldo não verificado") from None

    def configure(self, credential_id, project, model="gpt-6.1-sol", *, consented=False):
        if not consented: raise ValueError("consentimento de consumo API necessário")
        self.require_runtime()
        if not re.fullmatch(r"proj_[A-Za-z0-9_-]{1,100}", project): raise ValueError("projeto API inválido")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", model) or "codex" in model.casefold():
            raise ValueError("modelo API inválido ou fora do benefício")
        self.vault.reload_metadata()
        entry = self.vault.selected_entry(credential_id, provider="openai")
        credit = self.vault.api_credit(credential_id)
        if not credit or credit.state != "active": raise ValueError("registre concessão ativa da organização")
        if not re.fullmatch(r"org[-_][A-Za-z0-9_-]{1,100}", credit.organization): raise ValueError("organização API inválida")
        # Read-only auth/model probe. It does not establish grant issuance/balance.
        if model not in self.probe(credential_id, credit.organization, project):
            raise ValueError("modelo indisponível para chave/organização/projeto")
        if self.config.is_symlink(): raise ValueError("configuração symlink preservada")
        from linux.ai.opencode_9router_manager import parse_jsonc
        before = self.config.read_bytes() if self.config.exists() else b"{}"
        value = parse_jsonc(before.decode())
        current = self.state()
        if current and not current.get("restored"): raise ValueError("desative conexão atual antes de substituir chave")
        backup = backup_file(self.config, module="opencode-openai-api")
        plugin = Path(__file__).parent / "assets/opencode-openai-api"
        value.setdefault("plugins", []).append({"package": str(plugin), "options": {
            "python": "/usr/bin/python3" if Path("/usr/bin/python3").is_file() else sys.executable,
            "manager": str(Path(__file__).resolve())}})
        value.setdefault("providers", {})[PROVIDER] = {
            "name": "OpenAI API · carteira PhaseZero", "canonical": "openai",
            "package": "@opencode/ai/providers/openai-compatible",
            "settings": {"baseURL": "https://api.openai.com/v1", "apiKey": "phasezero-request-bound"},
            "models": {model: {"name": model, "modelID": model}}}
        value["model"] = f"{PROVIDER}/{model}"
        value.setdefault("policies", []).extend([
            {"action": "provider.use", "resource": "*", "effect": "deny"},
            {"action": "provider.use", "resource": PROVIDER, "effect": "allow"}])
        # Grant first, but disabled runtime until the config transaction finishes.
        connection = Connection(entry.account_id, entry.account_id, ADAPTER, "opencode", enabled=True)
        grant = self.ledger.grant(connection, CONSUMER, ("inference",), support=SUPPORT, consented=True)
        state = {"enabled": False, "credentialId": credential_id, "organization": credit.organization,
                 "project": project, "model": model, "grantId": grant.grant_id,
                 "backup": str(backup) if backup else None,
                 "previousConfigExisted": self.config.exists(),
                 "previousHash": hashlib.sha256(before).hexdigest(),
                 "configHash": hashlib.sha256(json.dumps(value).encode()).hexdigest()}
        save(self.state_path, state)
        try:
            if self.config.exists() and self.config.read_bytes() != before: raise ValueError("configuração mudou; preservada")
            save(self.config, value)
            state.update(enabled=True, configHash=hashlib.sha256(self.config.read_bytes()).hexdigest())
            save(self.state_path, state)
        except Exception:
            self.ledger.revoke(grant.grant_id)
            raise
        return {"configured": True, "defaultModel": value["model"], "balanceVerified": False,
                "billing": "provider-uses-promotional-then-purchased-credits", "reloadRequired": True}

    @staticmethod
    def require_runtime():
        binary = shutil.which("opencode")
        if not binary: raise ValueError("OpenCode não instalado")
        result = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=10)
        match = re.search(r"(\d+)\.(\d+)\.(\d+)", result.stdout)
        if result.returncode or not match or tuple(map(int, match.groups())) < (2, 2, 6):
            raise ValueError("OpenCode 2.2.6 ou posterior necessário para contrato de políticas/hooks; alinhe CLI e desktop")
        if shutil.which("pacman"):
            desktop = subprocess.run(["pacman", "-Q", "opencode-desktop-bin"], capture_output=True, text=True, timeout=10)
            version = re.search(r"(\d+)\.(\d+)\.(\d+)", desktop.stdout)
            if desktop.returncode == 0 and (not version or version.groups() != match.groups()):
                raise ValueError("CLI e desktop OpenCode precisam da mesma versão antes de configurar API")

    def revoke(self, credential_id):
        state = self.state()
        if state.get("credentialId") != credential_id: return False
        state["enabled"] = False
        save(self.state_path, state)
        self.ledger.revoke(state["grantId"])
        # Keep the blocked provider selected. Never fall back to a paid account.
        return True

    def disable(self):
        state = self.state()
        if not state or state.get("restored"): return {"disabled": True}
        self.revoke(state["credentialId"])
        if self.config.exists():
            current_hash = hashlib.sha256(self.config.read_bytes()).hexdigest()
            if current_hash == state.get("previousHash"):
                state["restored"] = True
                save(self.state_path, state)
                return {"disabled": True, "previousDefaultRestored": True}
            if current_hash != state.get("configHash"):
                raise ValueError("configuração mudou; consumo bloqueado, restauração exige revisão")
            if state.get("backup"):
                previous = Path(state["backup"]).read_bytes()
                if hashlib.sha256(previous).hexdigest() != state["previousHash"]:
                    raise ValueError("backup divergiu; consumo bloqueado, revisão necessária")
                atomic(self.config, previous)
            elif not state.get("previousConfigExisted"):
                self.config.unlink()
        elif state.get("previousConfigExisted"):
            raise ValueError("configuração ausente; consumo bloqueado, revisão necessária")
        state["restored"] = True
        save(self.state_path, state)
        return {"disabled": True, "previousDefaultRestored": True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["credential", "configure", "disable"])
    args = parser.parse_args()
    try:
        owner = OpenAIConsumer()
        payload = json.load(sys.stdin) if args.action != "disable" else {}
        if args.action == "credential":
            result = owner.request_credential(payload["url"])
        elif args.action == "configure":
            result = owner.configure(payload["credentialId"], payload["project"], payload.get("model", "gpt-6.1-sol"), consented=payload.get("consented") is True)
        else: result = owner.disable()
        # credential is an internal pipe protocol. Never expose through UI/logging.
        sys.stdout.write(json.dumps(result))
    except Exception:
        sys.stderr.write("Conexão OpenAI não autorizada ou indisponível; nenhum fallback.\n")
        return 1
    return 0


if __name__ == "__main__": raise SystemExit(main())
