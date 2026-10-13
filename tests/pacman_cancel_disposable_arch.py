"""Disposable Arch CI probe: real pacman cancellation and crash recovery.

Not collected by pytest. The explicit guards prevent accidental package
transactions on a developer host.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import replace
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.capabilities import state as capability_state
from linux.capabilities.engine import apply_plan, create_plan, rollback_operation
from linux.capabilities.platform import detect
from linux.capabilities.providers import Provider


def _assert_disposable_arch_ci() -> None:
    if (
        os.environ.get("PZ_ENABLE_ARCH_PACMAN_CONTAINER") != "1"
        or os.environ.get("GITHUB_ACTIONS") != "true"
        or os.environ.get("GITHUB_JOB") != "arch-clean-host"
        or os.geteuid() != 0
        or not Path("/etc/arch-release").is_file()
    ):
        raise SystemExit("requires the guarded disposable Arch CI container")


def _facts():
    # The CI container is not a clean-host G2 snapshot; this override exists
    # only for real pacman transaction/cancellation regression coverage.
    facts = replace(detect(), container=False)
    real_pacman = Path("/usr/bin/pacman").resolve()
    resolved_pacman = Path(shutil.which(facts.package_manager) or "/missing").resolve()
    if facts.package_family != "arch" or resolved_pacman != real_pacman:
        raise RuntimeError("real Arch pacman is unavailable")
    return facts


def _is_installed(name: str) -> bool:
    result = subprocess.run(
        ["pacman", "-Q", name], capture_output=True, text=True, timeout=20,
        check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 1 and "was not found" in result.stderr.casefold():
        return False
    raise RuntimeError(f"pacman -Q {name} inconclusive: {result.stderr.strip()}")


def _running_install(target: str) -> int | None:
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
            and argv[1:4] == ["-S", "--needed", "--noconfirm"]
            and argv[4:] == [target]
        ):
            return int(entry.name)
    return None


def _proc_state(pid: int) -> str | None:
    try:
        for line in (Path("/proc") / str(pid) / "status").read_text().splitlines():
            if line.startswith("State:"):
                return line.split()[1]
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return None
    return None


def _kill_worker_during_install(
    process: subprocess.Popen[str], target: str,
) -> tuple[int, str, str]:
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        pacman_pid = _running_install(target)
        if pacman_pid is not None:
            os.kill(process.pid, signal.SIGSTOP)
            stop_deadline = time.monotonic() + 10
            while time.monotonic() < stop_deadline:
                if _proc_state(process.pid) in {"T", "t"}:
                    if _running_install(target) != pacman_pid:
                        os.kill(process.pid, signal.SIGKILL)
                        process.communicate(timeout=10)
                        raise RuntimeError(
                            f"pacman transaction ended before worker crash: {target}"
                        )
                    os.kill(process.pid, signal.SIGKILL)
                    stdout, stderr = process.communicate(timeout=10)
                    if process.returncode != -signal.SIGKILL:
                        raise RuntimeError(
                            f"apply worker was not killed: returncode={process.returncode}"
                        )
                    return pacman_pid, stdout, stderr
                if process.poll() is not None:
                    break
                time.sleep(0.01)
            if process.poll() is None:
                _stop_process_group(process)
            raise RuntimeError(f"could not stop apply worker during pacman: {target}")
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"apply exited before real pacman install for {target}: "
                f"stdout={stdout!r} stderr={stderr!r}"
            )
        time.sleep(0.05)
    _stop_process_group(process)
    raise RuntimeError(f"real pacman install did not start for worker crash: {target}")


def _wait_for_install_exit(pid: int, target: str, timeout: int = 900) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _running_install(target) != pid:
            return
        time.sleep(0.05)
    raise RuntimeError(f"orphaned pacman install timed out: {target}")


def _wait_for_post_commit_worker(
    process: subprocess.Popen[str], marker: Path, target: str,
) -> None:
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if marker.exists():
            if process.poll() is not None:
                stdout, stderr = process.communicate()
                raise RuntimeError(
                    f"worker exited after real package commit: "
                    f"stdout={stdout!r} stderr={stderr!r}"
                )
            if not _is_installed(target) or _running_install(target) is not None:
                raise RuntimeError(
                    "post-commit barrier did not observe a finished pacman install"
                )
            os.kill(process.pid, signal.SIGSTOP)
            stop_deadline = time.monotonic() + 10
            while time.monotonic() < stop_deadline:
                if _proc_state(process.pid) in {"T", "t"}:
                    return
                if process.poll() is not None:
                    break
                time.sleep(0.01)
            raise RuntimeError("could not stop worker after real package commit")
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"worker exited before post-commit barrier: "
                f"stdout={stdout!r} stderr={stderr!r}"
            )
        time.sleep(0.02)
    raise RuntimeError("worker did not reach post-commit barrier")


def _clear_stale_pacman_lock() -> None:
    live_pacman: list[int] = []
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
            and _proc_state(int(entry.name)) not in {"Z", "X"}
        ):
            live_pacman.append(int(entry.name))
    if live_pacman:
        raise RuntimeError(f"refusing to clear pacman lock while processes run: {live_pacman}")

    lock = Path("/var/lib/pacman/db.lck")
    if lock.is_symlink():
        raise RuntimeError("refusing to clear unexpected pacman lock symlink")
    if lock.exists():
        if not lock.is_file():
            raise RuntimeError("refusing to clear unexpected pacman lock type")
        lock.unlink()
        print("removed stale pacman db.lck in guarded disposable Arch container", flush=True)


def _stop_orphaned_install(group_id: int, pid: int, target: str) -> None:
    if _running_install(target) != pid:
        return
    try:
        if os.getpgid(pid) != group_id:
            return
        os.killpg(group_id, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and _running_install(target) == pid:
        time.sleep(0.05)
    if _running_install(target) == pid:
        try:
            if os.getpgid(pid) == group_id:
                os.killpg(group_id, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _stop_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=10)


def _set_sandbox_paths(root: Path) -> None:
    home = root / "home"
    runtime = root / "runtime"
    home.mkdir(mode=0o700)
    runtime.mkdir(mode=0o700)
    (home / ".config").mkdir(mode=0o700)
    (home / ".local/share").mkdir(parents=True, mode=0o700)
    (home / ".local/state").mkdir(parents=True, mode=0o700)
    (home / ".cache").mkdir(mode=0o700)
    os.environ["HOME"] = str(home)
    os.environ["XDG_CONFIG_HOME"] = str(home / ".config")
    os.environ["XDG_DATA_HOME"] = str(home / ".local/share")
    os.environ["XDG_STATE_HOME"] = str(home / ".local/state")
    os.environ["XDG_CACHE_HOME"] = str(home / ".cache")
    os.environ["XDG_RUNTIME_DIR"] = str(runtime)
    os.environ["PZ_CAPABILITIES_STATE_DIR"] = str(root / "capabilities-state")
    os.environ["LANG"] = "C"
    os.environ["LC_ALL"] = "C"
    print(
        "Disposable Arch CI writes: root=/; pacman-db=/var/lib/pacman; "
        "cache=/var/cache/pacman/pkg; log=/var/log/pacman.log; "
        f"HOME={home}; PZ state={root / 'capabilities-state'}",
        flush=True,
    )


def _apply_child(
    plan_id: str,
    confirmation: str,
    cancel_path: Path | None,
    *,
    package_commit_marker: Path | None = None,
) -> int:
    facts = _facts()
    provider = Provider(facts)
    if package_commit_marker is not None:
        execute = provider.execute
        release_marker = package_commit_marker.with_name(
            package_commit_marker.name + ".release"
        )

        def execute_then_pause(plan):
            result = execute(plan)
            command = plan.command()
            if (
                result[0] == 0
                and Path(shutil.which(command[0]) or command[0]).resolve()
                == Path("/usr/bin/pacman")
                and command[1:] == ["-S", "--needed", "--noconfirm", "nodejs"]
            ):
                package_commit_marker.touch(mode=0o600, exist_ok=False)
                while not release_marker.exists():
                    time.sleep(0.02)
            return result

        provider.execute = execute_then_pause
    record = apply_plan(
        plan_id,
        confirmation=confirmation,
        facts=facts,
        provider=provider,
        cancel_file=cancel_path,
    )
    print(json.dumps(record, separators=(",", ":")))
    return 0


def _wait_for_real_pacman(
    process: subprocess.Popen[str], target: str, cancel_path: Path,
) -> tuple[str, str]:
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if _running_install(target) is not None:
            cancel_path.touch(mode=0o600)
            print(f"cancel request recorded during pacman install: {target}", flush=True)
            try:
                return process.communicate(timeout=900)
            except subprocess.TimeoutExpired as exc:
                _stop_process_group(process)
                raise RuntimeError(f"pacman install timed out: {target}") from exc
        if process.poll() is not None:
            stdout, stderr = process.communicate()
            raise RuntimeError(
                f"apply exited before real pacman install for {target}: "
                f"stdout={stdout!r} stderr={stderr!r}"
            )
        time.sleep(0.05)
    _stop_process_group(process)
    raise RuntimeError(f"real pacman install did not start for {target}")


def _run() -> None:
    _assert_disposable_arch_ci()
    facts = _facts()
    provider = Provider(facts)
    for package in ("nodejs", "pnpm"):
        if _is_installed(package):
            raise RuntimeError(f"clean Arch container unexpectedly has {package}")

    temp_root = Path(tempfile.mkdtemp(prefix="pxa004-pacman-cancel-"))
    os.chmod(temp_root, 0o700)
    try:
        _set_sandbox_paths(temp_root)
        plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        if not plan.get("ok") or plan.get("status") != "ready":
            raise RuntimeError(f"Arch development profile did not plan: {plan!r}")
        expected = [
            (item["capabilityId"], item["source"]["name"])
            for item in plan["actions"]
        ]
        if expected != [("development.nodejs", "nodejs"), ("development.pnpm", "pnpm")]:
            raise RuntimeError(f"unexpected development-web-js plan: {expected!r}")

        cancel_path = temp_root / "cancel.request"
        child = subprocess.Popen(
            [
                sys.executable, str(Path(__file__).resolve()), "_apply",
                str(plan["id"]), str(plan["confirmToken"]), str(cancel_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = _wait_for_real_pacman(child, "nodejs", cancel_path)
        except BaseException:
            _stop_process_group(child)
            raise
        if child.returncode != 0:
            raise RuntimeError(f"real apply failed: stdout={stdout!r} stderr={stderr!r}")
        cancelled = json.loads(stdout)
        if (
            cancelled.get("status") != "cancelled"
            or [item["capabilityId"] for item in cancelled["installedByOperation"]]
            != ["development.nodejs"]
            or not _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"real cancellation boundary was incorrect: {cancelled!r}")

        cancel_path.unlink()
        resumed = apply_plan(
            plan["id"], confirmation=plan["confirmToken"],
            facts=facts, provider=provider,
        )
        if (
            resumed.get("status") != "complete"
            or [item["capabilityId"] for item in resumed["installedByOperation"]]
            != ["development.pnpm"]
            or not _is_installed("nodejs")
            or not _is_installed("pnpm")
        ):
            raise RuntimeError(f"real resume did not complete the profile: {resumed!r}")
        subprocess.run(["node", "--eval", "process.stdout.write('node-ok')"], check=True)
        subprocess.run(["pnpm", "--version"], check=True)

        repeated_plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        repeated = apply_plan(
            repeated_plan["id"], confirmation=repeated_plan["confirmToken"],
            facts=facts, provider=provider,
        )
        if (
            repeated.get("status") != "complete"
            or repeated.get("installedByOperation")
            or any(item.get("status") != "preexisting" for item in repeated["results"])
        ):
            raise RuntimeError(f"real repeat was not idempotent: {repeated!r}")

        rollback_pnpm = rollback_operation(
            resumed["id"], confirmation=resumed["rollbackToken"],
            facts=facts, provider=provider,
        )
        if (
            rollback_pnpm.get("status") != "complete"
            or not _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"rollback removed shared Node.js or kept pnpm: {rollback_pnpm!r}")
        rollback_node = rollback_operation(
            cancelled["id"], confirmation=cancelled["rollbackToken"],
            facts=facts, provider=provider,
        )
        if (
            rollback_node.get("status") != "complete"
            or _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(f"final rollback left packages installed: {rollback_node!r}")

        crash_plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        if not crash_plan.get("ok") or crash_plan.get("status") != "ready":
            raise RuntimeError(f"Arch crash-recovery profile did not plan: {crash_plan!r}")
        crash_worker = subprocess.Popen(
            [
                sys.executable, str(Path(__file__).resolve()), "_apply",
                str(crash_plan["id"]), str(crash_plan["confirmToken"]),
                str(temp_root / "crash-cancel-unused"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        crash_pacman_pid: int | None = None
        try:
            crash_pacman_pid, crash_stdout, crash_stderr = (
                _kill_worker_during_install(crash_worker, "nodejs")
            )
            if crash_stdout or crash_stderr:
                print(
                    "Killed apply worker output captured before crash: "
                    f"stdout={crash_stdout!r} stderr={crash_stderr!r}",
                    flush=True,
                )
            _wait_for_install_exit(crash_pacman_pid, "nodejs")
            _clear_stale_pacman_lock()
        except BaseException:
            _stop_process_group(crash_worker)
            if crash_pacman_pid is not None:
                _stop_orphaned_install(crash_worker.pid, crash_pacman_pid, "nodejs")
            raise
        orphaned_nodejs = _is_installed("nodejs")
        print(
            "post-crash package observation: "
            f"nodejs={'installed without worker record' if orphaned_nodejs else 'absent'}",
            flush=True,
        )
        if _is_installed("pnpm"):
            raise RuntimeError("orphaned real pacman transaction left unexpected packages")

        crash_resumed = apply_plan(
            crash_plan["id"], confirmation=crash_plan["confirmToken"],
            facts=facts, provider=provider,
        )
        expected_owned = ["development.pnpm"]
        if not orphaned_nodejs:
            expected_owned.insert(0, "development.nodejs")
        if (
            crash_resumed.get("status") != "complete"
            or [item["capabilityId"] for item in crash_resumed["installedByOperation"]]
            != expected_owned
            or not _is_installed("nodejs")
            or not _is_installed("pnpm")
        ):
            raise RuntimeError(
                f"real resume adopted package from crashed worker: {crash_resumed!r}"
            )
        subprocess.run(
            ["node", "--eval", "process.stdout.write('crash-resume-node-ok')"],
            check=True,
        )
        subprocess.run(["pnpm", "--version"], check=True)
        crash_rollback = rollback_operation(
            crash_resumed["id"], confirmation=crash_resumed["rollbackToken"],
            facts=facts, provider=provider,
        )
        if (
            crash_rollback.get("status") != "complete"
            or _is_installed("nodejs") != orphaned_nodejs
            or _is_installed("pnpm")
        ):
            raise RuntimeError(
                f"crash recovery rollback removed unowned Node.js: {crash_rollback!r}"
            )
        if orphaned_nodejs:
            subprocess.run(["pacman", "-Rns", "--noconfirm", "nodejs"], check=True)
        if _is_installed("nodejs") or _is_installed("pnpm"):
            raise RuntimeError("crash-recovery cleanup left test packages installed")

        commit_plan = create_plan(
            profile_ids=["development-web-js"], facts=facts, provider=provider,
        )
        if not commit_plan.get("ok") or commit_plan.get("status") != "ready":
            raise RuntimeError(f"Arch post-commit profile did not plan: {commit_plan!r}")
        commit_marker = temp_root / "nodejs-package-committed"
        commit_worker = subprocess.Popen(
            [
                sys.executable, str(Path(__file__).resolve()), "_apply_after_commit",
                str(commit_plan["id"]), str(commit_plan["confirmToken"]),
                str(commit_marker),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            _wait_for_post_commit_worker(commit_worker, commit_marker, "nodejs")
            if _is_installed("pnpm"):
                raise RuntimeError("post-commit barrier reached after unexpected pnpm install")
            if any(
                item.get("planId") == commit_plan["id"]
                for item in capability_state.list_records("operations")
            ):
                raise RuntimeError("operation was recorded before the crash injection point")
            os.kill(commit_worker.pid, signal.SIGKILL)
            commit_stdout, commit_stderr = commit_worker.communicate(timeout=10)
            if commit_worker.returncode != -signal.SIGKILL:
                raise RuntimeError(
                    f"post-commit worker was not killed: "
                    f"returncode={commit_worker.returncode}"
                )
            print(
                "killed apply worker after real pacman committed nodejs and before "
                "operation record was saved",
                flush=True,
            )
            if commit_stdout or commit_stderr:
                print(
                    "Post-commit worker output captured before crash: "
                    f"stdout={commit_stdout!r} stderr={commit_stderr!r}",
                    flush=True,
                )
        except BaseException:
            _stop_process_group(commit_worker)
            raise

        if not _is_installed("nodejs") or _is_installed("pnpm"):
            raise RuntimeError("real package commit was not preserved across worker crash")
        committed_resumed = apply_plan(
            commit_plan["id"], confirmation=commit_plan["confirmToken"],
            facts=facts, provider=provider,
        )
        if (
            committed_resumed.get("status") != "complete"
            or [item["capabilityId"] for item in committed_resumed["installedByOperation"]]
            != ["development.pnpm"]
            or not _is_installed("nodejs")
            or not _is_installed("pnpm")
        ):
            raise RuntimeError(
                f"post-commit resume claimed package without operation record: "
                f"{committed_resumed!r}"
            )
        committed_rollback = rollback_operation(
            committed_resumed["id"],
            confirmation=committed_resumed["rollbackToken"],
            facts=facts,
            provider=provider,
        )
        if (
            committed_rollback.get("status") != "complete"
            or not _is_installed("nodejs")
            or _is_installed("pnpm")
        ):
            raise RuntimeError(
                f"post-commit rollback removed unowned Node.js: {committed_rollback!r}"
            )
        print(
            "post-commit recovery recorded only pnpm; rollback removed pnpm and "
            "preserved unowned Node.js",
            flush=True,
        )
        subprocess.run(["pacman", "-Rns", "--noconfirm", "nodejs"], check=True)

        print(
            "PASS: real pacman completed active Node.js transaction, honored cancel "
            "at the safe boundary, resumed pnpm, repeated idempotently, and rolled back; "
            "a killed worker recovered mid-transaction; a second worker killed after "
            "real Node.js commit resumed without claiming the unrecorded package, "
            "and rollback preserved it."
        )
    finally:
        shutil.rmtree(temp_root)


def main() -> int:
    _assert_disposable_arch_ci()
    os.environ["LANG"] = "C"
    os.environ["LC_ALL"] = "C"
    if len(sys.argv) == 5 and sys.argv[1] == "_apply":
        return _apply_child(sys.argv[2], sys.argv[3], Path(sys.argv[4]))
    if len(sys.argv) == 5 and sys.argv[1] == "_apply_after_commit":
        return _apply_child(
            sys.argv[2], sys.argv[3], None,
            package_commit_marker=Path(sys.argv[4]),
        )
    if len(sys.argv) != 1:
        raise SystemExit("usage: pacman_cancel_disposable_arch.py")
    _run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
