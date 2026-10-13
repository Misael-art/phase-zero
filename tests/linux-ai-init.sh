#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export HOME="$WORK/home"
mkdir -p "$HOME"

step() { echo "step: $*" >&2; }

PROJECT="$WORK/project"
mkdir -p "$PROJECT"
printf '# My project\n\ncustom content\n' > "$PROJECT/AGENTS.md"

step "dry-run"
dry="$("$ROOT/linux/pz" ai init --dry-run "$PROJECT" | tail -1)"
jq -e '.dryRun == true and (.plannedFiles | length) >= 15' <<< "$dry" >/dev/null
[ ! -f "$PROJECT/CLAUDE.md" ]

step "init"
out="$("$ROOT/linux/pz" ai init "$PROJECT" | tail -1)"
jq -e '.status == "ready" and .wrote.rules == true and .wrote.frugality == true' <<< "$out" >/dev/null

step "init wrote rule files"
grep -q 'custom content' "$PROJECT/AGENTS.md"
grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$PROJECT/AGENTS.md"
grep -q 'BEGIN PHASEZERO TOOLS' "$PROJECT/CLAUDE.md"
grep -q 'BEGIN PHASEZERO TOOLS' "$PROJECT/GEMINI.md"
grep -q 'BEGIN PHASEZERO TOOLS' "$PROJECT/.github/copilot-instructions.md"
[ -f "$PROJECT/.cursor/rules/caveman.mdc" ]
[ -f "$PROJECT/.windsurf/rules/phasezero-tools.md" ]
[ -f "$PROJECT/.clinerules/phasezero-tools.md" ]

step "init wrote frugality + vscode"
[ -f "$PROJECT/.codex/ai-context/frugality-manifest.json" ]
[ -f "$PROJECT/.codex/context-packs/ai-context-frugality.md" ]
grep -q 'PHASEZERO AI CONTEXT FRUGALITY' "$PROJECT/.aiderignore"
jq -e '.recommendations | length >= 5' "$PROJECT/.vscode/extensions.json" >/dev/null
[ ! -e "$PROJECT/.zcode" ]

step "registered in projects.json"
"$ROOT/linux/pz" ai init --list \
    | jq -e --arg p "$PROJECT" '.projects[] | select(.path == $p) | .lastStatus == "ready" and (.agents | index("cline") != null) and (.agents | index("grok-build") != null) and (.agents | index("kimi-code") != null) and (.agents | index("zcode") != null) and .zcodeDedicatedRules == false' >/dev/null

step "re-init without --force exits 3"
rc=0
"$ROOT/linux/pz" ai init "$PROJECT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ]

step "re-init with --force"
"$ROOT/linux/pz" ai init --force "$PROJECT" | tail -1 | jq -e '.status == "ready"' >/dev/null

step "status"
"$ROOT/linux/pz" ai init --status "$PROJECT" | tail -1 \
    | jq -e '.initialized == true and .registered == true and .rulesHashMatch == true and .frugalityConfigured == true' >/dev/null

step "zcode opt-in"
"$ROOT/linux/pz" ai init --force --zcode "$PROJECT" >/dev/null
[ -f "$PROJECT/.zcode/rules/caveman.md" ]
[ -f "$PROJECT/.zcode/rules/phasezero-tools.md" ]
"$ROOT/linux/pz" ai init --list \
    | jq -e --arg p "$PROJECT" '.projects[] | select(.path == $p) | (.agents | index("zcode") != null) and .zcodeDedicatedRules == true' >/dev/null

step "register existing without project mutation"
before_hash="$(sha256sum "$PROJECT/AGENTS.md" | awk '{print $1}')"
"$ROOT/linux/pz" ai init --register-existing "$PROJECT" \
    | jq -e '.status == "ready" and .modifiedProjectFiles == false' >/dev/null
after_hash="$(sha256sum "$PROJECT/AGENTS.md" | awk '{print $1}')"
[ "$before_hash" = "$after_hash" ]
"$ROOT/linux/pz" ai compat status \
    | jq -e --arg p "$PROJECT" '.workspaceRoot == $p and .workspaceSource == "registered" and .rules.ok == true and (.integrations.clients | map(.id) | index("zcode") != null)' >/dev/null

step "undo"
"$ROOT/linux/pz" ai init --undo "$PROJECT" >/dev/null
grep -q 'custom content' "$PROJECT/AGENTS.md"
if grep -q 'BEGIN PHASEZERO TOOLS' "$PROJECT/AGENTS.md"; then
    echo "FAIL: undo left PHASEZERO TOOLS marker in AGENTS.md"
    exit 1
fi
if grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$PROJECT/AGENTS.md"; then
    echo "FAIL: undo left BOOTSTRAP CAVEMAN marker in AGENTS.md"
    exit 1
fi
[ ! -f "$PROJECT/CLAUDE.md" ]
[ ! -f "$PROJECT/GEMINI.md" ]
[ ! -e "$PROJECT/.cursor" ]
[ ! -e "$PROJECT/.windsurf" ]
[ ! -e "$PROJECT/.clinerules" ]
[ ! -e "$PROJECT/.zcode" ]
[ ! -f "$PROJECT/.aiderignore" ]
[ ! -e "$PROJECT/.codex" ]
"$ROOT/linux/pz" ai init --list \
    | jq -e --arg p "$PROJECT" '[.projects[] | select(.path == $p)] | length == 0' >/dev/null

echo "linux-ai-init smoke ok"
