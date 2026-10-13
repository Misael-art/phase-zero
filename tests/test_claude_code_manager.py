from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "linux/ai/claude_code_manager.py"
SPEC = importlib.util.spec_from_file_location("claude_code_manager", MODULE_PATH)
assert SPEC and SPEC.loader
CC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CC)


class ClaudeCodeManagerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pz-claude-test-")
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.old_env = os.environ.copy()
        self.old_cwd = Path.cwd()
        os.chdir(self.home)
        os.environ.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "XDG_DATA_HOME": str(self.home / ".local/share"),
                "PZ_LOCAL_BIN": str(self.home / ".local/bin"),
                "PZ_CC_INSTALLER_ROOT": str(self.home / ".local/share/cc-installer"),
                "PZ_SYSTEMCTL_COMMAND": "/nonexistent/systemctl",
                "PZ_SS_COMMAND": "/nonexistent/ss",
                "PZ_BONSAI_NETWORK_PREFLIGHT": "skip",
                "PATH": f"{self.bin}:/usr/bin:/bin",
            }
        )
        self.claude = self._script(
            "claude",
            """#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo '2.1.220 (Claude Code)'; exit 0; fi
if [ "${1:-}" = "auth" ]; then echo '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty","email":"hidden@example.test"}'; exit 0; fi
python3 - <<'PY'
import json, os
print(json.dumps({k: os.environ.get(k) for k in ("ANTHROPIC_API_KEY","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_BASE_URL","ANTHROPIC_MODEL")}))
PY
""",
        )
        self.bonsai = self._script(
            "bonsai",
            """#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo '0.4.19'; exit 0; fi
if [ -n "${PZ_TEST_BONSAI_ROUTE:-}" ]; then printf '%s|%s\n' "$PWD" "${ENABLE_CLAUDEAI_MCP_SERVERS:-unset}" > "$PZ_TEST_BONSAI_ROUTE"; fi
echo "bonsai:$*"
""",
        )
        os.environ["PZ_CLAUDE_COMMAND"] = str(self.claude)
        os.environ["PZ_BONSAI_COMMAND"] = str(self.bonsai)
        bonsai_cfg = self.home / ".config/bonsai-cli-nodejs/config.json"
        bonsai_cfg.parent.mkdir(parents=True)
        bonsai_cfg.write_text("credential-store", encoding="utf-8")
        os.chmod(bonsai_cfg, 0o600)

    def tearDown(self) -> None:
        os.chdir(self.old_cwd)
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def _script(self, name: str, body: str) -> Path:
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        os.chmod(path, 0o700)
        return path

    def _settings(self) -> Path:
        path = self.home / ".claude/settings.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                {
                    "env": {
                        "ANTHROPIC_API_KEY": "super-secret-must-not-leak",
                        "ANTHROPIC_BASE_URL": "http://127.0.0.1:20128/v1",
                        "ANTHROPIC_DEFAULT_SONNET_MODEL": "proxy-combo",
                        "KEEP_ME": "yes",
                    },
                    "hooks": {
                        "SessionStart": [
                            {"hooks": [{"type": "command", "command": "/missing/ai-memory hook"}]},
                            {"hooks": [{"type": "command", "command": "/bin/true"}]},
                        ]
                    },
                }
            ),
            encoding="utf-8",
        )
        os.chmod(path, 0o600)
        return path

    def test_status_is_redacted_and_classifies_orphan(self) -> None:
        self._settings()
        state = CC.Manager().status()
        rendered = json.dumps(state)
        self.assertNotIn("super-secret-must-not-leak", rendered)
        self.assertTrue(state["claude"]["auth"]["loggedIn"])
        self.assertEqual("ok", state["claude"]["auth"]["probeStatus"])
        self.assertEqual("subscription", state["selectedAuth"])
        self.assertIn("installations", state)
        self.assertIn("authentications", state)
        self.assertIn("ports", state)
        self.assertIn("hooks", state)
        self.assertIn("recommendedActions", state)
        self.assertFalse(state["managedSessionLaunch"]["enabled"])
        self.assertEqual(
            "account-bound-consumer-grant-unavailable",
            state["managedSessionLaunch"]["blockedReason"],
        )
        self.assertTrue(state["routeCapabilities"]["subscription"]["claudeAiConnectors"])
        self.assertFalse(state["routeCapabilities"]["bonsai"]["claudeAiConnectors"])
        self.assertFalse(state["routeCapabilities"]["bonsai"]["connectorsWarningExpected"])
        self.assertTrue(state["routeCapabilities"]["bonsai"]["upstreamDirectCommandMayWarn"])
        self.assertTrue(state["routeCapabilities"]["bonsai"]["phaseZeroLauncherSuppressesWarning"])
        self.assertEqual(1, sum(item["state"] == "orphan" for item in state["configuration"]["hooks"]))

    def test_live_verify_reports_grant_block_without_sending_prompt(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        with mock.patch.object(subprocess, "run", wraps=subprocess.run) as run_spy:
            result = manager.verify("subscription", None, live=True)
        self.assertTrue(result["ok"], "configuration verification remains separate from launch authorization")
        self.assertFalse(result["managedLaunchEnabled"])
        self.assertEqual(
            "account-bound-consumer-grant-unavailable",
            result["live"]["subscription"]["blockedReason"],
        )
        self.assertIsNone(result["live"]["subscription"]["passed"])
        client_launches = [
            call for call in run_spy.call_args_list
            if call.args and isinstance(call.args[0], list)
            and Path(call.args[0][0]).name == "claude-subscription"
        ]
        self.assertEqual([], client_launches, "live verify must not run a provider-backed client")

    def test_missing_claude_backend_is_not_reported_as_logged_out(self) -> None:
        os.environ["PZ_CLAUDE_COMMAND"] = str(self.bin / "missing-claude")
        auth = CC.Manager().claude_info()["auth"]
        self.assertIsNone(auth["loggedIn"])
        self.assertEqual("backend-unavailable", auth["probeStatus"])

    def test_timed_out_claude_auth_probe_stays_unknown(self) -> None:
        with mock.patch.object(CC, "run_capture", side_effect=[
            (0, "2.1.220 (Claude Code)", ""), (124, "", "timed out"),
        ]):
            auth = CC.Manager().claude_info()["auth"]
        self.assertIsNone(auth["loggedIn"])
        self.assertEqual("timeout", auth["probeStatus"])

    def test_dry_run_leaves_no_trace(self) -> None:
        self._settings()
        manager = CC.Manager()
        result = manager.install("subscription", None, dry_run=True, yes=True, verbose=False)
        self.assertTrue(result["dryRun"])
        self.assertFalse(manager.data_root.exists())
        self.assertFalse((self.home / ".local/bin/claude-subscription").exists())

    def test_install_isolates_routes_and_is_idempotent(self) -> None:
        settings = self._settings()
        bashrc = self.home / ".bashrc"
        bashrc.write_text("export ANTHROPIC_API_KEY=legacy-secret\nexport KEEP=1\n", encoding="utf-8")
        manager = CC.Manager()
        result = manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        self.assertEqual("complete", result["status"])
        manifest_data = json.loads(Path(result["manifest"]).read_text(encoding="utf-8"))
        self.assertIn("packages", manifest_data)
        self.assertIn("processes", manifest_data)
        self.assertIn("systemd", manifest_data)
        repaired = json.loads(settings.read_text(encoding="utf-8"))
        self.assertEqual({"KEEP_ME": "yes"}, repaired["env"])
        commands = list(manager._hook_commands(repaired["hooks"]))
        self.assertEqual(["/bin/true"], commands)
        self.assertTrue(
            all(
                isinstance(group.get("hooks"), list) and group["hooks"]
                for groups in repaired["hooks"].values()
                for group in groups
            )
        )
        self.assertIn("[cc-installer:quarantine]", bashrc.read_text(encoding="utf-8"))
        self.assertIn(CC.SHIM_PATH_BLOCK_START, bashrc.read_text(encoding="utf-8"))
        self.assertTrue(bashrc.read_text(encoding="utf-8").rstrip().endswith(CC.SHIM_PATH_BLOCK_END))
        bonsai_dir = self.home / ".config/bonsai-cli-nodejs"
        self.assertEqual(0o700, stat.S_IMODE(bonsai_dir.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE((bonsai_dir / "config.json").stat().st_mode))

        launchers = [self.home / ".local/bin" / name for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai")]
        before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in launchers}
        env = os.environ.copy()
        env.update(
            {
                "ANTHROPIC_API_KEY": "bad",
                "ANTHROPIC_AUTH_TOKEN": "bad",
                "ANTHROPIC_BASE_URL": "http://bad",
                "ANTHROPIC_MODEL": "bad",
            }
        )
        for launcher in launchers[:3]:
            with self.subTest(launcher=launcher.name):
                probe = subprocess.run(
                    [str(launcher), "--probe"], text=True, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, env=env, check=False,
                )
                self.assertNotEqual(0, probe.returncode)
                self.assertIn("account-bound consumer grant", probe.stderr)
                self.assertEqual("", probe.stdout)

        second = manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        self.assertEqual("complete", second["status"])
        after = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in launchers}
        self.assertEqual(before, after)

    def test_bonsai_launcher_delegates_to_fail_closed_manager(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        project = self.root / "safe-project"
        project.mkdir()
        proc = subprocess.run(
            [str(self.home / ".local/bin/claude-bonsai"), "--probe"],
            cwd=project,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("account-bound consumer grant", proc.stderr)
        self.assertEqual("", proc.stdout)

    def test_bonsai_route_uses_explicit_reviewed_working_directory(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        project = self.root / "reviewed-project"
        project.mkdir()
        receipt = self.root / "bonsai-route.txt"
        os.environ["PZ_TEST_BONSAI_ROUTE"] = str(receipt)
        try:
            with self.assertRaisesRegex(RuntimeError, "account-bound consumer grant"):
                manager.run_route("bonsai", [], str(project))
        finally:
            os.environ.pop("PZ_TEST_BONSAI_ROUTE", None)
        self.assertFalse(receipt.exists(), "no Bonsai client process may start without a grant")
        parsed = CC.build_parser().parse_args(["run", "bonsai", "--cwd", str(project)])
        self.assertEqual(str(project), parsed.cwd)
        self.assertTrue(manager.preflight("bonsai", str(project))["ok"])
        self.assertFalse(manager.preflight("bonsai", str(self.home))["ok"])
        (project / ".env").write_text("fixture-only\n", encoding="utf-8")
        blocked = manager.preflight("bonsai", str(project))
        self.assertFalse(blocked["ok"])
        self.assertEqual(["dotenv"], blocked["workspace"]["blockers"])
        with self.assertRaisesRegex(RuntimeError, "account-bound consumer grant"):
            manager.run_route("bonsai", [], str(project))

    def test_all_managed_claude_routes_fail_closed_before_process_creation(self) -> None:
        manager = CC.Manager()
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("process must not start")):
            for route in ("subscription", "bonsai", "proxy"):
                with self.subTest(route=route):
                    with self.assertRaisesRegex(RuntimeError, "no client process was started"):
                        manager.run_route(route, ["--version"], str(self.home))

    def test_bonsai_shim_blocks_managed_launch_without_connection_grant(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        shim = self.home / ".local/bin/bonsai"
        version = subprocess.run([str(shim), "--version"], text=True, stdout=subprocess.PIPE, check=True)
        self.assertEqual("0.4.19", version.stdout.strip())

        project = self.root / "shim-project"
        project.mkdir()
        receipt = self.root / "shim-route.txt"
        env = os.environ.copy()
        env["PZ_TEST_BONSAI_ROUTE"] = str(receipt)
        direct = subprocess.run(
            [str(shim), "start", "--cwd", str(project), "--", "--probe"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            check=False,
        )
        self.assertNotEqual(0, direct.returncode)
        self.assertIn("account-bound consumer grant", direct.stderr)
        self.assertFalse(receipt.exists(), "the shim must not start Bonsai without a grant")

        receipt.unlink(missing_ok=True)
        env["BONSAI_ROUTE"] = "9router"
        fallback = subprocess.run(
            [str(shim), "start", "--cwd", str(project)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            check=False,
        )
        self.assertNotEqual(0, fallback.returncode)
        self.assertIn("account-bound consumer grant", fallback.stderr)
        self.assertFalse(receipt.exists())

    def test_network_error_classification_covers_enotimp_and_gateway(self) -> None:
        enotimp = CC.Manager.classify_network_failure("ENOTIMP")
        self.assertEqual("dns-not-implemented", enotimp["class"])
        self.assertTrue(enotimp["transient"])
        self.assertEqual("rate-limit", CC.Manager.classify_network_failure(None, 429)["class"])
        self.assertEqual("upstream-gateway", CC.Manager.classify_network_failure(None, 503)["class"])

    def test_bonsai_absent_is_reported_without_touching_claude(self) -> None:
        self.bonsai.unlink()
        (self.home / ".config/bonsai-cli-nodejs/config.json").unlink()
        info = CC.Manager().bonsai_info()
        self.assertFalse(info["installed"])
        self.assertIsNone(info["authenticated"])
        self.assertTrue(CC.Manager().claude_info()["auth"]["loggedIn"])

    def test_bonsai_unpublished_from_npm_gives_actionable_error(self) -> None:
        # @bonsai-ai/cli returns 404 on the npm registry since 2026-09.
        self.bonsai.unlink()
        manager = CC.Manager()
        tx = mock.MagicMock()
        with mock.patch.object(manager, "_bonsai_upstream", return_value=None), mock.patch.object(
            manager, "node_info", return_value={"npm": "/usr/bin/npm", "node": "/usr/bin/node", "major": 24}
        ), mock.patch.object(CC, "run_capture", return_value=(1, "", "npm error code E404\nnpm error 404 Not Found")):
            with self.assertRaisesRegex(RuntimeError, "indisponível no npm"):
                manager._ensure_bonsai(tx)

    def test_bonsai_status_flags_runner_that_fakes_latest(self) -> None:
        # AISR-006: a runner that answers npm "latest" with the installed version
        # keeps Bonsai pinned forever; status must say so.
        runner = self.home / "runner/bonsai-managed"
        runner.parent.mkdir(parents=True)
        runner.write_text(
            "#!/usr/bin/env bash\nexport PZ_BONSAI_INSTALLED_VERSION=0.4.19\n"
            "exec node --require latest-fail-open.cjs cli.js \"$@\"\n",
            encoding="utf-8",
        )
        self.assertEqual("upstream", CC.Manager._bonsai_update_check(str(self.bonsai)))
        shim = self.home / "shim/bonsai"
        shim.parent.mkdir(parents=True)
        shim.write_text(f"#!/usr/bin/env bash\nupstream={runner}\nexec \"$upstream\" \"$@\"\n", encoding="utf-8")
        self.assertEqual("forged", CC.Manager._bonsai_update_check(str(shim)))
        self.assertEqual("not-installed", CC.Manager._bonsai_update_check(None))

    def test_repair_removes_empty_hook_envelopes(self) -> None:
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            json.dumps({"hooks": {"SessionStart": [{"matcher": ""}], "Stop": [{"matcher": "", "hooks": []}]}}),
            encoding="utf-8",
        )
        result = CC.Manager().install("subscription", None, dry_run=False, yes=True, verbose=False)
        self.assertEqual("complete", result["status"])
        repaired = json.loads(settings.read_text(encoding="utf-8"))
        self.assertNotIn("hooks", repaired)

    def test_router_health_requires_correlated_install_and_port_owner(self) -> None:
        manager = CC.Manager()
        foreign = {
            "port": 20128,
            "listening": True,
            "address": "127.0.0.1",
            "pid": 4242,
            "command": "/opt/foreign/server",
        }
        with mock.patch.object(manager, "listener_info", return_value=foreign), mock.patch.object(
            manager, "url_healthy", return_value=True
        ):
            state = manager.router_status()
        self.assertFalse(state["healthy"])
        self.assertEqual("unknown", state["owner"])

        dead = dict(foreign, command=str(self.home / ".npm-global/lib/node_modules/9router/server"))
        with mock.patch.object(manager, "listener_info", return_value=dead), mock.patch.object(
            manager, "url_healthy", return_value=False
        ):
            self.assertFalse(manager.router_status()["healthy"])

    def test_legacy_router_duplicate_fixture_is_conflict(self) -> None:
        autostart = self.home / ".config/autostart/9router.desktop"
        autostart.parent.mkdir(parents=True)
        autostart.write_text("[Desktop Entry]\nX-GNOME-Autostart-enabled=true\n", encoding="utf-8")
        manager = CC.Manager()
        listener = {
            "port": 20128,
            "listening": True,
            "address": "0.0.0.0",
            "pid": 4343,
            "command": str(self.home / ".npm-global/lib/node_modules/9router/next-server"),
        }
        with mock.patch.object(manager, "listener_info", return_value=listener), mock.patch.object(
            manager, "url_healthy", return_value=True
        ):
            state = manager.router_status()
        self.assertTrue(state["legacyStartupConflict"])
        self.assertTrue(state["healthy"])
        self.assertFalse(state["loopbackOnly"])

    def test_rollback_restores_bytes_and_refuses_later_change(self) -> None:
        settings = self._settings()
        original = settings.read_bytes()
        manager = CC.Manager()
        result = manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        manifest = Path(result["manifest"])
        launcher = self.home / ".local/bin/claude-subscription"
        launcher.write_text("changed later\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            CC.restore_manifest(manifest)
        rolled_back = CC.restore_manifest(manifest, force=True)
        self.assertEqual("complete", rolled_back["status"])
        self.assertEqual(original, settings.read_bytes())
        self.assertFalse(launcher.exists())

    def test_rollback_rejects_external_manifest_and_target(self) -> None:
        self._settings()
        result = CC.Manager().install("subscription", None, dry_run=False, yes=True, verbose=False)
        manifest = Path(result["manifest"])
        external = self.root / "downloaded-manifest.json"
        external.write_bytes(manifest.read_bytes())
        os.chmod(external, 0o600)
        with self.assertRaisesRegex(RuntimeError, "outside a managed operation"):
            CC.restore_manifest(external, force=True)

        payload = json.loads(manifest.read_text(encoding="utf-8"))
        self.assertTrue(payload["paths"])
        payload["paths"][0]["path"] = "/etc/passwd"
        CC.atomic_json(manifest, payload, 0o600)
        with self.assertRaisesRegex(RuntimeError, "outside managed user roots"):
            CC.restore_manifest(manifest, force=True)

    def test_injected_failure_after_each_mutable_stage_rolls_back_bytes(self) -> None:
        stages = ("claude", "bonsai", "bonsai-store", "settings", "profiles", "9router-migration", "9router-model", "launchers", "path-precedence")
        for stage in stages:
            with self.subTest(stage=stage):
                settings = self._settings()
                bashrc = self.home / ".bashrc"
                bashrc.write_text("export ANTHROPIC_API_KEY=legacy-secret\nexport KEEP=1\n", encoding="utf-8")
                original_settings = settings.read_bytes()
                original_profile = bashrc.read_bytes()
                os.environ["PZ_CC_FAIL_AFTER"] = stage
                try:
                    with self.assertRaisesRegex(RuntimeError, "injected failure"):
                        CC.Manager().install("subscription", None, dry_run=False, yes=True, verbose=False)
                finally:
                    os.environ.pop("PZ_CC_FAIL_AFTER", None)
                self.assertEqual(original_settings, settings.read_bytes())
                self.assertEqual(original_profile, bashrc.read_bytes())
                for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai"):
                    self.assertFalse((self.home / ".local/bin" / name).exists())

    def test_rollback_restores_recorded_systemd_state(self) -> None:
        log = self.root / "systemctl.log"
        systemctl = self._script(
            "fake-systemctl",
            """#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_TEST_SYSTEMCTL_LOG"
case "$*" in
  *is-active*|*is-enabled*) exit 0 ;;
esac
exit 0
""",
        )
        os.environ["PZ_SYSTEMCTL_COMMAND"] = str(systemctl)
        os.environ["PZ_TEST_SYSTEMCTL_LOG"] = str(log)
        data_root = self.home / ".local/share/cc-installer"
        target = self.home / ".config/example.conf"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"before\n")
        tx = CC.Transaction(data_root, "systemd-test")
        tx.backup(target)
        tx.record_service("example.service")
        target.write_bytes(b"after\n")
        tx.complete({}, "test\n")
        CC.restore_manifest(tx.manifest_path)
        self.assertEqual(b"before\n", target.read_bytes())
        calls = log.read_text(encoding="utf-8")
        self.assertIn("disable --now example.service", calls)
        self.assertIn("enable example.service", calls)
        self.assertIn("start example.service", calls)


if __name__ == "__main__":
    unittest.main()
