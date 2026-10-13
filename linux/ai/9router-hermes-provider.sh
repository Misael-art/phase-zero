#!/usr/bin/env bash
# 9router-hermes-provider.sh - register a named Hermes custom provider backed by
# 9Router, make it the Hermes/Desktop default, and keep every other provider
# selectable. Self-heals drift through the existing hermes-router timer.
#
# The named provider "custom:9router" points base_url at the local 9Router
# (127.0.0.1:20128/v1) and injects the 9Router client credential. The model
# chosen as default is a 9Router *combo* (a group of models with internal
# fallback), so a single upstream failure does not break the default — the
# router simply falls through to the next healthy model.
#
# No token is ever printed; all output is JSON on stdout, logs on stderr.
set -euo pipefail

# Resolve PZ_ROOT robustly (repo checkout or the runtime copy). Walk up until
# we find linux/lib/common.sh.
PZ_ROOT=""
for _root_candidate in "${PZ_ROOT:-}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "/mnt/sdcard/Projects/PhaseZero"; do
    [ -n "$_root_candidate" ] || continue
    _p="$_root_candidate"
    while [ "$_p" != "/" ]; do
        if [ -f "$_p/linux/lib/common.sh" ]; then
            PZ_ROOT="$_p"
            break
        fi
        _p="$(dirname "$_p")"
    done
    [ -n "$PZ_ROOT" ] && break
done
if [ -z "$PZ_ROOT" ] || [ ! -f "$PZ_ROOT/linux/lib/common.sh" ]; then
    echo "ERROR: cannot locate PhaseZero common.sh (PZ_ROOT=$PZ_ROOT)" >&2
    exit 70
fi
source "$PZ_ROOT/linux/lib/common.sh"

# info() -> stderr, so JSON envelopes on stdout stay clean (pz_info -> stdout).
info() { echo "INFO:  $*" >&2; }

require_connection_grant() {
    pz_error "Hermes provider changes blocked: per-request account grants are unavailable"
    jq -cn '{schemaVersion:1,tool:"9router-hermes-provider",status:"blocked",usageBlocked:true,
      blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
    return 69
}

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
HERMES_AGENT_DIR="$HERMES_HOME/hermes-agent"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
ROUTER_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies/9router.env"
ROUTER_ENDPOINT="${PZ_HERMES_ROUTER_ENDPOINT:-http://127.0.0.1:20128/v1}"
ROUTER_BASE="${PZ_HERMES_ROUTER_BASE:-http://127.0.0.1:20128}"
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/9router/settings.json"
DATA_DIR="${PZ_9ROUTER_DATA_DIR:-$HOME/.9router}"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai/hermes-router.json"

# The named provider and the default combo. Defaults to the "live" combo built
# by `live` (a probe of models that actually answer right now, with fallback).
# If phasezero-live is absent, fall back to the curated combos. Override per
# host with PZ_HERMES_DEFAULT_COMBO.
PROVIDER_NAME="9router"
PROVIDER_LABEL="${PZ_HERMES_PROVIDER_LABEL:-9Router (free)}"
DEFAULT_COMBO="${PZ_HERMES_DEFAULT_COMBO:-phasezero-live}"

# Fallback combos to try in order if the preferred one is not exposed.
FALLBACK_COMBOS="phasezero-live Default Kimi default_free"

# ---------------------------------------------------------------------------
# 9Router client auth
# ---------------------------------------------------------------------------

env_file_value() {
    local key="$1"
    [ -f "$ROUTER_ENV" ] || return 1
    awk -F= -v k="$key" '$1 == k {sub(/^[^=]*=/, ""); print; exit}' "$ROUTER_ENV"
}

cli_token() {
    local machine secret
    [ -s "$DATA_DIR/machine-id" ] && [ -s "$DATA_DIR/auth/cli-secret" ] || return 1
    machine="$(tr -d '\r\n' < "$DATA_DIR/machine-id")"
    secret="$(tr -d '\r\n' < "$DATA_DIR/auth/cli-secret")"
    printf '%s' "${machine}9r-cli-auth${secret}" | sha256sum | cut -c1-16
}

api_request() {
    local method="$1" path="$2" token
    token="$(cli_token)" || { pz_error "9Router CLI authentication unavailable"; return 1; }
    curl -fsS --max-time 10 -X "$method" \
        -H "x-9r-cli-token: $token" -H 'Content-Type: application/json' \
        "$ROUTER_BASE$path" 2>/dev/null
}

router_models() {
    local key="$(env_file_value PHASEZERO_9ROUTER_API_KEY)"
    [ -n "$key" ] || { pz_error "9Router client credential unavailable"; return 1; }
    curl -fsS --max-time 10 -H "Authorization: Bearer $key" \
        "$ROUTER_ENDPOINT/models" 2>/dev/null
}

router_combos() {
    local data
    data="$(api_request GET /api/combos)" || true
    if [ -n "$data" ]; then
        jq -r '.combos[]?.name' <<< "$data" 2>/dev/null || true
    fi
}

router_ready() {
    [ -f "$ROUTER_ENV" ] && [ -s "$DATA_DIR/machine-id" ] && [ -s "$DATA_DIR/auth/cli-secret" ] || return 1
    curl -fsS --max-time 3 "$ROUTER_BASE/api/health" >/dev/null 2>&1
}

combo_ids() {
    local data filter=""
    data="$(api_request GET /api/combos)" || true
    [ -n "$data" ] || return 0
    jq -r --arg c "${1:-}" '.combos[] | select(.name == $c) | .models[]?' <<< "$data" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Hermes config helpers
# ---------------------------------------------------------------------------

hermes_cmd() {
    command -v hermes 2>/dev/null || {
        [ -x "$LOCAL_BIN/hermes" ] && echo "$LOCAL_BIN/hermes" && return 0
        [ -x "$HOME/.local/bin/hermes" ] && echo "$HOME/.local/bin/hermes" && return 0
        [ -x "$HERMES_AGENT_DIR/venv/bin/hermes" ] && echo "$HERMES_AGENT_DIR/venv/bin/hermes" && return 0
        return 1
    }
}

config_read() {
    python3 - "$HERMES_CONFIG" <<'PY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
    m = d.get("model") if isinstance(d, dict) else None
    if isinstance(m, dict):
        print(f"provider={m.get('provider','')!r}")
        print(f"default={m.get('default','')!r}")
        print(f"base_url={m.get('base_url','')!r}")
    else:
        print("model=missing")
except Exception:
    print("model=unreadable")
PY
}

is_provider_active() {
    local block
    block="$(config_read)" || return 1
    grep -q "provider='custom:$PROVIDER_NAME'" <<< "$block" || return 1
}

is_routed_through_9router() {
    local block
    block="$(config_read)" || return 1
    grep -q "base_url='$ROUTER_ENDPOINT'" <<< "$block" || return 1
}

# ---------------------------------------------------------------------------
# Apply: register named provider + pin a combo as Hermes/Desktop default
# ---------------------------------------------------------------------------

apply_provider() {
    local combo="${1:-}" chosen="" existing_default=""
    router_ready || { pz_error "9Router is not ready; cannot register provider"; return 69; }
    router_models >/dev/null 2>&1 || { pz_error "9Router exposes no models; refusing"; return 69; }

    # Preserve the user's current default when re-running a heal (no explicit
    # combo): read the existing model.default from config.yaml first, so
    # auto-heal never resets a combo the user picked with `set`.
    if [ -z "$combo" ]; then
        existing_default="$(grep -E "^  default:" "$HERMES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}')"
        if [ -n "$existing_default" ] && in_router "$existing_default"; then
            combo="$existing_default"
        else
            combo="$DEFAULT_COMBO"
        fi
    fi

    # Pick the combo to pin: explicit arg > preserved default > DEFAULT_COMBO >
    # first fallback that exists in 9Router.
    if ! in_router "$combo"; then
        for c in $FALLBACK_COMBOS; do
            if in_router "$c"; then chosen="$c"; break; fi
        done
        [ -n "$chosen" ] || { pz_error "no 9Router combo is exposed"; return 69; }
        combo="$chosen"
    fi

    [ -f "$HERMES_CONFIG" ] || { pz_error "Hermes config missing: $HERMES_CONFIG"; return 1; }
    python3 - "$HERMES_CONFIG" "$ROUTER_ENDPOINT" "$PROVIDER_NAME" "$PROVIDER_LABEL" "$combo" <<'PY'
import sys, yaml, os
from pathlib import Path
path = Path(sys.argv[1])
endpoint, pname, plabel, combo = sys.argv[2:6]
# --- PhaseZero durable config IO (AISR-011/013; same block in hermes-router.sh,
# 9router-hermes-provider.sh and setup-hermes.sh) ---
def _pz_fsync_write(target, payload):
    with open(target, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(target, 0o600)


def _pz_fsync_dir(directory):
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def pz_load_config(path):
    """Empty/missing config: restore the last good .pz-bak instead of starting
    from {} (an interrupted write once left config.yaml at 0 bytes)."""
    raw = path.read_bytes() if path.exists() else b""
    if raw.strip():
        return yaml.safe_load(raw.decode("utf-8")) or {}
    bak = path.with_name(path.name + ".pz-bak")
    if bak.is_file() and bak.stat().st_size > 0:
        try:
            restored = yaml.safe_load(bak.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            restored = None
        if isinstance(restored, dict) and restored:
            print(f"PhaseZero: {path.name} vazio; restaurado de {bak.name}", file=sys.stderr)
            return restored
    return {}


def pz_durable_write(path, text):
    """Backup (only a non-empty file), fsynced tmp, atomic replace, fsynced dir."""
    if path.exists() and path.stat().st_size > 0:
        _pz_fsync_write(path.with_name(path.name + ".pz-bak"), path.read_bytes())
    tmp = path.with_name("." + path.name + ".pz-tmp")
    _pz_fsync_write(tmp, text.encode("utf-8"))
    os.replace(tmp, path)
    os.chmod(path, 0o600)
    _pz_fsync_dir(path.parent)
# --- end PhaseZero durable config IO ---

data = pz_load_config(path)
if not isinstance(data, dict):
    raise SystemExit("Hermes config root must be a mapping")

providers = data.setdefault("providers", {})
if not isinstance(providers, dict):
    providers = {}
    data["providers"] = providers
providers[pname] = {
    "name": plabel,
    "api": endpoint,
    "api_key": "${PHASEZERO_9ROUTER_API_KEY}",
    "key_env": "PHASEZERO_9ROUTER_API_KEY",
    "discover_models": True,
}

data["model"] = {
    "provider": f"custom:{pname}",
    "default": combo,
    "base_url": endpoint,
    "api_key": "${PHASEZERO_9ROUTER_API_KEY}",
}

auxiliary = data.setdefault("auxiliary", {})
for slot in ("compression", "web_extract", "skills_hub", "mcp"):
    current = auxiliary.setdefault(slot, {})
    if isinstance(current, dict) and current.get("provider") in ("main", "custom"):
        continue
    if isinstance(current, dict):
        current["provider"] = "main"

pz_durable_write(path, yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
PY

    # Post-`set -e` guard: rerun checks now that the file changed.
    if ! is_provider_active || ! is_routed_through_9router; then
        pz_error "Hermes provider config did not pass reference validation"
        return 69
    fi

    # Keep Hermes MCP servers intact after the rewrite (best-effort).
    if [ -f "$PZ_ROOT/linux/ai/mcp-manager.sh" ]; then
        bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes >/dev/null 2>&1 || true
    fi
    # Refresh the custom-endpoint model cache so the picker lists every model.
    refresh_hermes_cache

    info "Hermes provider 'custom:$PROVIDER_NAME' pinned to combo '$combo' through 9Router"
}

in_router() {
    router_combos | grep -Fxq "${1:-}" 2>/dev/null
}

refresh_hermes_cache() {
    local models cache key
    models="$(router_models)" || return 0
    cache="$HERMES_HOME/provider_models_cache.json"
    key="custom:${ROUTER_ENDPOINT%/}"
    if [ -f "$cache" ]; then
        cp "$cache" "$cache.bak" 2>/dev/null || true
        python3 - "$cache" "$key" <<'PY'
import sys, json, os, time
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    data = {}
# Reuse the existing entry's model list if present; the live list is re-fetched
# by Hermes the next time the picker opens. Do not clobber other providers.
if key in data and isinstance(data[key], dict):
    data[key]["at"] = time.time()
    tmp = path.with_name("." + path.name + ".pz-tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(data))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
PY
    fi
}

# ---------------------------------------------------------------------------
# Status / doctor / pick
# ---------------------------------------------------------------------------

list_providers() {
    local combos models_count
    combos="$(router_combos | paste -sd, - 2>/dev/null || true)"
    models_count="$(router_models | jq '[.data[]?.id] | length' 2>/dev/null || echo 0)"
    jq -cn \
        --arg endpoint "$ROUTER_ENDPOINT" \
        --arg name "$PROVIDER_NAME" \
        --arg label "$PROVIDER_LABEL" \
        --arg defaultCombo "$DEFAULT_COMBO" \
        --arg combos "$combos" \
        --argjson models "$models_count" \
        '{provider:$name,label:$label,endpoint:$endpoint,defaultCombo:$defaultCombo,
          combos:([$combos|split(",")[]?]),modelCount:$models,secretsRedacted:true}'
}

status_json() {
    local active=false routed=false combo="" hermes_default=""
    [ -f "$HERMES_CONFIG" ] && {
        if is_provider_active; then active=true; fi
        if is_routed_through_9router; then routed=true; fi
        hermes_default="$(grep -E "^  default:" "$HERMES_CONFIG" 2>/dev/null | head -1 | awk '{print $2}')"
    }
    combo="$(jq -r '.activeCombo // .model // "Default"' "$SETTINGS_FILE" 2>/dev/null || echo Default)"
    jq -cn \
        --argjson providerActive "$active" \
        --argjson routed "$routed" \
        --arg provider "$PROVIDER_NAME" \
        --arg label "$PROVIDER_LABEL" \
        --arg hermesConfig "$HERMES_CONFIG" \
        --arg endpoint "$ROUTER_ENDPOINT" \
        --arg routerCombo "$combo" \
        --arg hermesDefault "$hermes_default" \
        '{schemaVersion:1,tool:"9router-hermes-provider",provider:{
            name:$provider,label:$label,endpoint:$endpoint,
            registered:$providerActive,isDefault:$providerActive,routed:$routed,
            defaultCombo:$hermesDefault,routerActiveCombo:$routerCombo},
          hermesConfig:$hermesConfig,usageBlocked:true,
          blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
}

doctor_json() {
    local status
    status="$(status_json)"
    jq -cn --argjson status "$status" \
        '{schemaVersion:1,tool:"9router-hermes-provider",diagnosticComplete:true,status:$status,
          issues:([
            if $status.provider.registered|not then {severity:"error",component:"hermes",code:"provider-not-registered"} else empty end,
            if $status.provider.isDefault|not then {severity:"error",component:"hermes",code:"provider-not-default"} else empty end,
            if $status.provider.routed|not then {severity:"error",component:"hermes",code:"not-routed-through-9router"} else empty end,
            if $status.usageBlocked then {severity:"warning",component:"hermes",code:"connection-grant-not-enforceable"} else empty end
          ]),secretsRedacted:true}'
}

# ---------------------------------------------------------------------------
# Live probe: test every exposed model, build a "phasezero-live" combo from the
# ones that answer, and pin it as the Hermes/Desktop default. This is what makes
# the default *actually work* — a combo of healthy models with fallback — instead
# of a curated combo that may reference providers whose credential/quota is down.
# ---------------------------------------------------------------------------
#
# classifies a /chat/completions response:
#   ok    -> returned visible assistant content
#   auth  -> credential/token expired (needs reconnect, not routing)
#   down  -> upstream unavailable/quota/unsupported (skip)
#   unk   -> no response / timeout / malformed
LIVE_COMBO_NAME="phasezero-live"
LIVE_MIN_OK="${PZ_HERMES_LIVE_MIN_OK:-3}"
LIVE_TIMEOUT="${PZ_HERMES_LIVE_TIMEOUT:-6}"

# Probe (in parallel) every distinct model id that shows up in a 9Router combo,
# and emit the ones that answer "ok". The combo surface is the selectable set;
# probing 110+ raw provider models serially would take minutes. Parallelism is
# bounded by PZ_HERMES_LIVE_JOBS (default 8), timeout by PZ_HERMES_LIVE_TIMEOUT.
LIVE_JOBS="${PZ_HERMES_LIVE_JOBS:-8}"

router_all_model_ids() {
    # Distinct model ids from /v1/models (includes combos + provider models).
    router_models 2>/dev/null | jq -r '[.data[]?.id] | unique | .[]' 2>/dev/null || true
}

probe_live_models() {
    local key="$(env_file_value PHASEZERO_9ROUTER_API_KEY)"
    [ -n "$key" ] || { pz_error "9Router client credential unavailable"; return 1; }
    local tmp
    tmp="$(mktemp -d)"
    # Fan out one probe job per model, bounded by LIVE_JOBS.
    # As aspas simples são deliberadas: o corpo roda no bash interno e recebe
    # os valores por posição ($1..$4), justamente para a chave não aparecer na
    # linha de comando de cada job. Expandir aqui quebraria as duas coisas.
    # shellcheck disable=SC2016
    router_all_model_ids | xargs -P "$LIVE_JOBS" -I{} bash -c '
        m="$1"; key="$2"; timeout="$3"; ep="$4"
        out="$(curl -s -m "$timeout" -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
            -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}" \
            "$ep/chat/completions" 2>/dev/null || true)"
        if [ -n "$out" ] && printf "%s" "$out" | grep -qiE "\"choices\"" && ! printf "%s" "$out" | grep -qiE "\"error\""; then
            printf "%s\n" "$m"
        fi
    ' _ {} "$key" "$LIVE_TIMEOUT" "$ROUTER_ENDPOINT"
    rm -rf "$tmp" 2>/dev/null || true
}

upsert_live_combo() {
    local models="$1" name="$2" combos id payload
    combos="$(api_request GET /api/combos)" || true
    id="$(jq -r --arg name "$name" '(.combos // .data // [])[] | select(.name==$name) | .id' <<< "$combos" 2>/dev/null | head -1)"
    payload="$(mktemp)"
    jq -n --arg name "$name" --argjson models "$(jq -R -s 'split("\n") | map(select(length>0))' <<< "$models")" \
        '{name:$name,models:$models}' > "$payload"
    if [ -n "$id" ]; then
        curl -fsS --max-time 10 -X PUT -H "x-9r-cli-token: $(cli_token)" -H 'Content-Type: application/json' \
            --data-binary "@$payload" "$ROUTER_BASE/api/combos/$id" >/dev/null 2>&1 || true
    else
        curl -fsS --max-time 10 -X POST -H "x-9r-cli-token: $(cli_token)" -H 'Content-Type: application/json' \
            --data-binary "@$payload" "$ROUTER_BASE/api/combos" >/dev/null 2>&1 || true
    fi
    rm -f "$payload"
}

live() {
    local ok_models live_models
    router_ready || { pz_error "9Router is not ready"; return 69; }
    ok_models="$(probe_live_models || true)"
    live_models="$(printf '%s\n' "$ok_models" | sed '/^$/d' | head -n 10)"
    if [ -z "$live_models" ]; then
        pz_error "no 9Router model is currently healthy; none can be put in phasezero-live"
        return 69
    fi
    upsert_live_combo "$live_models" "$LIVE_COMBO_NAME"
    # Pin it as the Hermes/Desktop default.
    apply_provider "$LIVE_COMBO_NAME" || true
    jq -cn \
        --arg combo "$LIVE_COMBO_NAME" \
        --argjson models "$(printf '%s\n' "$live_models" | jq -R -s 'split("\n") | map(select(length>0))')" \
        '{schemaVersion:1,action:"live-probe",combo:$combo,okModels:$models,
          note:"combo rebuilt from models that answered a live probe; default pinned",
          secretsRedacted:true}'
}

set_combo() {
    local combo="${1:-}"
    [ -n "$combo" ] || { pz_error "usage: 9router-hermes-provider.sh set <combo>"; return 2; }
    if ! in_router "$combo"; then
        pz_error "combo '$combo' is not exposed by 9Router; combos: $(router_combos | paste -sd, -)"
        return 2
    fi
    apply_provider "$combo"
    status_json
}

list_combos() {
    local combos
    combos="$(router_combos)"
    [ -n "$combos" ] || { pz_error "no 9Router combos exposed"; return 1; }
    jq -cn \
        --arg provider "$PROVIDER_NAME" \
        --argjson combos "$(jq -Rsc 'split("\n") | map(select(length>0))' <<< "$combos")" \
        '{schemaVersion:1,provider:$provider,combos:$combos,secretsRedacted:true}'
}

install_watch() {
    local runtime_dir="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/runtime"
    local sysd_user="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local repo_root="$PZ_ROOT"
    mkdir -p "$runtime_dir" "$sysd_user"
    # Reuse the existing hermes-router timer, but pin PZ_ROOT in a copy appended
    # to apply_provider. Register a dedicated service only if not present.
    local svc_file="$runtime_dir/9router-hermes-provider.sh.$$"
    sed "s|^PZ_ROOT=\"\"\$|PZ_ROOT=\"$repo_root\"|" \
        "$PZ_ROOT/linux/ai/9router-hermes-provider.sh" > "$svc_file"
    install -m 0755 "$svc_file" "$runtime_dir/9router-hermes-provider.sh"
    rm -f "$svc_file"
    # Ensure the hermes-router timer keeps running (it heals model.default is
    # custom; this script additionally restores the named provider).
    systemctl --user restart phasezero-hermes-router.timer >/dev/null 2>&1 || true
    info "9Router Hermes provider installed; hermes-router timer active"
}

main() {
    case "${1:-status}" in
        status) status_json ;;
        doctor|diagnose) doctor_json ;;
        apply|register|install-provider) require_connection_grant ;;
        set|pin) require_connection_grant ;;
        list-providers) list_providers ;;
        combos|list-combos) list_combos ;;
        live|probe|auto) require_connection_grant ;;
        install) require_connection_grant ;;
        heal|repair) require_connection_grant ;;
        help|-h|--help)
            echo "usage: 9router-hermes-provider.sh (status|doctor|combos|list-providers); provider changes and inference probes blocked until per-request grants exist"
            ;;
        *) pz_error "usage: 9router-hermes-provider.sh (status|doctor|apply [combo]|set <combo>|live|combos|list-providers|install|heal)"; return 2 ;;
    esac
}

main "$@"
