#!/usr/bin/env bash
# AISR-012: installed runtime copies must be compared with the repo so fixes
# that never reached the host are visible (status exit 2 on drift).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_DATA_HOME="$WORK/data"
export PZ_CC_INSTALLER_ROOT="$WORK/cc"
RUNTIME="$XDG_DATA_HOME/phasezero/runtime"
mkdir -p "$HOME" "$RUNTIME" "$PZ_CC_INSTALLER_ROOT/tools/hand-made"

# In sync: the installer's PZ_ROOT pin is the only difference.
sed "s|^PZ_ROOT=\"\"\$|PZ_ROOT=\"/some/checkout\"|" "$ROOT/linux/ai/hermes-router.sh" > "$RUNTIME/hermes-router.sh"
# Drift: an older copy.
{ cat "$ROOT/linux/ai/9router-hermes-provider.sh"; echo "# stale"; } > "$RUNTIME/9router-hermes-provider.sh"
echo 'echo hi' > "$PZ_CC_INSTALLER_ROOT/tools/hand-made/runner"

rc=0
out="$("$ROOT/linux/pz" ai drift status)" || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: drift status exited $rc" >&2; exit 1; }
jq -e '
  .state == "drift" and .nextAction == "linux/pz ai drift sync"
  and (.copies[] | select(.name == "hermes-router") | .state == "in-sync")
  and (.copies[] | select(.name == "9router-hermes-provider") | .state == "drift")
  and (.copies[] | select(.name == "desktop-apps") | .state == "not-installed")
  and (.unmanagedCopies | length == 1)
' <<< "$out" >/dev/null || { echo "FAIL: unexpected drift report: $out" >&2; exit 1; }

plan="$("$ROOT/linux/pz" ai drift sync --dry-run)"
grep -qx 'would refresh 9router-hermes-provider: bash linux/ai/9router-hermes-provider.sh install' <<< "$plan"
if grep -q 'hermes-router:' <<< "$plan"; then exit 1; fi

# Back in sync: exit 0.
sed "s|^PZ_ROOT=\"\"\$|PZ_ROOT=\"/x\"|" "$ROOT/linux/ai/9router-hermes-provider.sh" > "$RUNTIME/9router-hermes-provider.sh"
"$ROOT/linux/pz" ai drift status | jq -e '.state == "in-sync" and .nextAction == ""' >/dev/null

echo "PASS: runtime drift reported"
