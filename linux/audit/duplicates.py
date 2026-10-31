#!/usr/bin/env python3
"""Duplicate app scanner: one app, one install, unless the user says otherwise.

PhaseZero keeps the host under central, friendly management. Two copies of
the same tool (e.g. OpenCode from npm, from the upstream curl installer and a
desktop-pinned CLI) drift apart in version, share state, and leave the user
guessing which one runs. By default a duplicate is a conflict that must be
resolved before an installer proceeds; keeping one is a conscious choice
recorded in an allow list with a reason.

Commands:
  scan [--all] [--json]          report duplicates (exit 1 on unacknowledged)
  gate <app> [--resolve]         fail unless <app> has no unacknowledged duplicate
  resolve <app> [--keep PATH] [--dry-run]   quarantine extra user-owned copies
  allow <app> --reason TEXT      accept a duplicate consciously
  disallow <app>                 drop that acceptance
  restore <manifest>             undo a resolve
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

# Apps PhaseZero installs or wires; scanned by default. `--all` widens the
# scan to every executable on PATH.
WATCHLIST = (
    "opencode", "codex", "claude", "gemini", "qwen", "crush", "aider", "goose",
    "cursor-agent", "hermes", "ollama", "openclaw", "ai-memory", "rtk",
    "node", "npm", "npx", "pnpm", "bun", "deno", "uv", "uvx", "gh",
    "code", "cursor", "windsurf", "zed", "codium", "9router",
)

# Flatpak app id -> command name its native package would install.
FLATPAK_ALIASES = {
    "com.visualstudio.code": "code",
    "com.vscodium.codium": "codium",
    "dev.zed.Zed": "zed",
    "com.discordapp.Discord": "discord",
    "com.spotify.Client": "spotify",
    "com.valvesoftware.Steam": "steam",
    "com.obsproject.Studio": "obs",
    "org.mozilla.firefox": "firefox",
    "com.google.Chrome": "google-chrome-stable",
    "com.brave.Browser": "brave",
    "org.videolan.VLC": "vlc",
    "com.heroicgameslauncher.hgl": "heroic",
    "org.libretro.RetroArch": "retroarch",
}


def home() -> Path:
    return Path(os.environ.get("HOME", str(Path.home()))).expanduser().absolute()


def state_root() -> Path:
    data = Path(os.environ.get("XDG_DATA_HOME", home() / ".local/share"))
    return Path(os.environ.get("PZ_STATE", data / "phasezero"))


def allow_file() -> Path:
    config = Path(os.environ.get("XDG_CONFIG_HOME", home() / ".config"))
    return Path(os.environ.get("PZ_DUPLICATES_ALLOW", config / "phasezero/duplicates-allow.json"))


def search_dirs() -> list[Path]:
    """PATH plus the well-known side-install locations that upstream
    installers drop binaries into without touching PATH order."""
    h = home()
    extra = [
        h / ".local/bin", h / ".npm-global/bin", h / ".local/share/npm/bin", h / ".bun/bin", h / ".deno/bin",
        h / ".cargo/bin", h / ".volta/bin", h / ".opencode/bin", h / ".claude/local",
        h / "go/bin", "/usr/local/bin", "/usr/bin", "/opt/bin",
    ]
    seen: list[Path] = []
    for raw in [*os.environ.get("PATH", "").split(os.pathsep), *map(str, extra)]:
        if not raw:
            continue
        path = Path(raw).expanduser()
        if path not in seen and path.is_dir():
            seen.append(path)
    return seen


def path_dirs() -> list[Path]:
    return [Path(p).expanduser() for p in os.environ.get("PATH", "").split(os.pathsep) if p]


def classify(real: Path) -> dict[str, Any]:
    """Who owns this copy, and how it can be removed."""
    text = str(real)
    h = str(home())
    if "/node_modules/" in text and text.startswith(h):
        root = text.split("/node_modules/", 1)[1].split("/")
        package = "/".join(root[:2]) if root[0].startswith("@") else root[0]
        prefix = text.split("/lib/node_modules/", 1)[0] if "/lib/node_modules/" in text else None
        return {"channel": "npm", "package": package, "prefix": prefix, "userOwned": True}
    if text.startswith("/var/lib/flatpak") or "/.local/share/flatpak/" in text:
        return {"channel": "flatpak", "userOwned": text.startswith(h)}
    if "/ai.opencode.desktop/cli/" in text:
        # Shipped inside an app; its owner updates and removes it.
        return {"channel": "app-bundled", "userOwned": False}
    if text.startswith(h):
        channel = "upstream-installer" if "/." in text[len(h):] else "user"
        return {"channel": channel, "userOwned": True}
    owner = None
    if shutil.which("pacman"):
        proc = subprocess.run(["pacman", "-Qoq", text], capture_output=True, text=True, check=False)
        owner = proc.stdout.strip() or None
    elif shutil.which("dpkg"):
        proc = subprocess.run(["dpkg", "-S", text], capture_output=True, text=True, check=False)
        owner = proc.stdout.split(":", 1)[0].strip() or None
    return {"channel": "system-package" if owner else "system", "package": owner, "userOwned": False}


SHIM_MAX_BYTES = 8192
SHELLS = (b"#!/bin/sh", b"#!/bin/bash", b"#!/usr/bin/env bash", b"#!/usr/bin/env sh", b"#!/usr/bin/sh", b"#!/usr/bin/bash")


def shim_targets(path: Path) -> list[str] | None:
    """A small shell launcher that execs something else is a wrapper around
    an install, not an install of its own. Returns the absolute paths it
    execs, or None when the file is not a shim."""
    try:
        if path.stat().st_size > SHIM_MAX_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if not data.startswith(SHELLS):
        return None
    targets = []
    for line in data.decode("utf-8", "replace").splitlines():
        words = line.strip().split()
        if "exec" in words:
            after = words[words.index("exec") + 1:]
            targets += [w.strip('"\'') for w in after[:1] if w.strip('"\'').startswith("/")]
    return targets


def version_of(path: Path) -> str | None:
    try:
        proc = subprocess.run(
            [str(path), "--version"], capture_output=True, text=True, timeout=5, check=False,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    line = proc.stdout.strip().splitlines()
    return line[0][:80] if line else None


BROKEN_SHIMS: list[dict[str, Any]] = []


def collect(names: set[str] | None) -> dict[str, list[dict[str, Any]]]:
    BROKEN_SHIMS.clear()
    found: dict[str, dict[str, dict[str, Any]]] = {}
    path_order = path_dirs()
    for directory in search_dirs():
        try:
            entries = list(directory.iterdir())
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if names is not None and name not in names:
                continue
            if not (entry.is_file() and os.access(entry, os.X_OK)):
                continue
            real = entry.resolve()
            targets = shim_targets(real)
            if targets is not None:
                missing = [t for t in targets if not Path(t).exists()]
                if missing:
                    BROKEN_SHIMS.append({"app": name, "path": str(entry), "missingTargets": missing})
                continue
            copies = found.setdefault(name, {})
            key = str(real)
            if key not in copies:
                copies[key] = {"real": key, "entries": [], "onPath": False}
            copies[key]["entries"].append(str(entry))
            if directory in path_order:
                copies[key]["onPath"] = True
    flatpaks = flatpak_apps()
    for app_id, command in FLATPAK_ALIASES.items():
        if app_id in flatpaks and (names is None or command in names) and command in found:
            found[command][f"flatpak:{app_id}"] = {
                "real": f"flatpak:{app_id}", "entries": [], "onPath": False,
                "flatpak": app_id,
            }
    result: dict[str, list[dict[str, Any]]] = {}
    for name, copies in found.items():
        if len(copies) < 2:
            continue
        rows = []
        for copy in copies.values():
            if "flatpak" in copy:
                copy.update(channel="flatpak", userOwned=False, version=None)
            else:
                real = Path(copy["real"])
                copy.update(classify(real))
                copy["version"] = version_of(real)
            rows.append(copy)
        if not distinct_installs(rows):
            continue
        active = shutil.which(name)
        active_real = str(Path(active).resolve()) if active else None
        for row in rows:
            row["active"] = row["real"] == active_real
        result[name] = sorted(rows, key=lambda r: (not r["active"], r["real"]))
    return result


def distinct_installs(rows: list[dict[str, Any]]) -> bool:
    """Hard links or byte-identical copies of the same file in /usr/bin and
    /bin (merged-usr) are one install, not a duplicate."""
    digests = set()
    for row in rows:
        if "flatpak" in row:
            return True
        if row["channel"] in {"system-package", "system"} and row["real"].startswith(("/usr/bin/", "/bin/")):
            try:
                digests.add(hashlib.sha256(Path(row["real"]).read_bytes()).hexdigest())
                continue
            except OSError:
                pass
        digests.add(row["real"])
    return len(digests) > 1


def flatpak_apps() -> set[str]:
    if not shutil.which("flatpak"):
        return set()
    proc = subprocess.run(
        ["flatpak", "list", "--app", "--columns=application"],
        capture_output=True, text=True, check=False, timeout=30,
    )
    return {line.strip() for line in proc.stdout.splitlines() if line.strip()}


def load_allow() -> dict[str, Any]:
    try:
        value = json.loads(allow_file().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def save_allow(value: dict[str, Any]) -> None:
    path = allow_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def scan(all_apps: bool = False, only: str | None = None) -> dict[str, Any]:
    names = None if all_apps else ({only} if only else set(WATCHLIST))
    duplicates = collect(names)
    allowed = load_allow()
    conflicts = []
    for name, copies in sorted(duplicates.items()):
        accepted = allowed.get(name)
        conflicts.append({
            "app": name,
            "copies": copies,
            "acknowledged": bool(accepted),
            "reason": accepted.get("reason") if isinstance(accepted, dict) else None,
            "suggestion": suggest(name, copies),
        })
    blocking = [c["app"] for c in conflicts if not c["acknowledged"]]
    broken = [dict(item) for item in BROKEN_SHIMS]
    return {
        "schemaVersion": SCHEMA_VERSION,
        "tool": "duplicates",
        "ok": not blocking,
        "status": "clean" if not conflicts else ("conflict" if blocking else "acknowledged"),
        "blocking": blocking,
        "duplicates": conflicts,
        "brokenShims": broken,
        "allowFile": str(allow_file()),
    }


def suggest(name: str, copies: list[dict[str, Any]]) -> list[str]:
    keep = next((c for c in copies if c.get("active")), copies[0])
    tips = [f"manter: {keep['real']} (versão {keep.get('version') or '?'})"]
    for copy in copies:
        if copy is keep:
            continue
        if copy.get("flatpak"):
            tips.append(f"remover flatpak: flatpak uninstall {copy['flatpak']}")
        elif copy["channel"] == "npm" and copy.get("package"):
            prefix = f" --prefix {copy['prefix']}" if copy.get("prefix") else ""
            tips.append(f"remover npm: npm uninstall -g {copy['package']}{prefix}")
        elif copy["channel"] == "system-package" and copy.get("package"):
            tips.append(f"remover pacote do sistema: {copy['package']} (via gerenciador de pacotes)")
        elif copy.get("userOwned"):
            tips.append(f"quarentena reversível: pz host duplicates resolve {name}")
        else:
            tips.append(f"remover manualmente: {copy['real']}")
    tips.append(f"ou aceitar conscientemente: pz host duplicates allow {name} --reason '...'")
    return tips


def resolve(name: str, keep: str | None = None, dry_run: bool = False) -> dict[str, Any]:
    """Quarantine every user-owned copy except the kept one. Copies owned by a
    package manager are reported, never touched: their manager must remove
    them or the next upgrade puts them back."""
    copies = collect({name}).get(name, [])
    if not copies:
        return {"schemaVersion": SCHEMA_VERSION, "ok": True, "app": name, "changed": False, "moved": []}
    keep_real = str(Path(keep).expanduser().resolve()) if keep else next(
        (c["real"] for c in copies if c.get("active")), copies[0]["real"]
    )
    if keep_real not in {c["real"] for c in copies}:
        raise RuntimeError(f"--keep não é uma cópia conhecida de {name}: {keep_real}")
    planned, manual = [], []
    for copy in copies:
        if copy["real"] == keep_real:
            continue
        if copy.get("userOwned") and copy["channel"] in {"upstream-installer", "user"}:
            planned.extend(copy["entries"] or [copy["real"]])
            if copy["real"] not in copy["entries"]:
                planned.append(copy["real"])
        elif copy["channel"] == "npm" and copy.get("userOwned") and copy.get("package"):
            planned.append(f"npm:{copy.get('prefix') or ''}:{copy['package']}")
        else:
            manual.extend(suggest(name, [next(c for c in copies if c["real"] == keep_real), copy])[1:2])
    result: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION, "app": name, "keep": keep_real, "dryRun": dry_run,
        "planned": planned, "manual": manual, "moved": [], "manifest": None,
    }
    if dry_run or not planned:
        result.update(ok=not manual or dry_run, changed=False)
        return result
    stamp = time.strftime("%Y%m%d-%H%M%S")
    quarantine = state_root() / "quarantine" / f"{stamp}-{name}"
    quarantine.mkdir(parents=True, exist_ok=True)
    moved = []
    for item in planned:
        if item.startswith("npm:"):
            prefix, package = item[4:].split(":", 1)
            command = ["npm", "uninstall", "-g", package] + (["--prefix", prefix] if prefix else [])
            proc = subprocess.run(command, capture_output=True, text=True, check=False)
            # npm removals are not reversible from quarantine; record how to reinstall.
            moved.append({"npm": package, "prefix": prefix, "ok": proc.returncode == 0})
            continue
        source = Path(item)
        if not (source.exists() or source.is_symlink()):
            continue
        target = quarantine / f"{len(moved):02d}-{source.name}"
        shutil.move(str(source), str(target))
        moved.append({"from": str(source), "to": str(target)})
    manifest = quarantine / "manifest.json"
    manifest.write_text(json.dumps({"app": name, "keep": keep_real, "moved": moved}, indent=2) + "\n", encoding="utf-8")
    after = scan(only=name)
    result.update(
        moved=moved, manifest=str(manifest), changed=True,
        ok=not manual and all(m.get("ok", True) for m in moved),
        remaining=after["duplicates"],
    )
    return result


def restore(manifest_path: str) -> dict[str, Any]:
    manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    restored = []
    for item in manifest.get("moved", []):
        if "from" not in item:
            continue
        source, target = Path(item["to"]), Path(item["from"])
        if source.exists() and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(target))
            restored.append(str(target))
    return {"schemaVersion": SCHEMA_VERSION, "ok": True, "restored": restored}


def render(result: dict[str, Any]) -> str:
    lines = [
        f"[LANÇADOR QUEBRADO] {item['path']} aponta para inexistente: {', '.join(item['missingTargets'])}"
        for item in result.get("brokenShims", [])
    ]
    if result["status"] == "clean":
        lines.append("Nenhuma duplicidade de app encontrada.")
        return "\n".join(lines)
    for item in result["duplicates"]:
        flag = "aceita" if item["acknowledged"] else "CONFLITO"
        lines.append(f"[{flag}] {item['app']}: {len(item['copies'])} instalações")
        for copy in item["copies"]:
            mark = "*" if copy.get("active") else " "
            lines.append(f"  {mark} {copy['real']}  [{copy['channel']}] {copy.get('version') or ''}".rstrip())
        if item["acknowledged"]:
            lines.append(f"    motivo: {item['reason']}")
        else:
            lines.extend(f"    - {tip}" for tip in item["suggestion"])
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pz host duplicates")
    sub = parser.add_subparsers(dest="command")
    p_scan = sub.add_parser("scan")
    p_scan.add_argument("--all", action="store_true")
    p_scan.add_argument("--json", action="store_true")
    p_gate = sub.add_parser("gate")
    p_gate.add_argument("app")
    p_gate.add_argument("--resolve", action="store_true")
    p_resolve = sub.add_parser("resolve")
    p_resolve.add_argument("app")
    p_resolve.add_argument("--keep")
    p_resolve.add_argument("--dry-run", action="store_true")
    p_allow = sub.add_parser("allow")
    p_allow.add_argument("app")
    p_allow.add_argument("--reason", required=True)
    p_disallow = sub.add_parser("disallow")
    p_disallow.add_argument("app")
    p_restore = sub.add_parser("restore")
    p_restore.add_argument("manifest")
    args = parser.parse_args(argv)
    command = args.command or "scan"
    try:
        if command == "scan":
            result = scan(getattr(args, "all", False))
            print(json.dumps(result, indent=2) if getattr(args, "json", False) else render(result))
            return 0 if result["ok"] else 1
        if command == "gate":
            result = scan(only=args.app)
            if not result["ok"] and args.resolve:
                resolved = resolve(args.app)
                result = scan(only=args.app)
                result["resolved"] = resolved
            if not result["ok"]:
                print(render(result), file=sys.stderr)
                print(
                    f"{args.app}: duplicidade não aceita; resolva antes de continuar "
                    f"(pz host duplicates resolve {args.app}) ou aceite conscientemente "
                    f"(pz host duplicates allow {args.app} --reason '...').",
                    file=sys.stderr,
                )
                return 1
            return 0
        if command == "resolve":
            result = resolve(args.app, args.keep, args.dry_run)
        elif command == "allow":
            value = load_allow()
            value[args.app] = {"reason": args.reason, "since": time.strftime("%Y-%m-%d")}
            save_allow(value)
            result = {"schemaVersion": SCHEMA_VERSION, "ok": True, "app": args.app, "allowed": True}
        elif command == "disallow":
            value = load_allow()
            value.pop(args.app, None)
            save_allow(value)
            result = {"schemaVersion": SCHEMA_VERSION, "ok": True, "app": args.app, "allowed": False}
        else:
            result = restore(args.manifest)
        print(json.dumps(result, indent=2))
        return 0 if result.get("ok", True) else 1
    except (RuntimeError, OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"schemaVersion": SCHEMA_VERSION, "ok": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
