"""Guarda transversal do contrato de status (fase 4 das jornadas).

Todo comando de leitura referenciado no catálogo da Central precisa se comportar
como relatório, nunca como falha de ferramenta:

- exit code 0 mesmo quando o recurso não está pronto/configurado;
- stdout com envelope JSON objeto (state/ok/ready…).

Um comando de status que quebre isso recria a classe de bug do Homelab
("diagnóstico indisponível", PR #67/#68). Exclusões são por nome, com motivo.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from linux.ui_native.result_parser import parse_json_output  # noqa: E402

TIMEOUT_S = 90

# Nome da ação -> motivo (hardware interativo, parâmetros obrigatórios, etc).
# Nunca exclua por "está falhando": conserte o comando.
EXCLUDED: dict[str, str] = {
    # doctor é verificador de saúde por design: falha (rc!=0) é o contrato
    # quando há checks reprovados — classe intencional, como `verify`.
    "system.doctor.system": "verificador intencional (falha = achado)",
    # CCS-043: via `pz` o comando sai vazio/travado fora do desktop; direto no
    # script funciona. Investigar o wrapper antes de vigiar aqui.
    "emulation.shortcuts.status": "wrapper pz trava/vazio — CCS-043",
}


def _is_status_action(entry: dict) -> bool:
    name = str(entry.get("name", ""))
    command = str(entry.get("command", ""))
    if entry.get("mutable"):
        return False
    if "{" in command:  # requer parâmetros do operador
        return False
    if name in {"system.doctor.system", "system.doctor.full"}:
        return True
    tail = name.rsplit(".", 1)[-1]
    return tail == "status" or command.rstrip().endswith("status --json")


def _status_actions() -> list[tuple[str, str]]:
    raw = json.loads((ROOT / "linux" / "ui" / "actions.json").read_text())
    catalog: list = raw.get("actions", []) if isinstance(raw, dict) else raw
    found: dict[str, str] = {}
    for entry in catalog:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name", ""))
        if not name or name in EXCLUDED or not _is_status_action(entry):
            continue
        found[name] = str(entry["command"])
    return sorted(found.items())


def test_catalog_has_status_actions_to_guard() -> None:
    # A guarda só faz sentido se o catálogo continuar expondo diagnósticos.
    assert len(_status_actions()) >= 5


@pytest.mark.parametrize(
    "name,command",
    _status_actions(),
    ids=[name for name, _ in _status_actions()],
)
def test_status_command_always_reports(name: str, command: str) -> None:
    proc = subprocess.run(
        ["bash", *command.split()],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=TIMEOUT_S,
        check=False,
    )
    assert proc.returncode == 0, (
        f"{name} saiu {proc.returncode}: diagnóstico válido não pode falhar.\n"
        f"stderr: {proc.stderr.strip()[:300]}"
    )
    # Comandos que prometem máquina (--json) precisam de envelope objeto;
    # modo texto humano basta ser não-vazio (a UI formata).
    if "--json" in command:
        parsed = parse_json_output(proc.stdout)
        assert isinstance(parsed, dict) and parsed, (
            f"{name} (--json) não emitiu envelope JSON em stdout."
        )
    else:
        assert proc.stdout.strip() or proc.stderr.strip(), (
            f"{name} não produziu relatório algum."
        )
