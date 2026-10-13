#!/usr/bin/env bash
# windows-vm.sh - QEMU/KVM Windows VM automation for PhaseZero Linux hosts
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

# virsh output is parsed (domstate, domblklist); force C locale so state
# strings stay "running" instead of localized ("executando", ...).
virsh() { LC_ALL=C command virsh "$@"; }

ACTION="${1:-status}"
if [ $# -gt 0 ]; then
    shift || true
fi

# Where udisks mounts removable media. Overridable so the suite can exercise
# the hot-plug paths inside a sandbox instead of writing under /run/media.
REMOVABLE_ROOT="${PZ_WINDOWS_VM_REMOVABLE_ROOT:-/run/media}"
MEDIA_ROOT="${PZ_WINDOWS_VM_MEDIA_ROOT:-/media}"
TARGET_USER="${PZ_TARGET_USER:-${SUDO_USER:-${USER:-misael}}}"
[ "$TARGET_USER" = "root" ] && TARGET_USER="misael"
if [ "$EUID" -eq 0 ]; then
    target_home_root="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
    [ -n "$target_home_root" ] && export HOME="$target_home_root"
fi

VM_NAME_DEFAULT="PhaseZero-Windows"
VM_DIR_DEFAULT="$HOME/VirtualMachines/PhaseZero-Windows"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
CONFIG_FILE="${PZ_WINDOWS_VM_CONFIG:-$CONFIG_DIR/windows-vm.conf}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm"
TARGET_RUNTIME_BASE="${XDG_RUNTIME_DIR:-}"
if [ "$EUID" -eq 0 ]; then
    target_uid="$(id -u "$TARGET_USER" 2>/dev/null || true)"
    [ -n "$target_uid" ] && [ -d "/run/user/$target_uid" ] && TARGET_RUNTIME_BASE="/run/user/$target_uid"
fi
RUNTIME_DIR="${PZ_WINDOWS_VM_RUNTIME_DIR:-${TARGET_RUNTIME_BASE:-/tmp}/phasezero-windows-vm}"
APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

BOOT_HELPER_SOURCE="$PZ_ROOT/linux/windows-vm/windows-vm-boot-prepare.sh"
SESSION_SOURCE="$PZ_ROOT/linux/windows-vm/windows-vm-session.sh"
DISPLAY_SESSION_SOURCE="$PZ_ROOT/linux/steamdeck/display-session.sh"
# Prefixo do runtime de boot. Em produção é sempre /usr/local — nenhum
# gerenciador de pacotes é dono dele, que é justamente o motivo de a cópia
# existir. A variável é costura de teste: permite exercer a ressincronização
# sem root e sem tocar no host.
BOOT_LOCAL_PREFIX="${PZ_BOOT_LOCAL_PREFIX:-/usr/local}"
BOOT_HELPER_TARGET="$BOOT_LOCAL_PREFIX/lib/phasezero/windows-vm-boot-prepare"
SESSION_TARGET="$BOOT_LOCAL_PREFIX/lib/phasezero/windows-vm-session"
DISPLAY_SESSION_TARGET="$BOOT_LOCAL_PREFIX/lib/phasezero/display-session"
RUNTIME_ROOT="$BOOT_LOCAL_PREFIX/lib/phasezero/windows-vm-runtime"
# Written by the package post-transaction hook when an upgrade leaves the
# installed runtime behind; cleared by `boot install` and read by status so
# the UI can offer the one-click resync even before runtime-check runs.
BOOT_RUNTIME_PENDING_FILE="${PZ_BOOT_RUNTIME_PENDING:-/var/lib/phasezero/windows-vm-runtime-sync.pending}"
RUNTIME_LAUNCHER="$RUNTIME_ROOT/linux/windows-vm/windows-vm.sh"
RUNTIME_GRAPHICS="$RUNTIME_ROOT/linux/windows-vm/graphics.sh"
RUNTIME_COMMON="$RUNTIME_ROOT/linux/lib/common.sh"
# Overridable so the suite asserts the shipped defaults instead of whatever the
# developer's own host happens to have persisted in /etc.
ROOT_ENV_FILE="${PZ_WINDOWS_VM_ROOT_ENV_FILE:-/etc/phasezero/windows-vm.env}"
SERVICE_FILE="/etc/systemd/system/phasezero-windows-vm-boot-prepare.service"
WAYLAND_SESSION_FILE="/usr/share/wayland-sessions/phasezero-windows-vm.desktop"
XSESSION_FILE="/usr/share/xsessions/phasezero-windows-vm.desktop"
GRUB_SCRIPT="/etc/grub.d/43_phasezero_windows_vm"
GRUB_CFG="/boot/grub/grub.cfg"
SDDM_CONF="/etc/sddm.conf.d/91-phasezero-windows-vm.conf"
BOOT_ENTRY="PhaseZero Windows VM"
BOOT_ID="phasezero-windows-vm"
BOOT_DOCK_ENTRY="PhaseZero Windows VM (Dock)"
BOOT_DOCK_ID="phasezero-windows-vm-dock"
BOOT_HANDHELD_ENTRY="PhaseZero Windows VM (Handheld)"
BOOT_HANDHELD_ID="phasezero-windows-vm-handheld"
SAMBA_CONF="${PZ_WINDOWS_VM_SAMBA_CONF:-/etc/samba/smb.conf}"
SAMBA_BEGIN="# BEGIN PHASEZERO WINDOWS VM SHARES"
SAMBA_END="# END PHASEZERO WINDOWS VM SHARES"
USB_UDEV_RULE="${PZ_WINDOWS_VM_USB_UDEV_RULE:-/etc/udev/rules.d/72-phasezero-windows-vm-usb.rules}"
EXCHANGE_DIR="${PZ_WINDOWS_VM_EXCHANGE_DIR:-$HOME/Shared/WindowsVM}"

ISO_PATH=""
ISO_EXPLICIT=0
VIRTIO_ISO=""
VM_DIR=""
DISK_PATH=""
DISK_SIZE="256G"
# Identifies the guest disk to the unattended installer, which refuses to wipe
# a target whose serial does not match. Must stay in sync with the value
# provision.sh feeds to autounattend.sh, and must satisfy its [A-Za-z0-9_-]{1,32}
# validation.
DISK_SERIAL="${PZ_WINDOWS_VM_DISK_SERIAL:-PZWINVM0}"
EXPLICIT_DISK=0
RAM_MB=""
CPUS=""
USB_MODE=""
USB_AUTO_FILTER=""
SMB_HOST=""
FULLSCREEN=0
DRY_RUN="${PZ_DRY_RUN:-0}"
JSON_OUT="${JSON_OUT:-0}"
WITH_BOOT=0
PCI_DEVICES=""
EXTRA_ARGS=""
LIBVIRT_DOMAIN=""
EXPLICIT_DOMAIN=0
RAW_QEMU=0
RAW_DISK_BUS="nvme"
DISPLAY_MODE="gtk"
DISPLAY_WIDTH=""
DISPLAY_HEIGHT=""
OPTIMIZE_HOST="${PZ_WINDOWS_VM_OPTIMIZE:-1}"
GRAPHICS_PROFILE=""
GUEST_LOGIN_POLICY=""
GUEST_USER=""
NET_MODEL=""
OVMF_CODE=""
GRAPHICS_EXPERIMENTAL=0
EXPLICIT_GRAPHICS=0
REMOVE_CONFIRMED=0
# Provenance recorded by `adopt`. "provisioned" marks a disk PhaseZero itself
# built through `provision finalize`; the default marks a disk that already
# existed on the host. `remove` reads it back to decide how loudly to warn.
ADOPT_SOURCE="adopted-existing"

usage() {
    cat <<EOF
PhaseZero Windows VM - QEMU/KVM Windows automation

Usage:
  pz windows-vm status
  pz windows-vm discover [--json]
  pz windows-vm adopt [--disk PATH] [--source provisioned|adopted-existing]
  pz windows-vm plan --iso <windows.iso> [--json]
  pz windows-vm install --iso <windows.iso> [--disk-size 256G] [--ram 8192|8G] [--cpus N] [--dry-run]
  pz windows-vm remove [--dry-run] --yes [--json]
  pz windows-vm optimize [--dry-run]
  pz windows-vm launch [--domain NAME|--raw-qemu] [--iso <windows.iso>] [--fullscreen|--headless] [--graphics <profile>] [--experimental] [--dry-run]
  pz windows-vm launch-check [--graphics <profile>] [--json]
  pz windows-vm disk-check [--json]
  pz windows-vm secure-storage [--json]
  pz windows-vm guest-login (status|backup|prune-backups|apply|restore|rollback|recovery|repair-qga|repair-preflight|transport-verify|reboot|shutdown) [--mode auto|password] [--json]
  pz windows-vm guest-login recovery (status|apply|rotate|enable|disable) --password-stdin [--local-only|--allow-remote] [--json]
  pz windows-vm recover --mode auto|password [--password-stdin] [--leave-running] [--json]
  pz windows-vm graphics status [--json]
  pz windows-vm graphics doctor [--json]
  pz windows-vm graphics plan --profile <auto|compat|virtio-gl|virtio-venus|rutabaga|vfio-looking-glass> [--json]
  pz windows-vm graphics apply --profile <compat|virtio-gl> [--experimental --yes]
  pz windows-vm graphics remove
  pz windows-vm graphics runtime (status|install|rollback)
  pz windows-vm graphics guest-guide [--save]
  pz windows-vm shares (status|install|remove|dry-run)
  pz windows-vm usb-access (status|install|remove|dry-run)
  pz windows-vm apps (status|setup|configure|doctor|install-winboat|install-winpodx|launch-winboat|launch-winpodx)
  pz windows-vm boot status
  pz windows-vm boot runtime-check [--json]
  pz windows-vm boot install
  pz windows-vm boot next
  pz windows-vm boot next-reboot
  pz windows-vm boot remove
  pz windows-vm boot dry-run

  pz windows-vm media inspect --iso PATH [--json]

  pz windows-vm provision plan --iso PATH [--json]
  pz windows-vm provision start --plan-id ID --confirm TOKEN [--json]
  pz windows-vm provision status --operation-id ID [--json]
  pz windows-vm provision watch --operation-id ID
  pz windows-vm provision resume --operation-id ID
  pz windows-vm provision cancel --operation-id ID [--remove-staging]
  pz windows-vm provision finalize --operation-id ID [--target-dir PATH] [--json]
  pz windows-vm provision shutdown --operation-id ID [--json]
  pz windows-vm provision inventory [--json]
  pz windows-vm provision remove --operation-id ID [--trash|--purge --confirm-operation ID] --yes [--json]

Access:
  home, /mnt/sdcard, /run/media/\$USER and /mnt are exposed through SMB and virtiofs when available.
  USB redirection is enabled by default. Raw usb-host passthrough requires --usb-mode all or peripherals.
  On a direct GRUB boot the Steam Deck controller is passed raw (28de:1205) so Steam Deck Tools sees the
  real device; the host loses it until the VM exits. PZ_WINDOWS_VM_STEAMDECK_CONTROLLER=raw|virtio|off|auto.
  PCI/GPU passthrough is opt-in through PZ_WINDOWS_VM_PCI_DEVICES="0000:xx:yy.z ...".
EOF
}

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --iso) ISO_PATH="${2:-}"; ISO_EXPLICIT=1; shift 2 ;;
            --iso=*) ISO_PATH="${1#*=}"; ISO_EXPLICIT=1; shift ;;
            --virtio-iso) VIRTIO_ISO="${2:-}"; shift 2 ;;
            --virtio-iso=*) VIRTIO_ISO="${1#*=}"; shift ;;
            --vm-dir) VM_DIR="${2:-}"; shift 2 ;;
            --vm-dir=*) VM_DIR="${1#*=}"; shift ;;
            --disk) DISK_PATH="${2:-}"; EXPLICIT_DISK=1; shift 2 ;;
            --disk=*) DISK_PATH="${1#*=}"; EXPLICIT_DISK=1; shift ;;
            --disk-size) DISK_SIZE="${2:-}"; shift 2 ;;
            --disk-size=*) DISK_SIZE="${1#*=}"; shift ;;
            --ram) RAM_MB="$(normalize_ram_mb "${2:-}")"; shift 2 ;;
            --ram=*) RAM_MB="$(normalize_ram_mb "${1#*=}")"; shift ;;
            --cpus) CPUS="${2:-}"; shift 2 ;;
            --cpus=*) CPUS="${1#*=}"; shift ;;
            --usb-mode) USB_MODE="${2:-}"; shift 2 ;;
            --usb-mode=*) USB_MODE="${1#*=}"; shift ;;
            --usb-auto-filter) USB_AUTO_FILTER="${2:-}"; shift 2 ;;
            --usb-auto-filter=*) USB_AUTO_FILTER="${1#*=}"; shift ;;
            --pci) PCI_DEVICES="${PCI_DEVICES:+$PCI_DEVICES }${2:-}"; shift 2 ;;
            --pci=*) PCI_DEVICES="${PCI_DEVICES:+$PCI_DEVICES }${1#*=}"; shift ;;
            --extra-qemu) EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }${2:-}"; shift 2 ;;
            --extra-qemu=*) EXTRA_ARGS="${EXTRA_ARGS:+$EXTRA_ARGS }${1#*=}"; shift ;;
            --domain) LIBVIRT_DOMAIN="${2:-}"; EXPLICIT_DOMAIN=1; shift 2 ;;
            --domain=*) LIBVIRT_DOMAIN="${1#*=}"; EXPLICIT_DOMAIN=1; shift ;;
            --raw-qemu) RAW_QEMU=1; shift ;;
            --graphics) GRAPHICS_PROFILE="${2:-}"; EXPLICIT_GRAPHICS=1; shift 2 ;;
            --graphics=*) GRAPHICS_PROFILE="${1#*=}"; EXPLICIT_GRAPHICS=1; shift ;;
            --net-model) NET_MODEL="${2:-}"; shift 2 ;;
            --net-model=*) NET_MODEL="${1#*=}"; shift ;;
            --ovmf-code) OVMF_CODE="${2:-}"; shift 2 ;;
            --ovmf-code=*) OVMF_CODE="${1#*=}"; shift ;;
            --experimental) GRAPHICS_EXPERIMENTAL=1; shift ;;
            --headless) DISPLAY_MODE="none"; shift ;;
            --optimize) OPTIMIZE_HOST=1; shift ;;
            --no-optimize) OPTIMIZE_HOST=0; shift ;;
            --fullscreen) FULLSCREEN=1; shift ;;
            --with-boot) WITH_BOOT=1; shift ;;
            --json) JSON_OUT=1; shift ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --source) ADOPT_SOURCE="${2:-}"; shift 2 ;;
            --source=*) ADOPT_SOURCE="${1#*=}"; shift ;;
            --yes) REMOVE_CONFIRMED=1; shift ;;
            --rescue) PZ_WINDOWS_VM_RESCUE=1; shift ;;
            --no-rescue) PZ_WINDOWS_VM_RESCUE=0; shift ;;
            --help|-h) usage; exit 0 ;;
            *) pz_error "unknown windows-vm option: $1"; return 1 ;;
        esac
    done
}

resolve_display_geometry() {
    local width="${PZ_WINDOWS_VM_DISPLAY_WIDTH:-}" height="${PZ_WINDOWS_VM_DISPLAY_HEIGHT:-}"
    if [ -z "$width" ] && [ -z "$height" ]; then
        DISPLAY_WIDTH=""
        DISPLAY_HEIGHT=""
        return 0
    fi
    if [[ "$width" =~ ^[0-9]+$ ]] && [[ "$height" =~ ^[0-9]+$ ]] \
        && [ "$width" -ge 320 ] && [ "$width" -le 16384 ] \
        && [ "$height" -ge 320 ] && [ "$height" -le 16384 ]; then
        DISPLAY_WIDTH="$width"
        DISPLAY_HEIGHT="$height"
        return 0
    fi
    pz_warn "invalid boot display geometry ignored: ${width:-unset}x${height:-unset}"
    DISPLAY_WIDTH=""
    DISPLAY_HEIGHT=""
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

# Ajustes de host pulados por falta de privilégio. Treze WARN seguidos dizendo
# "skipped" não dão ao usuário nada para fazer; o resumo sai uma vez, no fim,
# com o comando que aplica tudo de uma vez.
SKIPPED_HOST_TUNING=()

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
    SKIPPED_HOST_TUNING+=("$label")
    return 0
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

report_skipped_host_tuning() {
    [ "${#SKIPPED_HOST_TUNING[@]}" -gt 0 ] || return 0
    local how="sudo"
    command -v phasezero-admin >/dev/null 2>&1 && how="phasezero-admin"
    pz_warn "${#SKIPPED_HOST_TUNING[@]} ajuste(s) de host exigem privilégio e ficaram de fora: ${SKIPPED_HOST_TUNING[*]}"
    pz_warn "a VM inicia assim mesmo; para aplicá-los: $how pz windows-vm optimize"
    SKIPPED_HOST_TUNING=()
}

apply_host_optimizations() {
    [ "$OPTIMIZE_HOST" = "1" ] || return 0
    pz_info "applying Windows VM host optimizations"
    if command -v powerprofilesctl >/dev/null 2>&1; then
        powerprofilesctl set performance >/dev/null 2>&1 || true
    fi
    sysctl_set_noninteractive vm.swappiness 1
    sysctl_set_noninteractive vm.vfs_cache_pressure 50
    sysctl_set_noninteractive vm.dirty_background_ratio 5
    sysctl_set_noninteractive vm.dirty_ratio 20
    sysctl_set_noninteractive kernel.nmi_watchdog 0
    write_root_value /sys/kernel/mm/transparent_hugepage/enabled madvise "transparent hugepages mode"
    write_root_value /sys/kernel/mm/transparent_hugepage/defrag madvise "transparent hugepages defrag"
    write_root_value /sys/kernel/mm/ksm/run 1 "KSM"
    write_root_value /sys/kernel/mm/ksm/pages_to_scan 1000 "KSM pages_to_scan"
    write_root_value /sys/kernel/mm/ksm/sleep_millisecs 20 "KSM sleep_millisecs"
    local governor governors=0
    for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -e "$governor" ] || continue
        governors=$((governors + 1))
        write_root_value "$governor" performance "CPU governor"
    done
    # Um governor por núcleo vira uma linha por núcleo; conta como um item.
    if [ "$governors" -gt 1 ] && [ "${#SKIPPED_HOST_TUNING[@]}" -gt 0 ]; then
        local kept=() entry seen_governor=0
        for entry in "${SKIPPED_HOST_TUNING[@]}"; do
            if [ "$entry" = "CPU governor" ]; then
                [ "$seen_governor" = "1" ] && continue
                seen_governor=1
            fi
            kept+=("$entry")
        done
        SKIPPED_HOST_TUNING=("${kept[@]}")
    fi
    report_skipped_host_tuning
}

json_escape() {
    jq -Rs . <<< "${1:-}" | tr -d '\n'
}

normalize_ram_mb() {
    local value="$1"
    [ -n "$value" ] || { echo ""; return 0; }
    case "$value" in
        *G|*g) echo "$(( ${value%[Gg]} * 1024 ))" ;;
        *M|*m) echo "${value%[Mm]}" ;;
        *) echo "$value" ;;
    esac
}

shell_join() {
    local out="" arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out="${out:+$out }$arg"
    done
    printf '%s\n' "$out"
}

command_path() {
    command -v "$1" 2>/dev/null || true
}

virtiofsd_path() {
    command -v virtiofsd 2>/dev/null || {
        [ -x /usr/lib/virtiofsd ] && printf '%s\n' /usr/lib/virtiofsd
    } || true
}

target_home() {
    getent passwd "$TARGET_USER" | cut -d: -f6
}

chown_target_user() {
    [ "$EUID" -eq 0 ] || return 0
    chown "$TARGET_USER:$TARGET_USER" "$@" 2>/dev/null || true
}

# O runtime dir vive em /run/user/<uid> do usuário. Criado por um comando
# elevado (a ponte admin), ele nascia root:root, e toda execução seguinte sem
# privilégio morria com "Operação não permitida" ao tentar reaplicar o modo —
# um `boot install` deixava o `windows-vm start` do usuário quebrado.
ensure_runtime_dir() {
    install -d -m 0700 "$@" || return 1
    chown_target_user "$@"
}

target_user_can_rw() {
    local path="$1"
    if [ "$EUID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
        # shellcheck disable=SC2016 # intentional: $1 is the inner sh's positional arg
        runuser -u "$TARGET_USER" -- sh -c 'test -r "$1" && test -w "$1"' sh "$path" 2>/dev/null
        return $?
    fi
    [ -r "$path" ] && [ -w "$path" ]
}

# The VM is sized for one of two very different hosts, and a single figure
# cannot serve both.
#
# Booted through the GRUB entry the host runs nothing but what carries the VM,
# so anything not given to the guest is wasted. Launched over a live KDE session
# the host is running the user's actual work, and sizing from MemTotal ignores
# that: it asked for 10374 MB with 5 GB free and pushed the host into 8.6 GB of
# swap during a Windows install.
windows_vm_boot_mode() {
    if [ "${PZ_WINDOWS_VM_PROFILE:-}" = "kiosk" ] || [ "${PZ_WINDOWS_VM_PROFILE:-}" = "desktop" ]; then
        printf '%s' "$PZ_WINDOWS_VM_PROFILE"
        return 0
    fi
    if grep -qw 'phasezero.windowsvm=1' /proc/cmdline 2>/dev/null; then
        printf 'kiosk'
    else
        printf 'desktop'
    fi
}

default_ram_mb() {
    local total avail ram reserve mode floor
    total="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 8192)"
    # MemAvailable is the kernel's own estimate of what can be handed out
    # without swapping, reclaimable page cache included. MemFree alone would
    # undercount badly on a warm desktop.
    avail="$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    [ "$avail" -gt 0 ] 2>/dev/null || avail="$total"
    # Windows 11 will not run below 4 GiB, so that is the floor whatever the
    # host has left. Going under it produces a guest that boots into thrashing.
    floor=4096
    mode="$(windows_vm_boot_mode)"

    if [ "$mode" = "kiosk" ]; then
        # Kernel, systemd, SDDM, gamescope, virtiofsd and swtpm all live in this
        # reserve. An OOM on the host side kills the VM outright, so it is not
        # squeezed further.
        reserve="${PZ_WINDOWS_VM_HOST_RESERVE_MB:-2048}"
        ram=$(( total - reserve ))
    else
        # Leave the session responsive: take a share of what is actually free
        # right now, never more than 70% of the machine.
        reserve="${PZ_WINDOWS_VM_HOST_RESERVE_MB:-3072}"
        ram=$(( avail - reserve ))
        [ "$ram" -gt $(( total * 70 / 100 )) ] && ram=$(( total * 70 / 100 ))
    fi

    # Round down to a whole GiB: odd sizes gain nothing and make logs harder to
    # compare between runs.
    ram=$(( ram / 1024 * 1024 ))
    if [ "$ram" -lt "$floor" ]; then
        # Say it out loud rather than quietly handing the guest less than it
        # needs: at this point the VM and the host cannot both be comfortable.
        pz_warn "host has ${avail} MiB available; sizing the VM at the ${floor} MiB Windows 11 minimum anyway"
        pz_warn "close applications or use --ram to choose deliberately"
        ram="$floor"
    fi
    echo "$ram"
}

default_cpus() {
    local total cpus
    total="$(nproc 2>/dev/null || echo 2)"
    cpus="$total"
    [ "$total" -gt 4 ] && cpus=$(( total - 1 ))
    [ "$total" -gt 8 ] && cpus=$(( total - 2 ))
    [ "$cpus" -lt 2 ] && cpus=2
    echo "$cpus"
}

disk_actual_bytes() {
    local path="$1" info value
    [ -f "$path" ] || { echo 0; return 0; }
    if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        if [ -n "$info" ]; then
            value="$(jq -r '."actual-size" // 0' <<< "$info" 2>/dev/null || true)"
            echo "${value:-0}"
            return 0
        fi
        stat -c %s "$path" 2>/dev/null || echo 0
    else
        stat -c %s "$path" 2>/dev/null || echo 0
    fi
}

disk_virtual_bytes() {
    local path="$1" info value
    [ -f "$path" ] || { echo 0; return 0; }
    if command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        if [ -n "$info" ]; then
            value="$(jq -r '."virtual-size" // 0' <<< "$info" 2>/dev/null || true)"
            echo "${value:-0}"
            return 0
        fi
        echo 0
    else
        echo 0
    fi
}

disk_looks_installed() {
    local path="$1" actual virtual min_actual=$((5 * 1024 * 1024 * 1024)) min_virtual=$((32 * 1024 * 1024 * 1024))
    actual="$(disk_actual_bytes "$path")"
    virtual="$(disk_virtual_bytes "$path")"
    [ "${actual:-0}" -ge "$min_actual" ] && return 0
    [ "${virtual:-0}" -ge "$min_virtual" ] && [ "${actual:-0}" -ge $((1024 * 1024 * 1024)) ] && return 0
    return 1
}

find_existing_windows_disk() {
    local base path
    for path in \
        "$VM_DIR_DEFAULT/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/Windows/Windows.qcow2" \
        "$HOME/VirtualMachines/Windows11/Windows11.qcow2" \
        "$HOME/.local/share/libvirt/images/windows.qcow2" \
        "$HOME/.local/share/libvirt/images/win11.qcow2" \
        "/var/lib/libvirt/images/windows.qcow2" \
        "/var/lib/libvirt/images/win11.qcow2"; do
        [ -f "$path" ] && disk_looks_installed "$path" && { printf '%s\n' "$path"; return 0; }
    done
    for base in "$HOME/VirtualMachines" "$HOME/.local/share/libvirt/images" "/var/lib/libvirt/images" "$HOME" "/mnt/sdcard"; do
        [ -d "$base" ] || continue
        path="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.qcow2' -o -iname '*windows*.qcow2' -o -iname '*win*.img' -o -iname '*windows*.img' -o -iname '*win*.raw' -o -iname '*windows*.raw' -o -iname '*win*.vmdk' -o -iname '*windows*.vmdk' \) 2>/dev/null | sort | while IFS= read -r candidate; do disk_looks_installed "$candidate" && { printf '%s\n' "$candidate"; break; }; done | sed -n '1p' || true)"
        [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

find_usable_existing_windows_disk() {
    local candidate
    candidate="$(find_existing_windows_disk | sed -n '1p')"
    [ -n "$candidate" ] && [ -r "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    return 0
}

find_existing_windows_disk_any() {
    local base path
    for path in \
        "$VM_DIR_DEFAULT/phasezero-windows.qcow2" \
        "$HOME/VirtualMachines/PhaseZero-Windows/phasezero-windows.qcow2"; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    for base in "$HOME/VirtualMachines" "$HOME/.local/share/libvirt/images" "/var/lib/libvirt/images" "$HOME" "/mnt/sdcard"; do
        [ -d "$base" ] || continue
        path="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.qcow2' -o -iname '*windows*.qcow2' -o -iname '*win*.img' -o -iname '*windows*.img' -o -iname '*win*.raw' -o -iname '*windows*.raw' -o -iname '*win*.vmdk' -o -iname '*windows*.vmdk' \) 2>/dev/null | sort | sed -n '1p' || true)"
        [ -n "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

libvirt_uri() {
    printf '%s\n' "${PZ_WINDOWS_VM_LIBVIRT_URI:-qemu:///system}"
}

find_existing_windows_domain() {
    type -P virsh >/dev/null 2>&1 || return 0
    local uri domain source
    uri="$(libvirt_uri)"
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        if windows_name_hint "$domain"; then
            printf '%s\n' "$domain"
            return 0
        fi
        while IFS= read -r source; do
            if windows_name_hint "$source"; then
                printf '%s\n' "$domain"
                return 0
            fi
        done < <(virsh -c "$uri" domblklist "$domain" --details 2>/dev/null | awk '$2 == "disk" {print $4}')
    done < <(virsh -c "$uri" list --all --name 2>/dev/null)
    return 0
}

windows_name_hint() {
    local value="${1,,}"
    [[ "$value" =~ windows|win(vm|xp|vista|[0-9]+) ]] ||
        [[ "$value" =~ (^|[^[:alnum:]])win([^[:alnum:]]|$) ]]
}

libvirt_domain_disk() {
    local domain="$1"
    [ -n "$domain" ] || return 0
    virsh -c "$(libvirt_uri)" domblklist "$domain" --details 2>/dev/null |
        awk '$2 == "disk" && !seen++ {print $4}'
}

libvirt_domain_xml_value() {
    local domain="$1" xpath="$2"
    [ -n "$domain" ] && command -v xmllint >/dev/null 2>&1 || return 0
    virsh -c "$(libvirt_uri)" dumpxml "$domain" 2>/dev/null |
        xmllint --xpath "string($xpath)" - 2>/dev/null || true
}

libvirt_domain_nvram() {
    libvirt_domain_xml_value "$1" "/domain/os/nvram"
}

libvirt_domain_disk_bus() {
    libvirt_domain_xml_value "$1" "/domain/devices/disk[@device='disk'][1]/target/@bus"
}

discovered_windows_disk() {
    find_usable_existing_windows_disk | sed -n '1p'
}

disk_format() {
    local path="$1" info fmt
    if [ -f "$path" ] && command -v qemu-img >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
        fmt="$(jq -r '.format // empty' <<< "$info" 2>/dev/null || true)"
        [ -n "$fmt" ] && { printf '%s\n' "$fmt"; return 0; }
    fi
    case "$path" in
        *.qcow2) echo qcow2 ;;
        *.vmdk) echo vmdk ;;
        *.raw) echo raw ;;
        *.img) echo raw ;;
        *) echo qcow2 ;;
    esac
}

discovery_json() {
    local mode="${1:-full}"
    local installed="" usable="" any="" configured="" installed_like="no" usable_like="no" any_like="no" configured_like="no" installed_readable="no" usable_readable="no" any_readable="no" configured_readable="no"
    configured="${PZ_WINDOWS_VM_DISK:-}"
    [ -z "$configured" ] && [ -f "$CONFIG_FILE" ] && configured="$(bash -c '. "$0"; printf "%s\n" "${PZ_WINDOWS_VM_DISK:-}"' "$CONFIG_FILE" 2>/dev/null || true)"
    # Status is requested on every page visit. A configured disk is already
    # authoritative; rescanning all of $HOME and /mnt/sdcard here caused
    # intermittent 15s UI timeouts. `windows-vm discover` keeps the exhaustive
    # path by calling this function without the configured-only mode.
    if [ "$mode" = "configured" ] && [ -n "$configured" ] && [ -f "$configured" ]; then
        any="$configured"
        if disk_looks_installed "$configured"; then
            installed="$configured"
            [ -r "$configured" ] && usable="$configured"
        fi
    else
        installed="$(find_existing_windows_disk | sed -n '1p')"
        [ -n "$installed" ] && [ -r "$installed" ] && usable="$installed"
        any="$(find_existing_windows_disk_any | sed -n '1p')"
    fi
    if [ -n "$installed" ]; then
        installed_like="yes"
        [ -r "$installed" ] && installed_readable="yes"
    fi
    if [ -n "$usable" ]; then
        usable_like="yes"
        [ -r "$usable" ] && usable_readable="yes"
    fi
    if [ -n "$any" ] && disk_looks_installed "$any"; then
        any_like="yes"
    fi
    if [ -n "$any" ] && [ -r "$any" ]; then
        any_readable="yes"
    fi
    if [ -n "$configured" ] && [ -f "$configured" ] && disk_looks_installed "$configured"; then
        configured_like="yes"
    fi
    if [ -n "$configured" ] && [ -r "$configured" ]; then
        configured_readable="yes"
    fi
    jq -n \
        --arg installed "$installed" \
        --arg usable "$usable" \
        --arg any "$any" \
        --arg configured "$configured" \
        --arg installedLike "$installed_like" \
        --arg usableLike "$usable_like" \
        --arg anyLike "$any_like" \
        --arg configuredLike "$configured_like" \
        --arg installedReadable "$installed_readable" \
        --arg usableReadable "$usable_readable" \
        --arg anyReadable "$any_readable" \
        --arg configuredReadable "$configured_readable" \
        '{
            configuredDisk: {path: $configured, installedLike: ($configuredLike == "yes"), readable: ($configuredReadable == "yes")},
            discoveredInstalledDisk: {path: $installed, installedLike: ($installedLike == "yes"), readable: ($installedReadable == "yes"), usable: (($installedLike == "yes") and ($installedReadable == "yes"))},
            discoveredUsableDisk: {path: $usable, installedLike: ($usableLike == "yes"), readable: ($usableReadable == "yes"), usable: (($usableLike == "yes") and ($usableReadable == "yes"))},
            discoveredAnyDisk: {path: $any, installedLike: ($anyLike == "yes"), readable: ($anyReadable == "yes")}
        }'
}

detect_windows_iso() {
    local base found
    for base in /mnt/sdcard/Steam "$HOME/Downloads" "$HOME" /mnt/sdcard; do
        [ -d "$base" ] || continue
        found="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.iso' -o -iname '*windows*.iso' \) 2>/dev/null | sort | sed -n '1p' || true)"
        [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    done
    return 0
}

detect_virtio_iso() {
    local path
    for path in \
        "$HOME/Downloads/virtio-win.iso" \
        "/usr/share/virtio/virtio-win.iso" \
        "/var/lib/libvirt/images/virtio-win.iso" \
        "/mnt/sdcard/Steam/virtio-win.iso"; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

ovmf_code_path() {
    pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.secboot.fd \
        /usr/share/OVMF/OVMF_CODE.fd || true
}

ovmf_vars_template() {
    local path
    for path in \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 0
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # PhaseZero writes this file as shell-escaped KEY=VALUE pairs.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

effective_config() {
    load_config
    local configured_disk="${PZ_WINDOWS_VM_DISK:-}" discovered_disk="${PZ_WINDOWS_VM_DISCOVERED_DISK:-}"
    if [ -z "$discovered_disk" ] && { [ -z "$configured_disk" ] || [ ! -f "$configured_disk" ]; }; then
        discovered_disk="$(discovered_windows_disk)"
    fi
    VM_NAME="${PZ_WINDOWS_VM_NAME:-$VM_NAME_DEFAULT}"
    VM_DIR="${VM_DIR:-${PZ_WINDOWS_VM_DIR:-$VM_DIR_DEFAULT}}"
    if [ "$EXPLICIT_DISK" -eq 0 ] && [ -n "$configured_disk" ] && [ -n "$discovered_disk" ] && ! disk_looks_installed "$configured_disk"; then
        configured_disk=""
    fi
    DISK_PATH="${DISK_PATH:-${configured_disk:-${discovered_disk:-$VM_DIR/phasezero-windows.qcow2}}}"
    if [ "$EXPLICIT_DOMAIN" -eq 0 ]; then
        LIBVIRT_DOMAIN="${LIBVIRT_DOMAIN:-${PZ_WINDOWS_VM_LIBVIRT_DOMAIN:-$(find_existing_windows_domain)}}"
    fi
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        local domain_disk domain_bus
        domain_disk="$(libvirt_domain_disk "$LIBVIRT_DOMAIN")"
        [ -n "$domain_disk" ] && [ "$EXPLICIT_DISK" -eq 0 ] && DISK_PATH="$domain_disk"
        domain_bus="$(libvirt_domain_disk_bus "$LIBVIRT_DOMAIN")"
        [ -n "$domain_bus" ] && RAW_DISK_BUS="$domain_bus"
    fi
    ISO_PATH="${ISO_PATH:-${PZ_WINDOWS_VM_ISO:-$(detect_windows_iso)}}"
    VIRTIO_ISO="${VIRTIO_ISO:-${PZ_WINDOWS_VM_VIRTIO_ISO:-$(detect_virtio_iso)}}"
    RAM_MB="${RAM_MB:-${PZ_WINDOWS_VM_RAM_MB:-$(default_ram_mb)}}"
    CPUS="${CPUS:-${PZ_WINDOWS_VM_CPUS:-$(default_cpus)}}"
    USB_MODE="${USB_MODE:-${PZ_WINDOWS_VM_USB_MODE:-redir}}"
    USB_AUTO_FILTER="${USB_AUTO_FILTER:-${PZ_WINDOWS_VM_USB_AUTO_FILTER:-0x08,-1,-1,-1,1}}"
    SMB_HOST="${PZ_WINDOWS_VM_SMB_HOST:-$(libvirt_gateway)}"
    PCI_DEVICES="${PCI_DEVICES:-${PZ_WINDOWS_VM_PCI_DEVICES:-}}"
    EXTRA_ARGS="${EXTRA_ARGS:-${PZ_WINDOWS_VM_EXTRA_ARGS:-}}"
    GRAPHICS_PROFILE="${GRAPHICS_PROFILE:-${PZ_WINDOWS_VM_GRAPHICS_PROFILE:-compat}}"
    [ "$GRAPHICS_PROFILE" = "auto" ] && GRAPHICS_PROFILE=compat
    GUEST_LOGIN_POLICY="${GUEST_LOGIN_POLICY:-${PZ_WINDOWS_VM_GUEST_LOGIN_POLICY:-auto}}"
    case "$GUEST_LOGIN_POLICY" in
        auto|password) ;;
        *) pz_warn "unknown guest login policy '$GUEST_LOGIN_POLICY'; falling back to auto"; GUEST_LOGIN_POLICY=auto ;;
    esac
    GUEST_USER="${GUEST_USER:-${PZ_WINDOWS_VM_GUEST_USER:-phasezero}}"
    NET_MODEL="${NET_MODEL:-${PZ_WINDOWS_VM_NET_MODEL:-e1000e}}"
    case "$NET_MODEL" in
        e1000e|virtio-net-pci) ;;
        *) pz_warn "unknown network model '$NET_MODEL'; falling back to e1000e"; NET_MODEL=e1000e ;;
    esac
    OVMF_CODE="${OVMF_CODE:-${PZ_WINDOWS_VM_OVMF_CODE:-$(ovmf_code_path)}}"
    OVMF_VARS="${PZ_WINDOWS_VM_OVMF_VARS:-$VM_DIR/OVMF_VARS.fd}"
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        local domain_nvram
        domain_nvram="$(libvirt_domain_nvram "$LIBVIRT_DOMAIN")"
        [ -f "$domain_nvram" ] && OVMF_VARS="$domain_nvram"
    fi
    SHARE_ROOT="${PZ_WINDOWS_VM_SHARE_ROOT:-$VM_DIR/shares}"
    TPM_DIR="${PZ_WINDOWS_VM_TPM_DIR:-$VM_DIR/tpm}"
    # Share policy: full (default) exposes home, sdcard, removable media and
    # /mnt READ-ONLY, plus the exchange dir as the single writable door. The
    # guest can therefore read everything on the Linux side while writes stay
    # funnelled through one controlled path.
    # PZ_WINDOWS_VM_SHARE_WRITABLE=1 makes the expanded shares writable too:
    # that hands anything running in Windows - malware included - write access
    # to the whole home directory under the operator's own identity, since the
    # generated smb.conf uses `guest ok=yes` and `force user`. Keep it at 0
    # unless that exposure is a deliberate decision.
    # PZ_WINDOWS_VM_SHARE_POLICY=minimal narrows the share set back to exchange.
    SHARE_POLICY="${SHARE_POLICY:-${PZ_WINDOWS_VM_SHARE_POLICY:-full}}"
    case "$SHARE_POLICY" in
        minimal|full) ;;
        *) pz_warn "unknown share policy '$SHARE_POLICY'; falling back to minimal"; SHARE_POLICY=minimal ;;
    esac
    SHARE_WRITABLE="${SHARE_WRITABLE:-${PZ_WINDOWS_VM_SHARE_WRITABLE:-0}}"
    case "$SHARE_WRITABLE" in
        1|0) ;;
        *) pz_warn "invalid PZ_WINDOWS_VM_SHARE_WRITABLE '$SHARE_WRITABLE'; using 0 (read-only expanded shares)"; SHARE_WRITABLE=0 ;;
    esac
    # A config written before the default changed pins minimal explicitly, so it
    # keeps the narrow share set and the operator sees only exchange in the
    # guest. Say so out loud instead of letting it look like a broken share.
    if [ -f "$CONFIG_FILE" ] && [ "$SHARE_POLICY" = "minimal" ]; then
        # stderr: effective_config runs for every subcommand, including the
        # --json ones, and pz_log sends INFO to stdout. On stdout this line
        # lands inside the JSON envelope and breaks every consumer.
        pz_info "share policy=minimal from $CONFIG_FILE (only exchange exposed). Set PZ_WINDOWS_VM_SHARE_POLICY=full there for read-only home/sdcard/removable." >&2
    fi
    # SPICE binding: loopback by default. Any non-loopback address requires an
    # explicit opt-in and emits a strong warning (unauthenticated SPICE server).
    SPICE_ADDR="${SPICE_ADDR:-${PZ_WINDOWS_VM_SPICE_ADDR:-127.0.0.1}}"
    case "$SPICE_ADDR" in
        127.0.0.1|::1|localhost) ;;
        *)
            pz_warn "SPICE binding to non-loopback address $SPICE_ADDR (unauthenticated SPICE). Set PZ_WINDOWS_VM_SPICE_ADDR=127.0.0.1 unless remote access is intentional."
            ;;
    esac
    local configured_source="${PZ_WINDOWS_VM_DISK_SOURCE:-new}"
    DISK_SOURCE="$configured_source"
    if [ "$EXPLICIT_DISK" -eq 1 ]; then
        DISK_SOURCE="explicit"
    elif [ -n "${PZ_WINDOWS_VM_DISK:-}" ] && [ "$DISK_PATH" = "${PZ_WINDOWS_VM_DISK:-}" ]; then
        if [ "$configured_source" = "new" ]; then
            DISK_SOURCE="config"
        fi
    elif [ -n "$discovered_disk" ] && [ "$DISK_PATH" = "$discovered_disk" ]; then
        DISK_SOURCE="discovered-installed"
    fi
}

write_config() {
    install -d "$CONFIG_DIR"
    {
        printf '# PhaseZero managed Windows VM config\n'
        printf 'PZ_WINDOWS_VM_NAME=%q\n' "$VM_NAME"
        printf 'PZ_WINDOWS_VM_DIR=%q\n' "$VM_DIR"
        printf 'PZ_WINDOWS_VM_DISK=%q\n' "$DISK_PATH"
        printf 'PZ_WINDOWS_VM_LIBVIRT_DOMAIN=%q\n' "$LIBVIRT_DOMAIN"
        printf 'PZ_WINDOWS_VM_LIBVIRT_URI=%q\n' "$(libvirt_uri)"
        printf 'PZ_WINDOWS_VM_ISO=%q\n' "$ISO_PATH"
        printf 'PZ_WINDOWS_VM_VIRTIO_ISO=%q\n' "$VIRTIO_ISO"
        printf 'PZ_WINDOWS_VM_RAM_MB=%q\n' "$RAM_MB"
        printf 'PZ_WINDOWS_VM_CPUS=%q\n' "$CPUS"
        printf 'PZ_WINDOWS_VM_USB_MODE=%q\n' "$USB_MODE"
        printf 'PZ_WINDOWS_VM_USB_AUTO_FILTER=%q\n' "$USB_AUTO_FILTER"
        printf 'PZ_WINDOWS_VM_SMB_HOST=%q\n' "$SMB_HOST"
        printf 'PZ_WINDOWS_VM_OVMF_CODE=%q\n' "$OVMF_CODE"
        printf 'PZ_WINDOWS_VM_OVMF_VARS=%q\n' "$OVMF_VARS"
        printf 'PZ_WINDOWS_VM_SHARE_ROOT=%q\n' "$SHARE_ROOT"
        printf 'PZ_WINDOWS_VM_TPM_DIR=%q\n' "$TPM_DIR"
        printf 'PZ_WINDOWS_VM_PCI_DEVICES=%q\n' "$PCI_DEVICES"
        printf 'PZ_WINDOWS_VM_EXTRA_ARGS=%q\n' "$EXTRA_ARGS"
        printf 'PZ_WINDOWS_VM_DISK_SOURCE=%q\n' "$DISK_SOURCE"
        printf 'PZ_WINDOWS_VM_OPTIMIZE=%q\n' "$OPTIMIZE_HOST"
        printf 'PZ_WINDOWS_VM_GRAPHICS_PROFILE=%q\n' "$GRAPHICS_PROFILE"
        printf 'PZ_WINDOWS_VM_GUEST_LOGIN_POLICY=%q\n' "$GUEST_LOGIN_POLICY"
        printf 'PZ_WINDOWS_VM_GUEST_USER=%q\n' "$GUEST_USER"
        printf 'PZ_WINDOWS_VM_NET_MODEL=%q\n' "$NET_MODEL"
        printf 'PZ_WINDOWS_VM_SHARE_POLICY=%q\n' "$SHARE_POLICY"
        printf 'PZ_WINDOWS_VM_SHARE_WRITABLE=%q\n' "$SHARE_WRITABLE"
        printf 'PZ_WINDOWS_VM_SPICE_ADDR=%q\n' "$SPICE_ADDR"
    } > "$CONFIG_FILE"
    chown_target_user "$CONFIG_DIR" "$CONFIG_FILE"
    pz_info "wrote $CONFIG_FILE"
}

# The guest disk holds the user's whole Windows installation, the TPM directory
# holds its sealed keys and OVMF_VARS holds Secure Boot state. None of it may be
# readable by other local accounts, and an adopted disk arrives with whatever
# mode its creator used, so the modes are enforced on every run, not just at
# creation time.
harden_vm_storage_modes() {
    [ "$DRY_RUN" = "1" ] && return 0
    local path tpm_dir="${TPM_DIR:-}"
    for path in "${VM_DIR:-}" "${STATE_DIR:-}" "$tpm_dir"; do
        if [ -z "$path" ] || [ ! -d "$path" ]; then continue; fi
        chmod 0700 "$path" 2>/dev/null || pz_warn "could not restrict directory mode: $path"
    done
    if [ -n "$tpm_dir" ] && [ -d "$tpm_dir" ]; then
        chmod -R go-rwx "$tpm_dir" 2>/dev/null || pz_warn "could not restrict TPM state: $tpm_dir"
    fi
    for path in "${DISK_PATH:-}" "${OVMF_VARS:-}"; do
        if [ -z "$path" ] || [ ! -f "$path" ]; then continue; fi
        chmod 0600 "$path" 2>/dev/null || pz_warn "could not restrict file mode: $path"
    done
    # Guest-login backups are whole copies of the same disk. Older ones were
    # written with --preserve=mode and inherited a world-readable source.
    local backup_root="${STATE_DIR:-}/guest-login-backups"
    if [ -n "${STATE_DIR:-}" ] && [ -d "$backup_root" ]; then
        chmod -R go-rwx "$backup_root" 2>/dev/null || pz_warn "could not restrict backup modes: $backup_root"
    fi
    return 0
}

# On btrfs a copy-on-write qcow2 fragments without bound and, written with
# O_DIRECT by QEMU, can fail its own checksum on readback: btrfs then returns
# EIO to the guest mid-write. That is not theoretical here, it corrupted an
# in-flight Windows servicing operation and left the guest unbootable.
#
# nodatacow is the standard remedy and it is a real trade: btrfs stops
# checksumming this file, so silent bit rot in it would no longer be detected.
# The inherit flag only affects files created afterwards, so this must run
# before qemu-img create; an already-created image cannot be converted in place.
mark_vm_dir_nodatacow() {
    [ "$DRY_RUN" = "1" ] && return 0
    command -v chattr >/dev/null 2>&1 || return 0
    local fstype
    fstype="$(stat -f -c %T "$VM_DIR" 2>/dev/null || true)"
    [ "$fstype" = "btrfs" ] || return 0
    if chattr +C "$VM_DIR" 2>/dev/null; then
        pz_info "btrfs: $VM_DIR marked nodatacow (new VM images skip CoW and checksums)"
    else
        pz_warn "btrfs: could not set nodatacow on $VM_DIR; VM image stays copy-on-write"
    fi
}

ensure_vm_storage() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would create VM directories under $VM_DIR"
    else
        install -d -m 0700 "$VM_DIR" "$STATE_DIR"
        ensure_runtime_dir "$RUNTIME_DIR"
    fi
    if [ ! -f "$DISK_PATH" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            pz_info "dry-run: would create qcow2 disk: $DISK_PATH ($DISK_SIZE)"
        else
            mark_vm_dir_nodatacow
            qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
            pz_info "created qcow2 disk: $DISK_PATH"
        fi
    fi
    if [ ! -f "$OVMF_VARS" ]; then
        local vars_template
        vars_template="$(ovmf_vars_template)"
        [ -n "$vars_template" ] || { pz_error "OVMF_VARS template missing"; return 1; }
        if [ "$DRY_RUN" = "1" ]; then
            pz_info "dry-run: would copy OVMF vars: $vars_template -> $OVMF_VARS"
        else
            cp "$vars_template" "$OVMF_VARS"
            chown_target_user "$OVMF_VARS"
            pz_info "created OVMF vars: $OVMF_VARS"
        fi
    fi
    harden_vm_storage_modes
}

desktop_entry_content() {
    cat <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Windows VM
Comment=Launch PhaseZero Windows VM
Exec=$PZ_ROOT/linux/pz windows-vm launch --fullscreen
Terminal=false
Categories=System;Utility;
EOF
}

boot_reboot_desktop_content() {
    local exec_line terminal
    if command -v pkexec >/dev/null 2>&1; then
        exec_line="pkexec bash $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
        terminal=false
    else
        exec_line="$PZ_ROOT/linux/pz windows-vm boot next-reboot"
        terminal=true
    fi
    cat <<EOF
[Desktop Entry]
Type=Application
Name=PhaseZero Reboot to Windows VM
Comment=Set one-shot GRUB boot to PhaseZero Windows VM and reboot
Exec=$exec_line
Terminal=$terminal
Categories=System;Utility;
EOF
}

user_service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero Windows VM
After=graphical-session.target

[Service]
Type=simple
ExecStart=$PZ_ROOT/linux/pz windows-vm launch --fullscreen
Restart=no

[Install]
WantedBy=default.target
EOF
}

install_user_files() {
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $APPLICATIONS_DIR/phasezero-windows-vm.desktop"
        pz_info "dry-run: would write $APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop"
        pz_info "dry-run: would write $SYSTEMD_USER_DIR/phasezero-windows-vm.service"
        return 0
    fi
    install -d "$APPLICATIONS_DIR" "$SYSTEMD_USER_DIR"
    desktop_entry_content | pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-windows-vm.desktop" system.machines
    boot_reboot_desktop_content | pz_desktop_write_entry "$APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop" system.boot
    user_service_content > "$SYSTEMD_USER_DIR/phasezero-windows-vm.service"
    chown_target_user "$APPLICATIONS_DIR" "$APPLICATIONS_DIR/phasezero-windows-vm.desktop" "$APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop" "$SYSTEMD_USER_DIR" "$SYSTEMD_USER_DIR/phasezero-windows-vm.service"
    pz_info "installed user launcher and service"
}

require_iso_for_install() {
    if [ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH"; then
        return 0
    fi
    [ -n "$ISO_PATH" ] || { pz_error "Windows ISO missing. Use --iso /path/to/Windows.iso"; return 1; }
    [ -f "$ISO_PATH" ] || { pz_error "Windows ISO not found: $ISO_PATH"; return 1; }
}

install_vm() {
    parse_options "$@"
    effective_config
    require_iso_for_install
    [ -n "$OVMF_CODE" ] || { pz_error "OVMF code firmware missing. Install edk2-ovmf."; return 1; }
    command -v qemu-img >/dev/null 2>&1 || { pz_error "qemu-img missing. Install qemu-base/qemu-desktop."; return 1; }
    ensure_vm_storage
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $CONFIG_FILE"
        install_user_files
        pz_info "dry-run: Windows VM user-space install planned"
        return 0
    fi
    write_config
    install_user_files
    if [ "$WITH_BOOT" = "1" ]; then
        install_boot
    else
        pz_info "Windows VM user-space install complete"
        pz_info "direct GRUB boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
    fi
}

vm_admin_run() {
    if [ "$EUID" -eq 0 ]; then "$@"
    # Dedicated GRUB/SDDM sessions have no operator present. Never launch an
    # authentication agent here: it is invisible behind the kiosk compositor
    # and turns a recoverable share degradation into a permanent black screen.
    elif [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ]; then return 127
    elif pz_can_sudo_noninteractive; then sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then phasezero-admin "$@"
    else return 127; fi
}

# QEMU's built-in SMB (\\10.0.2.4\qemu) serves ONE directory and does NOT follow
# symlinks that point outside it, so the old symlink share root left the guest with
# empty home/ and sdcard/ folders. Bind mounts are real directories smbd traverses
# fine. We populate a share root outside $HOME (so bind-mounting $HOME cannot
# recurse) and expose that; sets the global EFFECTIVE_SMB_DIR.
#
# The root must also be disk-backed. Windows reports free space for the volume
# of the share ROOT, not for the bind the user is writing into, so a root on the
# RUNTIME_DIR tmpfs made the guest see ~1.4 GB and refuse larger copies even
# though the exchange bind had hundreds of GB free. Prefer a persistent path and
# fall back to RUNTIME_DIR only when there is no way to create it.
SHARE_STATE_DIR="${PZ_WINDOWS_VM_SHARE_STATE_DIR:-/var/lib/phasezero/windows-vm}"
SHARE_BIND_ROOT="${PZ_WINDOWS_VM_SHARE_BIND_ROOT:-$SHARE_STATE_DIR/shares}"
# Fallback when the persistent root cannot be created (no admin bridge, e.g. a
# GRUB boot session). The guest keeps working; only the free-space figure it
# reports goes back to being the tmpfs size.
SHARE_BIND_ROOT_FALLBACK="$RUNTIME_DIR/shares"
share_pairs() {
    local ro_marker="${1:-0}"
    if [ "$SHARE_POLICY" = "full" ]; then
        if [ "$ro_marker" = "1" ]; then
            printf '%s\n' "exchange:$EXCHANGE_DIR:rw" "home:$HOME:ro" "sdcard:/mnt/sdcard:ro" "removable:$REMOVABLE_ROOT/$TARGET_USER:ro" "media:$MEDIA_ROOT/$TARGET_USER:ro" "mnt:/mnt:ro"
        else
            printf '%s\n' "exchange:$EXCHANGE_DIR" "home:$HOME" "sdcard:/mnt/sdcard" "removable:$REMOVABLE_ROOT/$TARGET_USER" "media:$MEDIA_ROOT/$TARGET_USER" "mnt:/mnt"
        fi
    else
        if [ "$ro_marker" = "1" ]; then
            printf '%s\n' "exchange:$EXCHANGE_DIR:rw"
        else
            printf '%s\n' "exchange:$EXCHANGE_DIR"
        fi
    fi
}
# Remove bind mounts/symlinks left from a previous WIDER policy. Migrating
# full -> minimal must stop exposing home/sdcard/... to the guest. Returns
# non-zero when a stale bind survives the umount attempt (or is still mounted
# right after it), so callers can fail closed instead of exposing a wider
# share set than the current policy allows.
prune_share_links() {
    local allowed="$1" name rc=0
    for name in exchange home sdcard removable media mnt; do
        case " $allowed " in
            *" $name "*) continue ;;
        esac
        if mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
            # -R: the binds are recursive, so a plain umount would detach the
            # top and leave the submounts (a pen drive under removable/) still
            # exposed to the guest under a policy that no longer allows it.
            if ! vm_admin_run umount -R "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
                pz_warn "failed to unmount stale share bind: $SHARE_BIND_ROOT/$name"
                rc=1
            elif mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
                pz_warn "stale share bind still mounted after umount: $SHARE_BIND_ROOT/$name"
                rc=1
            fi
        fi
        # Do not leave empty directory names visible through QEMU's built-in
        # SMB root after a full -> minimal policy migration.
        rmdir -- "$SHARE_BIND_ROOT/$name" 2>/dev/null || true
        if [ -L "$SHARE_ROOT/$name" ]; then
            rm -f "$SHARE_ROOT/$name" 2>/dev/null || true
        fi
    done
    return "$rc"
}

# True when the bind at the given mountpoint is writable (findmnt OPTIONS
# lacks the ro flag). Callers only invoke this after mountpoint -q confirmed
# the bind exists.
mount_is_rw() {
    local opts=""
    opts="$(findmnt -no OPTIONS "$1" 2>/dev/null || true)"
    case ",$opts," in
        *,ro,*) return 1 ;;
    esac
    return 0
}

# Create a directory inside the share root. The root can be root-owned
# (/var/lib/phasezero/...), so fall back to the admin bridge.
share_install_dir() {
    install -d "$1" 2>/dev/null || vm_admin_run install -d "$1" 2>/dev/null
}

# udisks creates /run/media/$USER only when the first removable device is
# mounted. Binding a path that does not exist yet was skipped outright, so a
# pen drive inserted after boot could never reach the guest. Create the target
# up front; the recursive bind below then carries every later mount into it.
ensure_share_target() {
    local target="$1"
    [ -d "$target" ] && return 0
    case "$target" in
        "$REMOVABLE_ROOT"/*|"$MEDIA_ROOT"/*) share_install_dir "$target" ;;
        *) return 1 ;;
    esac
}

# A plain --bind exposes only the directory itself: every filesystem mounted
# underneath stays invisible. Removable media are exactly that - each pen drive
# is its own mount under /run/media/$USER - so the guest saw an empty folder.
# --rbind carries the mounts that already exist, and --make-rslave makes the
# ones mounted later propagate in, which is what hotplug needs.
share_bind_mount() {
    local target="$1" mountpoint_path="$2" readonly_bind="$3"
    vm_admin_run mount --rbind "$target" "$mountpoint_path" 2>/dev/null || return 1
    # Slave propagation: host -> guest share only. Without it a umount inside
    # the share root could propagate back and unmount the user's real media.
    vm_admin_run mount --make-rslave "$mountpoint_path" 2>/dev/null || true
    if [ "$readonly_bind" = "1" ]; then
        vm_admin_run mount -o remount,ro,bind "$mountpoint_path" 2>/dev/null || return 1
    fi
    return 0
}

ensure_share_links() {
    local hard_fail="${1:-0}"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would expose shares for SMB (policy=$SHARE_POLICY)"
        EFFECTIVE_SMB_DIR="$SHARE_BIND_ROOT"
        return 0
    fi
    local ok=1 pair name target mode attempt=0
    while [ "$attempt" -le 1 ]; do
        ok=1
        if ! share_install_dir "$SHARE_BIND_ROOT"; then
            if [ "$SHARE_BIND_ROOT" != "$SHARE_BIND_ROOT_FALLBACK" ] && \
               share_install_dir "$SHARE_BIND_ROOT_FALLBACK"; then
                pz_warn "persistent share root unavailable ($SHARE_BIND_ROOT); using $SHARE_BIND_ROOT_FALLBACK. The guest will report that filesystem's free space, which may refuse large copies."
                SHARE_BIND_ROOT="$SHARE_BIND_ROOT_FALLBACK"
            else
                ok=0
            fi
        fi
        if [ "$ok" = "1" ]; then
            mkdir -p "$EXCHANGE_DIR"
            while IFS= read -r pair; do
                [ -n "$pair" ] || continue
                name="${pair%%:*}"; target="${pair#*:}"
                mode="rw"
                case "$target" in
                    *:rw|*:ro) mode="${target##*:}"; target="${target%:*}" ;;
                esac
                ensure_share_target "$target" || true
                [ -d "$target" ] || continue
                if [ "$mode" = "ro" ] && [ "$SHARE_WRITABLE" != "1" ]; then
                    if mountpoint -q "$SHARE_BIND_ROOT/$name"; then
                        if mount_is_rw "$SHARE_BIND_ROOT/$name"; then
                            vm_admin_run mount -o remount,ro,bind "$SHARE_BIND_ROOT/$name" 2>/dev/null || ok=0
                        fi
                    else
                        share_install_dir "$SHARE_BIND_ROOT/$name"
                        share_bind_mount "$target" "$SHARE_BIND_ROOT/$name" 1 || { ok=0; break; }
                    fi
                elif mountpoint -q "$SHARE_BIND_ROOT/$name"; then
                    if mount_is_rw "$SHARE_BIND_ROOT/$name"; then
                        continue
                    fi
                    vm_admin_run mount -o remount,rw,bind "$SHARE_BIND_ROOT/$name" 2>/dev/null || ok=0
                else
                    share_install_dir "$SHARE_BIND_ROOT/$name"
                    share_bind_mount "$target" "$SHARE_BIND_ROOT/$name" 0 || { ok=0; break; }
                fi
            done < <(share_pairs 1)
        fi
        [ "$ok" = "1" ] && break
        [ "$attempt" -ge 1 ] && break
        attempt=$((attempt + 1))
        pz_warn "bind mount attempt $attempt failed; retrying once"
    done
    local allowed_names=""
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        allowed_names="$allowed_names ${pair%%:*}"
    done < <(share_pairs 1)
    if ! prune_share_links "$allowed_names"; then
        pz_error "stale share binds remain mounted (policy=$SHARE_POLICY); refusing to expose SMB shares"
        return 1
    fi
    if [ "$ok" = "1" ] && mountpoint -q "$SHARE_BIND_ROOT/exchange"; then
        EFFECTIVE_SMB_DIR="$SHARE_BIND_ROOT"
        if [ "$SHARE_POLICY" = "full" ]; then
            if [ "$SHARE_WRITABLE" = "1" ]; then
                pz_info "host folders bind-mounted for SMB (policy=full, writable): \\\\10.0.2.4\\qemu -> exchange, home, sdcard, removable, media, mnt"
            else
                pz_info "host folders bind-mounted for SMB (policy=full, read-only except exchange): \\\\10.0.2.4\\qemu"
            fi
        else
            pz_info "host folders bind-mounted for SMB (policy=minimal): \\\\10.0.2.4\\qemu -> exchange"
        fi
        return 0
    fi
    if [ "$hard_fail" = "1" ]; then
        pz_error "bind mounts failed and virtiofs unavailable; SMB shares will be empty in guest. Aborting boot install."
        return 1
    fi
    install -d "$SHARE_ROOT"
    mkdir -p "$EXCHANGE_DIR"
    ln -sfn "$EXCHANGE_DIR" "$SHARE_ROOT/exchange"
    if [ "$SHARE_POLICY" = "full" ]; then
        ln -sfn "$HOME" "$SHARE_ROOT/home"
        [ -d /mnt/sdcard ] && ln -sfn /mnt/sdcard "$SHARE_ROOT/sdcard"
        [ -d "$REMOVABLE_ROOT/$TARGET_USER" ] && ln -sfn "$REMOVABLE_ROOT/$TARGET_USER" "$SHARE_ROOT/removable"
        [ -d "$MEDIA_ROOT/$TARGET_USER" ] && ln -sfn "$MEDIA_ROOT/$TARGET_USER" "$SHARE_ROOT/media"
        [ -d /mnt ] && ln -sfn /mnt "$SHARE_ROOT/mnt"
    fi
    EFFECTIVE_SMB_DIR="$SHARE_ROOT"
    pz_warn "no root for bind mounts; SMB share uses symlinks (guest home/sdcard may be empty). Run: sudo pz windows-vm shares install, or use virtiofs."
}

verify_share() {
    local name="$1" expected_target="$2" result="fail" detail=""
    if mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
        local actual
        actual="$(findmnt -no TARGET "$SHARE_BIND_ROOT/$name" 2>/dev/null || echo "")"
        if [ "$actual" = "$expected_target" ] || [ -z "$expected_target" ]; then
            result="pass"
            detail="bind-mounted"
        else
            detail="bind-mounted (expected=$expected_target actual=$actual)"
        fi
    elif [ -L "$SHARE_ROOT/$name" ]; then
        result="degraded"
        detail="symlink (guest may not follow)"
    elif [ -d "$SHARE_BIND_ROOT/$name" ]; then
        detail="directory exists, not mounted"
    else
        detail="not found"
    fi
    if [ "${JSON_OUT:-0}" = "1" ]; then
        jq -nc \
            --arg name "$name" \
            --arg result "$result" \
            --arg detail "$detail" \
            '{name:$name,result:$result,detail:$detail}'
    else
        printf 'share_%s: %s (%s)\n' "$name" "$result" "$detail"
    fi
}

cmd_shares_verify() {
    local fail=0 json_output="" line result_field failures=0
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        local name="${pair%%:*}" target="${pair#*:}"
        case "$target" in
            *:rw|*:ro) target="${target%:*}" ;;
        esac
        [ -d "$target" ] || continue
        if [ "${JSON_OUT:-0}" = "1" ]; then
            line="$(verify_share "$name" "$target")"
            result_field="$(jq -r '.result' <<< "$line" 2>/dev/null || echo "fail")"
            [ "$result_field" = "pass" ] || { fail=1; failures=$((failures + 1)); }
            json_output="$json_output$line,"
        else
            local capture
            capture="$(verify_share "$name" "$target")"
            printf '%s\n' "$capture"
            # Match "share_<name>: pass" at end of token; \b makes it tolerant
            # of the parenthesised detail suffix ("pass (bind-mounted)").
            if ! grep -Eq "share_[^:]+: pass( |\$)" <<< "$capture" 2>/dev/null; then
                fail=1
            fi
        fi
    done < <(share_pairs 0)
    if [ "${JSON_OUT:-0}" = "1" ]; then
        json_output="${json_output%,}"
        printf '{"ok":%s,"failures":%d,"shares":[%s]}\n' \
            "$([ "$fail" = "0" ] && echo true || echo false)" \
            "$failures" "$json_output"
    fi
    local samba_reachable="" smb_share="PZExchange"
    [ "$SHARE_POLICY" = "full" ] && smb_share="PZHome"
    if command -v smbclient >/dev/null 2>&1; then
        if smbclient -N -L "//127.0.0.1/$smb_share" -I 127.0.0.1 -p 445 2>&1 | grep "$smb_share" >/dev/null; then
            samba_reachable="yes"
        else
            samba_reachable="no"
            fail=1
        fi
    fi
    if [ "${JSON_OUT:-0}" != "1" ]; then
        [ -n "$samba_reachable" ] && echo "samba_${smb_share}_reachable: $samba_reachable"
        printf 'shares_ok: %s\n' "$([ "$fail" = "0" ] && echo yes || echo no)"
    fi
    return $fail
}

# Unmount the bind-mount share root (called on teardown / shares clean).
clean_share_binds() {
    local name
    for name in exchange home sdcard removable media mnt; do
        if mountpoint -q "$SHARE_BIND_ROOT/$name" 2>/dev/null; then
            vm_admin_run umount "$SHARE_BIND_ROOT/$name" 2>/dev/null || true
        fi
    done
}

libvirt_gateway() {
    local gateway=""
    if type -P virsh >/dev/null 2>&1; then
        gateway="$(virsh -c "$(libvirt_uri)" net-dumpxml default 2>/dev/null |
            awk -F"'" '/<ip address=/{if (!seen++) print $2}')"
    fi
    printf '%s\n' "${gateway:-192.168.122.1}"
}

# One expanded share stanza (full policy only). Read-only unless the operator
# explicitly opted into writable expanded shares (SHARE_WRITABLE=1).
samba_ro_stanza() {
    local name="$1" comment="$2" path="$3" veto="${4:-}"
    cat <<EOF
[$name]
    comment = $comment
    path = $path
    browseable = yes
    read only = $([ "$SHARE_WRITABLE" = "1" ] && echo no || echo yes)
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
$( [ -n "$veto" ] && printf '    veto files = %s\n' "$veto" )
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

EOF
}

samba_block_content() {
    local home removable media
    home="$(target_home)"
    removable="$REMOVABLE_ROOT/$TARGET_USER"
    media="$MEDIA_ROOT/$TARGET_USER"
    if [ "$SHARE_POLICY" = "full" ]; then
        cat <<EOF
$SAMBA_BEGIN
[PZExchange]
    comment = PhaseZero Windows exchange
    path = $EXCHANGE_DIR
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    smb encrypt = desired
    follow symlinks = no
    wide links = no
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

$(samba_ro_stanza PZHome "PhaseZero host home" "$home" '/.ssh/.gnupg/.aws/.kube/')
$(samba_ro_stanza PZSDCard "PhaseZero SD card" /mnt/sdcard)
$(samba_ro_stanza PZRemovable "PhaseZero removable media" "$removable")
$(samba_ro_stanza PZMedia "PhaseZero media mounts" "$media")
$(samba_ro_stanza PZMounts "PhaseZero host mounts" /mnt)
$SAMBA_END
EOF
    else
        # Policy=minimal: only the exchange directory is ever published.
        # Home, SD card, removable/media and /mnt are NOT exported over SMB.
        cat <<EOF
$SAMBA_BEGIN
[PZExchange]
    comment = PhaseZero Windows exchange
    path = $EXCHANGE_DIR
    browseable = yes
    read only = no
    guest ok = yes
    force user = $TARGET_USER
    force group = $TARGET_USER
    create mask = 0660
    directory mask = 0770
    smb encrypt = desired
    follow symlinks = no
    wide links = no
    hosts allow = 127.0.0.1 192.168.122.0/24
    hosts deny = 0.0.0.0/0

$SAMBA_END
EOF
    fi
}

strip_managed_samba_block() {
    local input="$1" output="$2"
    awk -v begin="$SAMBA_BEGIN" -v end="$SAMBA_END" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "$input" > "$output"
}

samba_shares_managed() {
    [ -r "$SAMBA_CONF" ] &&
        grep -Fqx "$SAMBA_BEGIN" "$SAMBA_CONF" &&
        grep -Fqx "$SAMBA_END" "$SAMBA_CONF" &&
        command -v testparm >/dev/null 2>&1 &&
        testparm -s "$SAMBA_CONF" >/dev/null 2>&1
}

samba_shares_reachable() {
    command -v smbclient >/dev/null 2>&1 || return 1
    local probe_timeout="${PZ_WINDOWS_VM_STATUS_PROBE_TIMEOUT_SECONDS:-4}"
    local -a timeout_prefix=()
    if command -v timeout >/dev/null 2>&1; then
        timeout_prefix=(timeout --signal=TERM --kill-after=1 "$probe_timeout")
    fi
    "${timeout_prefix[@]}" smbclient -N //127.0.0.1/PZExchange -c 'ls' >/dev/null 2>&1 || return 1
    if [ "$SHARE_POLICY" = "full" ]; then
        "${timeout_prefix[@]}" smbclient -N //127.0.0.1/PZHome -c 'ls' >/dev/null 2>&1 || return 1
        "${timeout_prefix[@]}" smbclient -N //127.0.0.1/PZSDCard -c 'ls' >/dev/null 2>&1 || return 1
    fi
}

# The managed block currently on disk must match the effective share policy:
# minimal publishes only PZExchange; full must include the expanded shares.
samba_policy_compliant() {
    [ -r "$SAMBA_CONF" ] || return 1
    if [ "$SHARE_POLICY" = "full" ]; then
        grep -q '^\[PZHome\]' "$SAMBA_CONF"
    else
        if grep -qE '^\[PZ(Home|SDCard|Removable|Media|Mounts)\]' "$SAMBA_CONF"; then
            return 1
        fi
        return 0
    fi
}

windows_usb_udev_content() {
    cat <<'EOF'
# PhaseZero: active-seat access for external USB passthrough.
# SPICE auto-redirection remains restricted to mass-storage interfaces.
ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_INTEGRATION}=="external", MODE="0660", TAG+="uaccess"
ACTION!="remove", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:08????:*", MODE="0660", TAG+="uaccess"
EOF
}

windows_usb_udev_managed() {
    [ -r "$USB_UDEV_RULE" ] && cmp -s <(windows_usb_udev_content) "$USB_UDEV_RULE"
}

configure_windows_usb_access() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to configure Windows VM USB access"
        return 1
    }
    install -d "$(dirname "$USB_UDEV_RULE")"
    windows_usb_udev_content > "$USB_UDEV_RULE"
    chmod 0644 "$USB_UDEV_RULE"
    command -v udevadm >/dev/null 2>&1 || return 0
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --action=change
    udevadm settle --timeout=10 || true
}

remove_windows_usb_access() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to remove Windows VM USB access"
        return 1
    }
    rm -f "$USB_UDEV_RULE"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=usb --action=change
    fi
    pz_info "Windows VM USB access disabled"
}

cmd_usb_access() {
    local sub="${1:-status}"
    case "$sub" in
        install|enable)
            need_root
            configure_windows_usb_access
            ;;
        remove|disable)
            need_root
            remove_windows_usb_access
            ;;
        dry-run|plan)
            echo "Windows VM USB access plan"
            echo "  managed rule: $USB_UDEV_RULE"
            echo "  policy: active-seat external devices and mass storage"
            return 0
            ;;
        status) ;;
        *) pz_error "usage: windows-vm usb-access (status|install|remove|dry-run)"; return 1 ;;
    esac
    jq -n \
        --arg rule "$USB_UDEV_RULE" \
        --argjson managed "$(windows_usb_udev_managed && echo true || echo false)" \
        --argjson channels "$(libvirt_usb_redir_count)" \
        '{tool:"windows-vm-usb-access",rule:$rule,managed:$managed,redirChannels:$channels}'
}

configure_windows_samba_shares() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to configure Windows VM host shares"
        return 1
    }
    command -v testparm >/dev/null 2>&1 || {
        pz_error "testparm missing; install Samba"
        return 1
    }
    [ -f "$SAMBA_CONF" ] || {
        pz_error "Samba config missing: $SAMBA_CONF"
        return 1
    }
    local tmp backup_dir fw_zone exchange_parent target_home_dir
    tmp="$(mktemp)"
    strip_managed_samba_block "$SAMBA_CONF" "$tmp"
    printf '\n' >> "$tmp"
    samba_block_content >> "$tmp"
    testparm -s "$tmp" >/dev/null
    backup_dir="/var/lib/phasezero/windows-vm/samba-backups"
    install -d -m 0700 "$backup_dir"
    cp -a "$SAMBA_CONF" "$backup_dir/smb.conf.$(date +%Y%m%d-%H%M%S)"
    install -m 0644 "$tmp" "$SAMBA_CONF"
    rm -f "$tmp"
    # Repair the canonical parent created by older root runs, then create every
    # missing descendant as the desktop user.  Do not chown arbitrary override
    # parents outside the target home.
    exchange_parent="$(dirname "$EXCHANGE_DIR")"
    target_home_dir="$(target_home)"
    if [ "$exchange_parent" = "$target_home_dir/Shared" ]; then
        install -d -m 0750 -o "$TARGET_USER" -g "$TARGET_USER" "$exchange_parent"
    fi
    # A root-owned 0700
    # $HOME/Shared made smbd authenticate successfully but fail the first chdir.
    runuser -u "$TARGET_USER" -- mkdir -p "$EXCHANGE_DIR" || {
        pz_error "target user cannot create exchange directory: $EXCHANGE_DIR"
        return 1
    }
    chown "$TARGET_USER:$TARGET_USER" "$EXCHANGE_DIR"
    chmod 0770 "$EXCHANGE_DIR"
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$REMOVABLE_ROOT/$TARGET_USER" "$MEDIA_ROOT/$TARGET_USER"
    systemctl enable --now smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    systemctl restart smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1; then
        ufw allow in on virbr0 to any port 445 proto tcp comment 'PhaseZero Windows VM SMB' >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        fw_zone="$(firewall-cmd --get-zone-of-interface=virbr0 2>/dev/null || true)"
        firewall-cmd --permanent --zone="${fw_zone:-libvirt}" --add-service=samba >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    samba_shares_reachable || {
        pz_error "managed Samba shares failed local reachability test"
        return 1
    }
    configure_windows_usb_access
    if [ "$SHARE_POLICY" = "full" ]; then
        pz_info "Windows shares ready: \\\\$(libvirt_gateway)\\PZExchange, PZHome, PZSDCard, PZRemovable, PZMedia, PZMounts (policy=full, writable=$SHARE_WRITABLE)"
    else
        pz_info "Windows shares ready: \\\\$(libvirt_gateway)\\PZExchange (policy=minimal)"
    fi
}

remove_windows_samba_shares() {
    [ "$EUID" -eq 0 ] || {
        pz_error "root required to remove Windows VM host shares"
        return 1
    }
    [ -f "$SAMBA_CONF" ] || return 0
    local tmp
    tmp="$(mktemp)"
    strip_managed_samba_block "$SAMBA_CONF" "$tmp"
    testparm -s "$tmp" >/dev/null
    install -m 0644 "$tmp" "$SAMBA_CONF"
    rm -f "$tmp"
    rm -f "$USB_UDEV_RULE"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=usb --action=change
    fi
    systemctl restart smb.service >/dev/null 2>&1 || systemctl restart smbd.service >/dev/null 2>&1 || true
    pz_info "PhaseZero Windows Samba shares removed"
}

libvirt_usb_redir_count() {
    [ -n "$LIBVIRT_DOMAIN" ] || { echo 0; return 0; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk '/<redirdev /{count++} END{print count+0}'
}

usb_accessible_device_count() {
    local count=0 device
    for device in /dev/bus/usb/*/*; do
        [ -c "$device" ] || continue
        [ -r "$device" ] && [ -w "$device" ] && count=$((count + 1))
    done
    echo "$count"
}

share_links_ready() {
    local root
    for root in "$SHARE_BIND_ROOT" /tmp/phasezero-windows-vm/shares; do
        mountpoint -q "$root/exchange" 2>/dev/null || continue
        if [ "$SHARE_POLICY" = "minimal" ]; then
            return 0
        fi
        if mountpoint -q "$root/home" 2>/dev/null &&
            mountpoint -q "$root/sdcard" 2>/dev/null &&
            mountpoint -q "$root/mnt" 2>/dev/null; then
            return 0
        fi
    done
    if [ "$SHARE_POLICY" = "minimal" ]; then
        [ -L "$SHARE_ROOT/exchange" ]
        return $?
    fi
    [ -L "$SHARE_ROOT/exchange" ] && [ -L "$SHARE_ROOT/home" ] &&
        [ -L "$SHARE_ROOT/sdcard" ] && [ -L "$SHARE_ROOT/mnt" ]
}

libvirt_webdav_channel_count() {
    [ -n "$LIBVIRT_DOMAIN" ] || { echo 0; return 0; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk '/<channel type=/{channel=1} channel && /org.spice-space.webdav.0/{count++; channel=0} /<\/channel>/{channel=0} END{print count+0}'
}

libvirt_network_state() {
    type -P virsh >/dev/null 2>&1 || { printf missing; return; }
    virsh -c "$(libvirt_uri)" net-info default 2>/dev/null |
        awk -F: '/^Active:/{gsub(/^[[:space:]]+/,"",$2); print $2; found=1} END{if(!found) print "missing"}'
}

libvirt_interface_model() {
    [ -n "$LIBVIRT_DOMAIN" ] || { printf missing; return; }
    virsh -c "$(libvirt_uri)" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null |
        awk -F"'" '/<model type=/{print $2; found=1; exit} END{if(!found) print "unknown"}'
}

grant_raw_qemu_disk_access() {
    local disk="${1:-$DISK_PATH}" chain_json path
    [ "$EUID" -eq 0 ] || return 0
    [ -f "$disk" ] || return 0
    command -v setfacl >/dev/null 2>&1 || {
        pz_warn "setfacl missing; raw QEMU fallback cannot access libvirt-owned disks"
        return 0
    }
    chain_json="$(qemu-img info --backing-chain --output=json "$disk" 2>/dev/null || true)"
    if [ -n "$chain_json" ] && command -v jq >/dev/null 2>&1; then
        while IFS= read -r path; do
            [ -f "$path" ] || continue
            setfacl -m "u:$TARGET_USER:rw-" "$path"
        done < <(jq -r 'if type == "array" then .[].filename else .filename end // empty' <<< "$chain_json")
    else
        setfacl -m "u:$TARGET_USER:rw-" "$disk"
    fi
    [ -f "$OVMF_VARS" ] && setfacl -m "u:$TARGET_USER:rw-" "$OVMF_VARS"
}

cmd_shares() {
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then
        shift || true
    fi
    parse_options "$@"
    effective_config
    case "$sub" in
        install|repair)
            need_root
            ensure_share_links || return 1
            configure_windows_samba_shares
            optimize_libvirt_domain
            ;;
        remove)
            need_root
            clean_share_binds
            remove_windows_samba_shares
            ;;
        clean)
            clean_share_binds
            pz_info "Windows VM share bind mounts removed"
            return 0
            ;;
        verify)
            cmd_shares_verify
            return $?
            ;;
        dry-run|plan)
            echo "Windows VM shared access plan"
            if [ "$SHARE_POLICY" = "full" ]; then
                # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
                echo "  built-in SMB (SLIRP): \\\\10.0.2.4\\qemu  -> exchange/ home/ sdcard/ (bind-mounted)"
                # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
                echo "  libvirt SMB host: \\\\$(libvirt_gateway)\\PZExchange, PZHome, PZSDCard, PZRemovable, PZMedia, PZMounts"
            else
                # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
                echo "  built-in SMB (SLIRP): \\\\10.0.2.4\\qemu  -> exchange/ (bind-mounted)"
                # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
                echo "  libvirt SMB host: \\\\$(libvirt_gateway)\\PZExchange"
            fi
            echo "  share policy: $SHARE_POLICY (expanded shares writable: $SHARE_WRITABLE)"
            echo "  SPICE WebDAV: $EXCHANGE_DIR (requires spice-webdavd in Windows guest)"
            echo "  bind-mount root: $SHARE_BIND_ROOT"
            echo "  USB auto filter: $USB_AUTO_FILTER"
            echo "  USB permissions: active-seat udev access for external devices"
            return 0
            ;;
        status) ;;
        *)
            pz_error "usage: windows-vm shares (status|install|repair|remove|clean|verify|dry-run)"
            return 1
            ;;
    esac
    # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
    echo "builtin_smb_unc: \\\\10.0.2.4\\qemu ($([ "$SHARE_POLICY" = "full" ] && echo "exchange/ home/ sdcard/" || echo "exchange/"))"
    echo "share_policy: $SHARE_POLICY"
    echo "share_writable: $SHARE_WRITABLE"
    echo "bind_root: $SHARE_BIND_ROOT"
    echo "home_bound: $(mountpoint -q "$SHARE_BIND_ROOT/home" 2>/dev/null && echo yes || echo no)"
    echo "sdcard_bound: $(mountpoint -q "$SHARE_BIND_ROOT/sdcard" 2>/dev/null && echo yes || echo no)"
    echo "samba_managed: $(samba_shares_managed && echo yes || echo no)"
    echo "samba_policy_compliant: $(samba_policy_compliant && echo yes || echo no)"
    echo "samba_reachable: $(samba_shares_reachable && echo yes || echo no)"
    echo "smb_host: $SMB_HOST"
    echo "exchange_dir: $EXCHANGE_DIR"
    echo "webdav_channels: $(libvirt_webdav_channel_count)"
    echo "libvirt_network: $(libvirt_network_state)"
    echo "libvirt_nic_model: $(libvirt_interface_model)"
    echo "share_links: $(share_links_ready && echo yes || echo no)"
    echo "usb_redir_channels: $(libvirt_usb_redir_count)"
    echo "usb_auto_filter: ${USB_AUTO_FILTER:-disabled}"
}

audio_driver() {
    local help
    help="$(qemu-system-x86_64 -audiodev help 2>&1 || true)"
    grep -x 'pipewire' >/dev/null <<< "$help" && { echo pipewire; return 0; }
    grep -x 'pa' >/dev/null <<< "$help" && { echo pa; return 0; }
    echo none
}

QEMU_ARGS=()
CLEANUP_PIDS=()
TPM_PID_FILE=""
VIRTIOFS_COUNT=0

cleanup_runtime() {
    local pid
    for pid in "${CLEANUP_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    if [ -n "${TPM_PID_FILE:-}" ] && [ -f "$TPM_PID_FILE" ]; then
        kill "$(cat "$TPM_PID_FILE" 2>/dev/null)" >/dev/null 2>&1 || true
    fi
}

start_virtiofs_share() {
    local tag="$1" path="$2" daemon sock pid extra=()
    [ -d "$path" ] || return 0
    daemon="$(virtiofsd_path)"
    [ -n "$daemon" ] || return 0
    # expanded shares (home/sdcard/removable/media/mnt) are exposed read-only
    # unless SHARE_WRITABLE=1; exchange is always read-write.
    if [ "$SHARE_POLICY" = "full" ] && [ "$tag" != "exchange" ] && [ "$SHARE_WRITABLE" != "1" ]; then
        extra+=(--readonly)
        pz_info "virtiofs share $tag mounted read-only (policy=full, SHARE_WRITABLE=0)"
    fi
    sock="$RUNTIME_DIR/virtiofs-$tag.sock"
    rm -f "$sock"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would start virtiofsd tag=$tag path=$path socket=$sock ${extra[*]}"
    else
        "$daemon" --shared-dir "$path" --socket-path "$sock" --cache auto --sandbox none --inode-file-handles=never --log-level warn "${extra[@]}" &
        pid=$!
        CLEANUP_PIDS+=("$pid")
        local i
        for ((i = 0; i < 50; i++)); do
            [ -S "$sock" ] && break
            sleep 0.05
        done
        if [ ! -S "$sock" ]; then
            pz_warn "virtiofsd socket did not become ready for $tag; share skipped"
            return 0
        fi
    fi
    QEMU_ARGS+=("-chardev" "socket,id=charfs_$tag,path=$sock")
    QEMU_ARGS+=("-device" "vhost-user-fs-pci,chardev=charfs_$tag,tag=$tag")
    VIRTIOFS_COUNT=$((VIRTIOFS_COUNT + 1))
}

start_tpm() {
    command -v swtpm >/dev/null 2>&1 || return 0
    install -d "$TPM_DIR"
    ensure_runtime_dir "$RUNTIME_DIR"
    local sock="$RUNTIME_DIR/swtpm.sock"
    TPM_PID_FILE="$RUNTIME_DIR/swtpm.pid"
    rm -f "$sock" "$TPM_PID_FILE"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would start swtpm socket: $sock"
    else
        swtpm socket --tpm2 \
            --tpmstate "dir=$TPM_DIR" \
            --ctrl "type=unixio,path=$sock,terminate" \
            --pid "file=$TPM_PID_FILE" \
            --log "file=$STATE_DIR/swtpm.log,level=20" \
            --daemon
        local i
        for ((i = 0; i < 50; i++)); do
            [ -S "$sock" ] && break
            sleep 0.05
        done
    fi
    QEMU_ARGS+=("-chardev" "socket,id=chrtpm,path=$sock")
    QEMU_ARGS+=("-tpmdev" "emulator,id=tpm0,chardev=chrtpm")
    QEMU_ARGS+=("-device" "tpm-tis,tpmdev=tpm0")
}

add_guest_hid_devices() {
    # GTK sends keyboard, pointer and touch events to QEMU. Keep standard USB
    # HID plus virtio multitouch present for every graphics profile; virtio-gl
    # has no SPICE USB channel. Touch must pass through GTK/Gamescope so the
    # Deck panel's native 800x1280 axes receive the active output rotation.
    QEMU_ARGS+=("-device" "qemu-xhci,id=xhci,p2=8,p3=8")
    QEMU_ARGS+=("-device" "usb-kbd,bus=xhci.0")
    QEMU_ARGS+=("-device" "usb-tablet,bus=xhci.0")
    QEMU_ARGS+=("-device" "virtio-multitouch-pci,id=pz-touchscreen")
}

add_spice_usb_redirection() {
    local idx
    case "$USB_MODE" in
        redir|peripherals|all)
            for idx in 0 1 2 3; do
                QEMU_ARGS+=("-chardev" "spicevmc,id=usbredir$idx,name=usbredir")
                QEMU_ARGS+=("-device" "usb-redir,chardev=usbredir$idx,id=usbredir$idx")
            done
            ;;
    esac
}

# Direct GRUB boot runs a local QEMU GTK display, outside the normal Steam
# Input/Gamescope session. Map the Deck composite devices through virtio-input
# so Windows receives the physical controls without passing USB storage or
# unrelated host devices to the guest. The directories are overridable only to
# keep the shell tests hermetic; production defaults stay under /dev/input.
first_readable_input_path() {
    local candidate
    for candidate in "$@"; do
        [ -n "$candidate" ] && [ -r "$candidate" ] && {
            printf '%s\n' "$candidate"
            return 0
        }
    done
    return 1
}

host_input_passthrough_enabled() {
    case "${PZ_WINDOWS_VM_HOST_INPUT:-auto}" in
        auto|"") [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ] ;;
        1|on|yes|true) return 0 ;;
        0|off|no|false) return 1 ;;
        *)
            pz_warn "invalid PZ_WINDOWS_VM_HOST_INPUT '${PZ_WINDOWS_VM_HOST_INPUT}'; using auto"
            [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ]
            ;;
    esac
}

add_host_input_device() {
    local id="$1" path="$2"
    [ -n "$path" ] || return 0
    QEMU_ARGS+=("-device" "virtio-input-host-pci,id=$id,evdev=$path")
}

# virtio-input carries every physical control (the joystick node exposes the
# back paddles, BTN_MODE for STEAM and the trackpads as hats), but the guest
# driver presents it as a generic HID gamepad. Steam Deck Tools and Steam Input
# talk to the native Valve HID device instead, so they see nothing under
# virtio-input. Raw usb-host passthrough hands the real 28de:1205 to Windows at
# the cost of detaching it from the host for the whole session - acceptable
# only on a direct GRUB boot, where Windows *is* the session and there is no
# host UI left to drive.
STEAMDECK_RAW_CONTROLLER_PATH=""
STEAMDECK_CONTROLLER_VENDOR="28de"
STEAMDECK_CONTROLLER_PRODUCT="1205"

usb_sysfs_dir() {
    printf '%s\n' "${PZ_WINDOWS_VM_USB_SYSFS_DIR:-/sys/bus/usb/devices}"
}

steamdeck_controller_sysfs_path() {
    local dev
    for dev in "$(usb_sysfs_dir)"/*; do
        if [ ! -f "$dev/idVendor" ] || [ ! -f "$dev/idProduct" ]; then
            continue
        fi
        [ "$(cat "$dev/idVendor" 2>/dev/null || true)" = "$STEAMDECK_CONTROLLER_VENDOR" ] || continue
        [ "$(cat "$dev/idProduct" 2>/dev/null || true)" = "$STEAMDECK_CONTROLLER_PRODUCT" ] || continue
        printf '%s\n' "$dev"
        return 0
    done
    return 1
}

steamdeck_controller_mode() {
    local requested="${PZ_WINDOWS_VM_STEAMDECK_CONTROLLER:-auto}"
    case "$requested" in
        raw|virtio|off) printf '%s\n' "$requested" ;;
        auto|"")
            if [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ]; then
                printf 'raw\n'
            else
                printf 'virtio\n'
            fi
            ;;
        *)
            pz_warn "invalid PZ_WINDOWS_VM_STEAMDECK_CONTROLLER '$requested'; using virtio"
            printf 'virtio\n'
            ;;
    esac
}

add_steamdeck_raw_controller() {
    local dev bus addr
    dev="$(steamdeck_controller_sysfs_path)" || return 1
    bus="$(cat "$dev/busnum" 2>/dev/null || true)"
    addr="$(cat "$dev/devnum" 2>/dev/null || true)"
    [ -n "$bus" ] && [ -n "$addr" ] || return 1
    QEMU_ARGS+=("-device" "usb-host,bus=xhci.0,hostbus=$((10#$bus)),hostaddr=$((10#$addr)),id=pz-steamdeck-controller")
    STEAMDECK_RAW_CONTROLLER_PATH="$dev"
    return 0
}

add_steamdeck_inputs() {
    [ "$GRAPHICS_PROFILE" = "virtio-gl" ] || return 0
    host_input_passthrough_enabled || return 0

    case "$(steamdeck_controller_mode)" in
        off) return 0 ;;
        raw)
            if add_steamdeck_raw_controller; then
                pz_info "steamdeck controller: raw usb-host passthrough; the host loses the controller until the VM exits" >&2
                return 0
            fi
            pz_warn "steamdeck controller ${STEAMDECK_CONTROLLER_VENDOR}:${STEAMDECK_CONTROLLER_PRODUCT} not found on USB; falling back to virtio-input"
            ;;
    esac
    add_steamdeck_host_inputs
}

add_steamdeck_host_inputs() {
    local by_id_dir="${PZ_WINDOWS_VM_INPUT_BY_ID_DIR:-/dev/input/by-id}"
    local keyboard mouse gamepad
    keyboard="$(first_readable_input_path "$by_id_dir"/usb-Valve_Software_Steam_Deck_Controller_*-event-kbd || true)"
    mouse="$(first_readable_input_path "$by_id_dir"/usb-Valve_Software_Steam_Deck_Controller_*-event-mouse || true)"
    gamepad="$(first_readable_input_path "$by_id_dir"/usb-Valve_Software_Steam_Deck_Controller_*-event-joystick || true)"

    add_host_input_device "pz-steamdeck-keyboard" "$keyboard"
    add_host_input_device "pz-steamdeck-mouse" "$mouse"
    add_host_input_device "pz-steamdeck-gamepad" "$gamepad"
}

add_raw_usb_devices() {
    local mode="$1" dev vendor product bus addr class
    [ "$mode" = "all" ] || [ "$mode" = "peripherals" ] || return 0
    for dev in "$(usb_sysfs_dir)"/*; do
        # The controller may already be attached by name above; a second
        # usb-host for the same hostbus/hostaddr makes QEMU refuse to start.
        if [ -n "${STEAMDECK_RAW_CONTROLLER_PATH:-}" ] && [ "$dev" = "$STEAMDECK_RAW_CONTROLLER_PATH" ]; then
            continue
        fi
        if [ ! -f "$dev/idVendor" ] || [ ! -f "$dev/idProduct" ]; then
            continue
        fi
        vendor="$(cat "$dev/idVendor" 2>/dev/null || true)"
        product="$(cat "$dev/idProduct" 2>/dev/null || true)"
        bus="$(cat "$dev/busnum" 2>/dev/null || true)"
        addr="$(cat "$dev/devnum" 2>/dev/null || true)"
        class="$(cat "$dev/bDeviceClass" 2>/dev/null || true)"
        [ "$class" = "09" ] && continue
        if [ "$mode" = "peripherals" ] && [ "$class" = "08" ]; then
            continue
        fi
        if [ -z "$vendor" ] || [ -z "$product" ] || [ -z "$bus" ] || [ -z "$addr" ]; then
            continue
        fi
        QEMU_ARGS+=("-device" "usb-host,hostbus=$((10#$bus)),hostaddr=$((10#$addr))")
    done
}

add_pci_devices() {
    local dev
    for dev in $PCI_DEVICES; do
        [[ "$dev" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
            pz_warn "invalid PCI id skipped: $dev"
            continue
        }
        QEMU_ARGS+=("-device" "vfio-pci,host=$dev")
    done
}

build_qemu_args() {
    local audio netdev accel_cpu accel_machine display_geometry=""
    QEMU_ARGS=()
    STEAMDECK_RAW_CONTROLLER_PATH=""
    VIRTIOFS_COUNT=0
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would prepare runtime dir: $RUNTIME_DIR"
    else
        # QGA and QMP allow guest execution/power control. Their Unix sockets
        # must never be reachable by another local account.
        ensure_runtime_dir "$RUNTIME_DIR"
        install -d -m 0700 "$STATE_DIR"
    fi
    ensure_share_links || return 1
    start_virtiofs_share exchange "$EXCHANGE_DIR"
    if [ "$SHARE_POLICY" = "full" ]; then
        start_virtiofs_share hosthome "$HOME"
        [ -d /mnt/sdcard ] && start_virtiofs_share sdcard /mnt/sdcard
        [ -d "$REMOVABLE_ROOT/$TARGET_USER" ] && start_virtiofs_share removable "$REMOVABLE_ROOT/$TARGET_USER"
        [ -d "$MEDIA_ROOT/$TARGET_USER" ] && start_virtiofs_share media "$MEDIA_ROOT/$TARGET_USER"
        [ -d /mnt ] && start_virtiofs_share mnt /mnt
    fi
    start_tpm

    QEMU_ARGS+=("-name" "$VM_NAME")
    if [ -e /dev/kvm ]; then
        accel_machine="q35,accel=kvm,kernel_irqchip=split"
        accel_cpu="host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time,hv_vpindex,hv_runtime,hv_synic,hv_stimer,hv_reset,hv_frequencies"
        QEMU_ARGS+=("-enable-kvm")
    else
        accel_machine="q35,accel=tcg"
        accel_cpu="max"
    fi
    QEMU_ARGS+=("-machine" "$accel_machine")
    QEMU_ARGS+=("-cpu" "$accel_cpu")
    QEMU_ARGS+=("-smp" "$CPUS,sockets=1,cores=$CPUS,threads=1")
    QEMU_ARGS+=("-m" "${RAM_MB}M")
    if [ "$VIRTIOFS_COUNT" -gt 0 ]; then
        QEMU_ARGS+=("-object" "memory-backend-memfd,id=mem,size=${RAM_MB}M,share=on")
        QEMU_ARGS+=("-numa" "node,memdev=mem")
    fi
    QEMU_ARGS+=("-drive" "if=pflash,format=raw,readonly=on,file=$OVMF_CODE")
    QEMU_ARGS+=("-drive" "if=pflash,format=raw,file=$OVMF_VARS")
    QEMU_ARGS+=("-drive" "if=none,id=system,file=$DISK_PATH,format=$(disk_format "$DISK_PATH"),cache=none,discard=unmap,aio=io_uring")
    case "$RAW_DISK_BUS" in
        sata|ide) QEMU_ARGS+=("-device" "ide-hd,drive=system,bus=ide.0,bootindex=1") ;;
        # The serial is the token the unattended install compares before it
        # wipes anything, so both bus types must expose the same one. virtio-blk
        # shipped with no serial at all, which left the guard nothing to match.
        virtio) QEMU_ARGS+=("-device" "virtio-blk-pci,drive=system,serial=$DISK_SERIAL,bootindex=1") ;;
        *) QEMU_ARGS+=("-device" "nvme,drive=system,serial=$DISK_SERIAL,bootindex=1") ;;
    esac
    if [ -n "$PCI_DEVICES" ]; then
        QEMU_ARGS+=("-device" "intel-iommu,intremap=on,caching-mode=on")
    fi
    if [ "$ISO_EXPLICIT" = "1" ] && [ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ]; then
        QEMU_ARGS+=("-cdrom" "$ISO_PATH")
        QEMU_ARGS+=("-boot" "order=d,menu=on")
    else
        QEMU_ARGS+=("-boot" "menu=on")
    fi
    if [ -n "$VIRTIO_ISO" ] && [ -f "$VIRTIO_ISO" ]; then
        QEMU_ARGS+=("-drive" "file=$VIRTIO_ISO,media=cdrom,readonly=on,index=3")
    fi
    if [ -n "$DISPLAY_WIDTH" ] && [ -n "$DISPLAY_HEIGHT" ]; then
        display_geometry=",xres=$DISPLAY_WIDTH,yres=$DISPLAY_HEIGHT"
    fi
    if [ "$GRAPHICS_PROFILE" = "virtio-gl" ]; then
        QEMU_ARGS+=("-device" "virtio-vga-gl$display_geometry")
    else
        QEMU_ARGS+=("-device" "virtio-vga$display_geometry")
    fi
    QEMU_ARGS+=("-device" "virtio-rng-pci")
    QEMU_ARGS+=("-device" "virtio-balloon-pci")
    add_guest_hid_devices
    if [ "$GRAPHICS_PROFILE" != "virtio-gl" ]; then
        add_spice_usb_redirection
    else
        add_steamdeck_inputs
    fi
    add_raw_usb_devices "$USB_MODE"
    audio="$(audio_driver)"
    if [ "$audio" != "none" ]; then
        QEMU_ARGS+=("-audiodev" "$audio,id=audio0")
        QEMU_ARGS+=("-device" "ich9-intel-hda")
        QEMU_ARGS+=("-device" "hda-duplex,audiodev=audio0")
    fi
    netdev="user,id=net0,hostname=pz-winvm,hostfwd=tcp:127.0.0.1:33890-:3389,hostfwd=tcp:127.0.0.1:59850-:5985"
    if command -v smbd >/dev/null 2>&1; then
        netdev="$netdev,smb=${EFFECTIVE_SMB_DIR:-$SHARE_ROOT}"
    fi
    QEMU_ARGS+=("-netdev" "$netdev")
    QEMU_ARGS+=("-device" "$NET_MODEL,netdev=net0,mac=52:54:00:50:5a:00")
    QEMU_ARGS+=("-device" "virtio-serial-pci,id=virtio-serial0")
    if [ "$DRY_RUN" != "1" ]; then
        rm -f "$RUNTIME_DIR/qga.sock" "$RUNTIME_DIR/qmp.sock"
    fi
    QEMU_ARGS+=("-chardev" "socket,path=$RUNTIME_DIR/qga.sock,server=on,wait=off,id=qga0")
    QEMU_ARGS+=("-qmp" "unix:$RUNTIME_DIR/qmp.sock,server=on,wait=off")
    QEMU_ARGS+=("-device" "virtserialport,bus=virtio-serial0.0,nr=1,chardev=qga0,name=org.qemu.guest_agent.0")
    if [ "$GRAPHICS_PROFILE" != "virtio-gl" ]; then
        QEMU_ARGS+=("-spice" "port=5930,addr=$SPICE_ADDR,disable-ticketing=on")
        QEMU_ARGS+=("-chardev" "spicevmc,id=vdagent,name=vdagent")
        QEMU_ARGS+=("-device" "virtserialport,bus=virtio-serial0.0,nr=2,chardev=vdagent,name=com.redhat.spice.0")
    else
        pz_info "virtio-gl uses local GTK display; SPICE redirection disabled; standard USB HID enabled"
    fi
    if [ "$DISPLAY_MODE" = "none" ]; then
        QEMU_ARGS+=("-display" "none")
    elif [ "$GRAPHICS_PROFILE" = "virtio-gl" ]; then
        # window-close=off (probed against the installed QEMU; -no-quit was
        # removed and confirm-quit never existed): closing the window must
        # never terminate a live guest.
        QEMU_ARGS+=("-display" "gtk,gl=on,show-cursor=on,zoom-to-fit=on,window-close=off")
        [ "$FULLSCREEN" = "1" ] && QEMU_ARGS+=("-full-screen")
    else
        QEMU_ARGS+=("-display" "gtk,show-cursor=on,zoom-to-fit=on,window-close=off")
        [ "$FULLSCREEN" = "1" ] && QEMU_ARGS+=("-full-screen")
    fi
    add_pci_devices
    if [ -n "$EXTRA_ARGS" ]; then
        # Intentional shell split for expert-only extra QEMU args.
        # shellcheck disable=SC2206
        local extra=( $EXTRA_ARGS )
        QEMU_ARGS+=("${extra[@]}")
    fi
}

# Existing guests do not rerun provision setup after an upgrade. Apply the
# touch-keyboard policy through QGA once Windows is ready, without delaying the
# compositor or exposing helper output over the fullscreen guest display.
start_guest_touch_input_setup() {
    [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ] || return 0
    [ "$DRY_RUN" != "1" ] || return 0
    local helper timeout log pid
    helper="${PZ_WINDOWS_VM_GUEST_LOGIN_HELPER:-$PZ_ROOT/linux/windows-vm/guest-login.sh}"
    [ -x "$helper" ] || {
        pz_warn "touch-input helper unavailable: $helper"
        return 0
    }
    # 180s was shorter than a cold Windows 11 boot on handheld hardware: the
    # guest reached the desktop long after the waiter had already given up, so
    # the touch keyboard - the only way to type when QEMU attaches a USB
    # keyboard - was never enabled. The guest side checks out (vioser.inf
    # installed, qemu-ga Start=2, DelayedAutoStart=0, --retry-path), so the
    # window, not the guest, was wrong.
    timeout="${PZ_WINDOWS_VM_TOUCH_INPUT_TIMEOUT_SECONDS:-420}"
    [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -ge 10 ] && [ "$timeout" -le 900 ] || timeout=420
    log="$STATE_DIR/touch-input.log"
    # Replace the previous boot's result before returning to the launcher.
    # Short sessions otherwise keep an old timeout/success indefinitely.
    printf '{"success":false,"state":"pending","action":"touch-input","startedAt":"%s","timeoutSeconds":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$timeout" >"${log}.tmp.$$"
    mv -f "${log}.tmp.$$" "$log"
    (
        local deadline attempt_log started attempts=0 remaining last_failure=socket-unavailable
        started="$SECONDS"
        deadline=$((SECONDS + timeout))
        attempt_log="${log}.tmp.$$"
        trap '
            printf "{\"success\":false,\"state\":\"interrupted\",\"action\":\"touch-input\",\"waitedSeconds\":%s,\"attempts\":%s}\n" \
                "$((SECONDS - started))" "$attempts" >"$attempt_log"
            mv -f "$attempt_log" "$log"
        ' EXIT
        trap 'exit 0' HUP INT TERM
        while [ "$SECONDS" -lt "$deadline" ]; do
            attempts=$((attempts + 1))
            remaining=$((deadline - SECONDS))
            [ "$remaining" -gt 0 ] || break
            if [ -S "$RUNTIME_DIR/qga.sock" ]; then
                last_failure=guest-policy-unavailable
                if timeout --kill-after=2s "${remaining}s" \
                    "$helper" touch-input --socket "$RUNTIME_DIR/qga.sock" --user "$GUEST_USER" --json \
                    >"$attempt_log" 2>&1; then
                    mv -f "$attempt_log" "$log"
                    trap - EXIT
                    exit 0
                fi
            fi
            [ "$SECONDS" -ge "$deadline" ] || sleep 2
        done
        # Record how long we actually waited. The previous payload said only
        # "timeout", which left no way to tell a window that is too short from
        # a guest that never answers.
        printf '{"success":false,"state":"timeout","action":"touch-input","waitedSeconds":%s,"attempts":%s,"lastFailure":"%s"}\n' \
            "$((SECONDS - started))" "$attempts" "$last_failure" >"$attempt_log"
        mv -f "$attempt_log" "$log"
        trap - EXIT
    ) &
    pid=$!
    CLEANUP_PIDS+=("$pid")
}

launch_libvirt_domain() {
    local uri state display viewer_args=()
    uri="$(libvirt_uri)"
    type -P virsh >/dev/null 2>&1 || {
        pz_error "virsh missing for discovered domain: $LIBVIRT_DOMAIN"
        return 1
    }
    if [ "$DRY_RUN" = "1" ]; then
        echo "virsh -c $uri start $LIBVIRT_DOMAIN"
        if [ "$DISPLAY_MODE" != "none" ]; then
            echo "virt-viewer/spicy fullscreen domain=$LIBVIRT_DOMAIN"
        fi
        return 0
    fi
    ensure_share_links || return 1
    state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    if [ "$state" != "running" ]; then
        if ! virsh -c "$uri" start "$LIBVIRT_DOMAIN"; then
            # "start" fails when the domain is already active; re-check before
            # declaring failure so we still attach the viewer to a live VM.
            state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ "$state" = "running" ] || {
                pz_error "failed to start libvirt domain: $LIBVIRT_DOMAIN"
                return 1
            }
        fi
        local wait_attempt
        for ((wait_attempt = 0; wait_attempt < 30; wait_attempt++)); do
            state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ "$state" = "running" ] && break
            sleep 1
        done
        [ "$state" = "running" ] || {
            pz_error "libvirt domain did not reach running state: $LIBVIRT_DOMAIN ($state)"
            return 1
        }
    fi
    if [ "$DISPLAY_MODE" = "none" ]; then
        pz_info "Windows libvirt domain running headless: $LIBVIRT_DOMAIN"
        return 0
    fi
    if command -v spicy >/dev/null 2>&1; then
        local attempt
        for ((attempt = 0; attempt < 100; attempt++)); do
            display="$(virsh -c "$uri" domdisplay "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
            [ -n "$display" ] && break
            sleep 0.1
        done
        [ -n "${display:-}" ] || {
            pz_error "SPICE display unavailable for domain: $LIBVIRT_DOMAIN"
            return 1
        }
        if [ -n "$USB_AUTO_FILTER" ] && [ "$USB_MODE" != "none" ]; then
            viewer_args+=("--spice-usbredir-auto-redirect-filter=$USB_AUTO_FILTER")
            viewer_args+=("--spice-usbredir-redirect-on-connect=$USB_AUTO_FILTER")
        fi
        [ "$FULLSCREEN" = "1" ] && viewer_args+=(-f)
        exec spicy --uri "$display" --spice-shared-dir="$SHARE_ROOT" --spice-smartcard "${viewer_args[@]}"
    fi
    if command -v virt-viewer >/dev/null 2>&1; then
        [ "$FULLSCREEN" = "1" ] && viewer_args+=(--full-screen)
        exec virt-viewer --connect "$uri" --wait --reconnect "${viewer_args[@]}" "$LIBVIRT_DOMAIN"
    fi
    pz_error "install virt-viewer or spice-gtk to display domain: $LIBVIRT_DOMAIN"
    return 1
}

attach_libvirt_device_config() {
    local domain="$1" xml="$2" tmp
    tmp="$(mktemp)"
    printf '%s\n' "$xml" > "$tmp"
    if ! virsh -c "$(libvirt_uri)" attach-device "$domain" "$tmp" --config >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

optimize_libvirt_domain() {
    [ -n "$LIBVIRT_DOMAIN" ] || return 0
    type -P virsh >/dev/null 2>&1 || return 0
    local uri state xml redir_count cdrom_target
    uri="$(libvirt_uri)"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would tune libvirt domain=$LIBVIRT_DOMAIN ram=${RAM_MB}M cpus=$CPUS"
        pz_info "dry-run: would eject install ISO and ensure four SPICE USB channels, WebDAV plus smartcard"
        return 0
    fi
    grant_raw_qemu_disk_access "$DISK_PATH"
    state="$(virsh -c "$uri" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    if [ "$state" = "running" ]; then
        pz_warn "domain running; persistent libvirt tuning deferred"
        return 0
    fi
    virsh -c "$uri" setmaxmem "$LIBVIRT_DOMAIN" "${RAM_MB}M" --config >/dev/null || true
    virsh -c "$uri" setmem "$LIBVIRT_DOMAIN" "${RAM_MB}M" --config >/dev/null || true
    virsh -c "$uri" setvcpus "$LIBVIRT_DOMAIN" "$CPUS" --maximum --config >/dev/null || true
    virsh -c "$uri" setvcpus "$LIBVIRT_DOMAIN" "$CPUS" --config >/dev/null || true
    cdrom_target="$(virsh -c "$uri" domblklist "$LIBVIRT_DOMAIN" --details 2>/dev/null | awk '$2 == "cdrom" && $4 != "-" && !seen++ {print $3}')"
    if [ -n "$cdrom_target" ]; then
        virsh -c "$uri" change-media "$LIBVIRT_DOMAIN" "$cdrom_target" --eject --config >/dev/null || true
    fi
    xml="$(virsh -c "$uri" dumpxml "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
    redir_count="$(grep -c "<redirdev " <<< "$xml" || true)"
    while [ "$redir_count" -lt 4 ]; do
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" "<redirdev bus='usb' type='spicevmc'/>" || break
        redir_count=$((redir_count + 1))
    done
    if ! grep "<smartcard " >/dev/null <<< "$xml"; then
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" "<smartcard mode='host'/>" ||
            pz_warn "libvirt smartcard passthrough unavailable; SPICE client support remains enabled"
    fi
    if ! grep "org.spice-space.webdav.0" >/dev/null <<< "$xml"; then
        attach_libvirt_device_config "$LIBVIRT_DOMAIN" \
            "<channel type='spiceport'><source channel='org.spice-space.webdav.0'/><target type='virtio' name='org.spice-space.webdav.0'/></channel>" ||
            pz_warn "SPICE WebDAV channel unavailable; Samba exchange remains active"
    fi
    pz_info "libvirt domain tuned: $LIBVIRT_DOMAIN ram=${RAM_MB}M cpus=$CPUS usbredir=$redir_count webdav=$(libvirt_webdav_channel_count)"
}

# v1 graphics contract: compat is the only profile allowed everywhere.
# virtio-gl is raw-QEMU-only and experimental; venus/rutabaga/VFIO are
# plan-only (see linux/windows-vm/graphics.sh). Never mutates a domain.
guard_graphics_profile() {
    case "$GRAPHICS_PROFILE" in
        compat|"")
            GRAPHICS_PROFILE=compat
            return 0
            ;;
        virtio-gl)
            if [ -n "$LIBVIRT_DOMAIN" ] && [ "$RAW_QEMU" != "1" ]; then
                if [ "$EXPLICIT_GRAPHICS" != "1" ]; then
                    pz_warn "perfil configurado virtio-gl requer QEMU direto; dominio libvirt $LIBVIRT_DOMAIN usara compat QXL/SPICE"
                    GRAPHICS_PROFILE=compat
                    return 0
                fi
                pz_error "graphics virtio-gl exige --raw-qemu na v1; dominio libvirt permanece QXL/SPICE"
                return 1
            fi
            if [ "$EXPLICIT_GRAPHICS" = "1" ] && [ "$GRAPHICS_EXPERIMENTAL" != "1" ]; then
                pz_error "graphics virtio-gl e experimental; adicione --experimental"
                return 1
            fi
            local blockers=()
            local gfx_kvm_path="${PZ_GFX_KVM_PATH:-/dev/kvm}"
            local gfx_dri_dir="${PZ_GFX_DRI_DIR:-/dev/dri}"
            local gfx_qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
            local -a render_nodes=("$gfx_dri_dir"/renderD*)
            [ -r "$gfx_kvm_path" ] && [ -w "$gfx_kvm_path" ] || blockers+=("KVM sem acesso read/write: $gfx_kvm_path")
            if [ ! -e "${render_nodes[0]}" ]; then
                blockers+=("render node ausente em $gfx_dri_dir")
            elif [ ! -r "${render_nodes[0]}" ] || [ ! -w "${render_nodes[0]}" ]; then
                blockers+=("render node sem acesso read/write: ${render_nodes[0]}")
            fi
            if ! command -v "$gfx_qemu_bin" >/dev/null 2>&1; then
                blockers+=("QEMU ausente: $gfx_qemu_bin")
            elif ! "$gfx_qemu_bin" -device help 2>/dev/null | grep 'virtio-vga-gl' >/dev/null; then
                blockers+=("QEMU sem device virtio-vga-gl")
            elif ! "$gfx_qemu_bin" -display help 2>/dev/null | grep -w gtk >/dev/null; then
                blockers+=("QEMU sem display GTK necessario para gtk,gl=on")
            fi
            if [ "${#blockers[@]}" -gt 0 ]; then
                local blocker
                if [ "$DRY_RUN" = "1" ]; then
                    for blocker in "${blockers[@]}"; do
                        pz_warn "virtio-gl blocker (dry-run continua): $blocker"
                    done
                else
                    pz_error "graphics virtio-gl bloqueado neste host:"
                    for blocker in "${blockers[@]}"; do
                        pz_error "  - $blocker"
                    done
                    pz_error "fallback: linux/pz windows-vm launch --graphics compat"
                    return 1
                fi
            fi
            return 0
            ;;
        virtio-venus|rutabaga)
            pz_error "graphics $GRAPHICS_PROFILE bloqueado para Windows na v1 (driver guest nao validado). Veja: linux/pz windows-vm graphics plan --profile $GRAPHICS_PROFILE"
            return 1
            ;;
        vfio-looking-glass)
            pz_error "graphics vfio-looking-glass e plan-only na v1 (sem bind VFIO nem GRUB). Veja: linux/pz windows-vm graphics plan --profile vfio-looking-glass"
            return 1
            ;;
        *)
            pz_error "unknown graphics profile: $GRAPHICS_PROFILE (auto|compat|virtio-gl|virtio-venus|rutabaga|vfio-looking-glass)"
            return 1
            ;;
    esac
}

launch_vm() {
    parse_options "$@"
    [ "${PZ_WINDOWS_VM_FULLSCREEN:-0}" = "1" ] && FULLSCREEN=1
    effective_config
    resolve_display_geometry
    local RESCUE_SOURCED=0
    RESCUE_SOURCED=0
    guard_graphics_profile || return 1
    trap cleanup_runtime EXIT INT TERM
    apply_host_optimizations
    if [ -n "$LIBVIRT_DOMAIN" ] && [ "$RAW_QEMU" != "1" ]; then
        if launch_libvirt_domain; then
            return 0
        fi
        local fallback_state
        fallback_state="$(virsh -c "$(libvirt_uri)" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
        case "$fallback_state" in
            running|paused|"pmsuspended")
                # Domain holds the disk write lock; direct QEMU would just
                # loop on lock errors. Let the caller retry the viewer.
                pz_error "libvirt domain is $fallback_state; not falling back to direct QEMU: $LIBVIRT_DOMAIN"
                return 1
                ;;
        esac
        pz_warn "libvirt domain start failed; falling back to direct QEMU/KVM"
        LIBVIRT_DOMAIN=""
        RAW_QEMU=1
    fi
    [ -n "$OVMF_CODE" ] || { pz_error "OVMF code firmware missing. Install edk2-ovmf."; return 1; }
    [ -f "$DISK_PATH" ] || {
        if [ "$RESCUE_SOURCED" = "0" ] && [ -f "$PZ_ROOT/linux/windows-vm/rescue.sh" ]; then
            source "$PZ_ROOT/linux/windows-vm/rescue.sh"
            RESCUE_SOURCED=1
        fi
        if [ "${PZ_WINDOWS_VM_RESCUE:-1}" != "0" ] && [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ] && type vm_rescue_run >/dev/null 2>&1; then
            if vm_rescue_run; then
                effective_config
                [ -f "$DISK_PATH" ] || { pz_error "VM disk still missing after rescue"; return 1; }
            else
                pz_error "VM disk missing: $DISK_PATH. Run: $PZ_ROOT/linux/pz windows-vm install --iso <windows.iso>"
                return 1
            fi
        else
            pz_error "VM disk missing: $DISK_PATH. Run: $PZ_ROOT/linux/pz windows-vm install --iso <windows.iso>"
            return 1
        fi
    }
    [ -f "$OVMF_VARS" ] || { pz_error "OVMF vars missing: $OVMF_VARS. Run install again."; return 1; }
    command -v qemu-system-x86_64 >/dev/null 2>&1 || { pz_error "qemu-system-x86_64 missing"; return 1; }
    build_qemu_args
    if [ "$DRY_RUN" = "1" ]; then
        shell_join qemu-system-x86_64 "${QEMU_ARGS[@]}"
        return 0
    fi
    start_guest_touch_input_setup
    pz_info "Windows VM shares: \\\\10.0.2.4\\qemu (policy=$SHARE_POLICY)"
    if [ "$GRAPHICS_PROFILE" = "virtio-gl" ]; then
        pz_info "Display: local GTK with virtio-gl acceleration (SPICE USB redirection disabled)"
    else
        pz_info "SPICE USB redirection: spice://$SPICE_ADDR:5930"
    fi
    local qemu_rc=0
    set +e
    if command -v ionice >/dev/null 2>&1; then
        ionice -c 2 -n 0 qemu-system-x86_64 "${QEMU_ARGS[@]}"
        qemu_rc=$?
    else
        qemu-system-x86_64 "${QEMU_ARGS[@]}"
        qemu_rc=$?
    fi
    set -e
    cleanup_runtime
    trap - EXIT INT TERM
    return "$qemu_rc"
}

# Repairs modes on a VM that already exists. install/adopt harden storage as
# they create it, but a VM adopted before this existed still carries whatever
# mode its creator used, and that is a readable Windows disk for every local
# account on the machine.
secure_storage() {
    parse_options "$@"
    effective_config
    harden_vm_storage_modes
    local vm_mode="" disk_mode="" ovmf_mode="" tpm_mode=""
    [ -d "$VM_DIR" ] && vm_mode="$(stat -c %a "$VM_DIR" 2>/dev/null || true)"
    [ -f "$DISK_PATH" ] && disk_mode="$(stat -c %a "$DISK_PATH" 2>/dev/null || true)"
    [ -f "$OVMF_VARS" ] && ovmf_mode="$(stat -c %a "$OVMF_VARS" 2>/dev/null || true)"
    [ -d "$TPM_DIR" ] && tpm_mode="$(stat -c %a "$TPM_DIR" 2>/dev/null || true)"
    local secure=true
    [ "$vm_mode" = "700" ] || [ -z "$vm_mode" ] || secure=false
    [ "$disk_mode" = "600" ] || [ -z "$disk_mode" ] || secure=false
    [ "$ovmf_mode" = "600" ] || [ -z "$ovmf_mode" ] || secure=false
    [ "$tpm_mode" = "700" ] || [ -z "$tpm_mode" ] || secure=false
    if [ "$JSON_OUT" = "1" ]; then
        jq -n --arg vmDir "$VM_DIR" --arg vmDirMode "$vm_mode" --arg diskMode "$disk_mode" \
            --arg ovmfVarsMode "$ovmf_mode" --arg tpmDirMode "$tpm_mode" \
            --argjson secure "$secure" \
            '{success:$secure,vmDir:$vmDir,vmDirMode:$vmDirMode,diskMode:$diskMode,
              ovmfVarsMode:$ovmfVarsMode,tpmDirMode:$tpmDirMode,storageModesSecure:$secure}'
    elif [ "$secure" = true ]; then
        pz_info "VM storage restricted to the owning user ($VM_DIR)"
    else
        pz_error "VM storage modes could not be fully restricted: $VM_DIR"
    fi
    [ "$secure" = true ]
}

# Image integrity after a controlled shutdown. Refuses while the VM still holds
# the disk, because qemu-img check on a live image reports nothing meaningful.
disk_check() {
    parse_options "$@"
    effective_config
    local output rc=0
    if [ ! -f "$DISK_PATH" ]; then
        pz_error "guest disk missing: $DISK_PATH"
        return 1
    fi
    if disk_in_use; then
        pz_error "disk-check requires the VM powered off"
        return 1
    fi
    set +e
    output="$(qemu-img check "$DISK_PATH" 2>&1)"
    rc=$?
    set -e
    if [ "$JSON_OUT" = "1" ]; then
        jq -n --arg disk "$DISK_PATH" --arg detail "$output" \
            --argjson ok "$([ "$rc" -eq 0 ] && echo true || echo false)" \
            '{success:$ok,disk:$disk,detail:$detail}'
    elif [ "$rc" -eq 0 ]; then
        pz_info "qemu-img check passed: $DISK_PATH"
    else
        pz_error "qemu-img check failed: $DISK_PATH"
        printf '%s\n' "$output" >&2
    fi
    return "$rc"
}

disk_in_use() {
    local proc cmd disk_real
    disk_real="$(realpath -e "$DISK_PATH" 2>/dev/null || printf '%s' "$DISK_PATH")"
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        cmd="$(tr '\0' ' ' < "$proc" 2>/dev/null || true)"
        if [[ "$cmd" == *qemu-system* || "$cmd" == *qemu-kvm* ]] && \
            { [[ "$cmd" == *"$DISK_PATH"* ]] || [[ "$cmd" == *"$disk_real"* ]]; }; then
            return 0
        fi
    done
    return 1
}

provision_removal_blocker() {
    local active_lock="$PZ_STATE/windows-vm/provision/active.lock"
    local operation_id="" operation_file="" operation_state=""
    [ -e "$active_lock" ] || return 1
    if [ ! -f "$active_lock" ] || [ -L "$active_lock" ]; then
        printf 'estado do provisionamento é inconsistente; repare ou descarte a operação antes de remover a VM'
        return 0
    fi
    IFS= read -r operation_id < "$active_lock" || true
    # provision_lock_clear truncates in place and never unlinks: an empty lock
    # is the idle state, not corruption.
    [ -n "$operation_id" ] || return 1
    case "$operation_id" in
        .|..|*[!A-Za-z0-9._-]*)
            printf 'estado do provisionamento é inconsistente; repare ou descarte a operação antes de remover a VM'
            return 0
            ;;
    esac
    operation_file="$PZ_STATE/operations/$operation_id/operation.json"
    if [ ! -f "$operation_file" ] || [ -L "$operation_file" ]; then
        printf 'estado do provisionamento é inconsistente; repare ou descarte a operação antes de remover a VM'
        return 0
    fi
    operation_state="$(jq -r 'if type == "object" then .state // empty else empty end' "$operation_file" 2>/dev/null || true)"
    case "$operation_state" in
        running)
            printf 'instalação Windows em andamento (%s); cancele ou aguarde antes de remover a VM' "$operation_id"
            return 0
            ;;
        completed|failed|cancelled) return 1 ;;
        *)
            printf 'estado do provisionamento é inconsistente; repare ou descarte a operação antes de remover a VM'
            return 0
            ;;
    esac
}

launch_check() {
    parse_options "$@"
    effective_config
    local -a blockers=()
    local kvm=false disk=false ovmf=false vars=false qemu=false graphics=false
    local kvm_path="${PZ_WINDOWS_VM_KVM_PATH:-/dev/kvm}"

    [ -r "$kvm_path" ] && [ -w "$kvm_path" ] && kvm=true || blockers+=("KVM sem acesso read/write: $kvm_path")
    [ -f "$DISK_PATH" ] && [ -r "$DISK_PATH" ] && disk=true || blockers+=("disco da VM ausente ou ilegível")
    [ -n "$OVMF_CODE" ] && [ -f "$OVMF_CODE" ] && [ -r "$OVMF_CODE" ] && ovmf=true || blockers+=("firmware OVMF ausente ou ilegível")
    [ -f "$OVMF_VARS" ] && [ -r "$OVMF_VARS" ] && [ -w "$OVMF_VARS" ] && vars=true || blockers+=("OVMF_VARS ausente ou sem escrita")
    command -v qemu-system-x86_64 >/dev/null 2>&1 && qemu=true || blockers+=("qemu-system-x86_64 ausente")

    case "$GRAPHICS_PROFILE" in
        compat) graphics=true ;;
        virtio-gl)
            local render_node="" qemu_bin
            for render_node in /dev/dri/renderD*; do
                [ -r "$render_node" ] && [ -w "$render_node" ] && break
                render_node=""
            done
            [ -n "$render_node" ] || blockers+=("render node GL sem acesso")
            qemu_bin="$(command -v qemu-system-x86_64 2>/dev/null || true)"
            if [ -n "$qemu_bin" ] && "$qemu_bin" -device help 2>/dev/null | grep -q 'virtio-vga-gl' \
                && "$qemu_bin" -display help 2>/dev/null | grep -qw gtk; then
                [ -n "$render_node" ] && graphics=true
            else
                blockers+=("QEMU sem virtio-vga-gl/GTK")
            fi
            ;;
        *) blockers+=("perfil gráfico não suportado no Windows: $GRAPHICS_PROFILE") ;;
    esac

    local success=false
    [ "${#blockers[@]}" -eq 0 ] && success=true
    if [ "$JSON_OUT" = "1" ]; then
        printf '%s\n' "${blockers[@]:-}" | jq -R -s \
            --argjson success "$success" \
            --arg profile "$GRAPHICS_PROFILE" \
            --arg diskPath "$DISK_PATH" \
            --argjson kvm "$kvm" --argjson disk "$disk" --argjson ovmf "$ovmf" \
            --argjson vars "$vars" --argjson qemu "$qemu" --argjson graphics "$graphics" \
            '{success:$success,graphicsProfile:$profile,diskPath:$diskPath,
              checks:{kvm:$kvm,disk:$disk,ovmf:$ovmf,ovmfVars:$vars,qemu:$qemu,graphics:$graphics},
              blockers:(split("\n")|map(select(length>0)))}'
    else
        if $success; then
            pz_info "Windows VM launch preflight passed ($GRAPHICS_PROFILE)"
        else
            pz_error "Windows VM launch preflight failed:"
            printf '  - %s\n' "${blockers[@]}" >&2
        fi
    fi
    $success
}

status_json() {
    effective_config
    local kvm="no" config="no" disk="no" iso="no" ovmf="no" vars="no" qemu="" qemu_img="" virtiofs="" smbd="" swtpm_bin="" boot_helper="no" boot_service="no" boot_grub="unknown" current_marker="no" installed_like="no" boot_current="no" boot_verification="stale" samba_managed="no" samba_reachable="no" share_links="no" usb_udev_managed="no" discovery
    local domain_state="missing" domain_disk=""
    [ -e /dev/kvm ] && kvm="yes"
    [ -f "$CONFIG_FILE" ] && config="yes"
    [ -f "$DISK_PATH" ] && disk="yes"
    if [ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH"; then
        installed_like="yes"
    fi
    [ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ] && iso="yes"
    [ -n "$OVMF_CODE" ] && [ -f "$OVMF_CODE" ] && ovmf="yes"
    [ -f "$OVMF_VARS" ] && vars="yes"
    qemu="$(command_path qemu-system-x86_64)"
    qemu_img="$(command_path qemu-img)"
    virtiofs="$(virtiofsd_path)"
    smbd="$(command_path smbd)"
    swtpm_bin="$(command_path swtpm)"
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        domain_state="$(virsh -c "$(libvirt_uri)" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || echo unavailable)"
        domain_disk="$(libvirt_domain_disk "$LIBVIRT_DOMAIN")"
    fi
    [ -x "$BOOT_HELPER_TARGET" ] && boot_helper="yes"
    [ -f "$SERVICE_FILE" ] && boot_service="yes"
    samba_shares_managed && samba_managed="yes"
    samba_shares_reachable && samba_reachable="yes"
    local samba_policy="no"
    samba_policy_compliant && samba_policy="yes"
    share_links_ready && share_links="yes"
    windows_usb_udev_managed && usb_udev_managed="yes"
    local boot_runtime_state_value
    boot_runtime_state_value="$(boot_runtime_state)"
    if boot_artifacts_current; then
        boot_current="yes"
        boot_verification="verified"
    elif [ "$boot_runtime_state_value" = "stale" ]; then
        boot_current="no"
        boot_verification="stale"
    elif [ "$EUID" -ne 0 ] && [ ! -x "$(dirname "$GRUB_SCRIPT")" ]; then
        boot_current="unknown"
        boot_verification="unknown-permission"
    fi
    boot_grub="$(grub_cfg_entry_state)"
    grep -w 'phasezero.windowsvm=1' /proc/cmdline >/dev/null 2>&1 && current_marker="yes"
    discovery="$(discovery_json configured)"
    local session_state_file="$PZ_STATE/windows-vm/session-state.json"
    local session_graceful=true session_reason="" session_ended_at=""
    if [ -r "$session_state_file" ]; then
        session_graceful="$(jq -r 'if has("graceful") and (.graceful|type) == "boolean" then .graceful else true end' "$session_state_file" 2>/dev/null || echo true)"
        session_reason="$(jq -r '.reason // ""' "$session_state_file" 2>/dev/null || true)"
        session_ended_at="$(jq -r '.endedAt // ""' "$session_state_file" 2>/dev/null || true)"
    fi
    [ "$session_graceful" = "false" ] || [ "$session_graceful" = "true" ] || session_graceful=true
    local session_unclean=false session_hint=false
    if [ "$session_graceful" = "false" ]; then
        session_unclean=true
    elif [ "$session_reason" = "guest-exit-unverified" ]; then
        session_hint=true
    fi
    local boot_pending=false
    [ -e "$BOOT_RUNTIME_PENDING_FILE" ] && boot_pending=true
    jq -n \
        --arg configFile "$CONFIG_FILE" \
        --arg configInstalled "$config" \
        --arg vmDir "$VM_DIR" \
        --arg disk "$DISK_PATH" \
        --arg diskExists "$disk" \
        --arg iso "$ISO_PATH" \
        --arg isoExists "$iso" \
        --arg ramMb "$RAM_MB" \
        --arg cpus "$CPUS" \
        --arg usbMode "$USB_MODE" \
        --arg graphicsProfile "$GRAPHICS_PROFILE" \
        --arg netModel "$NET_MODEL" \
        --arg usbAutoFilter "$USB_AUTO_FILTER" \
        --arg usbUdevManaged "$usb_udev_managed" \
        --arg usbRedirChannels "$(libvirt_usb_redir_count)" \
        --arg usbAccessibleDevices "$(usb_accessible_device_count)" \
        --arg shareRoot "$SHARE_ROOT" \
        --arg shareLinks "$share_links" \
        --arg sharePolicy "$SHARE_POLICY" \
        --arg shareWritable "$SHARE_WRITABLE" \
        --arg sambaManaged "$samba_managed" \
        --arg sambaPolicyCompliant "$samba_policy" \
        --arg sambaReachable "$samba_reachable" \
        --arg smbHost "$SMB_HOST" \
        --arg exchangeDir "$EXCHANGE_DIR" \
        --arg webdavChannels "$(libvirt_webdav_channel_count)" \
        --arg networkState "$(libvirt_network_state)" \
        --arg nicModel "$(libvirt_interface_model)" \
        --arg spicy "$(command_path spicy)" \
        --arg diskSource "$DISK_SOURCE" \
        --arg libvirtDomain "$LIBVIRT_DOMAIN" \
        --arg libvirtUri "$(libvirt_uri)" \
        --arg libvirtState "$domain_state" \
        --arg libvirtDisk "$domain_disk" \
        --arg diskInstalledLike "$installed_like" \
        --arg kvm "$kvm" \
        --arg qemu "$qemu" \
        --arg qemuImg "$qemu_img" \
        --arg ovmfCode "$OVMF_CODE" \
        --arg ovmfCodeExists "$ovmf" \
        --arg ovmfVars "$OVMF_VARS" \
        --arg ovmfVarsExists "$vars" \
        --arg virtiofsd "$virtiofs" \
        --arg smbd "$smbd" \
        --arg swtpm "$swtpm_bin" \
        --arg bootHelper "$boot_helper" \
        --arg bootService "$boot_service" \
        --arg bootArtifactsCurrent "$boot_current" \
        --arg artifactsVerification "$boot_verification" \
        --arg bootRuntimeState "$boot_runtime_state_value" \
        --argjson bootRuntimeStale "$([ "$boot_runtime_state_value" = "stale" ] && echo true || echo false)" \
        --argjson lastSessionGraceful "$session_graceful" \
        --arg lastSessionReason "$session_reason" \
        --arg lastSessionEndedAt "$session_ended_at" \
        --argjson sessionUnclean "$session_unclean" \
        --argjson sessionEndHint "$session_hint" \
        --argjson bootRuntimePendingSync "$boot_pending" \
        --arg hostLoginPolicy "$(root_env_value PZ_WINDOWS_VM_REQUIRE_LOGIN)" \
        --arg guestLoginPolicy "$GUEST_LOGIN_POLICY" \
        --arg bootConfiguredRepo "$(root_env_value PZ_WINDOWS_VM_REPO)" \
        --arg bootConfiguredUser "$(root_env_value PZ_WINDOWS_VM_BOOT_USER)" \
        --arg grubEntry "$boot_grub" \
        --arg currentMarker "$current_marker" \
        --argjson discovery "$discovery" \
        '{
            status: (
                if $kvm != "yes" or $qemu == "" or $ovmfCodeExists != "yes" or $ovmfVarsExists != "yes" then "blocked"
                elif $configInstalled != "yes" or $diskExists != "yes" or $diskInstalledLike != "yes" then "needsinstall"
                elif $bootRuntimeStale then "warning"
                else "ok"
                end
            ),
            health: {
                readyToLaunch: (
                    $configInstalled == "yes" and $diskExists == "yes" and $diskInstalledLike == "yes"
                    and $kvm == "yes" and $qemu != "" and $ovmfCodeExists == "yes" and $ovmfVarsExists == "yes"
                ),
                bootDirectReady: (
                    $bootHelper == "yes" and $bootService == "yes"
                    and $bootArtifactsCurrent == "yes" and ($bootRuntimeStale | not)
                ),
                findings: [
                    if $configInstalled != "yes" then
                        {id:"vm-not-configured", severity:"warning", message:"A máquina virtual ainda não foi configurada.", action:"windows.provision.player"}
                    elif $diskExists != "yes" then
                        {id:"disk-missing", severity:"error", message:"O disco configurado não foi encontrado.", action:"windows.provision.player"}
                    elif $diskInstalledLike != "yes" then
                        {id:"guest-not-installed", severity:"warning", message:"O disco existe, mas ainda não contém um Windows inicializável.", action:"windows.provision.player"}
                    else empty end,
                    if $kvm != "yes" then {id:"kvm-unavailable", severity:"error", message:"A aceleração KVM não está disponível.", action:"windows.graphics.doctor"} else empty end,
                    if $qemu == "" then {id:"qemu-missing", severity:"error", message:"QEMU não foi encontrado no host.", action:"windows.graphics.doctor"} else empty end,
                    if $ovmfCodeExists != "yes" or $ovmfVarsExists != "yes" then {id:"uefi-incomplete", severity:"error", message:"Os arquivos UEFI da VM estão incompletos.", action:"windows.provision.player"} else empty end,
                    if $bootRuntimeStale then {id:"boot-runtime-stale", severity:"warning", message:"O boot direto usa uma versão antiga do PhaseZero.", action:"windows.boot.install"} else empty end,
                    if $sessionUnclean and $diskInstalledLike == "yes" then {id:"guest-unclean-shutdown", severity:"warning", message:"Windows foi desligado de forma inesperada. Ao iniciar, deixe o reparo automático concluir — pode levar alguns minutos.", action:"windows.status"} else empty end,
                    if $sessionEndHint and $diskInstalledLike == "yes" then {id:"session-shutdown-hint", severity:"info", message:"Encerre o Windows pelo menu Iniciar ou pelo botão Desligar do PhaseZero para um desligamento limpo.", action:"windows.status"} else empty end
                ]
            },
            session: {lastEndedAt:$lastSessionEndedAt, lastGraceful:$lastSessionGraceful, lastReason:$lastSessionReason},
            config: {path: $configFile, installed: ($configInstalled == "yes")},
            vm: {dir: $vmDir, disk: $disk, diskExists: ($diskExists == "yes"), diskSource: $diskSource, installedLike: ($diskInstalledLike == "yes"), iso: $iso, isoExists: ($isoExists == "yes"), ramMb: ($ramMb|tonumber), cpus: ($cpus|tonumber), usbMode: $usbMode, graphicsProfile: $graphicsProfile, netModel: $netModel},
            libvirt: {domain: $libvirtDomain, uri: $libvirtUri, state: $libvirtState, disk: $libvirtDisk, preferred: ($libvirtDomain != ""), network:"default", networkState:$networkState, nicModel:$nicModel},
            host: {kvm: ($kvm == "yes"), qemu: $qemu, qemuImg: $qemuImg, ovmfCode: $ovmfCode, ovmfCodeExists: ($ovmfCodeExists == "yes"), ovmfVars: $ovmfVars, ovmfVarsExists: ($ovmfVarsExists == "yes"), virtiofsd: $virtiofsd, smbd: $smbd, swtpm: $swtpm},
            access: {
                shareRoot: $shareRoot,
                shareLinksReady: ($shareLinks == "yes"),
                sambaManaged: ($sambaManaged == "yes"),
                sambaPolicyCompliant: ($sambaPolicyCompliant == "yes"),
                sambaReachable: ($sambaReachable == "yes"),
                smbHost: $smbHost,
                exchangeDir: $exchangeDir,
                sharePolicy: $sharePolicy,
                shareWritable: ($shareWritable == "1"),
                shares: ([if $sharePolicy == "full" then "PZExchange", "PZHome", "PZSDCard", "PZRemovable", "PZMedia", "PZMounts" else "PZExchange" end]),
                spiceClient: $spicy,
                spiceWebdavChannels: ($webdavChannels|tonumber),
                usbMode: $usbMode,
                usbAutoFilter: $usbAutoFilter,
                usbUdevManaged: ($usbUdevManaged == "yes"),
                usbRedirChannels: ($usbRedirChannels|tonumber),
                usbAccessibleDevices: ($usbAccessibleDevices|tonumber)
            },
            discovery: $discovery,
            boot: {helperInstalled: ($bootHelper == "yes"), serviceInstalled: ($bootService == "yes"),
                   artifactsCurrent:(if $bootArtifactsCurrent == "unknown" then null else ($bootArtifactsCurrent == "yes") end),
                   artifactsVerification:$artifactsVerification,
                   bootRuntimeState:$bootRuntimeState, bootRuntimeStale:$bootRuntimeStale,
                   bootRuntimePendingSync:$bootRuntimePendingSync,
                   hostLoginPolicy:(if $hostLoginPolicy == "1" then "password" else "auto" end),
                   guestLoginPolicy:$guestLoginPolicy, guestLoginVerified:false,
                   configuredRepo: $bootConfiguredRepo, configuredUser: $bootConfiguredUser, grubCfgEntry: $grubEntry, currentBootWindowsVm: ($currentMarker == "yes")}
        }'
}

print_status() {
    status_json
}

print_discover() {
    parse_options "$@"
    if [ "$JSON_OUT" = "1" ]; then
        discovery_json
        return 0
    fi
    local discovery
    discovery="$(discovery_json)"
    echo "PhaseZero Windows VM discovery"
    echo "  configured_disk: $(jq -r '.configuredDisk.path // ""' <<< "$discovery")"
    echo "  discovered_installed_disk: $(jq -r '.discoveredInstalledDisk.path // ""' <<< "$discovery")"
    echo "  discovered_installed_usable: $(jq -r '.discoveredInstalledDisk.usable // false' <<< "$discovery")"
    echo "  discovered_usable_disk: $(jq -r '.discoveredUsableDisk.path // ""' <<< "$discovery")"
    echo "  discovered_any_disk: $(jq -r '.discoveredAnyDisk.path // ""' <<< "$discovery")"
}

cmd_optimize() {
    parse_options "$@"
    effective_config
    apply_host_optimizations
    optimize_libvirt_domain
}

cmd_adopt() {
    parse_options "$@"
    local target="${DISK_PATH:-$(find_existing_windows_disk | sed -n '1p')}"
    [ -n "$target" ] || { pz_error "no existing Windows VM disk found"; return 1; }
    [ -f "$target" ] || { pz_error "existing disk not found: $target"; return 1; }
    disk_looks_installed "$target" || { pz_error "disk does not look like an installed Windows VM: $target"; return 1; }
    if ! target_user_can_rw "$target"; then
        if [ "$EUID" -ne 0 ]; then
            pz_error "existing disk is not readable. run: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh adopt --disk '$target'"
            return 1
        fi
        if command -v setfacl >/dev/null 2>&1; then
            setfacl -m "u:$TARGET_USER:rw" "$target" || true
        else
            chmod g+rw "$target" || true
        fi
    fi
    target_user_can_rw "$target" || { pz_error "could not grant $TARGET_USER read/write access to existing disk: $target"; return 1; }
    DISK_PATH="$target"
    EXPLICIT_DISK=1
    effective_config
    local target_dir
    target="$(readlink -f -- "$target")"
    target_dir="$(dirname -- "$target")"
    DISK_PATH="$target"
    VM_DIR="$target_dir"
    LIBVIRT_DOMAIN=""
    OVMF_VARS="$VM_DIR/OVMF_VARS.fd"
    SHARE_ROOT="$VM_DIR/shares"
    TPM_DIR="$VM_DIR/tpm"
    SMB_HOST="10.0.2.2"
    case "$ADOPT_SOURCE" in
        provisioned|adopted-existing) DISK_SOURCE="$ADOPT_SOURCE" ;;
        *) pz_error "unknown adopt source: $ADOPT_SOURCE (provisioned|adopted-existing)"; return 1 ;;
    esac
    ensure_vm_storage
    write_config
    install_user_files
    pz_info "adopted existing Windows VM disk: $target"
}

cmd_remove() {
    parse_options "$@"
    effective_config
    local -a blockers=() warnings=()
    local vm_real disk_real domain_state="" provision_blocker="" blockers_json='[]'
    local warnings_json='[]' adopted=false
    vm_real="$(realpath -m -- "$VM_DIR" 2>/dev/null || printf '%s' "$VM_DIR")"
    disk_real="$(realpath -m -- "$DISK_PATH" 2>/dev/null || printf '%s' "$DISK_PATH")"

    # Ownership is decided by location, not by the provenance label: the disk
    # must sit inside ~/VirtualMachines/PhaseZero* (checked below). Disks that
    # PhaseZero adopted rather than built are still removable from there —
    # refusing them left every provisioned VM unremovable, since `provision
    # finalize` adopts its own output — but they are flagged so the caller can
    # warn before trashing an installation PhaseZero did not create.
    case "$DISK_SOURCE" in
        new|managed|config|provisioned) ;;
        adopted-existing|discovered-installed|explicit)
            adopted=true
            warnings+=("esta VM foi adotada, não criada pelo PhaseZero; confirme antes de removê-la")
            ;;
        *) blockers+=("origem do disco desconhecida: $DISK_SOURCE") ;;
    esac
    [ -d "$vm_real" ] || blockers+=("diretório gerenciado da VM não foi encontrado")
    [ "$vm_real" != "/" ] && [ "$vm_real" != "$HOME" ] || blockers+=("diretório da VM inseguro")
    case "$vm_real" in
        "$HOME"/VirtualMachines/PhaseZero*) ;;
        *) blockers+=("diretório não pertence ao local gerenciado ~/VirtualMachines/PhaseZero*") ;;
    esac
    case "$disk_real" in "$vm_real"/*) ;; *) blockers+=("disco configurado está fora do diretório gerenciado") ;; esac
    if provision_blocker="$(provision_removal_blocker)"; then
        blockers+=("$provision_blocker")
    fi
    disk_in_use && blockers+=("desligue a VM antes de removê-la")
    if [ -n "$LIBVIRT_DOMAIN" ]; then
        domain_state="$(virsh -c "$(libvirt_uri)" domstate "$LIBVIRT_DOMAIN" 2>/dev/null || true)"
        case "$domain_state" in running|paused|pmsuspended) blockers+=("domínio libvirt está $domain_state") ;; esac
    fi
    command -v gio >/dev/null 2>&1 || blockers+=("gio não está disponível para mover a VM à lixeira")
    if [ "${#blockers[@]}" -gt 0 ]; then
        blockers_json="$(printf '%s\n' "${blockers[@]}" | jq -R . | jq -s .)"
    fi
    if [ "${#warnings[@]}" -gt 0 ]; then
        warnings_json="$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)"
    fi

    if [ "$JSON_OUT" = "1" ] && { [ "$DRY_RUN" = 1 ] || [ "$REMOVE_CONFIRMED" != 1 ] || [ "${#blockers[@]}" -gt 0 ]; }; then
        jq -n \
            --arg vmDir "$vm_real" \
            --arg disk "$disk_real" \
            --arg source "$DISK_SOURCE" \
            --arg config "$CONFIG_FILE" \
            --arg domain "$LIBVIRT_DOMAIN" \
            --argjson blockers "$blockers_json" \
            --argjson warnings "$warnings_json" \
            --argjson adopted "$adopted" \
            --argjson confirmed "$([ "$REMOVE_CONFIRMED" = 1 ] && echo true || echo false)" \
            '{schemaVersion:1, operation:"windows-vm-remove", vm:{dir:$vmDir,disk:$disk,diskSource:$source,adopted:$adopted,libvirtDomain:$domain}, config:$config, blockers:$blockers, warnings:$warnings, ready:($blockers|length == 0), confirmed:$confirmed, recovery:"A VM será movida para a lixeira; restaure-a e use Adotar disco para recuperar.", nextAction:"Remova o boot direto Windows separadamente, se ele estiver instalado."}'
    elif [ "$JSON_OUT" != "1" ]; then
        printf 'VM: %s\nDisco: %s\n' "$vm_real" "$disk_real"
        [ "${#warnings[@]}" -eq 0 ] || printf 'Avisos:\n%s\n' "$(printf -- '- %s\n' "${warnings[@]}")"
        [ "${#blockers[@]}" -eq 0 ] && echo "Pronta para mover à lixeira." || printf 'Bloqueios:\n%s\n' "$(printf -- '- %s\n' "${blockers[@]}")"
    fi
    [ "${#blockers[@]}" -eq 0 ] || return 1
    [ "$DRY_RUN" = 1 ] && return 0
    [ "$REMOVE_CONFIRMED" = 1 ] || { pz_error "remoção requer --yes após a prévia"; return 1; }

    gio trash -- "$vm_real" || { pz_error "não foi possível mover a VM para a lixeira"; return 1; }
    [ ! -e "$vm_real" ] || { pz_error "a VM ainda existe após a operação de lixeira"; return 1; }
    rm -f -- "$CONFIG_FILE" "$APPLICATIONS_DIR/phasezero-windows-vm.desktop" \
        "$APPLICATIONS_DIR/phasezero-reboot-windows-vm.desktop" "$SYSTEMD_USER_DIR/phasezero-windows-vm.service" \
        || { pz_error "a VM foi movida para a lixeira, mas a configuração não pôde ser removida"; return 1; }
    [ ! -e "$CONFIG_FILE" ] || { pz_error "a VM foi movida para a lixeira, mas a configuração ainda existe"; return 1; }
    if [ "$JSON_OUT" = "1" ]; then
        jq -n --arg vmDir "$vm_real" --arg config "$CONFIG_FILE" \
            '{schemaVersion:1, operation:"windows-vm-remove", success:true, vmDir:$vmDir, configRemoved:(($config|length) > 0), recovery:"Restaure a pasta da lixeira e use Adotar disco para recuperar.", nextAction:"Remova o boot direto Windows separadamente, se ele estiver instalado."}'
    else
        pz_info "VM movida para a lixeira; configuração PhaseZero removida"
    fi
}

print_plan() {
    parse_options "$@"
    effective_config
    if [ "$JSON_OUT" = "1" ]; then
        status_json
        return 0
    fi
    echo "PhaseZero Windows VM plan"
    echo "  iso: ${ISO_PATH:-missing}"
    echo "  disk: $DISK_PATH ($DISK_SIZE)"
    echo "  disk_source: $DISK_SOURCE"
    echo "  disk_installed_like: $([ -f "$DISK_PATH" ] && disk_looks_installed "$DISK_PATH" && echo yes || echo no)"
    echo "  ram_mb: $RAM_MB"
    echo "  cpus: $CPUS"
    echo "  kvm: $([ -e /dev/kvm ] && echo yes || echo no)"
    echo "  ovmf: ${OVMF_CODE:-missing}"
    echo "  tpm: $(command_path swtpm || echo missing)"
    echo "  share_policy: $SHARE_POLICY"
    echo "  share_writable: $SHARE_WRITABLE"
    echo "  home_share: $([ "$SHARE_POLICY" = "full" ] && echo "$HOME" || echo 'hidden (policy=minimal)')"
    echo "  sdcard_share: $([ "$SHARE_POLICY" = "full" ] && { [ -d /mnt/sdcard ] && echo /mnt/sdcard || echo missing; } || echo 'hidden (policy=minimal)')"
    echo "  removable_share: $([ "$SHARE_POLICY" = "full" ] && { [ -d "$REMOVABLE_ROOT/$TARGET_USER" ] && echo "$REMOVABLE_ROOT/$TARGET_USER" || echo missing; } || echo 'hidden (policy=minimal)')"
    # shellcheck disable=SC2028 # intentional: echo with backslash escapes for user display
    echo "  smb_unc: \\\\10.0.2.4\\qemu"
    echo "  spice_usb: spice://$SPICE_ADDR:5930"
    echo "  direct_boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
}

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    pz_error "root required. run: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot install"
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
            --loader)
                [ -n "${2:-}" ] || { pz_error "--loader requires auto|grub|systemd-boot|refind|efi-stub"; return 1; }
                export PZ_BOOT_LOADER="$2"
                shift 2
                ;;
            --loader=*)
                export PZ_BOOT_LOADER="${1#*=}"
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

detected_loader() {
    local loader="${PZ_BOOT_LOADER:-auto}"
    if [ "$loader" = "auto" ]; then
        loader="$(pz_boot_detect_loader)"
    fi
    echo "$loader"
}

loader_install_entry() {
    local loader="$1" uuid version kernel initrd cmdline
    uuid="$(root_uuid)"
    version="$(latest_kernel_version)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    [ -n "$version" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    kernel="/boot/vmlinuz-$version"
    initrd="/boot/initramfs-$version.img"
    [ -f "$kernel" ] || { pz_error "missing kernel: $kernel"; return 1; }
    [ -f "$initrd" ] || { pz_error "missing initrd: $initrd"; return 1; }
    cmdline="root=UUID=$uuid rw quiet splash"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && cmdline="$cmdline rootflags=subvol=$subvol"

    case "$loader" in
        systemd-boot)
            pz_boot_systemd_boot_oneshot_entry "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            pz_boot_systemd_boot_set_oneshot "$BOOT_ID"
            ;;
        refind)
            pz_boot_refind_install_stanza "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            ;;
        efi-stub)
            pz_boot_efi_stub_entry "$BOOT_ID" "$kernel" "$initrd" "$cmdline"
            ;;
        grub-efi|grub-bios)
            return 0
            ;;
        *)
            pz_error "unsupported loader: $loader"
            return 1
            ;;
    esac
}

loader_remove_entry() {
    local loader="$1"
    case "$loader" in
        systemd-boot)
            pz_boot_systemd_boot_remove_entry "$BOOT_ID"
            ;;
        refind)
            pz_boot_refind_remove_stanza "$BOOT_ID"
            ;;
        efi-stub)
            pz_boot_efi_stub_remove "$BOOT_ID"
            ;;
        grub-efi|grub-bios)
            return 0
            ;;
        *)
            pz_error "unsupported loader: $loader"
            return 1
            ;;
    esac
}

loader_entry_state() {
    local loader="$1"
    case "$loader" in
        systemd-boot)
            local esp; esp="$(pz_boot_esp_dir)"
            [ -f "$esp/loader/entries/$BOOT_ID.conf" ] && echo present || echo missing
            ;;
        refind)
            local esp; esp="$(pz_boot_esp_dir)"
            [ -f "$esp/EFI/refind/entries/$BOOT_ID.conf" ] && echo present || echo missing
            ;;
        grub-efi|grub-bios)
            grub_cfg_entry_state
            ;;
        *)
            echo unknown
            ;;
    esac
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
Name=PhaseZero Windows VM
Comment=Start PhaseZero Windows VM without desktop login
Exec=$SESSION_TARGET
Type=Application
DesktopNames=PhaseZeroWindowsVM
EOF
}

root_env_content() {
    local boot_uid
    boot_uid="$(id -u "$TARGET_USER" 2>/dev/null || printf unknown)"
    printf '%s\n' '# PhaseZero managed Windows VM boot environment'
    printf 'PZ_WINDOWS_VM_REPO=%q\n' "$PZ_ROOT"
    printf 'PZ_WINDOWS_VM_BOOT_USER=%q\n' "$TARGET_USER"
    printf 'PZ_WINDOWS_VM_RUNTIME_LAUNCHER=%q\n' "$RUNTIME_LAUNCHER"
    printf 'PZ_WINDOWS_VM_RUNTIME_DIR=%q\n' "/run/phasezero/windows-vm-$boot_uid"
    printf 'PZ_DISPLAY_SESSION_HELPER=%q\n' "$DISPLAY_SESSION_TARGET"
    printf 'PZ_WINDOWS_VM_SESSION_RETRY_SECONDS=%q\n' "${PZ_WINDOWS_VM_SESSION_RETRY_SECONDS:-5}"
    printf 'PZ_WINDOWS_VM_DESKTOP_FALLBACK=%q\n' "${PZ_WINDOWS_VM_DESKTOP_FALLBACK:-0}"
    printf 'PZ_WINDOWS_VM_REQUIRE_LOGIN=%q\n' "${PZ_WINDOWS_VM_REQUIRE_LOGIN:-0}"
    printf 'PZ_WINDOWS_VM_BOOT_DOCK_ENTRY=%q\n' "$(boot_dock_entry_enabled)"
    printf 'PZ_WINDOWS_VM_BOOT_HANDHELD_ENTRY=%q\n' "$(boot_handheld_entry_enabled)"
}

root_env_value() {
    local name="$1"
    [ -r "$ROOT_ENV_FILE" ] || return 0
    (
        set +u
        # Managed root-owned environment generated by root_env_content.
        # shellcheck disable=SC1090
        . "$ROOT_ENV_FILE"
        printf '%s\n' "${!name:-}"
    )
}

# Dock GRUB entry state: the process environment wins (so `boot install
# --dock-entry` takes effect in the same run and tests can pin it), then the
# persisted root env, then disabled.
# The default GRUB entry already resolves the display at session start: with an
# external connector present it takes that output's mode and refresh rate, and
# falls back to the Deck panel otherwise. These two entries do not carry
# geometry - baking a resolution into a menuentry would freeze whatever monitor
# happened to be attached at `boot install` time - they carry intent, pinning
# the output when auto-detection is not what the operator wants.
# Enabled by default: the cost is two extra menu lines, and the alternative is
# having no way to override the choice from the boot menu at all.
boot_dock_entry_enabled() {
    if [ -n "${PZ_WINDOWS_VM_BOOT_DOCK_ENTRY+x}" ]; then
        case "$PZ_WINDOWS_VM_BOOT_DOCK_ENTRY" in 0) printf '0' ;; *) printf '1' ;; esac
        return 0
    fi
    case "$(root_env_value PZ_WINDOWS_VM_BOOT_DOCK_ENTRY)" in 0) printf '0' ;; *) printf '1' ;; esac
}

# Symmetric counterpart: the session has always understood
# phasezero.windowsvm-display=internal, but no menuentry emitted it, so booting
# while docked gave no way back to the handheld panel.
# State of one optional menuentry in the managed GRUB script.
# /etc/grub.d is root-only on most distributions (0700): an unreadable script
# must report unknown-permission, never "missing".
boot_menu_entry_state() {
    local entry="$1" enabled="$2"
    [ "$enabled" = "1" ] || { printf 'disabled'; return 0; }
    if [ -r "$GRUB_SCRIPT" ]; then
        if grep -Fq "menuentry '$entry'" "$GRUB_SCRIPT" 2>/dev/null; then
            printf 'present'
        else
            printf 'missing'
        fi
    else
        printf 'unknown-permission'
    fi
}

# Outcome of the background touch-keyboard policy started by the boot session.
# Windows hides the touch keyboard while a USB keyboard is attached, and QEMU
# always attaches one, so without this policy a handheld guest has no way to
# type at all. The helper wrote its result to a log nothing ever read: it timed
# out waiting for QGA and the failure stayed invisible until someone tried to
# use Windows with no keyboard.
boot_touch_input_state() {
    local log="$STATE_DIR/touch-input.log"
    [ -r "$log" ] || { printf 'unknown'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    local ok state
    ok="$(jq -r '.success // false' "$log" 2>/dev/null || printf 'false')"
    [ "$ok" = "true" ] && { printf 'applied'; return 0; }
    state="$(jq -r '.state // "failed"' "$log" 2>/dev/null || printf 'failed')"
    case "$state" in
        ""|null) printf 'failed' ;;
        *) printf '%s' "$state" ;;
    esac
}

boot_handheld_entry_enabled() {
    if [ -n "${PZ_WINDOWS_VM_BOOT_HANDHELD_ENTRY+x}" ]; then
        case "$PZ_WINDOWS_VM_BOOT_HANDHELD_ENTRY" in 0) printf '0' ;; *) printf '1' ;; esac
        return 0
    fi
    case "$(root_env_value PZ_WINDOWS_VM_BOOT_HANDHELD_ENTRY)" in 0) printf '0' ;; *) printf '1' ;; esac
}

# Arvore runtime da sessao de boot. Precisa ser auto-contida: durante o boot
# GRUB o repo do usuario pode nem estar montado, entao tudo que common.sh e
# windows-vm.sh carregam com `source` tem que estar aqui. Faltando um arquivo,
# a sessao falha em loop e o host mostra tela preta.
runtime_file_specs() {
    cat <<EOF
$PZ_ROOT/linux/windows-vm/windows-vm.sh|$RUNTIME_LAUNCHER|0755
$PZ_ROOT/linux/windows-vm/graphics.sh|$RUNTIME_GRAPHICS|0755
$PZ_ROOT/linux/windows-vm/rescue.sh|$RUNTIME_ROOT/linux/windows-vm/rescue.sh|0644
$PZ_ROOT/linux/windows-vm/guest-login.sh|$RUNTIME_ROOT/linux/windows-vm/guest-login.sh|0755
$PZ_ROOT/linux/windows-vm/guest-login.ps1|$RUNTIME_ROOT/linux/windows-vm/guest-login.ps1|0644
$PZ_ROOT/linux/windows-vm/provision.sh|$RUNTIME_ROOT/linux/windows-vm/provision.sh|0644
$PZ_ROOT/linux/windows-vm/graphics-profiles.json|$RUNTIME_ROOT/linux/windows-vm/graphics-profiles.json|0644
$PZ_ROOT/linux/lib/common.sh|$RUNTIME_COMMON|0644
$PZ_ROOT/linux/lib/ledger.sh|$RUNTIME_ROOT/linux/lib/ledger.sh|0644
$PZ_ROOT/linux/lib/desktop.sh|$RUNTIME_ROOT/linux/lib/desktop.sh|0644
$PZ_ROOT/linux/lib/flatpak.sh|$RUNTIME_ROOT/linux/lib/flatpak.sh|0644
EOF
}

install_runtime_tree() {
    local src dst mode
    while IFS='|' read -r src dst mode; do
        [ -n "$src" ] || continue
        [ -f "$src" ] || { pz_error "runtime source missing: $src"; return 1; }
        install -d "$(dirname "$dst")"
        install -m "$mode" "$src" "$dst"
    done < <(runtime_file_specs)
}

# Copia só os arquivos de runtime para /usr/local/lib/phasezero. É o que um
# upgrade de pacote invalida: os caminhos que a entrada GRUB já aponta passam a
# ter código da versão anterior. Deliberadamente NÃO regenera grub.cfg, não roda
# os-prober, não mexe em Samba nem no domínio libvirt — nada que possa deixar um
# bootloader meio escrito. Por ser só cópia dos arquivos que o próprio pacote
# acabou de instalar, roda seguro dentro da transação do gerenciador.
sync_boot_runtime_files() {
    install -d "$BOOT_LOCAL_PREFIX/lib/phasezero" "$RUNTIME_ROOT/linux/windows-vm" "$RUNTIME_ROOT/linux/lib" || return 1
    install -m 0755 "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET" || return 1
    install -m 0755 "$SESSION_SOURCE" "$SESSION_TARGET" || return 1
    install -m 0644 "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET" || return 1
    install_runtime_tree || return 1
    write_runtime_provenance
    rm -f -- "$BOOT_RUNTIME_PENDING_FILE" 2>/dev/null || true
}

write_runtime_provenance() {
    command -v jq >/dev/null 2>&1 || return 0
    local provenance_version="unknown"
    [ -r "$PZ_ROOT/version.json" ] && \
        provenance_version="$(jq -r '.version // "unknown"' "$PZ_ROOT/version.json" 2>/dev/null || echo unknown)"
    jq -n \
        --arg source "$PZ_ROOT" \
        --arg version "$provenance_version" \
        --arg installedAt "$(date -Iseconds)" \
        '{schemaVersion:1, source:$source, version:$version, installedAt:$installedAt}' \
        > "$RUNTIME_ROOT/provenance.json" 2>/dev/null || true
    chmod 0644 "$RUNTIME_ROOT/provenance.json" 2>/dev/null || true
}

# `boot sync-runtime`: o passo manual que sobrava depois de todo upgrade.
# Só faz sentido quando a integração de boot já existe — sem ela não há o que
# ressincronizar, e instalar boot é decisão do usuário, não de um upgrade.
cmd_boot_sync_runtime() {
    parse_options "$@"
    effective_config
    if [ ! -e "$BOOT_HELPER_TARGET" ] && [ ! -e "$RUNTIME_LAUNCHER" ]; then
        pz_info "boot integration not installed; nothing to resync"
        return 0
    fi
    # O requisito real é poder escrever no prefixo, não ser root: em produção
    # /usr/local é do root e dá no mesmo, mas assim o resync continua exercível
    # com um prefixo de teste e não mente sobre o que precisa.
    if [ ! -w "$BOOT_LOCAL_PREFIX/lib/phasezero" ]; then
        pz_error "sem permissão de escrita em $BOOT_LOCAL_PREFIX/lib/phasezero"
        pz_error "rode com privilégio: phasezero-admin $PZ_ROOT/linux/pz windows-vm boot sync-runtime"
        return 1
    fi
    pz_boot_require_current_root_target
    sync_boot_runtime_files || { pz_error "boot runtime resync failed"; return 1; }
    pz_info "Windows VM boot runtime resynced from $PZ_ROOT"
}

runtime_tree_current() {
    local src dst mode
    while IFS='|' read -r src dst mode; do
        [ -n "$src" ] || continue
        [ -f "$dst" ] || return 1
        cmp -s "$src" "$dst" || return 1
    done < <(runtime_file_specs)
}

# Every boot artifact lives under /usr/local and is world-readable, so whether
# the GRUB path is running current code can be answered without privilege.
# boot_artifacts_current cannot answer it: it also inspects /etc/grub.d and the
# root env file, so an unprivileged caller collapses a provable "stale" into
# "unknown-permission" and never learns the boot path is running old code.
# A package upgrade replaces $PZ_ROOT but never /usr/local, which makes this
# the normal state after every `pacman -U`, `apt upgrade` or `dnf update`.
boot_runtime_state() {
    local pair src dst mode
    if [ ! -e "$BOOT_HELPER_TARGET" ] && [ ! -e "$RUNTIME_LAUNCHER" ]; then
        printf 'not-installed'
        return 0
    fi
    for pair in "$BOOT_HELPER_SOURCE|$BOOT_HELPER_TARGET" \
                "$SESSION_SOURCE|$SESSION_TARGET" \
                "$DISPLAY_SESSION_SOURCE|$DISPLAY_SESSION_TARGET"; do
        src="${pair%%|*}"
        dst="${pair##*|}"
        [ -r "$src" ] || { printf 'unknown-source'; return 0; }
        [ -e "$dst" ] || { printf 'stale'; return 0; }
        [ -r "$dst" ] || { printf 'unknown-permission'; return 0; }
        cmp -s "$src" "$dst" || { printf 'stale'; return 0; }
    done
    while IFS='|' read -r src dst mode; do
        [ -n "$src" ] || continue
        [ -r "$src" ] || { printf 'unknown-source'; return 0; }
        [ -e "$dst" ] || { printf 'stale'; return 0; }
        [ -r "$dst" ] || { printf 'unknown-permission'; return 0; }
        cmp -s "$src" "$dst" || { printf 'stale'; return 0; }
    done < <(runtime_file_specs)
    printf 'current'
}

# Reports whether the installed boot runtime matches this PhaseZero root, and
# exits non-zero only when staleness is proven. Package hooks and doctor call
# this; it must stay cheap, privilege-free and silent about states it cannot
# establish, so an upgrade never fails on an inconclusive probe.
runtime_check() {
    parse_options "$@"
    effective_config
    local state hint
    state="$(boot_runtime_state)"
    hint="pz windows-vm boot install"
    if [ "$JSON_OUT" = "1" ]; then
        jq -n --arg state "$state" --arg source "$PZ_ROOT" --arg runtime "$RUNTIME_ROOT" \
            --arg remediation "$hint" \
            --argjson stale "$([ "$state" = "stale" ] && echo true || echo false)" \
            --argjson installed "$([ "$state" = "not-installed" ] && echo false || echo true)" \
            '{bootRuntimeState:$state,bootRuntimeStale:$stale,bootRuntimeInstalled:$installed,
              source:$source,runtime:$runtime,remediation:$remediation}'
    else
        case "$state" in
            not-installed) pz_info "Windows VM boot integration not installed" ;;
            current) pz_info "Windows VM boot runtime matches $PZ_ROOT" ;;
            stale)
                pz_warn "Windows VM boot runtime is OUTDATED: $RUNTIME_ROOT"
                pz_warn "the GRUB boot path still runs the previous version"
                pz_warn "run with admin rights: $hint"
                ;;
            *) pz_info "Windows VM boot runtime state could not be verified ($state)" ;;
        esac
    fi
    [ "$state" != "stale" ]
}

boot_artifacts_current() {
    local loader
    loader="$(detected_loader)"
        [ -x "$BOOT_HELPER_TARGET" ] &&
        [ -x "$SESSION_TARGET" ] &&
        [ -r "$DISPLAY_SESSION_TARGET" ] &&
        [ -x "$RUNTIME_LAUNCHER" ] &&
        [ -x "$RUNTIME_GRAPHICS" ] &&
        [ -r "$RUNTIME_COMMON" ] &&
        [ -f "$SERVICE_FILE" ] &&
        [ -f "$WAYLAND_SESSION_FILE" ] &&
        [ -f "$XSESSION_FILE" ] &&
        [ -f "$ROOT_ENV_FILE" ] || return 1
    case "$loader" in
        grub-efi|grub-bios)
            [ -x "$GRUB_SCRIPT" ] || return 1
            grep -Fq "phasezero.windowsvm=1" "$GRUB_SCRIPT" || return 1
            grep -Fq -- "--id='$BOOT_ID'" "$GRUB_SCRIPT" || return 1
            ;;
    esac
    cmp -s "$BOOT_HELPER_SOURCE" "$BOOT_HELPER_TARGET" || return 1
    cmp -s "$SESSION_SOURCE" "$SESSION_TARGET" || return 1
    cmp -s "$DISPLAY_SESSION_SOURCE" "$DISPLAY_SESSION_TARGET" || return 1
    runtime_tree_current || return 1
    [ "$(root_env_value PZ_WINDOWS_VM_REPO)" = "$PZ_ROOT" ] || return 1
    [ "$(root_env_value PZ_WINDOWS_VM_BOOT_USER)" = "$TARGET_USER" ] || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$WAYLAND_SESSION_FILE" || return 1
    grep -Fqx "Exec=$SESSION_TARGET" "$XSESSION_FILE" || return 1
    grep -Fqx "ExecStart=$BOOT_HELPER_TARGET" "$SERVICE_FILE" || return 1
}

boot_service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero Windows VM GRUB boot session switch
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
EnvironmentFile=-$ROOT_ENV_FILE
Environment=PZ_WINDOWS_VM_BOOT_USER=$TARGET_USER
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
    amd_ucode_rel="$(if [ -f /boot/amd-ucode.img ]; then grub-mkrelpath /boot/amd-ucode.img; fi)"
    intel_ucode_rel="$(if [ -f /boot/intel-ucode.img ]; then grub-mkrelpath /boot/intel-ucode.img; fi)"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"

    cat <<EOF
#!/usr/bin/env bash
exec tail -n +3 "\$0"
# PhaseZero managed GRUB entry. Re-run linux/pz windows-vm boot install after kernel changes.
menuentry '$BOOT_ENTRY' --id='$BOOT_ID' --hotkey=w --class windows --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Windows VM...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet splash phasezero.windowsvm=1
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
    if [ "$(boot_dock_entry_enabled)" = "1" ]; then
        cat <<EOF
menuentry '$BOOT_DOCK_ENTRY' --id='$BOOT_DOCK_ID' --hotkey=d --class windows --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Windows VM on the docked monitor...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet splash phasezero.windowsvm=1 phasezero.windowsvm-display=external
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
    fi
    if [ "$(boot_handheld_entry_enabled)" = "1" ]; then
        cat <<EOF
menuentry '$BOOT_HANDHELD_ENTRY' --id='$BOOT_HANDHELD_ID' --hotkey=h --class windows --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Windows VM on the handheld panel...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet splash phasezero.windowsvm=1 phasezero.windowsvm-display=internal
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
    fi
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
    local loader dock_pref="" handheld_pref=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dock-entry) dock_pref=1; shift ;;
            --no-dock-entry) dock_pref=0; shift ;;
            --handheld-entry) handheld_pref=1; shift ;;
            --no-handheld-entry) handheld_pref=0; shift ;;
            *) shift ;;
        esac
    done
    need_root
    pz_boot_require_current_root_target
    # The dock toggle is persisted in the root env so kernel-refresh installs
    # and package hooks keep regenerating the entry until it is disabled.
    if [ -n "$dock_pref" ]; then
        export PZ_WINDOWS_VM_BOOT_DOCK_ENTRY="$dock_pref"
    fi
    if [ -n "$handheld_pref" ]; then
        export PZ_WINDOWS_VM_BOOT_HANDHELD_ENTRY="$handheld_pref"
    fi
    loader="$(detected_loader)"
    pz_boot_backup_bundle "windows-vm-boot-install-${loader}"
    effective_config
    ensure_share_links 1
    configure_windows_samba_shares
    optimize_libvirt_domain
    install -d /etc/phasezero /usr/share/wayland-sessions /usr/share/xsessions
    # Mesma cópia que `boot sync-runtime` faz sozinha: um caminho só, para o
    # que o hook de pacote executa e o que o install completo executa nunca
    # divergirem. Também resolve o marcador pendente e grava a proveniência,
    # para um runtime vindo de worktree nunca passar por "current" sem rastro.
    sync_boot_runtime_files
    root_env_content > "$ROOT_ENV_FILE"
    chmod 0644 "$ROOT_ENV_FILE"
    session_desktop_content > "$WAYLAND_SESSION_FILE"
    session_desktop_content > "$XSESSION_FILE"
    chmod 0644 "$WAYLAND_SESSION_FILE" "$XSESSION_FILE"
    boot_service_content > "$SERVICE_FILE"
    chmod 0644 "$SERVICE_FILE"
    case "$loader" in
        grub-efi|grub-bios)
            pz_boot_preflight_grub
            pz_boot_validate_active_efi_safe
            grub_script_content > "$GRUB_SCRIPT"
            chmod 0755 "$GRUB_SCRIPT"
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            refresh_grub_config
            pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
            pz_boot_validate_active_efi_safe
            pz_info "PhaseZero Windows VM GRUB boot entry installed (loader=$loader)"
            ;;
        systemd-boot)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        refind)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        efi-stub)
            pz_boot_validate_active_efi_safe
            rm -f "$GRUB_SCRIPT" 2>/dev/null || true
            systemctl daemon-reload
            systemctl enable phasezero-windows-vm-boot-prepare.service >/dev/null
            loader_install_entry "$loader"
            ;;
        *)
            pz_error "unsupported bootloader: $loader"
            return 1
            ;;
    esac
    boot_artifacts_current || {
        pz_error "Windows VM boot artifact validation failed after install (loader=$loader)"
        return 1
    }
    pz_info "PhaseZero Windows VM boot entry installed (loader=$loader)"
}

remove_boot() {
    local loader
    need_root
    pz_boot_require_current_root_target
    loader="$(detected_loader)"
    pz_boot_backup_bundle "windows-vm-boot-remove-${loader}"
    systemctl disable phasezero-windows-vm-boot-prepare.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$GRUB_SCRIPT" "$WAYLAND_SESSION_FILE" "$XSESSION_FILE" "$BOOT_HELPER_TARGET" "$SESSION_TARGET" "$ROOT_ENV_FILE"
    rm -rf "$RUNTIME_ROOT"
    if [ -f "$SDDM_CONF" ] && grep 'PhaseZero managed' "$SDDM_CONF" >/dev/null 2>&1; then
        rm -f "$SDDM_CONF"
    fi
    loader_remove_entry "$loader"
    systemctl daemon-reload
    case "$loader" in
        grub-efi|grub-bios)
            pz_boot_preflight_grub
            refresh_grub_config
            pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
            pz_boot_validate_active_efi_safe
            ;;
        *)
            pz_boot_validate_active_efi_safe
            ;;
    esac
    pz_info "PhaseZero Windows VM boot entry removed (loader=$loader)"
}

ensure_boot_entry_ready() {
    local loader state
    if ! boot_artifacts_current; then
        pz_warn "Windows VM boot files missing or stale; reinstalling"
        install_boot
        return 0
    fi
    loader="$(detected_loader)"
    state="$(loader_entry_state "$loader")"
    if [ "$state" = "missing" ]; then
        pz_warn "Windows VM loader entry missing for $loader; reinstalling"
        loader_install_entry "$loader"
        state="$(loader_entry_state "$loader")"
    fi
    if [ "$state" != "present" ]; then
        pz_error "Windows VM loader entry not confirmed: $state (loader=$loader)"
        return 1
    fi
}

set_next_boot_root() {
    local loader
    pz_boot_require_current_root_target
    loader="$(detected_loader)"
    case "$loader" in
        systemd-boot)
            ensure_boot_entry_ready
            pz_boot_systemd_boot_set_oneshot "$BOOT_ID"
            ;;
        refind)
            ensure_boot_entry_ready
            pz_info "rEFInd: select PhaseZero Windows VM from boot menu manually"
            ;;
        efi-stub)
            ensure_boot_entry_ready
            pz_info "EFI stub: entry should appear in UEFI boot menu as PhaseZero Windows VM"
            ;;
        *)
            command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
            ensure_boot_entry_ready
            grub-reboot "$BOOT_ID"
            ;;
    esac
    pz_info "next boot set to: $BOOT_ENTRY ($BOOT_ID, loader=$loader)"
    pz_info "run: systemctl reboot"
}

set_next_boot() {
    need_root_action next
    set_next_boot_root
}

next_reboot() {
    need_root_action next-reboot
    set_next_boot_root
    pz_info "rebooting into Windows VM"
    systemctl reboot
}

set_default_boot() {
    local loader
    loader="$(detected_loader 2>/dev/null || echo grub-bios)"
    case "$loader" in
        systemd-boot)
            ensure_boot_entry_ready
            if command -v bootctl >/dev/null 2>&1; then
                bootctl set-default "$BOOT_ID" 2>/dev/null || bootctl set-default "$BOOT_ID.conf" 2>/dev/null || true
                pz_warn "permanent systemd-boot default set to: $BOOT_ENTRY"
            else
                pz_error "bootctl missing; cannot set systemd-boot default"
                return 1
            fi
            ;;
        refind)
            local esp
            esp="$(pz_boot_esp_dir 2>/dev/null || true)"
            if [ -n "$esp" ]; then
                pz_warn "rEFInd: set default selection in $esp/EFI/refind/refind.conf (default_selection)"
            else
                pz_warn "rEFInd: set default selection manually (ESP not detected)"
            fi
            ;;
        *)
            need_root_action set-default
            command -v grub-set-default >/dev/null 2>&1 || { pz_error "grub-set-default missing"; return 1; }
            ensure_boot_entry_ready
            grub-set-default "$BOOT_ID"
            pz_warn "permanent GRUB default set to: $BOOT_ENTRY ($BOOT_ID)"
            ;;
    esac
}

clear_next_boot() {
    local loader
    need_root_action clear-next
    loader="$(detected_loader)"
    case "$loader" in
        systemd-boot)
            if command -v bootctl >/dev/null 2>&1; then
                bootctl set-default "" 2>/dev/null || true
            fi
            ;;
        *)
            command -v grub-editenv >/dev/null 2>&1 || { pz_error "grub-editenv missing"; return 1; }
            grub-editenv - unset next_entry >/dev/null 2>&1 || true
            ;;
    esac
    pz_info "cleared one-shot next_entry (loader=$loader)"
}

status_boot() {
    local json=0
    while [ $# -gt 0 ]; do
        case "$1" in --json) json=1; shift ;; *) shift ;; esac
    done

    effective_config
    local loader="" grub_env="" grub_next_entry="" grub_saved_entry="" cmdline_marker="no" artifacts_current="no" artifacts_verification="stale"
    loader="$(detected_loader)"
    grep -w 'phasezero.windowsvm=1' /proc/cmdline >/dev/null 2>&1 && cmdline_marker="yes"
    # Answered without privilege, so an unprivileged caller still learns that a
    # package upgrade left the GRUB boot path on the previous version.
    local boot_runtime_state_value
    boot_runtime_state_value="$(boot_runtime_state)"
    if boot_artifacts_current; then
        artifacts_current="yes"
        artifacts_verification="verified"
    elif [ "$boot_runtime_state_value" = "stale" ]; then
        # Proven stale beats "cannot tell": the runtime comparison alone is
        # enough to know the boot path is outdated.
        artifacts_current="no"
        artifacts_verification="stale"
    elif [ "$EUID" -ne 0 ] && [ ! -x "$(dirname "$GRUB_SCRIPT")" ]; then
        artifacts_current="unknown"
        artifacts_verification="unknown-permission"
    fi
    # grub-editenv list exits 1 when the env block is missing or permission is
    # denied; under set -euo pipefail a pipeline failure must not abort status,
    # and stdout/stderr must not leak partial output. One invocation only, the
    # captured stream is parsed below; rc!=0 renders "unknown-permission" when
    # the error text says so, otherwise "none".
    if command -v grub-editenv >/dev/null 2>&1; then
        if grub_env="$(grub-editenv list 2>&1)"; then
            grub_next_entry="$(printf '%s\n' "$grub_env" | awk -F= '$1 == "next_entry" {print $2; exit}')"
            grub_saved_entry="$(printf '%s\n' "$grub_env" | awk -F= '$1 == "saved_entry" {print $2; exit}')"
        elif printf '%s\n' "$grub_env" | grep -qi 'permission denied'; then
            grub_next_entry="unknown-permission"
            grub_saved_entry="unknown-permission"
        fi
    fi

    local helper_installed="no" session_launcher_installed="no"
    local runtime_launcher_installed="no" runtime_graphics_installed="no"
    local service_installed="no" grub_script="no"
    [ -x "$BOOT_HELPER_TARGET" ] && helper_installed="yes"
    [ -x "$SESSION_TARGET" ] && session_launcher_installed="yes"
    [ -x "$RUNTIME_LAUNCHER" ] && runtime_launcher_installed="yes"
    [ -x "$RUNTIME_GRAPHICS" ] && runtime_graphics_installed="yes"
    [ -f "$SERVICE_FILE" ] && service_installed="yes"
    # /etc/grub.d is root-only on most distributions, so a plain -x test reports
    # a missing script to any unprivileged caller. Distinguish "absent" from
    # "cannot tell" the same way grub_cfg_entry_state does.
    if [ -x "$GRUB_SCRIPT" ]; then
        grub_script="yes"
    elif [ ! -r "$(dirname "$GRUB_SCRIPT")" ] || [ ! -x "$(dirname "$GRUB_SCRIPT")" ]; then
        grub_script="unknown-permission"
    fi
    local service_enabled; service_enabled="$(systemctl is-enabled phasezero-windows-vm-boot-prepare.service 2>/dev/null || echo "disabled")"
    local loader_entry; loader_entry="$(loader_entry_state "$loader")"
    local grub_cfg_entry="n/a"
    [ "$loader" = "grub-efi" ] || [ "$loader" = "grub-bios" ] && grub_cfg_entry="$(grub_cfg_entry_state)"
    local dock_entry handheld_entry touch_input
    touch_input="$(boot_touch_input_state)"
    dock_entry="$(boot_menu_entry_state "$BOOT_DOCK_ENTRY" "$(boot_dock_entry_enabled)")"
    handheld_entry="$(boot_menu_entry_state "$BOOT_HANDHELD_ENTRY" "$(boot_handheld_entry_enabled)")"
    local active_sddm="no"; [ -f "$SDDM_CONF" ] && active_sddm="yes"
    local target_root; target_root="$(pz_boot_target_root)"
    local configured_repo; configured_repo="$(root_env_value PZ_WINDOWS_VM_REPO)"
    local configured_user; configured_user="$(root_env_value PZ_WINDOWS_VM_BOOT_USER)"
    local boot_ready="no" one_shot_ready="no"
    local artifacts_current_json=false
    # bootReady only for a loader whose entry is CONFIRMED present; an
    # unknown/unsupported loader entry must never render ready.
    if [ "$artifacts_current" = "yes" ] && [ "$loader_entry" = "present" ] && [ "$service_enabled" = "enabled" ] && [ "$helper_installed" = "yes" ]; then
        case "$loader" in
            grub-efi|grub-bios|systemd-boot) boot_ready="yes"; one_shot_ready="yes" ;;
            refind) boot_ready="yes" ;;
        esac
    fi
    case "$artifacts_current" in
        yes) artifacts_current_json=true ;;
        unknown) artifacts_current_json=null ;;
    esac

    if [ "$json" = "1" ]; then
        jq -n \
            --arg helper "$BOOT_HELPER_TARGET" \
            --arg helperInstalled "$helper_installed" \
            --arg sessionLauncher "$SESSION_TARGET" \
            --arg sessionLauncherInstalled "$session_launcher_installed" \
            --arg runtimeLauncher "$RUNTIME_LAUNCHER" \
            --arg runtimeLauncherInstalled "$runtime_launcher_installed" \
            --arg runtimeGraphics "$RUNTIME_GRAPHICS" \
            --arg runtimeGraphicsInstalled "$runtime_graphics_installed" \
            --arg serviceFile "$SERVICE_FILE" \
            --arg serviceInstalled "$service_installed" \
            --arg serviceEnabled "$service_enabled" \
            --arg grubScript "$GRUB_SCRIPT" \
            --arg grubScriptExists "$grub_script" \
            --arg bootLoader "$loader" \
            --arg loaderEntry "$loader_entry" \
            --argjson artifactsCurrent "$artifacts_current_json" \
            --arg artifactsVerification "$artifacts_verification" \
            --arg bootRuntimeState "$boot_runtime_state_value" \
            --argjson bootRuntimeStale "$([ "$boot_runtime_state_value" = "stale" ] && echo true || echo false)" \
            --arg hostLoginPolicy "$(root_env_value PZ_WINDOWS_VM_REQUIRE_LOGIN)" \
            --arg guestLoginPolicy "$GUEST_LOGIN_POLICY" \
            --arg configuredRepo "$configured_repo" \
            --arg configuredBootUser "$configured_user" \
            --arg grubCfgEntry "$grub_cfg_entry" \
            --arg dockEntry "$dock_entry" \
            --arg handheldEntry "$handheld_entry" \
            --arg touchInput "$touch_input" \
            --arg grubNextEntry "${grub_next_entry:-none}" \
            --arg grubSavedEntry "${grub_saved_entry:-none}" \
            --arg sddmConf "$SDDM_CONF" \
            --arg activeSddm "$active_sddm" \
            --argjson currentBootWindowsVm "$([ "$cmdline_marker" = "yes" ] && echo true || echo false)" \
            --arg targetUser "$TARGET_USER" \
            --arg targetRoot "$target_root" \
            --arg session "phasezero-windows-vm.desktop" \
            --arg grubEntryId "$BOOT_ID" \
            --argjson bootReady "$([ "$boot_ready" = "yes" ] && echo true || echo false)" \
            --argjson oneShotReady "$([ "$one_shot_ready" = "yes" ] && echo true || echo false)" \
            '{
                helper: $helper, helperInstalled: $helperInstalled,
                sessionLauncher: $sessionLauncher, sessionLauncherInstalled: $sessionLauncherInstalled,
                runtimeLauncher: $runtimeLauncher, runtimeLauncherInstalled: $runtimeLauncherInstalled,
                runtimeGraphics: $runtimeGraphics, runtimeGraphicsInstalled: $runtimeGraphicsInstalled,
                serviceFile: $serviceFile, serviceInstalled: $serviceInstalled, serviceEnabled: $serviceEnabled,
                grubScript: $grubScript, grubScriptExists: $grubScriptExists,
                bootLoader: $bootLoader, loaderEntry: $loaderEntry,
                artifactsCurrent: $artifactsCurrent,
                artifactsVerification: $artifactsVerification,
                bootRuntimeState: $bootRuntimeState,
                bootRuntimeStale: $bootRuntimeStale,
                hostLoginPolicy: (if $hostLoginPolicy == "1" then "password" else "auto" end),
                guestLoginPolicy: $guestLoginPolicy,
                guestLoginVerified: false,
                configuredRepo: $configuredRepo, configuredBootUser: $configuredBootUser,
                grubCfgEntry: $grubCfgEntry,
                dockEntryState: $dockEntry, dockEntryInstalled: ($dockEntry == "present"),
                handheldEntryState: $handheldEntry, handheldEntryInstalled: ($handheldEntry == "present"),
                touchInputState: $touchInput, touchInputApplied: ($touchInput == "applied"),
                grubNextEntry: $grubNextEntry, grubSavedEntry: $grubSavedEntry,
                sddmConf: $sddmConf, activeSddm: $activeSddm,
                currentBootWindowsVm: $currentBootWindowsVm,
                targetUser: $targetUser, targetRoot: $targetRoot,
                session: $session, grubEntryId: $grubEntryId,
                bootReady: $bootReady,
                oneShotReady: $oneShotReady
            }'
    else
        echo "helper: $BOOT_HELPER_TARGET"
        echo "helper_installed: $helper_installed"
        echo "session_launcher_installed: $session_launcher_installed"
        echo "runtime_launcher_installed: $runtime_launcher_installed"
        echo "runtime_graphics_installed: $runtime_graphics_installed"
        echo "service_installed: $service_installed"
        echo "service_enabled: $service_enabled"
        echo "grub_script: $grub_script"
        echo "loader: $loader"
        echo "loader_entry: $loader_entry"
        echo "artifacts_current: $artifacts_current"
        echo "artifacts_verification: $artifacts_verification"
        echo "boot_runtime_state: $boot_runtime_state_value"
        echo "configured_repo: $configured_repo"
        echo "configured_boot_user: $configured_user"
        echo "grub_cfg_entry: $grub_cfg_entry"
        echo "dock_entry: $dock_entry"
        echo "handheld_entry: $handheld_entry"
        echo "touch_input: $touch_input"
        echo "grub_next_entry: ${grub_next_entry:-none}"
        echo "grub_saved_entry: ${grub_saved_entry:-none}"
        echo "active_sddm_windows_vm_conf: $active_sddm"
        echo "current_boot_windows_vm: $cmdline_marker"
        echo "target_user: $TARGET_USER"
        echo "target_root: $target_root"
        echo "session: phasezero-windows-vm.desktop"
        echo "grub_entry_id: $BOOT_ID"
        echo "recommended_direct_boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
        if [ "$boot_runtime_state_value" = "stale" ]; then
            pz_warn "boot runtime is OUTDATED; the GRUB path still runs the previous version"
            pz_warn "run with admin rights: pz windows-vm boot install"
        fi
    fi
}

dry_run_boot() {
    local loader
    loader="$(detected_loader)"
    echo "PhaseZero Windows VM boot dry-run"
    echo "  loader: $loader"
    echo "  helper: $BOOT_HELPER_TARGET"
    echo "  session_launcher: $SESSION_TARGET"
    echo "  runtime_launcher: $RUNTIME_LAUNCHER"
    echo "  runtime_graphics: $RUNTIME_GRAPHICS"
    echo "  service: $SERVICE_FILE"
    echo "  grub: $GRUB_SCRIPT"
    echo "  target_user: $TARGET_USER"
    echo "  root_uuid: $(root_uuid || true)"
    echo "  kernel: $(latest_kernel_version || true)"
    echo "  session: phasezero-windows-vm.desktop"
    echo "  grub entry id: $BOOT_ID"
    if [ "$(boot_dock_entry_enabled)" = "1" ]; then
        echo "  dock entry: enabled (id: $BOOT_DOCK_ID, hotkey: d, always external output)"
    else
        echo "  dock entry: disabled"
    fi
    if [ "$(boot_handheld_entry_enabled)" = "1" ]; then
        echo "  handheld entry: enabled (id: $BOOT_HANDHELD_ID, hotkey: h, always internal panel)"
    else
        echo "  handheld entry: disabled"
    fi
    [ "$loader" = "grub-efi" ] || [ "$loader" = "grub-bios" ] && echo "  grub hotkey: w"
    echo "  one-shot boot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next"
    echo "  one-shot reboot: sudo $PZ_ROOT/linux/windows-vm/windows-vm.sh boot next-reboot"
    echo "  loader override: --loader auto|grub|systemd-boot|refind|efi-stub"
}

cmd_boot() {
    parse_boot_common_args "$@"
    set -- "${PZ_BOOT_PARSED_ARGS[@]}"
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then
        shift || true
    fi
    case "$sub" in
        install) install_boot "$@" ;;
        remove) remove_boot "$@" ;;
        status) status_boot "$@" ;;
        next|set-next) set_next_boot "$@" ;;
        next-reboot|reboot-windows-vm|reboot) next_reboot "$@" ;;
        set-default) set_default_boot "$@" ;;
        clear-next) clear_next_boot "$@" ;;
        dry-run|plan) dry_run_boot "$@" ;;
        runtime-check|check-runtime) runtime_check "$@" ;;
        sync-runtime|resync-runtime) cmd_boot_sync_runtime "$@" ;;
        *) pz_error "usage: windows-vm boot (install|remove|status|runtime-check|sync-runtime|next|next-reboot|set-default|clear-next|dry-run) [--loader auto|grub|systemd-boot|refind|efi-stub] [--target-root /]"; exit 1 ;;
    esac
}

case "$ACTION" in
    status) parse_options "$@"; print_status ;;
    discover|detect) print_discover "$@" ;;
    adopt|use-existing) cmd_adopt "$@" ;;
    remove|delete) cmd_remove "$@" ;;
    plan|dry-run) print_plan "$@" ;;
    install|setup) install_vm "$@" ;;
    optimize|tune) cmd_optimize "$@" ;;
    shares|access) cmd_shares "$@" ;;
    usb-access|usb) cmd_usb_access "$@" ;;
    host-access|guest-disk|browse-guest) bash "$PZ_ROOT/linux/windows-vm/host-access.sh" "$@" ;;
    graphics|gpu) bash "$PZ_ROOT/linux/windows-vm/graphics.sh" "$@" ;;
    apps|frontends|containers) bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" "$@" ;;
    launch|start|run) launch_vm "$@" ;;
    launch-check|launch-preflight) launch_check "$@" ;;
    disk-check|check-disk) disk_check "$@" ;;
    secure-storage|harden-storage) secure_storage "$@" ;;
    guest-login) bash "$PZ_ROOT/linux/windows-vm/guest-login.sh" "$@" ;;
    recover) bash "$PZ_ROOT/linux/windows-vm/recover.sh" "$@" ;;
    boot) cmd_boot "$@" ;;
    media|iso) bash "$PZ_ROOT/linux/windows-vm/media-inspect.sh" "$@" ;;
    # UI-only surface: the native Control Center opens ImageManagerDialog when
    # the user requests the "windows.images.manage" action. This branch keeps a
    # direct CLI call harmless instead of falling through to the usage error.
    images|image)
        echo "Gerenciador de imagens: abra o PhaseZero Control Center em 'Windows VM' -> 'Gerenciar imagens'."
        ;;
    preflight|check|readiness) bash "$PZ_ROOT/linux/windows-vm/preflight.sh" "$@" ;;
    provision|provisioning|install-auto) bash "$PZ_ROOT/linux/windows-vm/provision.sh" "$@" ;;
    help|--help|-h|"") usage ;;
    *) pz_error "usage: windows-vm (status|discover|adopt|remove|plan|install|optimize|shares|usb-access|host-access|graphics|apps|launch|launch-check|disk-check|secure-storage|guest-login|recover|boot|media|images|preflight|provision)"; exit 1 ;;
esac
