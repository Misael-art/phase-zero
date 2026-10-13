#!/usr/bin/env bash
# rotate-secrets.sh - AI API key rotation via pass + age
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"

pz_check_deps pass age jq python3

PASS_DIR="${PASSWORD_STORE_DIR:-$HOME/.password-store}/phasezero"
SCHEMA="$PZ_ROOT/secrets/schema.json"

if [ ! -f "$SCHEMA" ]; then
    pz_error "secrets schema not found: $SCHEMA"
    exit 1
fi

# Initialize pass if needed
if [ ! -d "$HOME/.password-store" ]; then
    pz_info "initializing pass store"
    key=""
    key=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep sec | head -1 | awk '{print $2}' | cut -d/ -f2)
    if [ -n "$key" ]; then
        pass init "$key"
    else
        pz_error "no GPG key found. generate one: gpg --full-generate-key"
        exit 1
    fi
fi

mkdir -p "$PASS_DIR"

rotate_entry() {
    local key="$1" desc="$2"
    local pass_path="phasezero/$key"

    if pass show "$pass_path" &>/dev/null; then
        pz_info "existing $key found in pass store"
        return 0
    fi

    # Prompt for new value - do TTY, não do stdin do loop: sem o redirecionar,
    # o read consumia a PRÓXIMA linha do esquema como valor do segredo.
    read -r -s -p "Enter new value for $key ($desc): " value < /dev/tty
    echo
    if [ -n "$value" ]; then
        echo "$value" | pass insert -f "$pass_path" >/dev/null
        pz_info "$key saved to pass store"
    fi
}

apply_secret_to_config() {
    local key="$1" target="$2" pattern="$3"
    local value
    value=$(pass show "phasezero/$key" 2>/dev/null) || return

    if [ "${PZ_AI_APPLY_RAW_SECRETS:-0}" != "1" ]; then
        pz_warn "raw secret write skipped for $target; set PZ_AI_APPLY_RAW_SECRETS=1 only if this app has no secret-store integration"
        return 0
    fi

    target="${target/#\~/$HOME}"
    if [ ! -f "$target" ]; then
        pz_warn "target config not found: $target"
        return
    fi

    local backup
    backup="$(pz_backup_file "$target" user)"
    pz_rollback_register file "$target" "$backup"

    if ! printf '%s' "$value" | python3 -c '
import os
import pathlib
import sys
import tempfile
target = pathlib.Path(sys.argv[1])
pattern = sys.argv[2]
secret = sys.stdin.read()
text = target.read_text(encoding="utf-8")
if pattern not in text:
    raise SystemExit(3)
fd, temp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text.replace(pattern, secret))
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp_name, target.stat().st_mode & 0o777)
    os.replace(temp_name, target)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
' "$target" "$pattern"; then
        pz_warn "could not apply $key to $target (placeholder absent or write failed)"
    fi
}

pz_info "secrets rotation for PhaseZero"

# Rotate each entry in schema
entries=$(jq -r '.entries[] | "\(.key) \(.description)"' "$SCHEMA")
while IFS=' ' read -r key desc; do
    [ -z "$key" ] && continue
    rotate_entry "$key" "$desc"
done <<< "$entries"

# Apply secrets to config files
pz_info "applying secrets to config files..."
while IFS= read -r entry; do
    key=""
    paths=""
    key=$(echo "$entry" | jq -r '.key')
    paths=$(echo "$entry" | jq -r '.paths.linux // [] | .[]')
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        apply_secret_to_config "$key" "$path" "<${key}>"
    done <<< "$paths"
done < <(jq -c '.entries[]' "$SCHEMA")

pz_info "secrets rotation complete"
