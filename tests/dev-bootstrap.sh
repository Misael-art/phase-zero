#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
export PZ_DEV_HOME="$TEMP/phasezero-dev"

plan="$(bash "$ROOT/tools/dev-bootstrap.sh" plan --profile core)"
[[ "$plan" == *"venv: $PZ_DEV_HOME/venv-core"* ]]
[[ "$plan" == *'No product install, service, VM, login or boot change.'* ]]
[[ ! -e "$PZ_DEV_HOME" ]]

if bash "$ROOT/tools/dev-bootstrap.sh" install --profile core >"$TEMP/install.out" 2>&1; then
    echo 'install mutated without --yes' >&2; exit 1
fi
[[ ! -e "$PZ_DEV_HOME" ]]

if bash "$ROOT/tools/dev-bootstrap.sh" doctor --profile core >"$TEMP/doctor.out" 2>&1; then
    echo 'doctor reported ready without venv' >&2; exit 1
fi
rg -q 'Python environment missing or incomplete' "$TEMP/doctor.out"

if bash "$ROOT/tools/dev-bootstrap.sh" plan --profile invalid >"$TEMP/invalid.out" 2>&1; then
    echo 'invalid profile accepted' >&2; exit 1
fi
echo 'dev-bootstrap preflight contracts passed'
