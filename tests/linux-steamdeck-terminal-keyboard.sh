#!/usr/bin/env bash
# Hermetic: a touch in Ashyterm asks the KWin keyboard to open. The
# touchscreen is a fixture file. Nothing opens /dev/input or the live KWin.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$TMP/run"
export XDG_STATE_HOME="$TMP/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" "$TMP/bin"

export PATH="$TMP/bin:/usr/bin:/bin"
export PZ_INPUT_DEVICES_FILE="$TMP/devices"
export PZ_TERMINAL_KEYBOARD_STAMP="$TMP/stamp"
export PZ_TERMINAL_KEYBOARD_DEBOUNCE_MS=800
export PZ_SYSTEMD_USER_DIR="$TMP/systemd"
SCRIPT="$REPO_ROOT/linux/steamdeck/terminal-keyboard.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$PZ_INPUT_DEVICES_FILE" <<'EOF'
I: Bus=0018 Vendor=2808 Product=1015 Version=0100
N: Name="FTS3528:00 2808:1015"
P: Phys=i2c-FTS3528:00
H: Handlers=event9 mouse1
B: PROP=2

I: Bus=0018 Vendor=2808 Product=1015 Version=0100
N: Name="FTS3528:00 2808:1015 UNKNOWN"
P: Phys=i2c-FTS3528:00
H: Handlers=event10 mouse2
B: PROP=0

I: Bus=0003 Vendor=28de Product=1205 Version=0110
N: Name="SCController Mouse"
P: Phys=py-evdev-uinput
H: Handlers=event17 mouse0
B: PROP=0

EOF

picked="$(bash "$SCRIPT" pick-device)"
[ "$picked" = /dev/input/event9 ] || fail "picker chose $picked"

bash "$SCRIPT" is-terminal org.communitybig.ashyterm || fail "Ashyterm class rejected"
bash "$SCRIPT" is-terminal ashyterm || fail "ashyterm short name rejected"
if bash "$SCRIPT" is-terminal org.kde.dolphin; then
    fail "Dolphin counted as a terminal"
fi

if grep -q EVIOCGRAB "$SCRIPT"; then
    fail "watcher must not grab the touchscreen"
fi

python3 - "$TMP/events" <<'PY'
import struct
import sys

def ev(typ, code, value):
    return struct.pack("16xHHi", typ, code, value)

blob = b"".join([
    ev(3, 53, 10),   # ABS noise
    ev(1, 330, 1),   # BTN_TOUCH down
    ev(1, 330, 0),   # release
    ev(1, 330, 1),   # second down, inside the debounce window
])
open(sys.argv[1], "wb").write(blob)
PY

cat >"$TMP/bin/open-keyboard" <<EOF
#!/usr/bin/env bash
printf 'open\n' >> "$TMP/open.log"
EOF
chmod +x "$TMP/bin/open-keyboard"

run_drain() {
    : >"$TMP/open.log"
    rm -f "$PZ_TERMINAL_KEYBOARD_STAMP"
    PZ_TOUCH_DEVICE="$TMP/events" \
        PZ_TERMINAL_KEYBOARD_CLASS="$1" \
        PZ_TERMINAL_KEYBOARD_VISIBLE="$2" \
        PZ_TERMINAL_KEYBOARD_OPEN_CMD="$TMP/bin/open-keyboard" \
        bash "$SCRIPT" drain "$TMP/events"
}

run_drain org.communitybig.ashyterm false
[ "$(grep -c '^open$' "$TMP/open.log")" = 1 ] || fail "Ashyterm touch did not open once: $(cat "$TMP/open.log")"

run_drain org.communitybig.ashyterm true
[ ! -s "$TMP/open.log" ] || fail "visible panel was opened again"

run_drain org.kde.dolphin false
[ ! -s "$TMP/open.log" ] || fail "Dolphin touch opened the keyboard"

PZ_DRY_RUN=1 bash "$SCRIPT" install | grep -q 'dry-run' || fail "dry-run silent"
[ ! -e "$PZ_SYSTEMD_USER_DIR/phasezero-terminal-keyboard.service" ] || fail "dry-run wrote the unit"

bash "$SCRIPT" install >/dev/null
unit="$PZ_SYSTEMD_USER_DIR/phasezero-terminal-keyboard.service"
grep -q 'WantedBy=graphical-session.target' "$unit" || fail "unit is not tied to the graphical session"
grep -q 'terminal-keyboard.sh watch' "$unit" || fail "unit does not run the watcher"
if grep -q 'systemctl' "$unit"; then
    fail "unit must not call systemctl"
fi

grep -q 'terminal-keyboard.sh' "$REPO_ROOT/linux/pz" || fail "pz does not dispatch terminal-keyboard"

printf 'ok\n'
