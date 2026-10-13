"""Derivação dos itens da página Linux (apps, serviços e otimizações).

A página não inventa catálogo: cada card vem de uma fonte que já existe e já
sabe informar estado e reverter.

  capability  ->  `pz capabilities status` (instalar/remover com plano, token
                  de confirmação e verificação)
  tuning      ->  `pz tune <area> apply|revert|status`
  action      ->  `ActionSpec` do catálogo da UI, quando o item merece vitrine
                  mas não tem par liga/desliga

O overlay (`hub_overlay.json`) só acrescenta o que o backend não tem como
saber: ordem das seções, ícone, e quais ações entram na vitrine. Ele nunca
inventa item: apontar para um id inexistente é erro de validação, não um card
fantasma.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from .models import ActionSpec

OVERLAY_PATH = Path(__file__).resolve().parent / "hub_overlay.json"

MODES = ("recommended", "opt-in", "advanced")

# Rótulos dos mecanismos de reversão. Os de capability chegam prontos no
# payload (`rollbackLabels`); estes cobrem tuning e ações.
ROLLBACK_LABELS = {
    "package-remove": "Remoção pelo gerenciador de pacotes",
    "flatpak-uninstall": "Desinstalação do Flatpak",
    "service-disable": "Desativação do serviço systemd",
    "backup-file": "Restauração do arquivo original",
    "config-file": "Reescrita do arquivo de configuração",
    "setting-restore": "Devolução do valor anterior",
    "manual": "Reversão manual",
    "none": "Sem reversão automática",
}


class HubOverlayError(ValueError):
    """Overlay inconsistente com o catálogo real."""


@dataclass(frozen=True)
class HubToggle:
    """Um switch e o contrato que o sustenta.

    `kind == "capability"` significa que o fluxo é plan → apply → verify pelo
    motor de capabilities; a página conduz os passos. `kind == "command"` é um
    par direto de argv (usado pelo tuning).
    """

    kind: str  # capability | command
    status_args: tuple[str, ...] = ()
    enable_args: tuple[str, ...] = ()
    disable_args: tuple[str, ...] = ()
    preview_args: tuple[str, ...] = ()
    capability_id: str = ""

    def __post_init__(self) -> None:
        if self.kind not in {"capability", "command"}:
            raise HubOverlayError(f"tipo de toggle inválido: {self.kind}")
        if self.kind == "capability" and not self.capability_id:
            raise HubOverlayError("toggle de capability exige capability_id")
        if self.kind == "command" and not (self.enable_args and self.disable_args):
            raise HubOverlayError("toggle de comando exige enable e disable")


@dataclass(frozen=True)
class HubItem:
    id: str
    kind: str  # capability | tuning | action
    title: str
    description: str
    section: str
    icon: str
    mode: str
    rollback: tuple[str, ...] = ()
    install: HubToggle | None = None
    tune: HubToggle | None = None
    actions: tuple[ActionSpec, ...] = ()
    risk: str = "normal"
    reboot: str = "no"
    requires: tuple[str, ...] = ()
    conflicts: tuple[str, ...] = ()
    icon_explicit: bool = False
    available: bool = True
    reason: str = ""
    installed: bool | None = None
    # Fonte escolhida para o host (pacote ou flatpak). É o que permite achar o
    # ícone real do app: o nome do pacote vira `.desktop`, o app id do Flatpak
    # vira o arquivo exportado.
    source_kind: str = ""
    source_name: str = ""

    @property
    def reversible(self) -> bool:
        """Existe algum mecanismo que o próprio app sabe executar.

        `manual` e `none` não contam: um deles depende do usuário, o outro
        admite que não há volta. Marcar qualquer um como reversível daria selo
        verde a item que ninguém desfaz sozinho.
        """
        return any(kind not in {"manual", "none"} for kind in self.rollback)

    @property
    def rollback_labels(self) -> tuple[str, ...]:
        return tuple(ROLLBACK_LABELS.get(kind, kind) for kind in self.rollback)

    @property
    def searchable_text(self) -> str:
        return " ".join((self.title, self.description, self.section, self.id)).casefold()


def load_overlay(path: Path | None = None) -> dict[str, Any]:
    source = path or OVERLAY_PATH
    payload = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("schema") != 1:
        raise HubOverlayError("overlay do hub requer schema 1")
    for key in ("sections", "capabilities", "tuning", "actions"):
        if key in payload and not isinstance(payload[key], (dict, list)):
            raise HubOverlayError(f"campo {key} com tipo inválido")
    return payload


def _icon_for(overlay_entry: Mapping[str, Any], fallback: str) -> tuple[str, bool]:
    """(ícone, veio do overlay?).

    A distinção importa para a cascata de `icons.resolve_icon`: curadoria
    explícita vence o ícone do app instalado; fallback derivado, não.
    """
    icon = str(overlay_entry.get("icon", "")).strip()
    return (icon, True) if icon else (fallback, False)


def _mode_of(overlay_entry: Mapping[str, Any], derived: str) -> str:
    mode = str(overlay_entry.get("mode", "")).strip()
    if mode and mode not in MODES:
        raise HubOverlayError(f"modo inválido no overlay: {mode}")
    return mode or derived


def _icon_fields(overlay_entry: Mapping[str, Any], fallback: str) -> dict[str, Any]:
    icon, explicit = _icon_for(overlay_entry, fallback)
    return {"icon": icon, "icon_explicit": explicit}


def build_capability_items(
    payload: Mapping[str, Any],
    overlay: Mapping[str, Any],
) -> list[HubItem]:
    """Itens vindos de `pz capabilities status` (ou `catalog`, sem estado).

    `installed` fica `None` quando o payload não trouxe estado: a UI mostra
    "desconhecido" em vez de fingir que o switch está desligado.
    """
    entries = overlay.get("capabilities", {}) or {}
    if not isinstance(entries, dict):
        raise HubOverlayError("overlay.capabilities deve ser objeto")
    items: list[HubItem] = []
    known_ids = {str(item.get("id")) for item in payload.get("capabilities", ())}
    unknown = set(entries) - known_ids
    if unknown:
        raise HubOverlayError(
            f"overlay aponta para capabilities inexistentes: {', '.join(sorted(unknown))}"
        )
    has_status = payload.get("hasStatus") is True
    for raw in payload.get("capabilities", ()):
        capability_id = str(raw.get("id", ""))
        entry = entries.get(capability_id, {})
        if entry.get("hidden"):
            continue
        rollback = tuple(str(kind) for kind in raw.get("rollback", ()))
        source = raw.get("source") or {}
        items.append(HubItem(
            id=capability_id,
            kind="capability",
            title=str(raw.get("title", capability_id)),
            description=str(raw.get("description", "")),
            section=str(entry.get("section") or raw.get("groupTitle") or "Recursos"),
            **_icon_fields(entry, "package-x-generic"),
            mode=_mode_of(entry, str(raw.get("mode", "opt-in"))),
            rollback=rollback or ("none",),
            install=HubToggle(
                kind="capability",
                capability_id=capability_id,
                status_args=("capabilities", "status"),
                preview_args=("capabilities", "plan", "--capability", capability_id),
            ),
            risk=str(raw.get("risk", "normal")),
            reboot=str(raw.get("reboot", "no")),
            requires=tuple(str(value) for value in raw.get("requires", ())),
            conflicts=tuple(str(value) for value in raw.get("conflicts", ())),
            available=bool(raw.get("applicable", False)),
            reason=str(raw.get("reason", "")),
            installed=(
                raw.get("installed")
                if has_status and isinstance(raw.get("installed"), bool)
                else None
            ),
            source_kind=str(source.get("kind", "")),
            source_name=str(source.get("name", "")),
        ))
    return items


def build_tuning_items(overlay: Mapping[str, Any]) -> list[HubItem]:
    entries = overlay.get("tuning", []) or []
    if not isinstance(entries, list):
        raise HubOverlayError("overlay.tuning deve ser lista")
    items: list[HubItem] = []
    for entry in entries:
        area = str(entry.get("area", "")).strip()
        if not area:
            raise HubOverlayError("item de tuning sem área")
        items.append(HubItem(
            id=f"tune.{area}",
            kind="tuning",
            title=str(entry.get("title", area)),
            description=str(entry.get("description", "")),
            section=str(entry.get("section", "Ajustes do sistema")),
            **_icon_fields(entry, "preferences-system"),
            mode=_mode_of(entry, "opt-in"),
            # O contrato do tune-common: arquivo volta do backup, preferência
            # de ferramenta volta ao valor anterior.
            rollback=("backup-file", "setting-restore"),
            tune=HubToggle(
                kind="command",
                status_args=("tune", area, "status"),
                enable_args=("tune", area, "apply"),
                disable_args=("tune", area, "revert"),
                preview_args=("tune", area, "apply", "--dry-run"),
            ),
        ))
    return items


def build_action_items(
    overlay: Mapping[str, Any],
    by_id: Mapping[str, ActionSpec],
) -> list[HubItem]:
    """Itens de vitrine sem par liga/desliga.

    Existem porque parte do valor do projeto (setup de IA, emulação, Flatpak)
    não é um switch: é uma operação. Aparecem no hub com suas ações reais e
    sem switch, em vez de ganharem um botão falso que não sabe desligar.
    """
    entries = overlay.get("actions", []) or []
    if not isinstance(entries, list):
        raise HubOverlayError("overlay.actions deve ser lista")
    items: list[HubItem] = []
    for entry in entries:
        action_ids = tuple(str(value) for value in entry.get("actionIds", ()))
        if not action_ids:
            raise HubOverlayError(f"item de ação sem actionIds: {entry.get('id')}")
        missing = [value for value in action_ids if value not in by_id]
        if missing:
            raise HubOverlayError(
                f"overlay aponta para ações inexistentes: {', '.join(sorted(missing))}"
            )
        primary = by_id[action_ids[0]]
        rollback = tuple(str(value) for value in entry.get("rollback", ())) or ("manual",)
        unknown_rollback = [kind for kind in rollback if kind not in ROLLBACK_LABELS]
        if unknown_rollback:
            raise HubOverlayError(
                f"mecanismo de rollback desconhecido: {', '.join(sorted(unknown_rollback))}"
            )
        items.append(HubItem(
            id=str(entry.get("id") or primary.id),
            kind="action",
            title=str(entry.get("title") or primary.title),
            description=str(entry.get("description") or primary.description),
            section=str(entry.get("section", "Ferramentas")),
            **_icon_fields(entry, primary.icon),
            mode=_mode_of(entry, "advanced" if primary.visibility == "advanced" else "opt-in"),
            rollback=rollback,
            actions=tuple(by_id[value] for value in action_ids),
            risk=primary.risk,
        ))
    return items


def section_order(overlay: Mapping[str, Any]) -> tuple[str, ...]:
    sections = overlay.get("sections", []) or []
    if not isinstance(sections, list):
        raise HubOverlayError("overlay.sections deve ser lista")
    return tuple(str(value) for value in sections)


def build_hub_items(
    capabilities_payload: Mapping[str, Any] | None,
    by_id: Mapping[str, ActionSpec],
    overlay: Mapping[str, Any] | None = None,
) -> list[HubItem]:
    """Todos os cards do hub, na ordem das seções do overlay.

    `capabilities_payload` pode ser None quando o host ainda não respondeu: o
    hub abre com tuning e ações em vez de uma página vazia.
    """
    data = overlay if overlay is not None else load_overlay()
    items: list[HubItem] = []
    if capabilities_payload:
        items.extend(build_capability_items(capabilities_payload, data))
    items.extend(build_tuning_items(data))
    items.extend(build_action_items(data, by_id))
    order = section_order(data)
    rank = {name: index for index, name in enumerate(order)}
    items.sort(key=lambda item: (
        rank.get(item.section, len(rank)),
        item.section,
        MODES.index(item.mode) if item.mode in MODES else len(MODES),
        item.title.casefold(),
    ))
    return items


def group_by_section(items: Iterable[HubItem]) -> dict[str, list[HubItem]]:
    grouped: dict[str, list[HubItem]] = {}
    for item in items:
        grouped.setdefault(item.section, []).append(item)
    return grouped
