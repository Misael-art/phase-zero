#!/usr/bin/env bash
# Hermetic contract checks for recovery-account secret handling.
#
# This suite asserts literal PowerShell and shell source fragments, so every
# grep pattern is intentionally single-quoted and must not expand. Disabling
# SC2016 once for the file keeps new assertions from silently reintroducing the
# lint failure that has already broken CI twice.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="$ROOT/linux/windows-vm/guest-login.ps1"
SH="$ROOT/linux/windows-vm/guest-login.sh"
RECOVER="$ROOT/linux/windows-vm/recover.sh"

bash -n "$SH" "$RECOVER"
grep -Fq "\$recoveryUser = 'PZ-Recovery'" "$PS"
grep -Fq "Get-LocalGroup -SID 'S-1-5-32-544'" "$PS"
grep -Fq 'Add-LocalGroupMember -Group $adminGroup' "$PS"
grep -Fq 'SeDenyNetworkLogonRight' "$PS"
grep -Fq 'SeDenyRemoteInteractiveLogonRight' "$PS"
grep -Fq "Remove-ItemProperty -Path \$winlogon -Name DefaultPassword" "$PS"
grep -Fq 'recovery apply requires --password-stdin' "$SH"
grep -Fq 'QGA unavailable; use repair-qga with VM powered off' "$SH"
grep -Fq 'verified guest backup required before guest mutation' "$SH"
grep -Fq 'repair-qga requires VM powered off' "$SH"
grep -Fq 'virt-customize -a "$DISK_PATH"' "$SH"
grep -Fq -- '--firstboot "$OFFLINE_WORK/qga-offline-repair.bat"' "$SH"
grep -Fq -- 'qga-offline-repair.ps1:/ProgramData/PhaseZeroOffline/qga-offline-repair.ps1' "$SH"
grep -Fq 'automatic rollback failed' "$SH"
grep -Fq 'LIBGUESTFS_CACHEDIR="$guestfs_cache"' "$SH"
grep -Fq 'at least 3 GiB free space required for offline QGA repair' "$SH"
grep -Fq 'guest-login-diagnostics' "$SH"
grep -Fq 'Remove-Item -LiteralPath $payloadDir' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Join-Path \$env:SystemRoot 'System32'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Join-Path \$env:SystemRoot 'Sysnative'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'Test-Path -LiteralPath $sysnative' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq '& $pnputil /add-driver' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "\$trustedVirtioSha256 = '__PZ_VIRTIO_SHA256__'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'virtio media payload hash mismatch' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'QGA MSI signature hash mismatch' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'driver-installed'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'qga-installed'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq "Write-RepairStatus \$true 'reboot-scheduled'" "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'QGA transport unavailable after guest reboot' "$SH"
grep -Fq 'transport-verified' "$SH"
grep -Fq 'transport:"qmp"' "$SH"
grep -Fq 'Set-ExchangeMappingTask' "$PS"
grep -Fq "PhaseZero-MapExchange" "$PS"
grep -Fq '\\10.0.2.4\qemu' "$PS"
# Sockets QGA/QMP dão execução e poder de desligar o guest: os diretórios que
# os hospedam nascem 0700. A asserção é a invariante, não a linha literal — o
# runtime dir passou a ser criado por ensure_runtime_dir, que também devolve o
# dono ao usuário alvo quando a execução é elevada.
WVM_SH="$ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'install -d -m 0700 "$STATE_DIR"' "$WVM_SH"
awk '/^ensure_runtime_dir\(\)/,/^}/' "$WVM_SH" | grep -Fq 'install -d -m 0700'
grep -Fq 'ensure_runtime_dir "$RUNTIME_DIR"' "$WVM_SH"
grep -Fq 'transport-verify --json' "$RECOVER"
grep -Fq '"$GUEST_LOGIN" apply' "$RECOVER"
grep -Fq -- '--leave-running' "$RECOVER"

# Reboot proof must come from guest boot identity, never from watching the QGA
# socket disappear: a reboot faster than the poll interval is invisible to edge
# detection and hangs recovery on a perfectly healthy guest.
if grep -Fq 'wait_for_transport_cycle' "$RECOVER"; then
    echo 'recovery still infers reboots from transport gaps' >&2
    exit 1
fi
grep -Fq 'offlineRepairRebootProven == true' "$RECOVER"
grep -Fq 'wait_for_boot_change' "$RECOVER"
grep -Fq 'repairBootUpTime' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"
grep -Fq 'offlineRepairRebootProven' "$PS"
grep -Fq 'LastBootUpTime' "$PS"

# $Error is a PowerShell automatic variable; using it as a parameter name is a
# PSScriptAnalyzer Error and blocks the whole lint job.
if grep -Eq '\[string\]\$Error\b' "$ROOT/linux/windows-vm/qga-offline-repair.ps1"; then
    echo 'offline repair shadows the automatic $Error variable' >&2
    exit 1
fi

# The VM is started by recover.sh, so recover.sh must be able to stop it.
grep -Fq 'stop_vm' "$RECOVER"
grep -Fq 'kill -KILL' "$RECOVER"
grep -Fq 'disk-check' "$RECOVER"
grep -Fq 'setsid bash' "$RECOVER"

# Adapter presence is not acceleration. Readiness must not be satisfied by the
# Microsoft Basic Display Adapter or a bare QXL controller.
grep -Fq 'graphicsAccelerationVerified' "$PS"
grep -Fq 'basicDisplayAdapterOnly' "$PS"
grep -Fq 'Get-WddmVersion' "$PS"
grep -Fq 'graphicsAccelerationVerified == true' "$RECOVER"
# Public DNS resolution is diagnostic; an offline guest is still a valid guest.
grep -Fq 'dnsServersConfigured == true' "$RECOVER"
if grep -Fq '.dnsReady == true' "$RECOVER"; then
    echo 'recovery readiness still requires public DNS resolution' >&2
    exit 1
fi

# libguestfs firstboot needs RHSrvAny; resolving it explicitly is what makes the
# repair reproducible on a host that did not receive a manual copy.
grep -Fq 'VIRT_TOOLS_DATA_DIR="$virt_tools_dir"' "$SH"
grep -Fq 'resolve_virt_tools_dir' "$SH"
grep -Fq 'repair-preflight' "$RECOVER"

# Backups must not inherit a world-readable mode from an adopted disk.
grep -Fq 'chmod 0600 "$disk_backup"' "$SH"
grep -Fq 'prune_guest_backups' "$SH"
if grep -Fq -- '--preserve=mode,timestamps' "$SH"; then
    echo 'guest backup still inherits the source disk mode' >&2
    exit 1
fi
grep -Fq 'harden_vm_storage_modes' "$ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'install -d -m 0700 "$VM_DIR" "$STATE_DIR"' "$ROOT/linux/windows-vm/windows-vm.sh"
if grep -Eq -- 'PASSWORD=.*(echo|log|arg)' "$RECOVER"; then
    echo 'recovery orchestration may leak password' >&2
    exit 1
fi
grep -Fq 's/__PZ_VIRTIO_SHA256__/${virtio_sha_expected,,}/g' "$SH"
if grep -Eq -- '--arg (password|secret)|PZ_RECOVERY_PASSWORD|recovery.*password.*=' "$SH"; then
    echo 'recovery secret leaked through shell argv/environment contract' >&2
    exit 1
fi

offline_fixture() {
    local dir="$1" mode="$2"
    local trusted_sha
    mkdir -p "$dir/bin" "$dir/vm/tpm" "$dir/state" "$dir/config" "$dir/virt-tools"
    printf 'rhsrvany\n' > "$dir/virt-tools/rhsrvany.exe"
    printf 'original-qcow2\n' > "$dir/vm/phasezero-windows.qcow2"
    printf 'ovmf\n' > "$dir/vm/OVMF_VARS.fd"
    printf 'tpm\n' > "$dir/vm/tpm/state"
    printf 'virtio\n' > "$dir/virtio-win.iso"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$1" in' \
        '  check) [ -f "$2" ] ;;' \
        '  info) printf '\''{"format":"qcow2","virtual-size":4096}\n'\'' ;;' \
        '  *) exit 2 ;;' \
        'esac' > "$dir/bin/qemu-img"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf '\''%s\n'\'' "$@" > "$PZ_TEST_VIRT_ARGS"' \
        'if [ "$PZ_TEST_VIRT_MODE" = fail ]; then' \
        '  printf '\''mutated-before-failure\n'\'' > "$PZ_TEST_DISK"' \
        '  exit 42' \
        'fi' > "$dir/bin/virt-customize"
    chmod 0755 "$dir/bin/qemu-img" "$dir/bin/virt-customize"
    trusted_sha="$(sha256sum "$dir/virtio-win.iso" | cut -d' ' -f1)"
    [ "$mode" != hash-fail ] || trusted_sha="$(printf '0%.0s' {1..64})"
    PZ_TEST_VIRT_MODE="$mode" PZ_TEST_VIRT_ARGS="$dir/virt.args" \
    PZ_TEST_DISK="$dir/vm/phasezero-windows.qcow2" \
    PZ_WINDOWS_VM_DIR="$dir/vm" PZ_WINDOWS_VM_DISK="$dir/vm/phasezero-windows.qcow2" \
    PZ_WINDOWS_VM_OVMF_VARS="$dir/vm/OVMF_VARS.fd" PZ_WINDOWS_VM_TPM_DIR="$dir/vm/tpm" \
    PZ_WINDOWS_VM_VIRTIO_ISO="$dir/virtio-win.iso" \
    PZ_WINDOWS_VM_VIRTIO_SHA256="$trusted_sha" \
    PZ_WINDOWS_VM_VIRT_TOOLS_DIR="${PZ_TEST_VIRT_TOOLS_DIR-$dir/virt-tools}" \
    XDG_STATE_HOME="$dir/state" XDG_CONFIG_HOME="$dir/config" XDG_RUNTIME_DIR=/tmp \
    HOME="$dir/home" PATH="$dir/bin:$PATH" \
        bash "$SH" "${PZ_TEST_ACTION:-repair-qga}" --json
}

# Use persistent /tmp, not Codex's per-user runtime tmpfs: repair-qga
# deliberately requires 3 GiB for the libguestfs appliance.
tmp_success="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
success_json="$(offline_fixture "$tmp_success" success)"
printf '%s\n' "$success_json" | jq -e \
    '.success == true and .state == "pending-guest-boot" and .phase == "reboot-scheduled" and
     .guestRebootRequired == true and
     .qgaAvailable == false and (.rollbackManifest | type == "string")' >/dev/null
grep -Fxq -- '--firstboot' "$tmp_success/virt.args"
grep -Fq -- 'qga-offline-repair.bat' "$tmp_success/virt.args"
grep -Fq -- 'qga-offline-repair.ps1' "$tmp_success/virt.args"
manifest="$(printf '%s\n' "$success_json" | jq -r '.rollbackManifest')"
[ -f "$manifest" ]
jq -e '.qemuImageCheck == true and .sourceDisk and .backupDisk' "$manifest" >/dev/null
rm -rf -- "$tmp_success"

tmp_failure="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
set +e
failure_output="$(offline_fixture "$tmp_failure" fail 2>&1)"
failure_rc=$?
set -e
[ "$failure_rc" -ne 0 ]
grep -Fxq 'original-qcow2' "$tmp_failure/vm/phasezero-windows.qcow2"
if grep -Fq 'mutated-before-failure' "$tmp_failure/vm/phasezero-windows.qcow2"; then
    exit 1
fi
grep -Fq 'disk rollback attempted' <<<"$failure_output"
rm -rf -- "$tmp_failure"

tmp_hash="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
set +e
hash_output="$(offline_fixture "$tmp_hash" hash-fail 2>&1)"
hash_rc=$?
set -e
[ "$hash_rc" -ne 0 ]
grep -Fq 'SHA-256 mismatch' <<<"$hash_output"
[ ! -e "$tmp_hash/virt.args" ]
[ ! -d "$tmp_hash/state/phasezero/windows-vm/guest-login-backups" ]
rm -rf -- "$tmp_hash"

tmp_preflight="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
preflight_json="$(PZ_TEST_ACTION=repair-preflight offline_fixture "$tmp_preflight" success)"
printf '%s\n' "$preflight_json" | jq -e '.success == true and .ready == true and (.missing | length) == 0' >/dev/null
printf '%s\n' "$preflight_json" | jq -e '(.virtToolsDir | endswith("/virt-tools"))' >/dev/null

# A host without the libguestfs firstboot helper must be told before anything is
# copied, not after a backup and a rollback.
set +e
missing_json="$(PZ_TEST_ACTION=repair-preflight PZ_TEST_VIRT_TOOLS_DIR="$tmp_preflight/absent" \
    PZ_STATE="$tmp_preflight/absent-state" offline_fixture "$tmp_preflight" success 2>/dev/null)"
missing_rc=$?
set -e
if [ ! -r /usr/share/virt-tools/rhsrvany.exe ] && [ ! -r /usr/lib/virt-tools/rhsrvany.exe ]; then
    [ "$missing_rc" -ne 0 ]
    printf '%s\n' "$missing_json" | jq -e '.ready == false and (.missing | length) > 0' >/dev/null
fi
rm -rf -- "$tmp_preflight"

# Retention: bounded by count, and never willing to drop the last recoverable
# copy whatever the limits say.
tmp_prune="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
prune_root="$tmp_prune/state/phasezero/windows-vm/guest-login-backups"
mkdir -p "$prune_root"
for day in 1 2 3 4 5 6; do
    mkdir -p "$prune_root/2026010${day}T000000Z"
    printf '{"schemaVersion":1}\n' > "$prune_root/2026010${day}T000000Z/manifest.json"
    touch -d "2026-01-0${day} 00:00:00" "$prune_root/2026010${day}T000000Z/manifest.json"
done
# A directory whose copy was interrupted has no manifest and is unrecoverable.
mkdir -p "$prune_root/20260107T000000Z.partial"
prune_json="$(XDG_STATE_HOME="$tmp_prune/state" HOME="$tmp_prune/home" \
    PZ_WINDOWS_VM_BACKUP_KEEP=2 PZ_WINDOWS_VM_BACKUP_MAX_AGE_DAYS=99999 \
    PZ_WINDOWS_VM_BACKUP_MIN_FREE_GIB=0 \
    bash "$SH" prune-backups --json)"
printf '%s\n' "$prune_json" | jq -e '.success == true and .prunedBackups == 5' >/dev/null
[ "$(find "$prune_root" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)" -eq 2 ]
[ ! -d "$prune_root/20260107T000000Z.partial" ]

# Age alone must not empty the store: the newest copy survives.
touch -d '2000-01-01 00:00:00' "$prune_root"/*/manifest.json
XDG_STATE_HOME="$tmp_prune/state" HOME="$tmp_prune/home" \
    PZ_WINDOWS_VM_BACKUP_KEEP=2 PZ_WINDOWS_VM_BACKUP_MAX_AGE_DAYS=1 \
    PZ_WINDOWS_VM_BACKUP_MIN_FREE_GIB=0 \
    bash "$SH" prune-backups --json >/dev/null
[ "$(find "$prune_root" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)" -eq 1 ]

# Space pressure prunes further but still stops at the last recoverable copy.
for day in 1 2 3; do
    mkdir -p "$prune_root/2026020${day}T000000Z"
    printf '{"schemaVersion":1}\n' > "$prune_root/2026020${day}T000000Z/manifest.json"
done
XDG_STATE_HOME="$tmp_prune/state" HOME="$tmp_prune/home" \
    PZ_WINDOWS_VM_BACKUP_KEEP=99 PZ_WINDOWS_VM_BACKUP_MAX_AGE_DAYS=99999 \
    PZ_WINDOWS_VM_BACKUP_MIN_FREE_GIB=999999 \
    bash "$SH" prune-backups --json >/dev/null
[ "$(find "$prune_root" -mindepth 2 -maxdepth 2 -name manifest.json | wc -l)" -eq 1 ]
rm -rf -- "$tmp_prune"

# recover.sh must abort on the preflight, before it takes a backup or starts
# QEMU. An unsafe tmpfs root fails the gate deterministically on every host,
# including one that happens to ship the libguestfs firstboot helper.
tmp_recover="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
mkdir -p "$tmp_recover/state" "$tmp_recover/unsafe-runtime"
set +e
recover_output="$(XDG_STATE_HOME="$tmp_recover/state" XDG_CONFIG_HOME="$tmp_recover/config" \
    HOME="$tmp_recover/home" XDG_RUNTIME_DIR="$tmp_recover/unsafe-runtime" \
    bash "$RECOVER" --mode auto --json 2>&1)"
recover_rc=$?
set -e
[ "$recover_rc" -ne 0 ]
printf '%s\n' "$recover_output" | jq -e -s \
    'map(select(.phase == "preflight")) | length == 1 and .[0].success == false' >/dev/null
# Nothing may have been created before the gate fired.
[ ! -d "$tmp_recover/state/phasezero/windows-vm/guest-login-backups" ]
rm -rf -- "$tmp_recover"

# A package upgrade replaces the PhaseZero tree but never /usr/local, so the
# GRUB boot path keeps running the previous release. Detection must work
# without root: boot_artifacts_current also reads /etc/grub.d, so it collapses
# a provable "stale" into "unknown-permission" for an unprivileged caller.
VM="$ROOT/linux/windows-vm/windows-vm.sh"
NOTICE="$ROOT/linux/windows-vm/boot-runtime-notice.sh"
grep -Fq 'boot_runtime_state()' "$VM"
grep -Fq 'runtime-check|check-runtime) runtime_check' "$VM"
grep -Fq 'bootRuntimeState' "$VM"
grep -Fq 'bootRuntimeStale' "$VM"
grep -Fq 'bootRuntimeStale == true' "$ROOT/linux/audit/doctor.sh"
# The hook must warn only. boot install regenerates grub.cfg and runs
# os-prober; inside a package transaction a failure there is far worse than an
# outdated runtime.
if grep -Eq 'boot[ -]install' "$NOTICE"; then
    grep -Fq 'phasezero-admin' "$NOTICE"
fi
if grep -Eq '^[^#]*\b(grub-mkconfig|update-grub)\b' "$NOTICE"; then
    echo 'package hook must never regenerate the bootloader' >&2
    exit 1
fi
grep -Fq 'boot-runtime-notice.sh' "$ROOT/packaging/linux/deb/build-deb.sh"
grep -Fq 'boot-runtime-notice.sh' "$ROOT/packaging/linux/rpm/phasezero-control-center.spec"
grep -Fq 'phasezero-boot-runtime.hook' "$ROOT/packaging/linux/aur/PKGBUILD"
grep -Fq 'PostTransaction' "$ROOT/packaging/linux/hooks/phasezero-boot-runtime.hook"

# The notice must stay silent whenever it cannot prove staleness, so no upgrade
# is ever noisy or aborted by an inconclusive probe.
notice_silent() {
    local label="$1"; shift
    local out
    out="$(env "$@" bash "$NOTICE" 2>&1)"
    [ -z "$out" ] || { echo "boot runtime notice was not silent: $label" >&2; exit 1; }
}
notice_silent 'boot integration absent' PZ_BOOT_HELPER=/nonexistent/helper
notice_silent 'phasezero tree absent' PZ_LIB_DIR=/nonexistent

tmp_notice="$(mktemp -d /tmp/pz-guest-recovery.XXXXXX)"
mkdir -p "$tmp_notice/lib/linux/windows-vm" "$tmp_notice/local"
touch "$tmp_notice/local/windows-vm-boot-prepare"
# An installed tree older than `boot runtime-check` must degrade quietly.
printf '%s\n' '#!/usr/bin/env bash' 'echo "ERROR: unknown action" >&2' 'exit 1' \
    > "$tmp_notice/lib/linux/windows-vm/windows-vm.sh"
notice_silent 'installed tree predates runtime-check' \
    "PZ_LIB_DIR=$tmp_notice/lib" "PZ_BOOT_HELPER=$tmp_notice/local/windows-vm-boot-prepare"
# A runtime that is genuinely stale must produce an actionable warning.
printf '%s\n' '#!/usr/bin/env bash' \
    'printf %s "{\"bootRuntimeState\":\"stale\",\"bootRuntimeStale\":true}"' \
    > "$tmp_notice/lib/linux/windows-vm/windows-vm.sh"
notice_out="$(PZ_LIB_DIR="$tmp_notice/lib" PZ_BOOT_HELPER="$tmp_notice/local/windows-vm-boot-prepare" \
    bash "$NOTICE" 2>&1)"
grep -Fq 'OUTDATED' <<<"$notice_out"
grep -Fq 'boot install' <<<"$notice_out"
# The remediation path must follow the tree the package actually installed.
grep -Fq "$tmp_notice/lib/linux/pz" <<<"$notice_out"
# current must be silent again.
printf '%s\n' '#!/usr/bin/env bash' \
    'printf %s "{\"bootRuntimeState\":\"current\",\"bootRuntimeStale\":false}"' \
    > "$tmp_notice/lib/linux/windows-vm/windows-vm.sh"
notice_silent 'runtime current' \
    "PZ_LIB_DIR=$tmp_notice/lib" "PZ_BOOT_HELPER=$tmp_notice/local/windows-vm-boot-prepare"
rm -rf -- "$tmp_notice"

echo 'guest recovery secret and local-only contracts ok'
