"""Exercise the exact shell step that maps a version channel to release flags."""

import json
import os
from pathlib import Path
import subprocess
import textwrap


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/release.yml").read_text()


def metadata_script():
    lines = WORKFLOW.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: Read version and release channel")
    run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
    body = []
    for line in lines[run + 1 :]:
        if line and not line.startswith("          "):
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


def run_metadata(tmp_path, channel, *, event="push", accepted="false", evidence="", red_ci="false"):
    (tmp_path / "version.json").write_text('{"version":"1.22.99","channel":"' + channel + '"}')
    output = tmp_path / "outputs"
    env_file = tmp_path / "env"
    output.write_text("")
    env_file.write_text("")
    env = os.environ.copy()
    env.update(GITHUB_OUTPUT=str(output), GITHUB_ENV=str(env_file), GITHUB_EVENT_NAME=event,
               STABLE_GATES_ACCEPTED=accepted, STABLE_GATE_EVIDENCE=evidence, ALLOW_RED_CI=red_ci)
    result = subprocess.run(["bash", "-euo", "pipefail", "-c", metadata_script()], cwd=tmp_path,
                            env=env, capture_output=True, text=True, check=False)
    return result, output.read_text() if output.exists() else ""


def test_beta_and_nightly_publish_as_prerelease_without_latest(tmp_path):
    assert "/releases/latest" in (ROOT / "README.md").read_text()
    for channel in ("beta", "nightly"):
        result, output = run_metadata(tmp_path, channel)
        assert result.returncode == 0, result.stderr
        assert f"channel={channel}\n" in output
        assert "prerelease=true\n" in output
        assert "make_latest=false\n" in output


def test_stable_requires_manual_gate_evidence_and_green_ci(tmp_path):
    for kwargs in ({}, {"event": "workflow_dispatch", "accepted": "true"},
                   {"event": "workflow_dispatch", "accepted": "true",
                    "evidence": "docs/releases/v1.22.99-acceptance.json", "red_ci": "true"}):
        result, output = run_metadata(tmp_path, "stable", **kwargs)
        assert result.returncode != 0
        assert not output
    evidence = tmp_path / "docs/releases/v1.22.99-acceptance.json"
    evidence.parent.mkdir(parents=True)
    for gate in ("G2", "G3", "G4"):
        (tmp_path / f"docs/{gate}.md").write_text(f"{gate} physical evidence")
    manifest = {"version": "1.22.99", "gates": {
        gate: {"state": "verified", "evidence": f"docs/{gate}.md"} for gate in ("G2", "G3", "G4")}}
    manifest["gates"]["G3"]["state"] = "pending"
    evidence.write_text(json.dumps(manifest))
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "docs"], cwd=tmp_path, check=True)
    result, output = run_metadata(tmp_path, "stable", event="workflow_dispatch", accepted="true",
                                  evidence="docs/releases/v1.22.99-acceptance.json")
    assert result.returncode != 0 and not output
    manifest["gates"]["G3"]["state"] = "verified"
    evidence.write_text(json.dumps(manifest))
    result, output = run_metadata(tmp_path, "stable", event="push", accepted="true",
                                  evidence="docs/releases/v1.22.99-acceptance.json")
    assert result.returncode != 0 and not output
    result, output = run_metadata(tmp_path, "stable", event="workflow_dispatch", accepted="true",
                                  evidence="docs/releases/v1.22.99-acceptance.json")
    assert result.returncode == 0, result.stderr
    assert "prerelease=false\n" in output
    assert "make_latest=true\n" in output


def test_release_action_consumes_metadata_outputs():
    assert "prerelease: ${{ steps.release_metadata.outputs.prerelease }}" in WORKFLOW
    assert "make_latest: ${{ steps.release_metadata.outputs.make_latest }}" in WORKFLOW
    assert "prerelease: ${{ env.CHANNEL" not in WORKFLOW
