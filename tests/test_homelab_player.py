from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PySide6.QtWidgets import QApplication, QLabel
from PySide6.QtTest import QTest


@pytest.fixture(scope="module")
def app():
    return QApplication.instance() or QApplication([])


def _payload() -> dict:
    return {
        "schemaVersion": "1",
        "tool": "homelab-status",
        "profile": "assistant-private",
        "ready": False,
        "degraded": True,
        "accessMode": {"requested": "local", "effective": "local"},
        "resourceBudget": {
            "budgetMB": 3072, "availableMB": 8192, "verdict": "pass",
        },
        "stack": {
            "apps": [
                {
                    "key": "jellyfin", "layer": "core", "bind": "127.0.0.1",
                    "url": "http://127.0.0.1:8096", "running": False,
                },
                {
                    "key": "vaultwarden", "layer": "core", "bind": "127.0.0.1",
                    "url": "http://127.0.0.1:8222", "running": True,
                },
            ]
        },
    }


class BusyProc:  # noqa: N801
    """A fake process that reports Running, blocking every spawn."""
    def state(self):
        return 1  # Running != NotRunning(0)


def _page() -> "object":
    from linux.ui_native.pages.homelab import HomelabPage

    page = HomelabPage(ROOT, None, [], by_id={})
    page.build()
    page._proc = BusyProc()
    return page


class FakeSignal:  # noqa: N801
    def __init__(self, calls):
        self.calls = calls

    def connect(self, slot):
        self.calls.append(("connect", slot))


class FakeQProcess:  # noqa: N801
    """Records QProcess usage without ever starting a real binary."""
    MergedChannels = 0
    SeparateChannels = 1
    NotRunning = 0
    Running = 1
    FailedToStart = 1

    _calls: list = []

    def __init__(self, parent=None):
        self.parent = parent
        self.readyReadStandardOutput = FakeSignal(self._calls)
        self.readyReadStandardError = FakeSignal(self._calls)
        self.finished = FakeSignal(self._calls)
        self.errorOccurred = FakeSignal(self._calls)
        self._state = 0

    def setProcessChannelMode(self, *a):
        self._calls.append(("mode", a))

    def state(self):
        return self._state

    def start(self, program, args):
        self._calls.append(("start", program, list(args)))

    def kill(self):
        self._calls.append(("kill",))
        self._state = 0

    def readAllStandardOutput(self):
        return b""

    def readAllStandardError(self):
        return b""


@pytest.fixture(autouse=True)
def _never_spawn_real_pz(app, monkeypatch):
    """Force every HomelabPage spawn through FakeQProcess for the whole file.

    build() queues ``refresh_hosts`` via ``QTimer.singleShot(0, …)`` and every
    finished command queues ``refresh_status`` after 300 ms. Either can fire
    inside a later test, before that test installs its own fake, leaving real
    ``linux/pz`` children alive at interpreter shutdown (SIGSEGV after an all
    green suite in CI). PageRegistry builds the Linux hub eagerly, so the
    StatusLoader fetch timer is suppressed for the same reason.
    """
    import linux.ui_native.pages.homelab as mod

    FakeQProcess._calls = []
    monkeypatch.setattr(mod, "QProcess", FakeQProcess)
    monkeypatch.setattr(
        "linux.ui_native.status_loader.StatusLoader.fetch",
        lambda _self, *_a, **_k: None,
    )


def test_homelab_page_registered(app):
    from linux.ui_native.pages.registry import PageRegistry
    from linux.ui_native.command_runner import CommandRunner

    reg = PageRegistry(ROOT, CommandRunner(ROOT))
    assert "Homelab" in reg._pages
    assert "Homelab" in {r[0] for r in reg.cat_meta.values()}


def test_homelab_page_builds_widgets(app):
    page = _page()
    assert page._table.columnCount() == 5
    assert page._profile_combo is not None
    assert page._output is not None
    assert page._cards_host is not None
    assert page._cards_layout is not None
    assert page._host_combo is not None
    assert page._host_badge.text() == "Local"
    assert page._pair_btn is not None
    assert page._pair_btn.isEnabled() is False
    assert page._dash_btn is not None
    assert page._dash_btn.text() == "Abrir dashboard"
    assert page.dashboard_url() == "https://127.0.0.1:17443/"
    assert page.onboard_step_name() == "discover"
    assert page._onboard_next is not None


def test_homelab_page_applies_status(app):
    page = _page()
    page._apply_status(json.dumps(_payload()).encode())
    assert page._table.rowCount() == 2
    assert page._budget_label.text() == "3072 / 8192 MiB [pass]"
    assert page._state_label.text().startswith("não pronto")
    assert page._table.item(1, 4).text() == "sim"
    assert page._table.item(0, 4).text() == "não"


def test_homelab_page_translates_state_envelope(app):
    payload = dict(_payload(), state="needs-config", degraded=False,
                   summary="Homelab ainda não foi configurado.",
                   nextAction="linux/pz server homelab repair",
                   reasons=["homelab not configured (compose or .env missing)"])
    page = _page()
    page._apply_status(json.dumps(payload).encode())
    assert page._state_label.text() == "Ainda não configurado · acesso=local"
    out = page._output.toPlainText()
    assert "homelab not configured" in out
    assert "linux/pz server homelab repair" in out


def test_status_failure_is_actionable_not_scary(app):
    page = _page()
    page._proc = None
    page._on_status_done(1, b"", b"Cannot connect to the Docker daemon\n")
    assert page._state_label.text() == "não foi possível diagnosticar agora"
    assert "indisponível" not in page._state_label.text()
    out = page._output.toPlainText()
    assert "Docker daemon" in out
    assert "Atualizar" in out


def test_homelab_page_run_cmd_guard_blocks_running(app):
    page = _page()
    started = []

    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    try:
        page._proc = BusyProc()
        FakeQProcess._calls = started
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    assert started == []  # no new process while one is running


def test_homelab_page_run_cmd_spawns_process(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["profile", "set", "core"])
    finally:
        mod.QProcess = real_qprocess
    assert calls[0] == ("mode", (1,))  # SeparateChannels
    assert calls[-1][1].endswith("linux/pz")
    assert calls[-1][2] == ["server", "homelab", "profile", "set", "core"]
    # finished, error and both read channels are wired
    assert any(c[0] == "connect" for c in calls)


def test_homelab_page_modal_free_profile_empty(app):
    # Empty combo must warn instead of spawning a process.
    page = _page()
    warned = []

    import linux.ui_native.pages.homelab as mod

    class Fake:  # noqa: N801
        def addItem(self, *a):
            pass

        def findData(self, *a):
            return -1

        def currentData(self):
            return None

    page._profile_combo = Fake()

    class FakeBox:  # noqa: N801
        @staticmethod
        def warning(*a, **k):
            warned.append(1)

    real = mod.QMessageBox
    mod.QMessageBox = FakeBox
    try:
        page.apply_profile()
    finally:
        mod.QMessageBox = real
    assert warned == [1]


def test_homelab_page_pick_restore_never_passes_yes(app):
    # The Player must never append --yes: restore goes through --plan and the
    # CLI requires its own confirmation before applying.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._last_status = {
        "backupState": {"lastBackup": {"latest": "/tmp/fake-backup"}},
    }
    calls = []

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None

    class FakeQMessageBox:  # noqa: N801
        Yes = 1
        No = 2

        @staticmethod
        def question(*a, **k):
            return 1

        @staticmethod
        def information(*a, **k):
            pass

        @staticmethod
        def warning(*a, **k):
            pass

    real_box = mod.QMessageBox
    mod.QMessageBox = FakeQMessageBox
    try:
        page.pick_restore()
    finally:
        mod.QMessageBox = real_box
        mod.QProcess = real_qprocess
    assert calls
    assert "--yes" not in calls[-1][2]
    assert "--plan" in calls[-1][2]


def test_homelab_page_never_spawns_resume_flag(app):
    # CCS-004: the stack never parsed `up --resume`; the Player must not send a
    # flag the CLI rejects. Plain `up` is already idempotent/convergent.
    import inspect

    from PySide6.QtWidgets import QPushButton

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod)
    assert "--resume" not in src, "Player ainda envia up --resume (flag inexistente)"
    page = _page()
    resume_buttons = [b for b in page.findChildren(QPushButton) if b.text() == "Resume"]
    assert resume_buttons == []
    up_buttons = [b for b in page.findChildren(QPushButton) if b.text() == "Subir"]
    assert up_buttons, "ação Up convergente deve existir no Player (rótulo PT)"


def test_homelab_restore_catalog_action_is_plan_only(by_id_catalog):
    action = by_id_catalog["homelab.restore"]
    joined = " ".join(action.args)
    assert "--yes" not in joined, "catálogo não pode disparar restore com --yes"
    assert "--plan" in action.args
    assert not action.mutable, "restore --plan é leitura; mutável só na CLI com --yes"


def test_homelab_budget_targets_real_profile_not_core(by_id_catalog):
    """CCS-014: o orçamento usa perfil real do registro, não a chave 'core'."""
    action = by_id_catalog["homelab.budget"]
    assert "core" not in action.args
    assert "budget-active" in action.args
    assert "compose" in action.description.casefold() or "ram" in action.description.casefold()


def test_install_profiles_and_appliance_profiles_use_distinct_words(by_id_catalog):
    """CCS-014: server-* instala SO; perfis appliance são orçamento de RAM."""
    install_meta = by_id_catalog["server.homelab.status"]
    profiles_action = by_id_catalog["homelab.profiles"]
    assert "orçamento de ram" in profiles_action.description.casefold()
    # o eixo de instalação continua descrevendo instalação de sistema
    install_descriptions = " ".join(
        a.description for aid, a in by_id_catalog.items()
        if aid.startswith(("profile.server-homelab", "system.installation"))
    ).casefold()
    assert "instala" in install_descriptions or "instalação" in install_descriptions


@pytest.fixture(scope="module")
def by_id_catalog(app):
    from pathlib import Path as _Path

    from linux.ui_native.catalog import build_catalog

    return {a.id: a for a in build_catalog(_Path(ROOT))}


def test_homelab_page_restore_without_backup_warns(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._last_status = {}
    warned = []

    class FakeBox:  # noqa: N801
        @staticmethod
        def warning(*a, **k):
            warned.append(1)

    real = mod.QMessageBox
    mod.QMessageBox = FakeBox
    try:
        page.pick_restore()
    finally:
        mod.QMessageBox = real
    assert warned == [1]


def test_homelab_page_show_policy_uses_qprocess_not_subprocess(app):
    import inspect

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod)
    assert "import subprocess" not in src
    assert "subprocess.run" not in src
    assert "QFileDialog" not in src


def test_homelab_page_timeout_kills(app):
    page = _page()
    calls = []
    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    # Simulate the timeout firing for the spawned proc while it is running.
    proc = page._proc
    proc._state = FakeQProcess.Running
    page._kill_timed_out(proc)
    assert any(c[0] == "kill" for c in calls)
    assert page._proc is None


def _catalog_apps() -> list[dict]:
    return [
        {
            "key": "jellyfin", "title": "Jellyfin", "layer": "core",
            "enabled": True, "running": False, "budgetMB": 2048,
            "url": "http://127.0.0.1:8096",
            "governor": {"verdict": "pass", "reasons": []},
        },
        {
            "key": "n8n", "title": "n8n", "layer": "extras",
            "enabled": False, "running": False, "budgetMB": 1024,
            "url": "http://127.0.0.1:5678",
            "governor": {
                "verdict": "fail",
                "reasons": ["app overcommits memory: budget 1024 MiB > usable 200 MiB"],
            },
        },
    ]


def test_homelab_cards_render_catalog(app):
    page = _page()
    page._rebuild_cards(_catalog_apps())
    assert page._cards_layout.count() == 2
    texts = [w.text() for w in page.findChildren(QLabel)]
    joined = " ".join(texts)
    assert "Jellyfin" in joined
    assert "n8n" in joined
    assert "orçamento insuficiente" in joined or "overcommits" in joined
    toggles = [b for b in page._card_buttons if b.text() in {"Ligar", "Desligar"}]
    assert len(toggles) == 2
    ligar = [b for b in toggles if b.text() == "Ligar"][0]
    assert ligar.isEnabled() is False
    desligar = [b for b in toggles if b.text() == "Desligar"][0]
    assert desligar.isEnabled() is True


def test_homelab_card_preview_uses_qprocess(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._proc = None
    page._rebuild_cards(_catalog_apps())
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    try:
        previews = [b for b in page._card_buttons if b.text() == "Prévia"]
        previews[1].click()
    finally:
        mod.QProcess = real_qprocess
    assert calls
    argv = calls[-1][2]
    assert argv[:4] == ["server", "homelab", "apps", "enable"]
    assert "--dry-run" in argv
    assert "--yes" not in argv


def test_homelab_cards_do_not_block_event_loop_source(app):
    import inspect

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod)
    assert "import subprocess" not in src
    assert "subprocess.run" not in src
    assert "apps" in src
    assert "QProcess" in src


def test_homelab_remote_host_prefixes_qprocess(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._proc = BusyProc()
    page._host_combo.blockSignals(True)
    page._host_combo.addItem("garage (misael@192.168.1.8)", "garage")
    page._host_combo.setCurrentIndex(page._host_combo.findData("garage"))
    page._host_combo.blockSignals(False)
    page._on_host_changed()
    assert page._host_badge.text() == "Remoto"
    page._proc = None
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    try:
        page.run_cmd(["plan"])
    finally:
        mod.QProcess = real_qprocess
    argv = calls[-1][2]
    assert argv[:4] == ["server", "homelab", "--host", "garage"]
    assert "plan" in argv


def test_homelab_open_dashboard_url_local_and_remote(app):
    import inspect

    import linux.ui_native.pages.homelab as mod

    page = _page()
    assert page.dashboard_url() == "https://127.0.0.1:17443/"
    page._hosts["garage"] = {"alias": "garage", "user": "misael", "host": "192.168.1.8"}
    page._host_combo.blockSignals(True)
    page._host_combo.addItem("garage (misael@192.168.1.8)", "garage")
    page._host_combo.setCurrentIndex(page._host_combo.findData("garage"))
    page._host_combo.blockSignals(False)
    assert page.dashboard_url() == "https://192.168.1.8:17443/"
    src = inspect.getsource(mod.HomelabPage.open_dashboard)
    assert "QDesktopServices" in src
    assert "openUrl" in src
    assert "subprocess" not in src
    assert "--yes" not in src


def test_homelab_onboarding_discover_runs_real_discovery(app):
    # PZ-AUD-013: advancing on discover spawns agent discovery, it does
    # not record a placeholder.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page.start_onboarding()
    assert page.onboard_step_name() == "discover"
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.onboard_advance()
    finally:
        mod.QProcess = real_qprocess
    assert "discover" not in page._onboard_state
    argv = calls[-1][2]
    assert argv == ["server", "homelab", "agent", "discover", "--json"]
    # A real result advances; a failure stays with a message.
    import json as _json

    page._proc = None
    page._on_discover_done(0, _json.dumps({"manualFallback": "IP:17432"}).encode(), b"")
    assert page._onboard_state["discover"] == {"manualFallback": "IP:17432"}
    assert page.onboard_step_name() == "pair"


def test_homelab_onboarding_pair_needs_real_result(app):
    # PZ-AUD-013: an alias alone is not pairing; local host is explicit.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page.start_onboarding()
    page.onboard_ingest_discover({"manualFallback": "IP:17432"})
    page.onboard_advance()
    assert page.onboard_step_name() == "pair"
    # Local machine: recorded explicitly, no fake remote pairing.
    page._host_combo.setCurrentIndex(0)
    page.onboard_advance()
    assert page._onboard_state.get("pair") is True
    assert page.onboard_step_name() == "profile"


def test_homelab_onboarding_reaches_apply_without_yes(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    page.start_onboarding()
    assert page.onboard_step_name() == "discover"
    page.onboard_ingest_discover(
        {"service": "phasezero-homelab._tcp", "manualFallback": "IP:17432"}
    )
    page.onboard_advance()
    assert page.onboard_step_name() == "pair"
    page.onboard_ingest_pair(True)
    page.onboard_advance()
    assert page.onboard_step_name() == "profile"
    page.onboard_advance()
    assert page.onboard_step_name() == "review"
    assert "UPnP" in page.onboard_review_text()
    page.onboard_advance()
    assert page.onboard_step_name() == "review"
    page.onboard_confirm_review()
    page.onboard_advance()
    assert page.onboard_step_name() == "apply"
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        # PZ-AUD-013: first press renders the plan, never executes.
        page.onboard_apply()
    finally:
        mod.QProcess = real_qprocess
    argv = calls[-1][2]
    assert argv[:3] == ["server", "homelab", "prepare"]
    assert "--dry-run" in argv
    assert "--json" in argv
    assert "--yes" not in argv
    # Plan unchanged on second press: executes the reviewed plan.
    import json as _json

    plan = {"action": "prepare", "dryRun": True, "apps": ["vaultwarden"]}
    page._proc = None
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append((args, host))  # noqa: E731
    try:
        page._on_apply_plan_done(0, (_json.dumps(plan) + "\n").encode(), b"")
        assert page._onboard_state.get("review_plan") is not None
        page._proc = None
        page._on_apply_plan_done(0, (_json.dumps(plan) + "\n").encode(), b"")
        assert ran and ran[-1][0][:1] == ["prepare"] and "--dry-run" not in ran[-1][0]
        assert "--yes" not in ran[-1][0]
    finally:
        mod.QProcess = real_qprocess
        page.run_cmd = real_run_cmd


def test_homelab_pair_goes_through_hosts_pair(app):
    # PZ-AUD-014: pairing honors registry port/keys via `hosts pair`;
    # no raw ssh-copy-id argv. UX-008 added the first contact, and the
    # secret still never becomes an argument: only the `--password-stdin`
    # flag is appended, and the value goes to the child's stdin.
    import inspect

    import linux.ui_native.pages.homelab as mod

    src = inspect.getsource(mod.HomelabPage.start_pair)
    assert "hosts" in src and "pair" in src
    assert "ssh-copy-id" not in src
    assert "BatchMode=yes" not in src
    assert "sshpass" not in src
    assert "args.append(password)" not in src
    assert 'args.append("--password-stdin")' in src
    assert "proc.write" in src


def test_homelab_pair_done_ingests_states(app):
    import json

    import linux.ui_native.pages.homelab as mod

    page = _page()
    page._proc = None
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = []
    real_run_cmd = page.run_cmd
    seen = []
    page.run_cmd = lambda args: seen.append(args)  # noqa: E731
    warned = []

    class FakeBox:  # noqa: N801
        @staticmethod
        def warning(*a, **k):
            warned.append(a)

        @staticmethod
        def question(*a, **k):
            return 0

        @staticmethod
        def information(*a, **k):
            warned.append(a)

    real_box = mod.QMessageBox
    mod.QMessageBox = FakeBox
    try:
        paired = json.dumps({"paired": True, "state": "paired"}).encode()
        page._on_pair_done(0, paired, b"")
        assert page._onboard_state.get("pair") is True
        assert seen and seen[-1][:2] == ["hosts", "ping"]
        # UX-008: first contact is completed in the interface. Declining to
        # type a password leaves the host unpaired instead of printing a
        # terminal command to copy.
        asked = []
        real_ask = mod.HomelabPage._ask_first_contact_password
        mod.HomelabPage._ask_first_contact_password = \
            lambda self, alias: asked.append(alias) or ""
        try:
            first = json.dumps({
                "paired": False, "state": "needs-first-contact",
                "guidance": "first contact needs one terminal login",
            }).encode()
            page._on_pair_done(1, first, b"")
        finally:
            mod.HomelabPage._ask_first_contact_password = real_ask
        assert page._onboard_state.get("pair") is False
        assert asked, "senha do primeiro acesso não foi pedida"
        assert not warned, "primeiro acesso não deve terminar em aviso de terminal"
    finally:
        mod.QMessageBox = real_box
        mod.QProcess = real_qprocess
        page.run_cmd = real_run_cmd


def test_homelab_page_cancel_timeout_on_finish(app):
    page = _page()
    calls = []
    import linux.ui_native.pages.homelab as mod

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
        proc = page._proc
        page._cancel_timeout(proc)
    finally:
        mod.QProcess = real_qprocess
    assert id(proc) not in page._timeouts


def test_homelab_page_refresh_profiles_uses_roadmap_contract(app):
    # The CLI contract is `pz server homelab profiles --json`; the page must
    # spawn exactly that, not the legacy singular `profile list`.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.refresh_profiles()
    finally:
        mod.QProcess = real_qprocess
    assert calls[-1][1].endswith("linux/pz")
    assert calls[-1][2] == ["server", "homelab", "profiles", "--json"]


def test_homelab_page_marks_preview_profiles(app):
    # PZ-AUD-022: non-installable profiles show maturity, never an install
    # promise; the note is kept for the apply dialog.
    page = _page()
    payload = json.dumps({
        "profiles": [
            {"key": "edge", "title": "Edge", "maturity": "experimental",
             "installable": False, "installNote": "zeroclaw worker not implemented"},
            {"key": "core", "title": "Core", "maturity": "stable",
             "installable": True, "installNote": ""},
        ],
    }).encode()
    page._last_status = {}
    page._on_profiles_done(0, payload, b"")
    # UX-005: in simple mode a budget-only profile is not offered at all —
    # it cannot be mistaken for an install.
    labels = [page._profile_combo.itemText(i) for i in range(page._profile_combo.count())]
    assert not any("edge" in label for label in labels)
    # Asking for a simulation reveals it, still marked by maturity and with
    # the note that no service is installed.
    page._simulate_check.setChecked(True)
    labels = [page._profile_combo.itemText(i) for i in range(page._profile_combo.count())]
    assert any("[experimental]" in label for label in labels)
    assert not any("[stable]" in label for label in labels)
    assert "zeroclaw worker not implemented" in page._profile_map["edge:note"]


def test_homelab_page_no_blocking_event_loop(app):
    # Operations are spawned, never run synchronously: with a fake process the
    # call returns immediately and the GUI can keep processing events.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    calls = []

    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.run_cmd(["plan"])
        QTest.qWait(0)
        assert calls[-1][0] == "start"
    finally:
        mod.QProcess = real_qprocess


def test_restore_confirmation_phrase_binds_source():
    from linux.ui_native.pages.homelab import HomelabPage
    assert HomelabPage._confirmation_phrase("/backups/bk1") == "RESTAURAR bk1"


def test_write_confirm_file_roundtrip(app, tmp_path, monkeypatch):
    from linux.ui_native.pages.homelab import HomelabPage
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    page = _page()
    path = HomelabPage._write_confirm_file(page, "/backups/bk1", "RESTAURAR bk1")
    assert path is not None and path.exists()
    assert path.read_text(encoding="utf-8").strip() == "RESTAURAR bk1"
    assert path.stat().st_mode & 0o777 == 0o600
    path.unlink()


def test_zero_state_row_guides_to_up(app):
    payload = {
        "schemaVersion": "1", "ready": False, "degraded": False,
        "state": "needs-config",
        "summary": "Homelab ainda não foi configurado.",
        "nextAction": "linux/pz server homelab repair",
        "accessMode": {"requested": "local", "effective": "local"},
        "stack": {"apps": []},
    }
    page = _page()
    page._apply_status(json.dumps(payload).encode())
    cell = page._table.item(0, 0)
    assert cell is not None and "Subir" in cell.text()


def test_restore_summary_mentions_volumes_and_rollback():
    from linux.ui_native.pages.homelab import HomelabPage
    plan = {
        "action": "restore", "plan": True, "verified": True,
        "checks": [{"ok": True}, {"ok": True}],
        "archives": ["a.tgz", "b.tgz"],
        "volumesAffected": ["vaultwarden_data", "jellyfin_config"],
    }
    page = _page()
    text = page._restore_summary_text(plan, "/backups/bk1")
    assert "aprovada" in text and "(2/2 provas)" in text
    assert "vaultwarden_data" in text and "pré-backup" in text


# ---------------------------------------------------------------------------
# REV-004..007: document parser, pair gate, host-bound plan, typed plan.
# ---------------------------------------------------------------------------

def test_parse_json_payload_reads_multiline_document(app):
    # REV-004: `jq -n` output is pretty (multiline) JSON; the old line-based
    # parser returned {} and dropped a valid plan.
    page = _page()
    doc = {"action": "prepare", "dryRun": True, "apps": ["vaultwarden"]}
    pretty = json.dumps(doc, indent=2).encode()
    assert page._parse_json_payload(pretty) == doc
    # compact single line still works
    assert page._parse_json_payload(json.dumps(doc).encode()) == doc
    # leading non-JSON lines do not break parsing
    noisy = b"INFO: collecting\n" + json.dumps(doc, indent=2).encode()
    assert page._parse_json_payload(noisy) == doc
    # garbage stays {} (never raises)
    assert page._parse_json_payload(b"not json at all\n{broken") == {}


def test_parse_json_payload_unwraps_remote_host_envelope(app):
    # REV-006: `--host alias` wraps the payload in {hostAlias, rc, payload};
    # callers must see the payload plus the bound hostAlias.
    page = _page()
    inner = {"action": "prepare", "dryRun": True, "apps": ["vaultwarden"]}
    envelope = {
        "schemaVersion": "1", "tool": "homelab-hosts", "action": "exec",
        "hostAlias": "appliance", "rc": 0, "payload": inner, "error": None,
    }
    payload = page._parse_json_payload(json.dumps(envelope, indent=2).encode())
    assert payload["action"] == "prepare"
    assert payload["hostAlias"] == "appliance"
    assert "payload" not in payload


def test_onboarding_pair_false_blocks_advance(app):
    # REV-005: pair=false must keep the flow on the pair step; only a real
    # success for the selected host advances.
    page = _page()
    page._host_combo.addItem("fixture B", "fixture-b")
    page._host_combo.setCurrentIndex(1)
    page.start_onboarding()
    page.onboard_ingest_discover({"manualFallback": "IP:17432"})
    page.onboard_advance()
    assert page.onboard_step_name() == "pair"
    page.onboard_ingest_pair(False)
    page._pair_advance = False
    page.onboard_advance()
    assert page.onboard_step_name() == "pair"
    # a success recorded for ANOTHER host does not unlock this one
    page.onboard_ingest_pair(True, {"alias": "fixture-other"})
    page.onboard_advance()
    assert page.onboard_step_name() == "pair"
    page.onboard_ingest_pair(True, {"alias": "fixture-b"})
    page.onboard_advance()
    assert page.onboard_step_name() == "profile"


def test_onboarding_host_change_invalidates_pair_and_confirmation(app):
    # REV-005/006: authorization is bound to one host; switching targets
    # rewinds the flow to pair and drops the reviewed plan.
    page = _page()
    page.start_onboarding()
    page.onboard_ingest_pair(True, {"local": True})
    page._onboard_step = 4  # apply
    page.onboard_confirm_review()
    page._onboard_state["review_plan"] = json.dumps({"action": "prepare"})
    page._host_combo.addItem("fixture B", "fixture-b")
    page._host_combo.setCurrentIndex(1)  # fires _on_host_changed
    assert page._onboard_confirmed is False
    assert "review_plan" not in page._onboard_state
    assert "pair" not in page._onboard_state
    assert page.onboard_step_name() == "pair"


def test_plan_callback_from_other_host_is_dropped(app):
    # REV-006 acceptance: review A, select B, receive A's late callback —
    # nothing may execute and the stale plan must not be kept.
    page = _page()
    page.start_onboarding()
    page._onboard_confirmed = True
    page._onboard_state["profile"] = {"profile": "edge"}
    page._onboard_state["plan_host"] = "fixture-a"
    page._onboard_state["review_plan"] = json.dumps({"action": "prepare"})
    plan = {"action": "prepare", "dryRun": True, "host": "fixture-a"}
    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append((args, host))  # noqa: E731
    try:
        page._on_apply_plan_done(0, json.dumps(plan).encode(), b"")
        assert ran == []
        assert "review_plan" not in page._onboard_state
        # captured A vs current B: the host-switch guard fires
        assert "novo plano" in page._state_label.text()
    finally:
        page.run_cmd = real_run_cmd


def test_onboard_plan_binds_captured_host_and_carries_profile(app):
    # REV-007: the reviewed profile reaches the backend in both phases, and
    # execution targets the captured host.
    page = _page()
    page._host_combo.addItem("fixture A", "fixture-a")
    page._host_combo.setCurrentIndex(1)  # fires _on_host_changed (no-op here)
    page.start_onboarding()
    page._onboard_confirmed = True
    page._onboard_state["profile"] = {"profile": "edge"}
    import linux.ui_native.pages.homelab as mod

    calls = []
    real_qprocess = mod.QProcess
    mod.QProcess = FakeQProcess
    FakeQProcess._calls = calls
    page._proc = None
    try:
        page.onboard_apply()
    finally:
        mod.QProcess = real_qprocess
    argv = calls[-1][2]
    assert argv[:2] == ["server", "homelab"]
    assert argv[2:5] == ["--host", "fixture-a", "prepare"]
    assert "--dry-run" in argv and "--json" in argv
    assert argv[-2:] == ["--profile", "edge"]
    # matching plan -> second callback executes the same profile on the
    # captured host, never a re-derivation from widget state.
    plan = {"action": "prepare", "dryRun": True, "host": "fixture-a", "profile": "edge"}
    page._onboard_state["review_plan"] = json.dumps(plan, sort_keys=True)
    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append((args, host))  # noqa: E731
    try:
        page._on_apply_plan_done(0, json.dumps(plan).encode(), b"")
        assert ran == [(
            ["prepare", "--json", "--profile", "edge"], "fixture-a",
        )]
    finally:
        page.run_cmd = real_run_cmd


# ---------------------------------------------------------------------------
# R01-002: late pairing results never touch the wrong host.
# ---------------------------------------------------------------------------

def _to_pair_step_with_host(page, alias: str) -> None:
    page._host_combo.addItem(f"host {alias}", alias)
    page._host_combo.setCurrentIndex(page._host_combo.count() - 1)
    page.start_onboarding()
    page.onboard_ingest_discover({"manualFallback": "IP:17432"})
    page.onboard_advance()  # local-free: runs start_pair; blocked by BusyProc
    assert page.onboard_step_name() == "pair"


def test_late_pair_result_for_old_host_is_dropped(app):
    # Pair A in flight, operator selects B, A reports success: B stays
    # unpaired, the step does not advance, nothing runs against B.
    import linux.ui_native.pages.homelab as mod

    page = _page()
    _to_pair_step_with_host(page, "fixture-a")
    page._pair_advance = True
    # operator switches to B while the pairing runs
    page._host_combo.addItem("host fixture-b", "fixture-b")
    page._host_combo.setCurrentIndex(page._host_combo.count() - 1)
    assert page._pair_advance is False  # invalidated by the host switch
    paired = {"paired": True, "hostAlias": "fixture-a"}
    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append(args)  # noqa: E731
    try:
        page._on_pair_done(0, json.dumps(paired).encode(), b"", "fixture-a")
        assert page._onboard_state.get("pair") is not True
        assert page.onboard_step_name() == "pair"
        assert "outro host" in page._state_label.text()
        assert ran == []  # no ping / follow-up on B from A's result
    finally:
        page.run_cmd = real_run_cmd


def test_late_pair_result_for_selected_host_advances(app):
    import linux.ui_native.pages.homelab as mod

    page = _page()
    _to_pair_step_with_host(page, "fixture-b")
    page._pair_advance = True
    paired = {"paired": True, "hostAlias": "fixture-b"}
    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append(args)  # noqa: E731
    try:
        page._on_pair_done(0, json.dumps(paired).encode(), b"", "fixture-b")
        assert page._onboard_state.get("pair") is True
        assert (page._onboard_state.get("pair_detail") or {}).get("alias") == "fixture-b"
        assert page.onboard_step_name() == "profile"
        assert ran and ran[-1][:2] == ["hosts", "ping"]
    finally:
        page.run_cmd = real_run_cmd


# ---------------------------------------------------------------------------
# R01-003: the plan states budget-only profile truth in the UI.
# ---------------------------------------------------------------------------

def test_plan_renders_budget_only_profile_warning(app):
    page = _page()
    page.start_onboarding()
    page._onboard_confirmed = True
    page._onboard_state["profile"] = {"profile": "edge"}
    page._onboard_state["plan_host"] = ""
    plan = {
        "action": "prepare", "dryRun": True, "host": "local",
        "profile": "edge", "profileInstallable": False,
        "profileNote": "zeroclaw worker not implemented",
        "appsSource": "catalog-defaults",
    }
    page._on_apply_plan_done(0, json.dumps(plan).encode(), b"")
    assert page._onboard_state.get("review_plan") is not None
    # UX-007: the truth is stated on the page, in product language, and
    # recorded in the output pane as well.
    summary = page._plan_summary.text()
    assert page._plan_summary.isVisibleTo(page)
    for text in (summary, page._output.toPlainText()):
        assert "só reserva recursos" in text
        assert "zeroclaw worker not implemented" in text


def test_plan_without_warning_for_installable_profile(app):
    page = _page()
    page.start_onboarding()
    page._onboard_confirmed = True
    page._onboard_state["profile"] = {"profile": "edge"}
    page._onboard_state["plan_host"] = ""
    plan = {
        "action": "prepare", "dryRun": True, "host": "local",
        "profile": "edge", "profileInstallable": True,
        "appsSource": "catalog-defaults",
    }
    page._on_apply_plan_done(0, json.dumps(plan).encode(), b"")
    assert "só reserva recursos" not in page._output.toPlainText()
    assert "só reserva recursos" not in page._plan_summary.text()


# ---------------------------------------------------------------------------
# UX-001/UX-002: confirmation reachable by public input; stable plan intent.
# ---------------------------------------------------------------------------

def test_review_confirmation_reachable_by_clicks(app):
    # UX-001 acceptance: clicking through the PUBLIC controls must reach
    # apply. The button must be PRESENTED (visible AND enabled, whole
    # rectangle inside the scroll viewport) and the click is delivered to
    # the viewport AT the button's position — a hidden-but-enabled control
    # fails here. No private flags; onboard_confirm_review is never called
    # directly by the test.
    from PySide6.QtCore import Qt, QPoint, QRect
    from PySide6.QtTest import QTest

    import linux.ui_native.pages.homelab as mod

    page = _page()  # BusyProc keeps real spawns blocked
    page.resize(800, 600)
    page.show()
    app.processEvents()
    scroll = page._page_scroll

    def click_in_viewport(btn) -> None:
        scroll.ensureWidgetVisible(btn, 12, 12)
        app.processEvents()
        assert btn.isVisible() and btn.isEnabled(), \
            f"controle '{btn.text()}' não foi apresentado"
        assert not btn.visibleRegion().isEmpty()
        vp = scroll.viewport()
        rect = QRect(btn.mapTo(vp, QPoint(0, 0)), btn.size())
        assert vp.rect().contains(rect), \
            f"controle '{btn.text()}' parcialmente fora do viewport"
        # real hit-test: whatever the user's click would land on at the
        # button's position must be the button itself (a covered or clipped
        # control fails here)
        center_global = btn.mapToGlobal(btn.rect().center())
        hit = QApplication.widgetAt(center_global)
        assert hit is not None and (hit is btn or btn.isAncestorOf(hit)), \
            f"clique na posição de '{btn.text()}' atingiria {type(hit).__name__}"
        QTest.mouseClick(hit, Qt.MouseButton.LeftButton,
                         pos=hit.mapFromGlobal(center_global))

    spawned = []
    real_spawn = page._spawn
    page._spawn = lambda args, cb: spawned.append(list(args))  # noqa: E731
    try:
        page.start_onboarding()
        page.onboard_ingest_discover({"manualFallback": "IP:17432"})
        click_in_viewport(page._onboard_next)
        assert page.onboard_step_name() == "pair"
        click_in_viewport(page._onboard_next)
        assert page.onboard_step_name() == "profile"
        click_in_viewport(page._onboard_next)
        assert page.onboard_step_name() == "review"
        # the confirm control is presented whole and the click lands on it
        click_in_viewport(page._onboard_confirm)
        assert page._onboard_confirmed is True
        assert not page._onboard_confirm.isVisible()
        click_in_viewport(page._onboard_next)
        assert page.onboard_step_name() == "apply"
        # apply by clicks only: first press renders the plan
        click_in_viewport(page._onboard_next)
        assert spawned and spawned[-1][2:5] == ["prepare", "--dry-run", "--json"]
    finally:
        page._spawn = real_spawn
        page.hide()


def test_ui_pages_have_no_duplicate_method_definitions():
    # Prevention for UX-001: a later duplicate definition silently
    # overrides the earlier one (the confirm-button logic was lost that
    # way). Scans the page modules touched by this front.
    import re

    for name in ("homelab.py", "windows_vm.py", "base.py"):
        source = (ROOT / "linux" / "ui_native" / "pages" / name).read_text()
        names = re.findall(r"^    def (\w+)\(", source, re.M)
        dups = sorted({n for n in names if names.count(n) > 1})
        assert not dups, f"{name}: métodos duplicados {dups}"


# ---------------------------------------------------------------------------
# UX-003/UX-004 acceptance: real app window + real stylesheet, no horizontal
# overflow and every public control fully inside the viewport after
# scrolling — across the 800 -> 1280 -> 800 alternation.
# ---------------------------------------------------------------------------

@pytest.mark.usefixtures("no_homelab_startup_probe")
def test_pages_reflow_in_real_window_with_theme(app):
    from unittest.mock import patch

    from PySide6.QtCore import QPoint, QRect
    from PySide6.QtWidgets import QComboBox, QPushButton

    from linux.ui_native.app import apply_theme
    from linux.ui_native.main_window import MainWindow

    previous_qss = app.styleSheet()
    previous_style = app.style().objectName() if app.style() is not None else ""
    apply_theme(app, "dark")
    with patch.object(MainWindow, "_host_summary"), \
         patch("linux.ui_native.status_loader.StatusLoader.fetch_action"):
        win = MainWindow(ROOT)
        win.show()
        try:
            for width, height in ((800, 600), (1280, 800), (800, 600)):
                win.resize(width, height)
                for _ in range(8):
                    app.processEvents()
                for category in ("Homelab", "Windows VM"):
                    win.show_category(category)
                    for _ in range(8):
                        app.processEvents()
                    page = win.registry.page_for(category)
                    scroll = page._page_scroll
                    assert scroll.horizontalScrollBar().maximum() == 0, \
                        f"{category}: overflow horizontal em {width}x{height}"
                    host = scroll.widget()
                    vp = scroll.viewport()
                    def _label(w) -> str:
                        return w.text() if hasattr(w, "text") else w.currentText() or w.accessibleName()

                    controls = [
                        w for w in host.findChildren(QPushButton) + host.findChildren(QComboBox)
                        if w.isVisibleTo(host) and _label(w)
                    ]
                    assert controls, f"{category}: nenhum controle público"
                    for control in controls:
                        scroll.ensureWidgetVisible(control, 12, 12)
                        for _ in range(2):
                            app.processEvents()
                        rect = QRect(control.mapTo(vp, QPoint(0, 0)), control.size())
                        label = _label(control)
                        assert vp.rect().contains(rect), \
                            f"{category} {width}x{height}: '{label}' cortado no viewport"
        finally:
            win.hide()
            win.close()
            # Restaurar sempre: um assert acima não pode vazar o tema global
            # para os testes seguintes (mascarou a causa real no CI do #97).
            app.setStyleSheet(previous_qss)
            if previous_style:
                app.setStyle(previous_style)


def test_plan_survives_telemetry_drift_blocks_on_verdict_fail(app):
    # UX-002: availableMB drift (16000 -> 15999) must NOT revoke the
    # review; a crossed limit (verdict fail) blocks execution with a
    # reason; an app change still forces a new review.
    page = _page()
    page.start_onboarding()
    page._onboard_confirmed = True
    page._onboard_state["plan_host"] = ""
    base = {
        "action": "prepare", "dryRun": True, "host": "local",
        "apps": ["vaultwarden"], "access": "local",
        "budget": {"availableMB": 16000, "verdict": "pass"},
    }
    page._on_apply_plan_done(0, json.dumps(base).encode(), b"")
    assert page._onboard_state.get("review_plan") is not None

    ran = []
    real_run_cmd = page.run_cmd
    page.run_cmd = lambda args, host=None: ran.append((args, host))  # noqa: E731
    try:
        drifted = dict(base, budget={"availableMB": 15999, "verdict": "pass"})
        page._on_apply_plan_done(0, json.dumps(drifted).encode(), b"")
        assert ran, "1 MiB RAM drift wrongly invalidated the review"
        assert ran[-1][0][:2] == ["prepare", "--json"]

        # re-arm review with a different app set: material change forces a
        # new review (run_cmd is armed but must not fire yet)
        changed = dict(base, apps=["vaultwarden", "jellyfin"])
        page._on_apply_plan_done(0, json.dumps(changed).encode(), b"")
        assert len(ran) == 1
        assert page._onboard_state.get("review_plan") is not None

        # same intent as `changed`, but the budget crossed a limit
        crossed = dict(changed, budget={"availableMB": 512, "verdict": "fail"})
        page._on_apply_plan_done(0, json.dumps(crossed).encode(), b"")
        assert len(ran) == 1  # blocked
        assert "insuficientes" in page._state_label.text()
    finally:
        page.run_cmd = real_run_cmd


# ---------------------------------------------------------------------------
# UX-003: every control stays reachable by vertical scroll at small sizes.
# ---------------------------------------------------------------------------

def test_homelab_actions_reachable_by_vertical_scroll_at_800x600(app):
    from PySide6.QtTest import QTest

    page = _page()
    page.resize(800, 600)
    page.show()
    QTest.qWaitForWindowExposed(page)
    try:
        scroll = page._page_scroll
        assert scroll.widgetResizable()
        # the page never demands horizontal scrolling
        assert scroll.horizontalScrollBar().maximum() == 0
        for btn in page._action_buttons:
            scroll.ensureWidgetVisible(btn, 8, 8)
            app.processEvents()
            assert not btn.visibleRegion().isEmpty(), \
                f"botão '{btn.text()}' inalcançável em 800x600"
            assert btn.width() >= 60, f"botão '{btn.text()}' colapsado"
            assert btn.height() >= max(20, btn.sizeHint().height() - 4)
    finally:
        page.hide()
