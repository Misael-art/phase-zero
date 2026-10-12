from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from linux.ai import chatgpt_web_bridge as bridge_module
from linux.ai.chatgpt_web_bridge import (
    APPROVAL_LINE,
    DEFAULT_PORT,
    LEGACY_APPROVAL_LINE,
    OWNED_CONFIG,
    SESSION_COOKIE_DB,
    UNIT_NAME,
    Bridge,
    BridgeError,
)

ACKS = {"experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"}


class FakeRunner:
    """Host seam: no process, socket or systemd is touched."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.unit_active = False
        self.port_busy = False
        self.launchers: list[dict] = []
        self.terminated: list[int] = []
        self.codex_pids: list[int] = []
        self.upstream: dict[str, tuple[int, str, str]] = {}
        self.on_upstream = lambda verb: None
        self.spawned: list[tuple[list[str], dict]] = []
        self.notifications: list[tuple[str, str, bool]] = []

    def run(self, args, *, env=None, timeout=30, input_text=None):
        self.calls.append(list(args))
        if args[:3] == ["systemctl", "--user", "is-active"]:
            return (0, "active\n", "") if self.unit_active else (3, "inactive\n", "")
        if args[:3] == ["systemctl", "--user", "stop"]:
            self.unit_active = False
            return 0, "", ""
        if args[0] == "systemd-run" and "--wait" in args:
            verb = " ".join(upstream_args(args)[:2])
            self.on_upstream(verb)
            return self.upstream.get(verb, (0, "{}", ""))
        return 0, "", ""

    def port_in_use(self, port):
        return self.port_busy

    def spawn(self, args, env):
        self.spawned.append((list(args), dict(env)))
        return 4321

    def notify(self, title, body, critical=False):
        self.notifications.append((title, body, critical))
        return True

    def other_users(self):
        return []

    def launcher_processes(self, binary, data_dir, readonly_path):
        return list(self.launchers)

    def terminate(self, pid, timeout=20.0):
        self.terminated.append(pid)
        self.launchers = [item for item in self.launchers if item["pid"] != pid]
        return True

    def codex_processes(self, codex_home):
        return list(self.codex_pids)


def upstream_args(call: list[str]) -> list[str]:
    cli = [index for index, arg in enumerate(call) if arg.endswith("/codex-chatgpt-web")]
    return call[cli[0] + 1:] if cli else []


def upstream_calls(runner: FakeRunner) -> list[str]:
    return [" ".join(upstream_args(call)) for call in runner.calls if upstream_args(call)]


def write_profile(profile: Path, signed_in: bool, auto_start: bool = True) -> None:
    database = profile / SESSION_COOKIE_DB
    database.parent.mkdir(parents=True)
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE cookies (host_key TEXT, name TEXT)")
    if signed_in:
        connection.execute("INSERT INTO cookies VALUES ('.chatgpt.com', "
                           "'__Secure-next-auth.session-token')")
    connection.commit()
    connection.close()
    (profile / "launcher-state.json").write_text(json.dumps({"version": 1,
                                                             "autoStart": auto_start}))


@pytest.fixture
def host(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    runner = FakeRunner()
    env = {"HOME": str(home), "PATH": "/usr/bin", "PZ_CHATGPT_WEB_SETTLE_SECONDS": "0",
           "PZ_CHATGPT_WEB_POLL_SECONDS": "0"}
    bridge = Bridge(env=env, runner=runner)
    bridge.opt_in(ACKS)
    return bridge, runner, home


def configure(bridge: Bridge, runner: FakeRunner, route_active: bool) -> None:
    """A browser-only install as upstream leaves it."""
    paths = bridge.paths
    cli = paths.core_home / "versions/6.1.8-linux-x64/bin/codex-chatgpt-web"
    cli.parent.mkdir(parents=True)
    cli.write_text("#!/bin/sh\n")
    (paths.core_home / "config.json").write_text(json.dumps(
        {"mode": "browser-only", "solAvailable": True, "runtimeCommand": [str(cli)]}))
    bridge.seed_codex_home()
    state = bridge.load_state()
    bridge.snapshot_baseline(state)
    bridge.save_state(state)
    runner.upstream["route status"] = (0, json.dumps({"installed": True,
                                                       "active": route_active}), "")


def test_launcher_outside_the_unit_and_upstream_autostart_block_preflight(host):
    bridge, runner, _ = host
    runner.launchers = [{"pid": 4242, "managed": False}]
    bridge.paths.autostart_dir.mkdir(parents=True)
    bridge.paths.autostart_entry.write_text("[Desktop Entry]\n")

    blocked = bridge.preflight()["blocked"]

    assert {"no-unmanaged-launcher", "no-upstream-autostart"} <= set(blocked)
    assert bridge.isolation()["ok"] is False


def test_repair_stops_stray_launcher_and_quarantines_autostart(host):
    bridge, runner, _ = host
    runner.launchers = [{"pid": 4242, "managed": False}, {"pid": 7, "managed": True}]
    bridge.paths.autostart_dir.mkdir(parents=True)
    bridge.paths.autostart_entry.write_text("[Desktop Entry]\n")
    write_profile(bridge.paths.default_profile, signed_in=True)

    result = bridge.repair()

    assert runner.terminated == [4242]
    assert not bridge.paths.autostart_entry.exists()
    assert Path(result["quarantinedAutostart"]).read_text() == "[Desktop Entry]\n"
    state = json.loads((bridge.paths.default_profile / "launcher-state.json").read_text())
    assert state["autoStart"] is False
    assert result["isolation"]["ok"] is True


def test_adopt_session_moves_only_the_launchers_own_profile(host):
    bridge, _, _ = host
    write_profile(bridge.paths.default_profile, signed_in=True)
    write_profile(bridge.paths.launcher_data, signed_in=False)
    (bridge.paths.default_profile / "SingletonLock").write_text("stale")

    result = bridge.adopt_session()

    assert bridge.session_present(bridge.paths.launcher_data) is True
    assert not bridge.paths.default_profile.exists()
    assert not (bridge.paths.launcher_data / "SingletonLock").exists()
    assert Path(result["previousProfile"]).is_dir()
    adopted = json.loads(bridge.paths.launcher_state.read_text())
    assert adopted["autoStart"] is False


def test_adopt_session_refuses_without_a_session_or_with_a_running_launcher(host):
    bridge, runner, _ = host
    write_profile(bridge.paths.default_profile, signed_in=False)
    with pytest.raises(BridgeError) as missing:
        bridge.adopt_session()
    assert missing.value.code == "no-session"

    runner.launchers = [{"pid": 4242, "managed": False}]
    with pytest.raises(BridgeError) as running:
        bridge.adopt_session()
    assert running.value.code == "launcher-active"


def test_unit_seals_live_codex_home_and_autostart_directory(host):
    bridge, _, home = host
    properties = bridge.hardening_properties()

    assert f"ReadOnlyPaths=-{home / '.codex'}" in properties
    assert f"ReadOnlyPaths=-{home / '.config/autostart'}" in properties


def test_diff_accepts_interrupt_hook_only_for_the_managed_runtime(host):
    bridge, _, _ = host
    core = bridge.paths.core_home
    managed = (f"command = \"'{core}/versions/6.1.8-linux-x64/bin/codex-chatgpt-web' "
               f"'--home' '{core}' 'hook' 'interrupt'\"")
    foreign = "command = \"'/usr/bin/evil' '--home' '/tmp' 'hook' 'interrupt'\""
    after = OWNED_CONFIG + "\n".join([
        'openai_base_url = "http://127.0.0.1:17841/v1"', "[[hooks.Interrupt]]",
        "[[hooks.Interrupt.hooks]]", 'type = "command"', managed, "timeout = 3",
        f'[hooks.state."{bridge.paths.codex_config}:interrupt:0:0"]',
        'trusted_hash = "sha256:' + "a" * 64 + '"', ""])

    assert bridge.classify_diff(OWNED_CONFIG, after)["unexpected"] == []
    rejected = bridge.classify_diff(OWNED_CONFIG, after.replace(managed, foreign))
    assert rejected["unexpected"] == ["+" + foreign]
    assert bridge.classify_diff(OWNED_CONFIG, OWNED_CONFIG + 'model_provider = "x"\n')["unexpected"]


def test_legacy_approval_policy_is_migrated_in_config_and_baseline(host):
    bridge, _, _ = host
    legacy = OWNED_CONFIG.replace(APPROVAL_LINE, LEGACY_APPROVAL_LINE)
    bridge.paths.codex_home.mkdir(parents=True)
    bridge.paths.codex_config.write_text(legacy + 'openai_base_url = "http://127.0.0.1:17841/v1"\n')
    state = bridge.load_state()
    bridge.paths.journal.mkdir(parents=True)
    baseline = bridge.paths.journal / "config-baseline-legacy.toml"
    baseline.write_text(legacy)
    state["routeBaseline"] = {"path": str(baseline),
                              "sha256": bridge_module.sha256_bytes(legacy.encode())}
    bridge.save_state(state)

    assert bridge.migrate_owned_config(bridge.load_state()) is True

    assert LEGACY_APPROVAL_LINE not in bridge.paths.codex_config.read_text()
    verify = bridge.classify_diff(bridge._baseline_text(bridge.load_state()),
                                  bridge.paths.codex_config.read_text())
    assert verify["unexpected"] == []
    assert bridge.migrate_owned_config(bridge.load_state()) is False


def test_codex_command_pins_sandbox_supported_approval_and_a_web_model(host, monkeypatch):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    monkeypatch.setattr(bridge_module.shutil, "which", lambda name, path=None: "/usr/bin/codex")

    command, env = bridge.codex_command(["exec", "oi"])
    assert command == ["/usr/bin/codex", "--sandbox", "read-only", "--ask-for-approval",
                       "on-request", "--model", "chatgpt-web/medium", "exec", "oi"]
    assert env["CODEX_HOME"] == str(bridge.paths.codex_home)

    chosen, _ = bridge.codex_command(["exec", "-m", "chatgpt-web/high", "oi"])
    assert "--model" not in chosen
    for forbidden in (["--approve-for-me"], ["--sandbox", "danger-full-access"],
                      ["-c", "approval_policy=never"]):
        with pytest.raises(BridgeError):
            bridge.codex_command(forbidden)


def test_setup_relinks_a_configured_route_without_rerunning_upstream_setup(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    package = bridge.paths.package(bridge.asset())
    runner.unit_active = True
    runner.port_busy = True
    runner.launchers = [{"pid": 99, "managed": True}]
    bridge.paths.descriptor.parent.mkdir(parents=True)
    bridge.paths.descriptor.write_text(json.dumps({"pid": 99}))
    write_profile(bridge.paths.launcher_data, signed_in=True, auto_start=False)
    bridge.package_state = lambda: {"state": "verified", "path": str(package),
                                    "sha256": "x", "unpacked": "verified"}

    def connect(verb: str) -> None:
        if verb == "route connect":
            runner.upstream["route status"] = (0, json.dumps({"installed": True,
                                                               "active": True}), "")
    runner.on_upstream = connect
    seen: list[str] = []

    result = bridge.setup(lambda step, detail: seen.append(step))

    assert result["ready"] is True and result["stage"] == "web-model"
    assert seen == ["isolamento", "pacote", "launcher", "login", "modelo web", "bridge"]
    calls = upstream_calls(runner)
    assert "route connect" in calls
    assert not any(call.startswith("setup") for call in calls)
    assert result["liveCodexRouteTouched"] is False


def test_setup_stops_with_a_clear_message_when_login_is_missing(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    runner.unit_active = True
    runner.launchers = [{"pid": 99, "managed": True}]
    bridge.paths.descriptor.parent.mkdir(parents=True)
    bridge.paths.descriptor.write_text(json.dumps({"pid": 99}))
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}

    with pytest.raises(BridgeError) as error:
        bridge.setup(login_wait=0)

    assert error.value.code == "login-required"
    assert "route connect" not in upstream_calls(runner)


def test_upstream_cli_runs_under_the_same_path_restrictions(host):
    bridge, runner, home = host
    configure(bridge, runner, route_active=True)

    bridge.route_status()

    call = runner.calls[-1]
    assert call[:3] == ["systemd-run", "--user", "--wait"]
    assert f"ReadOnlyPaths=-{home / '.codex'}" in call
    assert f"--setenv=CODEX_HOME={bridge.paths.codex_home}" in call


def test_stop_refuses_while_route_is_active_and_port_constant_is_loopback_only(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True

    with pytest.raises(BridgeError) as error:
        bridge.stop_launcher()

    assert error.value.code == "route-active"
    assert ["systemctl", "--user", "stop", UNIT_NAME] not in runner.calls
    assert DEFAULT_PORT == 17841


def test_desktop_opens_separate_instance_on_dedicated_profile_and_guides_login(host, monkeypatch):
    bridge, runner, home = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    monkeypatch.setattr(bridge_module.shutil, "which",
                        lambda name, path=None: f"/usr/bin/{name}")

    result = bridge.desktop()

    args, env = runner.spawned[0]
    assert args == ["/usr/bin/codex-desktop", "--new-instance"]
    assert env["CODEX_HOME"] == str(bridge.paths.codex_home) != str(home / ".codex")
    assert env["CODEX_MULTI_LAUNCH"] == "1"
    title, body, critical = runner.notifications[0]
    assert "login necessário" in title and critical is True
    assert "Faça login no Codex" in body and "chatgpt-web/medium" in body
    assert result["codexSignedIn"] is False

    (bridge.paths.codex_home / "auth.json").write_text("{}")
    bridge.desktop()
    title, body, critical = runner.notifications[1]
    assert "janela aberta" in title and critical is False
    assert "Faça login" not in body


def test_desktop_refuses_when_route_is_inactive(host, monkeypatch):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    runner.unit_active = True

    with pytest.raises(BridgeError) as error:
        bridge.desktop()

    assert error.value.code == "route-inactive"
    assert runner.spawned == [] and runner.notifications == []


def test_profile_policy_tolerates_desktop_housekeeping_but_not_contract_breaks(host, monkeypatch):
    bridge, _, home = host
    wrapper = home / "codex-desktop"
    wrapper.write_text('#!/usr/bin/env bash\nexec /opt/codex-desktop/start.sh "$@"\n')
    monkeypatch.setattr(bridge_module.shutil, "which", lambda name, path=None: str(wrapper))
    core = bridge.paths.core_home
    desktop_written = OWNED_CONFIG + f"""openai_base_url = "http://127.0.0.1:17841/v1"
js_repl = false
model = "chatgpt-web/medium"

[plugins."computer-use@openai-bundled"]
enabled = true

[mcp_servers.node_repl]
command = "/opt/codex-desktop/resources/node_repl"

[mcp_servers.ai-memory]
url = "http://127.0.0.1:49374/mcp"

[[hooks.Interrupt]]
[[hooks.Interrupt.hooks]]
type = "command"
command = "'{core}/versions/6.1.8-linux-x64/bin/codex-chatgpt-web' '--home' '{core}' 'hook' 'interrupt'"
"""
    assert bridge.policy_violations(desktop_written) == []

    breaks = {
        "sandbox_mode": desktop_written.replace('"read-only"', '"danger-full-access"'),
        "approval_policy": desktop_written.replace(APPROVAL_LINE, 'approval_policy = "never"'),
        "openai_base_url": desktop_written.replace("127.0.0.1:17841", "evil.example"),
        "MCP": desktop_written.replace("/opt/codex-desktop/resources/node_repl", "/usr/bin/nc"),
        "MCP fora": desktop_written.replace("http://127.0.0.1:49374", "https://mcp.example"),
        "hook": desktop_written.replace(f"'{core}/versions", "'/tmp/versions"),
        "model_provider": 'model_provider = "x"\n' + desktop_written,
        "inválido": desktop_written + "[broken",
    }
    for expected, text in breaks.items():
        violations = bridge.policy_violations(text)
        assert violations and expected.split()[0] in violations[0], (expected, violations)


def test_login_autostart_is_opt_in_and_never_starts_the_upstream_launcher_directly(host):
    bridge, runner, _ = host
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    assert bridge.autostart_status()["state"] == "off"
    with pytest.raises(BridgeError) as refused:
        bridge.autostart_enable(False)
    assert refused.value.code == "ack-missing"
    assert not bridge.paths.managed_autostart.exists()

    assert bridge.autostart_enable(True)["state"] == "enabled"
    entry = bridge.paths.managed_autostart.read_text()
    assert "chatgpt_web_bridge.py\" autostart run" in entry
    assert "codex-web-gpt-launcher" not in entry
    assert bridge.isolation()["upstreamAutostartEntry"] is None

    bridge.paths.managed_autostart.write_text(entry.replace("autostart run", "launch"))
    assert bridge.autostart_status()["state"] == "inconsistent"
    with pytest.raises(BridgeError) as tampered:
        bridge.autostart_run()
    assert tampered.value.code == "autostart-off"

    assert bridge.autostart_disable()["state"] == "off"
    assert not bridge.paths.managed_autostart.exists()


def test_autostart_run_notifies_when_the_session_cannot_start(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    bridge.autostart_enable(True)
    runner.unit_active = True
    runner.launchers = [{"pid": 99, "managed": True}]
    bridge.paths.descriptor.parent.mkdir(parents=True)
    bridge.paths.descriptor.write_text(json.dumps({"pid": 99}))

    with pytest.raises(BridgeError) as error:
        bridge.autostart_run()

    assert error.value.code == "login-required"
    title, body, critical = runner.notifications[-1]
    assert "não iniciou" in title and critical is True and "setup" in body
