#!/usr/bin/env python3
"""Private, dependency-free MCP tools for one explicitly selected Git repository.

Transport: MCP stdio. The tunnel client owns network transport; this process
never opens a listener or accepts a shell command from a tool caller.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO


PROTOCOL = "2025-11-25"
MAX_MESSAGE = 1024 * 1024
MAX_FILE = 256 * 1024
MAX_LIST = 500
DENIED_PARTS = {".git", ".ssh", ".aws", ".gnupg", ".kube", "node_modules"}
DENIED_NAME = re.compile(
    r"(^\.env(?:\..*)?$|^\.netrc$|^auth\.json$|^credentials(?:\.(?:json|ya?ml))?$|"
    r"^id_(?:rsa|ed25519)$|\.(?:pem|p12|pfx|key)$)", re.I
)


class ProjectError(Exception):
    pass


def _json_text(value: dict[str, Any]) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}


def _read_limited(fd: int) -> bytes:
    chunks = bytearray()
    while len(chunks) <= MAX_FILE:
        block = os.read(fd, MAX_FILE + 1 - len(chunks))
        if not block:
            break
        chunks.extend(block)
    if len(chunks) > MAX_FILE:
        raise ProjectError("arquivo maior que 256 KiB")
    return bytes(chunks)


def _tool(name: str, description: str, properties: dict[str, Any], required: list[str],
          read_only: bool) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {"type": "object", "properties": properties,
                        "required": required, "additionalProperties": False},
        "annotations": {"readOnlyHint": read_only, "destructiveHint": not read_only,
                        "openWorldHint": False},
    }


TOOLS = [
    _tool("project_status", "Use to inspect the selected repository's branch and changed paths.",
          {}, [], True),
    _tool("project_list_files", "Use to list tracked files in the selected repository.",
          {"prefix": {"type": "string", "description": "Optional relative path prefix."}},
          [], True),
    _tool("project_read_file", "Use to read a UTF-8 project file. Common credential filenames are denied.",
          {"path": {"type": "string", "description": "Relative path inside selected repository."}},
          ["path"], True),
    _tool("project_write_file", "Use to replace one UTF-8 project file after checking its SHA-256, "
          "or create it when expectedSha256 is null. ChatGPT must confirm this write.",
          {"path": {"type": "string", "description": "Relative path inside selected repository."},
           "content": {"type": "string", "description": "Complete new UTF-8 content, max 256 KiB."},
           "expectedSha256": {"type": ["string", "null"],
                              "description": "Current SHA-256 from project_read_file, or null for a new file."}},
          ["path", "content", "expectedSha256"], False),
]


class Project:
    def __init__(self, repo: str) -> None:
        candidate = Path(repo).expanduser().resolve(strict=True)
        result = subprocess.run(
            ["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
             "-c", "core.hooksPath=/dev/null", "-C", str(candidate),
             "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if result.returncode != 0 or Path(result.stdout.strip()).resolve() != candidate:
            raise ProjectError("escolha a raiz canônica de um repositório Git")
        self.root = candidate

    @staticmethod
    def _parts(relative: str) -> tuple[str, ...]:
        if not isinstance(relative, str) or not relative or len(relative) > 512:
            raise ProjectError("caminho relativo inválido")
        if "\\" in relative or "\x00" in relative or any(ord(c) < 32 for c in relative):
            raise ProjectError("caminho relativo inválido")
        path = PurePosixPath(relative)
        parts = path.parts
        if path.is_absolute() or any(part in {"", ".", ".."} for part in relative.split("/")):
            raise ProjectError("caminho fora do projeto")
        if any(part in DENIED_PARTS or DENIED_NAME.search(part) for part in parts):
            raise ProjectError("arquivo privado não é exposto")
        return parts

    def _parent_fd(self, parts: tuple[str, ...]) -> int:
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            for part in parts[:-1]:
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                  os.O_CLOEXEC, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            return fd
        except BaseException:
            os.close(fd)
            raise

    def _read(self, parts: tuple[str, ...]) -> tuple[bytes, int]:
        parent = self._parent_fd(parts)
        try:
            fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                         dir_fd=parent)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE:
                    raise ProjectError("arquivo não regular ou maior que 256 KiB")
                data = _read_limited(fd)
                return data, stat.S_IMODE(info.st_mode)
            finally:
                os.close(fd)
        finally:
            os.close(parent)

    def status(self) -> dict[str, Any]:
        def git(*args: str) -> str:
            result = subprocess.run(
                ["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
                 "-c", "core.hooksPath=/dev/null", "-C", str(self.root), *args],
                capture_output=True, text=True, timeout=10, check=False,
                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_NOSYSTEM": "1"},
            )
            if result.returncode != 0:
                raise ProjectError("git não respondeu para este repositório")
            return result.stdout

        branch = git("branch", "--show-current").strip()
        changed = git("status", "--porcelain=v1", "--untracked-files=normal").splitlines()
        return {"root": str(self.root), "branch": branch,
                "changed": changed[:MAX_LIST], "truncated": len(changed) > MAX_LIST}

    def list_files(self, prefix: str = "") -> dict[str, Any]:
        parts = self._parts(prefix) if prefix else ()
        result = subprocess.run(
            ["git", "--no-optional-locks", "-c", "core.fsmonitor=false",
             "-c", "core.hooksPath=/dev/null", "-C", str(self.root), "ls-files", "-z"],
            capture_output=True, timeout=10, check=False,
        )
        if result.returncode != 0:
            raise ProjectError("git não respondeu para este repositório")
        files = []
        for raw in result.stdout.split(b"\0"):
            if not raw:
                continue
            name = raw.decode("utf-8", errors="replace")
            try:
                candidate = self._parts(name)
            except ProjectError:
                continue
            if parts and candidate[:len(parts)] != parts:
                continue
            files.append(name)
            if len(files) > MAX_LIST:
                break
        return {"files": files[:MAX_LIST], "truncated": len(files) > MAX_LIST}

    def read_file(self, path: str) -> dict[str, Any]:
        data, _ = self._read(self._parts(path))
        try:
            content = data.decode("utf-8")
        except UnicodeError:
            raise ProjectError("arquivo não é UTF-8") from None
        return {"path": path, "content": content,
                "sha256": hashlib.sha256(data).hexdigest()}

    def write_file(self, path: str, content: str, expected_sha256: str | None) -> dict[str, Any]:
        parts = self._parts(path)
        if not isinstance(content, str):
            raise ProjectError("conteúdo deve ser texto UTF-8")
        data = content.encode("utf-8")
        if len(data) > MAX_FILE:
            raise ProjectError("conteúdo maior que 256 KiB")
        if expected_sha256 is not None and (not isinstance(expected_sha256, str)
                                             or not re.fullmatch(r"[a-f0-9]{64}", expected_sha256)):
            raise ProjectError("SHA-256 esperado inválido")
        parent = self._parent_fd(parts)
        temp_name = ".pz-mcp-" + uuid.uuid4().hex
        try:
            try:
                current_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                     dir_fd=parent)
            except FileNotFoundError:
                current_fd = None
            if current_fd is None:
                if expected_sha256 is not None:
                    raise ProjectError("arquivo ausente; releia antes de gravar")
                mode = 0o644
            else:
                try:
                    info = os.fstat(current_fd)
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE:
                        raise ProjectError("arquivo não regular ou maior que 256 KiB")
                    old = _read_limited(current_fd)
                    if expected_sha256 is None or hashlib.sha256(old).hexdigest() != expected_sha256:
                        raise ProjectError("arquivo mudou; releia antes de gravar")
                    mode = stat.S_IMODE(info.st_mode) & 0o777
                finally:
                    os.close(current_fd)
            fd = os.open(temp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW |
                         os.O_CLOEXEC, 0o600, dir_fd=parent)
            try:
                os.fchmod(fd, mode)
                with os.fdopen(fd, "wb", closefd=False) as output:
                    output.write(data)
                    output.flush()
                    os.fsync(fd)
            finally:
                os.close(fd)
            # Refuse a changed destination immediately before replacement.
            # A caller holding write access to this directory is already in the
            # same local trust boundary; the server never follows symlink paths.
            try:
                latest_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                    dir_fd=parent)
            except FileNotFoundError:
                latest_fd = None
            if latest_fd is None:
                if expected_sha256 is not None:
                    raise ProjectError("arquivo mudou durante gravação")
            else:
                try:
                    latest = _read_limited(latest_fd)
                    if expected_sha256 is None or hashlib.sha256(latest).hexdigest() != expected_sha256:
                        raise ProjectError("arquivo mudou durante gravação")
                finally:
                    os.close(latest_fd)
            os.replace(temp_name, parts[-1], src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
            return {"path": path, "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data)}
        finally:
            try:
                os.unlink(temp_name, dir_fd=parent)
            except FileNotFoundError:
                pass
            os.close(parent)


def handle(project: Project, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    if not isinstance(method, str):
        return {"jsonrpc": "2.0", "id": message.get("id"),
                "error": {"code": -32600, "message": "Invalid request"}}
    if "id" not in message:
        return None
    request_id = message["id"]
    try:
        if method == "initialize":
            result: dict[str, Any] = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                                      "serverInfo": {"name": "phasezero-project", "version": "0.1.0"},
                                      "instructions": "Only the configured Git repository is available. "
                                      "Read files before replacement and pass their SHA-256. "
                                      "Common credential filenames are denied."}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = message.get("params")
            if not isinstance(params, dict) or not isinstance(params.get("arguments", {}), dict):
                raise ProjectError("argumentos inválidos")
            name = params.get("name")
            args = params.get("arguments", {})
            if name == "project_status" and not args:
                result = _json_text(project.status())
            elif name == "project_list_files" and set(args) <= {"prefix"}:
                result = _json_text(project.list_files(args.get("prefix", "")))
            elif name == "project_read_file" and set(args) == {"path"}:
                result = _json_text(project.read_file(args["path"]))
            elif name == "project_write_file" and set(args) == {"path", "content", "expectedSha256"}:
                result = _json_text(project.write_file(args["path"], args["content"],
                                                       args["expectedSha256"]))
            else:
                raise ProjectError("ferramenta ou parâmetros desconhecidos")
        else:
            return {"jsonrpc": "2.0", "id": request_id,
                    "error": {"code": -32601, "message": "Method not found"}}
    except (ProjectError, OSError, subprocess.TimeoutExpired) as error:
        # Do not echo OS paths or input content to remote tool callers.
        detail = str(error) if isinstance(error, ProjectError) else "operação local recusada"
        result = {"content": [{"type": "text", "text": detail}], "isError": True}
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def serve(project: Project, stdin: BinaryIO, stdout: BinaryIO) -> None:
    while True:
        line = stdin.readline(MAX_MESSAGE + 2)
        if not line:
            return
        if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
            return
        try:
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError("not an object")
            response = handle(project, message)
        except (UnicodeError, ValueError):
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "Parse error"}}
        if response is not None:
            stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
            stdout.flush()


def main() -> int:
    parser = argparse.ArgumentParser(description="MCP privado para um repositório Git")
    parser.add_argument("--repo", required=True, help="raiz canônica do repositório permitido")
    args = parser.parse_args()
    try:
        project = Project(args.repo)
    except (ProjectError, OSError, subprocess.TimeoutExpired) as error:
        print("repositório recusado: " + str(error), file=sys.stderr)
        return 2
    serve(project, sys.stdin.buffer, sys.stdout.buffer)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
