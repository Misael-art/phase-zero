#!/usr/bin/env bash
# Hermetic contract for removing a PhaseZero-created VM through the trash.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
export PZ_WINDOWS_VM_CONFIG="$XDG_CONFIG_HOME/phasezero/windows-vm.conf"
export TEST_VM_TRASH="$TEST_ROOT/trash"
mkdir -p "$HOME/VirtualMachines/PhaseZero-Windows" "$XDG_CONFIG_HOME/phasezero" \
    "$TEST_ROOT/bin" "$TEST_VM_TRASH"
VM_DIR="$HOME/VirtualMachines/PhaseZero-Windows"
DISK="$VM_DIR/phasezero-windows.qcow2"
touch "$DISK"

cat > "$TEST_ROOT/bin/gio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "trash" ] && [ "$2" = "--" ]
mv -- "$3" "$TEST_VM_TRASH/"
EOF
chmod +x "$TEST_ROOT/bin/gio"
export PATH="$TEST_ROOT/bin:$PATH"

write_config() {
    local source="$1"
    cat > "$PZ_WINDOWS_VM_CONFIG" <<EOF
PZ_WINDOWS_VM_DIR='$VM_DIR'
PZ_WINDOWS_VM_DISK='$DISK'
PZ_WINDOWS_VM_DISK_SOURCE='$source'
PZ_WINDOWS_VM_LIBVIRT_DOMAIN=''
PZ_WINDOWS_VM_SHARE_POLICY='minimal'
EOF
}

write_config new
plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and (.blockers | length == 0)' <<< "$plan" >/dev/null

write_config managed
legacy_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and .vm.diskSource == "managed"' <<< "$legacy_plan" >/dev/null
write_config new

if "$REPO_ROOT"/linux/pz windows-vm remove --json >/dev/null 2>&1; then
    echo "remove without --yes unexpectedly succeeded" >&2
    exit 1
fi
[ -d "$VM_DIR" ]

mkdir -p "$XDG_STATE_HOME/phasezero/windows-vm/provision" \
    "$XDG_STATE_HOME/phasezero/operations/op-running"
printf '%s\n' 'op-running' > "$XDG_STATE_HOME/phasezero/windows-vm/provision/active.lock"
printf '{"id":"op-running","state":"running","workerSpawnedEpoch":%s}\n' "$(date +%s)" \
    > "$XDG_STATE_HOME/phasezero/operations/op-running/operation.json"
blocked_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json || true)"
jq -e '.ready == false and any(.blockers[]; contains("instalação Windows em andamento"))' \
    <<< "$blocked_plan" >/dev/null
[ -d "$VM_DIR" ]
printf '%s\n' '{"id":"op-running","state":"failed"}' \
    > "$XDG_STATE_HOME/phasezero/operations/op-running/operation.json"
terminal_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true' <<< "$terminal_plan" >/dev/null

# provision_lock_clear truncates in place and never unlinks, so an empty lock
# is the canonical idle state and must not block removal.
: > "$XDG_STATE_HOME/phasezero/windows-vm/provision/active.lock"
idle_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true' <<< "$idle_plan" >/dev/null

mkdir -p "$TEST_ROOT/not-managed"
touch "$TEST_ROOT/not-managed/phasezero-windows.qcow2"
VM_DIR="$TEST_ROOT/not-managed"
DISK="$VM_DIR/phasezero-windows.qcow2"
write_config new
if "$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json >/dev/null 2>&1; then
    echo "remove outside managed directory unexpectedly planned as safe" >&2
    exit 1
fi
[ -d "$VM_DIR" ]

VM_DIR="$HOME/VirtualMachines/PhaseZero-Windows"
DISK="$VM_DIR/phasezero-windows.qcow2"
write_config new

result="$("$REPO_ROOT"/linux/pz windows-vm remove --yes --json)"
jq -s -e 'length == 1' <<< "$result" >/dev/null
jq -e '.success == true' <<< "$result" >/dev/null
[ ! -e "$VM_DIR" ]
[ ! -e "$PZ_WINDOWS_VM_CONFIG" ]
[ -e "$TEST_VM_TRASH/PhaseZero-Windows/phasezero-windows.qcow2" ]

mkdir -p "$VM_DIR"
touch "$DISK"
# A disk PhaseZero built itself is labelled "provisioned" by `provision
# finalize`, and removes without any adoption warning.
write_config provisioned
provisioned_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and .vm.adopted == false and (.warnings | length == 0)' \
    <<< "$provisioned_plan" >/dev/null

# An adopted disk inside the managed directory stays removable — refusing it
# left the user with no way to delete the VM at all — but the plan has to flag
# the adoption so the caller can warn first.
write_config adopted-existing
adopted_plan="$("$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json)"
jq -e '.ready == true and .vm.adopted == true and
    any(.warnings[]; contains("adotada"))' <<< "$adopted_plan" >/dev/null
[ -d "$VM_DIR" ]

# An unrecognised provenance is a corrupt config, not a removal target.
write_config bogus-source
if "$REPO_ROOT"/linux/pz windows-vm remove --dry-run --json >/dev/null 2>&1; then
    echo "remove accepted an unknown disk source" >&2
    exit 1
fi
[ -d "$VM_DIR" ]
write_config new

# Completed provisioning VMs are separate managed instances. Inventory must
# expose their real allocated size and removal must target one operation id,
# never an arbitrary path supplied by the caller.
OPS="$XDG_STATE_HOME/phasezero/operations"
STAGING="$XDG_STATE_HOME/phasezero/windows-vm/vms"
mkdir -p "$OPS/op-legacy-1" "$OPS/op-legacy-2" \
    "$STAGING/op-legacy-1" "$STAGING/op-legacy-2"
printf '%s\n' '{"id":"op-legacy-1","state":"completed","createdAt":"2026-08-01T10:00:00Z"}' \
    > "$OPS/op-legacy-1/operation.json"
printf '%s\n' '{"imageIndex":1}' > "$OPS/op-legacy-1/plan.json"
printf '%s\n' "$STAGING/op-legacy-1" > "$OPS/op-legacy-1/vm_dir"
dd if=/dev/zero of="$STAGING/op-legacy-1/disk.qcow2" bs=1024 count=64 status=none
printf '%s\n' '{"id":"op-legacy-2","state":"completed","createdAt":"2026-08-02T10:00:00Z"}' \
    > "$OPS/op-legacy-2/operation.json"
printf '%s\n' '{"imageIndex":2}' > "$OPS/op-legacy-2/plan.json"
printf '%s\n' "$STAGING/op-legacy-2" > "$OPS/op-legacy-2/vm_dir"
dd if=/dev/zero of="$STAGING/op-legacy-2/disk.qcow2" bs=1024 count=96 status=none

inventory="$("$REPO_ROOT"/linux/pz windows-vm provision inventory --json)"
jq -e '.count == 2 and .totalAllocatedBytes > 0 and
    ([.instances[].id] | sort) == ["op-legacy-1","op-legacy-2"]' <<< "$inventory" >/dev/null
purge_plan="$("$REPO_ROOT"/linux/pz windows-vm provision remove \
    --operation-id op-legacy-1 --purge --dry-run --json)"
jq -e '.ready == true and .freesSpaceImmediately == true and
    .target.operationId == "op-legacy-1" and .target.allocatedBytes > 0' \
    <<< "$purge_plan" >/dev/null

if "$REPO_ROOT"/linux/pz windows-vm provision remove --operation-id op-legacy-1 \
    --purge --yes --json >/dev/null 2>&1; then
    echo "permanent removal without matching operation confirmation unexpectedly succeeded" >&2
    exit 1
fi
[ -d "$STAGING/op-legacy-1" ]

printf '%s\n' 'op-running' > "$XDG_STATE_HOME/phasezero/windows-vm/provision/active.lock"
printf '{"id":"op-running","state":"running","workerSpawnedEpoch":%s}\n' "$(date +%s)" \
    > "$XDG_STATE_HOME/phasezero/operations/op-running/operation.json"
if "$REPO_ROOT"/linux/pz windows-vm provision remove --operation-id op-legacy-1 \
    --purge --confirm-operation op-legacy-1 --yes --json >/dev/null 2>&1; then
    echo "legacy removal raced an active provision operation" >&2
    exit 1
fi
[ -d "$STAGING/op-legacy-1" ]
printf '%s\n' '{"id":"op-running","state":"failed"}' \
    > "$XDG_STATE_HOME/phasezero/operations/op-running/operation.json"

purged="$("$REPO_ROOT"/linux/pz windows-vm provision remove --operation-id op-legacy-1 \
    --purge --confirm-operation op-legacy-1 --yes --json)"
jq -e '.success == true and .removalMode == "purge" and
    .releasedBytes > 0 and .indexReleased == true' <<< "$purged" >/dev/null
[ ! -e "$STAGING/op-legacy-1" ]
jq -e '.vmRemovedAt and .vmRemovalMode == "purge" and .vmRemovedBytes > 0' \
    "$OPS/op-legacy-1/operation.json" >/dev/null

trashed="$("$REPO_ROOT"/linux/pz windows-vm provision remove --operation-id op-legacy-2 \
    --trash --yes --json)"
jq -e '.success == true and .removalMode == "trash" and .indexReleased == true' \
    <<< "$trashed" >/dev/null
[ ! -e "$STAGING/op-legacy-2" ]
[ -e "$TEST_VM_TRASH/op-legacy-2/disk.qcow2" ]

after_inventory="$("$REPO_ROOT"/linux/pz windows-vm provision inventory --json)"
jq -e '.count == 0 and .totalAllocatedBytes == 0' <<< "$after_inventory" >/dev/null

mkdir -p "$OPS/op-unsafe" "$TEST_ROOT/outside-vm"
printf '%s\n' '{"id":"op-unsafe","state":"completed"}' > "$OPS/op-unsafe/operation.json"
printf '%s\n' '{"imageIndex":3}' > "$OPS/op-unsafe/plan.json"
printf '%s\n' "$TEST_ROOT/outside-vm" > "$OPS/op-unsafe/vm_dir"
touch "$TEST_ROOT/outside-vm/disk.qcow2"
if "$REPO_ROOT"/linux/pz windows-vm provision remove --operation-id op-unsafe \
    --purge --dry-run --json >/dev/null 2>&1; then
    echo "legacy removal accepted a path outside managed staging" >&2
    exit 1
fi
[ -d "$TEST_ROOT/outside-vm" ]

echo "windows-vm remove smoke ok"
