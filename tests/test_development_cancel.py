from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from PySide6.QtCore import QEventLoop, QProcess, QTimer
from PySide6.QtWidgets import QApplication, QPushButton


ROOT = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


def _assert_guarded_arch_container_ci() -> None:
    if (
        os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("GITHUB_JOB") != "arch-clean-host"
        or os.environ.get("GITHUB_REPOSITORY", "").casefold()
        != "misael-art/phase-zero"
        or os.geteuid() != 0
        or not Path("/etc/arch-release").is_file()
        or Path(shutil.which("pacman") or "/missing").resolve()
        != Path("/usr/bin/pacman").resolve()
    ):
        raise AssertionError("real pacman UI test requires guarded disposable Arch container CI")


def _pacman_install_pid(target: str) -> int | None:
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "cmdline").read_bytes().split(b"\0")
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        argv = [os.fsdecode(value) for value in raw if value]
        if (
            argv
            and Path(argv[0]).name == "pacman"
            and argv[1:] == ["-S", "--needed", "--noconfirm", target]
        ):
            return int(entry.name)
    return None


def _pacman_package_installed(name: str) -> bool:
    result = subprocess.run(
        ["pacman", "-Q", name], capture_output=True, text=True, timeout=20,
        check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1 and "was not found" in result.stderr.casefold():
        return False
    raise AssertionError(f"pacman -Q {name} inconclusive: {result.stderr.strip()}")


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def test_development_cancel_runs_engine_to_safe_boundary_and_keeps_resume_record(
    qapp, tmp_path, monkeypatch,
):
    from linux.ui_native.main_window import MainWindow

    real_pacman_ui = os.environ.get("PZ_ENABLE_ARCH_PACMAN_UI_CONTAINER") == "1"
    if real_pacman_ui:
        _assert_guarded_arch_container_ci()

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
    pid_file = tmp_path / "child.pid"
    marker = tmp_path / "child-survived-cancel"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(capability_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_STATE", str(package_state))
    monkeypatch.setenv("PZ_TEST_PACKAGE_EVENTS", str(package_events))
    monkeypatch.setenv("PZ_TEST_CHILD_PID", str(pid_file))
    monkeypatch.setenv("PZ_TEST_CHILD_MARKER", str(marker))

    from linux.capabilities import engine
    from linux.capabilities.platform import HostFacts, detect
    from linux.capabilities.providers import Provider

    if real_pacman_ui:
        # CI uses an Arch container, not a clean-host G2 snapshot. Override
        # detection only to exercise the public UI/provider transaction path.
        facts = replace(detect(), container=False)
        if (
            facts.package_family != "arch"
            or _pacman_package_installed("nodejs")
            or _pacman_package_installed("pnpm")
        ):
            raise AssertionError("real pacman UI test requires clean Arch without Node.js or pnpm")
    else:
        facts = HostFacts(
            platform="linux", architecture="x86_64", distro="arch", distro_like=(),
            package_family="arch", immutable=False, immutable_kind="", container=False,
            init="systemd", desktop="kde", session="wayland", gpus=("amd",),
            package_manager="pacman", flatpak=True, flathub=True,
        )

    class PlanningProvider(Provider):
        def installed(self, _source):
            return False

        def available(self, _source):
            return True

        def estimate_space(self, _source):
            return {"downloadBytes": 1024, "installedBytes": 4096}

        def estimate_transaction_space(self, _sources):
            return None

    monkeypatch.setattr(
        engine.shutil, "disk_usage",
        lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0),
    )
    plan_provider = Provider(facts) if real_pacman_ui else PlanningProvider(facts)
    plan = engine.create_plan(
        profile_ids=["development-web-js"], facts=facts, provider=plan_provider,
    )
    assert not plan["blockers"]
    assert [item["capabilityId"] for item in plan["actions"]] == [
        "development.nodejs", "development.pnpm",
    ]

    fake = tmp_path / "fake_provider.py"
    fake.write_text(
        "import json, os, subprocess, sys\n"
        "from pathlib import Path\n"
        "from types import SimpleNamespace\n"
        "sys.path.insert(0, r'__ROOT__')\n"
        "from linux.capabilities import __main__ as cli\n"
        "from linux.capabilities import engine\n"
        "from linux.capabilities.platform import HostFacts\n"
        "from linux.capabilities.providers import Provider\n"
        "facts = HostFacts(\n"
        " platform='linux', architecture='x86_64', distro='arch', distro_like=(),\n"
        " package_family='arch', immutable=False, immutable_kind='', container=False,\n"
        " init='systemd', desktop='kde', session='wayland', gpus=('amd',),\n"
        " package_manager='pacman', flatpak=True, flathub=True,\n"
        ")\n"
        "package_state = Path(os.environ['PZ_TEST_PACKAGE_STATE'])\n"
        "package_events = Path(os.environ['PZ_TEST_PACKAGE_EVENTS'])\n"
        "pid_file = Path(os.environ['PZ_TEST_CHILD_PID'])\n"
        "marker = Path(os.environ['PZ_TEST_CHILD_MARKER'])\n"
        "def installed_packages():\n"
        " return set(json.loads(package_state.read_text(encoding='utf-8'))) if package_state.exists() else set()\n"
        "class FakeProvider(Provider):\n"
        " def __init__(self):\n"
        "  super().__init__(facts)\n"
        " def installed(self, source):\n"
        "  return source.name in installed_packages()\n"
        " def available(self, _source):\n"
        "  return True\n"
        " def estimate_space(self, _source):\n"
        "  return {'downloadBytes': 1024, 'installedBytes': 4096}\n"
        " def estimate_transaction_space(self, _sources):\n"
        "  return None\n"
        " def execute(self, plan):\n"
        "  package = plan.args[-1]\n"
        "  with package_events.open('a', encoding='utf-8') as stream:\n"
        "   stream.write(json.dumps({'package': package}) + '\\n')\n"
        "  if package == 'nodejs':\n"
        "   code = 'import time; from pathlib import Path; import sys; time.sleep(2.0); '\n"
        "   code += 'Path(sys.argv[1]).write_bytes(bytes([115,116,101,112,45,102,105,110,105,115,104,101,100]))'\n"
        "   child = subprocess.Popen([sys.executable, '-c', code, str(marker)])\n"
        "   pid_file.write_text(str(child.pid), encoding='utf-8')\n"
        "   child_code = child.wait()\n"
        "   if child_code != 0:\n"
        "    return child_code, '', 'fixture child failed'\n"
        "  packages = installed_packages()\n"
        "  packages.add(package)\n"
        "  package_state.write_text(json.dumps(sorted(packages)), encoding='utf-8')\n"
        "  return 0, 'fixture package installed', ''\n"
        "provider = FakeProvider()\n"
        "engine.shutil.disk_usage = lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0)\n"
        "real_apply_plan = engine.apply_plan\n"
        "cli.detect = lambda: facts\n"
        "cli.apply_plan = lambda plan_id, **kwargs: real_apply_plan(\n"
        " plan_id, facts=facts, provider=provider, **kwargs,\n"
        ")\n"
        "arguments = sys.argv[1:]\n"
        "if arguments and arguments[0] == 'capabilities':\n"
        " arguments = arguments[1:]\n"
        "raise SystemExit(cli.main(arguments))\n".replace("__ROOT__", str(ROOT)),
        encoding="utf-8",
    )
    real_cli = tmp_path / "real_cli.py"
    if real_pacman_ui:
        real_cli.write_text(
            f"import sys\nsys.path.insert(0, {str(ROOT)!r})\n"
            "from dataclasses import replace\n"
            "from linux.capabilities import __main__ as cli\n"
            "from linux.capabilities.engine import apply_plan as real_apply_plan\n"
            "from linux.capabilities.platform import detect\n"
            "from linux.capabilities.providers import Provider\n"
            "facts = replace(detect(), container=False)\n"
            "provider = Provider(facts)\n"
            "cli.detect = lambda: facts\n"
            "cli.apply_plan = lambda plan_id, **kwargs: real_apply_plan(\n"
            " plan_id, facts=facts, provider=provider, **kwargs,\n"
            ")\n"
            "arguments = sys.argv[1:]\n"
            "if arguments and arguments[0] == 'capabilities':\n"
            " arguments = arguments[1:]\n"
            "raise SystemExit(cli.main(arguments))\n",
            encoding="utf-8",
        )

    def fake_request_action(window, action):
        # Cancellation under test; preview confirmation is covered by the
        # Development page's existing public-action tests.
        window.pending_action = action
        window.runner.start(action, preview=False)

    def fake_build_program(_root, _action, *, preview, value="", values=None):
        assert not preview
        cli_path = real_cli if real_pacman_ui else fake
        return sys.executable, [
            str(cli_path), "capabilities", "apply", "--plan-id", plan["id"],
            "--confirm", plan["confirmToken"],
        ]

    completed = []
    loop = QEventLoop()
    cancelled_pacman_pids = []

    def quiet_operation_completed(window, result):
        completed.append(result)
        window.cancel_button.setEnabled(False)
        loop.quit()

    monkeypatch.setattr(MainWindow, "request_action", fake_request_action)
    monkeypatch.setattr(MainWindow, "operation_completed", quiet_operation_completed)
    monkeypatch.setattr("linux.ui_native.command_runner.build_program", fake_build_program)
    host_patcher = patch.object(MainWindow, "_host_summary")
    status_patcher = patch("linux.ui_native.status_loader.StatusLoader.fetch_product_status")
    host_patcher.start()
    status_patcher.start()
    window = MainWindow(ROOT)
    cancelled = []
    cancel_file_paths = []
    window._ask_cancel = lambda _title, _elevated: True

    cancel_timer = QTimer(window)

    def cancel_when_package_running() -> None:
        child_pid = None
        if real_pacman_ui:
            child_pid = _pacman_install_pid("nodejs")
        elif pid_file.is_file():
            child_pid = int(pid_file.read_text(encoding="utf-8"))
        if child_pid is not None and not cancelled:
            cancelled.append(True)
            cancelled_pacman_pids.append(child_pid)
            assert window.cancel_button.isEnabled()
            window.cancel_button.click()
            assert window.runner.safe_cancel_pending
            assert window.runner.process.state() != QProcess.NotRunning
            assert window.runner._cancel_file is not None
            assert window.runner._cancel_file.is_file()
            cancel_file_paths.append(window.runner._cancel_file)

    cancel_timer.timeout.connect(cancel_when_package_running)
    try:
        window.show_category("Desenvolvimento")
        prepare = window.findChild(QPushButton, "prepareDevelopment")
        assert prepare is not None
        prepare.click()
        cancel_timer.start(10 if real_pacman_ui else 20)
        QTimer.singleShot(900_000 if real_pacman_ui else 6000, loop.quit)
        loop.exec()
        cancel_timer.stop()
        assert completed
        assert cancelled, (
            "UI operation completed before pacman cancellation was observed",
            completed[0].stdout, completed[0].stderr, completed[0].parsed,
        )
        if real_pacman_ui:
            assert cancelled_pacman_pids and cancelled_pacman_pids[0] > 0
        else:
            assert int(pid_file.read_text(encoding="utf-8")) > 0

        # The in-flight package step finishes; cancellation prevents later steps.
        if not real_pacman_ui:
            assert marker.read_bytes() == b"step-finished"
        assert completed[0].exit_code == 130, (
            completed[0].stdout, completed[0].stderr, completed[0].parsed,
        )
        assert completed[0].parsed["status"] == "cancelled"
        assert len(completed[0].parsed["results"]) == 1
        assert completed[0].parsed["results"][0]["capabilityId"] == "development.nodejs"
        assert completed[0].parsed["results"][0]["status"] == "installed"
        assert completed[0].parsed["results"][0]["exitCode"] == 0
        if real_pacman_ui:
            assert _pacman_package_installed("nodejs")
            assert not _pacman_package_installed("pnpm")
        else:
            assert json.loads(package_state.read_text(encoding="utf-8")) == ["nodejs"]
            package_attempts = [
                json.loads(line)["package"]
                for line in package_events.read_text(encoding="utf-8").splitlines()
            ]
            assert package_attempts == ["nodejs"]

        record = window.runner.ledger.records(limit=1)[0]
        assert record["status"] == "cancelled"
        assert record["resumable"] is True
        assert record["resumeMode"] == "retry-with-confirmation"
        assert record["nextAction"] == completed[0].action_id
        assert len(cancel_file_paths) == 1
        assert not cancel_file_paths[0].exists()
        operation = completed[0].parsed
        assert operation["id"]
        assert operation["rollbackToken"]
        rollback_provider = Provider(facts)
        if not real_pacman_ui:
            class FixtureRollbackProvider(PlanningProvider):
                def execute(self, command):
                    assert command.args == ("-Rs", "--noconfirm", "nodejs")
                    packages = set(json.loads(package_state.read_text(encoding="utf-8")))
                    packages.remove("nodejs")
                    package_state.write_text(json.dumps(sorted(packages)), encoding="utf-8")
                    return 0, "fixture package removed", ""

            rollback_provider = FixtureRollbackProvider(facts)
        rollback = engine.rollback_operation(
            operation["id"], confirmation=operation["rollbackToken"],
            facts=facts, provider=rollback_provider,
        )
        assert rollback["status"] == "complete"
        if real_pacman_ui:
            assert not _pacman_package_installed("nodejs")
        else:
            assert json.loads(package_state.read_text(encoding="utf-8")) == []
    finally:
        cancel_timer.stop()
        window.close()
        host_patcher.stop()
        status_patcher.stop()
