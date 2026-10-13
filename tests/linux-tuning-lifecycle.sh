#!/usr/bin/env bash
# Smoke tests for the tuning apply/revert/status contract.
# shellcheck disable=SC2030,SC2031 # pz commands run in intentionally isolated subshell envs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Um export por variável: HOME precisa estar definido antes de ser usado nas
# demais, caso contrário as variáveis XDG apontam para o home real.
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
# Sem admin bridge no PATH: as mutações root viram no-op anunciado em vez de
# escreverem em /etc durante o teste. O contrato user-scope continua exercido.
export PATH="$TMP_ROOT/bin:/usr/bin:/bin"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$PZ_LOCAL_BIN" "$TMP_ROOT/bin"
# O host de CI/dev pode ter pkexec e amigos no PATH padrão; stubs que falham
# rápido mantêm o teste offline, silencioso e sem tocar em /etc.
for stub in phasezero-admin bigsudo sudo pkexec; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/bin/$stub"
    chmod +x "$TMP_ROOT/bin/$stub"
done

PZ="$REPO_ROOT/linux/pz"
STATE_DIR="$XDG_STATE_HOME/phasezero/tuning"
MANGOHUD="$XDG_CONFIG_HOME/MangoHud/MangoHud.conf"
CORECTRL="$XDG_CONFIG_HOME/corectrl/corectrl.conf"

fail() { echo "FAIL: $1"; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq ausente"; exit 0; }

# --- status antes de qualquer aplicação -----------------------------------
out="$("$PZ" tune gaming status)"
jq -e '.applied == false and .drift == false and (.files | length) == 0' <<< "$out" >/dev/null \
    || fail "status inicial deveria ser applied=false sem arquivos: $out"

# --- dry-run não escreve nada ---------------------------------------------
"$PZ" tune gaming apply --dry-run >/dev/null
[ ! -f "$MANGOHUD" ] || fail "dry-run escreveu $MANGOHUD"
[ ! -f "$STATE_DIR/gaming.json" ] || fail "dry-run gravou estado"

# --- apply escreve arquivos de usuário e grava estado ---------------------
"$PZ" tune gaming apply >/dev/null
[ -f "$MANGOHUD" ] || fail "apply não escreveu $MANGOHUD"
[ -f "$CORECTRL" ] || fail "apply não escreveu $CORECTRL"
[ -f "$STATE_DIR/gaming.json" ] || fail "apply não gravou estado"

out="$("$PZ" tune gaming status)"
jq -e '.applied == true and .drift == false' <<< "$out" >/dev/null \
    || fail "status após apply deveria ser applied=true sem drift: $out"
jq -e '[.files[] | select(.path | endswith("MangoHud.conf"))] | length == 1' <<< "$out" >/dev/null \
    || fail "status não lista MangoHud.conf: $out"

# --- edição externa vira drift, não silêncio ------------------------------
printf '\n# editado pelo usuário\n' >> "$MANGOHUD"
out="$("$PZ" tune gaming status)"
jq -e '.applied == true and .drift == true' <<< "$out" >/dev/null \
    || fail "arquivo editado por fora deveria marcar drift: $out"
jq -e '[.files[] | select((.path | endswith("MangoHud.conf")) and .managed == false)] | length == 1' <<< "$out" >/dev/null \
    || fail "MangoHud.conf editado deveria vir managed=false: $out"

# --- revert --dry-run preserva tudo ---------------------------------------
"$PZ" tune gaming revert --dry-run >/dev/null
[ -f "$MANGOHUD" ] || fail "revert --dry-run removeu $MANGOHUD"
[ -f "$STATE_DIR/gaming.json" ] || fail "revert --dry-run apagou o estado"

# --- revert remove o que criamos e limpa o estado -------------------------
"$PZ" tune gaming revert >/dev/null
[ ! -f "$MANGOHUD" ] || fail "revert manteve $MANGOHUD (arquivo criado por nós)"
[ ! -f "$CORECTRL" ] || fail "revert manteve $CORECTRL"
[ ! -f "$STATE_DIR/gaming.json" ] || fail "revert não limpou o estado"

out="$("$PZ" tune gaming status)"
jq -e '.applied == false' <<< "$out" >/dev/null || fail "status após revert deveria ser applied=false: $out"

# --- arquivo pré-existente volta do backup, não some ----------------------
mkdir -p "$(dirname "$MANGOHUD")"
printf 'preexistente do usuário\n' > "$MANGOHUD"
"$PZ" tune gaming apply >/dev/null
grep -q 'PhaseZero MangoHud preset' "$MANGOHUD" || fail "apply não sobrescreveu o arquivo do usuário"
"$PZ" tune gaming revert >/dev/null
[ -f "$MANGOHUD" ] || fail "revert apagou arquivo que era do usuário"
grep -q 'preexistente do usuário' "$MANGOHUD" || fail "revert não restaurou o conteúdo original"

# --- revert sem estado é no-op explícito ----------------------------------
out="$("$PZ" tune gaming revert)"
jq -e '.ok == true' <<< "$out" >/dev/null || fail "revert sem estado deveria devolver envelope ok: $out"

# --- área dev: preferências de git voltam ao valor anterior ---------------
if command -v git >/dev/null 2>&1; then
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    git config --global pull.rebase false
    "$PZ" tune dev apply >/dev/null || true
    [ "$(git config --global --get pull.rebase)" = "true" ] \
        || fail "apply não ajustou git pull.rebase"
    "$PZ" tune dev revert >/dev/null
    [ "$(git config --global --get pull.rebase)" = "false" ] \
        || fail "revert não devolveu git pull.rebase ao valor do usuário"
    [ -z "$(git config --global --get fetch.prune || true)" ] \
        || fail "revert deveria remover chave que não existia antes"
fi

# --- usage rejeita ação inválida ------------------------------------------
if "$PZ" tune gaming banana >/dev/null 2>&1; then
    fail "ação inválida deveria falhar"
fi

echo "PASS: linux-tuning-lifecycle"
