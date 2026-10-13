from __future__ import annotations

import os
import pwd
import re
import shutil
import subprocess
from dataclasses import dataclass

from .models import SourceSpec
from .platform import HostFacts


@dataclass(frozen=True)
class CommandPlan:
    program: str
    args: tuple[str, ...]
    elevated: bool
    user_scope: bool = False

    def command(self) -> list[str]:
        return [self.program, *self.args]


class Provider:
    def __init__(self, facts: HostFacts) -> None:
        self.facts = facts

    def supports(self, source: SourceSpec) -> bool:
        if source.kind == "flatpak":
            return self.facts.flatpak and self.facts.flathub
        return source.kind == "package" and self.facts.package_family != "unknown"

    def installed(self, source: SourceSpec) -> bool | None:
        """Return package presence, absence, or unknown on probe failure.

        A failed package-manager query must never be treated as proof that an
        app is absent: that can prompt a duplicate install or misleading CTA.
        """
        command = self._query(source)
        if command is None:
            return None
        try:
            result = subprocess.run(
                command, capture_output=True, text=True,
                timeout=15, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode == 0:
            return True
        detail = f"{result.stdout or ''}\n{result.stderr or ''}".casefold()
        absent_markers = (
            "was not found", "is not installed", "not installed",
            "no packages found", "no package found", "no packages were found",
        )
        if any(marker in detail for marker in absent_markers):
            return False
        return None

    def available(self, source: SourceSpec) -> bool:
        if source.kind == "flatpak":
            return self.facts.flathub
        command = self._available(source)
        if command is None:
            return False
        try:
            return subprocess.run(
                command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=30, check=False,
            ).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    def estimate_space(self, source: SourceSpec) -> dict:
        """Best-effort repository size estimate; missing metadata stays unknown."""
        if source.kind != "package":
            return {"downloadBytes": None, "installedBytes": None}
        family = self.facts.package_family
        if family == "arch":
            command = ["pacman", "-Si", source.name]
            download_key, install_key = "Download Size", "Installed Size"
        elif family == "debian":
            command = ["apt-cache", "show", "--no-all-versions", source.name]
            download_key, install_key = "Size", "Installed-Size"
        elif family == "fedora":
            command = ["dnf", "repoquery", "--queryformat", "%{size} %{installsize}", source.name]
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
            except (OSError, subprocess.TimeoutExpired):
                return {"downloadBytes": None, "installedBytes": None}
            match = re.search(r"(?m)^\s*(\d+)\s+(\d+)\s*$", result.stdout or "")
            return {
                "downloadBytes": int(match.group(1)) if match else None,
                "installedBytes": int(match.group(2)) if match else None,
            }
        else:
            return {"downloadBytes": None, "installedBytes": None}
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return {"downloadBytes": None, "installedBytes": None}
        values: dict[str, int | None] = {"downloadBytes": None, "installedBytes": None}
        for line in (result.stdout or "").splitlines():
            key, separator, raw = line.partition(":")
            if not separator:
                continue
            value = raw.strip()
            if key.strip() == download_key:
                values["downloadBytes"] = self._size_bytes(value, default_unit="B" if family == "debian" else "")
            elif key.strip() == install_key:
                values["installedBytes"] = self._size_bytes(value, default_unit="KiB" if family == "debian" else "")
        return values

    def estimate_transaction_space(self, sources: list[SourceSpec]) -> dict | None:
        """Estimate a package install transaction without applying it.

        Debian uses APT's simulation summary; Arch asks pacman to print the
        resolved sync targets and reads each target's repository installed
        size; Fedora uses a cache-only DNF simulation; SUSE uses a no-refresh
        Zypper dry run. These use existing local package indexes. Missing or
        unparseable results fall back to direct-package lower bounds in the
        planner.
        """
        if not sources or any(source.kind != "package" for source in sources):
            return None
        names = list(dict.fromkeys(source.name for source in sources))
        if self.facts.package_family == "arch":
            return self._estimate_pacman_transaction_space(names)
        if self.facts.package_family == "fedora":
            return self._estimate_dnf_transaction_space(names)
        if self.facts.package_family == "suse":
            return self._estimate_zypper_transaction_space(names)
        if self.facts.package_family != "debian":
            return None
        command = [
            shutil.which("apt-get") or "apt-get", "--simulate",
            "-o", "Debug::NoLocking=1",
            "-o", "APT::Get::Show-User-Simulation-Note=false",
            "install", "--", *names,
        ]
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=30, check=False,
                env={**os.environ, "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        output = f"{result.stdout or ''}\n{result.stderr or ''}"
        return self.parse_apt_transaction_space(output)

    def _estimate_dnf_transaction_space(self, names: list[str]) -> dict | None:
        command = [
            self.facts.package_manager or "dnf", "--cacheonly", "--assumeno",
            "install", "--", *names,
        ]
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=45, check=False,
                env={**os.environ, "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        output = f"{result.stdout or ''}\n{result.stderr or ''}"
        # DNF reports cancellation as non-zero after --assumeno. Other errors
        # can contain partial summaries, so accept that status only on its
        # explicit cancellation marker.
        if result.returncode != 0 and not re.search(r"(?im)^Operation aborted\.?\s*$", output):
            return None
        return self.parse_dnf_transaction_space(output)

    @classmethod
    def parse_dnf_transaction_space(cls, output: str) -> dict | None:
        """Parse DNF transaction totals; reject removals and partial output."""
        if re.search(r"(?im)^\s*(?:Removing|Erasing)(?:\s|:)", output):
            return None
        size_pattern = r"([0-9][0-9,]*(?:\.[0-9]+)?\s*(?:[KMGT](?:i?B)?|[kMGT]|B)?)"
        download = re.search(rf"(?im)^\s*Total download size:\s*{size_pattern}\s*$", output)
        installed = re.search(rf"(?im)^\s*(?:Total )?Installed size:\s*{size_pattern}\s*$", output)
        download_bytes = cls._dnf_size_bytes(download.group(1)) if download else None
        installed_bytes = cls._dnf_size_bytes(installed.group(1)) if installed else None
        if download_bytes is None or installed_bytes is None:
            return None
        return {
            "downloadBytes": download_bytes,
            "installedBytes": installed_bytes,
            "estimateSource": "dnf-transaction-simulation",
            "estimateCompleteness": "resolved-local-package-indexes",
        }

    @classmethod
    def _dnf_size_bytes(cls, value: str) -> int | None:
        """Parse DNF's binary format_number suffixes and explicit byte units."""
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]|[KMGT]i?B|B)?", value.strip(), re.IGNORECASE)
        if not match:
            return None
        number, raw_unit = match.groups()
        unit = (raw_unit or "B").casefold()
        short_units = {"k": "kib", "m": "mib", "g": "gib", "t": "tib"}
        return cls._size_bytes(number + " " + short_units.get(unit, unit))

    def _estimate_zypper_transaction_space(self, names: list[str]) -> dict | None:
        command = [
            self.facts.package_manager or "zypper", "--no-refresh", "--non-interactive",
            "install", "--dry-run", "--", *names,
        ]
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=60, check=False,
                env={**os.environ, "LC_ALL": "C"},
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        output = f"{result.stdout or ''}\n{result.stderr or ''}"
        return self.parse_zypper_transaction_space(output)

    @classmethod
    def parse_zypper_transaction_space(cls, output: str) -> dict | None:
        """Parse Zypper's complete dry-run totals; reject package removals."""
        if re.search(
            r"(?im)^\s*The following .*\b(?:are|is) going to be (?:REMOVED|uninstalled)\b",
            output,
        ):
            return None
        size_pattern = r"([0-9][0-9,]*(?:\.[0-9]+)?\s*[KMGT]?i?B)"
        download = re.search(
            rf"(?im)^\s*Overall download size:\s*{size_pattern}(?:\.|\s|$)", output,
        )
        installed = re.search(
            rf"(?im)After the operation,\s*additional\s+{size_pattern}\s+will be used\.",
            output,
        )
        download_bytes = cls._size_bytes(download.group(1).replace(",", "")) if download else None
        installed_bytes = cls._size_bytes(installed.group(1).replace(",", "")) if installed else None
        if download_bytes is None or installed_bytes is None:
            return None
        return {
            "downloadBytes": download_bytes,
            "installedBytes": installed_bytes,
            "estimateSource": "zypper-transaction-dry-run",
            "estimateCompleteness": "resolved-local-package-indexes",
        }

    def _estimate_pacman_transaction_space(self, names: list[str]) -> dict | None:
        command = [
            self.facts.package_manager or "pacman", "-Sp", "--needed",
            "--print-format", "%n\t%s", "--", *names,
        ]
        env = {**os.environ, "LC_ALL": "C"}
        try:
            targets = subprocess.run(
                command, capture_output=True, text=True, timeout=30, check=False, env=env,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if targets.returncode != 0:
            return None
        resolved: list[tuple[str, int]] = []
        for line in (targets.stdout or "").splitlines():
            name, separator, raw_size = line.partition("\t")
            if not separator or not name.strip() or not raw_size.strip().isdigit():
                continue
            resolved.append((name.strip(), int(raw_size.strip())))
        if not resolved or not set(names).issubset({name for name, _download in resolved}):
            return None
        info_command = [
            self.facts.package_manager or "pacman", "-Si", "--",
            *(name for name, _download in resolved),
        ]
        try:
            info = subprocess.run(
                info_command, capture_output=True, text=True, timeout=30, check=False, env=env,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if info.returncode != 0:
            return None
        installed_sizes = self.parse_pacman_installed_sizes(info.stdout or "")
        if len(installed_sizes) != len(resolved):
            return None
        return {
            "downloadBytes": sum(download for _name, download in resolved),
            "installedBytes": sum(installed_sizes.values()),
            "estimateSource": "pacman-resolved-sync-targets",
            "estimateCompleteness": "resolved-local-package-indexes",
        }

    @classmethod
    def parse_pacman_installed_sizes(cls, output: str) -> dict[str, int]:
        """Parse package `Name` and `Installed Size` fields from `pacman -Si`."""
        sizes: dict[str, int] = {}
        for block in re.split(r"\n\s*\n", output):
            name = re.search(r"(?m)^Name\s*:\s*(\S+)\s*$", block)
            size = re.search(r"(?m)^Installed Size\s*:\s*(.+?)\s*$", block)
            if name and size:
                parsed_size = cls._size_bytes(size.group(1))
                if parsed_size is not None:
                    sizes[name.group(1)] = parsed_size
        return sizes

    @classmethod
    def parse_apt_transaction_space(cls, output: str) -> dict | None:
        """Parse both APT transaction totals; reject partial summaries/removals."""
        if re.search(r"(?m)^Remv\s", output):
            return None
        download = re.search(
            r"(?im)^Need to get\s+([0-9][0-9,]*(?:\.[0-9]+)?\s*[KMGT]?i?B)(?:/|\s+of archives)",
            output,
        )
        installed = re.search(
            r"(?im)^After this operation,\s*([0-9][0-9,]*(?:\.[0-9]+)?\s*[KMGT]?i?B)\s+of additional disk space will be used\.",
            output,
        )
        download_bytes = cls._size_bytes(download.group(1).replace(",", "")) if download else None
        installed_bytes = cls._size_bytes(installed.group(1).replace(",", "")) if installed else None
        if download_bytes is None or installed_bytes is None:
            return None
        return {
            "downloadBytes": download_bytes,
            "installedBytes": installed_bytes,
            "estimateSource": "apt-transaction-simulation",
            "estimateCompleteness": "resolved-local-package-indexes",
        }

    @staticmethod
    def _size_bytes(value: str, *, default_unit: str = "") -> int | None:
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B)?", value, re.IGNORECASE)
        if not match:
            return None
        number = float(match.group(1))
        unit = (match.group(2) or default_unit or "B").casefold()
        factors = {"b": 1, "kb": 1000, "kib": 1024, "mb": 1000**2, "mib": 1024**2,
                   "gb": 1000**3, "gib": 1024**3, "tb": 1000**4, "tib": 1024**4}
        factor = factors.get(unit)
        return int(number * factor) if factor else None

    def install_plan(self, source: SourceSpec) -> CommandPlan:
        if source.kind == "flatpak":
            return CommandPlan(
                shutil.which("flatpak") or "flatpak",
                ("--user", "install", "-y", source.remote, source.name),
                elevated=False,
                user_scope=True,
            )
        family = self.facts.package_family
        if family == "arch":
            return CommandPlan(self.facts.package_manager, ("-S", "--needed", "--noconfirm", source.name), True)
        if family == "debian":
            return CommandPlan(self.facts.package_manager, ("install", "-y", source.name), True)
        if family == "fedora":
            return CommandPlan(self.facts.package_manager, ("install", "-y", source.name), True)
        if family == "suse":
            return CommandPlan(self.facts.package_manager, ("--non-interactive", "install", source.name), True)
        if family == "rpm-ostree":
            return CommandPlan(self.facts.package_manager, ("install", "--idempotent", source.name), True)
        raise ValueError(f"provider indisponível para {source.name}")

    def remove_plan(self, source: SourceSpec) -> CommandPlan:
        if source.kind == "flatpak":
            return CommandPlan(
                shutil.which("flatpak") or "flatpak",
                ("--user", "uninstall", "-y", source.name),
                elevated=False,
                user_scope=True,
            )
        family = self.facts.package_family
        if family == "arch":
            # Remove package-owned dependencies only when pacman confirms no
            # installed package still requires them. Plain -R can leave
            # dependencies from the install transaction behind as blockers
            # for removing the primary package later.
            return CommandPlan(self.facts.package_manager, ("-Rs", "--noconfirm", source.name), True)
        if family == "debian":
            return CommandPlan(self.facts.package_manager, ("remove", "-y", source.name), True)
        if family == "fedora":
            return CommandPlan(self.facts.package_manager, ("remove", "-y", source.name), True)
        if family == "suse":
            return CommandPlan(self.facts.package_manager, ("--non-interactive", "remove", source.name), True)
        if family == "rpm-ostree":
            return CommandPlan(self.facts.package_manager, ("uninstall", source.name), True)
        raise ValueError(f"provider indisponível para {source.name}")

    def execute(self, plan: CommandPlan) -> tuple[int, str, str]:
        command = plan.command()
        if plan.elevated and os.geteuid() != 0:
            raise PermissionError("ação requer admin bridge")
        if plan.user_scope and os.geteuid() == 0:
            command = self._as_target_user(command)
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=1800, check=False,
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired as exc:
            return 124, exc.stdout or "", exc.stderr or "timeout"

    def _query(self, source: SourceSpec) -> list[str] | None:
        if source.kind == "flatpak":
            return [shutil.which("flatpak") or "flatpak", "--user", "info", source.name]
        family = self.facts.package_family
        if family == "arch":
            return ["pacman", "-Q", source.name]
        if family == "debian":
            return ["dpkg-query", "-W", "-f=${Status}", source.name]
        if family in {"fedora", "suse", "rpm-ostree"}:
            return ["rpm", "-q", source.name]
        return None

    def _available(self, source: SourceSpec) -> list[str] | None:
        family = self.facts.package_family
        if family == "arch":
            return ["pacman", "-Si", source.name]
        if family == "debian":
            return ["apt-cache", "show", source.name]
        if family == "fedora":
            return [self.facts.package_manager, "repoquery", source.name]
        if family == "suse":
            return [self.facts.package_manager, "--non-interactive", "search", "--match-exact", source.name]
        if family == "rpm-ostree":
            return ["rpm", "-q", source.name]
        return None

    @staticmethod
    def _as_target_user(command: list[str]) -> list[str]:
        user = os.environ.get("PZ_TARGET_USER") or os.environ.get("SUDO_USER") or ""
        if not user and os.environ.get("PKEXEC_UID", "").isdigit():
            try:
                user = pwd.getpwuid(int(os.environ["PKEXEC_UID"])).pw_name
            except KeyError:
                user = ""
        if not user or user == "root":
            raise PermissionError("usuário alvo ausente para operação Flatpak")
        home = pwd.getpwnam(user).pw_dir
        return [
            "runuser", "-u", user, "--", "env", f"HOME={home}",
            f"XDG_DATA_HOME={home}/.local/share", f"XDG_CONFIG_HOME={home}/.config",
            *command,
        ]
