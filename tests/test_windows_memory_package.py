"""An installed runtime must retain the real owner without importing host state."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("windows_memory_package", ROOT / "tools/package-memory-windows.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def test_installed_runtime_runs_canonical_plan_and_excludes_private_state(tmp_path):
    output = tmp_path / "runtime"
    package.build(output)
    manifest = json.loads((output / "runtime-manifest.json").read_text())
    assert "windows/ai/prepare-host.ps1" in manifest["files"]
    assert "windows/ai/host-instructions.ps1" in manifest["files"]
    assert "assets/ai/host-resource-policy.md" in manifest["files"]
    assert "linux/ai/windows_credential_store.py" in manifest["files"]
    assert not any(name.startswith((".git/", ".bootstrap-tools/", ".codex/")) for name in manifest["files"])
    assert not any(Path(name).name in ("portability.json", "auth.json", "memory.db") for name in manifest["files"])
    for name, item in manifest["files"].items():
        assert package.sha(output / name) == item["sha256"]
    env = {**os.environ, "HOME": str(tmp_path / "home"), "XDG_CONFIG_HOME": str(tmp_path / "config"),
           "XDG_STATE_HOME": str(tmp_path / "state"), "LOCALAPPDATA": str(tmp_path / "local")}
    result = subprocess.run([sys.executable, str(output / "linux/ai/memory_manager.py"), "plan", "--json"],
                            env=env, capture_output=True, check=True, timeout=15)
    assert json.loads(result.stdout)["ok"]
    assert not (tmp_path / "config/phasezero/ai-memory/portability.json").exists()
    with pytest.raises(ValueError, match="Destination exists"):
        package.build(output)


def test_corrupt_native_release_is_rejected_before_runtime_creation(tmp_path):
    packages = tmp_path / "packages"
    packages.mkdir()
    (packages / "ai-memory-windows-x86_64.zip").write_text("damaged")
    with pytest.raises(ValueError, match="hash differs"):
        package.build(tmp_path / "runtime", packages)
    assert not (tmp_path / "runtime").exists()
