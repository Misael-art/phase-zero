#!/usr/bin/env bash
# input-actions.sh - SteamOS-like input/session actions for Linux desktops
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT="$(cd "$DIR/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$DIR/common.sh"

# Literal KConfig key. The dollar sign is part of the name, not an expansion.
# shellcheck disable=SC2016
VKBD_IM_EXPAND_KEY='InputMethod[$e]'
# shellcheck disable=SC2016
VKBD_IM_DOLLAR_KEY='InputMethod$e'
# Not IFS whitespace. Tab would collapse empty fields and shift the record.
VKBD_REC=$'\x1f'

steamdeck_record() {
    local IFS="$VKBD_REC"
    printf '%s\n' "$*"
}

steamdeck_read_record() {
    local line IFS
    IFS= read -r line || true
    IFS="$VKBD_REC"
    read -r "$@" <<<"$line"
}

steamdeck_has_graphical_session() {
    [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]
}

steamdeck_run_detached() {
    local label="$1"
    shift

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would start $label: $*"
        return 0
    fi

    nohup "$@" >/dev/null 2>&1 &
    local pid="$!"
    disown "$pid" 2>/dev/null || true
    pz_info "started $label (pid $pid)"
}

steamdeck_steam_running() {
    pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1
}

steamdeck_pid_is_kwin_managed() {
    # maliit-keyboard spawned by kwin_wayland is the KDE input method client;
    # killing it never shows a keyboard, KWin just respawns it.
    local pid="$1" ppid parent_comm
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$ppid" ] || return 1
    parent_comm="$(ps -o comm= -p "$ppid" 2>/dev/null | tr -d ' ')"
    case "$parent_comm" in
        kwin_wayland*) return 0 ;;
    esac
    return 1
}

# qdbus6 talks to the live compositor. Tests pass PZ_QDBUS6 so a fixture
# never reads or writes the operator's KWin.
steamdeck_qdbus() {
    if [ -n "${PZ_QDBUS6:-}" ]; then
        "$PZ_QDBUS6" "$@"
        return $?
    fi
    command -v qdbus6 >/dev/null 2>&1 || return 127
    qdbus6 "$@"
}

steamdeck_kde_virtual_keyboard_supported() {
    steamdeck_qdbus org.kde.KWin /VirtualKeyboard >/dev/null 2>&1
}

# jq --argjson aborts on anything that is not valid JSON, so a probe that
# returns an empty string or a stray word takes the whole status command down
# with it. Every probed value passes through here before reaching jq.
steamdeck_bool() {
    case "${1:-}" in
        true|True|TRUE|1|yes) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

# KWin 6.7 exposes available/visible/active/mode. The old "enabled"
# property is not on the object; querying it is not evidence of config.
steamdeck_kde_virtual_keyboard_prop() {
    local prop="$1" value
    case "$prop" in
        enabled) return 2 ;;
    esac
    steamdeck_kde_virtual_keyboard_supported || return 1
    value="$(steamdeck_qdbus org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Get \
        org.kde.kwin.VirtualKeyboard "$prop" 2>/dev/null | tail -1 || true)"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

steamdeck_vkbd_desktop_root() {
    printf '%s\n' "${PZ_VKBD_DESKTOP_ROOT:-/usr/share/applications}"
}

steamdeck_vkbd_is_wayland_im() {
    local desktop="$1"
    [ -n "$desktop" ] && [ -f "$desktop" ] || return 1
    grep -q '^X-KDE-Wayland-VirtualKeyboard=true$' "$desktop"
}

steamdeck_vkbd_plasma_desktop() {
    local desktop
    desktop="$(steamdeck_vkbd_desktop_root)/org.kde.plasma.keyboard.desktop"
    steamdeck_vkbd_is_wayland_im "$desktop" || return 1
    printf '%s\n' "$desktop"
}

steamdeck_maliit_desktop_file() {
    local desktop root
    root="$(steamdeck_vkbd_desktop_root)"
    for desktop in \
        "$root/com.github.maliit.keyboard.desktop" \
        "$root/org.maliit.keyboard.desktop"; do
        if steamdeck_vkbd_is_wayland_im "$desktop"; then
            printf '%s\n' "$desktop"
            return 0
        fi
    done
    return 1
}

steamdeck_kwinrc_path() {
    printf '%s\n' "${PZ_KWINRC:-${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc}"
}

# Read one key from the Wayland group. The [$e] form is a different line
# from the plain key PhaseZero used to write, so kreadconfig6 is not enough.
steamdeck_kwinrc_wayland_key() {
    local key="$1" file line group=0 k
    file="$(steamdeck_kwinrc_path)"
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                if [ "$line" = "[Wayland]" ]; then group=1; else group=0; fi
                ;;
            *)
                [ "$group" = 1 ] || continue
                k="${line%%=*}"
                [ "$k" = "$key" ] || continue
                printf '%s\n' "${line#*=}"
                return 0
                ;;
        esac
    done <"$file"
    return 1
}

steamdeck_vkbd_enabled_state() {
    local value
    value="$(steamdeck_kwinrc_wayland_key VirtualKeyboardEnabled || true)"
    case "$value" in
        true|True|TRUE) printf 'true' ;;
        false|False|FALSE) printf 'false' ;;
        *) printf 'unset' ;;
    esac
}

steamdeck_vkbd_is_legacy_maliit_value() {
    case "$1" in
        */com.github.maliit.keyboard.desktop|*/org.maliit.keyboard.desktop) return 0 ;;
        *) return 1 ;;
    esac
}

# PhaseZero's configure deleted InputMethod[$e] and wrote a plain
# InputMethod pointing at Maliit. That signature is the managed legacy
# config. A qualified key, or any other Wayland input-method desktop, is
# an explicit choice and is left alone.
steamdeck_vkbd_legacy_maliit() {
    local plain qualified
    plain="$(steamdeck_kwinrc_wayland_key InputMethod || true)"
    qualified="$(steamdeck_kwinrc_wayland_key "$VKBD_IM_EXPAND_KEY" || true)"
    [ -z "$qualified" ] || return 1
    steamdeck_vkbd_is_legacy_maliit_value "$plain" || return 1
    steamdeck_vkbd_plasma_desktop >/dev/null
}

# Prints: origin, key, path, action. Empty key/path stay empty.
steamdeck_vkbd_resolve() {
    local plain qualified plasma maliit
    plain="$(steamdeck_kwinrc_wayland_key InputMethod || true)"
    qualified="$(steamdeck_kwinrc_wayland_key "$VKBD_IM_EXPAND_KEY" || true)"
    plasma="$(steamdeck_vkbd_plasma_desktop || true)"
    maliit="$(steamdeck_maliit_desktop_file || true)"

    if steamdeck_vkbd_is_wayland_im "$qualified"; then
        steamdeck_record explicit "$VKBD_IM_EXPAND_KEY" "$qualified" keep
        return 0
    fi
    if steamdeck_vkbd_legacy_maliit && [ -n "$plasma" ]; then
        steamdeck_record phasezero-legacy "$VKBD_IM_EXPAND_KEY" "$plasma" migrate
        return 0
    fi
    if steamdeck_vkbd_is_wayland_im "$plain"; then
        steamdeck_record explicit InputMethod "$plain" keep
        return 0
    fi
    if [ -n "$plasma" ]; then
        steamdeck_record default "$VKBD_IM_EXPAND_KEY" "$plasma" select
        return 0
    fi
    if [ -n "$maliit" ]; then
        steamdeck_record default InputMethod "$maliit" select
        return 0
    fi
    steamdeck_record unset "" "" keep
}

steamdeck_kwinrc_rewrite() {
    local mode="$1" key="${2:-}" value="${3:-}"
    local file tmp group=0 found=0 line k
    file="$(steamdeck_kwinrc_path)"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || : >"$file"
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                if [ "$group" = 1 ] && [ "$mode" = set ] && [ "$found" = 0 ]; then
                    printf '%s=%s\n' "$key" "$value"
                    found=1
                fi
                if [ "$line" = "[Wayland]" ]; then group=1; else group=0; fi
                printf '%s\n' "$line" >>"$tmp"
                ;;
            *)
                k="${line%%=*}"
                if [ "$group" = 1 ] && [ "$k" = "$key" ]; then
                    if [ "$mode" = set ]; then
                        printf '%s=%s\n' "$key" "$value" >>"$tmp"
                        found=1
                    fi
                    continue
                fi
                printf '%s\n' "$line" >>"$tmp"
                ;;
        esac
    done <"$file"
    if [ "$mode" = set ] && [ "$found" = 0 ]; then
        if [ "$group" != 1 ]; then
            printf '\n[Wayland]\n' >>"$tmp"
        fi
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    mv "$tmp" "$file"
}

steamdeck_kwinrc_remove_wayland_key() {
    steamdeck_kwinrc_rewrite remove "$1"
}

steamdeck_kwinrc_set_wayland_key() {
    steamdeck_kwinrc_rewrite set "$1" "$2"
}

steamdeck_kwinrc_write_enabled() {
    local value="$1" file
    file="$(steamdeck_kwinrc_path)"
    if [ "${PZ_KWINRC_FORCE_TEXT:-0}" != 1 ] && command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file "$file" --group Wayland --key VirtualKeyboardEnabled "$value"
        return 0
    fi
    steamdeck_kwinrc_set_wayland_key VirtualKeyboardEnabled "$value"
}

# BigLinux stores the KConfig shell-expand flag as InputMethod[$e].
# kwriteconfig6 cannot write that flag; it emits InputMethod$e. One text
# replacement drops every InputMethod spelling and writes the chosen line.
# KWin 6.7 does not reload the file from that replacement. It reloads only
# when KConfig emits Notify (see steamdeck_kwinrc_ensure_loaded). The key
# name KWin reads is still InputMethod.
steamdeck_kwinrc_write_method() {
    local key="$1" value="$2"
    local file tmp group=0 line k inserted=0
    file="$(steamdeck_kwinrc_path)"
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] || : >"$file"
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \[*\])
                if [ "$group" = 1 ] && [ "$inserted" = 0 ]; then
                    printf '%s=%s\n' "$key" "$value" >>"$tmp"
                    inserted=1
                fi
                if [ "$line" = "[Wayland]" ]; then group=1; else group=0; fi
                printf '%s\n' "$line" >>"$tmp"
                ;;
            *)
                if [ "$group" = 1 ]; then
                    k="${line%%=*}"
                    case "$k" in
                        InputMethod|"$VKBD_IM_DOLLAR_KEY"|"$VKBD_IM_EXPAND_KEY") continue ;;
                    esac
                fi
                printf '%s\n' "$line" >>"$tmp"
                ;;
        esac
    done <"$file"
    if [ "$inserted" = 0 ]; then
        if [ "$group" != 1 ]; then
            printf '\n[Wayland]\n' >>"$tmp"
        fi
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    mv "$tmp" "$file"
}

steamdeck_vkbd_state_file() {
    printf '%s/steamdeck-virtual-keyboard.json\n' "${XDG_STATE_HOME:-$HOME/.local/state}/phasezero"
}

steamdeck_vkbd_record_state() {
    local action="$1" origin="$2" key="$3" path="$4" backup="$5"
    local previous_key="$6" previous_value="$7" state
    state="$(steamdeck_vkbd_state_file)"
    mkdir -p "$(dirname "$state")"
    jq -n \
        --arg action "$action" \
        --arg origin "$origin" \
        --arg key "$key" \
        --arg path "$path" \
        --arg backup "$backup" \
        --arg previousKey "$previous_key" \
        --arg previousValue "$previous_value" \
        --arg at "$(date -Iseconds)" \
        '{
            schema: 1,
            action: $action,
            origin: $origin,
            at: $at,
            backup: $backup,
            previous: {key: $previousKey, value: $previousValue},
            current: {key: $key, value: $path},
            rollback: "pz steamdeck keyboard revert"
        }' >"$state"
}

# Tests set PZ_VKBD_PROCESS_CMD so pgrep/pkill never see the operator's
# onboard/wvkbd. Protocol: running|stop NAME.
steamdeck_keyboard_process_running() {
    local name="$1"
    if [ -n "${PZ_VKBD_PROCESS_CMD:-}" ]; then
        "$PZ_VKBD_PROCESS_CMD" running "$name"
        return $?
    fi
    pgrep -x "$name" >/dev/null 2>&1
}

steamdeck_stop_named_keyboard() {
    local name="$1"
    if [ -n "${PZ_VKBD_PROCESS_CMD:-}" ]; then
        "$PZ_VKBD_PROCESS_CMD" stop "$name"
        return $?
    fi
    if ! pgrep -x "$name" >/dev/null 2>&1; then
        return 1
    fi
    pkill -x "$name" >/dev/null 2>&1 || true
    pz_info "stopped virtual keyboard: $name"
    return 0
}

steamdeck_vkbd_on_wayland() {
    case "${PZ_VKBD_WAYLAND:-}" in
        1|true|yes|TRUE) return 0 ;;
        0|false|no|FALSE) return 1 ;;
    esac
    [ -n "${WAYLAND_DISPLAY:-}" ]
}

# A process that is alive is not a keyboard. On Wayland only a KWin input
# method client can type; onboard/wvkbd/standalone maliit are not that client.
# PZ_VKBD_USABLE_PROBE receives the candidate and the pid we started (empty
# when the process was already running).
steamdeck_fallback_usable() {
    local candidate="$1" pid="${2:-}"
    if [ -n "${PZ_VKBD_USABLE_PROBE:-}" ]; then
        "$PZ_VKBD_USABLE_PROBE" "$candidate" "$pid"
        return $?
    fi
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    if steamdeck_vkbd_on_wayland; then
        case "$candidate" in
            onboard|wvkbd|wvkbd-mobintl|maliit-keyboard) return 1 ;;
        esac
    fi
    if [ -n "$pid" ]; then
        return 0
    fi
    if steamdeck_vkbd_on_wayland; then
        return 1
    fi
    steamdeck_keyboard_process_running "$candidate"
}

steamdeck_fallback_snapshot() {
    local candidate
    for candidate in wvkbd-mobintl wvkbd onboard maliit-keyboard; do
        if steamdeck_keyboard_process_running "$candidate"; then
            if steamdeck_fallback_usable "$candidate" ""; then
                steamdeck_record "$candidate" usable
            else
                steamdeck_record "$candidate" alive-unusable-on-wayland
            fi
            return 0
        fi
    done
    steamdeck_record "" not-used
}

steamdeck_vkbd_provider_name() {
    local path="$1"
    case "$path" in
        *org.kde.plasma.keyboard.desktop) printf 'plasma-keyboard' ;;
        *maliit.keyboard.desktop) printf 'maliit' ;;
        "") printf 'none' ;;
        *) basename "$path" .desktop ;;
    esac
}

steamdeck_json_bool() {
    case "${1:-}" in
        true|True|TRUE) printf 'true' ;;
        false|False|FALSE) printf 'false' ;;
        *) printf 'null' ;;
    esac
}

steamdeck_dbus_bool_json() {
    local prop="$1" value
    if ! steamdeck_kde_virtual_keyboard_supported; then
        printf 'null'
        return 0
    fi
    if value="$(steamdeck_kde_virtual_keyboard_prop "$prop" 2>/dev/null)"; then
        steamdeck_json_bool "$value"
    else
        printf 'null'
    fi
}

steamdeck_dbus_int_json() {
    local prop="$1" value
    if ! steamdeck_kde_virtual_keyboard_supported; then
        printf 'null'
        return 0
    fi
    if value="$(steamdeck_kde_virtual_keyboard_prop "$prop" 2>/dev/null)"; then
        case "$value" in
            ''|*[!0-9-]*) printf 'null' ;;
            *) printf '%s' "$value" ;;
        esac
    else
        printf 'null'
    fi
}

steamdeck_dbus_method_bool_json() {
    local method="$1" value
    if ! steamdeck_kde_virtual_keyboard_supported; then
        printf 'null'
        return 0
    fi
    if value="$(steamdeck_qdbus org.kde.KWin /VirtualKeyboard \
        "org.kde.kwin.VirtualKeyboard.$method" 2>/dev/null | tail -1)"; then
        if [ -z "$value" ]; then
            printf 'null'
        else
            steamdeck_json_bool "$value"
        fi
    else
        printf 'null'
    fi
}

# Prints: effective, reason. effective is true only when the keyboard is
# actually showing, or a fallback process offers a usable keyboard.
steamdeck_vkbd_open_state() {
    local visible="$1" available="$2" supported="$3" method="$4" fb_state="$5"
    if [ "$visible" = true ]; then
        steamdeck_record true kwin-visible
        return 0
    fi
    if [ "$fb_state" = usable ]; then
        steamdeck_record true fallback-usable
        return 0
    fi
    if [ "$available" = true ]; then
        steamdeck_record false kwin-available-closed
        return 0
    fi
    if [ "$supported" != true ]; then
        steamdeck_record false dbus-unavailable
        return 0
    fi
    if [ -n "$method" ] && [ "$available" != true ]; then
        steamdeck_record false kwin-command-missing
        return 0
    fi
    if [ "$fb_state" = alive-unusable-on-wayland ]; then
        steamdeck_record false fallback-unusable
        return 0
    fi
    steamdeck_record false not-open
}

# dbus.available means KWin has some input-method command. KWin 6.7 does not
# expose which path it loaded, so this cannot prove the command matches
# configured.inputMethod. configure reloads when it changes the file.
steamdeck_virtual_keyboard_health_from_json() {
    local status
    status="$(cat)"
    if jq -e '.dbus.available == true and .configured.enabled == true and ((.configured.inputMethod // "") | length > 0)' <<<"$status" >/dev/null 2>&1; then
        printf 'PASS\tKDE/KWin input method loaded\n'
        return 0
    fi
    if jq -e '((.configured.inputMethod // "") | length > 0) and .dbus.available != true' <<<"$status" >/dev/null 2>&1; then
        printf 'WARN\tconfigured but KWin has not loaded the input method\n'
        return 0
    fi
    if jq -e '.provider != "none" and .provider != null and .provider != ""' <<<"$status" >/dev/null 2>&1; then
        printf 'WARN\tprovider present but not fully configured\n'
        return 0
    fi
    printf 'WARN\tno Wayland virtual keyboard configured\n'
}

# KWin's KConfigWatcher ignores a raw rewrite and ignores --notify when the
# value is unchanged. KConfig emits ConfigChanged only for a dirty key, on
# session-bus path /kwinrc. Delete the key, then write it back; both calls
# pass --notify. kwriteconfig6 flattens InputMethod[$e] to InputMethod, so
# the shell-expand line is put back afterwards. That put-back does not
# notify. Measured on KWin 6.7.4: available stayed true and the already
# loaded input-method process stayed up. PZ_KWINRC_SKIP_NOTIFY=1 skips this
# for tests that must not touch a real compositor. The live config must be
# addressed as the name "kwinrc"; an absolute path is not what KWin watches.
steamdeck_kwinrc_notify_input_method() {
    local file value live target
    file="$(steamdeck_kwinrc_path)"
    live="${XDG_CONFIG_HOME:-$HOME/.config}/kwinrc"
    value="$(steamdeck_kwinrc_wayland_key "$VKBD_IM_EXPAND_KEY" || true)"
    [ -n "$value" ] || value="$(steamdeck_kwinrc_wayland_key InputMethod || true)"
    [ -n "$value" ] || return 0
    if [ "$(realpath -m -- "$file" 2>/dev/null || printf '%s' "$file")" = "$(realpath -m -- "$live" 2>/dev/null || printf '%s' "$live")" ]; then
        target="kwinrc"
    else
        target="$file"
    fi
    kwriteconfig6 --notify --file "$target" --group Wayland --key InputMethod --delete || true
    if ! kwriteconfig6 --notify --file "$target" --group Wayland --key InputMethod "$value"; then
        pz_warn "KWin input-method notify write failed; retrying so the command is not left empty"
        kwriteconfig6 --notify --file "$target" --group Wayland --key InputMethod "$value"
    fi
}

# force=1 reloads even when D-Bus available is already true. A loaded Maliit
# client reports available=true while the file now points at Plasma Keyboard.
# keep + available=true does not bounce the running client.
steamdeck_kwinrc_ensure_loaded() {
    local key="$1" path="$2" force="${3:-0}" avail now
    [ -n "$path" ] || return 0
    [ "${PZ_DRY_RUN:-0}" = 1 ] && return 0
    [ "${PZ_KWINRC_SKIP_NOTIFY:-0}" = 1 ] && return 0
    command -v kwriteconfig6 >/dev/null 2>&1 || {
        pz_warn "kwriteconfig6 missing; KWin loads this input method on the next login"
        return 0
    }
    if ! steamdeck_kde_virtual_keyboard_supported; then
        return 0
    fi
    if [ "$force" != 1 ]; then
        avail="$(steamdeck_kde_virtual_keyboard_prop available || echo false)"
        [ "$avail" = true ] && return 0
    fi
    if ! steamdeck_kwinrc_notify_input_method; then
        pz_warn "could not notify KWin to load the virtual keyboard"
        return 0
    fi
    if [ "$key" = "$VKBD_IM_EXPAND_KEY" ]; then
        now="$(steamdeck_kwinrc_wayland_key "$VKBD_IM_EXPAND_KEY" || true)"
        if [ "$now" != "$path" ]; then
            steamdeck_kwinrc_write_method "$key" "$path"
        fi
    fi
    pz_info "notified KWin to load input method $path"
}

steamdeck_configure_virtual_keyboard() {
    local origin key path action enabled file backup previous_plain
    steamdeck_read_record origin key path action < <(steamdeck_vkbd_resolve)
    enabled="$(steamdeck_vkbd_enabled_state)"
    file="$(steamdeck_kwinrc_path)"
    previous_plain="$(steamdeck_kwinrc_wayland_key InputMethod || true)"
    # A valid explicit InputMethod[$e] wins, but a leftover plain Maliit line
    # is still the PhaseZero-managed value and must not stay beside it.
    if [ "$action" = keep ] && [ "$key" = "$VKBD_IM_EXPAND_KEY" ] && steamdeck_vkbd_is_legacy_maliit_value "$previous_plain"; then
        action="cleanup-legacy"
    fi
    if [ "$action" = keep ]; then
        # An explicit desktop with no enabled flag still looks unrepaired:
        # health requires the flag, and a later repair would otherwise no-op.
        if [ "$enabled" = unset ] && [ -n "$path" ] && [ "${PZ_DRY_RUN:-0}" != 1 ]; then
            backup="$(pz_backup_file "$file" user | tail -1 || true)"
            steamdeck_kwinrc_write_enabled true
            steamdeck_vkbd_record_state keep-enable "$origin" "$key" "$path" "$backup" VirtualKeyboardEnabled unset
            enabled=true
        elif [ "$enabled" = unset ] && [ -n "$path" ]; then
            pz_info "dry-run: would set VirtualKeyboardEnabled=true in $file"
        fi
        steamdeck_kwinrc_ensure_loaded "$key" "$path"
        pz_info "KDE virtual keyboard unchanged: origin=$origin inputMethod=${path:-unset} enabled=$enabled"
        return 0
    fi
    if [ -z "$path" ]; then
        pz_warn "no Wayland virtual keyboard desktop found; KDE virtual keyboard config skipped"
        return 1
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would set $key=$path in $file (action=$action)"
        return 0
    fi
    backup="$(pz_backup_file "$file" user | tail -1 || true)"
    # VirtualKeyboardEnabled is written first. A later kwriteconfig6 Notify
    # flattens InputMethod[$e]; steamdeck_kwinrc_ensure_loaded puts it back.
    if [ "$action" != cleanup-legacy ] && [ "$enabled" = unset ]; then
        steamdeck_kwinrc_write_enabled true
    fi
    if [ "$action" = cleanup-legacy ]; then
        steamdeck_kwinrc_remove_wayland_key InputMethod
    else
        steamdeck_kwinrc_write_method "$key" "$path"
    fi
    steamdeck_vkbd_record_state "$action" "$origin" "$key" "$path" "$backup" InputMethod "$previous_plain"
    steamdeck_kwinrc_ensure_loaded "$key" "$path" 1
    pz_info "KDE virtual keyboard configured: action=$action enabled=$(steamdeck_vkbd_enabled_state) inputMethod=$path"
}

# Restores the whole kwinrc captured before the last migration. A first
# select against a missing file has no backup and cannot be reverted.
steamdeck_revert_virtual_keyboard() {
    local state backup file
    state="$(steamdeck_vkbd_state_file)"
    file="$(steamdeck_kwinrc_path)"
    backup=""
    if [ -f "$state" ]; then
        backup="$(jq -r '.backup // empty' "$state" 2>/dev/null || true)"
    fi
    if [ -z "$backup" ] || [ ! -f "$backup" ]; then
        backup="$(pz_backup_latest "$file" || true)"
    fi
    if [ -z "$backup" ] || [ ! -f "$backup" ]; then
        pz_error "no virtual keyboard backup to restore"
        return 1
    fi
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would restore $file from $backup"
        return 0
    fi
    cp -p "$backup" "$file"
    pz_info "restored KDE virtual keyboard config from $backup"
}

steamdeck_kde_deactivate_virtual_keyboard() {
    steamdeck_kde_virtual_keyboard_supported || return 1
    steamdeck_qdbus org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Set \
        org.kde.kwin.VirtualKeyboard active false >/dev/null 2>&1 || return 1
    pz_info "KDE virtual keyboard deactivated"
}

# KWin 6.7 shows the input panel only when it is both requested and allowed.
# NonMouseInput allows it solely after touch or a stylus. A controller chord
# is a key, so forceActivate sets active, show() runs, and the panel stays
# hidden. AnyInput makes the next show() allow the panel. Restoring the
# previous mode does not hide a panel that is already on screen, and KWin
# writes VirtualKeyboardMode itself. This function puts back the mode it read.
steamdeck_kde_set_virtual_keyboard_mode() {
    local mode="$1"
    case "$mode" in
        0|1|2) ;;
        *) return 1 ;;
    esac
    steamdeck_qdbus org.kde.KWin /VirtualKeyboard \
        org.freedesktop.DBus.Properties.Set \
        org.kde.kwin.VirtualKeyboard mode "$mode" >/dev/null 2>&1
}

steamdeck_kde_keyboard_visible() {
    [ "$(steamdeck_kde_virtual_keyboard_prop visible || echo false)" = "true" ]
}

steamdeck_kde_force_activate_keyboard() {
    steamdeck_qdbus org.kde.KWin /VirtualKeyboard \
        org.kde.kwin.VirtualKeyboard.forceActivate >/dev/null 2>&1 || return 1
    local tries=0 max="${PZ_VKBD_VISIBLE_POLLS:-6}"
    while [ "$tries" -lt "$max" ]; do
        steamdeck_kde_keyboard_visible && return 0
        tries=$((tries + 1))
        sleep "${PZ_VKBD_VISIBLE_DELAY:-0.1}"
    done
    return 1
}

steamdeck_kde_open_virtual_keyboard() {
    local available tries max mode
    steamdeck_kde_virtual_keyboard_supported || return 1
    steamdeck_configure_virtual_keyboard || true

    available=false
    tries=0
    max="${PZ_VKBD_AVAILABLE_POLLS:-8}"
    while [ "$tries" -lt "$max" ]; do
        available="$(steamdeck_kde_virtual_keyboard_prop available || echo false)"
        [ "$available" = "true" ] && break
        tries=$((tries + 1))
        if [ "$tries" -lt "$max" ]; then
            sleep "${PZ_VKBD_AVAILABLE_DELAY:-0.25}"
        fi
    done
    [ "$available" = "true" ] || return 1

    if steamdeck_kde_force_activate_keyboard; then
        pz_info "virtual keyboard requested via KDE/KWin"
        return 0
    fi

    mode="$(steamdeck_kde_virtual_keyboard_prop mode || true)"
    case "$mode" in
        0|1) ;;
        *) mode="" ;;
    esac
    if [ -n "$mode" ]; then
        if steamdeck_kde_set_virtual_keyboard_mode 2; then
            steamdeck_kde_force_activate_keyboard || true
            steamdeck_kde_set_virtual_keyboard_mode "$mode" || \
                pz_warn "could not restore VirtualKeyboardMode $mode"
        fi
    fi
    if steamdeck_kde_keyboard_visible; then
        pz_info "virtual keyboard requested via KDE/KWin"
        return 0
    fi

    if [ "$(steamdeck_kde_virtual_keyboard_prop active || echo false)" = "true" ]; then
        # available means KWin has a command, not that a keyboard is showing.
        pz_warn "KDE virtual keyboard active but not visible"
        steamdeck_kde_deactivate_virtual_keyboard >/dev/null 2>&1 || true
    fi

    return 1
}

steamdeck_admin_run() {
    if pz_can_sudo_noninteractive; then
        sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then
        phasezero-admin "$@"
    else
        return 127
    fi
}

steamdeck_ensure_terminal_keyboard() {
    # Not called from configure. Installing wvkbd or onboard does not give
    # KWin a Wayland input method; only a desktop with
    # X-KDE-Wayland-VirtualKeyboard=true does. Kept for an explicit terminal
    # install, and a running copy is not treated as an open keyboard.
    local candidate
    for candidate in wvkbd-mobintl wvkbd onboard; do
        command -v "$candidate" >/dev/null 2>&1 && return 0
    done

    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would install wvkbd (terminal-capable virtual keyboard)"
        return 0
    fi

    if ! command -v pacman >/dev/null 2>&1; then
        pz_warn "no terminal-capable virtual keyboard found; install wvkbd manually"
        return 0
    fi

    pz_info "installing wvkbd (terminal-capable virtual keyboard)"
    if steamdeck_admin_run pacman -S --needed --noconfirm wvkbd; then
        pz_info "wvkbd installed"
    else
        pz_warn "could not install wvkbd automatically; run: sudo pacman -S wvkbd"
    fi
}

steamdeck_stop_virtual_keyboard() {
    local stopped=0
    local name pid
    for name in wvkbd-mobintl wvkbd onboard; do
        if steamdeck_stop_named_keyboard "$name"; then
            stopped=1
        fi
    done

    # only standalone maliit instances; the KWin-managed one must stay alive
    if [ -n "${PZ_VKBD_PROCESS_CMD:-}" ]; then
        if "$PZ_VKBD_PROCESS_CMD" stop maliit-keyboard; then
            stopped=1
        fi
    else
        for pid in $(pgrep -x maliit-keyboard 2>/dev/null || true); do
            if ! steamdeck_pid_is_kwin_managed "$pid"; then
                kill "$pid" >/dev/null 2>&1 || true
                pz_info "stopped standalone maliit-keyboard (pid $pid)"
                stopped=1
            fi
        done
    fi

    [ "$stopped" -eq 1 ]
}

steamdeck_request_steam_keyboard() {
    command -v steam >/dev/null 2>&1 || return 1
    steamdeck_steam_running || return 1
    steam steam://open/keyboard >/dev/null 2>&1 && {
        pz_info "virtual keyboard requested via Steam"
        return 0
    }
    return 1
}

steamdeck_start_keyboard_binary() {
    local candidate pid
    # Standalone maliit-keyboard is not started. Under KWin it is not the
    # input-method client, and a process that merely stays alive is not a
    # keyboard on Wayland.
    for candidate in wvkbd-mobintl wvkbd onboard; do
        command -v "$candidate" >/dev/null 2>&1 || continue

        if steamdeck_keyboard_process_running "$candidate"; then
            if steamdeck_fallback_usable "$candidate" ""; then
                pz_info "virtual keyboard already running: $candidate"
                return 0
            fi
            pz_warn "$candidate is running but is not a Wayland input method; leaving it alone"
            continue
        fi

        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would start virtual keyboard: $candidate"
            return 0
        fi

        nohup "$candidate" >/dev/null 2>&1 &
        pid="$!"
        disown "$pid" 2>/dev/null || true
        sleep "${PZ_VKBD_START_DELAY:-0.4}"
        if ! kill -0 "$pid" 2>/dev/null; then
            pz_warn "$candidate exited immediately; trying next"
            continue
        fi
        if steamdeck_fallback_usable "$candidate" "$pid"; then
            pz_info "started virtual keyboard: $candidate (pid $pid)"
            return 0
        fi
        pz_warn "$candidate started but does not offer a Wayland keyboard; stopping pid $pid"
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" 2>/dev/null || true
    done

    pz_error "no working virtual keyboard found. On Wayland the KWin input method must be available; a leftover onboard or wvkbd process is not a keyboard."
    return 1
}

steamdeck_open_virtual_keyboard() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for virtual keyboard"
        return 1
    }

    steamdeck_kde_open_virtual_keyboard && return 0
    steamdeck_request_steam_keyboard && return 0
    steamdeck_start_keyboard_binary
}

steamdeck_toggle_virtual_keyboard() {
    local candidate
    if steamdeck_kde_virtual_keyboard_supported &&
        [ "$(steamdeck_kde_virtual_keyboard_prop visible || echo false)" = "true" ]; then
        steamdeck_kde_deactivate_virtual_keyboard && return 0
    fi
    # An onboard/wvkbd process that cannot type on Wayland is left running.
    # Closing it from a toggle would kill a leftover the operator may still
    # be looking at, without revealing a keyboard.
    for candidate in wvkbd-mobintl wvkbd onboard maliit-keyboard; do
        if steamdeck_keyboard_process_running "$candidate" &&
            steamdeck_fallback_usable "$candidate" ""; then
            steamdeck_stop_named_keyboard "$candidate" && return 0
        fi
    done
    steamdeck_open_virtual_keyboard
}

steamdeck_virtual_keyboard_status() {
    local origin key path action provider enabled_state cfg_enabled
    local dbus_supported dbus_available dbus_visible dbus_active dbus_text dbus_mode dbus_will
    local kde_supported kde_available kde_enabled kde_visible kde_active
    local fb_candidate fb_state open_effective open_reason
    local legacy_present recorded_action recorded_backup state_file maliit plain qualified
    steamdeck_read_record origin key path action < <(steamdeck_vkbd_resolve)
    # Resolve names the desktop configure would write. Status reports the
    # desktop that is in the file now; action says whether that is legacy.
    plain="$(steamdeck_kwinrc_wayland_key InputMethod || true)"
    qualified="$(steamdeck_kwinrc_wayland_key "$VKBD_IM_EXPAND_KEY" || true)"
    if [ "$action" = keep ] && [ "$key" = "$VKBD_IM_EXPAND_KEY" ] && steamdeck_vkbd_is_legacy_maliit_value "$plain"; then
        action="cleanup-legacy"
    fi
    if steamdeck_vkbd_is_wayland_im "$qualified"; then
        key="$VKBD_IM_EXPAND_KEY"
        path="$qualified"
    elif steamdeck_vkbd_is_wayland_im "$plain"; then
        key="InputMethod"
        path="$plain"
    else
        key=""
        path=""
    fi
    provider="$(steamdeck_vkbd_provider_name "$path")"
    enabled_state="$(steamdeck_vkbd_enabled_state)"
    case "$enabled_state" in
        true) cfg_enabled=true ;;
        false) cfg_enabled=false ;;
        *) cfg_enabled=null ;;
    esac

    if steamdeck_kde_virtual_keyboard_supported; then
        dbus_supported=true
    else
        dbus_supported=false
    fi
    # Never query the missing "enabled" property. kde.enabled below is the
    # kwinrc flag, not a D-Bus value.
    dbus_available="$(steamdeck_dbus_bool_json available)"
    dbus_visible="$(steamdeck_dbus_bool_json visible)"
    dbus_active="$(steamdeck_dbus_bool_json active)"
    dbus_text="$(steamdeck_dbus_bool_json activeClientSupportsTextInput)"
    dbus_mode="$(steamdeck_dbus_int_json mode)"
    dbus_will="$(steamdeck_dbus_method_bool_json willShowOnActive)"

    kde_supported="$dbus_supported"
    if [ "$dbus_available" = true ]; then kde_available=true; else kde_available=false; fi
    if [ "$cfg_enabled" = true ]; then kde_enabled=true; else kde_enabled=false; fi
    if [ "$dbus_visible" = true ]; then kde_visible=true; else kde_visible=false; fi
    if [ "$dbus_active" = true ]; then kde_active=true; else kde_active=false; fi

    steamdeck_read_record fb_candidate fb_state < <(steamdeck_fallback_snapshot)
    steamdeck_read_record open_effective open_reason < <(steamdeck_vkbd_open_state \
        "$dbus_visible" "$dbus_available" "$dbus_supported" "$path" "$fb_state")

    legacy_present=false
    if steamdeck_vkbd_legacy_maliit; then
        legacy_present=true
    fi
    state_file="$(steamdeck_vkbd_state_file)"
    recorded_action=null
    recorded_backup=null
    if [ -f "$state_file" ]; then
        recorded_action="$(jq -r '.action // empty' "$state_file" 2>/dev/null || true)"
        recorded_backup="$(jq -r '.backup // empty' "$state_file" 2>/dev/null || true)"
        if [ -n "$recorded_action" ]; then
            recorded_action="$(jq -cn --arg v "$recorded_action" '$v')"
        else
            recorded_action=null
        fi
        if [ -n "$recorded_backup" ]; then
            recorded_backup="$(jq -cn --arg v "$recorded_backup" '$v')"
        else
            recorded_backup=null
        fi
    fi
    if [ -n "$(steamdeck_maliit_desktop_file || true)" ]; then
        maliit=true
    else
        maliit=false
    fi

    jq -n \
        --arg provider "$provider" \
        --arg origin "$origin" \
        --arg key "$key" \
        --arg path "$path" \
        --arg action "$action" \
        --arg fbCandidate "$fb_candidate" \
        --arg fbState "$fb_state" \
        --arg openReason "$open_reason" \
        --argjson cfgEnabled "$cfg_enabled" \
        --argjson dbusSupported "$dbus_supported" \
        --argjson dbusAvailable "$dbus_available" \
        --argjson dbusVisible "$dbus_visible" \
        --argjson dbusActive "$dbus_active" \
        --argjson dbusText "$dbus_text" \
        --argjson dbusMode "$dbus_mode" \
        --argjson dbusWill "$dbus_will" \
        --argjson kdeSupported "$kde_supported" \
        --argjson kdeAvailable "$kde_available" \
        --argjson kdeEnabled "$kde_enabled" \
        --argjson kdeVisible "$kde_visible" \
        --argjson kdeActive "$kde_active" \
        --argjson openEffective "$open_effective" \
        --argjson legacyPresent "$legacy_present" \
        --argjson recordedAction "$recorded_action" \
        --argjson recordedBackup "$recorded_backup" \
        --argjson maliit "$maliit" \
        '{
            provider: $provider,
            configured: {
                enabled: $cfgEnabled,
                inputMethod: $path,
                inputMethodKey: $key,
                origin: $origin,
                action: $action
            },
            dbus: {
                supported: $dbusSupported,
                available: $dbusAvailable,
                visible: $dbusVisible,
                active: $dbusActive,
                activeClientSupportsTextInput: $dbusText,
                mode: $dbusMode,
                willShowOnActive: $dbusWill
            },
            open: {
                effective: $openEffective,
                reason: $openReason
            },
            fallback: {
                candidate: $fbCandidate,
                state: $fbState
            },
            migration: {
                legacyPresent: $legacyPresent,
                recordedAction: $recordedAction,
                backup: $recordedBackup
            },
            kde: {
                supported: $kdeSupported,
                available: $kdeAvailable,
                enabled: $kdeEnabled,
                visible: $kdeVisible,
                active: $kdeActive,
                inputMethod: $path
            },
            maliitDesktopFile: $maliit
        }'
}

steamdeck_launch_steam_gamepad_ui() {
    steamdeck_has_graphical_session || {
        pz_error "no graphical session detected for Steam Gamepad UI"
        return 1
    }

    if ! command -v steam >/dev/null 2>&1; then
        pz_error "steam not installed"
        return 1
    fi

    bash "$DIR/plugins.sh" enable-cef-debug >/dev/null 2>&1 || true

    if steamdeck_steam_running; then
        steam steam://open/bigpicture >/dev/null 2>&1 && {
            pz_info "Steam Big Picture requested"
            return 0
        }
    fi

    steamdeck_run_detached "Steam Gamepad UI" steam -gamepadui
}

steamdeck_start_console_session() {
    local mode="${1:-auto}"
    if [ "$mode" = "auto" ]; then
        mode="$(steamdeck_detect_mode)"
    fi

    steamdeck_apply_mode "$mode"
    steamdeck_launch_steam_gamepad_ui
}

steamdeck_start_dev_session() {
    local mode="${1:-docked-monitor}"
    if [ "$mode" != "none" ]; then
        steamdeck_apply_mode "$mode"
    fi

    pz_info "desktop/dev session ready"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-keyboard}" in
        keyboard|virtual-keyboard|toggle|toggle-keyboard) steamdeck_toggle_virtual_keyboard ;;
        open|show|open-keyboard) steamdeck_open_virtual_keyboard ;;
        close|hide|close-keyboard)
            steamdeck_kde_deactivate_virtual_keyboard >/dev/null 2>&1 || true
            steamdeck_stop_virtual_keyboard || true
            ;;
        configure|install|repair|configure-keyboard|install-keyboard) steamdeck_configure_virtual_keyboard ;;
        revert|restore) steamdeck_revert_virtual_keyboard ;;
        status|status-keyboard) steamdeck_virtual_keyboard_status ;;
        health-json) steamdeck_virtual_keyboard_health_from_json ;;
        console) steamdeck_start_console_session "${2:-auto}" ;;
        dev|desktop) steamdeck_start_dev_session "${2:-docked-monitor}" ;;
        *) pz_error "usage: input-actions.sh (keyboard|open|close|configure|revert|status|console|dev)"; exit 1 ;;
    esac
fi
