"""CLI pública do motor de temas.

stdout JSON puro; logs e erros em stderr. Exit codes:
- 0 sucesso
- 2 erro de negócio (token, bloqueio, desconhecido)
- 3 estado KDE ilegível / registro corrompido
"""

from __future__ import annotations

import argparse
import json
import sys

from . import SCHEMA
from .engine import (
    ThemesError,
    apply_plan,
    catalog_payload,
    create_plan,
    history_payload,
    preview_plan,
    rescue_wallpaper,
    rollback_snapshot,
    status_payload,
    verify_operation,
)
from .kde import KdeStateError
from .state import ThemesLockTimeout


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pz themes",
        description="Temas e acessibilidade do Plasma com plan/apply/verify/rollback.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    status = commands.add_parser("status", help="Estado efetivo da sessão.")
    status.add_argument("--json", action="store_true", help="Saída JSON (padrão).")

    commands.add_parser("catalog", help="Catálogo avaliado (features, wallpapers, extensões).")

    plan = commands.add_parser("plan", help="Cria plano persistente com snapshot.")
    plan.add_argument("--profile", default="")
    plan.add_argument("--feature", default="")
    plan.add_argument("--state", default="", dest="feature_state", help="on ou off")
    plan.add_argument("--wallpaper", default="")
    plan.add_argument("--screen", default="")
    plan.add_argument("--target", default="desktop")
    plan.add_argument(
        "--param",
        action="append",
        default=[],
        metavar="CHAVE=VALOR",
        help="Parâmetro da feature; repita para vários (ex.: --param color=#4f7cc9).",
    )

    preview = commands.add_parser("preview", help="Pré-visualiza wallpaper (15 s).")
    preview.add_argument("--plan-id", required=True)
    preview.add_argument("--confirm", default="")

    apply = commands.add_parser("apply", help="Aplica plano confirmado.")
    apply.add_argument("--plan-id", required=True)
    apply.add_argument("--confirm", default="")

    verify = commands.add_parser("verify", help="Verifica uma operação.")
    verify.add_argument("--operation-id", required=True)

    rollback = commands.add_parser("rollback", help="Restaura snapshot (id ou latest).")
    rollback.add_argument("--snapshot", default="latest")

    commands.add_parser("rescue-wallpaper", help="Restaura wallpaper estático após crash.")

    history = commands.add_parser("history", help="Histórico de operações.")
    history.add_argument("--limit", type=int, default=15)

    return parser


def _parse_params(items: list[str]) -> dict:
    """CHAVE=VALOR pairs. A malformed one is rejected rather than ignored, so a
    typo cannot silently fall back to a default the user did not ask for."""
    params: dict[str, str] = {}
    for item in items or ():
        key, sep, value = str(item).partition("=")
        key = key.strip()
        if not sep or not key:
            raise ThemesError(f"--param espera CHAVE=VALOR, recebido: {item!r}")
        params[key] = value.strip()
    return params


def _emit(payload: dict) -> int:
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    # A failed apply used to exit 0 because only the JSON carried the verdict.
    # Every caller that checks the exit status - the UI runner, shell scripts,
    # CI - was told the theme had been applied while the engine had already
    # rolled it back.
    #
    # Only an operation that failed counts. A plan answering ok=false did its
    # job: it is reporting that the feature cannot be applied here, which is
    # the result, not a failure of the command. Payloads WITHOUT blockers -
    # verify, rescue-wallpaper - carry ok as the verdict itself and used to
    # exit 0 even when ok was false.
    if payload.get("status") == "failed":
        return 1
    results = payload.get("results")
    if isinstance(results, list) and any(
        isinstance(r, dict) and r.get("status") == "failed" for r in results
    ):
        return 1
    if payload.get("ok") is False and "blockers" not in payload:
        return 1
    return 0


def _fail(schema: str, message: str, code: int) -> int:
    print(json.dumps({"schema": schema, "ok": False, "error": message}, ensure_ascii=False), file=sys.stderr)
    return code


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "status":
            return _emit(status_payload())
        if args.command == "catalog":
            return _emit(catalog_payload())
        if args.command == "plan":
            return _emit(
                create_plan(
                    profile=args.profile,
                    feature=args.feature,
                    feature_state_target=args.feature_state,
                    wallpaper=args.wallpaper,
                    screen=args.screen,
                    wallpaper_target=args.target,
                    feature_params=_parse_params(args.param),
                )
            )
        if args.command == "preview":
            return _emit(preview_plan(args.plan_id, confirmation=args.confirm))
        if args.command == "apply":
            return _emit(apply_plan(args.plan_id, confirmation=args.confirm))
        if args.command == "verify":
            return _emit(verify_operation(args.operation_id))
        if args.command == "rollback":
            return _emit(rollback_snapshot(args.snapshot))
        if args.command == "rescue-wallpaper":
            return _emit(rescue_wallpaper())
        if args.command == "history":
            return _emit(history_payload(limit=args.limit))
        return _fail(SCHEMA, "comando desconhecido", 2)  # pragma: no cover
    except ThemesError as exc:
        return _fail(SCHEMA, str(exc), 2)
    except ThemesLockTimeout as exc:
        return _fail(SCHEMA, str(exc), 2)
    except KdeStateError as exc:
        return _fail(SCHEMA, str(exc), 3)
    except (ValueError, FileNotFoundError, PermissionError) as exc:
        return _fail(SCHEMA, str(exc), 3)


if __name__ == "__main__":
    raise SystemExit(main())
