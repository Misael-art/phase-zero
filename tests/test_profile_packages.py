"""PZ-AUD-027: profile manifests stay installable on clean Arch.

Static ghosts fail everywhere; live repo resolution runs only where pacman
exists (Arch family runners).
"""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = sorted((ROOT / "profiles").glob("*.json"))

# Names that never resolved in Arch repos: use the replacement instead.
GHOSTS = {
    "codecs": "gst plugin packages or ffmpeg (a bare `codecs` package does not exist)",
    "p7zip": "`7zip` (p7zip left Arch extra)",
    "cargo": "`rust` (cargo ships inside rust)",
    "redis": "`valkey` (redis left Arch extra)",
}


def _linux(profile: Path) -> dict:
    return json.loads(profile.read_text(encoding="utf-8")).get("packages", {}).get("linux", {})


def test_no_ghost_package_names():
    offenders = []
    for path in PROFILES:
        names = set(_linux(path).get("pacman", ())) | set(_linux(path).get("yay", ()))
        for ghost, hint in GHOSTS.items():
            if ghost in names:
                offenders.append(f"{path.name}: {ghost} -> {hint}")
    assert offenders == []


def test_no_duplicate_package_names():
    for path in PROFILES:
        linux = _linux(path)
        for key in ("pacman", "yay", "optionalPacman", "optionalYay"):
            names = list(linux.get(key, ()))
            assert len(names) == len(set(names)), f"{path.name}.{key}: duplicates"


def test_optional_lists_do_not_repeat_essential():
    for path in PROFILES:
        linux = _linux(path)
        essential = set(linux.get("pacman", ())) | set(linux.get("yay", ()))
        optional = set(linux.get("optionalPacman", ())) | set(linux.get("optionalYay", ()))
        assert essential.isdisjoint(optional), f"{path.name}: {sorted(essential & optional)}"


def test_essential_packages_resolve_in_repo():
    pacman = shutil.which("pacman")
    if pacman is None:
        import pytest

        pytest.skip("no pacman on this host")
    wanted: dict[str, list[str]] = {}
    for path in PROFILES:
        for name in _linux(path).get("pacman", ()):
            wanted.setdefault(name, []).append(path.name)
    # One batched query: -Si prints every resolvable package, errors on rest.
    proc = subprocess.run([pacman, "-Si", *sorted(wanted)], capture_output=True, text=True)
    found = {
        line.split(":", 1)[1].strip()
        for line in proc.stdout.splitlines()
        if line.startswith("Nome") or line.startswith("Name")
    }
    missing = [
        f"{','.join(sorted(set(profiles)))}: {name}"
        for name, profiles in sorted(wanted.items())
        if name not in found
        and subprocess.run([pacman, "-Q", name], capture_output=True).returncode != 0
    ]
    assert missing == []


def test_optional_preflight_never_blocks(tmp_path):
    """A profile with only an unavailable optional completes (best effort).

    Perfil legado é caminho pacman: fora de host Arch, `pz_run_profile`
    recusa por contrato ("use 'pz capabilities'"), que é a resposta certa
    e não o que este teste mede. O job arch-clean-host cobre isto de fato.
    """
    if shutil.which("pacman") is None:
        import pytest

        pytest.skip("no pacman on this host")
    profile = tmp_path / "opt.json"
    profile.write_text(json.dumps({
        "name": "pz-test-optional",
        "packages": {"linux": {"optionalPacman": ["phasezero-test-nope"]}},
    }), encoding="utf-8")
    script = (
        "source \"$0/linux/lib/common.sh\"; "
        "PZ_DRY_RUN=0 pz_run_profile \"$1\""
    )
    proc = subprocess.run(
        ["bash", "-c", script, str(ROOT), str(profile)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr[-2000:]
    assert "optional" in (proc.stdout + proc.stderr).lower()
