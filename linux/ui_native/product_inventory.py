"""PXA-001: stable product targets for existing Control Center actions.

This inventory describes navigation and ownership. It never probes or mutates a
host. Actions remain executable through their existing IDs while later phases
replace duplicate installers with one product detail and instance contract.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from linux.capabilities.catalog import CAPABILITIES

from .models import ActionSpec, ProductInstance


DESTINATIONS = frozenset({
    "Início", "Aplicativos", "Desenvolvimento", "Inteligência artificial",
    "Contas e conexões", "Plataformas", "Sistema", "Atividade",
})
ROLES = frozenset({"canonical", "shortcut", "legacy"})


@dataclass(frozen=True)
class ProductTarget:
    action_id: str
    target_id: str
    target_kind: str  # app | platform | journey | system | activity
    destination: str
    role: str
    context: str
    instance_scope: str  # local | host | project | account | selected


_CAPABILITY_IDS = frozenset(item.id for item in CAPABILITIES)
_APP_NAMES = {item.id: item.title for item in CAPABILITIES}

# These names deliberately merge actions from several old categories. A
# product has one stable ID even when its setup is offered in multiple places.
_AI_APPS = {
    "opencode": "opencode", "omo": "omo", "memory": "ai-memory",
    "ollama": "ollama", "webui": "open-webui", "usagebar": "usagebar",
    "codexbar": "codexbar", "claude": "claude-code", "9router": "9router",
    "odysseus": "odysseus", "hermes": "hermes", "omniroute": "omniroute",
}
_PROXIES = {"kimi": "kimiproxy", "qwen": "qwen-proxy", "deeps": "deepseek-proxy", "mimo": "mimo-proxy"}
_EXTRA_APPS = {
    "ai-memory": "ai-memory", "claude-code": "Claude Code", "claude-desktop": "Claude Desktop",
    "codex-desktop": "Codex Desktop", "codexbar": "CodexBar", "deepseek-proxy": "DeepSeek Proxy",
    "hermes": "Hermes", "kimiproxy": "Kimi Proxy", "mimo-proxy": "MiMo Proxy",
    "odysseus": "Odysseus", "ollama": "Ollama", "omo": "Oh My OpenCode",
    "omniroute": "OmniRoute", "open-webui": "Open WebUI", "opencode": "OpenCode",
    "qwen-code-desktop": "Qwen Code Desktop", "qwen-proxy": "Qwen Proxy",
    "9router": "9Router", "usagebar": "UsageBar",
}
_DESKTOP_ENTRY_HINTS = {
    "app.claude-desktop": ("claude-desktop",),
    "app.qwen-code-desktop": ("qwen-code-desktop",),
}

# Existing contexts can offer the same app without owning a second installer.
# `server.llm` keeps its model/server workflow, but delegates the package setup
# to the canonical Ollama installer.
_CANONICAL_APP_ACTIONS = {"app.ollama": "ai.ollama"}
_INSTALL_AUTHORITY_BY_ACTION = {
    "ai.ollama": "linux/ai/setup-ollama.sh",
    "server.llm": "linux/ai/setup-ollama.sh",
}
_COMPARISON_CATEGORY_BY_APP = {
    "app.brave": "web-browser",
    "app.librewolf": "web-browser",
    "app.vscode": "code-editor",
    "app.vscodium": "code-editor",
    "app.tailscale": "mesh-network",
    "app.zerotier": "mesh-network",
}
_INSTANCE_KEY_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_PRODUCT_SEARCH_TERMS = {
    "app.ollama": ("chat local", "modelos locais", "LLM local"),
    "app.vscode": ("programar", "editor de código", "desenvolver software"),
    "app.vscodium": ("programar", "editor de código", "desenvolver software"),
    "app.claude-code": ("agente de código", "assistente de código", "programar com IA"),
    "app.opencode": ("agente de código", "agente de programação", "programar com IA"),
}


def _capability_target(capability_id: str) -> str:
    if capability_id not in _CAPABILITY_IDS:
        raise ValueError(f"unknown capability target: {capability_id}")
    return f"app.{capability_id.rsplit('.', 1)[-1]}"


def status_action_matches_app(action: ActionSpec, app_id: str) -> bool:
    """Return whether an explicitly read-only status action owns this app."""
    if action.id == "product.capabilities.status":
        return app_id in _CAPABILITY_APP_IDS
    try:
        target = target_for(action)
    except ValueError:
        return False
    return target.target_kind == "app" and target.target_id == app_id


_CAPABILITY_APP_IDS = frozenset(_capability_target(item.id) for item in CAPABILITIES)


def _ai_app(action_id: str) -> str | None:
    suffix = action_id.removeprefix("ai.")
    if suffix.startswith("desktop."):
        name = suffix.split(".", 2)[1]
        return {"claude": "claude-desktop", "qwen": "qwen-code-desktop", "codex": "codex-desktop"}.get(name)
    if suffix.startswith("proxies-"):
        for token, name in _PROXIES.items():
            if (
                suffix.endswith(f"-{token}")
                or suffix.endswith(f"-{token}-login")
                or suffix.endswith(f"-{token}-status")
            ):
                return name
        return None
    for prefix, name in _AI_APPS.items():
        if suffix == prefix or suffix.startswith(prefix + "-") or suffix.startswith(prefix + "."):
            return name
    return None


def target_for(action: ActionSpec) -> ProductTarget:
    """Resolve every static action without guessing installed state."""
    aid = action.id
    category = action.category
    if aid.startswith(("hub.capability.install.", "hub.capability.remove.")):
        capability_id = aid.split(".", 3)[3]
        return ProductTarget(aid, _capability_target(capability_id), "app",
                             "Desenvolvimento" if capability_id.startswith("development.") else "Aplicativos",
                             "shortcut", category, "host")
    if aid.startswith("hub.tuning."):
        return ProductTarget(aid, "system.tune", "system", "Sistema", "shortcut", category, "host")
    if aid == "hub.capabilities.status":
        return ProductTarget(aid, "journey.capabilities", "journey", "Aplicativos", "shortcut", category, "host")
    if aid.startswith("routing."):
        return ProductTarget(aid, "journey.ai-routing", "journey", "Inteligência artificial",
                             "shortcut", category, "account")
    if aid.startswith("capability.plan."):
        capability_id = aid.removeprefix("capability.plan.")
        destination = "Desenvolvimento" if capability_id.startswith("development.") else "Aplicativos"
        return ProductTarget(aid, _capability_target(capability_id), "app", destination,
                             "canonical", category, "host")
    if aid.startswith("capability.profile.") or aid.startswith("profile."):
        return ProductTarget(aid, f"journey.{aid}", "journey", "Desenvolvimento" if "dev" in aid or "developer" in aid else "Início",
                             "legacy", category, "host")
    if aid.startswith("ai."):
        app = _ai_app(aid)
        if app:
            canonical = _CANONICAL_APP_ACTIONS.get(f"app.{app}") == aid
            return ProductTarget(aid, f"app.{app}", "app", "Inteligência artificial",
                                 "canonical" if canonical else "shortcut", category,
                                 "host" if app == "ollama" else "local")
        if "auth" in aid or "login" in aid or "credentials" in aid or "secrets" in aid:
            destination = "Contas e conexões"
        else:
            destination = "Inteligência artificial"
        return ProductTarget(aid, f"journey.{aid}", "journey", destination,
                             "legacy", category, "account" if destination == "Contas e conexões" else "local")
    if aid.startswith("server.hermes"):
        return ProductTarget(aid, "app.hermes", "app", "Inteligência artificial", "shortcut", category, "host")
    if aid.startswith("server.llm"):
        return ProductTarget(aid, "app.ollama", "app", "Inteligência artificial", "shortcut", category, "host")
    if aid.startswith("server.homelab") or aid.startswith("homelab."):
        return ProductTarget(aid, "platform.homelab", "platform", "Plataformas", "shortcut", category, "selected")
    if aid.startswith("windows."):
        return ProductTarget(aid, "platform.windows-vm", "platform", "Plataformas", "shortcut", category, "selected")
    if aid.startswith(("waydroid.", "steamdeck.", "emulation.")):
        platform = aid.split(".", 1)[0]
        return ProductTarget(aid, f"platform.{platform}", "platform", "Plataformas", "shortcut", category, "host")
    if aid.startswith("desktop."):
        return ProductTarget(aid, f"journey.{aid.split('.', 2)[1]}", "journey", "Aplicativos", "legacy", category, "local")
    if aid.startswith("capability."):
        return ProductTarget(aid, "journey.capabilities", "journey", "Aplicativos", "legacy", category, "host")
    if aid.startswith("flatpak."):
        return ProductTarget(aid, "system.flatpak", "system", "Aplicativos", "shortcut", category, "host")
    if aid.startswith(("boot.", "host.", "system.", "tune.", "themes.")):
        destination = "Atividade" if aid.startswith("system.support-") or aid.startswith("themes.history") else "Sistema"
        return ProductTarget(aid, f"system.{aid.split('.', 1)[0]}", "system", destination, "shortcut", category, "host")
    if aid.startswith("server."):
        return ProductTarget(aid, "platform.server", "platform", "Plataformas", "shortcut", category, "host")
    raise ValueError(f"unclassified action: {aid}")


def inventory(actions: list[ActionSpec]) -> tuple[ProductTarget, ...]:
    rows = tuple(target_for(action) for action in actions)
    if len({row.action_id for row in rows}) != len(actions):
        raise ValueError("duplicate or missing action in product inventory")
    for row in rows:
        if row.destination not in DESTINATIONS or row.role not in ROLES:
            raise ValueError(f"invalid product target: {row.action_id}")
        if row.target_kind == "app" and not row.target_id.startswith("app."):
            raise ValueError(f"invalid app ID: {row.action_id}")
    return rows


def _is_install_route(row: ProductTarget, action: ActionSpec) -> bool:
    if row.target_kind != "app":
        return False
    if action.id.startswith("hub.capability.install."):
        return True
    if action.id.startswith("capability.plan."):
        return True
    if "watchdog" in action.id:
        return False
    return any(verb in action.args for verb in ("install", "setup")) or action.args[:2] == ("ai", "setup")


def _installation_authority(row: ProductTarget, action: ActionSpec) -> str | None:
    if not _is_install_route(row, action):
        return None
    if action.id.startswith("hub.capability.install."):
        # Generated Hub action applies a reviewed plan through the capability
        # engine; its generic argv does not contain an install/setup verb.
        return "linux/capabilities/engine.py"
    if row.action_id in _INSTALL_AUTHORITY_BY_ACTION:
        return _INSTALL_AUTHORITY_BY_ACTION[row.action_id]
    if row.action_id.startswith("capability.plan."):
        return "linux/capabilities/engine.py"
    # A route with one installer is its own current owner. If a second route
    # appears for the same app/scope, manifest generation requires an explicit
    # shared authority above instead of silently declaring two installers.
    return f"action:{row.action_id}"


def inventory_manifest(root: Path) -> dict[str, object]:
    from .catalog import build_catalog

    actions = build_catalog(root)
    rows = inventory(actions)
    action_by_id = {action.id: action for action in actions}
    action_ids_by_app: dict[str, list[str]] = {}
    canonical_by_app: dict[str, str] = {}
    authorities_by_app_scope: dict[tuple[str, str], dict[str, list[str]]] = {}
    authority_by_action: dict[str, str] = {}
    for row in rows:
        if row.target_kind != "app":
            continue
        action_ids_by_app.setdefault(row.target_id, []).append(row.action_id)
        if row.role == "canonical":
            if row.target_id in canonical_by_app:
                raise ValueError(f"multiple canonical actions for {row.target_id}")
            canonical_by_app[row.target_id] = row.action_id
        authority_id = _installation_authority(row, action_by_id[row.action_id])
        if authority_id:
            authority_by_action[row.action_id] = authority_id
            scopes = authorities_by_app_scope.setdefault(
                (row.target_id, row.instance_scope), {},
            )
            scopes.setdefault(authority_id, []).append(row.action_id)
    ambiguous_authorities = {
        key: authorities for key, authorities in authorities_by_app_scope.items()
        if len(authorities) > 1
    }
    if ambiguous_authorities:
        raise ValueError(f"multiple install authorities per app and scope: {ambiguous_authorities}")
    installation_authorities = [
        {"appId": app_id, "instanceScope": scope,
         "authorityId": authority_id, "actionIds": sorted(authority_actions)}
        for (app_id, scope), authorities in sorted(authorities_by_app_scope.items())
        for authority_id, authority_actions in sorted(authorities.items())
    ]
    products = [
        {"appId": _capability_target(item.id), "name": item.title,
         "capabilityId": item.id, "description": item.description,
         "group": item.group, "requires": list(item.requires),
         "conflicts": list(item.conflicts), "risk": item.risk,
         "license": item.license,
         "compatibility": {
             "distros": list(item.compatibility.distros),
             "gpu": list(item.compatibility.gpu),
             "desktops": list(item.compatibility.desktops),
             "sessions": list(item.compatibility.sessions),
             "init": list(item.compatibility.init),
             "immutable": item.compatibility.immutable,
             "container": item.compatibility.container,
         },
         "sources": [
             {"kind": source.kind, "name": source.name} for source in item.sources
         ]}
        for item in CAPABILITIES
    ]
    capability_apps = {item["appId"] for item in products}
    products.extend(
        ({"appId": f"app.{key}", "name": name, "capabilityId": None,
          "description": "", "group": "Inteligência artificial",
          "requires": [], "conflicts": [], "risk": "normal", "license": "unknown",
          "compatibility": {"distros": [], "gpu": [], "desktops": [],
                            "sessions": [], "init": [], "immutable": "unknown",
                            "container": "unknown"}, "sources": [],
          **({"desktopEntries": list(_DESKTOP_ENTRY_HINTS[f"app.{key}"])}
             if f"app.{key}" in _DESKTOP_ENTRY_HINTS else {})})
        for key, name in sorted(_EXTRA_APPS.items())
        if f"app.{key}" not in capability_apps
    )
    known_apps = {item["appId"] for item in products}
    missing_apps = {row.target_id for row in rows if row.target_kind == "app"} - known_apps
    if missing_apps:
        raise ValueError(f"app targets without a product record: {sorted(missing_apps)}")
    if len({item["appId"] for item in products}) != len(products):
        raise ValueError("duplicate app ID in canonical product registry")
    for product in products:
        app_id = str(product["appId"])
        product["actionIds"] = sorted(action_ids_by_app.get(app_id, ()))
        if not product.get("description") and product["actionIds"]:
            primary_id = canonical_by_app.get(app_id) or product["actionIds"][0]
            product["description"] = action_by_id[primary_id].description
        product["comparisonCategory"] = _COMPARISON_CATEGORY_BY_APP.get(app_id)
        product["searchTerms"] = list(_PRODUCT_SEARCH_TERMS.get(app_id, ()))
        product["canonicalActionId"] = canonical_by_app.get(app_id)
        product["installationAuthorityIds"] = sorted({
            authority_by_action[action_id]
            for action_id in product["actionIds"]
            if action_id in authority_by_action
        })
    return {
        "schemaVersion": 1,
        "source": "linux.ui_native.catalog.build_catalog",
        "platform": "linux",
        "actionCount": len(rows),
        "dynamicActionPatterns": [
            "hub.capabilities.status",
            "hub.capability.install.<capabilityId>",
            "hub.capability.remove.<capabilityId>",
            "hub.tuning.apply.<tuningId>",
            "hub.tuning.revert.<tuningId>",
            "routing.<operation>.<task>.<policy>",
        ],
        "products": products,
        "installationAuthorities": installation_authorities,
        "comparisonCategories": [
            {"id": category, "appIds": sorted(
                app_id for app_id, app_category in _COMPARISON_CATEGORY_BY_APP.items()
                if app_category == category
            )}
            for category in sorted(set(_COMPARISON_CATEGORY_BY_APP.values()))
        ],
        "dynamicInstallationAuthorities": [
            {"pattern": "hub.capability.install.<capabilityId>",
             "authorityId": "linux/capabilities/engine.py"},
        ],
        "actions": [
            {"actionId": row.action_id, "targetId": row.target_id,
             "targetKind": row.target_kind, "destination": row.destination,
             "role": row.role, "context": row.context,
             "instanceScope": row.instance_scope,
             "installationAuthorityId": authority_by_action.get(row.action_id)}
            for row in rows
        ],
    }


def render_inventory_manifest(payload: dict[str, object]) -> str:
    """Render stable JSON with one compact record per inventory row."""
    lines = ["{"]
    entries = list(payload.items())
    for entry_index, (key, value) in enumerate(entries):
        suffix = "," if entry_index < len(entries) - 1 else ""
        encoded_key = json.dumps(key, ensure_ascii=False)
        if isinstance(value, list):
            lines.append(f"  {encoded_key}: [")
            for index, item in enumerate(value):
                item_suffix = "," if index < len(value) - 1 else ""
                encoded_item = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
                lines.append(f"    {encoded_item}{item_suffix}")
            lines.append(f"  ]{suffix}")
        else:
            encoded_value = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            lines.append(f"  {encoded_key}: {encoded_value}{suffix}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_inventory_manifest(root: Path, destination: Path) -> None:
    """Write the generated action/product contract to an explicit path."""
    destination.write_text(
        render_inventory_manifest(inventory_manifest(root)), encoding="utf-8",
    )


def instances_from_capability_status(
    payload: object, *, host_id: str, scope: str = "host",
) -> tuple[ProductInstance, ...]:
    """Read-only bridge from capability status; never infers owner or health.

    ``catalog`` payloads have ``hasStatus=false`` and therefore yield unknown
    installation even though their legacy ``installed`` field is false.
    """
    if not isinstance(payload, dict) or not host_id or not scope:
        return ()
    rows = payload.get("capabilities")
    if not isinstance(rows, list):
        return ()
    probed = payload.get("hasStatus") is True
    result: list[ProductInstance] = []
    for raw in rows:
        if not isinstance(raw, dict) or raw.get("id") not in _CAPABILITY_IDS:
            continue
        capability_id = raw["id"]
        source = raw.get("source")
        source = source if isinstance(source, dict) else {}
        installation = "unknown" if not probed or not isinstance(raw.get("installed"), bool) else (
            "present" if raw["installed"] else "absent"
        )
        origin = str(raw.get("origin", "unknown"))
        if origin not in {"phasezero", "external", "unknown"}:
            origin = "unknown"
        configuration = str(raw.get("configuration", "unknown"))
        if configuration not in {"ready", "needed", "unknown"}:
            configuration = "unknown"
        health = str(raw.get("health", "unknown"))
        if health not in {"online", "offline", "failed", "unknown"}:
            health = "unknown"
        # Host and scope come from the request context. Status output is
        # observation data and cannot relabel itself as another instance.
        instance_host = host_id
        instance_scope = scope
        app_id = _capability_target(capability_id)
        result.append(ProductInstance(
            instance_id=f"{instance_host}:{instance_scope}:{app_id}:{capability_id}",
            app_id=app_id,
            host_id=instance_host,
            scope=instance_scope,
            manager=str(source.get("kind") or "unknown"),
            installation=installation,
            origin=origin,
            configuration=configuration,
            health=health,
            version=str(raw.get("version") or ""),
            observed_at=str(raw.get("observedAt") or ""),
        ))
    return tuple(result)


def instances_from_status_payload(
    payload: object,
    *,
    app_id: str,
    host_id: str,
    scope: str,
    instance_key: str = "default",
) -> tuple[ProductInstance, ...]:
    """Normalize one or more read-only app statuses without guessing absence."""
    if not isinstance(payload, dict) or not app_id.startswith("app."):
        return ()
    rows = payload.get("instances")
    if rows is not None:
        if not isinstance(rows, list):
            return ()
        envelope = {key: value for key, value in payload.items() if key != "instances"}
        instances: list[ProductInstance] = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            key = row.get("instanceKey")
            if not isinstance(key, str) or not _INSTANCE_KEY_PATTERN.fullmatch(key):
                continue
            item_payload = dict(envelope)
            item_payload.update(row)
            instances.extend(_single_status_instance(
                item_payload, app_id=app_id, host_id=host_id, scope=scope,
                instance_key=key,
            ))
        return tuple(instances)
    return _single_status_instance(
        payload, app_id=app_id, host_id=host_id, scope=scope,
        instance_key=instance_key,
    )


def _single_status_instance(
    payload: dict[str, object],
    *,
    app_id: str,
    host_id: str,
    scope: str,
    instance_key: str,
) -> tuple[ProductInstance, ...]:
    probe_failed = bool(payload.get("error")) or payload.get("status") in {
        "unavailable", "unknown", "timeout", "error",
    }
    probed = (
        payload.get("hasStatus") is True
        if "hasStatus" in payload else not probe_failed
    )
    raw_state = payload.get("installationState")
    if isinstance(raw_state, str) and raw_state in {"present", "absent", "unknown"}:
        installation = raw_state if probed else "unknown"
    else:
        installed = payload.get("installed")
        installation = (
            ("present" if installed else "absent")
            if probed and isinstance(installed, bool) else "unknown"
        )
    raw_origin = payload.get("origin", "unknown")
    origin = (
        raw_origin
        if isinstance(raw_origin, str) and raw_origin in {"phasezero", "external", "unknown"}
        else "unknown"
    )
    raw_configuration = payload.get("configurationState")
    if (
        not isinstance(raw_configuration, str)
        or raw_configuration not in {"ready", "needed", "unknown"}
    ):
        configured = payload.get("configured")
        if payload.get("id") == "9router":
            providers = payload.get("providers")
            active_providers = providers.get("active") if isinstance(providers, dict) else None
            if isinstance(active_providers, int) and not isinstance(active_providers, bool):
                configured = active_providers > 0
        raw_configuration = (
            "ready" if configured is True else
            "needed" if configured is False else "unknown"
        )
    raw_health = payload.get("health")
    if (
        not isinstance(raw_health, str)
        or raw_health not in {"online", "offline", "failed", "unknown"}
    ):
        active = payload.get("serviceActive", payload.get("active"))
        healthy = payload.get("healthy")
        if isinstance(healthy, bool):
            active = healthy
        if payload.get("id") == "hermes":
            gateway = payload.get("gateway")
            if isinstance(gateway, dict):
                active = gateway.get("active")
        raw_health = "online" if active is True else "offline" if active is False else "unknown"
    version = payload.get("version", "")
    blocked_reason = payload.get("blockedReason")
    instance_id = f"{host_id}:{scope}:{app_id}:{instance_key}"
    return (ProductInstance(
        instance_id=instance_id,
        app_id=app_id,
        host_id=host_id,
        scope=scope,
        manager=str(payload.get("manager") or payload.get("managerKind") or "unknown"),
        version=version if isinstance(version, str) else "",
        installation=installation,
        origin=origin,
        configuration=raw_configuration,
        health=raw_health,
        observed_at=str(payload.get("observedAt") or ""),
        usage_blocked=payload.get("usageBlocked") is True,
        blocked_reason=blocked_reason if isinstance(blocked_reason, str) else "",
        launchable=(
            payload.get("launchable") is True
            and installation == "present" and raw_configuration == "ready"
        ),
    ),)
