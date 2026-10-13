#!/usr/bin/env bash
set -euo pipefail

KVM_DEVICE="${PZ_KVM_DEVICE:-/dev/kvm}"
if [[ ! -c "$KVM_DEVICE" || ! -r "$KVM_DEVICE" || ! -w "$KVM_DEVICE" ]]; then
    echo "SKIP: no usable KVM device at $KVM_DEVICE; guest probe unavailable, not G2 evidence"
    exit 0
fi
command -v qemu-system-x86_64 >/dev/null || {
    echo "FAIL: qemu-system-x86_64 missing" >&2
    exit 1
}

PROBE_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pz-kvm-probe.XXXXXX")"
QMP_SOCKET="$PROBE_ROOT/qmp.sock"
QEMU_PID=""

cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    rm -rf -- "$PROBE_ROOT"
}
trap cleanup EXIT

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -m 128 \
    -nodefaults \
    -display none \
    -S \
    -qmp "unix:$QMP_SOCKET,server=on,wait=off" &
QEMU_PID=$!

for _ in $(seq 1 50); do
    [[ -S "$QMP_SOCKET" ]] && break
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        wait "$QEMU_PID" || true
        echo "FAIL: QEMU exited before opening QMP socket" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -S "$QMP_SOCKET" ]] || {
    echo "FAIL: QEMU did not open QMP socket" >&2
    exit 1
}

python3 - "$QMP_SOCKET" <<'PY'
import json
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as qmp:
    qmp.settimeout(3)
    qmp.connect(sys.argv[1])
    stream = qmp.makefile("rwb")
    greeting = json.loads(stream.readline())
    if "QMP" not in greeting:
        raise SystemExit("FAIL: invalid QMP greeting")

    def command(name):
        stream.write(json.dumps({"execute": name}).encode() + b"\r\n")
        stream.flush()
        while True:
            message = json.loads(stream.readline())
            if "event" in message:
                continue
            if "error" in message:
                raise SystemExit(f"FAIL: QMP {name} rejected: {message}")
            return message

    capabilities = command("qmp_capabilities")
    if capabilities.get("return") != {}:
        raise SystemExit(f"FAIL: QMP capabilities rejected: {capabilities}")
    kvm = command("query-kvm").get("return", {})
    if kvm.get("present") is not True or kvm.get("enabled") is not True:
        raise SystemExit(f"FAIL: QEMU did not enable KVM: {kvm}")
    command("quit")
PY

wait "$QEMU_PID"
QEMU_PID=""
echo "hosted QEMU/KVM empty-guest probe passed; this is not G2 evidence"
