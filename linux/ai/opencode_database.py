"""Consistent, bounded OpenCode backup before changing CLI versions."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from linux.lib.pz_hostbackup import backup_dir_for, ledger_record


def backup_database(path: Path) -> Path | None:
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise ValueError("Banco OpenCode precisa ser arquivo regular")
    if not shutil.which("fuser"):
        raise ValueError("fuser necessário para verificar banco em uso")
    owners = subprocess.run(["fuser", str(path), str(path) + "-wal"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    if owners.returncode != 1:
        raise ValueError("Feche OpenCode antes de alinhar versões; banco preservado")
    directory = backup_dir_for(path)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    target = directory / f"{path.name}.bak.{time.time_ns()}"
    # Exclusive locking persists after COMMIT until this connection closes.
    # Checkpoint then clone under that lock: copying the main DB alone while
    # an active WAL exists would silently discard committed conversations.
    connection = sqlite3.connect(path, timeout=2)
    try:
        connection.execute("PRAGMA cache_size=-4096")
        connection.execute("PRAGMA locking_mode=EXCLUSIVE")
        connection.execute("BEGIN EXCLUSIVE")
        connection.commit()
        result = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if result[0]:
            raise ValueError("Banco ocupado; backup não confirmado")
        # Never overwrite the old adjacent backup or fall back to a multi-GB
        # physical copy during an automatic repair. Unsupported filesystems
        # need a separately planned backup rather than an unbounded retry.
        subprocess.run(["cp", "--reflink=always", "--preserve=mode,timestamps", "--",
                        str(path), str(target)], check=True, capture_output=True, timeout=20)
        os.chmod(target, 0o600)
        if target.stat().st_size != path.stat().st_size:
            raise ValueError("Tamanho do backup divergiu")
        (directory / "origin").write_text(str(path.absolute()) + "\n", encoding="utf-8")
    except Exception:
        target.unlink(missing_ok=True)
        raise
    finally:
        connection.close()
    ledger_record(module="opencode", action="backup", modified=[str(path)],
                  backups=[str(target)], reversible=True,
                  rollback_cmd="Restaurar backup central somente com OpenCode fechado")
    return target


if __name__ == "__main__":
    try:
        result = backup_database(Path(sys.argv[1]))
        if result:
            print(result)
    except Exception:
        sys.stderr.write("Backup OpenCode não confirmado: feche app e verifique suporte a reflink; alinhamento interrompido.\n")
        raise SystemExit(1)
