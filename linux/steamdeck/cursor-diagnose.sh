#!/usr/bin/env bash
# cursor-diagnose.sh — read-only record of the Steam Deck pointer handoff.
#
# Game Mode → KDE can hide the cursor. This probe does not know why. It
# records whether the SCController nodes exist, whether the desktop mapper
# unit is active, and whether KWin still exposes the virtual mouse. It does
# not grab the device, restart the mapper, or restart KWin. A snapshot with
# no motion sample is not evidence that events arrive.
set -euo pipefail

usage() {
    printf 'usage: cursor-diagnose.sh (snapshot|sample [seconds])\n' >&2
}

mode="${1:-snapshot}"
case "$mode" in
    snapshot|sample) ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac

sample_seconds=0
if [ "$mode" = "sample" ]; then
    sample_seconds="${2:-${PZ_CURSOR_SAMPLE_SECONDS:-2}}"
fi
case "$sample_seconds" in
    ''|*[!0-9.]*) printf 'invalid sample seconds: %s\n' "$sample_seconds" >&2; exit 2 ;;
esac

devices_file="${PZ_INPUT_DEVICES_FILE:-/proc/bus/input/devices}"
systemctl_bin="${PZ_SYSTEMCTL:-systemctl}"
qdbus_bin="${PZ_QDBUS6:-}"
if [ -z "$qdbus_bin" ] && command -v qdbus6 >/dev/null 2>&1; then
    qdbus_bin="qdbus6"
fi

devices_json='{"sccMouse":{"present":false,"event":null,"name":null},"sccKeyboard":{"present":false,"event":null,"name":null},"externalPointer":{"present":false,"event":null,"name":null}}'
if [ -f "$devices_file" ] && command -v python3 >/dev/null 2>&1; then
    parsed="$(python3 - "$devices_file" <<'PY' || true
import json, sys
path = sys.argv[1]
try:
    text = open(path, encoding="utf-8", errors="replace").read()
except OSError:
    print("{}")
    raise SystemExit(0)

def event_node(handlers):
    for token in handlers:
        if token.startswith("event") and token[5:].isdigit():
            return token
    return None

blocks = []
for raw in text.split("\n\n"):
    name = ""
    handlers = []
    phys = ""
    for line in raw.splitlines():
        if line.startswith("N: Name="):
            name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith("H: Handlers="):
            handlers = line.split("=", 1)[1].split()
        elif line.startswith("P: Phys="):
            phys = line.split("=", 1)[1].strip()
    if name or handlers:
        blocks.append((name, handlers, phys))

def pick(predicate):
    for name, handlers, phys in blocks:
        if predicate(name, handlers, phys):
            return {
                "present": True,
                "event": event_node(handlers),
                "name": name,
            }
    return {"present": False, "event": None, "name": None}

def is_external_pointer(name, handlers, phys):
    # The Deck touchscreen exposes mouseN on i2c. That is not a recovery
    # mouse. SCController Mouse is the mapper under test, not a fallback.
    if name.startswith("SCController"):
        return False
    if phys.startswith("i2c-"):
        return False
    return any(token.startswith("mouse") for token in handlers)

summary = {
    "sccMouse": pick(lambda name, _h, _p: name == "SCController Mouse"),
    "sccKeyboard": pick(lambda name, _h, _p: name == "SCController Keyboard"),
    "externalPointer": pick(is_external_pointer),
}
print(json.dumps(summary))
PY
)"
    if [ -n "$parsed" ]; then
        devices_json="$parsed"
    fi
fi

scc_event="$(jq -r '.sccMouse.event // empty' <<<"$devices_json" 2>/dev/null || true)"

service_active="unknown"
service_nrestarts="null"
if [ -n "$systemctl_bin" ] && { [ "$systemctl_bin" != "systemctl" ] || command -v systemctl >/dev/null 2>&1; }; then
    service_active="$("$systemctl_bin" --user is-active phasezero-controller-desktop 2>/dev/null || true)"
    nrestarts_raw="$("$systemctl_bin" --user show -p NRestarts --value phasezero-controller-desktop 2>/dev/null || true)"
    case "$nrestarts_raw" in
        ''|*[!0-9]*) service_nrestarts="null" ;;
        *) service_nrestarts="$nrestarts_raw" ;;
    esac
fi
[ -n "$service_active" ] || service_active="unknown"

kwin_queried=false
kwin_enabled="null"
kwin_pointer="null"
kwin_error="null"
if [ -n "$scc_event" ] && [ -n "$qdbus_bin" ]; then
    kwin_queried=true
    qdbus_runner=( "$qdbus_bin" )
    if command -v timeout >/dev/null 2>&1; then
        qdbus_runner=(timeout 2 "$qdbus_bin")
    fi
    object="/org/kde/KWin/InputDevice/${scc_event}"
    # qdbus6 does not expose this as a method. The property read is
    # org.freedesktop.DBus.Properties.Get. The method form returns
    # UnknownInterface and used to be stored as query-failed.
    enabled_raw="$("${qdbus_runner[@]}" org.kde.KWin "$object" \
        org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDevice enabled 2>/dev/null | tail -1 || true)"
    pointer_raw="$("${qdbus_runner[@]}" org.kde.KWin "$object" \
        org.freedesktop.DBus.Properties.Get org.kde.KWin.InputDevice pointer 2>/dev/null | tail -1 || true)"
    case "$enabled_raw" in
        true|false) kwin_enabled="$enabled_raw" ;;
        *) kwin_error='"query-failed"' ;;
    esac
    case "$pointer_raw" in
        true|false) kwin_pointer="$pointer_raw" ;;
    esac
elif [ -z "$scc_event" ]; then
    kwin_error='"no-scc-mouse-node"'
else
    kwin_error='"qdbus6-missing"'
fi

sample_ran=false
sample_rel="null"
sample_permission="null"
sample_error="null"
# A zero-length sample must not open the evdev node. The session handoff
# uses snapshot for that reason: opening the node is still shared and
# non-blocking, but it is unnecessary when nobody is moving the pad.
if [ "$mode" = "sample" ] && awk -v s="$sample_seconds" 'BEGIN { exit !(s > 0) }'; then
    sample_ran=true
    event_path="/dev/input/${scc_event}"
    if [ -n "${PZ_CURSOR_EVENT_PATH:-}" ]; then
        event_path="$PZ_CURSOR_EVENT_PATH"
    fi
    if [ -z "$scc_event" ] && [ -z "${PZ_CURSOR_EVENT_PATH:-}" ]; then
        sample_error='"no-scc-mouse-node"'
    elif ! command -v python3 >/dev/null 2>&1; then
        sample_error='"python3-missing"'
    else
        set +e
        sample_out="$(python3 - "$event_path" "$sample_seconds" <<'PY'
import os, select, struct, sys, time
path, seconds = sys.argv[1], float(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
except OSError as exc:
    sys.stdout.write("ERR %s\n" % exc.errno)
    raise SystemExit(13)
fmt = "16xHHi"
size = struct.calcsize(fmt)
count = 0
end = time.monotonic() + seconds
try:
    while time.monotonic() < end:
        remain = end - time.monotonic()
        if remain <= 0:
            break
        ready, _, _ = select.select([fd], [], [], min(0.2, remain))
        if not ready:
            continue
        try:
            data = os.read(fd, size * 32)
        except BlockingIOError:
            continue
        if not data:
            break
        for offset in range(0, len(data) - size + 1, size):
            typ, code, value = struct.unpack_from(fmt, data, offset)
            if typ == 2 and code in (0, 1) and value != 0:
                count += 1
finally:
    os.close(fd)
print(count)
PY
)"
        sample_rc=$?
        set -e
        if [ "$sample_rc" -eq 0 ] && case "$sample_out" in ''|*[!0-9]*) false ;; *) true ;; esac; then
            sample_rel="$sample_out"
        elif [ "$sample_rc" -eq 13 ]; then
            case "$sample_out" in
                "ERR 13"|"ERR 1") sample_permission='"denied"' ;;
                "ERR 2") sample_permission='"missing"' ;;
                *) sample_permission='"open-failed"' ;;
            esac
            sample_error='"open-failed"'
        else
            sample_error='"sample-failed"'
        fi
    fi
fi

conclusion="not-proven"
if [ "$sample_rel" != null ] && [ "$sample_rel" -gt 0 ] 2>/dev/null && [ "$kwin_enabled" = true ]; then
    conclusion="rel-events-and-kwin-enabled"
fi

session_id="${XDG_SESSION_ID:-}"
session_desktop="${XDG_CURRENT_DESKTOP:-}"
session_type="${XDG_SESSION_TYPE:-}"
session_wayland="${WAYLAND_DISPLAY:-}"

jq -n \
    --arg at "$(date -Iseconds)" \
    --arg mode "$mode" \
    --arg conclusion "$conclusion" \
    --arg serviceActive "$service_active" \
    --arg sessionId "$session_id" \
    --arg sessionDesktop "$session_desktop" \
    --arg sessionType "$session_type" \
    --arg sessionWayland "$session_wayland" \
    --argjson sampleSeconds "$sample_seconds" \
    --argjson serviceNRestarts "$service_nrestarts" \
    --argjson devices "$devices_json" \
    --argjson kwinQueried "$kwin_queried" \
    --argjson kwinEnabled "$kwin_enabled" \
    --argjson kwinPointer "$kwin_pointer" \
    --argjson kwinError "$kwin_error" \
    --argjson sampleRan "$sample_ran" \
    --argjson sampleRel "$sample_rel" \
    --argjson samplePermission "$sample_permission" \
    --argjson sampleError "$sample_error" \
    '{
        schema: 1,
        at: $at,
        mode: $mode,
        mutated: false,
        grabbed: false,
        serviceRestarted: false,
        conclusion: $conclusion,
        session: {
            id: (if $sessionId == "" then null else $sessionId end),
            desktop: (if $sessionDesktop == "" then null else $sessionDesktop end),
            type: (if $sessionType == "" then null else $sessionType end),
            wayland: (if $sessionWayland == "" then null else $sessionWayland end)
        },
        controllerService: {
            name: "phasezero-controller-desktop",
            active: $serviceActive,
            nRestarts: $serviceNRestarts
        },
        devices: $devices,
        kwin: {
            queried: $kwinQueried,
            mouseEnabled: $kwinEnabled,
            mousePointer: $kwinPointer,
            error: $kwinError
        },
        sample: {
            seconds: $sampleSeconds,
            ran: $sampleRan,
            relEvents: $sampleRel,
            permission: $samplePermission,
            error: $sampleError
        }
    }'
