from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

BOOT = Path(__file__).resolve().parents[1] / "linux" / "boot"


@pytest.mark.parametrize("conflict", ["", " phasezero.windowsvm=1", " systemd.unit=rescue.target"])
def test_grub_entry_reuses_normal_kernel_and_initrd(tmp_path, conflict):
    distro = tmp_path / "10_linux"
    distro.write_text(
        "#!/bin/sh\ncat <<'GRUB'\n"
        "menuentry 'Linux' --id='linux' {\n"
        "  savedefault\n"
        "  search --fs-uuid --set=root test-root\n"
        f"  linux /@/boot/vmlinuz root=UUID=test-root rootflags=subvol=@ quiet{conflict}\n"
        "  initrd /@/boot/amd-ucode.img /@/boot/initramfs.img\n"
        "}\n"
        "menuentry 'Fallback' {\n"
        "  linux /boot/vmlinuz-fallback\n"
        "}\n"
        "GRUB\n"
    )
    distro.chmod(0o755)
    result = subprocess.run(
        ["bash", BOOT / "vibe-code-grub.sh", distro], capture_output=True, text=True
    )
    if conflict:
        assert result.returncode != 0
        assert not result.stdout
        return
    assert result.returncode == 0
    assert "PhaseZero Vibe Code (Plasma)" in result.stdout
    assert "rootflags=subvol=@ quiet phasezero.vibe=1 systemd.unit=phasezero-vibe-code.target" in result.stdout
    assert "initrd /@/boot/amd-ucode.img /@/boot/initramfs.img" in result.stdout
    assert "savedefault" not in result.stdout
    assert "Fallback" not in result.stdout
    if shutil.which("grub-script-check"):
        candidate = tmp_path / "grub.cfg"
        candidate.write_text(result.stdout)
        subprocess.run(["grub-script-check", candidate], check=True)


def test_sddm_prepares_one_login_and_falls_back_on_missing_launcher(tmp_path):
    session_dir = tmp_path / "sessions"
    session_dir.mkdir()
    (session_dir / "plasma.desktop").touch()
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    commands = tmp_path / "bin"
    commands.mkdir()
    getent = commands / "getent"
    getent.write_text("#!/bin/sh\nprintf 'fixture:x:1000:1000::/fixture:/bin/bash\\n'\n")
    getent.chmod(0o755)
    setpriv = commands / "setpriv"
    setpriv.write_text('#!/bin/sh\n[ "$*" = "--reuid 1000 --regid 1000 --init-groups -- /usr/bin/test -x $VIBE_TEST_LAUNCHER" ] || exit 1\nshift 6\nexec "$@"\n')
    setpriv.chmod(0o755)
    launcher = tmp_path / "launcher with spaces"
    launcher.touch(mode=0o755)
    settings = tmp_path / "config"
    settings.write_text(f"# PhaseZero managed: Vibe Code\nfixture\n{launcher}\n")
    cmdline = tmp_path / "cmdline"
    login = runtime / "login.conf"
    env = {**os.environ, "PATH": f"{commands}:{os.environ['PATH']}", "VIBE_TEST_LAUNCHER": str(launcher)}
    command = ["bash", BOOT / "vibe-code-session.sh", "prepare", settings, cmdline, session_dir, runtime]

    cmdline.write_text("root=UUID=test phasezero.vibe=1\n")
    subprocess.run(command, env=env, check=True)
    assert login.read_text() == "[Autologin]\nUser=fixture\nSession=plasma.desktop\nRelogin=false\n"
    cmdline.write_text("root=UUID=test phasezero.vibe=1 steamzero.gamemode=1\n")
    subprocess.run(command, env=env, check=True)
    assert not login.exists()
    cmdline.write_text("root=UUID=test phasezero.vibe=1\n")
    launcher.unlink()
    subprocess.run(command, env=env, check=True)
    assert not login.exists()
