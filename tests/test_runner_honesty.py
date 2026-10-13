"""LUX-022 — progresso só de marcadores; tempo limite por tipo; falhas em PT."""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import PROGRESS_RE, READ_TIMEOUT_MS, CommandRunner
from linux.ui_native.provision_player import friendly_provision_failure

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.mark.parametrize("text", ["disco 95% usado", "bateria em 40%", "cpu 100% ocupada"])
def test_incidental_percentages_are_not_progress(text):
    assert PROGRESS_RE.findall(text) == []


@pytest.mark.parametrize("text,value", [
    ("PZ_PROGRESS=42", "42"),
    ("Progress: 70%", "70"),
    ("\\r[##########          ]  50% | instalando", "50"),
])
def test_explicit_markers_are_progress(text, value):
    groups = PROGRESS_RE.findall(text)[-1]
    assert next(g for g in groups if g) == value


def test_reads_and_previews_time_out_sooner(qapp):
    by_id = {a.id: a for a in build_catalog(ROOT)}
    runner = CommandRunner(ROOT)
    install = by_id["profile.safe-base"]
    assert runner.timeout_for(install, preview=False) == runner.timeout_ms
    assert runner.timeout_for(install, preview=True) == READ_TIMEOUT_MS
    assert runner.timeout_for(by_id["system.doctor"], preview=False) == READ_TIMEOUT_MS
    assert runner.timeout_for(replace(install, timeout_s=5), preview=False) == 5000


@pytest.mark.parametrize("reason", [
    "provision start timed out", "status poll failed 5x", "no operationId",
    "status JSON invalid", "failed", "start JSON: Expecting value",
])
def test_provision_failures_are_in_portuguese(reason):
    text = friendly_provision_failure(reason)
    assert text and reason not in text
