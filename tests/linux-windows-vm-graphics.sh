#!/usr/bin/env bash
# Smoke tests for PhaseZero Windows VM graphics diagnostics/profiles (v1).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Never let a physical Deck controller change the fake-input launch contract
# into USB passthrough. Reproduced on clean main on a Steam Deck host.
export PZ_WINDOWS_VM_USB_SYSFS_DIR="$TMP_ROOT/usb"
mkdir -p "$PZ_WINDOWS_VM_USB_SYSFS_DIR"

export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_RUNTIME_DIR="$TMP_ROOT/run"
# Keep domain discovery deterministic: never touch the host's real libvirt.
export PZ_WINDOWS_VM_LIBVIRT_URI="test:///default"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"

assert_grep_absent() {
    local label="$1"
    shift
    if grep -q "$@"; then
        echo "FAIL: $label" >&2
        exit 1
    fi
}

echo "=== static: parse + boot-safety invariants ==="
bash -n "$REPO_ROOT/linux/pz"
bash -n "$REPO_ROOT/linux/windows-vm/windows-vm.sh"
bash -n "$REPO_ROOT/linux/windows-vm/graphics.sh"
# v1 contract: graphics layer never touches boot chain or VFIO binding.
gfx="$REPO_ROOT/linux/windows-vm/graphics.sh"
assert_grep_absent "graphics.sh references grub-mkconfig" 'grub-mkconfig' "$gfx"
assert_grep_absent "graphics.sh references grub-reboot" 'grub-reboot' "$gfx"
assert_grep_absent "graphics.sh references update-grub" 'update-grub' "$gfx"
assert_grep_absent "graphics.sh references mkinitcpio" 'mkinitcpio' "$gfx"
assert_grep_absent "graphics.sh references modprobe" 'modprobe' "$gfx"
assert_grep_absent "graphics.sh references /etc/sddm" '/etc/sddm' "$gfx"
assert_grep_absent "graphics.sh references /sys/bus/pci/drivers" '/sys/bus/pci/drivers' "$gfx"
assert_grep_absent "graphics.sh references driver_override" 'driver_override' "$gfx"
assert_grep_absent "graphics.sh references virsh define" 'virsh define\|virsh -c .* define\|attach-device\|detach-device' "$gfx"
assert_grep_absent "graphics.sh references /proc/cmdline" '/proc/cmdline' "$gfx"
echo "  boot-safety greps ok"

echo "=== fixtures: fake sysfs, dri, kvm, qemu, virsh ==="
fake_bin="$TMP_ROOT/bin"
mkdir -p "$fake_bin"

make_sysfs() { # root vendor iommu_group_count
    local root="$1" vendor="$2" groups="$3" i
    mkdir -p "$root/class/drm/card0/device" "$root/class/drm/card0-eDP-1" "$root/kernel/iommu_groups"
    printf '%s\n' "$vendor" > "$root/class/drm/card0/device/vendor"
    printf '0x163f\n' > "$root/class/drm/card0/device/device"
    printf 'PCI_SLOT_NAME=0000:04:00.0\n' > "$root/class/drm/card0/device/uevent"
    for ((i = 0; i < groups; i++)); do
        mkdir -p "$root/kernel/iommu_groups/$i"
    done
}

make_pci_device() { # root address class iommu_group
    local root="$1" address="$2" class="$3" group="$4"
    mkdir -p "$root/bus/pci/devices/$address" "$root/kernel/iommu_groups/$group/devices"
    printf '%s\n' "$class" > "$root/bus/pci/devices/$address/class"
    ln -s "$root/kernel/iommu_groups/$group" "$root/bus/pci/devices/$address/iommu_group"
    ln -s "$root/bus/pci/devices/$address" "$root/kernel/iommu_groups/$group/devices/$address"
}

sys_deck="$TMP_ROOT/sys-deck"        # AMD VanGogh, IOMMU groups = 0
sys_desktop="$TMP_ROOT/sys-desktop"  # NVIDIA dGPU, isolated IOMMU groups
sys_intel="$TMP_ROOT/sys-intel"      # Intel iGPU, no IOMMU
make_sysfs "$sys_deck" 0x1002 0
make_sysfs "$sys_desktop" 0x10de 16
make_sysfs "$sys_intel" 0x8086 0
make_pci_device "$sys_desktop" 0000:04:00.0 0x030000 15
make_pci_device "$sys_desktop" 0000:04:00.1 0x040300 15

dri_present="$TMP_ROOT/dri-present"
dri_missing="$TMP_ROOT/dri-missing"
dri_mixed="$TMP_ROOT/dri-mixed"
mkdir -p "$dri_present" "$dri_missing" "$dri_mixed"
touch "$dri_present/renderD128"
touch "$dri_mixed/renderD128" "$dri_mixed/renderD129"
chmod 000 "$dri_mixed/renderD128"

kvm_present="$TMP_ROOT/kvm"
touch "$kvm_present"

fake_qemu="$fake_bin/fake-qemu"
cat > "$fake_qemu" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-device help")
        printf 'name "virtio-vga", bus PCI\n'
        printf 'name "virtio-vga-gl", bus PCI\n'
        printf 'name "virtio-gpu-gl-pci", bus PCI\n'
        ;;
    "-display help")
        printf 'Available display backend types:\nnone\ngtk\nspice-app\ndbus\n'
        ;;
    "-device virtio-vga-gl,help")
        printf 'virtio-vga-gl options:\n  venus=<bool>\n'
        ;;
esac
EOF
chmod +x "$fake_qemu"
ln -s "$fake_qemu" "$fake_bin/qemu-system-x86_64"
touch "$fake_bin/looking-glass-client"
chmod +x "$fake_bin/looking-glass-client"
export PATH="$fake_bin:$PATH"

virsh_bin="$TMP_ROOT/virsh-bin"
mkdir -p "$virsh_bin"
cat > "$virsh_bin/virsh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *" list --all --name")
        printf 'win11-test\n'
        ;;
    *" domstate win11-test")
        printf '%s\n' "${PZ_TEST_DOMSTATE:-shut off}"
        ;;
    *" dumpxml win11-test")
        cat <<'XML'
<domain type='kvm'>
  <name>win11-test</name>
  <devices>
    <interface type='network'>
      <model type='virtio'/>
    </interface>
    <graphics type='spice' autoport='yes'/>
    <video>
      <model type='qxl' ram='65536' vram='65536' heads='1'/>
    </video>
  </devices>
</domain>
XML
        ;;
esac
EOF
chmod +x "$virsh_bin/virsh"

gfx_env=(
    "PZ_GFX_DRI_DIR=$dri_present"
    "PZ_GFX_KVM_PATH=$kvm_present"
    "PZ_GFX_QEMU_BIN=$fake_qemu"
)
vfio_env=(
    "PZ_WINDOWS_VM_PCI_DEVICES=0000:04:00.0,0000:04:00.1"
    "PZ_GFX_LOOKING_GLASS_BIN=$fake_bin/looking-glass-client"
)

echo "=== status: AMD Deck sem IOMMU -> VFIO blocked, compat recomendado ==="
deck_json="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.host.gpus[0].vendor == "amd" and .host.iommuGroups == 0' <<< "$deck_json" >/dev/null
jq -e '.host.selectedRenderNode | endswith("renderD128")' <<< "$deck_json" >/dev/null
jq -e '.vfio.viability == "blocked"' <<< "$deck_json" >/dev/null
jq -e '.recommended.profile == "compat"' <<< "$deck_json" >/dev/null
jq -e '.profiles["virtio-gl"].eligible == true and .profiles["virtio-gl"].mode == "experimental"' <<< "$deck_json" >/dev/null
jq -e '.profiles["vfio-looking-glass"].eligible == false' <<< "$deck_json" >/dev/null
jq -e '.vfio.blockers | length > 0' <<< "$deck_json" >/dev/null
echo "  deck scenario ok"

echo "=== status: dGPU com grupos isolados -> VFIO eligible plan-only ==="
desktop_json="$(env "${gfx_env[@]}" "${vfio_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_desktop" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.host.gpus[0].vendor == "nvidia" and .host.iommuGroups == 16' <<< "$desktop_json" >/dev/null
jq -e '.vfio.viability == "eligible-plan-only"' <<< "$desktop_json" >/dev/null
jq -e '.profiles["vfio-looking-glass"].eligible == true and .profiles["vfio-looking-glass"].mode == "plan-only"' <<< "$desktop_json" >/dev/null
jq -e '.vfio.normalizedPciDevices == "0000:04:00.0 0000:04:00.1" and (.vfio.devices | length) == 2' <<< "$desktop_json" >/dev/null
jq -e '.recommended.profile == "compat"' <<< "$desktop_json" >/dev/null
echo "  desktop scenario ok"

echo "=== VFIO: grupo incompleto e endereco invalido permanecem bloqueados ==="
incomplete_json="$(env "${gfx_env[@]}" PZ_GFX_LOOKING_GLASS_BIN="$fake_bin/looking-glass-client" \
    PZ_WINDOWS_VM_PCI_DEVICES=04:00.0 PZ_GFX_SYSFS_ROOT="$sys_desktop" \
    "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.vfio.viability == "blocked"' <<< "$incomplete_json" >/dev/null
jq -e '(.vfio.blockers | join(" ")) | test("grupo IOMMU 15 incompleto") and test("sem funcao de audio")' <<< "$incomplete_json" >/dev/null
invalid_json="$(env "${gfx_env[@]}" PZ_GFX_LOOKING_GLASS_BIN="$fake_bin/looking-glass-client" \
    PZ_WINDOWS_VM_PCI_DEVICES=not-a-pci-id PZ_GFX_SYSFS_ROOT="$sys_desktop" \
    "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.vfio.viability == "blocked" and ((.vfio.blockers | join(" ")) | test("endereco PCI invalido"))' <<< "$invalid_json" >/dev/null
echo "  strict VFIO validation ok"

echo "=== status: Intel + render node -> virtio-gl eligible experimental ==="
intel_json="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_intel" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.host.gpus[0].vendor == "intel"' <<< "$intel_json" >/dev/null
jq -e '.profiles["virtio-gl"].eligible == true' <<< "$intel_json" >/dev/null
jq -e '.recommended.experimentalCandidate == "virtio-gl"' <<< "$intel_json" >/dev/null
jq -e '.vfio.viability == "blocked"' <<< "$intel_json" >/dev/null
echo "  intel scenario ok"

echo "=== status: sem /dev/kvm ou sem render node -> fallback compat ==="
nokvm_json="$(env PZ_GFX_SYSFS_ROOT="$sys_deck" PZ_GFX_DRI_DIR="$dri_present" PZ_GFX_KVM_PATH="$TMP_ROOT/missing-kvm" PZ_GFX_QEMU_BIN="$fake_qemu" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.host.kvm == false and .profiles["virtio-gl"].eligible == false' <<< "$nokvm_json" >/dev/null
jq -e '.recommended.profile == "compat" and .recommended.experimentalCandidate == ""' <<< "$nokvm_json" >/dev/null
nodri_json="$(env PZ_GFX_SYSFS_ROOT="$sys_deck" PZ_GFX_DRI_DIR="$dri_missing" PZ_GFX_KVM_PATH="$kvm_present" PZ_GFX_QEMU_BIN="$fake_qemu" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.profiles["virtio-gl"].eligible == false' <<< "$nodri_json" >/dev/null
jq -e '(.profiles["virtio-gl"].blockers | join(" ")) | test("render node")' <<< "$nodri_json" >/dev/null
echo "  fallback compat scenario ok"

echo "=== status: host multi-GPU escolhe render node acessivel ==="
mixed_json="$(env PZ_GFX_SYSFS_ROOT="$sys_intel" PZ_GFX_DRI_DIR="$dri_mixed" \
    PZ_GFX_KVM_PATH="$kvm_present" PZ_GFX_QEMU_BIN="$fake_qemu" \
    "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.host.selectedRenderNode | endswith("renderD129")' <<< "$mixed_json" >/dev/null
jq -e '.profiles["virtio-gl"].eligible == true' <<< "$mixed_json" >/dev/null
echo "  multi-GPU render selection ok"

echo "=== plan: auto resolve compat; perfis experimentais bloqueados ==="
auto_plan="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile auto --json)"
jq -e '.requestedProfile == "auto" and .profile == "compat" and .applyAllowed == true' <<< "$auto_plan" >/dev/null
jq -e '.bootSafety | test("GRUB")' <<< "$auto_plan" >/dev/null
gl_plan="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile virtio-gl --json)"
jq -e '.plannedQemuArgs | test("virtio-vga-gl") and test("gl=on")' <<< "$gl_plan" >/dev/null
jq -e '.eligible == true and .applyAllowed == true and .risk == "medium"' <<< "$gl_plan" >/dev/null
venus_plan="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile virtio-venus --json)"
# venus expõe plano honesto (mode=experimental) mas nunca libera apply/launch.
jq -e '.applyAllowed == false and .mode == "experimental"' <<< "$venus_plan" >/dev/null
rutabaga_plan="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile rutabaga --json)"
jq -e '.applyAllowed == false' <<< "$rutabaga_plan" >/dev/null
vfio_plan="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile vfio-looking-glass --json)"
jq -e '.applyAllowed == false and .mode == "plan-only"' <<< "$vfio_plan" >/dev/null
jq -e '(.blockers | join(" ")) | test("IOMMU")' <<< "$vfio_plan" >/dev/null
jq -e '.plannedDomainXml | test("hostdev")' <<< "$vfio_plan" >/dev/null
vfio_ready_plan="$(env "${gfx_env[@]}" "${vfio_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_desktop" \
    "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile vfio-looking-glass --json)"
jq -e '.eligible == true and .applyAllowed == false and (.blockers | length) == 0' <<< "$vfio_ready_plan" >/dev/null
jq -e '.plannedDomainXml | test("domain=.0x0000.") and test("function=.0x1.")' <<< "$vfio_ready_plan" >/dev/null
plan_text="$(env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile auto)"
grep -q 'resolved_profile: compat' <<< "$plan_text"
grep -q 'boot_safety:' <<< "$plan_text"
echo "  plan scenarios ok"

echo "=== libvirt: XML atual QXL/SPICE detectado; plan permanece read-only ==="
libvirt_json="$(env PATH="$virsh_bin:$PATH" "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics status --json)"
jq -e '.libvirt.domain == "win11-test" and .libvirt.videoModel == "qxl" and .libvirt.graphicsType == "spice"' <<< "$libvirt_json" >/dev/null
libvirt_plan="$(env PATH="$virsh_bin:$PATH" "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile vfio-looking-glass --json)"
jq -e '.libvirt.backupRequired == false and .libvirt.backupXml == ""' <<< "$libvirt_plan" >/dev/null
libvirt_gl_plan="$(env PATH="$virsh_bin:$PATH" "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics plan --profile virtio-gl --json)"
jq -e '.eligible == true and .applyAllowed == false and (.applyCommand == "")' <<< "$libvirt_gl_plan" >/dev/null
jq -e '(.blockers | join(" ")) | test("quebrar a sessao de boot")' <<< "$libvirt_gl_plan" >/dev/null
test ! -e "$XDG_STATE_HOME/phasezero/windows-vm/graphics/backups"
echo "  libvirt inspection read-only ok"

echo "=== runtime: status, dry-run, install, backup e rollback em root falso ==="
runtime_root="$TMP_ROOT/runtime-root"
runtime_env=("PZ_GFX_RUNTIME_TARGET_ROOT=$runtime_root")
runtime_before="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime status --json)"
jq -e '.status == "needsinstall" and .summary.missing == .summary.total' <<< "$runtime_before" >/dev/null
# A arvore runtime tem que carregar sozinha no boot GRUB: sem ledger.sh/desktop.sh
# o common.sh instalado aborta e a sessao vira tela preta.
jq -e '[.artifacts[].name] | index("ledger") != null and index("desktop") != null and index("rescue") != null' <<< "$runtime_before" >/dev/null
runtime_dry="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime install --dry-run --json)"
jq -e '.dryRun == true and (.wouldChange | length) == (.artifacts | length)' <<< "$runtime_dry" >/dev/null
test ! -e "$runtime_root/usr/local/lib/phasezero"
runtime_installed="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime install --json)"
jq -e '.status == "ok" and .summary.current == .summary.total and (.backupId | length) > 0' <<< "$runtime_installed" >/dev/null
runtime_launcher="$runtime_root/usr/local/lib/phasezero/windows-vm-runtime/linux/windows-vm/windows-vm.sh"
printf 'stale launcher\n' > "$runtime_launcher"
runtime_repaired="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime install --json)"
jq -e '.status == "ok" and .summary.current == .summary.total' <<< "$runtime_repaired" >/dev/null
runtime_rollback_dry="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime rollback --backup latest --dry-run --json)"
jq -e '.dryRun == true and .operation == "rollback"' <<< "$runtime_rollback_dry" >/dev/null
runtime_rolled_back="$(env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime rollback --backup latest --json)"
jq -e '.status == "needsrepair" and .operation == "rollback"' <<< "$runtime_rolled_back" >/dev/null
grep -q '^stale launcher$' "$runtime_launcher"
test ! -e "$runtime_root/etc/default/grub"
env "${runtime_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics runtime install --json >/dev/null
doctor_json="$(env "${runtime_env[@]}" "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics doctor --json)"
jq -e '.status == "ok" and .runtime.status == "ok" and .effectiveProfile == "compat"' <<< "$doctor_json" >/dev/null
echo "  runtime maintenance ok"

echo "=== apply: dominio rodando bloqueia; gates --experimental/--yes ==="
set +e
env PATH="$virsh_bin:$PATH" PZ_TEST_DOMSTATE=running "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" \
    "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental --yes >"$TMP_ROOT/apply-running.log" 2>&1
apply_running_rc=$?
set -e
test "$apply_running_rc" -ne 0
grep -q 'dominio libvirt em execucao' "$TMP_ROOT/apply-running.log"
set +e
env PATH="$virsh_bin:$PATH" "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" \
    "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental --yes >"$TMP_ROOT/apply-libvirt.log" 2>&1
apply_libvirt_rc=$?
set -e
test "$apply_libvirt_rc" -ne 0
grep -q 'apply persistente virtio-gl foi bloqueado' "$TMP_ROOT/apply-libvirt.log"
set +e
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl >"$TMP_ROOT/apply-noexp.log" 2>&1
apply_noexp_rc=$?
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental >"$TMP_ROOT/apply-noyes.log" 2>&1
apply_noyes_rc=$?
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile vfio-looking-glass --experimental --yes >"$TMP_ROOT/apply-vfio.log" 2>&1
apply_vfio_rc=$?
set -e
test "$apply_noexp_rc" -ne 0
test "$apply_noyes_rc" -ne 0
test "$apply_vfio_rc" -ne 0
grep -q 'plan-only' "$TMP_ROOT/apply-vfio.log"
echo "  apply gates ok"

echo "=== apply/remove: escreve somente PZ_WINDOWS_VM_GRAPHICS_PROFILE ==="
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile compat >/dev/null
grep -q '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=compat$' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental --yes >/dev/null
grep -q '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=virtio-gl$' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
test "$(grep -c '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf")" -eq 1
env "${gfx_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics remove >/dev/null
assert_grep_absent "graphics profile config left after remove" '^PZ_WINDOWS_VM_GRAPHICS_PROFILE=' "$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
echo "  config apply/remove ok"

echo "=== guest-guide: read-only por padrao; save explicito ==="
guide_output="$(env "${gfx_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics guest-guide)"
grep -q 'virtio-win' <<< "$guide_output"
grep -q 'Looking Glass' <<< "$guide_output"
grep -q 'RDP' <<< "$guide_output"
test ! -f "$XDG_STATE_HOME/phasezero/windows-vm/graphics/guest-guide.md"
env "${gfx_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics guest-guide --save >/dev/null
test -f "$XDG_STATE_HOME/phasezero/windows-vm/graphics/guest-guide.md"
echo "  guest guide ok"

echo "=== launch dry-run: compat preserva args; virtio-gl emite GL ==="
iso="$TMP_ROOT/Win11_test.iso"
printf 'fake iso for dry-run tests\n' > "$iso"
"$REPO_ROOT/linux/pz" windows-vm install --iso "$iso" --disk-size 64M --ram 2048 --cpus 2 >/dev/null
compat_launch="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics compat)"
grep -Fq -- '-qmp unix:' <<<"$compat_launch"
grep -q 'qemu-system-x86_64' <<< "$compat_launch"
grep -Eq -- '-device virtio-vga( |$)' <<< "$compat_launch"
grep -Fq 'gtk\,show-cursor=on\,zoom-to-fit=on\,window-close=off' <<< "$compat_launch"
assert_grep_absent "compat launch contains virtio-vga-gl" 'virtio-vga-gl' <<< "$compat_launch"
assert_grep_absent "compat launch contains gl=on" 'gl=on' <<< "$compat_launch"
default_launch="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu)"
assert_grep_absent "default launch contains gl=on" 'gl=on' <<< "$default_launch"
gl_launch="$(
    PZ_WINDOWS_VM_DISPLAY_WIDTH=2560 \
    PZ_WINDOWS_VM_DISPLAY_HEIGHT=1080 \
        "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-gl --experimental 2>/dev/null
)"
grep -Fq 'virtio-vga-gl\,xres=2560\,yres=1080' <<< "$gl_launch"
grep -Fq 'gtk\,gl=on\,show-cursor=on\,zoom-to-fit=on\,window-close=off' <<< "$gl_launch"
grep -Fq -- '-device qemu-xhci' <<< "$gl_launch"
grep -Fq -- '-device usb-kbd' <<< "$gl_launch"
grep -Fq -- '-device usb-tablet' <<< "$gl_launch"
grep -Fq -- '-device virtio-multitouch-pci' <<< "$gl_launch"
echo "  launch dry-run profiles ok"

echo "=== launch GRUB: controles diretos; touch rotacionado via GTK ==="
input_by_id="$TMP_ROOT/input/by-id"
mkdir -p "$input_by_id"
touch "$input_by_id/usb-Valve_Software_Steam_Deck_Controller_test-event-kbd"
touch "$input_by_id/usb-Valve_Software_Steam_Deck_Controller_test-event-mouse"
touch "$input_by_id/usb-Valve_Software_Steam_Deck_Controller_test-event-joystick"
deck_input_launch="$(PZ_WINDOWS_VM_BOOT_SESSION=1 \
    PZ_WINDOWS_VM_INPUT_BY_ID_DIR="$input_by_id" \
    "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-gl --experimental 2>/dev/null)"
grep -Fq 'pz-steamdeck-keyboard' <<< "$deck_input_launch"
grep -Fq 'pz-steamdeck-mouse' <<< "$deck_input_launch"
grep -Fq 'pz-steamdeck-gamepad' <<< "$deck_input_launch"
grep -Fq 'virtio-multitouch-pci' <<< "$deck_input_launch"
assert_grep_absent "raw portrait touchscreen bypasses output rotation" 'pz-steamdeck-touchscreen' <<< "$deck_input_launch"
desktop_input_launch="$(PZ_WINDOWS_VM_BOOT_SESSION=0 \
    PZ_WINDOWS_VM_INPUT_BY_ID_DIR="$input_by_id" \
    "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-gl --experimental 2>/dev/null)"
assert_grep_absent "desktop launch captures Steam Deck input" 'pz-steamdeck-' <<< "$desktop_input_launch"
empty_input_launch="$(PZ_WINDOWS_VM_BOOT_SESSION=1 \
    PZ_WINDOWS_VM_INPUT_BY_ID_DIR="$TMP_ROOT/empty-input/by-id" \
    PZ_WINDOWS_VM_INPUT_BY_PATH_DIR="$TMP_ROOT/empty-input/by-path" \
    "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-gl --experimental 2>/dev/null)"
assert_grep_absent "missing input devices abort GRUB launch" 'pz-steamdeck-' <<< "$empty_input_launch"
echo "  GRUB input mapping gated to boot session"

echo "=== launch: perfis bloqueados e gates ==="
set +e
"$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-gl >"$TMP_ROOT/launch-noexp.log" 2>&1
launch_noexp_rc=$?
"$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics virtio-venus --experimental >"$TMP_ROOT/launch-venus.log" 2>&1
launch_venus_rc=$?
"$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics rutabaga --experimental >"$TMP_ROOT/launch-rutabaga.log" 2>&1
launch_rutabaga_rc=$?
"$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu --graphics vfio-looking-glass --experimental >"$TMP_ROOT/launch-vfio.log" 2>&1
launch_vfio_rc=$?
PATH="$virsh_bin:$PATH" PZ_WINDOWS_VM_LIBVIRT_DOMAIN=win11-test \
    "$REPO_ROOT/linux/pz" windows-vm launch --dry-run --graphics virtio-gl --experimental >"$TMP_ROOT/launch-libvirt-gl.log" 2>&1
launch_libvirt_gl_rc=$?
set -e
test "$launch_noexp_rc" -ne 0
grep -q 'experimental' "$TMP_ROOT/launch-noexp.log"
test "$launch_venus_rc" -ne 0
grep -q 'bloqueado para Windows' "$TMP_ROOT/launch-venus.log"
test "$launch_rutabaga_rc" -ne 0
test "$launch_vfio_rc" -ne 0
grep -q 'plan-only' "$TMP_ROOT/launch-vfio.log"
test "$launch_libvirt_gl_rc" -ne 0
grep -q 'raw-qemu' "$TMP_ROOT/launch-libvirt-gl.log"
echo "  launch gates ok"

echo "=== config profile: apply virtio-gl vale para launch sem flags ==="
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental --yes >/dev/null
config_launch="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu 2>/dev/null)"
grep -q -- '-device virtio-vga-gl' <<< "$config_launch"
env "${gfx_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics remove >/dev/null
reset_launch="$("$REPO_ROOT/linux/pz" windows-vm launch --dry-run --raw-qemu)"
assert_grep_absent "config-driven launch still contains virtio-vga-gl" 'virtio-vga-gl' <<< "$reset_launch"
echo "  config-driven profile ok"

echo "=== config profile: dominio libvirt faz fallback compat sem quebrar boot ==="
env "${gfx_env[@]}" PZ_GFX_SYSFS_ROOT="$sys_deck" "$REPO_ROOT/linux/pz" windows-vm graphics apply --profile virtio-gl --experimental --yes >/dev/null
configured_libvirt_launch="$(PATH="$virsh_bin:$PATH" PZ_WINDOWS_VM_LIBVIRT_DOMAIN=win11-test \
    "$REPO_ROOT/linux/pz" windows-vm launch --dry-run 2>"$TMP_ROOT/config-libvirt.log")"
grep -q 'virsh.*start.*win11-test' <<< "$configured_libvirt_launch"
grep -q 'usara compat QXL/SPICE' "$TMP_ROOT/config-libvirt.log"
env "${gfx_env[@]}" "$REPO_ROOT/linux/pz" windows-vm graphics remove >/dev/null
echo "  configured libvirt fallback ok"

echo "=== status JSON expose graphicsProfile ==="
"$REPO_ROOT/linux/pz" windows-vm status | jq -e '.vm | has("graphicsProfile")' >/dev/null
echo "  status field ok"

echo "linux-windows-vm-graphics smoke ok"
