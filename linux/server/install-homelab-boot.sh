#!/usr/bin/env bash
# install-homelab-boot.sh - GRUB entry that boots PhaseZero into a slim headless
# home-server session, mirroring the SteamOS/Windows VM/Waydroid direct entries.
#
# The entry adds `systemd.unit=multi-user.target phasezero.homelab=1` so the box
# comes up WITHOUT the desktop (less RAM) and a boot-prepare oneshot brings up
# the enabled components (LLM / homelab stack / Hermes). It is fully reversible:
# the normal GRUB entry is untouched, so a plain reboot returns to the desktop.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

ACTION="${1:-status}"; shift 2>/dev/null || true

# Component selection (persisted to server-mode.env; consumed at boot).
MODE_LLM="${PZ_SERVER_LLM:-0}"
MODE_HOMELAB="${PZ_SERVER_HOMELAB:-0}"
MODE_HERMES="${PZ_SERVER_HERMES:-0}"
MODE_EXTRAS="${PZ_SERVER_EXTRAS:-0}"
MODE_ACCESS="${PZ_HOMELAB_ACCESS_MODE:-local}"
for a in "$@"; do
    case "$a" in
        --llm) MODE_LLM=1 ;;
        --homelab) MODE_HOMELAB=1 ;;
        --hermes) MODE_HERMES=1 ;;
        --extras) MODE_EXTRAS=1 ;;
        --access)
            [ "${2:-}" ] || { pz_error "--access requires local|tailscale|lan"; exit 2; }
            MODE_ACCESS="$2"
            shift
            ;;
        --access=*) MODE_ACCESS="${a#--access=}" ;;
    esac
done
case "$MODE_ACCESS" in
    local|tailscale|lan) ;;
    *) pz_error "invalid access mode: $MODE_ACCESS"; exit 2 ;;
esac

TARGET_USER="$(pz_target_user)" || exit 2

# Installed runtime wins; the checkout is a development fallback only.
if [ -x /usr/lib/phasezero/linux/pz ]; then
    PREPARE_TARGET="/usr/lib/phasezero/linux/server/homelab-boot-prepare.sh"
else
    PREPARE_TARGET="/usr/local/lib/phasezero/homelab-boot-prepare"
fi
PREPARE_SOURCE="$PZ_ROOT/linux/server/homelab-boot-prepare.sh"
SERVICE_FILE="/etc/systemd/system/phasezero-homelab-boot-prepare.service"
MODE_ENV="/etc/phasezero/server-mode.env"
GRUB_SCRIPT="/etc/grub.d/46_phasezero_homelab"
GRUB_CFG="/boot/grub/grub.cfg"
BOOT_ENTRY="PhaseZero Homelab (headless)"
BOOT_ID="phasezero-homelab"
MODE_ENV_VERSION="1"

need_root() {
    [ "$EUID" -eq 0 ] && return 0
    if command -v pkexec >/dev/null 2>&1 && { [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; }; then
        exec pkexec bash "$0" "$ACTION" "$@"
    fi
    command -v sudo >/dev/null 2>&1 && exec sudo bash "$0" "$ACTION" "$@"
    pz_error "root required. run: sudo $0 $ACTION"; return 1
}

grub_script_content() {
    local uuid version kernel initrd kernel_rel initrd_rel amd_ucode_rel intel_ucode_rel subvol rootflags=""
    uuid="$(pz_boot_root_uuid)"; version="$(pz_boot_latest_kernel_version)"
    [ -n "$uuid" ] || { pz_error "could not resolve root UUID"; return 1; }
    [ -n "$version" ] || { pz_error "could not resolve /boot/vmlinuz-*"; return 1; }
    kernel="/boot/vmlinuz-$version"; initrd="/boot/initramfs-$version.img"
    [ -f "$kernel" ] || { pz_error "missing kernel: $kernel"; return 1; }
    [ -f "$initrd" ] || { pz_error "missing initrd: $initrd"; return 1; }
    kernel_rel="$(grub-mkrelpath "$kernel")"; initrd_rel="$(grub-mkrelpath "$initrd")"
    if [ -f /boot/amd-ucode.img ]; then
        amd_ucode_rel="$(grub-mkrelpath /boot/amd-ucode.img)"
    else
        amd_ucode_rel=""
    fi
    if [ -f /boot/intel-ucode.img ]; then
        intel_ucode_rel="$(grub-mkrelpath /boot/intel-ucode.img)"
    else
        intel_ucode_rel=""
    fi
    subvol="$(pz_boot_root_subvol || true)"
    [ -n "$subvol" ] && rootflags=" rootflags=subvol=$subvol"
    cat <<EOF
#!/usr/bin/env bash
exec tail -n +3 "\$0"
# PhaseZero managed GRUB entry. Re-run linux/pz server boot install after kernel changes.
menuentry '$BOOT_ENTRY' --id='$BOOT_ID' --hotkey=h --class server --class gnu-linux --class gnu --class os {
    insmod part_gpt
    insmod btrfs
    search --no-floppy --fs-uuid --set=root $uuid
    echo 'Booting PhaseZero Homelab (headless)...'
    linux $kernel_rel root=UUID=$uuid rw$rootflags quiet systemd.unit=multi-user.target phasezero.homelab=1
    initrd $amd_ucode_rel $intel_ucode_rel $initrd_rel
}
EOF
}

service_content() {
    cat <<EOF
[Unit]
Description=PhaseZero homelab boot session bring-up
ConditionKernelCommandLine=phasezero.homelab
Wants=network-online.target
After=network-online.target docker.service ollama.service tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-$MODE_ENV
ExecStart=$PREPARE_TARGET
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_mode_env() {
    # Versioned + idempotent: backs up any previous file before rewriting.
    if [ -f "$MODE_ENV" ] && ! grep -q '^PZ_SERVER_MODE_VERSION=' "$MODE_ENV"; then
        cp -a "$MODE_ENV" "$MODE_ENV.bak.pre-${MODE_ENV_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
    fi
    install -d "$(dirname "$MODE_ENV")"
    cat > "$MODE_ENV" <<EOF
# PhaseZero server mode (consumed at boot by phasezero-homelab-boot-prepare).
# Versioned: bump PZ_SERVER_MODE_VERSION on incompatible changes and migrate.
PZ_SERVER_MODE_VERSION=$MODE_ENV_VERSION
PZ_ROOT=$PZ_ROOT
PZ_SERVER_USER=$TARGET_USER
PZ_SERVER_LLM=$MODE_LLM
PZ_SERVER_HOMELAB=$MODE_HOMELAB
PZ_SERVER_HERMES=$MODE_HERMES
PZ_SERVER_EXTRAS=$MODE_EXTRAS
PZ_HOMELAB_ACCESS_MODE=$MODE_ACCESS
EOF
    chmod 0644 "$MODE_ENV"
}

install_boot() {
    need_root "$@"
    pz_boot_require_current_root_target
    pz_boot_preflight_grub
    pz_boot_validate_active_efi_safe
    pz_boot_backup_bundle "homelab-boot-install"
    if [[ "$PREPARE_TARGET" == /usr/local/lib/* ]]; then
        install -d /usr/local/lib/phasezero
        install -m 0755 "$PREPARE_SOURCE" "$PREPARE_TARGET"
    fi
    write_mode_env
    service_content > "$SERVICE_FILE"; chmod 0644 "$SERVICE_FILE"
    grub_script_content > "$GRUB_SCRIPT"; chmod 0755 "$GRUB_SCRIPT"
    systemctl daemon-reload
    systemctl enable phasezero-homelab-boot-prepare.service >/dev/null 2>&1 || true
    pz_boot_refresh_grub_config "$GRUB_CFG"
    pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
    pz_boot_validate_active_efi_safe
    pz_info "PhaseZero Homelab GRUB entry installed (llm=$MODE_LLM homelab=$MODE_HOMELAB hermes=$MODE_HERMES extras=$MODE_EXTRAS access=$MODE_ACCESS)"
    pz_info "prepare helper: $PREPARE_TARGET"
    pz_info "one-shot boot: sudo $0 next-reboot"
    pz_info "one-shot boot: sudo $0 next-reboot"
}

remove_boot() {
    need_root "$@"
    pz_boot_preflight_grub
    pz_boot_backup_bundle "homelab-boot-remove"
    systemctl disable phasezero-homelab-boot-prepare.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$GRUB_SCRIPT" "$PREPARE_TARGET"
    systemctl daemon-reload
    pz_boot_refresh_grub_config "$GRUB_CFG"
    pz_boot_validate_grub_cfg_safe "$GRUB_CFG"
    pz_info "PhaseZero Homelab GRUB entry removed (server-mode.env kept for reuse)"
}

grub_entry_state() {
    if [ -r "$GRUB_CFG" ]; then
        grep -Fq "menuentry '$BOOT_ENTRY'" "$GRUB_CFG" && echo present || echo missing
    else
        echo unknown-permission
    fi
}

set_next_boot() {
    need_root "$@"
    command -v grub-reboot >/dev/null 2>&1 || { pz_error "grub-reboot missing"; return 1; }
    [ "$(grub_entry_state)" = "present" ] || { pz_error "homelab GRUB entry not present; run: sudo $0 install"; return 1; }
    grub-reboot "$BOOT_ID"
    pz_info "next boot set to: $BOOT_ENTRY ($BOOT_ID). Run: systemctl reboot"
}

next_reboot() { set_next_boot "$@"; systemctl reboot; }

status_boot() {
    local marker=no
    grep -qw 'phasezero.homelab=1' /proc/cmdline 2>/dev/null && marker=yes
    if printf '%s' "$*" | grep -q -- --json; then
        jq -n \
            --argjson grubScript "$([ -x "$GRUB_SCRIPT" ] && echo true || echo false)" \
            --arg grubCfgEntry "$(grub_entry_state)" \
            --argjson prepareHelper "$([ -x "$PREPARE_TARGET" ] && echo true || echo false)" \
            --argjson serviceInstalled "$([ -f "$SERVICE_FILE" ] && echo true || echo false)" \
            --argjson modeEnv "$([ -f "$MODE_ENV" ] && echo true || echo false)" \
            --arg currentBoot "$marker" \
            --arg bootId "$BOOT_ID" \
            --arg targetUser "$TARGET_USER" \
            --arg prepareTarget "$PREPARE_TARGET" \
            --arg llm "$MODE_LLM" --arg homelab "$MODE_HOMELAB" \
            --arg hermes "$MODE_HERMES" --arg extras "$MODE_EXTRAS" \
            --arg access "$MODE_ACCESS" \
            '{tool:"homelab-boot",
              status:(if $serviceInstalled and $prepareHelper then "installed" else "not-installed" end),
              statusOk:(if $serviceInstalled and $prepareHelper then true else false end),
              modeEnvVersion:"'$MODE_ENV_VERSION'",
              grub:{scriptExist:$grubScript, cfgEntry:$grubCfgEntry, bootId:$bootId},
              runtime:{prepareHelper:{exist:$prepareHelper, path:$prepareTarget},
                       serviceInstalled:$serviceInstalled, modeEnvPresent:$modeEnv},
              targetUser:$targetUser,
              currentBootHomelab:($currentBoot == "yes"),
              components:{llm:$llm, homelab:$homelab, hermes:$hermes, extras:$extras, access:$access}}'
        return 0
    fi
    echo "grub_script: $([ -x "$GRUB_SCRIPT" ] && echo yes || echo no)"
    echo "grub_cfg_entry: $(grub_entry_state)"
    echo "prepare_helper: $([ -x "$PREPARE_TARGET" ] && echo yes || echo no)"
    echo "service_installed: $([ -f "$SERVICE_FILE" ] && echo yes || echo no)"
    echo "mode_env: $([ -f "$MODE_ENV" ] && echo yes || echo no)"
    [ -f "$MODE_ENV" ] && sed 's/^/  /' "$MODE_ENV"
    echo "current_boot_homelab: $marker"
    echo "grub_entry_id: $BOOT_ID (hotkey h)"
    echo "target_user: $TARGET_USER"
    echo "prepare_target: $PREPARE_TARGET"
}

dry_run_boot() {
    echo "PhaseZero Homelab boot dry-run"
    echo "  grub: $GRUB_SCRIPT (id $BOOT_ID)"
    echo "  service: $SERVICE_FILE"
    echo "  prepare: $PREPARE_TARGET"
    echo "  mode_env: $MODE_ENV (version $MODE_ENV_VERSION)"
    echo "  components: llm=$MODE_LLM homelab=$MODE_HOMELAB hermes=$MODE_HERMES extras=$MODE_EXTRAS access=$MODE_ACCESS"
    echo "  root_uuid: $(pz_boot_root_uuid || true)"
    echo "  kernel: $(pz_boot_latest_kernel_version || true)"
    echo "  kernel args: systemd.unit=multi-user.target phasezero.homelab=1 (headless, reversible)"
}

case "$ACTION" in
    install) install_boot "$@" ;;
    remove) remove_boot "$@" ;;
    status) status_boot "$@" ;;
    next|set-next) set_next_boot "$@" ;;
    next-reboot|reboot) next_reboot "$@" ;;
    dry-run|plan) dry_run_boot ;;
    *) pz_error "usage: install-homelab-boot.sh (install|remove|status|next|next-reboot|dry-run) [--llm --homelab --hermes --extras]"; exit 1 ;;
esac
