#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/linux/ai/desktop-apps.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$SCRIPT"
bash -n "$ROOT/linux/pz"
bash -n "$ROOT/linux/ai/menu.sh"
bash -n "$ROOT/linux/ai/status.sh"
bash -n "$ROOT/linux/ai/setup-desktop-apps.sh"
bash -n "$ROOT/linux/audit/doctor.sh"
bash -n "$ROOT/linux/audit/repair-plan.sh"
python3 -m json.tool "$ROOT/profiles/dev-ai.json" >/dev/null
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$SCRIPT"
fi

status="$(
    HOME="$TMP/home" \
    XDG_DATA_HOME="$TMP/data" \
    XDG_CONFIG_HOME="$TMP/config" \
    XDG_STATE_HOME="$TMP/state" \
    XDG_CACHE_HOME="$TMP/cache" \
    "$SCRIPT" status
)"
jq -e '
  .schemaVersion == 2 and
  .claudeDesktop.installed == false and
  .claudeDesktop.source == "official-anthropic-apt" and
  .qwenCodeDesktop.installed == false and
  .qwenCodeDesktop.source == "official-qwen-github-release" and
  .codexDesktop.repairedPackageReady == false
' <<< "$status" >/dev/null || fail "clean status schema"

# A ready Desktop package must pass through the upstream installer and be
# observed in the package database; no host package operation runs in fixture.
mkdir -p "$TMP/codex-stubs"
cat > "$TMP/codex-stubs/codex-update-manager" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    status) echo '{"status":"ready_to_install","candidate_version":"2026.07.20.091033+3e5055c1"}' ;;
    diagnose) printf '{"app":{"running":%s}}\n' "${CODEX_TEST_RUNNING:-false}" ;;
    install-ready) echo install-ready >> "$CODEX_TEST_LOG" ;;
    *) exit 2 ;;
esac
EOF
cat > "$TMP/codex-stubs/pacman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -Q ] && [ "$2" = codex-desktop ]; then
    printf 'codex-desktop %s\n' "$CODEX_TEST_INSTALLED"
else
    exit 2
fi
EOF
chmod +x "$TMP/codex-stubs/codex-update-manager" "$TMP/codex-stubs/pacman"
CODEX_TEST_LOG="$TMP/codex-install.log" \
CODEX_TEST_INSTALLED='2026.07.20.091033+3e5055c1-1' \
PATH="$TMP/codex-stubs:$PATH" \
HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
"$SCRIPT" apply-codex >/dev/null || fail "ready Codex Desktop install"
[ "$(cat "$TMP/codex-install.log")" = install-ready ] || fail "upstream install-ready not used"
if CODEX_TEST_LOG="$TMP/codex-install.log" CODEX_TEST_RUNNING=true \
    CODEX_TEST_INSTALLED='2026.07.20.091033+3e5055c1-1' \
    PATH="$TMP/codex-stubs:$PATH" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
    "$SCRIPT" apply-codex >/dev/null 2>&1; then
    fail "running Codex Desktop update accepted"
fi
[ "$(wc -l < "$TMP/codex-install.log")" -eq 1 ] || fail "installer ran while Codex Desktop active"
if CODEX_TEST_LOG="$TMP/codex-install.log" CODEX_TEST_INSTALLED='2026.07.20.022256-1' \
    PATH="$TMP/codex-stubs:$PATH" HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" \
    "$SCRIPT" apply-codex >/dev/null 2>&1; then
    fail "unconfirmed Codex Desktop install accepted"
fi

mkdir -p "$TMP/workspaces/candidate/builder/scripts" "$TMP/seed/assets" "$TMP/seed/record-replay-linux"
printf 'png\n' > "$TMP/seed/assets/codex-linux.png"
printf 'feature\n' > "$TMP/seed/record-replay-linux/README"
cat > "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh" <<'EOF'
#!/usr/bin/env bash
local pkg_file=""
EOF
chmod 0755 "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh"

HOME="$TMP/home" \
XDG_STATE_HOME="$TMP/state" \
XDG_CACHE_HOME="$TMP/cache" \
PZ_CODEX_UPDATE_BUILDER="$TMP/seed" \
PZ_CLAUDE_ROOT="$TMP/claude" \
PZ_CLAUDE_CACHE="$TMP/claude-cache" \
PZ_LOCAL_BIN="$TMP/bin" \
PZ_CODEX_WORKSPACES="$TMP/workspaces" \
"$SCRIPT" codex-guard-once >/dev/null

[ -f "$TMP/workspaces/candidate/builder/assets/codex-linux.png" ] ||
    fail "Codex icon seed"
[ -f "$TMP/workspaces/candidate/builder/record-replay-linux/README" ] ||
    fail "Codex feature seed"
grep -q PHASEZERO_PKGEXT_COMPAT "$TMP/workspaces/candidate/builder/scripts/build-pacman.sh" ||
    fail "Codex package format patch"

help="$("$ROOT/linux/pz" help)"
grep -q 'pz ai desktop install-claude' <<< "$help" || fail "CLI help integration"
grep -q 'pz ai desktop install-qwen' <<< "$help" || fail "Qwen CLI help integration"
grep -q 'setup-desktop-apps.sh' "$ROOT/profiles/dev-ai.json" || fail "dev-ai profile integration"
grep -q 'install-qwen' "$ROOT/linux/ai/setup-desktop-apps.sh" || fail "Qwen setup integration"

echo "PASS: linux AI desktop manager"

# All update/help tests use a private systemctl stub, never the host bus.
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${TIMER_CASE:-disabled}:$*" in
    fail:*) exit 1 ;;
    disable-fail:*disable*) exit 1 ;;
esac
if [[ "$*" == *--value* ]]; then
    [[ "${TIMER_CASE:-}" == missing ]] && echo not-found || echo loaded
elif [[ "$*" == *show* ]]; then
    if [[ "${TIMER_CASE:-}" == missing ]]; then
        printf 'LoadState=not-found\nActiveState=inactive\nUnitFileState=\n'
    elif [[ "${TIMER_CASE:-}" == still-active ]]; then
        printf 'LoadState=loaded\nActiveState=active\nUnitFileState=disabled\n'
    else
        printf 'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n'
    fi
fi
EOF
chmod +x "$TMP/stubs/systemctl"
for scenario in disabled missing; do
    for repeat in 1 2; do
        PATH="$TMP/stubs:$PATH" TIMER_CASE="$scenario" HOME="$TMP/home" \
        XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" \
        XDG_CACHE_HOME="$TMP/cache" "$SCRIPT" disable-updates >/dev/null || fail "disable $scenario $repeat"
    done
done
for scenario in fail disable-fail still-active; do
    if PATH="$TMP/stubs:$PATH" TIMER_CASE="$scenario" HOME="$TMP/home" \
       XDG_CONFIG_HOME="$TMP/config" XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" \
       XDG_CACHE_HOME="$TMP/cache" "$SCRIPT" disable-updates >"$TMP/output" 2>&1; then
        fail "false disable success: $scenario"
    fi
    ! grep -q 'automatic updates disabled' "$TMP/output" || fail "false success message"
done
for flag in help --help -h; do
    PATH="$TMP/stubs:$PATH" TIMER_CASE=fail HOME="$TMP/help-home" \
    XDG_CONFIG_HOME="$TMP/help-config" XDG_DATA_HOME="$TMP/help-data" \
    XDG_STATE_HOME="$TMP/help-state" XDG_CACHE_HOME="$TMP/help-cache" \
    "$ROOT/linux/pz" ai "$flag" >"$TMP/help" || fail "AI help $flag"
    grep -q 'pz ai quota' "$TMP/help" || fail "quota missing in AI help"
    [[ ! -e "$TMP/help-home" && ! -e "$TMP/help-data" && ! -e "$TMP/help-state" ]] || fail "help mutates state"
done
echo 'PASS: update state confirmation and AI help'
