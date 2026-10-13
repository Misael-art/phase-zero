from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.capabilities.engine import catalog_payload
from linux.capabilities.platform import HostFacts
from linux.ui_native.catalog import build_catalog
from linux.ui_native.linux_hub import (
    HubOverlayError,
    build_hub_items,
    build_capability_items,
    group_by_section,
    load_overlay,
    section_order,
)


@pytest.fixture(scope="module")
def by_id():
    return {action.id: action for action in build_catalog(ROOT)}


@pytest.fixture(scope="module")
def overlay():
    return load_overlay()


def facts() -> HostFacts:
    return HostFacts(
        platform="linux",
        architecture="x86_64",
        distro="arch",
        distro_like=(),
        package_family="arch",
        immutable=False,
        immutable_kind="",
        container=False,
        init="systemd",
        desktop="kde",
        session="wayland",
        gpus=("amd",),
        package_manager="pacman",
        flatpak=True,
        flathub=True,
    )


class ProbeProvider:
    def __init__(self, state):
        self.state = state

    def installed(self, source):
        return self.state


def payload() -> dict:
    return catalog_payload(facts=facts())


def test_overlay_only_references_ids_that_exist(overlay, by_id):
    # A regra que impede catálogo fantasma: overlay acrescenta metadado, nunca
    # cria item. Um id morto tem de quebrar aqui, não virar card vazio na UI.
    for entry in overlay.get("actions", ()):
        for action_id in entry["actionIds"]:
            assert action_id in by_id, f"ação inexistente no overlay: {action_id}"
    known = {item["id"] for item in payload()["capabilities"]}
    for capability_id in overlay.get("capabilities", {}):
        assert capability_id in known, f"capability inexistente: {capability_id}"


def test_overlay_with_unknown_action_is_rejected(by_id):
    broken = {
        "schema": 1,
        "sections": [],
        "actions": [{"id": "x", "actionIds": ["nao.existe"], "rollback": ["manual"]}],
    }
    with pytest.raises(HubOverlayError, match="ações inexistentes"):
        build_hub_items(None, by_id, broken)


def test_overlay_with_unknown_capability_is_rejected(by_id):
    broken = {"schema": 1, "sections": [], "capabilities": {"nao.existe": {}}}
    with pytest.raises(HubOverlayError, match="capabilities inexistentes"):
        build_hub_items(payload(), by_id, broken)


def test_overlay_with_unknown_rollback_mechanism_is_rejected(by_id):
    broken = {
        "schema": 1,
        "sections": [],
        "actions": [{
            "id": "x",
            "actionIds": ["system.doctor"],
            "rollback": ["defender-exclusion"],
        }],
    }
    with pytest.raises(HubOverlayError, match="rollback desconhecido"):
        build_hub_items(None, by_id, broken)


def test_every_item_carries_mode_and_rollback(overlay, by_id):
    items = build_hub_items(payload(), by_id, overlay)
    assert items
    for item in items:
        assert item.mode in {"recommended", "opt-in", "advanced"}
        assert item.rollback, f"{item.id} sem mecanismo de rollback declarado"
        assert item.rollback_labels
        assert item.icon


def test_toggles_only_exist_where_the_backend_can_turn_things_off(overlay, by_id):
    items = build_hub_items(payload(), by_id, overlay)
    for item in items:
        if item.kind == "capability":
            assert item.install is not None and item.install.kind == "capability"
            assert item.tune is None
        elif item.kind == "tuning":
            # O par tem de existir: switch que só liga é mentira de UI.
            assert item.tune is not None
            assert item.tune.enable_args and item.tune.disable_args
            assert item.tune.status_args and item.tune.preview_args
            assert item.install is None
        else:
            assert item.install is None and item.tune is None
            assert item.actions, "item de vitrine precisa de ações reais"


def test_tuning_items_match_the_pz_tune_contract(overlay, by_id):
    items = {item.id: item for item in build_hub_items(None, by_id, overlay)}
    gaming = items["tune.gaming"]
    assert gaming.tune.enable_args == ("tune", "gaming", "apply")
    assert gaming.tune.disable_args == ("tune", "gaming", "revert")
    assert gaming.tune.status_args == ("tune", "gaming", "status")
    assert gaming.tune.preview_args == ("tune", "gaming", "apply", "--dry-run")
    assert gaming.reversible


def test_catalog_without_status_reports_unknown_instead_of_off(overlay):
    data = payload()
    data["hasStatus"] = False
    items = build_capability_items(data, overlay)
    assert items
    assert all(item.installed is None for item in items)


def test_catalog_probe_failure_remains_unknown(overlay):
    data = payload()
    data["hasStatus"] = True
    data["capabilities"][0]["installed"] = None
    items = build_capability_items(data, overlay)
    assert items[0].installed is None


def test_missing_or_malformed_status_marker_cannot_claim_absence(overlay):
    data = {"capabilities": [{"id": "gaming.gamemode", "installed": False}]}
    assert build_capability_items(data, overlay)[0].installed is None
    data["hasStatus"] = "true"
    assert build_capability_items(data, overlay)[0].installed is None


def test_catalog_payload_marks_whether_it_probed_the_host(overlay):
    # `catalog` não sonda: o hub tem de mostrar "desconhecido". `status` sonda:
    # aí sim o switch pode afirmar ligado/desligado.
    assert catalog_payload(facts=facts())["hasStatus"] is False
    probed = catalog_payload(
        facts=facts(), include_status=True, provider=ProbeProvider(False),
    )
    assert probed["hasStatus"] is True
    items = build_capability_items(probed, overlay)
    assert all(item.installed in (True, False) for item in items)


def test_package_probe_error_remains_unknown_through_catalog_and_hub(overlay):
    probed = catalog_payload(
        facts=facts(), include_status=True, provider=ProbeProvider(None),
    )
    assert probed["capabilities"][0]["installationState"] == "unknown"
    assert probed["capabilities"][0]["installed"] is None
    items = build_capability_items(probed, overlay)
    assert items[0].installed is None


def test_items_are_ordered_by_overlay_sections(overlay, by_id):
    items = build_hub_items(payload(), by_id, overlay)
    order = section_order(overlay)
    seen = [item.section for item in items if item.section in order]
    ranks = [order.index(name) for name in seen]
    assert ranks == sorted(ranks)
    grouped = group_by_section(items)
    assert "Ajustes do sistema" not in grouped or grouped["Ajustes do sistema"]
    for section_items in grouped.values():
        modes = [item.mode for item in section_items]
        # Dentro da seção, recomendados primeiro: é a leitura que o usuário faz.
        assert modes == sorted(modes, key=lambda mode: ("recommended", "opt-in", "advanced").index(mode))


def test_shipped_overlay_is_valid_json_schema_1():
    raw = json.loads((ROOT / "linux/ui_native/hub_overlay.json").read_text(encoding="utf-8"))
    assert raw["schema"] == 1
    assert raw["sections"]
    assert {entry["area"] for entry in raw["tuning"]} == {"gaming", "browser", "dev"}


def test_manual_and_none_are_not_counted_as_reversible(overlay, by_id):
    items = {item.id: item for item in build_hub_items(payload(), by_id, overlay)}
    # Selo verde só para o que o app desfaz sozinho.
    assert items["hub.flatpak"].rollback == ("manual",)
    assert items["hub.flatpak"].reversible is False
    assert items["hub.host-health"].rollback == ("none",)
    assert items["hub.host-health"].reversible is False
    assert items["tune.gaming"].reversible is True
