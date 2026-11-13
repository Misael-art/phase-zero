#!/usr/bin/env python3
"""Package the canonical memory owner for native Windows; no credentials/state."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    "bootstrap-tools.ps1", "windows/pz.ps1", "version.json", "LICENSE",
    "assets/agent-skills/token-economy.json",
)
TREES = ("windows/ai", "linux/ai", "linux/lib", "assets/ai", "packaging/ai-memory")


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(destination: Path, packages: Path | None = None, model_cache: Path | None = None):
    if destination.exists():
        raise ValueError("Destination exists; preserve the installed runtime.")
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    files = [name for name in tracked if name in FILES or any(name.startswith(tree + "/") for tree in TREES)]
    if packages:
        pins = json.loads((ROOT / "packaging/ai-memory/pins.json").read_text())
        core = packages / pins["assets"]["windows-x86_64"]["name"]
        if sha(core) != pins["assets"]["windows-x86_64"]["sha256"]:
            raise ValueError("Native release hash differs")
        manifest = json.loads((packages / "wikisync-package.json").read_text(encoding="utf-8-sig"))
        if (manifest["version"] != pins["version"] or manifest["sourceSha256"] != pins["source"]["sha256"]
                or sha(packages / "ai-memory-wikisync.exe") != manifest["sha256"]):
            raise ValueError("Companion provenance/hash differs")
    pins = json.loads((ROOT / "packaging/ai-memory/pins.json").read_text())
    if model_cache:
        if not packages:
            raise ValueError("A prepared model cache needs the native packages")
        for name, checksum in pins["localModel"]["files"].items():
            if sha(model_cache / pins["localModel"]["directory"] / name) != checksum:
                raise ValueError("Local model checksum differs from the upstream pin")
    destination.mkdir(parents=True)
    for name in files:
        source, target = ROOT / name, destination / name
        if source.is_symlink():
            raise ValueError("Symlink in runtime")
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        if source.suffix == ".ps1":
            data = b"\xef\xbb\xbf" + data.removeprefix(b"\xef\xbb\xbf")
        target.write_bytes(data)
    (destination / "INICIAR.cmd").write_text(
        '@echo off\r\npowershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0windows\\ai\\prepare-host.ps1"\r\n', encoding="ascii")
    (destination / "LEIA-ME.txt").write_text(
        "PhaseZero - Codex Desktop, Claude Code e ai-memory no Windows\n\n"
        "Abra INICIAR.cmd dentro do Windows, na sua conta normal.\n"
        "1. Instalar/reparar memoria: Python 3.13, GnuPG e GitHub CLI se ausentes; "
        "release ai-memory verificada e auxiliar precompilado. Uma operacao por vez.\n"
        "2. Instale Codex Desktop e Claude Code pelos instaladores oficiais. "
        "Downloads acima de 70 MB ficam manuais, salvo autorizacao expressa.\n"
        "3. Entre no GitHub pelo navegador. Contas Codex e Claude exigem login proprio no Windows.\n"
        "4. Memoria: importe primeiro a chave de recuperacao .gpg com sua senha local. "
        "Depois verifique o backup, revise o plano e restaure. Nenhum restore ocorre por anexar o cartao.\n"
        "5. Confira os projetos recebidos. Cadastre o destino GitHub privado existente, "
        "valide sua identidade/privacidade e escolha a pasta real do projeto neste Windows. "
        "Use Sincronizar e so entao ative a automacao pela janela Memoria.\n\n"
        "O servidor e unico, em 127.0.0.1:49374, com task BootstrapTools-AiMemoryServer. "
        "Os agentes compartilham MCP e hooks nativos; suas contas e tokens nao sao copiados do Linux. "
        "Caminhos, hostId e referencias do cofre sao gerados neste Windows.\n"
        "Dependencias de aplicativos e projetos verifica runtimes e permite instalar/reparar a selecao.\n"
        "Use o Windows em execucao no cartao. Registros ficam em logs do PhaseZero da conta.\n"
        "Git for Windows habilita os recursos de Git dos aplicativos; instale pelo fluxo oficial se necessario.\n"
        "PROTOCOLO.md acompanha o procedimento canonico. A preparacao offline nao comprova instalacao/login no Windows.\n",
        encoding="utf-8-sig")
    shutil.copyfile(ROOT / "docs/roadmaps/ai-memory-portability-v1.md", destination / "PROTOCOLO.md")
    if packages:
        (destination / "packages").mkdir()
        for name in (core.name, "ai-memory-wikisync.exe", "wikisync-package.json"):
            shutil.copyfile(packages / name, destination / "packages" / name)
        if (packages / "ChatGPTInstaller.exe").is_file():
            shutil.copyfile(packages / "ChatGPTInstaller.exe", destination / "packages/ChatGPTInstaller.exe")
        if model_cache:
            relative = Path("models") / pins["localModel"]["directory"]
            (destination / "packages" / relative).mkdir(parents=True)
            for name in pins["localModel"]["files"]:
                shutil.copyfile(model_cache / pins["localModel"]["directory"] / name, destination / "packages" / relative / name)
    manifest = {"schemaVersion": 1, "product": "PhaseZero Windows memory runtime",
                "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(),
                "files": {p.relative_to(destination).as_posix(): {"size": p.stat().st_size, "sha256": sha(p)}
                          for p in sorted(destination.rglob("*")) if p.is_file()}}
    (destination / "runtime-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"files": len(manifest["files"]), "bytes": sum(p["size"] for p in manifest["files"].values()),
            "sourceCommit": manifest["sourceCommit"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--packages", type=Path)
    parser.add_argument("--model-cache", type=Path)
    args = parser.parse_args()
    print(json.dumps(build(args.output, args.packages, args.model_cache)))
