from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


SCHEMA_VERSION = "windows-vm-graphics/v1"
DEFAULT_CONTRACT_PATH = Path(__file__).resolve().parents[1] / "windows-vm" / "graphics-profiles.json"


class GraphicsContractError(ValueError):
    """Raised when the installed graphics contract is absent or malformed."""


@dataclass(frozen=True)
class GraphicsProfile:
    id: str
    label: str
    helper_text: str
    provision_supported: bool
    apply_supported: bool
    plan_supported: bool
    mode: str


def load_graphics_profiles(path: Path | None = None) -> tuple[GraphicsProfile, ...]:
    contract_path = path or DEFAULT_CONTRACT_PATH
    try:
        payload = json.loads(contract_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GraphicsContractError(f"contrato gráfico ausente ou inválido: {contract_path}") from exc

    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise GraphicsContractError(f"schema gráfico incompatível: {contract_path}")
    raw_profiles = payload.get("profiles")
    if not isinstance(raw_profiles, list) or not raw_profiles:
        raise GraphicsContractError(f"lista de perfis gráficos inválida: {contract_path}")

    profiles: list[GraphicsProfile] = []
    seen: set[str] = set()
    for raw in raw_profiles:
        if not isinstance(raw, dict):
            raise GraphicsContractError(f"perfil gráfico inválido: {contract_path}")
        profile_id = raw.get("id")
        label = raw.get("label")
        helper_text = raw.get("helperText")
        mode = raw.get("mode")
        flags = (
            raw.get("provisionSupported"),
            raw.get("applySupported"),
            raw.get("planSupported"),
        )
        if (
            not isinstance(profile_id, str)
            or not profile_id
            or profile_id in seen
            or not isinstance(label, str)
            or not label
            or not isinstance(helper_text, str)
            or not helper_text
            or not isinstance(mode, str)
            or not mode
            or not all(isinstance(flag, bool) for flag in flags)
        ):
            raise GraphicsContractError(f"perfil gráfico inválido: {contract_path}")
        seen.add(profile_id)
        profiles.append(
            GraphicsProfile(
                id=profile_id,
                label=label,
                helper_text=helper_text,
                provision_supported=flags[0],
                apply_supported=flags[1],
                plan_supported=flags[2],
                mode=mode,
            )
        )
    return tuple(profiles)


def provision_graphics_options(path: Path | None = None) -> tuple[tuple[str, str, str], ...]:
    return tuple(
        (profile.id, profile.label, profile.helper_text)
        for profile in load_graphics_profiles(path)
        if profile.provision_supported
    )


# ---------------------------------------------------------------- UX-010
def host_profile_state(status: dict | None, profile_id: str) -> tuple[str, tuple[str, ...]]:
    """``(mode, blockers)`` this host reports for one profile.

    The host is the authority: ``windows-vm graphics status --json`` knows
    whether the render node, the QEMU device and the guest driver are
    actually there. An empty status means "not measured yet", never "fine".
    """
    profiles = (status or {}).get("profiles")
    entry = profiles.get(profile_id) if isinstance(profiles, dict) else None
    if not isinstance(entry, dict):
        return "", ()
    blockers = entry.get("blockers")
    blockers = tuple(str(b) for b in blockers) if isinstance(blockers, list) else ()
    if entry.get("eligible") is False:
        return "blocked", blockers
    return str(entry.get("mode") or ""), blockers


def recommended_profile(status: dict | None) -> tuple[str, str]:
    """``(profile_id, reason)`` recommended by the host, or the safe default.

    Without a measurement the recommendation is the compatible profile: a
    guest with no proven 3D must never be presented as accelerated.
    """
    recommended = (status or {}).get("recommended")
    if isinstance(recommended, dict) and recommended.get("profile"):
        return str(recommended["profile"]), str(recommended.get("note") or "")
    return "compat", "Sem medição do host: fica no perfil compatível, que funciona em qualquer máquina."


def simple_graphics_options(
    status: dict | None, path: Path | None = None,
) -> tuple[tuple[str, str, str], ...]:
    """Profiles offered in simple mode: stable on THIS host, nothing else.

    A profile the contract calls stable but the host reports experimental
    or blocked is not offered here — the promise has to survive contact
    with the machine it will run on. Experimental profiles stay in the
    advanced list, where they are labelled as such.
    """
    offered: list[tuple[str, str, str]] = []
    for profile in load_graphics_profiles(path):
        if not profile.provision_supported or profile.mode != "stable":
            continue
        host_mode, _blockers = host_profile_state(status, profile.id)
        if host_mode and host_mode != "stable":
            continue
        offered.append((profile.id, profile.label, profile.helper_text))
    return tuple(offered)
