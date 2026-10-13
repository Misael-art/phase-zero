#!/usr/bin/env bash
# waydroid.sh - Waydroid automation and direct GRUB boot for PhaseZero Linux hosts
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"
if [ $# -gt 0 ]; then shift; fi

# CCS-038: usuário alvo resolvido, nunca fixo no código.
TARGET_USER="$(pz_resolve_target_user "${PZ_TARGET_USER:-}")"
[ -n "$TARGET_USER" ] || { pz_error "unable to resolve target user; set PZ_TARGET_USER"; exit 1; }
if [ "$EUID" -eq 0 ]; then
    target_home_root="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
    [ -n "$target_home_root" ] && export HOME="$target_home_root"
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
CONFIG_FILE="${PZ_WAYDROID_CONFIG:-$CONFIG_DIR/waydroid.conf}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

BOOT_HELPER_SOURCE="$PZ_ROOT/linux/waydroid/waydroid-boot-prepare.sh"
SESSION_SOURCE="$PZ_ROOT/linux/waydroid/waydroid-session.sh"
SHARES_SOURCE="${PZ_WAYDROID_SHARES_SOURCE:-$PZ_ROOT/linux/waydroid/waydroid-shares-prepare.sh}"
DISPLAY_SESSION_SOURCE="$PZ_ROOT/linux/steamdeck/display-session.sh"
BOOT_HELPER_TARGET="/usr/local/lib/phasezero/waydroid-boot-prepare"
SESSION_TARGET="/usr/local/lib/phasezero/waydroid-session"
SHARES_TARGET="${PZ_WAYDROID_SHARES_TARGET:-/usr/local/lib/phasezero/waydroid-shares-prepare}"
DISPLAY_SESSION_TARGET="/usr/local/lib/phasezero/display-session"
ROOT_ENV_FILE="/etc/phasezero/waydroid.env"
SERVICE_FILE="/etc/systemd/system/phasezero-waydroid-boot-prepare.service"
WAYLAND_SESSION_FILE="/usr/share/wayland-sessions/phasezero-waydroid.desktop"
XSESSION_FILE="/usr/share/xsessions/phasezero-waydroid.desktop"
GRUB_SCRIPT="/etc/grub.d/44_phasezero_waydroid"
GRUB_CFG="/boot/grub/grub.cfg"
SDDM_CONF="/etc/sddm.conf.d/92-phasezero-waydroid.conf"
BOOT_ENTRY="PhaseZero Waydroid"
BOOT_ID="phasezero-waydroid"
BINDERFS_DIR="${PZ_WAYDROID_BINDERFS_DIR:-/dev/binderfs}"
LXC_CONFIG_BASE="${PZ_WAYDROID_LXC_CONFIG_BASE:-/usr/lib/waydroid/data/configs/config_base}"
LXC_CONFIG="${PZ_WAYDROID_LXC_CONFIG:-/var/lib/waydroid/lxc/waydroid/config}"

DRY_RUN="${PZ_DRY_RUN:-0}"
JSON_OUT=0
WITH_BOOT=0
INIT_ANDROID=0
IMAGE_TYPE="${PZ_WAYDROID_IMAGE_TYPE:-VANILLA}"
SESSION_RESTARTS="${PZ_WAYDROID_SESSION_RESTARTS:-3}"
INIT_ATTEMPTS="${PZ_WAYDROID_INIT_ATTEMPTS:-3}"
PREFETCH_IMAGES="${PZ_WAYDROID_PREFETCH_IMAGES:-1}"
PREINSTALLED_DIR="${PZ_WAYDROID_PREINSTALLED_DIR:-/etc/waydroid-extra/images}"
OPTIMIZE_HOST="${PZ_WAYDROID_OPTIMIZE:-1}"
SHARE_EXTRA="${PZ_WAYDROID_SHARE_EXTRA:-}"
PREFETCH_SYSTEM_PATH=""
PREFETCH_VENDOR_PATH=""

usage() {
    cat <<EOF
PhaseZero Waydroid - Android container automation

Usage:
  pz waydroid status
  pz waydroid plan [--json]
  pz waydroid install [--with-boot] [--init] [--image-type VANILLA|GAPPS]
  pz waydroid repair [--init] [--image-type VANILLA|GAPPS]
  pz waydroid optimize [--dry-run]
  pz waydroid launch
  pz waydroid stop [--json]
  pz waydroid shares (status|install|remove|dry-run)
  pz waydroid boot status
  pz waydroid boot install
  pz waydroid boot next
  pz waydroid boot next-reboot
  pz waydroid boot remove
  pz waydroid boot dry-run

Notes:
  Direct boot adds a GRUB entry with phasezero.waydroid=1.
  SDDM autologin starts a minimal Wayland kiosk session for Waydroid.
  Package/profile install is separate: pz install waydroid-linux.
EOF
}

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON_OUT=1; shift ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --with-boot) WITH_BOOT=1; shift ;;
            --init) INIT_ANDROID=1; shift ;;
            --image-type) IMAGE_TYPE="${2:-VANILLA}"; shift 2 ;;
            --image-type=*) IMAGE_TYPE="${1#*=}"; shift ;;
            --restart-attempts) SESSION_RESTARTS="${2:-3}"; shift 2 ;;
            --restart-attempts=*) SESSION_RESTARTS="${1#*=}"; shift ;;
            --init-attempts) INIT_ATTEMPTS="${2:-3}"; shift 2 ;;
            --init-attempts=*) INIT_ATTEMPTS="${1#*=}"; shift ;;
            --no-prefetch) PREFETCH_IMAGES=0; shift ;;
            --optimize) OPTIMIZE_HOST=1; shift ;;
            --no-optimize) OPTIMIZE_HOST=0; shift ;;
            --help|-h) usage; exit 0 ;;
            *) pz_error "unknown waydroid option: $1"; return 1 ;;
        esac
    done
}

command_path() {
    command -v "$1" 2>/dev/null || true
}

compositor_path() {
    local path
    path="$(command_path cage)"
    [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    path="$(command_path kwin_wayland)"
    [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    path="$(command_path weston)"
    [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    return 0
}

target_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

chown_target_user() {
    [ "$EUID" -eq 0 ] || return 0
    chown "$TARGET_USER:$TARGET_USER" "$@" 2>/dev/null || true
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # PhaseZero writes this file as shell-escaped KEY=VALUE pairs.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

effective_config() {
    load_config
    IMAGE_TYPE="${PZ_WAYDROID_IMAGE_TYPE:-$IMAGE_TYPE}"
    SESSION_RESTARTS="${PZ_WAYDROID_SESSION_RESTARTS:-$SESSION_RESTARTS}"
    INIT_ATTEMPTS="${PZ_WAYDROID_INIT_ATTEMPTS:-$INIT_ATTEMPTS}"
    PREFETCH_IMAGES="${PZ_WAYDROID_PREFETCH_IMAGES:-$PREFETCH_IMAGES}"
    PREINSTALLED_DIR="${PZ_WAYDROID_PREINSTALLED_DIR:-$PREINSTALLED_DIR}"
    OPTIMIZE_HOST="${PZ_WAYDROID_OPTIMIZE:-$OPTIMIZE_HOST}"
    SHARE_EXTRA="${PZ_WAYDROID_SHARE_EXTRA:-$SHARE_EXTRA}"
}

write_config() {
    install -d "$CONFIG_DIR"
    {
        printf '# PhaseZero managed Waydroid config\n'
        printf 'PZ_WAYDROID_IMAGE_TYPE=%q\n' "$IMAGE_TYPE"
        printf 'PZ_WAYDROID_SESSION_RESTARTS=%q\n' "$SESSION_RESTARTS"
        printf 'PZ_WAYDROID_INIT_ATTEMPTS=%q\n' "$INIT_ATTEMPTS"
        printf 'PZ_WAYDROID_PREFETCH_IMAGES=%q\n' "$PREFETCH_IMAGES"
        printf 'PZ_WAYDROID_PREINSTALLED_DIR=%q\n' "$PREINSTALLED_DIR"
        printf 'PZ_WAYDROID_OPTIMIZE=%q\n' "$OPTIMIZE_HOST"
        printf 'PZ_WAYDROID_SHARE_EXTRA=%q\n' "$SHARE_EXTRA"
    } > "$CONFIG_FILE"
    chown_target_user "$CONFIG_FILE"
    pz_info "wrote $CONFIG_FILE"
}

run_privileged_noninteractive() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "$@"
        return $?
    fi
    return 1
}

write_root_value() {
    local path="$1" value="$2"
    local label="${3:-$path}"
    [ -e "$path" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would set $label -> $value"
        return 0
    fi
    if [ -w "$path" ]; then
        printf '%s\n' "$value" > "$path" 2>/dev/null || true
        return 0
    fi
    if run_privileged_noninteractive tee "$path" >/dev/null <<< "$value"; then
        return 0
    fi
    pz_warn "$label requires root; skipped non-interactive write"
}

sysctl_set_noninteractive() {
    local key="$1" value="$2"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would sysctl $key=$value"
        return 0
    fi
    if [ "$EUID" -eq 0 ]; then
        sysctl -w "$key=$value" >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n sysctl -w "$key=$value" >/dev/null 2>&1 || true
    fi
}

apply_host_optimizations() {
    [ "$OPTIMIZE_HOST" = "1" ] || return 0
    pz_info "applying Waydroid host optimizations"
    if command -v powerprofilesctl >/dev/null 2>&1; then
        powerprofilesctl set performance >/dev/null 2>&1
    fi
    sysctl_set_noninteractive vm.swappiness 1
    sysctl_set_noninteractive vm.vfs_cache_pressure 50
    sysctl_set_noninteractive vm.dirty_background_ratio 5
    sysctl_set_noninteractive vm.dirty_ratio 20
    sysctl_set_noninteractive kernel.nmi_watchdog 0
    write_root_value /sys/kernel/mm/transparent_hugepage/enabled madvise "transparent hugepages mode"
    write_root_value /sys/kernel/mm/transparent_hugepage/defrag madvise "transparent hugepages defrag"
    local governor
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        write_root_value "$governor" performance "CPU governor"
    done
}

binder_filesystem_available() {
    grep -qw binder /proc/filesystems 2>/dev/null
}

binder_devices_available() {
    [ -e /dev/binder ] || [ -e "$BINDERFS_DIR/binder" ] || [ -e /dev/vndbinder ] || [ -e /dev/hwbinder ]
}

binder_runtime_mounted() {
    mountpoint -q "$BINDERFS_DIR" 2>/dev/null
}

lxc_post_stop_hook_safe() {
    local file
    for file in "$LXC_CONFIG_BASE" "$LXC_CONFIG"; do
        [ -f "$file" ] || continue
        grep -Fqx 'lxc.hook.post-stop = /dev/null' "$file" && return 1
    done
    return 0
}

waydroid_initialized() {
    [ -e /var/lib/waydroid/waydroid_base.prop ] || return 1
    if [ -e /var/lib/waydroid/images/system.img ] && [ -e /var/lib/waydroid/images/vendor.img ]; then
        return 0
    fi
    [ -e "$PREINSTALLED_DIR/system.img" ] && [ -e "$PREINSTALLED_DIR/vendor.img" ]
}

service_state() {
    local svc="$1" mode="$2" value
    case "$mode" in
        active) value="$(systemctl is-active "$svc" 2>/dev/null || true)" ;;
        enabled) value="$(systemctl is-enabled "$svc" 2>/dev/null || true)" ;;
        *) value="unknown" ;;
    esac
    printf '%s\n' "${value:-unknown}"
}

install_user_files() {
    install -d "$APPLICATIONS_DIR" "$SYSTEMD_USER_DIR"
    pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-waydroid.desktop" system.machines <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Waydroid
Comment=Start optimized Waydroid Android session
Exec=$PZ_ROOT/linux/pz waydroid launch
Terminal=false
Categories=System;Utility;
EOF
    pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-reboot-waydroid.desktop" system.boot <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Reboot to Waydroid
Comment=Set one-shot GRUB boot to Waydroid and reboot
Exec=pkexec bash $PZ_ROOT/linux/waydroid/waydroid.sh boot next-reboot
Terminal=false
Categories=System;
EOF
    cat > "$SYSTEMD_USER_DIR/phasezero-waydroid.service" <<EOF
[Unit]
Description=PhaseZero Waydroid optimized session
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PZ_ROOT/linux/pz waydroid launch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    pz_record_created waydroid "$SYSTEMD_USER_DIR/phasezero-waydroid.service"
    chown_target_user \
        "$APPLICATIONS_DIR/phasezero-waydroid.desktop" \
        "$APPLICATIONS_DIR/phasezero-reboot-waydroid.desktop" \
        "$SYSTEMD_USER_DIR/phasezero-waydroid.service"
    pz_info "installed Waydroid user launcher and service"
}

ensure_binder_runtime() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would ensure binder runtime"
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        pz_warn "binder runtime setup requires root; skipped"
        return 0
    fi
    modprobe binder_linux devices="binder,hwbinder,vndbinder" >/dev/null 2>&1 || true
    if binder_filesystem_available; then
        install -d "$BINDERFS_DIR"
        if ! binder_runtime_mounted; then
            mount -t binder binder "$BINDERFS_DIR" >/dev/null 2>&1 ||
                pz_warn "failed to mount binder filesystem at $BINDERFS_DIR"
        fi
    fi
    binder_devices_available || pz_warn "binder device missing after runtime setup"
}

repair_lxc_post_stop_hook() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would repair non-executable Waydroid LXC post-stop hook"
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        pz_warn "Waydroid LXC hook repair requires root; skipped"
        return 0
    fi
    local file
    for file in "$LXC_CONFIG_BASE" "$LXC_CONFIG"; do
        [ -f "$file" ] || continue
        if grep -Fqx 'lxc.hook.post-stop = /dev/null' "$file"; then
            sed -i 's|^lxc\.hook\.post-stop = /dev/null$|lxc.hook.post-stop = /usr/bin/true|' "$file"
            pz_info "repaired Waydroid LXC post-stop hook: $file"
        fi
    done
}

ensure_waydroid_service() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would enable/start waydroid-container"
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        pz_warn "waydroid-container service setup requires root; skipped"
        return 0
    fi
    systemctl list-unit-files waydroid-container.service >/dev/null 2>&1 || return 0
    systemctl enable waydroid-container.service >/dev/null 2>&1 || true
    systemctl start waydroid-container.service >/dev/null 2>&1 || true
}

waydroid_shares_status() {
    local helper="$SHARES_TARGET"
    [ -x "$helper" ] || helper="$SHARES_SOURCE"
    if [ ! -f "$helper" ]; then
        # Valid report: shares tooling not installed yet is a state, not a
        # failure. Callers (plan_command previews included) stay actionable.
        jq -nc '{state:"needs-install",
                 summary:"O suporte de pastas compartilhadas do Waydroid ainda nao foi instalado.",
                 nextAction:"linux/pz waydroid shares install"}' 2>/dev/null || \
            printf 'installed=false\n'
        return 0
    fi
    PZ_WAYDROID_BOOT_USER="$TARGET_USER" \
        PZ_WAYDROID_SHARE_EXTRA="$SHARE_EXTRA" \
        bash "$helper" status
}

waydroid_shares_value() {
    local key="$1"
    waydroid_shares_status 2>/dev/null | awk -F': ' -v key="$key" '$1 == key {value=$2} END {print value}'
}

configure_waydroid_shared_access() {
    if [ "$DRY_RUN" = "1" ]; then
        PZ_WAYDROID_BOOT_USER="$TARGET_USER" \
            PZ_WAYDROID_SHARE_EXTRA="$SHARE_EXTRA" \
            bash "$SHARES_SOURCE" dry-run
        return 0
    fi
    [ "$EUID" -eq 0 ] || {
        pz_warn "Waydroid shared access setup requires root; skipped"
        return 0
    }
    install -d /usr/local/lib/phasezero
    install -m 0755 "$SHARES_SOURCE" "$SHARES_TARGET"
    PZ_WAYDROID_BOOT_USER="$TARGET_USER" \
        PZ_WAYDROID_SHARE_EXTRA="$SHARE_EXTRA" \
        "$SHARES_TARGET" install
}

cmd_shares() {
    local sub="${1:-status}"
    shift 2>/dev/null || true
    local share_groups="all"
    while [ $# -gt 0 ]; do
        case "$1" in
            --groups) share_groups="${2:-all}"; shift ;;
            --groups=*) share_groups="${1#--groups=}" ;;
        esac
        shift
    done
    effective_config
    case "$sub" in
        install|repair)
            need_root
            PZ_WAYDROID_SHARE_GROUPS="$share_groups" configure_waydroid_shared_access
            ;;
        remove)
            need_root
            [ -x "$SHARES_TARGET" ] && PZ_WAYDROID_BOOT_USER="$TARGET_USER" \
                PZ_WAYDROID_SHARE_GROUPS="$share_groups" "$SHARES_TARGET" remove
            ;;
        dry-run|plan)
            PZ_WAYDROID_BOOT_USER="$TARGET_USER" \
                PZ_WAYDROID_SHARE_GROUPS="$share_groups" bash "$SHARES_SOURCE" dry-run
            return 0
            ;;
        status) ;;
        *)
            pz_error "usage: waydroid shares (status|install|repair|remove|dry-run) [--groups folders,usb]"
            return 1
            ;;
    esac
    waydroid_shares_status
}

waydroid_ota_url() {
    local image_type="${IMAGE_TYPE^^}"
    case "$1" in
        system) printf 'https://ota.waydro.id/system/lineage/waydroid_x86_64/%s.json\n' "$image_type" ;;
        vendor) printf 'https://ota.waydro.id/vendor/waydroid_x86_64/MAINLINE.json\n' ;;
    esac
}

prefetch_waydroid_archive() {
    local kind="$1" ota metadata url size checksum filename cache_dir cache_path part_path actual_size actual_checksum
    local sourceforge_path mirror download_url downloaded=0
    ota="$(waydroid_ota_url "$kind")"
    metadata="$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 "$ota")" || {
        pz_warn "Waydroid $kind OTA metadata unavailable: $ota"
        return 1
    }
    url="$(jq -r '.response[0].url // empty' <<< "$metadata")"
    size="$(jq -r '.response[0].size // 0' <<< "$metadata")"
    checksum="$(jq -r '.response[0].id // empty' <<< "$metadata")"
    filename="$(jq -r '.response[0].filename // empty' <<< "$metadata")"
    if ! { [ -n "$url" ] && [ -n "$filename" ] && [ "$size" -gt 0 ]; }; then
        pz_warn "Waydroid $kind OTA metadata invalid"
        return 1
    fi
    cache_dir="/var/lib/waydroid/cache_http"
    cache_path="$cache_dir/${filename//\//_}_$(printf '%s' "$url" | sha256sum | awk '{print $1}')"
    part_path="${cache_path}.part"
    install -d "$cache_dir"
    actual_size="$(stat -c %s "$cache_path" 2>/dev/null || echo 0)"
    if [ "$actual_size" -ne "$size" ]; then
        pz_info "fetching Waydroid $kind image: expected=$size bytes"
        rm -f "$part_path"
        sourceforge_path="${url#*projects/waydroid/files/}"
        sourceforge_path="${sourceforge_path%/download}"
        for mirror in ${PZ_WAYDROID_SOURCEFORGE_MIRRORS:-pilotfiber phoenixnap}; do
            download_url="https://${mirror}.dl.sourceforge.net/project/waydroid/$sourceforge_path"
            pz_info "trying SourceForge mirror=$mirror"
            if curl -fsSL --retry 10 --retry-all-errors --connect-timeout 20 \
                --speed-time 30 --speed-limit 32768 --output "$part_path" "$download_url"; then
                actual_size="$(stat -c %s "$part_path" 2>/dev/null || echo 0)"
                if [ "$actual_size" -eq "$size" ]; then
                    downloaded=1
                    break
                fi
            fi
            rm -f "$part_path"
        done
        if [ "$downloaded" != "1" ]; then
            pz_info "trying canonical Waydroid URL"
            curl -fsSL --retry 10 --retry-all-errors --connect-timeout 20 \
                --speed-time 30 --speed-limit 32768 --output "$part_path" "$url"
        fi
        actual_size="$(stat -c %s "$part_path" 2>/dev/null || echo 0)"
        [ "$actual_size" -eq "$size" ] || {
            pz_warn "Waydroid $kind image incomplete: $actual_size/$size bytes"
            return 1
        }
        mv -f "$part_path" "$cache_path"
    fi
    actual_size="$(stat -c %s "$cache_path" 2>/dev/null || echo 0)"
    [ "$actual_size" -eq "$size" ] || {
        pz_warn "Waydroid $kind image incomplete: $actual_size/$size bytes"
        return 1
    }
    if [ -n "$checksum" ] && [ "${#checksum}" -eq 64 ]; then
        actual_checksum="$(sha256sum "$cache_path" | awk '{print $1}')"
        if [ "$actual_checksum" != "$checksum" ]; then
            rm -f "$cache_path"
            pz_warn "Waydroid $kind image checksum mismatch"
            return 1
        fi
    fi
    pz_info "Waydroid $kind image cache verified"
    case "$kind" in
        system) PREFETCH_SYSTEM_PATH="$cache_path" ;;
        vendor) PREFETCH_VENDOR_PATH="$cache_path" ;;
    esac
}

prefetch_waydroid_images() {
    [ "$PREFETCH_IMAGES" = "1" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would resume and verify Waydroid system/vendor image caches"
        return 0
    fi
    prefetch_waydroid_archive system
    prefetch_waydroid_archive vendor
    install -d "$PREINSTALLED_DIR"
    rm -f "$PREINSTALLED_DIR/system.img" "$PREINSTALLED_DIR/vendor.img"
    unzip -oq "$PREFETCH_SYSTEM_PATH" -d "$PREINSTALLED_DIR"
    unzip -oq "$PREFETCH_VENDOR_PATH" -d "$PREINSTALLED_DIR"
    if ! { [ -s "$PREINSTALLED_DIR/system.img" ] && [ -s "$PREINSTALLED_DIR/vendor.img" ]; }; then
        pz_warn "Waydroid preinstalled image extraction incomplete"
        return 1
    fi
    pz_info "Waydroid preinstalled images staged: $PREINSTALLED_DIR"
}

maybe_init_waydroid() {
    local attempt
    [ "$INIT_ANDROID" = "1" ] || return 0
    if ! command -v waydroid >/dev/null 2>&1; then
        pz_warn "waydroid command missing; cannot initialize Android image"
        return 0
    fi
    if waydroid_initialized; then
        pz_info "Waydroid image already initialized"
        return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would run waydroid init -s $IMAGE_TYPE (attempts=$INIT_ATTEMPTS)"
        return 0
    fi
    if [ "$EUID" -ne 0 ]; then
        pz_error "root required for Waydroid image init"
        return 1
    fi
    for attempt in $(seq 1 "$INIT_ATTEMPTS"); do
        pz_info "Waydroid init attempt $attempt/$INIT_ATTEMPTS"
        prefetch_waydroid_images || pz_warn "resumable prefetch failed; Waydroid downloader will retry"
        if waydroid init -f -i "$PREINSTALLED_DIR" -s "$IMAGE_TYPE"; then
            return 0
        fi
        waydroid_initialized && return 0
        sleep 3
    done
    pz_error "Waydroid init failed after $INIT_ATTEMPTS attempt(s)"
    return 1
}

cmd_install() {
    parse_options "$@"
    effective_config
    write_config
    install_user_files
    if [ "$WITH_BOOT" = "1" ]; then
        install_boot
    fi
}

cmd_repair() {
    parse_options "$@"
    effective_config
    write_config
    install_user_files
    apply_host_optimizations
    ensure_binder_runtime
    repair_lxc_post_stop_hook
    ensure_waydroid_service
    configure_waydroid_shared_access
    maybe_init_waydroid
}

cmd_optimize() {
    parse_options "$@"
    effective_config
    apply_host_optimizations
}

cmd_launch() {
    parse_options "$@"
    effective_config
    if [ "$DRY_RUN" = "1" ]; then
        echo "$PZ_ROOT/linux/waydroid/waydroid-session.sh"
        echo "Waydroid launcher dry-run"
        echo "  waydroid: $(command_path waydroid || true)"
        echo "  compositor: $(compositor_path || echo missing)"
        echo "  restart_attempts: $SESSION_RESTARTS"
        return 0
    fi
    write_config
    install_user_files
    exec "$PZ_ROOT/linux/waydroid/waydroid-session.sh"
}

status_json() {
    effective_config
    local config="no" waydroid_bin cage_bin weston_bin kwin_bin dbus_bin binder_fs="no" binder_dev="no" binder_mounted="no" initialized="no" lxc_hook_safe="no"
    local waydroid_active waydroid_enabled boot_helper="no" session_launcher="no" shares_helper="no" boot_service="no" boot_current="no" boot_grub current_marker="no"
    local shares_ready="no" shares_mount_count="0" shares_android_root="" shares_usb="no"
    local host_link="$HOME/Waydroid" host_linked="no"
    [ -f "$CONFIG_FILE" ] && config="yes"
    waydroid_bin="$(command_path waydroid)"
    cage_bin="$(command_path cage)"
    weston_bin="$(command_path weston)"
    kwin_bin="$(command_path kwin_wayland)"
    dbus_bin="$(command_path dbus-run-session)"
    binder_filesystem_available && binder_fs="yes"
    binder_devices_available && binder_dev="yes"
    binder_runtime_mounted && binder_mounted="yes"
    lxc_post_stop_hook_safe && lxc_hook_safe="yes"
    waydroid_initialized && initialized="yes"
    waydroid_active="$(service_state waydroid-container active)"
    waydroid_enabled="$(service_state waydroid-container enabled)"
    # CCS-005: energia pela sessão Android, não pelo container. O container
    # pode estar ativo sem nenhuma sessão Android utilizável.
    local session_running="no"
    if [ -n "$waydroid_bin" ] && timeout 10 "$waydroid_bin" status 2>/dev/null | grep -Eq '^Session:[[:space:]]*RUNNING$'; then
        session_running="yes"
    fi
    [ -x "$BOOT_HELPER_TARGET" ] && boot_helper="yes"
    [ -x "$SESSION_TARGET" ] && session_launcher="yes"
    [ -x "$SHARES_TARGET" ] && shares_helper="yes"
    [ -f "$SERVICE_FILE" ] && boot_service="yes"
    boot_artifacts_current && boot_current="yes"
    boot_grub="$(grub_cfg_entry_state)"
    grep -qw 'phasezero.waydroid=1' /proc/cmdline 2>/dev/null && current_marker="yes"
    shares_ready="$(waydroid_shares_value shares_ready)"
    shares_mount_count="$(waydroid_shares_value mount_count)"
    shares_android_root="$(waydroid_shares_value android_host_root)"
    shares_usb="$(waydroid_shares_value usb_bus_shared)"
    [ -L "$host_link" ] && host_linked="yes"
    [[ "$shares_mount_count" =~ ^[0-9]+$ ]] || shares_mount_count=0
    jq -n \
        --arg configFile "$CONFIG_FILE" \
        --arg configInstalled "$config" \
        --arg waydroid "$waydroid_bin" \
        --arg cage "$cage_bin" \
        --arg weston "$weston_bin" \
        --arg kwin "$kwin_bin" \
        --arg dbus "$dbus_bin" \
        --arg binderFs "$binder_fs" \
        --arg binderDev "$binder_dev" \
        --arg binderMounted "$binder_mounted" \
        --arg lxcHookSafe "$lxc_hook_safe" \
        --arg initialized "$initialized" \
        --arg serviceActive "$waydroid_active" \
        --arg serviceEnabled "$waydroid_enabled" \
        --arg sessionRunning "$session_running" \
        --arg imageType "$IMAGE_TYPE" \
        --arg restartAttempts "$SESSION_RESTARTS" \
        --arg initAttempts "$INIT_ATTEMPTS" \
        --arg prefetchImages "$PREFETCH_IMAGES" \
        --arg preinstalledDir "$PREINSTALLED_DIR" \
        --arg bootHelper "$boot_helper" \
        --arg sessionLauncher "$session_launcher" \
        --arg sharesHelper "$shares_helper" \
        --arg bootService "$boot_service" \
        --arg bootArtifactsCurrent "$boot_current" \
        --arg bootConfiguredRepo "$(root_env_value PZ_WAYDROID_REPO)" \
        --arg bootConfiguredUser "$(root_env_value PZ_WAYDROID_BOOT_USER)" \
        --arg grubEntry "$boot_grub" \
        --arg currentMarker "$current_marker" \
        --arg sharesReady "$shares_ready" \
        --arg sharesMountCount "$shares_mount_count" \
        --arg sharesAndroidRoot "$shares_android_root" \
        --arg sharesUsb "$shares_usb" \
        --arg hostLink "$host_link" \
        --arg hostLinked "$host_linked" \
        '{
            config: {path: $configFile, installed: ($configInstalled == "yes")},
            host: {
                waydroid: $waydroid,
                cage: $cage,
                weston: $weston,
                kwinWayland: $kwin,
                dbusRunSession: $dbus,
                binderFilesystem: ($binderFs == "yes"),
                binderDevices: ($binderDev == "yes"),
                binderMounted: ($binderMounted == "yes")
            },
            android: {
                initialized: ($initialized == "yes"),
                imageType: $imageType,
                serviceActive: $serviceActive,
                serviceEnabled: $serviceEnabled,
                sessionRunning: ($sessionRunning == "yes"),
                restartAttempts: ($restartAttempts|tonumber),
                initAttempts: ($initAttempts|tonumber),
                resumablePrefetch: ($prefetchImages == "1"),
                preinstalledDir: $preinstalledDir,
                lxcPostStopHookSafe: ($lxcHookSafe == "yes")
            },
            access: {
                sharesHelperInstalled: ($sharesHelper == "yes"),
                sharesReady: ($sharesReady == "yes"),
                mountCount: ($sharesMountCount|tonumber),
                androidHostRoot: $sharesAndroidRoot,
                usbBusShared: ($sharesUsb == "yes"),
                hostLink: $hostLink,
                hostLinked: ($hostLinked == "yes")
            },
            boot: {
                helperInstalled: ($bootHelper == "yes"),
                sessionLauncherInstalled: ($sessionLauncher == "yes"),
                serviceInstalled: ($bootService == "yes"),
                artifactsCurrent: ($bootArtifactsCurrent == "yes"),
                configuredRepo: $bootConfiguredRepo,
                configuredUser: $bootConfiguredUser,
                grubCfgEntry: $grubEntry,
                currentBootWaydroid: ($currentMarker == "yes")
            }
        }'
}

print_status() {
    parse_options "$@"
    status_json
}

cmd_stop() {
    parse_options "$@"
    local waydroid_bin output rc=0 state="stopped"
    waydroid_bin="$(command_path waydroid)"
    [ -n "$waydroid_bin" ] || { pz_error "waydroid command missing"; return 1; }
    set +e
    if timeout 15 "$waydroid_bin" status 2>/dev/null | grep -Eq '^Session:[[:space:]]*RUNNING$'; then
        output="$(timeout 30 "$waydroid_bin" session stop 2>&1)"
        rc=$?
        [ "$rc" -eq 0 ] || state="error"
    else
        # CCS-005: stop idempotente — sessão já parada é sucesso, não erro.
        output="session already stopped"
        rc=0
        state="already-stopped"
    fi
    set -e
    if [ "$JSON_OUT" = "1" ]; then
        jq -n --arg detail "$output" --argjson success "$([ "$rc" -eq 0 ] && echo true || echo false)" --arg state "$state" \
            '{success:$success,state:$state,detail:$detail}'
    elif [ "$rc" -eq 0 ]; then
        pz_info "Waydroid session stopped; apps and data preserved"
    else
        pz_error "could not stop Waydroid session: ${output:-unknown error}"
    fi
    return "$rc"
}

print_plan() {
    parse_options "$@"
    effective_config
    if [ "$JSON_OUT" = "1" ]; then
        status_json
        return 0
    fi
    echo "PhaseZero Waydroid plan"
    echo "  waydroid: $(command_path waydroid || true)"
    echo "  compositor: $(compositor_path || echo missing)"
    echo "  binder_filesystem: $(binder_filesystem_available && echo yes || echo no)"
    echo "  binder_devices: $(binder_devices_available && echo yes || echo no)"
    echo "  initialized: $(waydroid_initialized && echo yes || echo no)"
    echo "  service_active: $(service_state waydroid-container active)"
    echo "  image_type: $IMAGE_TYPE"
    echo "  init_attempts: $INIT_ATTEMPTS"
    echo "  resumable_prefetch: $PREFETCH_IMAGES"
    echo "  user_launcher: $APPLICATIONS_DIR/phasezero-waydroid.desktop"
    echo "  direct_boot: sudo $PZ_ROOT/linux/waydroid/waydroid.sh boot install"
}

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    pz_error "root required. run: sudo $PZ_ROOT/linux/waydroid/waydroid.sh boot install"
    return 1
}

need_root_action() {
    local action="$1"
    shift || true
    [ "$EUID" -eq 0 ] && return 0
    if command -v pkexec >/dev/null 2>&1 && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
        exec pkexec bash "$0" boot "$action" "$@"
    fi
    if command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$0" boot "$action" "$@"
    fi
    pz_error "root required for boot $action"
    return 1
}

parse_boot_common_args() {
    local parsed=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --target-root)
                [ -n "${2:-}" ] || { pz_error "--target-root requires a path"; return 1; }
                export PZ_BOOT_TARGET_ROOT="$2"
                shift 2
                ;;
            --target-root=*)
                export PZ_BOOT_TARGET_ROOT="${1#*=}"
                shift
                ;;
            *)
                parsed+=("$1")
                shift
                ;;
        esac
    done
    PZ_BOOT_PARSED_ARGS=("${parsed[@]}")
}

latest_kernel_version() {
    pz_boot_latest_kernel_version
}

root_uuid() {
    pz_boot_root_uuid
}

root_subvol() {
    pz_boot_root_subvol
}

session_desktop_content() {
    cat <<EOF
[Desktop Entry]
Name=PhaseZero Waydroid
Comment=Start PhaseZero Waydroid without desktop login
Exec=$SESSION_TARGET
Type=Application
DesktopNames=PhaseZeroWaydroid
EOF
}

root_env_content() {
    printf '%s\n' '# PhaseZero managed Waydroid boot environment'
    printf 'PZ_WAYDROID_REPO=%q\n' "$PZ_ROOT"
    printf 'PZ_WAYDROID_BOOT_USER=%q\n' "$TARGET_USER"
    printf 'PZ_WAYDROID_IMAGE_TYPE=%q\n' "$IMAGE_TYPE"
    printf 'PZ_WAYDROID_SESSION_RESTARTS=%q\n' "$SESSION_RESTARTS"
    printf 'PZ_WAYDROID_INIT_ATTEMPTS=%q\n' "$INIT_ATTEMPTS"
    printf 'PZ_WAYDROID_PREFETCH_IMAGES=%q\n' "$PREFETCH_IMAGES"
    printf 'PZ_WAYDROID_PREINSTALLED_DIR=%q\n' "$PREINSTALLED_DIR"
    printf 'PZ_WAYDROID_OPTIMIZE=%q\n' "$OPTIMIZE_HOST"
    printf 'PZ_WAYDROID_SHARE_EXTRA=%q\n' "$SHARE_EXTRA"
    printf 'PZ_DISPLAY_SESSION_HELPER=%q\n' "$DISPLAY_SESSION_TARGET"
}

root_env_value() {
    local name="$1"
    [ -r "$ROOT_ENV_FILE" ] || return 0
    (
        set +u
        # Root-owned file generated by root_env_content.
        # shellcheck disable=SC1090
        . "$ROOT_ENV_FILE"
        printf '%s\n' "${!name:-}"
    )
}

boot_artifacts_current() {
        [ -x "$BOOT_HELPER_TARGET" ] &&
        [ -x "$SESSION_TARGET" ] &&
        [ -x "$SHARES_TARGET" ] &&
        [ -r "$DISPLAY_SESSION_TARGET" ] &&
        [ -f "$SERVICE_FILE" ] &&
        [ -f "$WAYLAND_SESSION_FILE" ] &&
        [ -f "$XSESSION_FILE" ] &&
        [ -f "$ROOT_ENV_FILE" ] &&
        [ -x "$GRUB_SCRIPT" ] || return 1
    cmp -s "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET" || return 1
    cmp -s "$SESSION_SOURCE" "$SESSION_TARGET" || return 1
    cmp -s "$SHARES_SOURCE" "$SHARES_TARGET" || return 1
    cmp -s "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET" || return 1
    [ "$(root_env_value PZ_WAYDROID_REPO)" = "$PZ_ROOT" ] || return 1
    [ "$(root_env_value PZ_WAYDROID_BOOT_USER)" = "$TARGET_USER" ] || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$WAYLAND_SESSION_FILE" || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$XSESSION_FILE" || return 1
    grep -Fqx "ExecStart=$BOOT_HELPER_TARGET" "$SERVICE_FILE" || return 1
    grep -Fq "phasezero.waydroid=1" "$GRUB_SCRIPT" || return 1
    grep -Fq -- "--id='$BOOT_ID'" "$GRUB_SCRIPT" || return 1
}

boot_service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero Waydroid GRUB boot session switch
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Before=display-manager.service

[Service]
Type=oneshot
Environment=PZ_WAYDROID_BOOT_USER=$TARGET_USER
EnvironmentFile=-$ROOT_ENV_FILE
ExecStart=$BOOT_HELPER_TARGET

[Install]
WantedBy=graphical.target
EOF
}

grub_script_content() {
    local uuid version kernel initrd kernel_rel initrd_rel amd_ucode_rel intel_ucode_rel subvol rootflags=""
    uuid="$(root_uuid)"
    version="$(latest_kernel_version)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    [ -n "$version" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    kernel="/boot/vmlinuz-$version"
    initrd="/boot/initramfs-$version.img"
    [ -f "$kernel" ] || { pz_error "missing kernel: $kernel"; return 1; }
    [ -f "$initrd" ] || { pz_error "missing initrd: $initrd"; return 1; }
    kernel_rel="$(grub-mkrelpath "$kernel")"
    initrd_rel="$(grub-mkrelpath "$initrd")"
    if [ -f /boot/amd-ucode.img ]; then
        amd_ucode_rel="$(grub-mkrelpath /boot/amd-ucode.img)"
    else
        amd_ucode_rel=""
    fi
    if [ -f /boot/intel-ucode.img ]; then
        intel_ucode_rel="$(grub-mkrelpath /boot/intel-ucode.img)"
    else
        intel_ucode_rel=""
    fi
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"

    cat <<EOF
#!/usr/bin/env bash
exec tail -n +3 "\$0"
# PhaseZero managed GRUB entry. Re-run linux/pz waydroid boot install after kernel changes.
menuentry '$BOOT_ENTRY' --id='$BOOT_ID' --hotkey=a --class android --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Waydroid...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet splash phasezero.waydroid=1
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
}

refresh_grub_config() {
    pz_boot_refresh_grub_config "$GRUB_CFG"
}

grub_cfg_entry_state() {
    if [ -r "$GRUB_CFG" ]; then
        grep -Fq "menuentry '$BOOT_ENTRY'" "$GRUB_CFG" && echo present || echo missing
    elif [ "$EUID" -eq 0 ] && [ -f "$GRUB_CFG" ]; then
        grep -Fq "menuentry '$BOOT_ENTRY'" "$GRUB_CFG" && echo present || echo missing
    else
        echo unknown-permission
    fi
}

install_boot() {
    need_root
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    pz_boot_backup_bundle "waydroid-boot-install"
    effective_config
    install -d /usr/local/lib/phasezero /etc/phasezero /usr/share/wayland-sessions /usr/share/xsessions
    install -m 0755 "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET"
    install -m 0755 "$SESSION_SOURCE" "$SESSION_TARGET"
    install -m 0755 "$SHARES_SOURCE" "$SHARES_TARGET"
    install -m 0644 "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET"
    root_env_content > "$ROOT_ENV_FILE"
    chmod 0644 "$ROOT_ENV_FILE"
    session_desktop_content > "$WAYLAND_SESSION_FILE"
    session_desktop_content > "$XSESSION_FILE"
    chmod 0644 "$WAYLAND_SESSION_FILE" "$XSESSION_FILE"
    boot_service_content > "$SERVICE_FILE"
    chmod 0644 "$SERVICE_FILE"
    grub_script_content > "$GRUB_SCRIPT"
    chmod 0755 "$GRUB_SCRIPT"
    ensure_binder_runtime
    repair_lxc_post_stop_hook
    configure_waydroid_shared_access
    ensure_waydroid_service
    systemctl daemon-reload
    systemctl enable phasezero-waydroid-boot-prepare.service >/dev/null
    refresh_grub_config
    pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
    pz_boot_validate_active_efi_safe
    boot_artifacts_current || {
        pz_error "Waydroid boot artifact validation failed after install"
        return 1
    }
    pz_info "PhaseZero Waydroid GRUB boot entry installed"
}

remove_boot() {
    need_root
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    pz_boot_backup_bundle "waydroid-boot-remove"
    systemctl disable phasezero-waydroid-boot-prepare.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$GRUB_SCRIPT" "$WAYLAND_SESSION_FILE" "$XSESSION_FILE" "$BOOT_HELPER_TARGET" "$SESSION_TARGET" "$SHARES_TARGET" "$ROOT_ENV_FILE"
    if [ -f "$SDDM_CONF" ] && grep -q 'PhaseZero managed' "$SDDM_CONF" 2>/dev/null; then
        rm -f "$SDDM_CONF"
    fi
    systemctl daemon-reload
    refresh_grub_config
    pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
    pz_boot_validate_active_efi_safe
    pz_info "PhaseZero Waydroid GRUB boot entry removed"
}

ensure_boot_entry_ready() {
    local state
    if ! boot_artifacts_current; then
        pz_warn "Waydroid GRUB boot files missing or stale; reinstalling"
        install_boot
        return 0
    fi
    state="$(grub_cfg_entry_state)"
    if [ "$state" = "missing" ]; then
        pz_warn "Waydroid GRUB menuentry missing from $GRUB_CFG; regenerating"
        refresh_grub_config
        state="$(grub_cfg_entry_state)"
    fi
    if [ "$state" != "present" ]; then
        pz_error "Waydroid GRUB menuentry not confirmed: $state"
        return 1
    fi
}

set_next_boot_root() {
    pz_boot_require_current_root_target
    command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
    ensure_boot_entry_ready
    grub-reboot "$BOOT_ID"
    pz_info "next boot set to: $BOOT_ENTRY ($BOOT_ID)"
    pz_info "run: systemctl reboot"
}

set_next_boot() {
    need_root_action next
    set_next_boot_root
}

next_reboot() {
    need_root_action next-reboot
    set_next_boot_root
    pz_info "rebooting into Waydroid"
    systemctl reboot
}

set_default_boot() {
    need_root_action set-default
    command -v grub-set-default >/dev/null 2>&1 || { pz_error "grub-set-default missing"; return 1; }
    ensure_boot_entry_ready
    grub-set-default "$BOOT_ID"
    pz_warn "permanent GRUB default set to: $BOOT_ENTRY ($BOOT_ID)"
}

clear_next_boot() {
    need_root_action clear-next
    command -v grub-editenv >/dev/null 2>&1 || { pz_error "grub-editenv missing"; return 1; }
    grub-editenv - unset next_entry >/dev/null 2>&1 || true
    pz_info "cleared GRUB one-shot next_entry"
}

status_boot() {
    local grub_next_entry="" grub_saved_entry="" cmdline_marker="no" artifacts_current="no"
    grep -qw 'phasezero.waydroid=1' /proc/cmdline 2>/dev/null && cmdline_marker="yes"
    boot_artifacts_current && artifacts_current="yes"
    if command -v grub-editenv >/dev/null 2>&1; then
        grub_next_entry="$(grub-editenv list 2>/dev/null | awk -F= '$1 == "next_entry" {print $2; exit}')"
        grub_saved_entry="$(grub-editenv list 2>/dev/null | awk -F= '$1 == "saved_entry" {print $2; exit}')"
    fi
    echo "helper: $BOOT_HELPER_TARGET"
    [ -x "$BOOT_HELPER_TARGET" ] && echo "helper_installed: yes" || echo "helper_installed: no"
    [ -x "$SESSION_TARGET" ] && echo "session_launcher_installed: yes" || echo "session_launcher_installed: no"
    [ -f "$SERVICE_FILE" ] && echo "service_installed: yes" || echo "service_installed: no"
    systemctl is-enabled phasezero-waydroid-boot-prepare.service 2>/dev/null || true
    [ -x "$GRUB_SCRIPT" ] && echo "grub_script: yes" || echo "grub_script: no"
    echo "artifacts_current: $artifacts_current"
    echo "configured_repo: $(root_env_value PZ_WAYDROID_REPO)"
    echo "configured_boot_user: $(root_env_value PZ_WAYDROID_BOOT_USER)"
    echo "grub_cfg_entry: $(grub_cfg_entry_state)"
    echo "grub_next_entry: ${grub_next_entry:-none}"
    echo "grub_saved_entry: ${grub_saved_entry:-none}"
    [ -f "$SDDM_CONF" ] && echo "active_sddm_waydroid_conf: yes" || echo "active_sddm_waydroid_conf: no"
    echo "current_boot_waydroid: $cmdline_marker"
    echo "target_user: $TARGET_USER"
    echo "target_root: $(pz_boot_target_root)"
    echo "session: phasezero-waydroid.desktop"
    echo "grub_entry_id: $BOOT_ID"
    echo "grub_hotkey: a"
    echo "recommended_direct_boot: sudo $PZ_ROOT/linux/waydroid/waydroid.sh boot next-reboot"
}

dry_run_boot() {
    echo "PhaseZero Waydroid boot dry-run"
    echo "  helper: $BOOT_HELPER_TARGET"
    echo "  session_launcher: $SESSION_TARGET"
    echo "  service: $SERVICE_FILE"
    echo "  grub: $GRUB_SCRIPT"
    echo "  target_user: $TARGET_USER"
    echo "  root_uuid: $(root_uuid || true)"
    echo "  kernel: $(latest_kernel_version || true)"
    echo "  session: phasezero-waydroid.desktop"
    echo "  grub entry id: $BOOT_ID"
    echo "  grub hotkey: a (keyboard only; Steam Deck controls remain firmware-dependent)"
    echo "  one-shot boot: sudo $PZ_ROOT/linux/waydroid/waydroid.sh boot next"
    echo "  one-shot reboot: sudo $PZ_ROOT/linux/waydroid/waydroid.sh boot next-reboot"
}

cmd_boot() {
    parse_boot_common_args "$@"
    set -- "${PZ_BOOT_PARSED_ARGS[@]}"
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then shift; fi
    case "$sub" in
        install) install_boot "$@" ;;
        remove) remove_boot "$@" ;;
        status) status_boot "$@" ;;
        next|set-next) set_next_boot "$@" ;;
        next-reboot|reboot-waydroid|reboot) next_reboot "$@" ;;
        set-default) set_default_boot "$@" ;;
        clear-next) clear_next_boot "$@" ;;
        dry-run|plan) dry_run_boot "$@" ;;
        *) pz_error "usage: waydroid boot (install|remove|status|next|next-reboot|set-default|clear-next|dry-run)"; exit 1 ;;
    esac
}

case "$ACTION" in
    status) print_status "$@" ;;
    plan|dry-run) print_plan "$@" ;;
    install|setup) cmd_install "$@" ;;
    repair) cmd_repair "$@" ;;
    optimize|tune) cmd_optimize "$@" ;;
    launch|start|run) cmd_launch "$@" ;;
    stop|down) cmd_stop "$@" ;;
    shares|access) cmd_shares "$@" ;;
    host-access|browse-guest|internal) bash "$PZ_ROOT/linux/waydroid/host-access.sh" "${@:-status}" ;;
    boot) cmd_boot "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "usage: waydroid (status|plan|install|repair|optimize|launch|stop|shares|host-access|boot)"; exit 1 ;;
esac
