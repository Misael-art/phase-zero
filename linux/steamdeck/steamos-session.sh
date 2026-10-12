#!/usr/bin/env bash
# steamos-session.sh - resilient SteamOS-like session with direct desktop handoff
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/steamos"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/phasezero-steamos"
TARGET_FILE="$RUNTIME_DIR/session-target"
LOG_FILE="$STATE_DIR/session.log"
GAMESCOPE_BIN="${PZ_STEAMOS_GAMESCOPE_BIN:-gamescope-session-plus}"
DESKTOP_BIN="${PZ_STEAMOS_DESKTOP_BIN:-}"

install -d "$STATE_DIR" "$RUNTIME_DIR"
exec >>"$LOG_FILE" 2>&1

log() {
    printf '%s %s\n' "$(date -Iseconds)" "$*"
}

start_desktop() {
    log "starting desktop session"
    if [ -n "$DESKTOP_BIN" ] && [ -x "$DESKTOP_BIN" ]; then
        exec "$DESKTOP_BIN"
    fi
    if [ -x /usr/bin/startkde-biglinux ]; then
        exec /usr/bin/startkde-biglinux wayland
    fi
    if command -v startplasma-wayland >/dev/null 2>&1; then
        exec startplasma-wayland
    fi
    if command -v startplasma-x11 >/dev/null 2>&1; then
        exec startplasma-x11
    fi
    log "desktop launcher missing"
    return 1
}

rm -f "$TARGET_FILE"

session="steam-plus"
if ! command -v opengamepadui >/dev/null 2>&1; then
    session="steam"
fi

if ! command -v "$GAMESCOPE_BIN" >/dev/null 2>&1 && [ ! -x "$GAMESCOPE_BIN" ]; then
    log "gamescope-session-plus missing; falling back to desktop session"
    log "install it to get Game Mode: sudo pacman -S gamescope-session-plus"
    log "also ensure 'steam' and 'sddm' are installed for the SteamOS boot flow"
    start_desktop
fi

if ! command -v steam >/dev/null 2>&1; then
    log "steam binary missing; Game Mode cannot start"
    log "install it: sudo pacman -S steam"
    start_desktop
fi

log "starting gamescope session=$session"
"$GAMESCOPE_BIN" "$session"
rc=$?
target="$(cat "$TARGET_FILE" 2>/dev/null || true)"
rm -f "$TARGET_FILE"
log "gamescope exited rc=$rc target=${target:-desktop}"

# Read-only record of the pointer handoff. It must not grab evdev, restart
# the controller, restart KWin, or block the desktop if the probe fails.
# A missing or empty file is not evidence that the cursor survived Game Mode.
_script_dir="$(cd "$(dirname "$0")" && pwd)"
if bash "$_script_dir/cursor-diagnose.sh" snapshot >"$STATE_DIR/cursor-handoff.json" 2>>"$LOG_FILE"; then
    log "cursor handoff recorded (read-only; cause not claimed)"
else
    log "cursor handoff skipped"
fi

case "$target" in
    reboot)
        exec systemctl reboot
        ;;
    shutdown|poweroff)
        exec systemctl poweroff
        ;;
    gamepadui|steam)
        exec "$0"
        ;;
    desktop|plasma|"")
        start_desktop
        ;;
    *)
        log "unknown target=$target; falling back to desktop"
        start_desktop
        ;;
esac
