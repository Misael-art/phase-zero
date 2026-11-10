#!/usr/bin/env bash
# PhaseZero managed: Vibe Code
set -euo pipefail

mode="${1:?usage: vibe-code-session prepare|launch}"
config="${2:-/etc/phasezero/vibe-code.conf}"
cmdline="${3:-/proc/cmdline}"
session_dir="${4:-/usr/share/wayland-sessions}"
runtime="${5:-/run/phasezero-vibe-code}"

if [ "$mode" = prepare ]; then
    rm -f -- "$runtime/login.conf"
fi
read -r -a flags < "$cmdline"
selected=0
for flag in "${flags[@]}"; do
    case "$flag" in
        phasezero.vibe=1) selected=1 ;;
        phasezero.steamos=1|phasezero.winvm=1|phasezero.windows-vm=1|phasezero.windowsvm=1|phasezero.waydroid=1|phasezero.homelab=1|steamzero.gamemode=1)
            exit 0 ;;
    esac
done
[ "$selected" = 1 ] || exit 0

mapfile -t settings < "$config"
owner="${settings[1]:-}"
launcher="${settings[2]:-}"
[[ "$owner" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]] && [ "$owner" != root ] || exit 1
[[ "$launcher" = /* ]] || exit 1

case "$mode" in
    prepare)
        if ! [ -f "$session_dir/plasma.desktop" ] ||
            ! runuser -u "$owner" -- test -x "$launcher"; then
            echo "Vibe Code incompleto. SDDM seguirá para o login normal." >&2
            exit 0
        fi
        temp="$(mktemp "$runtime/.login.XXXXXX")"
        trap 'rm -f -- "$temp"' EXIT
        printf '[Autologin]\nUser=%s\nSession=plasma.desktop\nRelogin=false\n' "$owner" > "$temp"
        chmod 0644 "$temp"
        mv -Tf -- "$temp" "$runtime/login.conf"
        ;;
    launch)
        [ "$(id -un)" = "$owner" ] || exit 0
        personal="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/phasezero-vibe-code.desktop"
        if [ -f "$personal" ] && grep -Fxq 'X-PhaseZero-Vibe-Code-Autostart=true' "$personal" &&
            ! grep -Eiq '^Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$personal"; then
            exit 0
        fi
        exec "$launcher" --vibe-code
        ;;
    *) exit 64 ;;
esac
