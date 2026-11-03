#!/usr/bin/env bash
# windows-vm-boot-prepare.sh - detect DM, configure autologin for PhaseZero Windows VM boot
set -euo pipefail

TARGET_USER="${PZ_WINDOWS_VM_BOOT_USER:-}"
CMDLINE="${PZ_BOOT_CMDLINE:-$(cat /proc/cmdline 2>/dev/null || true)}"
SESSION="phasezero-windows-vm.desktop"
RUNTIME_LAUNCHER="${PZ_WINDOWS_VM_RUNTIME_LAUNCHER:-/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/windows-vm.sh}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"
TARGET_GID="$(id -g "$TARGET_USER" 2>/dev/null || true)"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
BOOT_RUNTIME_DIR="${PZ_WINDOWS_VM_RUNTIME_DIR:-/run/phasezero/windows-vm-${TARGET_UID:-unknown}}"
REQUIRE_LOGIN="${PZ_WINDOWS_VM_REQUIRE_LOGIN:-0}"

log() {
    local msg="phasezero-windows-vm-boot: $*"
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$msg" | systemd-cat -t phasezero-windows-vm-boot >/dev/null 2>&1 || printf '%s\n' "$msg"
    else
        printf '%s\n' "$msg"
    fi
}

write_value() {
    local path="$1" value="$2"
    [ -e "$path" ] || return 0
    (printf '%s\n' "$value" > "$path") 2>/dev/null || true
}

apply_vm_tuning() {
    if [ "${PZ_WINDOWS_VM_SKIP_TUNING:-0}" = "1" ]; then
        log "host VM tuning skipped by environment"
        return 0
    fi
    if command -v powerprofilesctl >/dev/null 2>&1; then
        powerprofilesctl set performance >/dev/null 2>&1 ||
            log "WARN: performance power profile unavailable; continuing boot"
    fi
    sysctl -w vm.swappiness=1 >/dev/null 2>&1 || true
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w kernel.nmi_watchdog=0 >/dev/null 2>&1 || true
    write_value /sys/kernel/mm/transparent_hugepage/enabled madvise
    write_value /sys/kernel/mm/transparent_hugepage/defrag madvise
    write_value /sys/kernel/mm/ksm/run 1
    write_value /sys/kernel/mm/ksm/pages_to_scan 1000
    write_value /sys/kernel/mm/ksm/sleep_millisecs 20
    local governor
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        write_value "$governor" performance
    done
    log "host VM tuning applied"
}

prepare_runtime_resources() {
    if [ "${PZ_WINDOWS_VM_SKIP_RUNTIME_PREP:-0}" = "1" ]; then
        log "runtime resource preparation skipped by environment"
        return 0
    fi
    if [ -z "$TARGET_UID" ] || [ -z "$TARGET_GID" ] || [ -z "$TARGET_HOME" ]; then
        log "WARN: cannot resolve boot user $TARGET_USER; skipping runtime resources"
        return 0
    fi
    if [ ! -x "$RUNTIME_LAUNCHER" ]; then
        log "WARN: runtime launcher missing: $RUNTIME_LAUNCHER"
        return 0
    fi

    if ! install -d -m 0700 -o "$TARGET_UID" -g "$TARGET_GID" "$BOOT_RUNTIME_DIR"; then
        log "WARN: cannot create boot runtime directory; continuing without pre-mounted shares"
        return 0
    fi
    if env \
        HOME="$TARGET_HOME" \
        USER="$TARGET_USER" \
        PZ_TARGET_USER="$TARGET_USER" \
        PZ_WINDOWS_VM_BOOT_SESSION=1 \
        PZ_WINDOWS_VM_RUNTIME_DIR="$BOOT_RUNTIME_DIR" \
        XDG_CONFIG_HOME="$TARGET_HOME/.config" \
        XDG_STATE_HOME="$TARGET_HOME/.local/state" \
        "$RUNTIME_LAUNCHER" shares install >/dev/null 2>&1; then
        # Do not cross the exchange bind mount while fixing runtime ownership.
        find "$BOOT_RUNTIME_DIR" -xdev -type d -exec chown "$TARGET_UID:$TARGET_GID" {} + 2>/dev/null || true
        log "runtime resources prepared without interactive authentication"
    else
        log "WARN: runtime resource preparation failed; session will use safe degraded shares"
    fi
}

runtime_launch_preflight() {
    if [ "${PZ_WINDOWS_VM_SKIP_LAUNCH_PREFLIGHT:-0}" = "1" ]; then
        log "runtime launch preflight skipped by explicit test override"
        return 0
    fi
    if [ ! -x "$RUNTIME_LAUNCHER" ]; then
        log "ERROR: runtime launch preflight unavailable: $RUNTIME_LAUNCHER"
        return 1
    fi
    local result="" rc=0
    local -a target_prefix=()
    if [ "$EUID" -eq 0 ] && [ -n "$TARGET_UID" ] && [ "$TARGET_UID" != "0" ]; then
        command -v runuser >/dev/null 2>&1 || {
            log "ERROR: runuser unavailable; cannot verify launcher as $TARGET_USER"
            return 1
        }
        target_prefix=(runuser -u "$TARGET_USER" --)
    fi
    result="$("${target_prefix[@]}" env \
        HOME="$TARGET_HOME" \
        USER="$TARGET_USER" \
        PZ_TARGET_USER="$TARGET_USER" \
        PZ_WINDOWS_VM_BOOT_SESSION=1 \
        PZ_WINDOWS_VM_RUNTIME_DIR="$BOOT_RUNTIME_DIR" \
        XDG_RUNTIME_DIR="$BOOT_RUNTIME_DIR" \
        XDG_CONFIG_HOME="$TARGET_HOME/.config" \
        XDG_STATE_HOME="$TARGET_HOME/.local/state" \
        "$RUNTIME_LAUNCHER" launch-check --raw-qemu --json 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s\n' "$result" | jq -e '.success == true' >/dev/null 2>&1; then
        local blockers
        blockers="$(printf '%s\n' "$result" | jq -r '.blockers[]?' 2>/dev/null | paste -sd ';' - || true)"
        log "ERROR: runtime launch preflight failed${blockers:+: $blockers}"
        return 1
    fi
    log "runtime launch preflight passed"
}

detect_display_manager() {
    local dm_service dm_bin
    dm_service="$(systemctl list-units --type=service --state=running 2>/dev/null | awk '$1 ~ /display-manager/ {print $1; exit}' || true)"
    [ -z "$dm_service" ] && dm_service="$(systemctl list-units --type=service --state=running 2>/dev/null | awk '$1 ~ /(sddm|gdm|lightdm|lxdm|greetd)/ && $1 !~ /phasezero/ {print $1; exit}' || true)"
    [ -z "$dm_service" ] && dm_service="$(systemctl list-units --type=service --state=running 2>/dev/null | awk '$1 ~ /(sddm|gdm|lightdm|lxdm|greetd)/ && $1 !~ /phasezero/ {print $1}')"
    case "${dm_service,,}" in
        sddm*) echo sddm; return 0 ;;
        gdm3*) echo gdm3; return 0 ;;
        gdm*) echo gdm; return 0 ;;
        lightdm*) echo lightdm; return 0 ;;
        lxdm*) echo lxdm; return 0 ;;
        greetd*) echo greetd; return 0 ;;
    esac
    if command -v sddm >/dev/null 2>&1; then echo sddm; return 0; fi
    if command -v gdm >/dev/null 2>&1 || command -v gdm3 >/dev/null 2>&1; then
        command -v gdm3 >/dev/null 2>&1 && echo gdm3 || echo gdm
        return 0
    fi
    if command -v lightdm >/dev/null 2>&1; then echo lightdm; return 0; fi
    if command -v lxdm >/dev/null 2>&1; then echo lxdm; return 0; fi
    if command -v greetd >/dev/null 2>&1; then echo greetd; return 0; fi
    echo none
}

ensure_autologin_group() {
    local dm="$1" group=""
    case "$dm" in
        gdm|gdm3) group="gdm" ;;
        lightdm) group="autologin" ;;
        *) return 0 ;;
    esac
    if getent group "$group" >/dev/null 2>&1; then
        if ! id -nG "$TARGET_USER" 2>/dev/null | grep -qw "$group"; then
            if command -v groupmems >/dev/null 2>&1; then
                groupmems -g "$group" -a "$TARGET_USER" 2>/dev/null || true
                log "added $TARGET_USER to $group group"
            elif command -v usermod >/dev/null 2>&1; then
                usermod -aG "$group" "$TARGET_USER" 2>/dev/null || true
                log "added $TARGET_USER to $group group (usermod)"
            else
                log "WARN: cannot add $TARGET_USER to $group group (no groupmems/usermod)"
            fi
        fi
    fi
}

write_sddm_autologin() {
    local conf_dir="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
    local conf_file="$conf_dir/91-phasezero-windows-vm.conf"
    install -d "$conf_dir"
    cat > "$conf_file" <<EOF
# PhaseZero managed: Windows VM one-shot boot profile
[Autologin]
User=$TARGET_USER
Session=$SESSION
Relogin=false
EOF
    chmod 0644 "$conf_file"
    log "SDDM autologin written: user=$TARGET_USER session=$SESSION"
}

remove_sddm_autologin() {
    local conf_dir="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
    local conf_file="$conf_dir/91-phasezero-windows-vm.conf"
    if [ -f "$conf_file" ] && grep -q 'PhaseZero managed' "$conf_file" 2>/dev/null; then
        rm -f "$conf_file"
        log "removed SDDM autologin: $conf_file"
    fi
}

write_gdm_autologin() {
    local conf="/etc/gdm3/custom.conf"
    [ -f "$conf" ] || conf="/etc/gdm/custom.conf"
    [ -f "$conf" ] || touch "$conf"
    if grep -q '# PhaseZero managed' "$conf" 2>/dev/null; then
        sed -i '/# PhaseZero managed/,/AutomaticLogin.*/d' "$conf"
    fi
    cat >> "$conf" <<EOF
# PhaseZero managed: Windows VM one-shot boot profile
AutomaticLoginEnable=true
AutomaticLogin=$TARGET_USER
EOF
    log "GDM autologin written: $conf"
}

remove_gdm_autologin() {
    for conf in "/etc/gdm3/custom.conf" "/etc/gdm/custom.conf"; do
        [ -f "$conf" ] || continue
        if grep -q '# PhaseZero managed' "$conf" 2>/dev/null; then
            sed -i '/# PhaseZero managed/,/AutomaticLogin=/d' "$conf"
            log "removed GDM autologin from $conf"
        fi
    done
}

write_lightdm_autologin() {
    local conf_dir="/etc/lightdm/lightdm.conf.d"
    local conf_file="$conf_dir/91-phasezero-windows-vm.conf"
    install -d "$conf_dir"
    cat > "$conf_file" <<EOF
# PhaseZero managed: Windows VM one-shot boot profile
[Seat:*]
autologin-user=$TARGET_USER
autologin-session=$SESSION
autologin-user-timeout=0
EOF
    chmod 0644 "$conf_file"
    log "LightDM autologin written: $conf_file"
}

remove_lightdm_autologin() {
    local conf_file="/etc/lightdm/lightdm.conf.d/91-phasezero-windows-vm.conf"
    if [ -f "$conf_file" ] && grep -q 'PhaseZero managed' "$conf_file" 2>/dev/null; then
        rm -f "$conf_file"
        log "removed LightDM autologin: $conf_file"
    fi
}

write_lxdm_autologin() {
    local conf="/etc/lxdm/lxdm.conf"
    [ -f "$conf" ] || return 0
    local block_start="# PhaseZero managed: Windows VM one-shot boot profile"
    local block_end="# PhaseZero managed end"
    if grep -q "$block_start" "$conf" 2>/dev/null; then
        sed -i "/$block_start/,/$block_end/d" "$conf"
    fi
    cat >> "$conf" <<EOF
$block_start
autologin=$TARGET_USER
session=/usr/local/lib/phasezero/windows-vm-session
$block_end
EOF
    log "LXDM autologin written: $conf"
}

remove_lxdm_autologin() {
    local conf="/etc/lxdm/lxdm.conf"
    [ -f "$conf" ] || return 0
    local block_start="# PhaseZero managed: Windows VM one-shot boot profile"
    local block_end="# PhaseZero managed end"
    if grep -q "$block_start" "$conf" 2>/dev/null; then
        sed -i "/$block_start/,/$block_end/d" "$conf"
        log "removed LXDM autologin from $conf"
    fi
}

write_greetd_autologin() {
    local conf="/etc/greetd/config.toml"
    [ -f "$conf" ] || return 0
    local manifest="/var/lib/phasezero/windows-vm/greetd-restore.toml"
    local original_sha
    original_sha="$(sha256sum "$conf" 2>/dev/null | awk '{print $1}' || true)"
    install -d "$(dirname "$manifest")"
    local backup="$conf.phasezero-backup"
    cp -a "$conf" "$backup" 2>/dev/null || true
    cat > "$manifest" <<EOF
# PhaseZero managed: greetd restore manifest
original_path = "$conf"
backup_path = "$backup"
original_sha256 = "${original_sha:-unavailable}"
written_at = "$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
EOF
    cat > "$conf" <<EOF
# PhaseZero managed: Windows VM one-shot boot profile
[terminal]
vt = 1

[default_session]
command = "/usr/local/lib/phasezero/windows-vm-session"
user = "$TARGET_USER"
EOF
    log "greetd autologin written: $conf (manifest: $manifest)"
}

remove_greetd_autologin() {
    local conf="/etc/greetd/config.toml"
    local manifest="/var/lib/phasezero/windows-vm/greetd-restore.toml"
    [ -f "$conf" ] || return 0
    if grep -q 'PhaseZero managed' "$conf" 2>/dev/null; then
        if [ -f "$manifest" ]; then
            local backup original_sha current_sha
            backup="$(grep '^backup_path' "$manifest" 2>/dev/null | awk -F'"' '{print $2}' || true)"
            original_sha="$(grep '^original_sha256' "$manifest" 2>/dev/null | awk -F'"' '{print $2}' || true)"
            if [ -n "$backup" ] && [ -f "$backup" ]; then
                current_sha="$(sha256sum "$conf" 2>/dev/null | awk '{print $1}' || true)"
                if [ -n "$original_sha" ] && [ "$original_sha" != "unavailable" ] && [ "$current_sha" != "$original_sha" ]; then
                    log "WARN: greetd config modified since backup (expected SHA256=$original_sha, got $current_sha); refusing to clobber"
                    log "WARN: backup preserved at $backup; manual restore required"
                    log "WARN: remove $conf and restore $backup if safe"
                    return 0
                fi
                cp -a "$backup" "$conf"
                rm -f "$backup" "$manifest"
                log "restored greetd config from manifest backup"
            else
                log "WARN: greetd manifest found but backup file missing; cannot restore"
            fi
        else
            log "WARN: greetd config is PhaseZero managed but no manifest found; leaving in place"
        fi
    fi
}

if printf '%s\n' "$CMDLINE" | grep -qw 'phasezero.windowsvm=1'; then
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ] ||
        [ -z "$TARGET_UID" ] || [ "$TARGET_UID" = "0" ] ||
        [ -z "$TARGET_GID" ] || [ -z "$TARGET_HOME" ]; then
        log "ERROR: Windows VM boot user missing or invalid; set PZ_WINDOWS_VM_BOOT_USER in the managed runtime environment"
        remove_sddm_autologin
        remove_gdm_autologin
        remove_lightdm_autologin
        remove_lxdm_autologin
        remove_greetd_autologin
        exit 2
    fi
    current_dm="$(detect_display_manager)"
    log "detected display manager: $current_dm"
    # Prepare and validate everything before enabling automatic login. If the
    # runtime cannot launch, leave the normal greeter visible instead of
    # entering a compositor that can only show a black screen.
    apply_vm_tuning
    prepare_runtime_resources
    if ! runtime_launch_preflight; then
        remove_sddm_autologin
        remove_gdm_autologin
        remove_lightdm_autologin
        remove_lxdm_autologin
        remove_greetd_autologin
        exit 1
    fi
    if [ "$REQUIRE_LOGIN" = "1" ]; then
        remove_sddm_autologin
        remove_gdm_autologin
        remove_lightdm_autologin
        remove_lxdm_autologin
        remove_greetd_autologin
        log "manual login requested; autologin disabled by operator"
    else
        case "$current_dm" in
            sddm)
                remove_sddm_autologin
                write_sddm_autologin
                ;;
            gdm|gdm3)
                ensure_autologin_group "$current_dm"
                remove_gdm_autologin
                write_gdm_autologin
                ;;
            lightdm)
                ensure_autologin_group "$current_dm"
                remove_lightdm_autologin
                write_lightdm_autologin
                ;;
            lxdm)
                ensure_autologin_group "$current_dm"
                remove_lxdm_autologin
                write_lxdm_autologin
                ;;
            greetd)
                remove_greetd_autologin
                write_greetd_autologin
                ;;
            none)
                log "WARN: no display manager detected; boot may not autologin"
                ;;
        esac
    fi
    # Remove any managed SteamOS/Waydroid blocks
    conf_dir="${PZ_SDDM_CONF_DIR:-/etc/sddm.conf.d}"
    for f in "$conf_dir/90-phasezero-steamos.conf" "$conf_dir/92-phasezero-waydroid.conf"; do
        if [ -f "$f" ] && grep -q 'PhaseZero managed' "$f" 2>/dev/null; then
            rm -f "$f"
            log "removed stale DM block: $f"
        fi
    done
    exit 0
fi

# Normal boot: strip ALL managed DM blocks
remove_sddm_autologin
remove_gdm_autologin
remove_lightdm_autologin
remove_lxdm_autologin
remove_greetd_autologin
log "normal boot detected; all PhaseZero autologin blocks removed"
