#!/usr/bin/env bash
# Read-only, secret-redacted readiness audit for Hermes and Odysseus.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-doctor}"
PROFILE="${PZ_AGENT_WORKSPACES_PROFILE:-assistant-private}"
HERMES_MANAGER="${PZ_HERMES_MANAGER:-$PZ_ROOT/linux/ai/setup-hermes.sh}"
ODYSSEUS_MANAGER="${PZ_ODYSSEUS_MANAGER:-$PZ_ROOT/linux/ai/odysseus-manager.sh}"
ROUTER_MANAGER="${PZ_9ROUTER_MANAGER:-$PZ_ROOT/linux/ai/9router-manager.sh}"
GOVERNOR="${PZ_HOMELAB_GOVERNOR:-$PZ_ROOT/linux/server/homelab-governor.sh}"
POLICY_BROKER="${PZ_AI_POLICY_BROKER:-$PZ_ROOT/linux/server/ai-policy-broker.sh}"
PROFILES="${PZ_HOMELAB_PROFILES_FILE:-$PZ_ROOT/assets/home-server/homelab-profiles.json}"
PROBE_TIMEOUT="${PZ_AGENT_DIAGNOSTIC_TIMEOUT:-45}"

json_probe() {
    local fallback="$1"
    shift
    local output=""
    output="$(timeout "$PROBE_TIMEOUT" "$@" 2>/dev/null || true)"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<< "$output"; then
        printf '%s\n' "$output"
    else
        printf '%s\n' "$fallback"
    fi
}

command_present() {
    command -v "$1" >/dev/null 2>&1
}

ollama_json() {
    local installed=false healthy=false version=""
    command_present ollama && installed=true
    if [ "$installed" = true ]; then
        version="$(timeout 5 ollama --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    fi
    curl -fsS --max-time 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && healthy=true
    jq -cn --argjson installed "$installed" --argjson healthy "$healthy" --arg version "$version" \
        '{installed:$installed,healthy:$healthy,version:$version,endpoint:"http://127.0.0.1:11434",secretsRedacted:true}'
}

memory_json() {
    local docker_available=false running=false healthy=false count=0
    command_present docker && docker_available=true
    if [ "$docker_available" = true ] && docker info >/dev/null 2>&1; then
        count="$(docker ps --format '{{.Image}}|{{.Status}}' 2>/dev/null |
            awk -F'|' 'tolower($1) ~ /ai-memory/ {count++; if (tolower($2) ~ /healthy/) healthy=1} END {print count+0 ":" healthy+0}')"
        [ "${count%%:*}" -gt 0 ] && running=true
        [ "${count##*:}" -eq 1 ] && healthy=true
        count="${count%%:*}"
    else
        count=0
    fi
    jq -cn --argjson dockerAvailable "$docker_available" --argjson running "$running" \
        --argjson healthy "$healthy" --argjson count "$count" \
        '{dockerAvailable:$dockerAvailable,running:$running,healthy:$healthy,matchingContainers:$count,secretsRedacted:true}'
}

port_json() {
    local port="$1" listening=false
    ss -ltnH 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$") {found=1} END {exit(found ? 0 : 1)}' && listening=true
    jq -cn --argjson port "$port" --argjson listening "$listening" \
        '{port:$port,listening:$listening,ownerRedacted:true}'
}

profile_json() {
    if [ -f "$PROFILES" ]; then
        jq -c --arg profile "$PROFILE" \
            '{schemaVersion,profile:([.profiles[] | select(.key == $profile)] | .[0] // null)}' "$PROFILES" 2>/dev/null ||
            printf '%s\n' '{"schemaVersion":1,"profile":null}'
    else
        printf '%s\n' '{"schemaVersion":1,"profile":null}'
    fi
}

emit_diagnostic() {
    local hermes odysseus hermes_plan='null' odysseus_plan='null' router policy budget profile ollama memory port7000
    local roadmap_blocked=true tailscale_installed=false tailscale_authenticated=false
    local podman_installed=false podman_rootless=false
    hermes="$(json_probe '{"schemaVersion":1,"id":"hermes","diagnosticComplete":false,"ready":false,"issues":[{"severity":"error","code":"hermes-probe-failed"}],"secretsRedacted":true}' bash "$HERMES_MANAGER" doctor)"
    odysseus="$(json_probe '{"schemaVersion":1,"id":"odysseus","diagnosticComplete":false,"secure":false,"issues":[{"severity":"error","code":"odysseus-probe-failed"}],"secretsRedacted":true}' bash "$ODYSSEUS_MANAGER" doctor)"
    if [ "$ACTION" = plan ]; then
        hermes_plan="$(json_probe '{"schemaVersion":1,"id":"hermes","mode":"read-only-plan","deploymentAllowed":false,"blockers":["plan-probe-failed"],"secretsRedacted":true}' bash "$HERMES_MANAGER" plan)"
        odysseus_plan="$(json_probe '{"schemaVersion":1,"id":"odysseus","mode":"read-only-plan","deploymentAllowed":false,"blockers":["plan-probe-failed"],"secretsRedacted":true}' bash "$ODYSSEUS_MANAGER" plan)"
    fi
    router="$(json_probe '{"schemaVersion":1,"installed":false,"healthy":false,"secretsRedacted":true}' bash "$ROUTER_MANAGER" status)"
    policy="$(json_probe '{"schemaVersion":1,"mode":"unknown","conservative":true,"deniedActions":[]}' bash "$POLICY_BROKER" status)"
    budget="$(json_probe '{"schemaVersion":1,"profile":"assistant-private","verdict":"unknown","reasons":["budget probe failed"]}' bash "$GOVERNOR" budget "$PROFILE")"
    profile="$(profile_json)"
    ollama="$(ollama_json)"
    memory="$(memory_json)"
    port7000="$(port_json 7000)"
    command_present tailscale && tailscale_installed=true
    [ "$tailscale_installed" = true ] && tailscale status >/dev/null 2>&1 && tailscale_authenticated=true
    command_present podman && podman_installed=true
    if [ "$podman_installed" = true ] && [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo false)" = true ]; then
        podman_rootless=true
    fi
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && roadmap_blocked=false

    jq -cn \
        --arg action "$ACTION" --arg profileId "$PROFILE" --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson hermes "$hermes" --argjson odysseus "$odysseus" --argjson hermesPlan "$hermes_plan" \
        --argjson odysseusPlan "$odysseus_plan" --argjson router "$router" \
        --argjson policy "$policy" --argjson budget "$budget" --argjson profile "$profile" \
        --argjson ollama "$ollama" --argjson memory "$memory" --argjson port7000 "$port7000" \
        --argjson roadmapBlocked "$roadmap_blocked" --argjson tailscaleInstalled "$tailscale_installed" \
        --argjson tailscaleAuthenticated "$tailscale_authenticated" --argjson podmanInstalled "$podman_installed" \
        --argjson podmanRootless "$podman_rootless" \
        '{schemaVersion:1,tool:"agent-workspaces-diagnostic",action:$action,checkedAt:$checkedAt,
          mode:"read-only",diagnosticComplete:($hermes.diagnosticComplete == true and $odysseus.diagnosticComplete == true),
          deploymentAllowed:($roadmapBlocked|not),profileId:$profileId,profile:$profile.profile,
          components:{hermes:$hermes,odysseus:$odysseus,router:$router,ollama:$ollama,aiMemory:$memory},
          componentPlans:{hermes:$hermesPlan,odysseus:$odysseusPlan},
          runtime:{podman:{installed:$podmanInstalled,rootless:$podmanRootless},
            tailscale:{installed:$tailscaleInstalled,authenticated:$tailscaleAuthenticated},ports:{odysseus:$port7000}},
          policy:$policy,resourceBudget:$budget,
          configurationReady:($hermes.status.configured == true and $odysseus.configured == true and
            $router.healthy == true and $ollama.healthy == true and $memory.running == true),
          ready:(($roadmapBlocked|not) and ($hermes.ready == true) and ($odysseus.ready == true) and
            ($router.healthy == true) and ($ollama.healthy == true) and ($memory.healthy == true) and
            ($budget.verdict == "pass")),
          issues:(([
            if $roadmapBlocked then {severity:"error",component:"policy",code:"roadmap-host-deployment-blocked",
              message:"Host workload deployment is prohibited until a verified PhaseZero release"} else empty end,
            if ($profile.profile == null) then {severity:"error",component:"profile",code:"profile-missing",message:"Requested profile is absent"} else empty end,
            if ($budget.verdict != "pass") then {severity:"error",component:"resources",code:"resource-budget-not-approved",message:"Resource governor did not approve profile"} else empty end,
            if ($router.healthy != true) then {severity:"error",component:"9router",code:"router-unhealthy",message:"9Router health proof missing"} else empty end,
            if ($ollama.healthy != true) then {severity:"warning",component:"ollama",code:"ollama-unavailable",message:"Local inference endpoint is unavailable"} else empty end,
            if ($memory.healthy != true) then {severity:"error",component:"ai-memory",code:"ai-memory-unhealthy",message:"Canonical memory health proof missing"} else empty end,
            if ($tailscaleAuthenticated != true) then {severity:"warning",component:"tailscale",code:"tailscale-unavailable",message:"Remote Hermes access is not authenticated"} else empty end,
            if ($podmanRootless != true) then {severity:"error",component:"odysseus",code:"rootless-podman-unavailable",message:"Odysseus rootless runtime unavailable"} else empty end,
            if ($port7000.listening == true and $odysseus.healthy != true) then {severity:"error",component:"odysseus",code:"port-7000-conflict",message:"Port 7000 is occupied without Odysseus health proof"} else empty end
          ] + [$hermes.issues[]? | . + {component:(.component // "hermes")}] +
            [$odysseus.issues[]? | . + {component:(.component // "odysseus")}]) | unique_by(.component,.code)),
          plan:{phases:[
            {id:"discover",state:"complete",mutates:false},
            {id:"security-audit",state:"complete",mutates:false},
            {id:"provenance",state:(if ($hermes.distribution.sha256Pinned == true and $odysseus.commitTrusted == true) then "complete" else "blocked" end),mutates:false},
            {id:"configure",state:"blocked",mutates:true},
            {id:"deploy",state:"blocked",mutates:true},
            {id:"validate",state:"pending",mutates:false}],
            nextSafeAction:"Resolve provenance, profile-service coverage and release gate; rerun this doctor"},
          secretsRedacted:true}'
}

case "$ACTION" in
    status|doctor|diagnose|plan) emit_diagnostic ;;
    *) echo "usage: agent-workspaces-diagnostic.sh (status|doctor|diagnose|plan)" >&2; exit 2 ;;
esac
