#!/usr/bin/env bash
# AISR-004: `setup-agent-compat.sh rules` with no project must refuse instead
# of writing /AGENTS.md, /CLAUDE.md, ... (only file permissions stopped it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_CONFIG_HOME="$WORK/config"
export XDG_STATE_HOME="$WORK/state"
export XDG_DATA_HOME="$WORK/data"
export PZ_LOCAL_BIN="$WORK/bin"
unset PZ_WORKSPACE_ROOT
mkdir -p "$HOME"

# Run from a scratch cwd; nothing may be created outside the sandbox.
cd "$WORK"
rc=0
out="$("$ROOT/linux/ai/setup-agent-compat.sh" rules 2>"$WORK/err")" || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: rules without project exited $rc" >&2; cat "$WORK/err" >&2; exit 1; }
jq -e '.mode == "needs-project" and (.next | test("ai init"))' <<< "$out" >/dev/null
if grep -q "/AGENTS.md" "$WORK/err"; then exit 1; fi

# Defense in depth: apply_rules itself refuses empty, / and $HOME.
for bad in "" / "$HOME"; do
    rc=0
    PZ_WORKSPACE_ROOT="$bad" "$ROOT/linux/ai/setup-agent-compat.sh" rules >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { echo "FAIL: rules accepted workspace '$bad'" >&2; exit 1; }
done
[ ! -e "$HOME/AGENTS.md" ]

# A real project still receives the managed blocks.
mkdir -p "$WORK/project"
PZ_WORKSPACE_ROOT="$WORK/project" "$ROOT/linux/ai/setup-agent-compat.sh" rules >/dev/null
grep -q 'BEGIN BOOTSTRAP CAVEMAN' "$WORK/project/AGENTS.md"

echo "PASS: agent rules require a project"
