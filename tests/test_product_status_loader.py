from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QProcess
from PySide6.QtWidgets import QApplication

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.models import ActionSpec
from linux.ui_native.status_loader import StatusLoader, validate_remote_product_status


def test_status_loader_emits_scoped_product_instance(tmp_path):
    action = ActionSpec(
        "ai.webui-status", "AI", "Status Open WebUI", "", ("ai", "webui", "status"), "",
        status_args=("ai", "webui", "status"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.open-webui", host_id="local", scope="local",
        )
    fetch.assert_called_once_with(action.id, ["ai", "webui", "status"])

    instances = loader.product_instances_from_result(action.id, {
        "installed": True,
        "serviceActive": True,
        "configured": True,
        "version": "1.2.3",
    })
    assert len(instances) == 1
    instance = instances[0]
    assert (instance.app_id, instance.host_id, instance.scope) == (
        "app.open-webui", "local", "local",
    )
    assert (instance.installation, instance.health, instance.version) == (
        "present", "online", "1.2.3",
    )
    assert instance.ready
    assert loader.product_instances_from_result(action.id, {"installed": True}) == ()


def test_status_loader_rejects_remote_host_without_host_bound_executor(tmp_path):
    action = ActionSpec(
        "ai.webui-status", "AI", "Status Open WebUI", "", ("ai", "webui", "status"), "",
        status_args=("ai", "webui", "status"),
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.open-webui", host_id="homelab-a", scope="local",
        )
    fetch.assert_not_called()
    assert failures == [(
        action.id, "remote product status requires a host-bound executor",
    )]
    assert loader.product_instances_from_result(action.id, {"installed": True}) == ()


def test_status_loader_builds_fixed_host_bound_product_status_route(tmp_path):
    action = ActionSpec(
        "ai.usagebar-status", "IA & Dev", "Status UsageBar", "",
        ("ai", "product-status", "usagebar"), "",
        status_args=("ai", "product-status", "usagebar"),
    )
    loader = StatusLoader(tmp_path)
    host_id = "hlh-" + hashlib.sha256(b"garage").hexdigest()[:12]
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.usagebar", host_id=host_id,
            scope="user", remote_alias="garage",
        )
    fetch.assert_called_once_with(action.id, [
        "server", "homelab", "--host", "garage", "product-status", "usagebar",
    ])
    instances = loader.product_instances_from_result(action.id, {
        "hasStatus": True,
        "installationState": "unknown",
        "origin": "unknown",
        "health": "unknown",
    })
    assert len(instances) == 1
    assert (instances[0].host_id, instances[0].scope) == (host_id, "user")


def test_remote_product_status_rejects_unbound_host_id(tmp_path):
    action = ActionSpec(
        "ai.usagebar-status", "IA & Dev", "Status UsageBar", "",
        ("ai", "product-status", "usagebar"), "",
        status_args=("ai", "product-status", "usagebar"),
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.usagebar", host_id="hlh-a1b2c3d4e5f6",
            scope="user", remote_alias="garage",
        )
    fetch.assert_not_called()
    assert failures == [(action.id, "no allowlisted remote product status route")]


def test_remote_product_status_envelope_must_match_selected_host():
    payload = {"hasStatus": True, "installationState": "unknown"}
    envelope = {
        "schemaVersion": "1", "tool": "homelab-hosts", "action": "exec",
        "hostAlias": "garage", "rc": 0, "payload": payload,
        "error": None, "remoteVersion": "1.17.4",
    }
    assert validate_remote_product_status(envelope, "garage") == payload
    for wrong in (
        {**envelope, "hostAlias": "other"},
        {**envelope, "rc": 1},
        {**envelope, "remoteVersion": ""},
        {**envelope, "payload": None},
    ):
        with pytest.raises(ValueError):
            validate_remote_product_status(wrong, "garage")


@pytest.mark.parametrize("actual_alias, succeeds", [("garage", True), ("other", False)])
def test_qprocess_remote_status_binds_response_to_captured_host(
    tmp_path, actual_alias, succeeds,
):
    _app = QApplication.instance() or QApplication([])
    action = ActionSpec(
        "ai.usagebar-status", "IA & Dev", "Status UsageBar", "",
        ("ai", "product-status", "usagebar"), "",
        status_args=("ai", "product-status", "usagebar"),
    )
    remote_payload = {
        "hasStatus": True,
        "installationState": "unknown",
        "origin": "unknown",
        "health": "unknown",
    }
    envelope = {
        "schemaVersion": "1", "tool": "homelab-hosts", "action": "exec",
        "hostAlias": actual_alias, "rc": 0, "payload": remote_payload,
        "error": None, "remoteVersion": "1.17.4",
    }
    loader = StatusLoader(tmp_path)
    host_id = "hlh-" + hashlib.sha256(b"garage").hexdigest()[:12]
    outcomes = []
    instances = []
    loader.status_ready.connect(lambda *_: outcomes.append("ready"))
    loader.status_failed.connect(lambda _aid, reason: outcomes.append(("failed", reason)))
    loader.product_instances_ready.connect(lambda _aid, rows: instances.extend(rows))
    with patch.object(loader, "fetch"):
        loader.fetch_product_status(
            action, app_id="app.usagebar", host_id=host_id,
            scope="user", remote_alias="garage",
        )
    process = QProcess(loader)
    loader._processes[action.id] = process
    with patch("linux.ui_native.status_loader.parse_json_output", return_value=envelope):
        loader._on_finished(action.id, 0, process)

    if succeeds:
        assert outcomes == ["ready"]
        assert len(instances) == 1
        assert instances[0].host_id == host_id
        assert instances[0].installation == "unknown"
    else:
        assert outcomes and outcomes[0][0] == "failed"
        assert "selected Homelab host" in outcomes[0][1]
        assert instances == []


def test_status_loader_rejects_mutating_action(tmp_path):
    action = ActionSpec(
        "app.ollama.install", "AI", "Instalar Ollama", "", ("ai", "setup", "ollama"), "",
        mutable=True,
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.ollama", host_id="local", scope="service",
        )
    fetch.assert_not_called()
    assert failures == [(action.id, "product status requires a read-only action")]


def test_status_loader_rejects_status_action_for_another_product(tmp_path):
    action = ActionSpec(
        "ai.webui-status", "AI", "Status Open WebUI", "", ("ai", "webui", "status"), "",
        status_args=("ai", "webui", "status"),
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.ollama", host_id="local", scope="local",
        )
    fetch.assert_not_called()
    assert failures == [(action.id, "status action does not match product context")]


def test_status_loader_requires_explicit_read_only_arguments(tmp_path):
    action = ActionSpec(
        "ai.webui-status", "AI", "Status Open WebUI", "", ("ai", "webui", "status"), "",
    )
    loader = StatusLoader(tmp_path)
    failures = []
    loader.status_failed.connect(lambda action_id, reason: failures.append((action_id, reason)))
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.open-webui", host_id="local", scope="local",
        )
    fetch.assert_not_called()
    assert failures == [(
        action.id, "product status requires explicit read-only arguments",
    )]


def test_status_loader_normalizes_capability_catalog_by_app_and_scope(tmp_path):
    action = ActionSpec(
        "product.capabilities.status", "Aplicativos", "Status de recursos", "",
        ("capabilities", "status", "--json"), "",
        status_args=("capabilities", "status", "--json"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch"):
        loader.fetch_product_status(
            action, app_id="app.vscode", host_id="local", scope="host",
        )
    instances = loader.product_instances_from_result(action.id, {
        "hasStatus": True,
        "capabilities": [
            {"id": "development.vscode", "installed": True,
             "origin": "external", "configuration": "ready", "health": "online",
             "hostId": "forged-host", "scope": "forged-scope",
             "instanceId": "forged-instance"},
            {"id": "development.neovim", "installed": False},
        ],
    })
    assert len(instances) == 1
    assert (instances[0].app_id, instances[0].scope, instances[0].origin) == (
        "app.vscode", "host", "external",
    )
    assert instances[0].host_id == "local"
    assert instances[0].instance_id == "local:host:app.vscode:development.vscode"
    assert instances[0].ready


def test_status_loader_normalizes_verified_proxy_product_status(tmp_path):
    action = ActionSpec(
        "ai.proxies-qwen-status", "Proxies IA", "Status Qwen", "",
        ("ai", "proxies", "product-status", "qwenproxy"), "",
        status_args=("ai", "proxies", "product-status", "qwenproxy"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch") as fetch:
        loader.fetch_product_status(
            action, app_id="app.qwen-proxy", host_id="local", scope="local",
            instance_key="selected-qwen",
        )
    fetch.assert_called_once_with(action.id, ["ai", "proxies", "product-status", "qwenproxy"])
    instances = loader.product_instances_from_result(action.id, {
        "hasStatus": True,
        "installationState": "present",
        "origin": "phasezero",
        "configurationState": "ready",
        "health": "offline",
        "manager": "phasezero-ai-proxy-suite",
    })
    assert len(instances) == 1
    instance = instances[0]
    assert (instance.instance_id, instance.app_id, instance.scope) == (
        "local:local:app.qwen-proxy:selected-qwen", "app.qwen-proxy", "local",
    )
    assert (instance.installation, instance.origin, instance.configuration, instance.health) == (
        "present", "phasezero", "ready", "offline",
    )
    assert not instance.ready


def test_status_loader_keeps_same_host_same_scope_instances_distinct(tmp_path):
    action = ActionSpec(
        "ai.webui-status", "AI", "Status Open WebUI", "", ("ai", "webui", "status"), "",
        status_args=("ai", "webui", "status"),
    )
    loader = StatusLoader(tmp_path)
    with patch.object(loader, "fetch"):
        loader.fetch_product_status(
            action, app_id="app.open-webui", host_id="local", scope="local",
        )
    instances = loader.product_instances_from_result(action.id, {
        "hasStatus": True,
        "instances": [
            {"instanceKey": "local-a", "installationState": "present", "origin": "external",
             "health": "online"},
            {"instanceKey": "local-b", "installationState": "absent", "origin": "unknown",
             "health": "unknown"},
            {"instanceKey": "../unsafe", "installationState": "present"},
        ],
    })
    assert len(instances) == 2
    assert len({instance.instance_id for instance in instances}) == 2
    assert {(instance.host_id, instance.scope) for instance in instances} == {("local", "local")}
    assert {instance.instance_id.rsplit(":", 1)[-1] for instance in instances} == {"local-a", "local-b"}

    with patch.object(loader, "fetch"):
        loader.fetch_product_status(
            action, app_id="app.open-webui", host_id="local", scope="local",
        )
    unprobed = loader.product_instances_from_result(action.id, {
        "hasStatus": False,
        "instances": [{"instanceKey": "stale", "installationState": "present"}],
    })
    assert len(unprobed) == 1
    assert unprobed[0].installation == "unknown"
