"""Atalhos agrupados numa sub-área única e apps não duplicados.

Dois contratos:

1. Nenhum lançador do PhaseZero fica solto nas categorias globais do menu
   (Jogos, Desenvolvimento, ...). Tudo entra na raiz única "PhaseZero" e sai
   das categorias globais via `Categories=X-PhaseZero;`.
2. App já presente no host — por pacote, flatpak, binário no PATH, AppImage ou
   lançador de terceiro — não é instalado de novo pelo PhaseZero.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "linux" / "ui"))

MENU_PY = ROOT / "linux/ui/menu.py"


def menu(sandbox, command: str) -> dict:
    result = sandbox.run("python3", str(MENU_PY), command)
    assert result.returncode == 0, f"menu {command} falhou: {result.stderr}"
    return json.loads(result.stdout)


def write_entry(sandbox, filename: str, group: str, body: str) -> Path:
    """Grava um .desktop pelo caminho oficial (pz_desktop_write_entry)."""
    target = sandbox.home / ".local/share/applications" / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f"cat <<'DESKTOP' | pz_desktop_write_entry '{target}' {group}\n"
        f"{body}\n"
        "DESKTOP\n"
    )
    result = sandbox.run("bash", "-c", script)
    assert result.returncode == 0, result.stderr
    return target


def foreign_entry(sandbox, filename: str, name: str, exec_line: str, categories: str = "Network;") -> Path:
    """.desktop de terceiro: sem nenhuma marca do PhaseZero."""
    target = sandbox.home / ".local/share/applications" / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "[Desktop Entry]\nType=Application\n"
        f"Name={name}\nExec={exec_line}\nCategories={categories}\n",
        encoding="utf-8",
    )
    return target


# --- 1. agrupamento -------------------------------------------------------


def test_entry_is_stamped_as_managed_at_creation(host_sandbox):
    """A marca vem da ORIGEM, não só do `menu apply`."""
    target = write_entry(
        host_sandbox, "claude-desktop.desktop", "web.ai",
        "[Desktop Entry]\nType=Application\nName=Claude\n"
        "Exec=/opt/claude/claude\nCategories=Development;Utility;",
    )
    content = target.read_text(encoding="utf-8")
    assert "X-PhaseZero-Managed=true" in content
    assert "X-PhaseZero-MenuGroup=web.ai" in content


def test_unprefixed_entry_is_no_longer_invisible_to_the_menu(host_sandbox):
    """Regressão: `claude-desktop.desktop` escapava do menu unificado."""
    write_entry(
        host_sandbox, "claude-desktop.desktop", "web.ai",
        "[Desktop Entry]\nType=Application\nName=Claude\n"
        "Exec=/opt/claude/claude\nCategories=Development;Utility;",
    )
    payload = menu(host_sandbox, "scan")
    ids = {item["desktop_id"] for item in payload["items"]}
    assert "claude-desktop.desktop" in ids
    groups = {item["desktop_id"]: item["group"] for item in payload["items"]}
    assert groups["claude-desktop.desktop"] == "web.ai"


def test_exec_in_namespace_is_recognized_without_any_marker(host_sandbox):
    """Rede de segurança: Exec apontando pro namespace basta."""
    target = host_sandbox.home / ".local/share/applications/algum-launcher.desktop"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "[Desktop Entry]\nType=Application\nName=Algo\n"
        f"Exec={host_sandbox.home}/.local/bin/phasezero-algo\nCategories=Utility;\n",
        encoding="utf-8",
    )
    ids = {item["desktop_id"] for item in menu(host_sandbox, "scan")["items"]}
    assert "algum-launcher.desktop" in ids


def test_foreign_entry_is_never_captured_by_the_menu(host_sandbox):
    """O menu do PhaseZero não sequestra lançador de terceiro."""
    foreign_entry(host_sandbox, "discord.desktop", "Discord", "/usr/bin/discord %U")
    ids = {item["desktop_id"] for item in menu(host_sandbox, "scan")["items"]}
    assert "discord.desktop" not in ids


def test_apply_removes_entries_from_global_categories(host_sandbox):
    """O atalho sai de Jogos/Desenvolvimento e fica só sob PhaseZero."""
    target = write_entry(
        host_sandbox, "phasezero-demo.desktop", "games.emulators",
        "[Desktop Entry]\nType=Application\nName=Demo\n"
        "Exec=/usr/bin/demo\nCategories=Game;Emulator;",
    )
    assert "Categories=Game;Emulator;" in target.read_text(encoding="utf-8")

    menu(host_sandbox, "apply")

    content = target.read_text(encoding="utf-8")
    assert "Categories=X-PhaseZero;" in content
    assert "Game;Emulator;" not in content, "atalho continua solto na categoria Jogos"


@pytest.mark.parametrize("owner", ["codex-profiles", "chatgpt-web", ""])
def test_grouping_preserves_the_launcher_owner_for_repair(host_sandbox, owner):
    target = host_sandbox.home / ".local/share/applications/phasezero-chatgpt-web.desktop"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "[Desktop Entry]\nType=Application\nName=Codex Web Principal\n"
        "Exec=/usr/bin/true\nCategories=Development;\n"
        f"X-PhaseZero-Managed={owner}\n")
    menu(host_sandbox, "apply")
    menu(host_sandbox, "apply")  # repeat must retain the same owner
    content = target.read_text()
    assert f"X-PhaseZero-Managed={owner or 'true'}\n" in content
    assert content.count("X-PhaseZero-Managed=") == 1
    assert "Categories=X-PhaseZero;" in content


def test_apply_builds_a_single_root_with_sub_areas(host_sandbox):
    write_entry(
        host_sandbox, "phasezero-emu.desktop", "games.emulators",
        "[Desktop Entry]\nType=Application\nName=Emu\nExec=/usr/bin/emu\nCategories=Game;",
    )
    write_entry(
        host_sandbox, "phasezero-chat.desktop", "web.communication",
        "[Desktop Entry]\nType=Application\nName=Chat\nExec=/usr/bin/chat\nCategories=Network;",
    )
    menu(host_sandbox, "apply")

    menu_file = host_sandbox.home / ".config/menus/applications-merged/phasezero.menu"
    assert menu_file.is_file()
    xml = menu_file.read_text(encoding="utf-8")

    # raiz única
    assert xml.count("<Name>PhaseZero</Name>") == 1
    # sub-áreas, não entradas soltas na raiz
    assert "<Name>Jogos e emulação</Name>" in xml
    assert "<Name>Apps web</Name>" in xml
    assert "<Name>Emuladores</Name>" in xml
    assert "<Name>Comunicação</Name>" in xml
    assert "phasezero-emu.desktop" in xml
    assert "phasezero-chat.desktop" in xml


def test_unknown_group_degrades_instead_of_failing(host_sandbox):
    target = write_entry(
        host_sandbox, "phasezero-x.desktop", "grupo.inexistente",
        "[Desktop Entry]\nType=Application\nName=X\nExec=/usr/bin/x\nCategories=Utility;",
    )
    assert "X-PhaseZero-MenuGroup=system.tools" in target.read_text(encoding="utf-8")


# --- sync automático ------------------------------------------------------


def test_writing_an_entry_marks_the_menu_dirty(host_sandbox):
    write_entry(
        host_sandbox, "phasezero-demo.desktop", "games.tools",
        "[Desktop Entry]\nType=Application\nName=Demo\nExec=/usr/bin/demo\nCategories=Game;",
    )
    assert (host_sandbox.state / "desktop-menu/dirty").is_file()


def test_sync_regroups_only_when_dirty(host_sandbox):
    write_entry(
        host_sandbox, "phasezero-demo.desktop", "games.tools",
        "[Desktop Entry]\nType=Application\nName=Demo\nExec=/usr/bin/demo\nCategories=Game;",
    )
    first = menu(host_sandbox, "sync")
    assert first["applied"] is True
    assert first["status"] == "ok"

    second = menu(host_sandbox, "sync")
    assert second["applied"] is False, "sync reescreveu o menu sem necessidade"


def test_dry_run_never_marks_the_menu_dirty(host_sandbox):
    result = host_sandbox.run(
        "bash", "-c",
        f'source "{ROOT}/linux/lib/common.sh"\nPZ_DRY_RUN=1 pz_menu_mark_dirty\n',
    )
    assert result.returncode == 0, result.stderr
    assert not (host_sandbox.state / "desktop-menu/dirty").exists()


# --- 2. anti-duplicação ---------------------------------------------------


def guard(sandbox, *args: str, env_prefix: str = "") -> int:
    script = (
        f'source "{ROOT}/linux/lib/common.sh"\n'
        f"rc=0; {env_prefix}pz_app_install_guard {' '.join(args)} >/dev/null 2>&1 || rc=$?\n"
        'echo "$rc"\n'
    )
    result = sandbox.run("bash", "-c", script)
    return int(result.stdout.strip() or -1)


def test_foreign_desktop_entry_blocks_a_duplicate(host_sandbox):
    foreign_entry(host_sandbox, "discord.desktop", "Discord", "/usr/bin/discord %U")
    assert guard(host_sandbox, "--name", "Discord", "--desktop-exec", "discord") == 3


def test_new_app_is_allowed(host_sandbox):
    assert guard(host_sandbox, "--name", "AppInexistente", "--desktop-exec", "nadaaqui") == 0


def test_our_own_launcher_is_not_a_duplicate_of_itself(host_sandbox):
    target = host_sandbox.home / ".local/share/applications/phz-slack.desktop"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        "[Desktop Entry]\nName=Slack\nExec=xdg-open https://slack.com\n"
        "X-PhaseZero-Managed=true\n",
        encoding="utf-8",
    )
    assert guard(host_sandbox, "--name", "Slack", "--desktop-exec", "slack") == 0


def test_duplicate_can_be_forced(host_sandbox):
    foreign_entry(host_sandbox, "discord.desktop", "Discord", "/usr/bin/discord %U")
    assert guard(
        host_sandbox, "--name", "Discord", "--desktop-exec", "discord",
        env_prefix="PZ_ALLOW_DUPLICATE=1 ",
    ) == 0


def test_flatpak_install_blocks_a_duplicate(host_sandbox):
    host_sandbox.declare_installed("flatpak", "com.discordapp.Discord")
    assert guard(host_sandbox, "--flatpak", "com.discordapp.Discord") == 3


def test_flatpak_not_installed_allows_the_install(host_sandbox):
    """Contraprova: sem o flatpak presente, o guard libera."""
    assert guard(host_sandbox, "--flatpak", "com.discordapp.Discord") == 0


def test_pacman_package_blocks_a_duplicate(host_sandbox):
    host_sandbox.declare_installed("pacman", "retroarch")
    assert guard(host_sandbox, "--pacman", "retroarch") == 3


def test_pacman_package_absent_allows_the_install(host_sandbox):
    assert guard(host_sandbox, "--pacman", "retroarch") == 0


def test_appimage_blocks_a_duplicate(host_sandbox):
    apps = host_sandbox.home / "Applications"
    apps.mkdir(parents=True, exist_ok=True)
    (apps / "Cemu-1.2.3.AppImage").write_text("binário\n", encoding="utf-8")
    assert guard(host_sandbox, "--appimage", "Cemu*.AppImage") == 3


def test_our_own_bin_wrapper_is_not_a_third_party_install(host_sandbox):
    """`~/.local/bin/phasezero-*` é nosso; não conta como app já instalado."""
    wrapper = host_sandbox.home / ".local/bin/phasezero-demo"
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    wrapper.write_text("#!/bin/sh\n", encoding="utf-8")
    wrapper.chmod(0o755)
    assert guard(host_sandbox, "--bin", "phasezero-demo") == 0


# --- integração: webapp.sh ------------------------------------------------


def webapp(sandbox, *args: str):
    return sandbox.run("bash", str(ROOT / "linux/ui/webapp.sh"), *args)


def test_webapp_install_skips_when_the_native_app_exists(host_sandbox):
    foreign_entry(host_sandbox, "discord.desktop", "Discord", "/usr/bin/discord %U")

    result = webapp(host_sandbox, "install", "discord")
    assert result.returncode == 0, result.stderr
    assert "SKIP" in result.stdout

    created = host_sandbox.home / ".local/share/applications/phz-discord.desktop"
    assert not created.exists(), "web app duplicou um app nativo já instalado"


def test_webapp_install_proceeds_when_nothing_conflicts(host_sandbox):
    result = webapp(host_sandbox, "install", "notion")
    assert result.returncode == 0, result.stderr

    created = host_sandbox.home / ".local/share/applications/phz-notion.desktop"
    assert created.is_file()
    content = created.read_text(encoding="utf-8")
    assert "X-PhaseZero-Managed=true" in content
    assert "X-PhaseZero-MenuGroup=" in content


def test_webapp_install_is_grouped_not_scattered(host_sandbox):
    webapp(host_sandbox, "install", "notion")
    menu(host_sandbox, "sync")

    created = host_sandbox.home / ".local/share/applications/phz-notion.desktop"
    assert "Categories=X-PhaseZero;" in created.read_text(encoding="utf-8")

    xml = (host_sandbox.home / ".config/menus/applications-merged/phasezero.menu").read_text(
        encoding="utf-8"
    )
    assert "phz-notion.desktop" in xml
    assert xml.count("<Name>PhaseZero</Name>") == 1


# --- cobertura: nenhum escritor de .desktop escapa ------------------------


def test_no_module_writes_a_desktop_entry_outside_the_helper():
    """Todo .desktop em ~/.local/share/applications passa por pz_desktop_write_entry.

    Sem isto, um lançador novo volta a nascer sem marca e reaparece solto nas
    categorias globais do menu.
    """
    allowed_owners = {"desktop.sh", "menu.py", "common.sh"}
    offenders: list[str] = []
    for path in (ROOT / "linux").rglob("*"):
        if not path.is_file() or path.suffix not in (".sh", ".py"):
            continue
        if path.name in allowed_owners:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            # escrita direta num .desktop dentro de applications/
            if "APPLICATIONS_DIR" not in stripped and "applications/" not in stripped:
                continue
            if ".desktop" not in stripped:
                continue
            if any(token in stripped for token in ("cat > ", "cat >\"", "> \"$APPLICATIONS_DIR")):
                if "pz_desktop_write_entry" not in stripped:
                    offenders.append(f"{path.relative_to(ROOT)}:{number}: {stripped}")
    assert offenders == [], (
        "lançadores gravados sem passar por pz_desktop_write_entry "
        "(vão aparecer soltos no menu):\n" + "\n".join(offenders)
    )
