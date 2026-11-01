"""Real Qt event-loop/process tests; provider network replaced by a slow fake."""
import json
import os
import sys
import time
from pathlib import Path

import pytest
from PySide6.QtCore import QCoreApplication, QEventLoop, QProcess, QTimer
from PySide6.QtWidgets import QApplication

from linux.ai.quota_tray import TrayCollector


def pump_until(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while not predicate() and time.monotonic() < deadline:
        QCoreApplication.processEvents(QEventLoop.AllEvents, 10)
        time.sleep(.005)
    assert predicate()


@pytest.fixture
def tray_env(tmp_path):
    env = dict(os.environ)
    env.pop("CODEX_HOME", None)
    env.pop("CLAUDE_CONFIG_DIR", None)
    for name, suffix in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                         ('XDG_DATA_HOME', 'data'), ('XDG_CACHE_HOME', 'cache')]:
        env[name] = str(tmp_path / suffix)
        Path(env[name]).mkdir()
    credentials = Path(env['HOME']) / '.claude/.credentials.json'
    credentials.parent.mkdir()
    credentials.write_text(json.dumps({'claudeAiOauth': {'accessToken': 'fixture-only'}}))
    return env


def slow_command(delay):
    code = f'''from linux.ai import quota_meter as qm
import time
def slow_network(url, headers):
    time.sleep({delay})
    return {{}}
qm.http_json = slow_network
qm.main(['status', '--json'])
'''
    return [sys.executable, '-c', code]


def test_slow_network_leaves_event_loop_responsive_and_single_flight(tray_env):
    app = QApplication.instance() or QApplication([])
    collector = TrayCollector(tray_env, command=slow_command(.2))
    results, ticks = [], []
    collector.ready.connect(results.append)
    timer = QTimer()
    timer.timeout.connect(lambda: ticks.append(1))
    timer.start(10)
    try:
        assert collector.refresh()
        assert not collector.refresh()
        pump_until(lambda: bool(results))
        assert len(ticks) >= 10 and len(results) == 1
        assert collector.process.state() == QProcess.NotRunning
    finally:
        timer.stop()
        collector.close()


def test_timeout_and_close_reap_worker_and_ignore_late_result(tray_env):
    app = QApplication.instance() or QApplication([])
    collector = TrayCollector(tray_env, command=slow_command(5), timeout_ms=100)
    results, errors = [], []
    collector.ready.connect(results.append)
    collector.failed.connect(errors.append)
    collector.refresh()
    pump_until(lambda: bool(errors))
    collector.close()
    assert not results and collector.process.state() == QProcess.NotRunning
    assert not collector.refresh()


def test_account_change_discards_old_worker_response(tray_env):
    app = QApplication.instance() or QApplication([])
    collector = TrayCollector(tray_env, command=slow_command(.2))
    results, errors = [], []
    collector.ready.connect(results.append)
    collector.failed.connect(errors.append)
    collector.refresh()
    credential = Path(tray_env['HOME']) / '.claude/.credentials.json'
    credential.write_text(json.dumps({'claudeAiOauth': {'accessToken': 'new-fixture'}}))
    try:
        pump_until(lambda: bool(errors))
        assert not results and 'Conta alterada' in errors[0]
        pump_until(lambda: bool(results))
        assert len(results) == 1
    finally:
        collector.close()
