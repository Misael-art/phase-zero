from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("duplicates", ROOT / "linux/audit/duplicates.py")
assert SPEC and SPEC.loader
DUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DUP)


class DuplicateScannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pz-dup-test-")
        self.home = Path(self.temp.name)
        self.old_env = os.environ.copy()
        self.npm_bin = self.home / ".npm-global/bin"
        self.side_bin = self.home / ".opencode/bin"
        self.local_bin = self.home / ".local/bin"
        for path in (self.npm_bin, self.side_bin, self.local_bin):
            path.mkdir(parents=True)
        os.environ.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "XDG_DATA_HOME": str(self.home / ".local/share"),
                "PZ_STATE": str(self.home / ".local/share/phasezero"),
                "PATH": f"{self.local_bin}:{self.npm_bin}",
            }
        )
        DUP.FLATPAK_ALIASES = {}

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def _exe(self, path: Path, version: str) -> Path:
        # Binary-looking payload (no shell shebang) so it is an install, not a shim.
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/usr/bin/env python3\nprint('{version}')\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def _two_opencodes(self) -> tuple[Path, Path]:
        npm_real = self._exe(self.home / ".npm-global/lib/node_modules/opencode-ai/bin/opencode", "1.19.1")
        (self.npm_bin / "opencode").symlink_to(npm_real)
        side = self._exe(self.side_bin / "opencode", "1.17.20")
        return npm_real, side

    def test_scan_flags_unacknowledged_duplicate_as_conflict(self) -> None:
        self._two_opencodes()
        result = DUP.scan()
        self.assertFalse(result["ok"])
        self.assertEqual(["opencode"], result["blocking"])
        copies = result["duplicates"][0]["copies"]
        self.assertTrue(copies[0]["active"])
        self.assertEqual("npm", copies[0]["channel"])
        self.assertEqual("upstream-installer", copies[1]["channel"])

    def test_symlinks_to_one_install_are_not_a_duplicate(self) -> None:
        npm_real = self._exe(self.home / ".npm-global/lib/node_modules/opencode-ai/bin/opencode", "1")
        (self.npm_bin / "opencode").symlink_to(npm_real)
        (self.local_bin / "opencode").symlink_to(npm_real)
        self.assertEqual("clean", DUP.scan()["status"])

    def test_shell_shim_is_a_wrapper_and_broken_one_is_reported(self) -> None:
        self._exe(self.home / ".npm-global/lib/node_modules/9router/cli.js", "0.5")
        (self.npm_bin / "9router").symlink_to(self.home / ".npm-global/lib/node_modules/9router/cli.js")
        shim = self.local_bin / "9router"
        shim.write_text("#!/usr/bin/env bash\nexec \"/gone/pz\" ai 9router tui \"$@\"\n", encoding="utf-8")
        shim.chmod(0o755)
        result = DUP.scan()
        self.assertEqual("clean", result["status"])
        self.assertEqual(["/gone/pz"], result["brokenShims"][0]["missingTargets"])

    def test_allow_turns_conflict_into_conscious_choice(self) -> None:
        self._two_opencodes()
        self.assertEqual(0, DUP.main(["allow", "opencode", "--reason", "teste de versão"]))
        result = DUP.scan()
        self.assertTrue(result["ok"])
        self.assertEqual("acknowledged", result["status"])
        self.assertEqual("teste de versão", result["duplicates"][0]["reason"])

    def test_gate_blocks_and_resolve_quarantines_reversibly(self) -> None:
        npm_real, side = self._two_opencodes()
        self.assertEqual(1, DUP.main(["gate", "opencode"]))
        self.assertTrue(side.exists())

        self.assertEqual(0, DUP.main(["gate", "opencode", "--resolve"]))
        self.assertFalse(side.exists())
        self.assertTrue(npm_real.exists())
        manifests = list((self.home / ".local/share/phasezero/quarantine").glob("*/manifest.json"))
        self.assertEqual(1, len(manifests))

        restored = DUP.restore(str(manifests[0]))
        self.assertEqual([str(side)], restored["restored"])
        self.assertTrue(side.exists())

    def test_resolve_dry_run_touches_nothing(self) -> None:
        _, side = self._two_opencodes()
        result = DUP.resolve("opencode", dry_run=True)
        self.assertEqual([str(side)], result["planned"])
        self.assertTrue(side.exists())


if __name__ == "__main__":
    unittest.main()
