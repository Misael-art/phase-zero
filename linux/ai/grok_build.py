"""Linux integration for the official Grok Build CLI."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.error import URLError
from urllib.request import Request, urlopen


APP_ID = "app.grok-build"
DOWNLOAD_LIMIT = 70_000_000
BASE_URL = "https://x.ai/cli"
# Reviewed Linux x64 artifact. Its size and MD5 matched upstream's HTTPS
# object metadata when its SHA-256 was measured. Refresh together.
PIN = {
    "version": "1.0.77",
    "size": 201655392,
    "sha256": "b702950aa5827d855e493278ab6215a4e0f5bceb5bba6c6243a9f55cdd143b0a",
    "url": f"{BASE_URL}/grok-1.0.77-linux-x86_64",
}
STABLE_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
CLI_VERSION = re.compile(
    r"grok ([0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?)(?: \([^\n]+\))?(?: \[[a-z]+\])?"
)


class GrokError(Exception):
    pass


def find_grok() -> Path | None:
    home = Path.home()
    for candidate in (shutil.which("grok"), home / ".local/bin/grok", home / ".grok/bin/grok"):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            # Keep the launcher path. Resolving it here would freeze a live
            # symlink to an obsolete artifact after an upstream update.
            return Path(candidate).absolute()
    return None


def official_environment() -> dict[str, str]:
    env = os.environ.copy()
    for name in ("XAI_API_KEY", "GROK_DEPLOYMENT_KEY"):
        env.pop(name, None)
    return env


def run_grok(executable: Path, *args: str, timeout: int = 10) -> str:
    try:
        result = subprocess.run(
            [str(executable), "--no-auto-update", *args], env=official_environment(),
            cwd=Path.home(), stdin=subprocess.DEVNULL, capture_output=True,
            text=True, errors="replace", check=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        raise GrokError("A verificação do executável Grok falhou.") from None
    return result.stdout.strip()


def version(executable: Path) -> str:
    match = CLI_VERSION.fullmatch(run_grok(executable, "--version"))
    if match is None:
        raise GrokError("O executável encontrado não reportou uma versão do Grok Build.")
    return match[1]


def status() -> dict:
    executable = find_grok()
    return {
        "installed": executable is not None, "version": version(executable) if executable else "",
        "executable": str(executable) if executable else "",
        "installationState": "present" if executable else "missing",
        "accountState": "unknown", "quota": "unknown",
        "supportedInstall": platform.system() == "Linux" and platform.machine() == "x86_64",
        **({"artifact": PIN} if executable is None else {}),
    }


def check() -> dict:
    local = status()
    if not local["installed"]:
        return local | {"updateAvailable": None}
    try:
        upstream = json.loads(run_grok(Path(local["executable"]), "update", "--check", "--json"))
    except (ValueError, GrokError):
        raise GrokError("Não foi possível consultar o atualizador oficial. Tente novamente.") from None
    if (not isinstance(upstream, dict) or upstream.get("error")
            or type(upstream.get("updateAvailable")) is not bool
            or upstream.get("currentVersion") != local["version"]
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?",
                                str(upstream.get("latestVersion", "")))):
        raise GrokError("O atualizador oficial retornou um estado inconclusivo.")
    return local | {key: upstream[key] for key in ("latestVersion", "updateAvailable")} | {
        "channel": upstream.get("channel") if upstream.get("channel") in {"stable", "alpha", "enterprise"} else "unknown",
    }


def artifact_plan() -> dict:
    local = status()
    return local | {
        "artifact": PIN, "downloadMode": "manual", "mutatesHost": False,
        "reason": "Use o binário oficial baixado manualmente e selecione o arquivo na Central de Controle.",
    }


def install(artifact: Path) -> dict:
    if find_grok():
        return status() | {"state": "already-installed"}
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise GrokError("A instalação validada pelo PhaseZero exige Linux x86_64.")
    home = Path.home()
    upstream_bin = home / ".grok/bin"
    downloads = home / ".grok/downloads"
    local_bin = home / ".local/bin"
    for directory in (upstream_bin, downloads, local_bin):
        directory.mkdir(parents=True, exist_ok=True)
    with (downloads / ".phasezero-install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if find_grok():
            return status() | {"state": "already-installed"}
        launcher = upstream_bin / "grok"
        entry = local_bin / "grok"
        target = downloads / f"grok-{PIN['version']}-linux-x86_64"
        if any(path.exists() or path.is_symlink() for path in (launcher, entry, target)):
            raise GrokError("Há arquivos de uma instalação anterior. Revise os caminhos do Grok antes de instalar.")
        fd, temporary = tempfile.mkstemp(prefix=".phasezero-grok-", dir=downloads)
        stage = Path(temporary)
        try:
            with os.fdopen(fd, "wb") as destination:
                # O_NONBLOCK prevents a FIFO from hanging before the type check.
                source_fd = os.open(artifact, os.O_RDONLY | os.O_NONBLOCK)
                with os.fdopen(source_fd, "rb") as source:
                    metadata = os.fstat(source.fileno())
                    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != PIN["size"]:
                        raise GrokError("O arquivo deve ser o binário oficial com o tamanho esperado.")
                    digest = hashlib.sha256()
                    remaining = PIN["size"]
                    while remaining:
                        block = source.read(min(remaining, 1024 * 1024))
                        if not block:
                            break
                        destination.write(block)
                        digest.update(block)
                        remaining -= len(block)
                    if remaining or source.read(1) or digest.hexdigest() != PIN["sha256"]:
                        raise GrokError("SHA-256 divergente. Baixe o binário oficial novamente.")
            stage.chmod(0o755)
            if version(stage) != PIN["version"]:
                raise GrokError("O binário verificado não iniciou na versão esperada.")
            # link() fails if another installer occupied the target meanwhile.
            target.hardlink_to(stage)
            created = [target]
            try:
                launcher.symlink_to(Path("..") / "downloads" / target.name)
                created.append(launcher)
                entry.symlink_to(launcher)
            except OSError:
                for path in reversed(created):
                    path.unlink()
                raise
        finally:
            stage.unlink(missing_ok=True)
    return status() | {"state": "installed"}


def update_plan() -> dict:
    details = check()
    if not details["updateAvailable"]:
        return details | {"downloadMode": "none", "mutatesHost": False}
    candidate = details["latestVersion"]
    if (details["channel"] != "stable" or not STABLE_VERSION.fullmatch(candidate)
            or platform.system() != "Linux" or platform.machine() != "x86_64"):
        return details | {"downloadMode": "manual", "mutatesHost": False}
    url = f"{BASE_URL}/grok-{candidate}-linux-x86_64"
    try:
        with urlopen(Request(url, method="HEAD"), timeout=8) as response:
            size = int(response.headers.get("Content-Length", "0"))
    except (OSError, ValueError, URLError):
        size = 0
    return details | {
        "downloadMode": "upstream" if 0 < size <= DOWNLOAD_LIMIT else "manual",
        "artifact": {"url": url, "version": candidate, "size": size},
        "mutatesHost": False,
    }


def update() -> dict:
    plan = update_plan()
    if not plan["installed"]:
        raise GrokError("Instale o Grok Build antes de atualizar.")
    if not plan["updateAvailable"]:
        return plan | {"state": "current"}
    if plan["downloadMode"] != "upstream":
        return plan | {
            "ok": False, "state": "manual-download-required",
            "reason": "Execute a atualização oficial manualmente no terminal e volte a verificar a versão.",
        }
    executable = Path(plan["executable"])
    run_grok(executable, "update", "--version", plan["latestVersion"], timeout=300)
    updated = status()
    if updated["version"] != plan["latestVersion"]:
        raise GrokError("O atualizador terminou sem confirmar a versão esperada.")
    return updated | {"state": "updated"}


def launch(command: str, workspace: Path | None = None) -> dict:
    executable = find_grok()
    if executable is None:
        raise GrokError("Instale o Grok Build antes de abrir.")
    if workspace is not None and not workspace.is_dir():
        raise GrokError("Escolha uma pasta de projeto existente.")
    cwd = workspace.resolve() if workspace is not None else Path.home()
    args = [str(executable), "--no-auto-update"]
    if command == "login":
        args.append("login")
    if os.isatty(0) and os.isatty(1):
        os.chdir(cwd)
        os.execve(executable, args, official_environment())
    for name, options in (("xdg-terminal-exec", ()), ("konsole", ("--separate", "-e")),
                          ("gnome-terminal", ("--",)), ("xterm", ("-e",))):
        terminal = shutil.which(name)
        if terminal:
            subprocess.Popen(
                [terminal, *options, *args], cwd=cwd, env=official_environment(),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return {"state": "terminal-requested"}
    raise GrokError("Terminal gráfico indisponível. Execute o comando em um terminal.")


def main() -> int:
    parser = argparse.ArgumentParser(prog="pz ai grok-build")
    parser.add_argument("action", choices=("status", "check", "plan", "install", "update-plan", "update", "open", "login"),
                        default="status", nargs="?")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--workspace", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "install":
            if args.artifact is None:
                raise GrokError("Selecione o binário oficial baixado com --artifact.")
            payload = install(args.artifact)
        elif args.action in {"open", "login"}:
            if args.action == "open" and args.workspace is None:
                raise GrokError("Escolha a pasta do projeto com --workspace.")
            payload = launch(args.action, args.workspace)
        else:
            payload = {
                "status": status, "check": check, "plan": artifact_plan,
                "update-plan": update_plan, "update": update,
            }[args.action]()
        result = {"ok": True, **payload}
    except GrokError as exc:
        result = {"ok": False, "state": "blocked", "reason": str(exc)}
    except OSError:
        result = {"ok": False, "state": "blocked", "reason": "Falha ao acessar o arquivo ou iniciar o terminal."}
    print(json.dumps({"schemaVersion": 1, "appId": APP_ID, "command": args.action, **result}))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
