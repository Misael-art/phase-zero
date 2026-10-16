#!/usr/bin/env bash
# graphics.sh - Windows VM graphics diagnostics and profile planning (v1).
# Safe by design: status/plan/guest-guide never mutate host or domain.
# apply only writes PZ_WINDOWS_VM_GRAPHICS_PROFILE into the managed config.
# No GRUB, initramfs, kernel cmdline, VFIO bind/unbind or SDDM changes here.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

# virsh output is parsed; force C locale so state strings stay stable.
virsh() { LC_ALL=C command virsh "$@"; }

ACTION="${1:-status}"
if [ $# -gt 0 ]; then
    shift
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
CONFIG_FILE="${PZ_WINDOWS_VM_CONFIG:-$CONFIG_DIR/windows-vm.conf}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm/graphics"

# Test/diagnostic override roots (fake sysfs, fake devices, fake QEMU).
GFX_SYS_ROOT="${PZ_GFX_SYSFS_ROOT:-/sys}"
GFX_DRI_DIR="${PZ_GFX_DRI_DIR:-/dev/dri}"
GFX_KVM_PATH="${PZ_GFX_KVM_PATH:-/dev/kvm}"
GFX_QEMU_BIN="${PZ_GFX_QEMU_BIN:-qemu-system-x86_64}"
GFX_PCI_ROOT="${PZ_GFX_PCI_ROOT:-$GFX_SYS_ROOT/bus/pci/devices}"
GFX_RUNTIME_TARGET_ROOT="${PZ_GFX_RUNTIME_TARGET_ROOT:-/}"
GFX_RUNTIME_BACKUP_ROOT="${PZ_GFX_RUNTIME_BACKUP_ROOT:-$(printf '%s/var/lib/phasezero/backups/windows-vm-runtime' "${GFX_RUNTIME_TARGET_ROOT%/}")}"

PROFILE=""
JSON_OUT=0
EXPERIMENTAL=0
ASSUME_YES=0
DRY_RUN="${PZ_DRY_RUN:-0}"
SAVE_GUIDE=0
PCI_DEVICES_OPTION=""
BACKUP_ID="latest"

KNOWN_PROFILES="auto compat virtio-gl virtio-venus rutabaga vfio-looking-glass"

usage() {
    cat <<EOF
PhaseZero Windows VM graphics - diagnostico e perfis de aceleracao (v1)

Usage:
  pz windows-vm graphics status [--json]
  pz windows-vm graphics plan --profile <auto|compat|virtio-gl|virtio-venus|rutabaga|vfio-looking-glass> [--json]
  pz windows-vm graphics apply --profile <compat|virtio-gl> [--experimental --yes] [--dry-run]
  pz windows-vm graphics remove
  pz windows-vm graphics doctor [--json]
  pz windows-vm graphics runtime status [--json]
  pz windows-vm graphics runtime install [--dry-run]
  pz windows-vm graphics runtime rollback [--backup <id|latest>] [--dry-run]
  pz windows-vm graphics guest-guide [--save]

Perfis:
  compat             padrao estavel: QXL/SPICE (libvirt) e virtio-vga (raw QEMU)
  virtio-gl          virtio-vga-gl + display gtk,gl=on (raw QEMU, experimental)
  virtio-venus       Vulkan paravirtual (Mesa Venus) - somente plano na v1
  rutabaga           gfxstream/rutabaga - somente plano na v1
  vfio-looking-glass GPU passthrough + Looking Glass - somente plano na v1

v1 nunca altera GRUB, initramfs, modulos VFIO, SDDM ou dominio em execucao.
EOF
}

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) [ $# -ge 2 ] || { pz_error "--profile requires a value"; return 2; }; PROFILE="$2"; shift 2 ;;
            --profile=*) PROFILE="${1#*=}"; shift ;;
            --json) JSON_OUT=1; shift ;;
            --experimental) EXPERIMENTAL=1; shift ;;
            --yes|-y) ASSUME_YES=1; shift ;;
            --dry-run|-n) DRY_RUN=1; shift ;;
            --save) SAVE_GUIDE=1; shift ;;
            --pci-devices) [ $# -ge 2 ] || { pz_error "--pci-devices requires a value"; return 2; }; PCI_DEVICES_OPTION="$2"; shift 2 ;;
            --pci-devices=*) PCI_DEVICES_OPTION="${1#*=}"; shift ;;
            --backup) [ $# -ge 2 ] || { pz_error "--backup requires a value"; return 2; }; BACKUP_ID="$2"; shift 2 ;;
            --backup=*) BACKUP_ID="${1#*=}"; shift ;;
            --help|-h) usage; exit 0 ;;
            *) pz_error "unknown graphics option: $1"; return 1 ;;
        esac
    done
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    # PhaseZero writes this file as shell-escaped KEY=VALUE pairs.
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
}

runtime_target_path() {
    local path="/${1#/}"
    if [ "$GFX_RUNTIME_TARGET_ROOT" = "/" ]; then
        printf '%s\n' "$path"
    else
        printf '%s%s\n' "${GFX_RUNTIME_TARGET_ROOT%/}" "$path"
    fi
}

runtime_artifact_specs() {
    cat <<EOF
session|$PZ_ROOT/linux/windows-vm/windows-vm-session.sh|/usr/local/lib/phasezero/windows-vm-session|0755
display|$PZ_ROOT/linux/steamdeck/display-session.sh|/usr/local/lib/phasezero/display-session|0644
launcher|$PZ_ROOT/linux/windows-vm/windows-vm.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/windows-vm.sh|0755
graphics|$PZ_ROOT/linux/windows-vm/graphics.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/graphics.sh|0755
rescue|$PZ_ROOT/linux/windows-vm/rescue.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/rescue.sh|0644
guest-login|$PZ_ROOT/linux/windows-vm/guest-login.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/guest-login.sh|0755
guest-login-powershell|$PZ_ROOT/linux/windows-vm/guest-login.ps1|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/guest-login.ps1|0644
provision|$PZ_ROOT/linux/windows-vm/provision.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/provision.sh|0644
memory|$PZ_ROOT/linux/windows-vm/memory.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/memory.sh|0644
virtio-source|$PZ_ROOT/linux/windows-vm/virtio-source.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/virtio-source.sh|0644
graphics-contract|$PZ_ROOT/linux/windows-vm/graphics-profiles.json|/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/graphics-profiles.json|0644
common|$PZ_ROOT/linux/lib/common.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/lib/common.sh|0644
ledger|$PZ_ROOT/linux/lib/ledger.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/lib/ledger.sh|0644
desktop|$PZ_ROOT/linux/lib/desktop.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/lib/desktop.sh|0644
flatpak|$PZ_ROOT/linux/lib/flatpak.sh|/usr/local/lib/phasezero/windows-vm-runtime/linux/lib/flatpak.sh|0644
EOF
}

runtime_artifacts_json() {
    local name source relative mode target installed current source_exists
    local -a entries=()
    while IFS='|' read -r name source relative mode; do
        [ -n "$name" ] || continue
        target="$(runtime_target_path "$relative")"
        installed=no; current=no; source_exists=no
        [ -f "$target" ] && installed=yes
        [ -f "$source" ] && source_exists=yes
        [ "$source_exists" = "yes" ] && [ "$installed" = "yes" ] && cmp -s "$source" "$target" && current=yes
        entries+=("$(jq -n \
            --arg name "$name" --arg source "$source" --arg target "$target" \
            --arg mode "$mode" --arg installed "$installed" --arg current "$current" --arg sourceExists "$source_exists" \
            '{name: $name, source: $source, target: $target, mode: $mode, sourceExists: ($sourceExists == "yes"), installed: ($installed == "yes"), current: ($current == "yes")}')")
    done < <(runtime_artifact_specs)
    printf '%s\n' "${entries[@]}" | jq -s .
}

runtime_status_json() {
    local artifacts status
    artifacts="$(runtime_artifacts_json)"
    status="$(jq -r 'if all(.[]; .current) then "ok" elif any(.[]; .installed) then "needsrepair" else "needsinstall" end' <<< "$artifacts")"
    jq -n \
        --arg status "$status" \
        --arg targetRoot "$GFX_RUNTIME_TARGET_ROOT" \
        --arg backupRoot "$GFX_RUNTIME_BACKUP_ROOT" \
        --argjson artifacts "$artifacts" \
        '{schemaVersion: 1, status: $status, targetRoot: $targetRoot, backupRoot: $backupRoot, artifacts: $artifacts,
          summary: {total: ($artifacts|length), current: ([$artifacts[]|select(.current)]|length), stale: ([$artifacts[]|select(.installed and (.current|not))]|length), missing: ([$artifacts[]|select(.installed|not)]|length)}}'
}

require_runtime_admin() {
    [ "$GFX_RUNTIME_TARGET_ROOT" != "/" ] && return 0
    [ "$EUID" -eq 0 ] && return 0
    pz_error "runtime install/rollback requer admin bridge; use phasezero-admin ou a UI PhaseZero"
    return 77
}

latest_runtime_backup() {
    local path latest=""
    for path in "$GFX_RUNTIME_BACKUP_ROOT"/*; do
        [ -d "$path" ] || continue
        latest="$(basename "$path")"
    done
    printf '%s\n' "$latest"
}

runtime_install() {
    parse_options "$@"
    local before
    before="$(runtime_status_json)"
    if [ "$DRY_RUN" = "1" ]; then
        jq '. + {dryRun: true, operation: "install", wouldChange: [.artifacts[] | select(.current|not) | .name]}' <<< "$before"
        return 0
    fi
    require_runtime_admin
    if jq -e '.status == "ok"' <<< "$before" >/dev/null; then
        [ "$JSON_OUT" = "1" ] || pz_info "Windows VM graphics runtime already current"
        printf '%s\n' "$before"
        return 0
    fi

    local backup_id backup_dir name source relative mode target backup_file existed
    local -a manifest_entries=()
    backup_id="$(date +%Y%m%d-%H%M%S)-$$"
    backup_dir="$GFX_RUNTIME_BACKUP_ROOT/$backup_id"
    install -d -m 0755 "$backup_dir/files"
    while IFS='|' read -r name source relative mode; do
        [ -f "$source" ] || { pz_error "runtime source missing: $source"; return 1; }
        target="$(runtime_target_path "$relative")"
        backup_file="$backup_dir/files$relative"
        existed=no
        if [ -f "$target" ]; then
            existed=yes
            install -d -m 0755 "$(dirname "$backup_file")"
            cp -a "$target" "$backup_file"
        fi
        manifest_entries+=("$(jq -n --arg name "$name" --arg target "$target" --arg relative "$relative" --arg mode "$mode" --arg existed "$existed" '{name: $name, target: $target, relative: $relative, mode: $mode, existed: ($existed == "yes")}')")
    done < <(runtime_artifact_specs)
    printf '%s\n' "${manifest_entries[@]}" | jq -s --arg id "$backup_id" '{schemaVersion: 1, id: $id, artifacts: .}' > "$backup_dir/manifest.json"

    while IFS='|' read -r name source relative mode; do
        target="$(runtime_target_path "$relative")"
        install -d -m 0755 "$(dirname "$target")"
        install -m "$mode" "$source" "$target"
    done < <(runtime_artifact_specs)
    local after
    after="$(runtime_status_json)"
    jq -e '.status == "ok"' <<< "$after" >/dev/null || { pz_error "runtime verification failed; backup: $backup_id"; return 1; }
    [ "$JSON_OUT" = "1" ] || pz_info "Windows VM graphics runtime updated; backup=$backup_id"
    jq --arg backupId "$backup_id" '. + {operation: "install", backupId: $backupId}' <<< "$after"
}

runtime_rollback() {
    parse_options "$@"
    local selected="$BACKUP_ID"
    [ "$selected" = "latest" ] && selected="$(latest_runtime_backup)"
    [ -n "$selected" ] || { pz_error "runtime backup not found"; return 1; }
    [[ "$selected" =~ ^[A-Za-z0-9._-]+$ ]] || { pz_error "invalid backup id: $selected"; return 1; }
    local backup_dir="$GFX_RUNTIME_BACKUP_ROOT/$selected" manifest="$GFX_RUNTIME_BACKUP_ROOT/$selected/manifest.json"
    [ -f "$manifest" ] || { pz_error "runtime backup manifest missing: $selected"; return 1; }
    if [ "$DRY_RUN" = "1" ]; then
        jq --arg id "$selected" '{schemaVersion: 1, status: "ok", dryRun: true, operation: "rollback", backupId: $id, artifacts: .artifacts}' "$manifest"
        return 0
    fi
    require_runtime_admin
    local entry target relative mode existed backup_file
    while IFS= read -r entry; do
        target="$(jq -r '.target' <<< "$entry")"
        relative="$(jq -r '.relative' <<< "$entry")"
        mode="$(jq -r '.mode' <<< "$entry")"
        existed="$(jq -r '.existed' <<< "$entry")"
        backup_file="$backup_dir/files$relative"
        if [ "$existed" = "true" ]; then
            [ -f "$backup_file" ] || { pz_error "runtime backup file missing: $backup_file"; return 1; }
            install -d -m 0755 "$(dirname "$target")"
            install -m "$mode" "$backup_file" "$target"
        else
            rm -f "$target"
        fi
    done < <(jq -c '.artifacts[]' "$manifest")
    [ "$JSON_OUT" = "1" ] || pz_info "Windows VM graphics runtime rolled back: $selected"
    jq --arg id "$selected" '. + {operation: "rollback", backupId: $id}' <<< "$(runtime_status_json)"
}

cmd_runtime() {
    local sub="${1:-status}"
    if [ $# -gt 0 ]; then
        shift || true
    fi
    case "$sub" in
        status)
            parse_options "$@"
            local json
            json="$(runtime_status_json)"
            if [ "$JSON_OUT" = "1" ]; then printf '%s\n' "$json"; else
                echo "Windows VM graphics runtime: $(jq -r '.status' <<< "$json")"
                jq -r '.artifacts[] | "  \(.name): " + (if .current then "current" elif .installed then "stale" else "missing" end)' <<< "$json"
            fi
            ;;
        install|sync|repair) runtime_install "$@" ;;
        rollback) runtime_rollback "$@" ;;
        *) pz_error "usage: windows-vm graphics runtime (status|install|rollback)"; return 1 ;;
    esac
}

libvirt_uri() {
    printf '%s\n' "${PZ_WINDOWS_VM_LIBVIRT_URI:-qemu:///system}"
}

windows_name_hint() {
    local value="${1,,}"
    [[ "$value" =~ windows|win(vm|xp|vista|[0-9]+) ]] ||
        [[ "$value" =~ (^|[^[:alnum:]])win([^[:alnum:]]|$) ]]
}

find_windows_domain() {
    local configured="${PZ_WINDOWS_VM_LIBVIRT_DOMAIN:-}"
    [ -n "$configured" ] && { printf '%s\n' "$configured"; return 0; }
    type -P virsh >/dev/null 2>&1 || return 0
    local domain
    while IFS= read -r domain; do
        [ -n "$domain" ] || continue
        windows_name_hint "$domain" && { printf '%s\n' "$domain"; return 0; }
    done < <(virsh -c "$(libvirt_uri)" list --all --name 2>/dev/null)
    return 0
}

domain_state() {
    local domain="$1"
    [ -n "$domain" ] || { echo missing; return 0; }
    virsh -c "$(libvirt_uri)" domstate "$domain" 2>/dev/null | sed -n 1p || echo unavailable
}

domain_xml() {
    local domain="$1"
    [ -n "$domain" ] || return 0
    virsh -c "$(libvirt_uri)" dumpxml "$domain" 2>/dev/null || true
}

xml_attr_first() {
    # xml_attr_first "<tag prefix" "$xml" -> first attribute value of type='...'
    local pattern="$1" xml="$2"
    grep -o "${pattern} type='[^']*'" <<< "$xml" 2>/dev/null |
        sed -n "1s/.*type='\([^']*\)'.*/\1/p" || true
}

domain_video_model() {
    # Scope <model> lookup to the <video> block: interfaces also carry
    # <model type='virtio'/> and would win a whole-document first match.
    local xml="$1"
    sed -n '/<video/,/<\/video>/p' <<< "$xml" |
        grep -o "<model type='[^']*'" 2>/dev/null |
        sed -n "1s/.*type='\([^']*\)'.*/\1/p" || true
}

# --- host detection -----------------------------------------------------

pci_vendor_label() {
    case "$1" in
        0x1002|0x1022) echo amd ;;
        0x10de) echo nvidia ;;
        0x8086) echo intel ;;
        *) echo unknown ;;
    esac
}

host_gpus_json() {
    local card dev vendor device slot label entries=()
    for card in "$GFX_SYS_ROOT"/class/drm/card[0-9]*; do
        [ -e "$card" ] || continue
        case "$(basename "$card")" in
            *-*) continue ;; # connectors like card1-eDP-1
        esac
        dev="$card/device"
        [ -f "$dev/vendor" ] || continue
        vendor="$(cat "$dev/vendor" 2>/dev/null || true)"
        device="$(cat "$dev/device" 2>/dev/null || true)"
        slot="$(sed -n 's/^PCI_SLOT_NAME=//p' "$dev/uevent" 2>/dev/null | sed -n 1p)"
        label="$(pci_vendor_label "$vendor")"
        entries+=("$(jq -n \
            --arg card "$(basename "$card")" \
            --arg vendor "$label" \
            --arg vendorId "$vendor" \
            --arg deviceId "$device" \
            --arg pci "$slot" \
            '{card: $card, vendor: $vendor, vendorId: $vendorId, deviceId: $deviceId, pci: $pci}')")
    done
    if [ "${#entries[@]}" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "${entries[@]}" | jq -s .
    fi
}

render_nodes_json() {
    local node entries=()
    for node in "$GFX_DRI_DIR"/renderD*; do
        [ -e "$node" ] || continue
        entries+=("$node")
    done
    if [ "${#entries[@]}" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "${entries[@]}" | jq -R . | jq -s .
    fi
}

accessible_render_node() {
    local node
    for node in "$GFX_DRI_DIR"/renderD*; do
        [ -r "$node" ] && [ -w "$node" ] && { printf '%s\n' "$node"; return 0; }
    done
    return 1
}

iommu_group_count() {
    local count=0 group
    for group in "$GFX_SYS_ROOT"/kernel/iommu_groups/*; do
        [ -e "$group" ] || continue
        count=$((count + 1))
    done
    echo "$count"
}

kvm_available() {
    [ -r "$GFX_KVM_PATH" ] && [ -w "$GFX_KVM_PATH" ]
}

qemu_device_help() {
    command -v "$GFX_QEMU_BIN" >/dev/null 2>&1 || return 0
    "$GFX_QEMU_BIN" -device help 2>/dev/null || true
}

qemu_display_help() {
    command -v "$GFX_QEMU_BIN" >/dev/null 2>&1 || return 0
    "$GFX_QEMU_BIN" -display help 2>/dev/null || true
}

qemu_venus_supported() {
    command -v "$GFX_QEMU_BIN" >/dev/null 2>&1 || return 1
    "$GFX_QEMU_BIN" -device virtio-vga-gl,help 2>/dev/null | grep -q 'venus'
}

normalize_pci_address() {
    local address="${1,,}"
    [[ "$address" =~ ^[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] && address="0000:$address"
    [[ "$address" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || return 1
    printf '%s\n' "$address"
}

array_contains() {
    local expected="$1" value
    shift
    for value in "$@"; do
        [ "$value" = "$expected" ] && return 0
    done
    return 1
}

append_unique_blocker() {
    local message="$1" existing
    for existing in "${GFX_VFIO_BLOCKERS[@]:-}"; do
        [ "$existing" = "$message" ] && return 0
    done
    GFX_VFIO_BLOCKERS+=("$message")
}

collect_vfio_devices() {
    GFX_VFIO_DEVICES_JSON='[]'
    GFX_VFIO_DEVICES_NORMALIZED=""
    local raw="${GFX_PCI_DEVICES//,/ }" token address
    local -a selected=() entries=()
    for token in $raw; do
        if ! address="$(normalize_pci_address "$token")"; then
            append_unique_blocker "endereco PCI invalido: $token"
            continue
        fi
        array_contains "$address" "${selected[@]:-}" || selected+=("$address")
    done
    if [ "${#selected[@]}" -eq 0 ]; then
        append_unique_blocker "PZ_WINDOWS_VM_PCI_DEVICES nao configurado"
        return 0
    fi
    GFX_VFIO_DEVICES_NORMALIZED="${selected[*]}"

    local has_display=0 has_audio=0 path class group_path group member member_address
    local -a members=()
    for address in "${selected[@]}"; do
        path="$GFX_PCI_ROOT/$address"
        class=""; group=""; members=()
        if [ ! -e "$path" ]; then
            append_unique_blocker "dispositivo PCI ausente: $address"
        else
            class="$(cat "$path/class" 2>/dev/null || true)"
            case "$class" in
                0x03*) has_display=1 ;;
                0x0403*) has_audio=1 ;;
            esac
            group_path="$(readlink -f "$path/iommu_group" 2>/dev/null || true)"
            if [ -z "$group_path" ] || [ ! -d "$group_path" ]; then
                append_unique_blocker "grupo IOMMU ausente para $address"
            else
                group="$(basename "$group_path")"
                for member in "$group_path"/devices/*; do
                    [ -e "$member" ] || continue
                    member_address="$(basename "$member")"
                    members+=("$member_address")
                    if ! array_contains "$member_address" "${selected[@]}"; then
                        append_unique_blocker "grupo IOMMU $group incompleto: inclua $member_address"
                    fi
                done
            fi
        fi
        entries+=("$(jq -n \
            --arg address "$address" \
            --arg class "$class" \
            --arg group "$group" \
            --arg exists "$([ -e "$path" ] && echo yes || echo no)" \
            --argjson members "$(if [ "${#members[@]}" -eq 0 ]; then echo '[]'; else printf '%s\n' "${members[@]}" | jq -R . | jq -s .; fi)" \
            '{address: $address, exists: ($exists == "yes"), class: $class, iommuGroup: $group, groupMembers: $members}')")
    done
    [ "$has_display" = "1" ] || append_unique_blocker "selecao VFIO sem funcao de GPU/display (classe PCI 0x03)"
    if [ "$has_audio" != "1" ] && [ "${PZ_WINDOWS_VM_VFIO_ALLOW_NO_AUDIO:-0}" != "1" ]; then
        append_unique_blocker "selecao VFIO sem funcao de audio HDMI/DP; inclua GPU + audio ou defina PZ_WINDOWS_VM_VFIO_ALLOW_NO_AUDIO=1"
    fi
    GFX_VFIO_DEVICES_JSON="$(printf '%s\n' "${entries[@]}" | jq -s .)"
}

# --- profile evaluation -------------------------------------------------

# Populates GFX_* globals used by status/plan/apply.
collect_facts() {
    load_config
    GFX_GPUS_JSON="$(host_gpus_json)"
    GFX_RENDER_JSON="$(render_nodes_json)"
    GFX_RENDER_COUNT="$(jq 'length' <<< "$GFX_RENDER_JSON")"
    GFX_RENDER_NODE="$(accessible_render_node || true)"
    GFX_IOMMU_GROUPS="$(iommu_group_count)"
    GFX_KVM=no; kvm_available && GFX_KVM=yes
    GFX_QEMU_PATH="$(command -v "$GFX_QEMU_BIN" 2>/dev/null || true)"
    local device_help display_help
    device_help="$(qemu_device_help)"
    display_help="$(qemu_display_help)"
    GFX_QEMU_VGA_GL=no
    grep -q 'virtio-vga-gl' <<< "$device_help" && GFX_QEMU_VGA_GL=yes
    GFX_QEMU_GPU_GL_PCI=no
    grep -q 'virtio-gpu-gl-pci' <<< "$device_help" && GFX_QEMU_GPU_GL_PCI=yes
    GFX_QEMU_RUTABAGA=no
    grep -q 'virtio-gpu-rutabaga' <<< "$device_help" && GFX_QEMU_RUTABAGA=yes
    GFX_QEMU_VENUS=no
    qemu_venus_supported && GFX_QEMU_VENUS=yes
    GFX_DISPLAY_GTK=no
    grep -qw 'gtk' <<< "$display_help" && GFX_DISPLAY_GTK=yes
    GFX_DISPLAY_SDL=no
    grep -qw 'sdl' <<< "$display_help" && GFX_DISPLAY_SDL=yes
    GFX_DISPLAY_DBUS=no
    grep -qw 'dbus' <<< "$display_help" && GFX_DISPLAY_DBUS=yes
    GFX_DISPLAY_SPICE_APP=no
    grep -qw 'spice-app' <<< "$display_help" && GFX_DISPLAY_SPICE_APP=yes
    GFX_LOOKING_GLASS="${PZ_GFX_LOOKING_GLASS_BIN:-$(command -v looking-glass-client 2>/dev/null || true)}"
    [ -n "$GFX_LOOKING_GLASS" ] && [ -x "$GFX_LOOKING_GLASS" ] || GFX_LOOKING_GLASS=""
    GFX_PCI_DEVICES="${PCI_DEVICES_OPTION:-${PZ_WINDOWS_VM_PCI_DEVICES:-}}"
    GFX_PROFILE_CONFIGURED="${PZ_WINDOWS_VM_GRAPHICS_PROFILE:-compat}"
    GFX_DOMAIN="$(find_windows_domain)"
    GFX_DOMAIN_STATE="$(domain_state "$GFX_DOMAIN")"
    local xml=""
    [ -n "$GFX_DOMAIN" ] && xml="$(domain_xml "$GFX_DOMAIN")"
    GFX_VIDEO_MODEL="$(domain_video_model "$xml")"
    GFX_GRAPHICS_TYPE="$(xml_attr_first '<graphics' "$xml")"

    # virtio-gl blockers
    GFX_GL_BLOCKERS=()
    [ "$GFX_KVM" = "yes" ] || GFX_GL_BLOCKERS+=("KVM ausente ou sem acesso read/write: $GFX_KVM_PATH")
    [ "$GFX_RENDER_COUNT" -gt 0 ] || GFX_GL_BLOCKERS+=("render node ausente em $GFX_DRI_DIR")
    if [ "$GFX_RENDER_COUNT" -gt 0 ] && [ -z "$GFX_RENDER_NODE" ]; then
        GFX_GL_BLOCKERS+=("nenhum render node possui acesso read/write em $GFX_DRI_DIR")
    fi
    [ -n "$GFX_QEMU_PATH" ] || GFX_GL_BLOCKERS+=("qemu-system-x86_64 ausente")
    if [ -n "$GFX_QEMU_PATH" ] && [ "$GFX_QEMU_VGA_GL" != "yes" ]; then
        GFX_GL_BLOCKERS+=("QEMU sem device virtio-vga-gl")
    fi
    [ "$GFX_DISPLAY_GTK" = "yes" ] || GFX_GL_BLOCKERS+=("QEMU sem display GTK necessario para gtk,gl=on")
    GFX_GL_ELIGIBLE=no
    [ "${#GFX_GL_BLOCKERS[@]}" -eq 0 ] && GFX_GL_ELIGIBLE=yes

    # VFIO viability
    GFX_VFIO_BLOCKERS=()
    GFX_VFIO_VIABILITY=blocked
    if [ "$GFX_IOMMU_GROUPS" -eq 0 ]; then
        GFX_VFIO_BLOCKERS+=("IOMMU groups ausentes neste boot (VFIO indisponivel)")
    fi
    collect_vfio_devices
    [ -n "$GFX_LOOKING_GLASS" ] || GFX_VFIO_BLOCKERS+=("looking-glass-client ausente no host")
    if [ "$GFX_DOMAIN_STATE" = "running" ]; then
        GFX_VFIO_BLOCKERS+=("dominio libvirt em execucao: $GFX_DOMAIN")
    fi
    [ "${#GFX_VFIO_BLOCKERS[@]}" -eq 0 ] && GFX_VFIO_VIABILITY="eligible-plan-only"

    # Venus: experimental plan eligible, but apply blocked for Windows guests in v1.
    GFX_VENUS_BLOCKERS=()
    [ "$GFX_QEMU_VENUS" = "yes" ] || GFX_VENUS_BLOCKERS+=("QEMU sem suporte venus em virtio-vga-gl (kernel 6.7+ e mesa 23+ exigidos)")
    GFX_VENUS_APPLY_BLOCKED=("apply bloqueado na v1: driver guest Windows nao validado, prereqs nao fixados, sem cobertura de testes")
    GFX_RUTABAGA_BLOCKERS=("driver guest Windows para rutabaga/gfxstream nao validado (apply bloqueado na v1)")
    [ "$GFX_QEMU_RUTABAGA" = "yes" ] || GFX_RUTABAGA_BLOCKERS+=("QEMU sem device virtio-gpu-rutabaga")

    # Recommended: compat stays the stable default in v1; acceleration is opt-in.
    GFX_RECOMMENDED=compat
    GFX_EXPERIMENTAL_CANDIDATE=""
    [ "$GFX_GL_ELIGIBLE" = "yes" ] && GFX_EXPERIMENTAL_CANDIDATE="virtio-gl"
    return 0
}

blockers_json() {
    if [ "$#" -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -s 'map(select(length > 0))'
    fi
}

status_json() {
    collect_facts
    jq -n \
        --argjson gpus "$GFX_GPUS_JSON" \
        --argjson renderNodes "$GFX_RENDER_JSON" \
        --arg selectedRenderNode "$GFX_RENDER_NODE" \
        --arg kvm "$GFX_KVM" \
        --arg iommuGroups "$GFX_IOMMU_GROUPS" \
        --arg qemu "$GFX_QEMU_PATH" \
        --arg vgaGl "$GFX_QEMU_VGA_GL" \
        --arg gpuGlPci "$GFX_QEMU_GPU_GL_PCI" \
        --arg venus "$GFX_QEMU_VENUS" \
        --arg rutabaga "$GFX_QEMU_RUTABAGA" \
        --arg dispGtk "$GFX_DISPLAY_GTK" \
        --arg dispSdl "$GFX_DISPLAY_SDL" \
        --arg dispDbus "$GFX_DISPLAY_DBUS" \
        --arg dispSpiceApp "$GFX_DISPLAY_SPICE_APP" \
        --arg domain "$GFX_DOMAIN" \
        --arg domainState "$GFX_DOMAIN_STATE" \
        --arg videoModel "$GFX_VIDEO_MODEL" \
        --arg graphicsType "$GFX_GRAPHICS_TYPE" \
        --arg lookingGlass "$GFX_LOOKING_GLASS" \
        --arg vfioViability "$GFX_VFIO_VIABILITY" \
        --arg pciDevices "$GFX_PCI_DEVICES" \
        --arg normalizedPciDevices "$GFX_VFIO_DEVICES_NORMALIZED" \
        --argjson vfioDevices "$GFX_VFIO_DEVICES_JSON" \
        --arg configured "$GFX_PROFILE_CONFIGURED" \
        --arg recommended "$GFX_RECOMMENDED" \
        --arg experimentalCandidate "$GFX_EXPERIMENTAL_CANDIDATE" \
        --arg glEligible "$GFX_GL_ELIGIBLE" \
        --argjson glBlockers "$(blockers_json "${GFX_GL_BLOCKERS[@]:-}")" \
        --argjson vfioBlockers "$(blockers_json "${GFX_VFIO_BLOCKERS[@]:-}")" \
        --argjson venusBlockers "$(blockers_json "${GFX_VENUS_BLOCKERS[@]:-}")" \
        --argjson rutabagaBlockers "$(blockers_json "${GFX_RUTABAGA_BLOCKERS[@]:-}")" \
        '{
            host: {
                gpus: $gpus,
                renderNodes: $renderNodes,
                selectedRenderNode: $selectedRenderNode,
                kvm: ($kvm == "yes"),
                iommuGroups: ($iommuGroups | tonumber)
            },
            qemu: {
                binary: $qemu,
                virtioVgaGl: ($vgaGl == "yes"),
                virtioGpuGlPci: ($gpuGlPci == "yes"),
                venus: ($venus == "yes"),
                rutabaga: ($rutabaga == "yes"),
                displays: {gtk: ($dispGtk == "yes"), sdl: ($dispSdl == "yes"), dbus: ($dispDbus == "yes"), spiceApp: ($dispSpiceApp == "yes")}
            },
            libvirt: {
                domain: $domain,
                state: $domainState,
                videoModel: $videoModel,
                graphicsType: $graphicsType
            },
            lookingGlass: {client: $lookingGlass},
            vfio: {
                viability: $vfioViability,
                pciDevices: $pciDevices,
                normalizedPciDevices: $normalizedPciDevices,
                devices: $vfioDevices,
                blockers: $vfioBlockers
            },
            config: {profile: $configured},
            recommended: {
                profile: $recommended,
                experimentalCandidate: $experimentalCandidate,
                note: "v1: compat permanece estavel; VirtIO GL valida caminho host, sem garantir 3D no Windows; VFIO permanece plan-only"
            },
            profiles: {
                "compat": {eligible: true, mode: "stable", blockers: []},
                "virtio-gl": {eligible: ($glEligible == "yes"), mode: "experimental", blockers: $glBlockers},
                "virtio-venus": {eligible: ($venus == "yes"), mode: "experimental", blockers: $venusBlockers},
                "rutabaga": {eligible: false, mode: "experimental-blocked", blockers: $rutabagaBlockers},
                "vfio-looking-glass": {eligible: ($vfioViability == "eligible-plan-only"), mode: "plan-only", blockers: $vfioBlockers}
            }
        }'
}

cmd_status() {
    parse_options "$@"
    if [ "$JSON_OUT" = "1" ]; then
        status_json
        return 0
    fi
    local json
    json="$(status_json)"
    echo "PhaseZero Windows VM graphics status"
    echo "  gpus: $(jq -r '[.host.gpus[] | .vendor + " (" + .pci + ")"] | join(", ") // ""' <<< "$json")"
    echo "  render_nodes: $(jq -r '.host.renderNodes | join(", ")' <<< "$json")"
    echo "  kvm: $(jq -r '.host.kvm' <<< "$json")"
    echo "  iommu_groups: $(jq -r '.host.iommuGroups' <<< "$json")"
    echo "  qemu_virtio_vga_gl: $(jq -r '.qemu.virtioVgaGl' <<< "$json")"
    echo "  qemu_venus: $(jq -r '.qemu.venus' <<< "$json")"
    echo "  qemu_rutabaga: $(jq -r '.qemu.rutabaga' <<< "$json")"
    echo "  libvirt_domain: $(jq -r '.libvirt.domain' <<< "$json")"
    echo "  libvirt_video: $(jq -r '.libvirt.videoModel' <<< "$json")"
    echo "  libvirt_display: $(jq -r '.libvirt.graphicsType' <<< "$json")"
    echo "  looking_glass_client: $(jq -r '.lookingGlass.client' <<< "$json")"
    echo "  vfio_viability: $(jq -r '.vfio.viability' <<< "$json")"
    echo "  configured_profile: $(jq -r '.config.profile' <<< "$json")"
    echo "  recommended_profile: $(jq -r '.recommended.profile' <<< "$json")"
    echo "  experimental_candidate: $(jq -r '.recommended.experimentalCandidate' <<< "$json")"
}

doctor_json() {
    local graphics runtime
    graphics="$(status_json)"
    runtime="$(runtime_status_json)"
    jq -n --argjson graphics "$graphics" --argjson runtime "$runtime" '
        def configured_known: ["compat", "virtio-gl", "virtio-venus", "rutabaga", "vfio-looking-glass"] | index($graphics.config.profile) != null;
        def profile_blocked:
            (configured_known | not)
            or ($graphics.config.profile == "virtio-gl" and (($graphics.profiles["virtio-gl"].eligible | not) or ($graphics.libvirt.domain != "")))
            or ($graphics.config.profile == "virtio-venus")
            or ($graphics.config.profile == "rutabaga")
            or ($graphics.config.profile == "vfio-looking-glass");
        def overall:
            if (($graphics.host.kvm | not) or $graphics.qemu.binary == "") then "blocked"
            elif profile_blocked or $runtime.status != "ok" then "needsrepair"
            else "ok" end;
        {
            schemaVersion: 1,
            status: overall,
            configuredProfile: $graphics.config.profile,
            effectiveProfile: (if profile_blocked then "compat" else $graphics.config.profile end),
            checks: [
                {name: "kvm", status: (if $graphics.host.kvm then "ok" else "blocked" end), detail: ($graphics.host.kvm|tostring)},
                {name: "render-node", status: (if $graphics.host.selectedRenderNode != "" then "ok" else "blocked" end), detail: $graphics.host.selectedRenderNode},
                {name: "qemu-virtio-gl", status: (if $graphics.qemu.virtioVgaGl and $graphics.qemu.displays.gtk then "ok" else "blocked" end), detail: $graphics.qemu.binary},
                {name: "libvirt-video", status: "ok", detail: (($graphics.libvirt.videoModel // "") + "/" + ($graphics.libvirt.graphicsType // ""))},
                {name: "runtime", status: $runtime.status, detail: (($runtime.summary.current|tostring) + "/" + ($runtime.summary.total|tostring) + " current")},
                {name: "vfio", status: $graphics.vfio.viability, detail: ($graphics.vfio.blockers | join("; ")), optional: true}
            ],
            recommendedActions: ([
                if profile_blocked then "linux/pz windows-vm graphics apply --profile compat" else empty end,
                if $runtime.status != "ok" then "linux/pz windows-vm graphics runtime install" else empty end,
                if $graphics.profiles["virtio-gl"].eligible then "linux/pz windows-vm graphics plan --profile virtio-gl" else empty end
            ]),
            graphics: $graphics,
            runtime: $runtime,
            bootSafety: "doctor e runtime nao alteram GRUB, EFI, initramfs, SDDM ou bind VFIO"
        }'
}

cmd_doctor() {
    parse_options "$@"
    local json
    json="$(doctor_json)"
    if [ "$JSON_OUT" = "1" ]; then
        printf '%s\n' "$json"
        return 0
    fi
    echo "Windows VM graphics doctor: $(jq -r '.status' <<< "$json")"
    echo "  configured_profile: $(jq -r '.configuredProfile' <<< "$json")"
    echo "  effective_profile: $(jq -r '.effectiveProfile' <<< "$json")"
    jq -r '.checks[] | "  \(.name): \(.status) \(.detail)"' <<< "$json"
    jq -r '.recommendedActions[] | "  next: \(.)"' <<< "$json"
}

validate_profile() {
    local profile="$1" known
    for known in $KNOWN_PROFILES; do
        [ "$profile" = "$known" ] && return 0
    done
    pz_error "unknown graphics profile: $profile (use: $KNOWN_PROFILES)"
    return 1
}

resolve_auto_profile() {
    # v1 safe auto: keep the stable path; acceleration stays explicit opt-in.
    echo "$GFX_RECOMMENDED"
}

plan_payload_json() {
    local profile="$1" resolved="$1" eligible mode risk apply_allowed apply_cmd
    local -a blockers=() qemu_args=()
    local xml_plan="" notes=""
    if [ "$profile" = "auto" ]; then
        resolved="$(resolve_auto_profile)"
    fi
    case "$resolved" in
        compat)
            eligible=yes; mode=stable; risk=none; apply_allowed=yes
            apply_cmd="linux/pz windows-vm graphics apply --profile compat"
            qemu_args=("-device" "virtio-vga" "-display" "gtk,show-cursor=on")
            notes="mantem comportamento atual: QXL/SPICE (libvirt) e virtio-vga (raw QEMU)"
            ;;
        virtio-gl)
            eligible="$GFX_GL_ELIGIBLE"; mode=experimental; risk=medium
            apply_allowed=yes
            apply_cmd="linux/pz windows-vm graphics apply --profile virtio-gl --experimental --yes"
            blockers=("${GFX_GL_BLOCKERS[@]:-}")
            qemu_args=("-device" "virtio-vga-gl" "-display" "gtk,gl=on,show-cursor=on")
            notes="raw QEMU somente; ativa caminho GL no host, mas 3D no Windows depende de driver guest e nao e garantido. Libvirt permanece QXL/SPICE na v1"
            if [ -n "$GFX_DOMAIN" ]; then
                apply_allowed=no
                apply_cmd=""
                blockers+=("dominio libvirt $GFX_DOMAIN e o default; perfil persistente poderia quebrar a sessao de boot. Use launch --raw-qemu --graphics virtio-gl --experimental somente para teste")
            fi
            ;;
        virtio-venus)
            eligible=yes; mode=experimental; risk=high; apply_allowed=no
            apply_cmd=""
            blockers=()
            [ "$GFX_QEMU_VENUS" = "yes" ] || blockers+=("QEMU sem suporte venus (virtio-vga-gl,venus=on); kernel 6.7+ e mesa 23+ exigidos")
            qemu_args=("-device" "virtio-vga-gl,venus=on" "-display" "gtk,gl=on,show-cursor=on")
            notes="EXPERIMENTAL: Vulkan paravirtual (Mesa Venus). Nao habilitado em provision.sh.\n"
            notes+="Pre-requisitos: kernel >= 6.7, mesa >= 23 com venus, QEMU com virgl+venus, vulkan-radeon no host AMD.\n"
            notes+="Funciona experimentalmente: Vulkan 1.x via venus renderer; D3D12 via rutabaga+zink (muito experimental).\n"
            notes+="NAO funciona: D3D12 nativo sem rutabaga, DXGI swapchain, multi-adapter.\n"
            notes+="Nota Steam Deck: VanGogh APU unica -- VFIO passthrough impossivel; Venus e o unico caminho de aceleracao Vulkan e e experimental.\n"
            notes+="Nao integrado ao provision.sh: prereqs nao fixados, estabilidade do driver guest nao verificada, sem cobertura automatizada de testes."
            ;;
        rutabaga)
            eligible=no; mode=experimental-blocked; risk=high; apply_allowed=no
            apply_cmd=""
            blockers=("${GFX_RUTABAGA_BLOCKERS[@]:-}")
            qemu_args=("-device" "virtio-gpu-rutabaga" "-display" "gtk,gl=on,show-cursor=on")
            notes="gfxstream/rutabaga; bloqueado para Windows ate validacao explicita do driver guest"
            ;;
        vfio-looking-glass)
            eligible=no; [ "$GFX_VFIO_VIABILITY" = "eligible-plan-only" ] && eligible=yes
            mode="plan-only"; risk=high; apply_allowed=no
            apply_cmd=""
            blockers=("${GFX_VFIO_BLOCKERS[@]:-}")
            local dev
            for dev in $GFX_VFIO_DEVICES_NORMALIZED; do
                xml_plan+="<hostdev mode='subsystem' type='pci' managed='yes'><source><address domain='0x${dev%%:*}' bus='0x$(cut -d: -f2 <<< "$dev")' slot='0x$(cut -d: -f3 <<< "$dev" | cut -d. -f1)' function='0x${dev##*.}'/></source></hostdev>"
            done
            [ -n "$xml_plan" ] || xml_plan="<hostdev mode='subsystem' type='pci' managed='yes'><!-- defina PZ_WINDOWS_VM_PCI_DEVICES (GPU + funcao de audio no mesmo plano) --></hostdev>"
            notes="plan-only na v1: exige IOMMU groups completos, GPU+audio juntos, dominio desligado. Nenhum bind/unbind VFIO nem mudanca de GRUB e feita"
            ;;
        *)
            pz_error "unknown graphics profile: $resolved"
            return 1
            ;;
    esac
    local args_str=""
    [ "${#qemu_args[@]}" -gt 0 ] && args_str="${qemu_args[*]}"
    jq -n \
        --arg requested "$profile" \
        --arg profile "$resolved" \
        --arg eligible "$eligible" \
        --arg mode "$mode" \
        --arg risk "$risk" \
        --arg applyAllowed "$apply_allowed" \
        --arg applyCommand "$apply_cmd" \
        --arg qemuArgs "$args_str" \
        --arg xmlPlan "$xml_plan" \
        --arg notes "$notes" \
        --arg domain "$GFX_DOMAIN" \
        --arg domainState "$GFX_DOMAIN_STATE" \
        --argjson blockers "$(blockers_json "${blockers[@]:-}")" \
        '{
            requestedProfile: $requested,
            profile: $profile,
            eligible: ($eligible == "yes"),
            mode: $mode,
            risk: $risk,
            applyAllowed: ($applyAllowed == "yes"),
            applyCommand: $applyCommand,
            plannedQemuArgs: $qemuArgs,
            plannedDomainXml: $xmlPlan,
            blockers: $blockers,
            notes: $notes,
            libvirt: {domain: $domain, state: $domainState, backupRequired: false, backupXml: ""},
            bootSafety: "v1 nao altera GRUB, initramfs, kernel args, modulos VFIO ou SDDM"
        }'
}

cmd_plan() {
    parse_options "$@"
    [ -n "$PROFILE" ] || PROFILE=auto
    validate_profile "$PROFILE"
    collect_facts
    local payload
    payload="$(plan_payload_json "$PROFILE")"
    if [ "$JSON_OUT" = "1" ]; then
        printf '%s\n' "$payload"
        return 0
    fi
    echo "PhaseZero Windows VM graphics plan"
    echo "  requested_profile: $(jq -r '.requestedProfile' <<< "$payload")"
    echo "  resolved_profile: $(jq -r '.profile' <<< "$payload")"
    echo "  mode: $(jq -r '.mode' <<< "$payload")"
    echo "  eligible: $(jq -r '.eligible' <<< "$payload")"
    echo "  risk: $(jq -r '.risk' <<< "$payload")"
    echo "  apply_allowed: $(jq -r '.applyAllowed' <<< "$payload")"
    echo "  apply_command: $(jq -r '.applyCommand' <<< "$payload")"
    echo "  planned_qemu_args: $(jq -r '.plannedQemuArgs' <<< "$payload")"
    local xml_plan
    xml_plan="$(jq -r '.plannedDomainXml' <<< "$payload")"
    [ -n "$xml_plan" ] && echo "  planned_domain_xml: $xml_plan"
    echo "  libvirt_domain: $(jq -r '.libvirt.domain' <<< "$payload")"
    echo "  libvirt_state: $(jq -r '.libvirt.state' <<< "$payload")"
    echo "  boot_safety: $(jq -r '.bootSafety' <<< "$payload")"
    echo "  notes: $(jq -r '.notes' <<< "$payload")"
    while IFS= read -r line; do
        [ -n "$line" ] && echo "  blocker: $line"
    done < <(jq -r '.blockers[]' <<< "$payload")
    if [ "$GFX_EXPERIMENTAL_CANDIDATE" = "virtio-gl" ] && [ "$PROFILE" = "auto" ]; then
        echo "  experimental_candidate: virtio-gl (linux/pz windows-vm graphics plan --profile virtio-gl)"
    fi
}

write_config_profile() {
    local profile="$1"
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would set PZ_WINDOWS_VM_GRAPHICS_PROFILE=$profile in $CONFIG_FILE"
        return 0
    fi
    install -d "$CONFIG_DIR"
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    if [ -f "$CONFIG_FILE" ]; then
        grep -v '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=' "$CONFIG_FILE" > "$tmp" || true
    fi
    printf 'PZ_WINDOWS_VM_GRAPHICS_PROFILE=%q\n' "$profile" >> "$tmp"
    install -m 0644 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    pz_info "graphics profile set: $profile ($CONFIG_FILE)"
}

remove_config_profile() {
    [ -f "$CONFIG_FILE" ] || { pz_info "graphics profile not configured"; return 0; }
    if [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would remove PZ_WINDOWS_VM_GRAPHICS_PROFILE from $CONFIG_FILE"
        return 0
    fi
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    grep -v '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=' "$CONFIG_FILE" > "$tmp" || true
    install -m 0644 "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    pz_info "graphics profile removed; default volta a compat"
}

cmd_apply() {
    parse_options "$@"
    [ -n "$PROFILE" ] || { pz_error "apply requires --profile <compat|virtio-gl>"; return 1; }
    validate_profile "$PROFILE"
    collect_facts
    case "$PROFILE" in
        compat)
            write_config_profile compat
            return 0
            ;;
        virtio-gl)
            if [ "$GFX_DOMAIN_STATE" = "running" ]; then
                pz_error "dominio libvirt em execucao ($GFX_DOMAIN); desligue antes de aplicar perfis graficos"
                return 1
            fi
            if [ -n "$GFX_DOMAIN" ]; then
                pz_error "dominio libvirt $GFX_DOMAIN e o default; apply persistente virtio-gl foi bloqueado para preservar boot direto"
                pz_error "teste sem persistir: linux/pz windows-vm launch --raw-qemu --graphics virtio-gl --experimental"
                return 1
            fi
            [ "$EXPERIMENTAL" = "1" ] || {
                pz_error "virtio-gl e experimental; confirme com --experimental --yes"
                return 1
            }
            [ "$ASSUME_YES" = "1" ] || {
                pz_error "virtio-gl requer confirmacao explicita: adicione --yes"
                return 1
            }
            if [ "$GFX_GL_ELIGIBLE" != "yes" ]; then
                pz_error "virtio-gl bloqueado neste host:"
                local blocker
                for blocker in "${GFX_GL_BLOCKERS[@]}"; do
                    pz_error "  - $blocker"
                done
                return 1
            fi
            write_config_profile virtio-gl
            pz_info "launch acelerado: linux/pz windows-vm launch --raw-qemu --graphics virtio-gl --experimental"
            return 0
            ;;
        auto)
            pz_error "apply nao aceita auto; escolha compat ou virtio-gl"
            return 1
            ;;
        *)
            pz_error "graphics profile $PROFILE e plan-only na v1 (apply bloqueado). Use: linux/pz windows-vm graphics plan --profile $PROFILE"
            return 1
            ;;
    esac
}

cmd_remove() {
    parse_options "$@"
    remove_config_profile
}

guest_guide_content() {
    cat <<'EOF'
# PhaseZero Windows VM - Guia do guest (drivers graficos)

Checklist manual e verificavel; nada e instalado automaticamente no guest.

## 1. Drivers virtio (todos os perfis)
- [ ] Baixar virtio-win.iso (fedorapeople.org/groups/virt/virtio-win) ou usar o ISO ja detectado pelo PhaseZero.
- [ ] No Windows: instalar virtio-win-guest-tools.exe (inclui driver de video "viogpudo", rede, balloon e agente SPICE).
- [ ] Verificar no Gerenciador de Dispositivos: "Red Hat VirtIO GPU DOD" sem alertas.

## 2. Perfil compat (padrao)
- [ ] SPICE guest tools instalados (spice-guest-tools ou virtio-win-guest-tools).
- [ ] Resolucao ajusta automaticamente ao redimensionar a janela.

## 3. Perfil virtio-gl (experimental)
- [ ] Mesmos drivers virtio do passo 1; o perfil habilita GL/virgl no host, mas o driver Windows VirtIO GPU pode continuar sem aceleracao 3D.
- [ ] Validar no guest: dxdiag, OpenGL Extensions Viewer e carga real. Nao considerar `gl=on` prova de aceleracao Windows.
- [ ] Se houver tela preta: voltar para compat (linux/pz windows-vm graphics apply --profile compat).

## 4. Perfil vfio-looking-glass (etapa futura, plan-only na v1)
- [ ] Driver oficial da GPU (AMD/NVIDIA/Intel) instalado no guest.
- [ ] Looking Glass host application (looking-glass.io) instalado no guest.
- [ ] IVSHMEM driver instalado (virtio-win).
- [ ] RDP ou SPICE mantidos como fallback de acesso.

## 5. Fallback sempre disponivel
- [ ] RDP habilitado no guest (porta 3389; host: 127.0.0.1:33890).
- [ ] Snapshot/backup do disco antes de trocar drivers de video.
EOF
}

cmd_guest_guide() {
    parse_options "$@"
    local target="$STATE_DIR/guest-guide.md"
    if [ "$SAVE_GUIDE" != "1" ]; then
        guest_guide_content
        return 0
    elif [ "$DRY_RUN" = "1" ]; then
        pz_info "dry-run: would write $target"
    else
        install -d "$STATE_DIR"
        guest_guide_content > "$target"
        pz_info "guia salvo em: $target"
    fi
    guest_guide_content
}

case "$ACTION" in
    status) cmd_status "$@" ;;
    doctor|check) cmd_doctor "$@" ;;
    plan) cmd_plan "$@" ;;
    apply) cmd_apply "$@" ;;
    remove) cmd_remove "$@" ;;
    runtime|maintenance) cmd_runtime "$@" ;;
    guest-guide|guide) cmd_guest_guide "$@" ;;
    help|--help|-h) usage ;;
    *) pz_error "usage: windows-vm graphics (status|doctor|plan|apply|remove|runtime|guest-guide)"; exit 1 ;;
esac
