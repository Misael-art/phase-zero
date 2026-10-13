#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
export PZ_LOCAL_BIN="$HOME/.local/bin"
export PZ_KDE_PZ_BIN="$TMP_ROOT/runtime/linux/pz"
export PZ_TEST_LOG="$TMP_ROOT/actions.log"
mkdir -p "$TMP_ROOT/runtime/linux/steamdeck" "$TMP_ROOT/stubs"

cat > "$PZ_KDE_PZ_BIN" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "ai 9router status") printf '%s\n' '{"installed":true,"healthy":true}' ;;
  "windows-vm status --json") printf '%s\n' '{"health":{"readyToLaunch":true,"bootDirectReady":false}}' ;;
  "ai proxies detailed-status") printf '%s\n' '{"schemaVersion":1,"proxies":[]}' ;;
  *) printf '%s\n' "$*" >> "$PZ_TEST_LOG" ;;
esac
SH
chmod +x "$PZ_KDE_PZ_BIN"

cat > "$TMP_ROOT/runtime/linux/steamdeck/voice-typing.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"whisper":"whisper-cli","modelPresent":true,"recorder":true}'
SH
chmod +x "$TMP_ROOT/runtime/linux/steamdeck/voice-typing.sh"

cat > "$TMP_ROOT/stubs/kdialog" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_TEST_LOG"
exit 0
SH
chmod +x "$TMP_ROOT/stubs/kdialog"

python3 "$ROOT/scripts/generate_icons.py" >/dev/null
if grep -R -E '\{(accent|muted|bg)\}' "$ROOT/assets/icons/hicolor/scalable/apps"/*.svg; then
    echo "FAIL: unresolved icon template token" >&2
    exit 1
fi
mkdir -p "$XDG_DATA_HOME/icons/hicolor"
cp "$ROOT/assets/icons/hicolor/index.theme" "$XDG_DATA_HOME/icons/hicolor/index.theme"
mkdir -p "$XDG_CACHE_HOME"
printf '%s\n' 'stale-cache-fixture' > "$XDG_CACHE_HOME/icon-cache.kcache"
bash "$ROOT/linux/ui/kde-launchers.sh" install >/dev/null
test ! -e "$XDG_DATA_HOME/icons/hicolor/index.theme"
test ! -e "$XDG_CACHE_HOME/icon-cache.kcache"
test -s "$XDG_STATE_HOME/phasezero/kde-launchers/hicolor-cache-v2"

payload="$(bash "$ROOT/linux/ui/kde-launchers.sh" verify)"
jq -e '.ready == true and .summary.total == 25 and .summary.launcherReady == 25 and .summary.desktopReady == 25 and .summary.iconReady == 25' <<< "$payload" >/dev/null
jq -e '[.items[] | select(.backend == "blocked-policy")] | length == 3' <<< "$payload" >/dev/null

count=0
for desktop in "$XDG_DATA_HOME"/applications/phasezero-*.desktop; do
    desktop-file-validate "$desktop"
    grep -Eq '^Icon=(phasezero-|io\.phasezero\.|system-reboot$)' "$desktop"
    grep -q '^X-PhaseZero-Managed=true$' "$desktop"
    grep -q '^X-PhaseZero-MenuGroup=' "$desktop"
    count=$((count + 1))
done
[ "$count" -eq 24 ]
test -f "$XDG_DATA_HOME/applications/io.phasezero.ControlCenter.desktop"
if [ -f "$XDG_DATA_HOME/applications/org.steamzero.SteamZero.desktop" ]; then
    grep -q '^NoDisplay=true$' "$XDG_DATA_HOME/applications/org.steamzero.SteamZero.desktop"
    grep -q '^X-PhaseZero-SuppressedBy=phasezero-port-steam.desktop$' "$XDG_DATA_HOME/applications/org.steamzero.SteamZero.desktop"
fi

PATH="$TMP_ROOT/stubs:$PATH" "$PZ_LOCAL_BIN/phasezero-kde-launch" 9router
grep -qx 'ai 9router dashboard' "$PZ_TEST_LOG"

PATH="$TMP_ROOT/stubs:$PATH" "$PZ_LOCAL_BIN/phasezero-kde-launch" windows-vm
grep -qx 'windows-vm launch --fullscreen' "$PZ_TEST_LOG"

set +e
PATH="$TMP_ROOT/stubs:$PATH" "$PZ_LOCAL_BIN/phasezero-kde-launch" reboot-windows-vm
reboot_rc=$?
PATH="$TMP_ROOT/stubs:$PATH" "$PZ_LOCAL_BIN/phasezero-kde-launch" proxy-kimi
proxy_rc=$?
set -e
[ "$reboot_rc" -eq 69 ]
[ "$proxy_rc" -eq 69 ]
if grep -q 'windows-vm boot next-reboot' "$PZ_TEST_LOG"; then
    echo "FAIL: blocked reboot reached mutating action" >&2
    exit 1
fi

cat > "$XDG_DATA_HOME/icons/hicolor/index.theme" <<'EOF'
[Icon Theme]
Name=User custom hicolor overlay
Directories=scalable/apps,256x256/apps
EOF
custom_index_sha="$(sha256sum "$XDG_DATA_HOME/icons/hicolor/index.theme" | awk '{print $1}')"
before="$(find "$XDG_DATA_HOME/applications" "$XDG_DATA_HOME/icons" "$PZ_LOCAL_BIN" -type f -exec sha256sum {} + | sort)"
bash "$ROOT/linux/ui/kde-launchers.sh" install >/dev/null
after="$(find "$XDG_DATA_HOME/applications" "$XDG_DATA_HOME/icons" "$PZ_LOCAL_BIN" -type f -exec sha256sum {} + | sort)"
[ "$before" = "$after" ]
[ "$(sha256sum "$XDG_DATA_HOME/icons/hicolor/index.theme" | awk '{print $1}')" = "$custom_index_sha" ]

echo "linux-kde-launchers smoke ok"
