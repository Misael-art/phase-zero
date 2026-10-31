from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import socket
import tempfile
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import pytest

from linux.ai.codex_profiles import CodexProfiles, ProfileError
from linux.ai.chatgpt_web_bridge import BridgeError, DEFAULT_PORT, UNIT_NAME, Runner


@pytest.fixture
def manager(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    for key, value in {"HOME": str(home), "XDG_DATA_HOME": str(home / "data"),
                       "XDG_CONFIG_HOME": str(home / "config"), "XDG_STATE_HOME": str(home / "state"),
                       "XDG_CACHE_HOME": str(home / "cache"), "XDG_RUNTIME_DIR": str(tmp_path / "runtime")}.items():
        monkeypatch.setenv(key, value)
    return CodexProfiles()


def test_status_is_read_only_and_preserves_existing_accounts(manager):
    native = manager.home / ".codex"
    native.mkdir()
    (native / "auth.json").write_text('{"token":"private-native-sentinel"}')
    web = manager.bridge({"id": "current", "slot": 0}).paths
    web.launcher_data.mkdir(parents=True)
    (web.launcher_data / "Cookies").write_text("private-web-sentinel")
    before = sorted(str(path) for path in manager.home.rglob("*"))
    result = manager.status()
    assert before == sorted(str(path) for path in manager.home.rglob("*"))
    assert not manager.root.exists()
    assert result["profiles"][0]["nativeCredential"] == "present"
    assert result["profiles"][0]["session"] == "unverified"
    assert "sentinel" not in json.dumps(result)
    assert (native / "auth.json").read_text() == '{"token":"private-native-sentinel"}'
    manager.rename("current", "Conta principal", "azul")
    assert manager.get("current")["label"] == "Conta principal"
    assert manager.native_home(manager.get("current")) == native
    assert (native / "auth.json").read_text() == '{"token":"private-native-sentinel"}'


def test_concurrent_creation_retains_every_account_and_unique_slot(manager):
    with ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(pool.map(lambda index: manager.add(f"Account {index}"), range(8)))
    assert len(manager.rows()) == 8
    assert len({row["id"] for row in rows}) == 8
    assert len({row["slot"] for row in rows}) == 8
    assert manager.registry.stat().st_mode & 0o777 == 0o600
    assert manager.root.stat().st_mode & 0o777 == 0o700


def test_native_profiles_never_inherit_or_copy_credentials_routes_or_electron_state(manager):
    manager.env.update(OPENAI_API_KEY="secret-api", OPENAI_BASE_URL="http://wrong-route",
                       CODEX_HOME="/wrong/account", CODEX_ELECTRON_USER_DATA_DIR="/wrong/electron",
                       PZ_CHATGPT_WEB_ROOT="/wrong/web", ELECTRON_RUN_AS_NODE="1")
    rows = [manager.add("Conta A", "verde"), manager.add("Conta B", "roxo")]
    environments = []
    for row in rows:
        manager.prepare_native(row)
        env = manager.profile_env(row)
        environments.append(env)
        assert "OPENAI_API_KEY" not in env and "OPENAI_BASE_URL" not in env
        assert "PZ_CHATGPT_WEB_ROOT" not in env and "ELECTRON_RUN_AS_NODE" not in env
        assert not (Path(env["CODEX_HOME"]) / "auth.json").exists()
        config = (Path(env["CODEX_HOME"]) / "config.toml").read_text()
        assert 'cli_auth_credentials_store = "file"' in config
        assert 'forced_login_method = "chatgpt"' in config
    for key in ("CODEX_HOME", "CODEX_ELECTRON_USER_DATA_DIR", "CODEX_WEBVIEW_PORT",
                "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
        assert environments[0][key] != environments[1][key]
    # A shell inside either Desktop must resolve the same account registry,
    # rather than creating a second manager under the app's private XDG root.
    nested = CodexProfiles(environments[0])
    assert nested.root == manager.root and nested.config == manager.config
    # A simulated Codex login belongs to A and survives rename/restart; B stays empty.
    auth = manager.native_home(rows[0]) / "auth.json"
    auth.write_text("sentinel-account-A")
    original_port = environments[0]["CODEX_WEBVIEW_PORT"]
    manager.rename(rows[0]["id"], "Novo nome A", "laranja")
    restarted = CodexProfiles(manager.env)
    assert restarted.profile_env(restarted.get(rows[0]["id"]))["CODEX_WEBVIEW_PORT"] == original_port
    assert auth.read_text() == "sentinel-account-A"
    assert not (manager.native_home(rows[1]) / "auth.json").exists()


def test_two_real_stub_cli_processes_receive_distinct_persistent_homes(manager, tmp_path):
    binary = tmp_path / "bin" / "codex"
    binary.parent.mkdir()
    binary.write_text("#!/usr/bin/env python3\nimport os,pathlib\n"
                      "p=pathlib.Path(os.environ['CODEX_HOME'])\n"
                      "(p/'session-probe').write_text(str(p))\n")
    binary.chmod(0o700)
    manager.env["PATH"] = str(binary.parent) + os.pathsep + manager.env["PATH"]
    rows = [manager.add("A"), manager.add("B")]
    children = []
    for row in rows:
        command, env = manager.cli_command(row["id"], ["login", "status"])
        children.append(subprocess.Popen(command, env=env))
    assert [child.wait(timeout=10) for child in children] == [0, 0]
    for row in rows:
        home = manager.native_home(row)
        assert (home / "session-probe").read_text() == str(home)


def test_bridge_isolates_accounts_without_changing_default_contract(manager):
    default = manager.bridge({"id": "current", "slot": 0})
    assert default.paths.port == DEFAULT_PORT
    assert default.paths.unit_name == UNIT_NAME
    accounts = [manager.add("A"), manager.add("B")]
    bridges = [manager.bridge(row) for row in accounts]
    for name in ("root", "codex_home", "core_home", "launcher_data", "packages", "runtime",
                 "managed_autostart", "unit_name", "port"):
        assert getattr(bridges[0].paths, name) != getattr(bridges[1].paths, name)
        assert getattr(bridges[0].paths, name) != getattr(default.paths, name)
    for row, bridge in zip(accounts, bridges):
        assert bridge.paths.live_codex_home == manager.native_home(row)
        assert bridge.upstream_env()["CODEX_HOME"] != str(manager.native_home(row))
        bridge.seed_codex_home()
        assert 'cli_auth_credentials_store = "file"' in bridge.paths.codex_config.read_text()
        script = bridge.autostart_wrapper_text()
        assert row["id"] in script
        assert str(bridge.paths.root) in script
        assert str(bridge.paths.live_codex_home) in script
        assert set(bridge.paths.shortcut_entries.values()).isdisjoint(default.paths.shortcut_entries.values())
        bridge.opt_in({"experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"})
        with pytest.raises(BridgeError, match="login próprio"):
            bridge.adopt_session()
    from linux.ai.chatgpt_web_bridge import Bridge
    wrong = dict(bridges[0].env, PZ_CHATGPT_WEB_ROOT=str(default.paths.root))
    with pytest.raises(BridgeError, match="Raiz Web"):
        Bridge(env=wrong)
    wrong = dict(bridges[0].env, PZ_LIVE_CODEX_HOME=str(bridges[1].paths.live_codex_home))
    with pytest.raises(BridgeError, match="Perfil nativo"):
        Bridge(env=wrong)


def test_corrupt_registry_unknown_id_and_symlink_fail_closed(manager, tmp_path):
    row = manager.add("A")
    document = json.loads(manager.registry.read_text())
    document["profiles"].append(dict(row, id="pz-abcdefabcdef"))  # duplicate slot
    manager.registry.write_text(json.dumps(document))
    with pytest.raises(ProfileError, match="inválido"):
        manager.status()
    with pytest.raises(ProfileError):
        manager.launch("../escape", "desktop")
    manager.registry.unlink()
    manager.registry.symlink_to(tmp_path / "private")
    with pytest.raises(ProfileError, match="simbólico"):
        manager.rows()


def test_shortcuts_quote_paths_and_preserve_identity_through_archive_restore(manager):
    desktop = manager.home / "Área de Trabalho"
    desktop.mkdir()
    manager.config.mkdir()
    (manager.config / "user-dirs.dirs").write_text('XDG_DESKTOP_DIR="$HOME/Área de Trabalho"\n')
    row = manager.add("Conta A % com espaços", "verde")
    result = manager.shortcuts(row["id"])
    assert result["count"] == 6
    native = manager.native_home(row)
    manager.prepare_native(row)
    (native / "auth.json").write_text("private-A")
    entries = list(desktop.glob("*.desktop"))
    assert len(entries) == 2
    for entry in entries:
        text = entry.read_text()
        assert row["label"] in text and "private-A" not in text
        assert entry.stat().st_mode & 0o111
    wrappers = manager.profile_base(row)
    script = (wrappers / "open-desktop.sh").read_text()
    assert "export XDG_DATA_HOME=" in script
    assert row["id"] in script and "--surface desktop" in script
    manager.rename(row["id"], "Identidade atualizada", "laranja")
    assert all("Identidade atualizada" in path.read_text() for path in desktop.glob("*.desktop"))
    manager.archive(row["id"])
    assert not list(desktop.glob("*.desktop"))
    with pytest.raises(ProfileError, match="arquivado"):
        manager.launch(row["id"], "desktop")
    manager.archive(row["id"], restore=True)
    assert manager.get(row["id"])["id"] == row["id"]
    assert (native / "auth.json").read_text() == "private-A"


def test_absent_web_archive_never_downloads_or_uses_default_session(manager):
    row = manager.add("B")
    with patch("urllib.request.urlopen", side_effect=AssertionError("unexpected download")):
        with pytest.raises(ProfileError, match="Download manual"):
            manager.prepare_web_package(row["id"])
    assert not manager.bridge(row).paths.launcher_data.exists()
    bridge = manager.bridge(row)
    bridge.opt_in({"experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"})
    with patch.object(bridge.runner, "download", side_effect=AssertionError("unexpected download")):
        with pytest.raises(BridgeError, match="Download manual"):
            bridge.fetch()


def test_native_and_browser_launches_target_only_selected_account(manager):
    a, b = manager.add("A"), manager.add("B")
    spawned = []
    with patch("shutil.which", side_effect=lambda name, **kw: "/bin/" + name), \
         patch.object(manager, "desktop_profiles_supported", return_value=True), \
         patch.object(manager, "check_desktop_socket_path"), \
         patch("socket.socket") as sockets, \
         patch("subprocess.Popen", side_effect=lambda command, **kw:
               spawned.append((command, kw["env"])) or type("Child", (), {"pid": 321})()):
        sockets.return_value.__enter__.return_value.connect_ex.return_value = 1
        manager.launch(a["id"], "desktop")
        manager.launch(b["id"], "desktop")
        manager.launch(a["id"], "browser")
    assert spawned[0][1]["CODEX_HOME"] != spawned[1][1]["CODEX_HOME"]
    assert "--new-instance" in spawned[0][0]
    assert a["id"] in " ".join(spawned[2][0])
    assert b["id"] not in " ".join(spawned[2][0])


def test_stopping_one_web_profile_never_stops_another_profiles_scope():
    runner = Runner()
    calls = []
    def run(args, **kwargs):
        calls.append(args)
        if "list-units" in args:
            return 0, ("app-codex-web-gpt-launcher-101.scope loaded active running\n"
                       "app-codex-web-gpt-launcher-202.scope loaded active running\n"), ""
        return 0, "", ""
    runner.run = run
    assert runner.stop_launcher_scopes([101]) == ["app-codex-web-gpt-launcher-101.scope"]
    stops = [args[-1] for args in calls if "stop" in args]
    assert stops == ["app-codex-web-gpt-launcher-101.scope"]
    calls.clear()
    assert runner.stop_launcher_scopes([]) == []
    assert calls == []


def test_redirecting_one_profile_to_another_blocks_launch(manager):
    a, b = manager.add("A"), manager.add("B")
    manager.prepare_native(a)
    parent = manager.profile_base(b)
    parent.mkdir()
    (parent / "native").symlink_to(manager.native_home(a), target_is_directory=True)
    with pytest.raises(ProfileError, match="link simbólico"):
        manager.cli_command(b["id"], ["login"])


def test_bridge_stops_only_selected_unit_and_its_scope(manager):
    class SharedRunner(Runner):
        def __init__(self):
            self.active = {}
            self.calls = []
        def run(self, command, **kwargs):
            self.calls.append(command)
            if "is-active" in command:
                return (0, "active", "") if self.active.get(command[-1]) else (3, "inactive", "")
            if "list-units" in command:
                return 0, "\n".join(f"app-codex-web-gpt-launcher-{pid}.scope active" for pid in (101, 202)), ""
            if "stop" in command:
                self.active[command[-1]] = False
            return 0, "", ""
        def launcher_processes(self, binary, data_dir, readonly_path, *, unit_name):
            pid = 101 if unit_name == first.paths.unit_name else 202
            return [{"pid": pid, "managed": True}] if self.active.get(unit_name) else []
        def tunnel_clients(self, binary):
            return []
        def port_in_use(self, port):
            return False
    first, second = (manager.bridge(manager.add(label)) for label in ("A", "B"))
    runner = SharedRunner()
    runner.active = {first.paths.unit_name: True, second.paths.unit_name: True}
    first.runner = second.runner = runner
    assert second.stop_launcher()["launcher"] == "stopped"
    assert runner.active[first.paths.unit_name] is True
    assert runner.active[second.paths.unit_name] is False
    stops = [command[-1] for command in runner.calls if "stop" in command]
    assert stops == [second.paths.unit_name, "app-codex-web-gpt-launcher-202.scope"]


def test_desktop_socket_limit_counts_utf8_bytes_and_compact_defaults():
    manager = CodexProfiles({"HOME": "/home/test"})
    row = {"id": "pz-0123456789ab", "slot": 1}
    manager.check_desktop_socket_path(manager.native_home(row))
    manager.check_desktop_socket_path(manager.bridge(row).paths.codex_home)
    with pytest.raises(ProfileError, match="107 bytes"):
        manager.check_desktop_socket_path(Path("/home/" + "ã" * 60))


def test_web_open_restarts_only_its_saved_bridge_after_logout_or_reboot(manager):
    row = manager.add("A")
    bridge = manager.bridge(row)
    bridge.opt_in({"experimental", "unofficial", "unsigned", "same-user-boundary", "no-quota-promise"})
    calls = []
    with patch.object(manager, "bridge", return_value=bridge), \
         patch.object(manager, "prepare_web_package", side_effect=lambda profile_id: calls.append(profile_id)), \
         patch.object(manager, "check_desktop_socket_path"), \
         patch.object(manager, "desktop_profiles_supported", return_value=True), \
         patch.object(bridge, "launcher_active", return_value=False), \
         patch.object(bridge, "setup", side_effect=lambda **kw: calls.append(kw)), \
         patch.object(bridge, "desktop", return_value={"desktop": "started"}):
        assert manager.launch(row["id"], "web") == {"desktop": "started"}
    assert calls == [row["id"], {"login_wait": 0}]


def test_panel_metadata_uses_stdin_and_redacted_output(manager):
    script = Path(__file__).resolve().parents[1] / "linux/ai/codex_profiles.py"
    command = [sys.executable, str(script), "--redacted", "add", "--metadata-stdin"]
    nickname = "Private account nickname"
    result = subprocess.run(command, input=json.dumps({"label": nickname, "color": "roxo"}),
                            text=True, capture_output=True, env=manager.env, timeout=15)
    assert result.returncode == 0, result.stderr
    assert nickname not in " ".join(command) + result.stdout + result.stderr
    assert json.loads(result.stdout)["identityRedacted"] is True
    assert manager.rows()[0]["label"] == nickname


def test_isolated_desktop_retains_localized_user_directories_without_sharing_settings(manager):
    from linux.ai.chatgpt_web_bridge import DESKTOP_DIR_MAP_HEADER
    from linux.lib.pz_hostbackup import latest_backup
    manager.config.mkdir(parents=True)
    source = manager.config / "user-dirs.dirs"
    source.write_text('XDG_DESKTOP_DIR="$HOME/Área de trabalho"\n'
                      'XDG_DOCUMENTS_DIR="$HOME/Documentos"\n'
                      'XDG_DOWNLOAD_DIR="$HOME/Downloads"\n')
    settings = manager.config / "codex-desktop" / "settings.json"
    settings.parent.mkdir()
    settings.write_text('{"privateSettings":"sentinel-do-not-copy"}')
    row = manager.add("A")
    manager.prepare_native(row)
    targets = []
    for mode in ("native", "web"):
        env = manager.profile_env(row, mode)
        config = Path(env["XDG_CONFIG_HOME"])
        target = config / "user-dirs.dirs"
        targets.append(target)
        assert target.read_text().startswith(DESKTOP_DIR_MAP_HEADER)
        assert f'XDG_DESKTOP_DIR="{manager.home}/Área de trabalho"' in target.read_text()
        assert f'XDG_DOCUMENTS_DIR="{manager.home}/Documentos"' in target.read_text()
        assert not (config / "codex-desktop/settings.json").exists()
        assert target.stat().st_mode & 0o777 == 0o600
    mtimes = [target.stat().st_mtime_ns for target in targets]
    assert manager.prepare_desktop_dirs(row) == 0
    assert mtimes == [target.stat().st_mtime_ns for target in targets]
    previous = targets[0].read_bytes()
    source.write_text('XDG_DESKTOP_DIR="$HOME/Outra pasta"\n')
    assert manager.prepare_desktop_dirs(row) == 2
    assert latest_backup(targets[0]).read_bytes() == previous
    assert source.read_text() == 'XDG_DESKTOP_DIR="$HOME/Outra pasta"\n'


def test_user_directory_map_never_evaluates_shell_and_preserves_manual_maps(manager):
    from linux.ai.chatgpt_web_bridge import sync_desktop_user_dirs
    manager.config.mkdir(parents=True)
    source = manager.config / "user-dirs.dirs"
    source.write_text('XDG_DESKTOP_DIR="$HOME/Área $(touch SHOULD_NOT_EXIST) `echo bad`"\n'
                      'UNRELATED_SETTING="secret-do-not-copy"\n')
    target = manager.home / "isolated-config"
    assert sync_desktop_user_dirs(manager.home, manager.config, target)
    generated = (target / "user-dirs.dirs").read_text()
    assert r'\$(touch SHOULD_NOT_EXIST)' in generated and r'\`echo bad\`' in generated
    assert "secret-do-not-copy" not in generated
    assert not (manager.home / "SHOULD_NOT_EXIST").exists()
    custom = 'XDG_DESKTOP_DIR="/custom-user-choice"\n'
    (target / "user-dirs.dirs").write_text(custom)
    assert not sync_desktop_user_dirs(manager.home, manager.config, target)
    assert (target / "user-dirs.dirs").read_text() == custom


def test_open_busy_profile_focuses_existing_owner_without_spawning_or_using_another_account(manager):
    a, b = manager.add("A"), manager.add("B")
    with patch("shutil.which", return_value="/bin/codex-desktop"), \
         patch.object(manager, "desktop_profiles_supported", return_value=True), \
         patch.object(manager, "check_desktop_socket_path"), \
         patch("socket.socket") as sockets, \
         patch("linux.ai.chatgpt_web_bridge.focus_desktop_instance", return_value=123) as focus, \
         patch("subprocess.Popen", side_effect=AssertionError("must not spawn duplicate")):
        sockets.return_value.__enter__.return_value.connect_ex.return_value = 0
        result = manager.launch(a["id"], "desktop")
    assert result["focused"] is True and result["started"] is False
    env = focus.call_args.args[0]
    assert env["CODEX_HOME"] == str(manager.native_home(a))
    assert b["id"] not in env["CODEX_ELECTRON_USER_DATA_DIR"]


def test_unowned_busy_port_remains_an_error_and_is_never_stopped(manager):
    row = manager.add("A")
    with patch("shutil.which", return_value="/bin/codex-desktop"), \
         patch.object(manager, "desktop_profiles_supported", return_value=True), \
         patch.object(manager, "check_desktop_socket_path"), \
         patch("socket.socket") as sockets, \
         patch("linux.ai.chatgpt_web_bridge.focus_desktop_instance", return_value=None), \
         patch("subprocess.Popen", side_effect=AssertionError("must not spawn")), \
         patch("os.kill", side_effect=AssertionError("must not stop another process")):
        sockets.return_value.__enter__.return_value.connect_ex.return_value = 0
        with pytest.raises(ProfileError, match="porta ocupada"):
            manager.launch(row["id"], "desktop")


@pytest.mark.skipif(sys.platform != "linux", reason="Linux desktop namespace")
def test_desktop_owner_requires_process_identity_and_matching_electron_home(manager):
    from linux.ai import chatgpt_web_bridge as module
    a, b = manager.add("A"), manager.add("B")
    env = manager.profile_env(a)
    port = env["CODEX_WEBVIEW_PORT"]
    state = Path(env["XDG_STATE_HOME"]) / "codex-desktop/instances" / f"port-{port}"
    state.mkdir(parents=True)
    (state / "app.pid").write_text(str(os.getpid()))
    exe = Path(f"/proc/{os.getpid()}/exe")
    cmdline = Path(f"/proc/{os.getpid()}/cmdline")
    original_readlink, original_read_bytes = os.readlink, Path.read_bytes
    own = os.fsencode(env["CODEX_ELECTRON_USER_DATA_DIR"] + f"/instances/port-{port}")
    other = os.fsencode(manager.profile_env(b)["CODEX_ELECTRON_USER_DATA_DIR"])
    def link(path, *args, **kwargs):
        return "/opt/codex-desktop/electron" if Path(path) == exe else original_readlink(path, *args, **kwargs)
    for target, expected, collapsed in ((own, True, False), (other, False, False),
                                        (own, True, True), (other, False, True),
                                        (own + b"-other", False, True)):
        def read(path):
            if path != cmdline:
                return original_read_bytes(path)
            return (b"/opt/codex-desktop/electron --no-sandbox --user-data-dir=" + target + b" --class=codex-desktop\0"
                    if collapsed else b"electron\0--user-data-dir=" + target + b"\0")
        with patch("os.readlink", side_effect=link), patch.object(Path, "read_bytes", read):
            assert (module.desktop_instance(env) is not None) is expected
    (state / "app.pid").write_text("2147483647")
    assert module.desktop_instance(env) is None


@pytest.mark.skipif(not hasattr(socket, "SO_PEERCRED"), reason="Linux peer credentials")
@pytest.mark.parametrize("failure", ["", "peer-pid", "start-ticks"])
def test_focus_handoff_uses_real_unix_peer_and_refuses_wrong_owner(failure):
    from linux.ai import chatgpt_web_bridge as module
    # TMPDIR is the short persistent per-user test root, not the long pytest
    # fixture path, which can exceed AF_UNIX's pathname limit.
    with tempfile.TemporaryDirectory(prefix="focus-") as directory:
        endpoint = Path(directory) / "action.sock"
        code = (
            "import socket,sys,json\n"
            "s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(1)\n"
            "print('ready',flush=True)\n"
            "c,_=s.accept();data=c.recv(1024)\n"
            "if data:c.sendall(b'ok\\n')\n"
            "print(json.dumps({'received':data.decode()}),flush=True)\n"
        )
        process = subprocess.Popen([sys.executable, "-c", code, str(endpoint)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert process.stdout.readline().strip() == "ready"
            pid = process.pid if failure != "peer-pid" else process.pid + 1000000
            owner = {"pid": pid, "startTicks": "123", "socket": endpoint}
            current = {**owner, "startTicks": "456"} if failure == "start-ticks" else owner
            with patch.object(module, "desktop_instance", side_effect=[owner, current]):
                result = module.focus_desktop_instance({})
            output, errors = process.communicate(timeout=5)
            assert process.returncode == 0, errors
            received = json.loads(output)["received"]
            if not failure:
                assert result == process.pid and json.loads(received) == {"argv": []}
            else:
                assert result is None and received == ""
        finally:
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)


@pytest.fixture
def cleanup_manager(manager):
    with patch("linux.ai.chatgpt_web_bridge.Bridge.launcher_active", return_value=False), \
         patch("linux.ai.chatgpt_web_bridge.Runner.port_in_use", return_value=False):
        yield manager


def test_delete_one_preserves_primary_other_account_and_private_recovery(cleanup_manager):
    m = cleanup_manager
    a, b = m.add("A"), m.add("B")
    for row in (a, b):
        m.prepare_native(row)
        (m.native_home(row) / "auth.json").write_text("private-token-fixture")
        m.shortcuts(row["id"])
    primary = m.native_home(m.get("current"))
    primary.mkdir()
    (primary / "auth.json").write_text("primary-sentinel")
    web = m.bridge(m.get("current")).paths.root
    web.mkdir(parents=True)
    (web / "state.json").write_text("primary-web-sentinel")
    preview = m.remove(a["id"], dry_run=True)
    assert preview["selected"] == 1 and preview["removed"] == 0
    assert m.profile_base(a).is_dir() and len(m.rows()) == 2
    assert not (m.root / "removed").exists()
    result = m.remove(a["id"])
    assert result["removed"] == 1 and result["primaryWebPreserved"]
    assert [r["id"] for r in m.rows()] == [b["id"]]
    assert not m.profile_base(a).exists() and m.profile_base(b).is_dir()
    assert not list((m.data / "applications").glob(f"*{a['id']}*"))
    assert (primary / "auth.json").read_text() == "primary-sentinel"
    assert (web / "state.json").read_text() == "primary-web-sentinel"
    recovery = Path(result["recovery"])
    assert recovery.stat().st_mode & 0o777 == 0o700
    assert next(recovery.rglob("auth.json")).read_text() == "private-token-fixture"
    assert "private-token-fixture" not in json.dumps(result)
    with pytest.raises(ProfileError, match="protegidos"):
        m.remove("current")


def test_clear_all_includes_archived_and_cleans_autostart_and_runtime(cleanup_manager):
    m = cleanup_manager
    a, b = m.add("A"), m.add("B")
    m.prepare_native(a)
    m.archive(b["id"])
    bridge = m.bridge(a)
    bridge.paths.managed_autostart.parent.mkdir(parents=True)
    bridge.paths.managed_autostart.write_text(bridge.autostart_entry_text())
    bridge.paths.runtime.mkdir(parents=True)
    (bridge.paths.runtime / "lock").write_text("stale")
    desktop_runtime = Path(m.env["XDG_RUNTIME_DIR"]) / "codex-desktop/instances/port-22104"
    desktop_runtime.mkdir(parents=True)
    stale_socket = socket.socket(socket.AF_UNIX)
    # A real stale socket must be unlinked, never copied into persistent backup.
    with tempfile.TemporaryDirectory(prefix="delete-sock-") as directory:
        endpoint = Path(directory) / "stale.sock"
        stale_socket.bind(str(endpoint))
        stale_socket.close()
        endpoint.rename(desktop_runtime / "launch-action.sock")
    result = m.remove(all_custom=True)
    assert result["removed"] == 2 and m.rows() == []
    assert not bridge.paths.managed_autostart.exists()
    assert not bridge.paths.runtime.exists() and not desktop_runtime.exists()
    assert m.remove(all_custom=True)["removed"] == 0
    assert m.add("Fresh")["id"] not in {a["id"], b["id"]}


def test_clear_all_preflights_every_profile_before_any_mutation(cleanup_manager):
    m = cleanup_manager
    a, b = m.add("A"), m.add("B")
    m.prepare_native(a)
    original = m.registry.read_bytes()
    with patch.object(m, "_profile_processes", side_effect=[[], [123]]):
        with pytest.raises(ProfileError, match="em uso"):
            m.remove(all_custom=True)
    assert m.registry.read_bytes() == original and m.profile_base(a).is_dir()
    assert not (m.root / "removed").exists()


def test_delete_rejects_redirects_and_foreign_shortcuts(cleanup_manager):
    m = cleanup_manager
    row = m.add("A")
    m.prepare_native(row)
    foreign = m.data / "applications" / f"phasezero-codex-{row['id']}-desktop.desktop"
    foreign.parent.mkdir(parents=True)
    foreign.write_text("user-owned file")
    with pytest.raises(ProfileError, match="terceiros"):
        m.remove(row["id"])
    assert foreign.read_text() == "user-owned file"
    foreign.unlink()
    foreign.symlink_to(m.registry)
    with pytest.raises(ProfileError, match="simbólico"):
        m.remove(row["id"])
    assert len(m.rows()) == 1


def test_delete_rolls_back_moved_files_if_registry_save_fails(cleanup_manager):
    m = cleanup_manager
    row = m.add("A")
    m.prepare_native(row)
    original = m.registry.read_bytes()
    with patch.object(m, "_save", side_effect=OSError("write failed")):
        with pytest.raises(OSError, match="write failed"):
            m.remove(row["id"])
    assert m.registry.read_bytes() == original
    assert m.native_home(row).is_dir()


def test_real_live_profile_process_blocks_delete_without_sending_signals(cleanup_manager):
    m = cleanup_manager
    row, other = m.add("A"), m.add("B")
    m.prepare_native(row)
    child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)"], env=m.profile_env(row))
    try:
        assert child.pid in m._profile_processes(row)
        assert child.pid not in m._profile_processes(other)
        with patch("os.kill", side_effect=AssertionError("must not kill")):
            with pytest.raises(ProfileError, match="em uso"):
                m.remove(row["id"])
        assert child.poll() is None and len(m.rows()) == 2
    finally:
        child.terminate()
        child.wait(timeout=5)



def test_hidden_environment_does_not_hide_profile_argv(cleanup_manager):
    m = cleanup_manager
    row = m.add("A")
    child = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(30)",
                              f"--user-data-dir={m.profile_base(row)}/browser"])
    read_bytes = Path.read_bytes
    def restricted(path):
        if str(path) == f"/proc/{child.pid}/environ":
            raise PermissionError("non-dumpable environment")
        return read_bytes(path)
    try:
        with patch.object(Path, "read_bytes", restricted):
            assert child.pid in m._profile_processes(row)
    finally:
        child.terminate()
        child.wait(timeout=5)


def test_cli_remove_redacted_preview_and_execution_use_same_selection(cleanup_manager):
    m = cleanup_manager
    row = m.add("Private nickname")
    script = Path(__file__).resolve().parents[1] / "linux/ai/codex_profiles.py"
    command = [sys.executable, str(script), "--redacted", "remove", "--id", row["id"]]
    preview = subprocess.run([*command, "--dry-run"], env=m.env, text=True, capture_output=True, timeout=15)
    assert preview.returncode == 0, preview.stdout + preview.stderr
    result = json.loads(preview.stdout)
    assert result["selected"] == 1 and result["removed"] == 0 and result["dryRun"]
    assert len(m.rows()) == 1
    run = subprocess.run(command, env=m.env, text=True, capture_output=True, timeout=15)
    assert run.returncode == 0, run.stdout + run.stderr
    assert json.loads(run.stdout)["removed"] == 1 and m.rows() == []
    assert "Private nickname" not in preview.stdout + run.stdout



def test_runtime_cleanup_failure_is_reported_without_false_success(cleanup_manager):
    m = cleanup_manager
    row = m.add("A")
    runtime = m.bridge(row).paths.runtime
    runtime.mkdir(parents=True)
    with patch("shutil.rmtree", side_effect=OSError("busy runtime")):
        result = m.remove(row["id"])
    assert result["removed"] == 1 and m.rows() == []
    assert result["ok"] is False and result["runtimeRemaining"] == [str(runtime)]



def test_primary_is_first_and_all_64_custom_colors_are_unique(manager):
    rows = [manager.add(f"Account {i}") for i in range(64)]
    colors = [r["color"] for r in manager.status()["profiles"]]
    from linux.ai.codex_profiles import COLORS
    assert manager.status()["profiles"][0]["id"] == "current"
    assert len(colors) == len(set(colors)) == 65
    assert len({COLORS[key] for key in colors}) == 65
    with pytest.raises(ProfileError, match="Limite"):
        manager.add("Too many")


def test_colors_cannot_be_reused_or_reserved_even_for_archived_profiles(manager):
    a, b = manager.add("A", "verde"), manager.add("B", "roxo")
    manager.archive(a["id"])
    for operation in [lambda: manager.add("C", "verde"),
                      lambda: manager.add("C", "azul"),
                      lambda: manager.rename(b["id"], "B", "verde"),
                      lambda: manager.rename("current", "Principal", "laranja")]:
        with pytest.raises(ProfileError, match="[Cc]or"):
            operation()
    assert manager.get(a["id"])["color"] == "verde"


def test_shortcut_names_icons_and_hidden_auxiliary_entries(manager):
    from xml.etree import ElementTree as ET
    row = manager.add("Pessoal", "verde")
    manager.shortcuts(row["id"])
    menu = manager.data / "applications"
    desktop = menu / manager.entry_name(row, "desktop")
    web = menu / manager.entry_name(row, "web")
    assert "Name=Codex Pessoal\n" in desktop.read_text()
    assert "Name=Codex Web Pessoal\n" in web.read_text()
    assert "NoDisplay=true" not in web.read_text() + desktop.read_text()
    for surface in ("cli", "browser"):
        assert "NoDisplay=true" in (menu / manager.entry_name(row, surface)).read_text()
    svg = (manager.profile_base(row) / "account.svg").read_text()
    assert ET.fromstring(svg).find("{http://www.w3.org/2000/svg}path") is not None
    assert "<text" not in svg and "<rect" not in svg
    assert svg != manager.icon_svg(manager.get("current"))


def test_organize_preserves_primary_exec_hides_only_known_codex_duplicates(manager):
    menu = manager.data / "applications"
    menu.mkdir(parents=True)
    primary = menu / "codex-desktop.desktop"
    original = ('[Desktop Entry]\nName=ChatGPT\nName[pt]=Antigo\n'
                'Exec=/usr/bin/codex-desktop %u\nIcon=old\n'
                'MimeType=x-scheme-handler/codex;\nActions=new-window;\n'
                '\n[Desktop Action new-window]\nName=New Window\nExec=/usr/bin/codex-desktop --new-instance\n')
    primary.write_text(original)
    old = menu / "appimagekit_123-Codex.desktop"
    old.write_text('[Desktop Entry]\nName=Codex Desktop old\nX-AppImage-Old-Name=Codex Desktop\n'
                   'Exec=/home/user/codex-desktop-old.AppImage %u\n')
    other = menu / "other.desktop"
    other.write_text('[Desktop Entry]\nName=Other\nExec=other\n')
    bridge = manager.bridge(manager.get("current"))
    bridge.paths.root.mkdir(parents=True)
    bridge.save_state({"optIn": {"fixture": True}})
    tools = menu / "phasezero-chatgpt-web-tools.desktop"
    tools.write_text('[Desktop Entry]\nName=ChatGPT Web tools\nExec=old-tools\n'
                     'X-PhaseZero-Managed=chatgpt-web\n')
    result = manager.organize()
    assert result["organized"] and result["hiddenDuplicates"] == 2
    text = primary.read_text()
    assert "Name=Codex Principal\n" in text and "Name[pt]" not in text
    assert "Exec=/usr/bin/codex-desktop %u\n" in text
    assert "Exec=/usr/bin/codex-desktop --new-instance\n" in text
    assert "MimeType=x-scheme-handler/codex;" in text
    assert "NoDisplay=true" in old.read_text() and "NoDisplay=true" in tools.read_text()
    assert "NoDisplay" not in other.read_text()
    assert bridge.load_state()["accountShortcuts"] == "codex-profiles"
    assert bridge.shortcuts_status()["owner"] == "codex-profiles"
    assert bridge.shortcuts_status()["state"] == "installed"
    before = {p.name: p.read_bytes() for p in menu.glob("*.desktop")}
    assert bridge.restore_shortcuts() is False
    assert bridge.shortcuts_install()["state"] == "installed"
    manager.organize()
    assert before == {p.name: p.read_bytes() for p in menu.glob("*.desktop")}


def test_organize_migrates_old_color_collisions_without_changing_profile_ids(manager):
    a, b = manager.add("A", "verde"), manager.add("B", "roxo")
    document = json.loads(manager.registry.read_text())
    for row in document["profiles"]:
        row["color"] = "azul"
    document["current"]["label"] = "Conta atual"
    manager.registry.write_text(json.dumps(document))
    manager.organize()
    rows = manager.status()["profiles"]
    assert rows[0]["label"] == "Principal"
    assert {r["id"] for r in rows} == {"current", a["id"], b["id"]}
    assert len({r["color"] for r in rows}) == 3



def test_organize_preview_never_creates_state_or_shortcuts(manager):
    result = manager.organize(dry_run=True)
    assert result["dryRun"] and result["primaryFirst"]
    assert result["visibleLaunchersPerActiveAccount"] == 2
    assert not manager.root.exists() and not (manager.data / "applications").exists()



def test_account_shortcut_ownership_does_not_block_web_opt_out(manager):
    bridge = manager.bridge(manager.get("current"))
    bridge.paths.root.mkdir(parents=True)
    bridge.save_state({"optIn": {"fixture": True}})
    manager.shortcuts("current")
    native = manager.data / "applications/codex-desktop.desktop"
    original_native = native.read_bytes()
    web = manager.data / "applications/phasezero-chatgpt-web.desktop"
    assert web.exists()
    with patch.object(bridge, "launcher_active", return_value=False), \
         patch.object(bridge, "route_status", return_value={"active": False}):
        assert bridge.opt_out() == {"optIn": False}
    assert not web.exists() and native.read_bytes() == original_native
    assert bridge.shortcuts_status()["state"] == "off"
    assert bridge.restore_shortcuts() is False
    with pytest.raises(BridgeError, match="painel"):
        bridge.shortcuts_install()
    manager.shortcuts("current")
    assert web.exists() and bridge.shortcuts_status()["state"] == "installed"
    assert not bridge.load_state().get("optIn")



def test_primary_legacy_aliases_retire_but_browser_login_stays_in_place(manager):
    menu = manager.data / "applications"
    menu.mkdir(parents=True)
    alias = menu / "phasezero-codex-current-desktop.desktop"
    alias.write_text('[Desktop Entry]\nName=Old account\nX-PhaseZero-Managed=codex-profiles\n')
    browser = manager.runtime_root / "current/browser"
    browser.mkdir(parents=True)
    (browser / "Cookies").write_text("private-browser-sentinel")
    manager.shortcuts("current")
    assert not alias.exists()
    assert (menu / "codex-desktop.desktop").exists()
    assert manager.browser_home(manager.get("current")) == browser
    assert (browser / "Cookies").read_text() == "private-browser-sentinel"



def test_native_and_web_appearance_follow_color_preserving_primary_and_other_preferences(manager):
    import tomllib
    primary = manager.native_home(manager.get("current")) / "config.toml"
    primary.parent.mkdir()
    primary.write_text('[desktop]\nappearanceTheme="system"\n# primary untouched\n')
    primary_before = primary.read_bytes()
    row = manager.add("A", "verde")
    manager.prepare_native(row)
    native = manager.native_home(row) / "config.toml"
    bridge = manager.bridge(row)
    bridge.seed_codex_home()
    for path in (native, bridge.paths.codex_config):
        config = tomllib.loads(path.read_text())
        assert config["desktop"]["appearanceLightChromeTheme"]["accent"] == "#15803d"
        assert config["desktop"]["appearanceDarkChromeTheme"]["accent"] == "#15803d"
        assert config["desktop"]["appearanceDarkChromeTheme"]["surface"] == "#174227"
        assert config["desktop"]["appearanceLightChromeTheme"]["surface"] == "#dcece2"
    # The helper also accepts the nested-table format produced by the app.
    from linux.ai.chatgpt_web_bridge import sync_account_appearance
    custom = '[desktop]\nappearanceTheme="light"\nsansFontSize=19\n[desktop.appearanceDarkChromeTheme]\nsurface="#202428"\n'
    native.write_text(custom)
    manager.rename(row["id"], "A", "laranja")
    after = tomllib.loads(native.read_text())["desktop"]
    assert after["appearanceTheme"] == "light" and after["sansFontSize"] == 19
    assert after["appearanceDarkChromeTheme"]["surface"] == "#5c2813"
    assert after["appearanceDarkChromeTheme"]["accent"] == "#c2410c"
    assert tomllib.loads(bridge.paths.codex_config.read_text())["desktop"]["appearanceLightChromeTheme"]["accent"] == "#c2410c"
    assert primary.read_bytes() == primary_before
    assert manager.sync_appearance(manager.get("current")) == 0
    assert manager.sync_appearance(manager.get(row["id"])) == 0


def test_appearance_preserves_unrelated_toml_semantics_and_is_idempotent():
    import tomllib
    from linux.ai.chatgpt_web_bridge import account_appearance_text
    original = ('# retain this comment\nmodel="test"\napproval_policy="on-request"\n'
                '[projects."/space path"]\ntrust_level="trusted"\n'
                '[desktop]\nappearanceTheme="dark"\n'
                '[desktop.appearanceLightChromeTheme.fonts]\nui="Inter"\n'
                '[mcp_servers.example]\nurl="http://localhost:1234/mcp"\n')
    result = account_appearance_text(original, "#15803d")
    before = tomllib.loads(original)
    after = tomllib.loads(result)
    for key in before:
        if key != "desktop":
            assert before[key] == after[key]
    assert "# retain this comment" in result
    assert after["desktop"]["appearanceLightChromeTheme"]["fonts"]["ui"] == "Inter"
    assert account_appearance_text(result, "#15803d") == result


def test_account_surfaces_remain_distinct_and_default_text_readable():
    import tomllib
    from linux.ai.chatgpt_web_bridge import account_appearance_text
    from linux.ai.codex_profiles import COLORS

    def luminance(colour):
        channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                  for c in channels]
        return sum(c * weight for c, weight in zip(linear, (0.2126, 0.7152, 0.0722)))

    surfaces = {"Light": set(), "Dark": set()}
    for colour in COLORS.values():
        desktop = tomllib.loads(account_appearance_text("", colour))["desktop"]
        for variant in surfaces:
            theme = desktop[f"appearance{variant}ChromeTheme"]
            surface, ink = luminance(theme["surface"]), luminance(theme["ink"])
            assert (max(surface, ink) + 0.05) / (min(surface, ink) + 0.05) >= 4.5
            surfaces[variant].add(theme["surface"])
    assert all(len(values) == len(COLORS) for values in surfaces.values())


def test_appearance_rejects_corruption_and_ambiguous_syntax_without_writes(manager):
    from linux.ai.chatgpt_web_bridge import sync_account_appearance
    row = manager.add("A")
    manager.prepare_native(row)
    path = manager.native_home(row) / "config.toml"
    for content in ['broken [', 'desktop={appearanceTheme="light"}\n',
                    '[desktop]\nappearanceDarkChromeTheme="wrong-type"\n']:
        path.write_text(content)
        with pytest.raises(BridgeError, match="preservada"):
            sync_account_appearance(path, "#15803d")
        assert path.read_text() == content
        with pytest.raises(ProfileError, match="preservada"):
            manager.sync_appearance(row)
        assert path.read_text() == content


def test_web_appearance_reloads_saved_account_color_without_inherited_environment(manager):
    import tomllib
    row = manager.add("A", "verde")
    bridge = manager.bridge(row)
    bridge.seed_codex_home()
    bridge.save_state({"accountAppearanceAccent": "#c2410c"})
    bridge.env.pop("PZ_CHATGPT_WEB_ACCOUNT_COLOR")
    assert bridge.sync_account_theme()
    assert tomllib.loads(bridge.paths.codex_config.read_text())["desktop"]["appearanceDarkChromeTheme"]["accent"] == "#c2410c"
    assert not bridge.sync_account_theme()
