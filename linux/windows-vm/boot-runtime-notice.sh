#!/usr/bin/env bash
# Post-install notice: warn when a package upgrade left the Windows VM GRUB
# boot runtime on the previous version.
#
# `pz windows-vm boot install` copies a self-contained runtime into
# /usr/local/lib/phasezero so the boot session works before the user's home or
# repo is mounted. No package manager owns that copy, so upgrading the PhaseZero
# package silently leaves the GRUB boot path executing the previous release.
#
# What goes stale is only the copied files, so the hook resyncs THEM — a plain
# copy of files the package just installed, into paths the existing GRUB entry
# already points at. It never runs `boot install`: that regenerates grub.cfg,
# runs os-prober and reconfigures Samba, none of which belongs inside a package
# transaction, where a failure aborts the upgrade and a partially rewritten
# bootloader is far worse than an outdated runtime.
#
# The notice survives for what the copy cannot fix: a resync that fails, or a
# release that changes the GRUB stanza itself.
#
# Never fails the transaction: an inconclusive probe is silent, and a missing
# dependency exits 0.
set -u

PZ_LIB="${PZ_LIB_DIR:-/usr/lib/phasezero}"
VM_SH="$PZ_LIB/linux/windows-vm/windows-vm.sh"
BOOT_HELPER="${PZ_BOOT_HELPER:-/usr/local/lib/phasezero/windows-vm-boot-prepare}"

[ -r "$VM_SH" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# Nothing to warn about when the boot integration was never installed.
[ -e "$BOOT_HELPER" ] || exit 0

state="$(bash "$VM_SH" boot runtime-check --json 2>/dev/null | jq -r '.bootRuntimeState // "unknown"' 2>/dev/null)"
[ "$state" = "stale" ] || exit 0

# Ressincroniza sozinho. Nunca derruba a transação: falha vira o aviso de antes.
if bash "$VM_SH" boot sync-runtime >/dev/null 2>&1; then
    state="$(bash "$VM_SH" boot runtime-check --json 2>/dev/null | jq -r '.bootRuntimeState // "unknown"' 2>/dev/null)"
    if [ "$state" = "current" ]; then
        printf '>>> PhaseZero: Windows VM boot runtime resynced automatically.\n' >&2
        exit 0
    fi
fi

# Leave a marker the app can read without privileges: status --json surfaces
# bootRuntimePendingSync so the UI offers the one-click resync even when the
# user missed this stderr notice. `boot install` removes the marker on
# success. Best effort only — never fails the transaction.
PENDING_FILE="${PZ_BOOT_RUNTIME_PENDING:-/var/lib/phasezero/windows-vm-runtime-sync.pending}"
if install -d "$(dirname "$PENDING_FILE")" 2>/dev/null; then
    printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date)" "$state" \
        > "$PENDING_FILE" 2>/dev/null || true
fi

# $PZ_LIB, not a hardcoded path: rpm installs under %{_libdir}, which is
# /usr/lib64 on 64-bit Fedora and friends.
cat >&2 <<EOF

>>> PhaseZero: the Windows VM GRUB boot runtime is now OUTDATED.
    /usr/local/lib/phasezero still holds the previous release, so booting
    through the "PhaseZero Windows VM" GRUB entry runs the old code.

    Resync it with admin rights:

        phasezero-admin $PZ_LIB/linux/pz windows-vm boot install

    Check at any time, no privileges needed:

        $PZ_LIB/linux/pz windows-vm boot runtime-check

EOF
exit 0
