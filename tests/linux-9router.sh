#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
listener_pid=""
expect_grant_block() {
    local output rc
    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 69 ] || {
        printf 'expected grant block (exit 69), got %s: %s\n' "$rc" "$output" >&2
        return 1
    }
    jq -e '.status == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
        <<< "$output" >/dev/null
}
cleanup() {
    [ -z "$listener_pid" ] || kill "$listener_pid" >/dev/null 2>&1 || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
export PZ_AI_PROXY_ROOT="$HOME/.local/share/phasezero/ai-proxies"
export PZ_9ROUTER_INSTALL_ROOT="$PZ_AI_PROXY_ROOT/9router"
export PZ_9ROUTER_DATA_DIR="$HOME/.9router"
export PZ_LOCAL_BIN="$HOME/.local/bin"
export PZ_9ROUTER_NODE_BIN="$(command -v node)"
export PZ_9ROUTER_NPM_CLI="$TMP_ROOT/npm-cli.js"
export PZ_9ROUTER_MANAGED_PZ="$ROOT/linux/pz"
mkdir -p "$PZ_9ROUTER_INSTALL_ROOT/bin" \
    "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/app" \
    "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/hooks" \
    "$PZ_9ROUTER_DATA_DIR/auth" "$XDG_RUNTIME_DIR"
printf '#!/usr/bin/env bash\nexit 99\n' > "$PZ_9ROUTER_INSTALL_ROOT/bin/9router"
chmod +x "$PZ_9ROUTER_INSTALL_ROOT/bin/9router"
printf '{"version":"0.0.0-test"}\n' > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/package.json"
printf 'machine\n' > "$PZ_9ROUTER_DATA_DIR/machine-id"
printf 'secret\n' > "$PZ_9ROUTER_DATA_DIR/auth/cli-secret"
printf 'module.exports={ensureSqliteRuntime(){},buildEnvWithRuntime(e){return e}};\n' \
    > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/hooks/sqliteRuntime.js"
printf 'setInterval(() => {}, 1000);\n' > "$PZ_9ROUTER_INSTALL_ROOT/lib/node_modules/9router/app/server.js"
touch "$PZ_9ROUTER_NPM_CLI"

bash -n "$ROOT/linux/ai/9router-manager.sh"
node --check "$ROOT/linux/ai/9router-server-runner.js"
grep -Fq 'pz ai 9router tui' "$ROOT/linux/pz"
grep -Fq 'pz ai 9router repair' "$ROOT/linux/pz"

sleep 120 &
listener_pid=$!
stub_bin="$TMP_ROOT/stubs"
mkdir -p "$stub_bin"
cat > "$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *'is-active'*) echo active ;;
    *'show phasezero-9router.service -p MainPID --value'*) echo "$PZ_TEST_LISTENER_PID" ;;
    *'is-enabled'*) echo enabled ;;
esac
exit 0
EOF
cat > "$stub_bin/ss" <<'EOF'
#!/usr/bin/env bash
printf 'LISTEN 0 128 127.0.0.1:20128 0.0.0.0:* users:(("node",pid=%s,fd=20))\n' "$PZ_TEST_LISTENER_PID"
EOF
cat > "$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" -X POST "* || " $* " == *" -X PUT "* || " $* " == *" -X DELETE "* ]]; then
    mkdir -p "$XDG_STATE_HOME/phasezero"
    printf 'write\n' >> "$XDG_STATE_HOME/phasezero/managed-write-called"
fi
case "$*" in
    *'/api/health'*) printf '{"ok":true}\n' ;;
    *'/api/providers'*) printf '{"connections":[{"id":"fixture-account","isActive":true}]}\n' ;;
    *'/api/combos'*) printf '{"combos":[]}\n' ;;
    *'/api/usage/stats'*) printf '{}\n' ;;
    *'/v1/models'*)
        case "$*" in
            *'%{http_code}'*) printf '200' ;;
            *) printf '{"data":[{"id":"fixture-model"}]}\n' ;;
        esac
        ;;
    *'/v1/chat/completions'*)
        mkdir -p "$XDG_STATE_HOME/phasezero"
        printf 'called\n' >> "$XDG_STATE_HOME/phasezero/test-chat-called"
        printf '200'
        ;;
    *) printf '{}\n' ;;
esac
EOF
cat > "$stub_bin/xdg-open" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$XDG_STATE_HOME/phasezero"
printf '%s\n' "$*" > "$XDG_STATE_HOME/phasezero/dashboard-opened"
EOF
chmod +x "$stub_bin"/*
for stub in "$stub_bin"/*; do
    bash -n "$stub"
done
export PATH="$stub_bin:$PATH"
export PZ_TEST_LISTENER_PID="$listener_pid"

secret_marker='sk-phasezero-must-never-print-test'
mkdir -p "$XDG_CONFIG_HOME/phasezero/ai-proxies"
printf 'PHASEZERO_9ROUTER_API_KEY=%s\n' "$secret_marker" > "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
chmod 0600 "$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"
mkdir -p "$XDG_CONFIG_HOME/phasezero/9router"
printf '{"model":"Default","activeCombo":"Default"}\n' \
    > "$XDG_CONFIG_HOME/phasezero/9router/settings.json"
before_pid="$listener_pid"
repair_output="$("$ROOT/linux/pz" ai 9router repair)"
settings_hash="$(sha256sum "$XDG_CONFIG_HOME/phasezero/9router/settings.json" | awk '{print $1}')"
grep -A12 '^repair_9router()' "$ROOT/linux/ai/9router-manager.sh" | grep -Fq 'ensure_node_runtime'
kill -0 "$before_pid"
tui_output="$("$HOME/.local/bin/9router")"
kill -0 "$before_pid"
router_test="$("$ROOT/linux/pz" ai 9router test)"
jq -e '.health == true and .modelsEndpoint == true and .providerCount == 1 and
       .chat == "blocked" and .blockedReason == "connection-grant-not-enforceable"' \
    <<< "$router_test" >/dev/null
[ ! -e "$XDG_STATE_HOME/phasezero/test-chat-called" ]
client_status="$("$ROOT/linux/pz" ai 9router client status)"
jq -e '.ready == false and .blockedReason == "connection-grant-not-enforceable"' \
    <<< "$client_status" >/dev/null
client_target="$XDG_STATE_HOME/phasezero/client-started"
expect_grant_block "$ROOT/linux/pz" ai 9router client run /usr/bin/touch "$client_target"
expect_grant_block "$HOME/.local/bin/phasezero-9router-run" /usr/bin/touch "$client_target"
expect_grant_block "$ROOT/linux/pz" ai 9router provider sync-secrets
expect_grant_block "$ROOT/linux/pz" ai 9router provider remove fixture-account
expect_grant_block "$ROOT/linux/pz" ai 9router dashboard
expect_grant_block "$ROOT/linux/pz" ai 9router combo sync
expect_grant_block "$ROOT/linux/pz" ai 9router combo create fixture fixture-model
expect_grant_block "$ROOT/linux/pz" ai 9router combo switch Default
[ ! -e "$client_target" ]
[ ! -e "$XDG_STATE_HOME/phasezero/dashboard-opened" ]
[ ! -e "$XDG_STATE_HOME/phasezero/managed-write-called" ]
[ "$(sha256sum "$XDG_CONFIG_HOME/phasezero/9router/settings.json" | awk '{print $1}')" = "$settings_hash" ]
after_pid="$listener_pid"
test "$before_pid" = "$after_pid"
if grep -Fq "$secret_marker" <<< "$repair_output$tui_output"; then
    echo "9Router secret leaked to PhaseZero output" >&2
    exit 1
fi
jq -e '(.listener.pid == (env.PZ_TEST_LISTENER_PID | tonumber)) and
       .listener.ownedByService == true' <<< "$tui_output" >/dev/null

service_unit="$XDG_CONFIG_HOME/systemd/user/phasezero-9router.service"
watch_unit="$XDG_CONFIG_HOME/systemd/user/phasezero-9router-watch.service"
grep -Fq 'ExecStart='"$HOME/.local/bin/phasezero-9router-server" "$service_unit"
grep -Fq 'Name=9Router dashboard (uso bloqueado)' "$XDG_DATA_HOME/applications/phasezero-9router.desktop"
grep -Fq 'Terminal=true' "$XDG_DATA_HOME/applications/phasezero-9router.desktop"
grep -Fq "$ROOT/linux/ai/9router-server-runner.js" "$HOME/.local/bin/phasezero-9router-server"
if grep -Rq '/current/' "$XDG_CONFIG_HOME/systemd/user" "$HOME/.local/share/applications"; then
    echo "stale current symlink path found in managed launchers" >&2
    exit 1
fi
if grep -Fq 'killProcessOnPort' "$ROOT/linux/ai/9router-server-runner.js"; then
    echo "server runner must not contain upstream port-kill lifecycle" >&2
    exit 1
fi
grep -Eq '^ExecStart=(/usr/lib/phasezero/linux/pz|'"$ROOT"'/linux/pz) ai 9router watch-once$' "$watch_unit"

env_file="$XDG_CONFIG_HOME/phasezero/ai-proxies/9router.env"

# repair must rebuild the server variables a damaged env lost, and must carry the
# client credential across the rewrite instead of dropping it.
grep -Eq '^PORT=20128$' "$env_file"
grep -Eq '^HOSTNAME=127\.0\.0\.1$' "$env_file"
grep -Fq "PHASEZERO_9ROUTER_API_KEY=$secret_marker" "$env_file"

# The server wrapper is the last line of defence: without the managed loopback
# variables the upstream server binds 0.0.0.0:3000, so it must refuse to start.
set +e
HOSTNAME='' PORT='' "$HOME/.local/bin/phasezero-9router-server" >/dev/null 2>&1
guard_rc=$?
set -e
test "$guard_rc" = 78

# A single-letter key is the signature of a scratch write that escaped its
# sandbox onto the live file; env_upsert must reject it and leave the file alone.
manager_lib="$ROOT/linux/ai/9router-manager.sh"
upsert_err="$( ( source "$manager_lib" status; env_upsert K v ) 2>&1 1>/dev/null || true )"
grep -Fq 'refusing to write malformed 9Router env key: K' <<< "$upsert_err"
grep -Fq "PHASEZERO_9ROUTER_API_KEY=$secret_marker" "$env_file"
( source "$manager_lib" status; env_upsert JWT_SECRET rotated ) >/dev/null 2>&1
grep -Eq '^JWT_SECRET=rotated$' "$env_file"

# Truncation must be recoverable from the rotating backup, not fatal.
cp "$env_file" "$TMP_ROOT/env-good"
printf 'K=v\n' > "$env_file"
"$ROOT/linux/pz" ai 9router repair >/dev/null
grep -Fq "PHASEZERO_9ROUTER_API_KEY=$secret_marker" "$env_file"
grep -Eq '^PORT=20128$' "$env_file"

HOSTNAME=127.0.0.1 PORT=20128 "$HOME/.local/bin/phasezero-9router-server" >/dev/null 2>&1 &
runner_pid=$!
sleep 0.3
kill -0 "$runner_pid"
kill -TERM "$runner_pid" >/dev/null 2>&1 || true
wait "$runner_pid" 2>/dev/null || true

echo "9router attach-only, stable units, PID and secret redaction ok"
