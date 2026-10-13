#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux AI helpers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$TMP_ROOT/home/.config"
export XDG_DATA_HOME="$TMP_ROOT/home/.local/share"
export XDG_STATE_HOME="$TMP_ROOT/home/.local/state"
export PZ_WORKSPACE_ROOT="$TMP_ROOT/workspace"
export PZ_LOCAL_BIN="$TMP_ROOT/bin"
export PZ_NPM_PREFIX="$TMP_ROOT/npm"

mkdir -p "$HOME" "$PZ_WORKSPACE_ROOT" "$PZ_LOCAL_BIN"

# Deterministic fake opencode inside the isolated HOME: the test must not
# depend on a host opencode (symlinking it breaks on clean hosts and is
# non-reproducible). The stub only answers --version with a valid semver;
# it never touches the network or host state, and fails loudly on any other
# invocation so accidental real calls are caught instead of silently faked.
cat > "$PZ_LOCAL_BIN/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version)
        printf 'opencode 1.4.2\n'
        ;;
    *)
        printf 'opencode: test stub only supports --version\n' >&2
        exit 1
        ;;
esac
EOF
chmod +x "$PZ_LOCAL_BIN/opencode"
# ensure PZ_LOCAL_BIN is on PATH before any setup script runs
export PATH="$PZ_LOCAL_BIN:$PATH"

"$REPO_ROOT/linux/pz" ai status | jq -e '.schemaVersion == 1 and .runtime.node.available | type == "boolean"' >/dev/null
"$REPO_ROOT/linux/pz" ai mcp status | jq -e '.schemaVersion == 1 and (.definitions | length) >= 1' >/dev/null
"$REPO_ROOT/linux/pz" ai mcp sync >/dev/null
test -f "$XDG_CONFIG_HOME/opencode/opencode.json"
test -f "$XDG_CONFIG_HOME/claude/claude.json"
test -f "$XDG_CONFIG_HOME/Claude/claude_desktop_config.json"
test -f "$HOME/.codex/config.toml"
test -f "$PZ_WORKSPACE_ROOT/.vscode/mcp.json"
test -f "$XDG_CONFIG_HOME/Code/User/mcp.json"
test -f "$XDG_CONFIG_HOME/Cursor/User/mcp.json"
test -f "$XDG_CONFIG_HOME/zed/settings.json"
test -f "$XDG_CONFIG_HOME/ai.z.zcode/store.json"
test -f "$HOME/.hermes/config.yaml"
test ! -e "$HOME/.openclaw/config.json"
jq -e 'has("mcpServers") | not' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
jq -e '.mcp."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
jq -e '.servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$PZ_WORKSPACE_ROOT/.vscode/mcp.json" >/dev/null
jq -e '.servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/Code/User/mcp.json" >/dev/null
jq -e '.mcpServers."ai-memory".command == "npx"' "$XDG_CONFIG_HOME/Cursor/User/mcp.json" >/dev/null
jq -e '.context_servers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/zed/settings.json" >/dev/null
jq -e '."mcp-storage" | fromjson | .state.config.mcp.mcpServers."ai-memory".url | test("^http://127.0.0.1:49374/mcp$")' "$XDG_CONFIG_HOME/ai.z.zcode/store.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP ai-memory' "$HOME/.hermes/config.yaml"
grep -q 'BEGIN PHASEZERO MCP ai-memory' "$HOME/.codex/config.toml"

"$REPO_ROOT/linux/pz" ai mcp install context7 >/dev/null
jq -e '.mcp.context7.url == "https://mcp.context7.com/mcp"' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
jq -e '.servers.context7.url == "https://mcp.context7.com/mcp"' "$PZ_WORKSPACE_ROOT/.vscode/mcp.json" >/dev/null
grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.hermes/config.yaml"
grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.codex/config.toml"

"$REPO_ROOT/linux/pz" ai mcp remove context7 >/dev/null
if jq -e '.mcp.context7' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null; then
    echo "context7 should have been removed from opencode" >&2
    exit 1
fi
if grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.codex/config.toml"; then
    echo "context7 should have been removed from codex" >&2
    exit 1
fi
if grep -q 'BEGIN PHASEZERO MCP context7' "$HOME/.hermes/config.yaml"; then
    echo "context7 should have been removed from hermes" >&2
    exit 1
fi
test ! -e "$HOME/.openclaw/config.json"

"$REPO_ROOT/linux/ai/setup-ides.sh" dry-run | jq -e '.tool == "ides"' >/dev/null

# Auto-accept permissions: replace bash "*": ask and flip desktop autoApprove.
mkdir -p "$XDG_CONFIG_HOME/opencode" "$XDG_CONFIG_HOME/ai.opencode.desktop"
# Seed the restrictive value on top of the existing config: later assertions
# still read the MCP entries the earlier setup wrote to this file.
opencode_cfg="$XDG_CONFIG_HOME/opencode/opencode.json"
[[ -s "$opencode_cfg" ]] || printf '%s\n' '{}' > "$opencode_cfg"
jq '.permission = {"bash":{"*":"ask"}}' "$opencode_cfg" > "$opencode_cfg.tmp" && mv "$opencode_cfg.tmp" "$opencode_cfg"
printf '%s\n' '{"settings.v3":"{\"permissions\":{\"autoApprove\":false}}"}' > "$XDG_CONFIG_HOME/ai.opencode.desktop/default.dat"
"$REPO_ROOT/linux/ai/setup-opencode.sh" permissions-auto >/dev/null
jq -e '.permission["*"] == "allow" and .permission.bash == "allow" and .permission.edit == "allow"' \
    "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
python3 - "$XDG_CONFIG_HOME/ai.opencode.desktop/default.dat" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
settings = json.loads(data["settings.v3"])
assert settings["permissions"]["autoApprove"] is True, settings
PY
timeout 15 "$REPO_ROOT/linux/ai/setup-ides.sh" configure >/dev/null 2>&1 || echo "WARN: setup-ides.sh configure failed (non-fatal)" >&2
test -f "$PZ_WORKSPACE_ROOT/.vscode/extensions.json"
test -f "$XDG_CONFIG_HOME/nvim/lua/phasezero_ai.lua"
jq -e '.recommendations | index("GitHub.copilot")' "$PZ_WORKSPACE_ROOT/.vscode/extensions.json" >/dev/null

"$REPO_ROOT/linux/ai/setup-opencode.sh" dry-run | jq -e '.tool == "opencode" and .launcher == "opencode-deck"' >/dev/null
timeout 15 "$REPO_ROOT/linux/ai/setup-opencode.sh" desktop-integration >/dev/null 2>&1 || echo "WARN: desktop-integration failed (non-fatal)" >&2
test -x "$PZ_LOCAL_BIN/opencode-deck"
bash -n "$PZ_LOCAL_BIN/opencode-deck"
test -f "$XDG_DATA_HOME/applications/phasezero-opencode.desktop"
grep -q "opencode-deck" "$XDG_DATA_HOME/applications/phasezero-opencode.desktop"

# oh-my-openagent (OMO) wrapper: status contract, dry-run safety, and the
# enable/disable round-trip must preserve the canonical opencode.json MCP block.
"$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.tool == "omo" and (.plugin.registered | type == "boolean") and (.bun.present | type == "boolean") and .telemetryOff == true' >/dev/null
"$REPO_ROOT/linux/ai/setup-omo.sh" dry-run >/dev/null
if [ -f "$XDG_CONFIG_HOME/opencode/opencode.json" ]; then
    "$REPO_ROOT/linux/ai/setup-omo.sh" enable >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.plugin.registered == true' >/dev/null
    jq -e '(.plugin // []) | any(startswith("oh-my-openagent"))' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
    jq -e '.mcp."ai-memory".url | test("mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" disable >/dev/null
    "$REPO_ROOT/linux/ai/setup-omo.sh" status | jq -e '.plugin.registered == false' >/dev/null
    jq -e '.mcp."ai-memory".url | test("mcp$")' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null
fi
"$REPO_ROOT/linux/pz" ai omo status | jq -e '.tool == "omo"' >/dev/null

# OpenCode CLI<->desktop version lockstep: status contract + dry-run safety.
"$REPO_ROOT/linux/ai/setup-opencode.sh" version-status | jq -e '.tool == "opencode-version" and (.inSync | type == "boolean") and (.cliManaged | type == "boolean") and (.autoSyncHook | type == "boolean") and (.model.usable | type == "boolean")' >/dev/null
PZ_DRY_RUN=1 "$REPO_ROOT/linux/ai/setup-opencode.sh" sync >/dev/null
PZ_DRY_RUN=1 "$REPO_ROOT/linux/ai/setup-opencode.sh" install-hook >/dev/null
# local-model config is dry-run safe and reachable via pz (skips cleanly if no Ollama)
PZ_DRY_RUN=1 PZ_OLLAMA_URL="http://127.0.0.1:1" "$REPO_ROOT/linux/ai/setup-opencode.sh" local-model >/dev/null
"$REPO_ROOT/linux/pz" ai opencode version-status | jq -e '.tool == "opencode-version"' >/dev/null

"$REPO_ROOT/linux/ai/setup-memory.sh" dry-run \
    | jq -e '.tool == "ai-memory" and .version == "1.31.1" and (.sha256 | length) == 64 and (.planned | index("install verified native release") != null)' >/dev/null
"$REPO_ROOT/linux/ai/setup-usagebar.sh" dry-run | jq -e '.tool == "ai-usagebar"' >/dev/null
"$REPO_ROOT/linux/ai/setup-hermes.sh" dry-run | jq -e '.tool == "hermes"' >/dev/null
"$REPO_ROOT/linux/ai/setup-openclaw.sh" dry-run | jq -e '.tool == "openclaw" and .usageBlocked == true and .planned == []' >/dev/null
"$REPO_ROOT/linux/pz" ai status | jq -e '
  (.clis.hermes.available | type == "boolean")
  and (.clis.openclaw.available | type == "boolean")
  and (.setupCatalog.essentials | map(.id) | index("9router") != null)
  and (.setupCatalog.optional | map(.id) | index("hermes") != null)
  and ([.setupCatalog.optional[] | select(.id == "openclaw") | .usageBlocked] == [true])
  and (.setupCatalog.optional | map(.id) | index("odysseus") != null)
' >/dev/null
"$REPO_ROOT/linux/pz" install dev-ai --dry-run >/dev/null

# Smoke: AI managers gracefully report "not installed"
for cmd in "9router status" "odysseus status" "omniroute status"; do
    out=$("$REPO_ROOT/linux/pz" ai "$cmd" 2>/dev/null || true)
    jq -e '.status == "unavailable" or .error != null' <<< "$out" >/dev/null 2>&1 || \
        echo "  WARN: $cmd did not return error — may be installed"
done

# Smoke: headroom-agent dry-run
timeout 10 "$REPO_ROOT/linux/ai/headroom-agent.sh" status 2>/dev/null || true

# headroom ausente é envelope rc0 acionável (PATH restrito garante ausência).
hr_env="$(PATH="/usr/bin:/bin" "$REPO_ROOT/linux/ai/headroom-agent.sh" status 2>/dev/null)"; hr_rc=$?
[ "$hr_rc" -eq 0 ] || { echo "FAIL: headroom status sem binário deve sair 0 (rc=$hr_rc)" >&2; exit 1; }
jq -e '.state == "not-installed" and (.nextAction | type == "string")' <<< "$hr_env" >/dev/null \
    || { echo "FAIL: envelope not-installed do headroom ausente" >&2; echo "$hr_env"; exit 1; }
echo "  headroom not-installed envelope ok"

# omniroute GET sem chave/serviço é envelope needs-config rc0.
OMNI_HOME="$(mktemp -d)"
omni_out="$(HOME="$OMNI_HOME" "$REPO_ROOT/linux/ai/omniroute-manager.sh" combo list 2>/dev/null)"; omni_rc=$?
rm -rf "$OMNI_HOME"
[ "$omni_rc" -eq 0 ] || { echo "FAIL: omniroute combo list sem config deve sair 0 (rc=$omni_rc)" >&2; exit 1; }
jq -e '(.state == "needs-config") or (.combos.state == "needs-config")' <<< "$omni_out" >/dev/null \
    || { echo "FAIL: envelope needs-config do omniroute ausente" >&2; echo "$omni_out"; exit 1; }
echo "  omniroute unconfigured envelope ok"

# Smoke: setup scripts with dry-run
timeout 10 "$REPO_ROOT/linux/ai/setup-ides.sh" dry-run >/dev/null 2>&1 || true
timeout 10 "$REPO_ROOT/linux/ai/setup-admin-bridge.sh" dry-run >/dev/null 2>&1 || true
timeout 10 "$REPO_ROOT/linux/ai/setup-agent-compat.sh" dry-run >/dev/null 2>&1 || true

# Smoke: per-task AI routing configurator is dry-run safe via pz
# (degrades gracefully on hosts without a reachable local 9Router)
routing_out=$("$REPO_ROOT/linux/pz" ai routing status --json 2>/dev/null || true)
jq -e '.health | type == "boolean"' <<< "$routing_out" >/dev/null 2>&1 || \
    echo "  WARN: ai routing status did not answer — router may be absent"
routing_inv=$("$REPO_ROOT/linux/pz" ai routing inventory 2>/dev/null || true)
jq -e '.schemaVersion == 1' <<< "$routing_inv" >/dev/null 2>&1 || \
    echo "  WARN: ai routing inventory did not answer — router may be absent"
"$REPO_ROOT/linux/pz" ai routing apply --task code --dry-run >/dev/null 2>&1 || \
    echo "  WARN: ai routing apply --dry-run failed — router may be absent"

# Central auth registry: identities and secrets never leave source managers.
auth_out="$(timeout 30 "$REPO_ROOT/linux/pz" ai auth status)"
jq -e '
  .schemaVersion == 1 and .secretsRedacted == true
  and (.entries | type == "array")
  and ([.entries[] | has("name") or has("email") or has("apiKey") or has("token")] | any | not)
' <<< "$auth_out" >/dev/null
if grep -Eq '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' <<< "$auth_out"; then
    echo "auth registry leaked an account identity" >&2
    exit 1
fi
"$REPO_ROOT/linux/pz" ai auth doctor | jq -e '.secretsRedacted == true and (.issues | type == "array")' >/dev/null
"$REPO_ROOT/linux/pz" ai operations status | jq -e '.schemaVersion == 1 and .secretsRedacted == true' >/dev/null

echo "linux-ai smoke ok"
