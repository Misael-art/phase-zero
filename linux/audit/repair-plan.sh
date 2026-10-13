#!/usr/bin/env bash
# repair-plan.sh - analyze system and suggest repairs
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps jq

PLAN_FILE="$(mktemp)"
trap 'rm -f "$PLAN_FILE"' EXIT

add_item() {
    local id="$1" priority="$2" desc="$3" cmd="$4"
    jq -cn \
        --arg id "$id" \
        --arg priority "$priority" \
        --arg desc "$desc" \
        --arg cmd "$cmd" \
        '{id: $id, priority: $priority, description: $desc, command: $cmd}' >> "$PLAN_FILE"
}

is_pkg_installed() {
    pacman -Qi "$1" >/dev/null 2>&1
}

missing_any_pkg() {
    local pkg
    for pkg in "$@"; do
        is_pkg_installed "$pkg" || return 0
    done
    return 1
}

missing_any_command() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 ||
            [ -x "$HOME/.cargo/bin/$cmd" ] ||
            [ -x "$HOME/go/bin/$cmd" ] ||
            return 0
    done
    return 1
}

pz_info "analyzing system for repair recommendations..."

# Systemd failures
failed=$(systemctl --failed --no-pager 2>/dev/null | awk 'NR > 1 && $0 !~ /^$/ && $0 !~ /LOAD/ && $0 !~ /loaded units listed/ { count++ } END { print count + 0 }')
if [ "$failed" -gt 0 ]; then
    add_item "SYS01" "high" "${failed} failed systemd units" "systemctl --failed --no-pager"
fi

# Disk usage, ignoring ephemeral mounts that are expected to show 100%.
while read -r pct target; do
    [ -z "${pct:-}" ] && continue
    case "$target" in
        /tmp/.mount_*|/run/user/*|/var/lib/docker/overlay2/*/merged) continue ;;
    esac
    pct_num=${pct%\%}
    if [ "$pct_num" -gt 90 ] 2>/dev/null; then
        add_item "DISK_$(echo "$target" | tr / _)" "high" "disk $target at ${pct}% capacity" "sudo du -sh ${target}/* 2>/dev/null | sort -rh | head -10"
    elif [ "$pct_num" -gt 80 ] 2>/dev/null; then
        add_item "DISK_$(echo "$target" | tr / _)" "medium" "disk $target at ${pct}% capacity" "df -h $target && sudo du -sh ${target}/* 2>/dev/null | sort -rh | head -10"
    fi
done < <(df -h --output=pcent,target 2>/dev/null | tail -n+2)

# Package updates
updates=$( { pacman -Qu 2>/dev/null || true; } | wc -l)
if [ "$updates" -gt 50 ]; then
    add_item "PKG01" "medium" "${updates} pending package updates" "sudo pacman -Syu"
elif [ "$updates" -gt 10 ]; then
    add_item "PKG01" "low" "${updates} pending package updates" "sudo pacman -Syu"
fi

# Orphaned packages
orphans=$( { pacman -Qdt 2>/dev/null || true; } | wc -l)
if [ "$orphans" -gt 0 ]; then
    # shellcheck disable=SC2016 # literal suggested command; $(pacman -Qdtq) evaluated by user at run time
    add_item "PKG02" "low" "${orphans} orphaned packages" 'sudo pacman -Rns $(pacman -Qdtq 2>/dev/null)'
fi

# Firewall
if ! systemctl is-active ufw >/dev/null 2>&1 && ! systemctl is-active firewalld >/dev/null 2>&1; then
    add_item "SEC01" "medium" "no firewall active" "sudo systemctl enable --now ufw && sudo ufw enable"
fi

# Btrfs maintenance
if command -v btrfs >/dev/null 2>&1 && btrfs filesystem usage / >/dev/null 2>&1; then
    add_item "BTRFS01" "low" "btrfs filesystem detected on /" "sudo btrfs filesystem balance start -dusage=75 /"
fi

# Docker
if command -v docker >/dev/null 2>&1 && ! timeout 5 docker ps >/dev/null 2>&1; then
    add_item "DOCKER01" "high" "Docker daemon not accessible" "sudo systemctl restart docker"
fi

# Swap
swap=$(free -m | awk '/Swap:/ {print $2 + 0}')
if [ "$swap" -eq 0 ]; then
    add_item "MEM01" "medium" "no swap configured" "sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile"
fi

# Temperature
temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
temp_c=$((temp / 1000))
if [ "$temp_c" -gt 85 ]; then
    add_item "TEMP01" "high" "CPU temperature ${temp_c}C exceeds 85C" "check cooling, reduce TDP via ryzenadj, verify fan profile"
fi

# SteamOS-like UX gaps
if missing_any_pkg mangohud lib32-mangohud goverlay; then
    add_item "STEAMOS01" "medium" "MangoHud overlay stack missing" "sudo pacman -S --needed mangohud lib32-mangohud goverlay"
fi

if ! command -v ryzenadj >/dev/null 2>&1; then
    add_item "STEAMOS02" "medium" "TDP control tool missing" "sudo pacman -S --needed ryzenadj"
fi

priv_helper="/usr/local/lib/phasezero/steamdeck-privileged-control"
priv_dropin="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-steamdeck-mode-watcher.service.d/10-privileged-controls.conf"
if command -v ryzenadj >/dev/null 2>&1 &&
    { [ ! -x "$priv_helper" ] || [ ! -f "$priv_dropin" ] || ! sudo -n "$priv_helper" status >/dev/null 2>&1; }; then
    add_item "STEAMOS05" "medium" "Privileged TDP/GPU bridge incomplete" "sudo linux/steamdeck/install-privileged-controls.sh install"
fi

if ! systemctl --user is-active phasezero-steamdeck-mode-watcher.service >/dev/null 2>&1; then
    add_item "STEAMOS03" "medium" "PhaseZero Steam Deck mode watcher inactive" "linux/pz steamdeck watcher enable"
fi

if command -v qdbus6 >/dev/null 2>&1 && ! qdbus6 org.kde.kglobalaccel 2>/dev/null | grep -q 'phasezero_.*_desktop'; then
    add_item "STEAMOS04" "medium" "PhaseZero KDE shortcuts not active" "linux/pz steamdeck hotkeys install"
fi

vk_status="$(bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" status 2>/dev/null || echo '{}')"
vk_health="$(printf '%s\n' "$vk_status" | bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" health-json 2>/dev/null || printf 'WARN\tunreadable\n')"
case "$vk_health" in
    PASS*) ;;
    *) add_item "STEAMOS07" "medium" "KDE virtual keyboard not loaded by KWin" "linux/pz steamdeck keyboard repair" ;;
esac

steam_plus_fallback="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope-session-plus/sessions.d/steam-plus"
if ! command -v opengamepadui >/dev/null 2>&1 && [ ! -f "$steam_plus_fallback" ]; then
    add_item "STEAMOS06" "medium" "Steam Big Picture Plus can login-loop without OpenGamepadUI or fallback" "linux/pz steamdeck boot install"
fi
if [ ! -x /usr/local/lib/phasezero/steamos-session ] ||
    [ ! -x /usr/lib/os-session-select ] ||
    [ ! -f /usr/share/wayland-sessions/phasezero-steamos.desktop ]; then
    add_item "STEAMOS13" "medium" "SteamOS Desktop transition requires login" "sudo linux/steamdeck/install-steamos-boot.sh install"
fi

decky_status="$(bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status 2>/dev/null || echo '{}')"
if jq -e '.decky.service.dualServiceConflict == true' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS11" "medium" "Decky system and user fallback services are both active; this causes duplicate plugin loads" "linux/pz steamdeck plugins repair"
fi

if ! jq -e '.decky.installed == true and .decky.service.active == true' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS08" "medium" "Decky Loader not running for Big Picture plugin menu" "linux/pz steamdeck plugins install"
elif ! jq -e '.steamDeckExperience.deckyMenuReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS08" "low" "Decky Loader installed but Steam CEF debug is not ready; restart Steam/Gamepad UI" "linux/pz steamdeck console"
fi

if ! jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installed == true)' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS09" "medium" "Decky PowerTools TDP plugin missing" "linux/pz steamdeck plugins install-plugins"
elif jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .healthy != true)' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS09" "medium" "Decky PowerTools installed from incomplete source package; backend binary missing" "linux/pz steamdeck plugins install-plugin-privileged PowerTools"
elif ! jq -e '.steamDeckExperience.tdpPluginReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS09" "low" "PowerTools installed but plugin-side TDP needs privileged system Decky service" "linux/pz steamdeck plugins install-decky-privileged"
fi

unhealthy_decky_plugins="$(jq -r '[.desiredPlugins[] | select(.installed == true and .healthy != true and .id != "PowerTools") | .id] | join(", ")' <<< "$decky_status" 2>/dev/null || true)"
if [ -n "$unhealthy_decky_plugins" ]; then
    add_item "STEAMOS12" "medium" "Decky plugins installed from incomplete source packages: $unhealthy_decky_plugins" "linux/pz steamdeck plugins install-plugins-privileged"
fi

if ! jq -e '.steamDeckExperience.themePluginReady == true and ([.desiredThemes[] | select(.installed == true)] | length > 0)' <<< "$decky_status" >/dev/null 2>&1; then
    add_item "STEAMOS10" "low" "Decky CSS Loader themes missing" "linux/pz steamdeck plugins install-themes"
fi

# Windows VM
winvm_status="$(bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" status 2>/dev/null || echo '{}')"
if ! jq -e '.host.qemu != "" and .host.qemuImg != "" and .host.ovmfCodeExists == true and .host.swtpm != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    add_item "WINVM01" "medium" "Windows VM host dependencies incomplete" "linux/pz install windows-vm-linux --dry-run"
fi
if ! jq -e '.config.installed == true and .vm.diskExists == true' <<< "$winvm_status" >/dev/null 2>&1; then
    add_item "WINVM02" "medium" "Windows VM not configured; needs user-provided ISO" "linux/pz windows-vm install --iso /path/to/Win11.iso"
fi
if jq -e '.discovery.discoveredInstalledDisk.installedLike == true and .discovery.discoveredInstalledDisk.usable != true' <<< "$winvm_status" >/dev/null 2>&1; then
    blocked_disk="$(jq -r '.discovery.discoveredInstalledDisk.path' <<< "$winvm_status")"
    add_item "WINVM04" "medium" "Existing Windows VM install detected but not readable by current user" "sudo linux/windows-vm/windows-vm.sh adopt --disk '$blocked_disk'"
fi
if ! jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and (.boot.grubCfgEntry == "present" or .boot.grubCfgEntry == "unknown-permission")' <<< "$winvm_status" >/dev/null 2>&1; then
    add_item "WINVM03" "medium" "Windows VM direct boot missing or stale" "sudo linux/windows-vm/windows-vm.sh boot install"
fi
if ! jq -e '.access.shareLinksReady == true and .access.sambaManaged == true and .access.sambaReachable == true and .access.usbMode == "redir" and .access.usbRedirChannels > 0 and .access.usbUdevManaged == true' <<< "$winvm_status" >/dev/null 2>&1; then
    add_item "WINVM05" "high" "Windows VM host storage or USB redirection is incomplete" "phasezero-admin linux/pz windows-vm shares install"
fi
winvm_graphics="$(bash "$PZ_ROOT/linux/windows-vm/graphics.sh" doctor --json 2>/dev/null || echo '{}')"
if ! jq -e '.runtime.status == "ok"' <<< "$winvm_graphics" >/dev/null 2>&1; then
    add_item "WINVM06" "medium" "Windows VM graphics runtime missing or stale" "phasezero-admin linux/pz windows-vm graphics runtime install --json"
fi
if jq -e '.configuredProfile != .effectiveProfile' <<< "$winvm_graphics" >/dev/null 2>&1; then
    add_item "WINVM07" "medium" "Windows VM graphics profile is incompatible with current backend" "linux/pz windows-vm graphics apply --profile compat"
fi
winapps_status="$(bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" doctor 2>/dev/null || echo '{}')"
if ! jq -e '.healthy == true' <<< "$winapps_status" >/dev/null 2>&1; then
    add_item "WINVM08" "medium" "WinBoat/WinPodX Podman host integration incomplete" "linux/pz windows-vm apps setup"
fi
if ! jq -e '.concurrency.safe == true' <<< "$winapps_status" >/dev/null 2>&1; then
    add_item "WINVM09" "high" "Multiple Windows guest backends are active" "stop other Windows guests before launch"
fi

# Waydroid
waydroid_status="$(bash "$PZ_ROOT/linux/waydroid/waydroid.sh" status 2>/dev/null || echo '{}')"
if ! jq -e '.host.waydroid != "" and (.host.cage != "" or .host.kwinWayland != "" or .host.weston != "")' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID01" "medium" "Waydroid host packages or compositor missing" "linux/pz install waydroid-linux --dry-run"
fi
if ! jq -e '.host.binderFilesystem == true and .host.binderDevices == true and .host.binderMounted == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID02" "medium" "Waydroid binder runtime not ready" "sudo linux/waydroid/waydroid.sh repair"
fi
if ! jq -e '.android.serviceEnabled == "enabled" or .android.serviceActive == "active"' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID03" "medium" "Waydroid container service not enabled/active" "sudo linux/waydroid/waydroid.sh repair"
fi
if ! jq -e '.android.initialized == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID04" "medium" "Waydroid Android image not initialized" "sudo linux/waydroid/waydroid.sh repair --init"
fi
if ! jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and (.boot.grubCfgEntry == "present" or .boot.grubCfgEntry == "unknown-permission")' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID05" "medium" "Waydroid direct boot missing or stale" "sudo linux/waydroid/waydroid.sh boot install"
fi
if ! jq -e '.android.lxcPostStopHookSafe == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID06" "medium" "Waydroid LXC post-stop hook is not executable" "sudo linux/waydroid/waydroid.sh repair"
fi
if ! jq -e '.access.sharesHelperInstalled == true and .access.sharesReady == true and .access.mountCount > 0 and .access.usbBusShared == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    add_item "WAYDROID07" "high" "Waydroid host storage or USB bus access is incomplete" "phasezero-admin linux/pz waydroid shares install"
fi

# Emulation stack
emulation_root="${PZ_EMULATION_ROOT:-$HOME/Emulation}"
applications_dir="${PZ_APPLICATIONS_DIR:-$HOME/Applications}"
hydra_classic_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json"
hydra_emulators_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json"
if [ ! -d "$emulation_root" ]; then
    add_item "EMU01" "low" "Shared emulation layout missing" "linux/pz emulation layout"
fi
if [ ! -x "$applications_dir/EmuDeck.AppImage" ]; then
    add_item "EMU02" "low" "EmuDeck AppImage launcher missing" "linux/pz emulation emudeck install"
fi
if [ ! -x "$applications_dir/Eden.AppImage" ]; then
    add_item "EMU03" "low" "Eden Steam Deck AppImage launcher missing" "linux/pz emulation eden install"
fi
if [ ! -x "$applications_dir/Hydra.AppImage" ]; then
    add_item "EMU05" "low" "Hydra AppImage launcher missing" "linux/pz emulation hydra install"
elif ! python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" status --app-name Hydra >/dev/null 2>&1; then
    add_item "EMU06" "low" "Hydra Steam shortcut missing" "linux/pz emulation hydra steam-shortcut"
fi
if [ ! -f "$hydra_classic_config" ] || ! jq -e '.displayClassicContent == true and .enableRetroUIFeatures == true' "$hydra_classic_config" >/dev/null 2>&1; then
    add_item "EMU07" "low" "Hydra Classic flags missing" "linux/pz emulation hydra classic-config"
fi
if { [ -x "$applications_dir/DuckStation.AppImage" ] || [ -x "$applications_dir/pcsx2-Qt.AppImage" ] || [ -x "$applications_dir/rpcs3.AppImage" ]; } &&
    { [ ! -f "$hydra_emulators_config" ] || ! jq -e 'length > 0' "$hydra_emulators_config" >/dev/null 2>&1; }; then
    add_item "EMU08" "low" "Hydra emulator mappings missing" "linux/pz emulation hydra emulators-config"
fi
if [ -d "$emulation_root/firmware/switch/keys" ] && [ ! -f "$emulation_root/firmware/switch/keys/prod.keys" ]; then
    add_item "EMU04" "low" "Switch keys not imported" "linux/pz emulation switch import-keys <owned-dump-path>"
fi
srm_status="$(bash "$PZ_ROOT/linux/emulation/srm.sh" status 2>/dev/null || echo '{}')"
if jq -e '.configured == true' <<< "$srm_status" >/dev/null 2>&1; then
    :
elif jq -e '.appImageInstalled == true or .launcherInstalled == true' <<< "$srm_status" >/dev/null 2>&1; then
    add_item "EMU09" "medium" "Steam ROM Manager Steam/ROM/emulator paths not configured" "linux/pz emulation srm configure"
fi
ps3_status="$(bash "$PZ_ROOT/linux/emulation/ps3.sh" status 2>/dev/null || echo '{}')"
if ! jq -e '.vfsConfigured == true' <<< "$ps3_status" >/dev/null 2>&1; then
    add_item "EMU10" "medium" "RPCS3 PS3 VFS paths not configured" "linux/pz emulation ps3 configure"
fi
shortcut_status="$(bash "$PZ_ROOT/linux/emulation/shortcuts.sh" status --json 2>/dev/null || echo '{}')"
if ! jq -e '.status == "ok"' <<< "$shortcut_status" >/dev/null 2>&1; then
    shortcut_warns="$(jq -r '[.checks[]? | select(.status == "warn")] | length' <<< "$shortcut_status" 2>/dev/null || echo 0)"
    add_item "EMU11" "medium" "Desktop menu has ${shortcut_warns} AppImage launcher issue(s)" "linux/pz emulation shortcuts repair"
fi
performance_status="$(bash "$PZ_ROOT/linux/emulation/performance.sh" status 2>/dev/null || echo '{}')"
if ! jq -e '.configValid == true and .runtimeInstalled == true' <<< "$performance_status" >/dev/null 2>&1; then
    add_item "EMU12" "medium" "Adaptive Switch/PS3/PS4 performance profiles missing" "linux/pz emulation performance apply"
fi
if jq -e '.lsfg.ready != true and .lsfg.deckyPluginInstalled == true and .lsfg.losslessScalingInstalled == true' <<< "$performance_status" >/dev/null 2>&1; then
    add_item "EMU13" "medium" "LSFG plugin and Lossless Scaling present but Vulkan layer incomplete" "linux/pz emulation performance prepare-lsfg"
fi

if missing_any_command lua lua5.4 luajit luarocks; then
    add_item "LUA01" "medium" "Lua runtime incomplete" "linux/pz emulation lua install"
fi

if ! command -v protontricks >/dev/null 2>&1 ||
    ! command -v protonup-qt >/dev/null 2>&1 ||
    { ! command -v retroarch >/dev/null 2>&1 && { ! command -v flatpak >/dev/null 2>&1 || ! flatpak info org.libretro.RetroArch >/dev/null 2>&1; }; }; then
    add_item "STEAMTOOLS01" "medium" "Core Steam helper tools missing" "linux/pz emulation steam-tools install"
fi

if ! command -v ludusavi >/dev/null 2>&1 && { ! command -v flatpak >/dev/null 2>&1 || ! flatpak info com.github.mtkennerly.ludusavi >/dev/null 2>&1; }; then
    add_item "STEAMTOOLS02" "low" "Optional Ludusavi save backup missing" "linux/pz emulation steam-tools dry-run"
fi

boot_status="$(bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status 2>/dev/null || true)"
boot_entry_state="$(awk -F': ' '$1 == "grub_cfg_entry" {print $2; exit}' <<< "$boot_status")"
if [ ! -x /usr/local/lib/phasezero/steamos-boot-prepare ] || [ ! -x /etc/grub.d/42_phasezero_steamos ]; then
    add_item "BOOT01" "low" "Optional GRUB SteamOS console boot entry not installed" "sudo linux/steamdeck/install-steamos-boot.sh install"
elif [ "$boot_entry_state" = "missing" ]; then
    add_item "BOOT02" "medium" "PhaseZero SteamOS GRUB entry missing from generated grub.cfg" "sudo linux/steamdeck/install-steamos-boot.sh install"
fi
boot_recovery_status="$(bash "$PZ_ROOT/linux/boot/recovery.sh" status 2>/dev/null || true)"
boot_recovery_card="$(awk -F': ' '$1 ~ /recovery_card$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_phasezero_efi="$(awk -F': ' '$1 ~ /phasezero_efi$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_active_efi_prefix="$(awk -F': ' '$1 ~ /active_efi_prefix$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_safe_menu_profile="$(awk -F': ' '$1 ~ /safe_menu_profile$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_emergency_entry="$(awk -F': ' '$1 ~ /emergency_shell_entry$/ {print $2; exit}' <<< "$boot_recovery_status")"
if [ -z "$boot_recovery_card" ] || [ "$boot_recovery_card" = "missing" ]; then
    add_item "BOOTREC01" "low" "GRUB rescue card not installed" "sudo linux/pz boot install-card"
fi
if [ -z "$boot_phasezero_efi" ] || [ "$boot_phasezero_efi" = "missing" ]; then
    add_item "BOOTREC02" "low" "UUID-based PhaseZero standalone EFI fallback not installed" "sudo linux/pz boot install-efi-fallback"
elif [[ "$boot_phasezero_efi" == permission-denied* ]]; then
    add_item "BOOTREC04" "low" "EFI fallback status needs privileged verification" "sudo linux/pz boot status"
fi
if [ "$boot_active_efi_prefix" = "dangerous" ]; then
    add_item "BOOTEFI01" "high" "Active EFI GRUB loader has dangerous disk-order prefix" "sudo linux/pz boot install-efi-fallback --active --fallback"
elif [ "$boot_active_efi_prefix" = "permission-denied" ]; then
    add_item "BOOTEFI02" "low" "Active EFI GRUB prefix needs privileged verification" "sudo linux/pz boot status"
fi
if [ -z "$boot_safe_menu_profile" ] || [ "$boot_safe_menu_profile" = "missing" ]; then
    add_item "BOOTMENU01" "medium" "GRUB menu is not forced visible with a safe timeout for Steam Deck selection" "sudo linux/pz boot install-safe-menu"
elif [[ "$boot_safe_menu_profile" == permission-denied* ]]; then
    add_item "BOOTMENU02" "low" "GRUB safe menu profile needs privileged verification" "sudo linux/pz boot status"
fi
if [ "$boot_emergency_entry" = "installed" ]; then
    add_item "BOOTREC03" "medium" "Temporary emergency shell GRUB entry still installed" "sudo linux/pz boot emergency-shell clear"
fi
if [ ! -x /etc/grub.d/46_phasezero_iso_loopback ] || [ ! -x /etc/grub.d/47_phasezero_removable_efi ]; then
    add_item "BOOTISO01" "low" "Dynamic ISO/removable GRUB generators not installed" "sudo linux/pz boot iso install"
fi
if [ -x "$PZ_ROOT/linux/boot/iso-boot.sh" ]; then
    iso_unavailable="$(bash "$PZ_ROOT/linux/boot/iso-boot.sh" iso status --json 2>/dev/null | jq '[.entries[] | select(.available != true)] | length' 2>/dev/null || echo 0)"
    if [ "$iso_unavailable" -gt 0 ] 2>/dev/null; then
        add_item "BOOTISO02" "medium" "$iso_unavailable registered ISO boot entries unavailable or changed" "linux/pz boot iso status --json"
    fi
fi

# Development profile gaps
if missing_any_command go; then
    add_item "DEV01" "low" "Go development toolchain missing" "sudo pacman -S --needed go"
fi

# AI/local services
ai_status="$(bash "$PZ_ROOT/linux/ai/status.sh" 2>/dev/null || echo '{}')"
if ! jq -e '.clis.ollama.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI01" "low" "Ollama missing" "linux/pz ai setup ollama"
elif ! jq -e '.services.ollama.active == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI02" "low" "Ollama service inactive" "sudo systemctl enable --now ollama"
fi

if ! jq -e '.clis.opencode.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI03" "medium" "OpenCode CLI missing" "linux/pz ai setup opencode"
fi

# OpenCode CLI/desktop version skew corrupts the shared DB for the older one.
oc_ver_repair="$(bash "$PZ_ROOT/linux/ai/setup-opencode.sh" version-status 2>/dev/null || echo '{}')"
if jq -e '.desktop != null and .inSync == false' <<< "$oc_ver_repair" >/dev/null 2>&1; then
    add_item "AI17" "high" "OpenCode CLI ($(jq -r '.cli // "none"' <<< "$oc_ver_repair")) and desktop ($(jq -r '.desktop' <<< "$oc_ver_repair")) versions differ; shared DB skew breaks the CLI" "linux/pz ai opencode sync"
fi

# oh-my-openagent: only flag the broken half-installed state (plugin registered
# but its bun runtime absent); never nag to install an opt-in agent framework.
omo_repair_status="$(bash "$PZ_ROOT/linux/ai/setup-omo.sh" status 2>/dev/null || echo '{}')"
if jq -e '.plugin.registered == true and .bun.present == false' <<< "$omo_repair_status" >/dev/null 2>&1; then
    add_item "AI18" "medium" "oh-my-openagent plugin registered but bun runtime missing (OpenCode cannot load it)" "linux/pz ai setup omo"
fi

if ! jq -e '.clis.claude.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI04" "medium" "Claude Code CLI missing" "linux/pz ai setup claude"
fi

if ! jq -e '.desktopApps.claudeDesktop.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI13" "medium" "Claude Desktop missing" "linux/pz ai desktop install-claude"
fi

if ! jq -e '.desktopApps.codexDesktop.guardEnabled == true and .desktopApps.updater.timerEnabled == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI14" "medium" "AI desktop automatic updates not enabled" "linux/pz ai desktop install-services"
fi

if jq -e '.desktopApps.codexDesktop.updateStatus == "failed"' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI15" "high" "Codex Desktop local update failed" "linux/pz ai desktop repair-codex"
fi

if ! jq -e '.clis.hermes.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI08" "medium" "Hermes Agent missing" "linux/pz ai setup hermes"
elif ! jq -e '.agentConfigs.hermes.mcpServerCount > 0' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI10" "low" "Hermes MCP servers not configured" "linux/ai/setup-hermes.sh configure"
fi

if ! jq -e '.memory.installed == true and (.memory.serverReachable == true or .memory.configuredMarker == true or .memory.userServiceActive == true)' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI05" "medium" "ai-memory not installed or not wired" "linux/pz ai setup memory"
fi

if ! jq -e '.agentCompat.tools.rtk.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI16" "medium" "RTK shell compression missing" "linux/pz ai setup rtk"
fi

if ! jq -e '.agentCompat.tools.caveman.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI17" "low" "Caveman/PhaseZero agent rules missing" "linux/pz ai setup caveman"
fi

if ! jq -e '.agentCompat.tools.headroom.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI18" "low" "Headroom context compressor missing" "linux/pz ai setup headroom"
fi

if ! jq -e '.agentCompat.tools.aiContextFrugality.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI19" "low" "AI context frugality pack missing" "linux/pz ai setup frugality"
fi

if ! jq -e '.adminBridge.ready == true' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI20" "medium" "Admin escalation bridge missing for AI CLIs/IDEs" "linux/pz ai setup admin"
fi

if ! jq -e '[.mcp.targets[]?.count // 0] | add > 0' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI06" "low" "MCP definitions not synced to Linux AI clients" "linux/pz ai mcp sync"
fi

if ! jq -e '.ides | [.[] | select(.available == true)] | length > 0' <<< "$ai_status" >/dev/null 2>&1; then
    add_item "AI07" "low" "No AI-capable IDE/editor detected" "sudo pacman -S --needed code neovim"
fi

if command -v tailscale >/dev/null 2>&1 && ! tailscale status >/dev/null 2>&1; then
    add_item "NET02" "low" "Tailscale installed but not connected" "sudo systemctl enable --now tailscaled && sudo tailscale up"
elif ! command -v tailscale >/dev/null 2>&1; then
    add_item "NET02" "low" "Tailscale missing" "sudo pacman -S --needed tailscale && sudo systemctl enable --now tailscaled && sudo tailscale up"
fi

echo "=== PhaseZero Repair Plan ==="
echo "Generated: $(date)"
echo

if [ ! -s "$PLAN_FILE" ]; then
    echo "No repairs needed. System is healthy."
    exit 0
fi

jq -s -r '
    def weight: if .priority == "high" then 0 elif .priority == "medium" then 1 elif .priority == "low" then 2 else 9 end;
    sort_by(weight, .id)
    | .[]
    | "[\(.priority | ascii_upcase)] \(.id): \(.description)\n  -> \(.command)\n"
' "$PLAN_FILE"

echo "=== Commands to execute ==="
jq -s -r 'sort_by(.id)[] | "  \(.id): \(.command)"' "$PLAN_FILE"
