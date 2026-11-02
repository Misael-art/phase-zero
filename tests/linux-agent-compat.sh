#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$ROOT/linux/ai/setup-agent-compat.sh"
bash -n "$ROOT/linux/ai/headroom-agent.sh"

PZ_WORKSPACE_ROOT="$TMP/workspace" "$ROOT/linux/ai/setup-agent-compat.sh" dry-run | jq -e '.tool == "agent-compat" and (.planned | length) > 4' >/dev/null

mkdir -p "$TMP/workspace"
PZ_WORKSPACE_ROOT="$TMP/workspace" "$ROOT/linux/ai/setup-agent-compat.sh" rules >/dev/null
for file in \
    "$TMP/workspace/AGENTS.md" \
    "$TMP/workspace/CLAUDE.md" \
    "$TMP/workspace/GEMINI.md" \
    "$TMP/workspace/.github/copilot-instructions.md" \
    "$TMP/workspace/.cursor/rules/caveman.mdc" \
    "$TMP/workspace/.cursor/rules/phasezero-tools.mdc" \
    "$TMP/workspace/.windsurf/rules/caveman.md" \
    "$TMP/workspace/.windsurf/rules/phasezero-tools.md" \
    "$TMP/workspace/.clinerules/caveman.md" \
    "$TMP/workspace/.clinerules/phasezero-tools.md"; do
    [ -f "$file" ] || fail "missing rule file: $file"
done

grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$TMP/workspace/AGENTS.md" || fail "AGENTS missing Caveman"
grep -q 'BEGIN PHASEZERO TOOLS' "$TMP/workspace/AGENTS.md" || fail "AGENTS missing tools"
PZ_WORKSPACE_ROOT="$TMP/workspace" "$ROOT/linux/ai/setup-agent-compat.sh" status |
    jq -e '.rules.ok == true and .tools.caveman.configured == true and .tools.graphify.placeholder == true' >/dev/null

PZ_WORKSPACE_ROOT="$TMP/workspace" "$ROOT/linux/ai/setup-agent-compat.sh" frugality >/dev/null
[ -f "$TMP/workspace/.codex/ai-context/frugality-manifest.json" ] || fail "missing frugality manifest"
[ -f "$TMP/workspace/.codex/ai-context/repo-skeleton.json" ] || fail "missing skeleton"
grep -q 'PHASEZERO AI CONTEXT FRUGALITY' "$TMP/workspace/.aiderignore" || fail "missing aiderignore marker"

grep -q 'setup-agent-compat.sh' "$ROOT/profiles/dev-ai.json" || fail "dev-ai missing compat script"
grep -q 'headroom)' "$ROOT/linux/pz" || fail "pz missing headroom route"
grep -q 'compat|agent-compat|tools)' "$ROOT/linux/pz" || fail "pz missing compat route"

echo "PASS: linux agent compatibility"
