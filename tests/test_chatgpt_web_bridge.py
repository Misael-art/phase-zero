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
    assert 'Exec="' in entry and "chatgpt-web-autostart.sh\"" in entry
    assert "autostart run" not in entry  # Exec is the stable wrapper, not the worktree
    assert bridge.paths.autostart_wrapper.is_file()
    assert bridge.paths.autostart_target.is_file()
    assert "codex-web-gpt-launcher" not in entry
    assert bridge.isolation()["upstreamAutostartEntry"] is None

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
