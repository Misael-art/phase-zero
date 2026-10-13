"""PhaseZero Linux native control center."""

import json
from pathlib import Path


def _project_version() -> str:
    try:
        value = json.loads(
            Path(__file__).resolve().parents[2].joinpath("version.json").read_text(encoding="utf-8")
        )
        version = value.get("version")
        if not isinstance(version, str) or not version:
            return "0+unknown"
        channel = value.get("channel", "stable")
        return _display_version(version, channel)
    except (AttributeError, OSError, TypeError, json.JSONDecodeError):
        return "0+unknown"


def _display_version(version: str, channel: object) -> str:
    if channel == "beta" or channel == "nightly":
        return f"{version} ({channel})"
    return version


__version__ = _project_version()
