#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
export PZ_DUALSCREEN_LIB_ONLY=1
export PZ_DUALSCREEN_SKIP_RECONFIGURE=1
mkdir -p "$XDG_CONFIG_HOME"

cat > "$XDG_CONFIG_HOME/kwinrulesrc" <<'EOF'
[keep-id]
Description=User rule
wmclass=user-app

[old-managed]
Description=PhaseZero dualscreen: cemu-main
pb_dualscreen_managed=true
wmclass=Cemu

[General]
activity=true
count=2
rules=keep-id,old-managed
EOF

# shellcheck disable=SC1091
source "$REPO_ROOT/linux/emulation/dualscreen.sh"

dualscreen_kwin_rule_block \
    "new-managed" "PhaseZero dualscreen: cemu-pad" "Cemu" "1" "0,0" "false" |
    dualscreen_kwin_write_rules cemu

config="$(<"$KWINRULES")"
grep -q '^\[keep-id\]$' <<< "$config"
grep -q '^\[new-managed\]$' <<< "$config"
if grep -q '^\[old-managed\]$' <<< "$config"; then exit 1; fi
grep -q '^activity=true$' <<< "$config"
grep -q '^count=2$' <<< "$config"
grep -q '^rules=keep-id,new-managed$' <<< "$config"

dualscreen_kwin_remove_all
config="$(<"$KWINRULES")"
grep -q '^\[keep-id\]$' <<< "$config"
if grep -q 'PhaseZero dualscreen:' <<< "$config"; then exit 1; fi
grep -q '^count=1$' <<< "$config"
grep -q '^rules=keep-id$' <<< "$config"
find "$PZ_BACKUP_ROOT" -type f -name 'kwinrulesrc.bak.*' -print -quit | grep -q .

# A diagnostic never hangs: kscreen-doctor blocks forever without a KDE
# session, so the call is bounded and detect still answers with connectors.
stub_bin="$TMP_ROOT/stubbin"
mkdir -p "$stub_bin"
cat > "$stub_bin/kscreen-doctor" <<'EOS'
#!/usr/bin/env bash
sleep 300
EOS
chmod +x "$stub_bin/kscreen-doctor"
started="$(date +%s)"
PATH="$stub_bin:$PATH" env -u PZ_DUALSCREEN_LIB_ONLY timeout 40 \
    bash "$REPO_ROOT/linux/emulation/dualscreen.sh" detect \
    > "$TMP_ROOT/detect.json" 2>"$TMP_ROOT/detect.err"
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 30 ] || { echo "FAIL: detect levou ${elapsed}s com kscreen-doctor travado"; exit 1; }
jq -e '.externalKwinIndex == "unknown" and .internalKwinIndex == "unknown"' \
    "$TMP_ROOT/detect.json" >/dev/null
echo "  detect bounded with a stuck kscreen-doctor ok"

echo "linux dualscreen tests passed"
