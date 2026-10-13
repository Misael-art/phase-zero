from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.icons import (
    IconRef,
    desktop_dirs,
    find_desktop_icon,
    resolve_icon,
)
from linux.ui_native.linux_hub import HubItem


def item(**changes) -> HubItem:
    base = dict(
        id="gaming.mangohud",
        kind="capability",
        title="MangoHud",
        description="Overlay de desempenho.",
        section="Gaming e streaming",
        icon="package-x-generic",
        mode="recommended",
        rollback=("package-remove",),
        source_kind="package",
        source_name="mangohud",
    )
    base.update(changes)
    return HubItem(**base)


@pytest.fixture
def apps(tmp_path) -> Path:
    directory = tmp_path / "share" / "applications"
    directory.mkdir(parents=True)
    return directory


def write_entry(directory: Path, name: str, icon: str, extra: str = "") -> Path:
    path = directory / f"{name}.desktop"
    path.write_text(
        "[Desktop Entry]\n"
        "Type=Application\n"
        f"Name={name}\n"
        f"Icon={icon}\n"
        f"{extra}",
        encoding="utf-8",
    )
    return path


def test_desktop_entry_icon_wins_over_generic_fallback(apps):
    write_entry(apps, "mangohud", "io.github.flightlessmango.MangoHud")
    ref = resolve_icon(item(), roots=[apps])
    assert ref == IconRef("theme", "io.github.flightlessmango.MangoHud", "desktop")
    assert ref.is_original


def test_flatpak_app_id_matches_exported_entry(apps):
    write_entry(apps, "com.moonlight_stream.Moonlight", "com.moonlight_stream.Moonlight")
    ref = resolve_icon(
        item(source_kind="flatpak", source_name="com.moonlight_stream.Moonlight"),
        roots=[apps],
    )
    assert ref.origin == "desktop"
    assert ref.value == "com.moonlight_stream.Moonlight"


def test_versioned_package_name_falls_back_to_prefix(apps):
    write_entry(apps, "dotnet", "dotnet-logo")
    ref = resolve_icon(item(source_name="dotnet-sdk-8.0"), roots=[apps])
    assert ref == IconRef("theme", "dotnet-logo", "desktop")


def test_overlay_icon_beats_the_installed_app_icon(apps):
    write_entry(apps, "mangohud", "algum-icone-do-app")
    ref = resolve_icon(item(icon_explicit=True), overlay_icon="applications-games", roots=[apps])
    assert ref == IconRef("theme", "applications-games", "overlay")


def test_absolute_icon_path_outside_allowed_roots_is_refused(apps, tmp_path):
    # `.desktop` é dado de terceiro: um Icon= apontando para fora das raízes
    # conhecidas não pode virar caminho que a UI carrega.
    intruder = tmp_path / "intruso.png"
    intruder.write_bytes(b"\x89PNG\r\n\x1a\n")
    write_entry(apps, "mangohud", str(intruder))
    ref = resolve_icon(item(), roots=[apps])
    assert ref.kind == "theme"
    assert ref.value != str(intruder)
    # Cai para o passo seguinte da cascata (nome da fonte no tema), não para o
    # caminho recusado.
    assert ref.origin == "source"


def test_absolute_icon_path_inside_share_is_accepted(apps):
    icons = apps.parent / "icons"
    icons.mkdir()
    logo = icons / "mangohud.png"
    logo.write_bytes(b"\x89PNG\r\n\x1a\n")
    write_entry(apps, "mangohud", str(logo))
    ref = resolve_icon(item(), roots=[apps])
    assert ref == IconRef("file", str(logo), "desktop")


def test_missing_entry_falls_back_to_source_then_section(apps):
    # Sem `.desktop`, tenta o nome da fonte no tema; se o tema não tem, usa o
    # ícone semântico da seção — nunca um genérico solto.
    assert resolve_icon(item(), roots=[apps]).origin == "source"
    ref = resolve_icon(item(), roots=[apps], has_theme_icon=lambda name: False)
    assert ref == IconRef("theme", "applications-games", "section")


def test_item_without_source_uses_section_icon(apps):
    ref = resolve_icon(
        item(kind="tuning", source_kind="", source_name="", section="Desenvolvimento"),
        roots=[apps],
    )
    assert ref == IconRef("theme", "applications-development", "section")


def test_unknown_section_falls_back_to_declared_icon(apps):
    ref = resolve_icon(
        item(source_kind="", source_name="", section="Seção Inventada", icon="minha-icone"),
        roots=[apps],
    )
    assert ref == IconRef("theme", "minha-icone", "generic")


def test_entry_without_icon_key_is_ignored(apps):
    (apps / "mangohud.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=MangoHud\n", encoding="utf-8",
    )
    assert find_desktop_icon("package", "mangohud", [apps]) == ("", None)


def test_icon_key_outside_desktop_entry_section_is_ignored(apps):
    (apps / "mangohud.desktop").write_text(
        "[Desktop Entry]\nType=Application\nName=MangoHud\n"
        "[Desktop Action Extra]\nIcon=icone-da-acao\n",
        encoding="utf-8",
    )
    assert find_desktop_icon("package", "mangohud", [apps]) == ("", None)


def test_oversized_entry_is_refused(apps):
    path = apps / "mangohud.desktop"
    path.write_text("[Desktop Entry]\nIcon=x\n" + "#" * (300 * 1024), encoding="utf-8")
    assert find_desktop_icon("package", "mangohud", [apps]) == ("", None)


def test_desktop_dirs_include_flatpak_exports(tmp_path):
    data_home = tmp_path / "data"
    for relative in ("applications", "flatpak/exports/share/applications"):
        (data_home / relative).mkdir(parents=True)
    system = tmp_path / "usr/share/applications"
    system.mkdir(parents=True)
    roots = desktop_dirs({
        "HOME": str(tmp_path),
        "XDG_DATA_HOME": str(data_home),
        "XDG_DATA_DIRS": str(system.parent),
    })
    assert data_home / "applications" in roots
    assert data_home / "flatpak/exports/share/applications" in roots
    assert system in roots
