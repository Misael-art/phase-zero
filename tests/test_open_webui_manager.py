from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _fake_tools(tmp_path: Path, *, mode: str, curl_mode: str = "ok") -> tuple[dict[str, str], Path, Path]:
    bindir = tmp_path / "bin"
    bindir.mkdir()
    docker = bindir / "docker"
    docker.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' \"$*\" >> \"$FAKE_WEBUI_DOCKER_CALLS\"\n"
        "case \"$1\" in\n"
        "  ps)\n"
        "    case \"$FAKE_WEBUI_MODE:$2\" in\n"
        "      backend:*) exit 3 ;;\n"
        "      absent:*) exit 0 ;;\n"
        "      stopped:-a|healthy:-a) printf 'open-webui\\n' ;;\n"
        "      healthy:*) printf 'open-webui\\n' ;;\n"
        "    esac ;;\n"
        "  port) printf '127.0.0.1:3000\\n' ;;\n"
        "  *) exit 2 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    docker.chmod(0o755)
    curl = bindir / "curl"
    curl.write_text(
        "#!/bin/sh\n"
        "case \"$FAKE_WEBUI_CURL_MODE\" in\n"
        "  failed) printf '503'; exit 0 ;;\n"
        "  timeout) exit 28 ;;\n"
        "  *) printf '200' ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    curl.chmod(0o755)
    opened = tmp_path / "opened-url"
    docker_calls = tmp_path / "docker-calls"
    opener = bindir / "xdg-open"
    opener.write_text(
        "#!/bin/sh\nprintf '%s' \"$1\" > \"$FAKE_WEBUI_OPENED\"\n",
        encoding="utf-8",
    )
    opener.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = f"{bindir}:/usr/bin:/bin"
    env["FAKE_WEBUI_MODE"] = mode
    env["FAKE_WEBUI_CURL_MODE"] = curl_mode
    env["FAKE_WEBUI_OPENED"] = str(opened)
    env["FAKE_WEBUI_DOCKER_CALLS"] = str(docker_calls)
    env["HOME"] = str(tmp_path / "home")
    env["XDG_CONFIG_HOME"] = str(tmp_path / "home/.config")
    env["XDG_DATA_HOME"] = str(tmp_path / "home/.local/share")
    env["XDG_STATE_HOME"] = str(tmp_path / "home/.local/state")
    env["XDG_RUNTIME_DIR"] = str(tmp_path / "run")
    return env, opened, docker_calls


def _run(
    tmp_path: Path, mode: str, command: str, *, curl_mode: str = "ok",
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    env, opened, docker_calls = _fake_tools(tmp_path, mode=mode, curl_mode=curl_mode)
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "linux/pz"), "ai", "webui", command],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    return result, opened, docker_calls


def test_status_reports_absent_container_without_claiming_health(tmp_path):
    result, _opened, _docker_calls = _run(tmp_path, "absent", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["hasStatus"] is True
    assert payload["installationState"] == "absent"
    assert payload["configurationState"] == "needed"
    assert payload["health"] == "unknown"
    assert payload["origin"] == "unknown"


def test_unavailable_docker_backend_stays_unknown(tmp_path):
    result, _opened, _docker_calls = _run(tmp_path, "backend", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["hasStatus"] is False
    assert payload["installationState"] == "unknown"
    assert payload["configurationState"] == "unknown"
    assert payload["health"] == "unknown"
    assert payload["error"] == "backend-unavailable"


def test_status_reports_running_and_http_ready_container(tmp_path):
    result, _opened, _docker_calls = _run(tmp_path, "healthy", "status")

    assert result.returncode == 0, result.stderr
    payload = json.loads(result.stdout)
    assert payload["installationState"] == "present"
    assert payload["configurationState"] == "ready"
    assert payload["health"] == "online"
    assert payload["dashboardUrl"] == "http://127.0.0.1:3000/"
    assert payload["origin"] == "unknown"
    assert payload["usageBlocked"] is True
    assert payload["blockedReason"] == "connection-grant-not-enforceable"


def test_http_failure_and_timeout_never_claim_online(tmp_path):
    failed_dir = tmp_path / "failed"
    failed_dir.mkdir()
    result, _opened, _docker_calls = _run(failed_dir, "healthy", "status", curl_mode="failed")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["health"] == "failed"

    timeout_dir = tmp_path / "timeout"
    timeout_dir.mkdir()
    result, _opened, _docker_calls = _run(timeout_dir, "healthy", "status", curl_mode="timeout")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["health"] == "unknown"

def test_open_fails_before_health_probe_or_browser_launch(tmp_path):
    for command in ("open", "dashboard"):
        case_dir = tmp_path / command
        case_dir.mkdir()
        result, opened, docker_calls = _run(case_dir, "healthy", command)
        assert result.returncode == 69
        assert "not bound to PhaseZero grants" in result.stderr
        assert not opened.exists()
        assert not docker_calls.exists()


def test_setup_fails_before_docker_probe_or_container_start(tmp_path):
    env, _opened, docker_calls = _fake_tools(tmp_path, mode="absent")
    result = subprocess.run(
        ["/bin/bash", str(ROOT / "linux/pz"), "ai", "setup", "webui"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 69
    assert "not bound to PhaseZero grants" in result.stderr
    assert not docker_calls.exists()
