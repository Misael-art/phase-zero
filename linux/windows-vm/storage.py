#!/usr/bin/env python3
"""Read-only WinVM storage accounting and offline integrity observations.

No repair, conversion, guest boot, mount on the host, or automatic deletion.
Completion metadata is evidence about a worker, never proof of Windows health.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
from datetime import datetime, timezone


def signature(path: Path) -> tuple:
    st = path.stat()
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


def disk_size(path: Path) -> dict:
    try:
        if path.is_symlink() or not path.is_file():
            return {"available": False}
        st = path.stat()
        with path.open("rb") as stream:
            header = stream.read(32)
        qcow = len(header) == 32 and header[:4] == b"QFI\xfb"
        return {"available": True, "allocatedBytes": st.st_blocks * 512,
                "fileBytes": st.st_size, "format": "qcow2" if qcow else "unknown",
                "virtualBytes": struct.unpack(">Q", header[24:32])[0] if qcow else None}
    except OSError:
        return {"available": False}


def accounting(entry: dict) -> dict:
    root = Path(entry["vmDir"])
    parts = {"baseBytes": 0, "snapshotBytes": 0, "mediaBytes": 0, "otherBytes": 0}
    seen = set()
    complete = True

    def walk(directory: Path) -> None:
        nonlocal complete
        try:
            with os.scandir(directory) as children:
                for child in children:
                    st = child.stat(follow_symlinks=False)
                    identity = (st.st_dev, st.st_ino)
                    if identity in seen:
                        continue
                    seen.add(identity)
                    name = child.name
                    key = ("baseBytes" if name == "disk.qcow2" else
                           "snapshotBytes" if name.endswith(".qcow2") else
                           "mediaBytes" if name.endswith(".iso") or name == "oemdrv" else
                           "otherBytes")
                    parts[key] += st.st_blocks * 512
                    if child.is_dir(follow_symlinks=False):
                        walk(Path(child.path))
        except OSError:
            complete = False

    if root.is_dir() and not root.is_symlink():
        walk(root)
    else:
        complete = False
    base = disk_size(root / "disk.qcow2")
    adopted = disk_size(Path(entry["adoptedDisk"])) if entry.get("adoptedDisk") else {}
    return {**parts, "accountingComplete": complete,
            "stagingAllocatedBytes": sum(parts.values()),
            "virtualBytes": base.get("virtualBytes"), "format": base.get("format"),
            "adoptedDisk": adopted,
            "policy": "QCOW2 cresce conforme gravações; capacidade virtual não é reserva física.",
            "note": "Snapshots retêm blocos antigos; apagar arquivos no Windows não garante devolução ao host."}


def run(args: list[str], *, timeout: int = 30, script: str | None = None) -> subprocess.CompletedProcess:
    # Child processes have bounded lifetime. Never inherit a caller's stdin.
    with subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, start_new_session=True) as proc:
        try:
            stdout, stderr = proc.communicate(script or "", timeout=timeout)
        except subprocess.TimeoutExpired:
            # Reclaim only this probe's process group, including a libguestfs appliance.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.communicate()
            raise
        return subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)


def live_qemu() -> bool:
    """Conservative host-wide gate: a running guest can share a backing image."""
    for proc in Path("/proc").glob("[0-9]*"):
        try:
            comm = (proc / "comm").read_text().strip()
            if comm.startswith("qemu-system") or comm in {"qemu-kvm", "kvm"}:
                return True
        except (OSError, ProcessLookupError):
            continue
    return False


WINDOWS_FILES = (
    "/Windows/System32/config/SYSTEM",
    "/Windows/System32/config/SOFTWARE",
    "/Windows/System32/ntoskrnl.exe",
    "/Windows/System32/winload.efi",
)


def guest_files(path: Path) -> dict:
    if not shutil.which("guestfish"):
        return {"state": "unavailable", "reason": "Instale libguestfs/guestfish para verificar arquivos do Windows."}
    # --ro mounts inside the libguestfs appliance only. Windows never executes.
    script = "\n".join("is-file " + name for name in WINDOWS_FILES) + "\n"
    result = run(["guestfish", "--ro", "--format=qcow2", "-a", str(path), "-i"],
                 timeout=180, script=script)
    values = result.stdout.splitlines()
    if result.returncode or len(values) != len(WINDOWS_FILES) or any(v not in {"true", "false"} for v in values):
        return {"state": "unknown", "reason": "Não foi possível inspecionar Windows em modo somente leitura; pode haver volume cifrado, sujo ou appliance indisponível."}
    missing = [name for name, value in zip(WINDOWS_FILES, values) if value == "false"]
    return {"state": "missing-files" if missing else "present", "missingFiles": missing,
            "reason": "Arquivos essenciais ausentes." if missing else "Arquivos essenciais presentes; inicialização e saúde do Windows não foram testadas."}


def integrity(entry: dict, *, inspect_guest: bool = False) -> dict:
    observed = datetime.now(timezone.utc).isoformat()
    result = {"schemaVersion": 1, "operation": "windows-vm-integrity", "id": entry["id"],
              "observedAt": observed, "source": "qemu-img check (sem reparo) + guestfish --ro quando solicitado",
              "completionRecorded": entry.get("state") == "completed",
              "bootVerified": False, "storage": accounting(entry), "images": [], "findings": []}

    def finish(state: str, message: str, step: str) -> dict:
        result.update(state=state, message=message, nextStep=step)
        return result

    if entry.get("running") or entry.get("workerAlive") or live_qemu():
        return finish("busy", "Verificação bloqueada: VM em execução.", "Desligue as VMs normalmente e tente novamente.")
    if not shutil.which("qemu-img"):
        return finish("unavailable", "Verificador QCOW2 indisponível.", "Instale qemu-img e tente novamente.")
    root = Path(entry["vmDir"]).resolve()
    images = [root / "disk.qcow2", root / "golden-clean.qcow2"]
    if entry.get("adoptedDisk"):
        images.append(Path(entry["adoptedDisk"]))
    elif entry.get("state") != "completed" and not images[1].exists():
        images.pop()
    before = {}
    bad = False
    unknown = False
    try:
        for path in images:
            item = {"path": str(path), **disk_size(path)}
            result["images"].append(item)
            if not item["available"]:
                item["state"] = "missing"
                bad = True
                continue
            if item["format"] != "qcow2":
                item["state"] = "invalid-format"
                bad = True
                continue
            before[path] = signature(path)
            info_run = run(["qemu-img", "info", "-f", "qcow2", "--output=json", str(path)])
            if info_run.returncode:
                item["state"] = "unreadable"
                unknown = True
                continue
            info = json.loads(info_run.stdout)
            if not isinstance(info, dict):
                raise ValueError("qemu-img info returned a non-object")
            backing = info.get("full-backing-filename") or info.get("backing-filename")
            if backing:
                backing_path = Path(backing)
                if not backing_path.is_absolute():
                    backing_path = path.parent / backing_path
                # Only the canonical, local base is supported. No arbitrary chains/protocols.
                if backing_path != root / "disk.qcow2" or backing_path.is_symlink() or not backing_path.is_file():
                    item["state"] = "invalid-backing"
                    bad = True
                    continue
            checked = run(["qemu-img", "check", "-f", "qcow2", "--output=json", str(path)], timeout=90)
            item["checkExitCode"] = checked.returncode
            item["state"] = {0: "clean", 2: "corrupt", 3: "leaked-clusters"}.get(checked.returncode, "unknown")
            bad |= checked.returncode in {2, 3}
            unknown |= checked.returncode not in {0, 2, 3}
        if inspect_guest and not bad and not unknown:
            # Inspect the operational image, not the earlier installation base.
            target = images[-1] if len(images) > 1 else images[0]
            result["windowsFiles"] = {"imagePath": str(target), **guest_files(target)}
            bad |= result["windowsFiles"]["state"] == "missing-files"
            unknown |= result["windowsFiles"]["state"] != "present"
        else:
            result["windowsFiles"] = {"state": "not-checked"}
        if live_qemu() or any(signature(path) != stamp for path, stamp in before.items()):
            return finish("changed", "Disco mudou durante a verificação; resultado inconclusivo.", "Desligue as VMs e repita a verificação.")
    except subprocess.TimeoutExpired:
        return finish("timeout", "Tempo de verificação esgotado; arquivos preservados.", "Tente novamente sem outras VMs em execução.")
    except (OSError, ValueError, TypeError):
        return finish("unknown", "Não foi possível concluir a verificação; arquivos preservados.", "Confira permissões, dependências e disponibilidade do disco.")
    result["findings"] = [{"image": Path(item["path"]).name, "state": item["state"]}
                          for item in result["images"] if item["state"] != "clean"]
    if bad:
        result["reason"] = ("Disco ausente, formato inválido, cadeia de snapshot quebrada ou erro QCOW2."
                            if result["findings"] else "Arquivos essenciais do Windows ausentes.")
        return finish("issues", "Problema encontrado na instalação.", "Confira os detalhes. Recupere um backup ou escolha mover a instalação para a lixeira; nada foi apagado.")
    if unknown:
        result["reason"] = result.get("windowsFiles", {}).get("reason", "Falha de leitura, lock ou recurso não suportado; corrupção não comprovada.")
        return finish("unknown", "Verificação inconclusiva; arquivos preservados.", "Confira os detalhes e dependências. Não descarte uma instalação somente por este resultado.")
    if not result["completionRecorded"]:
        return finish("incomplete", "Instalação não concluída pelo instalador.", "Retome a instalação ou mova seus arquivos para a lixeira após revisar o diagnóstico.")
    return finish("checked" if inspect_guest else "structure-checked",
                  "Estrutura e arquivos essenciais verificados." if inspect_guest else "Estrutura QCOW2 verificada; Windows ainda não inspecionado.",
                  "Boot e funcionamento do Windows exigem teste no convidado; integridade completa não comprovada.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("inventory", "check"))
    parser.add_argument("--operation-id")
    parser.add_argument("--guest-files", action="store_true")
    args = parser.parse_args()
    payload = json.load(sys.stdin)
    if args.mode == "inventory":
        for entry in payload["instances"]:
            entry["storage"] = accounting(entry)
            entry["integrity"] = {"state": "not-checked", "message": "Integridade ainda não verificada."}
    else:
        entries = [entry for entry in payload["instances"] if entry["id"] == args.operation_id]
        if len(entries) != 1:
            print(json.dumps({"schemaVersion": 1, "state": "unavailable", "message": "Instalação não encontrada no inventário; atualize a lista."}))
            return 1
        payload = integrity(entries[0], inspect_guest=args.guest_files)
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
