#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
export OPENCLAW_CALLS="$TMP_ROOT/openclaw.calls"
export TOOL_CALLS="$TMP_ROOT/tool.calls"
export MEMORY_CALLS="$TMP_ROOT/memory.calls"
export PATH="$PZ_LOCAL_BIN:/usr/bin:/bin"

mkdir -p "$HOME" "$PZ_LOCAL_BIN" "$HOME/.openclaw"
: > "$OPENCLAW_CALLS"
: > "$TOOL_CALLS"
: > "$MEMORY_CALLS"

cat > "$PZ_LOCAL_BIN/openclaw" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OPENCLAW_CALLS"
case "${1:-}" in
    --version) echo 'OpenClaw test-stub' ;;
    gateway) [ "${2:-}" = status ] && echo 'Gateway stopped' || exit 97 ;;
    *) exit 97 ;;
esac
SH
cat > "$PZ_LOCAL_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$TOOL_CALLS"
exit 1
SH
for tool in npm node curl headroom; do
    cat > "$PZ_LOCAL_BIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TOOL_CALLS"
exit 97
SH
    chmod 0700 "$PZ_LOCAL_BIN/$tool"
done
cat > "$PZ_LOCAL_BIN/ai-memory" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MEMORY_CALLS"
exit 0
SH
chmod 0700 "$PZ_LOCAL_BIN/openclaw" "$PZ_LOCAL_BIN/systemctl" "$PZ_LOCAL_BIN/ai-memory"

printf '%s\n' '{"mcp":{"servers":{"operator-owned":{"url":"http://127.0.0.1:49999/mcp"}}}}' \
    > "$HOME/.openclaw/config.json"
cp "$HOME/.openclaw/config.json" "$TMP_ROOT/openclaw-config.before"

for action in setup install configure daemon; do
    rc=0
    if "$ROOT/linux/ai/setup-openclaw.sh" "$action" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
        rc=0
    else
        rc=$?
    fi
    test "$rc" -eq 69
    jq -e '.status == "blocked" and .ready == false and .usageBlocked == true and .blockedReason == "connection-grant-not-enforceable"' \
        "$TMP_ROOT/out" >/dev/null
done

rc=0
if "$ROOT/linux/pz" ai setup openclaw >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    rc=0
else
    rc=$?
fi
test "$rc" -eq 69
jq -e '.usageBlocked == true' "$TMP_ROOT/out" >/dev/null

bash "$ROOT/linux/ai/setup-openclaw-optional.sh" setup >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
grep -q 'SKIP: OpenClaw use blocked' "$TMP_ROOT/err"
"$ROOT/linux/ai/setup-openclaw.sh" dry-run | jq -e '.allowed == false and .usageBlocked == true and .planned == []' >/dev/null

rc=0
if "$ROOT/linux/ai/headroom-agent.sh" wrap-openclaw prompt >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; then
    rc=0
else
    rc=$?
fi
test "$rc" -eq 69
jq -e '.usageBlocked == true and .blockedReason == "connection-grant-not-enforceable"' "$TMP_ROOT/out" >/dev/null
if grep -q '^headroom ' "$TOOL_CALLS"; then
    echo "FAIL: OpenClaw Headroom wrapper ran despite missing request grants" >&2
    exit 1
fi

# Status may inspect the existing executable and service state, never claim use-ready.
"$ROOT/linux/ai/setup-openclaw.sh" status >"$TMP_ROOT/status.json"
jq -e '.available == true and .usageBlocked == true and .ready == false' "$TMP_ROOT/status.json" >/dev/null
test "$(wc -l < "$OPENCLAW_CALLS")" -eq 2
if grep -Eq '(^| )(setup|onboard|gateway (install|start)|plugins install)( |$)' "$OPENCLAW_CALLS"; then
    echo "FAIL: status invoked a mutating OpenClaw command" >&2
    exit 1
fi
if grep -Eq '(^| )(install|enable|start|restart)( |$)' "$TOOL_CALLS"; then
    echo "FAIL: blocked setup changed a service or installed a tool" >&2
    exit 1
fi

# Broad MCP and ai-memory wiring must leave a detected external OpenClaw untouched.
"$ROOT/linux/ai/mcp-manager.sh" sync >/dev/null
"$ROOT/linux/ai/setup-memory.sh" wire >"$TMP_ROOT/wire.out" 2>"$TMP_ROOT/wire.err"
cmp "$TMP_ROOT/openclaw-config.before" "$HOME/.openclaw/config.json"
if grep -Eq -- '--client openclaw|--agent openclaw' "$MEMORY_CALLS"; then
    echo "FAIL: ai-memory wired an ungranted OpenClaw consumer" >&2
    exit 1
fi
jq -e '.clients[] | select(.client == "openclaw" and .usageBlocked == true and .ready == false)' \
    "$XDG_STATE_HOME/phasezero/ai/memory-integrations.json" >/dev/null

jq -e '.scripts.linux | index("linux/ai/setup-openclaw-optional.sh") != null' \
    "$ROOT/profiles/dev-ai.json" >/dev/null

echo "PASS: OpenClaw use fails closed; read-only status and external config remain intact"
