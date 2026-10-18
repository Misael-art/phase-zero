from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
from pathlib import Path

import pytest

from linux.ai.chatgpt_project_mcp import Project, ProjectError, handle, serve


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    root.mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    (root / "README.md").write_text("Primeira versão\n")
    (root / "src").mkdir()
    (root / "src" / "app.py").write_text("print('ok')\n")
    subprocess.run(["git", "-C", str(root), "add", "README.md", "src/app.py"], check=True)
    return root


def test_read_write_uses_sha_and_preserves_existing_file_on_conflict(repo: Path) -> None:
    project = Project(str(repo))
    original = project.read_file("README.md")
    assert original["sha256"] == hashlib.sha256("Primeira versão\n".encode()).hexdigest()

    changed = project.write_file("README.md", "Segunda versão\n", original["sha256"])
    assert changed["sha256"] == hashlib.sha256("Segunda versão\n".encode()).hexdigest()
    assert (repo / "README.md").read_text() == "Segunda versão\n"

    with pytest.raises(ProjectError, match="mudou"):
        project.write_file("README.md", "perdida\n", original["sha256"])
    assert (repo / "README.md").read_text() == "Segunda versão\n"
    assert not list(repo.glob(".pz-mcp-*"))

    with pytest.raises(ProjectError, match="mudou"):
        project.write_file("README.md", "perdida\n", None)
    assert (repo / "README.md").read_text() == "Segunda versão\n"


def test_create_only_when_absent_and_no_symlink_or_parent_traversal(repo: Path,
                                                                    tmp_path: Path) -> None:
    project = Project(str(repo))
    outside = tmp_path / "outside.txt"
    outside.write_text("intacto")
    (repo / "link.txt").symlink_to(outside)
    (repo / "jump").symlink_to(tmp_path, target_is_directory=True)
    os.link(outside, repo / "hardlink.txt")

    for path in ("../outside.txt", "/etc/passwd", "jump/outside.txt", "link.txt",
                 "hardlink.txt",
                 ".git/config", ".env", "src/../README.md"):
        with pytest.raises((ProjectError, OSError)):
            project.read_file(path)
        with pytest.raises((ProjectError, OSError)):
            project.write_file(path, "mudou", None)
    assert outside.read_text() == "intacto"

    created = project.write_file("src/new.py", "print('new')\n", None)
    assert created["bytes"] == len("print('new')\n")
    with pytest.raises(ProjectError, match="mudou"):
        project.write_file("src/new.py", "unexpected", None)


def test_server_protocol_and_tool_error_are_valid_json_rpc(repo: Path) -> None:
    project = Project(str(repo))
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "project_read_file", "arguments": {"path": "README.md"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "project_read_file", "arguments": {"path": "../outside"}}},
    ]
    stdin = io.BytesIO(b"".join((json.dumps(item) + "\n").encode() for item in requests))
    stdout = io.BytesIO()
    serve(project, stdin, stdout)
    output = [json.loads(line) for line in stdout.getvalue().splitlines()]

    assert [item["id"] for item in output] == [1, 2, 3, 4]
    assert output[0]["result"]["capabilities"] == {"tools": {}}
    tools = output[1]["result"]["tools"]
    assert {item["name"] for item in tools} == {
        "project_status", "project_list_files", "project_read_file", "project_write_file"}
    assert next(item for item in tools if item["name"] == "project_write_file")["annotations"]["readOnlyHint"] is False
    assert json.loads(output[2]["result"]["content"][0]["text"])["content"] == "Primeira versão\n"
    assert output[3]["result"]["isError"] is True


def test_tool_arguments_are_rejected_without_running_project_code(repo: Path) -> None:
    project = Project(str(repo))
    bad = handle(project, {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                           "params": {"name": "project_write_file",
                                      "arguments": {"path": "src/app.py", "content": "pass",
                                                    "expectedSha256": None,
                                                    "command": "rm -rf /"}}})
    assert bad["result"]["isError"] is True
    assert (repo / "src/app.py").read_text() == "print('ok')\n"
    assert os.path.exists(repo / "README.md")
