"""Exercise the real shell installer using an offline release and fake service."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("migration_fails,rollback_fails", [(False, False), (True, False), (True, True)])
def test_native_upgrade_preserves_snapshot_and_recovers_failed_migration(tmp_path, migration_fails, rollback_fails):
    home = tmp_path / "home"
    binaries = home / ".local/bin"
    binaries.mkdir(parents=True)
    calls = tmp_path / "calls"
    active = tmp_path / "service-active"
    active.touch()
    old = binaries / "ai-memory"
    old.write_text('#!/bin/bash\ncase "$*" in *--version*) echo "ai-memory 1.31.1";; *backup*) printf before > "${@: -1}";; esac\n')
    old.chmod(0o755)
    service = binaries / "systemctl"
    service.write_text('''#!/bin/bash
printf '%s\n' "$*" >> "$PZ_FIXTURE_CALLS"
case "$*" in
  *show-environment*) printf 'HOME=%s\n' "$HOME" ;;
  *is-active*) test -f "$PZ_FIXTURE_ACTIVE" ;;
  *stop*) rm -f "$PZ_FIXTURE_ACTIVE" ;;
  *start*) touch "$PZ_FIXTURE_ACTIVE" ;;
esac
''')
    service.chmod(0o755)
    payload = tmp_path / "payload"
    payload.mkdir()
    candidate = payload / "ai-memory"
    candidate.write_text('''#!/bin/bash
case "$*" in
  *--version*) echo 'ai-memory 3.3.1';;
  *init*) [ "${PZ_FIXTURE_MIGRATION_FAIL:-0}" != 1 ]; exit $?;;
  *restore*) echo restore >> "$PZ_FIXTURE_CALLS"; [ "${PZ_FIXTURE_ROLLBACK_FAIL:-0}" != 1 ]; exit $?;;
esac
''')
    candidate.chmod(0o755)
    archive = tmp_path / "native.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(candidate, arcname="ai-memory")
    env = os.environ.copy()
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_DATA_HOME=str(home / ".local/share"),
               XDG_STATE_HOME=str(home / ".local/state"), AI_MEMORY_DATA_DIR=str(home / "memory"),
               PZ_LOCAL_BIN=str(binaries), AI_MEMORY_RELEASE_ARCHIVE=str(archive),
               AI_MEMORY_SHA256_X86_64=hashlib.sha256(archive.read_bytes()).hexdigest(),
               PATH=str(binaries) + os.pathsep + os.environ["PATH"], PZ_FIXTURE_CALLS=str(calls),
               PZ_FIXTURE_ACTIVE=str(active), PZ_FIXTURE_MIGRATION_FAIL="1" if migration_fails else "0",
               PZ_FIXTURE_ROLLBACK_FAIL="1" if rollback_fails else "0",
               TMPDIR=str(tmp_path))
    result = subprocess.run(["bash", str(ROOT / "linux/ai/setup-memory.sh"), "install"],
                            env=env, capture_output=True, timeout=30)
    assert result.returncode == (1 if migration_fails else 0), result.stderr.decode()
    if rollback_fails:
        required = home / ".local/state/phasezero/ai/ai-memory-recovery-required.json"
        assert required.is_file()
        assert not active.exists()
        retried = subprocess.run(["bash", str(ROOT / "linux/ai/setup-memory.sh"), "install"], env=env,
                                 capture_output=True, timeout=30)
        assert retried.returncode == 1
        assert b"recovery required" in retried.stderr
        assert not active.exists()
        return
    version = subprocess.run([str(old), "--version"], env=env, capture_output=True, check=True).stdout
    assert (b"1.31.1" if migration_fails else b"3.3.1") in version
    assert active.exists()
    snapshots = list((home / ".local/state/phasezero/ai/memory-upgrades").glob("*/data-before.tar.gz"))
    assert len(snapshots) == 1
    assert snapshots[0].read_text() == "before"
    if migration_fails:
        assert "restore" in calls.read_text()
        env["PZ_FIXTURE_MIGRATION_FAIL"] = "0"
        retried = subprocess.run(["bash", str(ROOT / "linux/ai/setup-memory.sh"), "install"], env=env,
                                 capture_output=True, timeout=30)
        assert retried.returncode == 0, retried.stderr.decode()
        assert active.exists()
        assert b"3.3.1" in subprocess.run([str(old), "--version"], env=env, capture_output=True).stdout
