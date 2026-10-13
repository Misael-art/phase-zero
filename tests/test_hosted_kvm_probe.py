import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_hosted_kvm_probe_skips_cleanly_without_device(tmp_path):
    env = os.environ.copy()
    env["PZ_KVM_DEVICE"] = str(tmp_path / "no-kvm-device")

    result = subprocess.run(
        ["bash", str(ROOT / "tests/probe_hosted_qemu_kvm.sh")],
        capture_output=True,
        text=True,
        env=env,
        timeout=5,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "SKIP:" in result.stdout
    assert "not G2 evidence" in result.stdout
