#!/usr/bin/env bash
# homelab-host-facts.sh — read-only SMART/network/disk/temperature.
#
# JSON on stdout. Never invents a sensor reading. Missing tools become
# available:false + reason, never a fabricated PASS or temperature.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

SCHEMA_VERSION="1"
SMART_BIN="${PZ_HOMELAB_SMARTCTL:-smartctl}"
IP_BIN="${PZ_HOMELAB_IP:-ip}"
DF_BIN="${PZ_HOMELAB_DF:-df}"
SENSORS_BIN="${PZ_HOMELAB_SENSORS:-sensors}"
THERMAL_DIR="${PZ_HOMELAB_THERMAL_DIR:-/sys/class/thermal}"

tool_path() {
    local name="$1"
    if [ -n "$name" ] && command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

smart_facts() {
    local bin
    if ! bin="$(tool_path "$SMART_BIN")"; then
        jq -nc '{available:false, reason:"smartctl ausente", devices:[]}'
        return 0
    fi
    local scan=""
    scan="$("$bin" --scan 2>/dev/null || true)"
    if [ -z "$scan" ]; then
        jq -nc --arg reason "smartctl sem dispositivos (ou sem permissão)" \
            '{available:false, reason:$reason, devices:[]}'
        return 0
    fi
    local devices='[]' line dev health
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        dev="${line%% *}"
        [ -n "$dev" ] || continue
        health="$("$bin" -H "$dev" 2>/dev/null | awk -F: '/SMART overall-health|SMART Health Status/{gsub(/^ +/,"",$2); print $2; exit}')"
        if [ -z "$health" ]; then
            devices="$(jq -c --arg dev "$dev" '. + [{device:$dev, health:null, available:false, reason:"indisponível"}]' <<< "$devices")"
        else
            devices="$(jq -c --arg dev "$dev" --arg health "$health" \
                '. + [{device:$dev, health:$health, available:true, reason:null}]' <<< "$devices")"
        fi
    done <<< "$scan"
    jq -nc --argjson devices "$devices" '{available:true, reason:null, devices:$devices}'
}

network_facts() {
    local host
    host="$(hostname -s 2>/dev/null || uname -n 2>/dev/null || true)"
    if [ -z "$host" ]; then
        host=""
    fi
    local bin iface_json='[]' reason=""
    if bin="$(tool_path "$IP_BIN")"; then
        iface_json="$("$bin" -4 -json addr 2>/dev/null || echo '[]')"
        if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$iface_json"; then
            iface_json='[]'
            reason="ip -json indisponível"
        fi
    else
        reason="ip ausente"
    fi
    jq -nc --arg hostname "$host" --argjson interfaces "$iface_json" --arg reason "$reason" \
        '{hostname:(if $hostname == "" then null else $hostname end),
          interfaces:$interfaces,
          available:($hostname != "" or ($interfaces | length) > 0),
          reason:(if $reason == "" then null else $reason end)}'
}

disk_facts() {
    local bin
    if ! bin="$(tool_path "$DF_BIN")"; then
        jq -nc '{available:false, reason:"df ausente", volumes:[]}'
        return 0
    fi
    local volumes='[]' line total used mount
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        total="$(awk '{print $2}' <<< "$line")"
        used="$(awk '{print $3}' <<< "$line")"
        mount="$(awk '{print $6}' <<< "$line")"
        case "$total" in
            ''|*[!0-9]*) continue ;;
        esac
        volumes="$(jq -c --arg mount "$mount" --argjson total "$total" --argjson used "$used" \
            '. + [{mount:$mount, totalBytes:$total, usedBytes:$used}]' <<< "$volumes")"
    done < <("$bin" -B1 -P / 2>/dev/null | awk 'NR>1 {print}')
    if [ "$(jq -r 'length' <<< "$volumes")" = "0" ]; then
        jq -nc '{available:false, reason:"df sem volumes", volumes:[]}'
        return 0
    fi
    jq -nc --argjson volumes "$volumes" '{available:true, reason:null, volumes:$volumes}'
}

temperature_facts() {
    local zone temp_raw milli type_name
    if [ -d "$THERMAL_DIR" ]; then
        for zone in "$THERMAL_DIR"/thermal_zone*; do
            [ -e "$zone/temp" ] || continue
            temp_raw="$(cat "$zone/temp" 2>/dev/null || true)"
            case "$temp_raw" in
                ''|*[!0-9-]*) continue ;;
            esac
            milli="$temp_raw"
            type_name="$(cat "$zone/type" 2>/dev/null || echo unknown)"
            jq -nc --arg source "$type_name" --argjson milli "$milli" \
                '{available:true, reason:null, celsius:($milli / 1000), source:$source}'
            return 0
        done
    fi
    local bin out
    if bin="$(tool_path "$SENSORS_BIN")"; then
        out="$("$bin" -u 2>/dev/null || true)"
        if [ -n "$out" ]; then
            jq -nc --arg reason "sensors presente mas sem temperatura parseável" \
                '{available:false, reason:$reason, celsius:null, source:null}'
            return 0
        fi
    fi
    jq -nc '{available:false, reason:"sensors ausente", celsius:null, source:null}'
}

smart_json="$(smart_facts)"
net_json="$(network_facts)"
disk_json="$(disk_facts)"
temp_json="$(temperature_facts)"

jq -nc --arg schemaVersion "$SCHEMA_VERSION" \
    --argjson smart "$smart_json" \
    --argjson network "$net_json" \
    --argjson disk "$disk_json" \
    --argjson temperature "$temp_json" \
    '{schemaVersion:$schemaVersion, tool:"homelab-host-facts",
      smart:$smart, network:$network, disk:$disk, temperature:$temperature}'
