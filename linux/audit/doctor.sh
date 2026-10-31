#!/usr/bin/env bash
# doctor.sh - PhaseZero system diagnostics (30+ health checks)
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PASS=0 WARN=0 FAIL=0 ERROR=0 INFO=0
RESULTS=()
RESULTS_JSON=()
# PZ: `--json` promete saída de máquina. Sem isto a flag era ignorada em
# silêncio e o consumidor recebia o relatório humano.
JSON_OUTPUT="${PZ_DOCTOR_JSON:-0}"
# Em modo JSON quem monta o encanamento é o `pz`: ele abre o descritor 3 para
# o stdout real e manda o stdout deste script para /dev/null. Assim o relatório
# humano — daqui e de todo subcomando — não tem como vazar para dentro do
# envelope, e nenhuma linha nova precisa lembrar de se silenciar.

check() {
    local id="$1" desc="$2" status="$3" msg="$4"
    case "$status" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        ERROR) ERROR=$((ERROR + 1)) ;;
        INFO) INFO=$((INFO + 1)) ;;
    esac
    RESULTS+=("[$status] $id: $desc — $msg")
    RESULTS_JSON+=("$(jq -cn --arg id "$id" --arg title "$desc" --arg status "$status" \
        --arg detail "$msg" '{id:$id, title:$title, status:$status, detail:$detail}')")
    echo "[$status] $id: $desc"
}

header() { echo; echo "=== $1 ==="; }

# External subcommands get a bounded budget so one hung check can never stall
# the whole doctor run. Override with PZ_DOCTOR_CMD_TIMEOUT (seconds).
PZ_DOCTOR_CMD_TIMEOUT="${PZ_DOCTOR_CMD_TIMEOUT:-30}"
run() { timeout "$PZ_DOCTOR_CMD_TIMEOUT" "$@"; }
footer() {
    echo
    echo "=== Summary ==="
    printf "PASS: %d  WARN: %d  FAIL: %d  ERROR: %d  INFO: %d\n" "$PASS" "$WARN" "$FAIL" "$ERROR" "$INFO"
    echo "Total: $((PASS + WARN + FAIL + ERROR + INFO)) checks"
    [ "$FAIL" -gt 0 ] && echo ">>> Some checks FAILED" || echo ">>> All checks passed"
}
finish() {
    if [ "$JSON_OUTPUT" = "1" ]; then
        # Envelope objeto, como os demais comandos de status do produto.
        printf '%s\n' "${RESULTS_JSON[@]}" | jq -s \
            --arg scope "${PZ_DOCTOR_SCOPE:-full}" \
            --argjson pass "$PASS" --argjson warn "$WARN" --argjson fail "$FAIL" \
            --argjson error "$ERROR" --argjson info "$INFO" \
            '{schemaVersion:1, tool:"doctor", scope:$scope,
              summary:{pass:$pass, warn:$warn, fail:$fail, error:$error, info:$info,
                       total:($pass+$warn+$fail+$error+$info)},
              ok:(($fail+$error) == 0),
              checks:.}' >&3
        return 0
    fi
    footer
    echo
    echo "Results JSON:"
    printf '%s\n' "${RESULTS[@]}" | jq -R . | jq -s .
    [ "$FAIL" -eq 0 ] && [ "$ERROR" -eq 0 ]
}

header "System Info"
echo "Host:       $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || hostnamectl hostname)"
echo "Kernel:     $(uname -r)"
echo "OS:         $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo 'N/A')"
echo "Uptime:     $(uptime -p)"
echo "Shell:      $SHELL"
echo "CPU:        $(LANG=C lscpu 2>/dev/null | grep 'Model name' | head -1 | cut -d: -f2 | xargs || echo 'N/A')"

# Host profile — reused across multiple checks
HOST_PROFILE=generic
case "$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)" in
    Jupiter|Jupiter*) HOST_PROFILE=steamdeck-lcd ;;
    Galileo|Galileo*)  HOST_PROFILE=steamdeck-oled ;;
esac

# Subsystems manifest — suppress checks for never-opted-in subsystems
SUBSYSTEMS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/subsystems.conf"
if [ -f "$SUBSYSTEMS_CONF" ]; then
    source "$SUBSYSTEMS_CONF"
fi
subsystem_opted() {
    local var="SUBSYSTEM_$1"
    # CCS-016: ausência de conf = nunca optou. Um host fresco não pode virar
    # uma parede de WARN por subsystemas que o usuário nunca pediu.
    case "${!var:-never}" in
        opted|partial) return 0 ;;
        *) return 1 ;;
    esac
}

header "Memory"
total_mem_mb=$(LANG=C free -m | awk '/^Mem:/ {if ($2 ~ /^[0-9]+$/) print $2; else print "nan"}')
avail_mem_mb=$(LANG=C free -m | awk '/^Mem:/ {if ($7 ~ /^[0-9]+$/) print $7; else print "nan"}')
swap_total_mb=$(LANG=C free -m | awk '/^Swap:/ {if ($2 ~ /^[0-9]+$/) print $2; else print "nan"}')
[[ "$total_mem_mb" =~ ^[0-9]+$ ]] && total_mem_mb_num=$total_mem_mb || total_mem_mb_num=0
[[ "$avail_mem_mb" =~ ^[0-9]+$ ]] && avail_mem_mb_num=$avail_mem_mb || avail_mem_mb_num=0
[[ "$swap_total_mb" =~ ^[0-9]+$ ]] && swap_total_mb_num=$swap_total_mb || swap_total_mb_num=0
total_mem_gb=$((total_mem_mb_num / 1024))
avail_mem_gb=$((avail_mem_mb_num / 1024))
swap_total_gb=$((swap_total_mb_num / 1024))
if [[ "$total_mem_mb" =~ ^[0-9]+$ ]] && [ "$total_mem_mb" -ge 4096 ]; then
    check MEM01 "Total RAM >= 4GB" PASS "${total_mem_gb}GB"
elif [[ "$total_mem_mb" =~ ^[0-9]+$ ]]; then
    check MEM01 "Total RAM >= 4GB" WARN "${total_mem_gb}GB"
else
    check MEM01 "Total RAM >= 4GB" ERROR "parse fail: ${total_mem_mb}MB"
fi
if [[ "$avail_mem_mb" =~ ^[0-9]+$ ]] && [ "$avail_mem_mb" -ge 1024 ]; then
    check MEM02 "Available RAM >= 1GB" PASS "${avail_mem_gb}GB"
elif [[ "$avail_mem_mb" =~ ^[0-9]+$ ]]; then
    check MEM02 "Available RAM >= 1GB" WARN "${avail_mem_gb}GB"
else
    check MEM02 "Available RAM >= 1GB" ERROR "parse fail: ${avail_mem_mb}MB"
fi
if [[ "$swap_total_mb" =~ ^[0-9]+$ ]] && [ "$swap_total_mb" -ge 2048 ]; then
    check MEM03 "Swap >= 2GB" PASS "${swap_total_gb}GB"
elif [[ "$swap_total_mb" =~ ^[0-9]+$ ]]; then
    check MEM03 "Swap >= 2GB" WARN "${swap_total_gb}GB"
else
    check MEM03 "Swap >= 2GB" ERROR "parse fail: ${swap_total_mb}MB"
fi

header "Disk"
root_dev=$(LANG=C df --output=source / 2>/dev/null | tail -1 | xargs)
while IFS=' ' read -r dev target _size _used pct; do
    [ -z "$dev" ] && continue
    [ "$dev" = "$root_dev" ] && continue
    case "$target" in
        /|/tmp/.mount_*|/run/user/*|/var/lib/docker/overlay2/*/merged|/var/lib/snapd/snap/*) continue ;;
    esac
    case "$(LANG=C df --output=fstype "$target" 2>/dev/null | tail -1)" in
        squashfs|iso9660) continue ;;
    esac
    case "$dev" in
        /dev/loop*) continue ;;
    esac
    pct_num=${pct//[!0-9]/}
    if [[ ! "$pct_num" =~ ^[0-9]+$ ]]; then
        check "DISK_$(echo "$target" | tr / _)" "$target usage" ERROR "malformed df output: $pct"
        continue
    fi
    [ "$pct_num" -gt 90 ] && check "DISK_$(echo "$target" | tr / _)" "$target usage" FAIL "$pct used"
    [ "$pct_num" -le 90 ] && [ "$pct_num" -gt 80 ] && check "DISK_$(echo "$target" | tr / _)" "$target usage" WARN "$pct used"
done < <(LANG=C df -h --output=source,target,size,used,pcent 2>/dev/null | tail -n+2)

root_pct=$(LANG=C df -h / | tail -1 | awk '{print $5}')
root_pct_num=${root_pct//[!0-9]/}
if [[ ! "$root_pct_num" =~ ^[0-9]+$ ]]; then
    check DISK_ROOT "root partition usage" ERROR "malformed df output: $root_pct"
elif [ "$root_pct_num" -gt 90 ]; then
    check DISK_ROOT "root partition usage" FAIL "$root_pct"
elif [ "$root_pct_num" -gt 80 ]; then
    check DISK_ROOT "root partition usage" WARN "$root_pct"
else
    check DISK_ROOT "root partition usage" PASS "$root_pct"
fi

root_fs=$(df -T / | tail -1 | awk '{print $2}')
if [[ "$root_fs" =~ btrfs|ext4|xfs ]]; then check FS01 "Root filesystem type" PASS "$root_fs"; else check FS01 "Root filesystem type" WARN "$root_fs"; fi

if command -v btrfs &>/dev/null && timeout 5 btrfs filesystem show / &>/dev/null 2>&1; then
    check FS02 "Btrfs available" PASS "yes"
fi

# Estado local cresce sem poda automática: cada operação deixa um registro.
# `pz installation prune` já sabe podar; o que faltava era alguém dizer que
# está na hora. Aqui foram encontrados 5122 arquivos num único diretório.
pz_state_ops="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/operations"
if [ -d "$pz_state_ops" ]; then
    ops_files=0
    for _entry in "$pz_state_ops"/*.json; do
        [ -e "$_entry" ] || break
        ops_files=$((ops_files + 1))
    done
    if [ "$ops_files" -gt 500 ]; then
        check STATE01 "Local operation records bounded" WARN \
            "$ops_files registros em $pz_state_ops; poda: pz installation prune"
    else
        check STATE01 "Local operation records bounded" PASS "$ops_files registros"
    fi
fi

header "CPU / Temperature"
temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)
if [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -gt 0 ]; then
    temp_c=$((temp / 1000))
    if [ "$temp_c" -lt 85 ]; then check CPU01 "CPU temperature < 85°C" PASS "${temp_c}°C"; else check CPU01 "CPU temperature < 85°C" FAIL "${temp_c}°C"; fi
else
    check CPU01 "CPU temperature" INFO "sensor unavailable"
fi

load_1=$(uptime | awk -F'load average:' '{print $2}' | cut -d, -f1 | xargs)
cpus=$(nproc)
if awk -v loadavg="$load_1" -v cpus="$cpus" 'BEGIN { exit (loadavg < cpus ? 0 : 1) }'; then check CPU02 "CPU load (1m) < cores" PASS "$load_1 / $cpus"; else check CPU02 "CPU load (1m) < cores" WARN "$load_1 / $cpus"; fi

header "GPU (AMD)"
if lspci -nn | grep -i "VGA.*AMD\|VGA.*ATI\|VanGogh" >/dev/null; then check GPU01 "AMD GPU detected" PASS "VanGogh 0405"; else check GPU01 "AMD GPU detected" WARN "not found"; fi
if [ -d /sys/class/drm/card1/device ]; then check GPU02 "GPU device in sysfs" PASS ""; else check GPU02 "GPU device in sysfs" FAIL ""; fi

header "Network"
if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then check NET01 "Internet connectivity" PASS ""; else check NET01 "Internet connectivity" FAIL ""; fi
if command -v tailscale &>/dev/null && tailscale status 2>/dev/null | head -1 | grep "Connected" >/dev/null; then
    check NET02 "Tailscale connected" PASS ""
elif [[ "$HOST_PROFILE" =~ ^steamdeck ]] && ! ip link show tailscale0 >/dev/null 2>&1; then
    check NET02 "Tailscale connected" INFO "not configured on Steam Deck"
else
    check NET02 "Tailscale connected" WARN "not connected or not installed"
fi

header "Services"
for svc in docker sshd NetworkManager bluetooth; do
    if systemctl is-active "$svc" &>/dev/null; then check "SVC_$svc" "$svc running" PASS ""; else check "SVC_$svc" "$svc running" WARN "inactive"; fi
done

if [ "${PZ_DOCTOR_SCOPE:-full}" = "system" ]; then
    finish
    exit $?
fi

header "Steam Deck"
if [ "$HOST_PROFILE" != generic ]; then check SD01 "Steam Deck hardware" PASS "$HOST_PROFILE"; else check SD01 "Steam Deck hardware" WARN "not a Steam Deck"; fi
if command -v gamescope &>/dev/null; then check SD02 "Gamescope installed" PASS "$(gamescope --version 2>&1 | head -1)"; else check SD02 "Gamescope installed" FAIL ""; fi
if command -v steam &>/dev/null; then check SD03 "Steam installed" PASS ""; else check SD03 "Steam installed" FAIL ""; fi

header "SteamOS UX"
if command -v steam &>/dev/null; then check UX01 "Steam client available" PASS "$(command -v steam)"; else check UX01 "Steam client available" WARN "install steam"; fi
if command -v gamescope &>/dev/null; then check UX02 "Gamescope available" PASS "$(command -v gamescope)"; else check UX02 "Gamescope available" WARN "install gamescope"; fi
if command -v mangohud &>/dev/null; then check UX03 "MangoHud available" PASS "$(command -v mangohud)"; else check UX03 "MangoHud available" WARN "install mangohud"; fi
if command -v gamemoderun &>/dev/null; then check UX04 "GameMode launcher available" PASS "$(command -v gamemoderun)"; else check UX04 "GameMode launcher available" WARN "install gamemode"; fi

vk_status="$(run bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" status 2>/dev/null || echo '{}')"
vk_health="$(printf '%s\n' "$vk_status" | bash "$PZ_ROOT/linux/steamdeck/input-actions.sh" health-json 2>/dev/null || printf 'WARN\tvirtual keyboard status unreadable\n')"
vk_level="${vk_health%%$'\t'*}"
vk_detail="${vk_health#*$'\t'}"
case "$vk_level" in
    PASS|WARN) ;;
    *) vk_level="WARN"; vk_detail="virtual keyboard status unreadable" ;;
esac
check UX05 "Virtual keyboard available" "$vk_level" "$vk_detail"

if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/sxhkd/sxhkdrc" ] || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/swhkd/swhkdrc" ]; then
    check UX06 "Steam Deck hotkey config installed" PASS "found"
else
    check UX06 "Steam Deck hotkey config installed" WARN "run: linux/pz steamdeck hotkeys install"
fi

if systemctl --user is-active phasezero-steamdeck-hotkeys.service &>/dev/null; then
    check UX07 "Steam Deck hotkeys active" PASS "sxhkd service"
elif command -v qdbus6 &>/dev/null && qdbus6 org.kde.kglobalaccel 2>/dev/null | grep 'phasezero_.*_desktop' >/dev/null; then
    check UX07 "Steam Deck hotkeys active" PASS "KDE native shortcuts"
else
    check UX07 "Steam Deck hotkeys active" WARN "inactive or compositor-native shortcuts required"
fi

if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-steamdeck-mode-watcher.service" ]; then
    check UX08 "Steam Deck mode watcher installed" PASS "user service"
else
    check UX08 "Steam Deck mode watcher installed" WARN "run: linux/pz steamdeck watcher install"
fi

if systemctl --user is-active phasezero-steamdeck-mode-watcher.service &>/dev/null; then check UX09 "Steam Deck mode watcher active" PASS ""; else check UX09 "Steam Deck mode watcher active" WARN "not running"; fi
if command -v ryzenadj &>/dev/null; then check UX10 "TDP control available" PASS "$(command -v ryzenadj)"; else check UX10 "TDP control available" WARN "install ryzenadj for TDP limits"; fi

priv_helper="/usr/local/lib/phasezero/steamdeck-privileged-control"
priv_dropin="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-steamdeck-mode-watcher.service.d/10-privileged-controls.conf"
if [ -x "$priv_helper" ] && [ -f "$priv_dropin" ] && sudo -n "$priv_helper" status >/dev/null 2>&1; then
    check UX11 "Privileged TDP/GPU bridge installed" PASS "$priv_helper"
else
    check UX11 "Privileged TDP/GPU bridge installed" WARN "run: sudo linux/steamdeck/install-privileged-controls.sh install"
fi

steam_plus_fallback="${XDG_CONFIG_HOME:-$HOME/.config}/gamescope-session-plus/sessions.d/steam-plus"
if command -v opengamepadui >/dev/null 2>&1; then
    check UX12 "Steam Big Picture Plus OpenGamepadUI" PASS "$(command -v opengamepadui)"
elif [ -f "$steam_plus_fallback" ]; then
    check UX12 "Steam Big Picture Plus OpenGamepadUI" INFO "missing; user fallback starts Steam Big Picture without QAM overlay"
else
    check UX12 "Steam Big Picture Plus OpenGamepadUI" WARN "missing; install OpenGamepadUI or run: linux/pz steamdeck boot install"
fi

decky_status="$(run bash "$PZ_ROOT/linux/steamdeck/plugins.sh" status 2>/dev/null || echo '{}')"
if jq -e '.decky.service.dualServiceConflict == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" WARN "system and user plugin_loader services both active; run: linux/pz steamdeck plugins repair"
elif jq -e '.steamDeckExperience.deckyMenuReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" PASS "loader + CEF debug ready"
elif jq -e '.decky.installed == true and .decky.service.active == true and .decky.cefRemoteDebuggingEnabled == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX13 "Decky Loader Big Picture integration" WARN "restart Steam/Gamepad UI so CEF debug port opens"
else
    check UX13 "Decky Loader Big Picture integration" WARN "run: linux/pz steamdeck plugins install"
fi

if jq -e '.steamDeckExperience.tdpPluginReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" PASS "privileged Decky service active"
elif jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installed == true and .healthy != true)' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" WARN "PowerTools incomplete; run: linux/pz steamdeck plugins install-plugin-privileged PowerTools"
elif jq -e '.desiredPlugins[] | select(.id == "PowerTools" and .installed == true)' <<< "$decky_status" >/dev/null 2>&1 &&
    jq -e '.steamDeckExperience.tdpFallbackReady == true' <<< "$decky_status" >/dev/null 2>&1; then
    check UX14 "Decky PowerTools TDP plugin" INFO "PowerTools installed; plugin TDP needs privileged Decky, PhaseZero ryzenadj fallback ready"
else
    check UX14 "Decky PowerTools TDP plugin" WARN "run: linux/pz steamdeck plugins install-plugins"
fi

if jq -e '.steamDeckExperience.themePluginReady == true and ([.desiredThemes[] | select(.installed == true)] | length > 0)' <<< "$decky_status" >/dev/null 2>&1; then
    check UX15 "Decky CSS Loader themes" PASS "CSS Loader + themes installed"
else
    check UX15 "Decky CSS Loader themes" WARN "run: linux/pz steamdeck plugins install-themes"
fi

if jq -e '[.desiredPlugins[] | select(.installed == true and .healthy != true)] | length == 0' <<< "$decky_status" >/dev/null 2>&1; then
    check UX16 "Decky plugin package health" PASS "all installed curated plugins have runnable package layout"
else
    bad_plugins="$(jq -r '[.desiredPlugins[] | select(.installed == true and .healthy != true) | .id] | join(", ")' <<< "$decky_status" 2>/dev/null || true)"
    check UX16 "Decky plugin package health" WARN "repair incomplete plugins: ${bad_plugins:-unknown}"
fi

if [ -x /usr/local/lib/phasezero/steamos-session ] &&
    [ -x /usr/lib/os-session-select ] &&
    [ -f /usr/share/wayland-sessions/phasezero-steamos.desktop ]; then
    check UX17 "SteamOS desktop handoff without login" PASS "managed session + os-session-select hook"
else
    check UX17 "SteamOS desktop handoff without login" WARN "run: sudo linux/steamdeck/install-steamos-boot.sh install"
fi

header "Windows VM"
winvm_status="$(run bash "$PZ_ROOT/linux/windows-vm/windows-vm.sh" status 2>/dev/null || echo '{}')"
if jq -e '.host.qemu != "" and .host.qemuImg != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM01 "QEMU available" PASS "$(jq -r '.host.qemu' <<< "$winvm_status")"
else
    check WINVM01 "QEMU available" WARN "run: linux/pz install windows-vm-linux --dry-run"
fi
if jq -e '.host.kvm == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM02 "KVM device available" PASS "/dev/kvm"
else
    check WINVM02 "KVM device available" WARN "enable virtualization or fix /dev/kvm permissions"
fi
OVMF_CODE_PATH="$(pz_path_resolve ovmf_code \
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd \
    /usr/share/edk2-ovmf/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.secboot.fd \
    /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null || true)"
SWTPM_BIN_PATH="$(command -v swtpm || true)"
if [ -n "$OVMF_CODE_PATH" ] && [ -n "$SWTPM_BIN_PATH" ]; then
    check WINVM03 "Windows 11 firmware/TPM ready" PASS "OVMF + swtpm"
elif [ -z "$OVMF_CODE_PATH" ] && [ -n "$SWTPM_BIN_PATH" ]; then
    check WINVM03 "Windows 11 firmware/TPM ready" WARN "OVMF not found — install edk2-ovmf (swtpm OK)"
elif [ -n "$OVMF_CODE_PATH" ] && [ -z "$SWTPM_BIN_PATH" ]; then
    check WINVM03 "Windows 11 firmware/TPM ready" WARN "swtpm missing — install swtpm (OVMF OK)"
else
    check WINVM03 "Windows 11 firmware/TPM ready" WARN "install edk2-ovmf and swtpm (both missing)"
fi
if jq -e '.config.installed == true and .vm.diskExists == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM04 "Windows VM configured" PASS "$(jq -r '.vm.disk' <<< "$winvm_status")"
else
    check WINVM04 "Windows VM configured" INFO "run: linux/pz windows-vm install --iso /path/to/Win11.iso"
fi
if jq -e '.libvirt.preferred == true and .libvirt.domain != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM08 "Existing libvirt Windows domain selected" PASS "$(jq -r '.libvirt.domain + " (" + .libvirt.state + ")"' <<< "$winvm_status")"
else
    check WINVM08 "Existing libvirt Windows domain selected" INFO "no Windows domain; QEMU disk path will be used"
fi
if jq -e '.discovery.discoveredInstalledDisk.installedLike == true and .discovery.discoveredInstalledDisk.usable != true' <<< "$winvm_status" >/dev/null 2>&1; then
    blocked_disk="$(jq -r '.discovery.discoveredInstalledDisk.path' <<< "$winvm_status")"
    check WINVM07 "Existing Windows VM install usable" WARN "permission blocked: sudo linux/windows-vm/windows-vm.sh adopt --disk '$blocked_disk'"
elif jq -e '.discovery.discoveredUsableDisk.usable == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM07 "Existing Windows VM install usable" PASS "$(jq -r '.discovery.discoveredUsableDisk.path' <<< "$winvm_status")"
fi
if jq -e '.host.smbd != "" and .host.virtiofsd != ""' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM05 "Host folder sharing available" PASS "SMB + virtiofs"
else
    check WINVM05 "Host folder sharing available" WARN "install samba and virtiofsd/qemu"
fi
if jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "present"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM06 "Windows VM direct GRUB boot installed" PASS "boot artifacts current"
elif jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "unknown-permission"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM06 "Windows VM direct GRUB boot installed" INFO "artifacts current; generated GRUB entry needs privileged verification"
elif [[ "$HOST_PROFILE" =~ ^steamdeck ]]; then
    check WINVM06 "Windows VM direct GRUB boot installed" INFO "GRUB boot expected on Steam Deck; VM install will enable it"
else
    check WINVM06 "Windows VM direct GRUB boot installed" WARN "run: sudo linux/windows-vm/windows-vm.sh boot install"
fi
# A package upgrade replaces the PhaseZero tree but never /usr/local, so the
# GRUB boot path keeps running the previous version with nothing to announce
# it. This comparison needs no privilege, so it reports for every user.
if jq -e '.boot.bootRuntimeStale == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM16 "Windows VM boot runtime matches this install" FAIL \
        "GRUB boot path runs an outdated runtime; run: phasezero-admin linux/pz windows-vm boot install"
elif jq -e '.boot.bootRuntimeState == "current"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM16 "Windows VM boot runtime matches this install" PASS "boot runtime current"
elif jq -e '.boot.bootRuntimeState == "not-installed"' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM16 "Windows VM boot runtime matches this install" INFO "boot integration not installed"
else
    check WINVM16 "Windows VM boot runtime matches this install" INFO \
        "boot runtime state unverified ($(jq -r '.boot.bootRuntimeState // "unknown"' <<< "$winvm_status"))"
fi
if jq -e '.access.shareLinksReady == true and .access.sambaManaged == true and .access.sambaReachable == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM09 "Windows host storage shares ready" PASS "$(jq -r '.access.shares | join(", ")' <<< "$winvm_status")"
else
    check WINVM09 "Windows host storage shares ready" WARN "run: phasezero-admin linux/pz windows-vm shares install"
fi
if jq -e '.access.usbMode == "redir" and .access.usbRedirChannels > 0 and .access.usbUdevManaged == true' <<< "$winvm_status" >/dev/null 2>&1; then
    check WINVM10 "Windows USB redirection ready" PASS "$(jq -r '.access.usbRedirChannels|tostring' <<< "$winvm_status") SPICE channels"
else
    check WINVM10 "Windows USB redirection ready" WARN "run: phasezero-admin linux/pz windows-vm shares repair"
fi
winvm_graphics="$(run bash "$PZ_ROOT/linux/windows-vm/graphics.sh" doctor --json 2>/dev/null || echo '{}')"
winvm_gfx_effective="$(jq -r '.effectiveProfile // "unknown"' <<< "$winvm_graphics")"
winvm_gfx_eligible="$(jq -r '.graphics.profiles["virtio-gl"].eligible // false' <<< "$winvm_graphics")"
# Resolve user state dir (stable under sudo via SUDO_USER)
winvm_user_home="${HOME}"
[ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && winvm_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" && winvm_user_home="${winvm_user_home:-$HOME}"
winvm_ops_dir="${XDG_STATE_HOME:-$winvm_user_home/.local/state}/phasezero/operations"
winvm_latest_resolved=""
if [ -d "$winvm_ops_dir" ]; then
    # `ls | head -1` mata o doctor: sob `set -euo pipefail`, head fecha o
    # pipe, ls leva SIGPIPE e o pipeline devolve 141. Com muitas operações
    # gravadas (aqui: 5118) isso acontece sempre, e o relatório terminava
    # em silêncio no meio, sem avaliar nada depois deste ponto. Ordenar com
    # o próprio shell não usa pipe e não depende do tamanho do diretório.
    last_op_dir=""
    newest_mtime=0
    # Só diretórios de operação interessam; o mesmo diretório guarda milhares
    # de arquivos soltos e varrer todos custaria caro por nada.
    for op_entry in "$winvm_ops_dir"/op-*; do
        [ -d "$op_entry" ] || continue
        op_mtime="$(stat -c %Y "$op_entry" 2>/dev/null || echo 0)"
        if [ "$op_mtime" -gt "$newest_mtime" ]; then
            newest_mtime="$op_mtime"
            last_op_dir="$(basename "$op_entry")"
        fi
    done
    [ -n "$last_op_dir" ] && winvm_latest_resolved="$(jq -r '.graphicsResolved.profile // ""' "$winvm_ops_dir/$last_op_dir/operation.json" 2>/dev/null || true)"
fi
# Steam Deck VFIO note (VanGogh APU unica, sem VFIO)
winvm_deck_note=""
if grep -i 'steam\|deck\|jupiter' /sys/devices/virtual/dmi/id/product_name >/dev/null 2>&1; then
    winvm_deck_note="; Steam Deck (VanGogh APU) VFIO passthrough nao suportado"
fi
VIRGL_OK=false
ldconfig -p 2>/dev/null | grep 'virglrenderer' >/dev/null && VIRGL_OK=true
RENDER_NODE=""
for node in /dev/dri/renderD*; do
    [ -r "$node" ] && [ -w "$node" ] && { RENDER_NODE="$node"; break; }
done
if jq -e '.status == "ok"' <<< "$winvm_graphics" >/dev/null 2>&1; then
    if [ "$winvm_gfx_effective" = "compat" ] && [ "$winvm_gfx_eligible" = "true" ]; then
        check WINVM11 "Windows graphics integration" WARN "perfil=compat mas virtio-gl elegivel; upgrade: linux/pz windows-vm graphics plan --profile virtio-gl$winvm_deck_note"
    elif [ "$winvm_gfx_effective" = "compat" ]; then
        gfx_blockers=""
        $VIRGL_OK || gfx_blockers="${gfx_blockers}virglrenderer "
        [ -n "$RENDER_NODE" ] || gfx_blockers="${gfx_blockers}render-node "
        [ -n "$gfx_blockers" ] && gfx_blockers=" (faltando: ${gfx_blockers%-})"
        check WINVM11 "Windows graphics integration" INFO "perfil=compat; virtio-gl nao elegivel${gfx_blockers}${winvm_deck_note}"
    else
        resolved_detail="${winvm_latest_resolved:+ ultima resolucao: $winvm_latest_resolved}"
        check WINVM11 "Windows graphics integration" PASS "profile=$winvm_gfx_effective; runtime current${resolved_detail}${winvm_deck_note}"
    fi
elif jq -e '.runtime.status != "ok"' <<< "$winvm_graphics" >/dev/null 2>&1; then
    check WINVM11 "Windows graphics integration" WARN "run: phasezero-admin linux/pz windows-vm graphics runtime install --json$winvm_deck_note"
else
    check WINVM11 "Windows graphics integration" WARN "run: linux/pz windows-vm graphics doctor --json$winvm_deck_note"
fi
preflight_json="$(run bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --json 2>/dev/null || echo '{}')"
SWTPM_SOCKET_PATH="${XDG_RUNTIME_DIR:-/run/user/$UID}/swtpm.sock"
if [ -S "$SWTPM_SOCKET_PATH" ]; then
    check WINVM14 "swtpm daemon running" PASS "$SWTPM_SOCKET_PATH"
elif [ -n "$SWTPM_BIN_PATH" ]; then
    check WINVM14 "swtpm daemon running" WARN "binary present but daemon not running — run: linux/windows-vm/preflight.sh --auto-fix"
else
    check WINVM14 "swtpm daemon running" WARN "install swtpm (pacman -S swtpm)"
fi
if echo "$preflight_json" | jq -e '.virtio.outdated == true' >/dev/null 2>&1; then
    virtio_latest="$(echo "$preflight_json" | jq -r '.virtio.latest')"
    virtio_pinned="$(echo "$preflight_json" | jq -r '.virtio.pinned')"
    check WINVM15 "virtio-win up-to-date" WARN "pinned ${virtio_pinned}, latest ${virtio_latest} — run: linux/windows-vm/preflight.sh --auto-fix"
else
    virtio_iso="${PZ_STATE}/windows-vm/vm/virtio-win.iso"
    virtio_version="$(echo "$preflight_json" | jq -r '.virtio.latest // .virtio.pinned')"
    if [ -f "$virtio_iso" ]; then
        virtio_version="${virtio_version} (ISO cached)"
    fi
    check WINVM15 "virtio-win up-to-date" PASS "$virtio_version"
fi

winapps_status="$(run bash "$PZ_ROOT/linux/windows-vm/container-frontends.sh" doctor 2>/dev/null || echo '{}')"
if jq -e '.healthy == true' <<< "$winapps_status" >/dev/null 2>&1; then
    check WINVM12 "WinBoat + WinPodX Podman host" PASS "verified AppImages; guests stopped by default"
else
    check WINVM12 "WinBoat + WinPodX Podman host" WARN "run: linux/pz windows-vm apps setup"
fi
if jq -e '.concurrency.safe == true' <<< "$winapps_status" >/dev/null 2>&1; then
    check WINVM13 "Windows guest concurrency" PASS "one-guest policy available"
else
    check WINVM13 "Windows guest concurrency" WARN "stop competing Windows guests"
fi

header "Waydroid"
if ! subsystem_opted WAYDROID; then
    check WAYDROID00 "Waydroid subsystem" INFO "not opted in; run linux/pz install waydroid-linux to enable"
else
waydroid_status="$(run bash "$PZ_ROOT/linux/waydroid/waydroid.sh" status 2>/dev/null || echo '{}')"
if jq -e '.host.waydroid != ""' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID01 "Waydroid command available" PASS "$(jq -r '.host.waydroid' <<< "$waydroid_status")"
else
    check WAYDROID01 "Waydroid command available" WARN "run: linux/pz install waydroid-linux --dry-run"
fi
if jq -e '.host.binderFilesystem == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID02 "Binder filesystem available" PASS "kernel supports binder"
else
    check WAYDROID02 "Binder filesystem available" WARN "load binder_linux or use a kernel with binder support"
fi
if jq -e '.host.binderDevices == true and .host.binderMounted == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID03 "Binder devices mounted" PASS "binder device present"
else
    check WAYDROID03 "Binder devices mounted" WARN "run: sudo linux/waydroid/waydroid.sh repair"
fi
if jq -e '.host.cage != "" or .host.kwinWayland != "" or .host.weston != ""' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID04 "Wayland kiosk compositor available" PASS "cage/kwin/weston"
else
    check WAYDROID04 "Wayland kiosk compositor available" WARN "install cage or kwin_wayland"
fi
if jq -e '.android.serviceEnabled == "enabled" or .android.serviceActive == "active"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID05 "Waydroid container service configured" PASS "$(jq -r '.android.serviceActive' <<< "$waydroid_status")"
else
    check WAYDROID05 "Waydroid container service configured" INFO "run: sudo linux/waydroid/waydroid.sh repair"
fi
if jq -e '.android.initialized == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID06 "Waydroid Android image initialized" PASS "image present"
else
    check WAYDROID06 "Waydroid Android image initialized" INFO "optional: sudo linux/waydroid/waydroid.sh repair --init"
fi
if jq -e '.android.resumablePrefetch == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID08 "Waydroid image download resilience" PASS "mirror fallback + size/SHA-256 validation"
else
    check WAYDROID08 "Waydroid image download resilience" WARN "reinstall current Waydroid automation"
fi
if jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "present"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID07 "Waydroid direct GRUB boot installed" PASS "boot artifacts current"
elif jq -e '.boot.helperInstalled == true and .boot.serviceInstalled == true and .boot.artifactsCurrent == true and .boot.grubCfgEntry == "unknown-permission"' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID07 "Waydroid direct GRUB boot installed" INFO "artifacts current; generated GRUB entry needs privileged verification"
elif [[ "$HOST_PROFILE" =~ ^steamdeck ]]; then
    check WAYDROID07 "Waydroid direct GRUB boot installed" INFO "GRUB boot expected on Steam Deck; Waydroid install will enable it"
else
    check WAYDROID07 "Waydroid direct GRUB boot installed" WARN "run: sudo linux/waydroid/waydroid.sh boot install"
fi
if jq -e '.android.lxcPostStopHookSafe == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID09 "Waydroid LXC stop hook" PASS "executable no-op hook"
else
    check WAYDROID09 "Waydroid LXC stop hook" WARN "run: sudo linux/waydroid/waydroid.sh repair"
fi
if jq -e '.access.sharesHelperInstalled == true and .access.sharesReady == true and .access.mountCount > 0 and .access.usbBusShared == true' <<< "$waydroid_status" >/dev/null 2>&1; then
    check WAYDROID10 "Waydroid host storage and USB shares ready" PASS "$(jq -r '.access.mountCount|tostring' <<< "$waydroid_status") managed mounts"
else
    check WAYDROID10 "Waydroid host storage and USB shares ready" WARN "run: phasezero-admin linux/pz waydroid shares install"
fi
fi

header "Emulation"
emulation_root="${PZ_EMULATION_ROOT:-$HOME/Emulation}"
applications_dir="${PZ_APPLICATIONS_DIR:-$HOME/Applications}"
emudeck_app="$applications_dir/EmuDeck.AppImage"
eden_app="$applications_dir/Eden.AppImage"
hydra_app="$applications_dir/Hydra.AppImage"
hydra_classic_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/config.json"
hydra_emulators_config="${XDG_CONFIG_HOME:-$HOME/.config}/hydralauncher/emulators_config.json"
if [ -d "$emulation_root" ]; then check EMU01 "Shared emulation root" PASS "$emulation_root"; else check EMU01 "Shared emulation root" WARN "run: linux/pz emulation layout"; fi
emudeck_status="$(run bash "$PZ_ROOT/linux/emulation/emudeck.sh" status 2>/dev/null || echo '{}')"
if jq -e '.launcher.installed == true and .launcher.kind == "steamdeck-desktop"' <<< "$emudeck_status" >/dev/null 2>&1; then
    emudeck_launcher="$(jq -r '.launcher.path' <<< "$emudeck_status")"
    check EMU02 "EmuDeck Steam Deck launcher installed" PASS "$emudeck_launcher"
elif jq -e '.appImageInstalled == true' <<< "$emudeck_status" >/dev/null 2>&1 || [ -x "$emudeck_app" ]; then
    check EMU02 "EmuDeck AppImage installed" PASS "$emudeck_app"
else
    check EMU02 "EmuDeck launcher installed" WARN "run: linux/pz emulation emudeck install"
fi
if [ -x "$eden_app" ]; then check EMU03 "Eden AppImage installed" PASS "$eden_app"; else check EMU03 "Eden AppImage installed" WARN "run: linux/pz emulation eden install"; fi
if [ -x "$hydra_app" ]; then check EMU06 "Hydra AppImage installed" PASS "$hydra_app"; else check EMU06 "Hydra AppImage installed" WARN "run: linux/pz emulation hydra install"; fi
if python3 "$PZ_ROOT/linux/emulation/steam-shortcut.py" status --app-name Hydra >/dev/null 2>&1; then
    check EMU07 "Hydra Steam shortcut installed" PASS "Steam userdata"
else
    check EMU07 "Hydra Steam shortcut installed" WARN "run: linux/pz emulation hydra steam-shortcut"
fi
if [ -f "$hydra_classic_config" ] && jq -e '.displayClassicContent == true and .enableRetroUIFeatures == true' "$hydra_classic_config" >/dev/null 2>&1; then
    check EMU08 "Hydra Classic flags enabled" PASS "$hydra_classic_config"
else
    check EMU08 "Hydra Classic flags enabled" WARN "run: linux/pz emulation hydra classic-config"
fi
if [ -f "$hydra_emulators_config" ] && jq -e 'length > 0' "$hydra_emulators_config" >/dev/null 2>&1; then
    hydra_emulator_count="$(jq 'length' "$hydra_emulators_config" 2>/dev/null || echo 0)"
    check EMU09 "Hydra emulator mappings configured" PASS "${hydra_emulator_count} systems"
elif [ -x "$applications_dir/DuckStation.AppImage" ] || [ -x "$applications_dir/pcsx2-Qt.AppImage" ] || [ -x "$applications_dir/rpcs3.AppImage" ]; then
    check EMU09 "Hydra emulator mappings configured" WARN "run: linux/pz emulation hydra emulators-config"
else
    check EMU09 "Hydra emulator mappings configured" INFO "install DuckStation/PCSX2/RPCS3 then run: linux/pz emulation hydra emulators-config"
fi
if [ -d "$emulation_root/bios" ]; then
    bios_count=$(find "$emulation_root/bios" -type f 2>/dev/null | wc -l | tr -d ' ')
    check EMU04 "Local BIOS import folder" PASS "${bios_count} files"
else
    check EMU04 "Local BIOS import folder" WARN "run: linux/pz emulation layout"
fi
if [ -f "$emulation_root/firmware/switch/keys/prod.keys" ]; then
    check EMU05 "Switch keys imported locally" PASS "prod.keys present"
else
    check EMU05 "Switch keys imported locally" INFO "optional: linux/pz emulation switch import-keys <owned-dump-path>"
fi
srm_status="$(run bash "$PZ_ROOT/linux/emulation/srm.sh" status 2>/dev/null || echo '{}')"
if jq -e '.configured == true' <<< "$srm_status" >/dev/null 2>&1; then
    srm_count="$(jq -r '.managedParsers // 0' <<< "$srm_status")"
    check EMU10 "Steam ROM Manager paths configured" PASS "${srm_count} managed parsers"
elif jq -e '.appImageInstalled == true or .launcherInstalled == true' <<< "$srm_status" >/dev/null 2>&1; then
    check EMU10 "Steam ROM Manager paths configured" WARN "run: linux/pz emulation srm configure"
else
    check EMU10 "Steam ROM Manager available" INFO "optional: install via EmuDeck"
fi
ps3_status="$(run bash "$PZ_ROOT/linux/emulation/ps3.sh" status 2>/dev/null || echo '{}')"
if jq -e '.vfsConfigured == true' <<< "$ps3_status" >/dev/null 2>&1; then
    ps3_games="$(jq -r '.gameEntries // 0' <<< "$ps3_status")"
    ps3_pkg="$(jq -r '.pkgFiles // 0' <<< "$ps3_status")"
    ps3_rap="$(jq -r '.rapFiles // 0' <<< "$ps3_status")"
    check EMU11 "RPCS3 PS3 paths configured" PASS "games=${ps3_games} pkg=${ps3_pkg} rap=${ps3_rap}"
else
    check EMU11 "RPCS3 PS3 paths configured" WARN "run: linux/pz emulation ps3 configure"
fi
shortcut_status="$(run bash "$PZ_ROOT/linux/emulation/shortcuts.sh" status --json 2>/dev/null || echo '{}')"
if jq -e '.status == "ok"' <<< "$shortcut_status" >/dev/null 2>&1; then
    shortcut_count="$(jq -r '[.checks[]? | select(.status == "ok")] | length' <<< "$shortcut_status")"
    check EMU12 "Desktop AppImage launchers clean" PASS "${shortcut_count} managed launchers"
else
    shortcut_warns="$(jq -r '[.checks[]? | select(.status == "warn")] | length' <<< "$shortcut_status" 2>/dev/null || echo 0)"
    check EMU12 "Desktop AppImage launchers clean" WARN "${shortcut_warns} issue(s); run: linux/pz emulation shortcuts repair"
fi
performance_status="$(run bash "$PZ_ROOT/linux/emulation/performance.sh" status 2>/dev/null || echo '{}')"
if jq -e '.configValid == true and .runtimeInstalled == true and .profiles.switch.lsfg == "auto" and .profiles.ps3.lsfg == "auto" and .profiles.ps4.lsfg == "auto"' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU13 "Adaptive emulator profiles" PASS "Switch/PS3/PS4 auto profiles active"
else
    check EMU13 "Adaptive emulator profiles" WARN "run: linux/pz emulation performance apply"
fi
if jq -e '.lsfg.ready == true' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU14 "LSFG Vulkan frame generation" PASS "verified local layer ready"
elif jq -e '.lsfg.deckyPluginInstalled == true and .lsfg.losslessScalingInstalled == true' <<< "$performance_status" >/dev/null 2>&1; then
    check EMU14 "LSFG Vulkan frame generation" WARN "run: linux/pz emulation performance prepare-lsfg"
else
    check EMU14 "LSFG Vulkan frame generation" INFO "optional; needs Decky LSFG-VK plus owned Lossless Scaling"
fi

header "Lua Runtime"
if command -v lua >/dev/null 2>&1; then check LUA01 "Lua installed" PASS "$(lua -v 2>&1 | head -1)"; else check LUA01 "Lua installed" WARN "run: linux/pz emulation lua install"; fi
if command -v lua5.4 >/dev/null 2>&1; then check LUA02 "Lua 5.4 installed" PASS "$(lua5.4 -v 2>&1 | head -1)"; else check LUA02 "Lua 5.4 installed" WARN "run: linux/pz emulation lua install"; fi
if command -v luajit >/dev/null 2>&1; then check LUA03 "LuaJIT installed" PASS "$(luajit -v 2>&1 | head -1)"; else check LUA03 "LuaJIT installed" WARN "run: linux/pz emulation lua install"; fi
if command -v luarocks >/dev/null 2>&1; then check LUA04 "LuaRocks installed" PASS "$(luarocks --version 2>/dev/null | head -1 | xargs)"; else check LUA04 "LuaRocks installed" WARN "run: linux/pz emulation lua install"; fi

header "Steam Tools"
if command -v protontricks >/dev/null 2>&1; then check ST01 "Protontricks installed" PASS "$(command -v protontricks)"; else check ST01 "Protontricks installed" WARN "run: linux/pz emulation steam-tools install"; fi
if command -v protonup-qt >/dev/null 2>&1; then check ST02 "ProtonUp-Qt installed" PASS "$(command -v protonup-qt)"; else check ST02 "ProtonUp-Qt installed" WARN "run: linux/pz emulation steam-tools install"; fi
if command -v retroarch >/dev/null 2>&1; then
    check ST03 "RetroArch installed" PASS "$(command -v retroarch)"
elif command -v flatpak >/dev/null 2>&1 && flatpak info org.libretro.RetroArch >/dev/null 2>&1; then
    check ST03 "RetroArch installed" PASS "flatpak"
else
    check ST03 "RetroArch installed" WARN "run: linux/pz emulation steam-tools install"
fi
if command -v ludusavi >/dev/null 2>&1; then
    check ST04 "Ludusavi available" PASS "$(command -v ludusavi)"
elif command -v flatpak >/dev/null 2>&1 && flatpak info com.github.mtkennerly.ludusavi >/dev/null 2>&1; then
    check ST04 "Ludusavi available" PASS "flatpak"
else
    check ST04 "Ludusavi available" INFO "optional save backup tool"
fi
if command -v steam-rom-manager >/dev/null 2>&1 || find "$applications_dir" -maxdepth 1 -iname '*steam*rom*manager*.AppImage' -type f -perm -u+x 2>/dev/null | grep . >/dev/null; then
    check ST05 "Steam ROM Manager available" PASS "found"
else
    check ST05 "Steam ROM Manager available" INFO "optional; EmuDeck may manage SRM internally"
fi
if command -v boilr >/dev/null 2>&1 || find "$applications_dir" -maxdepth 1 -iname '*boilr*.AppImage' -type f -perm -u+x 2>/dev/null | grep . >/dev/null; then
    check ST06 "BoilR available" PASS "found"
else
    check ST06 "BoilR available" INFO "optional non-Steam importer"
fi
if command -v steamtinkerlaunch >/dev/null 2>&1; then check ST07 "SteamTinkerLaunch available" PASS "$(command -v steamtinkerlaunch)"; else check ST07 "SteamTinkerLaunch available" INFO "optional Proton/Wine per-game tool"; fi

header "SteamOS Boot"
boot_status="$(run bash "$PZ_ROOT/linux/steamdeck/install-steamos-boot.sh" status 2>/dev/null || true)"
boot_entry_state="$(awk -F': ' '$1 == "grub_cfg_entry" {print $2; exit}' <<< "$boot_status")"
if [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ] && [ "$boot_entry_state" = "present" ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" PASS "one-shot boot ready"
elif [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ] && [ "$boot_entry_state" = "unknown-permission" ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" INFO "installed; run sudo linux/steamdeck/install-steamos-boot.sh status to verify grub.cfg"
elif [ -x /usr/local/lib/phasezero/steamos-boot-prepare ] && [ -x /etc/grub.d/42_phasezero_steamos ]; then
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" WARN "grub_cfg_entry=${boot_entry_state:-unknown}; run: sudo linux/steamdeck/install-steamos-boot.sh install"
else
    check BOOT01 "PhaseZero SteamOS GRUB entry installed" INFO "optional: sudo linux/steamdeck/install-steamos-boot.sh install"
fi
boot_recovery_status="$(run bash "$PZ_ROOT/linux/boot/recovery.sh" status 2>/dev/null || true)"
boot_recovery_card="$(awk -F': ' '$1 ~ /recovery_card$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_phasezero_efi="$(awk -F': ' '$1 ~ /phasezero_efi$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_active_efi="$(awk -F': ' '$1 ~ /active_efi$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_active_efi_prefix="$(awk -F': ' '$1 ~ /active_efi_prefix$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_safe_menu_profile="$(awk -F': ' '$1 ~ /safe_menu_profile$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_safe_menu_timeout="$(awk -F': ' '$1 ~ /safe_menu_timeout$/ {print $2; exit}' <<< "$boot_recovery_status")"
boot_emergency_entry="$(awk -F': ' '$1 ~ /emergency_shell_entry$/ {print $2; exit}' <<< "$boot_recovery_status")"
if [ -n "$boot_recovery_card" ] && [ "$boot_recovery_card" != "missing" ]; then
    check BOOT02 "GRUB rescue card available" PASS "$boot_recovery_card"
else
    check BOOT02 "GRUB rescue card available" INFO "optional: sudo linux/pz boot install-card"
fi
if [[ "$boot_phasezero_efi" == permission-denied* ]]; then
    check BOOT03 "PhaseZero standalone EFI fallback available" INFO "permission denied; verify with: sudo linux/pz boot status"
elif [ -n "$boot_phasezero_efi" ] && [ "$boot_phasezero_efi" != "missing" ]; then
    check BOOT03 "PhaseZero standalone EFI fallback available" PASS "$boot_phasezero_efi"
else
    check BOOT03 "PhaseZero standalone EFI fallback available" INFO "optional: sudo linux/pz boot install-efi-fallback"
fi
case "$boot_active_efi_prefix" in
    safe) check BOOT05 "Active EFI GRUB prefix safe" PASS "$boot_active_efi" ;;
    dangerous) check BOOT05 "Active EFI GRUB prefix safe" FAIL "dangerous disk-order prefix in $boot_active_efi; run: sudo linux/pz boot install-efi-fallback --active --fallback" ;;
    permission-denied) check BOOT05 "Active EFI GRUB prefix safe" INFO "permission denied; verify with: sudo linux/pz boot status" ;;
    *) check BOOT05 "Active EFI GRUB prefix safe" INFO "unknown; verify with: sudo linux/pz boot status" ;;
esac
case "$boot_safe_menu_profile" in
    installed*) check BOOT06 "GRUB menu visible with safe timeout" PASS "${boot_safe_menu_timeout:-installed}" ;;
    permission-denied*) check BOOT06 "GRUB menu visible with safe timeout" INFO "permission denied; verify with: sudo linux/pz boot status" ;;
    *) check BOOT06 "GRUB menu visible with safe timeout" WARN "run: sudo linux/pz boot install-safe-menu" ;;
esac
if [ "$boot_emergency_entry" = "installed" ]; then
    check BOOT04 "Emergency shell GRUB entry inactive" WARN "temporary entry installed; clear after use: sudo linux/pz boot emergency-shell clear"
else
    check BOOT04 "Emergency shell GRUB entry inactive" PASS "not installed"
fi

iso_boot_backend="$PZ_ROOT/linux/boot/iso-boot.sh"
if [ -x "$iso_boot_backend" ]; then
    iso_boot_status="$(bash "$iso_boot_backend" iso status --json 2>/dev/null || echo '{}')"
    usb_boot_status="$(bash "$iso_boot_backend" usb status --json 2>/dev/null || echo '{}')"
    grubfm_status="$(bash "$iso_boot_backend" grubfm status --json 2>/dev/null || echo '{}')"
    if jq -e '.schemaVersion == 1' <<< "$iso_boot_status" >/dev/null 2>&1; then
        unavailable_iso="$(jq '[.entries[] | select(.available != true)] | length' <<< "$iso_boot_status")"
        if [ "$unavailable_iso" -eq 0 ]; then check BOOTISO01 "Registered ISO boot entries healthy" PASS "$(jq '.entries | length' <<< "$iso_boot_status") registered"; else check BOOTISO01 "Registered ISO boot entries healthy" WARN "$unavailable_iso unavailable or changed"; fi
    else
        check BOOTISO01 "Registered ISO boot entries healthy" FAIL "invalid manifest or backend output"
    fi
    if jq -e '.installed == true' <<< "$usb_boot_status" >/dev/null 2>&1; then
        check BOOTUSB01 "Removable EFI boot generator installed" PASS "$(jq '.entries | length' <<< "$usb_boot_status") registered"
    else
        check BOOTUSB01 "Removable EFI boot generator installed" INFO "install with: sudo linux/pz boot usb install"
    fi
    case "$(jq -r '.state // "missing"' <<< "$grubfm_status")" in
        installed) check BOOTFM01 "Experimental grubfm payload audited" INFO "installed; upstream archived; secureBoot=$(jq -r '.secureBoot' <<< "$grubfm_status")" ;;
        *) check BOOTFM01 "Experimental grubfm payload audited" INFO "not installed (optional, upstream archived)" ;;
    esac
else
    check BOOTISO01 "Dynamic ISO boot backend available" WARN "missing linux/boot/iso-boot.sh"
fi

header "Security"
if systemctl is-active ufw &>/dev/null; then check SEC01 "UFW firewall active" PASS ""; else check SEC01 "UFW firewall active" WARN "inactive"; fi
if systemctl is-active sshd &>/dev/null; then check SEC02 "SSH server running" PASS ""; else check SEC02 "SSH server running" INFO "disabled (ok if not needed)"; fi

header "Containers"
if timeout 5 docker ps &>/dev/null; then check DOCKER01 "Docker daemon accessible" PASS ""; else check DOCKER01 "Docker daemon accessible" FAIL ""; fi
if docker_compose_ver=$(timeout 5 docker compose version 2>/dev/null | head -1); then check DOCKER02 "Docker Compose" PASS "${docker_compose_ver:-installed}"; else check DOCKER02 "Docker Compose" FAIL ""; fi

header "Development"
tool_path() {
    local tool="$1"
    command -v "$tool" 2>/dev/null || {
        [ -x "$HOME/.cargo/bin/$tool" ] && echo "$HOME/.cargo/bin/$tool" && return 0
        [ -x "$HOME/go/bin/$tool" ] && echo "$HOME/go/bin/$tool" && return 0
        return 1
    }
}
for tool in node npm python3 rustc cargo go jq git gh; do
    tool_bin="$(tool_path "$tool" || true)"
    if [ -n "$tool_bin" ]; then
        case "$tool" in
            go) ver=$("$tool_bin" version 2>/dev/null | head -1) ;;
            *) ver=$("$tool_bin" --version 2>/dev/null | head -1) ;;
        esac
        if [ -n "$ver" ]; then check "DEV_$tool" "$tool installed" PASS "$ver"; else check "DEV_$tool" "$tool installed" FAIL "$tool_bin"; fi
    else
        check "DEV_$tool" "$tool installed" FAIL ""
    fi
done
if command -v git-lfs >/dev/null 2>&1; then
    check DEV_git-lfs "git-lfs installed" PASS "$(git-lfs --version 2>/dev/null | head -1)"
else
    check DEV_git-lfs "git-lfs installed" WARN ""
fi

header "AI Tools"
ai_status="$(run bash "$PZ_ROOT/linux/ai/status.sh" 2>/dev/null || echo '{}')"
for tool in codex claude opencode hermes openclaw ollama; do
    if jq -e --arg tool "$tool" '.clis[$tool].available == true' <<< "$ai_status" >/dev/null 2>&1; then
        ai_path="$(jq -r --arg tool "$tool" '.clis[$tool].path' <<< "$ai_status")"
        check "AI_$tool" "$tool installed" PASS "$ai_path"
    else
        case "$tool" in
            codex) check "AI_$tool" "$tool installed" INFO "optional; install Codex CLI through its official flow" ;;
            *) check "AI_$tool" "$tool installed" WARN "run: linux/pz ai setup $tool" ;;
        esac
    fi
done
codexbar_health="$(run bash "$PZ_ROOT/linux/ai/setup-codexbar.sh" health 2>/dev/null || echo '{"verdict":"degraded","problems":["health_unavailable"]}')"
if jq -e '.clis.codexbar.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    if jq -e '[.problems[]? | select(. == "cli_binary_corrupted" or . == "cli_integrity_baseline_missing")] | length == 0' <<< "$codexbar_health" >/dev/null 2>&1; then
        check AI_CODEXBAR_CLI "CodexBar CLI integrity" PASS "$(jq -r '.clis.codexbar.path' <<< "$ai_status")"
    else
        check AI_CODEXBAR_CLI "CodexBar CLI integrity" FAIL "run: linux/pz ai codexbar repair"
    fi
else
    check AI_CODEXBAR_CLI "CodexBar CLI available" WARN "run: linux/pz ai setup codexbar"
fi
if jq -e '.codexbarPlasmoid.configExists == true' <<< "$ai_status" >/dev/null 2>&1 \
    && jq -e '[.problems[]? | select(startswith("config_"))] | length == 0' <<< "$codexbar_health" >/dev/null 2>&1; then
    check AI_CODEXBAR_CONFIG "CodexBar config valid" PASS "$(jq -r '.codexbar.config.path // "resolved by CodexBar"' <<< "$ai_status")"
else
    check AI_CODEXBAR_CONFIG "CodexBar config valid" WARN "$(jq -r '[.problems[]? | select(startswith("config_"))] | join(", ")' <<< "$codexbar_health"); run: linux/pz ai codexbar repair"
fi
if jq -e '.verdict == "healthy"' <<< "$codexbar_health" >/dev/null 2>&1; then
    check AI_CODEXBAR_USAGE "CodexBar providers return usage" PASS "enabled providers validated"
else
    check AI_CODEXBAR_USAGE "CodexBar providers return usage" WARN "$(jq -r '.problems | join(", ")' <<< "$codexbar_health")"
fi
if jq -e '.codexbarPlasmoid.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CODEXBAR_PLASMOID "KodexBar Plasma widget package" INFO "optional external QML; live updates blocked"
else
    check AI_CODEXBAR_PLASMOID "KodexBar Plasma widget package" INFO "not installed; native PhaseZero UI remains available"
fi
if jq -e '.desktopApps.claudeDesktop.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CLAUDE_DESKTOP "Claude Desktop installed" PASS "$(jq -r '.desktopApps.claudeDesktop.version' <<< "$ai_status")"
else
    check AI_CLAUDE_DESKTOP "Claude Desktop installed" WARN "run: linux/pz ai desktop install-claude"
fi
if jq -e '.desktopApps.codexDesktop.updateStatus != "failed"' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CODEX_DESKTOP_UPDATE "Codex Desktop updater healthy" PASS "$(jq -r '.desktopApps.codexDesktop.updateStatus' <<< "$ai_status")"
elif jq -e '.desktopApps.codexDesktop.installedVersion != "" and .desktopApps.codexDesktop.guardActive == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CODEX_DESKTOP_UPDATE "Codex Desktop updater healthy" WARN \
        "candidate incompatible; guard preserved $(jq -r '.desktopApps.codexDesktop.installedVersion' <<< "$ai_status")"
else
    check AI_CODEX_DESKTOP_UPDATE "Codex Desktop updater healthy" FAIL "run: linux/pz ai desktop repair-codex"
fi
if jq -e '.desktopApps.codexDesktop.guardEnabled == true and .desktopApps.updater.timerEnabled == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_DESKTOP_UPDATE_TIMER "AI desktop automatic updates enabled" PASS "user timer + Codex guard"
else
    check AI_DESKTOP_UPDATE_TIMER "AI desktop automatic updates enabled" WARN "run: linux/pz ai desktop install-services"
fi
router_doctor="$(run bash "$PZ_ROOT/linux/ai/9router-manager.sh" doctor 2>/dev/null || echo '{}')"
if jq -e '.secure == true and .healthy == true' <<< "$router_doctor" >/dev/null 2>&1; then
    check AI_9ROUTER "9Router local gateway" PASS "loopback; API key; private container bridge; passive watchdog"
else
    check AI_9ROUTER "9Router local gateway" WARN "run: linux/pz ai 9router install"
fi
odysseus_doctor="$(run bash "$PZ_ROOT/linux/ai/odysseus-manager.sh" doctor 2>/dev/null || echo '{}')"
if jq -e '.secure == true' <<< "$odysseus_doctor" >/dev/null 2>&1; then
    check AI_ODYSSEUS "Odysseus workspace" PASS "rootless; auth; pinned images"
elif jq -e '.currentRelease == true' <<< "$odysseus_doctor" >/dev/null 2>&1; then
    check AI_ODYSSEUS "Odysseus workspace" WARN "run: linux/pz ai odysseus doctor"
else
    check AI_ODYSSEUS "Odysseus workspace" INFO "optional: linux/pz ai odysseus install"
fi
if systemctl --user is-enabled phasezero-app-update-check.timer >/dev/null 2>&1; then
    check AI_UPDATE_INVENTORY "PhaseZero app update inventory" PASS "daily check-only timer"
else
    check AI_UPDATE_INVENTORY "PhaseZero app update inventory" WARN "run: linux/pz updates install-service"
fi

# OpenCode CLI must stay in version lockstep with opencode-desktop (they share
# one SQLite DB); a skew crashes the older one on the migrated schema.
oc_ver_status="$(run bash "$PZ_ROOT/linux/ai/setup-opencode.sh" version-status 2>/dev/null || echo '{}')"
if jq -e '.desktop != null' <<< "$oc_ver_status" >/dev/null 2>&1; then
    if jq -e '.inSync == true' <<< "$oc_ver_status" >/dev/null 2>&1; then
        check AI_OPENCODE_SYNC "OpenCode CLI/desktop in lockstep" PASS "$(jq -r '.cli' <<< "$oc_ver_status") == desktop"
    else
        check AI_OPENCODE_SYNC "OpenCode CLI/desktop in lockstep" WARN "CLI $(jq -r '.cli // "none"' <<< "$oc_ver_status") vs desktop $(jq -r '.desktop' <<< "$oc_ver_status"); run: linux/pz ai opencode sync"
    fi
fi
# A model must be usable or opencode/desktop reply "Interrupted" to every prompt.
if jq -e '.model != null' <<< "$oc_ver_status" >/dev/null 2>&1; then
    if jq -e '.model.usable == true' <<< "$oc_ver_status" >/dev/null 2>&1; then
        check AI_OPENCODE_MODEL "OpenCode has a usable model" PASS "$(jq -r 'if .model.hasCredentials then "cloud credentials" else "local Ollama provider" end' <<< "$oc_ver_status")"
    else
        check AI_OPENCODE_MODEL "OpenCode has a usable model" WARN "no provider — chats will be interrupted; run: opencode auth login, or linux/pz ai opencode local-model"
    fi
fi

# oh-my-openagent (OMO) is an opt-in OpenCode plugin; report state without
# requiring it (config-only status, no bunx spawn).
omo_status="$(run bash "$PZ_ROOT/linux/ai/setup-omo.sh" status 2>/dev/null || echo '{}')"
if jq -e '.plugin.registered == true' <<< "$omo_status" >/dev/null 2>&1; then
    if jq -e '.bun.present == true' <<< "$omo_status" >/dev/null 2>&1; then
        check AI_OMO "oh-my-openagent OpenCode plugin" PASS "registered; verify: linux/pz ai omo doctor"
    else
        check AI_OMO "oh-my-openagent OpenCode plugin" WARN "plugin registered but bun missing; run: linux/pz ai setup omo"
    fi
else
    check AI_OMO "oh-my-openagent OpenCode plugin" INFO "optional; enable with: linux/pz ai setup omo"
fi
if jq -e '.github.installed == true and .github.authenticated == true' <<< "$ai_status" >/dev/null 2>&1; then
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" PASS "gh auth status"
elif jq -e '.github.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" INFO "optional: gh auth login"
else
    check DEV_GITHUB_AUTH "GitHub CLI authenticated" WARN "run: sudo pacman -S github-cli"
fi
if jq -e '.agentConfigs.hermes.mcpServerCount > 0' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_HERMES_MCP "Hermes MCP configured" PASS "$(jq -r '.agentConfigs.hermes.path' <<< "$ai_status")"
else
    check AI_HERMES_MCP "Hermes MCP configured" WARN "run: linux/pz ai setup hermes"
fi
if jq -e '.clis.openclaw.available == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_OPENCLAW_USAGE "OpenClaw managed use" INFO "blocked: connection-grant-not-enforceable"
fi
if jq -e '.memory.installed == true' <<< "$ai_status" >/dev/null 2>&1; then
    if jq -e '.memory.serverReachable == true or .memory.configuredMarker == true or .memory.userServiceActive == true' <<< "$ai_status" >/dev/null 2>&1; then
        check AI_MEMORY "ai-memory configured" PASS "$(jq -r '.memory.serverUrl' <<< "$ai_status")"
    else
        check AI_MEMORY "ai-memory configured" WARN "run: linux/pz ai setup memory"
    fi
else
    check AI_MEMORY "ai-memory installed" WARN "run: linux/pz ai setup memory"
fi
if jq -e '.compatibility.rtkAvailable == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_RTK "RTK available" PASS "$(jq -r '.clis.rtk.path' <<< "$ai_status")"
else
    check AI_RTK "RTK available" WARN "run: linux/pz ai setup rtk"
fi
if jq -e '.agentCompat.tools.caveman.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CAVEMAN "Caveman/PhaseZero rules configured" PASS "$(jq -r '.agentCompat.rules.files | length' <<< "$ai_status") files"
else
    check AI_CAVEMAN "Caveman/PhaseZero rules configured" WARN "run: linux/pz ai setup caveman"
fi
if jq -e '.agentCompat.tools.headroom.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_HEADROOM "Headroom available" PASS "$(jq -r '.agentCompat.tools.headroom.path' <<< "$ai_status")"
else
    check AI_HEADROOM "Headroom available" WARN "run: linux/pz ai setup headroom"
fi
if jq -e '.agentCompat.tools.aiContextFrugality.configured == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_CONTEXT_FRUGALITY "AI context frugality pack configured" PASS ".codex/ai-context"
else
    check AI_CONTEXT_FRUGALITY "AI context frugality pack configured" WARN "run: linux/pz ai setup frugality"
fi
if jq -e '.adminBridge.ready == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_ADMIN_BRIDGE "Admin escalation bridge ready" PASS "$(jq -r '.adminBridge.backend' <<< "$ai_status")"
else
    check AI_ADMIN_BRIDGE "Admin escalation bridge ready" WARN "run: linux/pz ai setup admin"
fi
if jq -e '.agentCompat.tools.ponytail.status == "active"' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_PONYTAIL "Ponytail workspace rules" PASS "active"
else
    check AI_PONYTAIL "Ponytail workspace rules" INFO "inactive; only applied in Ponytail workspaces"
fi
if jq -e '.agentCompat.tools.graphify.placeholder == true' <<< "$ai_status" >/dev/null 2>&1; then
    check AI_GRAPHIFY "Graphify placeholder" INFO "not configured; safe placeholder"
fi
if jq -e '.mcp.definitions | length > 0' <<< "$ai_status" >/dev/null 2>&1; then
    mcp_defs="$(jq -r '.mcp.definitions | length' <<< "$ai_status")"
    mcp_targets="$(jq -r '[.mcp.targets[]?.count // 0] | add // 0' <<< "$ai_status")"
    if [ "$mcp_targets" -gt 0 ] 2>/dev/null; then
        check AI_MCP "MCP definitions synced" PASS "definitions=${mcp_defs} installed=${mcp_targets}"
    else
        check AI_MCP "MCP definitions synced" WARN "run: linux/pz ai mcp sync"
    fi
else
    check AI_MCP "MCP definitions available" WARN "assets/mcp/servers missing"
fi
if jq -e '.ides | [.[] | select(.available == true)] | length > 0' <<< "$ai_status" >/dev/null 2>&1; then
    ide_count="$(jq -r '.ides | [.[] | select(.available == true)] | length' <<< "$ai_status")"
    check AI_IDE "AI-capable IDE/editor available" PASS "${ide_count} detected"
else
    check AI_IDE "AI-capable IDE/editor available" WARN "install VS Code/Cursor/Windsurf/Zed/Neovim"
fi

# $XDG_RUNTIME_DIR is a small RAM-backed tmpfs. When something fills it the
# user systemd manager can no longer create transient units, so every app
# launched from the menu fails with "Unit app-...service not found".
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ -d "$runtime_dir" ]; then
    runtime_use="$(df --output=pcent "$runtime_dir" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
    # Skip mount points (e.g. the document portal FUSE): they use no tmpfs space.
    runtime_top="$( { for entry in "$runtime_dir"/* "$runtime_dir"/.[!.]*; do
            [ -e "$entry" ] && ! mountpoint -q "$entry" && du -xsh "$entry" 2>/dev/null
        done || true; } | sort -h | tail -1 | tr '\t' ' ' || true)"
    if [ "${runtime_use:-0}" -ge 95 ] 2>/dev/null; then
        check RUN01 "Runtime dir has free space" FAIL \
            "${runtime_dir} ${runtime_use}% cheio — apps não abrem pelo menu; maior: ${runtime_top:-?}"
    elif [ "${runtime_use:-0}" -ge 80 ] 2>/dev/null; then
        check RUN01 "Runtime dir has free space" WARN "${runtime_dir} ${runtime_use}% cheio; maior: ${runtime_top:-?}"
    else
        check RUN01 "Runtime dir has free space" PASS "${runtime_use:-?}% usado"
    fi
fi

# A game frontend swaps the Deck to a gamepad profile and suspends KDE
# shortcuts; if that outlives the game the desktop has no trackpad mouse,
# keyboard or button shortcuts.
input_state="$(run bash "$PZ_ROOT/linux/steamdeck/input-restore.sh" status 2>/dev/null || true)"
case "$(jq -r '.mode // empty' <<< "$input_state" 2>/dev/null)" in
    stuck) check INPUT01 "Desktop controls restored after games" FAIL \
        "controle preso no modo jogo — rode: linux/pz steamdeck input restore (ou toque em Restaurar controles)" ;;
    game) check INPUT01 "Desktop controls restored after games" INFO "jogo ativo; perfil de controle esperado" ;;
    desktop) check INPUT01 "Desktop controls restored after games" PASS "trackpad, teclado e atalhos no modo Desktop" ;;
esac

# One install per app: duplicates drift apart in version and leave the user
# guessing which copy runs. Unacknowledged ones are a conflict to resolve.
dup_status="$(run python3 "$PZ_ROOT/linux/audit/duplicates.py" scan --json 2>/dev/null || true)"
dup_blocking="$(jq -r '.blocking // [] | join(", ")' <<< "$dup_status" 2>/dev/null || true)"
dup_broken="$(jq -r '.brokenShims // [] | map(.path) | join(", ")' <<< "$dup_status" 2>/dev/null || true)"
if [ -n "$dup_blocking" ]; then
    check DUP01 "No duplicate app installs" WARN \
        "duplicado: ${dup_blocking} — veja: linux/pz host duplicates scan"
else
    check DUP01 "No duplicate app installs" PASS "nenhuma duplicidade não aceita"
fi
if [ -n "$dup_broken" ]; then
    check DUP02 "Launchers point to installed apps" WARN "lançador quebrado: ${dup_broken}"
fi
oc_health="$(run python3 "$PZ_ROOT/linux/ai/opencode_9router_manager.py" status 2>/dev/null || true)"
if jq -e '.configuration.present and (.configuration.health.loads | not)' <<< "$oc_health" >/dev/null 2>&1; then
    check OC01 "OpenCode config loads" FAIL "provider quebrado impede o OpenCode de abrir — rode: linux/pz ai opencode heal"
fi

# Optional dependencies degrade a service without breaking the product, so
# absence is reported rather than treated as a fault. The distinction that
# matters to the user is whether PhaseZero can install it here: on a
# distribution we have no package name for, offering a fix would be a lie.
deps_status="$(run bash "$PZ_ROOT/linux/pz" deps status --json 2>/dev/null || echo '{}')"
deps_missing="$(jq -r '.missingCount // 0' <<< "$deps_status" 2>/dev/null || echo 0)"
if [ "${deps_missing:-0}" = "0" ]; then
    check DEPS01 "Optional dependencies present" PASS "nada ausente"
else
    deps_names="$(jq -r '[.dependencies[] | select(.present == false) | .title] | join(", ")' <<< "$deps_status" 2>/dev/null)"
    deps_fixable="$(jq -r '.installable | join(" ")' <<< "$deps_status" 2>/dev/null)"
    if [ -n "$deps_fixable" ]; then
        check DEPS01 "Optional dependencies present" WARN \
            "ausente: ${deps_names} — instale com: linux/pz deps install ${deps_fixable} --confirm"
    else
        check DEPS01 "Optional dependencies present" INFO \
            "ausente: ${deps_names} — sem pacote conhecido nesta distribuição; instale manualmente"
    fi
fi

finish
