#!/usr/bin/env bash
# Fast system scope powers UI overview without repeating every subsystem audit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
set +e
output="$(PZ_DOCTOR_SCOPE=system timeout 15 bash "$REPO_ROOT/linux/audit/doctor.sh")"
rc=$?
set -e

grep -q '=== System Info ===' <<< "$output"
grep -q '=== Services ===' <<< "$output"
grep -q '=== Summary ===' <<< "$output"
grep -q 'Results JSON:' <<< "$output"
grep -q '=== Steam Deck ===' <<< "$output" && exit 1
jq -e 'type == "array" and length >= 10' <<< "$(sed -n '/^Results JSON:$/,$p' <<< "$output" | tail -n +2)" >/dev/null
if grep -q '\[FAIL\]\|\[ERROR\]' <<< "$output"; then
    test "$rc" -ne 0
else
    test "$rc" -eq 0
fi

# CCS-016: host fresco sem subsystems.conf → subsystemas opcionais viram
# INFO, não uma parede de WARN.
fresh_home="$(mktemp -d)"
set +e
fresh_out="$(XDG_CONFIG_HOME="$fresh_home/.config" HOME="$fresh_home" PZ_DOCTOR_SCOPE=full timeout 120 bash "$REPO_ROOT/linux/audit/doctor.sh")"
rc=$?
set -e
rm -rf "$fresh_home"
grep -q '\[INFO\] WAYDROID00' <<< "$fresh_out" || {
    echo "FAIL: sem conf, o Waydroid deveria ser INFO (nunca optado)"
    exit 1
}
waydroid_warns="$(grep -c '^\[WARN\] WAYDROID' <<< "$fresh_out" || true)"
test "$waydroid_warns" -eq 0 || { echo "FAIL: $waydroid_warns WARN de Waydroid em host sem conf"; exit 1; }
# pz doctor --scope system roda o mesmo recorte
scoped="$("$REPO_ROOT/linux/pz" doctor --scope system 2>/dev/null | grep -c '=== Steam Deck ===' || true)"
test "$scoped" -eq 0 || { echo "FAIL: --scope system vazou seções além de system"; exit 1; }

echo "linux-doctor smoke ok"

echo "=== doctor completa mesmo com muitos registros de operação (SIGPIPE) ==="
# Regressão de host real: `ls -t "$dir" | head -1` sob `set -euo pipefail`
# fazia o doctor morrer com 141 no meio do relatório. Com o diretório cheio,
# o run tem de chegar ao fim e avaliar os checks que vinham depois.
big_state="$TMP/bigstate"
mkdir -p "$big_state/phasezero/operations/op-20260101-000000-1"
printf '{"graphicsResolved":{"profile":"compat"}}\n' \
    > "$big_state/phasezero/operations/op-20260101-000000-1/operation.json"
for i in $(seq 1 800); do : > "$big_state/phasezero/operations/legacy-$i.json"; done
doc_json="$(XDG_STATE_HOME="$big_state" PZ_DOCTOR_TIMEOUT=600 \
    bash "$REPO_ROOT/linux/pz" doctor --json 2>/dev/null)"
echo "$doc_json" | jq -e '.schemaVersion == 1 and .tool == "doctor"
    and (.checks | length) > 100
    and (.summary.total == (.checks | length))' >/dev/null \
    || { echo "FAIL: doctor --json não devolveu envelope completo"; exit 1; }
# Os checks que vinham DEPOIS do ponto de morte precisam existir.
echo "$doc_json" | jq -e '[.checks[].id] | index("WINVM11") != null' >/dev/null \
    || { echo "FAIL: doctor parou antes dos checks finais"; exit 1; }
echo "  doctor completa com diretório cheio ok"

echo "=== doctor --json é contrato de máquina, não relatório humano ==="
# Sem pipe: `printf | head` e `printf | grep -q` levam SIGPIPE quando o leitor
# sai antes, e sob `set -euo pipefail` isso derruba a suíte — o mesmo defeito
# que este arquivo existe para impedir no produto. Expansão do bash não tem
# leitor para fechar o cano.
doc_first_line="${doc_json%%$'\n'*}"
case "$doc_first_line" in
    "{"*) ;;
    *)
        echo "FAIL: --json não emitiu objeto na primeira linha; começo real:"
        printf '%s\n' "$doc_first_line"
        exit 1
        ;;
esac
case "$doc_json" in
    *"=== System Info ==="*)
        echo "FAIL: relatório humano vazou para dentro do JSON"; exit 1 ;;
esac
XDG_STATE_HOME="$big_state" bash "$REPO_ROOT/linux/pz" doctor --json >/dev/null 2>&1 \
    || { echo "FAIL: comando de status deve sair 0 mesmo com FAIL nos checks"; exit 1; }
# Flag desconhecida não pode ser ignorada em silêncio.
if bash "$REPO_ROOT/linux/pz" doctor --nao-existe >/dev/null 2>&1; then
    echo "FAIL: flag desconhecida aceita em silêncio"; exit 1
fi
echo "  doctor --json ok"

echo "=== doctor avisa quando o estado local passa do limite ==="
echo "$doc_json" | jq -e '[.checks[]|select(.id=="STATE01")]|first
    | .status == "WARN" and (.detail | test("installation prune"))' >/dev/null \
    || { echo "FAIL: acúmulo de registros não reportado"; exit 1; }
echo "  poda de estado sinalizada ok"
