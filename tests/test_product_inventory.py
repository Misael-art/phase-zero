from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import build_catalog
from linux.ui_native.models import ProductInstance
from linux.ui_native.product_inventory import (
    instances_from_capability_status, instances_from_status_payload,
    inventory, inventory_manifest, render_inventory_manifest,
    status_action_matches_app, target_for,
)


def test_every_action_has_exactly_one_target_and_snapshot_is_current():
    payload = inventory_manifest(ROOT)
    saved = json.loads((ROOT / "linux/ui_native/product_inventory.json").read_text(encoding="utf-8"))
    assert saved == payload
    assert payload["actionCount"] == len(build_catalog(ROOT))
    assert len({item["actionId"] for item in payload["actions"]}) == payload["actionCount"]
    assert json.loads(render_inventory_manifest(payload)) == payload
    assert all(len(item["installationAuthorityIds"]) <= 1 for item in payload["products"])


def test_install_routes_have_one_authority_per_app_scope():
    payload = inventory_manifest(ROOT)
    app_actions = {item.id: item for item in build_catalog(ROOT)}
    grouped = {}
    for action in payload["actions"]:
        authority = action["installationAuthorityId"]
        if not authority:
            continue
        key = (action["targetId"], action["instanceScope"])
        grouped.setdefault(key, set()).add(authority)
    assert grouped
    assert all(len(authorities) == 1 for authorities in grouped.values())
    assert all(
        action["installationAuthorityId"]
        for action in payload["actions"]
        if action["targetKind"] == "app"
        and "watchdog" not in action["actionId"]
        and any(verb in app_actions[action["actionId"]].args for verb in ("install", "setup"))
    )


def test_existing_shortcuts_converge_on_one_product():
    rows = {row.action_id: row for row in inventory(build_catalog(ROOT))}
    assert rows["ai.ollama"].target_id == rows["server.llm"].target_id == "app.ollama"
    assert rows["ai.hermes-status"].target_id == rows["server.hermes"].target_id == "app.hermes"
    assert rows["capability.plan.development.vscode"].target_id == "app.vscode"
    assert rows["capability.plan.development.vscodium"].target_id == "app.vscodium"


def test_open_webui_usage_routes_are_not_advertised_without_request_grant_support():
    actions = {action.id: action for action in build_catalog(ROOT)}

    assert actions["ai.webui"].title == "Uso bloqueado — Open WebUI"
    assert actions["ai.webui-open"].title == "Uso bloqueado — Open WebUI"
    assert "webui" not in actions["ai.setup.tool"].parameters[0].choices
    assert actions["ai.webui-status"].status_args == ("ai", "webui", "status")
    observed = instances_from_status_payload(
        {"hasStatus": True, "installationState": "present", "configurationState": "ready",
         "health": "online", "usageBlocked": True,
         "blockedReason": "connection-grant-not-enforceable"},
        app_id="app.open-webui", host_id="local", scope="local",
    )[0]
    assert observed.next_action == "open"
    assert observed.ready is False
    assert observed.to_dict()["usageBlocked"] is True
    assert observed.to_dict()["blockedReason"] == "connection-grant-not-enforceable"


def test_hermes_consumption_and_setup_wait_for_request_bound_grants():
    actions = {action.id: action for action in build_catalog(ROOT)}

    assert "hermes" not in actions["ai.setup.tool"].parameters[0].choices
    assert "bloqueado" in actions["server.hermes.start"].title.casefold()
    observed = instances_from_status_payload(
        {"id": "hermes", "installed": True, "configured": True,
         "healthy": True, "ready": False, "usageBlocked": True,
         "blockedReason": "connection-grant-not-enforceable"},
        app_id="app.hermes", host_id="local", scope="local",
    )[0]
    assert observed.next_action == "open"
    assert observed.ready is False
    assert observed.to_dict()["usageBlocked"] is True
    assert observed.to_dict()["blockedReason"] == "connection-grant-not-enforceable"


def test_openclaw_setup_is_not_offered_without_request_bound_grants():
    actions = {action.id: action for action in build_catalog(ROOT)}
    assert "openclaw" not in actions["ai.setup.tool"].parameters[0].choices


def test_chatgpt_codex_bridge_stays_unlisted_until_browser_only_gate_passes():
    catalog = build_catalog(ROOT)
    payload = inventory_manifest(ROOT)
    public_surface = json.dumps({
        "actions": [
            {"id": item.id, "title": item.title, "description": item.description,
             "args": item.args}
            for item in catalog
        ],
        "products": payload["products"],
    }, ensure_ascii=False).casefold()

    assert "codex-chatgpt-web" not in public_surface
    assert "chatgpt no codex" not in public_surface
    assert "ai.desktop.codex.status" in {item.id for item in catalog}


def test_every_non_capability_app_has_an_explicit_product_status_probe():
    actions = {action.id: action for action in build_catalog(ROOT)}
    payload = inventory_manifest(ROOT)
    unsupported = []
    for product in payload["products"]:
        app_id = product["appId"]
        if product["capabilityId"] is not None:
            continue
        probes = [
            actions[action_id]
            for action_id in product["actionIds"]
            if action_id in actions
            and status_action_matches_app(actions[action_id], app_id)
            and actions[action_id].status_args
            and not actions[action_id].mutable
            and (action_id.endswith("status") or ".status." in action_id)
        ]
        if not probes:
            unsupported.append(app_id)
    assert unsupported == []

    expected = {
        "app.ai-memory": ("ai.memory-status", "ai-memory"),
        "app.usagebar": ("ai.usagebar-status", "usagebar"),
        "app.claude-desktop": ("ai.desktop.claude.status", "claude-desktop"),
        "app.codex-desktop": ("ai.desktop.codex.status", "codex-desktop"),
        "app.qwen-code-desktop": ("ai.desktop.qwen.status", "qwen-code-desktop"),
    }
    for app_id, (action_id, slug) in expected.items():
        action = actions[action_id]
        assert action.status_args == ("ai", "product-status", slug)
        assert status_action_matches_app(action, app_id)


def test_product_status_normalizers_preserve_unknown_installation_evidence(tmp_path, monkeypatch):
    from linux.ai.product_status import normalize_payload

    desktop = normalize_payload("claude-desktop", {
        "claudeDesktop": {"installed": False, "launcherOk": False, "desktopEntryOk": False},
    })
    assert desktop["hasStatus"] is True
    assert desktop["installationState"] == "unknown"
    assert desktop["origin"] == "unknown"
    assert desktop["health"] == "unknown"
    managed_desktop = normalize_payload("claude-desktop", {
        "claudeDesktop": {
            "installed": True, "version": "1.0", "launcherOk": True,
            "desktopEntryOk": True,
        },
    })
    assert managed_desktop["installationState"] == "present"
    assert managed_desktop["configurationState"] == "ready"
    assert managed_desktop["health"] == "unknown"
    assert managed_desktop["launchable"] is True

    qwen_launcher = tmp_path / "qwen-code-desktop"
    qwen_binary = tmp_path / "Qwen-Code-Desktop.AppImage"
    qwen_launcher.write_text("#!/bin/sh\n", encoding="utf-8")
    qwen_binary.write_text("fixture", encoding="utf-8")
    qwen_launcher.chmod(0o755)
    qwen_binary.chmod(0o755)
    qwen = normalize_payload("qwen-code-desktop", {
        "qwenCodeDesktop": {
            "installed": True, "version": "1.0", "launcher": str(qwen_launcher),
            "binary": str(qwen_binary),
        },
    })
    assert qwen["configurationState"] == "ready"
    assert qwen["launchable"] is True

    usagebar = normalize_payload("usagebar", {
        "available": True, "version": "1.2", "configPath": str(tmp_path / "config.toml"),
        "configExists": True,
    })
    assert usagebar["installationState"] == "present"
    assert usagebar["origin"] == "unknown"
    assert usagebar["configurationState"] == "unknown"
    config_path = tmp_path / "managed-config.toml"
    config_path.write_text("# PhaseZero managed ai-usagebar config.\n", encoding="utf-8")
    managed_usagebar = normalize_payload("usagebar", {
        "available": True, "version": "1.2", "configPath": str(config_path),
        "configExists": True,
    })
    assert managed_usagebar["configurationState"] == "ready"

    home = tmp_path / "home"
    xdg_state = home / ".local/state"
    binary = home / ".local/bin/ai-memory"
    binary.parent.mkdir(parents=True)
    binary.write_text("fixture", encoding="utf-8")
    manifest_path = xdg_state / "phasezero/ai/ai-memory-install.json"
    manifest_path.parent.mkdir(parents=True)
    manifest_path.write_text(json.dumps({"path": str(binary), "version": "1.31.1"}), encoding="utf-8")
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_STATE_HOME", str(xdg_state))
    memory = normalize_payload("ai-memory", {
        "installed": True, "commandPath": str(binary), "version": "ai-memory 1.31.1",
        "configuredMarker": True, "serverReachable": False,
        "integrations": {"ok": True},
    })
    assert memory["installationState"] == "present"
    assert memory["origin"] == "phasezero"
    assert memory["configurationState"] == "ready"
    assert memory["health"] == "offline"

    codex = normalize_payload("codex-desktop", {"codexDesktop": {"installedVersion": "1.0"}})
    assert codex["installationState"] == "unknown"
    assert codex["origin"] == "unknown"


def test_launchable_status_requires_present_configured_instance():
    launchable = instances_from_status_payload(
        {"hasStatus": True, "installationState": "present", "origin": "phasezero",
         "configurationState": "ready", "health": "unknown", "launchable": True},
        app_id="app.claude-desktop", host_id="local", scope="local",
    )[0]
    assert launchable.next_action == "open"
    assert launchable.health == "unknown"
    assert launchable.to_dict()["launchable"] is True

    uninstalled = instances_from_status_payload(
        {"hasStatus": True, "installationState": "absent", "launchable": True},
        app_id="app.claude-desktop", host_id="local", scope="local",
    )[0]
    assert uninstalled.launchable is False
    assert uninstalled.next_action == "prepare"


def test_ollama_has_one_canonical_host_installer_across_legacy_contexts():
    payload = inventory_manifest(ROOT)
    actions = {item["actionId"]: item for item in payload["actions"]}
    product = next(item for item in payload["products"] if item["appId"] == "app.ollama")
    authority = next(
        item for item in payload["installationAuthorities"]
        if item["appId"] == "app.ollama" and item["instanceScope"] == "host"
    )

    assert product["canonicalActionId"] == "ai.ollama"
    assert product["actionIds"] == sorted(("ai.ollama", "server.llm", "server.llm.expose",
                                           "server.llm.restore", "server.llm.status"))
    assert actions["ai.ollama"]["role"] == "canonical"
    assert actions["server.llm"]["role"] == "shortcut"
    assert actions["ai.ollama"]["instanceScope"] == actions["server.llm"]["instanceScope"] == "host"
    assert actions["ai.ollama"]["installationAuthorityId"] == "linux/ai/setup-ollama.sh"
    assert actions["server.llm"]["installationAuthorityId"] == "linux/ai/setup-ollama.sh"
    assert authority["actionIds"] == ["ai.ollama", "server.llm"]


def test_comparison_groups_only_include_curated_same_function_apps():
    payload = inventory_manifest(ROOT)
    groups = {item["id"]: item["appIds"] for item in payload["comparisonCategories"]}
    assert groups == {
        "code-editor": ["app.vscode", "app.vscodium"],
        "mesh-network": ["app.tailscale", "app.zerotier"],
        "web-browser": ["app.brave", "app.librewolf"],
    }
    categories = {item["appId"]: item["comparisonCategory"] for item in payload["products"]}
    assert categories["app.ollama"] is None
    assert categories["app.9router"] is None


def test_managed_desktop_entry_hints_are_exact_app_ids():
    products = {item["appId"]: item for item in inventory_manifest(ROOT)["products"]}
    assert products["app.claude-desktop"]["desktopEntries"] == ["claude-desktop"]
    assert products["app.qwen-code-desktop"]["desktopEntries"] == ["qwen-code-desktop"]


def test_unclassified_action_fails_closed():
    from dataclasses import replace

    action = build_catalog(ROOT)[0]
    try:
        target_for(replace(action, id="unknown.new-action"))
    except ValueError as error:
        assert "unclassified action" in str(error)
    else:
        raise AssertionError("unknown action was silently accepted")


def test_generated_hub_actions_resolve_same_app_as_static_capability():
    from dataclasses import replace

    action = build_catalog(ROOT)[0]
    for operation in ("install", "remove"):
        row = target_for(replace(action, id=f"hub.capability.{operation}.development.vscode"))
        assert row.target_id == "app.vscode"
        assert row.instance_scope == "host"
    assert target_for(replace(action, id="hub.capabilities.status")).target_id == "journey.capabilities"


def test_dynamic_hub_install_routes_reuse_canonical_capability_authority():
    from dataclasses import replace

    from linux.capabilities.catalog import CAPABILITIES
    from linux.ui_native.product_inventory import _installation_authority

    template = build_catalog(ROOT)[0]
    manifest = inventory_manifest(ROOT)
    assert manifest["dynamicInstallationAuthorities"] == [
        {"pattern": "hub.capability.install.<capabilityId>",
         "authorityId": "linux/capabilities/engine.py"}
    ]
    static_rows = {row.action_id: row for row in inventory(build_catalog(ROOT))}
    for capability in CAPABILITIES:
        dynamic = replace(template, id=f"hub.capability.install.{capability.id}",
                          args=("capabilities", "apply", "--plan-id", "{plan_id}",
                                "--confirm", "{confirm}"))
        row = target_for(dynamic)
        canonical = static_rows[f"capability.plan.{capability.id}"]
        assert row.target_id == canonical.target_id
        assert row.role == "shortcut"
        assert row.instance_scope == canonical.instance_scope == "host"
        assert _installation_authority(row, dynamic) == "linux/capabilities/engine.py"


def test_two_instances_share_one_product_without_merging_host_or_owner():
    local = ProductInstance("local:ollama", "app.ollama", "local", "user",
                            installation="present", origin="external", configuration="unknown")
    homelab = ProductInstance("homelab:ollama", "app.ollama", "homelab", "service",
                              installation="present", origin="phasezero",
                              configuration="ready", health="online")
    assert local.app_id == homelab.app_id
    assert local.instance_id != homelab.instance_id
    assert local.next_action == "verify"
    assert not local.ready
    assert homelab.next_action == "open"


def test_capability_catalog_does_not_fake_absence_or_ownership():
    base = {"capabilities": [{"id": "development.vscode", "installed": False,
                               "source": {"kind": "package"}}]}
    unprobed = instances_from_capability_status({**base, "hasStatus": False}, host_id="host-a")
    assert unprobed[0].installation == "unknown"
    assert unprobed[0].next_action == "verify"
    found = instances_from_capability_status({**base, "hasStatus": True,
        "capabilities": [{**base["capabilities"][0], "installed": True}]}, host_id="host-a")
    assert found[0].installation == "present"
    assert found[0].origin == "unknown"
    assert found[0].health == "unknown"
    assert not found[0].ready


def test_capability_status_cannot_override_bound_host_scope_or_identity():
    instances = instances_from_capability_status({
        "hasStatus": True,
        "capabilities": [{
            "id": "development.vscode",
            "installed": True,
            "hostId": "forged-host",
            "scope": "forged-scope",
            "instanceId": "forged-instance",
        }],
    }, host_id="registered-host", scope="host")

    assert len(instances) == 1
    assert (
        instances[0].host_id,
        instances[0].scope,
        instances[0].instance_id,
    ) == (
        "registered-host",
        "host",
        "registered-host:host:app.vscode:development.vscode",
    )


def test_status_adapter_keeps_scope_and_unknown_dimensions_separate():
    local = instances_from_status_payload(
        {"hasStatus": True, "installed": True, "serviceActive": False,
         "origin": "external", "version": "0.4.2"},
        app_id="app.ollama", host_id="host-a", scope="local",
    )[0]
    remote = instances_from_status_payload(
        {"hasStatus": False, "installed": False, "configured": True},
        app_id="app.ollama", host_id="host-b", scope="service",
    )[0]
    assert local.app_id == remote.app_id == "app.ollama"
    assert local.instance_id != remote.instance_id
    assert (local.installation, local.origin, local.health) == ("present", "external", "offline")
    assert (remote.installation, remote.configuration, remote.health) == ("unknown", "ready", "unknown")
    assert not remote.ready
    assert local.to_dict()["instanceId"] == local.instance_id


def test_status_adapter_ignores_malformed_state_fields():
    instance = instances_from_status_payload(
        {"hasStatus": True, "installationState": [], "origin": {},
         "configurationState": [], "health": {}, "error": "provider timeout"},
        app_id="app.hermes", host_id="local", scope="user",
    )[0]
    assert instance.installation == "unknown"
    assert instance.origin == instance.configuration == instance.health == "unknown"


def test_hermes_status_uses_nested_gateway_health_without_claiming_ownership():
    instance = instances_from_status_payload(
        {"id": "hermes", "installed": True, "configured": True,
         "gateway": {"active": False}},
        app_id="app.hermes", host_id="local", scope="local",
    )[0]
    assert (instance.installation, instance.origin, instance.configuration, instance.health) == (
        "present", "unknown", "ready", "offline",
    )


def test_9router_and_odysseus_health_use_manager_health_fields():
    router = instances_from_status_payload(
        {"id": "9router", "installed": True, "healthy": True, "service": "active",
         "providers": {"active": 1, "total": 2}},
        app_id="app.9router", host_id="local", scope="local",
    )[0]
    assert (router.installation, router.origin, router.configuration, router.health) == (
        "present", "unknown", "ready", "online",
    )

    no_provider = instances_from_status_payload(
        {"id": "9router", "installed": True, "healthy": True,
         "providers": {"active": 0, "total": 0}},
        app_id="app.9router", host_id="local", scope="local",
    )[0]
    assert no_provider.next_action == "configure"

    odysseus = instances_from_status_payload(
        {"id": "odysseus", "installed": True, "configured": True,
         "healthy": True, "service": "active"},
        app_id="app.odysseus", host_id="local", scope="local",
    )[0]
    assert (odysseus.installation, odysseus.origin, odysseus.configuration, odysseus.health) == (
        "present", "unknown", "ready", "online",
    )
    assert odysseus.next_action == "open"


def test_proxy_status_actions_target_exact_product_and_preserve_provenance_contract():
    actions = {action.id: action for action in build_catalog(ROOT)}
    expected = {
        "app.kimiproxy": ("ai.proxies-kimi-status", "kimiproxy"),
        "app.qwen-proxy": ("ai.proxies-qwen-status", "qwenproxy"),
        "app.deepseek-proxy": ("ai.proxies-deeps-status", "deepsproxy"),
        "app.mimo-proxy": ("ai.proxies-mimo-status", "mimo-ai-proxy"),
    }
    rows = {row.action_id: row for row in inventory(list(actions.values()))}
    for app_id, (action_id, proxy_id) in expected.items():
        action = actions[action_id]
        assert not action.mutable
        assert action.status_args == ("ai", "proxies", "product-status", proxy_id)
        assert rows[action_id].target_id == app_id
        assert rows[action_id].instance_scope == "local"
    mimo_credentials = actions["ai.proxies-credentials-mimo"]
    assert mimo_credentials.stdin_parameter == "credentials"
    assert mimo_credentials.parameters[0].name == "credentials"
    assert mimo_credentials.parameters[0].kind == "secret"
    assert "{credentials}" not in mimo_credentials.args
    observed = instances_from_status_payload(
        {"hasStatus": True, "installationState": "present", "origin": "phasezero",
         "configurationState": "ready", "health": "offline",
         "manager": "phasezero-ai-proxy-suite"},
        app_id="app.qwen-proxy", host_id="local", scope="local",
    )[0]
    assert (observed.installation, observed.origin, observed.configuration, observed.health) == (
        "present", "phasezero", "ready", "offline",
    )
    malformed = instances_from_status_payload(
        {"hasStatus": True, "installationState": [], "origin": [],
         "configurationState": [], "health": [], "installed": "yes"},
        app_id="app.qwen-proxy", host_id="local", scope="local",
    )[0]
    assert malformed.installation == malformed.origin == malformed.configuration == malformed.health == "unknown"
