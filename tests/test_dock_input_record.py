"""Dock/undock input recorder (LUX-033): hermetic, no real sysfs, no real KWin."""
from __future__ import annotations

import importlib.util
import json
import os
import struct
import sys
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "linux" / "steamdeck" / "dock_input_record.py"

DEVICES = """\
I: Bus=0018 Vendor=2808 Product=1015 Version=0100
N: Name="FTS3528:00 2808:1015"
H: Handlers=event9 mouse2
B: PROP=2

I: Bus=0018 Vendor=2808 Product=1015 Version=0100
N: Name="FTS3528:00 2808:1015 UNKNOWN"
H: Handlers=event12 mouse3
B: PROP=0

I: Bus=0003 Vendor=28de Product=1142 Version=0001
N: Name="SCController Mouse"
H: Handlers=event19 mouse4
B: PROP=0

I: Bus=0003 Vendor=28de Product=1142 Version=0001
N: Name="SCController Keyboard"
H: Handlers=sysrq kbd event18
B: PROP=0
"""


@pytest.fixture()
def recorder(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("dock_input_record", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    drm = tmp_path / "drm"
    for name, status in (("card1-eDP-1", "connected"), ("card1-DP-1", "connected")):
        (drm / name).mkdir(parents=True)
        (drm / name / "status").write_text(status + "\n")
        (drm / name / "enabled").write_text("enabled\n")
    devices = tmp_path / "devices"
    devices.write_text(DEVICES)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    kwin_state = tmp_path / "kwin"
    kwin_state.mkdir()
    # Fake qdbus6: answers a property from a file named <event>.<prop>, or a default.
    (bin_dir / "qdbus6").write_text(
        "#!/usr/bin/env bash\n"
        'event="${2##*/}"; prop="${5}"\n'
        f'file="{kwin_state}/$event.$prop"\n'
        'if [ -f "$file" ]; then cat "$file"; exit 0; fi\n'
        'case "$prop" in enabled) echo true ;; outputName) echo "" ;; *) echo false ;; esac\n'
    )
    (bin_dir / "systemctl").write_text(
        "#!/usr/bin/env bash\nprintf 'ActiveState=active\\nNRestarts=0\\nMainPID=4242\\n'\n"
    )
    for tool in ("qdbus6", "systemctl"):
        (bin_dir / tool).chmod(0o755)

    monkeypatch.setenv("PZ_DRM_ROOT", str(drm))
    monkeypatch.setenv("PZ_INPUT_DEVICES_FILE", str(devices))
    monkeypatch.setenv("PZ_QDBUS6", str(bin_dir / "qdbus6"))
    monkeypatch.setenv("PZ_SYSTEMCTL", str(bin_dir / "systemctl"))
    monkeypatch.setenv("PZ_DOCK_RECORD_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("PZ_INPUT_DEV_ROOT", str(tmp_path / "dev"))
    (tmp_path / "dev").mkdir()
    module.test_paths = {"drm": drm, "devices": devices, "kwin": kwin_state, "dev": tmp_path / "dev"}
    return module


def test_state_picks_the_direct_touch_node_not_its_sibling(recorder) -> None:
    state = recorder.collect_state("manual")
    assert state["docked"] is True
    assert state["devices"]["touchscreen"]["event"] == "event9"
    assert state["devices"]["sccMouse"]["event"] == "event19"
    assert state["devices"]["touchscreen"]["kwin"]["enabled"] is True
    assert state["controllerService"]["MainPID"] == "4242"
    assert state["mutated"] is False and state["grabbed"] is False


def test_internal_panel_alone_is_not_docked(recorder) -> None:
    (recorder.test_paths["drm"] / "card1-DP-1" / "status").write_text("disconnected\n")
    assert recorder.collect_state("manual")["docked"] is False


def test_node_gone_after_undock_is_reported_as_such(recorder) -> None:
    before = recorder.collect_state("start")
    (recorder.test_paths["drm"] / "card1-DP-1" / "status").write_text("disconnected\n")
    recorder.test_paths["devices"].write_text(DEVICES.split("\n\n", 1)[1])
    after = recorder.collect_state("transition")
    findings = recorder.judge(before, after, None)
    assert findings["touchscreen"]["finding"] == "node-gone"
    assert findings["sccMouse"]["finding"] == "not-proven"


def test_touch_mapped_to_a_disconnected_output_is_named(recorder) -> None:
    (recorder.test_paths["drm"] / "card1-DP-1" / "status").write_text("disconnected\n")
    (recorder.test_paths["kwin"] / "event9.outputName").write_text("DP-1\n")
    after = recorder.collect_state("transition")
    findings = recorder.judge(None, after, None)
    assert findings["touchscreen"]["finding"] == "mapped-to-missing-output"
    assert "DP-1" in findings["touchscreen"]["detail"]


def test_kwin_disabled_device_is_named(recorder) -> None:
    (recorder.test_paths["kwin"] / "event19.enabled").write_text("false\n")
    findings = recorder.judge(None, recorder.collect_state("transition"), None)
    assert findings["sccMouse"]["finding"] == "kwin-disabled"


def test_silence_is_not_proof(recorder) -> None:
    state = recorder.collect_state("transition")
    sample = {"nodes": {"touchscreen": {"opened": True, "errno": None, "events": 0}}}
    assert recorder.judge(None, state, sample)["touchscreen"]["finding"] == "not-proven"


def test_sample_counts_events_without_consuming_a_missing_node(recorder) -> None:
    fifo = recorder.test_paths["dev"] / "event9"
    os.mkfifo(fifo)

    def writer() -> None:
        with open(fifo, "wb", buffering=0) as handle:
            time.sleep(0.1)
            # two EV_ABS events and one EV_SYN, which does not count
            handle.write(struct.pack("16xHHi", 3, 53, 100))
            handle.write(struct.pack("16xHHi", 3, 54, 200))
            handle.write(struct.pack("16xHHi", 0, 0, 0))
            time.sleep(0.3)

    thread = threading.Thread(target=writer, daemon=True)
    thread.start()
    state = recorder.collect_state("transition")
    sample = recorder.collect_sample(state, 0.8)
    thread.join(timeout=2)
    assert sample["nodes"]["touchscreen"] == {"opened": True, "errno": None, "events": 2}
    # event19 has no node under the fake /dev/input
    assert sample["nodes"]["sccMouse"]["opened"] is False
    assert sample["grabbed"] is False
    findings = recorder.judge(None, state, sample)
    assert findings["touchscreen"]["finding"] == "kernel-events-arrive"


def test_watch_records_an_undock_and_report_pairs_it_with_its_sample(recorder, capsys) -> None:
    dp_status = recorder.test_paths["drm"] / "card1-DP-1" / "status"

    def unplug() -> None:
        time.sleep(0.15)
        dp_status.write_text("disconnected\n")

    thread = threading.Thread(target=unplug, daemon=True)
    thread.start()
    code = recorder.main([
        "watch", "--interval", "0.05", "--settle", "0", "--sample-seconds", "0",
        "--max-transitions", "1",
    ])
    thread.join(timeout=2)
    assert code == 0

    records = recorder.load_records()
    assert [record["kind"] for record in records] == ["state", "state", "sample"]
    assert [record.get("reason") for record in records[:2]] == ["start", "transition"]
    assert records[0]["docked"] is True and records[1]["docked"] is False

    assert recorder.main(["report"]) == 0
    report = json.loads(capsys.readouterr().out)
    assert report["undocks"] == 1
    assert report["transitions"][0]["direction"] == "undock"
    assert report["transitions"][0]["sampled"] is True


def test_record_file_stays_bounded(recorder, monkeypatch) -> None:
    monkeypatch.setattr(recorder, "MAX_RECORDS", 5)
    for index in range(12):
        recorder.append_record({"kind": "state", "at": str(index)})
    records = recorder.load_records()
    assert len(records) == 5
    assert records[-1]["at"] == "11"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
