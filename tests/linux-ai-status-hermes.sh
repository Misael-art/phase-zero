#!/usr/bin/env bash
# Regressão: `pz ai status` quebrava quando o Hermes estava instalado sem
# nenhum bloco MCP gerenciado. `grep -c` imprime a contagem E sai com 1 quando
# ela é zero, então o ramo `|| echo 0` imprimia um segundo zero e o
# `--argjson` recebia "0\n0" — JSON inválido, comando inteiro fora do ar.
#
# O CI nunca pegou porque runner limpo não tem ~/.hermes/config.yaml: sem o
# arquivo, o teste `[ -f ]` falha e o `echo 0` é a única saída.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Um export por variável: HOME precisa existir antes de ser usado nas demais.
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME/.hermes"

fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq ausente"; exit 0; }

status_json() {
    local out
    out="$("$REPO_ROOT/linux/pz" ai status 2>/dev/null)" || fail "pz ai status saiu $?"
    printf '%s' "$out"
}

# --- config do Hermes presente e sem bloco MCP: o caso que quebrava ---------
printf 'agent:\n  name: hermes\n' > "$HOME/.hermes/config.yaml"
out="$(status_json)"
jq -e '.schemaVersion == 1' <<< "$out" >/dev/null || fail "envelope sem schemaVersion"
jq -e '.agentConfigs.hermes.exists == true' <<< "$out" >/dev/null \
    || fail "config do Hermes existe mas não foi reportada"
jq -e '.agentConfigs.hermes.mcpServerCount == 0' <<< "$out" >/dev/null \
    || fail "contagem deveria ser 0: $(jq -c '.agentConfigs.hermes' <<< "$out")"

# --- com blocos gerenciados: conta de verdade -------------------------------
printf 'agent:\n  name: hermes\n  # BEGIN PHASEZERO MCP um\n  # BEGIN PHASEZERO MCP dois\n' \
    > "$HOME/.hermes/config.yaml"
out="$(status_json)"
jq -e '.agentConfigs.hermes.mcpServerCount == 2' <<< "$out" >/dev/null \
    || fail "deveria contar 2 blocos: $(jq -c '.agentConfigs.hermes' <<< "$out")"

# --- sem config nenhuma ----------------------------------------------------
rm -rf "$HOME/.hermes"
out="$(status_json)"
jq -e '.agentConfigs.hermes.exists == false and .agentConfigs.hermes.mcpServerCount == 0' <<< "$out" >/dev/null \
    || fail "sem config, exists=false e contagem 0"

echo "PASS: linux-ai-status-hermes"
