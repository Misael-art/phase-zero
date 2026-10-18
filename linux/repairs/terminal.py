#!/usr/bin/env python3
"""Recover user-runtime space without restarting applications or deleting sessions."""
from __future__ import annotations
import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import tempfile
import sys
import time


def private_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError("Diretório symlink recusado")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.stat().st_uid != os.getuid():
        raise RuntimeError("Diretório pertence a outro usuário")
    path.chmod(0o700)
    return path


def atomic(path, content, mode=0o600):
    if path.is_symlink():
        raise RuntimeError("Arquivo symlink preservado: " + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text() == content:
        return
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".pz-terminal-")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fchmod(handle.fileno(), mode)
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def snapshot(path):
    result = {}
    for root, directories, files in os.walk(path, followlinks=False):
        for name in directories + files:
            item = Path(root) / name
            info = item.lstat()
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)) or info.st_uid != os.getuid() or info.st_dev != path.stat().st_dev:
                raise RuntimeError("Árvore contém objeto especial ou outro proprietário")
            result[str(item.relative_to(path))] = (info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode, os.readlink(item) if item.is_symlink() else None)
    return result


def references(base, target_uid=None):
    target_uid = os.getuid() if target_uid is None else target_uid
    active = set()
    blocked = False
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if proc.stat().st_uid != target_uid:
                continue
            for line in (proc / "maps").read_text().splitlines():
                fields = line.split(None, 5)
                if len(fields) == 6:
                    target = Path(fields[5].removesuffix(" (deleted)"))
                    if target.is_relative_to(base):
                        active.add(target.relative_to(base).parts[0])
            for entry in [proc / "cwd", *(proc / "fd").iterdir()]:
                try:
                    target = Path(os.readlink(entry))
                    if target.is_relative_to(base):
                        active.add(target.relative_to(base).parts[0])
                except (OSError, ValueError, IndexError):
                    pass
        except FileNotFoundError:
            pass
        except PermissionError:
            blocked = True
    if blocked:
        if os.getuid() == 0 or not shutil.which("phasezero-admin"):
            raise RuntimeError("Não foi possível verificar processos ativos; nenhuma limpeza permitida")
        result = subprocess.run(["phasezero-admin", sys.executable, str(Path(__file__).resolve()), "scan-references", "--uid", str(target_uid)], capture_output=True, text=True, timeout=45)
        if result.returncode:
            raise RuntimeError("Autorização de leitura de processos não concluída; fixtures preservadas")
        try:
            payload = json.loads(result.stdout)
            if payload.get("uid") != target_uid or not isinstance(payload.get("active"), list):
                raise ValueError("invalid scan")
            active.update(payload["active"])
        except (ValueError, TypeError):
            raise RuntimeError("Sondagem de processos inválida; fixtures preservadas")
    return active


def candidates(base, active, now=None):
    now = time.time() if now is None else now
    if base.is_symlink() or not base.is_dir():
        return []
    current = base / "pytest-current"
    current_name = current.resolve().name if current.is_symlink() else None
    eligible = []
    for path in base.iterdir():
        if not re.fullmatch(r"pytest-[0-9]+", path.name) or path.is_symlink() or not path.is_dir() or path.name in active or path.name == current_name:
            continue
        if path.stat().st_uid != os.getuid():
            continue
        lock = path / ".lock"
        if lock.exists() or lock.is_symlink():
            try:
                if lock.is_symlink():
                    continue
                pid = int(lock.read_text().strip())
                if pid <= 0 or Path(f"/proc/{pid}").exists():
                    continue
            except (OSError, ValueError):
                continue
        tree = snapshot(path)
        latest = max([path.stat().st_mtime, *[v[2] / 1e9 for v in tree.values()]])
        if now - latest < 3600:
            continue
        eligible.append((path, tree))
    return eligible


def status(runtime=None):
    runtime = Path(runtime or os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    usage = shutil.disk_usage(runtime)
    return {"schemaVersion": 1, "runtime": str(runtime), "freeBytes": usage.free,
            "totalBytes": usage.total, "full": usage.free < 1024 * 1024,
            "terminalInstalled": shutil.which("ashyterm") is not None,
            "reason": "runtime-full" if usage.free < 1024 * 1024 else "runtime-space-available"}


def archive(path, expected, destination):
    # Keep full originals on disk, rather than deleting retained test artifacts.
    target = destination / path.name
    if snapshot(path) != expected:
        raise RuntimeError("Fixture mudou; preservada")
    shutil.copytree(path, target, symlinks=True, copy_function=shutil.copy2)
    if snapshot(path) != expected:
        raise RuntimeError("Fixture mudou durante cópia; origem preservada")
    for relative, values in expected.items():
        source = path / relative
        copied = target / relative
        if stat.S_ISREG(values[3]):
            import hashlib
            def digest(file):
                value = hashlib.sha256()
                with file.open("rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        value.update(chunk)
                return value.digest()
            if copied.is_symlink() or digest(source) != digest(copied):
                raise RuntimeError("Cópia não verificada; origem preservada")
            with copied.open("rb") as durable:
                os.fsync(durable.fileno())
    if snapshot(path) != expected or path.name in references(path.parent):
        raise RuntimeError("Fixture mudou ou está em uso; origem preservada")
    for root, _, _ in os.walk(target, topdown=False):
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    shutil.rmtree(path)


def configure(home, temporary, backup):
    temporary = private_dir(temporary)
    pytest = private_dir(temporary / "pytest")
    targets = [home / name for name in (".bashrc", ".bash_profile", ".profile", ".zshrc") if (home / name).is_file()]
    marker_a = "# >>> PhaseZero agent temporary storage >>>"
    marker_b = "# <<< PhaseZero agent temporary storage <<<"
    for index, path in enumerate(targets):
        raw = path.read_text()
        cleaned = re.sub(r"(?ms)^" + re.escape(marker_a) + r"\n.*?^" + re.escape(marker_b) + r"\n?", "", raw).rstrip("\n")
        block = marker_a + '\nexport TMPDIR="$HOME/.cache/phasezero/agent-tmp"\nexport PYTEST_DEBUG_TEMPROOT="$TMPDIR/pytest"\n' + marker_b + "\n"
        desired = cleaned + "\n\n" + block
        if raw != desired:
            shutil.copy2(path, backup / (str(index) + "-" + path.name))
            atomic(path, desired, stat.S_IMODE(path.stat().st_mode))
    environment = home / ".config/environment.d/70-phasezero-agent-tmp.conf"
    if environment.exists():
        shutil.copy2(environment, backup / "70-phasezero-agent-tmp.conf")
    atomic(environment, 'TMPDIR=${HOME}/.cache/phasezero/agent-tmp\nPYTEST_DEBUG_TEMPROOT=${HOME}/.cache/phasezero/agent-tmp/pytest\n')
    result = subprocess.run(["systemctl", "--user", "set-environment", f"TMPDIR={temporary}", f"PYTEST_DEBUG_TEMPROOT={pytest}"], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError("Falhou configuração do ambiente para novas aplicações")


def repair():
    home = Path.home()
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
    if runtime.is_symlink() or runtime.stat().st_uid != os.getuid():
        raise RuntimeError("Runtime inválido")
    base = runtime / "codex-desktop/tmp" / ("pytest-of-" + pwd.getpwuid(os.getuid()).pw_name)
    for parent in (runtime / "codex-desktop", runtime / "codex-desktop/tmp"):
        if parent.is_symlink():
            raise RuntimeError("Origem symlink recusada")
    store = private_dir(home / ".local/state/phasezero/terminal-repair")
    if store.stat().st_dev == runtime.stat().st_dev:
        raise RuntimeError("Backup precisa ficar em disco, fora do runtime cheio")
    private_dir(home / ".cache/phasezero/agent-tmp")
    if (home / ".cache/phasezero/agent-tmp").stat().st_dev == runtime.stat().st_dev:
        raise RuntimeError("Novos temporários precisam ficar fora do runtime da sessão")
    with (store / "repair.lock").open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        backup = private_dir(store / (time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}"))
        before = status(runtime)
        preliminary = candidates(base, set()) if base.is_dir() else []
        selected = candidates(base, references(base)) if preliminary else []
        for path, tree in selected:
            archive(path, tree, backup)
        configure(home, home / ".cache/phasezero/agent-tmp", backup)
        # No daemon restart, reset-failed, D-Bus activation or terminal session kill.
        with tempfile.TemporaryFile(dir=runtime) as probe:
            probe.write(b"phasezero-runtime-probe")
            probe.flush()
        after = status(runtime)
        if after["freeBytes"] < 1024 * 1024:
            raise RuntimeError("Runtime ainda sem espaço; fixtures ativas/ambíguas preservadas")
        result = {"ok": True, "before": before, "after": after, "archived": len(selected),
                  "backup": str(backup), "restartRequired": False,
                  "nextStep": "Abra novamente o terminal. Agentes já abertos preservam ambiente antigo; use TMPDIR/PYTEST_DEBUG_TEMPROOT em disco nos próximos testes."}
        atomic(backup / "result.json", json.dumps(result, indent=2))
        return result


def install():
    home = Path.home()
    directory = private_dir(home / ".local/share/phasezero/repairs")
    target = directory / "terminal.py"
    atomic(target, Path(__file__).read_text(), 0o700)
    import shlex
    wrapper = home / ".local/bin/reparo-terminal.sh"
    if wrapper.is_file() and "PhaseZero managed terminal repair" not in wrapper.read_text():
        raise RuntimeError("Wrapper não gerenciado preservado")
    atomic(wrapper, "#!/usr/bin/env bash\n# PhaseZero managed terminal repair\nexec python3 " + shlex.quote(str(target)) + ' repair --confirm "$@"\n', 0o700)
    result = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True, text=True, timeout=10) if shutil.which("xdg-user-dir") else None
    desktop = Path(result.stdout.strip()) if result and result.returncode == 0 and result.stdout.strip() else home / "Desktop"
    if not desktop.is_absolute() or desktop == home:
        raise RuntimeError("Área de trabalho inválida")
    for folder in (home / ".local/share/applications", desktop):
        path = folder / "phasezero-reparo-terminal.desktop"
        if path.is_file() and "X-PhaseZero-Managed=true" not in path.read_text():
            raise RuntimeError("Atalho não gerenciado preservado")
        content = '[Desktop Entry]\nType=Application\nName=Reparar terminal e sessão\nComment=Libera temporários inativos com backup; preserva aplicações abertas\nExec="' + str(wrapper) + '"\nIcon=utilities-terminal\nTerminal=false\nCategories=System;\nX-PhaseZero-Managed=true\n'
        atomic(path, content, 0o755)
    return {"installed": True, "wrapper": str(wrapper), "automaticRepair": False}


def main():
    parser = argparse.ArgumentParser(description="Reparo seguro do runtime da sessão e terminal")
    parser.add_argument("action", choices=("status", "repair", "install", "scan-references"), default="status", nargs="?")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--uid", type=int)
    args = parser.parse_args()
    try:
        if args.action == "scan-references":
            if os.getuid() != 0 or args.uid is None or args.uid <= 0:
                raise RuntimeError("Sondagem administrativa exige UID explícito")
            base = Path(f"/run/user/{args.uid}/codex-desktop/tmp/pytest-of-{pwd.getpwuid(args.uid).pw_name}")
            print(json.dumps({"uid": args.uid, "active": sorted(references(base, args.uid))}))
            return 0
        if os.getuid() == 0:
            raise RuntimeError("Reparo deve executar como usuário da sessão")
        if args.action == "repair" and not args.yes:
            if not args.confirm or not shutil.which("kdialog"):
                raise RuntimeError("Use --confirm (gráfico) ou --yes para arquivar fixtures inativas e configurar novos temporários em disco")
            if subprocess.run(["kdialog", "--yesno", "Arquivar fixtures de testes inativas com backup e direcionar novos temporários para disco? Aplicações abertas serão preservadas."], check=False).returncode:
                return 1
        result = status() if args.action == "status" else install() if args.action == "install" else repair()
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if args.action == "repair" and args.confirm and shutil.which("kdialog"):
            subprocess.run(["kdialog", "--passivepopup", "Runtime recuperado. Abra novamente o terminal. Agentes já abertos precisam usar temporários em disco nos próximos testes.", "10"], check=False)
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        if args.confirm and shutil.which("kdialog"):
            subprocess.run(["kdialog", "--error", "Reparo não concluído: " + str(error)], check=False)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
