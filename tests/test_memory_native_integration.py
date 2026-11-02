"""Opt-in real native/companion/crypto test. No production service is stopped.

Set PZ_MEMORY_TEST_NATIVE and PZ_MEMORY_TEST_WIKISYNC to audited binaries.
Linux restore uses a private PID namespace because upstream refuses *any*
other ai-memory process, including unrelated data directories.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import time
from urllib.request import urlopen

import pytest

from linux.ai import memory_manager as memory

NATIVE = os.environ.get("PZ_MEMORY_TEST_NATIVE")
COMPANION = os.environ.get("PZ_MEMORY_TEST_WIKISYNC")
pytestmark = pytest.mark.skipif(not NATIVE or not COMPANION, reason="requires explicitly selected native test binaries")


class Vault:
    def __init__(self):
        self.values = {}

    def lookup(self, ref):
        return self.values.get(ref)

    def store(self, ref, value):
        self.values[ref] = value


@contextmanager
def server(directory):
    directory.mkdir()
    data = directory / "data"
    config = directory / "config.toml"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    origin = f"http://127.0.0.1:{port}"
    config.write_text(f'data_dir = "{data}"\nbind = "127.0.0.1:{port}"\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith("AI_MEMORY_")}
    env.update(HOME=str(directory), XDG_CONFIG_HOME=str(directory / ".config"),
               XDG_DATA_HOME=str(directory / ".local/share"), XDG_STATE_HOME=str(directory / ".local/state"),
               AI_MEMORY_DATA_DIR=str(data), AI_MEMORY_CONFIG=str(config), AI_MEMORY_SERVER_URL=origin,
               AI_MEMORY_BIN=NATIVE, AI_MEMORY_WIKISYNC_BIN=COMPANION,
               GNUPGHOME=str(directory / ".gnupg"))
    (directory / ".gnupg").mkdir(mode=0o700)
    prefix = [NATIVE, "--data-dir", str(data), "--config", str(config)]
    subprocess.run([*prefix, "init"], env=env, check=True, capture_output=True)
    token = data / "auth-tokens/default"
    if token.exists():
        env["AI_MEMORY_AUTH_TOKEN"] = token.read_text().strip()
    log = (directory / "server.log").open("wb")
    process = subprocess.Popen([*prefix, "serve", "--transport", "http", "--enable-api", "--no-watcher"],
                               env=env, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if process.poll() is not None:
                pytest.fail("isolated native server exited; inspect fixture server.log")
            try:
                with urlopen(origin + "/healthz", timeout=.2) as response:
                    if response.status == 200:
                        break
            except Exception:
                time.sleep(.1)
        else:
            pytest.fail("isolated server readiness timed out")
        yield env, prefix, process
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        log.close()
        subprocess.run(["gpgconf", "--kill", "gpg-agent"], env=env, capture_output=True)


def test_two_hosts_conditional_sync_conflict_and_native_restore(tmp_path, monkeypatch):
    with server(tmp_path / "a") as (env_a, prefix_a, _), server(tmp_path / "b") as (env_b, prefix_b, _):
        def select(env):
            for key in list(os.environ):
                if key.startswith("AI_MEMORY_"):
                    monkeypatch.delenv(key, raising=False)
            for key, value in env.items():
                monkeypatch.setenv(key, value)

        def write(prefix, env, path, body):
            subprocess.run([*prefix, "write-page", "--workspace", "default", "--project", "shared",
                            "--path", path, "--body", "-"], input=body.encode(), env=env,
                           check=True, capture_output=True)

        def read(prefix, env, path):
            return subprocess.run([*prefix, "read-page", "--workspace", "default", "--project", "shared",
                                   "--path", path], env=env, check=True, capture_output=True).stdout.decode()

        original = "# Host A\n\nsource_host: original-a\nregistered_at: 2026-01-02T03:04:05Z\n"
        write(prefix_a, env_a, "decisions/a.md", original)
        write(prefix_b, env_b, "decisions/b.md", "# Host B\n\nIndependent knowledge.\n")
        select(env_a)
        a = memory.Manager(vault=Vault())
        a.initialize()
        select(env_b)
        b = memory.Manager(vault=Vault())
        b.initialize()
        b.vault.store(b.config["keyRef"], a.vault.lookup(a.config["keyRef"]))
        b.config["memoryId"] = a.config["memoryId"]
        b.save()
        scope = {"id": "a" * 64, "workspace": "default", "project": "shared", "families": ["decisions"]}
        a.config["scopes"] = [scope]
        b.config["scopes"] = [scope]
        select(env_a)
        out_a = tmp_path / "export-a"
        out_a.mkdir()
        blob_a, _, _ = a.export_knowledge(scope, out_a)
        select(env_b)
        b.import_knowledge(blob_a, scope, a.config["hostId"], tmp_path / "import-b")
        assert "original-a" in read(prefix_b, env_b, "decisions/a.md")
        assert "2026-01-02T03:04:05Z" in read(prefix_b, env_b, "decisions/a.md")
        before_versions = json.loads(b.native("status", "--json").stdout)["counts"]["pages_all"]
        b.import_knowledge(blob_a, scope, a.config["hostId"], tmp_path / "repeat-import-b")
        assert json.loads(b.native("status", "--json").stdout)["counts"]["pages_all"] == before_versions
        out_b = tmp_path / "export-b"
        out_b.mkdir()
        blob_b, _, _ = b.export_knowledge(scope, out_b)
        select(env_a)
        a.import_knowledge(blob_b, scope, b.config["hostId"], tmp_path / "import-a")
        assert "Independent knowledge" in read(prefix_a, env_a, "decisions/b.md")
        # Both hosts edit the same page after B's baseline was recorded.
        write(prefix_b, env_b, "decisions/a.md", "# Keep B's concurrent edit\n")
        write(prefix_a, env_a, "decisions/a.md", "# A's concurrent edit\n")
        out_a2 = tmp_path / "export-a2"
        out_a2.mkdir()
        blob_a2, _, _ = a.export_knowledge(scope, out_a2)
        select(env_b)
        with pytest.raises(memory.MemoryError, match="conflict"):
            b.import_knowledge(blob_a2, scope, a.config["hostId"], tmp_path / "conflict-b")
        assert "Keep B's concurrent edit" in read(prefix_b, env_b, "decisions/a.md")
        # Full online snapshot and authenticated envelope, using the real CLI.
        stage = tmp_path / "full-snapshot"
        stage.mkdir()
        full, _ = b.snapshot("backup", stage)
        verified, _ = b.verify(full, tmp_path / "full-verified")
        restored = tmp_path / "restored-data"
        restored.mkdir()
        restored_config = tmp_path / "restored-config.toml"
        restored_config.write_text(f'data_dir = "{restored}"\n')
        # Namespace contains no sibling native processes and affects no host service.
        subprocess.run(["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc",
                        NATIVE, "--data-dir", str(restored), "--config", str(restored_config),
                        "restore", "--from", str(verified / "payload/native.tar.gz"), "--force"],
                       env={**env_b, "AI_MEMORY_DATA_DIR": str(restored)}, check=True, capture_output=True, timeout=90)
        with sqlite3.connect(f"file:{restored}/db/memory.sqlite?mode=ro", uri=True) as connection:
            assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            assert connection.execute("SELECT COUNT(*) FROM pages").fetchone()[0] >= 2
        # An empty host may explicitly prepare the selected project through API.
        created = b.add_scope("new-on-this-host", "default", str(memory.ROOT), "decisions,notes", create_project=True)
        assert created["scopeId"]
        assert b.config["scopes"][-1]["projectId"]
