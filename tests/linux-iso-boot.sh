#!/usr/bin/env bash
# Tests for managed dynamic ISO/USB/grubfm boot backend.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export PZ_ISO_BOOT_CONFIG="$tmp/boot-isos.json"
export PZ_ISO_BOOT_ARTIFACTS="$tmp/artifacts.json"
export PZ_ISO_GRUB_SCRIPT="$tmp/46_phasezero_iso_loopback"
export PZ_USB_GRUB_SCRIPT="$tmp/47_phasezero_removable_efi"
export PZ_GRUBFM_GRUB_SCRIPT="$tmp/48_phasezero_grubfm"

bash -n "$REPO_ROOT/linux/lib/common.sh" "$REPO_ROOT/linux/boot/iso-boot.sh"

printf 'fixture\n' > "$tmp/rescue.iso"
sha="$(sha256sum "$tmp/rescue.iso" | awk '{print $1}')"
cat > "$PZ_ISO_BOOT_CONFIG" <<EOF
{
  "schemaVersion": 1,
  "entries": [
    {
      "id": "arch-rescue",
      "title": "Arch Rescue",
      "kind": "iso",
      "profile": "archiso",
      "hostPath": "$tmp/rescue.iso",
      "fsUuid": "1111-2222",
      "fsType": "btrfs",
      "fsModule": "btrfs",
      "grubPath": "/@/boot/iso/arch rescue.iso",
      "kernelPath": "/arch/boot/x86_64/vmlinuz-linux",
      "initrdPath": "/arch/boot/x86_64/initramfs-linux.img",
      "isoLabel": "ARCH_TEST",
      "sha256": "$sha",
      "enabled": true
    },
    {
      "id": "ventoy-test",
      "title": "Ventoy Test",
      "kind": "removable-efi",
      "fsUuid": "3333-4444",
      "fsType": "vfat",
      "fsModule": "fat",
      "efiPath": "/EFI/BOOT/BOOTX64.EFI",
      "sha256": "deadbeef",
      "enabled": true
    }
  ]
}
EOF

export PZ_ISO_BOOT_LIBRARY_ONLY=1
# shellcheck disable=SC1090
source "$REPO_ROOT/linux/boot/iso-boot.sh"
unset PZ_ISO_BOOT_LIBRARY_ONLY

render_iso_script "$PZ_ISO_BOOT_CONFIG" > "$PZ_ISO_GRUB_SCRIPT"
render_usb_script "$PZ_ISO_BOOT_CONFIG" > "$PZ_USB_GRUB_SCRIPT"

grep -q "phasezero-iso-arch-rescue" "$PZ_ISO_GRUB_SCRIPT"
grep -q 'search --no-floppy --fs-uuid --set=iso_dev 1111-2222' "$PZ_ISO_GRUB_SCRIPT"
grep -q 'img_dev=/dev/disk/by-uuid/1111-2222' "$PZ_ISO_GRUB_SCRIPT"
grep -q 'img_loop=/@/boot/iso/arch rescue.iso' "$PZ_ISO_GRUB_SCRIPT"
grep -q "phasezero-removable-ventoy-test" "$PZ_USB_GRUB_SCRIPT"
grep -q 'search --no-floppy --fs-uuid --set=removable 3333-4444' "$PZ_USB_GRUB_SCRIPT"
grep -q '/EFI/BOOT/BOOTX64.EFI' "$PZ_USB_GRUB_SCRIPT"
if grep -Eq '\(hd[0-9]+,gpt[0-9]+' "$PZ_ISO_GRUB_SCRIPT" "$PZ_USB_GRUB_SCRIPT"; then
    echo "FAIL: grub scripts contain device-specific hd/gpt references"
    exit 1
fi

# shellcheck disable=SC2016 # literal dquote fixtures
[ "$(pz_boot_grub_dquote 'a $b `c` "d"')" = '"a \$b \`c\` \"d\""' ]
pz_boot_valid_id arch-rescue
if pz_boot_valid_id 'Arch Rescue'; then
    echo "FAIL: 'Arch Rescue' should be an invalid id"
    exit 1
fi
if safe_title "bad'title"; then
    echo "FAIL: bad title should be rejected"
    exit 1
fi

status="$(bash "$REPO_ROOT/linux/boot/iso-boot.sh" iso status --json)"
jq -e '.schemaVersion == 1 and .entries[0].available == true and .entries[0].reason == "ready"' <<< "$status" >/dev/null

before="$(sha256sum "$PZ_ISO_BOOT_CONFIG" | awk '{print $1}')"
bash "$REPO_ROOT/linux/boot/iso-boot.sh" iso remove arch-rescue --dry-run >/dev/null
after="$(sha256sum "$PZ_ISO_BOOT_CONFIG" | awk '{print $1}')"
[ "$before" = "$after" ]

catalog="$(bash "$REPO_ROOT/linux/boot/iso-boot.sh" catalog)"
jq -e '.choices[] | select(.key == "iso:arch-rescue" and .available == true)' <<< "$catalog" >/dev/null

(
    iso_listing() {
        printf '%s\n' boot/vmlinuz-x86_64 boot/initramfs-x86_64.img \
            boot/amd_ucode.img boot/intel_ucode.img manjaro/x86_64/rootfs.sfs
    }
    blkid() {
        case "$3" in TYPE) printf '%s\n' iso9660 ;; LABEL) printf '%s\n' BIGLINUXLIVE ;; esac
    }
    inspection="$(inspect_iso_json "$tmp/rescue.iso")"
    jq -e '.profile=="manjaro-miso" and (.microcodePaths | length)==2' <<< "$inspection" >/dev/null
    live="$(jq -c --argjson inspection "$inspection" '.entries[0] + $inspection' "$PZ_ISO_BOOT_CONFIG")"
    manifest_with_entry "$live" > "$tmp/miso-manifest.json"
    render_iso_script "$tmp/miso-manifest.json" > "$tmp/miso-script"
    bash "$tmp/miso-script" > "$tmp/miso.cfg"
    grep -Fq 'misobasedir=manjaro "misolabel=BIGLINUXLIVE"' "$tmp/miso.cfg"
    grep -Fq '"img_dev=/dev/disk/by-uuid/1111-2222"' "$tmp/miso.cfg"
    grep -Fq 'initrd "(loop)/boot/amd_ucode.img" "(loop)/boot/intel_ucode.img" "(loop)/boot/initramfs-x86_64.img"' "$tmp/miso.cfg"
    iso_plan_json "$live" add | jq -e --arg hash "$sha" '.sha256==$hash and .entry.profile=="manjaro-miso"' >/dev/null
    if command -v grub-script-check >/dev/null; then
        grub-script-check "$tmp/miso.cfg"
    fi

    GRUB_CFG="$tmp/grub.cfg"
    printf 'menuentry "Linux atual" {\n    true\n}\n' > "$GRUB_CFG"
    original_cfg="$(cat "$GRUB_CFG")"
    original_manifest="$(cat "$PZ_ISO_BOOT_CONFIG")"
    need_root() { :; }
    pz_boot_path() { printf '%s\n' "$tmp/lock"; }
    pz_boot_require_current_root_target() { :; }
    pz_boot_preflight_grub() { :; }
    pz_boot_validate_active_efi_safe() { :; }
    pz_boot_backup_bundle() { :; }
    pz_boot_refresh_grub_config() { printf '%s\n' incomplete > "$GRUB_CFG"; return 9; }
    if ! command -v grub-script-check >/dev/null; then grub-script-check() { :; }; fi
    # The nested shell keeps errexit active for the transaction under test.
    set +e
    (set -e; apply_manifest_file "$tmp/miso-manifest.json" "$original_manifest")
    rc=$?
    set -e
    [ "$rc" -eq 9 ]
    [ "$(cat "$GRUB_CFG")" = "$original_cfg" ]
    [ "$(cat "$PZ_ISO_BOOT_CONFIG")" = "$original_manifest" ]
)

echo "linux-iso-boot ok"
