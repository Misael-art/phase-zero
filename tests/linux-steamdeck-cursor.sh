#!/usr/bin/env bash
# Hermetic pointer-handoff tests. The probe is read-only: no grab, no
# service restart, no KWin restart. It must not claim a cause.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$TMP/bin"

export PATH="$TMP/bin:/usr/bin:/bin"
export PZ_INPUT_DEVICES_FILE="$TMP/devices"
export PZ_SYSTEMCTL="$TMP/bin/systemctl"
export PZ_SYSTEMCTL_LOG="$TMP/systemctl.log"
export PZ_QDBUS6="$TMP/bin/qdbus6"
export PZ_QDBUS_LOG="$TMP/qdbus.log"
: > "$PZ_SYSTEMCTL_LOG"
: > "$PZ_QDBUS_LOG"

cat > "$PZ_INPUT_DEVICES_FILE" <<'EOF'
I: Bus=0018 Vendor=2808 Product=1015 Version=0100
N: Name="FTS3528:00 2808:1015"
P: Phys=i2c-FTS3528:00
H: Handlers=event9 mouse1

I: Bus=0003 Vendor=046d Product=c52b Version=0111
N: Name="Logitech Wireless Mouse"
H: Handlers=event6 mouse0

I: Bus=0003 Vendor=0000 Product=0000 Version=0001
N: Name="SCController Keyboard"
H: Handlers=event16

I: Bus=0003 Vendor=0000 Product=0000 Version=0001
N: Name="SCController Mouse"
H: Handlers=event17 mouse3
EOF

cat > "$PZ_SYSTEMCTL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_SYSTEMCTL_LOG"
if printf '%s' "$*" | grep -Eq '(^| )(restart|reboot|poweroff|stop|start|isolate|kill)( |$)'; then
    printf 'forbidden systemctl action\n' >&2
    exit 99
fi
if printf '%s' "$*" | grep -q 'is-active'; then
    printf 'active\n'
    exit 0
fi
if printf '%s' "$*" | grep -q 'NRestarts'; then
    printf '0\n'
    exit 0
fi
printf 'unexpected systemctl: %s\n' "$*" >&2
exit 97
EOF

cat > "$PZ_QDBUS6" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PZ_QDBUS_LOG"
prop="${*: -1}"
case "$prop" in
    enabled|pointer) printf 'true\n' ;;
    *) printf 'false\n' ;;
esac
exit 0
EOF
chmod +x "$PZ_SYSTEMCTL" "$PZ_QDBUS6"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if grep -q 'EVIOCGRAB' "$REPO_ROOT/linux/steamdeck/cursor-diagnose.sh"; then
    fail "cursor diagnose grabs the input device"
fi
if grep -E -q 'systemctl[[:space:]]+(restart|reboot|poweroff)' "$REPO_ROOT/linux/steamdeck/cursor-diagnose.sh"; then
    fail "cursor diagnose restarts a service"
fi

snapshot="$(bash "$REPO_ROOT/linux/steamdeck/cursor-diagnose.sh" snapshot)"
jq -e . >/dev/null <<<"$snapshot" || fail "snapshot is not JSON"
jq -e '.grabbed == false and .serviceRestarted == false and .mutated == false' >/dev/null <<<"$snapshot" || fail "snapshot claims a mutation"
jq -e '.conclusion == "not-proven"' >/dev/null <<<"$snapshot" || fail "snapshot claimed a cause without motion"
jq -e '.devices.sccMouse.event == "event17" and .devices.sccMouse.present == true' >/dev/null <<<"$snapshot" || fail "scc mouse node"
jq -e '.devices.sccKeyboard.event == "event16"' >/dev/null <<<"$snapshot" || fail "scc keyboard node"
jq -e '.devices.externalPointer.present == true and .devices.externalPointer.name == "Logitech Wireless Mouse"' >/dev/null <<<"$snapshot" || fail "external recovery pointer"
jq -e '.controllerService.active == "active" and .controllerService.nRestarts == 0' >/dev/null <<<"$snapshot" || fail "service state"
jq -e '.kwin.mouseEnabled == true and .kwin.mousePointer == true and .sample.ran == false' >/dev/null <<<"$snapshot" || fail "kwin or sample flags"
grep -q 'org.freedesktop.DBus.Properties.Get' "$PZ_QDBUS_LOG" || fail "kwin property was not read with Properties.Get"
if grep -F -q 'org.kde.KWin.InputDevice.enabled' "$PZ_QDBUS_LOG"; then
    fail "kwin property used the method form that KWin rejects"
fi
if grep -E -q '(^| )(restart|reboot|poweroff|stop|start)( |$)' "$PZ_SYSTEMCTL_LOG"; then
    fail "systemctl log shows a mutating action: $(cat "$PZ_SYSTEMCTL_LOG")"
fi

# sample of a missing node records the failure and still does not grab.
sample="$(PZ_CURSOR_EVENT_PATH="$TMP/missing-event" bash "$REPO_ROOT/linux/steamdeck/cursor-diagnose.sh" sample 0.1)"
jq -e '.grabbed == false and .conclusion == "not-proven" and .sample.ran == true and .sample.permission == "missing"' >/dev/null <<<"$sample" || fail "missing event node was not reported as missing: $sample"

# Session return writes the handoff and still starts the desktop.
: > "$PZ_SYSTEMCTL_LOG"
cat > "$TMP/bin/steam" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
fake_gamescope="$TMP/bin/fake-gamescope"
fake_desktop="$TMP/bin/fake-desktop"
cat > "$fake_gamescope" <<'EOF'
#!/usr/bin/env bash
printf 'desktop\n' > "${XDG_RUNTIME_DIR}/phasezero-steamos/session-target"
EOF
cat > "$fake_desktop" <<'EOF'
#!/usr/bin/env bash
touch "${XDG_RUNTIME_DIR}/desktop-started"
EOF
chmod +x "$TMP/bin/steam" "$fake_gamescope" "$fake_desktop"
PZ_STEAMOS_GAMESCOPE_BIN="$fake_gamescope" PZ_STEAMOS_DESKTOP_BIN="$fake_desktop" \
    bash "$REPO_ROOT/linux/steamdeck/steamos-session.sh"
test -f "$XDG_RUNTIME_DIR/desktop-started" || fail "desktop did not start"
handoff="$XDG_STATE_HOME/phasezero/steamos/cursor-handoff.json"
test -f "$handoff" || fail "cursor handoff was not recorded"
jq -e '.grabbed == false and .serviceRestarted == false and .mutated == false and .conclusion == "not-proven"' >/dev/null <"$handoff" || fail "handoff is not an honest snapshot"
if grep -E -q '(^| )(restart|reboot|poweroff)( |$)' "$PZ_SYSTEMCTL_LOG"; then
    fail "session handoff restarted a service"
fi
# The handoff is recorded before the target dispatch, including reboot.
awk '
    /cursor-diagnose.sh/ { seen = NR }
    /^case "\$target"/ { if (!seen || seen > NR) exit 1; exit 0 }
    END { if (!seen) exit 1 }
' "$REPO_ROOT/linux/steamdeck/steamos-session.sh" || fail "handoff is not before session dispatch"

printf 'linux-steamdeck-cursor ok\n'
