"""LUX-011 — Visão geral coerente com o veredito dos checks."""
from __future__ import annotations

from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QPushButton

from linux.ui_native.catalog import build_catalog
from linux.ui_native.command_runner import CommandRunner

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def qapp():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def page(qapp, monkeypatch):
    from linux.ui_native.pages.overview import OverviewPage

    catalog = build_catalog(ROOT)
    by_id = {a.id: a for a in catalog}
    page = OverviewPage(ROOT, CommandRunner(ROOT), catalog, by_id)
    monkeypatch.setattr(page.status_loader, "fetch_action", lambda _action: None)
    page.build()
    return page


def test_initial_state_has_no_success_mark(page):
    assert page.health_icon.text() != "✓"


def test_info_only_is_all_good(page):
    page._on_status_ready("system.doctor.system", "", [
        "[PASS] HOST: Kernel ok",
        "[INFO] WAYDROID: Waydroid não optado",
    ])
    assert page.health_title.text() == "Tudo certo"


def test_warn_still_warns(page):
    page._on_status_ready("system.doctor.system", "", ["[WARN] HOST: Disco quase cheio"])
    assert page.health_title.text() == "Sistema funcionando com avisos"


def test_failure_offers_history_not_second_retry(page):
    page._on_status_failed("system.doctor.system", "boom")
    labels = [b.text() for b in page.findChildren(QPushButton) if b.isVisibleTo(page)]
    assert labels.count("Tentar novamente") == 0
    assert "Abrir Resultados" in labels
