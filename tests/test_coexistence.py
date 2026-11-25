"""PhaseZero não instala por cima, não apaga nem sobrescreve o que é do usuário."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "linux" / "ai"))

from linux.capabilities import presence  # noqa: E402


@pytest.fixture
def no_host(monkeypatch):
    """Nada instalado: cada teste liga só o canal que quer provar."""
    monkeypatch.setattr(presence, "pacman_exact", lambda name: False)
    monkeypatch.setattr(presence, "pacman_satisfied", lambda name: False)
    monkeypatch.setattr(presence, "flatpak_scopes", lambda app_id: [])
    monkeypatch.setattr(presence, "binary_presence", lambda names: None)
    return monkeypatch


def test_profile_package_skipped_when_flatpak_equivalent_exists(no_host):
    no_host.setattr(presence, "flatpak_scopes",
                    lambda app_id: ["user"] if app_id == "org.libretro.RetroArch" else [])
    assert presence.equivalent("pacman", "retroarch") == ("flatpak", "org.libretro.RetroArch (user)")


def test_flatpak_skipped_when_native_package_exists(no_host):
    no_host.setattr(presence, "pacman_exact", lambda name: name == "brave-browser")
    assert presence.equivalent("flatpak", "com.brave.Browser") == ("pacman", "brave-browser")


def test_provides_counts_as_present(no_host):
    no_host.setattr(presence, "pacman_satisfied", lambda name: name == "nodejs")
    assert presence.equivalent("pacman", "nodejs") == ("pacman", "pacote que fornece nodejs")


def test_exact_package_is_left_to_package_manager(no_host):
    no_host.setattr(presence, "pacman_exact", lambda name: name == "steam")
    assert presence.equivalent("pacman", "steam") is None


def test_unrelated_package_has_no_equivalent(no_host):
    assert presence.equivalent("pacman", "python") is None


def test_broken_wrapper_and_own_launcher_are_not_installs(tmp_path):
    broken = tmp_path / "code"
    broken.write_text("#!/bin/bash\nexec /nonexistent/usr/bin/code \"$@\"\n")
    own = tmp_path / "claude-desktop"
    own.write_text("#!/usr/bin/env bash\n# PhaseZero managed: claude-desktop\nexec /bin/true\n")
    real = tmp_path / "brave"
    real.write_text("#!/bin/bash\nexec /bin/true \"$@\"\n")
    assert presence.live_executable(str(broken)) is False
    assert presence.live_executable(str(own)) is False
    assert presence.live_executable(str(real)) is True


@pytest.mark.parametrize("command,state", [
    ('"$CLAUDE_PROJECT_DIR"/.claude/hooks/check.sh', "opaque"),
    ('bash "$CLAUDE_PLUGIN_ROOT/hooks/run.sh"', "opaque"),
    ("/nonexistent/hook.sh", "orphan"),
])
def test_claude_hook_with_variables_is_never_pruned(command, state, monkeypatch):
    monkeypatch.delenv("CLAUDE_PROJECT_DIR", raising=False)
    monkeypatch.delenv("CLAUDE_PLUGIN_ROOT", raising=False)
    import claude_code_manager as manager

    assert manager.Manager._command_state(command)[0] == state


def _bash(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=60, check=False)


def _sandbox_env(tmp_path: Path) -> dict[str, str]:
    home = tmp_path / "home"
    home.mkdir()
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local/share")
    env["XDG_STATE_HOME"] = str(home / ".local/state")
    env["XDG_CACHE_HOME"] = str(home / ".cache")
    env.pop("PZ_APPLICATIONS_DIR", None)
    env.pop("PZ_DESKTOP_ENTRIES_DIR", None)
    return env


def test_emulation_appimages_go_to_applications_not_menu_dir(tmp_path):
    env = _sandbox_env(tmp_path)
    result = _bash('source linux/emulation/common.sh >/dev/null; printf "%s" "$PZ_APPLICATIONS_DIR"', env)
    assert result.stdout == f"{env['HOME']}/Applications"


def test_safe_link_keeps_real_file_from_other_installer(tmp_path):
    env = _sandbox_env(tmp_path)
    apps = Path(env["HOME"]) / "Applications"
    apps.mkdir()
    (apps / "Eden.AppImage").write_text("emudeck copy")
    (apps / "Eden-new.AppImage").write_text("phasezero copy")
    _bash('source linux/emulation/common.sh >/dev/null; '
          'pz_emulation_safe_link "$HOME/Applications/Eden-new.AppImage" "$HOME/Applications/Eden.AppImage"', env)
    assert (apps / "Eden.AppImage").read_text() == "emudeck copy"
    assert not (apps / "Eden.AppImage").is_symlink()


def test_release_asset_matches_host_architecture(tmp_path):
    env = _sandbox_env(tmp_path)
    release = tmp_path / "release.json"
    release.write_text('{"assets":['
                       '{"name":"EmuDeck-2.7.1-arm64.AppImage","browser_download_url":"arm"},'
                       '{"name":"EmuDeck-2.7.1-x86_64.AppImage","browser_download_url":"x86"}]}')
    script = ('source linux/emulation/common.sh >/dev/null; uname() { echo x86_64; }; '
              f'curl() {{ cat "{release}"; }}; pz_emulation_release_appimage_url api')
    assert _bash(script, env).stdout.strip() == "x86"


def test_efi_entries_are_found_by_exact_label(tmp_path):
    listing = tmp_path / "efi.txt"
    listing.write_text("BootCurrent: 0001\nBoot0001* Manjaro\tHD(1)\n"
                       "Boot0003* PhaseZero Windows VM\tHD(1)\nBoot0004  PhaseZero Windows VM\tHD(1)\n"
                       "Boot0005* PhaseZero Windows VM (old)\tHD(1)\n")
    env = _sandbox_env(tmp_path)
    script = (f'source linux/lib/common.sh >/dev/null; efibootmgr() {{ cat "{listing}"; }}; '
              'pz_boot_efi_bootnums_by_label "PhaseZero Windows VM"')
    assert _bash(script, env).stdout.split() == ["0003", "0004"]


def test_codex_link_never_replaces_foreign_binary(tmp_path):
    env = _sandbox_env(tmp_path)
    local_bin = Path(env["HOME"]) / ".local/bin"
    local_bin.mkdir(parents=True)
    (local_bin / "codex").write_text("official standalone codex")
    prefix = Path(env["HOME"]) / ".local/share/npm/bin"
    prefix.mkdir(parents=True)
    (prefix / "codex").write_text("#!/bin/sh\n")
    (prefix / "codex").chmod(0o755)
    script = ('source linux/lib/common.sh >/dev/null; '
              'eval "$(sed -n \'/^NPM_PREFIX=/,/^LOCAL_BIN=/p;/^link_managed_bin()/,/^}/p\' linux/ai/setup-codex.sh)"; '
              'link_managed_bin codex "$NPM_PREFIX/bin/codex"')
    _bash(script, env)
    assert (local_bin / "codex").read_text() == "official standalone codex"
    assert not (local_bin / "codex").is_symlink()


def test_mcp_repair_preserves_user_server_with_catalog_name(tmp_path):
    env = _sandbox_env(tmp_path)
    config = Path(env["XDG_CONFIG_HOME"]) / "opencode"
    config.mkdir(parents=True)
    target = config / "opencode.json"
    target.write_text('{"mcp":{"context7":{"type":"local","command":["mine"],"enabled":true}}}\n')
    for command in ("install context7 opencode", "install sentry opencode", "repair opencode"):
        _bash(f"bash linux/ai/mcp-manager.sh {command}", env)
    import json

    servers = json.loads(target.read_text())["mcp"]
    assert servers["context7"]["command"] == ["mine"]
    assert "sentry" not in servers


def test_broad_mcp_sync_skips_clients_absent_from_host(tmp_path):
    env = _sandbox_env(tmp_path)
    home = Path(env["HOME"])
    env["PATH"] = "/usr/bin:/bin"
    clients = ("claude", "codex", "opencode", "cursor", "zed", "zeditor", "hermes")
    if any(shutil.which(name, path=env["PATH"]) for name in clients):
        pytest.skip("host has an AI client in /usr/bin; presence would be real")
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    env["PZ_WORKSPACE_ROOT"] = str(workspace)
    (home / ".config/opencode").mkdir(parents=True)
    result = _bash("bash linux/ai/mcp-manager.sh sync", env)
    assert result.returncode == 0, result.stderr
    assert "ai-memory" in (home / ".config/opencode/opencode.json").read_text()
    for absent in (".cursor", ".hermes", ".codex", ".claude.json", ".config/zed", ".config/Code",
                   ".config/Claude", ".config/ai.z.zcode"):
        assert not (home / absent).exists(), absent
    assert not (workspace / ".codex").exists() and not (workspace / ".vscode").exists()
    explicit = _bash("bash linux/ai/mcp-manager.sh install ai-memory cursor", env)
    assert explicit.returncode == 0, explicit.stderr
    assert "ai-memory" in (home / ".cursor/mcp.json").read_text()
