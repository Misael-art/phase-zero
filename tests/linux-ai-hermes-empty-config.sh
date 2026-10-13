#!/usr/bin/env bash
# AICR-033: `hermes config check` accepts an empty config.yaml, so status said
# configured/configCheckOk true while ~/.hermes/config.yaml had 0 bytes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_LOCAL_BIN="$WORK/bin"
mkdir -p "$HOME/.hermes" "$XDG_CONFIG_HOME/phasezero" "$PZ_LOCAL_BIN"

# Stub hermes: every subcommand succeeds, like upstream `config check` on an empty file.
# shellcheck disable=SC2016 # Emit literal $1 into the stub.
printf '#!/bin/sh\n[ "$1" = --version ] && echo "Hermes Agent v0.0.0"\nexit 0\n' > "$PZ_LOCAL_BIN/hermes"
chmod +x "$PZ_LOCAL_BIN/hermes"
export PATH="$PZ_LOCAL_BIN:$PATH"
install -m 600 /dev/null "$XDG_CONFIG_HOME/phasezero/hermes.env"

install -m 600 /dev/null "$HOME/.hermes/config.yaml"
out="$("$ROOT/linux/ai/setup-hermes.sh" status)"
jq -e '.configCheckOk == false and .configured == false and .ready == false' <<< "$out" >/dev/null \
    || { echo "FAIL: empty config reported as ok: $(jq -c '{configured,configCheckOk,ready}' <<< "$out")" >&2; exit 1; }

printf 'model:\n  default: x\n' > "$HOME/.hermes/config.yaml"
out="$("$ROOT/linux/ai/setup-hermes.sh" status)"
jq -e '.configCheckOk == true' <<< "$out" >/dev/null || { echo "FAIL: non-empty config not checked" >&2; exit 1; }

echo "PASS: empty Hermes config is not reported as checked"
