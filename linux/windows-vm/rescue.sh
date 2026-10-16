#!/usr/bin/env bash
# rescue.sh - PhaseZero Windows VM boot rescue wizard
# Sourced by windows-vm-session.sh and launch_vm on missing disk.
# No set -euo pipefail at file level — caller controls strictness.

# Source tui.sh for pz_tui_* functions if available
if ! type pz_tui_menu >/dev/null 2>&1; then
    for _rescue_tui_candidate in \
        "${PZ_ROOT:-}/linux/ui/tui.sh" \
        "/usr/local/lib/phasezero/windows-vm-runtime/linux/ui/tui.sh"; do
        [ -f "$_rescue_tui_candidate" ] && source "$_rescue_tui_candidate" 2>/dev/null && break
    done
fi

RESCUE_LOG="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/windows-vm}/rescue.log"

# The rescue wizard downloads the driver ISO too, so it needs the same trusted
# version/URL/hash as provisioning. This file is sourced by callers that may not
# have set PZ_ROOT, hence the same candidate search as tui.sh above.
if ! type virtio_win_sha_matches >/dev/null 2>&1; then
    for _rescue_virtio_candidate in \
        "${PZ_ROOT:-}/linux/windows-vm/virtio-source.sh" \
        "/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/virtio-source.sh"; do
        [ -f "$_rescue_virtio_candidate" ] && source "$_rescue_virtio_candidate" 2>/dev/null && break
    done
fi

# Removable-media mounts are named after the logged-in account. A boot session
# is spawned by systemd, which does not export USER, and its caller runs under
# `set -u` — so reading $USER directly aborts the wizard before it lists
# anything. Fall back through LOGNAME to the uid that actually owns the run.
_rescue_user_name() {
    printf '%s' "${USER:-${LOGNAME:-$(id -un 2>/dev/null || true)}}"
}

_vm_rescue_log() {
    local ts
    ts="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "unknown")"
    install -d "$(dirname "$RESCUE_LOG")" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >> "$RESCUE_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# text fallback (whiptail absent)
# ---------------------------------------------------------------------------
vm_rescue_text_menu() {
    local title="$1" text="$2" label
    shift 2
    printf '\n=== %s ===\n' "$title" >&2
    printf '%s\n\n' "$text" >&2
    local i=0 pairs=()
    while [ "$#" -gt 1 ]; do
        i=$((i + 1))
        printf '  %d. %s\n' "$i" "$1" >&2
        pairs+=("$i" "$1" "$2")
        shift 2
    done
    printf 'Escolha [1-%d]: ' "$i" >&2
    read -r choice
    local idx=$(( (choice - 1) * 3 + 1 ))
    [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ] && printf '%s\n' "${pairs[$idx]}" || printf '\n'
}

# ---------------------------------------------------------------------------
# should_run guard
# ---------------------------------------------------------------------------
vm_rescue_should_run() {
    [ "${PZ_WINDOWS_VM_RESCUE:-1}" = "0" ] && return 1
    [ "${PZ_WINDOWS_VM_BOOT_SESSION:-0}" = "1" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# ISO scan (extends detect_windows_iso bases)
# ---------------------------------------------------------------------------
vm_rescue_scan_isos() {
    local base found all=""
    for base in "$HOME/Downloads" "$HOME" /mnt/sdcard "/run/media/$(_rescue_user_name)" "/media/$(_rescue_user_name)" /mnt; do
        [ -d "$base" ] || continue
        found="$(find "$base" -maxdepth 4 -type f \( -iname '*win*.iso' -o -iname '*windows*.iso' \) 2>/dev/null || true)"
        [ -n "$found" ] && all="$all$found"$'\n'
    done
    printf '%s' "$all" | sort -u | sed '/^$/d'
}

# ---------------------------------------------------------------------------
# disk scan (reuses find_existing_windows_disk_any, extends with pendrive bases)
# ---------------------------------------------------------------------------
vm_rescue_scan_disks() {
    local base found all="" patterns
    patterns=( -iname '*win*.qcow2' -o -iname '*windows*.qcow2' -o -iname '*win*.img' -o -iname '*windows*.img' -o -iname '*win*.raw' -o -iname '*windows*.raw' -o -iname '*win*.vmdk' -o -iname '*windows*.vmdk' )
    for base in "$HOME/VirtualMachines" "$HOME/.local/share/libvirt/images" "/var/lib/libvirt/images" "$HOME" /mnt/sdcard "/run/media/$(_rescue_user_name)" "/media/$(_rescue_user_name)" /mnt; do
        [ -d "$base" ] || continue
        found="$(find "$base" -maxdepth 4 -type f \( "${patterns[@]}" \) 2>/dev/null || true)"
        [ -n "$found" ] || continue
        while IFS= read -r candidate; do
            [ -f "$candidate" ] || continue
            if disk_looks_installed "$candidate" 2>/dev/null; then
                all="$all$candidate"$'\n'
            fi
        done <<< "$found"
    done
    printf '%s' "$all" | sort -u | sed '/^$/d'
}

# ---------------------------------------------------------------------------
# TUI source picker
# ---------------------------------------------------------------------------
vm_rescue_pick_source() {
    local iso_local_count=0 disk_count=0 msg
    iso_local_count="$(vm_rescue_scan_isos | wc -l)"
    disk_count="$(vm_rescue_scan_disks | wc -l)"
    if command -v whiptail >/dev/null 2>&1; then
        local choices=()
        [ "$iso_local_count" -gt 0 ] && choices+=( "iso-local" "ISO local ($iso_local_count encontrado(s))" )
        choices+=( "iso-net" "Download oficial (virtio-win)" )
        [ "$disk_count" -gt 0 ] && choices+=( "disk-adopt" "Adotar disco existente ($disk_count encontrado(s))" )
        choices+=( "escape" "Voltar ao desktop normal" )
        pz_tui_menu "Rescue Windows VM" "Disco da VM ausente. Escolha uma fonte:" "${choices[@]}"
    else
        local choices=()
        [ "$iso_local_count" -gt 0 ] && choices+=( "iso-local" "ISO local ($iso_local_count encontrado(s))" )
        choices+=( "iso-net" "Download oficial (virtio-win)" )
        [ "$disk_count" -gt 0 ] && choices+=( "disk-adopt" "Adotar disco existente ($disk_count encontrado(s))" )
        choices+=( "escape" "Voltar ao desktop normal" )
        vm_rescue_text_menu "Rescue Windows VM" "Disco da VM ausente. Escolha uma fonte:" "${choices[@]}"
    fi
}

# ---------------------------------------------------------------------------
# download official virtio-win ISO
# ---------------------------------------------------------------------------
vm_rescue_download_official() {
    local dest_dir="${PZ_WINDOWS_VM_RESCUE_DOWNLOAD_DIR:-$HOME/Downloads}"
    install -d "$dest_dir" 2>/dev/null || true
    local iso_path="$dest_dir/virtio-win.iso"
    local url="${PZ_VIRTIO_WIN_URL:-}"
    local known_sha256="${PZ_VIRTIO_WIN_SHA256:-}"
    if [ -z "$url" ] || [ -z "$known_sha256" ]; then
        # The floating stable-virtio link has no hash to check, so an ISO from it
        # cannot be proven to be the one provisioning will accept.
        _vm_rescue_log "trusted virtio source unavailable; refusing an unverified download"
        pz_error "virtio-win trusted URL/hash missing; refusing to download what cannot be verified"
        return 1
    fi
    _vm_rescue_log "download starting: $url -> $iso_path"
    if command -v download_atomic >/dev/null 2>&1; then
        download_atomic "$url" "$iso_path" 2>&1 || {
            _vm_rescue_log "download_atomic failed"
            pz_error "virtio-win download failed"
            return 1
        }
    else
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$iso_path" 2>&1 || {
            _vm_rescue_log "curl download failed"
            pz_error "virtio-win download failed"
            return 1
        }
    fi
    if [ -n "$known_sha256" ]; then
        local actual
        actual="$(sha256sum "$iso_path" | awk '{print $1}')"
        if [ "${actual,,}" != "${known_sha256,,}" ]; then
            _vm_rescue_log "SHA256 mismatch: expected $known_sha256, got $actual"
            rm -f "$iso_path"
            pz_error "virtio-win SHA256 mismatch; download deleted"
            return 1
        fi
        _vm_rescue_log "SHA256 verified"
    fi
    _vm_rescue_log "download complete: $iso_path"
    printf '%s\n' "$iso_path"
    return 0
}

# ---------------------------------------------------------------------------
# install from ISO
# ---------------------------------------------------------------------------
vm_rescue_do_install() {
    local iso="$1"
    _vm_rescue_log "install starting: iso=$iso"
    if ! file "$iso" 2>/dev/null | grep -qi 'iso\s*9660\|cdrom\|archive'; then
        pz_error "not a valid ISO: $iso"
        _vm_rescue_log "invalid ISO: $iso"
        return 1
    fi
    PZ_WINDOWS_VM_RESCUE=0 install_vm --iso "$iso" --with-boot 2>&1 || {
        local rc=$?
        _vm_rescue_log "install_vm failed rc=$rc"
        return $rc
    }
    if [ ! -f "$DISK_PATH" ] || ! disk_looks_installed "$DISK_PATH"; then
        _vm_rescue_log "disk not found/installed after install: $DISK_PATH"
        pz_error "disk not found after install"
        return 1
    fi
    _vm_rescue_log "install complete: disk=$DISK_PATH"
    return 0
}

# ---------------------------------------------------------------------------
# adopt existing disk
# ---------------------------------------------------------------------------
vm_rescue_do_adopt() {
    local disk="$1"
    _vm_rescue_log "adopt starting: disk=$disk"
    if [ "$EUID" -ne 0 ]; then
        local msg="Adocao requer root.\n\nExecute manualmente:\n  sudo linux/pz windows-vm adopt --disk \"$disk\"\n\nDepois reinicie."
        if command -v whiptail >/dev/null 2>&1; then
            pz_tui_msgbox "Requer root" "$msg"
        else
            printf '\n%s\n' "$msg"
        fi
        _vm_rescue_log "adopt skipped (no root); user instructed to run manually"
        return 1
    fi
    cmd_adopt --disk "$disk" 2>&1 || {
        local rc=$?
        _vm_rescue_log "cmd_adopt failed rc=$rc"
        return $rc
    }
    _vm_rescue_log "adopt complete: disk=$disk"
    return 0
}

# ---------------------------------------------------------------------------
# escape: strip ALL PhaseZero DM drop-ins and restart DM / isolate graphical
# ---------------------------------------------------------------------------
vm_rescue_escape_to_desktop() {
    _vm_rescue_log "escape starting"
    local question="Voltar ao desktop normal? Remove o autologin PhaseZero e reinicia o gerenciador de login."
    local do_escape=0
    if [ -n "${PZ_WINDOWS_VM_RESCUE_TEST:-}" ]; then
        printf 'RESCUE-TEST: would prompt "%s"\n' "$question"
        do_escape=1
    elif command -v whiptail >/dev/null 2>&1; then
        pz_tui_yesno "Desktop normal" "$question" && do_escape=1
    else
        printf '\n%s [s/N]: ' "$question"
        read -r ans
        case "${ans,,}" in
            s|sim|y|yes) do_escape=1 ;;
        esac
    fi
    if [ "$do_escape" = "1" ]; then
        _vm_rescue_log "escape confirmed"
        if [ -n "${PZ_WINDOWS_VM_RESCUE_TEST:-}" ]; then
            printf 'RESCUE-TEST: would call remove_sddm_autologin\n'
            printf 'RESCUE-TEST: would call remove_gdm_autologin\n'
            printf 'RESCUE-TEST: would call remove_lightdm_autologin\n'
            printf 'RESCUE-TEST: would call remove_lxdm_autologin\n'
            printf 'RESCUE-TEST: would call remove_greetd_autologin\n'
            printf 'RESCUE-TEST: would restart display-manager or isolate graphical.target\n'
            _vm_rescue_log "escape test mode - actions printed"
            return 0
        fi
        if [ -f /etc/sddm.conf.d/91-phasezero-windows-vm.conf ] && grep -q 'PhaseZero managed' /etc/sddm.conf.d/91-phasezero-windows-vm.conf 2>/dev/null; then
            rm -f /etc/sddm.conf.d/91-phasezero-windows-vm.conf
            _vm_rescue_log "sddm drop-in removed"
        fi
        for _conf in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
            [ -f "$_conf" ] || continue
            if grep -q '# PhaseZero managed' "$_conf" 2>/dev/null; then
                sed -i '/# PhaseZero managed/,/AutomaticLogin=/d' "$_conf"
                _vm_rescue_log "gdm block removed: $_conf"
            fi
        done
        if [ -f /etc/lightdm/lightdm.conf.d/91-phasezero-windows-vm.conf ] && grep -q 'PhaseZero managed' /etc/lightdm/lightdm.conf.d/91-phasezero-windows-vm.conf 2>/dev/null; then
            rm -f /etc/lightdm/lightdm.conf.d/91-phasezero-windows-vm.conf
            _vm_rescue_log "lightdm drop-in removed"
        fi
        _lxdm_conf=/etc/lxdm/lxdm.conf
        if [ -f "$_lxdm_conf" ]; then
            if grep -q '# PhaseZero managed' "$_lxdm_conf" 2>/dev/null; then
                sed -i '/# PhaseZero managed/,/# PhaseZero managed end/d' "$_lxdm_conf"
                _vm_rescue_log "lxdm block removed: $_lxdm_conf"
            fi
        fi
        if [ -f /etc/greetd/config.toml ] && grep -q 'PhaseZero managed' /etc/greetd/config.toml 2>/dev/null; then
            local greetd_backup="/etc/greetd/config.toml.phasezero-backup"
            if [ -f "$greetd_backup" ]; then cp -a "$greetd_backup" /etc/greetd/config.toml && _vm_rescue_log "greetd restored from backup"; else rm -f /etc/greetd/config.toml && _vm_rescue_log "greetd config removed (no backup)"; fi
        fi
        if systemctl restart display-manager.service 2>/dev/null; then
            _vm_rescue_log "display-manager restarted"
        else
            systemctl isolate graphical.target 2>/dev/null || true
            _vm_rescue_log "isolated graphical.target"
        fi
        exit 0
    else
        _vm_rescue_log "escape declined"
        if [ -n "${PZ_WINDOWS_VM_RESCUE_TEST:-}" ]; then
            printf 'RESCUE-TEST: would prompt "Reiniciar o host?"\n'
            _vm_rescue_log "escape test mode - restart prompt would appear"
            return 0
        fi
        local reboot_q="Reiniciar o host?"
        if command -v whiptail >/dev/null 2>&1; then
            if pz_tui_yesno "Reiniciar" "$reboot_q"; then
                _vm_rescue_log "user requested reboot"
                systemctl reboot
            fi
        else
            printf '\n%s [s/N]: ' "$reboot_q"
            read -r ans2
            case "${ans2,,}" in
                s|sim|y|yes)
                    _vm_rescue_log "user requested reboot"
                    systemctl reboot;;
            esac
        fi
    fi
    _vm_rescue_log "escape flow ended (user stayed)"
    return 1
}

# ---------------------------------------------------------------------------
# main entry point
# ---------------------------------------------------------------------------
vm_rescue_run() {
    vm_rescue_should_run || return 1
    _vm_rescue_log "=== rescue wizard started ==="
    # Test/auto mode: auto-pick first scanned ISO
    if [ -n "${PZ_WINDOWS_VM_RESCUE_AUTO_PICK:-}" ]; then
        local iso
        iso="$(vm_rescue_scan_isos | head -1)"
        if [ -n "$iso" ]; then
            _vm_rescue_log "auto-pick ISO: $iso"
            vm_rescue_do_install "$iso"
            local rc=$?
            _vm_rescue_log "=== rescue wizard end (auto-pick, rc=$rc) ==="
            return $rc
        fi
        _vm_rescue_log "auto-pick: no ISO found"
        return 1
    fi
    if [ -n "${PZ_WINDOWS_VM_RESCUE_TEST:-}" ]; then
        printf 'RESCUE-TEST: vm_rescue_run entered\n'
        _vm_rescue_log "test mode - returning 0"
        return 0
    fi
    local rescue_disk_path="${DISK_PATH:-desconhecido}"
    local question="Disco da VM ausente em $rescue_disk_path.\n\nAbrir assistente de instalacao?"
    local proceed=0
    if command -v whiptail >/dev/null 2>&1; then
        pz_tui_yesno "VM Inacessivel" "$question" && proceed=1
    else
        printf '\n=== VM Inacessivel ===\n%s\n\n[s/N]: ' "$question"
        read -r ans
        case "${ans,,}" in
            s|sim|y|yes) proceed=1 ;;
        esac
    fi
    [ "$proceed" = "1" ] || {
        _vm_rescue_log "user declined rescue wizard"
        vm_rescue_escape_to_desktop
        return $?
    }
    while true; do
        local source=""
        source="$(vm_rescue_pick_source)"
        [ -z "$source" ] && source="escape"
        case "$source" in
            iso-local)
                local isos
                isos="$(vm_rescue_scan_isos)"
                if [ -z "$isos" ]; then
                    local msg="Nenhum ISO Windows encontrado.\nColoque um ISO em /mnt/sdcard, ~/Downloads, ou pendrive."
                    command -v whiptail >/dev/null 2>&1 && pz_tui_msgbox "Sem ISO" "$msg" || printf '\n%s\n' "$msg"
                    continue
                fi
                local chosen_iso=""
                if command -v whiptail >/dev/null 2>&1; then
                    local menu_items=()
                    while IFS= read -r iso; do
                        [ -n "$iso" ] && menu_items+=("$iso" "$iso")
                    done <<< "$isos"
                    chosen_iso="$(pz_tui_menu "ISO Local" "Selecione o ISO Windows:" "${menu_items[@]}")"
                else
                    local lines=()
                    while IFS= read -r iso; do
                        [ -n "$iso" ] && lines+=("$iso")
                    done <<< "$isos"
                    printf '\nISOs encontrados:\n'
                    local idx=0
                    for l in "${lines[@]}"; do
                        idx=$((idx + 1))
                        printf '  %d. %s\n' "$idx" "$l"
                    done
                    printf 'Escolha [1-%d]: ' "$idx"
                    read -r iso_idx
                    [ "$iso_idx" -ge 1 ] && [ "$iso_idx" -le "$idx" ] 2>/dev/null && chosen_iso="${lines[$((iso_idx - 1))]}" || chosen_iso=""
                fi
                [ -n "$chosen_iso" ] || continue
                vm_rescue_do_install "$chosen_iso" && {
                    _vm_rescue_log "=== rescue wizard end (install ok) ==="
                    return 0
                }
                pz_error "install failed"
                ;;
            iso-net)
                local dl_iso
                dl_iso="$(vm_rescue_download_official)" || {
                    local msg2="Falha no download.\n\nWindows ISO: baixe manualmente de\nhttps://www.microsoft.com/software-download/windows11\nou\nhttps://www.microsoft.com/software-download/windows10\ne coloque em /mnt/sdcard ou ~/Downloads, depois escolha 'ISO local'."
                    command -v whiptail >/dev/null 2>&1 && pz_tui_msgbox "Download" "$msg2" || printf '\n%s\n' "$msg2"
                    continue
                }
                vm_rescue_do_install "$dl_iso" && {
                    _vm_rescue_log "=== rescue wizard end (install from download ok) ==="
                    return 0
                }
                pz_error "install from download failed"
                ;;
            disk-adopt)
                local disks
                disks="$(vm_rescue_scan_disks)"
                if [ -z "$disks" ]; then
                    local msg3="Nenhum disco Windows encontrado."
                    command -v whiptail >/dev/null 2>&1 && pz_tui_msgbox "Sem Disco" "$msg3" || printf '\n%s\n' "$msg3"
                    continue
                fi
                local chosen_disk=""
                if command -v whiptail >/dev/null 2>&1; then
                    local menu_items2=()
                    while IFS= read -r d; do
                        [ -n "$d" ] && menu_items2+=("$d" "$d")
                    done <<< "$disks"
                    chosen_disk="$(pz_tui_menu "Adotar Disco" "Selecione o disco Windows:" "${menu_items2[@]}")"
                else
                    local dlines=()
                    while IFS= read -r d; do
                        [ -n "$d" ] && dlines+=("$d")
                    done <<< "$disks"
                    printf '\nDiscos encontrados:\n'
                    local d_idx=0
                    for l in "${dlines[@]}"; do
                        d_idx=$((d_idx + 1))
                        printf '  %d. %s\n' "$d_idx" "$l"
                    done
                    printf 'Escolha [1-%d]: ' "$d_idx"
                    read -r d_choice
                    [ "$d_choice" -ge 1 ] && [ "$d_choice" -le "$d_idx" ] 2>/dev/null && chosen_disk="${dlines[$((d_choice - 1))]}" || chosen_disk=""
                fi
                [ -n "$chosen_disk" ] || continue
                vm_rescue_do_adopt "$chosen_disk" && {
                    _vm_rescue_log "=== rescue wizard end (adopt ok) ==="
                    return 0
                }
                pz_error "adopt failed"
                ;;
            escape|*)
                vm_rescue_escape_to_desktop
                return $?
                ;;
        esac
    done
}
