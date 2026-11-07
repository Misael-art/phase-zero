import importlib.util
import gzip
import json
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stability", ROOT / "linux/repairs/stability.py")
stability = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stability)


@pytest.fixture
def host(tmp_path):
    vendor = tmp_path / stability.VENDOR
    vendor.parent.mkdir(parents=True)
    vendor.write_text("[Unit]\nConditionUser=!root\n[Service]\nExecStart=icc_profile_apply enable\n")
    return tmp_path


class Journal:
    def __init__(self, root):
        self.root = root
        self.calls = []
        self.failure = None
        self.base = "[Journal]\nStorage=persistent\nSystemMaxUse=50M\nSyncIntervalSec=5m\n"

    def __call__(self, command, **kwargs):
        self.calls.append(command)
        if command == stability.JOURNAL_COMMAND:
            if isinstance(self.failure, Exception):
                raise self.failure
            return subprocess.CompletedProcess(command, self.failure or 0, "", "")
        assert command == ["systemd-analyze", "cat-config", "systemd/journald.conf"]
        text = self.base
        for name, content in stability.DROPINS.items():
            if "journald.conf.d" in name and (self.root / name).exists():
                text += content
        return subprocess.CompletedProcess(command, 0, text, "")


def test_status_missing_data_is_unknown_and_never_elevates(host):
    runner = Journal(host)
    before = list(host.rglob("*"))
    result = stability.status(host, runner)
    assert result["pstore"]["backend"]["state"] == "unknown"
    assert result["kernel"]["diagnosticDisablers"] is None
    assert result["stabilityProven"] is False
    assert list(host.rglob("*")) == before
    assert all(call[0] == "systemd-analyze" for call in runner.calls)


def test_plan_shows_exact_scope_and_pending_kernel_gates(host):
    result = stability.plan(host, Journal(host))
    assert len(result["changes"]) == 2
    assert result["changes"][0]["content"].endswith("ConditionUser=!sddm\n")
    assert "SystemMaxUse=150M" in result["changes"][1]["content"]
    assert any("Kernel capture is not enabled" in gate for gate in result["captureGates"])
    assert not (host / stability.STATE).exists()


def test_status_distinguishes_disabled_console_from_missing_kernel_config(host):
    (host / "proc").mkdir()
    with gzip.open(host / "proc/config.gz", "wt") as stream:
        stream.write("# unrelated config\n" * 9000)
        stream.write("# CONFIG_PSTORE_CONSOLE is not set\n")
    assert stability.status(host, Journal(host))["kernel"]["config"]["CONFIG_PSTORE_CONSOLE"] == "n"


def test_invalid_receipt_cannot_authorize_removal(host):
    receipt = host / stability.STATE
    receipt.parent.mkdir(parents=True)
    receipt.write_text("[]")
    path = host / next(iter(stability.DROPINS))
    path.parent.mkdir(parents=True)
    path.write_text("personal config")
    with pytest.raises(RuntimeError, match="Estado desconhecido"):
        stability.rollback(host, Journal(host))
    assert path.read_text() == "personal config"


def test_apply_then_idempotence_then_rollback_preserves_original(host):
    runner = Journal(host)
    original = host / "etc/systemd/journald.conf"
    original.parent.mkdir(parents=True)
    original.write_text(runner.base)
    assert stability.apply(host, runner)["state"] == "active"
    assert json.loads((host / stability.STATE).read_text())["previous"] == "absent"
    for name, content in stability.DROPINS.items():
        assert (host / name).read_text() == content
    assert stability.apply(host, runner)["changed"] is False
    assert runner.calls.count(stability.JOURNAL_COMMAND) == 1
    assert stability.rollback(host, runner)["state"] == "rolled-back"
    assert all(not (host / name).exists() for name in stability.DROPINS)
    assert original.read_text() == runner.base
    assert runner.calls.count(stability.JOURNAL_COMMAND) == 2
    assert stability.rollback(host, runner)["changed"] is False
    assert stability.apply(host, runner)["state"] == "active"


@pytest.mark.parametrize("index", [0, 1])
def test_apply_refuses_existing_unowned_file_even_if_content_matches(host, index):
    name, content = list(stability.DROPINS.items())[index]
    path = host / name
    path.parent.mkdir(parents=True)
    path.write_text(content)
    with pytest.raises(RuntimeError, match="preexistente"):
        stability.apply(host, Journal(host))
    assert path.read_text() == content
    assert not (host / stability.STATE).exists()


def test_changed_dropin_blocks_entire_rollback_before_any_removal(host):
    runner = Journal(host)
    stability.apply(host, runner)
    names = list(stability.DROPINS)
    modified = host / names[1]
    modified.write_text("personal change\n")
    with pytest.raises(RuntimeError, match="mudou"):
        stability.rollback(host, runner)
    assert (host / names[0]).exists()
    assert modified.read_text() == "personal change\n"
    assert runner.calls.count(stability.JOURNAL_COMMAND) == 1


def test_symlink_parent_refuses_write_outside_owned_tree(host, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    parent = host / "etc/systemd/user"
    parent.parent.mkdir(parents=True)
    parent.symlink_to(outside, target_is_directory=True)
    with pytest.raises(RuntimeError, match="inseguro"):
        stability.apply(host, Journal(host))
    assert list(outside.iterdir()) == []


@pytest.mark.parametrize("failure", [1, subprocess.TimeoutExpired("systemctl", 30)])
def test_failed_activation_stays_uncertain_and_cannot_retry_blindly(host, failure):
    runner = Journal(host)
    runner.failure = failure
    result = stability.apply(host, runner)
    assert result["ok"] is False
    assert result["state"] == "activation-unknown"
    assert all((host / p).exists() for p in stability.DROPINS)
    with pytest.raises(RuntimeError, match="incompleta"):
        stability.apply(host, runner)
    assert runner.calls.count(stability.JOURNAL_COMMAND) == 1
    runner.failure = None
    assert stability.rollback(host, runner)["ok"]


def test_partial_write_has_receipt_and_allows_explicit_rollback(host, monkeypatch):
    runner = Journal(host)
    atomic = stability.atomic
    second = list(stability.DROPINS)[1]

    def interrupted(root, path, *args, **kwargs):
        if path == host / second:
            raise OSError("simulated disk failure")
        return atomic(root, path, *args, **kwargs)

    monkeypatch.setattr(stability, "atomic", interrupted)
    with pytest.raises(OSError):
        stability.apply(host, runner)
    assert json.loads((host / stability.STATE).read_text())["phase"] == "prepared"
    monkeypatch.setattr(stability, "atomic", atomic)
    with pytest.raises(RuntimeError, match="incompleta"):
        stability.apply(host, runner)
    assert stability.rollback(host, runner)["ok"]
    assert all(not (host / p).exists() for p in stability.DROPINS)


@pytest.mark.parametrize("base", [
    "[Journal]\nSystemMaxUse=400M\nSyncIntervalSec=5m\n",
    "[Journal]\nSystemMaxUse=50M\nSyncIntervalSec=10s\n",
    "[Journal]\n",
])
def test_never_reduces_existing_retention_or_sync_guarantees(host, base):
    runner = Journal(host)
    runner.base = base
    with pytest.raises(RuntimeError, match="mais fortes"):
        stability.apply(host, runner)
    assert all(not (host / p).exists() for p in stability.DROPINS)


def test_rollback_without_ownership_receipt_preserves_files(host):
    path = host / next(iter(stability.DROPINS))
    path.parent.mkdir(parents=True)
    path.write_text("personal config")
    with pytest.raises(RuntimeError, match="Sem recibo"):
        stability.rollback(host, Journal(host))
    assert path.read_text() == "personal config"


def test_effective_override_mismatch_does_not_restart_journal(host):
    runner = Journal(host)

    def overridden(command, **kwargs):
        result = runner(command, **kwargs)
        if command[0] == "systemd-analyze" and (host / next(iter(stability.DROPINS))).exists():
            result.stdout += "[Journal]\nSystemMaxUse=50M\n"
        return result

    with pytest.raises(RuntimeError, match="prevalece"):
        stability.apply(host, overridden)
    assert stability.JOURNAL_COMMAND not in runner.calls
    assert json.loads((host / stability.STATE).read_text())["phase"] == "configuration-blocked"


def test_effect_without_confirmation_never_invokes_bridge(monkeypatch):
    monkeypatch.setattr(stability.shutil, "which", lambda *_: pytest.fail("unexpected elevation"))
    assert stability.main(["apply"]) == 2
    assert stability.main(["rollback"]) == 2


def test_legacy_manager_routes_stability_status_through_existing_entrypoint():
    result = subprocess.run(["bash", str(ROOT / "linux/pz"), "repair", "stability", "status"],
                            text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["mode"] == "read-only"
