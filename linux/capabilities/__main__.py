from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import SCHEMA
from .engine import (
    CapabilityError,
    apply_plan,
    apply_removal,
    catalog_payload,
    create_plan,
    create_removal_plan,
    profiles_payload,
    rollback_operation,
    verify_operation,
    verify_removal,
)
from .platform import detect


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pz capabilities",
        description="Recursos PhaseZero com detect/plan/apply/verify/rollback.",
    )
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("detect", help="Detecta compatibilidade do host.")
    catalog = commands.add_parser("catalog", help="Lista recursos aplicáveis.")
    catalog.add_argument("--group", default="")
    status = commands.add_parser("status", help="Lista recursos e estado instalado.")
    status.add_argument("--group", default="")
    commands.add_parser("profiles", help="Lista perfis declarativos.")
    plan = commands.add_parser("plan", help="Cria preview persistente.")
    plan.add_argument("--capability", action="append", default=[])
    plan.add_argument("--profile", action="append", default=[])
    plan.add_argument("--manifest", default="")
    apply = commands.add_parser("apply", help="Aplica plano confirmado.")
    apply.add_argument("--plan-id", required=True)
    apply.add_argument("--confirm", default="")
    apply.add_argument("--dry-run", action="store_true")
    apply.add_argument("--cancel-file", type=Path)
    verify = commands.add_parser("verify", help="Verifica uma operação.")
    verify.add_argument("--operation-id", required=True)
    rollback = commands.add_parser("rollback", help="Reverte somente itens instalados pela operação.")
    rollback.add_argument("--operation-id", required=True)
    rollback.add_argument("--confirm", default="")
    rollback.add_argument("--dry-run", action="store_true")
    # Remoção por capability: a UI tem o id do item, não o id da operação que o
    # instalou. `remove-plan` faz a ponte e continua exigindo preview + token.
    remove_plan = commands.add_parser(
        "remove-plan", help="Preview de remoção do que o PhaseZero instalou.",
    )
    remove_plan.add_argument("--capability", action="append", default=[], required=True)
    remove = commands.add_parser("remove", help="Executa um plano de remoção confirmado.")
    remove.add_argument("--plan-id", required=True)
    remove.add_argument("--confirm", default="")
    remove.add_argument("--dry-run", action="store_true")
    verify_removed = commands.add_parser(
        "verify-removal", help="Confere que as capabilities saíram do host.",
    )
    verify_removed.add_argument("--capability", action="append", default=[], required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "detect":
            payload = {"schema": SCHEMA, "host": detect().to_dict()}
        elif args.command == "catalog":
            payload = catalog_payload(group=args.group)
        elif args.command == "status":
            payload = catalog_payload(group=args.group, include_status=True)
        elif args.command == "profiles":
            payload = profiles_payload()
        elif args.command == "plan":
            payload = create_plan(
                capability_ids=args.capability,
                profile_ids=args.profile,
                manifest=args.manifest,
            )
        elif args.command == "apply":
            payload = apply_plan(
                args.plan_id, confirmation=args.confirm, dry_run=args.dry_run,
                cancel_file=args.cancel_file,
            )
        elif args.command == "verify":
            payload = verify_operation(args.operation_id)
        elif args.command == "rollback":
            payload = rollback_operation(
                args.operation_id, confirmation=args.confirm, dry_run=args.dry_run,
            )
        elif args.command == "remove-plan":
            payload = create_removal_plan(args.capability)
        elif args.command == "remove":
            payload = apply_removal(
                args.plan_id, confirmation=args.confirm, dry_run=args.dry_run,
            )
        elif args.command == "verify-removal":
            payload = verify_removal(args.capability)
        else:  # pragma: no cover - argparse protects this branch
            raise CapabilityError("comando desconhecido")
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        if args.command == "apply" and payload.get("status") == "cancelled":
            return 130
        return 0
    except (CapabilityError, FileNotFoundError, PermissionError, ValueError) as exc:
        print(json.dumps({
            "schema": SCHEMA,
            "ok": False,
            "error": str(exc),
        }, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
