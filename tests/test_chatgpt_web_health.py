from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import time

import pytest

from linux.ai.chatgpt_web_bridge import Bridge, MODEL_LABEL_COMPAT_JS
from linux.ai.chatgpt_web_health import Recovery, classify_error, decisions, recent_events
from test_chatgpt_web_bridge import ACKS, FakeRunner


def test_repair_entrypoint_exposes_web_recovery_without_touching_host():
    import sys
    manager = Path(__file__).resolve().parents[1] / "linux/repairs/manager.py"
    result = subprocess.run([sys.executable, str(manager), "codex-web", "--help"],
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert "enable" in result.stdout and "status" in result.stdout and "--deep" in result.stdout


@pytest.mark.parametrize("message,status,code,expected", [
    ("ChatGPT model 6 could not be selected and verified", 400, "", "model-compatibility"),
    ("", 400, "model_version_unavailable", "model-compatibility"),
    ("", 429, "usage_limit_exceeded", "quota-exhausted"),
    ("", 429, "rate_limit_exceeded", "rate-limited"),
    ("", 401, "", "login-required"),
    ("", 403, "", "permission-required"),
    ("ERR_NETWORK_CHANGED", None, "", "network-unavailable"),
    ("", 503, "", "upstream-unavailable"),
    ("Unexpected response", 500, "", "unclassified-error"),
])
def test_failures_have_distinct_recovery_policies(message, status, code, expected):
    assert classify_error(message, status, code) == expected


def healthy():
    return {"optIn": True, "launcherActive": True, "compatActive": True,
            "daemonListening": True, "routeActive": True, "busy": False,
            "policyValid": True, "isolationOk": True, "resourcesOk": True}


@pytest.mark.parametrize("change,state,actions", [
    ({}, "ready", []),
    ({"optIn": False, "launcherActive": False}, "off", []),
    ({"policyValid": False}, "configuration-conflict", []),
    ({"integrity": "mismatch"}, "configuration-conflict", []),
    ({"isolationOk": False}, "isolation-conflict", []),
    ({"resourcesOk": False}, "waiting-for-resources", []),
    ({"starting": True, "daemonListening": False}, "waiting-for-startup", []),
    ({"busy": True, "daemonListening": False}, "waiting-for-idle", []),
    ({"busy": None, "daemonListening": False}, "waiting-for-idle", []),
    ({"busy": True, "compatActive": False}, "waiting-for-idle", ["restore-composer"]),
    ({"launcherActive": False}, "repairable", ["start-launcher"]),
    ({"orphanTunnels": [123]}, "repairable", ["restart-backend"]),
    ({"tunnelReady": False}, "repairable", ["restart-backend"]),
    ({"daemonListening": False}, "repairable", ["restart-backend"]),
    ({"routeActive": False}, "repairable", ["restore-route"]),
    ({"shortcutsMissing": True}, "repairable", ["restore-shortcuts"]),
    ({"autostartMissing": True}, "repairable", ["restore-login-entry"]),
    ({"failure": "model-compatibility"}, "repairable", ["restore-composer"]),
    ({"failure": "rate-limited", "daemonListening": False}, "rate-limited", ["restart-backend"]),
    ({"failure": "quota-exhausted", "daemonListening": False}, "quota-exhausted", ["restart-backend"]),
    ({"failure": "login-required", "daemonListening": False}, "login-required", ["restart-backend"]),
    ({"failure": "quota-exhausted", "tunnelReady": False}, "quota-exhausted", []),
    ({"failure": "network-unavailable", "tunnelReady": False}, "network-unavailable", []),
    ({"failure": "rate-limited", "busy": True, "daemonListening": False}, "rate-limited", []),
    ({"failure": "permission-required"}, "permission-required", []),
    ({"failure": "network-unavailable"}, "network-unavailable", []),
    ({"failure": "upstream-unavailable"}, "upstream-unavailable", []),
])
def test_fault_matrix_preserves_work_and_external_limits(change, state, actions):
    assert decisions({**healthy(), **change}) == {"state": state, "actions": actions}


@pytest.fixture
def manager(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    runner = FakeRunner()
    runner.launchers = [{"pid": 99, "managed": True}]
    bridge = Bridge(env={"HOME": str(home), "PATH": "/usr/bin"}, runner=runner)
    bridge.opt_in(ACKS)
    recovery = Recovery(bridge)
    observation = healthy()
    monkeypatch.setattr(recovery, "observe", lambda deep=False: observation.copy())
    monkeypatch.setattr(bridge, "package_state", lambda: {"state": "verified", "unpacked": "verified"})
    return recovery, bridge, runner, observation


def test_timer_reuses_stable_manager_and_is_opt_in(manager):
    recovery, bridge, runner, observation = manager
    assert recovery.apply(automatic=True) == {"state": "off", "actions": []}
    result = recovery.enable()
    assert result["enabled"] and result["intervalSeconds"] == 60
    assert "MemoryMax=256M" in recovery.service.read_text()
    assert "RandomizedDelaySec=10" in recovery.timer.read_text()
    assert bridge.paths.manager_health.is_file()
    assert "recovery cycle" in recovery.wrapper.read_text()
    assert ["systemctl", "--user", "enable", "--now", recovery.timer.name] in runner.calls
    recovery.service.write_text("foreign service")
    with pytest.raises(RuntimeError, match="preservado"):
        recovery.enable()
    assert recovery.service.read_text() == "foreign service"


def test_disable_stops_only_own_timer_and_no_inference_is_generated(manager, monkeypatch):
    recovery, bridge, runner, observation = manager
    recovery.enable()
    monkeypatch.setattr(bridge, "codex_command", lambda *a, **k: pytest.fail("monitor must never infer"))
    assert recovery.apply(automatic=True)["state"] == "ready"
    assert recovery.disable() == {"enabled": False}
    assert ["systemctl", "--user", "disable", "--now", recovery.timer.name] in runner.calls
    assert not any("kill" in arg for call in runner.calls for arg in call)


def test_backend_recovery_verifies_result_and_keeps_desktop_open(manager, monkeypatch):
    recovery, bridge, runner, observation = manager
    observation["daemonListening"] = False
    original = runner.run

    def run(args, **kwargs):
        if args[:3] == ["systemctl", "--user", "restart"]:
            observation["daemonListening"] = True
            runner.port_busy = True
        return (0, "", "") if args[:3] == ["systemctl", "--user", "restart"] else original(args, **kwargs)

    monkeypatch.setattr(runner, "run", run)
    result = recovery.apply()
    assert result["state"] == "ready" and result["actions"] == ["restart-backend"]
    assert result["after"]["daemonListening"] is True
    assert runner.terminated == [] and not runner.spawned


def test_failed_repair_persists_budget_before_attempt_and_backs_off(manager, monkeypatch):
    recovery, bridge, runner, observation = manager
    observation["daemonListening"] = False

    def fail(args, **kwargs):
        assert recovery.read()["pendingAction"] == "restart-backend"
        assert len(recovery.read()["restartAttempts"]) == 1
        raise TimeoutError("own restart timed out")

    monkeypatch.setattr(runner, "run", fail)
    result = recovery.apply()
    assert result["state"] == "repair-failed" and result["errorCode"] == "TimeoutError"
    assert recovery.apply()["state"] == "cooldown"


def test_repeated_failure_opens_circuit_instead_of_looping(manager):
    recovery, bridge, runner, observation = manager
    observation["daemonListening"] = False
    recovery.write({"restartAttempts": [time.time() - i for i in (10, 20, 30)]})
    assert recovery.apply()["state"] == "circuit-open"
    assert not any(call[:3] == ["systemctl", "--user", "restart"] for call in runner.calls)


def test_unknown_content_blocks_executable_repair(manager, monkeypatch):
    recovery, bridge, runner, observation = manager
    observation["daemonListening"] = False
    monkeypatch.setattr(bridge, "package_state", lambda: {"state": "mismatch"})
    assert recovery.apply()["state"] == "configuration-conflict"
    assert not runner.calls


def test_same_model_failure_is_not_repaired_repeatedly_without_a_new_turn(manager, monkeypatch):
    recovery, bridge, runner, observation = manager
    observation.update(failure="model-compatibility", failureAt="2026-11-07T21:00:00Z")
    monkeypatch.setattr(bridge, "ensure_dom_compat", lambda **k: "restarted")
    result = recovery.apply()
    assert result["state"] == "awaiting-validation"
    result["nextAttemptAt"] = 0
    recovery.write(result)
    assert recovery.apply()["actions"] == []


def test_manual_login_disable_also_revokes_background_recovery(manager):
    recovery, bridge, runner, observation = manager
    recovery.enable()
    bridge.autostart_disable()
    assert bridge.load_state()["recovery"]["enabled"] is False
    assert recovery.apply(automatic=True)["state"] == "off"


def test_manual_product_disable_is_not_undone_by_the_timer(manager):
    recovery, bridge, runner, observation = manager
    recovery.enable()
    assert bridge.disable()["disabled"] is True
    assert bridge.load_state()["recovery"]["enabled"] is False


def test_interactive_maintenance_and_monitor_share_a_reentrant_lock(manager):
    recovery, bridge, runner, observation = manager
    other = Bridge(env=bridge.env, runner=runner)
    with bridge.maintenance() as available:
        assert available
        with bridge.maintenance() as nested:
            assert nested
            assert Recovery(other).apply()["state"] == "maintenance-busy"
    with other.maintenance() as available:
        assert available


def test_foreign_service_cannot_be_restarted_even_when_its_port_is_down(manager):
    recovery, bridge, runner, observation = manager
    runner.launchers = []
    observation["daemonListening"] = False
    assert recovery.apply()["state"] == "isolation-conflict"
    assert not any(call[:3] == ["systemctl", "--user", "restart"] for call in runner.calls)


def test_symlink_state_is_preserved_without_reading_the_target(manager, tmp_path):
    recovery, bridge, runner, observation = manager
    target = tmp_path / "private.json"
    target.write_text('{"private":"unchanged"}')
    recovery.record.symlink_to(target)
    with pytest.raises(RuntimeError, match="preservado"):
        recovery.read()
    assert target.read_text() == '{"private":"unchanged"}'


def test_login_repair_requires_official_user_action_and_notifications_are_bounded(manager):
    recovery, bridge, runner, observation = manager
    observation["failure"] = "login-required"
    assert recovery.apply()["state"] == "login-required"
    assert len(runner.notifications) == 1
    record = recovery.read()
    record["nextAttemptAt"] = 0
    recovery.write(record)
    assert recovery.apply()["actions"] == []
    assert len(runner.notifications) == 1
    assert not runner.spawned and not runner.terminated


def test_success_clears_previous_local_failure_without_logging_chat_content(tmp_path):
    path = tmp_path / "launcher.jsonl"
    lines = [
        {"at": "2026-11-07T21:00:00Z", "detail": {"line": "browser turn abc stage=browser_page started"}},
        {"at": "2026-11-07T21:00:01Z", "detail": {"line": "browser turn abc stage=effort_selection failed: ChatGPT model 6 could not be selected and verified"}},
        {"at": "2026-11-07T21:01:00Z", "detail": {"line": 'browser_settled {"traceId":"def","outcome":"final"}'}},
    ]
    path.write_text("\n".join(json.dumps(x) for x in lines))
    result = recent_events(path)
    assert result == {"failure": None, "busy": False, "lastSuccessfulWebTurnAt": "2026-11-07T21:01:00Z"}
    assert "line" not in json.dumps(result)


def test_busy_metadata_survives_format_changes_but_not_a_dead_runtime(tmp_path):
    path = tmp_path / "launcher.jsonl"
    rows = [[], {"detail": "invalid"}, {"event": "browser.turn_started", "detail": {"traceId": "abc"}}]
    path.write_text("\n".join(json.dumps(x) for x in rows))
    assert recent_events(path)["busy"] is True
    rows.append({"event": "runtime.daemon_exited", "detail": {"code": 1}})
    path.write_text("\n".join(json.dumps(x) for x in rows))
    assert recent_events(path)["busy"] is False


def test_portuguese_labels_translate_same_model_without_faking_selection():
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node required for JavaScript compatibility regression")
    cases = {"6 Alta": "6 High", "6 Média, 2 de 5.": "6 Medium, 2 de 5.",
             "6 Extra alta": "6 Extra high", "5.6 Instantâneo": "5.6 Instant",
             "GPT-6 Sol Alta": "GPT-6 Sol High", "6 High": "6 High",
             "7 Alta": "7 Alta", "Conta Alta": "Conta Alta", "6 Média alta": "6 Média alta"}
    script = MODEL_LABEL_COMPAT_JS + "\nprocess.stdout.write(JSON.stringify(" + json.dumps(list(cases)) + ".map(pzModelLabel)));"
    result = subprocess.run([node, "-e", script], capture_output=True, text=True, timeout=10, check=True)
    assert json.loads(result.stdout) == list(cases.values())


def test_account_shortcut_repair_uses_only_proven_sibling_and_preserves_foreign(manager):
    recovery, bridge, runner, observation = manager
    state = bridge.load_state()
    state["accountShortcuts"] = "codex-profiles"
    bridge.save_state(state)
    base = bridge.paths.root.parent / "ai-accounts/codex-profiles/primary"
    base.mkdir(parents=True)
    (base / "open-web.sh").write_text("#!/bin/sh\n")
    desktop = bridge.user_desktop_dir()
    desktop.mkdir()
    copy = desktop / "phasezero-chatgpt-web.desktop"
    copy.write_text('[Desktop Entry]\nType=Application\nName=Codex Web Principal\n'
                    f'Exec="{base / "open-web.sh"}"\nIcon={base / "account-web.svg"}\n'
                    'Terminal=false\nX-PhaseZero-Managed=codex-profiles\n')
    bridge.paths.applications.mkdir(parents=True)
    assert recovery.restore_account_shortcuts() is True
    menu = bridge.paths.applications / copy.name
    assert menu.read_bytes() == copy.read_bytes()
    menu.write_text("foreign")
    assert recovery.restore_account_shortcuts() is False
    assert menu.read_text() == "foreign"
