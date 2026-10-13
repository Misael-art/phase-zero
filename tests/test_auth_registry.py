from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o700)


def _sandbox(tmp_path: Path) -> tuple[dict[str, str], Path]:
    bin_dir = tmp_path / "bin"
    fixtures = tmp_path / "fixtures"
    bin_dir.mkdir()
    fixtures.mkdir()
    system_path = os.environ["PATH"]
    real_timeout = shutil.which("timeout", path=system_path)
    assert real_timeout
    _write_executable(bin_dir / "timeout", f'''#!/bin/bash
if [[ "$PZ_TEST_FAST_TIMEOUT" == "1" ]]; then
    [[ "$1" == --kill-after=* ]] && shift
    shift
    exec "{real_timeout}" --kill-after=0.2s 0.05s "$@"
fi
exec "{real_timeout}" "$@"
''')
    _write_executable(bin_dir / "bash", '''#!/bin/bash
args="$*"
if [[ "$args" == *"proxy-suite.sh auth all"* ]]; then
    [[ "$PZ_TEST_MODE" == "timeout-proxies" ]] && sleep 2
    cat "$PZ_TEST_FIXTURES/proxies.json"
    exit 0
fi
if [[ "$args" == *"9router-manager.sh provider status"* ]]; then
    [[ "$PZ_TEST_MODE" == "backend-providers" ]] && exit 23
    [[ "$PZ_TEST_MODE" == "timeout-providers" ]] && sleep 2
    cat "$PZ_TEST_FIXTURES/providers.json"
    exit 0
fi
case "$args" in
  *"9router-manager.sh status"*) cat "$PZ_TEST_FIXTURES/router.json"; exit 0 ;;
  *"setup-claude-code.sh status"*) cat "$PZ_TEST_FIXTURES/claude.json"; exit 0 ;;
  *"setup-hermes.sh status"*) cat "$PZ_TEST_FIXTURES/hermes.json"; exit 0 ;;
  *"setup-openclaw.sh status"*) cat "$PZ_TEST_FIXTURES/openclaw.json"; exit 0 ;;
  *"odysseus-manager.sh status"*) cat "$PZ_TEST_FIXTURES/odysseus.json"; exit 0 ;;
esac
exec /bin/bash "$@"
''')
    real_python = shutil.which("python3", path=system_path)
    assert real_python
    _write_executable(bin_dir / "python3", f'''#!/bin/bash
if [[ "$1" == *"opencode_9router_manager.py" && "$2" == "status" ]]; then
    cat "$PZ_TEST_FIXTURES/opencode.json"
    exit 0
fi
exec "{real_python}" "$@"
''')

    payloads = {
        "proxies.json": [{
            "id": "qwenproxy", "label": "Private profile", "installed": True,
            "apiKeyConfigured": True, "service": "active",
            "webValidation": {"status": "authenticated"},
        }],
        "providers.json": {"connections": [{
            "id": "provider-record-1", "provider": "openai", "name": "Private person",
            "active": True, "status": "active",
        }]},
        "router.json": {"installed": True, "healthy": True,
                         "providers": {"active": 1, "total": 1}},
        "claude.json": {"claude": {"installed": True,
                        "auth": {"loggedIn": True, "authMethod": "oauth"}},
                        "bonsai": {"installed": False, "authenticated": False}},
        "opencode.json": {"cli": {"installed": True},
                          "configuration": {"configured": True},
                          "credential": {"present": True, "secure": True},
                          "router": {"healthy": True}},
        "hermes.json": {"installed": False, "configured": False,
                         "ready": False, "auth": {"configured": False}},
        "openclaw.json": {"available": True, "configExists": True,
                           "ready": False, "usageBlocked": True,
                           "blockedReason": "connection-grant-not-enforceable"},
        "odysseus.json": {"installed": False, "configured": False,
                           "ready": False, "routerCredential": {"configured": False}},
    }
    for name, payload in payloads.items():
        (fixtures / name).write_text(json.dumps(payload), encoding="utf-8")
    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}:{system_path}"
    env["HOME"] = str(tmp_path / "home")
    env["XDG_CONFIG_HOME"] = str(tmp_path / "config")
    env["XDG_DATA_HOME"] = str(tmp_path / "data")
    env["PZ_TEST_FIXTURES"] = str(fixtures)
    env["PZ_TEST_MODE"] = "ok"
    env["PZ_TEST_FAST_TIMEOUT"] = "0"
    return env, fixtures


def _run(tmp_path: Path, env: dict[str, str]) -> tuple[subprocess.CompletedProcess[str], dict]:
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "linux/ai/auth-registry.sh"), "status"],
        cwd=ROOT, env=env, text=True, capture_output=True, check=False, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    return result, json.loads(result.stdout)


def test_auth_registry_v1_redaction_and_probe_failure_semantics(tmp_path):
    env, _fixtures = _sandbox(tmp_path)
    result, registry = _run(tmp_path, env)
    assert registry["schemaVersion"] == 1
    assert registry["secretsRedacted"] is True
    assert registry["probes"]["providers"] == "ok"
    assert registry["summary"]["accounts"] == 1
    router = next(entry for entry in registry["entries"] if entry["id"] == "gateway:9router")
    assert router["ready"] is True  # Service health is separate from consumer permission.
    assert router["usageBlocked"] is True
    assert router["blockedReason"] == "connection-grant-not-enforceable"
    assert router["nextAction"] == "blocked:connection-grant-not-enforceable"
    odysseus = next(entry for entry in registry["entries"] if entry["id"] == "workspace:odysseus")
    assert odysseus["usageBlocked"] is True
    assert odysseus["blockedReason"] == "connection-grant-not-enforceable"
    hermes = next(entry for entry in registry["entries"] if entry["id"] == "workspace:hermes")
    assert hermes["ready"] is False
    assert hermes["usageBlocked"] is True
    assert hermes["blockedReason"] == "connection-grant-not-enforceable"
    openclaw = next(entry for entry in registry["entries"] if entry["id"] == "workspace:openclaw")
    assert openclaw["ready"] is False
    assert openclaw["usageBlocked"] is True
    assert openclaw["blockedReason"] == "connection-grant-not-enforceable"
    assert "Private person" not in result.stdout
    assert "Private profile" not in result.stdout
    assert "provider-record-1" not in result.stdout

    env["PZ_TEST_MODE"] = "backend-providers"
    failed, unknown = _run(tmp_path, env)
    assert unknown["schemaVersion"] == 1
    assert unknown["probes"]["providers"] == "backend-unavailable"
    assert unknown["summary"]["accounts"] is None
    assert unknown["summary"]["providers"] is None
    assert "\"accounts\":0" not in failed.stdout.replace(" ", "")


def test_auth_registry_timeout_is_unknown_not_backend_or_empty(tmp_path):
    env, _fixtures = _sandbox(tmp_path)
    env["PZ_TEST_MODE"] = "timeout-providers"
    env["PZ_TEST_FAST_TIMEOUT"] = "1"
    _result, registry = _run(tmp_path, env)
    assert registry["schemaVersion"] == 1
    assert registry["probes"]["providers"] == "timeout"
    assert registry["summary"]["accounts"] is None
