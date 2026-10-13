#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_STATE="$XDG_STATE_HOME/phasezero"
export PZ_OMNIROUTE_PREFIX="$HOME/.local/share/npm"
export PZ_LOCAL_BIN="$HOME/.local/bin"
export OMNIROUTE_GATE_CALLS="$TMP_ROOT/calls.log"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/phasezero/omniroute" "$TMP_ROOT/stubs"
printf 'PORT=20128\nOMNIROUTE_API_KEY=fixture-key\n' \
    > "$XDG_CONFIG_HOME/phasezero/omniroute/omniroute.env"
chmod 0600 "$XDG_CONFIG_HOME/phasezero/omniroute/omniroute.env"

cat > "$TMP_ROOT/stubs/curl" <<'SH'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
    case "$arg" in http://127.0.0.1:*) url="$arg" ;; esac
done
printf 'curl\t%s\n' "$*" >> "$OMNIROUTE_GATE_CALLS"
case "$url" in
    */api/health) printf '{"ok":true}\n' ;;
    */v1/models)
        case "$*" in *'%{http_code}'*) printf '200' ;;
            *) printf '{"data":[{"id":"fixture-model"}]}\n' ;; esac ;;
    */api/providers) printf '{"connections":[{"id":"fixture-account","isActive":true}]}\n' ;;
    */api/combos) printf '{"combos":[{"name":"phasezero-smart","models":["fixture-model"]}]}\n' ;;
    */api/usage/stats) printf '{}\n' ;;
    */v1/chat/completions)
        printf 'chat-inference\t%s\n' "$*" >> "$OMNIROUTE_GATE_CALLS"
        printf '200' ;;
    *) printf '{}\n' ;;
esac
SH

for name in npm npx systemctl xdg-open ss; do
    cat > "$TMP_ROOT/stubs/$name" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${0##*/}" "$*" >> "$OMNIROUTE_GATE_CALLS"
exit 0
SH
done
chmod 0700 "$TMP_ROOT/stubs/"*
export PATH="$TMP_ROOT/stubs:/usr/bin:/bin"

out="$(bash "$ROOT/linux/ai/omniroute-manager.sh" test)"
jq -e '.health == true and .modelsEndpoint == true and .chat == "blocked" and
       .blockedReason == "connection-grant-not-enforceable"' <<< "$out" >/dev/null
if grep -q '^chat-inference' "$OMNIROUTE_GATE_CALLS"; then
    echo "FAIL: read-only OmniRoute test sent chat inference" >&2
    exit 1
fi

status="$(bash "$ROOT/linux/ai/omniroute-manager.sh" status)"
jq -e '.usageBlocked == true and .blockedReason == "connection-grant-not-enforceable" and
       .nextAction == "connection-grant-not-enforceable"' <<< "$status" >/dev/null
client_status="$(bash "$ROOT/linux/ai/omniroute-manager.sh" client status)"
jq -e '.ready == false and .usageBlocked == true and
       .blockedReason == "connection-grant-not-enforceable"' <<< "$client_status" >/dev/null
doctor="$(bash "$ROOT/linux/ai/omniroute-manager.sh" doctor)"
jq -e '.usageBlocked == true and .blockedReason == "connection-grant-not-enforceable" and
       ([.nextActions[]] | all(. != "linux/pz ai omniroute install" and
                               . != "linux/pz ai omniroute start"))' <<< "$doctor" >/dev/null

: > "$OMNIROUTE_GATE_CALLS"
blocked_target="$TMP_ROOT/client-started"
wrapper_stdout="$TMP_ROOT/wrapper.stdout"
wrapper_stderr="$TMP_ROOT/wrapper.stderr"
wrapper_rc=0
if bash "$ROOT/linux/ai/omniroute-client-wrapper.sh" /usr/bin/touch "$blocked_target" \
    >"$wrapper_stdout" 2>"$wrapper_stderr"; then
    wrapper_rc=0
else
    wrapper_rc=$?
fi
test "$wrapper_rc" -eq 69
jq -e '.status == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
    "$wrapper_stdout" >/dev/null

assert_blocked() {
    local label="$1" rc=0 stdout="$TMP_ROOT/$1.stdout" stderr="$TMP_ROOT/$1.stderr"
    shift
    if bash "$ROOT/linux/ai/omniroute-manager.sh" "$@" >"$stdout" 2>"$stderr"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 69 ]; then
        echo "FAIL: $label returned $rc, expected 69" >&2
        cat "$stderr" >&2
        cat "$stdout" >&2
        exit 1
    fi
    jq -e '.status == "blocked" and .usageBlocked == true and
           .blockedReason == "connection-grant-not-enforceable"' "$stdout" >/dev/null
}

assert_blocked install install
assert_blocked start start
assert_blocked restart restart
assert_blocked dashboard dashboard
assert_blocked provider-sync provider sync-secrets
assert_blocked combo-auto combo auto
assert_blocked opencode opencode
assert_blocked update update
assert_blocked client-run client run /usr/bin/touch "$blocked_target"
[ ! -e "$blocked_target" ]
[ ! -s "$OMNIROUTE_GATE_CALLS" ]
[ ! -e "$PZ_OMNIROUTE_PREFIX" ]
[ ! -e "$PZ_LOCAL_BIN" ]
[ ! -e "$XDG_CONFIG_HOME/opencode/opencode.json" ]
[ ! -e "$XDG_CONFIG_HOME/systemd/user/phasezero-omniroute.service" ]
[ ! -e "$XDG_DATA_HOME/applications/phasezero-omniroute.desktop" ]
[ ! -e "$PZ_STATE/omniroute" ]

echo "PASS: OmniRoute inference and enabling mutations fail closed before side effects"
