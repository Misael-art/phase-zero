#!/usr/bin/env bash
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/windows-vm/memory.sh"

SWTPM_BIN=""
SWTPM_RUNNING=false
SWTPM_SOCKET=""
SWTPM_PID=""
SWTPM_SERVICE_INSTALLED=false
VIRTIO_PINNED="0.1.285"
VIRTIO_PINNED_SHA="e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331"
VIRTIO_LATEST=""
VIRTIO_LATEST_URL=""
VIRTIO_OUTDATED=false
GRAPHICS_PROFILE="compat"
GRAPHICS_SUPPORTED=false
GRAPHICS_FALLBACK="compat"
GRAPHICS_FAILURES=()
GRAPHICS_CONTRACT="${PZ_WINDOWS_VM_GRAPHICS_CONTRACT:-$PZ_ROOT/linux/windows-vm/graphics-profiles.json}"
KVM_ACCESS=false
OVMF_PRESENT=false
RAM_MB=0
TOTAL_MB=0
CPUS=0
DISK_GB=0

cleanup() { true; }

swtpm_check() {
    SWTPM_BIN="$(command -v swtpm || true)"
    SWTPM_SERVICE_INSTALLED=false
    SWTPM_RUNNING=false

    [ -n "$SWTPM_BIN" ] || return 0

    local service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    [ -f "$service_dir/swtpm.service" ] && SWTPM_SERVICE_INSTALLED=true

    local sock="${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock"
    local pid_file="${XDG_RUNTIME_DIR:-/tmp}/swtpm.pid"

    if [ -S "$sock" ]; then
        SWTPM_SOCKET="$sock"
        SWTPM_RUNNING=true
        [ -f "$pid_file" ] && SWTPM_PID="$(cat "$pid_file" 2>/dev/null || true)"
    elif systemctl --user is-active swtpm.service >/dev/null 2>&1; then
        SWTPM_RUNNING=true
        SWTPM_SOCKET="$sock"
    fi
}

swtpm_auto_fix() {
    [ -z "$SWTPM_BIN" ] && { pz_warn "swtpm binary not found — cannot auto-start"; return 1; }
    if $SWTPM_RUNNING; then
        return 0
    fi

    local service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$service_dir"
    if ! $SWTPM_SERVICE_INSTALLED; then
        cp "$PZ_ROOT/linux/windows-vm/swtpm.service" "$service_dir/swtpm.service"
        systemctl --user daemon-reload
        SWTPM_SERVICE_INSTALLED=true
    fi

    local tpm_state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/swtpm"
    mkdir -p "$tpm_state_dir"

    systemctl --user enable --now swtpm.service 2>/dev/null || \
        swtpm socket --tpm2 \
            --tpmstate "dir=$tpm_state_dir" \
            --ctrl "type=unixio,path=${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock,terminate" \
            --pid "file=${XDG_RUNTIME_DIR:-/tmp}/swtpm.pid" \
            --log "file=${XDG_STATE_HOME:-$HOME/.local/state}/swtpm.log,level=20" \
            --daemon

    local i
    for ((i=0; i<50; i++)); do
        [ -S "${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock" ] && { SWTPM_RUNNING=true; SWTPM_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/swtpm.sock"; break; }
        sleep 0.05
    done
    $SWTPM_RUNNING || pz_warn "swtpm socket did not appear after start"
}

virtio_check() {
    local redirect
    redirect="$(curl -sI 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso' 2>/dev/null | grep -i '^location:' | tail -1 | tr -d '\r')" || true
    if [ -n "$redirect" ]; then
        local url="${redirect#*: }"
        VIRTIO_LATEST_URL="$url"
        local version
        version="$(echo "$url" | sed -n 's|.*virtio-win-\([0-9.]*\)-1/virtio-win.*|\1|p')" || true
        if [ -z "$version" ]; then
            version="$(echo "$url" | sed -n 's|.*virtio-win-\([0-9.]*\)/virtio-win.*|\1|p')"
        fi
        if [ -n "$version" ]; then
            VIRTIO_LATEST="$version"
            if [ "$VIRTIO_LATEST" != "$VIRTIO_PINNED" ]; then
                VIRTIO_OUTDATED=true
            fi
        fi
    fi
}

virtio_auto_fix() {
    $VIRTIO_OUTDATED || return 0
    [ -z "$VIRTIO_LATEST_URL" ] && { pz_warn "cannot resolve latest virtio-win URL"; return 1; }

    local vm_dir="${PZ_STATE}/windows-vm/vm"
    mkdir -p "$vm_dir"

    pz_info "downloading virtio-win $VIRTIO_LATEST → $vm_dir/virtio-win.iso"
    local ok=0
    if command -v curl >/dev/null 2>&1; then
        if curl -L -o "$vm_dir/virtio-win.iso" "$VIRTIO_LATEST_URL"; then
            ok=1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -O "$vm_dir/virtio-win.iso" "$VIRTIO_LATEST_URL"; then
            ok=1
        fi
    fi

    if [ "$ok" = "1" ]; then
        local actual
        actual="$(sha256sum "$vm_dir/virtio-win.iso" | cut -d' ' -f1)"
        pz_info "virtio-win.iso SHA-256: $actual"
        echo "  url: $VIRTIO_LATEST_URL"
        echo "  sha: $actual"
        echo "  pinned_version: $VIRTIO_LATEST"
    else
        pz_warn "virtio-win download failed"
        rm -f "$vm_dir/virtio-win.iso"
    fi
}

graphics_check() {
    GRAPHICS_FAILURES=()
    local qemu_bin="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
    local kvm_path="${PZ_GFX_KVM_PATH:-/dev/kvm}"

    [ -e "$kvm_path" ] || GRAPHICS_FAILURES+=("KVM not accessible")

    [ -e "$kvm_path" ] && KVM_ACCESS=true

    if pz_path_resolve ovmf_code \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE.fd >/dev/null 2>&1; then
        OVMF_PRESENT=true
    fi

    if ! jq -e '
        .schemaVersion == "windows-vm-graphics/v1"
        and (.profiles | type == "array")
        and all(.profiles[]; (.id | type == "string") and (.provisionSupported | type == "boolean"))
    ' "$GRAPHICS_CONTRACT" >/dev/null 2>&1; then
        GRAPHICS_FAILURES+=("graphics contract missing or invalid")
        GRAPHICS_SUPPORTED=false
        return 0
    fi
    if ! jq -e --arg profile "$GRAPHICS_PROFILE" \
        '.profiles[] | select(.id == $profile and .provisionSupported == true)' \
        "$GRAPHICS_CONTRACT" >/dev/null 2>&1; then
        GRAPHICS_FAILURES+=("profile $GRAPHICS_PROFILE is not supported by automated provisioning")
        GRAPHICS_SUPPORTED=false
        return 0
    fi

    case "$GRAPHICS_PROFILE" in
        compat)
            GRAPHICS_SUPPORTED=true
            ;;
        virtio-gl)
            local render_node="${PZ_GFX_RENDER_NODE:-}"
            if [ -z "$render_node" ]; then
                for node in /dev/dri/renderD*; do
                    [ -r "$node" ] && [ -w "$node" ] && { render_node="$node"; break; }
                done
            fi
            [ -n "$render_node" ] || GRAPHICS_FAILURES+=("no accessible render node")

            local has_virtio_vga_gl=false
            if [ -n "${PZ_GFX_QEMU_VIRTIO_VGA_GL:-}" ]; then
                [ "$PZ_GFX_QEMU_VIRTIO_VGA_GL" = "1" ] && has_virtio_vga_gl=true
            elif command -v "$qemu_bin" >/dev/null 2>&1; then
                "$qemu_bin" -device help 2>/dev/null | grep 'virtio-vga-gl' >/dev/null && has_virtio_vga_gl=true
            fi
            $has_virtio_vga_gl || GRAPHICS_FAILURES+=("QEMU lacks virtio-vga-gl device")

            local virgl_ok=false
            if [ -n "${PZ_GFX_VIRGL_PRESENT:-}" ]; then
                [ "$PZ_GFX_VIRGL_PRESENT" = "1" ] && virgl_ok=true
            else
                ldconfig -p 2>/dev/null | grep 'virglrenderer' >/dev/null && virgl_ok=true
            fi
            $virgl_ok || GRAPHICS_FAILURES+=("virglrenderer library not found")

            if [ -e "$kvm_path" ] && [ -n "$render_node" ] && $has_virtio_vga_gl && $virgl_ok; then
                GRAPHICS_SUPPORTED=true
            fi
            ;;
    esac
}

resource_check() {
    # MemTotal is not a budget. This field is what a caller reads to decide
    # whether the host can carry a guest, so it has to be the memory the host
    # can actually hand over. The total stays next to it for context.
    RAM_MB="$(windows_vm_meminfo_mb MemAvailable)"
    TOTAL_MB="$(windows_vm_meminfo_mb MemTotal)"
    CPUS="$(nproc 2>/dev/null || echo 0)"
    local root_avail
    root_avail="$(df -BG / | awk 'NR==2 {print $4}' 2>/dev/null | tr -d 'G' || echo 0)"
    DISK_GB="$root_avail"
}

emit_json() {
    local status="pass"
    [ -z "$SWTPM_BIN" ] && status="fail"
    if ! $SWTPM_RUNNING; then
        [ "$status" = "pass" ] && status="warn"
    fi
    if $VIRTIO_OUTDATED; then
        [ "$status" = "pass" ] && status="warn"
    fi
    if ! $GRAPHICS_SUPPORTED; then
        status="fail"
    fi

    jq -n \
        --arg status "$status" \
        --arg swtpmBin "${SWTPM_BIN:-}" \
        --argjson swtpmRunning "$SWTPM_RUNNING" \
        --arg swtpmSocket "${SWTPM_SOCKET:-}" \
        --arg swtpmPid "${SWTPM_PID:-}" \
        --argjson swtpmServiceInstalled "$SWTPM_SERVICE_INSTALLED" \
        --arg virtioPinned "$VIRTIO_PINNED" \
        --arg virtioLatest "${VIRTIO_LATEST:-$VIRTIO_PINNED}" \
        --argjson virtioOutdated "$VIRTIO_OUTDATED" \
        --arg virtioLatestUrl "${VIRTIO_LATEST_URL:-}" \
        --arg graphicsProfile "$GRAPHICS_PROFILE" \
        --argjson graphicsSupported "$GRAPHICS_SUPPORTED" \
        --arg graphicsFallback "$GRAPHICS_FALLBACK" \
        --argjson kvmAccess "$KVM_ACCESS" \
        --argjson ovmfPresent "$OVMF_PRESENT" \
        --argjson ramMb "$RAM_MB" \
        --argjson totalMb "$TOTAL_MB" \
        --argjson cpus "$CPUS" \
        --argjson diskGb "$DISK_GB" \
        --argjson graphicsFailures "$(if [ "${#GRAPHICS_FAILURES[@]}" -eq 0 ]; then echo '[]'; else printf '%s\n' "${GRAPHICS_FAILURES[@]}" | jq -R . | jq -s -c .; fi)" \
        '{
            status: $status,
            swtpm: {
                binary: ($swtpmBin != ""),
                running: $swtpmRunning,
                socket: $swtpmSocket,
                pid: $swtpmPid,
                serviceInstalled: $swtpmServiceInstalled
            },
            virtio: {
                pinned: $virtioPinned,
                latest: $virtioLatest,
                outdated: $virtioOutdated,
                latestUrl: $virtioLatestUrl
            },
            graphics: {
                profile: $graphicsProfile,
                supported: $graphicsSupported,
                fallback: $graphicsFallback,
                failures: $graphicsFailures
            },
            resources: {
                ramMb: $ramMb,
                totalMb: $totalMb,
                cpus: $cpus,
                diskGb: $diskGb,
                kvmAccess: $kvmAccess,
                ovmfPresent: $ovmfPresent
            }
        }'
}

run_checks() {
    resource_check
    swtpm_check
    virtio_check
    graphics_check
}

do_auto_fix() {
    if ! $SWTPM_RUNNING; then
        swtpm_auto_fix
    fi
    if $VIRTIO_OUTDATED; then
        virtio_auto_fix
    fi
    if ! $OVMF_PRESENT; then
        pz_info "installing edk2-ovmf..."
        pz_admin_run pacman -S --noconfirm edk2-ovmf 2>/dev/null || \
            pz_warn "could not install edk2-ovmf (admin bridge needed)"
    fi
    if ! ldconfig -p 2>/dev/null | grep 'virglrenderer' >/dev/null; then
        pz_info "installing virglrenderer..."
        pz_admin_run pacman -S --noconfirm virglrenderer 2>/dev/null || \
            pz_warn "could not install virglrenderer (admin bridge needed)"
    fi
}

emit_event() {
    local transition="$1" key="$2" old_val="$3" new_val="$4"
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --arg transition "$transition" \
        --arg key "$key" \
        --arg old "$old_val" \
        --arg new "$new_val" \
        '{timestamp: $ts, transition: $transition, key: $key, old: $old, new: $new}'
}

watch_loop() {
    local interval="${PZ_PREFLIGHT_WATCH_INTERVAL:-60}"
    local prev_state=""
    local cur_state key

    run_checks
    prev_state="$(emit_json 2>/dev/null || echo '{}')"

    while true; do
        sleep "$interval"
        run_checks
        cur_state="$(emit_json 2>/dev/null || echo '{}')"

        for key in swtpm.running swtpm.binary virtio.outdated graphics.supported ovmfPresent; do
            local old_val new_val
            old_val="$(echo "$prev_state" | jq -r ".$key" 2>/dev/null || echo 'null')"
            new_val="$(echo "$cur_state" | jq -r ".$key" 2>/dev/null || echo 'null')"
            if [ "$old_val" != "$new_val" ] && [ "$old_val" != "null" ]; then
                if [ "$new_val" = "true" ]; then
                    emit_event recovered "$key" "$old_val" "$new_val"
                elif [ "$new_val" = "false" ]; then
                    emit_event degraded "$key" "$old_val" "$new_val"
                fi
            fi
        done
        prev_state="$cur_state"
    done
}

main() {
    local AUTO_FIX=false JSON_OUT=false WATCH=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto-fix) AUTO_FIX=true; shift ;;
            --json) JSON_OUT=true; shift ;;
            --watch) WATCH=true; shift ;;
            --graphics) GRAPHICS_PROFILE="${2:-}"; shift 2 ;;
            --graphics=*) GRAPHICS_PROFILE="${1#*=}"; shift ;;
            --interval) PZ_PREFLIGHT_WATCH_INTERVAL="${2:-60}"; shift 2 ;;
            *) pz_error "unknown preflight option: $1"; return 1 ;;
        esac
    done

    run_checks

    if $WATCH; then
        watch_loop
        return 0
    fi

    if $AUTO_FIX; then
        do_auto_fix
    fi

    if $JSON_OUT; then
        emit_json
    fi
}

main "$@"
