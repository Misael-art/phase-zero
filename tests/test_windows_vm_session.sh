#!/usr/bin/env bash
# Hermetic contract for the direct-boot Windows VM session lifecycle:
# graceful shutdown paths, unclean-end classification and session state.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME"

STATE_DIR="$XDG_STATE_HOME/phasezero/windows-vm"
mkdir -p "$STATE_DIR"
SESSION_STATE="$STATE_DIR/session-state.json"
STOP_FILE="$STATE_DIR/shutdown.requested"

# The session script resolves its display helper and rescue wizard from its own
# directory, so mirror the package layout and stub only the rescue wizard.
PKG_DIR="$TEST_ROOT/pkg"
mkdir -p "$PKG_DIR/linux/windows-vm" "$PKG_DIR/linux/steamdeck" "$TEST_ROOT/sys"
cp "$REPO_ROOT/linux/windows-vm/windows-vm-session.sh" "$PKG_DIR/linux/windows-vm/"
cp "$REPO_ROOT/linux/steamdeck/display-session.sh" "$PKG_DIR/linux/steamdeck/"
printf '%s\n' 'vm_rescue_run() { return 1; }' > "$PKG_DIR/linux/windows-vm/rescue.sh"

# Fake runtime tree: runtime_tree_usable() only needs the launcher plus the
# three library files, so the stub below IS the whole runtime.
RUNTIME_DIR="$TEST_ROOT/rt"
mkdir -p "$RUNTIME_DIR/linux/windows-vm" "$RUNTIME_DIR/linux/lib"
: > "$RUNTIME_DIR/linux/lib/common.sh"
: > "$RUNTIME_DIR/linux/lib/ledger.sh"
: > "$RUNTIME_DIR/linux/lib/desktop.sh"
cat > "$RUNTIME_DIR/linux/windows-vm/windows-vm.sh" <<'STUB'
#!/usr/bin/env bash
# Fake runtime launcher: "guest-login shutdown" simulates QGA accepting the
# shutdown; "launch" follows the mode file so tests can model guest exits,
# crashes and start failures.
set -u
STUB_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
MODE_FILE="$STUB_STATE/stub.mode"
MARKER="$STUB_STATE/stub.guest-shutdown"
case "${1:-}" in
    guest-login)
        mkdir -p "$(dirname "$MARKER")"
        touch "$MARKER"
        exit 0
        ;;
    graphics)
        # plan probe: eligibility toggled by a marker file
        if [ -e "$STUB_STATE/virtio-gl-eligible" ]; then
            printf '%s\n' '{"eligible":true}'
        else
            printf '%s\n' '{"eligible":false}'
        fi
        exit 0
        ;;
    launch)
        mode="$(cat "$MODE_FILE" 2>/dev/null || printf 'exit0')"
        case "$mode" in
            exit0) sleep 2; exit 0 ;;
            wait-marker)
                n=0
                while [ ! -e "$MARKER" ] && [ "$n" -lt 60 ]; do
                    sleep 1
                    n=$((n + 1))
                done
                exit 0
                ;;
            quickfail) exit 7 ;;
            crash7) sleep 2; exit 7 ;;
        esac
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$RUNTIME_DIR/linux/windows-vm/windows-vm.sh"

set_stub_mode() {
    printf '%s\n' "$1" > "$STATE_DIR/stub.mode"
}

run_session() {
    # exec keeps $! pointing at timeout(1) itself when backgrounded, so the
    # signal test can TERM the session bash (timeout's child) reliably.
    exec timeout 30 env \
        HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        XDG_STATE_HOME="$XDG_STATE_HOME" XDG_DATA_HOME="$XDG_DATA_HOME" \
        PZ_WINDOWS_VM_ENV_FILE="$TEST_ROOT/phasezero-no.env" \
        PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$RUNTIME_DIR/linux/windows-vm/windows-vm.sh" \
        PZ_DISPLAY_SYSFS_ROOT="$TEST_ROOT/sys" \
        PZ_WINDOWS_VM_COMPOSITOR=0 \
        PZ_WINDOWS_VM_SESSION_DESKTOP_FALLBACK=0 \
        PZ_WINDOWS_VM_SESSION_RETRY_SECONDS="${PZ_WINDOWS_VM_SESSION_RETRY_SECONDS:-1}" \
        PZ_WINDOWS_VM_SESSION_MAX_RETRIES="${PZ_WINDOWS_VM_SESSION_MAX_RETRIES:-1}" \
        PZ_WINDOWS_VM_SESSION_STABLE_SECONDS="${PZ_WINDOWS_VM_SESSION_STABLE_SECONDS:-30}" \
        bash "$PKG_DIR/linux/windows-vm/windows-vm-session.sh"
}

state_get() {
    jq -r "$1" "$SESSION_STATE"
}

# --- 1: launcher exit nobody requested -> unverified, not counted as damage.
set_stub_mode exit0
rm -f "$SESSION_STATE"
run_session >/dev/null 2>&1 &
wait $! || exit 1
[ "$(state_get .reason)" = "guest-exit-unverified" ] || { echo "FAIL: expected guest-exit-unverified" >&2; exit 2; }
[ "$(state_get .graceful)" = "true" ] || { echo "FAIL: unverified exit must stay graceful=true" >&2; exit 3; }
[ "$(state_get .elapsedSeconds)" -ge 1 ] || { echo "FAIL: elapsed not recorded" >&2; exit 4; }
[ "$(state_get .display.width)" = "1280" ] || { echo "FAIL: display not recorded" >&2; exit 5; }

# --- 2: stop file asks the guest to shut down first.
set_stub_mode wait-marker
rm -f "$SESSION_STATE" "$STATE_DIR/stub.guest-shutdown"
run_session >/dev/null 2>&1 &
SESSION_PID=$!
sleep 2
[ -e "$STOP_FILE" ] || touch "$STOP_FILE"
wait "$SESSION_PID" || { echo "FAIL: stop-file session exit" >&2; exit 6; }
[ "$(state_get .reason)" = "graceful:stop-file" ] || { echo "FAIL: expected graceful:stop-file, got $(state_get .reason)" >&2; exit 7; }
[ "$(state_get .graceful)" = "true" ] || exit 8
grep -q 'graceful stop requested (stop-file)' "$STATE_DIR/session.log" || { echo "FAIL: stop-file not logged" >&2; exit 9; }

# --- 3: SIGTERM to the session takes the guest down gracefully.
set_stub_mode wait-marker
rm -f "$SESSION_STATE" "$STATE_DIR/stub.guest-shutdown"
run_session >/dev/null 2>&1 &
SESSION_PID=$!
sleep 2
# TERM must reach the session bash, not the timeout(1) wrapper around it.
SESSION_CHILD="$(pgrep -P "$SESSION_PID" | head -n1)"
kill -TERM "$SESSION_CHILD"
wait "$SESSION_PID" || { echo "FAIL: signal session exit" >&2; exit 10; }
[ "$(state_get .reason)" = "graceful:signal" ] || { echo "FAIL: expected graceful:signal, got $(state_get .reason)" >&2; exit 11; }
[ "$(state_get .graceful)" = "true" ] || exit 12

# --- 4: crash after stable runtime -> unclean, no automatic relaunch.
set_stub_mode crash7
rm -f "$SESSION_STATE"
PZ_WINDOWS_VM_SESSION_STABLE_SECONDS=1 run_session >/dev/null 2>&1 &
RC=0
wait $! || RC=$?
[ "$RC" -eq 7 ] || { echo "FAIL: expected rc 7, got $RC" >&2; exit 13; }
[ "$(state_get .reason)" = "launcher-crash" ] || { echo "FAIL: expected launcher-crash, got $(state_get .reason)" >&2; exit 14; }
[ "$(state_get .graceful)" = "false" ] || { echo "FAIL: crash must be graceful=false" >&2; exit 15; }
grep -q 'refusing automatic relaunch' "$STATE_DIR/session.log" || { echo "FAIL: relaunch refusal not logged" >&2; exit 16; }

# --- 5: bounded start failure -> rescue declined once, give up, stays clean.
set_stub_mode quickfail
rm -f "$SESSION_STATE"
run_session >/dev/null 2>&1 &
RC=0
wait $! || RC=$?
[ "$RC" -eq 1 ] || { echo "FAIL: expected give-up rc 1, got $RC" >&2; exit 17; }
[ "$(state_get .reason)" = "start-failure" ] || { echo "FAIL: expected start-failure, got $(state_get .reason)" >&2; exit 18; }
[ "$(state_get .graceful)" = "true" ] || { echo "FAIL: start failure never touches the guest" >&2; exit 19; }
grep -q 'giving up after' "$STATE_DIR/session.log" || { echo "FAIL: give-up not logged" >&2; exit 20; }

# --- 6: eligible host -> direct boot passes the accelerated profile.
set_stub_mode exit0
rm -f "$SESSION_STATE"
touch "$STATE_DIR/virtio-gl-eligible"
run_session >/dev/null 2>&1 &
wait $! || exit 21
grep -q 'direct boot graphics: --graphics virtio-gl' "$STATE_DIR/session.log" || { echo "FAIL: eligible probe must pick virtio-gl" >&2; exit 22; }
grep -q -- '--graphics virtio-gl' < <(grep 'launching Windows VM' "$STATE_DIR/session.log" | tail -n1) || { echo "FAIL: launcher args missing virtio-gl" >&2; exit 23; }
# The launcher refuses an explicitly requested virtio-gl unless --experimental
# comes with it. Choosing the profile is not enough: without this flag every
# direct boot logged "adicione --experimental", fell back to compat, and left
# the guest at 1024x768 letterboxed on the 1280x800 panel.
grep -q -- '--experimental' < <(grep 'launching Windows VM' "$STATE_DIR/session.log" | tail -n1) || { echo "FAIL: explicit virtio-gl must carry --experimental or the launcher rejects it" >&2; exit 27; }

# --- 7: ineligible host -> keep the configured profile, no extra flag.
set_stub_mode exit0
rm -f "$SESSION_STATE" "$STATE_DIR/virtio-gl-eligible"
: > "$STATE_DIR/session.log"
run_session >/dev/null 2>&1 &
wait $! || exit 24
grep -q 'direct boot graphics: configured profile' "$STATE_DIR/session.log" || { echo "FAIL: ineligible probe must keep configured profile" >&2; exit 25; }
if grep -q -- '--graphics virtio-gl' "$STATE_DIR/session.log"; then
    echo "FAIL: virtio-gl leaked into ineligible boot" >&2
    exit 26
fi

# --- 8: the dedicated "(Dock)" GRUB entry pins the output via kernel cmdline.
DOCK_SYS="$TEST_ROOT/dock-sys"
mkdir -p "$DOCK_SYS/class/drm/card1-eDP-1" "$DOCK_SYS/class/drm/card1-DP-1"
printf 'connected\n' > "$DOCK_SYS/class/drm/card1-eDP-1/status"
printf '800x1280\n' > "$DOCK_SYS/class/drm/card1-eDP-1/modes"
printf 'connected\n' > "$DOCK_SYS/class/drm/card1-DP-1/status"
printf '2560x1080\n' > "$DOCK_SYS/class/drm/card1-DP-1/modes"
printf '%s\n' 'BOOT_IMAGE=/vmlinuz root=UUID=x phasezero.windowsvm=1 phasezero.windowsvm-display=external' > "$TEST_ROOT/cmdline-dock"
printf '%s\n' 'BOOT_IMAGE=/vmlinuz root=UUID=x phasezero.windowsvm=1 phasezero.windowsvm-display=internal' > "$TEST_ROOT/cmdline-internal"
dock_validate="$(
    PZ_WINDOWS_VM_CMDLINE_FILE="$TEST_ROOT/cmdline-dock" \
    PZ_DISPLAY_SYSFS_ROOT="$DOCK_SYS" \
    PZ_WINDOWS_VM_PRIMARY_DISPLAY=internal \
    PZ_WINDOWS_VM_ENV_FILE="$TEST_ROOT/phasezero-no.env" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$RUNTIME_DIR/linux/windows-vm/windows-vm.sh" \
        bash "$PKG_DIR/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'display_width=2560 display_height=1080 display_connector=DP-1' <<< "$dock_validate" || { echo "FAIL: dock cmdline must pin the external output" >&2; exit 27; }
internal_validate="$(
    PZ_WINDOWS_VM_CMDLINE_FILE="$TEST_ROOT/cmdline-internal" \
    PZ_DISPLAY_SYSFS_ROOT="$DOCK_SYS" \
    PZ_WINDOWS_VM_PRIMARY_DISPLAY=external \
    PZ_WINDOWS_VM_ENV_FILE="$TEST_ROOT/phasezero-no.env" \
    PZ_WINDOWS_VM_RUNTIME_LAUNCHER="$RUNTIME_DIR/linux/windows-vm/windows-vm.sh" \
        bash "$PKG_DIR/linux/windows-vm/windows-vm-session.sh" --validate
)"
grep -q 'display_width=1280 display_height=800 display_connector=eDP-1' <<< "$internal_validate" || { echo "FAIL: internal cmdline must pin the panel" >&2; exit 28; }

echo "windows-vm session lifecycle contract ok"
