#!/usr/bin/env bash
# Persistent KDE login for normal SDDM boots. Direct-boot sessions use later drop-ins.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
shift || true
PLAN_ACTION=""
if [ "$ACTION" = plan ]; then
    PLAN_ACTION="${1:-enable}"
    shift || true
fi
TARGET_USER=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            [ -n "${2:-}" ] || { pz_error "--user requires a local account"; exit 2; }
            TARGET_USER="$2"
            shift 2
            ;;
        *) pz_error "usage: pz boot kde-login (status|enable|disable|plan enable|plan disable) [--user USER]"; exit 2 ;;
    esac
done

CONF_DIR="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
CONF_FILE="$CONF_DIR/50-phasezero-kde-autologin.conf"
SESSION_DIR="${PZ_WAYLAND_SESSION_DIR:-/usr/share/wayland-sessions}"
SESSION="plasma.desktop"
MARKER="# PhaseZero managed: normal KDE autologin"

managed_file() {
    [ -f "$CONF_FILE" ] && [ ! -L "$CONF_FILE" ] &&
        IFS= read -r first_line < "$CONF_FILE" && [ "$first_line" = "$MARKER" ]
}

has_autologin_keys() {
    awk '
        /^\[/{section=($0=="[Autologin]")}
        section && /^[[:space:]]*(User|Session|Relogin)[[:space:]]*=/ {found=1}
        END {exit !found}
    ' "$1"
}

autologin_override() {
    local file name
    if [ "$CONF_DIR" = /etc/sddm.conf.d ] && [ -f /etc/sddm.conf ] && has_autologin_keys /etc/sddm.conf; then
        printf '%s\n' /etc/sddm.conf
        return 0
    fi
    for file in "$CONF_DIR"/*.conf; do
        [ -f "$file" ] || continue
        name="${file##*/}"
        [[ "$name" > 50-phasezero-kde-autologin.conf ]] || continue
        case "$name" in
            90-phasezero-steamos.conf|91-phasezero-windows-vm.conf|92-phasezero-waydroid.conf|99-steamzero-gamemode.conf) continue ;;
        esac
        if has_autologin_keys "$file"; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

status() {
    local override
    if [ -e "$CONF_FILE" ] || [ -L "$CONF_FILE" ]; then
        if managed_file; then
            override="$(autologin_override || true)"
            if [ -n "$override" ]; then
                printf 'kde_login: overridden (%s)\n' "$override"
                return 1
            fi
            printf 'kde_login: enabled\n'
            sed -n '/^User=/p; /^Session=/p; /^Relogin=/p' "$CONF_FILE"
            printf 'note: later SDDM drop-ins may override normal KDE during direct boot\n'
        else
            printf 'kde_login: unmanaged-conflict (%s)\n' "$CONF_FILE"
            return 1
        fi
    elif [ -d "$CONF_DIR" ] && [ ! -r "$CONF_DIR" ]; then
        printf 'kde_login: permission-denied (%s)\n' "$CONF_DIR"
        return 1
    else
        printf 'kde_login: disabled\n'
    fi
}

resolve_user() {
    if [ -n "$TARGET_USER" ]; then
        export PZ_TARGET_USER="$TARGET_USER"
    fi
    TARGET_USER="$(pz_target_user)" || return
    local passwd_entry home
    passwd_entry="$(getent passwd "$TARGET_USER")" || return 1
    home="$(cut -d: -f6 <<< "$passwd_entry")"
    [ -d "$home" ] || { pz_error "home missing for $TARGET_USER"; return 1; }
}

elevate_if_needed() {
    [ "$CONF_DIR" != /etc/sddm.conf.d ] && return 0
    [ "$EUID" -eq 0 ] && return 0
    pz_admin_run bash "$0" "$ACTION" --user "$TARGET_USER"
    exit $?
}

case "$ACTION" in
    status) status ;;
    plan)
        case "$PLAN_ACTION" in
            enable)
                resolve_user
                [ -f "$SESSION_DIR/$SESSION" ] || { pz_error "KDE Wayland session missing: $SESSION_DIR/$SESSION"; exit 1; }
                printf 'action: enable\nuser: %s\nsession: %s\nconfig: %s\nrelogin: true\n' "$TARGET_USER" "$SESSION" "$CONF_FILE"
                ;;
            disable) printf 'action: disable\nconfig: %s\n' "$CONF_FILE" ;;
            *) pz_error "usage: pz boot kde-login plan (enable|disable)"; exit 2 ;;
        esac
        ;;
    enable)
        override=""
        resolve_user
        [ -f "$SESSION_DIR/$SESSION" ] || { pz_error "KDE Wayland session missing: $SESSION_DIR/$SESSION"; exit 1; }
        elevate_if_needed
        if [ "$CONF_DIR" = /etc/sddm.conf.d ]; then
            systemctl is-active --quiet sddm.service || { pz_error "SDDM is not active; KDE login preference would have no effect"; exit 1; }
        fi
        if [ -e "$CONF_FILE" ] || [ -L "$CONF_FILE" ]; then
            managed_file || { pz_error "refusing to replace unmanaged $CONF_FILE"; exit 1; }
        fi
        override="$(autologin_override || true)"
        [ -z "$override" ] || { pz_error "SDDM autologin is overridden by $override; remove the conflicting entry first"; exit 1; }
        [ -d "$CONF_DIR" ] || install -d -m 0755 "$CONF_DIR"
        temporary="$(mktemp "$CONF_DIR/.phasezero-kde-autologin.XXXXXX")"
        trap 'rm -f "$temporary"' EXIT
        printf '%s\n[Autologin]\nUser=%s\nSession=%s\nRelogin=true\n' "$MARKER" "$TARGET_USER" "$SESSION" > "$temporary"
        chmod 0644 "$temporary"
        mv -f "$temporary" "$CONF_FILE"
        trap - EXIT
        pz_info "KDE autologin enabled for $TARGET_USER; takes effect on next SDDM start"
        ;;
    disable)
        if [ "$CONF_DIR" = /etc/sddm.conf.d ] && [ "$EUID" -ne 0 ]; then
            resolve_user
        fi
        elevate_if_needed
        if [ -e "$CONF_FILE" ] || [ -L "$CONF_FILE" ]; then
            managed_file || { pz_error "refusing to remove unmanaged $CONF_FILE"; exit 1; }
            rm -- "$CONF_FILE"
        fi
        pz_info "KDE autologin disabled; takes effect on next SDDM start"
        ;;
    *) pz_error "usage: pz boot kde-login (status|enable|disable|plan enable|plan disable) [--user USER]"; exit 2 ;;
esac
