from __future__ import annotations

import importlib.util
import json
import os
import shutil
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
        self.desktop_workspace = self.root / "phasezero-workspace"
        self.desktop_workspace.mkdir()
        self.old_env = os.environ.copy()
        self.old_cwd = Path.cwd()
        self.real_node = shutil.which("node")
        if not self.real_node:
            self.skipTest("node unavailable")
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
                "PZ_BONSAI_DESKTOP_CWD": str(self.desktop_workspace),
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
        bonsai_package = self.root / "bonsai-package"
        bonsai_dist = bonsai_package / "dist"
        bonsai_dist.mkdir(parents=True)
        self.bonsai = bonsai_dist / "cli.js"
        self.bonsai.write_text(
            """#!/usr/bin/env node
const fs = require("node:fs");
if (process.argv[2] === "--version") { console.log("0.4.19"); process.exit(0); }
if (process.env.PZ_TEST_BONSAI_ROUTE) fs.writeFileSync(process.env.PZ_TEST_BONSAI_ROUTE, `${process.cwd()}|${process.env.ENABLE_CLAUDEAI_MCP_SERVERS || "unset"}\n`);
console.log(`bonsai:${process.argv.slice(2).join(" ")}`);
""",
            encoding="utf-8",
        )
        os.chmod(self.bonsai, 0o700)
        bonsai_package_json = bonsai_package / "package.json"
        bonsai_package_json.write_text(json.dumps({"name": "@bonsai-ai/cli", "version": "0.4.19"}), encoding="utf-8")
        self.original_bonsai_hashes = dict(CC.BONSAI_EXISTING_HASHES)
        CC.BONSAI_EXISTING_HASHES["0.4.19"] = {
            "cliSha256": CC.file_sha256(self.bonsai),
            "packageSha256": CC.file_sha256(bonsai_package_json),
        }
        os.environ["PZ_CLAUDE_COMMAND"] = str(self.claude)
        os.environ["PZ_BONSAI_COMMAND"] = str(self.bonsai)
        os.environ["PZ_BONSAI_NODE_BIN"] = self.real_node
        bonsai_cfg = self.home / ".config/bonsai-cli-nodejs/config.json"
        self._write_credential_store(bonsai_cfg, 60_000)
        os.chmod(bonsai_cfg, 0o600)

    def tearDown(self) -> None:
        CC.BONSAI_EXISTING_HASHES.clear()
        CC.BONSAI_EXISTING_HASHES.update(self.original_bonsai_hashes)
        os.chdir(self.old_cwd)
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def _script(self, name: str, body: str) -> Path:
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        os.chmod(path, 0o700)
        return path

    def _write_credential_store(self, path: Path, expires_delta_ms: int) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        writer = r'''
const fs=require("node:fs"),crypto=require("node:crypto");
const iv=Buffer.alloc(16,7), encryptionKey=crypto.scryptSync("bonsai-cli","salt",32).toString("hex").slice(0,32);
const key=crypto.pbkdf2Sync(encryptionKey,iv.toString(),10000,32,"sha512"), cipher=crypto.createCipheriv("aes-256-cbc",key,iv);
const payload=Buffer.from(JSON.stringify({accessToken:"fixture",refreshToken:"fixture-refresh",expiresAt:Date.now()+Number(process.argv[2]),apiKey:"fixture-key",apiKeyName:"fixture",apiKeyCreatedAt:1}));
fs.writeFileSync(process.argv[1],Buffer.concat([iv,Buffer.from(":"),cipher.update(payload),cipher.final()]));
'''
        subprocess.run([self.real_node, "-e", writer, str(path), str(expires_delta_ms)], check=True)

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
        self.assertEqual("subscription", state["selectedAuth"])
        self.assertIn("installations", state)
        self.assertIn("authentications", state)
        self.assertIn("ports", state)
        self.assertIn("hooks", state)
        self.assertIn("recommendedActions", state)
        self.assertTrue(state["routeCapabilities"]["subscription"]["claudeAiConnectors"])
        self.assertFalse(state["routeCapabilities"]["bonsai"]["claudeAiConnectors"])
        self.assertFalse(state["routeCapabilities"]["bonsai"]["connectorsWarningExpected"])
        self.assertTrue(state["routeCapabilities"]["bonsai"]["upstreamDirectCommandMayWarn"])
        self.assertTrue(state["routeCapabilities"]["bonsai"]["phaseZeroLauncherSuppressesWarning"])
        self.assertEqual(1, sum(item["state"] == "orphan" for item in state["configuration"]["hooks"]))

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
        managed_manager = manager.data_root / "tools/phasezero-claude-manager/claude_code_manager.py"
        self.assertEqual(MODULE_PATH.read_bytes(), managed_manager.read_bytes())
        for launcher_name in ("bonsai", "claude-bonsai"):
            launcher = self.home / ".local/bin" / launcher_name
            launcher_content = launcher.read_text(encoding="utf-8")
            self.assertIn(str(managed_manager), launcher_content)
            self.assertNotIn(str(ROOT / "linux/pz"), launcher_content)
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

        launchers = [self.home / ".local/bin" / name for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai", "phasezero-ai-bonsai")]
        launchers.extend(
            [
                manager.data_root / "tools/bonsai-runner/latest-fail-open.cjs",
                manager.data_root / "tools/bonsai-runner/bonsai-managed",
                manager.data_root / "tools/phasezero-claude-manager/claude_code_manager.py",
                self.home / ".local/share/applications/phasezero-ai-bonsai.desktop",
                self.home / ".local/share/icons/hicolor/512x512/apps/phasezero-bonsai.png",
            ]
        )
        desktop_entry = (self.home / ".local/share/applications/phasezero-ai-bonsai.desktop").read_text(encoding="utf-8")
        self.assertIn("Name=PhaseZero AI — Bonsai", desktop_entry)
        self.assertIn("Icon=phasezero-bonsai", desktop_entry)
        self.assertIn("Terminal=true", desktop_entry)
        self.assertIn("Categories=Development;", desktop_entry)
        self.assertIn("X-PhaseZero-MenuGroup=web.ai", desktop_entry)
        self.assertIn(f"X-PhaseZero-Workspace={self.desktop_workspace}", desktop_entry)
        desktop_launcher = (self.home / ".local/bin/phasezero-ai-bonsai").read_text(encoding="utf-8")
        self.assertIn('PZ_BONSAI_DESKTOP_ROUTE:-9router', desktop_launcher)
        self.assertIn(str(self.desktop_workspace), desktop_launcher)
        self.assertEqual(
            (ROOT / "assets/ai/phasezero-bonsai.png").read_bytes(),
            (self.home / ".local/share/icons/hicolor/512x512/apps/phasezero-bonsai.png").read_bytes(),
        )
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
        probe = subprocess.run([str(launchers[0]), "--probe"], text=True, stdout=subprocess.PIPE, env=env, check=True)
        self.assertEqual(
            {"ANTHROPIC_API_KEY": None, "ANTHROPIC_AUTH_TOKEN": None, "ANTHROPIC_BASE_URL": None, "ANTHROPIC_MODEL": None},
            json.loads(probe.stdout),
        )

        second = manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        self.assertEqual("complete", second["status"])
        after = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in launchers}
        self.assertEqual(before, after)

    def test_bonsai_guard_blocks_home(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        proc = subprocess.run(
            [str(self.home / ".local/bin/claude-bonsai")],
            cwd=self.home,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(69, proc.returncode)
        self.assertIn("sensitive-directory", proc.stderr)

    def test_bonsai_audit_uses_git_send_set_and_redacts_contents(self) -> None:
        manager = CC.Manager()
        project = self.root / "audit-project"
        project.mkdir()
        subprocess.run(["git", "init", "-q", str(project)], check=True)
        (project / ".mimosa").mkdir()
        (project / ".mimosa/state").write_text("local", encoding="utf-8")
        (project / ".gitignore").write_text(".mimosa/\n", encoding="utf-8")
        clean = manager.bonsai_workspace_audit(project)
        self.assertTrue(clean["safe"])
        (project / ".npmrc").write_text("never-render-this", encoding="utf-8")
        blocked = manager.bonsai_workspace_audit(project)
        self.assertFalse(blocked["safe"])
        self.assertIn("credential-file", blocked["blockers"])
        self.assertEqual(".npmrc", blocked["blockerDetails"][0]["path"])
        self.assertNotIn("never-render-this", json.dumps(blocked))
        subprocess.run(["git", "-C", str(project), "add", ".npmrc"], check=True)
        (project / ".npmrc").unlink()
        self.assertTrue(manager.bonsai_workspace_audit(project)["safe"])
        (project / "outside").symlink_to(self.home)
        symlink = manager.bonsai_workspace_audit(project)
        self.assertIn("external-symlink", symlink["blockers"])

    def test_bonsai_route_uses_explicit_reviewed_working_directory(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        project = self.root / "reviewed-project"
        project.mkdir()
        receipt = self.root / "bonsai-route.txt"
        os.environ["PZ_TEST_BONSAI_ROUTE"] = str(receipt)
        try:
            self.assertEqual(0, manager.run_route("bonsai", [], str(project)))
        finally:
            os.environ.pop("PZ_TEST_BONSAI_ROUTE", None)
        self.assertEqual(f"{project.resolve()}|false", receipt.read_text(encoding="utf-8").strip())
        parsed = CC.build_parser().parse_args(["run", "bonsai", "--cwd", str(project)])
        self.assertEqual(str(project), parsed.cwd)
        self.assertTrue(manager.preflight("bonsai", str(project))["ok"])
        self.assertFalse(manager.preflight("bonsai", str(self.home))["ok"])
        (project / ".env").write_text("fixture-only\n", encoding="utf-8")
        blocked = manager.preflight("bonsai", str(project))
        self.assertFalse(blocked["ok"])
        self.assertEqual(["dotenv"], blocked["workspace"]["blockers"])
        self.assertEqual(69, manager.run_route("bonsai", [], str(project)))

    def test_bonsai_shim_intercepts_only_start_and_supports_safe_selector(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        shim = self.home / ".local/bin/bonsai"
        version = subprocess.run([str(shim), "--version"], text=True, stdout=subprocess.PIPE, check=True)
        self.assertEqual("0.4.19", version.stdout.strip())

        login_env = os.environ.copy()
        login_env["PZ_BONSAI_AUTH_PROBE"] = "disabled"
        login = subprocess.run([str(shim), "login"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=login_env, check=False)
        self.assertEqual(69, login.returncode)
        self.assertIn("upstream-auth-disabled", login.stderr)

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
        self.assertEqual(0, direct.returncode, direct.stderr)
        self.assertEqual(f"{project.resolve()}|false", receipt.read_text(encoding="utf-8").strip())

        receipt.unlink()
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
        self.assertIn("no Bonsai snapshot/upload", fallback.stderr)
        self.assertFalse(receipt.exists())

    def test_bonsai_auth_probe_blocks_disabled_upstream_without_touching_credentials(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        original = manager.bonsai_config.read_bytes()
        os.environ["PZ_BONSAI_AUTH_PROBE"] = "disabled"
        self.assertEqual(69, manager.login("bonsai"))
        self.assertEqual(original, manager.bonsai_config.read_bytes())
        state = manager.bonsai_info()["authProvider"]
        self.assertFalse(state["available"])
        self.assertEqual("upstream-auth-disabled", state["class"])
        self.assertNotIn("user_code", json.dumps(state))

    def test_bonsai_never_reports_ready_when_login_is_disabled_and_token_expired(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        self._write_credential_store(manager.bonsai_config, -60_000)
        os.chmod(manager.bonsai_config, 0o600)
        os.environ["PZ_BONSAI_AUTH_PROBE"] = "disabled"
        manager.bonsai_auth_probe()

        info = manager.bonsai_info()
        self.assertTrue(info["runtimeReady"])
        self.assertTrue(info["runner"]["ready"])
        self.assertFalse(info["ready"])
        self.assertIn("bonsai-auth-invalid", info["readinessBlockers"])
        self.assertIn("upstream-auth-disabled", info["readinessBlockers"])

        project = self.root / "blocked-bonsai-project"
        project.mkdir()
        preflight = manager.preflight("bonsai", str(project))
        self.assertFalse(preflight["ok"])
        self.assertIn("upstream-auth-disabled", preflight["readinessBlockers"])
        state = manager.status("bonsai")
        self.assertFalse(state["routeCapabilities"]["bonsai"]["ready"])
        verified = manager.verify("bonsai", None, live=True, cwd=str(project))
        self.assertFalse(verified["ok"])
        self.assertFalse(verified["live"]["bonsai"]["routeReady"])

    def test_bonsai_login_cancel_restores_credential_store_bytes(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        original = manager.bonsai_config.read_bytes()
        self.bonsai.write_text(
            """#!/usr/bin/env node
const fs=require("node:fs"),path=require("node:path");
if (process.argv[2] === "--version") { console.log("0.4.19"); process.exit(0); }
fs.writeFileSync(path.join(process.env.XDG_CONFIG_HOME,"bonsai-cli-nodejs/config.json"),"changed");
process.exit(130);
""",
            encoding="utf-8",
        )
        os.chmod(self.bonsai, 0o700)
        os.environ["PZ_BONSAI_AUTH_PROBE"] = "healthy"
        self.assertEqual(130, manager.login("bonsai"))
        self.assertEqual(original, manager.bonsai_config.read_bytes())

    def test_bonsai_update_loader_passes_valid_and_fails_open_invalid(self) -> None:
        self._settings()
        manager = CC.Manager()
        manager.install("subscription", None, dry_run=False, yes=True, verbose=False)
        loader = manager.data_root / "tools/bonsai-runner/latest-fail-open.cjs"
        real_node = shutil.which("node")
        if not real_node:
            self.skipTest("node unavailable")

        def probe(payload: str, url: str = "https://registry.npmjs.org/@bonsai-ai/cli/latest") -> str:
            prelude = self.root / "fetch-prelude.cjs"
            prelude.write_text(
                "globalThis.fetch=async()=>new Response(" + json.dumps(payload) + ",{status:200,headers:{'content-type':'application/json'}});\n",
                encoding="utf-8",
            )
            script = "fetch(process.argv[1]).then(r=>r.json()).then(v=>console.log(v.version))"
            return subprocess.run(
                [real_node, "--require", str(prelude), "--require", str(loader), "-e", script, url],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            ).stdout.strip()

        self.assertEqual("9.8.7", probe('{"version":"9.8.7"}'))
        self.assertEqual("0.4.19", probe('{}'))
        self.assertEqual("7.6.5", probe('{"version":"7.6.5"}', "https://api.trybons.ai/v1/models"))

    def test_existing_bonsai_requires_name_version_and_hash_allowlist(self) -> None:
        package = self.root / "package"
        cli = package / "dist/cli.js"
        cli.parent.mkdir(parents=True)
        cli.write_text("known-cli", encoding="utf-8")
        package_json = package / "package.json"
        package_json.write_text(json.dumps({"name": "@bonsai-ai/cli", "version": "0.4.19"}), encoding="utf-8")
        allowed = {"cliSha256": CC.file_sha256(cli), "packageSha256": CC.file_sha256(package_json)}
        with mock.patch.dict(CC.BONSAI_EXISTING_HASHES, {"0.4.19": allowed}, clear=True):
            accepted = CC.Manager()._validated_existing_bonsai(str(cli))
            self.assertEqual("existing-known-installation", accepted["source"])
            cli.write_text("tampered", encoding="utf-8")
            self.assertIsNone(CC.Manager()._validated_existing_bonsai(str(cli)))

    def test_bonsai_distribution_selection_handles_registry_failures(self) -> None:
        integrity = CC.BONSAI_INTEGRITIES[CC.BONSAI_VERSION]
        valid = json.dumps({"version": CC.BONSAI_VERSION, "dist.integrity": integrity})
        self.assertEqual("registry", CC.Manager.select_bonsai_distribution(0, valid)[2])
        for rc, payload in (
            (1, "404"),
            (124, "timeout"),
            (0, "not-json"),
            (0, json.dumps({"version": None, "dist.integrity": integrity})),
            (0, json.dumps({"version": "999.0.0", "dist.integrity": integrity})),
        ):
            with self.subTest(rc=rc, payload=payload):
                version, selected_integrity, source = CC.Manager.select_bonsai_distribution(rc, payload)
                self.assertEqual(CC.BONSAI_VERSION, version)
                self.assertEqual(integrity, selected_integrity)
                self.assertEqual("npm-cache", source)

    def test_bonsai_total_distribution_absence_leaves_no_partial_install(self) -> None:
        manager = CC.Manager()
        tx = CC.Transaction(manager.data_root, "distribution-test")
        with mock.patch.object(manager, "_bonsai_upstream", return_value=None), mock.patch.object(
            manager, "_download_node_runtime", return_value=(self.real_node, "/fake/npm")
        ), mock.patch.object(
            CC, "run_capture", side_effect=[(1, "", "404"), (1, "", "cache miss")]
        ):
            with self.assertRaisesRegex(RuntimeError, "upstream-distribution-unavailable"):
                manager._ensure_bonsai(tx)
        self.assertFalse((manager.data_root / "tools/bonsai").exists())

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

    def test_bonsai_credential_probe_distinguishes_valid_and_expired_tokens(self) -> None:
        manager = CC.Manager()
        self._write_credential_store(manager.bonsai_config, 60_000)
        valid = manager.bonsai_credential_status()
        self.assertTrue(valid["authenticated"])
        self.assertEqual("valid-local-token", valid["state"])
        self._write_credential_store(manager.bonsai_config, -60_000)
        expired = manager.bonsai_credential_status()
        self.assertFalse(expired["authenticated"])
        self.assertEqual("expired-refresh-required", expired["state"])
        self.assertNotIn("fixture-refresh", json.dumps(expired))

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
                for name in ("claude-subscription", "claude-bonsai", "claude-9router", "bonsai", "phasezero-ai-bonsai"):
                    self.assertFalse((self.home / ".local/bin" / name).exists())
                self.assertFalse((self.home / ".local/share/applications/phasezero-ai-bonsai.desktop").exists())
                self.assertFalse((self.home / ".local/share/icons/hicolor/512x512/apps/phasezero-bonsai.png").exists())

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
