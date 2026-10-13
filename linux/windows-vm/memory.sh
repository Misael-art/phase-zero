#!/usr/bin/env bash
# memory.sh - how much RAM the Windows VM gets, and whether the host can give it.
#
# Sourced by windows-vm.sh and provision.sh. It used to live only in
# windows-vm.sh; provision.sh kept an older copy that sized from MemTotal, so
# the install plan asked for 10374 MB on a host with 2 GB available while the
# launch path, already fixed, would have asked for 4096 MB. One definition,
# two callers.

# Overridable so the suites can describe a host instead of depending on the
# machine they happen to run on.
windows_vm_meminfo_file() {
    printf '%s' "${PZ_WINDOWS_VM_MEMINFO_FILE:-/proc/meminfo}"
}

windows_vm_meminfo_mb() {
    local field="$1" value
    value="$(awk -v key="$field:" '$1 == key {print int($2 / 1024)}' "$(windows_vm_meminfo_file)" 2>/dev/null || true)"
    case "$value" in ''|*[!0-9]*) value=0 ;; esac
    printf '%s' "$value"
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
    total="$(windows_vm_meminfo_mb MemTotal)"
    [ "$total" -gt 0 ] || total=8192
    # MemAvailable is the kernel's own estimate of what can be handed out
    # without swapping, reclaimable page cache included. MemFree alone would
    # undercount badly on a warm desktop.
    avail="$(windows_vm_meminfo_mb MemAvailable)"
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

# Can the host hand over this much right now?
#   fits   - within MemAvailable
#   tight  - above MemAvailable but covered by free swap: it runs, and the
#            session pays for it in swapping
#   exceed - above MemAvailable plus free swap: the kernel has nowhere to put
#            it, and the OOM killer picks the victim. On a desktop that can be
#            the browser, the terminal, or the VM in the middle of an install.
# A dedicated GRUB boot is always "fits": MemAvailable there describes a host
# that is about to stop running the desktop, and the sizing already kept a
# reserve.
windows_vm_memory_fit() {
    local ram="${1:-0}" avail swap_free
    case "$ram" in ''|*[!0-9]*) printf 'fits'; return 0 ;; esac
    if [ "$(windows_vm_boot_mode)" = "kiosk" ]; then
        printf 'fits'
        return 0
    fi
    avail="$(windows_vm_meminfo_mb MemAvailable)"
    # No reading at all is not evidence of a problem.
    if [ "$avail" -le 0 ]; then
        printf 'fits'
        return 0
    fi
    swap_free="$(windows_vm_meminfo_mb SwapFree)"
    if [ "$ram" -le "$avail" ]; then
        printf 'fits'
    elif [ "$ram" -le $(( avail + swap_free )) ]; then
        printf 'tight'
    else
        printf 'exceed'
    fi
}

# Refuse a start that cannot fit. Returns 1 only for "exceed", and only when
# the operator has not said to go ahead anyway.
windows_vm_memory_guard() {
    local ram="${1:-0}" fit avail swap_free
    fit="$(windows_vm_memory_fit "$ram")"
    avail="$(windows_vm_meminfo_mb MemAvailable)"
    swap_free="$(windows_vm_meminfo_mb SwapFree)"
    case "$fit" in
        tight)
            pz_warn "a VM pede ${ram} MiB e o host tem ${avail} MiB disponíveis agora; o resto sai da swap (${swap_free} MiB livres) e a sessão vai ficar lenta"
            ;;
        exceed)
            if [ "${PZ_WINDOWS_VM_ALLOW_MEMORY_OVERCOMMIT:-0}" = "1" ]; then
                pz_warn "a VM pede ${ram} MiB com ${avail} MiB disponíveis e ${swap_free} MiB de swap livre; seguindo por PZ_WINDOWS_VM_ALLOW_MEMORY_OVERCOMMIT=1"
                return 0
            fi
            pz_error "memória insuficiente: a VM pede ${ram} MiB, o host tem ${avail} MiB disponíveis e ${swap_free} MiB de swap livre"
            pz_error "feche aplicativos ou escolha um valor menor com --ram (mínimo do Windows 11: 4096)"
            return 1
            ;;
    esac
    return 0
}
