#!/usr/bin/env bash
# hermes-router.sh - Force every Hermes inference call through 9Router.
#
# What this guarantees, and why:
#   1. Hermes' model config is ALWAYS `provider: custom` + the local 9Router
#      endpoint. When 9Router has any provider credential, Hermes must route
#      through it (Never silently drift to `nous`, or any other direct gateway).
#   2. Every individual model that 9Router exposes (each combo + the per-model
#      ids in /v1/models) is made selectable/targetable from Hermes, so the
#      user can pick a single provider or model per run instead of only a combo.
#   3. Self-heals drift: if a `hermes model`/`setup`/portal flow rewrites the
#      model block (e.g. back to `nous`), this repairs it back to 9Router.
#   4. b.ai provider-nodes are surfaced for diagnosis; if they have no
#      credential/connection wired in 9Router, we say so honestly (never invent
#      a key) and tell the user the exact wiring step.
#
# No token is ever printed. All model/endpoint output is redacted from secrets.
set -euo pipefail
# Resolve PZ_ROOT robustly: the repo checkout (linux/ai/hermes-router.sh) OR the
# runtime copy (~/.local/share/phasezero/runtime/hermes-router.sh). When
# installed under runtime/, PZ_ROOT is the repo parent of linux/ai, so walk up
# until we find linux/lib/common.sh rather than trusting a fixed-depth relative.
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

# info() -> stderr, so JSON envelopes on stdout stay clean (pz_info goes to stdout).
info() { echo "INFO:  $*" >&2; }

require_connection_grant() {
    pz_error "Hermes routing changes blocked: per-request account grants are unavailable"
    jq -cn '{schemaVersion:1,tool:"hermes-router",status:"blocked",usageBlocked:true,
      blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
    return 69
}

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
HERMES_AGENT_DIR="$HERMES_HOME/hermes-agent"
HERMES_VENV_PY="$HERMES_AGENT_DIR/venv/bin/python"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
HERMES_CMD=""
ROUTER_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies/9router.env"
ROUTER_ENDPOINT="${PZ_HERMES_ROUTER_ENDPOINT:-http://127.0.0.1:20128/v1}"
ROUTER_BASE="${PZ_HERMES_ROUTER_BASE:-http://127.0.0.1:20128}"
SETTINGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/9router/settings.json"
DATA_DIR="${PZ_9ROUTER_DATA_DIR:-$HOME/.9router}"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai/hermes-router.json"
DEFAULT_MODEL="${PZ_HERMES_DEFAULT_MODEL:-}"

# ---------------------------------------------------------------------------
# 9Router client-side auth (mirrors 9router-manager.sh: cli_token + api_key)
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

router_provider_nodes() {
    local data
    data="$(api_request GET /api/provider-nodes)" || true
    if [ -n "$data" ]; then
        jq -c '.nodes[]?' <<< "$data" 2>/dev/null || true
    fi
}

router_ready() {
    [ -f "$ROUTER_ENV" ] && [ -s "$DATA_DIR/machine-id" ] && [ -s "$DATA_DIR/auth/cli-secret" ] || return 1
    curl -fsS --max-time 3 "$ROUTER_BASE/api/health" >/dev/null 2>&1
}

router_providers_present() {
    router_models >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Hermes config inspection
# ---------------------------------------------------------------------------

hermes_cmd() {
    command -v hermes 2>/dev/null || {
        [ -x "$LOCAL_BIN/hermes" ] && echo "$LOCAL_BIN/hermes" && return 0
        [ -x "$HOME/.local/bin/hermes" ] && echo "$HOME/.local/bin/hermes" && return 0
        [ -x "$HERMES_AGENT_DIR/venv/bin/hermes" ] && echo "$HERMES_AGENT_DIR/venv/bin/hermes" && return 0
        return 1
    }
}

hermes_model_block() {
    [ -f "$HERMES_CONFIG" ] || return 1
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

model_is_router() {
    local block
    block="$(hermes_model_block)" || return 1
    grep -Eq "provider='custom(:[a-z0-9_-]+)?'" <<< "$block" && \
        grep -Fq "base_url='$ROUTER_ENDPOINT'" <<< "$block" || return 1
}

# ---------------------------------------------------------------------------
# Apply / heal the model config to 9Router
# ---------------------------------------------------------------------------
# Sets the model block to `provider: custom`, the local 9Router endpoint and a
# DERIVED api_key (a literal env reference) so the managed launcher injects the
# 9Router client credential and no raw key is ever written to config.yaml.

apply_router_config() {
    local default="${1:-}" current_model preserved_default=""
    [ -f "$HERMES_CONFIG" ] || { pz_error "Hermes config missing: $HERMES_CONFIG"; return 1; }
    router_ready || { pz_error "9Router is not ready; cannot force Hermes through it"; return 69; }
    router_models >/dev/null 2>&1 || { pz_error "9Router exposes no models; refusing to force routing"; return 69; }

    # Preserve an existing model.default when the config already has a named
    # custom provider (custom:9router). This keeps a user's chosen combo (e.g.
    # phasezero-live) through auto-heal instead of resetting it to the 9Router
    # activeCombo. Only fall back to the active combo when no default exists.
    # An empty config is restored from .pz-bak by the writer below; read the
    # user's default from the same source so the restore keeps their combo.
    local default_source="$HERMES_CONFIG"
    [ -s "$default_source" ] || default_source="$HERMES_CONFIG.pz-bak"
    preserved_default="$(grep -E "^  default:" "$default_source" 2>/dev/null | head -1 | awk '{print $2}')"
    if [ -z "$default" ]; then
        if [ -n "$preserved_default" ]; then
            default="$preserved_default"
        else
            current_model="$(jq -r '.activeCombo // .model // "Default"' "$SETTINGS_FILE" 2>/dev/null || echo Default)"
            default="$current_model"
        fi
    fi

    python3 - "$HERMES_CONFIG" "$ROUTER_ENDPOINT" "$default" <<'PY'
import sys, yaml, os
from pathlib import Path
path = Path(sys.argv[1])
endpoint = sys.argv[2]
default = sys.argv[3]
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
# Preserve a named custom provider (custom:9router) when one is already set, so
# the auto-heal never downgrades the named provider to the bare "custom" id.
current_provider = str(data.get("model", {}).get("provider", "") if isinstance(data.get("model"), dict) else "")
provider = "custom"
if current_provider.startswith("custom:") and current_provider != "custom":
    provider = current_provider
data["model"] = {
    "provider": provider,
    "default": default,
    "base_url": endpoint,
    "api_key": "${PHASEZERO_9ROUTER_API_KEY}",
}
auxiliary = data.setdefault("auxiliary", {})
for slot in ("compression", "web_extract", "skills_hub", "mcp"):
    current = auxiliary.setdefault(slot, {})
    if isinstance(current, dict) and current.get("provider") == "main":
        continue
    if isinstance(current, dict):
        current["provider"] = "main"
pz_durable_write(path, yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
PY

    model_is_router || {
        pz_error "Hermes 9Router configuration did not pass reference validation"
        return 69
    }
    info "Hermes model pinned through 9Router ($default)"
}

# ---------------------------------------------------------------------------
# Expose every individual 9Router model to the Hermes model prefs
# ---------------------------------------------------------------------------

refresh_model_cache() {
    local models ids cache key
    models="$(router_models)" || { pz_error "cannot read /v1/models"; return 1; }
    ids="$(jq -r '[.data[]?.id] | join("\n")' <<< "$models" 2>/dev/null || true)"
    [ -n "$ids" ] || { pz_error "9Router /v1/models is empty"; return 1; }
    # Keep the Hermes custom-endpoint model cache in sync with 9Router's live
    # /v1/models so the /model picker (and any catalog-based selection) reflects
    # every individual model + combo, not just a stale snapshot. Backup first.
    cache="$HERMES_HOME/provider_models_cache.json"
    # Hermes keys the custom-endpoint cache as "custom:<normalized base_url>".
    key="custom:${ROUTER_ENDPOINT%/}"
    if [ -f "$cache" ]; then
        cp "$cache" "$cache.bak" 2>/dev/null || true
        python3 - "$cache" "$key" "$ids" <<'PY'
import sys, json, os, time
from pathlib import Path
path = Path(sys.argv[1])
key, ids_text = sys.argv[2], sys.argv[3]
ids = [i for i in ids_text.splitlines() if i]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    data = {}
data[key] = {"fp": "live", "at": time.time(), "models": ids}
tmp = path.with_name("." + path.name + ".pz-tmp")
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(data))
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, path)
PY
    fi
    info "9Router exposes $(printf '%s\n' "$ids" | wc -l) selectable models/combos"
}

list_models() {
    local models ids_json
    models="$(router_models)" || { pz_error "cannot read /v1/models"; return 1; }
    ids_json="$(jq '[.data[]?.id | {id:.}] | if length > 0 then . else [] end' <<< "$models" 2>/dev/null || echo '[]')"
    jq -cn \
        --arg endpoint "$ROUTER_ENDPOINT" \
        --argjson models "$ids_json" \
        '{router:$endpoint,models:$models,secretsRedacted:true}'
}

# ---------------------------------------------------------------------------
# b.ai provider-node surface (diagnostic + credential hook, never a fake key)
# ---------------------------------------------------------------------------

bai_status() {
    local nodes
    nodes="$(router_provider_nodes)" || nodes=""
    if [ -z "$nodes" ]; then
        jq -cn '{provider:"b.ai",detected:false,connected:false,credential:false,note:"no provider-nodes exposed through 9Router",secretsRedacted:true}'
        return 0
    fi
    jq -s '
      [ .[] | select((.name|ascii_downcase) == "b.ai" or (.name|ascii_downcase) == "b.ai")
        | {name:.name, prefix:(.prefix // .data.prefix // ""), baseUrl:(.baseUrl // .data.baseUrl // "")}
      ] as $bai
      | {
          provider:"b.ai",
          detected: ($bai|length > 0),
          connected:false,
          credential:false,
          nodes:$bai,
          note:"b.ai provider-nodes exist in 9Router but require a credential/connection before they can route; run: pz ai 9router provider <b.ai> to add your key",
          secretsRedacted:true
        }' <<< "$nodes"
}

# ---------------------------------------------------------------------------
# Status / doctor
# ---------------------------------------------------------------------------

status_json() {
    local configured=false routed=false ready=false drifts="" models_count=0
    local drift_bool=false
    router_ready && ready=true
    [ -f "$HERMES_CONFIG" ] && configured=true
    model_block="$(hermes_model_block || echo model=unreadable)"
    if model_is_router >/dev/null 2>&1; then
        routed=true
    else
        drifts="$(grep -E "provider=|default=|base_url=" <<< "$model_block" | tr '\n' ' ')"
        drift_bool=true
    fi
    if router_models >/dev/null 2>&1; then
        models_count="$(router_models | jq '.data|length' 2>/dev/null || echo 0)"
    fi
    jq -cn \
        --argjson routerReady "$ready" \
        --argjson configured "$configured" \
        --argjson routed "$routed" \
        --argjson models "$models_count" \
        --arg drift "$drifts" \
        --argjson drift_bool "$drift_bool" \
        --arg home "$HERMES_HOME" --arg config "$HERMES_CONFIG" \
        --arg endpoint "$ROUTER_ENDPOINT" \
        '{schemaVersion:1,tool:"hermes-router",router:{endpoint:$endpoint,ready:$routerReady,models:$models},
          hermes:{configured:$configured,home:$home,configPath:$config,modelBlock:$drift},
          forcedThroughRouter:$routed,drift:$drift_bool,usageBlocked:true,
          blockedReason:"connection-grant-not-enforceable",
          secretsRedacted:true}'
}

doctor_json() {
    local status bai
    status="$(status_json)"
    bai="$(bai_status)"
    jq -cn \
        --argjson status "$status" --argjson bai "$bai" \
        '{schemaVersion:1,tool:"hermes-router",diagnosticComplete:true,status:$status,
          bai:$bai,
          issues:([
            if $status.router.ready|not then {severity:"error",component:"9router",code:"router-unavailable"} else empty end,
            if $status.router.models == 0 then {severity:"error",component:"9router",code:"router-no-models"} else empty end,
            if $status.hermes.configured|not then {severity:"error",component:"hermes",code:"hermes-not-configured"} else empty end,
            if $status.forcedThroughRouter|not then {severity:"error",component:"hermes",code:"hermes-not-routed-through-9router"} else empty end,
            if $status.usageBlocked then {severity:"warning",component:"hermes",code:"connection-grant-not-enforceable"} else empty end,
            if $bai.detected and ($bai.connected|not) then {severity:"warning",component:"b.ai",code:"bai-no-credential"} else empty end
          ]),secretsRedacted:true}'
}

# ---------------------------------------------------------------------------
# Manual model pin / switch (individual provider or combo)
# ---------------------------------------------------------------------------

pin_model() {
    local model="${1:-}"
    [ -n "$model" ] || { pz_error "usage: hermes-router.sh model <model-id|combo>"; return 2; }
    apply_router_config "$model"
    status_json
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

wire() {
    apply_router_config
    refresh_model_cache
    # When the named 9Router provider script is available and a named provider
    # is (or should be) the default, let it re-register so auto-heal restores
    # the named provider + combo, not just the bare "custom" routing.
    if [ -f "$PZ_ROOT/linux/ai/9router-hermes-provider.sh" ]; then
        bash "$PZ_ROOT/linux/ai/9router-hermes-provider.sh" apply >/dev/null 2>&1 || true
    fi
    # Keep Hermes MCP servers intact after a config rewrite (setup-hermes.sh
    # configure does the same); best-effort — routing must not drop MCP.
    if [ -f "$PZ_ROOT/linux/ai/mcp-manager.sh" ]; then
        bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes >/dev/null 2>&1 || true
    fi
    status_json
}

install_watch() {
    local runtime_dir="${XDG_DATA_HOME:-$HOME/.local/share}/phasezero/runtime"
    local sysd_user="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local repo_root="$PZ_ROOT"
    mkdir -p "$runtime_dir" "$sysd_user"
    # Pin PZ_ROOT to the actual repo in the installed copy: the runtime copy
    # lives under ~/.local/share/phasezero/runtime/, so its own probe cannot
    # walk up to the repo and the loop would end at the repo fallback. Pin it.
    local tmp="$runtime_dir/hermes-router.sh.$$"
    sed "s|^PZ_ROOT=\"\"\$|PZ_ROOT=\"$repo_root\"|" \
        "$PZ_ROOT/linux/ai/hermes-router.sh" > "$tmp"
    install -m 0755 "$tmp" "$runtime_dir/hermes-router.sh"
    rm -f "$tmp"

    local service="$sysd_user/phasezero-hermes-router.service"
    local timer="$sysd_user/phasezero-hermes-router.timer"
    pz_write_managed_file "$service" user <<EOF
[Unit]
Description=PhaseZero Hermes 9Router routing enforcement
After=phasezero-9router.service

[Service]
Type=oneshot
ExecStart=$runtime_dir/hermes-router.sh enforce
EOF
    pz_write_managed_file "$timer" user <<'EOF'
[Unit]
Description=Periodically enforce Hermes through 9Router

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now "$timer" >/dev/null 2>&1 || true
    systemctl --user restart "$timer" >/dev/null 2>&1 || true
    info "Hermes 9Router enforcement watch installed (auto-heals config drift)"
}

watch_status() {
    local timer
    timer="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/phasezero-hermes-router.timer"
    jq -cn \
        --argjson enabled "$(systemctl --user is-enabled phasezero-hermes-router.timer >/dev/null 2>&1 && echo true || echo false)" \
        --argjson active "$(systemctl --user is-active phasezero-hermes-router.timer >/dev/null 2>&1 && echo true || echo false)" \
        '{schemaVersion:1,tool:"hermes-router",watch:{enabled:$enabled,active:$active},secretsRedacted:true}'
}

main() {
    HERMES_CMD="$(hermes_cmd || true)"
    case "${1:-status}" in
        status) status_json ;;
        doctor|diagnose) doctor_json ;;
        models|list) list_models ;;
        bai|b-ai|b.ai) bai_status ;;
        apply|wire|enforce) require_connection_grant ;;
        model|pin|set) require_connection_grant ;;
        heal|repair) require_connection_grant ;;
        list-models) list_models ;;
        install|install-watch) require_connection_grant ;;
        watch|guard) watch_status ;;
        help|-h|--help)
            echo "usage: hermes-router.sh (status|doctor|models|bai|watch); route changes blocked until per-request grants exist"
            ;;
        *) pz_error "usage: hermes-router.sh (status|doctor|models|bai|apply|model <id>|heal|install|watch)"; return 2 ;;
    esac
}

main "$@"
