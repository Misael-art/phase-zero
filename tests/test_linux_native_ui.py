from __future__ import annotations

import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.ui_native.catalog import CATEGORIES, build_catalog, catalog_manifest
from linux.ui_native import __version__
from linux.ui_native.boot_selector import BOOT_CHOICES, build_boot_selector_program, load_dynamic_boot_choices
from linux.ui_native.command_runner import build_program
from linux.ui_native.models import ActionSpec
from linux.ui_native.result_parser import parse_json_output, severity_for
from linux.ui_native.pages.results import create_safe_results_archive
from linux.ui_native.preferences import UiPreferences


def test_doctor_results_are_grouped_and_translated_for_nontechnical_users():
    from linux.ui_native.health_models import parse_health_checks, suggested_action_id

    checks = parse_health_checks([
        "[PASS] MEM01: Total RAM >= 4GB — 14GB",
        "[WARN] CPU02: CPU load (1m) < cores — 9 / 8",
        "[FAIL] NET01: Internet connectivity — offline",
    ])
    assert [check.group for check in checks] == ["Hardware", "Hardware", "Conexão"]
    assert checks[0].title == "Memória total suficiente"
    assert checks[1].state == "warning" and checks[1].needs_attention
    assert checks[2].state == "error"
    assert suggested_action_id(checks[1]) == "system.repair-plan"


@pytest.fixture(scope="module")
def catalog():
    return build_catalog(ROOT)


def test_catalog_covers_every_control_center_category(catalog):
    categories = {item.category for item in catalog}
    # "Resultados" (histórico) e "Linux" (hub) não consomem o catálogo de
    # ações: a primeira lê o ledger, a segunda deriva os itens de
    # `capabilities`/`tune` e reusa ações de outras categorias. Receitas de
    # desenvolvimento e probes de conta usam adaptadores existentes.
    expected = {row[0] for row in CATEGORIES if row[0] not in {
        "Resultados", "Linux", "Desenvolvimento", "Contas e conexões",
    }}
    assert categories == expected
    assert len(catalog) >= 100


def test_every_mutation_has_safe_preview(catalog):
    mutable = [item for item in catalog if item.mutable]
    assert mutable
    assert all(item.preview_args for item in mutable)
    assert all(item.preview_args != item.args for item in mutable)


def test_catalog_ids_and_commands_are_allowlisted(catalog):
    ids = [item.id for item in catalog]
    assert len(ids) == len(set(ids))
    valid_commands = {
        "install",
        "steamdeck",
        "windows-vm",
        "waydroid",
        "emulation",
        "boot",
        "flatpak",
        "server",
        "ai",
        "doctor",
        "support-bundle",
        "repair-plan",
        "tune",
        "host",
            "capabilities",
            "installation",
            "self-update",
            "updates",
            "version",
            "webapp",
            "games",
            "ui",
            "themes",
            "deps",
        "--internal-player",
        }
    for item in catalog:
        assert item.args[0] in valid_commands
        if item.preview_args:
            assert item.preview_args[0] in valid_commands


def test_input_token_substitution_is_literal():
    action = ActionSpec(
        "test.input",
        "test",
        "Input",
        "Input",
        ("emulation", "bios", "import", "{input}"),
        "folder",
        mutable=True,
        preview_args=("emulation", "bios", "status"),
        input_kind="path",
    )
    dangerous_looking = "/tmp/$(touch should-not-run); value"
    assert action.resolved_args(dangerous_looking)[-1] == dangerous_looking
    with pytest.raises(ValueError):
        build_program(ROOT, action, preview=False)


def test_build_program_never_uses_shell(catalog):
    action = next(item for item in catalog if item.id == "profile.safe-base")
    program, args = build_program(ROOT, action, preview=True)
    assert program == str(ROOT / "linux" / "pz")
    assert args == ["install", "safe-base", "--dry-run"]


def test_windows_graphics_actions_are_safe_plans(catalog):
    actions = {item.id: item for item in catalog if item.id.startswith("windows.graphics.")}
    assert set(actions) == {
        "windows.graphics.doctor",
        "windows.graphics.status",
        "windows.graphics.plan-gl",
        "windows.graphics.test-gl",
        "windows.graphics.plan-vfio",
        "windows.graphics.plan-venus",
        "windows.graphics.compat",
        "windows.graphics.enable",
        "windows.graphics.disable",
        "windows.graphics.runtime-status",
        "windows.graphics.runtime-install",
        "windows.graphics.runtime-rollback",
        "windows.graphics.guest-guide",
    }
    mutable = {action.id for action in actions.values() if action.mutable}
    assert mutable == {
        "windows.graphics.compat",
        "windows.graphics.enable",
        "windows.graphics.disable",
        "windows.graphics.runtime-install",
        "windows.graphics.runtime-rollback",
    }
    assert all(actions[action_id].preview_args for action_id in mutable)
    assert actions["windows.graphics.runtime-install"].elevated is True
    assert actions["windows.graphics.runtime-rollback"].elevated is True
    assert actions["windows.graphics.doctor"].args[-1] == "--json"
    assert actions["windows.graphics.status"].args[-1] == "--json"
    assert "virtio-gl" in actions["windows.graphics.plan-gl"].args
    assert "vfio-looking-glass" in actions["windows.graphics.plan-vfio"].args
    assert actions["windows.graphics.plan-vfio"].parameter_names == ("input",)


def test_elevated_program_prefers_phasezero_admin(catalog):
    action = next(item for item in catalog if item.id == "boot.safe-menu")
    with patch("linux.ui_native.platform.shutil.which") as which:
        which.side_effect = lambda name: "/usr/bin/phasezero-admin" if name == "phasezero-admin" else None
        program, args = build_program(ROOT, action, preview=False)
    assert program == "/usr/bin/phasezero-admin"
    assert args[0] == str(ROOT / "linux" / "pz")
    assert args[1:] == ["boot", "install-safe-menu"]


def test_boot_selector_uses_admin_bridge_without_shell():
    with patch("linux.ui_native.platform.shutil.which") as which:
        which.side_effect = lambda name: "/usr/bin/bigsudo" if name == "bigsudo" else None
        program, args = build_boot_selector_program(ROOT, "windows", reboot=True)
    assert program == "/usr/bin/bigsudo"
    assert args == [str(ROOT / "linux" / "pz"), "boot", "choose", "windows", "--reboot"]
    assert [choice.key for choice in BOOT_CHOICES] == [
        "normal",
        "steamos",
        "windows",
        "waydroid",
        "emergency",
    ]


def test_dynamic_boot_choices_are_loaded_without_shell():
    payload = {
        "schemaVersion": 1,
        "choices": [
            {"key": "iso:arch", "title": "Arch ISO", "description": "ready", "available": True},
            {"key": "usb:gone", "title": "Gone", "description": "missing", "available": False},
            {"key": "grubfm", "title": "Explorer", "description": "experimental", "available": True},
        ],
    }
    completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(payload), stderr="")
    with patch("linux.ui_native.boot_selector.subprocess.run", return_value=completed) as run:
        choices = load_dynamic_boot_choices(ROOT)
    assert [choice.key for choice in choices] == ["iso:arch", "grubfm"]
    assert run.call_args.args[0] == [str(ROOT / "linux" / "pz"), "boot", "catalog"]
    assert run.call_args.kwargs["timeout"] == 5


def test_dynamic_boot_catalog_actions_are_safe(catalog):
    actions = {item.id: item for item in catalog if item.id.startswith("boot.iso.") or item.id.startswith("boot.usb.") or item.id.startswith("boot.grubfm.")}
    assert set(actions) == {
        "boot.iso.status", "boot.iso.add", "boot.usb.discover", "boot.usb.add",
        "boot.grubfm.status", "boot.grubfm.install", "boot.grubfm.remove",
    }
    for action in actions.values():
        if action.mutable:
            assert action.preview_args
            assert action.elevated
    assert actions["boot.grubfm.install"].parameter_names == ("source", "sha256")
    assert actions["boot.grubfm.install"].risk == "high"


def test_proxies_page_has_dedicated_category_and_lifecycle_actions(catalog):
    proxies = {item.id: item for item in catalog if item.category == "Proxies IA"}
    expected = {
        "ai.proxies", "ai.proxies-ides", "ai.proxies-auth", "ai.proxies-test",
        "ai.proxies-login-all", "ai.proxies-start-all", "ai.proxies-stop-all",
        "ai.proxies.detailed-status", "ai.proxies.restart-one",
    }
    assert expected <= set(proxies)
    for suffix in ("kimi", "qwen", "deeps", "mimo"):
        assert f"ai.proxies-start-{suffix}" in proxies
        assert f"ai.proxies-stop-{suffix}" in proxies
    for action in proxies.values():
        if action.mutable:
            assert action.preview_args
    assert not any(item.id.startswith("ai.proxies") for item in catalog if item.category == "IA & Dev")


def test_proxy_models_parse_detailed_status_and_gateways():
    from linux.ui_native.proxy_models import (
        PROXY_CARDS, parse_detailed_status, parse_gateway_status,
    )

    payload = {
        "schemaVersion": 1,
        "proxies": [
            {
                "id": "kimiproxy", "kind": "node", "port": 3010, "installed": True,
                "service": "active", "apiKeyConfigured": True,
                "webValidation": {"required": True, "kind": "browser-session", "status": "authenticated", "missing": []},
            },
            {
                "id": "mimo-ai-proxy", "kind": "go", "port": 3013, "installed": True,
                "service": "inactive", "apiKeyConfigured": False,
                "webValidation": {"required": True, "kind": "env-session", "status": "missing-credentials", "missing": ["service-token-group"]},
            },
        ],
        "ide": {
            "envDefaults": True, "envDefaultsPath": "/tmp/ide-defaults.env",
            "defaultProxy": "deepsproxy", "opencodeProviders": 4,
            "continueModels": 11, "zcodeProviders": 4,
        },
    }
    proxies, ide = parse_detailed_status(payload)
    assert proxies["kimiproxy"].running and proxies["kimiproxy"].auth_state == "success"
    assert not proxies["mimo-ai-proxy"].running
    assert proxies["mimo-ai-proxy"].auth_missing == ("service-token-group",)
    assert ide.env_defaults and ide.opencode_providers == 4 and ide.default_proxy == "deepsproxy"
    assert {row[0] for row in PROXY_CARDS} <= {"kimiproxy", "qwenproxy", "deepsproxy", "mimo-ai-proxy"}

    router = parse_gateway_status("9router", {"installed": True, "healthy": True, "providers": {"active": 3}, "combos": {"total": 5}})
    assert router.label == "ativo" and "3 contas conectadas" in router.detail
    odysseus = parse_gateway_status("odysseus", {"installed": True, "healthy": False, "endpoint": "http://127.0.0.1:4000"})
    assert odysseus.label == "parado" and odysseus.state == "warning"
    assert parse_gateway_status("9router", None).label == "não instalado"


def test_json_parser_accepts_logs_before_envelope():
    text = 'INFO: checking\n{"status":"warn","checks":[{"name":"x"}]}\n'
    assert parse_json_output(text)["status"] == "warn"
    assert severity_for(parse_json_output(text), 0) == "warning"


def test_results_export_excludes_auth_files_and_redacts_secrets(tmp_path):
    source = tmp_path / "phasezero"
    results = source / "ui" / "results"
    results.mkdir(parents=True)
    (source / "ui-token").write_text("live-token", encoding="utf-8")
    (results / "run.json").write_text(
        '{"access_token":"secret-token","sha256":"safe-digest"}', encoding="utf-8"
    )
    (source / "pz.log").write_text(
        "Authorization: Bearer bearer-secret\n", encoding="utf-8"
    )
    output = create_safe_results_archive(source, tmp_path / "export.zip")
    assert output.stat().st_mode & 0o777 == 0o600
    with zipfile.ZipFile(output) as archive:
        assert sorted(archive.namelist()) == ["logs/pz.log", "results/run.json"]
        content = "\n".join(
            archive.read(name).decode("utf-8") for name in archive.namelist()
        )
    assert "live-token" not in content
    assert "secret-token" not in content
    assert "bearer-secret" not in content
    assert content.count("[REDACTED]") >= 2
    assert severity_for(None, 1) == "error"


def test_manifest_serializes_catalog(catalog):
    manifest = catalog_manifest(ROOT)
    assert manifest["schemaVersion"] == 2
    assert len(manifest["actions"]) == len(catalog)
    json.dumps(manifest)


def test_native_version_comes_from_project_manifest_and_channel():
    manifest = json.loads((ROOT / "version.json").read_text())
    expected = manifest["version"]
    if manifest.get("channel") in {"beta", "nightly"}:
        expected = f"{expected} ({manifest['channel']})"
    assert __version__ == expected


def test_simplified_mode_is_default_and_env_can_enable_advanced(monkeypatch):
    monkeypatch.setenv("PZ_UI_ADVANCED_MODE", "0")
    assert UiPreferences().advanced_mode is False
    monkeypatch.setenv("PZ_UI_ADVANCED_MODE", "1")
    assert UiPreferences().advanced_mode is True


def test_native_launcher_reports_version_without_starting_qt():
    result = subprocess.run(
        [sys.executable, "-m", "linux.ui_native", "--version"],
        cwd=ROOT, capture_output=True, text=True, timeout=10, check=False,
    )
    assert result.returncode == 0
    assert result.stdout.strip() == f"PhaseZero {__version__}"


def test_pages_route_actions_through_central_confirmation_flow():
    page_dir = ROOT / "linux" / "ui_native" / "pages"
    # windows_vm._request_plan calls runner.start directly to pass
    # provision context (graphics, image_index) that ActionSpec parameters
    # alone cannot express.  Accepted exception.
    skip: set[str] = {"windows_vm.py"}
    offenders = [
        path.name for path in page_dir.glob("*.py")
        if "self.runner.start(" in path.read_text(encoding="utf-8")
        and path.name not in skip
    ]
    assert offenders == []


def test_rom_optimizer_requires_library_and_has_distinct_preview(catalog):
    action = next(item for item in catalog if item.id == "emulation.rom-optimize")
    assert action.input_kind == "path"
    assert action.args == ("emulation", "rom-optimize", "{input}")
    assert action.preview_args == (
        "emulation", "rom-optimize", "{input}", "--dry-run", "--json",
    )


def test_appimage_bundle_is_standalone():
    apprun = (ROOT / "packaging" / "linux" / "appimage" / "AppRun").read_text()
    assert '"$PHASEZERO_ROOT:' in apprun, "linux.ui_native must resolve from any cwd"
    build = (ROOT / "packaging" / "linux" / "appimage" / "build-appimage.sh").read_text()
    assert "shiboken6==" in build, "PySide6 needs shiboken6 bundled explicitly"
    assert "PySide6_Essentials==" in build, "AppImage should not bundle unused Qt addons"
    assert 'PySide6==' not in build, "full PySide6 adds unused Qt modules to the AppImage"
    assert ".appdata.xml" in build, "appimagetool must discover AppStream metadata"
    assert "--smoke-test" in build, "bundle must be smoke-tested before packaging"


def test_linux_release_build_covers_all_formats_and_checksums():
    build = (ROOT / "packaging" / "linux" / "build-all.sh").read_text()
    for builder in ("deb", "rpm", "arch", "appimage", "flatpak"):
        assert f'/{builder}/build-' in build
    assert "sha256sum -c" in build


def test_native_gui_offscreen_smoke(tmp_path):
    screenshot = tmp_path / "ui.png"
    state = tmp_path / "state"
    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["XDG_STATE_HOME"] = str(state)
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "linux.ui_native",
            "--smoke-test",
            "--screenshot",
            str(screenshot),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert screenshot.exists()
    assert screenshot.stat().st_size > 20_000


def test_boot_selector_offscreen_smoke(tmp_path):
    screenshot = tmp_path / "boot-selector.png"
    state = tmp_path / "state"
    env = os.environ.copy()
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["XDG_STATE_HOME"] = str(state)
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "linux.ui_native",
            "--boot-selector",
            "--smoke-test",
            "--screenshot",
            str(screenshot),
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert screenshot.exists()
    assert screenshot.stat().st_size > 10_000


def test_profile_preview_runs_without_mutation(tmp_path):
    env = os.environ.copy()
    env["HOME"] = str(tmp_path / "home")
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    Path(env["HOME"]).mkdir()
    result = subprocess.run(
        [str(ROOT / "linux" / "pz"), "install", "safe-base", "--dry-run"],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "would install" in result.stdout.casefold()
    assert not (Path(env["HOME"]) / ".config").exists()


def test_qprocess_runner_writes_result_envelope(tmp_path):
    script = r"""
import json
import os
from pathlib import Path
from PySide6.QtCore import QCoreApplication, QTimer
from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

root = Path.cwd()
app = QCoreApplication([])
runner = CommandRunner(root)
action = next(a for a in build_catalog(root) if a.id == "system.version")
state = {"result": None}
def done(result):
    state["result"] = result
    app.quit()
runner.completed.connect(done)
QTimer.singleShot(60000, app.quit)
runner.start(action)
app.exec()
result = state["result"]
assert result is not None
assert result.ok
assert result.result_path.exists()
saved = json.loads(result.result_path.read_text())
assert saved["action"] == "system.version"
assert saved["exitCode"] == 0
assert saved["operationId"]
ledger_path = Path(os.environ["XDG_STATE_HOME"]) / "phasezero" / "control-center" / "operations" / saved["operationId"] / "operation.json"
ledger = json.loads(ledger_path.read_text())
assert ledger["status"] == "succeeded"
assert ledger["resultPath"] == str(result.result_path)
assert ledger["secretsRedacted"] is True
"""
    env = os.environ.copy()
    env["XDG_STATE_HOME"] = str(tmp_path / "state")
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_no_orphaned_bytecode_for_dead_pages():
    """CCS-030: nenhum .pyc sobrevive sem o .py correspondente em linux/."""
    orphans = [
        str(pyc.relative_to(ROOT))
        for pyc in ROOT.glob("linux/**/__pycache__/*.pyc")
        if not pyc.with_name(pyc.name.split(".")[0] + ".py").exists()
        and not (pyc.parent.parent / (pyc.name.split(".")[0] + ".py")).exists()
    ]
    assert orphans == [], f"pyc órfãos de páginas mortas: {orphans}"
