#!/usr/bin/env bash
# Hermetic coverage for interrupted WinVM installation recovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME/phasezero/operations" \
    "$TMP/bin" "$TMP/trash"
export PATH="$TMP/bin:$PATH"
export TEST_TRASH="$TMP/trash"
cat > "$TMP/bin/gio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = trash ] && [ "$2" = -- ]
mv -- "$3" "$TEST_TRASH/"
EOF
chmod +x "$TMP/bin/gio"

OP=op-interrupted-fixture
OP_DIR="$XDG_STATE_HOME/phasezero/operations/$OP"
VM_DIR="$XDG_STATE_HOME/phasezero/windows-vm/vms/$OP"
mkdir -p "$OP_DIR" "$VM_DIR"
printf '%s\n' "$VM_DIR" > "$OP_DIR/vm_dir"
printf '%s\n' '{"id":"op-interrupted-fixture","state":"running","checkpoint":"setup","progress":50,"log":[]}' \
    > "$OP_DIR/operation.json"
printf '%s\n' '{"imageIndex":1,"graphics":"compat"}' > "$OP_DIR/plan.json"
dd if=/dev/zero of="$VM_DIR/partial.qcow2" bs=4096 count=2 status=none

STATUS="$(bash "$ROOT/linux/windows-vm/provision.sh" status --operation-id "$OP" --json)"
jq -e '.state == "interrupted" and .workerAlive == false and .recoveryAction == "resume-or-remove"' \
    <<< "$STATUS" >/dev/null

INVENTORY="$(bash "$ROOT/linux/windows-vm/provision.sh" inventory --json)"
jq -e --arg op "$OP" --arg vm "$VM_DIR" \
    '.instances | any(.[]; .id == $op and .state == "interrupted" and .vmDir == $vm and .allocatedBytes > 0 and .removable == true)' \
    <<< "$INVENTORY" >/dev/null

PLAN="$(bash "$ROOT/linux/windows-vm/provision.sh" remove --operation-id "$OP" --dry-run --json)"
jq -e '.ready == true and .target.allocatedBytes > 0' <<< "$PLAN" >/dev/null

# A QEMU process whose command line names the staging disk must remain visible
# and unremovable even though its worker record is stale.
exec -a qemu-system-x86_64 python3 -c 'import time; time.sleep(30)' "$VM_DIR/partial.qcow2" &
QEMU_PID=$!
sleep 0.2
INVENTORY="$(bash "$ROOT/linux/windows-vm/provision.sh" inventory --json)"
jq -e --arg op "$OP" '.instances | any(.[]; .id == $op and .running == true and .removable == false)' \
    <<< "$INVENTORY" >/dev/null
if bash "$ROOT/linux/windows-vm/provision.sh" remove --operation-id "$OP" --dry-run --json >"$TMP/blocked.json"; then
    echo "remove preview unexpectedly accepted an open staging disk" >&2
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1
fi
jq -e '.ready == false and any(.blockers[]; contains("desligue esta VM"))' \
    "$TMP/blocked.json" >/dev/null
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true

echo "provision interrupted recovery smoke ok"
