from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _stub(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def test_ai_and_server_ollama_routes_share_existing_instance(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    calls = tmp_path / "calls.log"
    _stub(bin_dir / "ollama", """#!/bin/sh
printf 'ollama %s\\n' "$*" >> "$CALL_LOG"
if [ "${1:-}" = list ]; then printf 'NAME ID SIZE MODIFIED\\n'; fi
""")
    _stub(bin_dir / "systemctl", """#!/bin/sh
printf 'systemctl %s\\n' "$*" >> "$CALL_LOG"
[ "${1:-}" = is-active ]
""")
    _stub(bin_dir / "pacman", """#!/bin/sh
printf 'pacman %s\\n' "$*" >> "$CALL_LOG"
exit 99
""")
    _stub(bin_dir / "sudo", """#!/bin/sh
printf 'sudo %s\\n' "$*" >> "$CALL_LOG"
exit 99
""")
    home = tmp_path / "home"
    env = dict(os.environ)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local/share")
    env["XDG_STATE_HOME"] = str(home / ".local/state")
    env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
    env["CALL_LOG"] = str(calls)
    env["PZ_DRY_RUN"] = "1"
    env["PZ_USE_SUDO"] = "0"
    (home / ".config").mkdir(parents=True)
    (home / ".local/share").mkdir(parents=True)
    (home / ".local/state").mkdir(parents=True)

    routes = (
        ("ai", "setup", "ollama"),
        ("server", "llm", "install"),
    )
    for args in routes:
        result = subprocess.run(
            [str(ROOT / "linux/pz"), *args],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        assert result.returncode == 0, result.stderr

    calls_text = calls.read_text(encoding="utf-8")
    assert calls_text.count("systemctl is-active ollama") == 2
    assert "ollama list" in calls_text
    assert "ollama pull" not in calls_text
    assert "pacman " not in calls_text
    assert "sudo " not in calls_text
