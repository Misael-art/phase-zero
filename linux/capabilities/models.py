from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class SourceSpec:
    kind: str
    name: str
    distros: tuple[str, ...] = ()
    version: str = "repository"
    sha256: str = "repository-signature"
    remote: str = ""

    def validate(self) -> None:
        if self.kind not in {"package", "flatpak"}:
            raise ValueError(f"fonte executável não permitida: {self.kind}")
        if not self.name or any(character.isspace() for character in self.name):
            raise ValueError(f"nome de fonte inválido: {self.name!r}")
        if not self.version or not self.sha256:
            raise ValueError(f"fonte sem política de versão/integridade: {self.name}")
        if self.kind == "flatpak" and not self.remote:
            raise ValueError(f"Flatpak sem remote explícito: {self.name}")


@dataclass(frozen=True)
class Compatibility:
    distros: tuple[str, ...] = ()
    gpu: tuple[str, ...] = ()
    desktops: tuple[str, ...] = ()
    sessions: tuple[str, ...] = ()
    init: tuple[str, ...] = ()
    immutable: str = "supported"  # supported | layered | blocked
    container: str = "blocked"    # supported | blocked


@dataclass(frozen=True)
class CapabilitySpec:
    id: str
    title: str
    description: str
    group: str
    sources: tuple[SourceSpec, ...]
    compatibility: Compatibility = field(default_factory=Compatibility)
    requires: tuple[str, ...] = ()
    conflicts: tuple[str, ...] = ()
    reboot: str = "no"  # no | recommended | required
    risk: str = "normal"
    license: str = "upstream"
    keywords: tuple[str, ...] = ()
    # Vazio significa "derive de risco/reboot/perfis" (ver catalog.mode_for).
    # Preencher só quando a curadoria discordar da derivação.
    mode: str = ""  # recommended | opt-in | advanced

    def validate(self) -> None:
        if not self.id or self.id != self.id.casefold() or " " in self.id:
            raise ValueError(f"ID de capability inválido: {self.id!r}")
        if not self.sources:
            raise ValueError(f"capability sem fonte: {self.id}")
        if self.risk not in {"normal", "elevated", "high"}:
            raise ValueError(f"risco inválido: {self.id}")
        if self.reboot not in {"no", "recommended", "required"}:
            raise ValueError(f"reboot inválido: {self.id}")
        if self.compatibility.immutable not in {"supported", "layered", "blocked"}:
            raise ValueError(f"política immutable inválida: {self.id}")
        if self.mode not in {"", "recommended", "opt-in", "advanced"}:
            raise ValueError(f"modo inválido: {self.id}")
        for source in self.sources:
            source.validate()

