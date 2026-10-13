from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QTimer
from PySide6.QtWidgets import QApplication, QMessageBox, QPushButton


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


def _assert_guarded_arch_container_ci() -> None:
    if (
        os.environ.get("PZ_ENABLE_ARCH_PUBLIC_JOURNEY_CONTAINER") != "1"
        or os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("GITHUB_JOB") != "arch-clean-host"
        or os.environ.get("GITHUB_REPOSITORY") not in {"Misael-art/PhaseZero", "Misael-art/phase-zero"}
        or os.geteuid() != 0
        or not Path("/etc/arch-release").is_file()
        or Path(shutil.which("pacman") or "/missing").resolve()
        != Path("/usr/bin/pacman").resolve()
    ):
        raise AssertionError("real Development journey requires guarded Arch container CI")


def _pacman_package_installed(name: str) -> bool:
    result = subprocess.run(
        ["/usr/bin/pacman", "-Q", name], capture_output=True, text=True,
        timeout=20, check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1 and "was not found" in result.stderr.casefold():
        return False
    raise AssertionError(f"pacman -Q {name} inconclusive: {result.stderr.strip()}")


def _pacman_package_version(name: str) -> str:
    result = subprocess.run(
        ["/usr/bin/pacman", "-Q", name], capture_output=True, text=True,
        timeout=20, check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"pacman -Q {name} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def _system_python_version() -> str:
    result = subprocess.run(
        ["/usr/bin/python", "--version"], capture_output=True, text=True,
        timeout=20, check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"/usr/bin/python --version failed: {result.stderr.strip()}")
    return (result.stdout + result.stderr).strip()


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_public_journey_uses_real_pacman_in_disposable_arch_container(
    qapp, tmp_path, monkeypatch,
):
    if os.environ.get("PZ_ENABLE_ARCH_PUBLIC_JOURNEY_CONTAINER") != "1":
        pytest.skip("real package journey runs only in guarded Arch container CI")
    _assert_guarded_arch_container_ci()

    from linux.capabilities.engine import rollback_operation
    from linux.capabilities.platform import detect
    from linux.capabilities.providers import Provider
    from linux.ui_native.main_window import MainWindow
    from linux.ui_native.widgets import PreviewDialog, ResultDialog

    # This isolated container test overrides host detection only to exercise
    # the public real-pacman UI path. It cannot count as clean-host G2 evidence.
    facts = replace(detect(), container=False)
    if facts.package_family != "arch":
        raise AssertionError("guarded Arch container did not detect Arch package family")
    if _pacman_package_installed("nodejs") or _pacman_package_installed("pnpm"):
        raise AssertionError("real public journey requires clean Arch without Node.js or pnpm")
    system_python_package = _pacman_package_version("python")
    system_python_runtime = _system_python_version()
    print(
        f"OS Python baseline: pacman -Q python => {system_python_package}; "
        f"/usr/bin/python --version => {system_python_runtime}",
        flush=True,
    )

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state = home / ".local" / "state"
    cache = home / ".cache"
    runtime = tmp_path / "runtime"
    for path in (home, config, data, state, cache, runtime):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state))
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(runtime))
    capability_state = state / "phasezero-capabilities"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(capability_state))
    print(
        "Disposable Arch public journey writes: package root=/; "
        "pacman db=/var/lib/pacman; cache=/var/cache/pacman/pkg; "
        "log=/var/log/pacman.log; "
        f"HOME={home}; XDG_CONFIG_HOME={config}; XDG_DATA_HOME={data}; "
        f"XDG_STATE_HOME={state}; XDG_CACHE_HOME={cache}; "
        f"XDG_RUNTIME_DIR={runtime}; PZ_CAPABILITIES_STATE_DIR={capability_state}",
        flush=True,
    )

    real_cli = tmp_path / "real_capabilities_cli.py"
    real_cli.write_text(
        """\
import sys
from dataclasses import replace

sys.path.insert(0, r"__ROOT__")
from linux.capabilities import __main__ as cli
from linux.capabilities import engine
from linux.capabilities.platform import detect
from linux.capabilities.providers import Provider

facts = replace(detect(), container=False)
provider = Provider(facts)
real_create_plan = engine.create_plan
real_apply_plan = engine.apply_plan
real_catalog_payload = engine.catalog_payload
cli.detect = lambda: facts
cli.create_plan = lambda **kwargs: real_create_plan(
    **kwargs, facts=facts, provider=provider,
)
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

    def real_build_program(_root, action, *, preview, value="", values=None):
        args = action.resolved_args(value, preview=preview, values=values)
        return sys.executable, [str(real_cli), *args]

    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch(
        "linux.ui_native.status_loader.StatusLoader.fetch_product_status",
    )
    host_patcher.start()
    status_patcher.start()
    monkeypatch.setattr("linux.ui_native.command_runner.build_program", real_build_program)
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
                dialog_errors.append("preview did not enable confirmation")
                dialog.reject()
                return
            dialog.confirm.click()
        elif isinstance(dialog, ResultDialog):
            close = next(
                (button for button in dialog.findChildren(QPushButton)
                 if button.text() == "Fechar"),
                None,
            )
            if close is None:
                dialog_errors.append("result has no Fechar button")
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
        QTimer.singleShot(900_000, loop.quit)
        loop.exec()
        window.runner.completed.disconnect(check)
        assert len(results) >= count, "public Development journey timed out"

    try:
        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        page.reload = lambda: None

        page.findChild(QPushButton, "prepareDevelopment").click()
        wait_for_results(2)
        assert [result.preview for result in results] == [True, False]
        applied = results[1]
        assert applied.ok, (applied.exit_code, applied.stdout, applied.stderr, applied.parsed)
        operation = applied.parsed
        assert operation["status"] == "complete"
        assert operation["id"] and operation["rollbackToken"]
        assert {
            item["capabilityId"] for item in operation["installedByOperation"]
        } == {"development.nodejs", "development.pnpm"}
        assert _pacman_package_installed("nodejs")
        assert _pacman_package_installed("pnpm")
        package_versions = subprocess.run(
            ["/usr/bin/pacman", "-Q", "nodejs", "pnpm"],
            capture_output=True, text=True, timeout=20, check=False,
        )
        assert package_versions.returncode == 0, (
            package_versions.stdout, package_versions.stderr,
        )
        print(
            "Public prepareDevelopment confirmed PreviewDialog; engine status=complete; "
            "owned=development.nodejs,development.pnpm",
            flush=True,
        )
        print(
            "Installed package versions via pacman -Q nodejs pnpm:\n"
            f"{package_versions.stdout.strip()}",
            flush=True,
        )

        node = subprocess.run(
            ["/usr/bin/node", "--version"], capture_output=True, text=True,
            timeout=20, check=False,
        )
        pnpm = subprocess.run(
            ["/usr/bin/pnpm", "--version"], capture_output=True, text=True,
            timeout=30, check=False,
        )
        assert node.returncode == 0, (node.stdout, node.stderr)
        assert pnpm.returncode == 0, (pnpm.stdout, pnpm.stderr)
        assert node.stdout.strip().startswith("v") and pnpm.stdout.strip()
        assert _pacman_package_version("python") == system_python_package
        assert _system_python_version() == system_python_runtime
        print(
            f"Installed and used nodejs={node.stdout.strip()} via "
            f"/usr/bin/node --version; pnpm={pnpm.stdout.strip()} via "
            "/usr/bin/pnpm --version",
            flush=True,
        )

        page.findChild(QPushButton, "validateDevelopment").click()
        wait_for_results(3)
        assert results[2].action_id == "capability.status"
        status_by_id = {
            item["id"]: item["installed"] for item in results[2].parsed["capabilities"]
        }
        assert status_by_id["development.nodejs"] is True
        assert status_by_id["development.pnpm"] is True
        assert "Validação consultada" in page.status.text()
        print(
            "Public validateDevelopment confirms nodejs=true and pnpm=true",
            flush=True,
        )

        page.findChild(QPushButton, "openDevelopmentTool").click()
        assert window.stack.currentWidget() is window.registry.page_for("Aplicativos")
        assert window.registry.page_for("Aplicativos").selected_app_id == "app.nodejs"
        print("Public openDevelopmentTool selected canonical app.nodejs", flush=True)
        assert dialogs_seen.count("preview") == 1
        assert dialogs_seen.count("result") == 2
        assert not dialog_errors, dialog_errors

        rollback = rollback_operation(
            operation["id"], confirmation=operation["rollbackToken"],
            facts=facts, provider=Provider(facts),
        )
        assert rollback["status"] == "complete", rollback
        assert not _pacman_package_installed("nodejs")
        assert not _pacman_package_installed("pnpm")
        assert _pacman_package_version("python") == system_python_package
        assert _system_python_version() == system_python_runtime
        print(
            "First rollback complete; nodejs/pnpm absent; system Python package "
            "and runtime unchanged",
            flush=True,
        )

        window.show_category("Desenvolvimento")
        page = window.registry.page_for("Desenvolvimento")
        page.findChild(QPushButton, "prepareDevelopment").click()
        wait_for_results(5)
        assert results[3].preview is True and results[4].preview is False
        reapplied = results[4]
        assert reapplied.ok, (
            reapplied.exit_code, reapplied.stdout, reapplied.stderr, reapplied.parsed,
        )
        reactivated = reapplied.parsed
        assert reactivated["status"] == "complete"
        assert {
            item["capabilityId"] for item in reactivated["installedByOperation"]
        } == {"development.nodejs", "development.pnpm"}
        assert _pacman_package_installed("nodejs")
        assert _pacman_package_installed("pnpm")
        assert _pacman_package_version("python") == system_python_package
        assert _system_python_version() == system_python_runtime
        print(
            "Public reactivation completed through prepareDevelopment; both "
            "packages reinstalled; system Python unchanged",
            flush=True,
        )

        rollback = rollback_operation(
            reactivated["id"], confirmation=reactivated["rollbackToken"],
            facts=facts, provider=Provider(facts),
        )
        assert rollback["status"] == "complete", rollback
        assert not _pacman_package_installed("nodejs")
        assert not _pacman_package_installed("pnpm")
        assert _pacman_package_version("python") == system_python_package
        assert _system_python_version() == system_python_runtime
        print(
            "Final removal rollback complete; nodejs/pnpm absent; system Python "
            "package and runtime unchanged",
            flush=True,
        )
        assert dialogs_seen.count("preview") == 2
        assert dialogs_seen.count("result") == 3
    finally:
        modal_driver.stop()
        window.close()
        host_patcher.stop()
        status_patcher.stop()
