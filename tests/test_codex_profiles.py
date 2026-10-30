from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
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
    manager.rename("current", "Conta principal", "verde")
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
    assert result["count"] == 8
    native = manager.native_home(row)
    manager.prepare_native(row)
    (native / "auth.json").write_text("private-A")
    entries = list(desktop.glob("*.desktop"))
    assert len(entries) == 4
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
         patch("subprocess.Popen", side_effect=lambda command, **kw:
               spawned.append((command, kw["env"])) or type("Child", (), {"pid": 321})()):
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
