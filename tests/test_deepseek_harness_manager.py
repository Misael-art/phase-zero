from __future__ import annotations

import hashlib
import io
import json
import os
import socket
import stat
import time
from pathlib import Path

import pytest

from linux.ai import deepseek_harness_manager as manager


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


@pytest.fixture
def dsh_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    root = tmp_path / "phasezero" / "deepseek-harness"
    monkeypatch.setenv("PZ_DSH_ROOT", str(root))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg-data"))
    monkeypatch.setenv("PZ_DSH_PORT", str(_free_port()))
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    return root


def _installed_runtime(root: Path, *, crash: bool = False) -> tuple[Path, Path]:
    runtime_name = "dsh-test-runtime"
    runtime = root / "runtime" / runtime_name
    node = runtime / "node" / "bin" / "node"
    dsh = runtime / "app" / "node_modules" / "@deepseek-ai" / "dsh" / "lib" / "bin.js"
    node.parent.mkdir(parents=True)
    dsh.parent.mkdir(parents=True)
    script = """#!/usr/bin/env python3
import os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
record = os.environ.get('PZ_DSH_FAKE_ENV_RECORD')
if record:
    with open(record, 'w') as stream:
        json.dump({'apiKey': os.environ.get('DEEPSEEK_API_KEY'), 'home': os.environ.get('DSH_HOME'),
                   'permission': os.environ.get('DSH_PERMISSION_MODE'), 'cwd': os.getcwd(),
                   'sensitiveNames': [name for name in ('OPENAI_API_KEY', 'AWS_SECRET_ACCESS_KEY', 'NODE_AUTH_TOKEN') if os.environ.get(name)],
                   'nodeOptions': os.environ.get('NODE_OPTIONS'),
                   'nodeConfigNames': [name for name in ('NODE_PATH', 'NODE_EXTRA_CA_CERTS', 'NPM_CONFIG_USERCONFIG') if os.environ.get(name)]}, stream)
port = int(sys.argv[sys.argv.index('--port') + 1])
print(f'dsh web: http://127.0.0.1:{port}/?token=fixture-launch-secret', flush=True)
print('apiKey=fixture-visible-secret', flush=True)
if os.environ.get('PZ_DSH_FAKE_CRASH'):
    raise SystemExit(19)
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'fixture web ui')
    def log_message(self, *_args):
        pass
HTTPServer(('127.0.0.1', port), Handler).serve_forever()
"""
    node.write_text(script, encoding="utf-8")
    node.chmod(node.stat().st_mode | stat.S_IXUSR)
    dsh.write_text("// fixture only; never executed by the fake Node shim\n", encoding="utf-8")
    manager._atomic_json(manager.active_file(), {
        "schemaVersion": 1,
        "version": manager._read_pins()["harness"]["version"],
        "nodeVersion": manager._read_pins()["node"]["version"],
        "runtimePath": runtime_name,
    })
    return runtime, node


def test_plan_and_diagnostics_are_read_only_and_keep_external_states_unknown(dsh_root: Path):
    plan = manager.plan_payload()
    doctor = manager.doctor_payload()
    assert plan["mutatesHost"] is False
    assert plan["startsRuntime"] is False
    assert not dsh_root.exists()
    assert doctor["quota"] == "unknown"
    assert doctor["balance"] == "unknown"
    assert doctor["sandboxEnforcement"] == "unknown"
    assert doctor["memoryBudget"] in {"sufficient", "unknown"}
    assert {check["id"] for check in doctor["checks"]} >= {
        "sandbox-enforcement", "account-session", "api-validity-and-quota"
    }


def test_absent_status_is_a_successful_report_without_creating_managed_state(
    dsh_root: Path, capsys: pytest.CaptureFixture[str],
):
    exit_code = manager.main(["status", "--json"])
    report = json.loads(capsys.readouterr().out)
    assert exit_code == 0
    assert report["state"] == "not-installed"
    assert report["ok"] is False
    assert not dsh_root.exists()


def test_plan_rejects_filesystem_root_or_symlink_as_managed_root(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    target = tmp_path / "target"
    link = tmp_path / "managed-link"
    link.symlink_to(target, target_is_directory=True)
    monkeypatch.setenv("PZ_DSH_ROOT", str(link))
    plan = manager.plan_payload()
    assert plan["ok"] is False
    assert plan["reason"] == "unsafe-managed-root"
    assert not target.exists()


def test_plan_and_start_block_when_available_memory_is_below_budget(
    dsh_root: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setattr(manager, "_available_memory_bytes", lambda: manager.MIN_AVAILABLE_MEMORY_BYTES - 1)
    plan = manager.plan_payload()
    assert plan["reason"] == "insufficient-memory"
    _installed_runtime(dsh_root)
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    with pytest.raises(manager.DshError, match="2 GiB available memory"):
        manager.start(str(workspace), "api")
    assert not manager.supervisor_file().exists()


def test_truncated_node_download_fails_integrity_and_deletes_partial(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    monkeypatch.setattr(manager.urllib.request, "urlopen", lambda *_args, **_kwargs: Response(b"short"))
    target = tmp_path / "node.tar.xz"
    with pytest.raises(manager.DshError, match="SHA-256"):
        manager._download("https://nodejs.org/pinned.tar.xz", target, hashlib.sha256(b"different").hexdigest())
    assert not target.exists()


def test_registry_failure_rolls_back_without_replacing_active_runtime(
    dsh_root: Path, monkeypatch: pytest.MonkeyPatch,
):
    old_runtime, _node = _installed_runtime(dsh_root)
    old_active = manager._load_json(manager.active_file())
    monkeypatch.setattr(manager, "_host_support", lambda: ("linux", "x64"))
    monkeypatch.setattr(manager, "plan_payload", lambda: {"ok": True, "reason": "", "nextAction": "install"})
    monkeypatch.setattr(manager, "_download", lambda _url, target, _hash: target.write_bytes(b"fixture"))
    monkeypatch.setattr(manager, "_safe_extract", lambda _archive, _target: None)

    def fake_flatten(_extracted: Path, destination: Path, _os_name: str) -> None:
        node = destination / "bin" / "node"
        npm = destination / "bin" / "npm"
        node.parent.mkdir(parents=True)
        node.write_text("fixture", encoding="utf-8")
        npm.write_text("fixture", encoding="utf-8")
        node.chmod(0o700)
        npm.chmod(0o700)

    monkeypatch.setattr(manager, "_flatten_node", fake_flatten)
    monkeypatch.setenv("NODE_OPTIONS", "--require=/tmp/ambient-hook.js")
    monkeypatch.setenv("NODE_PATH", "/tmp/ambient-modules")
    monkeypatch.setenv("NPM_CONFIG_USERCONFIG", "/tmp/ambient-npmrc")

    def fail_registry(args, **kwargs):
        assert "NODE_OPTIONS" not in kwargs["env"]
        assert "NODE_PATH" not in kwargs["env"]
        assert "NPM_CONFIG_USERCONFIG" not in kwargs["env"]
        if args[1] == "--version":
            return "v24.22.0"
        assert "--userconfig" in args and "--globalconfig" in args
        raise manager.DshError("dependency-failed", "registry unavailable", "retry")

    monkeypatch.setattr(manager, "_run_checked", fail_registry)
    with pytest.raises(manager.DshError, match="registry unavailable"):
        manager.install(update=True)
    assert manager._load_json(manager.active_file()) == old_active
    assert old_runtime.is_dir()
    assert not list(manager.install_root().glob(".stage-*"))


def test_port_conflict_does_not_stop_or_replace_unrelated_listener(dsh_root: Path, tmp_path: Path):
    _installed_runtime(dsh_root)
    port = manager._port()
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen()
        with pytest.raises(manager.DshError, match="occupied"):
            manager.start(str(tmp_path), "account")
        assert manager._port_in_use(port)
        assert not manager.supervisor_file().exists()


def test_api_route_is_explicit_and_does_not_inherit_project_key(dsh_root: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    _installed_runtime(dsh_root)
    workspace = tmp_path / "project"
    workspace.mkdir()
    (workspace / ".env").write_text("DEEPSEEK_API_KEY=project-key-fixture\n", encoding="utf-8")
    env_record = tmp_path / "dsh-env.json"
    monkeypatch.setenv("DEEPSEEK_API_KEY", "ambient-key-fixture")
    monkeypatch.setenv("OPENAI_API_KEY", "ambient-other-key-fixture")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "ambient-cloud-key-fixture")
    monkeypatch.setenv("NODE_AUTH_TOKEN", "ambient-registry-token-fixture")
    monkeypatch.setenv("NODE_OPTIONS", "--require=/tmp/ambient-hook.js")
    monkeypatch.setenv("NODE_PATH", "/tmp/ambient-modules")
    monkeypatch.setenv("NPM_CONFIG_USERCONFIG", "/tmp/ambient-npmrc")
    monkeypatch.setenv("PZ_DSH_FAKE_ENV_RECORD", str(env_record))
    started = manager.start(str(workspace), "api")
    captured = json.loads(env_record.read_text(encoding="utf-8"))
    assert started["authRoute"] == "api"
    assert started["apiCredential"] == "not observed"
    assert captured["apiKey"] is None
    assert captured["sensitiveNames"] == []
    assert captured["nodeConfigNames"] == []
    assert captured["nodeOptions"] == "--max-old-space-size=2048"
    assert captured["home"].endswith("/homes/api")
    assert captured["permission"] == "workspace-write"
    assert Path(captured["cwd"]) == dsh_root / "homes/api/launch"
    assert Path(captured["cwd"]) != workspace
    for private_path in (dsh_root, dsh_root / "homes", dsh_root / "homes/api", dsh_root / "homes/api/launch"):
        assert stat.S_IMODE(private_path.stat().st_mode) == 0o700
    assert started["workspaceSelection"] == "confirm in Harness Web UI"
    manager._stop_supervisor()


def test_cli_port_override_is_loopback_and_status_retains_choice(
    dsh_root: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
):
    _installed_runtime(dsh_root)
    workspace = tmp_path / "port-workspace"
    workspace.mkdir()
    port = _free_port()
    result = manager.main([
        "start", "--workspace", str(workspace), "--auth-route", "api",
        "--port", str(port), "--json",
    ])
    output = capsys.readouterr().out
    assert result == 0
    assert json.loads(output)["port"] == port
    monkeypatch.delenv("PZ_DSH_PORT", raising=False)
    assert manager.status_payload()["port"] == port
    manager._stop_supervisor()


def test_supervisor_auth_handoff_redacts_persisted_token_and_stops_only_owned_child(
    dsh_root: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
):
    _installed_runtime(dsh_root)
    browser_record = tmp_path / "browser-url.txt"
    browser = tmp_path / "browser-fixture"
    browser.write_text(
        "#!/usr/bin/env python3\nimport os,sys\nopen(os.environ['PZ_DSH_BROWSER_RECORD'],'w').write(sys.argv[-1])\n",
        encoding="utf-8",
    )
    browser.chmod(0o700)
    monkeypatch.setenv("BROWSER", str(browser))
    monkeypatch.setenv("PZ_DSH_BROWSER_RECORD", str(browser_record))
    started = manager.start(str(tmp_path), "account")
    assert started["state"] == "running"
    pid = started["processId"]
    assert pid

    duplicate = manager.start(str(tmp_path), "account")
    assert duplicate["processId"] == pid

    opened = manager._dispatch(manager.build_parser().parse_args(["open", "--json"]))[0]
    assert opened["opened"] is True
    assert browser_record.exists()
    assert "fixture-launch-secret" in browser_record.read_text(encoding="utf-8")
    assert "fixture-launch-secret" not in manager.state_file().read_text(encoding="utf-8")
    assert "fixture-launch-secret" not in manager.supervisor_file().read_text(encoding="utf-8")
    logged = manager.log_file().read_text(encoding="utf-8")
    assert "fixture-launch-secret" not in logged
    assert "fixture-visible-secret" not in logged
    assert "apiKey=[redacted]" in logged

    stop_payload, exit_code = manager._dispatch(manager.build_parser().parse_args(["stop", "--json"]))
    assert exit_code == 0
    assert stop_payload["runtimeState"] == "stopped"
    assert not manager.supervisor_file().exists()
    deadline = time.monotonic() + 5
    while manager._pid_alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not manager._pid_alive(pid)


def test_crash_recovery_and_restart_do_not_claim_account_quota(dsh_root: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    _installed_runtime(dsh_root)
    monkeypatch.setenv("PZ_DSH_FAKE_CRASH", "1")
    with pytest.raises(manager.DshError) as error:
        manager.start(str(tmp_path), "account")
    assert error.value.code == "runtime-crashed"
    monkeypatch.delenv("PZ_DSH_FAKE_CRASH")
    restarted = manager.start(str(tmp_path), "account")
    assert restarted["state"] == "running"
    assert restarted["quota"] == "unknown"
    assert restarted["balance"] == "unknown"
    manager._stop_supervisor()


def test_uninstall_preserves_two_dsh_homes_and_workspace(dsh_root: Path, tmp_path: Path):
    runtime, _node = _installed_runtime(dsh_root)
    account_home = dsh_root / "homes/account"
    api_home = dsh_root / "homes/api"
    workspace = tmp_path / "workspace"
    account_home.mkdir(parents=True)
    api_home.mkdir(parents=True)
    workspace.mkdir()
    (account_home / "account-data").write_text("keep", encoding="utf-8")
    (api_home / "api-data").write_text("keep", encoding="utf-8")
    manager._atomic_json(manager.state_file(), {"schemaVersion": 1, "workspace": str(workspace), "authRoute": "account"})
    result = manager.uninstall()
    assert result["state"] == "removed"
    assert not runtime.exists()
    assert (account_home / "account-data").read_text(encoding="utf-8") == "keep"
    assert (api_home / "api-data").read_text(encoding="utf-8") == "keep"
    assert workspace.is_dir()


def test_credential_file_presence_never_claims_validity_or_quota(dsh_root: Path):
    (dsh_root / "homes/api").mkdir(parents=True)
    (dsh_root / "homes/api/.credentials.yaml").write_text(
        "version: 1\nrefs:\n  DEEPSEEK_API_KEY: fixture-invalid-key\nrecords: {}\n",
        encoding="utf-8",
    )
    manager._atomic_json(manager.state_file(), {"schemaVersion": 1, "authRoute": "api"})
    payload = manager.status_payload()
    assert payload["apiCredential"] == "credential file present; validity unknown"
    assert payload["quota"] == "unknown"
    assert payload["balance"] == "unknown"
