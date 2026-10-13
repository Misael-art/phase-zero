"""Optional dependencies that degrade a PhaseZero service when absent.

Only dependencies that are genuinely optional belong here: something the
product works without, in a reduced form, and whose absence is a normal state
rather than a defect. A hard requirement should fail loudly at its own call
site instead of being listed as installable.

Each entry says what breaks without it, so a user reading the report can decide
whether they care rather than being told to install something unexplained.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class DepSpec:
    id: str
    title: str
    # What stops working, in the user's terms. Not "library X is missing".
    degrades: str
    # Probe kind: "python" for an importable module, "binary" for $PATH.
    probe: str
    probe_target: str
    # Package name per distro family. A family absent from this map means we do
    # not know the package there and must say so rather than guess a name.
    packages: dict[str, str] = field(default_factory=dict)
    # Provider per family: "official" (default) or "aur". An AUR entry is only
    # installable when an AUR helper is present; never via pacman -S.
    providers: dict[str, str] = field(default_factory=dict)
    # Scenarios where this "optional" dep is a hard requirement. Callers
    # owning those scenarios must fail closed, not degrade silently.
    required_by: tuple[str, ...] = ()


DEPENDENCIES: dict[str, DepSpec] = {
    "pillow": DepSpec(
        id="pillow",
        title="Pillow",
        degrades=(
            "cor de destaque automática a partir do wallpaper; a cor ainda pode "
            "ser informada manualmente"
        ),
        probe="python",
        probe_target="PIL",
        packages={
            "arch": "python-pillow",
            "debian": "python3-pil",
            "fedora": "python3-pillow",
            "suse": "python3-Pillow",
        },
    ),
    "wallpaper-engine-kde": DepSpec(
        id="wallpaper-engine-kde",
        title="Wallpaper Engine para KDE",
        degrades="papéis de parede animados da Steam Workshop no Plasma",
        probe="path",
        probe_target="/usr/share/plasma/wallpapers/com.github.catsout.wallpaperEngineKde",
        # Only packaged for Arch derivatives today, via AUR; elsewhere it is
        # built from source, which is not something to run unattended.
        packages={"arch": "plasma6-wallpapers-wallpaper-engine-git"},
        providers={"arch": "aur"},
    ),
    "qdbus": DepSpec(
        id="qdbus",
        title="qdbus (Qt 6)",
        degrades="leitura e escrita de estado do Plasma: temas e wallpapers",
        probe="binary",
        probe_target="qdbus6",
        packages={
            "arch": "qt6-tools",
            "debian": "qt6-tools-dev-tools",
            "fedora": "qt6-qttools",
        },
    ),
    "libguestfs": DepSpec(
        id="libguestfs",
        title="libguestfs",
        degrades="reparo offline da VM Windows e acesso ao disco do convidado",
        probe="binary",
        probe_target="virt-customize",
        packages={
            "arch": "libguestfs",
            "debian": "libguestfs-tools",
            "fedora": "libguestfs-tools-c",
        },
    ),
    "swtpm": DepSpec(
        id="swtpm",
        title="swtpm",
        degrades="TPM 2.0 na VM Windows; sem ele o Windows 11 recusa instalar",
        probe="binary",
        probe_target="swtpm",
        packages={"arch": "swtpm", "debian": "swtpm", "fedora": "swtpm"},
        # Optional for the product overall, essential for this scenario:
        # WinVM preflight must fail closed on it, not degrade silently.
        required_by=("windows-11-vm",),
    ),
}
