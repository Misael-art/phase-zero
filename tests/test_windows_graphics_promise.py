"""UX-010 — o Windows explica gráficos sem prometer 3D.

Um guest sem 3D provado nunca pode aparecer como acelerado. O que vale é
o que ESTA máquina mede (`windows-vm graphics status --json`), não o
rótulo otimista do contrato.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication, QLabel

from linux.ui_native.graphics_profiles import (
    host_profile_state, load_graphics_profiles, provision_graphics_options,
    recommended_profile, simple_graphics_options,
)
from linux.ui_native.windows_install_dialog import WindowsInstallDialog

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def _status(**profiles) -> dict:
    return {
        "recommended": {"profile": "compat", "note": "compat permanece estável"},
        "profiles": {
            key: {"eligible": value[0], "mode": value[1], "blockers": list(value[2])}
            for key, value in profiles.items()
        },
    }


# ------------------------------------------------------------------ contrato
def test_contract_never_calls_an_experimental_path_stable():
    """O rótulo do contrato tem de bater com o que o backend classifica."""
    proc = subprocess.run(
        ["bash", "linux/pz", "windows-vm", "graphics", "status", "--json"],
        cwd=ROOT, capture_output=True, text=True, timeout=90, check=False,
    )
    assert proc.returncode == 0, proc.stderr[:300]
    backend = json.loads(proc.stdout).get("profiles") or {}
    assert backend, "backend não classificou perfil algum"

    for profile in load_graphics_profiles():
        entry = backend.get(profile.id)
        if not isinstance(entry, dict):
            continue
        backend_mode = str(entry.get("mode") or "")
        if profile.mode == "stable":
            assert backend_mode == "stable", (
                f"{profile.id}: contrato diz stable, host diz {backend_mode}"
            )
        # Nada que o contrato ofereça para instalar pode prometer 3D no texto.
        if profile.provision_supported and backend_mode != "stable":
            assert "experimental" in profile.label.casefold() or \
                   "não garante" in profile.helper_text.casefold(), (
                f"{profile.id}: oferecido sem dizer que é experimental"
            )


# -------------------------------------------------------------- modo simples
def test_simple_mode_drops_a_profile_this_host_calls_experimental():
    status = _status(compat=(True, "stable", []), **{"virtio-gl": (True, "experimental", [])})
    simple = [pid for pid, _label, _helper in simple_graphics_options(status)]
    assert "compat" in simple
    assert "virtio-gl" not in simple


def test_simple_mode_drops_a_blocked_profile():
    status = _status(
        compat=(True, "stable", []),
        **{"virtio-gl": (False, "experimental", ["render node ausente"])},
    )
    simple = [pid for pid, _l, _h in simple_graphics_options(status)]
    assert simple == ["compat"]


def test_without_measurement_simple_mode_stays_on_the_compatible_profile():
    simple = [pid for pid, _l, _h in simple_graphics_options({})]
    assert simple == ["compat"], "sem medição não se oferece aceleração"
    profile, reason = recommended_profile({})
    assert profile == "compat" and reason


def test_host_state_reports_blockers():
    status = _status(**{"virtio-gl": (False, "experimental", ["render node ausente"])})
    mode, blockers = host_profile_state(status, "virtio-gl")
    assert mode == "blocked"
    assert blockers == ("render node ausente",)
    assert host_profile_state(status, "inexistente") == ("", ())


# --------------------------------------------------------------------- diálogo
def _labels(dialog) -> list[str]:
    return [dialog.graphics_combo.itemText(row) for row in range(dialog.graphics_combo.count())]


def test_dialog_shows_the_recommended_display_and_the_reason(app, tmp_path):
    status = _status(compat=(True, "stable", []))
    status["recommended"]["note"] = "VirtIO GL não garante 3D no Windows"
    dialog = WindowsInstallDialog(used_indices=set(), graphics_status=status)
    try:
        assert dialog.graphics_value() == "compat"
        text = dialog.graphics_recommendation.text()
        assert "compat" in text and "não garante 3D" in text
    finally:
        dialog.deleteLater()


def test_simple_dialog_never_offers_an_experimental_display(app):
    status = _status(compat=(True, "stable", []), **{"virtio-gl": (True, "experimental", [])})
    dialog = WindowsInstallDialog(used_indices=set(), graphics_status=status)
    try:
        joined = " | ".join(_labels(dialog))
        assert "virtio-gl" not in joined
        assert "compat" in joined
    finally:
        dialog.deleteLater()


def test_advanced_dialog_offers_it_but_says_it_is_experimental_here(app):
    status = _status(
        compat=(True, "stable", []),
        **{"virtio-gl": (False, "experimental", ["render node ausente em /dev/dri"])},
    )
    dialog = WindowsInstallDialog(used_indices=set(), graphics_status=status, advanced=True)
    try:
        labels = _labels(dialog)
        virtio = next(label for label in labels if "virtio-gl" in label)
        assert "indisponível neste host" in virtio
        # O motivo medido acompanha a opção, não some num log.
        for row in range(dialog.graphics_combo.count()):
            value, helper = dialog.graphics_combo.itemData(row)
            if value == "virtio-gl":
                assert "render node ausente" in helper
                break
        else:  # pragma: no cover - defensivo
            pytest.fail("virtio-gl ausente no modo avançado")
    finally:
        dialog.deleteLater()


def test_advanced_list_still_excludes_what_cannot_be_installed(app):
    # virtio-venus não é provisionável em nenhum modo: plan-only no contrato.
    offered = [pid for pid, _l, _h in provision_graphics_options()]
    assert "virtio-venus" not in offered
