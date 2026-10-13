#!/usr/bin/env bash
# Testes para provisionamento Windows VM
# shellcheck disable=SC2016 # Assertions intentionally match literal shell/PowerShell source.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

PASS=0 FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected=$expected actual=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    # Avoid producer SIGPIPE under pipefail when grep -q finds an early match
    # in large JSON/log payloads.
    if grep -F -q -- "$needle" <<< "$haystack"; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label (expected to contain: $needle)"
        FAIL=$((FAIL + 1))
    fi
}

PROVISION_SCRIPT="$PZ_ROOT/linux/windows-vm/provision.sh"
MEDIA_SCRIPT="$PZ_ROOT/linux/windows-vm/media-inspect.sh"
AUTOUNATTEND_SCRIPT="$PZ_ROOT/linux/windows-vm/autounattend.sh"
TWEAKS_SCRIPT="$PZ_ROOT/linux/windows-vm/tweaks.sh"

echo "=== common: command-substitution temp cleanup ==="
TEMP_HELPER_ROOT="$(mktemp -d)"
TEMP_HELPER_PATH="$(cd "$TEMP_HELPER_ROOT" && bash -c 'source "'"$PZ_ROOT"'/linux/lib/common.sh"; pz_tempfile "pz-relative.XXXXXX"')"
assert_eq "relative temp allocated outside current directory" "0" "$([ -e "$TEMP_HELPER_ROOT/$(basename "$TEMP_HELPER_PATH")" ] && echo 1 || echo 0)"
assert_eq "command-substitution temp removed at parent exit" "0" "$([ -e "$TEMP_HELPER_PATH" ] && echo 1 || echo 0)"
rm -rf "$TEMP_HELPER_ROOT"
SNAPSHOT_SCRIPT="$PZ_ROOT/linux/windows-vm/snapshot.sh"

# Hermetic preflight fixture: plan must not depend on host state (CI lacks
# swtpm/daemons). PZ_PREFLIGHT_JSON is consumed by provision.sh plan but only
# with the PZ_TEST_MODE=1 sentinel — production always runs the real preflight.
PREFLIGHT_PASS_FIXTURE='{"status":"pass","swtpm":{"binary":true,"running":true},"virtio":{"outdated":false}}'

echo "=== provision: plan generation ==="

# Create dummy ISO
DUMMY_ISO="$(mktemp -d)/dummy.iso"
dd if=/dev/urandom bs=1M count=10 of="$DUMMY_ISO" 2>/dev/null

PZ_STATE_DIR="$(mktemp -d)"
PLAN_OUT=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo "")
assert_contains "plan has id" "$PLAN_OUT" '"id"'
assert_contains "plan has confirmToken" "$PLAN_OUT" '"confirmToken"'
assert_contains "plan has iso" "$PLAN_OUT" '"iso"'
assert_contains "plan has resources" "$PLAN_OUT" '"resources"'
assert_contains "plan has profile" "$PLAN_OUT" '"performance-safe"'
assert_contains "plan has imageIndex" "$PLAN_OUT" '"imageIndex"'
assert_eq "default guest login policy is auto" "auto" "$(echo "$PLAN_OUT" | jq -r '.guestLogin')"

PLAN_ID=$(echo "$PLAN_OUT" | jq -r '.id // ""' 2>/dev/null || echo "")
assert_eq "plan id not empty" "1" "$([ -n "$PLAN_ID" ] && echo 1 || echo 0)"

CONFIRM_TOKEN=$(echo "$PLAN_OUT" | jq -r '.confirmToken // ""' 2>/dev/null || echo "")
assert_eq "confirm token not empty" "1" "$([ -n "$CONFIRM_TOKEN" ] && echo 1 || echo 0)"

IMAGE_INDEX=$(echo "$PLAN_OUT" | jq -r '.imageIndex // 0' 2>/dev/null || echo "0")
assert_eq "default imageIndex is 1" "1" "$IMAGE_INDEX"

echo ""
echo "=== provision: plan with --image-index ==="
PLAN_OUT2=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --image-index 3 --json 2>/dev/null || echo "")
IMAGE_INDEX2=$(echo "$PLAN_OUT2" | jq -r '.imageIndex // 0' 2>/dev/null || echo "0")
assert_eq "custom imageIndex is 3" "3" "$IMAGE_INDEX2"

index_zero_rejected=0
PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --image-index 0 --json >/dev/null 2>&1 || index_zero_rejected=1
assert_eq "imageIndex 0 is rejected" "1" "$index_zero_rejected"
index_eleven_rejected=0
PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --image-index 11 --json >/dev/null 2>&1 || index_eleven_rejected=1
assert_eq "imageIndex 11 is rejected" "1" "$index_eleven_rejected"

PLAN_PASSWORD=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --guest-login password --json 2>/dev/null || echo "")
assert_eq "explicit guest password policy is serialized" "password" "$(echo "$PLAN_PASSWORD" | jq -r '.guestLogin')"

PLAN_BYPASS=$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --tpm-bypass --json 2>/dev/null || echo "")
assert_eq "tpm bypass serializes as JSON boolean" "boolean:true" "$(echo "$PLAN_BYPASS" | jq -r '(.tpmBypass | type) + ":" + (.tpmBypass | tostring)' 2>/dev/null || echo "")"

echo ""
echo "=== provision: plan validation ==="
BLOCKERS=$(echo "$PLAN_OUT" | jq '.blockers | length' 2>/dev/null || echo "1")
assert_eq "no blockers" "0" "$BLOCKERS"

echo ""
echo "=== provision: preflight override sentinel ==="
# Without PZ_TEST_MODE=1 the override must NOT be honored: an invalid fixture
# must never reach the plan as preflight data.
set +e
PLAN_NO_SENTINEL="$(PZ_PREFLIGHT_JSON='not-json' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
NO_SENTINEL_RC=$?
set -e
assert_eq "override without sentinel does not abort plan" "0" "$NO_SENTINEL_RC"
if [ -n "$PLAN_NO_SENTINEL" ]; then
    assert_contains "no sentinel: override ignored, plan still valid" "$PLAN_NO_SENTINEL" '"id"'
fi
# With the sentinel, an invalid fixture is rejected loudly (rc != 0).
set +e
PLAN_BAD_FIXTURE="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON='not-json' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
BAD_FIXTURE_RC=$?
set -e
assert_eq "bad fixture with sentinel rejected" "1" "$BAD_FIXTURE_RC"
# A fixture missing required fields is rejected too.
set +e
PLAN_BAD_SCHEMA="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON='{"status":"pass"}' PZ_STATE="$PZ_STATE_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null)"
BAD_SCHEMA_RC=$?
set -e
assert_eq "schema-missing fixture with sentinel rejected" "1" "$BAD_SCHEMA_RC"

echo ""
echo "=== autounattend: XML generation ==="
OUT_DIR="$(mktemp -d)"
AUTO_OUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-TEST-1234" --product-key "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE" --output-dir "$OUT_DIR" 2>/dev/null || echo "")
assert_contains "autounattend generated" "$AUTO_OUT" "autounattend.xml"
assert_eq "autounattend.xml exists" "1" "$([ -f "$OUT_DIR/autounattend.xml" ] && echo 1 || echo 0)"

# Validate XML structure
if command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout "$OUT_DIR/autounattend.xml" 2>/dev/null; then
        assert_eq "autounattend.xml valid XML" "1" "1"
    else
        assert_eq "autounattend.xml valid XML" "1" "0"
    fi
fi

assert_contains "autounattend has disk config" "$(cat "$OUT_DIR/autounattend.xml")" "DiskConfiguration"
assert_contains "autounattend has OOBE" "$(cat "$OUT_DIR/autounattend.xml")" "OOBE"
assert_contains "autounattend has phasezero user" "$(cat "$OUT_DIR/autounattend.xml")" "phasezero"
assert_contains "autounattend has partition" "$(cat "$OUT_DIR/autounattend.xml")" "CreatePartition"
assert_eq "autounattend avoids invalid Recovery CreatePartition type" "0" "$(grep -Fc '<Type>Recovery</Type>' "$OUT_DIR/autounattend.xml" 2>/dev/null || true)"
assert_contains "autounattend installs to primary partition 3" "$(cat "$OUT_DIR/autounattend.xml")" "<PartitionID>3</PartitionID>"
assert_contains "autounattend uses case-sensitive Restart value" "$(cat "$OUT_DIR/autounattend.xml")" "<Restart>Restart</Restart>"
assert_contains "autounattend nests product key under Key" "$(cat "$OUT_DIR/autounattend.xml")" "<Key>AAAAA-BBBBB-CCCCC-DDDDD-EEEEE</Key>"
assert_contains "autounattend suppresses product key UI" "$(cat "$OUT_DIR/autounattend.xml")" "<WillShowUI>Never</WillShowUI>"
assert_eq "autounattend discovers OEMDRV without hanging Get-Volume" "1" "$(grep -Fq 'foreach ($code in 68..90)' "$OUT_DIR/autounattend.xml" && ! grep -Fq 'Get-Volume' "$OUT_DIR/autounattend.xml" && echo 1 || echo 0)"

rm -rf "$OUT_DIR"

echo ""
echo "=== media-inspect: ISO inspection ==="
MEDIA_OUT=$(bash "$MEDIA_SCRIPT" inspect --iso "$DUMMY_ISO" --json 2>/dev/null || echo "")
assert_contains "media inspect has sha256" "$MEDIA_OUT" '"sha256"'
assert_contains "media inspect has arch" "$MEDIA_OUT" '"arch"'
assert_contains "media inspect has uefi" "$MEDIA_OUT" '"uefiBoot"'
assert_contains "media inspect has size" "$MEDIA_OUT" '"sizeMb"'
assert_contains "media inspect has valid" "$MEDIA_OUT" '"valid"'
MEDIA_VALID=$(echo "$MEDIA_OUT" | jq -r '.valid' 2>/dev/null || echo "null")
assert_eq "dummy ISO not valid (no Windows structure)" "false" "$MEDIA_VALID"

echo ""
echo "=== tweaks: performance-safe profile ==="
TWEAKS_RAW=$(bash "$TWEAKS_SCRIPT" apply 2>/dev/null || echo "")
TWEAKS_OUT=$(echo "$TWEAKS_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo "{}")
assert_contains "tweaks has profile" "$TWEAKS_OUT" '"performance-safe"'
assert_contains "tweaks has changes" "$TWEAKS_OUT" '"powerScheme"'
assert_contains "tweaks has appxRemoval" "$TWEAKS_OUT" '"appxRemoval"'
assert_contains "tweaks preserves Defender" "$TWEAKS_OUT" '"Defender"'
TWEAKS_COUNT=$(echo "$TWEAKS_OUT" | jq -c '.changes | length' 2>/dev/null || echo 0)
assert_eq "tweaks count > 0" "1" "$([ "$TWEAKS_COUNT" -gt 0 ] && echo 1 || echo 0)"

echo ""
echo "=== snapshot: create and verify ==="
SNAP_DIR="$(mktemp -d)"
SNAP_DISK="$SNAP_DIR/test-disk.qcow2"
if command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -f qcow2 "$SNAP_DISK" 64M 2>/dev/null || dd if=/dev/zero bs=1M count=64 of="$SNAP_DISK" 2>/dev/null
    SNAP_RAW=$(SNAPSHOT_DIR="$SNAP_DIR" bash "$SNAPSHOT_SCRIPT" create --name "test-snap" --disk "$SNAP_DISK" --json 2>/dev/null || echo '{"created": false}')
    SNAP_RESULT=$(echo "$SNAP_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo '{"created": false}')
    assert_contains "snapshot created" "$SNAP_RESULT" '"created"'
    SNAP_PATH=$(echo "$SNAP_RESULT" | jq -r '.path // ""' 2>/dev/null || echo "")
    if [ -n "$SNAP_PATH" ] && [ -f "$SNAP_PATH" ]; then
        assert_eq "snapshot file exists" "1" "1"
        VERIFY_RAW=$(SNAPSHOT_DIR="$SNAP_DIR" bash "$SNAPSHOT_SCRIPT" verify --path "$SNAP_PATH" --json 2>/dev/null || echo '{"valid": false}')
        VERIFY_RESULT=$(echo "$VERIFY_RAW" | awk '/^{/{p=1} p{print} /^}/{p=0}' | tr -d '\n' || echo '{"valid": false}')
        SNAP_VALID=$(echo "$VERIFY_RESULT" | jq -r '.valid // false' 2>/dev/null || echo "false")
        assert_eq "snapshot verified" "true" "$SNAP_VALID"
        # Verify backing chain
        BACKING_FILE=$(qemu-img info "$SNAP_PATH" 2>/dev/null | grep 'backing file:' | sed 's/.*backing file: //' || echo "")
        assert_eq "snapshot has backing file" "1" "$([ -n "$BACKING_FILE" ] && echo 1 || echo 0)"
        assert_eq "backing file is test disk" "$SNAP_DISK" "$BACKING_FILE"
    else
        assert_eq "snapshot file exists" "1" "0"
    fi
else
    echo "  (snapshot tests skipped: qemu-img not installed)"
fi

rm -rf "$SNAP_DIR"

echo ""
echo "=== secret redaction ==="
# Verify bootstrap secret is stored with 0600 permissions and never in stdout
OUT_DIR2="$(mktemp -d)"
bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$OUT_DIR2" > /dev/null 2>&1
SECRET_OUT_DIR="$(mktemp -d)"
PWD_IN_OUTPUT=$(bash "$AUTOUNATTEND_SCRIPT" generate --wim-index 1 --disk-serial "PZ-SECRET-TEST" \
    --password "SuperSecretP@ss123!" --output-dir "$SECRET_OUT_DIR" 2>&1 || true)
assert_eq "password not in stdout" "0" "$(echo "$PWD_IN_OUTPUT" | grep -c 'SuperSecretP@ss123!' || true)"
rm -rf "$OUT_DIR2" "$SECRET_OUT_DIR"

echo ""
echo "=== provision: cancel set -u safety ==="
# Verify provision_cancel uses $operation_id not $op (no crash under set -u)
CANCEL_TEST_DIR="$(mktemp -d)"
mkdir -p "$CANCEL_TEST_DIR/phasezero/operations/test-cancel"
mkdir -p "$CANCEL_TEST_DIR/phasezero/windows-vm/vms/test-cancel"
echo '{"id":"test-cancel","state":"running","checkpoint":"assets","progress":10}' > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json"
echo "$CANCEL_TEST_DIR/phasezero/windows-vm/vms/test-cancel" > "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/vm_dir"
set +e
CANCEL_JSON=$(XDG_STATE_HOME="$CANCEL_TEST_DIR" bash "$PROVISION_SCRIPT" cancel --operation-id test-cancel --json 2>/dev/null)
CANCEL_RC=$?
set -e
CANCEL_STATE=$(jq -r '.state // ""' "$CANCEL_TEST_DIR/phasezero/operations/test-cancel/operation.json" 2>/dev/null || echo "")
assert_eq "cancel changes state to cancelled" "cancelled" "$CANCEL_STATE"
assert_eq "cancel --json rc 0" "0" "$CANCEL_RC"
assert_eq "cancel --json success" "true" "$(echo "$CANCEL_JSON" | jq -r '.success' 2>/dev/null || echo "")"
assert_eq "cancel --json cancelled" "true" "$(echo "$CANCEL_JSON" | jq -r '.cancelled' 2>/dev/null || echo "")"
assert_eq "cancel --json removalRequested (assets checkpoint)" "true" "$(echo "$CANCEL_JSON" | jq -r '.removalRequested' 2>/dev/null || echo "")"
assert_eq "cancel --json removalSucceeded" "true" "$(echo "$CANCEL_JSON" | jq -r '.removalSucceeded' 2>/dev/null || echo "")"
rm -rf "$CANCEL_TEST_DIR"

echo ""
echo "=== provision: cancel --json refuses external staging ==="
CANCEL_EVIL_T="$(mktemp -d)"
mkdir -p "$CANCEL_EVIL_T/phasezero/operations/cancel-evil" "$CANCEL_EVIL_T/external-staging"
echo '{"id":"cancel-evil","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_EVIL_T/phasezero/operations/cancel-evil/operation.json"
echo "$CANCEL_EVIL_T/external-staging" > "$CANCEL_EVIL_T/phasezero/operations/cancel-evil/vm_dir"
set +e
CANCEL_EVIL_JSON=$(XDG_STATE_HOME="$CANCEL_EVIL_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-evil --remove-staging --json 2>/dev/null)
CANCEL_EVIL_RC=$?
set -e
assert_eq "cancel external staging rc non-zero" "1" "$CANCEL_EVIL_RC"
assert_eq "cancel external staging preserved" "1" "$([ -d "$CANCEL_EVIL_T/external-staging" ] && echo 1 || echo 0)"
assert_eq "cancel --json success false" "false" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.success' 2>/dev/null || echo "")"
assert_eq "cancel --json removalSucceeded false" "false" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.removalSucceeded' 2>/dev/null || echo "")"
assert_eq "cancel --json preservedPath set" "$CANCEL_EVIL_T/external-staging" "$(echo "$CANCEL_EVIL_JSON" | jq -r '.preservedPath' 2>/dev/null || echo "")"
rm -rf "$CANCEL_EVIL_T"

echo ""
echo "=== provision: discard succeeds when nothing was ever staged ==="
# An operation that stopped at the validate checkpoint never created a staging
# directory, so there is no vm_dir record. Discarding it used to report
# "staging removal failed; preserved: " with an empty path, which left the
# player stuck in FAILED and blocked starting a new installation.
CANCEL_NOSTAGE_T="$(mktemp -d)"
mkdir -p "$CANCEL_NOSTAGE_T/phasezero/operations/cancel-nostage"
echo '{"id":"cancel-nostage","state":"cancelled","checkpoint":"validate","progress":0}' \
    > "$CANCEL_NOSTAGE_T/phasezero/operations/cancel-nostage/operation.json"
set +e
CANCEL_NOSTAGE_JSON=$(XDG_STATE_HOME="$CANCEL_NOSTAGE_T" bash "$PROVISION_SCRIPT" \
    cancel --operation-id cancel-nostage --remove-staging --json 2>/dev/null)
CANCEL_NOSTAGE_RC=$?
set -e
assert_eq "cancel without staging rc 0" "0" "$CANCEL_NOSTAGE_RC"
assert_eq "cancel without staging success" "true" "$(echo "$CANCEL_NOSTAGE_JSON" | jq -r '.success' 2>/dev/null || echo "")"
assert_eq "cancel without staging removalSucceeded" "true" "$(echo "$CANCEL_NOSTAGE_JSON" | jq -r '.removalSucceeded' 2>/dev/null || echo "")"
assert_eq "cancel without staging no error" "" "$(echo "$CANCEL_NOSTAGE_JSON" | jq -r '.error' 2>/dev/null || echo "")"
assert_eq "cancel without staging no preserved path" "" "$(echo "$CANCEL_NOSTAGE_JSON" | jq -r '.preservedPath' 2>/dev/null || echo "")"
rm -rf "$CANCEL_NOSTAGE_T"

# shellcheck source=linux/windows-vm/provision.sh
source "$PROVISION_SCRIPT" 2>/dev/null || true

echo ""
echo "=== provision: validate_qemu_pid guards ==="
# Never kill real processes: use the test shell's own pid (alive, not qemu)
# and a background sleeper with a forged qemu argv0 (qemu-like but no op).
set +e
validate_qemu_pid "$$" "" "op-guard" 2>/dev/null
GUARD_NOT_QEMU=$?
set -e
assert_eq "alive non-qemu pid refused" "1" "$GUARD_NOT_QEMU"
sleep 60 &
FAKE_QEMU_PID=$!
set +e
validate_qemu_pid "$FAKE_QEMU_PID" "" "op-guard" 2>/dev/null
GUARD_SLEEPER=$?
set -e
kill "$FAKE_QEMU_PID" 2>/dev/null || true
wait "$FAKE_QEMU_PID" 2>/dev/null || true
assert_eq "sleeper pid refused (not qemu)" "1" "$GUARD_SLEEPER"
set +e
validate_qemu_pid "999999" "" "op-guard" 2>/dev/null
GUARD_DEAD=$?
set -e
assert_eq "dead pid refused" "1" "$GUARD_DEAD"
set +e
validate_qemu_pid "abc" "" "op-guard" 2>/dev/null
GUARD_NAN=$?
set -e
assert_eq "non-numeric pid refused" "1" "$GUARD_NAN"
set +e
validate_qemu_pid "" "" "op-guard" 2>/dev/null
GUARD_EMPTY=$?
set -e
assert_eq "empty pid refused" "1" "$GUARD_EMPTY"

echo ""
echo "=== provision: shutdown validates staging before touching socat/qemu-pid ==="
SHUT_EVIL_T="$(mktemp -d)"
mkdir -p "$SHUT_EVIL_T/phasezero/operations/shut-evil" "$SHUT_EVIL_T/external-vm"
echo '{"id":"shut-evil","state":"running"}' > "$SHUT_EVIL_T/phasezero/operations/shut-evil/operation.json"
echo "$SHUT_EVIL_T/external-vm" > "$SHUT_EVIL_T/phasezero/operations/shut-evil/vm_dir"
SHUT_BIN="$SHUT_EVIL_T/bin"
mkdir -p "$SHUT_BIN"
cat > "$SHUT_BIN/socat" <<'EOF'
#!/usr/bin/env bash
printf 'socat %s\n' "$*" >> "${SHUT_SOCAT_LOG:?}"
exit 0
EOF
chmod +x "$SHUT_BIN/socat"
set +e
SHUT_EVIL_JSON=$(PATH="$SHUT_BIN:$PATH" SHUT_SOCAT_LOG="$SHUT_EVIL_T/socat.log" XDG_STATE_HOME="$SHUT_EVIL_T" bash "$PROVISION_SCRIPT" shutdown --operation-id shut-evil --json 2>/dev/null)
SHUT_EVIL_RC=$?
set -e
assert_eq "shutdown external staging rc non-zero" "1" "$SHUT_EVIL_RC"
assert_eq "shutdown external staging success false" "false" "$(echo "$SHUT_EVIL_JSON" | jq -r '.success | tostring' 2>/dev/null || echo "")"
assert_eq "shutdown external staging never invoked socat" "0" "$([ -s "$SHUT_EVIL_T/socat.log" ] && echo 1 || echo 0)"

echo ""
echo "=== provision: shutdown corrupt metadata fails closed ==="
SHUT_CORRUPT_T="$(mktemp -d)"
mkdir -p "$SHUT_CORRUPT_T/phasezero/operations/shut-corrupt" "$SHUT_CORRUPT_T/phasezero/windows-vm/vms/shut-corrupt"
echo 'garbage' > "$SHUT_CORRUPT_T/phasezero/operations/shut-corrupt/operation.json"
echo "$SHUT_CORRUPT_T/phasezero/windows-vm/vms/shut-corrupt" > "$SHUT_CORRUPT_T/phasezero/operations/shut-corrupt/vm_dir"
SHUT_CORRUPT_BIN="$SHUT_CORRUPT_T/bin"
mkdir -p "$SHUT_CORRUPT_BIN"
cat > "$SHUT_CORRUPT_BIN/socat" <<'EOF'
#!/usr/bin/env bash
printf 'socat %s\n' "$*" >> "${SHUT_SOCAT_LOG:?}"
exit 0
EOF
chmod +x "$SHUT_CORRUPT_BIN/socat"
set +e
SHUT_CORRUPT_JSON=$(PATH="$SHUT_CORRUPT_BIN:$PATH" SHUT_SOCAT_LOG="$SHUT_CORRUPT_T/socat.log" XDG_STATE_HOME="$SHUT_CORRUPT_T" bash "$PROVISION_SCRIPT" shutdown --operation-id shut-corrupt --json 2>/dev/null)
SHUT_CORRUPT_RC=$?
set -e
assert_eq "shutdown corrupt metadata rc non-zero" "1" "$SHUT_CORRUPT_RC"
assert_eq "shutdown corrupt metadata success false" "false" "$(echo "$SHUT_CORRUPT_JSON" | jq -r '.success | tostring' 2>/dev/null || echo "")"
assert_eq "shutdown corrupt metadata never invoked socat" "0" "$([ -s "$SHUT_CORRUPT_T/socat.log" ] && echo 1 || echo 0)"
rm -rf "$SHUT_EVIL_T" "$SHUT_CORRUPT_T"

echo ""
echo "=== provision: shutdown success path hermetic (stub socat/virsh, dead pid) ==="
SHUT_OK_T="$(mktemp -d)"
SHUT_OK_BIN="$SHUT_OK_T/bin"
mkdir -p "$SHUT_OK_BIN" "$SHUT_OK_T/phasezero/operations/shut-ok" "$SHUT_OK_T/phasezero/windows-vm/vms/shut-ok"
echo '{"id":"shut-ok","state":"running"}' > "$SHUT_OK_T/phasezero/operations/shut-ok/operation.json"
VM_OK_DIR="$SHUT_OK_T/phasezero/windows-vm/vms/shut-ok"
echo "$VM_OK_DIR" > "$SHUT_OK_T/phasezero/operations/shut-ok/vm_dir"
echo '999999' > "$VM_OK_DIR/qemu-pid"
python3 -c "
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind('$VM_OK_DIR/qga.sock')
s.listen(1)
time.sleep(30)
" &
SHUT_SOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$VM_OK_DIR/qga.sock" ] && break
    sleep 0.2
done
[ -S "$VM_OK_DIR/qga.sock" ] || { echo "  FAIL: could not create qga.sock fixture"; exit 1; }
cat > "$SHUT_OK_BIN/socat" <<'EOF'
#!/usr/bin/env bash
printf 'socat %s\n' "$*" >> "${SHUT_SOCAT_LOG:?}"
cat >> "${SHUT_SOCAT_LOG:?}"
exit 0
EOF
cat > "$SHUT_OK_BIN/virsh" <<'EOF'
#!/usr/bin/env bash
printf 'virsh %s\n' "$*" >> "${SHUT_SOCAT_LOG:?}"
printf 'shut off\n'
exit 0
EOF
chmod +x "$SHUT_OK_BIN/socat" "$SHUT_OK_BIN/virsh"
set +e
SHUT_OK_JSON=$(PATH="$SHUT_OK_BIN:$PATH" SHUT_SOCAT_LOG="$SHUT_OK_T/socat.log" XDG_STATE_HOME="$SHUT_OK_T" bash "$PROVISION_SCRIPT" shutdown --operation-id shut-ok --json 2>/dev/null)
SHUT_OK_RC=$?
set -e
kill "$SHUT_SOCK_PID" 2>/dev/null || true
wait "$SHUT_SOCK_PID" 2>/dev/null || true
assert_eq "shutdown success rc 0" "0" "$SHUT_OK_RC"
assert_eq "shutdown success true" "true" "$(echo "$SHUT_OK_JSON" | jq -r '.success // ""' 2>/dev/null || echo "")"
assert_contains "shutdown sent guest-shutdown via socat" "$(cat "$SHUT_OK_T/socat.log" 2>/dev/null || echo "")" "guest-shutdown"
assert_contains "shutdown consulted virsh domstate" "$(cat "$SHUT_OK_T/socat.log" 2>/dev/null || echo "")" "domstate"
rm -rf "$SHUT_OK_T"

echo ""
echo "=== provision: finalize is idempotent while adopted VM is active ==="
FINALIZE_T="$(mktemp -d)"
FINALIZE_HOME="$FINALIZE_T/home"
FINALIZE_STATE="$FINALIZE_T/phasezero"
FINALIZE_BIN="$FINALIZE_T/bin"
FINALIZE_OP="finalize-active"
FINALIZE_DISK="$FINALIZE_HOME/VirtualMachines/PhaseZero-Windows-Test/phasezero-windows.qcow2"
mkdir -p "$FINALIZE_BIN" "$FINALIZE_STATE/operations/$FINALIZE_OP" "$(dirname "$FINALIZE_DISK")"
printf 'fake-qcow2\n' > "$FINALIZE_DISK"
jq -n --arg id "$FINALIZE_OP" --arg disk "$FINALIZE_DISK" \
    '{id:$id,state:"completed",adoptedDisk:$disk}' > "$FINALIZE_STATE/operations/$FINALIZE_OP/operation.json"
cat > "$FINALIZE_BIN/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done
EOF
cat > "$FINALIZE_BIN/qemu-img" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' > "${FINALIZE_QEMU_IMG_MARKER:?}"
exit 70
EOF
chmod +x "$FINALIZE_BIN/qemu-system-x86_64" "$FINALIZE_BIN/qemu-img"
"$FINALIZE_BIN/qemu-system-x86_64" "$FINALIZE_DISK" &
FINALIZE_QEMU_PID=$!
sleep 0.2
set +e
FINALIZE_JSON=$(HOME="$FINALIZE_HOME" XDG_STATE_HOME="$FINALIZE_T" PATH="$FINALIZE_BIN:$PATH" \
    FINALIZE_QEMU_IMG_MARKER="$FINALIZE_T/qemu-img.called" \
    bash "$PROVISION_SCRIPT" finalize --operation-id "$FINALIZE_OP" --json 2>/dev/null)
FINALIZE_RC=$?
set -e
kill "$FINALIZE_QEMU_PID" 2>/dev/null || true
wait "$FINALIZE_QEMU_PID" 2>/dev/null || true
assert_eq "active adopted finalize rc 0" "0" "$FINALIZE_RC"
assert_eq "active adopted finalize reports already finalized" "true" "$(echo "$FINALIZE_JSON" | jq -r '.alreadyFinalized // false' 2>/dev/null || echo false)"
assert_eq "active adopted finalize bypasses locked qemu-img check" "0" "$([ -e "$FINALIZE_T/qemu-img.called" ] && echo 1 || echo 0)"
assert_eq "active adopted finalize keeps canonical disk" "$FINALIZE_DISK" "$(echo "$FINALIZE_JSON" | jq -r '.adoptedDisk // ""' 2>/dev/null || echo "")"
rm -rf "$FINALIZE_T"

echo ""
echo "=== provision: finalize contends on the shared operation lock ==="
FINALIZE_LOCK_T="$(mktemp -d)"
FINALIZE_LOCK_STATE="$FINALIZE_LOCK_T/phasezero"
FINALIZE_LOCK_OP="op-finalize-lock"
FINALIZE_LOCK_VM="$FINALIZE_LOCK_STATE/windows-vm/vms/$FINALIZE_LOCK_OP"
FINALIZE_LOCK_FILE="$FINALIZE_LOCK_STATE/windows-vm/provision/active.lock"
mkdir -p "$FINALIZE_LOCK_STATE/operations/$FINALIZE_LOCK_OP" \
    "$FINALIZE_LOCK_VM" "$(dirname "$FINALIZE_LOCK_FILE")"
printf '%s\n' '{"id":"op-finalize-lock","state":"completed"}' \
    > "$FINALIZE_LOCK_STATE/operations/$FINALIZE_LOCK_OP/operation.json"
printf '%s\n' "$FINALIZE_LOCK_VM" \
    > "$FINALIZE_LOCK_STATE/operations/$FINALIZE_LOCK_OP/vm_dir"
printf '%s\n' "$FINALIZE_LOCK_VM/snapshot.qcow2" \
    > "$FINALIZE_LOCK_STATE/operations/$FINALIZE_LOCK_OP/snapshot_path"
touch "$FINALIZE_LOCK_VM/snapshot.qcow2"
(
    exec 9<>"$FINALIZE_LOCK_FILE"
    flock 9
    printf '%s\n' "$FINALIZE_LOCK_OP" > "$FINALIZE_LOCK_FILE"
    touch "$FINALIZE_LOCK_T/ready"
    sleep 30
) &
FINALIZE_LOCK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$FINALIZE_LOCK_T/ready" ] && break
    sleep 0.1
done
[ -e "$FINALIZE_LOCK_T/ready" ] || { echo "  FAIL: lock holder did not start"; exit 1; }
set +e
HOME="$FINALIZE_LOCK_T/home" XDG_STATE_HOME="$FINALIZE_LOCK_T" \
    bash "$PROVISION_SCRIPT" finalize --operation-id "$FINALIZE_LOCK_OP" --json \
    >/dev/null 2>&1
FINALIZE_LOCK_RC=$?
set -e
kill "$FINALIZE_LOCK_PID" 2>/dev/null || true
wait "$FINALIZE_LOCK_PID" 2>/dev/null || true
assert_eq "finalize refuses concurrent removal lock" "1" \
    "$([ "$FINALIZE_LOCK_RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "finalize contention preserves staging" "1" \
    "$([ -f "$FINALIZE_LOCK_VM/snapshot.qcow2" ] && echo 1 || echo 0)"
rm -rf "$FINALIZE_LOCK_T"

echo ""
echo "=== graphics: plan serialization ==="
GFX_PLAN_DIR="$(mktemp -d)"
GFX_VIRTIO=$(PZ_STATE="$GFX_PLAN_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics virtio-gl --json 2>/dev/null | jq -r '.graphics // ""' 2>/dev/null || echo "")
assert_eq "plan --graphics virtio-gl produces virtio-gl" "virtio-gl" "$GFX_VIRTIO"
GFX_DEFAULT=$(PZ_STATE="$GFX_PLAN_DIR" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null | jq -r '.graphics // ""' 2>/dev/null || echo "")
assert_eq "plan without --graphics defaults to compat" "compat" "$GFX_DEFAULT"
rm -rf "$GFX_PLAN_DIR"

echo ""
echo "=== graphics: plan rejects non-provisionable profiles before persistence ==="
GFX_REJECT_BASE="$(mktemp -d)"
GFX_REJECT_DIR="$GFX_REJECT_BASE/phasezero"
mkdir -p "$GFX_REJECT_DIR/windows-vm/provision/plans"
mkdir -p "$GFX_REJECT_DIR/operations"
GFX_REJECT_BEFORE="$(find "$GFX_REJECT_DIR/windows-vm/provision/plans" -type f | wc -l)"
set +e
GFX_VENUS_ERROR="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" XDG_STATE_HOME="$GFX_REJECT_BASE" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics virtio-venus --json 2>&1)"
GFX_VENUS_RC=$?
GFX_CUSTOM_ERROR="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" XDG_STATE_HOME="$GFX_REJECT_BASE" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics custom --json 2>&1)"
GFX_CUSTOM_RC=$?
set -e
GFX_REJECT_AFTER="$(find "$GFX_REJECT_DIR/windows-vm/provision/plans" -type f | wc -l)"
assert_eq "venus provision plan rejected" "1" "$GFX_VENUS_RC"
assert_contains "venus rejection explains plan-only" "$GFX_VENUS_ERROR" "plan-only"
assert_eq "custom provision plan rejected" "1" "$GFX_CUSTOM_RC"
assert_contains "custom rejection lists supported profiles" "$GFX_CUSTOM_ERROR" "valid: compat, virtio-gl"
assert_eq "invalid profiles create no plan/token" "$GFX_REJECT_BEFORE" "$GFX_REJECT_AFTER"

echo ""
echo "=== graphics: malformed contract fails closed ==="
GFX_BAD_CONTRACT="$GFX_REJECT_DIR/bad-contract.json"
printf '%s\n' '{"schemaVersion":"wrong","profiles":[]}' > "$GFX_BAD_CONTRACT"
set +e
GFX_BAD_ERROR="$(PZ_WINDOWS_VM_GRAPHICS_CONTRACT="$GFX_BAD_CONTRACT" PZ_TEST_MODE=1 \
    PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" XDG_STATE_HOME="$GFX_REJECT_BASE" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics compat --json 2>&1)"
GFX_BAD_RC=$?
set -e
assert_eq "malformed graphics contract rejected" "1" "$GFX_BAD_RC"
assert_contains "malformed graphics contract error" "$GFX_BAD_ERROR" "contract is missing or invalid"

echo ""
echo "=== graphics: start rejects stale Venus plan before operation creation ==="
GFX_STALE_PLAN_DIR="$GFX_REJECT_DIR/windows-vm/provision/plans"
cat > "$GFX_STALE_PLAN_DIR/stale-venus.json" <<'EOF'
{"id":"stale-venus","confirmToken":"stale-token","graphics":"virtio-venus","blockers":[]}
EOF
set +e
GFX_STALE_ERROR="$(XDG_STATE_HOME="$GFX_REJECT_BASE" bash "$PROVISION_SCRIPT" start \
    --plan-id stale-venus --confirm stale-token --json 2>&1)"
GFX_STALE_RC=$?
set -e
assert_eq "stale Venus plan rejected by start" "1" "$GFX_STALE_RC"
assert_contains "stale Venus rejection is explicit" "$GFX_STALE_ERROR" "refusing stale plan"
assert_eq "stale plan creates no operation" "0" "$(find "$GFX_REJECT_DIR/operations" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
rm -rf "$GFX_REJECT_BASE"

echo ""
echo "=== preflight: selected graphics profile is honest ==="
PREFLIGHT_SCRIPT="$PZ_ROOT/linux/windows-vm/preflight.sh"
GFX_PREFLIGHT_T="$(mktemp -d)"
touch "$GFX_PREFLIGHT_T/kvm"
GFX_PREFLIGHT_COMPAT="$(PZ_GFX_KVM_PATH="$GFX_PREFLIGHT_T/kvm" PZ_GFX_RENDER_NODE="" \
    PZ_GFX_QEMU_VIRTIO_VGA_GL=0 PZ_GFX_VIRGL_PRESENT=0 \
    bash "$PREFLIGHT_SCRIPT" --graphics compat --json 2>/dev/null)"
assert_eq "compat preflight reports requested profile" "compat" "$(jq -r '.graphics.profile' <<< "$GFX_PREFLIGHT_COMPAT")"
assert_eq "compat preflight ignores GL dependencies" "true" "$(jq -r '.graphics.supported' <<< "$GFX_PREFLIGHT_COMPAT")"
GFX_PREFLIGHT_GL="$(PZ_GFX_KVM_PATH="$GFX_PREFLIGHT_T/kvm" PZ_GFX_RENDER_NODE="$GFX_PREFLIGHT_T/render" \
    PZ_GFX_QEMU_VIRTIO_VGA_GL=1 PZ_GFX_VIRGL_PRESENT=1 \
    bash "$PREFLIGHT_SCRIPT" --graphics virtio-gl --json 2>/dev/null)"
assert_eq "virtio-gl preflight reports requested profile" "virtio-gl" "$(jq -r '.graphics.profile' <<< "$GFX_PREFLIGHT_GL")"
assert_eq "virtio-gl preflight passes hermetic requirements" "true" "$(jq -r '.graphics.supported' <<< "$GFX_PREFLIGHT_GL")"
GFX_PREFLIGHT_VENUS="$(PZ_GFX_KVM_PATH="$GFX_PREFLIGHT_T/kvm" \
    bash "$PREFLIGHT_SCRIPT" --graphics virtio-venus --json 2>/dev/null)"
assert_eq "Venus preflight preserves requested profile" "virtio-venus" "$(jq -r '.graphics.profile' <<< "$GFX_PREFLIGHT_VENUS")"
assert_eq "Venus preflight refuses provisioning support" "false" "$(jq -r '.graphics.supported' <<< "$GFX_PREFLIGHT_VENUS")"
assert_contains "Venus preflight explains provisioning boundary" \
    "$(jq -r '.graphics.failures[]' <<< "$GFX_PREFLIGHT_VENUS")" "not supported by automated provisioning"
rm -rf "$GFX_PREFLIGHT_T"

echo ""
echo "=== graphics: unsupported virtio-gl becomes a plan blocker ==="
GFX_BLOCK_BASE="$(mktemp -d)"
GFX_BLOCK_FIXTURE='{"status":"fail","swtpm":{"binary":true,"running":true},"virtio":{"outdated":false},"graphics":{"profile":"wrong","supported":false,"fallback":"compat","failures":["no render node"]}}'
GFX_BLOCK_PLAN="$(PZ_TEST_MODE=1 PZ_PREFLIGHT_JSON="$GFX_BLOCK_FIXTURE" XDG_STATE_HOME="$GFX_BLOCK_BASE" \
    bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --graphics virtio-gl --json 2>/dev/null)"
assert_eq "plan preflight profile matches selection" "virtio-gl" "$(jq -r '.preflight.graphics.profile' <<< "$GFX_BLOCK_PLAN")"
assert_eq "unsupported virtio-gl adds blocker" "1" "$(jq -r '.blockers | length' <<< "$GFX_BLOCK_PLAN")"
assert_contains "virtio-gl blocker gives compat action" "$(jq -r '.blockers[]' <<< "$GFX_BLOCK_PLAN")" \
    "Selecione Compatibilidade para continuar"
rm -rf "$GFX_BLOCK_BASE"

echo ""
echo "=== graphics: preflight compat ==="
GFX_COM_DIR="$(mktemp -d)"
mkdir -p "$GFX_COM_DIR/gfx-test-compat"
echo '{"id":"gfx-test-compat","checkpoint":"validate","state":"running","log":[]}' > "$GFX_COM_DIR/gfx-test-compat/operation.json"
OPERATIONS_DIR="$GFX_COM_DIR" graphics_preflight "gfx-test-compat" "compat"
assert_eq "preflight compat returns 0" "0" "$?"
rm -rf "$GFX_COM_DIR"

echo ""
echo "=== graphics: preflight virtio-gl fail-loud ==="
GFX_VGL_DIR="$(mktemp -d)"
mkdir -p "$GFX_VGL_DIR/gfx-test-vgl"
echo '{"id":"gfx-test-vgl","checkpoint":"validate","state":"running","log":[]}' > "$GFX_VGL_DIR/gfx-test-vgl/operation.json"
OPERATIONS_DIR="$GFX_VGL_DIR" PZ_GFX_RENDER_NODE="" PZ_GFX_KVM_PATH="/nonexistent/kvm" \
    PZ_GFX_QEMU_BIN="false" PZ_GFX_VIRGL_PRESENT=0 PZ_GFX_QEMU_VIRTIO_VGA_GL=0 \
    graphics_preflight "gfx-test-vgl" "virtio-gl" && true
assert_eq "preflight virtio-gl fails without resources" "1" "$?"
LOG_TEXT=$(jq -r '.log[]' "$GFX_VGL_DIR/gfx-test-vgl/operation.json" 2>/dev/null || echo "")
assert_contains "preflight logs fallback message" "$LOG_TEXT" "fallback: --graphics compat"
rm -rf "$GFX_VGL_DIR"

echo ""
echo "=== graphics: preflight unknown profile ==="
GFX_UNK_DIR="$(mktemp -d)"
mkdir -p "$GFX_UNK_DIR/gfx-test-unk"
echo '{"id":"gfx-test-unk","checkpoint":"validate","state":"running","log":[]}' > "$GFX_UNK_DIR/gfx-test-unk/operation.json"
OPERATIONS_DIR="$GFX_UNK_DIR" graphics_preflight "gfx-test-unk" "vfio-looking-glass" && true
assert_eq "preflight unknown profile fails" "1" "$?"
LOG_UNK=$(jq -r '.log[]' "$GFX_UNK_DIR/gfx-test-unk/operation.json" 2>/dev/null || echo "")
assert_contains "preflight logs unknown profile" "$LOG_UNK" "unknown graphics profile"
rm -rf "$GFX_UNK_DIR"

echo ""
echo "=== graphics: resolve_qemu_args compat ==="
GFX_RES_COM_DIR="$(mktemp -d)"
mkdir -p "$GFX_RES_COM_DIR/gfx-resolve-compat"
echo '{"id":"gfx-resolve-compat","state":"running","log":[]}' > "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json"
GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
OPERATIONS_DIR="$GFX_RES_COM_DIR" resolve_graphics_qemu_args "gfx-resolve-compat" "compat"
assert_eq "resolve compat VGA" "-vga qxl" "$GRAPHICS_VGA"
assert_eq "resolve compat display" "-display gtk" "$GRAPHICS_DISPLAY"
assert_contains "resolve compat accel log" "$GRAPHICS_ACCEL_LOG" "NONE (QXL)"
RESOLVED_PROFILE=$(jq < "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve compat persists profile" "compat" "$RESOLVED_PROFILE"
RESOLVED_VGA=$(jq < "$GFX_RES_COM_DIR/gfx-resolve-compat/operation.json" -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
assert_eq "resolve compat persists vgaDevice" "-vga qxl" "$RESOLVED_VGA"
rm -rf "$GFX_RES_COM_DIR"

echo ""
echo "=== graphics: resolve_qemu_args virtio-gl ==="
GFX_RES_VGL_DIR="$(mktemp -d)"
mkdir -p "$GFX_RES_VGL_DIR/gfx-resolve-vgl"
echo '{"id":"gfx-resolve-vgl","state":"running","log":[]}' > "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json"
GRAPHICS_VGA="" GRAPHICS_DISPLAY="" GRAPHICS_ACCEL_LOG=""
OPERATIONS_DIR="$GFX_RES_VGL_DIR" resolve_graphics_qemu_args "gfx-resolve-vgl" "virtio-gl"
assert_eq "resolve vgl VGA" "-device virtio-vga-gl" "$GRAPHICS_VGA"
assert_eq "resolve vgl display" "-display gtk,gl=on" "$GRAPHICS_DISPLAY"
assert_contains "resolve vgl accel log" "$GRAPHICS_ACCEL_LOG" "virgl"
RESOLVED_VGL_PROFILE=$(jq < "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" -r '.graphicsResolved.profile // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists profile" "virtio-gl" "$RESOLVED_VGL_PROFILE"
RESOLVED_VGL_VGA=$(jq < "$GFX_RES_VGL_DIR/gfx-resolve-vgl/operation.json" -r '.graphicsResolved.vgaDevice // ""' 2>/dev/null || echo "")
assert_eq "resolve vgl persists vgaDevice" "-device virtio-vga-gl" "$RESOLVED_VGL_VGA"
rm -rf "$GFX_RES_VGL_DIR"

echo ""
echo "=== graphics: run_relaunch qemu_args per profile (stubbed qemu, argv captured) ==="
RL_DIR="$(mktemp -d)"
RL_BIN="$RL_DIR/bin"
mkdir -p "$RL_BIN" "$RL_DIR/phasezero/vms/relaunch-test"
export RL_QEMU_ARGV="$RL_DIR/qemu-argv.log"
cat > "$RL_BIN/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${RL_QEMU_ARGV:?}"
sock=""
for arg in "$@"; do
    case "$arg" in
        socket,path=*,server=on,wait=off,id=qga0)
            sock="${arg#socket,path=}"
            sock="${sock%%,server=*}"
            ;;
    esac
done
if [ -n "$sock" ]; then
    python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(10)
PY
fi
sleep 10
EOF
chmod +x "$RL_BIN/qemu-system-x86_64"
: > "$RL_QEMU_ARGV"
truncate -s 64M "$RL_DIR/phasezero/vms/relaunch-test/disk.qcow2"
truncate -s 64M "$RL_DIR/phasezero/vms/relaunch-test/golden-clean.qcow2"
mkdir -p "$RL_DIR/phasezero/operations/relaunch-compat"
echo '{"id":"rl-plan","graphics":"compat","resources":{"ramMb":2048,"cpus":2},"iso":{"path":"'"$DUMMY_ISO"'","arch":"x64"}}' > "$RL_DIR/phasezero/operations/relaunch-compat/plan.json"
echo '{"id":"relaunch-compat","state":"running","checkpoint":"relaunch","log":[]}' > "$RL_DIR/phasezero/operations/relaunch-compat/operation.json"
echo "$RL_DIR/phasezero/vms/relaunch-test" > "$RL_DIR/phasezero/operations/relaunch-compat/vm_dir"
touch "$RL_DIR/phasezero/ovmf_vars.fd"
XDG_STATE_HOME="$RL_DIR" PATH="$RL_BIN:$PATH" \
    PZ_WINDOWS_VM_OVMF_CODE="$RL_DIR/phasezero/ovmf_vars.fd" \
    bash -c '
source "'"$PROVISION_SCRIPT"'" 2>/dev/null || true
qga_ping() { return 0; }
qga_exec() {
    case "$2" in
        *guest-get-osinfo*) QGA_RESPONSE="{\"return\":{\"name\":\"Microsoft Windows\"}}" ;;
        *guest-network-get-interfaces*) QGA_RESPONSE="{\"return\":[{\"name\":\"Ethernet\",\"ip-addresses\":[{\"ip-address-type\":\"ipv4\",\"ip-address\":\"10.0.2.15\"}]}]}" ;;
        *guest-file-open*) QGA_RESPONSE="{\"return\":7}" ;;
        *guest-file-read*) QGA_RESPONSE="{\"return\":{\"buf-b64\":\"eyJjb21wbGV0ZWRBdCI6IngiLCJleGNoYW5nZVBhdGgiOiJxZW11In0=\"}}" ;;
        *guest-file-close*) QGA_RESPONSE="{\"return\":{}}" ;;
        *) QGA_RESPONSE="{\"return\":{}}" ;;
    esac
    return 0
}
run_relaunch "relaunch-compat" 2>/dev/null || true
' 2>/dev/null || true
RL_LOG=$(jq -r '.log[]' "$RL_DIR/phasezero/operations/relaunch-compat/operation.json" 2>/dev/null || echo "")
assert_contains "relaunch compat logs NONE" "$RL_LOG" "NONE (QXL)"
assert_contains "relaunch compat logs relaunch" "$RL_LOG" "relaunching with display"
RL_ARGV=$(cat "$RL_QEMU_ARGV" 2>/dev/null || echo "")
assert_contains "relaunch argv machine" "$RL_ARGV" "-machine q35,accel=kvm"
assert_contains "relaunch argv cpu" "$RL_ARGV" "-cpu host"
assert_contains "relaunch argv smp" "$RL_ARGV" "-smp 2"
assert_contains "relaunch argv ram" "$RL_ARGV" "-m 2048"
assert_contains "relaunch argv compat vga" "$RL_ARGV" "-vga qxl"
assert_contains "relaunch argv display" "$RL_ARGV" "-display gtk"
assert_eq "relaunch never passes combined QEMU option argv" "0" "$(grep -Fc 'qemu_args+=("$GRAPHICS_' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_contains "relaunch argv qga socket" "$RL_ARGV" "qga.sock"
assert_contains "relaunch argv QMP recovery socket" "$RL_ARGV" "relaunch-qmp.sock"
assert_eq "relaunch QEMU survives worker terminal teardown" "1" "$(grep -Fq -- 'nohup setsid qemu-system-x86_64' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch falls back once when virtio-gl is not manageable" "1" "$(grep -Fq -- 'PZ_RELAUNCH_FALLBACK_ACTIVE=1 PZ_RELAUNCH_GRAPHICS_OVERRIDE=compat' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch qemu-pid file written" "1" "$([ -f "$RL_DIR/phasezero/vms/relaunch-test/qemu-pid" ] && echo 1 || echo 0)"

echo ""
echo "=== graphics: run_relaunch virtio-gl argv ==="
mkdir -p "$RL_DIR/phasezero/operations/relaunch-vgl"
echo '{"id":"rl-plan","graphics":"virtio-gl","resources":{"ramMb":4096,"cpus":4},"iso":{"path":"'"$DUMMY_ISO"'","arch":"x64"}}' > "$RL_DIR/phasezero/operations/relaunch-vgl/plan.json"
echo '{"id":"relaunch-vgl","state":"running","checkpoint":"relaunch","log":[]}' > "$RL_DIR/phasezero/operations/relaunch-vgl/operation.json"
echo "$RL_DIR/phasezero/vms/relaunch-test" > "$RL_DIR/phasezero/operations/relaunch-vgl/vm_dir"
: > "$RL_QEMU_ARGV"
XDG_STATE_HOME="$RL_DIR" PATH="$RL_BIN:$PATH" \
    PZ_WINDOWS_VM_OVMF_CODE="$RL_DIR/phasezero/ovmf_vars.fd" \
    bash -c '
source "'"$PROVISION_SCRIPT"'" 2>/dev/null || true
qga_ping() { return 0; }
qga_exec() {
    case "$2" in
        *guest-get-osinfo*) QGA_RESPONSE="{\"return\":{\"name\":\"Microsoft Windows\"}}" ;;
        *guest-network-get-interfaces*) QGA_RESPONSE="{\"return\":[{\"name\":\"Ethernet\",\"ip-addresses\":[{\"ip-address-type\":\"ipv4\",\"ip-address\":\"10.0.2.15\"}]}]}" ;;
        *guest-file-open*) QGA_RESPONSE="{\"return\":7}" ;;
        *guest-file-read*) QGA_RESPONSE="{\"return\":{\"buf-b64\":\"eyJjb21wbGV0ZWRBdCI6IngiLCJleGNoYW5nZVBhdGgiOiJxZW11In0=\"}}" ;;
        *guest-file-close*) QGA_RESPONSE="{\"return\":{}}" ;;
        *) QGA_RESPONSE="{\"return\":{}}" ;;
    esac
    return 0
}
run_relaunch "relaunch-vgl" 2>/dev/null || true
' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$RL_QEMU_ARGV" ] && break
    sleep 0.1
done
RL_VGL_ARGV=$(cat "$RL_QEMU_ARGV" 2>/dev/null || echo "")
assert_contains "relaunch virtio-gl vga" "$RL_VGL_ARGV" "-device virtio-vga-gl"
assert_contains "relaunch virtio-gl display" "$RL_VGL_ARGV" "-display gtk,gl=on"
assert_eq "virtio-gl relaunch omits incompatible SPICE" "0" "$(grep -c -- '-spice' <<< "$RL_VGL_ARGV" || true)"
assert_contains "relaunch virtio-gl smp" "$RL_VGL_ARGV" "-smp 4"
rm -rf "$RL_DIR"
unset RL_QEMU_ARGV

echo ""
echo "=== graphics: headless invariant ==="
SETUP_COUNT=$(grep -c '\-vga qxl' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
HEADLESS_COUNT=$(grep -c '\-display none' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
# setup, drivers, tweaks each have -vga qxl (3 total)
# relaunch also has a -vga line but it's dynamic (GRAPHICS_VGA)
assert_eq "at least 3 instances of -vga qxl (setup+drivers+tweaks)" "1" "$([ "$SETUP_COUNT" -ge 3 ] && echo 1 || echo 0)"
assert_eq "at least 3 instances of -display none (setup+drivers+tweaks)" "1" "$([ "$HEADLESS_COUNT" -ge 3 ] && echo 1 || echo 0)"
assert_eq "Windows install ISO uses first CD device" "1" "$(grep -Fq -- '-device ide-cd,bus=ide.0,drive=isoboot' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "Windows install DVD is booted only once" "1" "$(grep -Fq -- '-boot once=d' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "Windows install disk has no persistent lower boot priority" "0" "$(grep -Fc -- 'drive=drive0,bootindex=' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "Windows install acknowledges ISO boot prompt through QMP" "1" "$(grep -Fq -- 'setup-boot-prompt.py' "$PROVISION_SCRIPT" && echo 1 || echo 0)"

# Behavioral: a fake QMP server counts the presses, so a regression that
# narrows the prompt window (like the fixed three-press burst that missed it
# on real hardware) fails here instead of stalling an actual install.
PROMPT_TMP="$(mktemp -d)"
PROMPT_SOCK="$PROMPT_TMP/fake-qmp.sock"
PROMPT_COUNT_FILE="$PROMPT_TMP/prompt-count"
python3 - "$PROMPT_SOCK" "$PROMPT_COUNT_FILE" <<'PYFAKE' &
import json, os, sys
sock_path, count_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
import socket
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)
conn, _ = server.accept()
conn.sendall(json.dumps({"QMP": {"version": {}}}).encode() + b"\n")
presses = 0
buf = b""
while True:
    chunk = conn.recv(4096)
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("execute") == "human-monitor-command":
            presses += 1
        conn.sendall(b'{"return": {}}\n')
open(count_path, "w").write(str(presses))
conn.close()
PYFAKE
FAKE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$PROMPT_SOCK" ] && break; sleep 0.1; done
python3 "$PZ_ROOT/linux/windows-vm/setup-boot-prompt.py" "$PROMPT_SOCK" --presses 6 --delay 0.02
wait "$FAKE_PID"
assert_eq "boot prompt helper presses across the whole window" "6" "$(cat "$PROMPT_COUNT_FILE")"
QGA_WAIT_OFF_COUNT=$(grep -Fc 'server=on,wait=off,id=qga0' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
assert_eq "all provision QGA sockets avoid startup deadlock" "4" "$QGA_WAIT_OFF_COUNT"
VIRTIO_SERIAL_COUNT=$(grep -Fc -- '-device virtio-serial-pci' "$PROVISION_SCRIPT" 2>/dev/null || echo 0)
assert_eq "all QGA launch phases provide virtio serial bus" "4" "$VIRTIO_SERIAL_COUNT"
assert_eq "QGA phase transport keeps one channel" "1" "$(grep -Fq -- 'coproc PZ_QGA_SOCAT' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "QGA requests have bounded reads" "1" "$(grep -Fq -- 'IFS= read -r -t 1 response' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "QGA ping retains parent channel" "1" "$(grep -Fq -- 'QGA_RESPONSE="$response"' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "QGA requests correlate responses by id" "1" "$(grep -Fq -- '.id == $id and (has("return") or has("error"))' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "QGA shutdown transport survives stdin EOF" "1" "$(grep -Fq -- 'timeout 5 socat -T 2 STDIO,ignoreeof' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "QGA command rejects empty successful transport" "1" "$(grep -Fq -- 'if [ -n "$response" ]' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup tries built-in and host SMB endpoints" "1" "$(grep -Fq -- "\$shareCandidates = @('\\\\10.0.2.4\\qemu', '\\\\10.0.2.2\\PZExchange')" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup retains local account password" "0" "$(grep -Fc -- '.SetPassword("")' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "guest setup delegates autologon to LSA helper" "1" "$(grep -Fq -- 'guest-login.ps1' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup enables automatic touch keyboard" "1" "$(grep -Fq -- '-Mode touch-input' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup does not disable autologon after success" "0" "$(grep -Fc -- 'automatic logon secret removed' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "guest setup installs bounded QGA MSI" "1" "$(grep -Fq -- 'WaitForExit(300000)' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup delays QGA and clears brittle dependencies" "1" "$(grep -Fq -- 'start= delayed-auto depend= /' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "driver phase promotes proven QGA to automatic start" "1" "$(grep -Fq -- 'start= auto depend= /' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup configures QGA service recovery" "1" "$(grep -Fq -- 'actions= restart/5000/restart/10000/restart/30000' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup avoids hanging all-in-one installer" "0" "$(grep -Fc 'Start-Process $guestTools' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "guest setup persists completion marker" "1" "$(grep -Fq -- 'provisioning-complete.json' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks enumerate Xbox packages before removal" "1" "$(grep -Fq -- "Get-AppxPackage -AllUsers -Name '*Xbox*'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks never pass wildcard as package identity" "0" "$(grep -Fc -- 'Remove-AppxPackage -Package "*xbox*"' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "tweaks never stop a healthy Workstation service" "0" "$(grep -Fc -- 'Restart-Service LanmanWorkstation' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "tweaks repair missing Workstation ServiceDll" "1" "$(grep -Fq -- "ServiceDll registry repaired" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch validates guest network without blocking PowerShell" "1" "$(grep -Fq -- 'guest-network-get-interfaces' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch DHCP wait has wall-clock 60-second bound" "1" "$(grep -Fq -- 'local network_deadline=$((SECONDS + 60))' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch reads completion marker through QGA" "1" "$(grep -Fq -- 'guest-file-read' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch strips Windows QGA marker padding" "1" "$(grep -Fq -- "tr -d '\\000'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "Windows net use calls are time bounded" "1" "$(grep -Fq -- 'WaitForExit(15000)' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "relaunch failure attempts guest shutdown before kill" "1" "$(grep -Fq -- 'qga_shutdown "$vm_dir/qga.sock"' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup retries exchange mapping at login" "1" "$(grep -Fq -- 'PhaseZeroMapExchange' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "guest setup and drivers avoid hanging Get-Volume cmdlet" "0" "$(grep -Fc -- 'Get-Volume' "$PROVISION_SCRIPT" 2>/dev/null || true)"
assert_eq "driver phase targets Windows 11 AMD64 INF packages" "1" "$(grep -Fq -- "'NetKVM\w11\amd64\netkvm.inf'" "$PROVISION_SCRIPT" && grep -Fq -- "'viogpudo\w11\amd64\viogpudo.inf'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "driver phase installs virtio touchscreen and controls" "1" "$(grep -Fq -- "'vioinput\w11\amd64\vioinput.inf'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "driver phase accepts pnputil already-current exit 259" "1" "$(grep -Fq -- 'if ($LASTEXITCODE -notin @(0, 259))' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "driver phase has wall-clock bounded 10-minute QGA wait" "1" "$(grep -Fq -- 'local wait_timeout=600 wait_started=$SECONDS wait_deadline=$((SECONDS + 600))' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "driver phase treats missing QGA service as failure" "1" "$(grep -Fq -- "throw 'QEMU Guest Agent service missing after driver installation'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks verify selected SMB endpoint" "1" "$(grep -Fq -- 'Test-NetConnection $exchangeHost -Port 445' "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks require active Windows network adapter" "1" "$(grep -Fq -- "throw 'No active Windows network adapter'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks persist verified provisioning marker" "1" "$(grep -Fq -- "exchangeDrive = 'P:'" "$PROVISION_SCRIPT" && echo 1 || echo 0)"
assert_eq "tweaks serialize exchange path as plain string" "1" "$(grep -Fq -- '$exchangePath = [string](Get-Content' "$PROVISION_SCRIPT" && echo 1 || echo 0)"

echo ""
echo "=== graphics: QGA display-adapter check logic ==="
# Verify base64 decoding of guest-exec-status out-data in isolation.
# The full post-driver check runs inside provision.sh via qga_exec; we test
# the parsing logic directly.
MOCK_BASIC_DISPLAY=$(echo -n "Microsoft Basic Display Adapter" | base64 -w0 2>/dev/null || echo "")
DECODED=$(echo "$MOCK_BASIC_DISPLAY" | base64 -d 2>/dev/null || echo "")
assert_eq "QGA display base64 roundtrip" "Microsoft Basic Display Adapter" "$DECODED"
# Verify grep detection of Basic Display
BASIC_CHECK=$(echo "$DECODED" | grep -qi "Microsoft Basic Display" && echo "WARN" || echo "OK")
assert_eq "QGA Basic Display triggers WARN" "WARN" "$BASIC_CHECK"
# Verify VirtIO GPU does NOT trigger WARN
VIRTIO_CHECK=$(echo "Red Hat VirtIO GPU DOD" | grep -qi "Microsoft Basic Display" && echo "WARN" || echo "OK")
assert_eq "QGA VirtIO GPU does not trigger WARN" "OK" "$VIRTIO_CHECK"

echo ""
echo "=== graphics: venus plan (experimental) ==="
VENUS_STATE="$(mktemp -d)"
VENUS_PLAN=$(PZ_STATE="$VENUS_STATE" bash "$PZ_ROOT/linux/windows-vm/graphics.sh" plan --profile virtio-venus --json 2>/dev/null || echo '{}')
VENUS_ELIGIBLE=$(jq -r '.eligible' <<< "$VENUS_PLAN")
VENUS_MODE=$(jq -r '.mode' <<< "$VENUS_PLAN")
VENUS_ALLOW=$(jq -r '.applyAllowed' <<< "$VENUS_PLAN")
VENUS_NOTES=$(jq -r '.notes' <<< "$VENUS_PLAN")
assert_eq "venus plan eligible" "true" "$VENUS_ELIGIBLE"
assert_eq "venus plan mode experimental" "experimental" "$VENUS_MODE"
assert_eq "venus apply blocked" "false" "$VENUS_ALLOW"
assert_contains "venus notes mention Vulkan" "$VENUS_NOTES" "Vulkan"
assert_contains "venus notes mention experimental" "$VENUS_NOTES" "EXPERIMENTAL"
assert_contains "venus notes mention Deck" "$VENUS_NOTES" "Steam Deck"
rm -rf "$VENUS_STATE"

echo ""
echo "=== preflight: JSON output structure ==="
PREFLIGHT_SCRIPT="$PZ_ROOT/linux/windows-vm/preflight.sh"
PRE_OUT=$(bash "$PREFLIGHT_SCRIPT" --json 2>/dev/null || echo '{}')
# Convert jq boolean output to "1"/"0" so assert_eq works
pre_has() { echo "$PRE_OUT" | jq "has($1)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
pre_sub_has() { echo "$PRE_OUT" | jq ".$1 | has($2)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
assert_eq "preflight has status" "1" "$(pre_has '"status"')"
assert_eq "preflight has swtpm" "1" "$(pre_has '"swtpm"')"
assert_eq "preflight has virtio" "1" "$(pre_has '"virtio"')"
assert_eq "preflight has graphics" "1" "$(pre_has '"graphics"')"
assert_eq "preflight has resources" "1" "$(pre_has '"resources"')"
assert_eq "swtpm has binary" "1" "$(pre_sub_has 'swtpm' '"binary"')"
assert_eq "swtpm has running" "1" "$(pre_sub_has 'swtpm' '"running"')"
assert_eq "virtio has pinned" "1" "$(pre_sub_has 'virtio' '"pinned"')"
assert_eq "virtio has latest" "1" "$(pre_sub_has 'virtio' '"latest"')"
assert_eq "virtio has outdated" "1" "$(pre_sub_has 'virtio' '"outdated"')"
assert_eq "resources has ramMb" "1" "$(pre_sub_has 'resources' '"ramMb"')"
assert_eq "resources has cpus" "1" "$(pre_sub_has 'resources' '"cpus"')"
assert_eq "resources has diskGb" "1" "$(pre_sub_has 'resources' '"diskGb"')"
assert_eq "resources has kvmAccess" "1" "$(pre_sub_has 'resources' '"kvmAccess"')"
assert_eq "resources has ovmfPresent" "1" "$(pre_sub_has 'resources' '"ovmfPresent"')"

echo ""
echo "=== preflight: swtpm detection ==="
SWTPM_BINARY=$(echo "$PRE_OUT" | jq -r '.swtpm.binary' 2>/dev/null || echo "false")
if command -v swtpm >/dev/null 2>&1; then
    assert_eq "swtpm binary detected when installed" "true" "$SWTPM_BINARY"
else
    assert_eq "swtpm binary not detected when missing" "false" "$SWTPM_BINARY"
fi

echo ""
echo "=== provision plan includes preflight ==="
# Create a fresh state dir for plan test
PZ_STATE_DIR2="$(mktemp -d)"
PLAN_PRE=$(PZ_PREFLIGHT_JSON="$PREFLIGHT_PASS_FIXTURE" PZ_STATE="$PZ_STATE_DIR2" bash "$PROVISION_SCRIPT" plan --iso "$DUMMY_ISO" --json 2>/dev/null || echo '{}')
assert_eq "plan has preflight field" "1" "$(echo "$PLAN_PRE" | jq 'has("preflight")' 2>/dev/null | grep -q true && echo 1 || echo 0)"
PLAN_PRE_SWTPM=$(echo "$PLAN_PRE" | jq -r '.preflight.swtpm.binary' 2>/dev/null || echo "false")
if command -v swtpm >/dev/null 2>&1; then
    assert_eq "plan.preflight.swtpm matches host" "true" "$PLAN_PRE_SWTPM"
fi
PLAN_PRE_STATUS=$(echo "$PLAN_PRE" | jq -r '.preflight.status' 2>/dev/null || echo "")
assert_eq "plan.preflight status is pass/warn/fail" "1" "$(echo "$PLAN_PRE_STATUS" | grep -cE '^(pass|warn|fail)$' || echo 0)"
assert_eq "plan has warnings array" "1" "$(echo "$PLAN_PRE" | jq 'has("warnings")' 2>/dev/null | grep -q true && echo 1 || echo 0)"

rm -rf "$PZ_STATE_DIR2"

echo ""
echo "=== preflight: inspection stays read-only ==="
PZ_STATE_DIR3="$(mktemp -d)"
PREFLIGHT_READONLY="$(PZ_STATE="$PZ_STATE_DIR3" bash "$PREFLIGHT_SCRIPT" --json 2>/dev/null || echo '{}')"
assert_contains "preflight read-only report has status" "$PREFLIGHT_READONLY" '"status"'
assert_eq "read-only preflight does not create a guest staging tree" "0" \
    "$([ -e "$PZ_STATE_DIR3/windows-vm/vm" ] && echo 1 || echo 0)"
rm -rf "$PZ_STATE_DIR3"

rm -rf "$DUMMY_ISO" "$(dirname "$DUMMY_ISO")" "$PZ_STATE_DIR"

echo ""
echo "=== resilient checks: preflight structure (hermetic) ==="

RESILIENT_PREFLIGHT="$(bash "$PZ_ROOT/linux/windows-vm/preflight.sh" --json 2>/dev/null || echo '{}')"
rp_has() { echo "$RESILIENT_PREFLIGHT" | jq "has($1)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
rp_sub_has() { echo "$RESILIENT_PREFLIGHT" | jq ".$1 | has($2)" 2>/dev/null | grep -q true && echo 1 || echo 0; }
assert_eq "preflight resources has ovmfPresent" "1" "$(rp_sub_has 'resources' '"ovmfPresent"')"
assert_eq "preflight graphics has failures array" "1" "$(rp_sub_has 'graphics' '"failures"')"
assert_eq "preflight swtpm has running key" "1" "$(rp_sub_has 'swtpm' '"running"')"
assert_eq "preflight graphics has supported" "1" "$(rp_sub_has 'graphics' '"supported"')"
assert_eq "preflight virtio has outdated" "1" "$(rp_sub_has 'virtio' '"outdated"')"

echo ""
echo "=== provision: staging removal safety ==="
SAFE_T="$(mktemp -d)"
# valid case: op dir under official layout with matching metadata
mkdir -p "$SAFE_T/phasezero/windows-vm/vms/valid-op" "$SAFE_T/phasezero/operations/valid-op"
echo '{"id":"valid-op","state":"cancelled"}' > "$SAFE_T/phasezero/operations/valid-op/operation.json"
echo "$SAFE_T/phasezero/windows-vm/vms/valid-op" > "$SAFE_T/phasezero/operations/valid-op/vm_dir"
RESOLVED_OK=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
resolve_vm_staging_dir "valid-op" >/dev/null 2>&1 && echo OK || echo FAILED
')
assert_eq "staging resolves valid op" "OK" "$RESOLVED_OK"
# root
REJECT_ROOT=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/root-op"
echo "/" > "$OPERATIONS_DIR/root-op/vm_dir"
echo "{\"id\":\"root-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/root-op/operation.json"
resolve_vm_staging_dir "root-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects root" "REJECTED" "$REJECT_ROOT"
# outside the official base
REJECT_OUTSIDE=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/evil-op"
echo "{\"id\":\"evil-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/evil-op/operation.json"
echo "/tmp/evil-outside" > "$OPERATIONS_DIR/evil-op/vm_dir"
resolve_vm_staging_dir "evil-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects external path" "REJECTED" "$REJECT_OUTSIDE"
# '..' traversal
REJECT_DOTS=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/dots-op"
echo "{\"id\":\"dots-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/dots-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/dots-op/../../../etc" > "$OPERATIONS_DIR/dots-op/vm_dir"
resolve_vm_staging_dir "dots-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects .. traversal" "REJECTED" "$REJECT_DOTS"
# metadata id mismatch
REJECT_MISMATCH=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/mismatch-op"
echo "{\"id\":\"other-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/mismatch-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/valid-op" > "$OPERATIONS_DIR/mismatch-op/vm_dir"
resolve_vm_staging_dir "mismatch-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects metadata id mismatch" "REJECTED" "$REJECT_MISMATCH"
# corrupt metadata
REJECT_CORRUPT=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/corrupt-op"
echo "not-json" > "$OPERATIONS_DIR/corrupt-op/operation.json"
echo "$PZ_STATE/windows-vm/vms/valid-op" > "$OPERATIONS_DIR/corrupt-op/vm_dir"
resolve_vm_staging_dir "corrupt-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects corrupt metadata" "REJECTED" "$REJECT_CORRUPT"
# symlink escape
REJECT_SYMLINK=$(XDG_STATE_HOME="$SAFE_T" bash -c '
source "'"$PROVISION_SCRIPT"'" >/dev/null 2>&1 || true
mkdir -p "$OPERATIONS_DIR/symlink-op" "$PZ_STATE/windows-vm/vms/real-dir" /tmp/pz-symlink-target
echo "{\"id\":\"symlink-op\",\"state\":\"cancelled\"}" > "$OPERATIONS_DIR/symlink-op/operation.json"
ln -sfn /tmp/pz-symlink-target "$PZ_STATE/windows-vm/vms/real-dir"
echo "$PZ_STATE/windows-vm/vms/real-dir" > "$OPERATIONS_DIR/symlink-op/vm_dir"
resolve_vm_staging_dir "symlink-op" >/dev/null 2>&1 && echo ACCEPTED || echo REJECTED
')
assert_eq "staging rejects symlink escape" "REJECTED" "$REJECT_SYMLINK"
rm -rf "$SAFE_T" /tmp/pz-symlink-target

echo ""
echo "=== provision: cancel with staging removal ==="
CANCEL_SAFE_T="$(mktemp -d)"
mkdir -p "$CANCEL_SAFE_T/phasezero/operations/cancel-rm" "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm"
echo '{"id":"cancel-rm","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/operation.json"
echo "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm" > "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/vm_dir"
XDG_STATE_HOME="$CANCEL_SAFE_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-rm --remove-staging >/dev/null 2>&1 || true
assert_eq "cancel --remove-staging removes staged dir" "0" "$([ -d "$CANCEL_SAFE_T/phasezero/windows-vm/vms/cancel-rm" ] && echo 1 || echo 0)"
CANCEL_RM_STATE=$(jq -r '.state // ""' "$CANCEL_SAFE_T/phasezero/operations/cancel-rm/operation.json" 2>/dev/null || echo "")
assert_eq "cancel --remove-staging state cancelled" "cancelled" "$CANCEL_RM_STATE"
# cancel refusing an external staging dir must NOT delete it
mkdir -p "$CANCEL_SAFE_T/phasezero/operations/cancel-evil" "$CANCEL_SAFE_T/external-staging"
echo '{"id":"cancel-evil","state":"running","checkpoint":"validate","progress":5}' > "$CANCEL_SAFE_T/phasezero/operations/cancel-evil/operation.json"
echo "$CANCEL_SAFE_T/external-staging" > "$CANCEL_SAFE_T/phasezero/operations/cancel-evil/vm_dir"
XDG_STATE_HOME="$CANCEL_SAFE_T" bash "$PROVISION_SCRIPT" cancel --operation-id cancel-evil --remove-staging >/dev/null 2>&1 || true
assert_eq "cancel refuses external staging dir" "1" "$([ -d "$CANCEL_SAFE_T/external-staging" ] && echo 1 || echo 0)"
rm -rf "$CANCEL_SAFE_T"

echo ""
echo "=== provision: atomic lock lifecycle ==="
LOCK_T="$(mktemp -d)"
(
    XDG_STATE_HOME="$LOCK_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR"
    # acquire op A
    provision_lock_acquire "op-a" || exit 10
    # A is running -> a different operation B must be blocked
    mkdir -p "$OPERATIONS_DIR/op-a"
    printf '{"id":"op-a","state":"running","workerSpawnedEpoch":%s}\n' "$(date +%s)" > "$OPERATIONS_DIR/op-a/operation.json"
    mkdir -p "$OPERATIONS_DIR/op-b"
    echo '{"id":"op-b","state":"failed"}' > "$OPERATIONS_DIR/op-b/operation.json"
    if provision_lock_acquire "op-b" 2>/dev/null; then exit 11; fi
    # complete A -> B can take over (recovery)
    echo '{"id":"op-a","state":"completed"}' > "$OPERATIONS_DIR/op-a/operation.json"
    provision_lock_acquire "op-b" || exit 12
    # clear must only remove when content matches: op-b is current, clearing
    # op-a must leave the lock file in place
    provision_lock_clear "op-a"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 13
    # same-op re-acquire after completion is the worker handoff -> proceeds
    provision_lock_acquire "op-a" || exit 14
    provision_lock_clear "op-a"
    # Clear truncates in place, never unlinks: the file persists (empty) so
    # the flock inode stays permanent for the next acquire.
    [ -f "$PROVISION_DIR/active.lock" ] || exit 15
    [ -z "$(cat "$PROVISION_DIR/active.lock" 2>/dev/null || true)" ] || exit 16
    # corrupt reference -> refused with diagnostic
    printf 'ghost-op\n' > "$PROVISION_DIR/active.lock"
    if provision_lock_acquire "op-c" 2>/dev/null; then exit 17; fi
    printf 'ghost-op\n' > "$PROVISION_DIR/active.lock"
    mkdir -p "$OPERATIONS_DIR/ghost-op"
    echo 'garbage' > "$OPERATIONS_DIR/ghost-op/operation.json"
    if provision_lock_acquire "op-c" 2>/dev/null; then exit 18; fi
    exit 0
)
LOCK_RC=$?
assert_eq "lock lifecycle (acquire/block/recover/clear)" "0" "$LOCK_RC"
rm -rf "$LOCK_T"

echo ""
echo "=== provision: lock across separate processes (crash handoff) ==="
LOCK2_T="$(mktemp -d)"
(
    XDG_STATE_HOME="$LOCK2_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-a" "$OPERATIONS_DIR/op-b"
    printf '{"id":"op-a","state":"running","workerSpawnedEpoch":%s}\n' "$(date +%s)" > "$OPERATIONS_DIR/op-a/operation.json"
    echo '{"id":"op-b","state":"failed"}' > "$OPERATIONS_DIR/op-b/operation.json"
    provision_lock_acquire "op-a" || exit 20
    echo '{"id":"op-a","state":"completed"}' > "$OPERATIONS_DIR/op-a/operation.json"
    # Crash: exit without provision_lock_release. flock auto-releases; the
    # recorded operation id survives because <> never truncates the file.
    exit 0
) &
HOLDER_PID=$!
sleep 0.5
B_OUT=$(
    XDG_STATE_HOME="$LOCK2_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    provision_lock_acquire "op-b" || exit 21
    # B holds the lock now; clearing a stale op id must be a no-op.
    provision_lock_clear "op-a"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 22
    [ "$(cat "$PROVISION_DIR/active.lock" 2>/dev/null || true)" = "op-b" ] || exit 23
    provision_lock_clear "op-b"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 24
    [ -z "$(cat "$PROVISION_DIR/active.lock" 2>/dev/null || true)" ] || exit 25
    exit 0
)
B_RC=$?
wait "$HOLDER_PID" 2>/dev/null || true
assert_eq "crash handoff: B takes over after holder exit" "0" "$B_RC"
rm -rf "$LOCK2_T"

echo ""
echo "=== provision: lock inode stable across re-acquire (flock mode) ==="
LOCK3_T="$(mktemp -d)"
INODE_OUT=$(
    XDG_STATE_HOME="$LOCK3_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-i1" "$OPERATIONS_DIR/op-i2"
    echo '{"id":"op-i1","state":"completed"}' > "$OPERATIONS_DIR/op-i1/operation.json"
    echo '{"id":"op-i2","state":"failed"}' > "$OPERATIONS_DIR/op-i2/operation.json"
    provision_lock_acquire "op-i1" || exit 30
    INODE_1=$(stat -c %i "$PROVISION_DIR/active.lock" 2>/dev/null || echo 0)
    provision_lock_release
    provision_lock_acquire "op-i2" || exit 31
    INODE_2=$(stat -c %i "$PROVISION_DIR/active.lock" 2>/dev/null || echo 0)
    provision_lock_clear "op-i2"
    printf '%s %s\n' "$INODE_1" "$INODE_2"
)
assert_eq "lock inode stable (no truncate/recreate between acquires)" \
    "$(echo "$INODE_OUT" | awk '{print $1}') $(echo "$INODE_OUT" | awk '{print $1}')" \
    "$INODE_OUT"
rm -rf "$LOCK3_T"

echo ""
echo "=== provision: mkdir fallback lock (stale dead pid recovers, live holder refuses) ==="
LOCK4_T="$(mktemp -d)"
set +e
(
    PZ_LOCK_FORCE_MKDIR=1
    XDG_STATE_HOME="$LOCK4_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-d" "$OPERATIONS_DIR/op-e"
    echo '{"id":"op-d","state":"running"}' > "$OPERATIONS_DIR/op-d/operation.json"
    echo '{"id":"op-e","state":"failed"}' > "$OPERATIONS_DIR/op-e/operation.json"
    # Stale lock: holder pid not alive -> recovered with warning.
    mkdir -p "$PROVISION_DIR/active.lock.d"
    echo '999999999' > "$PROVISION_DIR/active.lock.d/pid"
    provision_lock_acquire "op-d" || exit 40
    [ -f "$PROVISION_DIR/active.lock.d/pid" ] || exit 41
    provision_lock_release
    # Live holder: sleep holds the pid -> acquisition refused.
    sleep 60 &
    LIVE_PID=$!
    mkdir -p "$PROVISION_DIR/active.lock.d"
    echo "$LIVE_PID" > "$PROVISION_DIR/active.lock.d/pid"
    if provision_lock_acquire "op-e" 2>/dev/null; then exit 42; fi
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    exit 0
)
MK_RC=$?
set -e
assert_eq "mkdir lock: stale recovers, live holder refused" "0" "$MK_RC"
rm -rf "$LOCK4_T"

echo ""
echo "=== provision: cross-process acquire between clear and release (flock mode) ==="
LOCK5_T="$(mktemp -d)"
LOCK5_RC=1
(
    XDG_STATE_HOME="$LOCK5_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-f" "$OPERATIONS_DIR/op-g"
    echo '{"id":"op-f","state":"completed"}' > "$OPERATIONS_DIR/op-f/operation.json"
    echo '{"id":"op-g","state":"failed"}' > "$OPERATIONS_DIR/op-g/operation.json"
    provision_lock_acquire "op-f" || exit 50
    INODE_BEFORE=$(stat -c %i "$PROVISION_DIR/active.lock")
    provision_lock_clear "op-f"
    [ -f "$PROVISION_DIR/active.lock" ] || exit 51
    # Between clear and release the racer must still be excluded: the path
    # resolves to the SAME inode we hold the flock on. Clear must never have
    # unlinked it, or the racer would lock a brand-new inode concurrently.
    RACER_TRIES=0
    for _ in 1 2 3 4 5; do
        RACER_TRIES=$((RACER_TRIES + 1))
        if XDG_STATE_HOME="$LOCK5_T" bash -c '
            provision_script="$1"
            set --
            source "$provision_script" >/dev/null 2>&1 || true
            mkdir -p "$OPERATIONS_DIR/op-g"
            provision_lock_acquire "op-g" 2>/dev/null && exit 0 || exit 1
        ' _ "$PROVISION_SCRIPT"; then
            break
        fi
        sleep 0.1
    done
    [ "$RACER_TRIES" -eq 5 ] || exit 52
    provision_lock_release
    # After release the racer is admitted, still on the same inode.
    XDG_STATE_HOME="$LOCK5_T" bash -c '
        provision_script="$1"
        set --
        source "$provision_script" >/dev/null 2>&1 || true
        mkdir -p "$OPERATIONS_DIR/op-g"
        provision_lock_acquire "op-g" 2>/dev/null || exit 1
        provision_lock_clear "op-g"
        exit 0
    ' _ "$PROVISION_SCRIPT" || exit 53
    INODE_AFTER=$(stat -c %i "$PROVISION_DIR/active.lock")
    [ "$INODE_BEFORE" = "$INODE_AFTER" ] || exit 54
    exit 0
)
LOCK5_RC=$?
assert_eq "flock: racer blocked between clear+release, admitted after, inode stable" "0" "$LOCK5_RC"
rm -rf "$LOCK5_T"

echo ""
echo "=== provision: cross-process acquire between clear and release (mkdir fallback) ==="
LOCK6_T="$(mktemp -d)"
set +e
(
    PZ_LOCK_FORCE_MKDIR=1
    XDG_STATE_HOME="$LOCK6_T"
    source "$PROVISION_SCRIPT" >/dev/null 2>&1 || true
    mkdir -p "$OPERATIONS_DIR/op-h" "$OPERATIONS_DIR/op-i"
    echo '{"id":"op-h","state":"completed"}' > "$OPERATIONS_DIR/op-h/operation.json"
    echo '{"id":"op-i","state":"failed"}' > "$OPERATIONS_DIR/op-i/operation.json"
    provision_lock_acquire "op-h" || exit 60
    provision_lock_clear "op-h"
    # clear only empties the id file; the mkdir holder dir survives until
    # release, so a racer between clear and release is still refused.
    [ -d "$PROVISION_DIR/active.lock.d" ] || exit 61
    if PZ_LOCK_FORCE_MKDIR=1 XDG_STATE_HOME="$LOCK6_T" bash -c '
        provision_script="$1"
        set --
        source "$provision_script" >/dev/null 2>&1 || true
        mkdir -p "$OPERATIONS_DIR/op-i"
        provision_lock_acquire "op-i" 2>/dev/null && exit 0 || exit 1
    ' _ "$PROVISION_SCRIPT"; then
        exit 62
    fi
    provision_lock_release
    PZ_LOCK_FORCE_MKDIR=1 XDG_STATE_HOME="$LOCK6_T" bash -c '
        provision_script="$1"
        set --
        source "$provision_script" >/dev/null 2>&1 || true
        mkdir -p "$OPERATIONS_DIR/op-i"
        provision_lock_acquire "op-i" 2>/dev/null || exit 1
        provision_lock_clear "op-i"
        exit 0
    ' _ "$PROVISION_SCRIPT" || exit 63
    exit 0
)
MK6_RC=$?
set -e
assert_eq "mkdir: clear keeps holder dir until release, racer admitted after" "0" "$MK6_RC"
rm -rf "$LOCK6_T"

echo ""
echo "=== provision: SPICE loopback invariant ==="
SPICE_LINES=$(grep -h 'spice.*port=5930' "$PROVISION_SCRIPT" | grep -cv 'addr=127.0.0.1' || true)
assert_eq "every provision -spice line binds loopback" "0" "$SPICE_LINES"

echo ""
echo "=== media-inspect: hermetic fake-tool structure gates ==="
MK_T="$(mktemp -d)"
FAKE_BIN="$MK_T/bin"
mkdir -p "$FAKE_BIN"
# Fake `file`: always reports an ISO/UDF image so the format gate passes and
# the boot/payload gates are exercised independently.
cat > "$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE_BIN/file"
# Fake listing/extract tool: member list from $FAKE_MEMBERS, WIM payload from
# $FAKE_WIM_STREAM when the extract pattern matches install.wim.
cat > "$FAKE_BIN/7z" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "l" ]; then
    cat "${FAKE_MEMBERS:-}" 2>/dev/null || true
    exit 0
fi
if [ "$1" = "e" ] && [ "$2" = "-so" ]; then
    case " $* " in
        *"install.wim"*) cat "${FAKE_WIM_STREAM:-}" 2>/dev/null || true ;;
    esac
    exit 0
fi
exit 2
EOF
chmod +x "$FAKE_BIN/7z"

# A valid WIM container header (208 bytes) + XML with two images, emitted as
# the streamed payload so wim_payload_images can parse it in bounded fashion.
FAKE_WIM_STREAM="$MK_T/install.wim"
printf 'WIM\0' > "$FAKE_WIM_STREAM"
truncate -s 208 "$FAKE_WIM_STREAM"
printf '\x02\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=48 conv=notrunc 2>/dev/null
printf '\xd0\x00\x00\x00\x00\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=76 conv=notrunc 2>/dev/null
printf '\x00\x02\x00\x00\x00\x00\x00\x00' | dd of="$FAKE_WIM_STREAM" bs=1 seek=84 conv=notrunc 2>/dev/null
printf '<WIM><IMAGE INDEX="1"><NAME>Windows 11 Pro</NAME><DISPLAYNAME>Windows 11 Pro</DISPLAYNAME></IMAGE><IMAGE INDEX="2"><NAME>Home</NAME><DISPLAYNAME>Home</DISPLAYNAME></IMAGE></WIM>' | dd of="$FAKE_WIM_STREAM" bs=1 seek=208 conv=notrunc 2>/dev/null

FAKE_ISO="$MK_T/win.iso"
printf 'fakeiso\n' > "$FAKE_ISO"

FULL_MEMBERS="$MK_T/members-full.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FULL_MEMBERS"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$FULL_MEMBERS"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SETUP.EXE;1\n' >> "$FULL_MEMBERS"
FULL_OUT=$(
    FAKE_MEMBERS="$FULL_MEMBERS" FAKE_WIM_STREAM="$FAKE_WIM_STREAM" PATH="$FAKE_BIN:$PATH" \
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "boot+wim valid" "true" "$(echo "$FULL_OUT" | jq -r '.valid' 2>/dev/null || echo false)"
assert_eq "uppercase/;1 normalized -> 2 wim images parsed" "2" "$(echo "$FULL_OUT" | jq -r '.imageCount' 2>/dev/null || echo 0)"

echo "--- setup.exe alone is NOT a boot chain ---"
SETUP_MEMBERS="$MK_T/members-setup.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SETUP.EXE;1\n' > "$SETUP_MEMBERS"
SETUP_OUT=$(
    FAKE_MEMBERS="$SETUP_MEMBERS" FAKE_WIM_STREAM="$FAKE_WIM_STREAM" PATH="$FAKE_BIN:$PATH" \
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "setup.exe alone invalid" "false" "$(echo "$SETUP_OUT" | jq -r '.valid' 2>/dev/null || echo true)"

echo "--- boot chain without install.wim invalid ---"
NOBOOT_MEMBERS="$MK_T/members-noboot.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$NOBOOT_MEMBERS"
NOBOOT_OUT=$(
    FAKE_MEMBERS="$NOBOOT_MEMBERS" FAKE_WIM_STREAM="$FAKE_WIM_STREAM" PATH="$FAKE_BIN:$PATH" \
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "bootmgr without wim invalid" "false" "$(echo "$NOBOOT_OUT" | jq -r '.valid' 2>/dev/null || echo true)"

echo "--- payload only inside ISO: imageCount=0 + payloadNote ---"
NOSTREAM_MEMBERS="$MK_T/members-nostream.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$NOSTREAM_MEMBERS"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$NOSTREAM_MEMBERS"
NOSTREAM_OUT=$(
    FAKE_MEMBERS="$NOSTREAM_MEMBERS" FAKE_WIM_STREAM=/nonexistent/install.wim PATH="$FAKE_BIN:$PATH" \
    bash "$MEDIA_SCRIPT" inspect --iso "$FAKE_ISO" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "structure still valid with unparseable payload" "true" "$(echo "$NOSTREAM_OUT" | jq -r '.valid' 2>/dev/null || echo false)"
assert_eq "imageCount 0 when payload only inside ISO" "0" "$(echo "$NOSTREAM_OUT" | jq -r '.imageCount' 2>/dev/null || echo 1)"
assert_contains "payloadNote present" "$NOSTREAM_OUT" "payload only inside ISO"
rm -rf "$MK_T"

echo ""
echo "=== media-inspect: WIM header stream bounded (no WIM-sized temp files) ==="
MK2_T="$(mktemp -d)"
FAKE2_BIN="$MK2_T/bin"
mkdir -p "$FAKE2_BIN"
cat > "$FAKE2_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE2_BIN/file"
cat > "$FAKE2_BIN/7z" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "l" ]; then
    cat "${FAKE_MEMBERS:-}" 2>/dev/null || true
    exit 0
fi
if [ "$1" = "e" ] && [ "$2" = "-so" ]; then
    cat "${FAKE_WIM_STREAM:-}" 2>/dev/null || true
    exit 0
fi
exit 2
EOF
chmod +x "$FAKE2_BIN/7z"
FAKE2_MEMBERS="$MK2_T/members.txt"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /BOOTMGR;1\n' > "$FAKE2_MEMBERS"
printf -- '-rw-r--r-- 1 user user 1 2020-01-01 00:00 /SOURCES/INSTALL.WIM;1\n' >> "$FAKE2_MEMBERS"
# Fake payload that is far larger than any temp file the bounded reader may
# create: real WIM header + XML (208B + 512B) followed by 60MB of zeros.
BIG_WIM="$MK2_T/install.wim"
printf 'WIM\0' > "$BIG_WIM"
truncate -s 208 "$BIG_WIM"
printf '\x01\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=48 conv=notrunc 2>/dev/null
printf '\xd0\x00\x00\x00\x00\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=76 conv=notrunc 2>/dev/null
printf '\x00\x02\x00\x00\x00\x00\x00\x00' | dd of="$BIG_WIM" bs=1 seek=84 conv=notrunc 2>/dev/null
printf '<WIM><IMAGE INDEX="1"><NAME>Windows 11 Pro</NAME><DISPLAYNAME>Windows 11 Pro</DISPLAYNAME></IMAGE></WIM>' | dd of="$BIG_WIM" bs=1 seek=208 conv=notrunc 2>/dev/null
truncate -s 62914560 "$BIG_WIM"
printf 'fakeiso\n' > "$MK2_T/win.iso"
BIG_OUT=$(
    FAKE_MEMBERS="$FAKE2_MEMBERS" FAKE_WIM_STREAM="$BIG_WIM" PATH="$FAKE2_BIN:$PATH" \
    bash "$MEDIA_SCRIPT" inspect --iso "$MK2_T/win.iso" --json 2>/dev/null || echo '{"valid":false}'
)
assert_eq "imageCount parsed from bounded stream" "1" "$(echo "$BIG_OUT" | jq -r '.imageCount' 2>/dev/null || echo 0)"
BIG_TEMPS=$(find "$MK2_T" -type f -size +1M ! -name 'install.wim' | wc -l)
assert_eq "no temp file of WIM size created" "0" "$BIG_TEMPS"
rm -rf "$MK2_T"

echo ""
echo "=== media-inspect: unreadable listing tool degrades to deterministic JSON ==="
MK3_T="$(mktemp -d)"
FAKE3_BIN="$MK3_T/bin"
mkdir -p "$FAKE3_BIN"
cat > "$FAKE3_BIN/file" <<'EOF'
#!/usr/bin/env bash
echo "ISO 9660 CD-ROM filesystem data (fake for hermetic test)"
EOF
chmod +x "$FAKE3_BIN/file"
# Listing tools that exist but cannot read the medium (rc != 0): the inspect
# must degrade to deterministic JSON instead of aborting under pipefail.
for tool in 7z 7za 7zr bsdtar; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE3_BIN/$tool"
    chmod +x "$FAKE3_BIN/$tool"
done
printf 'fakeiso\n' > "$MK3_T/win.iso"
set +e
NO_TOOL_OUT=$(PATH="$FAKE3_BIN:$PATH" bash "$MEDIA_SCRIPT" inspect --iso "$MK3_T/win.iso" --json 2>/dev/null)
NO_TOOL_RC=$?
set -e
assert_eq "unreadable listing tool: rc 0" "0" "$NO_TOOL_RC"
assert_contains "unreadable listing tool: valid key present" "$NO_TOOL_OUT" '"valid"'
assert_eq "unreadable listing tool: valid false" "false" "$(echo "$NO_TOOL_OUT" | jq -r '.valid' 2>/dev/null || echo true)"
assert_eq "unreadable listing tool: imageCount 0" "0" "$(echo "$NO_TOOL_OUT" | jq -r '.imageCount' 2>/dev/null || echo 1)"
rm -rf "$MK3_T"

echo ""
echo "=== media-inspect: UDF-style listing detection ==="
if command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1; then
    UDF_T="$(mktemp -d)"
    mkdir -p "$UDF_T/tree/sources" "$UDF_T/tree/efi/boot"
    printf 'boot\n' > "$UDF_T/tree/bootmgr"
    printf 'setup\n' > "$UDF_T/tree/setup.exe"
    printf 'wim\n' > "$UDF_T/tree/sources/install.wim"
    printf 'x64\n' > "$UDF_T/tree/efi/boot/bootx64.efi"
    UDF_ISO="$UDF_T/win-udf.iso"
    (cd "$UDF_T/tree" && genisoimage -quiet -udf -o "$UDF_ISO" . 2>/dev/null || mkisofs -quiet -udf -o "$UDF_ISO" . 2>/dev/null) || true
    if [ -f "$UDF_ISO" ]; then
        UDF_OUT=$(bash "$MEDIA_SCRIPT" inspect --iso "$UDF_ISO" --json 2>/dev/null || echo '{"valid":false}')
        assert_eq "UDF fixture detected valid" "true" "$(echo "$UDF_OUT" | jq -r '.valid // false' 2>/dev/null || echo false)"
        assert_eq "UDF fixture uefi boot detected" "1" "$(echo "$UDF_OUT" | jq -r '.uefiBoot // 0' 2>/dev/null || echo 0)"
    else
        echo "  (UDF fixture generation failed; skipped)"
    fi
    rm -rf "$UDF_T"
else
    echo "  (UDF fixture test skipped: genisoimage/mkisofs not installed)"
fi

echo ""
echo "=== results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
