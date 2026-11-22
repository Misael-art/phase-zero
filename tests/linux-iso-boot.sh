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
    iso_listing() { printf '%s\n' live/vmlinuz live/initrd.img live/filesystem.squashfs; }
    blkid() {
        case "$3" in TYPE) printf '%s\n' iso9660 ;; LABEL) printf '%s\n' ARMBIAN ;; esac
    }
    bsdtar() {
        python3 -c '
import os
import sys
header = bytearray(0x238)
header[0x1fe:0x200] = b"\x55\xaa"
header[0x202:0x206] = b"HdrS"
header[0x236] = int(os.environ.get("PZ_TEST_KERNEL_64", "1"))
sys.stdout.buffer.write(header + bytes(50000))
'
    }
    pz_boot_resolve_file_identity() {
        jq -n --arg host "$tmp/rescue.iso" '{hostPath:$host,fsUuid:"20006A5C006A38C4",
            fsModule:"ntfs",fsType:"fuseblk",grubPath:"/Isos/Armbian-test.iso"}'
    }
    armbian_ntfs_type() { armbian_ntfs_type_from_listing "${PZ_TEST_INITRD_LISTING}"; }
    PZ_TEST_INITRD_LISTING=$'usr/bin/ntfs-3g\nusr/sbin/mount.ntfs'
    jq -e '.profile == "armbian-live" and .initrdPath == "/live/initrd.img"' \
        <<< "$(inspect_iso_json "$tmp/rescue.iso")" >/dev/null
    if PZ_TEST_KERNEL_64=0 inspect_iso_json "$tmp/rescue.iso" >/dev/null 2>&1 ||
        inspect_iso_json "$tmp/rescue.iso" debian-live >/dev/null 2>&1 ||
        armbian_fromiso_arg 1234 "/Isos/Armbian copy.iso" ntfs >/dev/null ||
        PZ_TEST_INITRD_LISTING=usr/bin/ntfs-3g iso_entry_json "$tmp/rescue.iso" auto armbian "Armbian" >/dev/null 2>&1; then
        echo "FAIL: Armbian accepted an incompatible architecture, profile, path or NTFS image"
        exit 1
    fi
    armbian="$(iso_entry_json "$tmp/rescue.iso" auto armbian "Armbian")"
    iso_plan_json "$armbian" add | jq -e '.reasons[-1] | contains("somente leitura")' >/dev/null
    jq -n --argjson entry "$armbian" '{schemaVersion:1,entries:[$entry]}' > "$tmp/armbian.json"
    render_iso_script "$tmp/armbian.json" | tail -n +3 > "$tmp/armbian.cfg"
    grep -Fq 'boot=live components systemd.gpt_auto=0 nopersistence ro' "$tmp/armbian.cfg"
    grep -Fq '"fromiso=ntfs:/dev/disk/by-uuid/20006A5C006A38C4/Isos/Armbian-test.iso"' "$tmp/armbian.cfg"
    grep -Fq 'initrd "(loop)/live/initrd.img"' "$tmp/armbian.cfg"
    if command -v grub-script-check >/dev/null; then grub-script-check "$tmp/armbian.cfg"; fi
    PZ_TEST_INITRD_LISTING=usr/lib/modules/7.3.5/kernel/fs/ntfs3/ntfs3.ko.zst
    armbian="$(iso_entry_json "$tmp/rescue.iso" auto armbian "Armbian")"
    jq -n --argjson entry "$armbian" '{schemaVersion:1,entries:[$entry]}' > "$tmp/armbian.json"
    render_iso_script "$tmp/armbian.json" > "$tmp/armbian.cfg"
    grep -Fq '"fromiso=ntfs3:/dev/disk/by-uuid/20006A5C006A38C4/Isos/Armbian-test.iso"' "$tmp/armbian.cfg"
)

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

    ntfs="$(jq -c '. + {id:"biglinux-ntfs",fsModule:"ntfs",fsType:"fuseblk"}' <<< "$live")"
    entry_state_json "$ntfs" |
        jq -e '.available == false and .reason == "miso-ntfs" and .bootValidation == "blocked"' >/dev/null
    jq -n --argjson entry "$ntfs" '{schemaVersion:1,entries:[$entry]}' > "$tmp/miso-ntfs.json"
    render_iso_script "$tmp/miso-ntfs.json" > "$tmp/miso-ntfs-script"
    bash "$tmp/miso-ntfs-script" > "$tmp/miso-ntfs.cfg"
    grep -Fq -- "--id='phasezero-iso-biglinux-ntfs'" "$tmp/miso-ntfs.cfg"
    grep -Fq 'Use um pendrive de instalacao separado' "$tmp/miso-ntfs.cfg"
    if grep -Eq '^[[:space:]]+(loopback|linux|initrd)[[:space:]]' "$tmp/miso-ntfs.cfg"; then
        echo "FAIL: unsafe legacy ISO entry still loads a kernel"
        exit 1
    fi
    if command -v grub-script-check >/dev/null; then grub-script-check "$tmp/miso-ntfs.cfg"; fi

    (
        CONFIG="$tmp/miso-ntfs.json"
        SUBCOMMAND=add
        REST=("$tmp/rescue.iso" --id=biglinux-ntfs --plan-json)
        pz_boot_resolve_file_identity() { printf '%s\n' "$ntfs"; }
        if result="$(cmd_iso)"; then
            echo "FAIL: preview allowed BigLinux from NTFS"
            exit 1
        fi
        jq -e '.status == "blocked" and (.blockers[0] | contains("pendrive"))' <<< "$result" >/dev/null
        if result="$(schedule_next iso biglinux-ntfs 2>&1)"; then
            echo "FAIL: one-shot allowed a blocked legacy entry"
            exit 1
        fi
        grep -Fq 'pendrive de instalação separado' <<< "$result"
    )

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
