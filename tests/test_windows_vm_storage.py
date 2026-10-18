from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("winvm_storage", ROOT / "linux/windows-vm/storage.py")
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)


@pytest.fixture
def entry(tmp_path, monkeypatch):
    if not shutil.which("qemu-img"):
        pytest.skip("qemu-img unavailable")
    monkeypatch.setattr(storage, "live_qemu", lambda: False)
    base = tmp_path / "disk.qcow2"
    subprocess.run(["qemu-img", "create", "-f", "qcow2", "-o", "preallocation=off", str(base), "256G"], check=True, capture_output=True)
    subprocess.run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(tmp_path / "golden-clean.qcow2")], check=True, capture_output=True)
    return {"id": "op-fixture", "vmDir": str(tmp_path), "state": "completed"}


def test_real_dynamic_disk_and_read_only_check(entry):
    root = Path(entry["vmDir"])
    before = {p: storage.signature(p) for p in root.iterdir()}
    accounted = storage.accounting(entry)
    assert accounted["virtualBytes"] == 256 * 1024**3
    assert accounted["baseBytes"] < 1024**2
    result = storage.integrity(entry)
    assert result["state"] == "structure-checked"
    assert result["bootVerified"] is False
    assert all(i["state"] == "clean" for i in result["images"])
    assert before == {p: storage.signature(p) for p in root.iterdir()}


def test_missing_snapshot_is_problem_not_completed_health(entry):
    (Path(entry["vmDir"]) / "golden-clean.qcow2").unlink()
    result = storage.integrity(entry)
    assert result["state"] == "issues"
    assert result["completionRecorded"] is True
    assert result["images"][1]["state"] == "missing"


def test_qcow2_grows_only_when_written(entry):
    if not shutil.which("qemu-io"):
        pytest.skip("qemu-io unavailable")
    path = Path(entry["vmDir"]) / "disk.qcow2"
    before = storage.disk_size(path)
    subprocess.run(["qemu-io", "-f", "qcow2", "-c", "write -P 0x5a 0 1M", str(path)], check=True, capture_output=True)
    after = storage.disk_size(path)
    assert after["virtualBytes"] == before["virtualBytes"]
    assert before["allocatedBytes"] < after["allocatedBytes"] < 4 * 1024**2


def test_partial_installation_without_snapshot_is_incomplete(entry):
    entry["state"] = "interrupted"
    (Path(entry["vmDir"]) / "golden-clean.qcow2").unlink()
    assert storage.integrity(entry)["state"] == "incomplete"


def test_invalid_image_and_symlink_never_healthy(entry):
    path = Path(entry["vmDir"]) / "disk.qcow2"
    path.write_bytes(b"not a disk")
    assert storage.integrity(entry)["state"] == "issues"
    path.unlink()
    path.symlink_to("golden-clean.qcow2")
    assert storage.integrity(entry)["state"] == "issues"


def test_adopted_copy_accounted_separately_and_checked(entry, tmp_path):
    adopted = tmp_path / "activated.qcow2"
    shutil.copyfile(tmp_path / "disk.qcow2", adopted)
    entry["adoptedDisk"] = str(adopted)
    result = storage.integrity(entry)
    assert result["storage"]["adoptedDisk"]["available"]
    assert len(result["images"]) == 3


def test_busy_never_opens_images(entry, monkeypatch):
    monkeypatch.setattr(storage, "live_qemu", lambda: True)
    monkeypatch.setattr(storage, "run", lambda *_a, **_k: pytest.fail("external process on busy image"))
    assert storage.integrity(entry)["state"] == "busy"


def test_timeout_is_inconclusive(entry, monkeypatch):
    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 30)
    monkeypatch.setattr(storage, "run", timeout)
    assert storage.integrity(entry)["state"] == "timeout"


def test_invalid_response_is_inconclusive(entry, monkeypatch):
    monkeypatch.setattr(storage, "run", lambda *a, **k: subprocess.CompletedProcess(a, 0, "not JSON", ""))
    assert storage.integrity(entry)["state"] == "unknown"


@pytest.mark.parametrize("code,state", [(2, "issues"), (3, "issues"), (1, "unknown"), (63, "unknown")])
def test_qcow_failures_are_not_success(entry, monkeypatch, code, state):
    actual_run = storage.run
    def injected(args, **kwargs):
        if args[1] == "check":
            assert "-r" not in args and "-U" not in args
            return subprocess.CompletedProcess(args, code, "{}", "")
        return actual_run(args, **kwargs)
    monkeypatch.setattr(storage, "run", injected)
    assert storage.integrity(entry)["state"] == state


@pytest.mark.parametrize("guest_state,state", [("present", "checked"), ("missing-files", "issues"), ("unknown", "unknown"), ("unavailable", "unknown")])
def test_windows_files_separate_from_image_structure(entry, monkeypatch, guest_state, state):
    monkeypatch.setattr(storage, "guest_files", lambda path: {"state": guest_state})
    result = storage.integrity(entry, inspect_guest=True)
    assert result["state"] == state
    assert not result["bootVerified"]


def test_guestfish_read_only_fixed_commands(monkeypatch, tmp_path):
    monkeypatch.setattr(storage.shutil, "which", lambda _: "/usr/bin/guestfish")
    def capture(args, **kwargs):
        assert "--ro" in args and "--format=qcow2" in args
        assert kwargs["script"].splitlines() == ["is-file " + p for p in storage.WINDOWS_FILES]
        return subprocess.CompletedProcess(args, 0, "true\ntrue\nfalse\ntrue\n", "")
    monkeypatch.setattr(storage, "run", capture)
    result = storage.guest_files(tmp_path / "snapshot.qcow2")
    assert result["state"] == "missing-files"
    assert result["missingFiles"] == ["/Windows/System32/ntoskrnl.exe"]


def test_changed_disk_invalidates_observation(entry, monkeypatch):
    actual_run = storage.run
    def changed(args, **kwargs):
        result = actual_run(args, **kwargs)
        if args[1] == "check":
            Path(args[-1]).touch()
        return result
    monkeypatch.setattr(storage, "run", changed)
    assert storage.integrity(entry)["state"] == "changed"


def test_external_backing_is_rejected(entry, tmp_path):
    snap = tmp_path / "golden-clean.qcow2"
    snap.unlink()
    outside = tmp_path / "another-base.qcow2"
    shutil.copyfile(tmp_path / "disk.qcow2", outside)
    subprocess.run(["qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", str(outside), str(snap)], check=True, capture_output=True)
    result = storage.integrity(entry)
    assert result["state"] == "issues"
    assert result["images"][1]["state"] == "invalid-backing"


def test_public_cli_integrity_and_inventory_are_read_only(tmp_path):
    home = tmp_path / "home"
    state = tmp_path / "state"
    op = "op-cli-test"
    operation = state / "phasezero/operations" / op
    vm = state / "phasezero/windows-vm/vms" / op
    vm.mkdir(parents=True)
    operation.mkdir(parents=True)
    (operation / "operation.json").write_text(json.dumps({"id": op, "state": "completed"}))
    (operation / "plan.json").write_text('{"imageIndex":1}')
    (operation / "vm_dir").write_text(str(vm))
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               XDG_DATA_HOME=str(home / ".local/share"), XDG_CACHE_HOME=str(home / ".cache"),
               XDG_STATE_HOME=str(state), PZ_STATE=str(state / "phasezero"))
    before = {p: p.read_bytes() for p in operation.iterdir()}
    call = subprocess.run([str(ROOT / "linux/pz"), "windows-vm", "provision", "inventory", "--json"],
                          capture_output=True, text=True, env=env, check=True)
    assert json.loads(call.stdout)["instances"][0]["integrity"]["state"] == "not-checked"
    call = subprocess.run([str(ROOT / "linux/pz"), "windows-vm", "provision", "integrity", "--operation-id", op, "--json"],
                          capture_output=True, text=True, env=env, check=True)
    observed = json.loads(call.stdout)
    assert observed["state"] in {"issues", "unavailable", "busy"}
    assert not observed["bootVerified"]
    assert before == {p: p.read_bytes() for p in operation.iterdir()}


def test_probe_timeout_reclaims_its_own_child_processes(tmp_path):
    marker = tmp_path / "child-pid"
    child = ("import signal,time,sys,pathlib,os; "
             "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
             "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(30)")
    code = ("import subprocess,sys,time; "
            "subprocess.Popen([sys.executable,'-c',sys.argv[2],sys.argv[1]],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); time.sleep(30)")
    with pytest.raises(subprocess.TimeoutExpired):
        storage.run([sys.executable, "-c", code, str(marker), child], timeout=1)
    pid = int(marker.read_text())
    status = Path(f"/proc/{pid}/status")
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            if "State:\tZ" in status.read_text():
                return
        except (FileNotFoundError, ProcessLookupError):
            return
        time.sleep(0.01)
    pytest.fail("probe child outlived timeout cleanup")
