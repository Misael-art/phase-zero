"""LUX-017 — TUI somente leitura, sem esconder falhas."""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUI = ROOT / "linux" / "ui" / "tui.sh"

MUTATING = re.compile(
    r"\b(install|install-[a-z-]+|integrate|repair|apply|index|next-reboot|"
    r"prepare(-[a-z]+)?|configure|toggle-keyboard|handheld|docked-tv|docked-monitor)\s*;;"
)


def _dispatch_lines() -> list[str]:
    return [
        line for line in TUI.read_text(encoding="utf-8").splitlines()
        if re.match(r"\s+[a-z-]+\)\s", line) and ("bash " in line or "linux/pz" in line)
    ]


def test_no_menu_entry_runs_a_mutating_command():
    offenders = [line.strip() for line in _dispatch_lines() if MUTATING.search(line)]
    assert offenders == []


def test_apply_entries_point_to_the_control_center():
    text = TUI.read_text(encoding="utf-8")
    assert "pz ui" in text
    assert "sudo pacman -S libnewt" in text


def test_show_output_reports_exit_code(tmp_path):
    body = re.search(r"^pz_tui_show_output\(\) \{.*?^\}", TUI.read_text(encoding="utf-8"), re.S | re.M)
    assert body
    shown = tmp_path / "shown.txt"
    script = f"""
set -euo pipefail
pz_tempfile() {{ mktemp "{tmp_path}/out.XXXX"; }}
pz_tui_height() {{ echo 24; }}
PZ_TUI_BACKTITLE=t
whiptail() {{ while [ "$1" != --textbox ]; do shift; done; cat "$2" > "{shown}"; }}
{body.group(0)}
pz_tui_show_output "t" sh -c 'echo quebrou; exit 7'
"""
    subprocess.run(["bash", "-c", script], check=True, env={**os.environ})
    text = shown.read_text(encoding="utf-8")
    assert "quebrou" in text and "falhou (código 7)" in text
