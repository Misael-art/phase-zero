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

# How much the host keeps for itself, per profile. One definition so the
# sizing and the verdict cannot disagree: they used to, and the sizing was the
# only one that honoured it.
windows_vm_profile_reserve_mb() {
    if [ "$(windows_vm_boot_mode)" = "kiosk" ]; then
        printf '%s' "${PZ_WINDOWS_VM_HOST_RESERVE_MB:-2048}"
    else
        printf '%s' "${PZ_WINDOWS_VM_HOST_RESERVE_MB:-3072}"
    fi
}

# Pressure Stall Information says what the memory figures cannot: whether the
# host is already stalling. Overridable for the same reason as the meminfo
# file, and unread when only the meminfo is described — a suite that
# describes a host must not read the machine it happens to run on, or CI load
# would decide a verdict.
windows_vm_pressure_file() {
    if [ -n "${PZ_WINDOWS_VM_PRESSURE_FILE:-}" ]; then
        printf '%s' "$PZ_WINDOWS_VM_PRESSURE_FILE"
        return 0
    fi
    if [ -n "${PZ_WINDOWS_VM_MEMINFO_FILE:-}" ]; then
        # /dev/null yields no line, which reads as "no pressure measured".
        printf '%s' "/dev/null"
        return 0
    fi
    printf '%s' "/proc/pressure/memory"
}

# Empty means no reading. Absence of a reading is not evidence of pressure.
windows_vm_psi_some_avg10() {
    local value
    value="$(awk '/^some /{for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) {split($i, p, "="); print p[2]; exit}}' \
        "$(windows_vm_pressure_file)" 2>/dev/null || true)"
    case "$value" in
        *[0-9]*) printf '%s' "$value" ;;
        *) printf '' ;;
    esac
}

windows_vm_psi_some_max() {
    printf '%s' "${PZ_WINDOWS_VM_PSI_SOME_MAX:-10.0}"
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
    reserve="$(windows_vm_profile_reserve_mb)"

    if [ "$mode" = "kiosk" ]; then
        # Kernel, systemd, SDDM, gamescope, virtiofsd and swtpm all live in this
        # reserve. An OOM on the host side kills the VM outright, so it is not
        # squeezed further.
        ram=$(( total - reserve ))
    else
        # Leave the session responsive: take a share of what is actually free
        # right now, never more than 70% of the machine.
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

# Can the host hand over this much and still run what the profile expects it to
# run? Two axes, because the figure alone has never been enough:
#   fits   - the guest fits and the profile's reserve is left intact, and the
#            host is not already stalling
#   tight  - it runs, and the session pays: the guest leans on swap, the margin
#            under the reserve is too small, or pressure says it is stalling now
#   exceed - above MemAvailable plus free swap (or above MemTotal on a GRUB
#            boot): the kernel has nowhere to put it, and the OOM killer picks
#            the victim. On a desktop that can be the browser, the terminal, or
#            the VM in the middle of an install.
# What the margin measures depends on the profile: a live desktop is judged by
# MemAvailable, a GRUB boot that runs nothing but the VM by MemTotal.
windows_vm_memory_margin_mb() {
    local ram="${1:-0}" base
    case "$ram" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
    if [ "$(windows_vm_boot_mode)" = "kiosk" ]; then
        base="$(windows_vm_meminfo_mb MemTotal)"
    else
        base="$(windows_vm_meminfo_mb MemAvailable)"
    fi
    printf '%s' "$(( base - ram ))"
}

# PSI's "some" line is the share of time at least one task is stalled on
# memory. An unreadable file is not a reading, so it never blocks a start.
windows_vm_memory_pressure_high() {
    local psi max
    psi="$(windows_vm_psi_some_avg10)"
    [ -n "$psi" ] || return 1
    max="$(windows_vm_psi_some_max)"
    awk -v got="$psi" -v limit="$max" 'BEGIN { exit !(got + 0 >= limit + 0) }'
}

windows_vm_memory_fit() {
    local ram="${1:-0}" base swap_free reserve
    case "$ram" in ''|*[!0-9]*) printf 'fits'; return 0 ;; esac
    reserve="$(windows_vm_profile_reserve_mb)"
    if [ "$(windows_vm_boot_mode)" = "kiosk" ]; then
        base="$(windows_vm_meminfo_mb MemTotal)"
    else
        base="$(windows_vm_meminfo_mb MemAvailable)"
    fi
    # No reading at all is not evidence of a problem.
    if [ "$base" -le 0 ]; then
        printf 'fits'
        return 0
    fi
    if [ "$ram" -gt "$base" ]; then
        if [ "$(windows_vm_boot_mode)" = "kiosk" ]; then
            printf 'exceed'
            return 0
        fi
        swap_free="$(windows_vm_meminfo_mb SwapFree)"
        if [ "$ram" -gt $(( base + swap_free )) ]; then
            printf 'exceed'
            return 0
        fi
    fi
    if [ "$(( base - ram ))" -lt "$reserve" ] || windows_vm_memory_pressure_high; then
        printf 'tight'
        return 0
    fi
    printf 'fits'
}

# Say out loud what the host can do with this figure, and print the verdict.
# Split from the guard so the pre-check can report the same thing without
# deciding anything: it used to answer "success" for a VM the host could not
# hold, because only launch_vm ever looked at memory.
windows_vm_memory_notice() {
    local ram="${1:-0}" fit avail swap_free margin reserve psi mode
    fit="$(windows_vm_memory_fit "$ram")"
    if [ "$fit" = "fits" ]; then
        printf 'fits'
        return 0
    fi
    avail="$(windows_vm_meminfo_mb MemAvailable)"
    swap_free="$(windows_vm_meminfo_mb SwapFree)"
    margin="$(windows_vm_memory_margin_mb "$ram")"
    reserve="$(windows_vm_profile_reserve_mb)"
    mode="$(windows_vm_boot_mode)"
    if [ "$fit" = "exceed" ]; then
        pz_error "memória insuficiente: a VM pede ${ram} MiB, o host tem ${avail} MiB disponíveis e ${swap_free} MiB de swap livre"
        pz_error "feche aplicativos ou escolha um valor menor com --ram (mínimo do Windows 11: 4096)"
        printf 'exceed'
        return 0
    fi
    if [ "$mode" != "kiosk" ] && [ "$ram" -gt "$avail" ]; then
        pz_warn "a VM pede ${ram} MiB e o host tem ${avail} MiB disponíveis agora; o resto sai da swap (${swap_free} MiB livres) e a sessão vai ficar lenta"
    fi
    if [ "$margin" -lt "$reserve" ]; then
        pz_warn "a folga depois do convidado é ${margin} MiB e a reserva do perfil ${mode} é ${reserve} MiB; o convidado cabe, o resto do host não"
    fi
    psi="$(windows_vm_psi_some_avg10)"
    if [ -n "$psi" ] && windows_vm_memory_pressure_high; then
        pz_warn "pressão de memória no host: some avg10=${psi} acima do limite $(windows_vm_psi_some_max); adiar a inicialização é o que protege a sessão"
    fi
    printf '%s' "$fit"
}

# Refuse a start that cannot fit. Returns 1 only for "exceed", and only when
# the operator has not said to go ahead anyway.
windows_vm_memory_guard() {
    local ram="${1:-0}" fit
    fit="$(windows_vm_memory_notice "$ram")"
    if [ "$fit" = "exceed" ]; then
        if [ "${PZ_WINDOWS_VM_ALLOW_MEMORY_OVERCOMMIT:-0}" = "1" ]; then
            pz_warn "seguindo mesmo assim por PZ_WINDOWS_VM_ALLOW_MEMORY_OVERCOMMIT=1"
            return 0
        fi
        return 1
    fi
    return 0
}

# The figure saved in the config was right for the host that wrote it. A Deck
# that installed the VM through the GRUB boot saved 12288 and then could never
# launch it from the desktop: the value stayed pinned, the guard refused every
# start, and the only way out was a flag typed in a terminal.
#
# Used only when the figure came from the config. An explicit --ram is someone
# speaking now: it is honoured, and refused when the host cannot hold it.
windows_vm_configured_ram_mb() {
    local configured="${1:-}" fit default
    case "$configured" in
        ''|*[!0-9]*)
            if [ -z "$configured" ]; then
                default_ram_mb
            else
                # A figure this shell cannot read as MiB is not ours to judge.
                printf '%s' "$configured"
            fi
            return 0
            ;;
    esac
    fit="$(windows_vm_memory_fit "$configured")"
    if [ "$fit" != "exceed" ]; then
        printf '%s' "$configured"
        return 0
    fi
    default="$(default_ram_mb)"
    if [ "$default" -ge "$configured" ]; then
        # Nothing smaller would help: the host cannot hold even the floor.
        printf '%s' "$configured"
        return 0
    fi
    pz_warn "a configuração pede ${configured} MiB e o host não tem como entregar isso; a VM vai iniciar com ${default} MiB"
    pz_warn "para fixar um valor que o host sustente, edite PZ_WINDOWS_VM_RAM_MB ou passe --ram"
    printf '%s' "$default"
}
