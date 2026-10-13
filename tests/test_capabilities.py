from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

import pytest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from linux.capabilities import SCHEMA
from linux.capabilities.catalog import BY_ID, CAPABILITIES, PROFILES, compatibility, validate_catalog
from linux.capabilities.engine import (
    CapabilityError,
    apply_plan,
    create_plan,
    read_manifest,
    rollback_operation,
    verify_operation,
)
from linux.capabilities.models import SourceSpec
from linux.capabilities.platform import HostFacts
from linux.capabilities.providers import Provider
from linux.capabilities.catalog import source_for


def host(**changes) -> HostFacts:
    base = HostFacts(
        platform="linux",
        architecture="x86_64",
        distro="arch",
        distro_like=(),
        package_family="arch",
        immutable=False,
        immutable_kind="",
        container=False,
        init="systemd",
        desktop="kde",
        session="wayland",
        gpus=("amd",),
        package_manager="pacman",
        flatpak=True,
        flathub=True,
    )
    return replace(base, **changes)


class FakeProvider(Provider):
    def __init__(self, facts: HostFacts, installed: set[str] | None = None) -> None:
        super().__init__(facts)
        self.installed_names = set(installed or ())
        self.executed: list[list[str]] = []

    def installed(self, source):
        return source.name in self.installed_names

    def available(self, source):
        return True

    def estimate_space(self, source):
        if source.kind == "flatpak":
            return {"downloadBytes": None, "installedBytes": None}
        return {"downloadBytes": 1024, "installedBytes": 4096}

    def estimate_transaction_space(self, _sources):
        return None

    def execute(self, plan):
        self.executed.append(plan.command())
        name = plan.args[-1]
        if "uninstall" in plan.args or any(
            argument.startswith("-R") for argument in plan.args
        ) or "remove" in plan.args:
            self.installed_names.discard(name)
        else:
            self.installed_names.add(name)
        return 0, "ok", ""


@pytest.fixture
def private_state(tmp_path, monkeypatch):
    root = tmp_path / "state"
    monkeypatch.setenv("PZ_CAPABILITIES_STATE_DIR", str(root))
    return root


def test_catalog_is_valid_unique_and_uses_only_trusted_provider_kinds():
    validate_catalog()
    assert len(BY_ID) == len(CAPABILITIES) >= 70
    assert set(PROFILES) >= {
        "gaming-core", "game-streaming", "hardware-tools", "system-health",
        "developer", "security", "backup", "creative", "administration",
        "education", "full-workstation",
    }
    for capability in CAPABILITIES:
        assert capability.sources
        for source in capability.sources:
            assert source.kind in {"package", "flatpak"}
            assert source.version
            assert source.sha256
            if source.kind == "flatpak":
                assert source.remote == "flathub"


def test_installation_probe_distinguishes_absent_from_unverifiable():
    provider = Provider(host())
    source = SourceSpec("package", "ollama")
    with patch("linux.capabilities.providers.subprocess.run", return_value=SimpleNamespace(
        returncode=1, stdout="", stderr="error: package 'ollama' was not found",
    )):
        assert provider.installed(source) is False
    with patch("linux.capabilities.providers.subprocess.run", return_value=SimpleNamespace(
        returncode=1, stdout="", stderr="error: could not lock database",
    )):
        assert provider.installed(source) is None
    with patch("linux.capabilities.providers.subprocess.run", side_effect=FileNotFoundError):
        assert provider.installed(source) is None


def test_arch_removal_asks_pacman_to_prune_only_unneeded_dependencies():
    command = Provider(host()).remove_plan(SourceSpec("package", "nodejs"))

    assert command.command() == ["pacman", "-Rs", "--noconfirm", "nodejs"]
    assert command.elevated is True


def test_plan_blocks_when_existing_installation_cannot_be_probed(private_state):
    facts = host()
    class UnknownProvider(FakeProvider):
        def installed(self, source):
            return None

    plan = create_plan(
        capability_ids=["gaming.gamemode"], facts=facts,
        provider=UnknownProvider(facts),
    )
    assert plan["status"] == "blocked"
    assert "estado da instalação não pôde ser verificado" in " ".join(plan["blockers"])
    assert plan["actions"][0]["command"] is None


def test_compatibility_blocks_non_linux_container_immutable_and_wrong_gpu():
    xpadneo = BY_ID["hardware.xpadneo"]
    rocm = BY_ID["hardware.rocm"]
    assert compatibility(xpadneo, host(platform="windows"))[0] is False
    assert compatibility(xpadneo, host(container=True))[0] is False
    assert compatibility(xpadneo, host(immutable=True, immutable_kind="ostree"))[0] is False
    assert compatibility(rocm, host(gpus=("intel",)))[0] is False
    assert compatibility(rocm, host(gpus=("amd",)))[0] is True


@pytest.mark.parametrize(
    ("family", "distro", "expected"),
    (
        ("arch", "arch", "gamemode"),
        ("debian", "ubuntu", "gamemode"),
        ("fedora", "fedora", "gamemode"),
        ("suse", "opensuse-tumbleweed", "gamemode"),
    ),
)
def test_native_source_selection_is_multi_distro(family, distro, expected):
    facts = host(package_family=family, distro=distro, flatpak=False, flathub=False)
    source = source_for(BY_ID["gaming.gamemode"], facts)
    assert source is not None
    assert source.kind == "package"
    assert source.name == expected


@pytest.mark.parametrize(
    ("family", "distro", "expected"),
    (
        ("arch", "arch", "gcc"),
        ("debian", "debian", "g++"),
        ("fedora", "fedora", "gcc-c++"),
        ("suse", "opensuse-tumbleweed", "gcc-c++"),
    ),
)
def test_c_cpp_compiler_uses_native_distro_package(family, distro, expected):
    facts = host(package_family=family, distro=distro, flatpak=False, flathub=False)
    source = source_for(BY_ID["development.cpp"], facts)
    assert source is not None
    assert source.kind == "package"
    assert source.name == expected


def test_immutable_host_falls_back_to_flatpak_where_available():
    facts = host(
        distro="bazzite", distro_like=("fedora",), package_family="rpm-ostree",
        immutable=True, immutable_kind="rpm-ostree",
    )
    source = source_for(BY_ID["gaming.lutris"], facts)
    assert source is not None
    assert source.kind == "flatpak"


def test_plan_falls_back_when_native_repository_lacks_package(private_state):
    class FlatpakFallbackProvider(FakeProvider):
        def available(self, source):
            return source.kind == "flatpak"

    facts = host()
    provider = FlatpakFallbackProvider(facts)
    plan = create_plan(
        capability_ids=["hardware.qdiskinfo"], facts=facts, provider=provider,
    )
    assert plan["blockers"] == []
    assert plan["actions"][0]["source"]["kind"] == "flatpak"


def test_plan_expands_dependencies_and_records_private_preview(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["gaming.goverlay"], facts=facts, provider=provider,
    )
    assert [item["capabilityId"] for item in plan["actions"]] == [
        "gaming.mangohud", "gaming.goverlay",
    ]
    assert plan["confirmToken"]
    record = private_state / "plans" / f"{plan['id']}.json"
    assert stat.S_IMODE(record.stat().st_mode) == 0o600
    assert stat.S_IMODE(private_state.stat().st_mode) == 0o700
    assert all(item["command"]["program"] != "sh" for item in plan["actions"])


def test_web_js_recipe_has_no_ai_or_remote_service_dependencies(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(profile_ids=["development-web-js"], facts=facts, provider=provider)
    ids = [item["capabilityId"] for item in plan["actions"]]
    assert ids == ["development.nodejs", "development.pnpm"]
    assert "ollama" not in " ".join(ids).casefold()
    assert all(item["recipe"] is None for item in plan["actions"])
    assert plan["space"] == {
        "status": "partial", "downloadBytes": 2048,
        "installedBytes": 8192, "availableBytes": plan["space"]["availableBytes"],
        "estimateSource": "package-repository-metadata",
        "estimateCompleteness": "direct-packages-lower-bound",
        "targets": {
            "system": {
                "status": "partial", "downloadBytes": 2048,
                "installedBytes": 8192,
                "availableBytes": plan["space"]["targets"]["system"]["availableBytes"],
                "estimateSource": "package-repository-metadata",
                "estimateCompleteness": "direct-packages-lower-bound",
            },
        },
    }
    assert plan["space"]["availableBytes"] >= 0


def test_plan_uses_resolved_package_transaction_estimate(private_state):
    class AptSimulationProvider(FakeProvider):
        sources_seen = None

        def estimate_transaction_space(self, sources):
            self.sources_seen = [source.name for source in sources]
            return {
                "downloadBytes": 12_000_000,
                "installedBytes": 48_000_000,
                "estimateSource": "apt-transaction-simulation",
                "estimateCompleteness": "resolved-local-package-indexes",
            }

    facts = host(distro="debian", package_family="debian", package_manager="apt")
    provider = AptSimulationProvider(facts)
    plan = create_plan(
        profile_ids=["development-web-js"], facts=facts,
        provider=provider,
    )
    assert provider.sources_seen == ["nodejs", "node-pnpm"]
    target = plan["space"]["targets"]["system"]
    assert plan["space"]["downloadBytes"] == 12_000_000
    assert plan["space"]["installedBytes"] == 48_000_000
    assert target["estimateSource"] == "apt-transaction-simulation"
    assert target["estimateCompleteness"] == "resolved-local-package-indexes"
    assert plan["space"]["estimateCompleteness"] == "resolved-local-package-indexes"


@pytest.mark.parametrize(
    ("profile_id", "expected_packages"),
    (
        ("development-c-cpp", {"gcc"}),
        ("development-rust", {"rust"}),
        ("development-java", {"jdk-openjdk", "maven"}),
        ("development-dotnet", {"dotnet-sdk"}),
    ),
)
def test_language_development_profiles_prepare_only_the_selected_stack(
    private_state, profile_id, expected_packages,
):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(profile_ids=[profile_id], facts=facts, provider=provider)
    assert plan["status"] == "ready"
    assert {item["source"]["name"] for item in plan["actions"]} == expected_packages
    ids = {item["capabilityId"] for item in plan["actions"]}
    assert not any("ollama" in item or "ssh" in item for item in ids)

    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["status"] == "complete"
    assert provider.installed_names == expected_packages


def test_conflicting_capabilities_are_rejected_before_apply():
    facts = host()
    with pytest.raises(CapabilityError, match="conflitos na seleção"):
        create_plan(
            capability_ids=["health.iwd", "health.wpa-supplicant"],
            facts=facts, provider=FakeProvider(facts),
        )


def test_plan_blocks_when_conflict_is_already_installed(private_state):
    facts = host()
    provider = FakeProvider(facts, {"wpa_supplicant"})
    plan = create_plan(capability_ids=["health.iwd"], facts=facts, provider=provider)
    assert plan["status"] == "blocked"
    assert any("conflito instalado" in blocker for blocker in plan["blockers"])


def test_package_size_parser_handles_binary_and_decimal_units():
    assert Provider._size_bytes("1.5 MiB") == 1_572_864
    assert Provider._size_bytes("2 MB") == 2_000_000
    assert Provider._size_bytes("128", default_unit="KiB") == 131_072
    assert Provider._size_bytes("unknown") is None


def test_apt_transaction_parser_requires_both_totals_and_rejects_removal():
    output = """Need to get 1,234 kB/2,000 kB of archives.
After this operation, 5.5 MB of additional disk space will be used.
"""
    parsed = Provider.parse_apt_transaction_space(output)
    assert parsed == {
        "downloadBytes": 1_234_000,
        "installedBytes": 5_500_000,
        "estimateSource": "apt-transaction-simulation",
        "estimateCompleteness": "resolved-local-package-indexes",
    }
    assert Provider.parse_apt_transaction_space("Need to get 1 MB of archives.") is None
    assert Provider.parse_apt_transaction_space(
        output + "Remv important-package [1.0]\n"
    ) is None


def test_apt_transaction_estimate_runs_only_simulation(monkeypatch):
    facts = host(distro="debian", package_family="debian", package_manager="apt")
    provider = Provider(facts)
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(
            returncode=0,
            stdout="Need to get 10 MB of archives.\nAfter this operation, 25 MB of additional disk space will be used.\n",
            stderr="",
        )

    monkeypatch.setattr("linux.capabilities.providers.subprocess.run", fake_run)
    result = provider.estimate_transaction_space([
        SourceSpec("package", "nodejs"), SourceSpec("package", "pnpm"),
        SourceSpec("package", "nodejs"),
    ])
    assert result["downloadBytes"] == 10_000_000
    assert result["installedBytes"] == 25_000_000
    command, kwargs = calls[0]
    assert command[command.index("--") + 1:] == ["nodejs", "pnpm"]
    assert "--simulate" in command
    assert "--no-install-recommends" not in command
    assert kwargs["env"]["LC_ALL"] == "C"
    assert kwargs["timeout"] <= 30


def test_dnf_transaction_parser_handles_dnf4_and_dnf5_totals():
    output = """Dependencies resolved.
Total download size: 10 M
Installed size: 25 M
Operation aborted.
"""
    assert Provider.parse_dnf_transaction_space(output) == {
        "downloadBytes": 10 * 1024**2,
        "installedBytes": 25 * 1024**2,
        "estimateSource": "dnf-transaction-simulation",
        "estimateCompleteness": "resolved-local-package-indexes",
    }
    dnf5 = "Total download size: 10 MiB\nTotal installed size: 25 MiB\n"
    assert Provider.parse_dnf_transaction_space(dnf5)["downloadBytes"] == 10 * 1024**2
    assert Provider.parse_dnf_transaction_space("Total download size: 10 M\n") is None
    assert Provider.parse_dnf_transaction_space(
        output + "Removing:\n old-package\n"
    ) is None


def test_dnf_transaction_estimate_is_cache_only_and_non_mutating(monkeypatch):
    facts = host(distro="fedora", package_family="fedora", package_manager="dnf")
    provider = Provider(facts)
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(
            returncode=1,
            stdout="Total download size: 10 M\nInstalled size: 25 M\nOperation aborted.\n",
            stderr="",
        )

    monkeypatch.setattr("linux.capabilities.providers.subprocess.run", fake_run)
    result = provider.estimate_transaction_space([
        SourceSpec("package", "nodejs"), SourceSpec("package", "pnpm"),
        SourceSpec("package", "nodejs"),
    ])
    assert result["downloadBytes"] == 10 * 1024**2
    command, kwargs = calls[0]
    assert command[:5] == ["dnf", "--cacheonly", "--assumeno", "install", "--"]
    assert command[5:] == ["nodejs", "pnpm"]
    assert "-y" not in command
    assert kwargs["env"]["LC_ALL"] == "C"
    assert kwargs["timeout"] <= 45


def test_dnf_transaction_estimate_rejects_partial_nonzero_output(monkeypatch):
    facts = host(distro="fedora", package_family="fedora", package_manager="dnf")
    provider = Provider(facts)
    monkeypatch.setattr(
        "linux.capabilities.providers.subprocess.run",
        lambda *_args, **_kwargs: SimpleNamespace(
            returncode=1,
            stdout="Total download size: 10 M\nError: repository unavailable\n",
            stderr="",
        ),
    )
    assert provider.estimate_transaction_space([SourceSpec("package", "nodejs")]) is None


def test_zypper_transaction_parser_handles_summary_and_rejects_removals():
    output = """The following 2 NEW packages are going to be installed:
  libfoo foo
2 new packages to install.
Overall download size: 42.6 MiB. Already cached: 0 B. After the operation, additional 179.7 MiB will be used.
"""
    assert Provider.parse_zypper_transaction_space(output) == {
        "downloadBytes": int(42.6 * 1024**2),
        "installedBytes": int(179.7 * 1024**2),
        "estimateSource": "zypper-transaction-dry-run",
        "estimateCompleteness": "resolved-local-package-indexes",
    }
    assert Provider.parse_zypper_transaction_space(
        output + "The following package is going to be REMOVED:\n old-lib\n"
    ) is None
    assert Provider.parse_zypper_transaction_space(
        "Overall download size: 42.6 MiB.\n"
    ) is None


def test_zypper_transaction_estimate_uses_no_refresh_dry_run(monkeypatch):
    facts = host(distro="opensuse-tumbleweed", package_family="suse", package_manager="zypper")
    provider = Provider(facts)
    calls = []

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        return SimpleNamespace(
            returncode=0,
            stdout=(
                "Overall download size: 10 MiB. Already cached: 0 B. "
                "After the operation, additional 25 MiB will be used.\n"
            ),
            stderr="",
        )

    monkeypatch.setattr("linux.capabilities.providers.subprocess.run", fake_run)
    result = provider.estimate_transaction_space([
        SourceSpec("package", "nodejs"), SourceSpec("package", "pnpm"),
        SourceSpec("package", "nodejs"),
    ])
    assert result["downloadBytes"] == 10 * 1024**2
    command, kwargs = calls[0]
    assert command == [
        "zypper", "--no-refresh", "--non-interactive", "install", "--dry-run", "--",
        "nodejs", "pnpm",
    ]
    assert kwargs["env"]["LC_ALL"] == "C"
    assert kwargs["timeout"] <= 60


def test_pacman_transaction_includes_resolved_targets_and_installed_sizes(monkeypatch):
    provider = Provider(host())
    calls = []
    packages = {
        "nodejs": "Name : nodejs\nInstalled Size : 1.00 MiB\n",
        "node-pnpm": "Name : node-pnpm\nInstalled Size : 2.00 MiB\n",
        "libfoo": "Name : libfoo\nInstalled Size : 512 KiB\n",
    }

    def fake_run(command, **kwargs):
        calls.append((command, kwargs))
        if "-Sp" in command:
            return SimpleNamespace(returncode=0, stdout="nodejs\t100\nnode-pnpm\t200\nlibfoo\t300\n", stderr="")
        body = "\n\n".join(packages[name] for name in ("nodejs", "node-pnpm", "libfoo"))
        return SimpleNamespace(returncode=0, stdout=body, stderr="")

    monkeypatch.setattr("linux.capabilities.providers.subprocess.run", fake_run)
    result = provider.estimate_transaction_space([
        SourceSpec("package", "nodejs"), SourceSpec("package", "node-pnpm"),
    ])
    assert result["downloadBytes"] == 600
    assert result["installedBytes"] == 3_670_016
    assert result["estimateSource"] == "pacman-resolved-sync-targets"
    assert len(calls) == 2
    assert "--needed" in calls[0][0]
    assert "--print-format" in calls[0][0]
    assert "-y" not in calls[0][0]
    assert all(call[1]["env"]["LC_ALL"] == "C" for call in calls)


def test_flatpak_space_preview_targets_user_filesystem(private_state):
    facts = host()
    seen = []

    def disk_usage(path):
        seen.append(str(path))
        return SimpleNamespace(free=777)

    with patch("linux.capabilities.engine.shutil.disk_usage", side_effect=disk_usage):
        plan = create_plan(
            capability_ids=["development.vscode"], facts=facts,
            provider=FakeProvider(facts),
        )
    assert plan["space"]["targets"]["user"]["availableBytes"] == 777
    assert str(Path.home()) in seen
    assert plan["space"]["status"] == "partial"


def test_reapplying_same_plan_does_not_duplicate_install(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(capability_ids=["development.nodejs"], facts=facts, provider=provider)
    first = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert provider.installed_names == {"nodejs"}
    second = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert provider.installed_names == {"nodejs"}
    assert len(provider.executed) == 1
    assert first["installedByOperation"]
    assert second["installedByOperation"] == []


def test_partial_profile_apply_can_resume_without_reinstalling_completed_steps(private_state):
    class InterruptedPnpmProvider(FakeProvider):
        interrupt_once = True

        def execute(self, plan):
            if plan.args[-1] == "pnpm" and self.interrupt_once:
                self.executed.append(plan.command())
                self.interrupt_once = False
                return 130, "", "interrupted"
            return super().execute(plan)

    facts = host()
    provider = InterruptedPnpmProvider(facts)
    plan = create_plan(profile_ids=["development-web-js"], facts=facts, provider=provider)
    first = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert first["status"] == "failed"
    assert provider.installed_names == {"nodejs"}

    resumed = apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert resumed["status"] == "complete"
    assert provider.installed_names == {"nodejs", "pnpm"}
    assert sum(command[-1] == "nodejs" for command in provider.executed) == 1


def test_worker_crash_after_fake_package_commit_resumes_without_adopting_for_rollback(
    private_state, tmp_path, monkeypatch,
):
    """An abrupt child exit leaves one fake package outside operation ownership."""
    from linux.capabilities import state

    home = tmp_path / "home"
    config = home / ".config"
    data = home / ".local" / "share"
    state_home = home / ".local" / "state"
    for path in (home, config, data, state_home):
        path.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_STATE_HOME", str(state_home))

    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        profile_ids=["development-web-js"], facts=facts, provider=provider,
    )
    package_state = tmp_path / "fake-installed-packages.json"
    crash_worker = tmp_path / "crash_apply.py"
    crash_worker.write_text(
        """\
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, r"__ROOT__")
from linux.capabilities import engine
from linux.capabilities.platform import HostFacts
from linux.capabilities.providers import Provider

facts = HostFacts(
    platform="linux", architecture="x86_64", distro="arch", distro_like=(),
    package_family="arch", immutable=False, immutable_kind="", container=False,
    init="systemd", desktop="kde", session="wayland", gpus=("amd",),
    package_manager="pacman", flatpak=True, flathub=True,
)
packages_path = Path(os.environ["PZ_TEST_PACKAGE_STATE"])

class CrashAfterFirstPackage(Provider):
    def __init__(self):
        super().__init__(facts)

    def installed(self, source):
        packages = (
            json.loads(packages_path.read_text(encoding="utf-8"))
            if packages_path.exists() else []
        )
        return source.name in packages

    def available(self, source):
        return True

    def estimate_space(self, source):
        return {"downloadBytes": 1024, "installedBytes": 4096}

    def estimate_transaction_space(self, sources):
        return None

    def execute(self, plan):
        packages = (
            json.loads(packages_path.read_text(encoding="utf-8"))
            if packages_path.exists() else []
        )
        packages.append(plan.args[-1])
        packages_path.write_text(json.dumps(packages), encoding="utf-8")
        os._exit(73)

engine.shutil.disk_usage = lambda _path: SimpleNamespace(free=10**12, total=10**12, used=0)
engine.apply_plan(
    sys.argv[1], confirmation=sys.argv[2], facts=facts,
    provider=CrashAfterFirstPackage(),
)
""".replace("__ROOT__", str(ROOT)),
        encoding="utf-8",
    )
    child_env = {
        "PATH": os.defpath,
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(config),
        "XDG_DATA_HOME": str(data),
        "XDG_STATE_HOME": str(state_home),
        "PZ_CAPABILITIES_STATE_DIR": str(private_state),
        "PZ_TEST_PACKAGE_STATE": str(package_state),
    }
    crashed = subprocess.run(
        [sys.executable, str(crash_worker), plan["id"], plan["confirmToken"]],
        capture_output=True, text=True, cwd=ROOT, env=child_env, timeout=15,
        check=False,
    )
    assert crashed.returncode == 73, (crashed.stdout, crashed.stderr)
    assert json.loads(package_state.read_text(encoding="utf-8")) == ["nodejs"]
    assert state.list_records("operations") == []

    recovered_provider = FakeProvider(facts, installed={"nodejs"})
    resumed = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts,
        provider=recovered_provider,
    )
    assert resumed["status"] == "complete"
    assert [item["status"] for item in resumed["results"]] == ["preexisting", "installed"]
    assert len(resumed["installedByOperation"]) == 1
    recovered = resumed["installedByOperation"][0]
    assert recovered["capabilityId"] == "development.pnpm"
    assert recovered["source"]["name"] == "pnpm"
    assert sum(command[-1] == "nodejs" for command in recovered_provider.executed) == 0

    rolled_back = rollback_operation(
        resumed["id"], confirmation=resumed["rollbackToken"], facts=facts,
        provider=recovered_provider,
    )
    assert rolled_back["status"] == "complete"
    assert recovered_provider.installed_names == {"nodejs"}


def test_cooperative_cancel_stops_between_package_steps_and_resumes(private_state):
    class CancelAfterFirstPackageProvider(FakeProvider):
        def execute(self, plan):
            result = super().execute(plan)
            if len(self.executed) == 1:
                cancel_file.touch()
            return result

    facts = host()
    provider = CancelAfterFirstPackageProvider(facts)
    plan = create_plan(profile_ids=["development-web-js"], facts=facts, provider=provider)
    cancel_file = private_state / "cancel.request"

    cancelled = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
        cancel_file=cancel_file,
    )
    assert cancelled["status"] == "cancelled"
    assert "continuar" in cancelled["nextAction"]
    assert provider.installed_names == {"nodejs"}
    assert len(provider.executed) == 1

    cancel_file.unlink()
    resumed = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert resumed["status"] == "complete"
    assert provider.installed_names == {"nodejs", "pnpm"}
    assert sum(command[-1] == "nodejs" for command in provider.executed) == 1


def test_capability_cli_reports_cooperative_cancel_as_interrupt(capsys, monkeypatch):
    from linux.capabilities import __main__ as cli

    monkeypatch.setattr(cli, "apply_plan", lambda *_args, **_kwargs: {"status": "cancelled"})
    code = cli.main(["apply", "--plan-id", "plan-id", "--confirm", "confirmation"])
    assert code == 130
    assert json.loads(capsys.readouterr().out)["status"] == "cancelled"


def test_apply_rechecks_space_after_preview(private_state, monkeypatch):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(capability_ids=["development.nodejs"], facts=facts, provider=provider)
    monkeypatch.setattr("linux.capabilities.engine.shutil.disk_usage", lambda _path: SimpleNamespace(free=1))
    with pytest.raises(CapabilityError, match="espaço livre caiu"):
        apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert provider.executed == []


def test_preview_blocks_known_insufficient_space(private_state, monkeypatch):
    facts = host()
    monkeypatch.setattr("linux.capabilities.engine.shutil.disk_usage", lambda _path: SimpleNamespace(free=1))
    plan = create_plan(
        capability_ids=["development.nodejs"], facts=facts,
        provider=FakeProvider(facts),
    )
    assert plan["status"] == "blocked"
    assert plan["space"]["status"] == "insufficient"
    assert any("espaço estimado insuficiente" in blocker for blocker in plan["blockers"])


def test_all_profiles_resolve_without_catalog_gaps(private_state, monkeypatch):
    from linux.capabilities.recipes import ServiceRecipe

    monkeypatch.setattr(ServiceRecipe, "active", lambda self: False)
    facts = host()
    for profile_id in PROFILES:
        plan = create_plan(
            profile_ids=[profile_id], facts=facts, provider=FakeProvider(facts),
        )
        assert plan["actions"], profile_id
        assert plan["blockers"] == [], (profile_id, plan["blockers"])


def test_manifest_policy_blocks_excess_risk_and_reboot(private_state, tmp_path):
    manifest = tmp_path / "restricted.json"
    manifest.write_text(json.dumps({
        "schema": SCHEMA,
        "capabilities": ["hardware.xpadneo"],
        "policy": {"maxRisk": "normal", "allowReboot": False},
    }), encoding="utf-8")
    facts = host(package_family="debian", distro="debian")
    plan = create_plan(
        manifest=str(manifest), facts=facts, provider=FakeProvider(facts),
    )
    assert plan["status"] == "blocked"
    assert any("maxRisk" in blocker for blocker in plan["blockers"])
    assert any("allowReboot" in blocker for blocker in plan["blockers"])


def test_apply_verify_and_rollback_are_transaction_scoped(private_state):
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["gaming.gamemode"], facts=facts, provider=provider,
    )
    with pytest.raises(CapabilityError, match="token"):
        apply_plan(plan["id"], confirmation="wrong", facts=facts, provider=provider)
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["status"] == "complete"
    assert len(operation["installedByOperation"]) == 1
    assert verify_operation(operation["id"], facts=facts, provider=provider)["ok"] is True
    preview = rollback_operation(
        operation["id"], dry_run=True, facts=facts, provider=provider,
    )
    assert preview["status"] == "preview"
    rollback = rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    assert rollback["status"] == "complete"
    assert provider.installed_names == set()


def test_preexisting_item_is_never_rollback_candidate(private_state):
    facts = host()
    provider = FakeProvider(facts, {"gamemode"})
    plan = create_plan(
        capability_ids=["gaming.gamemode"], facts=facts, provider=provider,
    )
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["results"][0]["status"] == "preexisting"
    assert operation["installedByOperation"] == []
    rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    assert provider.installed_names == {"gamemode"}


def test_reversible_service_recipe_is_previewed_applied_and_rolled_back(
    private_state, monkeypatch,
):
    from linux.capabilities.recipes import ServiceRecipe

    monkeypatch.setattr(ServiceRecipe, "active", lambda self: False)
    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(
        capability_ids=["development.docker"], facts=facts, provider=provider,
    )
    assert plan["actions"][0]["recipe"]["unit"] == "docker.service"
    operation = apply_plan(
        plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider,
    )
    assert operation["recipesByOperation"] == [{
        "capabilityId": "development.docker", "unit": "docker.service",
    }]
    rollback_operation(
        operation["id"], confirmation=operation["rollbackToken"],
        facts=facts, provider=provider,
    )
    commands = [" ".join(command) for command in provider.executed]
    assert any("enable --now docker.service" in command for command in commands)
    assert any("disable --now docker.service" in command for command in commands)


def test_manifest_is_bounded_versioned_and_rejects_symlink(tmp_path):
    manifest = tmp_path / "profile.json"
    manifest.write_text(json.dumps({
        "schema": SCHEMA,
        "profiles": ["gaming-core"],
        "capabilities": ["backup.rclone"],
    }), encoding="utf-8")
    assert read_manifest(manifest)["schema"] == SCHEMA
    link = tmp_path / "linked.json"
    link.symlink_to(manifest)
    with pytest.raises(CapabilityError, match="simbólico"):
        read_manifest(link)


def test_cli_detect_and_profiles_emit_versioned_json():
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT)
    for command in ("detect", "profiles"):
        result = subprocess.run(
            [sys.executable, "-m", "linux.capabilities", command],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=20, check=False,
        )
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)["schema"] == SCHEMA


def test_pz_exposes_capabilities_cli():
    result = subprocess.run(
        [str(ROOT / "linux" / "pz"), "capabilities", "profiles"],
        cwd=ROOT, capture_output=True, text=True, timeout=20, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["schema"] == SCHEMA


def test_ui_preview_bindings_feed_plan_tokens_without_prompting():
    from linux.ui_native.catalog import build_catalog

    action = next(
        item for item in build_catalog(ROOT)
        if item.id == "capability.plan.gaming.gamemode"
    )
    assert action.mutable is True
    assert action.parameters == ()
    assert action.preview_bindings == (("plan_id", "id"), ("confirm", "confirmToken"))
    assert action.resolved_args(preview=True) == [
        "capabilities", "plan", "--capability", "gaming.gamemode",
    ]
    assert action.resolved_args(values={"plan_id": "plan-1", "confirm": "token-1"}) == [
        "capabilities", "apply", "--plan-id", "plan-1", "--confirm", "token-1",
    ]


def test_mode_and_rollback_metadata_are_derived_from_real_machinery():
    from linux.capabilities.catalog import mode_for, rollback_kinds

    # Perfil curado -> recomendado; risco elevado -> avançado; resto -> opt-in.
    assert mode_for(BY_ID["gaming.gamemode"]) == "recommended"
    assert mode_for(BY_ID["administration.tailscale"]) == "advanced"
    assert mode_for(BY_ID["education.stellarium"]) == "opt-in"
    assert mode_for(BY_ID["health.iwd"]) == "advanced"

    facts = host()
    package = source_for(BY_ID["gaming.gamemode"], facts)
    assert rollback_kinds(BY_ID["gaming.gamemode"], package) == ("package-remove",)
    # Capability com receita de serviço reverte a unidade antes do pacote.
    assert rollback_kinds(BY_ID["health.earlyoom"], package, has_recipe=True) == (
        "service-disable", "package-remove",
    )
    # Sem fonte aplicável não existe reversão automática, e o payload precisa
    # dizer isso em vez de sugerir um rollback que não existe.
    assert rollback_kinds(BY_ID["gaming.gamemode"], None) == ()


def test_status_payload_exposes_mode_and_rollback_for_every_item(monkeypatch):
    from linux.capabilities import engine

    facts = host()
    monkeypatch.setattr(engine, "detect", lambda: facts)
    payload = engine.catalog_payload(facts=facts, group="gaming")
    assert payload["rollbackLabels"]["package-remove"]
    for item in payload["capabilities"]:
        assert item["mode"] in {"recommended", "opt-in", "advanced"}
        assert isinstance(item["rollback"], list)
        if item["applicable"]:
            assert item["rollback"], f"{item['id']} aplicável sem rollback declarado"


def test_removal_requires_phasezero_install_history(private_state):
    from linux.capabilities.engine import create_removal_plan

    facts = host()
    # Instalado pelo usuário, fora do PhaseZero: o toggle não pode desinstalar.
    provider = FakeProvider(facts, {"gamemode"})
    plan = create_removal_plan(["gaming.gamemode"], facts=facts, provider=provider)
    assert plan["status"] == "blocked"
    assert plan["actions"] == []
    assert "não foi instalado pelo PhaseZero" in plan["blockers"][0]


def test_removal_plan_apply_and_verify_round_trip(private_state):
    from linux.capabilities.engine import (
        apply_removal, create_removal_plan, verify_removal,
    )

    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(capability_ids=["gaming.gamemode"], facts=facts, provider=provider)
    apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    assert provider.installed_names == {"gamemode"}

    removal_plan = create_removal_plan(["gaming.gamemode"], facts=facts, provider=provider)
    assert removal_plan["status"] == "ready"
    assert removal_plan["actions"][0]["rollback"] == ["package-remove"]

    preview = apply_removal(removal_plan["id"], dry_run=True, facts=facts, provider=provider)
    assert preview["status"] == "preview"
    assert provider.installed_names == {"gamemode"}, "preview não pode remover nada"

    with pytest.raises(CapabilityError, match="token"):
        apply_removal(removal_plan["id"], confirmation="wrong", facts=facts, provider=provider)

    removal = apply_removal(
        removal_plan["id"], confirmation=removal_plan["confirmToken"],
        facts=facts, provider=provider,
    )
    assert removal["status"] == "complete"
    assert provider.installed_names == set()
    assert verify_removal(["gaming.gamemode"], facts=facts, provider=provider)["ok"] is True


def test_removal_refuses_while_another_installed_capability_requires_it(private_state):
    from linux.capabilities.engine import create_removal_plan

    facts = host()
    provider = FakeProvider(facts)
    plan = create_plan(capability_ids=["gaming.goverlay"], facts=facts, provider=provider)
    apply_plan(plan["id"], confirmation=plan["confirmToken"], facts=facts, provider=provider)
    # goverlay depende de mangohud; remover mangohud sozinho quebraria o outro.
    blocked = create_removal_plan(["gaming.mangohud"], facts=facts, provider=provider)
    assert blocked["status"] == "blocked"
    assert "requisito de" in blocked["blockers"][0]


def test_removal_preserves_shared_dependency_until_last_dependent_is_removed(
    private_state, monkeypatch,
):
    from linux.capabilities.engine import apply_removal, create_removal_plan
    from linux.capabilities.recipes import ServiceRecipe

    # Keep service checks and changes inside the fake provider.
    monkeypatch.setattr(ServiceRecipe, "active", lambda self: False)
    facts = host()
    provider = FakeProvider(facts)
    install = create_plan(
        capability_ids=["development.docker-compose", "development.kind"],
        facts=facts, provider=provider,
    )
    assert [item["capabilityId"] for item in install["actions"]] == [
        "development.docker", "development.docker-compose", "development.kind",
    ]
    operation = apply_plan(
        install["id"], confirmation=install["confirmToken"],
        facts=facts, provider=provider,
    )
    assert operation["status"] == "complete"
    assert sum(command[-1] == "docker" for command in provider.executed) == 1

    remove_compose = create_removal_plan(
        ["development.docker-compose"], facts=facts, provider=provider,
    )
    assert remove_compose["status"] == "ready"
    apply_removal(
        remove_compose["id"], confirmation=remove_compose["confirmToken"],
        facts=facts, provider=provider,
    )
    assert "docker-compose" not in provider.installed_names
    assert {"docker", "kind"} <= provider.installed_names

    blocked = create_removal_plan(
        ["development.docker"], facts=facts, provider=provider,
    )
    assert blocked["status"] == "blocked"
    assert any("Kind" in blocker for blocker in blocked["blockers"])
    before_blocked_apply = list(provider.executed)
    with pytest.raises(CapabilityError, match="bloqueios"):
        apply_removal(blocked["id"], confirmation=blocked["confirmToken"], facts=facts, provider=provider)
    assert provider.executed == before_blocked_apply

    remove_kind = create_removal_plan(
        ["development.kind"], facts=facts, provider=provider,
    )
    assert remove_kind["status"] == "ready"
    apply_removal(
        remove_kind["id"], confirmation=remove_kind["confirmToken"],
        facts=facts, provider=provider,
    )
    assert "docker" in provider.installed_names

    remove_docker = create_removal_plan(
        ["development.docker"], facts=facts, provider=provider,
    )
    assert remove_docker["status"] == "ready"
    apply_removal(
        remove_docker["id"], confirmation=remove_docker["confirmToken"],
        facts=facts, provider=provider,
    )
    assert "docker" not in provider.installed_names
