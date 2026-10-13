#!/usr/bin/env bash
# setup-hermes.sh - install/configure Hermes Agent for PhaseZero Linux agents
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG="$HERMES_HOME/config.yaml"
HERMES_AGENT_DIR="$HERMES_HOME/hermes-agent"
HERMES_VENV_PY="$HERMES_AGENT_DIR/venv/bin/python"
HERMES_ENTRYPOINT="$HERMES_AGENT_DIR/hermes"
LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
PHASEZERO_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai"
ENV_FILE="$PHASEZERO_CONFIG_DIR/hermes.env"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai/hermes.json"
INSTALL_TIMEOUT="${PZ_HERMES_INSTALL_TIMEOUT:-1800}"
DISTRIBUTION_FILE="${PZ_HERMES_DISTRIBUTION_FILE:-$PZ_ROOT/assets/ai/hermes-distribution-audit.json}"
ROUTER_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero/ai-proxies/9router.env"
ROUTER_ENDPOINT="${PZ_HERMES_ROUTER_ENDPOINT:-http://127.0.0.1:20128/v1}"
ROUTER_MODEL="${PZ_HERMES_ROUTER_MODEL:-Default}"
DASHBOARD_ENTRY="${XDG_DATA_HOME:-$HOME/.local/share}/applications/phasezero-hermes.desktop"
HERMES_GATEWAY_SERVICE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hermes-gateway.service"
HERMES_GATEWAY_DROPIN="${HERMES_GATEWAY_SERVICE}.d/phasezero.conf"
PYTHON_PLAYWRIGHT_VERSION="${PZ_HERMES_PYTHON_PLAYWRIGHT_VERSION:-1.62.0}"

distribution_valid() {
    [ -f "$DISTRIBUTION_FILE" ] || return 1
    jq -e '
      .schemaVersion == 1 and .id == "hermes" and
      (.source.repository == "https://github.com/NousResearch/hermes-agent.git") and
      (.source.releaseTag | type == "string" and length > 1) and
      (.source.commit | test("^[0-9a-f]{40}$")) and
      (.source.tree | test("^[0-9a-f]{40}$")) and
      (.source.commitSignatureVerified | type == "boolean") and
      (.source.tagSignatureVerified | type == "boolean") and
      (.installer.url == ("https://raw.githubusercontent.com/NousResearch/hermes-agent/" + .source.commit + "/scripts/install.sh")) and
      (.installer.sha256 | test("^[0-9a-f]{64}$")) and
      .installer.supportsCommitPin == true and
      (.files["uv.lock"] | test("^[0-9a-f]{64}$")) and
      (.files["pyproject.toml"] | test("^[0-9a-f]{64}$")) and
      (.files.LICENSE | test("^[0-9a-f]{64}$")) and
      (.semanticAudit | type == "boolean") and
      (.transitiveArtifactsPinned | type == "boolean") and
      (.approvedForInstall | type == "boolean") and
      (.findings | type == "array" and length > 0)
    ' "$DISTRIBUTION_FILE" >/dev/null 2>&1
}

distribution_approved() {
    distribution_valid || return 1
    jq -e '.approvedForInstall == true and .semanticAudit == true and .transitiveArtifactsPinned == true' \
        "$DISTRIBUTION_FILE" >/dev/null 2>&1
}

operator_risk_accepted() {
    local commit accepted="${PZ_HERMES_ACCEPT_UNAUDITED_COMMIT:-}"
    distribution_valid || return 1
    commit="$(jq -r '.source.commit' "$DISTRIBUTION_FILE")"
    [ "$accepted" = "$commit" ] && return 0
    [ -f "$STATE_FILE" ] && jq -e --arg commit "$commit" \
      '.distribution.sourceCommit == $commit and .distribution.operatorRiskAccepted == true' \
      "$STATE_FILE" >/dev/null 2>&1
}

distribution_install_allowed() {
    distribution_approved || operator_risk_accepted
}

router_credentials_ready() {
    [ -f "$ROUTER_ENV" ] || return 1
    [ "$(stat -c %a "$ROUTER_ENV" 2>/dev/null || echo unknown)" = 600 ] || return 1
    awk -F= '
      $1 == "PHASEZERO_9ROUTER_API_KEY" {
        value=$0; sub(/^[^=]*=/, "", value)
        if (value != "" && value !~ /[[:space:]]/) found=1
      }
      END { exit(found ? 0 : 1) }
    ' "$ROUTER_ENV"
}

config_has_router_reference() {
    [ -f "$HERMES_CONFIG" ] || return 1
    grep -Fq 'provider: custom' "$HERMES_CONFIG" &&
      grep -Fq "base_url: $ROUTER_ENDPOINT" "$HERMES_CONFIG" &&
      grep -Fq "\${PHASEZERO_9ROUTER_API_KEY}" "$HERMES_CONFIG"
}

distribution_json() {
    if ! distribution_valid; then
        jq -cn --arg manifest "$DISTRIBUTION_FILE" \
            '{manifestPath:$manifest,manifestValid:false,approvedForInstall:false,semanticAudit:false,
              transitiveArtifactsPinned:false,installerPinned:false,signatureVerified:false,findings:[]}'
        return
    fi
    jq -c --arg manifest "$DISTRIBUTION_FILE" '
      {manifestPath:$manifest,manifestValid:true,releaseTag:.source.releaseTag,
       sourceCommit:.source.commit,sourceTree:.source.tree,installer:.installer.url,
       installerSha256:.installer.sha256,installerPinned:true,
       signatureVerified:(.source.commitSignatureVerified and .source.tagSignatureVerified),
       commitSignatureVerified:.source.commitSignatureVerified,
       tagSignatureVerified:.source.tagSignatureVerified,
       semanticAudit:.semanticAudit,transitiveArtifactsPinned:.transitiveArtifactsPinned,
       approvedForInstall:.approvedForInstall,license:.license,findings:.findings}' "$DISTRIBUTION_FILE"
}

require_workload_release_gate() {
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && return 0
    pz_error "Hermes changes blocked by Homelab release gate; run: pz ai workspaces plan"
    return 69
}

require_connection_grant() {
    pz_error "Hermes usage blocked: PhaseZero cannot bind an account grant to every request"
    jq -cn '{schemaVersion:1,tool:"hermes",id:"hermes",status:"blocked",
      usageBlocked:true,blockedReason:"connection-grant-not-enforceable",secretsRedacted:true}'
    return 69
}

hermes_cmd() {
    command -v hermes 2>/dev/null || {
        [ -x "$LOCAL_BIN/hermes" ] && echo "$LOCAL_BIN/hermes" && return 0
        [ -x "$HOME/.local/bin/hermes" ] && echo "$HOME/.local/bin/hermes" && return 0
        [ -x "$HERMES_AGENT_DIR/venv/bin/hermes" ] && echo "$HERMES_AGENT_DIR/venv/bin/hermes" && return 0
        return 1
    }
}

link_managed_bin() {
    local source_path="$1"
    [ -x "$source_path" ] || return 0
    mkdir -p "$LOCAL_BIN"
    if [ "$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")" = "$(readlink -f "$LOCAL_BIN/hermes" 2>/dev/null || printf '%s' "$LOCAL_BIN/hermes")" ]; then
        pz_info "hermes already linked in $LOCAL_BIN"
        return 0
    fi
    ln -sfn "$source_path" "$LOCAL_BIN/hermes"
    pz_info "linked hermes into $LOCAL_BIN"
}

prepare_managed_uv() {
    local uv_bin
    [ -x "$HERMES_HOME/bin/uv" ] && return 0
    uv_bin="$(command -v uv || true)"
    [ -x "$uv_bin" ] || {
        pz_error "verified host uv is required to avoid mutable bootstrap download"
        return 69
    }
    install -d -m 0700 "$HERMES_HOME/bin"
    ln -sfn "$uv_bin" "$HERMES_HOME/bin/uv"
    pz_info "Using host-managed $("$uv_bin" --version) for locked Hermes sync"
}

write_router_launchers() {
    if [ ! -x "$HERMES_VENV_PY" ] || [ ! -f "$HERMES_ENTRYPOINT" ]; then
        pz_error "Hermes launcher prerequisites missing"
        return 1
    fi
    router_credentials_ready || {
        pz_error "canonical 9Router client credential unavailable or unsafe: $ROUTER_ENV"
        return 69
    }
    install -d -m 0755 "$LOCAL_BIN"
    pz_write_managed_file "$LOCAL_BIN/hermes" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
router_env="$ROUTER_ENV"
key="\$(awk -F= '\$1=="PHASEZERO_9ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' "\$router_env")"
[ -n "\$key" ] || { echo "9Router client credential missing" >&2; exit 69; }
export PHASEZERO_9ROUTER_API_KEY="\$key"
unset PYTHONPATH PYTHONHOME PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND
exec "$HERMES_VENV_PY" "$HERMES_ENTRYPOINT" "\$@"
EOF
    pz_write_managed_file "$LOCAL_BIN/hermes-agent" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
router_env="$ROUTER_ENV"
key="\$(awk -F= '\$1=="PHASEZERO_9ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' "\$router_env")"
[ -n "\$key" ] || { echo "9Router client credential missing" >&2; exit 69; }
export PHASEZERO_9ROUTER_API_KEY="\$key"
unset PYTHONPATH PYTHONHOME PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND
exec "$HERMES_VENV_PY" "$HERMES_AGENT_DIR/run_agent.py" "\$@"
EOF
    pz_write_managed_file "$LOCAL_BIN/hermes-acp" user <<EOF
#!/usr/bin/env bash
set -euo pipefail
router_env="$ROUTER_ENV"
key="\$(awk -F= '\$1=="PHASEZERO_9ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' "\$router_env")"
[ -n "\$key" ] || { echo "9Router client credential missing" >&2; exit 69; }
export PHASEZERO_9ROUTER_API_KEY="\$key"
unset PYTHONPATH PYTHONHOME PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND
exec "$HERMES_VENV_PY" "$HERMES_ENTRYPOINT" acp "\$@"
EOF
    chmod 0700 "$LOCAL_BIN/hermes" "$LOCAL_BIN/hermes-agent" "$LOCAL_BIN/hermes-acp"

    install -d -m 0755 "$(dirname "$DASHBOARD_ENTRY")"
    pz_write_managed_file "$DASHBOARD_ENTRY" user <<EOF
[Desktop Entry]
Type=Application
Name=Hermes Agent
Comment=PhaseZero agent through 9Router
Exec=$LOCAL_BIN/hermes
Icon=applications-science
Terminal=true
Categories=X-PhaseZero-AI;Development;
X-PHZ-Group=ia
X-PhaseZero-Managed=true
EOF
    chmod 0644 "$DASHBOARD_ENTRY"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$(dirname "$DASHBOARD_ENTRY")" >/dev/null 2>&1 || true
    fi
}

install_hermes() {
    if hermes_cmd >/dev/null 2>&1; then
        pz_info "Hermes already installed: $(hermes_cmd)"
        return 0
    fi

    local tmp size rc=0 args=() ck installer_url commit
    distribution_install_allowed || {
        pz_error "Hermes distribution is not approved; exact operator acceptance required: PZ_HERMES_ACCEPT_UNAUDITED_COMMIT=$(jq -r '.source.commit // empty' "$DISTRIBUTION_FILE" 2>/dev/null)"
        return 69
    }
    if ! distribution_approved; then
        pz_warn "Installing immutable Hermes release with explicit operator risk acceptance; semantic audit remains incomplete"
    fi
    pz_check_deps curl git jq xz
    prepare_managed_uv
    ck="$(jq -r '.installer.sha256' "$DISTRIBUTION_FILE")"
    installer_url="$(jq -r '.installer.url' "$DISTRIBUTION_FILE")"
    commit="$(jq -r '.source.commit' "$DISTRIBUTION_FILE")"
    if ! bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$ck" version="$commit" >/dev/null 2>&1; then
        pz_error "AI policy denies approved Hermes distribution"
        return 69
    fi
    tmp="$(pz_tempfile "${TMPDIR:-/tmp}/phasezero-hermes.XXXXXX")"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 120 \
        "$installer_url" -o "$tmp"; then
        rm -f -- "$tmp"
        pz_error "Hermes installer download failed"
        return 1
    fi
    size="$(wc -c < "$tmp")"
    if [ "$size" -lt 256 ] || [ "$size" -gt 2097152 ] || ! head -n 1 "$tmp" | grep -q '^#!'; then
        rm -f -- "$tmp"
        pz_error "Hermes installer failed content validation (size=$size)"
        return 1
    fi
    local got
    got="$(sha256sum "$tmp" | cut -d' ' -f1)"
    if [ "$got" != "$ck" ]; then
        rm -f -- "$tmp"
        pz_error "Hermes installer checksum mismatch: got $got, expected $ck"
        return 69
    fi
    pz_info "Hermes installer checksum verified"
    args+=(--commit "$commit" --skip-setup --non-interactive)
    [ "${PZ_HERMES_SKIP_BROWSER:-0}" = "1" ] && args+=(--skip-browser)
    [ "${PZ_HERMES_INCLUDE_DESKTOP:-0}" = "1" ] && args+=(--include-desktop)
    pz_info "installing Hermes Agent into $HERMES_HOME"
    HERMES_HOME="$HERMES_HOME" timeout "$INSTALL_TIMEOUT" bash "$tmp" "${args[@]}" || rc=$?
    rm -f -- "$tmp"
    [ "$rc" -eq 0 ] || { pz_error "Hermes installer failed (exit=$rc)"; return "$rc"; }

    write_router_launchers
}

write_env_template() {
    mkdir -p "$PHASEZERO_CONFIG_DIR"
    if [ ! -f "$ENV_FILE" ]; then
        pz_write_managed_file "$ENV_FILE" <<'EOF'
# PhaseZero Hermes env template. No raw keys in repo files.
# Prefer official auth/config flows:
#   hermes setup --portal
#   hermes model
# Optional BYOK examples:
# OPENAI_API_KEY=<manual-secret-store-value>
# ANTHROPIC_API_KEY=<manual-secret-store-value>
# OPENROUTER_API_KEY=<manual-secret-store-value>
EOF
        chmod 600 "$ENV_FILE" 2>/dev/null || true
    fi
}

configure_router_model() {
    router_credentials_ready || {
        pz_error "9Router client credential unavailable; Hermes cannot be integrated"
        return 69
    }
    write_router_launchers
    "$HERMES_VENV_PY" - "$HERMES_CONFIG" "$ROUTER_ENDPOINT" "$ROUTER_MODEL" <<'PY'
import os
import sys
from pathlib import Path

import yaml

path = Path(sys.argv[1])
endpoint = sys.argv[2]
model_name = sys.argv[3]
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
model = data.setdefault("model", {})
model.update({
    "provider": "custom",
    "default": model_name,
    "base_url": endpoint,
    "api_key": "${PHASEZERO_9ROUTER_API_KEY}",
})
auxiliary = data.setdefault("auxiliary", {})
for slot in ("compression", "web_extract", "skills_hub", "mcp"):
    current = auxiliary.setdefault(slot, {})
    if isinstance(current, dict):
        current["provider"] = "main"
path.parent.mkdir(parents=True, exist_ok=True)
pz_durable_write(path, yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
PY
    config_has_router_reference || {
        pz_error "Hermes 9Router configuration did not pass reference validation"
        return 69
    }
    pz_info "Hermes model routed through 9Router ($ROUTER_MODEL)"
}

ensure_playwright_sdk() {
    local python_playwright_version="" uv_bin="$HERMES_HOME/bin/uv"
    [ "${PZ_HERMES_SKIP_BROWSER:-0}" = "1" ] && return 0
    [ -x "$HERMES_VENV_PY" ] || {
        pz_warn "Hermes Python environment missing; browser SDK skipped"
        return 0
    }
    [[ "$PYTHON_PLAYWRIGHT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        pz_error "invalid Hermes Python Playwright version: $PYTHON_PLAYWRIGHT_VERSION"
        return 69
    }
    python_playwright_version="$($HERMES_VENV_PY - <<'PY' 2>/dev/null || true
import importlib.metadata
try:
    print(importlib.metadata.version("playwright"))
except importlib.metadata.PackageNotFoundError:
    pass
PY
)"
    if [ "$python_playwright_version" != "$PYTHON_PLAYWRIGHT_VERSION" ]; then
        [ -x "$uv_bin" ] || prepare_managed_uv
        pz_info "Installing pinned Hermes Python browser SDK $PYTHON_PLAYWRIGHT_VERSION"
        "$uv_bin" pip install --python "$HERMES_VENV_PY" "playwright==$PYTHON_PLAYWRIGHT_VERSION"
    fi
    PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" \
        "$HERMES_VENV_PY" -m playwright install chromium
    "$HERMES_VENV_PY" - <<PY >/dev/null
import importlib.metadata
from playwright.sync_api import sync_playwright
assert importlib.metadata.version("playwright") == "$PYTHON_PLAYWRIGHT_VERSION"
with sync_playwright() as runtime:
    browser = runtime.chromium.launch(headless=True)
    page = browser.new_page()
    page.set_content("<title>Hermes browser probe</title>")
    assert page.title() == "Hermes browser probe"
    browser.close()
PY
    pz_info "Hermes browser SDK ready (Playwright $PYTHON_PLAYWRIGHT_VERSION)"
}

install_gateway_service() {
    distribution_install_allowed || {
        pz_error "Hermes gateway blocked by distribution policy"
        return 69
    }
    router_credentials_ready || {
        pz_error "Hermes gateway requires canonical 9Router client credential"
        return 69
    }
    write_router_launchers
    if [ ! -f "$HERMES_GATEWAY_SERVICE" ]; then
        timeout 90 "$LOCAL_BIN/hermes" gateway install --no-start-now --start-on-login
    fi
    install -d -m 0755 "$(dirname "$HERMES_GATEWAY_DROPIN")"
    pz_write_managed_file "$HERMES_GATEWAY_DROPIN" user <<EOF
[Unit]
Requires=phasezero-9router.service
After=phasezero-9router.service

[Service]
ExecStart=
ExecStart=$LOCAL_BIN/hermes gateway run
WorkingDirectory=$HERMES_HOME
Environment="HOME=$HOME"
Environment="HERMES_HOME=$HERMES_HOME"
UnsetEnvironment=PHASEZERO_ADMIN PHASEZERO_ADMIN_BACKEND PHASEZERO_ADMIN_COMMAND
EOF
    chmod 0644 "$HERMES_GATEWAY_DROPIN"
    systemctl --user daemon-reload
    systemctl --user enable --now hermes-gateway.service
    systemctl --user restart hermes-gateway.service
    systemctl --user is-active --quiet hermes-gateway.service || {
        pz_error "Hermes gateway did not become active"
        return 1
    }
    systemctl --user show -p ExecStart --value hermes-gateway.service | grep -Fq "$LOCAL_BIN/hermes gateway run" || {
        pz_error "Hermes gateway drop-in did not select the managed 9Router launcher"
        return 69
    }
    pz_info "Hermes gateway active through persistent 9Router drop-in"
}

install_mcp_sdk() {
    if [ ! -x "$HERMES_VENV_PY" ]; then
        pz_warn "Hermes venv python not found; skipping MCP SDK install"
        return 0
    fi
    if "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import mcp
PY
    then
        pz_info "Hermes MCP SDK already installed"
        return 0
    fi
    "$HERMES_VENV_PY" -m pip install mcp >/dev/null 2>&1 || \
        pz_warn "could not install Python mcp package into Hermes venv"
}

configure_hermes() {
    local cmd=""
    write_env_template
    mkdir -p "$HERMES_HOME"
    if [ -x "$HERMES_VENV_PY" ]; then
        configure_router_model
        ensure_playwright_sdk
    fi
    bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes >/dev/null || pz_warn "Hermes MCP sync failed"
    install_mcp_sdk
    cmd="$(hermes_cmd || true)"
    if [ -n "$cmd" ]; then
        timeout 30 "$cmd" config check >/dev/null 2>&1 || pz_warn "Hermes config check reported issues; run: hermes config check"
        timeout 30 "$cmd" doctor >/dev/null 2>&1 || pz_warn "Hermes doctor reported issues; run: hermes doctor"
    else
        pz_warn "Hermes not installed; config prepared only"
    fi
    write_state "$cmd"
}

write_state() {
    local cmd="${1:-}" version="" distribution_commit="" installer_sha="" risk=false
    [ -n "$cmd" ] && version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
    if distribution_valid; then
        distribution_commit="$(jq -r '.source.commit' "$DISTRIBUTION_FILE")"
        installer_sha="$(jq -r '.installer.sha256' "$DISTRIBUTION_FILE")"
    fi
    operator_risk_accepted && risk=true
    mkdir -p "$(dirname "$STATE_FILE")"
    jq -n \
        --arg installedAt "$(date -Iseconds)" \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg hermesHome "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        --arg distributionCommit "$distribution_commit" \
        --arg installerSha256 "$installer_sha" \
        --argjson operatorRiskAccepted "$risk" \
        '{schemaVersion:1,tool:"hermes",installedAt:$installedAt,commandPath:$commandPath,version:$version,
          home:$hermesHome,configPath:$configPath,envFile:$envFile,
          distribution:{sourceCommit:$distributionCommit,installerSha256:$installerSha256,
            operatorRiskAccepted:$operatorRiskAccepted}}' |
        pz_write_managed_file "$STATE_FILE" user
    chmod 0600 "$STATE_FILE"
}

mcp_sdk_available() {
    [ -x "$HERMES_VENV_PY" ] || return 1
    "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import mcp
PY
}

browser_sdk_available() {
    [ -x "$HERMES_VENV_PY" ] || return 1
    "$HERMES_VENV_PY" - <<'PY' >/dev/null 2>&1
import playwright.sync_api
PY
}

env_has_auth_reference() {
    [ -f "$ENV_FILE" ] || return 1
    awk -F= '
        /^(OPENAI|ANTHROPIC|OPENROUTER)_API_KEY=/ {
            value=$0; sub(/^[^=]*=/, "", value)
            if (value != "" && value !~ /^<.*>$/ && value !~ /manual-secret-store-value/) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$ENV_FILE"
}

path_is_local_regular() {
    local path="$1" root="$2" resolved
    [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
    [ -f "$path" ] || return 1
    resolved="$(realpath -e -- "$path" 2>/dev/null || true)"
    [ -n "$resolved" ] && [[ "$resolved" == "$root"/* ]]
}

status_json() {
    local cmd="" version="" mcp_count=0 sdk=false browser_sdk=false config_check=false doctor_ok=false
    local installed=false configured=false ready=false configuration_ready=false auth=false config_safe=false mcp_ready=false distribution_ok=false risk=false
    local gateway_active=false gateway_enabled=false
    local auth_method="none"
    local config_mode="missing" env_mode="missing" state_mode="missing"
    cmd="$(hermes_cmd || true)"
    if [ -n "$cmd" ]; then
        installed=true
        version="$(timeout 10 "$cmd" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        # `hermes config check` accepts an empty config.yaml; an empty file
        # (interrupted write) must not read as a passing check.
        [ -s "$HERMES_CONFIG" ] && timeout 15 "$cmd" config check >/dev/null 2>&1 && config_check=true
        timeout 30 "$cmd" doctor >/dev/null 2>&1 && doctor_ok=true
    fi
    [ -f "$HERMES_CONFIG" ] && mcp_count="$(grep -c -E '^  # BEGIN PHASEZERO MCP ' "$HERMES_CONFIG" 2>/dev/null || true)"
    mcp_sdk_available && sdk=true
    browser_sdk_available && browser_sdk=true
    systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null && gateway_active=true
    systemctl --user is-enabled --quiet hermes-gateway.service 2>/dev/null && gateway_enabled=true
    path_is_local_regular "$HERMES_CONFIG" "$HERMES_HOME" && config_safe=true
    [ -f "$HERMES_CONFIG" ] && config_mode="$(stat -c %a "$HERMES_CONFIG" 2>/dev/null || echo unknown)"
    [ -f "$ENV_FILE" ] && env_mode="$(stat -c %a "$ENV_FILE" 2>/dev/null || echo unknown)"
    [ -f "$STATE_FILE" ] && state_mode="$(stat -c %a "$STATE_FILE" 2>/dev/null || echo unknown)"
    if config_has_router_reference && router_credentials_ready; then
        auth=true
        auth_method="canonical-9router-reference"
    elif env_has_auth_reference; then
        auth=true
        auth_method="provider-env"
    fi
    distribution_install_allowed && distribution_ok=true
    operator_risk_accepted && risk=true
    [ "$mcp_count" -gt 0 ] && [ "$sdk" = true ] && mcp_ready=true
    if [ -s "$HERMES_CONFIG" ] && [ -f "$ENV_FILE" ] && [ "$config_safe" = true ] &&
        [ "$config_mode" = 600 ] && [ "$env_mode" = 600 ]; then
        configured=true
    fi
    if [ "$installed" = true ] && [ "$configured" = true ] && [ "$config_check" = true ] &&
        [ "$doctor_ok" = true ] && [ "$auth" = true ] && [ "$mcp_ready" = true ] &&
        [ "$distribution_ok" = true ]; then
        ready=true
    fi
    configuration_ready="$ready"
    ready=false
    jq -cn \
        --argjson schemaVersion 1 \
        --arg commandPath "$cmd" \
        --arg version "$version" \
        --arg hermesHome "$HERMES_HOME" \
        --arg configPath "$HERMES_CONFIG" \
        --arg envFile "$ENV_FILE" \
        --arg stateFile "$STATE_FILE" \
        --arg configMode "$config_mode" \
        --arg envMode "$env_mode" \
        --arg stateMode "$state_mode" \
        --argjson available "$installed" \
        --argjson installed "$installed" \
        --argjson configured "$configured" \
        --argjson configurationReady "$configuration_ready" \
        --argjson ready "$ready" \
        --argjson authConfigured "$auth" \
        --arg authMethod "$auth_method" \
        --argjson distributionAllowed "$distribution_ok" \
        --argjson operatorRiskAccepted "$risk" \
        --argjson configPathSafe "$config_safe" \
        --argjson configExists "$([ -f "$HERMES_CONFIG" ] && echo true || echo false)" \
        --argjson envExists "$([ -f "$ENV_FILE" ] && echo true || echo false)" \
        --argjson stateExists "$([ -f "$STATE_FILE" ] && echo true || echo false)" \
        --argjson mcpServerCount "$mcp_count" \
        --argjson mcpSdk "$sdk" \
        --argjson mcpReady "$mcp_ready" \
        --argjson browserSdk "$browser_sdk" \
        --argjson gatewayActive "$gateway_active" \
        --argjson gatewayEnabled "$gateway_enabled" \
        --argjson configCheckOk "$config_check" \
        --argjson doctorOk "$doctor_ok" \
        --arg blockedReason "connection-grant-not-enforceable" \
        '{schemaVersion:$schemaVersion,tool:"hermes",id:"hermes",available:$available,installed:$installed,
          configured:$configured,configurationReady:$configurationReady,healthy:$gatewayActive,ready:$ready,
          usageBlocked:true,blockedReason:$blockedReason,commandPath:$commandPath,version:$version,home:$hermesHome,
          configPath:$configPath,configExists:$configExists,configMode:$configMode,configPathSafe:$configPathSafe,
          envFile:$envFile,envExists:$envExists,envMode:$envMode,stateFile:$stateFile,stateExists:$stateExists,
          stateMode:$stateMode,auth:{configured:$authConfigured,method:$authMethod,secretsRedacted:true},
          provenance:{distributionAllowed:$distributionAllowed,operatorRiskAccepted:$operatorRiskAccepted},
          mcp:{serverCount:$mcpServerCount,pythonSdk:$mcpSdk,ready:$mcpReady},
          browser:{pythonSdk:$browserSdk},gateway:{active:$gatewayActive,enabled:$gatewayEnabled},
          configCheckOk:$configCheckOk,
          doctor:{ok:$doctorOk,outputRedacted:true},secretsRedacted:true}'
}

doctor_json() {
    local status policy distribution checksum="" tailscale=false tailscale_auth=false risk=false
    status="$(status_json)"
    distribution="$(distribution_json)"
    checksum="$(jq -r '.installerSha256 // empty' <<< "$distribution")"
    policy="$(bash "$PZ_ROOT/linux/server/ai-policy-broker.sh" check hermes-install checksum="$checksum" 2>/dev/null || echo '{"allow":false,"reasons":["policy probe failed"]}')"
    operator_risk_accepted && risk=true
    command -v tailscale >/dev/null 2>&1 && tailscale=true
    [ "$tailscale" = true ] && tailscale status >/dev/null 2>&1 && tailscale_auth=true
    jq -cn --argjson status "$status" --argjson policy "$policy" --argjson distribution "$distribution" \
        --argjson operatorRiskAccepted "$risk" \
        --argjson tailscaleInstalled "$tailscale" --argjson tailscaleAuthenticated "$tailscale_auth" \
        '{schemaVersion:1,id:"hermes",diagnosticComplete:true,ready:$status.ready,status:$status,
          distribution:($distribution + {sha256Pinned:$distribution.installerPinned,policyAllowed:$policy.allow,
            operatorRiskAccepted:$operatorRiskAccepted,
            installAllowed:($distribution.approvedForInstall or $operatorRiskAccepted)}),
          remoteAccess:{provider:"tailscale",installed:$tailscaleInstalled,
            authenticated:$tailscaleAuthenticated},issues:([
              if ($status.installed|not) then {severity:"error",component:"hermes",code:"hermes-not-installed"} else empty end,
              if ($distribution.manifestValid|not) then {severity:"error",component:"hermes",code:"hermes-distribution-manifest-invalid"} else empty end,
              if ($distribution.installerPinned|not) then {severity:"error",component:"hermes",code:"hermes-installer-untrusted"} else empty end,
              if (($distribution.approvedForInstall|not) and ($operatorRiskAccepted|not)) then {severity:"error",component:"hermes",code:"hermes-distribution-unapproved"} else empty end,
              if ($distribution.transitiveArtifactsPinned|not) then {severity:(if $operatorRiskAccepted then "warning" else "error" end),component:"hermes",code:"hermes-transitive-artifacts-unpinned"} else empty end,
              if ($distribution.semanticAudit|not) then {severity:(if $operatorRiskAccepted then "warning" else "error" end),component:"hermes",code:"hermes-semantic-audit-incomplete"} else empty end,
              if (($distribution.approvedForInstall|not) and $operatorRiskAccepted) then {severity:"warning",component:"hermes",code:"hermes-operator-risk-accepted"} else empty end,
              if ($distribution.signatureVerified|not) then {severity:"warning",component:"hermes",code:"hermes-release-signature-unverified"} else empty end,
              if ($status.auth.configured|not) then {severity:"warning",component:"hermes",code:"hermes-auth-unconfigured"} else empty end,
              if ($status.configExists and $status.configMode != "600") then {severity:"error",component:"hermes",code:"hermes-config-permissions-unsafe"} else empty end,
              if ($status.envExists and $status.envMode != "600") then {severity:"error",component:"hermes",code:"hermes-env-permissions-unsafe"} else empty end,
              if ($status.mcp.ready|not) then {severity:"warning",component:"hermes",code:"hermes-mcp-not-ready"} else empty end,
              if ($status.installed and ($status.browser.pythonSdk|not)) then {severity:"warning",component:"hermes",code:"hermes-browser-sdk-missing"} else empty end,
              if ($status.installed and ($status.gateway.active|not)) then {severity:"warning",component:"hermes",code:"hermes-gateway-inactive"} else empty end,
              if ($status.installed and ($status.gateway.enabled|not)) then {severity:"warning",component:"hermes",code:"hermes-gateway-disabled"} else empty end,
              if $status.usageBlocked then {severity:"warning",component:"hermes",code:"connection-grant-not-enforceable"} else empty end,
              if ($status.configPathSafe|not) then {severity:"error",component:"hermes",code:"hermes-config-path-unsafe"} else empty end,
              if ($tailscaleAuthenticated|not) then {severity:"warning",component:"tailscale",code:"tailscale-unavailable"} else empty end
            ]),secretsRedacted:true}'
}

plan_json() {
    local doctor gate=false allowed=false
    doctor="$(doctor_json)"
    [ "${PZ_HOMELAB_ALLOW_HOST_WORKLOADS:-0}" = 1 ] && gate=true
    if [ "$gate" = true ] && jq -e '.usageBlocked != true and .distribution.manifestValid == true and .distribution.installAllowed == true and
        .distribution.policyAllowed == true' \
        >/dev/null 2>&1 <<< "$doctor"; then
        allowed=true
    fi
    jq -cn \
        --arg home "$HERMES_HOME" --arg configPath "$HERMES_CONFIG" --arg envFile "$ENV_FILE" \
        --argjson doctor "$doctor" --argjson releaseGate "$gate" --argjson deploymentAllowed "$allowed" \
        '{schemaVersion:1,tool:"hermes",id:"hermes",mode:"read-only-plan",releaseGate:$releaseGate,
          deploymentAllowed:$deploymentAllowed,ready:$doctor.ready,usageBlocked:true,
          blockedReason:"connection-grant-not-enforceable",distribution:$doctor.distribution,
          home:$home,configPath:$configPath,envFile:$envFile,
          phases:["verify immutable source, installer and dependency chain","complete semantic security audit",
            "verify policy and release gate","stage isolated install",
            "sync MCP configuration without raw secrets","run config check and doctor","complete official authentication",
            "record version, paths and rollback manifest"],
          blockers:(([if ($releaseGate|not) then "roadmap-host-deployment-blocked" else empty end,
            if ($doctor.distribution.manifestValid|not) then "hermes-distribution-manifest-invalid" else empty end,
            if ($doctor.distribution.installAllowed|not) then "hermes-distribution-unapproved" else empty end,
            if ($doctor.distribution.policyAllowed|not) then "policy-denied" else empty end,
            if $doctor.status.usageBlocked then "connection-grant-not-enforceable" else empty end] +
            [$doctor.issues[]?.code]) | unique),secretsRedacted:true}'
}

case "${1:-setup}" in
    setup)
        require_connection_grant
        require_workload_release_gate
        install_hermes
        configure_hermes
        install_gateway_service
        status_json
        ;;
    install) require_connection_grant; require_workload_release_gate; install_hermes ;;
    configure) require_connection_grant; require_workload_release_gate; configure_hermes ;;
    mcp) require_connection_grant; require_workload_release_gate; bash "$PZ_ROOT/linux/ai/mcp-manager.sh" sync hermes ;;
    status) status_json ;;
    dry-run|plan) plan_json ;;
    doctor|diagnose) doctor_json ;;
    portal)
        require_connection_grant
        require_workload_release_gate
        cmd="$(hermes_cmd || true)"
        [ -n "$cmd" ] || { pz_error "Hermes not installed"; exit 1; }
        "$cmd" setup --portal
        ;;
    gateway) require_connection_grant; require_workload_release_gate; install_gateway_service ;;
    *) echo "usage: setup-hermes.sh (setup|install|configure|mcp|gateway|status|doctor|dry-run|portal)"; exit 1 ;;
esac
