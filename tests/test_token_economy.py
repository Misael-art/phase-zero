import json
import subprocess
from pathlib import Path

import pytest

from linux.ai import token_economy as economy


@pytest.fixture
def owner(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(home / ".config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(home / ".local/share"))
    monkeypatch.setenv("XDG_STATE_HOME", str(home / "state"))
    project = tmp_path / "project"
    project.mkdir()
    monkeypatch.setattr(economy.Economy, "memory", lambda _self: {"available": True, "state": "ready", "clients": {"codex": {"mcp": True, "hooks": True}}})
    return economy.Economy(project)


def test_profiles_preserve_existing_rules_and_other_clients(owner):
    path = owner.project / "AGENTS.md"
    original = b"\xef\xbb\xbf# User rules\r\nKeep all tests.\r\n"
    path.write_bytes(original)
    assert owner.apply("codex", "economy")["changed"] is True
    first = path.read_bytes()
    assert owner.apply("codex", "economy")["changed"] is False
    assert path.read_bytes() == first
    assert first.startswith(original)
    owner.apply("opencode", "economy")
    opencode = economy.extract(economy.native_text(path), "opencode")
    owner.apply("codex", "basic")
    assert path.read_bytes().startswith(original)
    assert economy.extract(economy.native_text(path), "opencode") == opencode
    status = owner.status()
    codex = next(r for r in status["agents"] if r["id"] == "codex")
    assert codex["configured"] and codex["profile"] == "basic"
    assert codex["memory"]["connected"] and codex["memoryRequired"]
    assert codex["sessionUse"] == "unverified"
    assert "second memory store" in path.read_text(encoding="utf-8-sig")


def test_explicit_project_isolated_and_status_plan_have_no_writes(owner, tmp_path):
    before = set(owner.project.iterdir())
    assert owner.plan("claude-code", "economy")["routingChanges"] is False
    assert owner.status()["usage"]["billingSavings"] is None
    assert not owner.state.exists()
    assert set(owner.project.iterdir()) == before
    owner.apply("codex", "economy")
    other = tmp_path / "other" / "project"
    other.mkdir(parents=True)
    second = economy.Economy(other)
    assert second.project_id != owner.project_id
    assert second.row("codex")["profile"] == "basic"
    assert not second.row("codex")["configured"]


def test_drift_never_overwrites_user_edits(owner):
    owner.apply("codex", "basic")
    path = owner.project / "AGENTS.md"
    path.write_text(path.read_text().replace("Preserve user", "Changed by user: Preserve user"))
    original = path.read_bytes()
    assert owner.row("codex")["drift"]
    with pytest.raises(economy.EconomyError, match="drift"):
        owner.apply("codex", "economy")
    assert path.read_bytes() == original


def test_unmanaged_changes_outside_block_are_preserved(owner):
    owner.apply("codex", "basic")
    path = owner.project / "AGENTS.md"
    path.write_text("Never change my model.\n" + path.read_text())
    owner.apply("codex", "economy")
    assert path.read_text().startswith("Never change my model.\n")


def test_commit_failure_rolls_back_rules(owner, monkeypatch):
    path = owner.project / "CLAUDE.md"
    path.write_text("Original rules\n")
    monkeypatch.setattr(economy, "write_json", lambda *_args: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        owner.apply("claude-code", "economy")
    assert path.read_text() == "Original rules\n"
    assert not (owner.state / "profiles.json").exists()


def test_new_host_can_adopt_canonical_rules_but_not_foreign_markers(owner):
    path = owner.project / "AGENTS.md"
    path.write_text(economy.block("codex", "basic", owner.policy) + "\n")
    owner.apply("codex", "economy")
    assert owner.row("codex")["configured"]
    other = owner.project / "CLAUDE.md"
    other.write_text(economy.block("claude-code", "basic", owner.policy).replace("Preserve user", "Foreign content: Preserve user"))
    with pytest.raises(economy.EconomyError, match="unregistered"):
        owner.apply("claude-code", "basic")


def test_lock_prevents_parallel_profile_mutations(owner):
    with economy.locked(owner.state / "operation.lock"):
        with pytest.raises(RuntimeError):
            owner.apply("codex", "basic")
    assert not (owner.project / "AGENTS.md").exists()


def test_symlinks_and_malformed_blocks_are_refused(owner, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (owner.project / ".cursor").symlink_to(outside, target_is_directory=True)
    with pytest.raises(RuntimeError, match="symlink"):
        owner.apply("cursor", "economy")
    assert not list(outside.iterdir())
    (owner.project / "AGENTS.md").write_text(economy.markers("codex")[0])
    with pytest.raises(economy.EconomyError, match="markers"):
        owner.plan("codex", "basic")


def test_negative_compression_is_recorded_without_billing_claim(owner, monkeypatch):
    monkeypatch.setattr(economy.shutil, "which", lambda _name: "/fixture/rtk")
    def capture(command, **_kwargs):
        data = (b"rtk 0.43.0" if "--version" in command else b"revision\n" if command[1:2] == ["rev-parse"]
                else b"abc" if command[0] == "git" else b"abcdef")
        return subprocess.CompletedProcess(command, 0, data, b"")
    monkeypatch.setattr(economy, "capture", capture)
    report = owner.measure("codex")["measurement"]
    assert report["reductionPercent"] == -100
    assert report["billingSavings"] is None and report["quality"] == "not-evaluated"
    assert report["scope"] == "fixed-local-commands-not-agent-session"
    assert "abc" not in json.dumps(owner.record())


def usage(profile="basic", **updates):
    return {"agent": "codex", "profile": profile, "taskId": "case-1", "acceptanceId": "same-suite-v1", "model": "same-model",
            "runtimeVersion": "same-runtime", "revision": "same-revision", "inputTokens": 100,
            "outputTokens": 50, "cachedInputTokens": 10, "latencyMs": 1000, "retries": 0,
            "passed": True, "source": "provider-export", **updates}


def record(owner, value):
    path = owner.project / "usage.json"
    path.write_text(json.dumps(value))
    return owner.record_usage(path)


def test_usage_keeps_acceptance_cache_latency_retries_and_provenance(owner):
    record(owner, usage())
    record(owner, usage("economy", inputTokens=50, cachedInputTokens=20, passed=False, retries=2))
    summary = owner.usage_summary()
    pair = summary["pairs"][0]
    assert pair["baselineTokens"] == 150 and pair["economyTokens"] == 100
    assert not pair["accepted"] and pair["retryRegression"]
    assert pair["economyCachedInputTokens"] == 20
    assert summary["automaticPromotion"] is False
    assert summary["verification"] == "reported-not-attested"
    assert summary["byAgent"]["codex"]["acceptedPairs"] == 0
    assert summary["byAgent"]["codex"]["retryRegressions"] == 1
    assert summary["byAgent"]["codex"]["reductionPercent"] == 33.33
    record(owner, usage("economy", runtimeVersion="different-runtime"))
    assert len(owner.usage_summary()["pairs"]) == 1
    # Two different observations of the same tuple cannot be cherry-picked.
    record(owner, usage("economy", inputTokens=1, cachedInputTokens=0))
    assert not owner.usage_summary()["pairs"]


@pytest.mark.parametrize("updates", [{"apiKey": "secret"}, {"prompt": "private"}, {"inputTokens": -1},
                                     {"passed": 1}, {"cachedInputTokens": 101}, {"source": "attested"}])
def test_usage_refuses_secrets_unknown_fields_and_invalid_numbers(owner, updates):
    with pytest.raises(economy.EconomyError):
        record(owner, usage(**updates))
    assert not (owner.state / "usage").exists()


def test_real_rtk_measurement_uses_only_local_git(owner):
    if not economy.shutil.which("rtk"):
        pytest.skip("RTK not installed")
    subprocess.run(["git", "init", "-q", str(owner.project)], check=True)
    subprocess.run(["git", "-C", str(owner.project), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "--allow-empty", "-qm", "Fixture"], check=True)
    report = owner.measure("codex")["measurement"]
    assert report["providerCallsMade"] is False
    assert len(report["commands"]) == 3 and report["rawBytes"] >= 0


def test_default_policy_preserves_memory_and_does_not_enable_proxies(owner):
    for agent in owner.policy["agents"]:
        plan = owner.plan(agent, "basic")
        assert plan["memoryRequired"] and not plan["routingChanges"]
        assert "ai-memory stays connected" in plan["instruction"]
        assert "--memory" not in plan["instruction"]
    assert not owner.state.exists()
