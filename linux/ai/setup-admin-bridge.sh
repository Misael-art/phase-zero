#!/usr/bin/env bash
# setup-admin-bridge.sh - configure graphical/admin escalation for Linux AI CLIs/IDEs
set -euo pipefail

PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

LOCAL_BIN="${PZ_LOCAL_BIN:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/phasezero"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/phasezero/ai"
ADMIN_BIN="$LOCAL_BIN/phasezero-admin"
FALLBACK_BIGSUDO="$LOCAL_BIN/bigsudo"
CONFIG_JSON="$CONFIG_DIR/admin-bridge.json"
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
ENV_FILE="$ENV_DIR/90-phasezero-admin.conf"
STATE_FILE="$STATE_DIR/admin-bridge.json"

real_bigsudo_path() {
    local candidate real_candidate real_fallback
    real_fallback="$(readlink -f "$FALLBACK_BIGSUDO" 2>/dev/null || true)"
    for candidate in /usr/sbin/bigsudo /usr/bin/bigsudo "$(command -v bigsudo 2>/dev/null || true)"; do
        [ -n "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        real_candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [ -n "$real_fallback" ] && [ "$real_candidate" = "$real_fallback" ] && continue
        if grep -q 'PHASEZERO_ADMIN_FALLBACK' "$candidate" 2>/dev/null; then
            continue
        fi
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

backend_record() {
    local bigsudo_path="" backend="missing" backend_path="" fallback=false pkexec_path="" sudo_path=""
    bigsudo_path="$(real_bigsudo_path || true)"
    pkexec_path="$(command -v pkexec 2>/dev/null || true)"
    sudo_path="$(command -v sudo 2>/dev/null || true)"
    if [ -n "$bigsudo_path" ]; then
        backend="bigsudo"
        backend_path="$bigsudo_path"
    elif [ -x "$FALLBACK_BIGSUDO" ]; then
        backend="phasezero-bigsudo-fallback"
        backend_path="$FALLBACK_BIGSUDO"
        fallback=true
    elif [ -n "$pkexec_path" ]; then
        backend="pkexec"
        backend_path="$pkexec_path"
    elif [ -n "$sudo_path" ]; then
        backend="sudo"
        backend_path="$sudo_path"
    fi
    jq -cn \
        --arg backend "$backend" \
        --arg backendPath "$backend_path" \
        --arg bigsudoPath "$bigsudo_path" \
        --arg pkexecPath "$pkexec_path" \
        --arg sudoPath "$sudo_path" \
        --arg adminBin "$ADMIN_BIN" \
        --arg fallbackBigsudo "$FALLBACK_BIGSUDO" \
        --arg config "$CONFIG_JSON" \
        --arg envFile "$ENV_FILE" \
        --argjson fallback "$fallback" \
        --argjson ready "$([ "$backend" != "missing" ] && [ -x "$ADMIN_BIN" ] && echo true || echo false)" \
        '{schemaVersion:1,ready:$ready,backend:$backend,backendPath:$backendPath,bigsudoPath:$bigsudoPath,pkexecPath:$pkexecPath,sudoPath:$sudoPath,phasezeroAdmin:$adminBin,fallbackBigsudo:$fallbackBigsudo,fallbackInstalled:$fallback,configPath:$config,envFile:$envFile,policy:{noPasswordlessSudo:true,noStoredPassword:true,preferBigsudo:true,fallbackOrder:["bigsudo","pkexec","sudo"]}}'
}

install_bigsudo_if_possible() {
    real_bigsudo_path >/dev/null 2>&1 && return 0
    if ! pacman -Si bigsudo >/dev/null 2>&1; then
        return 1
    fi
    if command -v pkexec >/dev/null 2>&1; then
        pkexec pacman -S --needed --noconfirm bigsudo || return 1
    elif pz_can_sudo_noninteractive; then
        sudo -n pacman -S --needed --noconfirm bigsudo || return 1
    else
        return 1
    fi
    real_bigsudo_path >/dev/null 2>&1
}

write_phasezero_admin() {
    mkdir -p "$LOCAL_BIN"
    pz_write_managed_file "$ADMIN_BIN" <<'EOF'
#!/usr/bin/env bash
# PhaseZero managed admin bridge. No password storage, no passwordless sudo.
set -euo pipefail

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

is_phasezero_fallback() {
    local candidate="$1"
    grep -q 'PHASEZERO_ADMIN_FALLBACK' "$candidate" 2>/dev/null
}

real_bigsudo() {
    local candidate real_candidate fallback="$HOME/.local/bin/bigsudo" real_fallback=""
    real_fallback="$(readlink -f "$fallback" 2>/dev/null || true)"
    for candidate in /usr/sbin/bigsudo /usr/bin/bigsudo "$(command -v bigsudo 2>/dev/null || true)"; do
        [ -n "$candidate" ] || continue
        [ -x "$candidate" ] || continue
        real_candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [ -n "$real_fallback" ] && [ "$real_candidate" = "$real_fallback" ] && continue
        is_phasezero_fallback "$candidate" && continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

backend_path() {
    local bigsudo_path=""
    bigsudo_path="$(real_bigsudo || true)"
    if [ -n "$bigsudo_path" ]; then
        printf '%s\t%s\n' "bigsudo" "$bigsudo_path"
    elif command -v pkexec >/dev/null 2>&1; then
        printf '%s\t%s\n' "pkexec" "$(command -v pkexec)"
    elif command -v sudo >/dev/null 2>&1; then
        printf '%s\t%s\n' "sudo" "$(command -v sudo)"
    else
        printf '%s\t%s\n' "missing" ""
        return 1
    fi
}

status_json() {
    local pair backend path ready=false
    pair="$(backend_path || true)"
    backend="${pair%%	*}"
    path="${pair#*	}"
    [ "$backend" != "missing" ] && ready=true
    printf '{"schemaVersion":1,"ready":%s,"backend":"%s","backendPath":"%s","phasezeroAdmin":"%s","policy":{"noPasswordlessSudo":true,"noStoredPassword":true}}\n' \
        "$ready" "$(json_escape "$backend")" "$(json_escape "$path")" "$(json_escape "$0")"
}

case "${1:-}" in
    --status|status)
        status_json
        exit 0
        ;;
    --backend|backend)
        backend_path | cut -f1
        exit 0
        ;;
    --backend-path|backend-path)
        backend_path | cut -f2
        exit 0
        ;;
    --dry-run|dry-run)
        shift
        pair="$(backend_path || true)"
        printf 'phasezero-admin dry-run: backend=%s path=%s args=%q\n' "${pair%%	*}" "${pair#*	}" "$*"
        exit 0
        ;;
    -h|--help|"")
        echo "usage: phasezero-admin [--status|--backend|--backend-path|--dry-run] <command> [args...]"
        exit 0
        ;;
esac

pair="$(backend_path || true)"
backend="${pair%%	*}"
path="${pair#*	}"
[ "$backend" != "missing" ] && [ -n "$path" ] || {
    echo "phasezero-admin: no admin backend found (install bigsudo, pkexec, or sudo)" >&2
    exit 127
}
exec "$path" "$@"
EOF
    chmod 0755 "$ADMIN_BIN" 2>/dev/null || true
}

write_bigsudo_fallback() {
    real_bigsudo_path >/dev/null 2>&1 && return 0
    mkdir -p "$LOCAL_BIN"
    pz_write_managed_file "$FALLBACK_BIGSUDO" <<'EOF'
#!/usr/bin/env bash
# PHASEZERO_ADMIN_FALLBACK
exec "$HOME/.local/bin/phasezero-admin" "$@"
EOF
    chmod 0755 "$FALLBACK_BIGSUDO" 2>/dev/null || true
}

write_configs() {
    mkdir -p "$CONFIG_DIR" "$ENV_DIR" "$STATE_DIR"
    backend_record > "$CONFIG_JSON"
    backend_record > "$STATE_FILE"
    pz_write_managed_file "$ENV_FILE" <<EOF
PHASEZERO_ADMIN=phasezero-admin
PHASEZERO_ADMIN_COMMAND=$ADMIN_BIN
PHASEZERO_ADMIN_BACKEND=$(jq -r '.backend' "$STATE_FILE")
EOF
}

apply_agent_rules() {
    local rc=0
    bash "$PZ_ROOT/linux/ai/setup-agent-compat.sh" rules >/dev/null || rc=$?
    case "$rc" in
        0) ;;
        2) pz_info "no registered project; agent rules skipped (run: linux/pz ai init <dir>)" ;;
        *) pz_warn "agent rule sync failed" ;;
    esac
}

setup_admin_bridge() {
    install_bigsudo_if_possible || true
    write_phasezero_admin
    write_bigsudo_fallback
    write_configs
    apply_agent_rules
    status_json
}

status_json() {
    backend_record
}

dry_run() {
    jq -cn \
        --arg localBin "$LOCAL_BIN" \
        --arg adminBin "$ADMIN_BIN" \
        --arg fallbackBigsudo "$FALLBACK_BIGSUDO" \
        '{tool:"admin-bridge",planned:["install bigsudo via pacman/pkexec when missing and available","write phasezero-admin wrapper","write bigsudo fallback wrapper only when official bigsudo is absent","write user env/config state","sync agent/IDE rules"],localBin:$localBin,phasezeroAdmin:$adminBin,fallbackBigsudo:$fallbackBigsudo,security:{noPasswordlessSudo:true,noStoredPassword:true}}'
}

case "${1:-setup}" in
    setup|install|configure) setup_admin_bridge ;;
    status) status_json ;;
    dry-run|plan) dry_run ;;
    rules) apply_agent_rules ;;
    *) echo "usage: setup-admin-bridge.sh (setup|status|dry-run|rules)" >&2; exit 1 ;;
esac
