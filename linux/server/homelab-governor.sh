#!/usr/bin/env bash
# homelab-governor.sh - resource governor for the PhaseZero homelab appliance.
#
# Reads the profile registry (assets/home-server/homelab-profiles.json) and
# computes a memory budget for a profile against available RAM. The verdict
# fails closed: any unknown profile, unreadable registry, or overcommit means
# the check returns non-zero so bring-up can gate on it.
#
# RAM is read from /proc/meminfo unless PZ_HOMELAB_RAM_TOTAL_OVERRIDE (MiB) is
# set, which keeps hermetically-testable environments deterministic.
#
#   homelab-governor.sh list
#   homelab-governor.sh weights [--json]
#   homelab-governor.sh budget <profile> [--headroom PCT]
#   homelab-governor.sh check <profile> [--headroom PCT]
#   homelab-governor.sh winvm-status
#   homelab-governor.sh winvm-suspend [--dry-run]
#   homelab-governor.sh winvm-resume
#
# WinVM contract (Fase 4): the governor never touches WinVM processes. It reads
# the guest state through ONE boundary -- PZ_HOMELAB_WINVM_STATUS_FILE or
# `pz windows-vm status --json` -- and suspends only through a graceful QGA
# command (PZ_HOMELAB_WINVM_SUSPEND_CMD, default `pz windows-vm guest-login
# shutdown --json`). A silent kill is never used; every suspend path records
# `killUsed:"never"`. No WinVM file is modified from here.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

COMPOSE_DIR="${PZ_HOMELAB_COMPOSE_DIR:-$PZ_ROOT/assets/home-server}"
REGISTRY_FILE="${PZ_HOMELAB_PROFILES_FILE:-$COMPOSE_DIR/homelab-profiles.json}"

SCHEMA_VERSION="1"

# pz_governor_registry -> registry JSON (fails closed on missing/invalid)
pz_governor_registry() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        pz_error "profile registry missing: $REGISTRY_FILE"
        return 2
    fi
    if ! jq -e '.schemaVersion == 1 and (.profiles | type == "array")' "$REGISTRY_FILE" >/dev/null 2>&1; then
        pz_error "profile registry invalid: $REGISTRY_FILE"
        return 2
    fi
    cat "$REGISTRY_FILE"
}

pz_governor_available_mb() {
    # PZ-AUD-031: MemAvailable via the shared helper (override = test seam).
    pz_mem_available_mb
}

# pz_governor_winvm_status -> 'active' | 'idle' | 'unknown'
pz_governor_winvm_status() {
    local file="${PZ_HOMELAB_WINVM_STATUS_FILE:-}" json=""
    if [ -n "$file" ] && [ -f "$file" ]; then
        json="$(cat "$file" 2>/dev/null || true)"
    elif command -v pz >/dev/null 2>&1; then
        json="$(pz windows-vm status --json 2>/dev/null || true)"
    else
        printf 'unknown\n'
        return 0
    fi
    [ -n "$json" ] || { printf 'unknown\n'; return 0; }
    if printf '%s\n' "$json" | \
        jq -e '(.libvirtState? == "running") or (.currentMarker? == "yes") or (.bootRuntimeStale? == true)' \
        >/dev/null 2>&1; then
        printf 'active\n'
    else
        printf 'idle\n'
    fi
}

pz_governor_winvm_mb() {
    local reg
    reg="$(pz_governor_registry)" || return $?
    jq -r '.winvmMB? // 2048' <<< "$reg"
}

pz_governor_winvm_status_json() {
    local st mb
    st="$(pz_governor_winvm_status)"
    if ! mb="$(pz_governor_winvm_mb)"; then
        # Unconfigured budget is a reportable state, not a tool failure.
        jq -cn --argjson schemaVersion "$SCHEMA_VERSION" --arg status "$st" \
            '{schemaVersion:$schemaVersion, tool:"homelab-governor", action:"winvm-status",
              status:$status, active:false, weightMB:null, state:"needs-config",
              summary:"Nenhum orcamento WinVM configurado no governador.",
              nextAction:"linux/pz server homelab profile set <perfil>"}'
        return 0
    fi
jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg status "$st" \
        --argjson active "$([ "$st" = "active" ] && echo true || echo false)" \
        --argjson weightMB "$mb" \
        --arg probe "${PZ_HOMELAB_WINVM_STATUS_FILE:-pz windows-vm status --json}" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", action:"winvm-status",
         status:$status, active:$active, weightMB:$weightMB, probe:$probe}'
}

# pz_governor_winvm_suspend <dry-run> -- graceful QGA shutdown, never a kill.
pz_governor_winvm_suspend() {
    local dry="${1:-0}"
    local cmd="${PZ_HOMELAB_WINVM_SUSPEND_CMD:-pz windows-vm guest-login shutdown --json}"
    local st
    st="$(pz_governor_winvm_status)"
    if [ "$st" != "active" ]; then
        jq -cn --arg method "graceful-qga" --arg status "$st" \
            '{action:"winvm-suspend", winvmSuspendRequested:false, method:$method, status:$status, killUsed:"never"}'
        return 0
    fi
    if [ "$dry" = "1" ]; then
        jq -cn --arg method "graceful-qga" --arg cmd "$cmd" \
            '{action:"winvm-suspend", winvmSuspendRequested:true, method:$method, command:$cmd,
              dryRun:true, applied:false, killUsed:"never"}'
        return 0
    fi
    if ! bash -c "$cmd" >/dev/null 2>&1; then
        jq -cn --arg method "graceful-qga" --arg cmd "$cmd" \
            '{action:"winvm-suspend", winvmSuspendRequested:true, method:$method, command:$cmd,
              dryRun:false, applied:false, error:"graceful suspend command failed", killUsed:"never"}'
        return 1
    fi
    jq -cn --arg method "graceful-qga" --arg cmd "$cmd" \
        '{action:"winvm-suspend", winvmSuspendRequested:true, method:$method, command:$cmd,
          dryRun:false, applied:true, killUsed:"never"}'
}

pz_governor_winvm_resume_check() {
    local st
    st="$(pz_governor_winvm_status)"
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg status "$st" \
        --argjson released "$([ "$st" != "active" ] && echo true || echo false)" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", action:"winvm-resume",
          winvmReleased:$released, status:$status}'
}

# pz_governor_budget <profile> [headroom] -> budget JSON
pz_governor_budget() {
    local profile="${1:?profile required}" headroom="${2:-20}"
    local reg base used=0 total available verdict reasons="[]"
    local winvm_st winvm_mb=0 winvm_active=false
    reg="$(pz_governor_registry)" || return $?
    if ! jq -e --arg k "$profile" '[.profiles[].key] | index($k) != null' <<< "$reg" >/dev/null 2>&1; then
        pz_error "unknown homelab profile: $profile"
        return 2
    fi
    base="$(jq -r '.coreBaseMB' <<< "$reg")"
    used="$(jq -r --arg k "$profile" \
        '(.weightsMB) as $w | [.profiles[] | select(.key == $k) | .services[] as $s | $w[$s] // 0] | add // 0' \
        <<< "$reg")"
    total=$((base + used))
    available="$(pz_governor_available_mb)" || return $?
    local usable=$(( available - available * headroom / 100 ))
    winvm_st="$(pz_governor_winvm_status)"
    if [ "$winvm_st" = "active" ]; then
        winvm_active=true
        winvm_mb="$(pz_governor_winvm_mb)" || return $?
        usable=$((usable - winvm_mb))
        [ "$usable" -lt 0 ] && usable=0
    fi
    if [ "$total" -le "$usable" ]; then
        verdict="pass"
    else
        verdict="fail"
    fi
    local over_message="profile overcommits memory: budget ${total} MiB > usable ${usable} MiB (headroom ${headroom}%)"
    local winvm_reason=""
    if [ "$winvm_active" = "true" ]; then
        winvm_reason="winvm active: guest reserved ${winvm_mb} MiB; no silent kill, graceful stop via governor winvm-suspend"
    fi
    if [ "$verdict" = "fail" ] || [ -n "$winvm_reason" ]; then
        reasons="$(jq -cn --arg m "$over_message" --arg w "$winvm_reason" \
            'if $w == "" then [$m] else [$m, $w] end')"
    fi
    local title total_mb disk_mb
    title="$(jq -r --arg k "$profile" '[.profiles[] | select(.key == $k) | .title] | .[0]' <<< "$reg")"
    total_mb="$(pz_mem_total_mb 2>/dev/null || printf 'null')"
    disk_mb="$(pz_disk_available_mb "${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}" 2>/dev/null || printf 'null')"
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg tool "homelab-governor" \
        --arg profile "$profile" \
        --arg profileTitle "$title" \
        --argjson coreBaseMB "$base" \
        --argjson serviceMB "$used" \
        --argjson budgetMB "$total" \
        --argjson availableMB "$available" \
        --argjson totalMB "${total_mb:-null}" \
        --argjson diskAvailableMB "${disk_mb:-null}" \
        --argjson headroomPct "$headroom" \
        --argjson winvmActive "$winvm_active" \
        --argjson winvmWeightMB "$winvm_mb" \
        --arg verdict "$verdict" \
        --argjson reasons "$reasons" \
        '{schemaVersion:$schemaVersion, tool:$tool, profile:$profile, profileTitle:$profileTitle,
          coreBaseMB:$coreBaseMB, serviceMB:$serviceMB, budgetMB:$budgetMB,
          availableMB:$availableMB, totalMB:$totalMB, diskAvailableMB:$diskAvailableMB,
          headroomPct:$headroomPct,
          winvmActive:$winvmActive, winvmWeightMB:$winvmWeightMB, verdict:$verdict, reasons:$reasons}'
}

pz_governor_list_json() {
    local reg
    reg="$(pz_governor_registry)" || return $?
    local def
    def="$(jq -r '.default' <<< "$reg")"
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg default "$def" \
        --argjson profiles "$(jq -c '[.profiles[] | {key, title, description, class, maturity, installable, installNote, extras, services}]' <<< "$reg")" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", default:$default, profiles:$profiles}'
}

pz_governor_weights_json() {
    local reg
    reg="$(pz_governor_registry)" || return $?
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --argjson weights "$(jq -c '.weightsMB' <<< "$reg")" \
        '{schemaVersion:$schemaVersion, tool:"homelab-governor", weightsMB:$weights}'
}

main() {
    local cmd="${1:-list}"
    shift 2>/dev/null || true
    case "$cmd" in
        list)
            pz_governor_list_json
            ;;
        weights)
            pz_governor_weights_json
            ;;
        budget)
            local profile="${1:-}" headroom="${2:-}"
            [ -n "$profile" ] || { pz_error "budget requires a profile"; return 2; }
            if [ -n "$headroom" ]; then
                pz_governor_budget "$profile" "$headroom"
            else
                pz_governor_budget "$profile"
            fi
            ;;
        budget-active)
            # CCS-014: o orçamento mostrado na Central é sempre de um perfil
            # real do registro (o ativo), nunca uma chave interna como "core".
            local active headroom="${1:-}"
            local state_dir="${PZ_HOMELAB_STATE:-$PZ_STATE/homelab}"
            active="$(cat "$state_dir/profile.active" 2>/dev/null || true)"
            if [ -z "$active" ]; then
                jq -cn --arg msg "nenhum perfil appliance ativo; defina com: pz server homelab profile set <key>" \
                    --argjson keys "$(pz_governor_registry | jq -c '[.profiles[].key]')" \
                    '{error:"no-active-profile", message:$msg, profiles:$keys}'
                return 3
            fi
            if [ -n "$headroom" ]; then
                pz_governor_budget "$active" "$headroom"
            else
                pz_governor_budget "$active"
            fi
            ;;
        check)
            local profile="${1:-}" headroom="${2:-}"
            [ -n "$profile" ] || { pz_error "check requires a profile"; return 2; }
            local out
            if [ -n "$headroom" ]; then
                out="$(pz_governor_budget "$profile" "$headroom")" || return $?
            else
                out="$(pz_governor_budget "$profile")" || return $?
            fi
            printf '%s\n' "$out"
            [ "$(printf '%s\n' "$out" | jq -r '.verdict')" = "pass" ]
            ;;
        winvm-status)
            pz_governor_winvm_status_json
            ;;
        winvm-suspend)
            local dry=0 a
            for a in "$@"; do [ "$a" = "--dry-run" ] && dry=1; done
            pz_governor_winvm_suspend "$dry"
            ;;
        winvm-resume)
            pz_governor_winvm_resume_check
            ;;
        *)
            echo "usage: homelab-governor.sh (list|weights|budget <profile>|check <profile>|winvm-status|winvm-suspend [--dry-run]|winvm-resume) [--headroom PCT]" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi