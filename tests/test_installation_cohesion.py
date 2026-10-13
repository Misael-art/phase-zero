from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def profile_data(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_runtime_source_has_no_ghost_files():
    result = subprocess.run(
        ["git", "ls-files", "-oi", "--exclude-standard", "linux", "profiles", "assets"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    )
    ghosts = [line for line in result.stdout.splitlines() if "/.ghost-" in line]
    assert ghosts == []


def test_profile_package_managers_are_disjoint():
    for path in (ROOT / "profiles").glob("*.json"):
        linux = profile_data(path).get("packages", {}).get("linux", {})
        pacman = set(linux.get("pacman", ()))
        yay = set(linux.get("yay", ()))
        assert pacman.isdisjoint(yay), f"{path.name}: {sorted(pacman & yay)}"


def test_profiles_do_not_install_same_desktop_app_native_and_flatpak():
    equivalents = {
        "steam": "com.valvesoftware.Steam",
        "lutris": "net.lutris.Lutris",
        "heroic-games-launcher-bin": "com.heroicgameslauncher.hgl",
        "prismlauncher": "org.prismlauncher.PrismLauncher",
    }
    for path in (ROOT / "profiles").glob("*.json"):
        linux = profile_data(path).get("packages", {}).get("linux", {})
        native = set(linux.get("pacman", ())) | set(linux.get("yay", ()))
        flatpak = linux.get("flatpak", ())
        if isinstance(flatpak, dict):
            flatpak = flatpak.get("packages", ())
        flatpak = set(flatpak)
        duplicates = [package for package, app_id in equivalents.items() if package in native and app_id in flatpak]
        assert duplicates == [], f"{path.name}: {duplicates}"


def test_release_metadata_matches_version_json():
    version = profile_data(ROOT / "version.json")["version"]
    checks = {
        "deb": (ROOT / "packaging/linux/deb/control", r"^Version:\s*(\S+)"),
        "rpm": (ROOT / "packaging/linux/rpm/phasezero-control-center.spec", r"^Version:\s*(\S+)"),
        "aur": (ROOT / "packaging/linux/aur/PKGBUILD", r"^pkgver=(\S+)"),
        "srcinfo": (ROOT / "packaging/linux/aur/.SRCINFO", r"^\s*pkgver\s*=\s*(\S+)"),
        "flatpak": (ROOT / "packaging/linux/flatpak/io.phasezero.ControlCenter.yml", r"^\s*tag:\s*v(\S+)"),
        "appstream": (ROOT / "packaging/linux/io.phasezero.ControlCenter.metainfo.xml", r'<release version="([^"]+)"'),
    }
    for name, (path, pattern) in checks.items():
        match = re.search(pattern, path.read_text(encoding="utf-8"), re.MULTILINE)
        assert match and match.group(1) == version, name


def test_every_builder_uses_canonical_git_export():
    builders = (
        "install-user.sh", "deb/build-deb.sh", "rpm/build-rpm.sh",
        "arch/build-arch.sh", "appimage/build-appimage.sh", "flatpak/build-flatpak.sh",
    )
    for relative in builders:
        text = (ROOT / "packaging/linux" / relative).read_text(encoding="utf-8")
        assert "export-source.sh" in text, relative


def test_dirty_source_export_overlays_complete_worktree():
    text = (ROOT / "packaging/linux/export-source.sh").read_text(encoding="utf-8")
    assert "ls-files -z --modified --others --exclude-standard" in text
    assert "diff --name-only --diff-filter=D -z" in text
    assert 'tar -C "$ROOT" -cf - -- "${changed[@]}"' in text


def test_user_install_pruning_cannot_abort_completed_install():
    text = (ROOT / "packaging/linux/install-user.sh").read_text(encoding="utf-8")
    assert 'if ! rm -rf -- "$path"' in text


def test_static_action_snapshot_matches_native_catalog():
    from linux.ui_native.catalog import build_catalog

    expected = {action.id for action in build_catalog(ROOT)}
    static = {
        action["name"]
        for action in json.loads((ROOT / "linux/ui/actions.json").read_text(encoding="utf-8"))["actions"]
    }
    assert static == expected


def test_ci_shellcheck_covers_extensionless_entry_points():
    """Selecionar por extensão deixava linux/pz fora do lint.

    O CLI por onde todo o produto é operado não tem sufixo .sh, então nunca era
    verificado, e um defeito ali sobreviveu num arquivo editado o tempo todo.
    """
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    lister = ROOT / "tools/list-shell-scripts.sh"
    assert lister.is_file(), "a descoberta compartilhada sumiu"
    source = lister.read_text(encoding="utf-8")
    assert "git ls-files" in source, "a descoberta precisa usar arquivos versionados"
    assert "(ba)?sh" in source, "scripts sem extensão são achados pelo shebang"
    # Os três passos que varrem scripts têm de usar a mesma lista; um deles
    # (bash -n) é bloqueante e também deixava linux/pz de fora.
    assert workflow.count("tools/list-shell-scripts.sh") >= 3, (
        "algum passo voltou a descobrir scripts por conta própria"
    )
    assert "find . -name '*.sh' -not -path" not in workflow, (
        "a seleção voltou a ser only-by-extension"
    )


def test_extensionless_entry_points_are_shell_and_tracked():
    """Se um destes deixar de existir, o teste acima perde o sentido."""
    import subprocess

    tracked = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split()
    for path in ("linux/pz", "packaging/linux/phasezero-control-center", "packaging/linux/pz"):
        assert path in tracked, f"{path} deixou de ser versionado"
        first = (ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines()[0]
        assert first.startswith("#!") and "sh" in first, f"{path} não tem shebang de shell"


def test_pz_entrypoint_shipped_on_path():
    """PZ-AUD-001: a bridge SSH chama `pz`; todo empacotador instala o wrapper."""
    wrapper = ROOT / "packaging/linux/pz"
    assert wrapper.is_file(), "wrapper packaging/linux/pz sumiu"
    body = wrapper.read_text(encoding="utf-8")
    assert "linux/pz" in body, "wrapper não resolve para linux/pz"
    for path, marker in (
        ("packaging/linux/aur/PKGBUILD", "packaging/linux/pz"),
        ("packaging/linux/deb/build-deb.sh", "packaging/linux/pz"),
        ("packaging/linux/rpm/phasezero-control-center.spec", "packaging/linux/pz"),
        ("packaging/linux/install-user.sh", "packaging/linux/pz"),
    ):
        content = (ROOT / path).read_text(encoding="utf-8")
        assert marker in content, f"{path} não instala o wrapper pz"
    hosts = (ROOT / "linux/server/homelab-hosts.sh").read_text(encoding="utf-8")
    assert "/usr/lib/phasezero/linux/pz" in hosts, "bridge perdeu fallback do pz remoto"
