from __future__ import annotations

import datetime as dt
import json
import os
import sqlite3
import struct
import subprocess
import sys
import urllib.error
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
        self.download_bytes = b""
        self.download_error: Exception | None = None
        self.downloads: list[str] = []
        self.journal = ""
        self.ldd_code = 0
        self.ldd_out = ""
        self.unpack_binary = True
        self.codex_reply: str | None = None

    def run(self, args, *, env=None, timeout=30, input_text=None):
        self.calls.append(list(args))
        if args[:3] == ["systemctl", "--user", "is-active"]:
            return (0, "active\n", "") if self.unit_active else (3, "inactive\n", "")
        if args[:3] == ["systemctl", "--user", "stop"]:
            self.unit_active = False
            return 0, "", ""
        if args[0] == "unsquashfs":
            dest = Path(args[args.index("-d") + 1])
            dest.mkdir(parents=True, exist_ok=True)
            if self.unpack_binary:
                (dest / bridge_module.LAUNCHER_BINARY).write_text("")
            return 0, "", ""
        if args[0] == "ldd":
            return self.ldd_code, self.ldd_out, ""
        if args[0] == "journalctl":
            return 0, self.journal, ""
        if args[0] == "git":  # read-only history snapshot runs against a real temp repo
            done = subprocess.run(args, capture_output=True, text=True, check=False)
            return done.returncode, done.stdout, done.stderr
        if args[0].endswith("/codex") and self.codex_reply is not None:
            Path(args[args.index("-o") + 1]).write_text(self.codex_reply)
            return 0, "", ""
        if args[0] == "systemd-run" and "--wait" in args:
            verb = " ".join(upstream_args(args)[:2])
            self.on_upstream(verb)
            return self.upstream.get(verb, (0, "{}", ""))
        return 0, "", ""

    def download(self, url, target, expected_size):
        self.downloads.append(url)
        if self.download_error is not None:
            raise self.download_error
        target.write_bytes(self.download_bytes)

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


def test_route_accepts_current_upstream_bun_hook_without_trusting_other_commands(host):
    bridge, _, _ = host
    version = bridge.paths.core_home / "versions/6.1.8-linux-x64"
    core = bridge.paths.core_home
    managed = (f"command = \"'{version}/runtime/bun' '{version}/app/cli.js' "
               f"'--home' '{core}' 'hook' 'interrupt'\"")
    text = (OWNED_CONFIG + "\n[[hooks.Interrupt]]\n[[hooks.Interrupt.hooks]]\n"
            "type = \"command\"\n" + managed + "\ntimeout = 3\n")

    assert bridge.classify_diff(OWNED_CONFIG, text)["unexpected"] == []
    assert bridge.policy_violations(text) == []

    for changed in (managed.replace("/app/cli.js", "/app/other.js"),
                    managed.replace("/runtime/bun", "/runtime/other"),
                    managed.replace("6.1.8-linux-x64", "6.1.9-linux-x64"),
                    managed.replace("'hook' 'interrupt'", "'hook' 'restart'")):
        hostile = text.replace(managed, changed)
        assert bridge.classify_diff(OWNED_CONFIG, hostile)["unexpected"] == ["+" + changed]
        assert bridge.policy_violations(hostile) == ["hook fora do runtime gerenciado"]


def test_browser_only_ignores_inert_auto_approve_flag_but_full_mode_refuses(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    config_path = bridge.paths.core_home / "config.json"
    config = json.loads(config_path.read_text())
    config["autoApproveToolCalls"] = True
    config_path.write_text(json.dumps(config))

    bridge.require_ready(bridge.load_state())

    broker = bridge.paths.core_home / "runtime/turn-broker.sock"
    broker.parent.mkdir(parents=True)
    broker.touch()
    with pytest.raises(BridgeError) as unexpected:
        bridge.require_ready(bridge.load_state())
    assert unexpected.value.code == "unexpected-broker"
    broker.unlink()

    config["mode"] = "full"
    config_path.write_text(json.dumps(config))
    with pytest.raises(BridgeError) as error:
        bridge.require_ready(bridge.load_state())
    assert error.value.code == "auto-approve"


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
    assert "Faça login no Codex" in body and "(Web)" in body
    assert "chatgpt-web/" not in body  # tier slugs are hidden in the Desktop selector
    assert result["model"] == "chatgpt-web/medium"  # still the CLI default
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
    assert 'Exec="' in entry and "chatgpt-web-autostart.sh\"" in entry
    assert "autostart run" not in entry  # Exec is the stable wrapper, not the worktree
    assert bridge.paths.autostart_wrapper.is_file()
    assert bridge.paths.autostart_target.is_file()
    assert bridge.paths.autostart_target.read_text().splitlines()[1] == str(
        bridge.paths.manager_script)
    assert bridge.paths.autostart_target.read_text().splitlines()[0] == str(
        bridge.managed_python())
    assert bridge.paths.manager_script.is_file()
    assert "codex-web-gpt-launcher" not in entry
    assert bridge.isolation()["upstreamAutostartEntry"] is None

    bridge.paths.autostart_target.write_text(
        f"{sys.executable}\n{bridge.paths.home / 'deleted-worktree' / 'bridge.py'}\n")
    assert bridge.autostart_status()["state"] == "inconsistent"
    assert bridge.autostart_enable(True)["state"] == "enabled"

    bridge.paths.managed_autostart.write_text(
        entry.replace("chatgpt-web-autostart.sh", "dev.codexwebgpt.launcher.desktop"))
    assert bridge.autostart_status()["state"] == "inconsistent"
    with pytest.raises(BridgeError) as tampered:
        bridge.autostart_run()
    assert tampered.value.code == "autostart-off"

    assert bridge.autostart_disable()["state"] == "off"
    assert not bridge.paths.managed_autostart.exists()
    assert not bridge.paths.autostart_wrapper.exists()
    assert not bridge.paths.autostart_target.exists()


def _run_wrapper(wrapper: Path, home: Path) -> subprocess.CompletedProcess:
    fake_bin = home / "fakebin"
    fake_bin.mkdir(exist_ok=True)
    recorder = home / "notify.log"
    (fake_bin / "notify-send").write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" >> {recorder}\n")
    (fake_bin / "notify-send").chmod(0o755)
    env = dict(os.environ, PATH=f"{fake_bin}{os.pathsep}{os.environ['PATH']}")
    return subprocess.run(["/bin/sh", str(wrapper)], capture_output=True, text=True,
                          timeout=30, env=env, check=False)


def test_autostart_wrapper_survives_the_worktree_and_fails_visibly(tmp_path, host):
    # PXA-010(c): the login Exec is a stable path. When the recorded manager
    # script disappears, the wrapper notifies in pt-BR instead of vanishing.
    bridge, runner, home = host
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    bridge.autostart_enable(True)
    wrapper = bridge.paths.autostart_wrapper

    bridge.paths.autostart_target.write_text(f"{sys.executable}\n{home / 'gone' / 'bridge.py'}\n")
    gone = _run_wrapper(wrapper, home)
    assert gone.returncode == 1
    log = (home / "notify.log").read_text()
    assert "não iniciou" in log and "não existe mais" in log
    assert "--urgency=critical" in log

    missing = home / "no-target"
    bridge.paths.autostart_target.unlink()
    orphan = _run_wrapper(wrapper, home)
    assert orphan.returncode == 1
    assert (home / "notify.log").read_text() != log


def test_autostart_wrapper_executes_the_manager_when_the_path_exists(tmp_path, host):
    bridge, runner, home = host
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    bridge.autostart_enable(True)
    manager = home / "manager.py"
    manager.write_text("import sys\nprint('|'.join(sys.argv[1:]))\n")
    bridge.paths.autostart_target.write_text(f"{sys.executable}\n{manager}\n")
    done = _run_wrapper(bridge.paths.autostart_wrapper, home)
    assert done.returncode == 0, done.stderr
    assert "autostart|run" in done.stdout


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


# ---- PXA-011: hostile-host fixtures ---------------------------------------

PAYLOAD = b"appimage-bytes" * 32


def pin_payload(bridge: Bridge, payload: bytes) -> dict:
    """Pin the fake asset to `payload` so fetch's size and hash checks can pass."""
    asset = {"name": "codex-web-gpt-launcher.AppImage",
             "size": len(payload),
             "sha256": bridge_module.sha256_bytes(payload)}
    bridge.asset = lambda: asset
    return asset


def fake_appimage(path: Path) -> Path:
    """Minimal ELF64 little-endian header; enough for squashfs_offset."""
    header = bytearray(64)
    header[:4] = b"\x7fELF"
    header[4], header[5] = 2, 1
    struct.pack_into("<Q", header, 0x28, 1024)
    struct.pack_into("<HH", header, 0x3A, 64, 10)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    path.write_bytes(bytes(header))
    return path


def verified_package(bridge: Bridge, image: Path, unpacked: str = "absent") -> None:
    bridge.package_state = lambda: {"state": "verified", "path": str(image),
                                    "sha256": "x", "unpacked": unpacked}


def clean_preflight(monkeypatch, bridge: Bridge) -> None:
    """Make preflight deterministic: no real tools or filesystem probes."""
    monkeypatch.setattr(bridge_module, "enforces_permissions", lambda directory: True)
    monkeypatch.setattr(bridge_module.shutil, "which",
                        lambda name, path=None: f"/usr/bin/{name}")


def test_clean_host_fetches_and_installs_without_executing(host, monkeypatch):
    bridge, runner, _ = host
    clean_preflight(monkeypatch, bridge)
    asset = pin_payload(bridge, PAYLOAD)
    runner.download_bytes = PAYLOAD

    fetched = bridge.fetch()

    assert fetched["package"] == "verified" and fetched["downloaded"] is True
    package = bridge.paths.package(asset)
    assert package.read_bytes() == PAYLOAD
    assert package.stat().st_mode & 0o777 == 0o400  # never executed in place
    assert not (package.parent / (package.name + ".part")).exists()
    assert bridge.package_state()["state"] == "verified"

    verified_package(bridge, fake_appimage(package))
    installed = bridge.install()

    assert installed["install"] == "unpacked"
    assert installed["desktopEntry"] is False and installed["autostart"] is False
    assert (bridge.paths.app / bridge_module.LAUNCHER_BINARY).is_file()


def test_truncated_download_is_rejected_with_sizes(host):
    bridge, runner, _ = host
    pin_payload(bridge, PAYLOAD)
    runner.download_bytes = PAYLOAD[: len(PAYLOAD) // 2]

    with pytest.raises(BridgeError) as error:
        bridge.fetch()

    assert error.value.code == "size-mismatch"
    assert f"tamanho {len(PAYLOAD) // 2} difere do fixado {len(PAYLOAD)}" in str(error.value)
    assert not bridge.paths.package(bridge.asset()).exists()


def test_wrong_hash_discards_the_package(host):
    bridge, runner, _ = host
    pin_payload(bridge, PAYLOAD)
    runner.download_bytes = b"X" * len(PAYLOAD)

    with pytest.raises(BridgeError) as error:
        bridge.fetch()

    assert error.value.code == "hash-mismatch"
    assert "SHA-256 difere do valor fixado" in str(error.value)
    assert not bridge.paths.package(bridge.asset()).exists()


def test_failed_download_is_reported_not_swallowed(host):
    bridge, runner, _ = host
    pin_payload(bridge, PAYLOAD)
    runner.download_error = urllib.error.URLError("sem conexão")

    with pytest.raises(BridgeError) as error:
        bridge.fetch()

    assert error.value.code == "download-failed"
    assert "download falhou" in str(error.value)


def test_missing_host_tool_blocks_launch_by_name(host, monkeypatch):
    bridge, runner, _ = host
    clean_preflight(monkeypatch, bridge)
    monkeypatch.setattr(bridge_module.shutil, "which",
                        lambda name, path=None: None if name == "unsquashfs"
                        else f"/usr/bin/{name}")
    verified_package(bridge, Path("unused"), unpacked="verified")

    with pytest.raises(BridgeError) as error:
        bridge.launch()

    assert error.value.code == "preflight"
    assert "tool-unsquashfs" in str(error.value)


def test_missing_shared_libraries_are_listed_before_install_finishes(host):
    bridge, runner, _ = host
    image = fake_appimage(bridge.paths.packages / "launcher.AppImage")
    verified_package(bridge, image)
    runner.ldd_out = "\tlibwebkit2gtk-4.1.so.37 => not found\n"

    with pytest.raises(BridgeError) as error:
        bridge.install()

    assert error.value.code == "missing-libraries"
    assert "bibliotecas ausentes no sistema: libwebkit2gtk-4.1.so.37" in str(error.value)
    assert not bridge.paths.app.exists()


def test_foreign_process_on_the_bridge_port_blocks_launch(host, monkeypatch):
    bridge, runner, _ = host
    clean_preflight(monkeypatch, bridge)
    verified_package(bridge, Path("unused"), unpacked="verified")
    runner.port_busy = True

    with pytest.raises(BridgeError) as error:
        bridge.launch()

    assert error.value.code == "preflight"
    assert "port" in str(error.value)
    check = next(c for c in bridge.preflight()["checks"] if c["id"] == "port")
    assert check["status"] == "blocked"
    assert f"127.0.0.1:{DEFAULT_PORT} ocupada por outro processo" in check["detail"]


def test_launcher_that_crashes_on_start_reports_its_journal(host, monkeypatch):
    bridge, runner, _ = host
    clean_preflight(monkeypatch, bridge)
    verified_package(bridge, Path("unused"), unpacked="verified")
    runner.journal = "codex-web-gpt-launcher[123]: Fatal: bootstrap renderer crashed"

    with pytest.raises(BridgeError) as error:
        bridge.launch()

    assert error.value.code == "launch-failed"
    assert "launcher encerrou logo após iniciar" in str(error.value)
    assert "bootstrap renderer crashed" in str(error.value)


def test_manual_config_edit_is_reported_by_route_verify(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    bridge.paths.codex_config.write_text(
        bridge.paths.codex_config.read_text() + 'model_provider = "x"\n')

    result = bridge.route_verify()

    assert result["ok"] is False
    assert any("model_provider" in violation for violation in result["violations"])
    assert any("model_provider" in line for line in result["otherChanges"])


def test_route_enable_refuses_unexpected_changes_and_restores_the_config(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    runner.unit_active = True
    before = bridge.paths.codex_config.read_text()

    def upstream(verb: str) -> None:
        if verb == "route connect":
            bridge.paths.codex_config.write_text(before + 'model_provider = "x"\n')
        elif verb == "route disconnect":
            bridge.paths.codex_config.write_text(before)

    runner.on_upstream = upstream

    with pytest.raises(BridgeError) as error:
        bridge.route_enable()

    assert error.value.code == "route-enable-failed"
    assert "mudanças inesperadas na configuração" in str(error.value)
    assert "configuração anterior restaurada" in str(error.value)
    assert bridge.paths.codex_config.read_text() == before
    assert "route disconnect" in upstream_calls(runner)
    assert "routeEnabled" not in bridge.load_state()


# ---- PXA-013: rejection and reversion proofs ------------------------------


class FakeVault:
    """System secret store seam: keeps material out of state files."""

    def __init__(self) -> None:
        self.items: dict[str, str] = {}

    def store(self, reference: str, secret: str) -> None:
        self.items[reference] = secret

    def lookup(self, reference: str) -> str | None:
        return self.items.get(reference)

    def delete(self, reference: str) -> None:
        self.items.pop(reference, None)


def test_disable_during_a_running_task_restores_route_then_refuses(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    runner.codex_pids = [555]

    def upstream(verb: str) -> None:
        if verb == "route disconnect":
            runner.upstream["route status"] = (0, json.dumps({"installed": True,
                                                              "active": False}), "")

    runner.on_upstream = upstream

    with pytest.raises(BridgeError) as error:
        bridge.disable()

    assert error.value.code == "codex-running"
    assert "555" in str(error.value)
    assert "route disconnect" in upstream_calls(runner)  # route reverted first
    assert ["systemctl", "--user", "stop", UNIT_NAME] not in runner.calls
    assert runner.unit_active is True  # launcher and task untouched


def test_disable_aborts_before_teardown_when_route_cannot_be_restored(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    runner.upstream["route disconnect"] = (1, "", "upstream recusou")

    with pytest.raises(BridgeError) as error:
        bridge.disable()

    assert error.value.code == "route-restore-failed"
    assert "Nada mais foi encerrado" in str(error.value)
    assert ["systemctl", "--user", "stop", UNIT_NAME] not in runner.calls
    assert runner.unit_active is True


def test_route_disable_keeps_external_edits_and_reports_them(host):
    bridge, runner, _ = host
    configure(bridge, runner, route_active=True)
    bridge.paths.codex_config.write_text(
        bridge.paths.codex_config.read_text() + "js_repl = false\n")

    def upstream(verb: str) -> None:
        if verb == "route disconnect":
            runner.upstream["route status"] = (0, json.dumps({"installed": True,
                                                              "active": False}), "")

    runner.on_upstream = upstream
    result = bridge.route_disable()

    assert result["route"] == "restored"
    assert result["matchesBaseline"] is False
    assert any("js_repl" in line for line in result["externalEditsPreserved"])
    assert "js_repl = false" in bridge.paths.codex_config.read_text()


def test_stale_eligibility_blocks_the_tools_gate(host):
    bridge, _, _ = host
    base = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    bridge.clock = lambda: base
    assert bridge.record_eligibility("pro", "yes", "use", "yes")["blockers"] == []

    bridge.clock = lambda: base + dt.timedelta(days=31)

    blockers = bridge.eligibility(bridge.load_state())["blockers"]
    assert any("vencido" in blocker for blocker in blockers)
    with pytest.raises(BridgeError) as error:
        bridge.require_tools_ready(bridge.load_state())
    assert error.value.code == "tools-not-ready"
    assert "vencido" in str(error.value)


def test_tools_gate_refuses_while_launcher_stays_browser_only(host):
    bridge, runner, _ = host
    base = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    bridge.clock = lambda: base
    bridge.record_eligibility("pro", "yes", "use", "yes")
    bridge._secret_store = FakeVault()
    bridge.key_store("runtime-key-material", 30)
    configure(bridge, runner, route_active=False)  # upstream mode: browser-only

    with pytest.raises(BridgeError) as error:
        bridge.require_tools_ready(bridge.load_state())

    assert error.value.code == "tools-not-ready"
    assert "launcher não está no modo com ferramentas" in str(error.value)


def test_runtime_key_never_lands_in_state_or_errors(host):
    bridge, _, _ = host
    vault = FakeVault()
    bridge._secret_store = vault

    status = bridge.key_store("super-segredo-42", 30)

    assert status["state"] == "stored" and status["store"] == "os-secret-store"
    reference = bridge.load_state()["runtimeKey"]["ref"]
    assert reference.startswith("secret-service:")
    assert vault.items[reference] == "super-segredo-42"
    raw = bridge.paths.state.read_text()
    assert "super-segredo-42" not in raw
    assert "super-segredo-42" not in json.dumps(status)

    with pytest.raises(BridgeError) as empty:
        bridge.key_store("   ", 30)
    assert empty.value.code == "empty-key" and "super-segredo" not in str(empty.value)
    with pytest.raises(BridgeError) as out_of_range:
        bridge.key_store("x", 0)
    assert out_of_range.value.code == "rotation-range"


# ---- shortcuts, the two Desktop modes and consented history ----------------

MODELS_CACHE = {"models": [
    {"slug": "gpt-6-sol", "display_name": "GPT-6-Sol", "visibility": "list"},
    {"slug": "chatgpt-web/gpt-6-sol", "display_name": "GPT-6 Sol (Web)", "visibility": "list"},
    {"slug": "chatgpt-web/gpt-5.6-sol-instant", "display_name": "GPT-5.6 Sol Instant (Web)",
     "visibility": "list"},
    {"slug": "chatgpt-web/medium", "display_name": "ChatGPT Web — Medium", "visibility": "hide"},
]}


def ready_host(host, monkeypatch, mode: str = "browser-only"):
    bridge, runner, home = host
    configure(bridge, runner, route_active=True)
    config = bridge.paths.core_home / "config.json"
    config.write_text(json.dumps({**json.loads(config.read_text()), "mode": mode}))
    runner.unit_active = True
    runner.port_busy = True
    (bridge.paths.codex_home / "auth.json").write_text("{}")
    monkeypatch.setattr(bridge_module.shutil, "which",
                        lambda name, path=None: f"/usr/bin/{name}")
    return bridge, runner, home


def tools_gate_met(bridge: Bridge) -> None:
    bridge.record_eligibility("pro", "yes", "use", "yes")
    bridge._secret_store = FakeVault()
    bridge.key_store("runtime-key-material", 30)


def test_desktop_guidance_uses_the_labels_the_selector_really_shows(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch)
    (bridge.paths.codex_home / "models_cache.json").write_text(json.dumps(MODELS_CACHE))

    result = bridge.desktop()

    body = runner.notifications[-1][1]
    assert "GPT-6 Sol (Web)" in body and "GPT-5.6 Sol Instant (Web)" in body
    assert "ChatGPT Web — Medium" not in body and "chatgpt-web/medium" not in body
    assert result["visibleModels"] == ["GPT-6 Sol (Web)", "GPT-5.6 Sol Instant (Web)"]


def test_tools_window_stays_closed_until_the_gate_is_met(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch)  # launcher is browser-only

    with pytest.raises(BridgeError) as error:
        bridge.desktop("tools")

    assert error.value.code == "tools-not-ready"
    assert "elegibilidade não registrada" in str(error.value)
    assert runner.spawned == []

    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    bridge.shortcuts_install(desktop_copy=False)
    with pytest.raises(BridgeError):
        bridge.shortcut_run("tools")
    title, body, critical = runner.notifications[-1]
    assert critical is True and "com ferramentas" in title
    assert "ainda não pode abrir" in body and "eligibility --plan" in body
    assert runner.spawned == []


def test_tools_window_stays_closed_with_full_runtime_network_blocker(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch, mode="full")
    tools_gate_met(bridge)

    with pytest.raises(BridgeError) as error:
        bridge.desktop("tools")
    assert error.value.code == "tools-not-ready"
    assert "acesso de rede" in str(error.value) and "read-only" in str(error.value)
    assert runner.spawned == []

    # The browser-only shortcut must not quietly become a tools window.
    with pytest.raises(BridgeError) as error:
        bridge.desktop("web")
    assert error.value.code == "full-mode"
    assert runner.spawned == []


@pytest.mark.parametrize("line", ['approval_policy = "never"',
                                  'sandbox_mode = "danger-full-access"',
                                  'sandbox_mode = "workspace-write"'])
def test_no_desktop_window_opens_on_a_profile_that_allows_writes_or_auto_approval(
        host, monkeypatch, line):
    bridge, runner, _ = ready_host(host, monkeypatch, mode="full")
    tools_gate_met(bridge)
    key = line.split(" = ")[0]
    text = bridge.paths.codex_config.read_text()
    bridge.paths.codex_config.write_text(
        "\n".join(line if row.startswith(key) else row for row in text.splitlines()) + "\n")

    with pytest.raises(BridgeError) as error:
        bridge.desktop("tools")

    assert error.value.code == "config-drift"
    assert runner.spawned == []


def installed_shortcuts(host, monkeypatch):
    bridge, runner, home = ready_host(host, monkeypatch)
    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    (home / ".config").mkdir(exist_ok=True)
    (home / ".config/user-dirs.dirs").write_text('XDG_DESKTOP_DIR="$HOME/Área de trabalho"\n')
    (home / "Área de trabalho").mkdir()
    return bridge, runner, home


def test_shortcuts_land_in_menu_and_localised_desktop_on_a_stable_path(host, monkeypatch):
    bridge, runner, home = installed_shortcuts(host, monkeypatch)
    live = home / ".codex"
    live.mkdir()
    (live / "config.toml").write_text('model = "gpt-6-sol"\n')
    native = home / ".local/share/applications/codex-desktop.desktop"
    native.parent.mkdir(parents=True)
    native.write_text("[Desktop Entry]\nExec=/usr/bin/codex-desktop %u\n")
    assert bridge.shortcuts_status()["state"] == "off"

    status = bridge.shortcuts_install()

    assert status["state"] == "installed"
    target = bridge.paths.open_target.read_text()
    assert str(bridge.paths.manager_script) in target
    assert str(Path(bridge_module.__file__).resolve()) not in target
    assert bridge.paths.manager_secret_store.is_file()
    assert bridge.paths.manager_windows_secret_store.is_file()
    menu = home / ".local/share/applications"
    desk = home / "Área de trabalho"
    names = {"phasezero-chatgpt-web.desktop": "web", "phasezero-chatgpt-web-tools.desktop": "tools"}
    for name, mode in names.items():
        for folder in (menu, desk):
            entry = (folder / name).read_text()
            assert f'Exec="{bridge.paths.open_wrapper}" {mode}' in entry
            assert str(Path(bridge_module.__file__).resolve()) not in entry
            assert "NoDisplay" not in entry and "codex-web-gpt-launcher" not in entry
        assert os.access(desk / name, os.X_OK)  # KDE only launches trusted desktop icons
    assert "experimental" in (menu / "phasezero-chatgpt-web-tools.desktop").read_text()
    assert str(bridge.paths.open_wrapper).startswith(str(bridge.paths.root / "bin"))
    # The user's own Codex stays exactly as it was.
    assert native.read_text() == "[Desktop Entry]\nExec=/usr/bin/codex-desktop %u\n"
    assert sorted(item.name for item in live.iterdir()) == ["config.toml"]
    assert (live / "config.toml").read_text() == 'model = "gpt-6-sol"\n'

    # A stale worktree target must not be reported as a working shortcut.
    bridge.paths.open_target.write_text(
        f"{sys.executable}\n{home / 'deleted-worktree' / 'bridge.py'}\n")
    assert bridge.shortcuts_status()["state"] == "inconsistent"
    bridge.shortcuts_install()
    assert bridge.shortcuts_status()["state"] == "installed"

    (desk / "phasezero-chatgpt-web.desktop").write_text("[Desktop Entry]\nExec=/bin/true\n")
    assert bridge.shortcuts_status()["state"] == "inconsistent"
    with pytest.raises(BridgeError) as tampered:
        bridge.shortcut_run("web")
    assert tampered.value.code == "shortcuts-off" and runner.spawned == []

    assert bridge.shortcuts_remove()["state"] == "off"
    assert not any((folder / name).exists() for folder in (menu, desk) for name in names)
    assert not bridge.paths.open_wrapper.exists() and native.exists()


def test_shortcuts_can_skip_the_desktop_copy_and_leave_on_opt_out(host, monkeypatch):
    bridge, runner, home = installed_shortcuts(host, monkeypatch)

    status = bridge.shortcuts_install(desktop_copy=False)

    assert status["state"] == "installed" and status["desktopCopy"] is False
    assert list((home / "Área de trabalho").iterdir()) == []
    runner.unit_active = False
    runner.upstream["route status"] = (0, json.dumps({"installed": True, "active": False}), "")
    bridge.opt_out()
    assert bridge.shortcuts_status()["state"] == "off"
    assert not (home / ".local/share/applications/phasezero-chatgpt-web.desktop").exists()


def test_open_wrapper_fails_visibly_and_passes_the_mode_through(host, monkeypatch):
    bridge, _, home = installed_shortcuts(host, monkeypatch)
    bridge.shortcuts_install()
    wrapper = bridge.paths.open_wrapper

    bridge.paths.open_target.write_text(f"{sys.executable}\n{home / 'gone' / 'bridge.py'}\n")
    gone = _run_wrapper(wrapper, home)
    assert gone.returncode == 1
    log = (home / "notify.log").read_text()
    assert "não abriu" in log and "não existe mais" in log and "--urgency=critical" in log

    manager = home / "manager.py"
    manager.write_text("import sys\nprint('|'.join(sys.argv[1:]))\n")
    bridge.paths.open_target.write_text(f"{sys.executable}\n{manager}\n")
    done = subprocess.run(["/bin/sh", str(wrapper), "tools"], capture_output=True, text=True,
                          timeout=30, check=False)
    assert done.returncode == 0, done.stderr
    assert "shortcuts|run|--mode|tools" in done.stdout


def test_shortcut_starts_a_stopped_bridge_before_opening_the_window(host, monkeypatch):
    bridge, runner, _ = installed_shortcuts(host, monkeypatch)
    bridge.shortcuts_install()
    runner.unit_active = False
    waits: list[float] = []

    def fake_setup(report=None, login_wait=300):
        waits.append(login_wait)
        runner.unit_active = True
        return {"ready": True}

    bridge.setup = fake_setup

    result = bridge.shortcut_run("web")

    assert waits == [0]  # never blocks a click waiting for a login
    assert result["desktop"] == "started" and len(runner.spawned) == 1

    def broken_setup(report=None, login_wait=300):
        raise BridgeError("Login no ChatGPT ainda não concluído.", "login-required")

    runner.unit_active = False
    bridge.setup = broken_setup
    with pytest.raises(BridgeError):
        bridge.shortcut_run("web")
    title, body, critical = runner.notifications[-1]
    assert critical is True and "não abriu" in title and "Login no ChatGPT" in body
    assert len(runner.spawned) == 1


def make_repo(path: Path) -> Path:
    path.mkdir(parents=True)
    env = dict(os.environ, GIT_AUTHOR_NAME="Dev", GIT_AUTHOR_EMAIL="dev@example.invalid",
               GIT_COMMITTER_NAME="Dev", GIT_COMMITTER_EMAIL="dev@example.invalid",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")

    def git(*args: str) -> None:
        subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True, env=env)

    git("init", "-q", "-b", "main")
    (path / "app.py").write_text("print('a')\n")
    git("add", "app.py")
    git("commit", "-q", "-m", "feat: first screen")
    (path / "app.py").write_text("print('b')\n")
    git("commit", "-q", "-am", "fix: rotate key sk-abcdefghijklmnopqrstuvwx0123 leaked in CI")
    (path / "notes.txt").write_text("draft\n")
    return path


def test_history_needs_recorded_consent_for_that_repository(host, tmp_path):
    bridge, _, _ = host
    repo = make_repo(tmp_path / "work/project")

    with pytest.raises(BridgeError) as error:
        bridge.history_snapshot(str(repo))
    assert error.value.code == "history-consent-required"

    with pytest.raises(BridgeError) as no_ack:
        bridge.history_consent(str(repo), acknowledged=False)
    assert no_ack.value.code == "ack-missing"

    base = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
    bridge.clock = lambda: base
    granted = bridge.history_consent(str(repo), acknowledged=True)
    assert granted["repos"][0]["path"] == str(repo) and granted["repos"][0]["state"] == "granted"
    assert bridge.history_snapshot(str(repo))["commits"] == 2

    bridge.clock = lambda: base + dt.timedelta(days=31)
    with pytest.raises(BridgeError) as stale:
        bridge.history_snapshot(str(repo))
    assert stale.value.code == "history-consent-required" and "venceu" in str(stale.value)

    bridge.clock = lambda: base
    assert bridge.history_revoke(str(repo))["repos"] == []
    with pytest.raises(BridgeError):
        bridge.history_snapshot(str(repo))


def test_history_scope_excludes_codex_profiles_and_non_repositories(host, tmp_path):
    bridge, _, home = host
    sessions = make_repo(home / ".codex")
    (sessions / "sessions").mkdir()
    plain = tmp_path / "plain"
    plain.mkdir()

    for target in (sessions, sessions / "sessions", bridge.paths.root, home):
        target.mkdir(parents=True, exist_ok=True)
        with pytest.raises(BridgeError) as error:
            bridge.history_consent(str(target), acknowledged=True)
        assert error.value.code == "history-scope", target
    with pytest.raises(BridgeError) as not_repo:
        bridge.history_consent(str(plain), acknowledged=True)
    assert not_repo.value.code == "history-not-a-repo"
    assert "history" not in bridge.load_state()


def test_history_snapshot_is_bounded_redacted_and_carries_no_identity(host, tmp_path):
    bridge, _, _ = host
    repo = make_repo(tmp_path / "work/project")
    bridge.history_consent(str(repo), acknowledged=True)

    snapshot = bridge.history_snapshot(str(repo), commits=1)

    text = snapshot["text"]
    assert snapshot["commits"] == 1 and "feat: first screen" not in text
    assert "fix: rotate key" in text and "sk-abcdefghijklmnopqrstuvwx0123" not in text
    assert "[REDIGIDO]" in text
    assert "dev@example.invalid" not in text and "Dev <" not in text
    assert "notes.txt" in text and "main" in text
    assert "print('b')" not in text  # file contents never leave by default
    assert snapshot["bytes"] == len(text.encode()) <= bridge_module.HISTORY_MAX_BYTES
    with pytest.raises(BridgeError) as too_many:
        bridge.history_snapshot(str(repo), commits=10_000)
    assert too_many.value.code == "history-range"


def test_ask_sends_the_snapshot_through_the_read_only_profile(host, monkeypatch, tmp_path):
    bridge, runner, home = ready_host(host, monkeypatch)
    repo = make_repo(tmp_path / "work/project")
    before = sorted(item.name for item in repo.iterdir())
    runner.codex_reply = "Dois commits: tela inicial e rotação de chave."

    with pytest.raises(BridgeError) as error:
        bridge.ask(str(repo), "O que mudou?")
    assert error.value.code == "history-consent-required"
    assert not any(call[0].endswith("/codex") for call in runner.calls)

    bridge.history_consent(str(repo), acknowledged=True)
    result = bridge.ask(str(repo), "O que mudou?")

    call = next(call for call in runner.calls if call[0].endswith("/codex"))
    assert call[1:5] == ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
    assert call[call.index("--model") + 1] == "chatgpt-web/medium"
    assert str(repo) not in call[call.index("-C") + 1]  # Codex never runs inside the repo
    prompt = call[-1]
    assert "feat: first screen" in prompt and "O que mudou?" in prompt
    assert "sk-abcdefghijklmnopqrstuvwx0123" not in prompt
    assert result["ok"] is True and "Dois commits" in result["reply"]
    assert result["sandbox"] == "read-only" and result["localTools"] is False
    assert sorted(item.name for item in repo.iterdir()) == before
    assert not (home / ".codex").exists()


def test_tools_steps_explain_an_ineligible_plan_and_the_single_next_step(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch)
    first = bridge.tools_steps()
    assert first["ready"] is False and first["next"]["id"] == "eligibility"
    assert "eligibility --plan" in first["next"]["action"]

    bridge.record_eligibility("plus", "no", "manage", "yes")
    status = bridge.tools_steps()

    assert status["ready"] is False and status["webModelStillWorks"] is True
    step = status["next"]
    assert step["id"] == "plan" and step["ok"] is False
    assert "Plus" in step["detail"] and "Pro" in step["detail"] and "Business" in step["detail"]
    assert "help.openai.com" in step["action"]
    # Later steps are listed but never offered before the plan is resolved.
    assert [item["id"] for item in status["steps"]][:3] == ["eligibility", "plan", "developer-mode"]

    bridge.package_state = lambda: {"state": "verified", "path": "x", "sha256": "x",
                                    "unpacked": "verified"}
    bridge.shortcuts_install(desktop_copy=False)
    with pytest.raises(BridgeError) as error:
        bridge.shortcut_run("tools")
    assert error.value.code == "tools-not-ready"
    title, body, critical = runner.notifications[-1]
    assert "com ferramentas" in title and critical is True
    assert "Plus" in body and "Business" in body
    assert "ChatGPT Web no Codex" in body  # the browser-only shortcut still works
    assert runner.spawned == []


def test_tools_steps_report_runtime_blocker_after_other_requirements(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch)
    bridge.record_eligibility("pro", "yes", "use", "yes")
    single_user = next(item for item in bridge.tools_steps()["steps"]
                       if item["id"] == "single-user")
    assert single_user["ok"] is True and "verificado" in single_user["detail"]
    assert single_user["action"] == "Nenhuma ação necessária."
    assert bridge.tools_steps()["next"]["id"] == "runtime-key"
    assert "tunnel key store" in bridge.tools_steps()["next"]["action"]

    bridge._secret_store = FakeVault()
    bridge.key_store("runtime-key-material", 30)
    step = bridge.tools_steps()["next"]
    assert step["id"] == "full-runtime" and "browser-only" in step["action"]
    launcher_mode = next(item for item in bridge.tools_steps()["steps"]
                         if item["id"] == "launcher-mode")
    assert launcher_mode["ok"] is False
    assert "Não altere o launcher" in launcher_mode["action"]

    runner.other_users = lambda: ["another-user"]
    single_user = bridge.tools_steps()["next"]
    assert single_user["id"] == "single-user" and single_user["ok"] is False
    assert "outra conta local" in single_user["detail"]
    assert "Não ative ferramentas" in single_user["action"]
    runner.other_users = lambda: ["unknown"]
    assert "não foi possível verificar" in bridge.tools_steps()["next"]["detail"]
    runner.other_users = lambda: []

    config = bridge.paths.core_home / "config.json"
    config.write_text(json.dumps({**json.loads(config.read_text()), "mode": "full",
                                  "autoApproveToolCalls": True}))
    assert bridge.tools_steps()["next"]["id"] == "auto-approve"

    config.write_text(json.dumps({**json.loads(config.read_text()),
                                  "autoApproveToolCalls": False}))
    done = bridge.tools_steps()
    assert done["ready"] is False and done["next"]["id"] == "full-runtime"
    assert "runtime-key-material" not in json.dumps(done)


def test_tools_check_rejects_healthy_doctor_without_a_working_turn(host, monkeypatch):
    bridge, runner, _ = ready_host(host, monkeypatch, mode="full")
    tools_gate_met(bridge)
    runner.upstream["doctor --json"] = (0, json.dumps({"ok": True}), "")

    result = bridge.tools_check()

    assert result["ready"] is False
    assert result["doctor"] == {"ok": True}
    assert any("acesso de rede" in blocker for blocker in result["blockers"])
    assert bridge.status()["toolsGate"]["next"]["id"] == "full-runtime"


DESKTOP_REWRITTEN = (
    'sandbox_mode = "read-only"\n'
    f'{APPROVAL_LINE}\n'
    f'openai_base_url = "http://127.0.0.1:{DEFAULT_PORT}/v1"\n'
    'experimental_realtime_webrtc_call_base_url = "https://chatgpt.com/backend-api/codex"\n'
    '\n[features]\nmulti_agent = true\n')


REFUSAL = ("codex-chatgpt-web: Codex interrupt lifecycle hook changed after setup; "
           "refusing to overwrite it.")


def test_disable_resets_the_dedicated_profile_when_upstream_refuses_a_rewritten_config(host):
    # Reproduced on the host with 6.1.8: after Codex Desktop re-serialises
    # config.toml, upstream's `route disconnect` refuses and teardown was stuck.
    bridge, runner, home = host
    configure(bridge, runner, route_active=True)
    runner.unit_active = True
    rewritten = DESKTOP_REWRITTEN + '\n[desktop]\nsansFontSize = 14\n'
    bridge.paths.codex_config.write_text(rewritten)
    journal = bridge.paths.core_home / "codex/integration-journal.json"
    journal.parent.mkdir(parents=True)
    journal.write_text('{"version": 10, "active": true}')
    runner.upstream["route disconnect"] = (0, REFUSAL, "")
    runner.upstream["route status"] = (0, json.dumps({"installed": True, "active": True,
                                                       "errors": [REFUSAL]}), "")

    status = bridge.route_status()
    assert status["desktopRewroteConfig"] is True and "disable" in status["hint"]
    assert bridge.paths.codex_config.read_text() == rewritten  # observing never edits

    result = bridge.disable()

    assert result["disabled"] is True
    route = result["steps"][0]
    assert route["route"] == "restored-by-reset"
    assert bridge.paths.codex_config.read_text() == OWNED_CONFIG
    assert Path(route["configBackup"]).read_text() == rewritten
    quarantine = Path(route["upstreamStateQuarantined"])
    assert quarantine.parent == bridge.paths.journal
    assert (quarantine / "integration-journal.json").is_file()
    assert (quarantine / "config.json").is_file()
    assert not journal.exists() and not (bridge.paths.core_home / "config.json").exists()
    assert bridge.route_status() == {"installed": False, "active": False,
                                     "source": "no-upstream-config"}
    assert ["systemctl", "--user", "stop", UNIT_NAME] in runner.calls
    assert "routeEnabled" not in bridge.load_state()
    assert not (home / ".codex").exists()


def test_setup_after_a_reset_restarts_the_launcher_before_configuring_again(host):
    # With no upstream config left, the still-running daemon would hold the
    # bridge port and upstream setup would collide with it.
    bridge, runner, _ = host
    configure(bridge, runner, route_active=False)
    (bridge.paths.core_home / "config.json").unlink()
    package = bridge.paths.package(bridge.asset())
    bridge.package_state = lambda: {"state": "verified", "path": str(package),
                                    "sha256": "x", "unpacked": "verified"}
    runner.unit_active = True
    runner.port_busy = True
    runner.launchers = [{"pid": 99, "managed": True}]
    bridge.paths.descriptor.parent.mkdir(parents=True)
    bridge.paths.descriptor.write_text(json.dumps({"pid": 99}))
    write_profile(bridge.paths.launcher_data, signed_in=True, auto_start=False)
    order: list[str] = []
    bridge.restart_launcher = lambda: (order.append("restart"),
                                       setattr(runner, "port_busy", False))[0]

    def upstream(verb: str) -> None:
        if verb.startswith("setup"):
            order.append("upstream-setup")
            (bridge.paths.core_home / "config.json").write_text(json.dumps(
                {"mode": "browser-only", "solAvailable": True}))
            runner.upstream["route status"] = (0, json.dumps({"installed": True,
                                                               "active": True}), "")
            runner.port_busy = True

    runner.on_upstream = upstream

    result = bridge.setup()

    assert order == ["restart", "upstream-setup"]
    assert result["ready"] is True and result["stage"] == "web-model"
