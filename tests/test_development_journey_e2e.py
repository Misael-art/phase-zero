from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QTimer
from PySide6.QtWidgets import QApplication, QLabel, QMessageBox, QPushButton


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_public_journey_retries_partial_failure_then_validates_and_opens(
    qapp, tmp_path, monkeypatch,
):
    from linux.ui_native.main_window import MainWindow
    from linux.ui_native.widgets import PreviewDialog, ResultDialog

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state = home / ".local" / "state"
    for path in (home, config, data, state):
        path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))
    capability_state = state / "phasezero-capabilities"
    package_state = tmp_path / "installed-packages.json"
    package_events = tmp_path / "fake-package-events.jsonl"
    pnpm_failure = tmp_path / "pnpm-first-attempt-failed"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(capability_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_STATE", str(package_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_EVENTS", str(package_events))
    monkeypatch.setenv("PZ_TEST_PNPM_FAILURE", str(pnpm_failure))

    events_file = tmp_path / "fake-operations.jsonl"
    fake = tmp_path / "fake_capabilities.py"
    fake.write_text(
        """\
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, r"__ROOT__")
from linux.capabilities import __main__ as cli
from linux.capabilities import engine
from linux.capabilities.platform import HostFacts
from linux.capabilities.providers import Provider

facts = HostFacts(
    platform="linux", architecture="x86_64", distro="arch", distro_like=(),
    package_family="arch", immutable=False, immutable_kind="", container=False,
    init="systemd", desktop="kde", session="wayland", gpus=("amd",),
    package_manager="pacman", flatpak=True, flathub=True,
)
package_state = Path(os.environ["PZ_TEST_PACKAGE_STATE"])
package_events = Path(os.environ["PZ_TEST_PACKAGE_EVENTS"])
pnpm_failure = Path(os.environ["PZ_TEST_PNPM_FAILURE"])

def installed_packages():
    return set(json.loads(package_state.read_text(encoding="utf-8"))) if package_state.exists() else set()

class FakeProvider(Provider):
    def __init__(self):
        super().__init__(facts)

    def installed(self, source):
        return source.name in installed_packages()

    def available(self, source):
        return True

    def estimate_space(self, source):
        return {"downloadBytes": 1024, "installedBytes": 4096}

    def estimate_transaction_space(self, sources):
        return None

    def execute(self, plan):
        package = plan.args[-1]
        with package_events.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"package": package, "command": plan.command()}) + "\\n")
        if package == "pnpm" and not pnpm_failure.exists():
            pnpm_failure.touch()
            return 1, "", "fixture package failure"
        packages = installed_packages()
        packages.add(package)
        package_state.write_text(json.dumps(sorted(packages)), encoding="utf-8")
        return 0, "fixture package installed", ""

provider = FakeProvider()
engine.shutil.disk_usage = lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0)
real_create_plan = engine.create_plan
real_apply_plan = engine.apply_plan
real_catalog_payload = engine.catalog_payload
cli.detect = lambda: facts
cli.create_plan = lambda **kwargs: real_create_plan(**kwargs, facts=facts, provider=provider)
cli.apply_plan = lambda plan_id, **kwargs: real_apply_plan(
    plan_id, facts=facts, provider=provider, **kwargs,
)
cli.catalog_payload = lambda **kwargs: real_catalog_payload(
    facts=facts, provider=provider, **kwargs,
)
arguments = sys.argv[1:]
if arguments and arguments[0] == "capabilities":
    arguments = arguments[1:]
raise SystemExit(cli.main(arguments))
""".replace("__ROOT__", str(ROOT)),
        encoding="utf-8",
    )

    def fake_build_program(_root, action, *, preview, value="", values=None):
        phase = "preview" if preview else "status" if action.id == "capability.status" else "apply"
        args = action.resolved_args(value, preview=preview, values=values)
        with events_file.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"action": action.id, "phase": phase, "args": args}) + "\n")
        return sys.executable, [str(fake), *args]

    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    monkeypatch.setattr("linux.ui_native.command_runner.build_program", fake_build_program)
    window = MainWindow(ROOT)
    results = []
    dialogs_seen = []
    dialog_errors = []
    window.runner.completed.connect(results.append)
    modal_driver = QTimer(window)

    def click_modal_controls() -> None:
        dialog = qapp.activeModalWidget()
        if isinstance(dialog, PreviewDialog):
            dialogs_seen.append("preview")
            if not dialog.confirm.isEnabled():
                dialog_errors.append("preview não habilitou confirmação")
                dialog.reject()
                return
            dialog.confirm.click()
        elif isinstance(dialog, ResultDialog):
            close = next(
                (button for button in dialog.findChildren(QPushButton) if button.text() == "Fechar"),
                None,
            )
            if close is None:
                dialog_errors.append("resultado sem botão Fechar")
                dialog.reject()
            else:
                dialogs_seen.append("result")
                close.click()
        elif isinstance(dialog, QMessageBox):
            dialog_errors.append(dialog.text())
            dialog.accept()

    modal_driver.timeout.connect(click_modal_controls)
    modal_driver.start(10)

    def wait_for_results(count: int) -> None:
        if len(results) >= count:
            return
        loop = QEventLoop()

        def check(_result) -> None:
            if len(results) >= count:
                loop.quit()

        window.runner.completed.connect(check)
        QTimer.singleShot(10000, loop.quit)
        loop.exec()
        window.runner.completed.disconnect(check)
        assert len(results) >= count

    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        page.reload = lambda: None

        page.findChild(QPushButton, "prepareDevelopment").click()
        wait_for_results(2)
        assert [result.preview for result in results[:2]] == [True, False]
        assert results[1].exit_code == 0 and not results[1].ok
        assert results[1].parsed["status"] == "failed"
        assert window.status_text.text() == "Falhou"
        assert "incompleta" in page.status.text()
        assert json.loads(package_state.read_text(encoding="utf-8")) == ["nodejs"]

        page.findChild(QPushButton, "prepareDevelopment").click()
        wait_for_results(4)
        assert [result.preview for result in results[2:4]] == [True, False]
        assert results[3].ok, (results[3].exit_code, results[3].stdout, results[3].stderr, results[3].parsed)
        assert "Preparação concluída" in page.status.text()
        assert json.loads(package_state.read_text(encoding="utf-8")) == ["nodejs", "pnpm"]
        package_attempts = [
            json.loads(line)["package"]
            for line in package_events.read_text(encoding="utf-8").splitlines()
        ]
        assert package_attempts == ["nodejs", "pnpm", "pnpm"]

        page.findChild(QPushButton, "validateDevelopment").click()
        wait_for_results(5)
        assert results[4].action_id == "capability.status"
        status_by_id = {
            item["id"]: item["installed"] for item in results[4].parsed["capabilities"]
        }
        assert status_by_id["development.nodejs"] is True
        assert status_by_id["development.pnpm"] is True
        assert "Validação consultada" in page.status.text()

        page.findChild(QPushButton, "openDevelopmentTool").click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == "app.nodejs"
        assert dialogs_seen.count("preview") == 2
        assert dialogs_seen.count("result") == 3
        assert not dialog_errors, dialog_errors
        events = [json.loads(line) for line in events_file.read_text(encoding="utf-8").splitlines()]
        assert [(event["phase"], event["action"]) for event in events] == [
            ("preview", "capability.profile.development-web-js"),
            ("apply", "capability.profile.development-web-js"),
            ("preview", "capability.profile.development-web-js"),
            ("apply", "capability.profile.development-web-js"),
            ("status", "capability.status"),
        ]
        first_apply_args = results[1].command[2:]
        second_apply_args = results[3].command[2:]
        first_preview = results[0].parsed
        second_preview = results[2].parsed
        assert first_preview["id"] != second_preview["id"]
        assert first_apply_args[:5] == [
            "capabilities", "apply", "--plan-id", first_preview["id"],
            "--confirm",
        ]
        assert first_apply_args[5] == first_preview["confirmToken"]
        assert second_apply_args[:5] == [
            "capabilities", "apply", "--plan-id", second_preview["id"],
            "--confirm",
        ]
        assert second_apply_args[5] == second_preview["confirmToken"]
        assert first_apply_args[6] == second_apply_args[6] == "--cancel-file"
        assert not Path(first_apply_args[7]).exists()
        assert not Path(second_apply_args[7]).exists()
    finally:
        modal_driver.stop()
        window.close()
        host_patcher.stop()
        status_patcher.stop()
