#!/usr/bin/env python3
"""User-level lifecycle for the project-scoped ChatGPT MCP tunnel."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

try:
    from .chatgpt_project_mcp import Project, ProjectError
except ImportError:  # Executed directly by linux/pz or the installed package.
    from chatgpt_project_mcp import Project, ProjectError


VERSION = "v0.0.12"
ASSET = "tunnel-client-v0.0.12-linux-amd64.zip"
ASSET_URL = f"https://github.com/openai/tunnel-client/releases/download/{VERSION}/{ASSET}"
ASSET_SHA256 = "2bb693bd7b5cd28da7ce09cd9e309529dbb33b7cc9dc0058e62a064688f92c81"
BINARY_SHA256 = "ee9d4a75bc0b42f36f345aa96231e0db1ab00488122f34ebc99d6db055b6603e"
UNIT = "pz-chatgpt-project-mcp.service"
PROFILE = "pz-phasezero"
TUNNEL_ID = re.compile(r"tunnel_[0-9a-f]{32}")


class ManagerError(Exception):
    pass


def _digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _atomic(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        Path(name).unlink(missing_ok=True)


class Manager:
    def __init__(self, home: Path | None = None, runtime: Path | None = None) -> None:
        data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
        self.home = home or data / "phasezero/chatgpt-project-mcp"
        xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
        self.runtime = runtime or (Path(xdg_runtime) / "phasezero/chatgpt-project-mcp"
                                   if xdg_runtime else None)
        self.server = self.home / "chatgpt_project_mcp.py"
        self.manager = self.home / "chatgpt_project_mcp_manager.py"
        self.binary = self.home / "tunnel-client"
        self.config = self.home / "config.json"
        self.profile_dir = self.home / "profile"

    @staticmethod
    def _run(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)

    @staticmethod
    def _bridge() -> Any:
        sibling = Path(__file__).with_name("chatgpt_web_bridge.py")
        if not sibling.is_file():
            data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
            sibling = data / "phasezero/chatgpt-web/manager/chatgpt_web_bridge.py"
        spec = importlib.util.spec_from_file_location("pz_project_mcp_bridge", sibling)
        if spec is None or spec.loader is None:
            raise ManagerError("gerenciador ChatGPT Web ausente")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.Bridge()

    def _load(self) -> dict[str, Any]:
        if self.config.is_symlink():
            raise ManagerError("configuração por symlink recusada")
        try:
            data = json.loads(self.config.read_text())
        except (OSError, ValueError) as error:
            raise ManagerError("conector não instalado ou configuração inválida") from error
        if not isinstance(data, dict) or not TUNNEL_ID.fullmatch(str(data.get("tunnelId", ""))):
            raise ManagerError("identidade do túnel inválida")
        if (not isinstance(data.get("repo"), str) or not Path(data["repo"]).is_absolute()
                or not isinstance(data.get("serverSha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", data["serverSha256"])):
            raise ManagerError("configuração do projeto inválida")
        return data

    def _install_binary(self) -> None:
        if self.binary.is_file() and not self.binary.is_symlink() and _digest(self.binary) == BINARY_SHA256:
            return
        with tempfile.TemporaryDirectory(prefix="pz-project-mcp-") as work:
            asset = Path(work) / ASSET
            try:
                with urllib.request.urlopen(ASSET_URL, timeout=60) as response, asset.open("wb") as output:
                    copied = 0
                    while block := response.read(1024 * 1024):
                        copied += len(block)
                        if copied > 32 * 1024 * 1024:
                            raise ManagerError("pacote de túnel excede o limite")
                        output.write(block)
            except OSError as error:
                raise ManagerError("download do túnel falhou") from error
            if _digest(asset) != ASSET_SHA256:
                raise ManagerError("checksum do túnel não confere")
            with zipfile.ZipFile(asset) as archive:
                info = archive.getinfo("tunnel-client")
                if info.file_size > 25 * 1024 * 1024:
                    raise ManagerError("binário do túnel excede o limite")
                binary = archive.read(info)
            if hashlib.sha256(binary).hexdigest() != BINARY_SHA256:
                raise ManagerError("binário do túnel não confere")
            _atomic(self.binary, binary, 0o700)

    def install(self, repo: str, tunnel_id: str) -> dict[str, Any]:
        if sys.platform != "linux" or platform.machine() not in {"x86_64", "amd64"}:
            raise ManagerError("cliente de túnel fixado apenas para Linux x86_64")
        if not TUNNEL_ID.fullmatch(tunnel_id):
            raise ManagerError("tunnel_id inválido")
        root = Project(repo).root
        if self._active():
            raise ManagerError("pare o túnel antes de instalar ou atualizar")
        if self.config.exists():
            current = self._load()
            if current["repo"] != str(root) or current["tunnelId"] != tunnel_id:
                raise ManagerError("outro repositório/túnel já instalado; desative e remova antes")
        for path in (self.home, self.profile_dir):
            if path.is_symlink():
                raise ManagerError("diretório por symlink recusado")
            path.mkdir(parents=True, exist_ok=True)
            path.chmod(0o700)
        self._install_binary()
        source = Path(__file__).with_name("chatgpt_project_mcp.py")
        _atomic(self.server, source.read_bytes())
        _atomic(self.manager, Path(__file__).read_bytes())
        _atomic(self.config, json.dumps({"repo": str(root), "tunnelId": tunnel_id,
                                         "serverSha256": _digest(self.server)},
                                        ensure_ascii=False).encode())
        return {"installed": True, "repo": str(root), "tunnelClient": VERSION,
                "ready": False, "next": "start"}

    def _key(self) -> Path:
        if self.runtime is None:
            raise ManagerError("XDG_RUNTIME_DIR indisponível")
        if self.runtime.is_symlink():
            raise ManagerError("runtime por symlink recusado")
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.runtime.chmod(0o700)
        if self.runtime.stat().st_uid != os.getuid():
            raise ManagerError("runtime não pertence ao usuário atual")
        bridge = self._bridge()
        state = bridge.load_state()
        record = state.get("runtimeKey") or {}
        if bridge.key_status(state).get("state") != "stored":
            raise ManagerError("chave de túnel ausente ou vencida no cofre")
        secret = bridge.secret_store().lookup(record["ref"])
        if not secret:
            raise ManagerError("chave não encontrada no cofre")
        path = self.runtime / "runtime-key"
        _atomic(path, secret.encode())
        return path

    def start(self) -> dict[str, Any]:
        data = self._load()
        if self._active():
            return self.status()
        if self.binary.is_symlink() or not self.binary.is_file() or _digest(self.binary) != BINARY_SHA256:
            raise ManagerError("binário ausente ou alterado; reinstale")
        if self.server.is_symlink() or not self.server.is_file() or _digest(self.server) != data.get("serverSha256"):
            raise ManagerError("servidor ausente ou alterado; reinstale")
        Project(data["repo"])
        key = self._key()
        proof = self.runtime / "proof.json"
        proof.unlink(missing_ok=True)
        command = shlex.join(["/usr/bin/python3", str(self.server), "--repo", data["repo"],
                              "--proof-file", str(proof)])
        init = self._run([str(self.binary), "init", "--profile", PROFILE,
                          "--profile-dir", str(self.profile_dir), "--tunnel-id", data["tunnelId"],
                          "--mcp-command", command, "--control-plane-api-key-ref",
                          "file:" + str(key), "--health-listen-addr", "127.0.0.1:0", "--force"], 30)
        if init.returncode:
            self.stop()
            raise ManagerError("perfil do túnel não foi criado")
        doctor = self._run([str(self.binary), "doctor", "--profile", PROFILE,
                            "--profile-dir", str(self.profile_dir)], 60)
        if doctor.returncode:
            self.stop()
            raise ManagerError("diagnóstico do túnel falhou")
        health = self.runtime / "health.url"
        health.unlink(missing_ok=True)
        run = self._run(["systemd-run", "--user", "--collect", "--quiet", "--unit=" + UNIT,
                         "--description=PhaseZero project-scoped ChatGPT MCP", "-p", "Restart=no",
                         "-p", "KillMode=mixed", "-p", "TimeoutStopSec=15",
                         str(self.binary), "run", "--profile", PROFILE,
                         "--profile-dir", str(self.profile_dir),
                         "--health.url-file", str(health)], 30)
        if run.returncode:
            self.stop()
            raise ManagerError("serviço do túnel não iniciou")
        for _ in range(30):
            if self.status()["tunnelReady"]:
                return self.status()
            time.sleep(0.5)
        self.stop()
        raise ManagerError("túnel não ficou pronto; chave temporária removida")

    @staticmethod
    def _active() -> bool:
        return Manager._run(["systemctl", "--user", "is-active", UNIT], 5).returncode == 0

    def status(self) -> dict[str, Any]:
        try:
            data = self._load()
        except ManagerError:
            return {"installed": False, "tunnelReady": False, "active": False}
        active = self._active()
        integrity = (self.binary.is_file() and not self.binary.is_symlink()
                     and _digest(self.binary) == BINARY_SHA256
                     and self.server.is_file() and not self.server.is_symlink()
                     and _digest(self.server) == data.get("serverSha256"))
        ready = False
        if active and self.runtime is not None:
            health = self.runtime / "health.url"
            if health.is_file():
                try:
                    import urllib.request
                    url = health.read_text().strip()
                    if re.fullmatch(r"http://127\.0\.0\.1:\d+", url):
                        with urllib.request.urlopen(url + "/readyz", timeout=2) as response:
                            ready = response.status == 200
                except (OSError, ValueError):
                    pass
        proven = False
        if ready and integrity and self.runtime is not None:
            proof = self.runtime / "proof.json"
            try:
                if (proof.is_file() and not proof.is_symlink()
                        and proof.stat().st_uid == os.getuid()
                        and not proof.stat().st_mode & 0o077):
                    flags = json.loads(proof.read_text(encoding="utf-8"))
                    proven = isinstance(flags, dict) and flags.get("read") is True \
                        and flags.get("write") is True
            except (OSError, UnicodeError, ValueError):
                pass
        return {"installed": True, "active": active, "tunnelReady": ready,
                "integrity": integrity,
                "repo": data["repo"], "toolCallProven": proven,
                "next": "No ChatGPT Plugins, conecte o túnel e faça uma chamada real de leitura "
                        "e escrita reversível." if ready and not proven else
                        "Leitura e escrita comprovadas nesta sessão." if proven else "start"}

    def stop(self) -> dict[str, Any]:
        self._run(["systemctl", "--user", "stop", UNIT], 30)
        if self.runtime is not None:
            key = self.runtime / "runtime-key"
            if key.is_file() and not key.is_symlink():
                with key.open("r+b") as stream:
                    stream.write(b"\0" * key.stat().st_size)
                    stream.flush()
                    os.fsync(stream.fileno())
            key.unlink(missing_ok=True)
            (self.runtime / "health.url").unlink(missing_ok=True)
            (self.runtime / "proof.json").unlink(missing_ok=True)
        return {"active": self._active(), "tunnelReady": False,
                "runtimeKeyStaged": False}

    def remove(self) -> dict[str, Any]:
        self.stop()
        if self._active():
            raise ManagerError("túnel ainda ativo; remoção recusada")
        for path in (self.profile_dir,):
            shutil.rmtree(path, ignore_errors=True)
        for path in (self.server, self.manager, self.binary, self.config):
            path.unlink(missing_ok=True)
        return {"installed": False, "repoPreserved": True,
                "externalTunnelPreserved": True, "externalPluginPreserved": True}


def main() -> int:
    parser = argparse.ArgumentParser(description="Ferramentas MCP privadas de um repositório")
    commands = parser.add_subparsers(dest="command", required=True)
    install = commands.add_parser("install")
    install.add_argument("--repo", required=True)
    install.add_argument("--tunnel-id", required=True)
    for name in ("start", "status", "stop", "remove"):
        commands.add_parser(name)
    args = parser.parse_args()
    manager = Manager()
    try:
        result = (manager.install(args.repo, args.tunnel_id) if args.command == "install" else
                  getattr(manager, args.command)())
    except (ManagerError, ProjectError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
