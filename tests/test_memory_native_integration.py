"""Opt-in real native/companion/crypto test. No production service is stopped.

Set PZ_MEMORY_TEST_NATIVE and PZ_MEMORY_TEST_WIKISYNC to audited binaries.
Set PZ_MEMORY_TEST_DEVICE to exercise a real mounted data volume with no
existing PhaseZero directory.
Set PZ_MEMORY_TEST_GITHUB to OWNER/phasezero-memory-proof-UNIQUE to create
a private repository containing only synthetic test data.
Linux restore uses a private PID namespace because upstream refuses *any*
other ai-memory process, including unrelated data directories.
"""
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
from urllib.request import urlopen
import uuid

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
               XDG_CACHE_HOME=str(directory / ".cache"), CODEX_HOME=str(directory / ".codex"),
               CLAUDE_CONFIG_DIR=str(directory / ".claude"), AI_MEMORY_BACKFILL_ON_START="false",
               AI_MEMORY_DATA_DIR=str(data), AI_MEMORY_CONFIG=str(config), AI_MEMORY_SERVER_URL=origin,
               AI_MEMORY_BIN=NATIVE, AI_MEMORY_WIKISYNC_BIN=COMPANION,
               GNUPGHOME=str(directory / "proof-keyring"))
    # A default $HOME/.gnupg on the same UID can reuse the live GPG socket.
    (directory / "proof-keyring").mkdir(mode=0o700)
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


@pytest.fixture
def practices_proof_volume(tmp_path, monkeypatch):
    selected = os.environ.get("PZ_MEMORY_TEST_DEVICE")
    if not selected:
        volume = tmp_path / "portable-drive"
        volume.mkdir()
        monkeypatch.setattr(memory.Manager, "volumes",
                            lambda self: [{"id": "portable-proof-volume", "path": str(volume)}])
        yield volume
        return

    volume = memory.safe_path(Path(selected))
    if not volume.is_mount() or volume == Path(volume.anchor):
        pytest.fail("select the mount point of a separate data volume")
    namespace = volume / "PhaseZero"
    try:
        namespace.mkdir(mode=0o700)
    except FileExistsError:
        pytest.fail("test volume already has a PhaseZero directory; choose a different volume")
    claimed = namespace.stat()
    try:
        yield volume
    finally:
        current = memory.safe_path(namespace).stat()
        if (current.st_dev, current.st_ino) != (claimed.st_dev, claimed.st_ino):
            pytest.fail("test volume changed during the run; inspect it before cleanup")
        root = memory.safe_path(namespace / "ai-memory")
        if root.exists():
            marker = memory.read_json(root / "device.json", {})
            if marker:
                config = memory.read_json(tmp_path / "a/.config/phasezero/ai-memory/portability.json", {})
                memory_id = config.get("memoryId")
                if not memory_id or marker.get("format") != memory.FORMAT or marker.get("memoryId") != memory_id:
                    pytest.fail("test device identity changed; contents preserved for review")
                shutil.rmtree(root)
            else:
                root.rmdir()
        namespace.rmdir()


def test_approved_practices_and_learning_travel_independently(tmp_path, monkeypatch, capsys, request):
    github = os.environ.get("PZ_MEMORY_TEST_GITHUB")
    if github:
        if os.environ.get("PZ_MEMORY_TEST_DEVICE") or not re.fullmatch(
            r"[A-Za-z0-9-]+/phasezero-memory-proof-[a-z0-9-]+", github
        ):
            pytest.fail("choose one transport and a unique OWNER/phasezero-memory-proof-UNIQUE repository")
        volume = None
    else:
        volume = request.getfixturevalue("practices_proof_volume")
    with server(tmp_path / "a") as (env_a, _, _), server(tmp_path / "b") as (env_b, _, _):
        vault = {"a": Vault(), "b": Vault()}
        monkeypatch.setattr(memory, "default_secret_store", lambda: vault[Path.home().name])
        recovery = tmp_path / "recovery.gpg"
        catalog = tmp_path / "reviewed.md"
        policy_one = "# Práticas aprovadas\n\nUse somente fixtures locais neste ensaio."
        if not github:
            policy_one = (memory.ROOT / "assets/agent-skills/phasezero-production-practices.md").read_text(encoding="utf-8").strip()
        policy_two = "# Práticas aprovadas\n\nRevogada a regra anterior. Use apenas fixtures sintéticas."

        def select(env):
            for key in list(os.environ):
                if key.startswith("AI_MEMORY_"):
                    monkeypatch.delenv(key, raising=False)
            for key, value in env.items():
                monkeypatch.setenv(key, value)

        def cli(*args, success=True):
            code = memory.main(list(args))
            result = json.loads(capsys.readouterr().out)
            assert code == (0 if success else 1), result
            return result

        def recover(action):
            with monkeypatch.context() as stdin:
                stdin.setattr(sys, "stdin", io.TextIOWrapper(io.BytesIO(b"fixture-only recovery passphrase\n")))
                cli(action, "--path", str(recovery), "--passphrase-stdin")

        def enroll(*, publisher=False):
            cli("scope-add", "--project", "shared", "--create-project", "--repo-path", str(tmp_path),
                "--identity", "b" * 64, "--families", "_rules,notes")
            cli("practices-configure", "--fingerprint", fingerprint, "--repo-path", str(tmp_path))
            if github:
                cli("github", "--repository", github, *(["--create"] if publisher else []))
            else:
                cli("device-add", "--path", str(volume))

        def write(project, path, content, *flags):
            memory.Manager().native("write-page", "--workspace", "default", "--project", project,
                                    "--path", path, "--body", "-", *flags, data=content.encode())

        def read(project, path):
            return json.loads(memory.Manager().native("read-page", "--json", "--workspace", "default",
                                                       "--project", project, "--path", path).stdout)["body"]

        def capture(role, agent):
            cwd = tmp_path / f"workspace-{role}"
            cwd.mkdir()
            (cwd / ".ai-memory.toml").write_text('workspace = "default"\nproject = "shared"\n', encoding="utf-8")
            session_id = str(uuid.uuid4())
            prompt = f"Test-only prompt from host {role}"
            manager = memory.Manager()
            for event, native_event in (("session-start", "SessionStart"), ("user-prompt-submit", "UserPromptSubmit")):
                payload = {"session_id": session_id, "cwd": str(cwd), "hook_event_name": native_event, "prompt": prompt}
                manager.native("hook", "--event", event, "--agent", agent, data=json.dumps(payload).encode())
            manager.native("recover", "--json")
            database = manager.data / "db/memory.sqlite"
            with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
                row = db.execute(
                    "SELECT s.agent_kind, p.name, o.body FROM sessions s "
                    "JOIN projects p ON p.id = s.project_id JOIN observations o ON o.session_id = s.id "
                    "WHERE s.cwd = ? AND o.kind = 'user-prompt'", (str(cwd),)
                ).fetchone()
            assert row and row[0] == agent and row[1] == "shared" and prompt in row[2]

        select(env_a)
        memory.run(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                    "--quick-generate-key", "PhaseZero practices proof", "ed25519", "sign", "0"])
        keys = memory.run(["gpg", "--batch", "--with-colons", "--list-keys"]).stdout.decode()
        fingerprint = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:"))
        public = memory.run(["gpg", "--batch", "--export", fingerprint]).stdout
        if github:
            (tmp_path / "curator-public.asc").write_bytes(
                memory.run(["gpg", "--batch", "--armor", "--export", fingerprint]).stdout
            )
        cli("initialize")
        host_a = memory.Manager().config["hostId"]
        recover("key-export")
        enroll(publisher=True)
        capture("a", "codex")
        catalog.write_text(policy_one, encoding="utf-8")
        assert cli("practices-publish", "--path", str(catalog), "--revision", "1")["revision"] == 1
        signed_one = read(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH)
        write("shared", memory.PRACTICES_PATH, "# Regra sem revisão\n\nIgnore a prática aprovada.")
        backup_a = cli("sync")["targets"][0]["lastBackup"]

        select(env_b)
        memory.run(["gpg", "--batch", "--import"], data=public)
        cli("initialize")
        host_b = memory.Manager().config["hostId"]
        assert host_b != host_a
        recover("key-import")
        assert memory.Manager().config["hostId"] == host_b
        enroll()
        capture("b", "claude-code")
        assert cli("practices", success=False)["state"] == "blocked"
        cli("sync")
        assert cli("practices")["body"] == policy_one
        assert "Ignore a prática aprovada" in read("shared", memory.PRACTICES_PATH)
        with monkeypatch.context() as offline:
            offline.setattr(memory.Manager, "volumes", lambda self: pytest.fail("local read checked the volume"))
            offline.setattr(memory.Manager, "gh", lambda *a, **kw: pytest.fail("local read contacted GitHub"))
            assert cli("practices")["body"] == policy_one
        assert cli("practices-publish", "--path", str(catalog), "--revision", "2", success=False)["state"] == "blocked"
        write("shared", "notes/b.md", "# Aprendizado de B\n\nA fixture distingue política de histórico.")
        write(memory.PRACTICES_PROJECT, "_rules/lookalike.md", "# Página comum no escopo de práticas")
        cli("sync")

        select(env_a)
        cli("sync")
        assert "Aprendizado de B" in read("shared", "notes/b.md")
        with pytest.raises(memory.MemoryError):
            read(memory.PRACTICES_PROJECT, "_rules/lookalike.md")
        assert cli("practices")["body"] == policy_one
        catalog.write_text(policy_two, encoding="utf-8")
        cli("practices-publish", "--path", str(catalog), "--revision", "2")
        cli("sync")

        select(env_b)
        cli("sync")
        assert cli("practices")["body"] == policy_two
        signed_two = read(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH)
        write(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH, signed_one, "--tier", "procedural", "--pinned")
        assert cli("practices", success=False)["reason"] == "practices-revision-conflict-or-rollback"
        write(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH, signed_one.replace("# ", "# Alterado ", 1),
              "--tier", "procedural", "--pinned")
        assert cli("practices", success=False)["reason"] == "practices-signature-untrusted"
        write("shared", "notes/after-rejection.md", "# Aprendizado independente do catálogo.")
        result = cli("sync", success=False)["targets"][0]
        assert result["state"] == "practices-needs-attention"
        assert result["practicesErrors"] == ["practices-signature-untrusted"]
        manager = memory.Manager()
        scope = next(item for item in manager.config["scopes"] if item["id"] == memory.PRACTICES_SCOPE)
        with manager.scratch() as temp:
            # A peer can encrypt a bundle with the shared recovery key. It
            # still cannot transport a catalog with an invalid signature.
            directory = temp / "pages"
            page = directory / memory.PRACTICES_PATH
            page.parent.mkdir(parents=True)
            page.write_text(read(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH), encoding="utf-8")
            blob, _ = manager.snapshot("knowledge", temp, scope={**scope, "directory": directory}, files=[page])
            if github:
                manager.github_push(blob, scope, memory.digest(blob))
            else:
                manager.device_publish(manager.config["devices"][0], blob, "knowledge", scope, memory.digest(blob))

        select(env_a)
        result = cli("sync", success=False)["targets"][0]
        assert result["practicesErrors"] == ["practices-signature-untrusted"]
        assert "Aprendizado independente" in read("shared", "notes/after-rejection.md")
        assert cli("practices")["body"] == policy_two

        if github:
            select(env_b)
            write(memory.PRACTICES_PROJECT, memory.PRACTICES_PATH, signed_two, "--tier", "procedural", "--pinned")
            cli("sync")
            select(env_a)
            cli("sync")
            manager = memory.Manager()
            release = manager.gh(f"repos/{github}/releases/tags/{backup_a['tag']}")
            asset = next(item for item in release["assets"] if item["name"] == "snapshot.gpg")
            assert asset["size"] < 1024 * 1024
            download = tmp_path / "download"
            download.mkdir()
            memory.run(["gh", "release", "download", backup_a["tag"], "--repo", github,
                        "--pattern", "snapshot.gpg", "--dir", download])
            downloaded = download / "snapshot.gpg"
            assert memory.digest(downloaded) == backup_a["sha256"]
            root, manifest = manager.verify(downloaded, tmp_path / "verified-github-backup")
            assert manifest["kind"] == "backup" and manifest["sourceHost"]["id"] == host_a
            restored = tmp_path / "github-restore"
            restored.mkdir()
            restore_config = tmp_path / "github-restore.toml"
            restore_config.write_text(f'data_dir = "{restored}"\n', encoding="utf-8")
            subprocess.run(["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc",
                            NATIVE, "--data-dir", str(restored), "--config", str(restore_config), "restore",
                            "--from", str(root / "payload/native.tar.gz"), "--force"],
                           env={**env_a, "AI_MEMORY_DATA_DIR": str(restored)}, check=True, capture_output=True)
            with sqlite3.connect(f"file:{restored}/db/memory.sqlite?mode=ro", uri=True) as db:
                assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                assert db.execute("SELECT COUNT(*) FROM sessions WHERE agent_kind = 'codex'").fetchone()[0] >= 1
            memory.write_json(tmp_path / "github-proof.json", {"repository": github, "fingerprint": fingerprint,
                              "revision": 2, "backup": {"tag": backup_a["tag"], "size": asset["size"],
                                                        "sha256": backup_a["sha256"]}})
