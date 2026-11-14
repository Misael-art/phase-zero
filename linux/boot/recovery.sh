#!/usr/bin/env bash
# recovery.sh - PhaseZero GRUB recovery card, EFI fallback and one-shot emergency shell
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --target-root)
            [ -n "${2:-}" ] || { pz_error "--target-root requires a path"; exit 1; }
            export PZ_BOOT_TARGET_ROOT="$2"
            shift 2
            ;;
        --target-root=*)
            export PZ_BOOT_TARGET_ROOT="${1#*=}"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${ARGS[@]}"

ACTION="${1:-status}"
BOOT_ENTRY="PhaseZero Emergency Root Shell"
BOOT_ID="phasezero-emergency-shell"
EMERGENCY_GRUB_SCRIPT="$(pz_boot_path /etc/grub.d/45_phasezero_emergency_shell)"
SAFE_MENU_DROPIN="$(pz_boot_path /etc/default/grub.d/10-phasezero-safe-menu.cfg)"
RECOVERY_DIR="$(pz_boot_path /var/lib/phasezero/boot-recovery)"
RECOVERY_CARD="$RECOVERY_DIR/grub-rescue.txt"
ESP_DIR="$(pz_boot_esp_dir)"
PHASEZERO_EFI_DIR="$ESP_DIR/EFI/PhaseZero"
PHASEZERO_EFI="$PHASEZERO_EFI_DIR/grubx64.efi"
FALLBACK_EFI="$ESP_DIR/EFI/boot/bootx64.efi"
ISO_BOOT="$PZ_ROOT/linux/boot/iso-boot.sh"
KDE_LOGIN="$PZ_ROOT/linux/boot/kde-autologin.sh"

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    pz_error "root required. run: sudo $PZ_ROOT/linux/pz boot $ACTION"
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

root_fs_module() {
    local fstype
    fstype="$(pz_boot_root_fstype || true)"
    case "$fstype" in
        btrfs) echo btrfs ;;
        ext2|ext3|ext4) echo ext2 ;;
        xfs) echo xfs ;;
        f2fs) echo f2fs ;;
        *) echo "${PZ_BOOT_GRUB_FS_MODULE:-btrfs}" ;;
    esac
}

boot_grub_relpath() {
    pz_boot_grub_relpath
}

kernel_relpath() {
    local version
    version="$(latest_kernel_version)"
    [ -n "$version" ] || return 1
    pz_boot_file_relpath "/boot/vmlinuz-$version"
}

initrd_relpath() {
    local version
    version="$(latest_kernel_version)"
    [ -n "$version" ] || return 1
    pz_boot_file_relpath "/boot/initramfs-$version.img"
}

microcode_initrd_args() {
    local amd="" intel=""
    amd="$(if [ -f "$(pz_boot_path /boot/amd-ucode.img)" ]; then pz_boot_file_relpath /boot/amd-ucode.img || true; fi)"
    intel="$(if [ -f "$(pz_boot_path /boot/intel-ucode.img)" ]; then pz_boot_file_relpath /boot/intel-ucode.img || true; fi)"
    printf '%s %s' "$amd" "$intel"
}

bootstrap_config_content() {
    local uuid fs_module grub_rel
    uuid="$(root_uuid)"
    fs_module="$(root_fs_module)"
    grub_rel="$(boot_grub_relpath)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    cat <<EOF
insmod part_gpt
insmod $fs_module
insmod search
insmod search_fs_uuid
search --no-floppy --fs-uuid --set=root $uuid
set prefix=(\$root)$grub_rel
configfile (\$root)$grub_rel/grub.cfg
EOF
}

recovery_card_content() {
    local uuid fs_module grub_rel kernel_rel initrd_rel subvol rootflags="" microcode
    uuid="$(root_uuid)"
    fs_module="$(root_fs_module)"
    grub_rel="$(boot_grub_relpath)"
    kernel_rel="$(kernel_relpath 2>/dev/null || true)"
    initrd_rel="$(initrd_relpath 2>/dev/null || true)"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"
    microcode="$(microcode_initrd_args)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }

    cat <<EOF
PhaseZero GRUB rescue card
Generated: $(date -Iseconds)

Purpose:
  Use these commands at a "grub rescue>" prompt when GRUB lost its prefix.

Preferred commands:
  insmod part_gpt
  insmod $fs_module
  insmod search
  insmod search_fs_uuid
  search --no-floppy --fs-uuid --set=root $uuid
  set prefix=(\$root)$grub_rel
  insmod normal
  normal

If normal mode still fails, try direct Linux boot from GRUB prompt:
  insmod part_gpt
  insmod $fs_module
  insmod search
  insmod search_fs_uuid
  search --no-floppy --fs-uuid --set=root $uuid
  linux $kernel_rel root=UUID=$uuid rw$rootflags
  initrd $microcode $initrd_rel
  boot

Notes:
  Do not use disk ordinals like (hd6,gpt2) as source of truth.
  Prefer UUID search above because firmware disk order can change.
EOF
}

emergency_grub_script_content() {
    local uuid kernel_rel initrd_rel fs_module subvol rootflags="" microcode
    uuid="$(root_uuid)"
    kernel_rel="$(kernel_relpath)"
    initrd_rel="$(initrd_relpath)"
    fs_module="$(root_fs_module)"
    subvol="$(root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"
    microcode="$(microcode_initrd_args)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }

    cat <<EOF
#!/usr/bin/env bash
exec tail -n +3 "\$0"
# PhaseZero managed emergency entry. Remove with: linux/pz boot emergency-shell clear
menuentry '$BOOT_ENTRY' --id='$BOOT_ID' --hotkey=e --class recovery --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod $fs_module
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero emergency root shell...'
    echo 'Filesystem will start read-only; remount rw only if needed.'
    linux $kernel_rel root=UUID=$uuid ro$rootflags systemd.unit=rescue.target
    initrd $microcode $initrd_rel
}
EOF
}

validate_efi_safe() {
    local path="$1"
    pz_boot_validate_efi_safe "$path"
}

safe_menu_timeout() {
    local timeout="${PZ_GRUB_SAFE_MENU_TIMEOUT:-20}"
    case "$timeout" in
        ""|*[!0-9]*) pz_error "PZ_GRUB_SAFE_MENU_TIMEOUT must be an integer"; return 1 ;;
    esac
    if [ "$timeout" -lt 3 ] || [ "$timeout" -gt 60 ]; then
        pz_error "PZ_GRUB_SAFE_MENU_TIMEOUT must be between 3 and 60 seconds"
        return 1
    fi
    echo "$timeout"
}

safe_menu_timeout_from_file() {
    [ -r "$SAFE_MENU_DROPIN" ] || return 0
    awk -F= '$1 == "GRUB_TIMEOUT" {print $2; exit}' "$SAFE_MENU_DROPIN"
}

safe_menu_dropin_content() {
    local timeout
    timeout="$(safe_menu_timeout)"
    cat <<EOF
# PhaseZero managed: safe GRUB menu visibility for Steam Deck.
# Keeps the menu selectable without global input, preload, or video overrides.
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=$timeout
GRUB_RECORDFAIL_TIMEOUT=$timeout
EOF
}

cmd_install_safe_menu() {
    need_root
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    pz_boot_backup_bundle "boot-safe-menu"
    install -d "$(dirname "$SAFE_MENU_DROPIN")"
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    safe_menu_dropin_content > "$tmp"
    install -m 0644 "$tmp" "$SAFE_MENU_DROPIN"
    rm -f "$tmp"
    if command -v grub-editenv >/dev/null 2>&1; then
        grub-editenv - unset menu_auto_hide >/dev/null 2>&1 || true
        grub-editenv - unset menu_show_once >/dev/null 2>&1 || true
    fi
    pz_boot_refresh_grub_config /boot/grub/grub.cfg
    pz_boot_validate_grub_cfg_safe /boot/grub/grub.cfg
    pz_boot_validate_active_efi_safe
    pz_info "safe GRUB menu profile installed: $SAFE_MENU_DROPIN"
}

cmd_remove_safe_menu() {
    need_root
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    pz_boot_backup_bundle "boot-safe-menu-remove"
    rm -f "$SAFE_MENU_DROPIN"
    pz_boot_refresh_grub_config /boot/grub/grub.cfg
    pz_boot_validate_grub_cfg_safe /boot/grub/grub.cfg
    pz_boot_validate_active_efi_safe
    pz_info "safe GRUB menu profile removed"
}

cmd_safe_menu() {
    local sub="${1:-status}" state
    state="$(pz_boot_file_state "$SAFE_MENU_DROPIN")"
    case "$sub" in
        status)
            case "$state" in
                present) echo "installed $(safe_menu_timeout_from_file || true)" ;;
                permission-denied) echo "permission-denied" ;;
                *) echo "missing" ;;
            esac
            ;;
        install|repair) cmd_install_safe_menu ;;
        remove|clear) cmd_remove_safe_menu ;;
        dry-run|plan) safe_menu_dropin_content ;;
        *) pz_error "usage: linux/pz boot safe-menu (status|install|remove|dry-run)"; return 1 ;;
    esac
}

cmd_status() {
    local phasezero_state active_path active_state safe_menu_state safe_menu_timeout_value
    phasezero_state="$(pz_boot_file_state "$PHASEZERO_EFI")"
    active_path="$(pz_boot_active_efi_path 2>/dev/null || true)"
    active_state=""
    [ -n "$active_path" ] && active_state="$(pz_boot_efi_prefix_state "$active_path")"
    safe_menu_state="$(pz_boot_file_state "$SAFE_MENU_DROPIN")"
    safe_menu_timeout_value="$(safe_menu_timeout_from_file || true)"
    echo "PhaseZero boot recovery status"
    echo "  target_root: $(pz_boot_target_root)"
    echo "  root_uuid: $(root_uuid || true)"
    echo "  root_subvol: $(root_subvol || true)"
    echo "  root_fs_module: $(root_fs_module || true)"
    echo "  kernel: $(latest_kernel_version || true)"
    echo "  boot_grub: $(boot_grub_relpath || true)"
    [ -f "$RECOVERY_CARD" ] && echo "  recovery_card: $RECOVERY_CARD" || echo "  recovery_card: missing"
    case "$phasezero_state" in
        present) echo "  phasezero_efi: $PHASEZERO_EFI" ;;
        permission-denied) echo "  phasezero_efi: permission-denied ($PHASEZERO_EFI)" ;;
        *) echo "  phasezero_efi: missing" ;;
    esac
    if [ -n "$active_path" ]; then
        echo "  active_efi: $active_path"
        echo "  active_efi_prefix: ${active_state:-unknown}"
    else
        echo "  active_efi: unknown"
        echo "  active_efi_prefix: unknown"
    fi
    case "$safe_menu_state" in
        present)
            echo "  safe_menu_profile: installed ($SAFE_MENU_DROPIN)"
            echo "  safe_menu_timeout: ${safe_menu_timeout_value:-unknown}"
            ;;
        permission-denied) echo "  safe_menu_profile: permission-denied ($SAFE_MENU_DROPIN)" ;;
        *) echo "  safe_menu_profile: missing" ;;
    esac
    [ -x "$EMERGENCY_GRUB_SCRIPT" ] && echo "  emergency_shell_entry: installed" || echo "  emergency_shell_entry: missing"
    if [ -f "$ISO_BOOT" ]; then
        bash "$ISO_BOOT" summary | sed '1d; s/^  /  dynamic_/'
    else
        echo "  dynamic_iso_boot: unavailable"
    fi
}

cmd_card() {
    recovery_card_content
}

cmd_install_card() {
    need_root
    pz_boot_preflight_grub
    pz_boot_backup_bundle "boot-recovery-card"
    install -d "$RECOVERY_DIR"
    recovery_card_content > "$RECOVERY_CARD"
    chmod 0600 "$RECOVERY_CARD"
    if [ -d "$ESP_DIR/EFI" ]; then
        install -d "$ESP_DIR/EFI/PhaseZero"
        recovery_card_content > "$ESP_DIR/EFI/PhaseZero/grub-rescue.txt"
        chmod 0644 "$ESP_DIR/EFI/PhaseZero/grub-rescue.txt"
    fi
    pz_info "recovery card installed: $RECOVERY_CARD"
}

cmd_install_efi_fallback() {
    need_root
    pz_boot_preflight_grub
    command -v grub-mkstandalone >/dev/null 2>&1 || { pz_error "grub-mkstandalone missing"; return 1; }
    [ -d "$ESP_DIR/EFI" ] || { pz_error "ESP not mounted at $ESP_DIR"; return 1; }
    local install_fallback=0 install_active=0 active_path="" arg tmp
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --fallback|--write-fallback) install_fallback=1 ;;
            --active|--write-active) install_active=1 ;;
            --active-path=*) active_path="${arg#*=}"; install_active=1 ;;
            *) pz_error "usage: linux/pz boot install-efi-fallback [--active] [--active-path PATH] [--fallback]"; return 1 ;;
        esac
    done

    pz_boot_backup_bundle "boot-efi-fallback"
    # shellcheck disable=SC2119 # pz_tempfile template arg optional; default mktemp template intended
    tmp="$(pz_tempfile)"
    bootstrap_config_content > "$tmp"
    install -d "$PHASEZERO_EFI_DIR"
    grub-mkstandalone \
        -O x86_64-efi \
        -o "$PHASEZERO_EFI" \
        --modules="part_gpt $(root_fs_module) search search_fs_uuid configfile normal" \
        "/boot/grub/grub.cfg=$tmp"
    rm -f "$tmp"
    validate_efi_safe "$PHASEZERO_EFI"

    if [ "$install_active" = "1" ]; then
        if [ -z "$active_path" ]; then
            active_path="$(pz_boot_active_efi_path 2>/dev/null || true)"
        fi
        [ -n "$active_path" ] || { pz_error "active EFI loader path not detected; use --active-path=/boot/efi/EFI/<vendor>/grubx64.efi"; return 1; }
        install -d "$(dirname "$active_path")"
        cp -a "$PHASEZERO_EFI" "$active_path"
        validate_efi_safe "$active_path"
        pz_warn "active EFI updated: $active_path"
    fi

    if [ "$install_fallback" = "1" ]; then
        install -d "$(dirname "$FALLBACK_EFI")"
        cp -a "$PHASEZERO_EFI" "$FALLBACK_EFI"
        validate_efi_safe "$FALLBACK_EFI"
        pz_warn "fallback EFI updated: $FALLBACK_EFI"
    else
        pz_info "fallback EFI not overwritten; rerun with --fallback to update $FALLBACK_EFI"
    fi
    pz_info "PhaseZero standalone EFI installed: $PHASEZERO_EFI"
}

cmd_emergency_next() {
    need_root
    pz_boot_preflight_grub
    command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
    pz_boot_backup_bundle "boot-emergency-shell-next"
    emergency_grub_script_content > "$EMERGENCY_GRUB_SCRIPT"
    chmod 0755 "$EMERGENCY_GRUB_SCRIPT"
    pz_boot_require_current_root_target
    pz_boot_refresh_grub_config /boot/grub/grub.cfg
    pz_boot_validate_grub_cfg_safe /boot/grub/grub.cfg
    grep -Fq "menuentry '$BOOT_ENTRY'" /boot/grub/grub.cfg || { pz_error "emergency menuentry missing after grub refresh"; return 1; }
    grub-reboot "$BOOT_ID"
    pz_warn "one-shot emergency rescue boot set: $BOOT_ENTRY ($BOOT_ID)"
    pz_warn "clear with: sudo $PZ_ROOT/linux/pz boot emergency-shell clear"
}

cmd_emergency_clear() {
    need_root
    pz_boot_preflight_grub
    pz_boot_backup_bundle "boot-emergency-shell-clear"
    rm -f "$EMERGENCY_GRUB_SCRIPT"
    if command -v grub-editenv >/dev/null 2>&1; then
        grub-editenv - unset next_entry >/dev/null 2>&1 || true
    fi
    pz_boot_require_current_root_target
    pz_boot_refresh_grub_config /boot/grub/grub.cfg
    pz_boot_validate_grub_cfg_safe /boot/grub/grub.cfg
    pz_info "emergency shell entry cleared"
}

cmd_emergency() {
    local sub="${1:-status}"
    case "$sub" in
        status) [ -x "$EMERGENCY_GRUB_SCRIPT" ] && echo installed || echo missing ;;
        next|set-next) cmd_emergency_next ;;
        clear|remove) cmd_emergency_clear ;;
        dry-run|plan)
            echo "PhaseZero emergency shell dry-run"
            echo "  entry: $EMERGENCY_GRUB_SCRIPT"
            echo "  boot: one-shot via grub-reboot"
            echo "  kernel: $(latest_kernel_version || true)"
            ;;
        *) pz_error "usage: linux/pz boot emergency-shell (status|next|clear|dry-run)"; return 1 ;;
    esac
}

boot_menu_text() {
    cat <<'EOF'
PhaseZero boot choices
  normal        Clear one-shot boot and keep distro default
  steamos       Next boot: SteamOS/Gamepad UI session
  windows       Next boot: Windows VM session
  waydroid      Next boot: Waydroid Android session
  emergency     Next boot: rescue.target root shell
  iso:<id>      Next boot: registered local ISO
  usb:<id>      Next boot: registered removable EFI
  grubfm        Next boot: experimental ISO explorer

Use:
  linux/pz boot choose <choice>
  linux/pz boot choose <choice> --dry-run
  linux/pz boot choose <choice> --reboot
  linux/pz boot selector

GRUB hotkeys when keyboard input works:
  s SteamOS, w Windows VM, a Waydroid, e Emergency

Steam Deck note:
  D-pad/analog input in GRUB depends on firmware and is not reliable.
  Install the safe visible GRUB menu with: sudo linux/pz boot install-safe-menu
  Prefer this Linux-side selector or desktop launchers before reboot.
EOF
}

boot_choice_id() {
    case "$1" in
        normal|default|linux|biglinux) printf '%s\n' "" ;;
        steamos|steam|gamepad) printf '%s\n' "phasezero-steamos" ;;
        windows|windows-vm|win) printf '%s\n' "phasezero-windows-vm" ;;
        waydroid|android) printf '%s\n' "phasezero-waydroid" ;;
        emergency|rescue) printf '%s\n' "phasezero-emergency-shell" ;;
        iso:*) pz_boot_valid_id "${1#iso:}" && printf 'phasezero-iso-%s\n' "${1#iso:}" || return 1 ;;
        usb:*) pz_boot_valid_id "${1#usb:}" && printf 'phasezero-removable-%s\n' "${1#usb:}" || return 1 ;;
        grubfm|iso-explorer) printf '%s\n' "phasezero-grubfm" ;;
        *) return 1 ;;
    esac
}

boot_next_entry() {
    command -v grub-editenv >/dev/null 2>&1 || return 1
    grub-editenv list 2>/dev/null | awk -F= '$1 == "next_entry" {print $2; exit}'
}

validate_next_entry() {
    local expected="$1" actual
    command -v grub-editenv >/dev/null 2>&1 || { pz_warn "grub-editenv missing; next_entry validation skipped"; return 0; }
    actual="$(boot_next_entry || true)"
    if [ -z "$expected" ]; then
        [ -z "$actual" ] || { pz_error "next_entry validation failed: expected empty, got $actual"; return 1; }
    else
        [ "$actual" = "$expected" ] || { pz_error "next_entry validation failed: expected $expected, got ${actual:-empty}"; return 1; }
    fi
    pz_info "next_entry validated: ${actual:-default}"
}

cmd_selector() {
    if [ -x "$PZ_ROOT/linux/ui/native.sh" ]; then
        exec "$PZ_ROOT/linux/ui/native.sh" --boot-selector
    fi
    if command -v python3 >/dev/null 2>&1; then
        cd "$PZ_ROOT"
        exec python3 -m linux.ui_native --boot-selector
    fi
    pz_error "native UI unavailable; use: linux/pz boot menu"
    return 1
}

cmd_menu() {
    local choice
    if [ -t 0 ] && [ -z "${PZ_BOOT_MENU_PRINT_ONLY:-}" ]; then
        boot_menu_text
        printf 'choice> '
        read -r choice
        [ -n "$choice" ] || return 0
        cmd_choose "$choice"
    else
        boot_menu_text
    fi
}

cmd_choose() {
    local choice="${1:-}" reboot=0 dry_run=0 arg expected
    [ -n "$choice" ] || { pz_error "usage: linux/pz boot choose (normal|steamos|windows|waydroid|emergency|iso:<id>|usb:<id>|grubfm) [--dry-run] [--reboot]"; return 1; }
    shift || true
    for arg in "$@"; do
        case "$arg" in
            --reboot) reboot=1 ;;
            --dry-run|-n) dry_run=1 ;;
            *) pz_error "usage: linux/pz boot choose (normal|steamos|windows|waydroid|emergency|iso:<id>|usb:<id>|grubfm) [--dry-run] [--reboot]"; return 1 ;;
        esac
    done
    expected="$(boot_choice_id "$choice")" || { pz_error "unknown boot choice: $choice"; return 1; }
    if [ "$dry_run" = "1" ]; then
        echo "PhaseZero boot choose dry-run"
        echo "  choice: $choice"
        echo "  next_entry: ${expected:-default}"
        echo "  would_reboot: $([ "$reboot" = "1" ] && echo yes || echo no)"
        return 0
    fi

    case "$choice" in
        normal|default|linux|biglinux)
            need_root
            pz_boot_require_current_root_target
            command -v grub-editenv >/dev/null 2>&1 || { pz_error "grub-editenv missing"; return 1; }
            grub-editenv - unset next_entry >/dev/null 2>&1 || true
            pz_info "one-shot GRUB entry cleared; next boot uses distro default"
            ;;
        steamos|steam|gamepad)
            bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" next
            ;;
        windows|windows-vm|win)
            bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" boot next
            ;;
        waydroid|android)
            bash "$PZ_ROOT/linux/waydroid/waydroid.sh" boot next
            ;;
        emergency|rescue)
            cmd_emergency_next
            ;;
        iso:*)
            bash "$ISO_BOOT" iso next "${choice#iso:}"
            ;;
        usb:*)
            bash "$ISO_BOOT" usb next "${choice#usb:}"
            ;;
        grubfm|iso-explorer)
            bash "$ISO_BOOT" grubfm next
            ;;
        *)
            pz_error "unknown boot choice: $choice"
            return 1
            ;;
    esac
    validate_next_entry "$expected"

    if [ "$reboot" = "1" ]; then
        pz_info "rebooting"
        systemctl reboot
    fi
}

case "$ACTION" in
    status) cmd_status ;;
    safe-menu) shift || true; cmd_safe_menu "${1:-status}" ;;
    install-safe-menu|repair-safe-menu) cmd_install_safe_menu ;;
    remove-safe-menu|clear-safe-menu) cmd_remove_safe_menu ;;
    card|recovery-card|grub-rescue-card) cmd_card ;;
    install-card|install-recovery-card) cmd_install_card ;;
    install-efi-fallback|efi-fallback|repair-active-efi) cmd_install_efi_fallback "$@" ;;
    emergency-shell|emergency) shift || true; cmd_emergency "${1:-status}" ;;
    iso|usb|removable|grubfm|catalog)
        exec bash "$ISO_BOOT" "$ACTION" "${@:2}"
        ;;
    kde-login|kde-autologin)
        exec bash "$KDE_LOGIN" "${@:2}"
        ;;
    vibe-code)
        pz_boot_require_current_root_target
        exec bash "$PZ_ROOT/linux/boot/vibe-code.sh" "${@:2}"
        ;;
    selector|visual-selector|gui) cmd_selector ;;
    menu|choices|select) cmd_menu ;;
    choose|next) shift || true; cmd_choose "$@" ;;
    *) pz_error "usage: linux/pz boot (status|menu|selector|choose|kde-login|vibe-code|iso|usb|grubfm|safe-menu|install-safe-menu|card|install-card|install-efi-fallback [--active] [--fallback]|emergency-shell)"; exit 1 ;;
esac
