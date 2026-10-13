#!/usr/bin/env bash
# ai-policy-broker.sh - policy broker for AI agent installs and model pulls.
#
# Default mode is "conservative": high-mutability actions (large model pulls,
# versionless installs, unchecksummed remote installers) are denied unless the
# operator opts in. Mode is persisted in state (ai/policy.json) and can be
# overridden per invocation with PZ_AI_POLICY_MODE for hermetic tests.
#
#   ai-policy-broker.sh status [--json]
#   ai-policy-broker.sh set <mode>
#   ai-policy-broker.sh check <action> [key=value ...]
#   ai-policy-broker.sh list
#
# Actions:
#   ollama-pull          pulling a large model into a running Ollama
#   openclaw-install     npm global install of OpenClaw
#   ai-memory-install    docker wrapper install for ai-memory
#   hermes-install       remote install.sh execution
#   codex-install        npm global install of OpenAI Codex CLI
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=linux/lib/common.sh
source "$PZ_ROOT/linux/lib/common.sh"

AI_STATE="${PZ_AI_STATE:-$PZ_STATE/ai}"
POLICY_FILE="$AI_STATE/policy.json"

SCHEMA_VERSION="1"

pz_policy_defaults() {
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        '{schemaVersion:$schemaVersion, mode:"conservative", updatedAt:null}'
}

pz_policy_read() {
    if [ -f "$POLICY_FILE" ] && jq -e '.schemaVersion == 1 and (.mode == "conservative" or .mode == "permissive")' "$POLICY_FILE" >/dev/null 2>&1; then
        cat "$POLICY_FILE"
    else
        pz_policy_defaults
    fi
}

pz_policy_mode() {
    if [ -n "${PZ_AI_POLICY_MODE:-}" ]; then
        printf '%s\n' "$PZ_AI_POLICY_MODE"
        return 0
    fi
    jq -r '.mode' <<< "$(pz_policy_read)"
}

# pz_policy_check <action> [k=v ...] -> JSON {allow, mode, action, reasons[]}
# Hints recognized: version=<pin> checksum=<sha256> explicit=1
pz_policy_check() {
    local action="${1:?action required}" mode version="" checksum="" explicit=0
    shift
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        case "$k" in
            version) version="$v" ;;
            checksum) checksum="$v" ;;
            explicit) [ "$v" = "1" ] && explicit=1 || explicit=0 ;;
            *) ;;
        esac
    done
    mode="$(pz_policy_mode)"
    local -a reasons=()
    local allow=true
    case "$mode:$action" in
        conservative:ollama-pull)
            if [ "$explicit" = "1" ]; then
                reasons+=("explicit opt-in pull under conservative policy")
            else
                allow=false
                reasons+=("conservative policy denies automatic model pulls; pass explicit=1 to opt in")
            fi
            ;;
        conservative:openclaw-install)
            if [ -n "$version" ] && [ "$version" != "latest" ]; then
                reasons+=("pinned version $version under conservative policy")
            else
                allow=false
                reasons+=("conservative policy denies versionless OpenClaw install; supply version=<pin>")
            fi
            ;;
        conservative:hermes-install)
            if [ -n "$checksum" ] && [ "${#checksum}" -eq 64 ]; then
                reasons+=("pinned sha256 checksum under conservative policy")
            else
                allow=false
                reasons+=("conservative policy denies remote installer without pinned sha256 checksum")
            fi
            ;;
        conservative:ai-memory-install|conservative:codex-install)
            allow=true
            ;;
        permissive:*)
            allow=true
            ;;
        *)
            allow=false
            reasons+=("unknown action: $action")
            ;;
    esac
    local reasons_json
    if [ "${#reasons[@]}" -gt 0 ]; then
        reasons_json="$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -cs .)"
    else
        reasons_json='[]'
    fi
    jq -cn --arg action "$action" --arg mode "$mode" --argjson allow "$allow" \
        --argjson reasons "$reasons_json" \
        '{schemaVersion:'"$SCHEMA_VERSION"', action:$action, mode:$mode, allow:$allow, reasons:$reasons,
          scope:"install-policy",
          executionEnforced:false,
          note:"this broker gates installs/pulls only; runtime tool execution is bounded by the caller allowlist (agent), never by this verdict"}'
}

pz_policy_status_json() {
    local mode
    mode="$(pz_policy_mode)"
    local actions_json='[]'
    [ "$mode" = "conservative" ] && actions_json='["ollama-pull","openclaw-install","hermes-install"]'
    jq -cn --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg mode "$mode" \
        --argjson conservative "$([ "$mode" = "conservative" ] && echo true || echo false)" \
        --argjson actions "$actions_json" \
        '{schemaVersion:$schemaVersion, tool:"ai-policy-broker", mode:$mode, conservative:$conservative,
          deniedActions:$actions, scope:"install-policy", executionEnforced:false}'
}

pz_policy_set() {
    local mode="${1:-}"
    case "$mode" in
        conservative|permissive) ;;
        *) pz_error "invalid policy mode: $mode (conservative|permissive)"; return 2 ;;
    esac
    mkdir -p "$AI_STATE"
    jq -cn --arg mode "$mode" --argjson schemaVersion "$SCHEMA_VERSION" \
        --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schemaVersion:$schemaVersion, mode:$mode, updatedAt:$updatedAt}' > "$POLICY_FILE"
    jq -n --arg mode "$mode" '{action:"policy-set", mode:$mode, ok:true}'
}

main() {
    local cmd="${1:-status}"
    shift 2>/dev/null || true
    case "$cmd" in
        status) pz_policy_status_json ;;
        set) pz_policy_set "${1:-}" ;;
        check) pz_policy_check "$@" ;;
        list)
            jq -cn --argjson actions '["ollama-pull","openclaw-install","ai-memory-install","hermes-install","codex-install"]' \
                '{schemaVersion:'"$SCHEMA_VERSION"', actions:$actions, scope:"install-policy", executionEnforced:false}'
            ;;
        *) echo "usage: ai-policy-broker.sh (status|set <mode>|check <action>|list)" >&2; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi