"""LUX-013 — Início no primeiro uso: sem duplicatas, sem promessa falsa."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


def _page(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "empty"))
    from linux.ui_native.pages.dashboard import DashboardPage

    catalog = build_catalog(ROOT)
    page = DashboardPage(ROOT, CommandRunner(ROOT), catalog, by_id={a.id: a for a in catalog})
    page.build()
    return page


def test_first_use_has_no_duplicate_entries_and_few_ctas(qapp, tmp_path, monkeypatch):
    page = _page(tmp_path, monkeypatch)
    assert page.first_use is True
    assert page.dashboard_cards == [], "atalhos só depois do primeiro trabalho"
    primaries = [b for b in page.findChildren(QPushButton) if b.objectName() == "primaryButton"]
    assert len(primaries) <= 8
    journey_titles = [
        card.findChildren(QLabel)[0].text() for card in page.journey_cards
    ]
    assert "Preparar este computador" not in journey_titles  # já é o passo 2


def test_play_goal_promises_only_what_it_runs(qapp, tmp_path, monkeypatch):
    from linux.ui_native.pages.dashboard import JOURNEYS

    play = next(row for row in JOURNEYS if row[0] == "play")
    assert play[2] == "profile.gaming"
    assert "Android" not in play[1] and "VM" not in play[1]


# ------------------------------------------------------------------ LUX-014
def _op(state, name, **fields):
    import json
    op = state / "phasezero" / "control-center" / "operations" / name
    op.mkdir(parents=True)
    record = {"schemaVersion": 1, "operationId": name, "category": "Visão geral"}
    record.update(fields)
    (op / "operation.json").write_text(json.dumps(record), encoding="utf-8")


def test_resume_ignores_reads_and_offers_retry_on_failure(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    _op(tmp_path, "20260101T000000Z-1-a-install", actionId="profile.safe-base",
        title="Instalar base", status="failed", mutable=True, preview=False)
    _op(tmp_path, "20260102T000000Z-1-b-status", actionId="system.doctor",
        title="Diagnóstico", status="succeeded", mutable=False, preview=False)
    _op(tmp_path, "20260103T000000Z-1-c-preview", actionId="profile.safe-base",
        title="Instalar base (prévia)", status="succeeded", mutable=True, preview=True)
    from linux.ui_native.pages.dashboard import DashboardPage

    catalog = build_catalog(ROOT)
    page = DashboardPage(ROOT, CommandRunner(ROOT), catalog, by_id={a.id: a for a in catalog})
    page.build()
    labels = " | ".join(w.text() for w in page.resume_card.findChildren(QLabel))
    assert "Última tarefa falhou" in labels and "Instalar base" in labels
    buttons = {b.text(): b for b in page.resume_card.findChildren(QPushButton)}
    assert "Retomar" not in buttons
    assert "Ver o que falhou" in buttons and "Tentar de novo" in buttons
    requested = []
    page.action_requested.connect(requested.append)
    buttons["Tentar de novo"].click()
    assert [a.id for a in requested] == ["profile.safe-base"]
