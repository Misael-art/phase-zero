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
        account="$(getent passwd "$owner")"
        IFS=: read -r _ _ uid gid _ _ _ <<< "$account"
        # runuser opens a PAM session and can wait on graphical user services.
        # This boot-time check only needs the user's filesystem permissions.
        if ! [ -f "$session_dir/plasma.desktop" ] ||
            ! setpriv --reuid "$uid" --regid "$gid" --init-groups -- /usr/bin/test -x "$launcher"; then
            echo "Vibe Code incompleto. SDDM seguirá para o login normal." >&2
            exit 0
        fi
        temp="$(mktemp "$runtime/.login.XXXXXX")"
        trap 'rm -f -- "$temp"' EXIT
        printf '[Autologin]\nUser=%s\nSession=plasma.desktop\nRelogin=false\n' "$owner" > "$temp"
        chmod 0644 "$temp"
        mv -Tf -- "$temp" "$runtime/login.conf"
        echo "Vibe Code: autologin Plasma preparado para uma tentativa."
        ;;
    launch)
        [ "$(id -un)" = "$owner" ] || exit 0
        autostart_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
        if [ ! -f "$autostart_dir/folego.desktop" ] && command -v gio >/dev/null; then
            folego_entry="${XDG_DATA_HOME:-$HOME/.local/share}/applications/folego.desktop"
            if [ -f "$folego_entry" ]; then gio launch "$folego_entry" || true; fi
        fi
        personal="$autostart_dir/phasezero-vibe-code.desktop"
        if [ -f "$personal" ] && grep -Fxq 'X-PhaseZero-Vibe-Code-Autostart=true' "$personal" &&
            ! grep -Eiq '^Hidden[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$personal"; then
            exit 0
        fi
        exec "$launcher" --vibe-code
        ;;
    *) exit 64 ;;
esac
