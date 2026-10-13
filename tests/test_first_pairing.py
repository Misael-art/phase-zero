"""UX-008 — o primeiro pareamento remoto acontece na interface.

Antes, uma máquina sem chave contra um host novo terminava num aviso
mandando abrir o terminal. Estes testes exercem a página real: a senha é
pedida, vai só por stdin, nunca entra em argv, e cancelar deixa o host
sem pareamento.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from linux.ui_native.command_runner import CommandRunner
from linux.ui_native.pages.homelab import HomelabPage

ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.usefixtures("no_homelab_startup_probe")


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def page(app, monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    page = HomelabPage(ROOT, CommandRunner(ROOT), [], by_id={})
    page.build()
    page._hosts = {"garagem": {"alias": "garagem", "user": "misael", "host": "192.168.1.9"}}
    page._host_combo.addItem("garagem (misael@192.168.1.9)", "garagem")
    page._host_combo.setCurrentIndex(page._host_combo.findData("garagem"))
    yield page
    page.deleteLater()


class _Spawn:
    """Records what start_pair would run, plus what it wrote to stdin."""

    def __init__(self) -> None:
        self.calls: list[tuple[list[str], str]] = []

    def install(self, page, monkeypatch) -> None:
        def fake(generate: bool = False, password: str = "") -> None:
            args = ["server", "homelab", "hosts", "pair", page._selected_host(), "--json"]
            if generate:
                args.append("--generate")
            if password:
                args.append("--password-stdin")
            self.calls.append((args, password))

        monkeypatch.setattr(page, "start_pair", fake)


def _needs_first_contact(alias: str = "garagem") -> bytes:
    return json.dumps({
        "schemaVersion": "1", "tool": "homelab-hosts", "action": "pair",
        "hostAlias": alias, "ok": False, "paired": False,
        "state": "needs-first-contact", "keyPath": "/home/u/.ssh/id_ed25519.pub",
        "generated": False,
        "guidance": "first contact needs one terminal login",
    }).encode("utf-8")


def _failure(state: str, guidance: str, alias: str = "garagem") -> bytes:
    return json.dumps({
        "schemaVersion": "1", "tool": "homelab-hosts", "action": "pair",
        "hostAlias": alias, "ok": False, "paired": False, "state": state,
        "firstContact": True, "guidance": guidance,
    }).encode("utf-8")


# Valor de fixture, não credencial: só precisa ser rastreável em argv.
FIXTURE_PW = "senha-fake-de-teste"  # gitleaks:allow


def test_first_contact_asks_for_the_password_instead_of_a_terminal(page, monkeypatch):
    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    asked: list[str] = []
    monkeypatch.setattr(
        type(page), "_ask_first_contact_password",
        lambda self, alias: asked.append(alias) or FIXTURE_PW,
    )

    page._on_pair_done(1, _needs_first_contact(), b"", "garagem")

    assert asked == ["garagem"], "senha do primeiro acesso não foi pedida"
    assert spawn.calls, "primeiro acesso não foi tentado"
    args, password = spawn.calls[-1]
    assert "--password-stdin" in args
    assert password == FIXTURE_PW
    # A senha nunca vira argumento — nem em pedaço.
    assert not any(FIXTURE_PW in arg for arg in args)


def test_cancelling_leaves_the_host_unpaired(page, monkeypatch):
    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    monkeypatch.setattr(type(page), "_ask_first_contact_password", lambda self, alias: "")

    page._on_pair_done(1, _needs_first_contact(), b"", "garagem")

    assert spawn.calls == [], "cancelar não pode disparar comando"
    assert page._onboard_state.get("pair") is False
    assert "cancelado" in page._state_label.text().casefold()


@pytest.mark.parametrize(
    "state,guidance",
    [
        ("auth-failed", "senha recusada pelo servidor"),
        ("timeout", "o servidor não respondeu a tempo (60s)"),
        ("unreachable", "não foi possível alcançar o servidor"),
    ],
)
def test_failed_first_contact_explains_and_offers_another_try(page, monkeypatch, state, guidance):
    from PySide6.QtWidgets import QMessageBox

    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    shown: list[str] = []
    monkeypatch.setattr(
        QMessageBox, "question",
        staticmethod(lambda *a, **k: shown.append(a[2]) or QMessageBox.Yes),
    )
    monkeypatch.setattr(type(page), "_ask_first_contact_password", lambda self, alias: FIXTURE_PW)

    page._on_pair_done(1, _failure(state, guidance), b"", "garagem")

    assert shown and guidance in shown[0], "causa não apresentada"
    assert spawn.calls, "nova tentativa não foi oferecida"
    assert spawn.calls[-1][1] == FIXTURE_PW


def test_declining_the_retry_states_the_cause_without_a_command(page, monkeypatch):
    from PySide6.QtWidgets import QMessageBox

    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    monkeypatch.setattr(QMessageBox, "question", staticmethod(lambda *a, **k: QMessageBox.No))

    page._on_pair_done(1, _failure("auth-failed", "senha recusada pelo servidor"), b"", "garagem")

    assert spawn.calls == []
    assert "senha recusada" in page._state_label.text().casefold()


def test_retry_keeps_the_onboarding_intent(page, monkeypatch):
    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    monkeypatch.setattr(type(page), "_ask_first_contact_password", lambda self, alias: FIXTURE_PW)
    page._pair_advance = True

    page._on_pair_done(1, _needs_first_contact(), b"", "garagem")

    assert page._pair_advance is True, "retomada perdeu a intenção do onboarding"


def test_result_for_another_host_is_still_dropped(page, monkeypatch):
    spawn = _Spawn()
    spawn.install(page, monkeypatch)
    asked: list[str] = []
    monkeypatch.setattr(
        type(page), "_ask_first_contact_password",
        lambda self, alias: asked.append(alias) or FIXTURE_PW,
    )

    page._on_pair_done(1, _needs_first_contact("outro"), b"", "outro")

    assert asked == [], "senha pedida para host que não é o selecionado"
    assert spawn.calls == []
