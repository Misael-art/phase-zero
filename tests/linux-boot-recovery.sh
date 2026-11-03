#!/usr/bin/env bash
# Smoke tests for PhaseZero Linux boot recovery tooling.

assert_grep_absent() {
    local label="$1"
    shift
    if grep -q "$@"; then
        echo "FAIL: $label" >&2
        exit 1
    fi
}
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$REPO_ROOT/linux/pz" "$REPO_ROOT/linux/lib/common.sh" "$REPO_ROOT/linux/boot/recovery.sh" "$REPO_ROOT/linux/boot/iso-boot.sh"

"$REPO_ROOT/linux/pz" boot status >/dev/null
menu_output="$(PZ_BOOT_MENU_PRINT_ONLY=1 "$REPO_ROOT/linux/pz" boot menu)"
grep -q 'PhaseZero boot choices' <<< "$menu_output"
grep -q 'linux/pz boot choose <choice>' <<< "$menu_output"
grep -q 'linux/pz boot choose <choice> --dry-run' <<< "$menu_output"
grep -q 'linux/pz boot selector' <<< "$menu_output"
grep -q 's SteamOS, w Windows VM, a Waydroid, e Emergency' <<< "$menu_output"
grep -q 'install-safe-menu' <<< "$menu_output"
grep -q 'iso:<id>' <<< "$menu_output"
grep -q 'usb:<id>' <<< "$menu_output"
grep -q 'grubfm' <<< "$menu_output"
dry_run_output="$("$REPO_ROOT/linux/pz" boot choose windows --dry-run)"
grep -q 'PhaseZero boot choose dry-run' <<< "$dry_run_output"
grep -q 'next_entry: phasezero-windows-vm' <<< "$dry_run_output"
grep -q 'would_reboot: no' <<< "$dry_run_output"
dry_run_reboot_output="$("$REPO_ROOT/linux/pz" boot choose waydroid --dry-run --reboot)"
grep -q 'next_entry: phasezero-waydroid' <<< "$dry_run_reboot_output"
grep -q 'would_reboot: yes' <<< "$dry_run_reboot_output"
iso_dry_run="$("$REPO_ROOT/linux/pz" boot choose iso:arch-rescue --dry-run)"
grep -q 'next_entry: phasezero-iso-arch-rescue' <<< "$iso_dry_run"
usb_dry_run="$("$REPO_ROOT/linux/pz" boot choose usb:ventoy --dry-run)"
grep -q 'next_entry: phasezero-removable-ventoy' <<< "$usb_dry_run"
grubfm_dry_run="$("$REPO_ROOT/linux/pz" boot choose grubfm --dry-run)"
grep -q 'next_entry: phasezero-grubfm' <<< "$grubfm_dry_run"
target_status="$("$REPO_ROOT/linux/pz" boot status --target-root /)"
grep -q 'target_root: /' <<< "$target_status"
emergency_plan="$("$REPO_ROOT/linux/pz" boot emergency-shell dry-run)"
grep -q 'one-shot via grub-reboot' <<< "$emergency_plan"
safe_menu_plan="$("$REPO_ROOT/linux/pz" boot safe-menu dry-run)"
grep -q 'GRUB_TIMEOUT_STYLE=menu' <<< "$safe_menu_plan"
grep -q 'GRUB_TIMEOUT=20' <<< "$safe_menu_plan"
grep -q 'GRUB_RECORDFAIL_TIMEOUT=20' <<< "$safe_menu_plan"

grep -q 'cmd_boot' "$REPO_ROOT/linux/pz"
grep -q 'install-safe-menu' "$REPO_ROOT/linux/pz"
grep -q '10-phasezero-safe-menu.cfg' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'GRUB_TIMEOUT_STYLE=menu' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'GRUB_RECORDFAIL_TIMEOUT' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'unset menu_auto_hide' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'install-efi-fallback' "$REPO_ROOT/linux/pz"
grep -q 'grub-mkstandalone' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q -- '--active' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q "BOOT_ID=\"phasezero-emergency-shell\"" "$REPO_ROOT/linux/boot/recovery.sh"
grep -q -- "--hotkey=e" "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'boot choose' "$REPO_ROOT/linux/pz"
grep -q 'boot selector' "$REPO_ROOT/linux/pz"
grep -q 'cmd_selector' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'validate_next_entry' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'search --no-floppy --fs-uuid --set=root' "$REPO_ROOT/linux/boot/recovery.sh"
# shellcheck disable=SC2016 # literal grep pattern
grep -q 'configfile (\\$root)' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'systemd.unit=rescue.target' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'pz_boot_preflight_grub' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'pz_boot_backup_bundle "boot-efi-fallback"' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q 'iso-boot.sh' "$REPO_ROOT/linux/boot/recovery.sh"
# shellcheck disable=SC2016 # literal grep pattern
grep -q '\[ -f "$ISO_BOOT" \]' "$REPO_ROOT/linux/boot/recovery.sh"
grep -q '46_phasezero_iso_loopback' "$REPO_ROOT/linux/boot/iso-boot.sh"
grep -q '47_phasezero_removable_efi' "$REPO_ROOT/linux/boot/iso-boot.sh"
grep -q '48_phasezero_grubfm' "$REPO_ROOT/linux/boot/iso-boot.sh"

assert_grep_absent "recovery.sh contains init=/bin/bash" 'init=/bin/bash' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains GRUB_TERMINAL_INPUT=" 'GRUB_TERMINAL_INPUT=' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains usb_keyboard" 'usb_keyboard' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains at_keyboard" 'at_keyboard' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains GRUB_GFXPAYLOAD_LINUX=keep" 'GRUB_GFXPAYLOAD_LINUX=keep' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains fbcon=rotate" 'fbcon=rotate' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "recovery.sh contains video=.*rotate" -E 'video=.*rotate' "$REPO_ROOT/linux/boot/recovery.sh"
assert_grep_absent "install-steamos-boot.sh contains GRUB_GFXPAYLOAD_LINUX=keep" 'GRUB_GFXPAYLOAD_LINUX=keep' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
assert_grep_absent "install-steamos-boot.sh contains fbcon=rotate" 'fbcon=rotate' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"
assert_grep_absent "install-steamos-boot.sh contains video=.*rotate" -E 'video=.*rotate' "$REPO_ROOT/linux/steamdeck/install-steamos-boot.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
test_sddm="$tmp_root/sddm"
test_sessions="$tmp_root/sessions"
mkdir -p "$test_sddm" "$test_sessions"
chmod 0700 "$test_sddm"
printf '[Desktop Entry]\nExec=true\n' > "$test_sessions/plasma.desktop"
plan="$(PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    "$REPO_ROOT/linux/pz" boot kde-login plan enable)"
grep -qx "user: $(id -un)" <<< "$plan"
grep -qx 'relogin: true' <<< "$plan"
printf '[Autologin]\nUser=guest\nSession=phasezero-windows-vm.desktop\nRelogin=false\n' > "$test_sddm/91-phasezero-windows-vm.conf"
PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    "$REPO_ROOT/linux/pz" boot kde-login enable >/dev/null
[ "$(stat -c %a "$test_sddm")" = 700 ]
grep -qx "User=$(id -un)" "$test_sddm/50-phasezero-kde-autologin.conf"
grep -qx 'Session=plasma.desktop' "$test_sddm/50-phasezero-kde-autologin.conf"
grep -qx 'Relogin=true' "$test_sddm/50-phasezero-kde-autologin.conf"
grep -qx 'Session=phasezero-windows-vm.desktop' "$test_sddm/91-phasezero-windows-vm.conf"
kde_login_status="$(PZ_SDDM_CONF_DIR="$test_sddm" "$REPO_ROOT/linux/pz" boot kde-login status)"
grep -q 'kde_login: enabled' <<< "$kde_login_status"
PZ_SDDM_CONF_DIR="$test_sddm" "$REPO_ROOT/linux/pz" boot kde-login disable >/dev/null
[ ! -e "$test_sddm/50-phasezero-kde-autologin.conf" ]
[ -e "$test_sddm/91-phasezero-windows-vm.conf" ]
printf '[Autologin]\nUser=guest\n' > "$test_sddm/kde_settings.conf"
if PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    "$REPO_ROOT/linux/pz" boot kde-login enable > "$tmp_root/override.out" 2>&1; then
    echo 'later SDDM autologin override was accepted' >&2; exit 1
fi
grep -q 'overridden by' "$tmp_root/override.out"
[ ! -e "$test_sddm/50-phasezero-kde-autologin.conf" ]
rm "$test_sddm/kde_settings.conf"
if PZ_TARGET_USER=root PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    "$REPO_ROOT/linux/pz" boot kde-login enable > "$tmp_root/identity.out" 2>&1; then
    echo 'root account was accepted for KDE autologin' >&2; exit 1
fi
[ ! -e "$test_sddm/50-phasezero-kde-autologin.conf" ]
printf 'unmanaged\n' > "$test_sddm/50-phasezero-kde-autologin.conf"
if PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$test_sessions" \
    "$REPO_ROOT/linux/pz" boot kde-login enable > "$tmp_root/conflict.out" 2>&1; then
    echo 'unmanaged KDE login file was replaced' >&2; exit 1
fi
grep -qx unmanaged "$test_sddm/50-phasezero-kde-autologin.conf"
if PZ_SDDM_CONF_DIR="$test_sddm" "$REPO_ROOT/linux/pz" boot kde-login disable > "$tmp_root/conflict.out" 2>&1; then
    echo 'unmanaged KDE login file was removed' >&2; exit 1
fi
grep -qx unmanaged "$test_sddm/50-phasezero-kde-autologin.conf"
rm "$test_sddm/50-phasezero-kde-autologin.conf"
if PZ_SDDM_CONF_DIR="$test_sddm" PZ_WAYLAND_SESSION_DIR="$tmp_root/missing" \
    "$REPO_ROOT/linux/pz" boot kde-login enable > "$tmp_root/missing.out" 2>&1; then
    echo 'missing KDE session was accepted' >&2; exit 1
fi
[ ! -e "$test_sddm/50-phasezero-kde-autologin.conf" ]
printf '%s\n' 'grub-probe: error: cannot find a GRUB drive for /dev/sdg1.  Check your device.map.' > "$tmp_root/os-prober-warning.log"
if bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_grub_log_has_fatal_errors '$tmp_root/os-prober-warning.log'"; then
    echo "known os-prober hybrid-media warning was treated as fatal" >&2
    exit 1
fi
printf '%s\n' 'grub-mkconfig: error: syntax failure' > "$tmp_root/fatal-grub.log"
bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_grub_log_has_fatal_errors '$tmp_root/fatal-grub.log'"
printf '%s\n' '(,gpt2)/@/boot/grub' > "$tmp_root/dangerous-a.efi"
printf '%s\n' '(hd6,gpt2)/@/boot/grub' > "$tmp_root/dangerous-b.efi"
printf '%s\n' '(hd0,gpt1)/boot/grub2/sealed.tpm' > "$tmp_root/generic-help.efi"
bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/dangerous-a.efi'"
bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/dangerous-b.efi'"
if bash -c ". '$REPO_ROOT/linux/lib/common.sh'; pz_boot_efi_has_dangerous_prefix '$tmp_root/generic-help.efi'"; then
    echo "generic GRUB help text was treated as dangerous" >&2
    exit 1
fi
if bash -c ". '$REPO_ROOT/linux/lib/common.sh'; export PZ_BOOT_TARGET_ROOT='$tmp_root'; pz_boot_require_current_root_target" >/tmp/phasezero-target-root-test.out 2>&1; then
    echo "expected non-/ target root mutation guard to fail" >&2
    exit 1
fi
grep -q 'target-root mutation must run inside target chroot' /tmp/phasezero-target-root-test.out

if [ "$(findmnt -no FSTYPE / 2>/dev/null || true)" = "overlay" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo -n bash -c '"$0" install-card > "$1" 2>&1' "$REPO_ROOT/linux/boot/recovery.sh" /tmp/phasezero-boot-recovery-test.out; then
        cat /tmp/phasezero-boot-recovery-test.out >&2
        echo "expected install-card to refuse live overlay root" >&2
        exit 1
    fi
    grep -q 'refusing GRUB mutation' /tmp/phasezero-boot-recovery-test.out
fi

echo "linux-boot-recovery smoke ok"
