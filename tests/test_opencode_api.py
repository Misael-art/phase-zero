import json
from pathlib import Path
import shutil
import subprocess
import pytest
from linux.ai.api_credits import ApiCredit
from linux.ai.credential_vault import CredentialVault
from linux.ai.opencode_api import OpenAIConsumer, PROVIDER
from tests.test_credential_vault import MemorySecretStore


class Store(MemorySecretStore):
    reads = 0
    def lookup(self, reference):
        self.reads += 1
        return self.items[reference]


@pytest.fixture
def owner(tmp_path, monkeypatch):
    for key, path in [("HOME", tmp_path / "home"), ("XDG_DATA_HOME", tmp_path / "data"),
                      ("XDG_CONFIG_HOME", tmp_path / "config"), ("XDG_STATE_HOME", tmp_path / "state")]:
        monkeypatch.setenv(key, str(path))
    store = Store(); vault = CredentialVault(tmp_path / "data/phasezero/ai-accounts/credentials.json", store)
    entry = vault.add("openai", "API fixture", "fixture-secret-not-in-config")
    vault.record_api_credit(entry.account_id, ApiCredit("openai", "org-example", activation="active", remaining=10,
                                                     observed_at="2026-11-07T12:00:00Z"))
    consumer = OpenAIConsumer(vault)
    monkeypatch.setattr(consumer, "require_runtime", lambda: None)
    monkeypatch.setattr(consumer, "probe", lambda *a: {"gpt-6.1-sol"})
    consumer.config.parent.mkdir(parents=True)
    consumer.config.write_text('{"model":"old/model","permission":{"edit":"ask"}}')
    return consumer, entry, store


def test_explicit_selection_creates_request_grant_and_default_without_persisting_secret(owner):
    consumer, entry, store = owner
    result = consumer.configure(entry.account_id, "proj_example", consented=True)
    assert result["configured"] and result["defaultModel"] == f"{PROVIDER}/gpt-6.1-sol"
    raw = consumer.config.read_text()
    assert "fixture-secret-not-in-config" not in raw
    assert json.loads(raw)["permission"] == {"edit": "ask"}
    assert json.loads(raw)["policies"][-1]["resource"] == PROVIDER
    binding = consumer.request_credential("https://api.openai.com/v1/chat/completions")
    assert binding["key"] == "fixture-secret-not-in-config" and store.reads == 1
    assert binding["organization"] == "org-example" and binding["project"] == "proj_example"


def test_no_consent_or_failed_auth_never_changes_default_or_creates_grant(owner, monkeypatch):
    consumer, entry, store = owner
    before = consumer.config.read_bytes()
    with pytest.raises(ValueError): consumer.configure(entry.account_id, "proj_example")
    def rejected(*args): raise ValueError("HTTP 401")
    monkeypatch.setattr(consumer, "probe", rejected)
    with pytest.raises(ValueError): consumer.configure(entry.account_id, "proj_example", consented=True)
    assert consumer.config.read_bytes() == before
    assert not consumer.state_path.exists()
    assert not consumer.ledger.for_consumer("app.opencode")


@pytest.mark.parametrize("url", ["https://evil.example/v1/responses", "http://api.openai.com/v1/responses", "https://api.openai.com/v1/files", "https://api.openai.com/v1/responses?redirect=other"])
def test_destination_is_checked_before_secret_access(owner, url):
    consumer, entry, store = owner
    with pytest.raises(ValueError): consumer.request_credential(url)
    assert store.reads == 0


def test_revocation_prevents_next_request_without_switching_to_old_provider(owner):
    consumer, entry, store = owner
    consumer.configure(entry.account_id, "proj_example", consented=True)
    before = consumer.config.read_bytes()
    consumer.revoke(entry.account_id)
    with pytest.raises(ValueError): consumer.request_credential("https://api.openai.com/v1/responses")
    assert consumer.config.read_bytes() == before and store.reads == 0


def test_wallet_removal_revokes_request_access_before_deleting_secret(owner):
    from linux.ai.credential_inventory import remove_local_credential
    consumer, entry, store = owner
    consumer.configure(entry.account_id, "proj_example", consented=True)
    assert remove_local_credential(consumer.vault, entry.account_id)
    with pytest.raises(ValueError): consumer.request_credential("https://api.openai.com/v1/responses")
    assert not store.items


def test_zero_or_expired_observation_blocks_new_requests(owner):
    consumer, entry, store = owner
    consumer.configure(entry.account_id, "proj_example", consented=True)
    consumer.vault.record_api_credit(entry.account_id, ApiCredit("openai", "org-example", activation="active", remaining=0,
                                                               observed_at="2026-11-07T12:00:00Z"))
    with pytest.raises(ValueError): consumer.request_credential("https://api.openai.com/v1/responses")
    assert store.reads == 0


def test_explicit_disable_restores_previous_default_but_preserves_user_edits(owner):
    consumer, entry, store = owner
    before = json.loads(consumer.config.read_text())
    consumer.configure(entry.account_id, "proj_example", consented=True)
    assert consumer.disable()["previousDefaultRestored"]
    assert json.loads(consumer.config.read_text()) == before
    assert consumer.disable()["disabled"]
    consumer.configure(entry.account_id, "proj_example", consented=True)
    consumer.config.write_text('{"model":"user/change"}')
    with pytest.raises(ValueError, match="configuração mudou"): consumer.disable()
    assert consumer.config.read_text() == '{"model":"user/change"}'
    assert consumer.state()["enabled"] is False


def test_plugin_http_binding_checks_host_model_and_revocation(tmp_path):
    node = shutil.which("node")
    if not node: pytest.skip("Node unavailable")
    plugin = Path(__file__).parents[1] / "linux/ai/assets/opencode-openai-api/index.js"
    script = '''
const {authorizeRequest} = await import(process.argv[1]);
const event = {request:new Request('https://api.openai.com/v1/responses',{method:'POST',body:JSON.stringify({model:'gpt-6.1-sol'})})};
await authorizeRequest(event,async()=>({key:'fixture',organization:'org-test',project:'proj_test',model:'gpt-6.1-sol'}));
if(event.request.headers.get('authorization')!=='Bearer fixture'||event.request.redirect!=='error')throw Error('missing binding');
let reads=0;
try{await authorizeRequest({request:new Request('https://evil.example')},async()=>{reads++;return {}});throw Error('accepted');}catch(e){if(e.message==='accepted')throw e;}
if(reads)throw Error('secret read before host check');
try{await authorizeRequest(event,async()=>{throw Error('revoked')});throw Error('accepted');}catch(e){if(e.message==='accepted')throw e;}
console.log('request-binding-verified');
'''
    result = subprocess.run([node, "--input-type=module", "-e", script, plugin.as_uri()], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert "request-binding-verified" in result.stdout
