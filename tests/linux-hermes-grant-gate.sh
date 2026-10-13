#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
printf 'Hermes grant-gate fixture root: %s\n' "$TMP_ROOT"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export HERMES_HOME="$HOME/.hermes"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
export HERMES_GATE_CALLS="$TMP_ROOT/calls.log"
unset PZ_HOMELAB_ALLOW_HOST_WORKLOADS || true
mkdir -p "$HOME" "$PZ_LOCAL_BIN"

for stub in curl systemctl hermes uv; do
    cat > "$PZ_LOCAL_BIN/$stub" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "${0##*/}" "$*" >> "$HERMES_GATE_CALLS"
if [ "${0##*/}" = systemctl ]; then exit 1; fi
exit 0
SH
    chmod 0700 "$PZ_LOCAL_BIN/$stub"
done
export PATH="$PZ_LOCAL_BIN:/usr/bin:/bin"

assert_blocked() {
    local label="$1" rc=0
    shift
    local stdout="$TMP_ROOT/$label.json" stderr="$TMP_ROOT/$label.stderr"
    if "$@" >"$stdout" 2>"$stderr"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 69 ]; then
        echo "FAIL: $label returned $rc, expected 69" >&2
        cat "$stderr" >&2
        exit 1
    fi
    jq -e '.usageBlocked == true and .blockedReason == "connection-grant-not-enforceable"' \
        "$stdout" >/dev/null || {
        echo "FAIL: $label did not return the account-grant block envelope" >&2
        cat "$stdout" >&2
        exit 1
    }
}

status="$(bash "$ROOT/linux/ai/setup-hermes.sh" status)"
jq -e '.ready == false and .usageBlocked == true
    and .blockedReason == "connection-grant-not-enforceable"
    and .configurationReady == false and .secretsRedacted == true' \
    <<< "$status" >/dev/null

calls_before="$(wc -l < "$HERMES_GATE_CALLS")"
for action in setup install configure mcp portal gateway; do
    assert_blocked "setup-$action" bash "$ROOT/linux/ai/setup-hermes.sh" "$action"
done
assert_blocked release-override env PZ_HOMELAB_ALLOW_HOST_WORKLOADS=1 \
    bash "$ROOT/linux/ai/setup-hermes.sh" configure

for action in apply wire enforce; do
    assert_blocked "router-$action" bash "$ROOT/linux/ai/hermes-router.sh" "$action"
done
for action in "model Default" "pin Default" "set Default" heal repair install install-watch; do
    read -r -a argv <<< "$action"
    assert_blocked "router-${argv[0]}" bash "$ROOT/linux/ai/hermes-router.sh" "${argv[@]}"
done

for action in "apply Default" "register Default" "install-provider Default" \
    "set Default" "pin Default" live probe auto install heal repair; do
    read -r -a argv <<< "$action"
    assert_blocked "provider-${argv[0]}" bash "$ROOT/linux/ai/9router-hermes-provider.sh" "${argv[@]}"
done

assert_blocked pz-setup bash "$ROOT/linux/pz" ai setup hermes
assert_blocked pz-route bash "$ROOT/linux/pz" ai hermes route apply
assert_blocked pz-provider bash "$ROOT/linux/pz" ai hermes provider apply Default
assert_blocked remote-start bash "$ROOT/linux/pz" server hermes start

calls_after="$(wc -l < "$HERMES_GATE_CALLS")"
test "$calls_before" -eq "$calls_after"
test ! -e "$HOME/.hermes"
test ! -e "$HOME/.config/phasezero/ai"
test ! -e "$HOME/.config/systemd"
test ! -e "$HOME/.local/share/phasezero/runtime"

# Prove aggregate setup records both consumer gates, then continues later steps.
SHADOW_ROOT="$TMP_ROOT/shadow"
mkdir -p "$SHADOW_ROOT/linux/lib" "$SHADOW_ROOT/linux/ai"
cp "$ROOT/linux/pz" "$SHADOW_ROOT/linux/pz"
cat > "$SHADOW_ROOT/linux/lib/common.sh" <<'SH'
pz_warn() { printf 'WARN: %s\n' "$*" >&2; }
pz_error() { printf 'ERROR: %s\n' "$*" >&2; }
SH
cat > "$SHADOW_ROOT/linux/lib/pacman.sh" <<'SH'
# Minimal CLI dependency for the isolated aggregate-setup fixture.
SH
for script in setup-codex.sh setup-ollama.sh setup-open-webui.sh \
    setup-claude-code.sh desktop-apps.sh setup-opencode.sh setup-hermes.sh \
    setup-openclaw.sh setup-memory.sh setup-admin-bridge.sh \
    setup-agent-compat.sh setup-usagebar.sh setup-codexbar.sh setup-ides.sh; do
    cat > "$SHADOW_ROOT/linux/ai/$script" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$PZ_SETUP_ALL_CALLS"
case ",${PZ_SETUP_ALL_BLOCKED:-}," in
  *,"${0##*/}",*) printf '%s\n' '{"usageBlocked":true,"blockedReason":"connection-grant-not-enforceable"}'; exit 69 ;;
esac
exit 0
SH
    chmod 0700 "$SHADOW_ROOT/linux/ai/$script"
done
export PZ_SETUP_ALL_CALLS="$TMP_ROOT/setup-all.calls"
setup_all_stdout="$TMP_ROOT/setup-all.stdout"
setup_all_stderr="$TMP_ROOT/setup-all.stderr"
setup_all_rc=0
if PZ_SETUP_ALL_BLOCKED="setup-open-webui.sh,setup-hermes.sh,setup-openclaw.sh" \
    bash "$SHADOW_ROOT/linux/pz" ai setup all >"$setup_all_stdout" 2>"$setup_all_stderr"; then
    setup_all_rc=0
else
    setup_all_rc=$?
fi
test "$setup_all_rc" -eq 69
grep -q 'Open WebUI omitted: request-bound account grants are unavailable' "$setup_all_stderr"
grep -q 'Hermes omitted: per-request account grants are unavailable' "$setup_all_stderr"
grep -q 'OpenClaw omitted: per-request account grants are unavailable' "$setup_all_stderr"
for script in setup-openclaw.sh setup-memory.sh setup-admin-bridge.sh \
    setup-agent-compat.sh setup-usagebar.sh setup-codexbar.sh setup-ides.sh; do
    grep -q "^$script " "$PZ_SETUP_ALL_CALLS"
done

echo "PASS: Hermes consumers fail closed before network, config, launcher, or service work"
