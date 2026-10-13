#!/usr/bin/env bash
# llm-server.sh - PhaseZero local LLM server mode (Ollama).
#
# Installs/enables Ollama, pulls a small default model and (opt-in) exposes it on
# the LAN so other devices on the Tailscale/home network can use it. The LAN bind
# is a reversible systemd drop-in.
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN="$DROPIN_DIR/10-phasezero-llm-server.conf"
DEFAULT_MODEL="${PZ_LLM_SERVER_MODEL:-qwen2.5-coder:1.5b}"
STATE_FILE="${PZ_LLM_SERVER_STATE:-$PZ_STATE/llm-server.json}"

admin_run() {
    if pz_can_sudo_noninteractive; then sudo -n "$@"
    elif command -v phasezero-admin >/dev/null 2>&1; then phasezero-admin "$@"
    else return 127; fi
}

ollama_inference_probe() {
    # PZ-AUD-024: a real answer closes readiness. Short prompt, no stream,
    # generous timeout for cold model load. Never logs the prompt.
    local model="$1" out
    out="$(curl -fsS -m 150 -X POST http://127.0.0.1:11434/api/generate \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg m "$model" '{model:$m, prompt:"reply with: ok", stream:false}')" \
        2>/dev/null || true)"
    [ -n "$out" ] && jq -e '(.response | type == "string") and ((.response | length) > 0)' <<< "$out" >/dev/null 2>&1
}

record_llm_state() {
    local model="$1" probed="$2" code="$3"
    mkdir -p "$(dirname "$STATE_FILE")"
    jq -n --arg model "$model" --argjson probed "$probed" --arg code "$code" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schemaVersion:1, tool:"llm-server", defaultModel:$model,
          inference:{probed:$probed, httpCode:$code, checkedAt:$at}}' > "$STATE_FILE.tmp" \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

cmd_install() {
    # PZ-AUD-024: one persistent operation — base setup, broker-gated
    # foreground pull with visible progress, then a real inference probe.
    # "ready" is printed only after an answer; background nohup is gone.
    bash "$PZ_ROOT/linux/ai/setup-ollama.sh" || return 1
    command -v ollama >/dev/null 2>&1 || {
        pz_error "ollama still missing after setup; install it, then re-run: pz server llm install"
        return 1
    }
    if ! ollama list 2>/dev/null | grep -q "${DEFAULT_MODEL%%:*}"; then
        if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
            pz_info "dry-run: would pull $DEFAULT_MODEL"
            return 0
        fi
        pz_info "pulling $DEFAULT_MODEL (foreground; progress below)"
        bash "$PZ_ROOT/linux/ai/setup-ollama.sh" --pull "$DEFAULT_MODEL" || return 1
        ollama list 2>/dev/null | grep -q "${DEFAULT_MODEL%%:*}" || {
            pz_error "model $DEFAULT_MODEL not present after pull (offline? disk full? interrupted?)"
            return 1
        }
    fi
    pz_info "probing inference on $DEFAULT_MODEL (cold load may take a while)"
    if ollama_inference_probe "$DEFAULT_MODEL"; then
        record_llm_state "$DEFAULT_MODEL" true 200
    else
        record_llm_state "$DEFAULT_MODEL" true non-200
        pz_error "model present but inference probe failed; retry when the service is unloaded: pz server llm install"
        return 1
    fi
    [ "${PZ_LLM_SERVER_LAN:-0}" = "1" ] && cmd_expose_lan
    pz_info "LLM server ready. Local API: http://127.0.0.1:11434"
}

cmd_expose_lan() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then
        pz_info "dry-run: would write $DROPIN (OLLAMA_HOST=0.0.0.0) and restart ollama"
        return 0
    fi
    local tmp
    # shellcheck disable=SC2119 # pz_tempfile forwards args to mktemp; no args is intentional
    tmp="$(pz_tempfile)"
    cat > "$tmp" <<'EOF'
# PhaseZero managed: expose Ollama on the LAN/Tailscale interface for the home
# server. Remove this drop-in (llm-server.sh restore) to revert to localhost.
[Service]
Environment=OLLAMA_HOST=0.0.0.0:11434
EOF
    if admin_run install -Dm644 "$tmp" "$DROPIN"; then
        admin_run systemctl daemon-reload
        admin_run systemctl restart ollama || pz_warn "restart ollama manually"
        pz_info "Ollama now listening on 0.0.0.0:11434 (reach it via Tailscale IP)"
    else
        pz_warn "need root to write $DROPIN; run: sudo $0 expose-lan"
    fi
    rm -f "$tmp"
}

cmd_restore() {
    if [ "${PZ_DRY_RUN:-0}" = "1" ]; then pz_info "dry-run: would remove $DROPIN"; return 0; fi
    admin_run rm -f "$DROPIN" 2>/dev/null || true
    admin_run systemctl daemon-reload 2>/dev/null || true
    admin_run systemctl restart ollama 2>/dev/null || true
    pz_info "Ollama LAN exposure reverted to localhost"
}

cmd_status() {
    local installed=false active=false lan=false models="[]"
    command -v ollama >/dev/null 2>&1 && installed=true
    systemctl is-active ollama >/dev/null 2>&1 && active=true
    [ -f "$DROPIN" ] && lan=true
    if $active; then
        models="$(curl -fsS http://127.0.0.1:11434/api/tags 2>/dev/null | jq -c '[.models[].name]' 2>/dev/null || echo '[]')"
    fi
    local last_probe='null' model_present=false
    [ -f "$STATE_FILE" ] && last_probe="$(cat "$STATE_FILE" 2>/dev/null || echo null)"
    if [ "$models" != "[]" ]; then
        jq -e --arg m "$DEFAULT_MODEL" 'index($m) != null' <<< "$models" >/dev/null 2>&1 && model_present=true
    fi
    jq -n --argjson installed "$installed" --argjson active "$active" --argjson lan "$lan" \
        --arg default "$DEFAULT_MODEL" --argjson models "$models" \
        --argjson modelPresent "$model_present" --argjson lastInference "$last_probe" \
        '{tool:"llm-server", installed:$installed, serviceActive:$active, lanExposed:$lan, defaultModel:$default, models:$models, defaultModelPresent:$modelPresent, lastInference:$lastInference}'
}

case "${1:-status}" in
    install|setup|up) cmd_install ;;
    expose-lan|lan) cmd_expose_lan ;;
    restore|revert) cmd_restore ;;
    status) cmd_status ;;
    dry-run|plan) PZ_DRY_RUN=1 cmd_install ;;
    *) pz_error "usage: llm-server.sh (install|expose-lan|restore|status|dry-run)"; exit 2 ;;
esac
