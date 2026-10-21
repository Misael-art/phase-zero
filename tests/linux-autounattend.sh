#!/usr/bin/env bash
# Hermetic contract checks for unattended Windows install generation.
#
# The answer file is only exercised for real hours into a Windows install, on a
# disk that is about to be wiped. Every property that would be expensive or
# destructive to discover there is asserted here instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AU="$ROOT/linux/windows-vm/autounattend.sh"
GUARD="$ROOT/linux/windows-vm/assets/pz-disk-guard.cmd"

bash -n "$AU"
[ -f "$GUARD" ]

WORK="$(mktemp -d /tmp/pz-autounattend.XXXXXX)"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

gen() {
    local out="$1"; shift
    PZ_STATE="$WORK/state" bash "$AU" generate --output-dir "$out" "$@" >/dev/null 2>&1
}

# --- the install target guard -------------------------------------------------
# Setup addresses the target by 0-based index and wipes it unconditionally, so
# an index alone must never authorise the wipe.
out="$WORK/ok"
gen "$out" --disk-serial PZWINVM0 --password 'A.b3!xyzQ' --tpm-bypass
xml="$out/autounattend.xml"
[ -f "$xml" ]
grep -Fq '<WillWipeDisk>true</WillWipeDisk>' "$xml"
# The guard script must be staged beside the answer file or it can never run.
[ -f "$out/pz-disk-guard.cmd" ]

# The guard is opt-in: WMIC.exe ships in the 25H2 Setup WinPE but the WMI
# service behind it does not, so the query returns nothing, the script exits
# non-zero and Setup aborts with 0x800700FF on a disk it should have accepted.
# Bisected against a real install: identical media minus this command installs.
if grep -Fq 'PhaseZeroDiskTargetGuard' "$xml"; then
    echo 'guard must not be enabled by default: it aborts Setup in WinPE' >&2
    exit 1
fi
gen "$WORK/guarded" --disk-serial PZWINVM0 --password 'A.b3!xyzQ' --disk-guard
grep -Fq 'PhaseZeroDiskTargetGuard' "$WORK/guarded/autounattend.xml"
grep -Fq 'pz-disk-guard.cmd PZWINVM0 0' "$WORK/guarded/autounattend.xml"

# A serial that cannot be compared verbatim inside cmd must be refused rather
# than silently producing a guard that never matches.
for bad in '' 'PZ WINVM' 'PZ;rm' 'PZ"0' "$(printf 'x%.0s' {1..33})"; do
    if gen "$WORK/bad" --disk-serial "$bad" --password 'A.b3!xyzQ'; then
        echo "accepted unusable disk serial: [$bad]" >&2
        exit 1
    fi
    rm -rf "$WORK/bad"
done

# --- WinPE capability contract ------------------------------------------------
# The Setup WinPE image ships no powershell.exe and no Storage module, so a
# guard written in PowerShell would silently never execute.
# Match invocation, not mention: the guard's own comments explain why it avoids
# PowerShell, so a blanket grep would flag the documentation it is meant to keep.
if grep -viE '^[[:space:]]*rem\b' "$GUARD" | grep -qiE 'powershell|pwsh'; then
    echo 'disk guard must not invoke PowerShell: absent from Setup WinPE' >&2
    exit 1
fi
grep -Fq 'wmic diskdrive' "$GUARD"
# A guard that cannot identify the disk must refuse, never fall through.
grep -Fq 'exit /b 2' "$GUARD"
grep -Fq 'exit /b 3' "$GUARD"
# Containment, not equality. Windows reports an NVMe serial padded and suffixed
# with namespace detail ("PZWINVM0                _00000001."), so an exact
# comparison rejected the correct disk and aborted Setup with 0x80070057.
grep -Fq 'findstr /i /c:"%EXPECTED%"' "$GUARD"
if grep -Eq 'if /i (not )?"!FOUND!"=="%EXPECTED%"' "$GUARD"; then
    echo 'disk guard reverted to exact serial match; Windows pads and suffixes it' >&2
    exit 1
fi

# The guest does not echo back the serial QEMU stamped. An NVMe device
# advertising PZWINVM0 is reported by Windows as "PZWINVM0    _00000001.",
# padded and suffixed. An equality test refused the correct disk and aborted
# Setup with 0x80070057, so the comparison must be containment.
grep -Fq 'findstr /i /c:"%EXPECTED%"' "$GUARD"
if grep -qE 'if /i not "!FOUND!"=="%EXPECTED%"' "$GUARD"; then
    echo 'guard compares serials for equality; the guest pads and suffixes them' >&2
    exit 1
fi

# --- driver paths must resolve ------------------------------------------------
# Speculatively listing D: through H: to find whichever letter WinPE assigned
# the virtio media made Setup reject the entire windowsPE pass with
# 0x80070057 as soon as one path was absent, which is the normal case. Verified
# against a real 25H2 install: removing the component was what let Setup past
# it. Nothing is emitted unless the caller names a path.
if grep -Fq 'PnpCustomizationsWinPE' "$xml"; then
    echo 'default answer file must not declare speculative driver paths' >&2
    exit 1
fi
gen "$WORK/drv" --disk-serial PZWINVM0 --password 'A.b3!xyzQ' --driver-path 'E:\amd64\w11'
grep -Fq 'Microsoft-Windows-PnpCustomizationsWinPE' "$WORK/drv/autounattend.xml"
grep -Fq 'E:\amd64\w11' "$WORK/drv/autounattend.xml"

# --- product key page ---------------------------------------------------------
# Omitting ProductKey does not skip the page: Setup stops there and an
# unattended install waits on it forever. Observed on a real 25H2 run.
grep -Fq '<Key></Key>' "$xml"
grep -Fq '<WillShowUI>Never</WillShowUI>' "$xml"

# --- autologon persistence ----------------------------------------------------
# Omitted LogonCount means persistent AutoAdminLogon, which is what an
# unattended GRUB -> Windows-logged-in boot requires.
if grep -Fq '<LogonCount>' "$xml"; then
    echo 'default install must not cap autologon' >&2
    exit 1
fi
gen "$WORK/counted" --disk-serial PZWINVM0 --password 'A.b3!xyzQ' --autologon-count 1
grep -Fq '<LogonCount>1</LogonCount>' "$WORK/counted/autounattend.xml"

# --- structural validity ------------------------------------------------------
python3 - "$xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
ns = '{urn:schemas-microsoft-com:unattend}'
tree = ET.parse(sys.argv[1])
passes = {s.get('pass') for s in tree.getroot()}
for required in ('windowsPE', 'oobeSystem', 'specialize'):
    assert required in passes, f'missing settings pass: {required}'
# Unattend rejects duplicate Order values among siblings; CreatePartitions and
# RunSynchronous both legitimately start at 1, so compare per parent.
for parent in tree.iter():
    orders = [c.findtext(f'{ns}Order') for c in parent
              if c.findtext(f'{ns}Order') is not None]
    dupes = {o for o in orders if orders.count(o) > 1}
    assert not dupes, f'duplicate <Order> under {parent.tag}: {sorted(dupes)}'
PYEOF

# The generator must reject a malformed document instead of shipping it.
# head closing the pipe early would SIGPIPE sed and, under pipefail, fail the
# suite with 141 rather than testing anything.
broken="$WORK/broken.xml"
sed -n '1,20p' "$xml" > "$broken"
if python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$broken" 2>/dev/null; then
    echo 'truncated answer file parsed as valid XML; validation is not meaningful' >&2
    exit 1
fi

# --- host-side serial agreement ----------------------------------------------
# The guard compares against whatever QEMU stamped on the disk device. If these
# drift the guard rejects every disk and the install cannot proceed.
# Literal shell source contract.
# shellcheck disable=SC2016
grep -Fq 'serial=$DISK_SERIAL' "$ROOT/linux/windows-vm/windows-vm.sh"
grep -Eq 'DISK_SERIAL="\$\{PZ_WINDOWS_VM_DISK_SERIAL:-PZWINVM0\}"' "$ROOT/linux/windows-vm/windows-vm.sh"
grep -Fq 'PZ_WINDOWS_VM_DISK_SERIAL:-PZWINVM0' "$ROOT/linux/windows-vm/provision.sh"

# provision.sh builds its own QEMU command line for the installer VM. It
# hardcoded serial=pzvm while the answer file demanded PZWINVM0, so the guard
# rejected every disk and Setup aborted. Asserting agreement between only two of
# the three places let that through, so every -device serial= must resolve from
# the shared variable rather than a literal.
# Literal shell source contract: the variable name, not its value.
# shellcheck disable=SC2016
bad_serials="$(grep -oE '(nvme|virtio-blk-pci)[^ ]*serial=[^,"[:space:]]+' \
    "$ROOT/linux/windows-vm/provision.sh" "$ROOT/linux/windows-vm/windows-vm.sh" \
    | grep -v 'serial=\$DISK_SERIAL' || true)"
if [ -n "$bad_serials" ]; then
    echo "hardcoded QEMU disk serial would defeat the install guard:" >&2
    printf '%s\n' "$bad_serials" >&2
    exit 1
fi

# --- btrfs nodatacow ----------------------------------------------------------
# CoW + O_DIRECT on a live qcow2 produced EIO mid-write and an unbootable guest.
grep -Fq 'mark_vm_dir_nodatacow' "$ROOT/linux/windows-vm/windows-vm.sh"
python3 - "$ROOT/linux/windows-vm/windows-vm.sh" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
i, j = s.index('mark_vm_dir_nodatacow\n'), s.index('qemu-img create -f qcow2')
assert i < j, 'nodatacow must be set before the image is created; the flag only affects new files'
PYEOF

# --- guest-side post-install script -------------------------------------------
# Each of these cost a two hour timeout on a real run before being found.
PROV="$ROOT/linux/windows-vm/provision.sh"

# WaitForExit(ms) does not refresh the cached process state, so ExitCode reads
# back as $null on Windows PowerShell 5.1 and the guest aborted setups that had
# actually succeeded. The no-argument wait is what makes the code readable.
grep -Fq 'qgaInstall.WaitForExit()' "$PROV"
# The service existing is the outcome that matters; an odd exit code alone must
# not condemn an install whose service is present.
# Literal PowerShell contract.
# shellcheck disable=SC2016
grep -Fq 'qgaPresent -and $qgaExit -notin' "$PROV"

# Write-Error is a terminating error while ErrorActionPreference is Stop, so it
# aborted the rest of the failure handler: no shutdown, no autologin teardown.
python3 - "$PROV" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
# provision.sh embeds several PowerShell scripts. Anchor on the shutdown this
# handler owns and walk back to its own catch, not the first one in the file.
end = src.index('shutdown.exe /s /t 10 /c "PhaseZero unattended setup failed"')
handler = src[src.rindex('} catch {', 0, end):end]
# Match code, not prose: the handler's own comment names Write-Error to explain
# why it is avoided, and a blanket search flags the documentation it protects.
code = '\n'.join(l for l in handler.splitlines() if not l.lstrip().startswith('#'))
assert 'Write-Error' not in code, (
    'failure handler must not use Write-Error: with ErrorActionPreference=Stop '
    'it re-throws and the shutdown below never runs'
)
assert "$ErrorActionPreference = 'Continue'" in code, (
    'failure handler must relax ErrorActionPreference before reporting'
)
for required in ('AutoAdminLogon', 'Stop-Transcript'):
    assert required in code, f'failure handler lost: {required}'
PYEOF

# A rejected guest-exec must record why, or the next failure is undebuggable.
grep -Fq 'QGA rejected driver installation command: ' "$PROV"

echo 'unattended install contracts ok'

# --- memory sizing profiles ---------------------------------------------------
# One figure cannot serve both hosts. Booted through GRUB the host runs nothing
# but the VM, so unused RAM is wasted; over a live KDE session the same figure
# pushed this machine into 8.6 GiB of swap because it sized from MemTotal and
# ignored what was actually in use.
# The sizing has one home. windows-vm.sh and provision.sh both source it; a
# private copy in either is how the install plan came to ask for 10 GiB on a
# host with 2 GiB available.
VM_SH="$ROOT/linux/windows-vm/memory.sh"
for consumer in windows-vm.sh provision.sh; do
    # shellcheck disable=SC2016 # literal source line, not an expansion
    grep -Fq 'source "$PZ_ROOT/linux/windows-vm/memory.sh"' "$ROOT/linux/windows-vm/$consumer"
    if grep -q '^default_ram_mb()' "$ROOT/linux/windows-vm/$consumer"; then
        echo "$consumer still defines its own default_ram_mb" >&2
        exit 1
    fi
done
grep -Fq 'windows_vm_boot_mode()' "$VM_SH"
grep -Fq 'windows_vm_meminfo_mb MemAvailable' "$VM_SH"
# The GRUB marker is what distinguishes the two hosts.
grep -Fq 'phasezero.windowsvm=1' "$VM_SH"

ram_for() {
    PZ_WINDOWS_VM_PROFILE="$1" bash -c '
        . '"$ROOT"'/linux/lib/common.sh 2>/dev/null
        . '"$VM_SH"'
        default_ram_mb' 2>/dev/null
}
kiosk_ram="$(ram_for kiosk)"
desktop_ram="$(ram_for desktop)"
for value in "$kiosk_ram" "$desktop_ram"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "sizing did not produce a number: [$value]" >&2; exit 1; }
    # Windows 11 does not run below 4 GiB; a smaller guest boots into thrashing.
    [ "$value" -ge 4096 ] || { echo "sizing fell below the Windows 11 minimum: $value" >&2; exit 1; }
done
# The dedicated-boot host has no desktop to serve, so it must never be the
# stingier of the two.
[ "$kiosk_ram" -ge "$desktop_ram" ] || {
    echo "kiosk sizing ($kiosk_ram) must not be below desktop sizing ($desktop_ram)" >&2
    exit 1
}
# Whatever the mode, the host keeps a reserve: handing over everything OOMs the
# host, and an OOM there kills the VM outright.
mem_total="$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)"
[ "$kiosk_ram" -lt "$mem_total" ] || {
    echo "kiosk sizing left the host no reserve: $kiosk_ram of $mem_total" >&2
    exit 1
}

echo 'memory sizing profile contracts ok'
