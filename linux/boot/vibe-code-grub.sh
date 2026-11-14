#!/usr/bin/env bash
# PhaseZero managed: Vibe Code
set -euo pipefail

# Reuse the distro kernel, root device, Btrfs/crypto options and microcode.
standard="$("${1:-/etc/grub.d/10_linux}")"
awk '
    /^menuentry[[:blank:]]/ && !found {
        found=1
        entry="menuentry \047PhaseZero Vibe Code (Plasma)\047 --id=\047phasezero-vibe-code\047 --class gnu-linux {\n"
        next
    }
    found && /^}/ {
        if (kernel == 1 && initrd == 1) {
            print "set timeout_style=menu"
            print "if [ \"\$timeout\" != -1 ]; then"
            print "  if [ -z \"\$timeout\" ]; then"
            print "    set timeout=5"
            print "  elif [ \"\$timeout\" -lt 5 ]; then"
            print "    set timeout=5"
            print "  fi"
            print "fi"
            printf "%s}\n", entry
            done=1
        }
        exit
    }
    found {
        if ($1 == "savedefault") next
        if ($1 ~ /^linux(efi|16)?$/) {
            if ($0 ~ /[[:blank:]]phasezero\.(vibe|steamos|waydroid|winvm|windows-vm|windowsvm|homelab)=/ ||
                $0 ~ /[[:blank:]]steamzero\.gamemode=/) exit 1
            if ($0 ~ /[[:blank:]]systemd\.unit=/) exit 1
            $0=$0 " phasezero.vibe=1 systemd.unit=phasezero-vibe-code.target"
            kernel++
        }
        if ($1 ~ /^initrd(efi|16)?$/) initrd++
        entry=entry $0 "\n"
    }
    END { if (!done) exit 1 }
' <<< "$standard"
